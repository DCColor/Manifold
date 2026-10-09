import XCTest
@testable import DisplayProviders

/// Stage 0b-2's rule (docs/COLOR_MANAGEMENT_FINDINGS.md §6.10): max(default, 1.5 × largest PES +
/// 0.08 s, largest max(pts − dts) + 0.05 s), clamped to 1.0 s, grow-only. The packing figures are the
/// 0b-1 measurements; the reorder figures are 0b-2b's fixtures, measured offline.
final class LiveCushionTests: XCTestCase {

    private let srt = 0.250

    /// One AAC frame per PES (21.3 ms; the sync fixture, OBS's default): the floor stands.
    func testOneFramePerPESLeavesTheDefault() {
        XCTAssertEqual(LiveCushion.seconds(transportDefault: srt, largestPES: 0.0213), srt)
        XCTAssertNil(LiveCushion.raise(current: srt, transportDefault: srt, largestPES: 0.0213))
    }

    /// Programme audio packed ~6 frames (128 ms): 0.272 s, a small raise.
    func testProgrammePackingRaisesSlightly() {
        XCTAssertEqual(LiveCushion.seconds(transportDefault: srt, largestPES: 0.128), 0.272, accuracy: 1e-12)
    }

    /// hi8 / hi25: 8 frames, 170.7 ms → 0.336 s. lo150: max 17 frames, 362.7 ms → 0.624 s.
    func testTheFixturesPredictedFigures() {
        XCTAssertEqual(LiveCushion.seconds(transportDefault: srt, largestPES: 8 * 1024 / 48_000),
                       0.336, accuracy: 1e-12)
        XCTAssertEqual(LiveCushion.seconds(transportDefault: srt, largestPES: 17 * 1024 / 48_000),
                       0.624, accuracy: 1e-12)
    }

    /// The measured floor (cushion − 1.41 × PES on ffmpeg's packing) lands at ~95 ms for hi8 and
    /// stays ≥ ~80 ms wherever the factor governs: the reason for the factor.
    func testTheFloorModelStaysPositive() {
        for frames in 6...29 {
            let pes = Double(frames) * 1024 / 48_000
            let floor = LiveCushion.seconds(transportDefault: srt, largestPES: pes) - 1.41 * pes
            XCTAssertGreaterThan(floor, 0.079, "\(frames) frames")
        }
    }

    /// The break-even: 1.5 × PES + 0.08 = 0.25 at PES 113.3 ms; below it the default stands.
    func testBreakEvenIsTheDefault() {
        XCTAssertNil(LiveCushion.raise(current: srt, transportDefault: srt, largestPES: 0.113))
        XCTAssertNotNil(LiveCushion.raise(current: srt, transportDefault: srt, largestPES: 0.115))
    }

    func testClampedToTheCeiling() {
        XCTAssertEqual(LiveCushion.seconds(transportDefault: srt, largestPES: 2.0), 1.0)
    }

    /// Grow-only: a smaller PES after a larger one never lowers the cushion.
    func testGrowOnly() {
        let raised = LiveCushion.raise(current: srt, transportDefault: srt, largestPES: 0.3627)
        XCTAssertEqual(raised?.seconds ?? 0, 0.62405, accuracy: 1e-12)
        XCTAssertEqual(raised?.reason, .packing(0.3627))
        XCTAssertNil(LiveCushion.raise(current: raised!.seconds, transportDefault: srt, largestPES: 0.1707))
        XCTAssertNil(LiveCushion.raise(current: raised!.seconds, transportDefault: srt, largestPES: 0.3627))
    }

    /// Two readings of one packing a hair apart are not a raise.
    func testSubMillisecondIsNotARaise() {
        XCTAssertNil(LiveCushion.raise(current: 0.336, transportDefault: srt, largestPES: 0.17070))
    }

    func testNonsensePESAsksForTheDefault() {
        for pes in [nil, 0, -0.1, .nan, .infinity] as [Double?] {
            XCTAssertEqual(LiveCushion.seconds(transportDefault: srt, largestPES: pes), srt)
        }
    }

    // MARK: The reorder term (0b-2b)

    /// No B-frames (the sync and soak fixtures) and x264's 25 fps default (hi8: 200 ms, so exactly the
    /// floor) leave the default; a no-pyramid stream (125 ms) too.
    func testShallowReorderLeavesTheDefault() {
        for d in [0, 0.1251, 0.200] {
            XCTAssertNil(LiveCushion.raise(current: srt, transportDefault: srt, largestPES: 0.0213,
                                           largestReorder: d), "\(d)")
        }
    }

    /// The fixtures: b3pyr 208.5 ms → 0.2585, b8pyr 417.1 → 0.4671, b16pyr 750.8 → 0.8008.
    func testTheReorderFixturesPredictedFigures() {
        for (frames, want) in [(5.0, 0.2585), (10.0, 0.4671), (18.0, 0.8008)] {
            let d = frames * 1001 / 24_000
            let r = LiveCushion.raise(current: srt, transportDefault: srt, largestPES: 0.0213, largestReorder: d)
            XCTAssertEqual(r?.seconds ?? 0, want, accuracy: 0.0001, "\(frames) frames")
            XCTAssertEqual(r?.reason, .reorder(d))
        }
    }

    /// hi8: the packing (0.336) beats the reorder (0.250) and is named.
    func testThePackingWinsOnHi8() {
        let w = LiveCushion.wanted(transportDefault: srt, largestPES: 8 * 1024 / 48_000, largestReorder: 0.200)
        XCTAssertEqual(w.seconds, 0.336, accuracy: 1e-12)
        XCTAssertEqual(w.reason, .packing(8 * 1024 / 48_000))
    }

    /// The deeper of the two terms is named, whichever it is.
    func testTheReorderWinsWhenDeeper() {
        let w = LiveCushion.wanted(transportDefault: srt, largestPES: 8 * 1024 / 48_000, largestReorder: 0.4171)
        XCTAssertEqual(w.seconds, 0.4671, accuracy: 1e-12)
        XCTAssertEqual(w.reason, .reorder(0.4171))
    }

    /// A packing raise followed by a deeper reorder raises again; a shallower one does not.
    func testGrowOnlyAcrossTerms() {
        let packed = LiveCushion.raise(current: srt, transportDefault: srt, largestPES: 8 * 1024 / 48_000)!
        XCTAssertNil(LiveCushion.raise(current: packed.seconds, transportDefault: srt,
                                       largestPES: 8 * 1024 / 48_000, largestReorder: 0.2085))
        let deeper = LiveCushion.raise(current: packed.seconds, transportDefault: srt,
                                       largestPES: 8 * 1024 / 48_000, largestReorder: 0.4171)
        XCTAssertEqual(deeper?.seconds ?? 0, 0.4671, accuracy: 1e-12)
    }

    /// 15 fps, 18 frames of reorder (1.2 s): clamped to 1.0 and flagged. 0.95 s is the last reorder
    /// the ceiling covers with its margin.
    func testReorderBeyondTheCeiling() {
        XCTAssertEqual(LiveCushion.seconds(transportDefault: srt, largestPES: nil, largestReorder: 1.2), 1.0)
        XCTAssertTrue(LiveCushion.reorderBeyondCeiling(largestReorder: 1.2))
        XCTAssertTrue(LiveCushion.reorderBeyondCeiling(largestReorder: 0.951))
        XCTAssertFalse(LiveCushion.reorderBeyondCeiling(largestReorder: 0.95))
        XCTAssertFalse(LiveCushion.reorderBeyondCeiling(largestReorder: 0.7508))
        XCTAssertFalse(LiveCushion.reorderBeyondCeiling(largestReorder: nil))
    }

    func testNonsenseReorderAsksForNothing() {
        for d in [nil, 0, -0.1, .nan, .infinity] as [Double?] {
            XCTAssertEqual(LiveCushion.seconds(transportDefault: srt, largestPES: nil, largestReorder: d), srt)
        }
    }

    // MARK: The readout line

    func testReadoutAtTheDefault() {
        let r = LiveCushion.Report(transport: "SRT", cushion: 0.250, transportDefault: 0.250, transportLatencyMs: 120)
        XCTAssertEqual(r.text, "250 ms + SRT 120 ms")
    }

    /// The figures print whole, and the raise is their difference: 336 − 250 = 86.
    func testReadoutRaised() {
        let pes = 8.0 * 1024 / 48_000
        let r = LiveCushion.Report(transport: "SRT",
                                   cushion: LiveCushion.seconds(transportDefault: 0.250, largestPES: pes),
                                   transportDefault: 0.250, transportLatencyMs: 120, raisedBy: .packing(pes))
        XCTAssertEqual(r.text, "336 ms + SRT 120 ms — raised 86 ms: the sender packs 171 ms of audio per packet")
    }

    /// Cloudflare's OBS egress: 5 frames at 23.976 → 0.2585 s, printed 259, raised 9.
    func testReadoutRaisedByTheReorder() {
        let d = 5 * 1001.0 / 24_000
        let r = LiveCushion.Report(transport: "SRT",
                                   cushion: LiveCushion.seconds(transportDefault: 0.250, largestPES: 0.0213,
                                                                largestReorder: d),
                                   transportDefault: 0.250, transportLatencyMs: 120, raisedBy: .reorder(d))
        XCTAssertEqual(r.text, "259 ms + SRT 120 ms — raised 9 ms: the stream reorders 209 ms of pictures")
    }

    /// WHEP has no transport buffer to state and no raise.
    func testReadoutWithoutTransportLatency() {
        XCTAssertEqual(LiveCushion.Report(transport: "WHEP", cushion: 0.400, transportDefault: 0.400).text, "400 ms")
    }

    /// Before the negotiated latency is known the transport term is left out, not printed as 0.
    func testReadoutBeforeTheLatencyIsKnown() {
        XCTAssertEqual(LiveCushion.Report(transport: "SRT", cushion: 0.250, transportDefault: 0.250).text, "250 ms")
    }
}
