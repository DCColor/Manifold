//
//  MarkerThumbnailCache.swift — marker thumbnails on disk (docs/MARKERS_PLAN.md §4.4, Robbie 2026-11-15).
//
//      ~/Library/Caches/com.graviton.manifold/MarkerThumbnails/<fingerprint>/<frame>.jpg
//
//  A CACHE: Caches only (macOS may purge it; a missing file is made again), keyed by the file's content fingerprint and
//  the frame, so it follows the markers' own key (`MarkerStore`). Cleared with the file's markers: a deleted marker's
//  thumbnail goes with it (`keepOnly`), and a file whose last marker is deleted loses its folder.
//
//  ⚠️ PRIVACY: these are pictures from the user's media. Never logged, never in Export Diagnostics, never anywhere
//  else (docs/PRIVACY_AUDIT.md §1).
//

import Foundation

public struct MarkerThumbnailCache: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func standard() -> MarkerThumbnailCache {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return MarkerThumbnailCache(directory: base.appendingPathComponent("com.graviton.manifold", isDirectory: true)
            .appendingPathComponent("MarkerThumbnails", isDirectory: true))
    }

    func folder(_ fingerprint: String) -> URL? {
        guard !fingerprint.isEmpty, fingerprint.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }) else { return nil }
        return directory.appendingPathComponent(fingerprint, isDirectory: true)
    }

    public func url(fingerprint: String, frame: Int) -> URL? {
        guard frame >= 0 else { return nil }
        return folder(fingerprint)?.appendingPathComponent("\(frame).jpg")
    }

    public func read(fingerprint: String, frame: Int) -> Data? {
        url(fingerprint: fingerprint, frame: frame).flatMap { try? Data(contentsOf: $0) }
    }

    public func write(_ jpeg: Data, fingerprint: String, frame: Int) {
        guard let dir = folder(fingerprint), let u = url(fingerprint: fingerprint, frame: frame) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? jpeg.write(to: u, options: .atomic)
    }

    /// Remove every thumbnail of this file whose frame is not in `frames`; the folder too when `frames` is empty.
    public func keepOnly(_ frames: Set<Int>, fingerprint: String) {
        guard let dir = folder(fingerprint) else { return }
        if frames.isEmpty { try? FileManager.default.removeItem(at: dir); return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names {
            guard name.hasSuffix(".jpg"), let f = Int(name.dropLast(4)), !frames.contains(f) else { continue }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
