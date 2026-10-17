import XCTest
import CoreMedia
@testable import FrameGrid

/// The step targets, at the eight rates of the 2026-10-16 fix and the real files' timescales: every frame time is
/// exact, every step from frame n lands on n ± k, the ends clamp, and a variable-rate track gets no grid.
final class FrameGridTests: XCTestCase {
    /// (name, timescale, frame duration in that timescale, nominalFrameRate as AVFoundation reports it)
    private let rates: [(String, Int32, Int64, Float)] = [
        ("23.976", 24000, 1001, 23.976025), ("24", 24, 1, 24), ("25", 25, 1, 25), ("25 (12800)", 12800, 512, 25),
        ("29.97", 30000, 1001, 29.97003), ("30", 30, 1, 30), ("50", 50, 1, 50),
        ("59.94", 60000, 1001, 59.94006), ("60", 60, 1, 60), ("24 (600)", 600, 25, 24),
    ]

    private func grid(_ ts: Int32, _ dur: Int64, _ nfr: Float, frames: Int = 30,
                      origin: CMTime = .zero) -> FrameGrid {
        FrameGrid(origin: origin, frameDuration: CMTime(value: dur, timescale: ts),
                  trackDuration: CMTime(value: dur * Int64(frames), timescale: ts), nominalFrameRate: nfr)!
    }

    func testFrameTimesAreExact() {
        for (name, ts, dur, nfr) in rates {
            let g = grid(ts, dur, nfr)
            XCTAssertEqual(g.frameCount, 30, name)
            for n in 0..<30 {
                // Exactly n × duration in the track's own time: no seconds, no rounding.
                XCTAssertEqual(CMTimeCompare(g.time(ofFrame: n), CMTime(value: Int64(n) * dur, timescale: ts)), 0, "\(name) n=\(n)")
            }
        }
    }

    /// The bug, stated as the old arithmetic: at the NTSC rates `n / Float fps` at timescale 600 falls in frame
    /// n−1's interval; the grid's own time falls on frame n.
    func testOldTargetWasEarlyAndGridIsNot() {
        for (name, ts, dur, nfr) in rates where dur == 1001 {
            let g = grid(ts, dur, nfr)
            let old = CMTime(seconds: 1 / Double(nfr), preferredTimescale: 600)
            XCTAssertLessThan(CMTimeCompare(old, g.time(ofFrame: 1)), 0, "\(name): old target is before frame 1")
            XCTAssertEqual(g.frame(atSeconds: old.seconds), 0, "\(name): old target names frame 0")
            XCTAssertEqual(g.frame(atSeconds: g.seconds(ofFrame: 1)), 1, name)
        }
    }

    func testEveryStepLandsOnTheNextFrame() {
        for (name, ts, dur, nfr) in rates {
            let g = grid(ts, dur, nfr)
            var t = g.seconds(ofFrame: 0)
            for n in 1..<30 {                                   // → from 0 to the last frame
                let f = g.frame(steppingFrom: t, by: 1)
                XCTAssertEqual(f, n, "\(name) forward")
                t = g.seconds(ofFrame: f)
            }
            XCTAssertEqual(g.frame(steppingFrom: t, by: 1), 29, "\(name): → at the last frame stays")
            XCTAssertEqual(g.frame(steppingFrom: t, by: 1000), 29, name)
            for n in stride(from: 28, through: 0, by: -1) {    // ← back to 0
                let f = g.frame(steppingFrom: t, by: -1)
                XCTAssertEqual(f, n, "\(name) back")
                t = g.seconds(ofFrame: f)
            }
            XCTAssertEqual(g.frame(steppingFrom: t, by: -1), 0, "\(name): ← at frame 0 stays")
            XCTAssertEqual(g.frame(steppingFrom: t, by: Int.min), 0, name)
            XCTAssertEqual(g.frame(steppingFrom: g.seconds(ofFrame: 3), by: Int.max), 29, name)
        }
    }

    /// Mid-interval times (a pause between frames, a scrub release) name the frame on screen; a step goes from it.
    func testMidFrameNamesTheFrameShowing() {
        for (name, ts, dur, nfr) in rates {
            let g = grid(ts, dur, nfr)
            for n in 0..<29 {
                let t0 = g.seconds(ofFrame: n), d = g.frameDuration.seconds
                XCTAssertEqual(g.frame(atSeconds: t0 + 0.5 * d), n, name)
                XCTAssertEqual(g.frame(atSeconds: t0 + 0.99 * d), n, name)
                XCTAssertEqual(g.frame(steppingFrom: t0 + 0.7 * d, by: 1), n + 1, name)
                // A frame's time a hair short (Double round-trip) still names that frame.
                XCTAssertEqual(g.frame(atSeconds: t0 - 1e-9), n, name)
            }
            XCTAssertEqual(g.frame(atSeconds: -5), 0)
            XCTAssertEqual(g.frame(atSeconds: 1e9), 29)
        }
    }

    func testOriginIsHonoured() {
        let g = grid(24000, 1001, 23.976025, origin: CMTime(value: 2002, timescale: 24000))
        XCTAssertEqual(CMTimeCompare(g.time(ofFrame: 0), CMTime(value: 2002, timescale: 24000)), 0)
        XCTAssertEqual(g.frame(atSeconds: CMTime(value: 2002 + 1001 * 5, timescale: 24000).seconds), 5)
    }

    /// A long file at 29.97 (the 48-minute `2997p.mov` has 87 549 frames): the last frame is exact and reachable.
    func testLongFile() {
        let g = grid(30000, 1001, 29.97003, frames: 87549)
        XCTAssertEqual(g.lastIndex, 87548)
        XCTAssertEqual(CMTimeCompare(g.time(ofFrame: 87548), CMTime(value: 87548 * 1001, timescale: 30000)), 0)
        XCTAssertEqual(g.frame(steppingFrom: g.seconds(ofFrame: 87547), by: 1), 87548)
        XCTAssertEqual(g.frame(steppingFrom: g.seconds(ofFrame: 87548), by: 1), 87548)
    }

    /// No grid where the facts are not a constant-rate track: the caller keeps its old arithmetic.
    func testRefusals() {
        let d = CMTime(value: 1001, timescale: 24000), long = CMTime(value: 30030, timescale: 24000)
        // Variable rate: minFrameDuration is the fastest frame (1/60) on a track averaging 29.6.
        XCTAssertNil(FrameGrid(origin: .zero, frameDuration: CMTime(value: 1, timescale: 60), trackDuration: long, nominalFrameRate: 29.6))
        XCTAssertNil(FrameGrid(origin: .zero, frameDuration: .invalid, trackDuration: long, nominalFrameRate: 23.976025))
        XCTAssertNil(FrameGrid(origin: .zero, frameDuration: CMTime(value: 0, timescale: 24000), trackDuration: long, nominalFrameRate: 24))
        XCTAssertNil(FrameGrid(origin: .zero, frameDuration: d, trackDuration: .indefinite, nominalFrameRate: 23.976025))
        XCTAssertNil(FrameGrid(origin: .zero, frameDuration: d, trackDuration: long, nominalFrameRate: 0))
        XCTAssertNil(FrameGrid(origin: .zero, frameDuration: d, trackDuration: .zero, nominalFrameRate: 23.976025))
        // The real tolerance: 23.976 against a nominal that is the Float of 24000/1001 passes, 24 against it fails.
        XCTAssertNotNil(FrameGrid(origin: .zero, frameDuration: d, trackDuration: long, nominalFrameRate: Float(24000.0 / 1001.0)))
        XCTAssertNil(FrameGrid(origin: .zero, frameDuration: d, trackDuration: long, nominalFrameRate: 24))
    }

    /// A typed timecode seeks to `(n + 0.25) / rate` (TimecodeEntry). On the libav path the start is the grid's frame
    /// for that time, so it must name frame n at every rate, late in a long file too, and its exact time must be
    /// frame n's (docs/BUGS.md, "a typed timecode lands one frame late on MXF and every libav-decoded file").
    func testQuarterFrameNudgeNamesTheFrameTyped() {
        for (value, scale) in [(1001, 24000), (1, 24), (1, 25), (1001, 30000), (1001, 60000)] as [(Int64, Int32)] {
            let d = CMTime(value: value, timescale: scale)
            let rate = Double(scale) / Double(value)
            let count = 216_000
            guard let g = FrameGrid(origin: .zero, frameDuration: d,
                                    trackDuration: CMTimeMultiply(d, multiplier: Int32(count)),
                                    nominalFrameRate: Float(rate)) else { return XCTFail("no grid at \(rate)") }
            for n in [0, 1, 12, 1485, count - 2, count - 1] {
                let typed = (Double(n) + 0.25) / rate
                XCTAssertEqual(g.frame(atSeconds: typed), n, "\(rate) fps, frame \(n)")
                XCTAssertEqual(g.time(ofFrame: g.frame(atSeconds: typed)), CMTimeMultiply(d, multiplier: Int32(n)))
            }
        }
    }

    /// N presses chained on the index move exactly N frames, both ways, and stop on the first and last frames
    /// (docs/BUGS.md, "repeated frame-step presses get lost").
    func testChainedPressesMoveExactlyNFramesAndClamp() {
        let d = CMTime(value: 1001, timescale: 60000)
        guard let g = FrameGrid(origin: .zero, frameDuration: d, trackDuration: CMTimeMultiply(d, multiplier: 360),
                                nominalFrameRate: Float(60000.0 / 1001.0)) else { return XCTFail("no grid") }
        for n in [1, 5, 30, 200] {
            var i = 0
            for _ in 0..<n { i = g.frame(steppingFromIndex: i, by: 1) }
            XCTAssertEqual(i, n, "\(n) presses forward")
            for _ in 0..<n { i = g.frame(steppingFromIndex: i, by: -1) }
            XCTAssertEqual(i, 0, "\(n) presses back")
        }
        var i = 357
        for _ in 0..<5 { i = g.frame(steppingFromIndex: i, by: 1) }
        XCTAssertEqual(i, 359, "stops on the last frame")
        i = 2
        for _ in 0..<5 { i = g.frame(steppingFromIndex: i, by: -1) }
        XCTAssertEqual(i, 0, "stops on the first frame")
        XCTAssertEqual(g.frame(steppingFromIndex: 10, by: Int.max), 359)
        XCTAssertEqual(g.frame(steppingFromIndex: 10, by: Int.min), 0)
    }
}
