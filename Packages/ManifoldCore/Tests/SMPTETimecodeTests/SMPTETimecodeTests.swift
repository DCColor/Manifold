import XCTest
@testable import SMPTETimecode

final class SMPTETimecodeTests: XCTestCase {

    /// TimecodeReader.format as it was before the move (2026-11-15), for the "unchanged below 24 hours" check.
    private func legacyFormat(frameCount: Int, nfr: Int, fps: Double, dropFrame: Bool) -> String {
        var fc = frameCount
        if dropFrame {
            let dropFrames = Int((fps * 0.066666).rounded())
            let framesPer10Min = 10 * 60 * nfr - 9 * dropFrames
            let framesPerMin = 60 * nfr - dropFrames
            let d = fc / framesPer10Min
            var m = fc % framesPer10Min
            if m < dropFrames { m = dropFrames }
            fc = fc + dropFrames * 9 * d + dropFrames * ((m - dropFrames) / framesPerMin)
        }
        let ff = fc % nfr, totalSecs = fc / nfr
        return String(format: "%02d:%02d:%02d%@%02d", (totalSecs / 60) / 60, (totalSecs / 60) % 60, totalSecs % 60,
                      dropFrame ? ";" : ":", ff)
    }

    private let rates: [(nfr: Int, fps: Double, df: Bool)] = [
        (24, 24000.0 / 1001, false), (24, 24, false), (25, 25, false), (30, 30000.0 / 1001, true),
        (30, 30000.0 / 1001, false), (60, 60000.0 / 1001, true), (50, 50, false),
    ]

    func testFormatUnchangedBelowTwentyFourHours() {
        for r in rates {
            let day = SMPTETimecode.framesPerDay(nfr: r.nfr, fps: r.fps, dropFrame: r.df)
            for fc in Array(stride(from: 0, to: day, by: 997)) + [0, 1, day - 1] {
                XCTAssertEqual(SMPTETimecode.format(frameCount: fc, nfr: r.nfr, fps: r.fps, dropFrame: r.df),
                               legacyFormat(frameCount: fc, nfr: r.nfr, fps: r.fps, dropFrame: r.df), "\(r) \(fc)")
            }
        }
    }

    func testTwentyFourHourWrap() {
        let r2398 = 24000.0 / 1001
        XCTAssertEqual(SMPTETimecode.format(frameCount: 24 * 86400 - 1, nfr: 24, fps: r2398, dropFrame: false), "23:59:59:23")
        XCTAssertEqual(SMPTETimecode.format(frameCount: 24 * 86400, nfr: 24, fps: r2398, dropFrame: false), "00:00:00:00")
        XCTAssertEqual(SMPTETimecode.format(frameCount: 24 * 86400 + 25, nfr: 24, fps: r2398, dropFrame: false), "00:00:01:01")
        XCTAssertEqual(SMPTETimecode.format(frameCount: -1, nfr: 24, fps: r2398, dropFrame: false), "23:59:59:23")
        let r2997 = 30000.0 / 1001
        let dfDay = SMPTETimecode.framesPerDay(nfr: 30, fps: r2997, dropFrame: true)
        XCTAssertEqual(dfDay, 2_589_408)
        XCTAssertEqual(SMPTETimecode.format(frameCount: dfDay - 1, nfr: 30, fps: r2997, dropFrame: true), "23:59:59;29")
        XCTAssertEqual(SMPTETimecode.format(frameCount: dfDay, nfr: 30, fps: r2997, dropFrame: true), "00:00:00;00")
        XCTAssertEqual(SMPTETimecode.format(frameCount: -1, nfr: 30, fps: r2997, dropFrame: true), "23:59:59;29")
    }

    func testSeparatorOverride() {
        XCTAssertEqual(SMPTETimecode.format(frameCount: 1800, nfr: 30, fps: 30000.0 / 1001, dropFrame: true, separator: ":"),
                       "00:01:00:02")
    }

    func testStrictParseRoundTripsEveryLabelDropFrame() {
        let fps = 30000.0 / 1001
        for fc in 0..<(11 * 60 * 30) {
            let label = SMPTETimecode.format(frameCount: fc, nfr: 30, fps: fps, dropFrame: true)
            XCTAssertEqual(SMPTETimecode.frameCount(label: label, nfr: 30, fps: fps, dropFrame: true), fc, label)
            // Colons, as Resolve writes drop-frame in an EDL.
            XCTAssertEqual(SMPTETimecode.frameCount(label: label.replacingOccurrences(of: ";", with: ":"), nfr: 30, fps: fps,
                                                    dropFrame: true), fc)
        }
    }

    func testStrictParseRefusesLabelsThatAreNotTimes() {
        let fps = 30000.0 / 1001
        XCTAssertNil(SMPTETimecode.frameCount(label: "00:01:00;00", nfr: 30, fps: fps, dropFrame: true))
        XCTAssertNil(SMPTETimecode.frameCount(label: "00:01:00;01", nfr: 30, fps: fps, dropFrame: true))
        XCTAssertEqual(SMPTETimecode.frameCount(label: "00:01:00;02", nfr: 30, fps: fps, dropFrame: true), 1800)
        XCTAssertEqual(SMPTETimecode.frameCount(label: "00:10:00;00", nfr: 30, fps: fps, dropFrame: true), 17982)
        XCTAssertEqual(SMPTETimecode.frameCount(label: "00:01:00:00", nfr: 30, fps: fps, dropFrame: false), 1800)
        XCTAssertNil(SMPTETimecode.frameCount(label: "24:00:00:00", nfr: 24, fps: 24, dropFrame: false))
        XCTAssertNil(SMPTETimecode.frameCount(label: "00:00:00:24", nfr: 24, fps: 24, dropFrame: false))
        XCTAssertNil(SMPTETimecode.frameCount(label: "00:60:00:00", nfr: 24, fps: 24, dropFrame: false))
        XCTAssertNil(SMPTETimecode.frameCount(label: "1:2:3", nfr: 24, fps: 24, dropFrame: false))
        XCTAssertNil(SMPTETimecode.frameCount(label: "aa:00:00:00", nfr: 24, fps: 24, dropFrame: false))
    }

    func testLenientParseMatchesTimecodeReaderSemantics() {
        let fps = 30000.0 / 1001
        // TimecodeEntry relies on this resolving a non-existent DF label to two frames before the minute.
        XCTAssertEqual(SMPTETimecode.lenientFrameCount(timecode: "00:01:00;00", fps: fps)?.frameCount, 1798)
        XCTAssertEqual(SMPTETimecode.lenientFrameCount(timecode: "01:00:00;00", fps: fps)?.frameCount, 107_892)
        XCTAssertEqual(SMPTETimecode.lenientFrameCount(timecode: "01:00:00;00", fps: fps)?.dropFrame, true)
        XCTAssertEqual(SMPTETimecode.lenientFrameCount(timecode: "01:00:00:00", fps: 24000.0 / 1001)?.frameCount, 86_400)
        XCTAssertNil(SMPTETimecode.lenientFrameCount(timecode: "01:00:00", fps: 24))
    }

    func testDurations() {
        XCTAssertEqual(SMPTETimecode.durationLabel(frames: 1, nfr: 24), "00:00:00:01")
        XCTAssertEqual(SMPTETimecode.durationLabel(frames: 48, nfr: 24), "00:00:02:00")
        XCTAssertEqual(SMPTETimecode.durationFrames(label: "00:00:02:00", nfr: 24), 48)
        XCTAssertEqual(SMPTETimecode.durationFrames(label: "60", nfr: 30), 60)
        XCTAssertNil(SMPTETimecode.durationFrames(label: "00:00:00:30", nfr: 30))
    }
}
