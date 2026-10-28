//
//  MachineID.swift
//  LicenseClient — the hardware-derived machine ID, macOS only.
//
//  A port of license.js `computeMachineId` / `normalizeUuid` / `sha256Prefix` / `cacheMachineId`.
//  SHA-256 of the normalised hardware UUID, first 32 lowercase hex characters, so a reinstall of
//  the app or the OS produces the same ID and does not spend another of the key's slots. On this
//  Mac it must equal what `getMachineId()` in license.js answers, which every Electron app sends.
//
//  Sources, tried in this fixed order:
//
//    'ioreg'            IOPlatformUUID, read from the IORegistry with IOKit — the property
//                       `ioreg -rd1 -c IOPlatformExpertDevice` prints. Stored under the source name
//                       license.js uses for it (Robbie, 2026-10-28, D2).
//    'system_profiler'  "Hardware UUID" from `system_profiler SPHardwareDataType`, 5 s timeout.
//
//  ⚠️ NO HOSTNAME FALLBACK. A hostname is what an OS reinstall changes, so a hostname ID would
//  quietly cost the customer a slot later. With no source the answer is no ID, and activation
//  refuses.
//
//  Self-contained (Foundation, CryptoKit, IOKit) so a harness can compile it on its own.
//

import Foundation
import CryptoKit
import IOKit

public struct MachineIdResult: Equatable, Sendable {
    public let id: String?
    public let source: String?

    public init(id: String?, source: String?) {
        self.id = id
        self.source = source
    }

    public static let none = MachineIdResult(id: nil, source: nil)
}

public enum MachineID {

    public typealias Source = (name: String, read: @Sendable () async throws -> String?)

    /// The macOS sources, in order. Injectable for tests.
    public static let darwinSources: [Source] = [
        ("ioreg", { try readIOPlatformUUID() }),
        ("system_profiler", { parseSystemProfiler(try await runSystemProfiler()) }),
    ]

    /// The first source that yields a valid UUID wins. A source that throws, or yields something
    /// that does not normalise, is skipped.
    public static func compute(sources: [Source] = darwinSources) async -> MachineIdResult {
        for source in sources {
            if let raw = try? await source.read(), let uuid = normalizeUuid(raw) {
                return MachineIdResult(id: sha256Prefix(uuid), source: source.name)
            }
        }
        return .none
    }

    private static let uuidPattern = try! NSRegularExpression(
        pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")

    /// Trim, strip one leading `{` and one trailing `}`, uppercase, then require a UUID. All
    /// zeros and all Fs are firmware placeholders many machines share, so they are rejected.
    public static func normalizeUuid(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("{") { s.removeFirst() }
        if s.hasSuffix("}") { s.removeLast() }
        let uuid = s.uppercased()
        let range = NSRange(uuid.startIndex..., in: uuid)
        guard uuidPattern.firstMatch(in: uuid, range: range) != nil else { return nil }
        if uuid.allSatisfy({ $0 == "0" || $0 == "-" }) || uuid.allSatisfy({ $0 == "F" || $0 == "-" }) {
            return nil
        }
        return uuid
    }

    public static func sha256Prefix(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    // MARK: - Sources

    struct SourceFailure: Error {}

    /// IOPlatformUUID straight from the IORegistry. No subprocess.
    static func readIOPlatformUUID() throws -> String? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard entry != 0 else { throw SourceFailure() }
        defer { IOObjectRelease(entry) }
        let property = IORegistryEntryCreateCFProperty(entry, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        return property?.takeRetainedValue() as? String
    }

    /// license.js: `out.match(/Hardware UUID:\s*(\S+)/)`.
    public static func parseSystemProfiler(_ output: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"Hardware UUID:\s*(\S+)"#),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return String(output[range])
    }

    static let commandTimeout: TimeInterval = 5

    /// `system_profiler SPHardwareDataType`, killed after 5 s. Rejects on a non-zero exit or a
    /// timeout, as execFile does. Runs on a dispatch queue: it blocks a thread while it waits.
    static func runSystemProfiler(timeout: TimeInterval = commandTimeout) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
                process.arguments = ["SPHardwareDataType"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let kill = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: kill)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                kill.cancel()
                guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                    continuation.resume(throwing: SourceFailure())
                    return
                }
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    // MARK: - Caching

    /// Computed once per process: the hardware does not change under us. A result with no ID is
    /// not kept, so the next call reads the hardware again. Concurrent calls share one read. A
    /// compute that throws is reported as no ID, never as an error.
    public actor Cache {
        private let compute: @Sendable () async throws -> MachineIdResult
        private var inFlight: Task<MachineIdResult, Never>?

        public init(_ compute: @escaping @Sendable () async throws -> MachineIdResult) {
            self.compute = compute
        }

        public func get() async -> MachineIdResult {
            if let inFlight { return await inFlight.value }
            let compute = self.compute
            let task = Task { (try? await compute()) ?? .none }
            inFlight = task
            let result = await task.value
            if result.id == nil, inFlight == task { inFlight = nil }
            return result
        }
    }

    /// The process-wide cache the client uses by default.
    public static let shared = Cache { await compute() }

    public struct Unavailable: Error, Equatable {
        /// license.js `getMachineId` rejects with this; the error carries no ID.
        public let message = "Couldn't read this computer's hardware ID"
    }

    /// license.js `getMachineId()`: the 32-hex ID, or throws when no hardware source works.
    public static func getMachineId(_ cache: Cache = shared) async throws -> String {
        guard let id = await cache.get().id else { throw Unavailable() }
        return id
    }
}
