//
//  ScopePerf.swift
//  Manifold
//
//  [SCOPE-PERF] (pre-ship list, docs/BUGS.md): DEBUG-only counters for the scope playback-cost item,
//  "while playing with the tray open, every scope publish re-runs the whole ContentView body".
//

#if DEBUG
import Foundation
import CoreGraphics

/// `MANIFOLD_SCOPE_PERF=1` (launch environment, never `defaults`): once a second, how many times each counted event
/// happened in that second — frames rendered, each scope's compute passes and publishes, and the body evaluations of the
/// window's main views. Unset, `count` is one Bool test and nothing else runs: no lock, no timer, no output.
///
/// Process-wide, not per window: the measurement runs one window. Thread-safe (renderer completion threads and main).
enum ScopePerf {
    static let enabled = ProcessInfo.processInfo.environment["MANIFOLD_SCOPE_PERF"] == "1"

    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]
    private static var timer: DispatchSourceTimer?

    static func count(_ key: String) {
        guard enabled else { return }
        lock.lock()
        counts[key, default: 0] += 1
        if timer == nil {
            let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { flush() }
            t.resume()
            timer = t
        }
        lock.unlock()
    }

    /// `MANIFOLD_SCOPE_DUMP_DIR=<dir>` (launch environment): every scope image published is also written there,
    /// overwriting, as `<scope>.rgba` (the CGImage's bytes as drawn into an 8-bit RGBA premultiplied context) and
    /// `<scope>.json` (width, height, a publish sequence number). Lets a run compare a paused frame's scope pictures
    /// between two builds at the data level, with no screenshot.
    static let dumpDir = ProcessInfo.processInfo.environment["MANIFOLD_SCOPE_DUMP_DIR"]
    private static var dumpSeq: [String: Int] = [:]

    /// Count a publish of `scope`'s trace image, and dump it when `MANIFOLD_SCOPE_DUMP_DIR` is set. Main thread.
    static func published(_ scope: String, _ image: CGImage) {
        count("pub.\(scope)")
        guard let dir = dumpDir else { return }
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return }
        let seq = (dumpSeq[scope] ?? 0) + 1
        dumpSeq[scope] = seq
        try? Data(bytes).write(to: URL(fileURLWithPath: "\(dir)/\(scope).rgba"))
        try? Data("{\"width\":\(w),\"height\":\(h),\"seq\":\(seq)}".utf8)
            .write(to: URL(fileURLWithPath: "\(dir)/\(scope).json"))
    }

    private static func flush() {
        lock.lock()
        let snapshot = counts
        counts = [:]
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        let line = snapshot.keys.sorted().map { "\($0)=\(snapshot[$0]!)" }.joined(separator: " ")
        print("[SCOPE-PERF] \(line)")
    }
}
#endif
