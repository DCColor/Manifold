//
//  FileFingerprint.swift — the key markers are stored under (docs/MARKERS_PLAN.md §5, D15).
//
//  SHA-256 over a version tag, the file's size, its first 4 MB and its last 4 MB (the whole file once, if it is 8 MB or
//  less). Content only: no path, no name, no dates, so a rename, a move or a copy to another volume keeps the key, and a
//  re-render or re-wrap (a different file) does not. Not the frame count or rate either (the plan had them): a later
//  build reading a file's rate or length differently would have orphaned its markers.
//
//  Reads at most 8 MB, never writes. On a network volume that is the cost of opening a file's markers.
//

import Foundation
import CryptoKit

public enum FileFingerprint {
    public static let edgeBytes = 4 * 1024 * 1024
    static let tag = Data("manifold.markers.fingerprint.v1".utf8)

    /// Hex SHA-256, or nil when the file cannot be read.
    public static func compute(url: URL, edgeBytes: Int = FileFingerprint.edgeBytes) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return nil }
        var hasher = SHA256()
        hasher.update(data: tag)
        var le = size.littleEndian
        hasher.update(data: Data(bytes: &le, count: 8))
        do {
            try fh.seek(toOffset: 0)
            if size <= UInt64(edgeBytes * 2) {
                guard let all = try fh.read(upToCount: Int(size)) else { return nil }
                hasher.update(data: all)
            } else {
                guard let head = try fh.read(upToCount: edgeBytes) else { return nil }
                try fh.seek(toOffset: size - UInt64(edgeBytes))
                guard let tail = try fh.read(upToCount: edgeBytes) else { return nil }
                hasher.update(data: head)
                hasher.update(data: tail)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
