//
//  MarkerStore.swift — one JSON file per media file, in Manifold's own Application Support folder (docs/MARKERS_PLAN.md
//  §5, D15). Never next to the media, never in the media, never in UserDefaults (so never in Settings Transfer, D12).
//
//      ~/Library/Application Support/com.graviton.manifold/Markers/<fingerprint>.json
//
//  Atomic writes (temp file, rename). A document with no markers and no override is removed rather than kept empty.
//  Nothing here logs: callers log counts (§5.1).
//

import Foundation

public struct MarkerStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// The app's store.
    public static func standard() -> MarkerStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return MarkerStore(directory: base.appendingPathComponent("com.graviton.manifold", isDirectory: true)
            .appendingPathComponent("Markers", isDirectory: true))
    }

    public enum StoreError: Error { case badFingerprint }

    func url(for fingerprint: String) throws -> URL {
        // A fingerprint is lowercase hex; anything else would be a path.
        guard !fingerprint.isEmpty, fingerprint.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }) else {
            throw StoreError.badFingerprint
        }
        return directory.appendingPathComponent(fingerprint + ".json")
    }

    /// The stored document, or nil when there is none. Throws when one exists and cannot be read: the caller must not
    /// then save over it.
    public func load(fingerprint: String) throws -> MarkerDocument? {
        let u = try url(for: fingerprint)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        let data = try Data(contentsOf: u)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MarkerDocument.self, from: data)
    }

    /// Settings ▸ Delete All Stored Markers…: every stored document. Returns how many there were.
    @discardableResult
    public func deleteAll() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let n = names.filter { $0.hasSuffix(".json") }.count
        try? FileManager.default.removeItem(at: directory)
        return n
    }

    public func save(_ doc: MarkerDocument) throws {
        let u = try url(for: doc.fingerprint)
        if doc.markers.isEmpty && doc.startOverride == nil {
            if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(doc).write(to: u, options: .atomic)
    }
}
