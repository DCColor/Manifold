//
//  SettingsBackups.swift — the automatic backup taken before any import (docs/SETTINGS_EXPORT_PLAN.md §4.5).
//
//  Shortcuts only, and never a secret. A backup that cannot be written and read back equal stops the import.
//

import Foundation

public struct SettingsBackups {
    public static let defaultKeep = 10
    private static let prefix = "Shortcuts "

    public enum BackupError: Error, Equatable { case notWritten, readBackDiffers }

    public let directory: URL
    public let keep: Int

    public init(directory: URL = SettingsBackups.defaultDirectory, keep: Int = SettingsBackups.defaultKeep) {
        self.directory = directory
        self.keep = keep
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.graviton.manifold", isDirectory: true)
            .appendingPathComponent("Settings Backups", isDirectory: true)
    }

    /// Write `data`, read it back, compare, then keep the newest `keep`.
    @discardableResult
    public func write(_ data: Data, at date: Date) throws -> URL {
        let url: URL
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = freeURL(for: date)
            try data.write(to: url, options: .atomic)
        } catch {
            throw BackupError.notWritten
        }
        guard (try? Data(contentsOf: url)) == data else { throw BackupError.readBackDiffers }
        prune()
        return url
    }

    /// Newest first. The names sort by date.
    public func list() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return names.filter { $0.pathExtension == SettingsFile.fileExtension && $0.lastPathComponent.hasPrefix(Self.prefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func freeURL(for date: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stem = Self.prefix + f.string(from: date)
        var url = directory.appendingPathComponent("\(stem).\(SettingsFile.fileExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(stem) \(n).\(SettingsFile.fileExtension)")
            n += 1
        }
        return url
    }

    /// Removes only this type's own files, past the newest `keep`.
    private func prune() {
        for url in list().dropFirst(keep) { try? FileManager.default.removeItem(at: url) }
    }
}
