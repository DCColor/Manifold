//
//  LiveAudioResampleSpliceTests.swift
//  LiveAudioResampleTests
//
//  Build step 5 of docs/AUDIO_RESAMPLER_DESIGN.md §7: the splice (§2.4), through the real stage,
//  fed as `LiveAudioSink.enqueue` feeds it. Ratio 1.0 throughout, so outside the fade every output
//  sample is an input sample BIT FOR BIT and a misplaced frame cannot hide in rounding.
//
//  Per §9.5's rule, LENGTHS first (frame counts), then samples.
//

import XCTest
import CoreMedia
@testable import LiveAudioResample

final class LiveAudioResampleSpliceTests: XCTestCase {

    typealias T = LiveAudioResampleStageTests
    static let rate = 48_000.0
    static let fade = 480            // 10 ms at 48 kHz
    static let latency = 32

    func stage() -> LiveAudioResampleStage {
        LiveAudioResampleStage(tag: "[TEST-SPLICE]", reportsWindows: false, log: nil)
    }

    func assertContiguous(_ outs: [T.Out], _ what: String, file: StaticString = #filePath,
                          line: UInt = #line) {
        for i in 1..<outs.count {
            XCTAssertEqual(CMTimeCompare(outs[i].pts, outs[i - 1].endTime), 0,
                           "\(what): buffer \(i) does not abut the previous one", file: file, line: line)
        }
    }

    /// Output tick → first-channel... every channel's sample, for ticks in `range`, must be the input
    /// sample at `tick + shift`. Returns the count checked, so a vacuous pass is visible.
    @discardableResult
    func assertCarries(_ outs: [T.Out], ticks range: Range<Int64>, shift: Int64, _ what: String,
                       file: StaticString = #filePath, line: UInt = #line) -> Int {
        var bad = 0, checked = 0
        for o in outs {
            for f in 0..<o.frames {
                let tick = o.pts.value + Int64(f)
                guard range.contains(tick) else { continue }
                for c in 0..<o.channels {
                    if o.pcm[f * o.channels + c] != T.sample(tick: tick + shift, channel: c) { bad += 1 }
                    checked += 1
                }
            }
        }
        XCTAssertEqual(bad, 0, "\(what): \(bad) of \(checked) samples are not input tick + \(shift)",
                       file: file, line: line)
        XCTAssertGreaterThan(checked, 0, "\(what): nothing checked", file: file, line: line)
        return checked
    }

    /// 20 buffers, a splice of `delta` frames, 40 more. The fade starts at content 20·960.
    func run(delta: Int64, bufferFrames n: Int = 960) -> (outs: [T.Out], s: LiveAudioResampleStage,
                                                          grant: LiveAudioResampleStage.SpliceGrant?,
                                                          start: Int64, input: Int64) {
        let fmt = T.makeFormat(rate: Self.rate, channels: 2)
        let s = stage()
        var outs: [T.Out] = []
        let start: Int64 = 96_000
        var tick = start
        for _ in 0..<(20 * 960 / n) {
            outs += s.process(T.makeInput(tick: tick, frames: n, format: fmt)).map(T.read); tick += Int64(n)
        }
        let grant = s.requestSplice(contentSeconds: Double(delta) / Self.rate)
        for _ in 0..<(40 * 960 / n) {
            outs += s.process(T.makeInput(tick: tick, frames: n, format: fmt)).map(T.read); tick += Int64(n)
        }
        return (outs, s, grant, start, tick - start)
    }

    // MARK: - Exact frame counts, both directions

    func testDropAndInsertMoveExactlyTheRequestedFrames() {
        for delta: Int64 in [9_600, -9_600, 2_401, -2_401] {
            let r = run(delta: delta)
            XCTAssertEqual(r.grant?.frames, delta, "granted exactly, \(delta)")
            XCTAssertEqual(r.grant?.crossfadeFrames, Self.fade)
            let out = r.outs.reduce(0) { $0 + Int64($1.frames) }
            // Session primer (+32) and the tail still held (−32) cancel: output = fed = input − delta.
            XCTAssertEqual(out, r.input - delta, "output frames = input − delta, \(delta)")
            let t = r.s.totals
            XCTAssertEqual(t.spliceDrops, delta > 0 ? 1 : 0)
            XCTAssertEqual(t.spliceDropFrames, max(0, delta))
            XCTAssertEqual(t.spliceInserts, delta < 0 ? 1 : 0)
            XCTAssertEqual(t.spliceInsertFrames, max(0, -delta))
            XCTAssertEqual(t.splicesAbandoned, 0)
            XCTAssertEqual(t.clamps, 0)

            // Before the fade: tick k carries input k. After it: input k + delta, bit for bit.
            let fadeStart = r.start + 20 * 960
            assertCarries(r.outs, ticks: r.start..<fadeStart, shift: 0, "before, \(delta)")
            assertCarries(r.outs, ticks: (fadeStart + Int64(Self.fade))..<(r.start + out - 32),
                          shift: delta, "after, \(delta)")
        }
    }

    // MARK: - The output axis stays contiguous

    func testOutputAxisIsContiguousThroughDropAndInsert() {
        for delta: Int64 in [9_600, -9_600] {
            let r = run(delta: delta)
            assertContiguous(r.outs, "splice \(delta)")
            XCTAssertEqual(r.outs.first!.pts.value, r.start - Int64(Self.latency))
        }
    }

    // MARK: - The content-time map reports the splice when it is heard, and not before

    func testContentMapStepsAtTheMarkAndAheadCoversTheGap() {
        let delta: Int64 = 9_600
        let fmt = T.makeFormat(rate: Self.rate, channels: 2)
        let s = stage()
        var tick: Int64 = 96_000
        for _ in 0..<20 { _ = s.process(T.makeInput(tick: tick, frames: 960, format: fmt)); tick += 960 }
        _ = s.requestSplice(contentSeconds: 0.2)
        // Requested, material not arrived: the whole correction is ahead of anything enqueued.
        XCTAssertEqual(s.spliceCorrectionAhead(ofOutputTime: 2.0), 0.2, accuracy: 1e-12)
        for _ in 0..<40 { _ = s.process(T.makeInput(tick: tick, frames: 960, format: fmt)); tick += 960 }

        // The mark: fed frame 20·960 + fade/2, which at ratio 1.0 is output tick start + that.
        let markTick = 96_000 + 20 * 960 + Int64(Self.fade / 2)
        let before = (Double(markTick) - 0.5) / Self.rate
        // A quarter-frame in: exactly ON the tick, tick/rate·rate can round under it, and both the
        // map and `ahead` then (consistently) say "not yet".
        let at = (Double(markTick) + 0.25) / Self.rate
        let after = (Double(markTick) + 100) / Self.rate
        XCTAssertEqual(s.inputTime(atOutputTime: before), before, accuracy: 1e-12, "old content before")
        XCTAssertEqual(s.spliceCorrectionAhead(ofOutputTime: before), 0.2, accuracy: 1e-12)
        XCTAssertEqual(s.inputTime(atOutputTime: at), at + 0.2, accuracy: 1e-12, "new content from the mark")
        XCTAssertEqual(s.spliceCorrectionAhead(ofOutputTime: at), 0, accuracy: 1e-12)
        XCTAssertEqual(s.inputTime(atOutputTime: after), after + 0.2, accuracy: 1e-12)
        // What the loop reads, content + ahead, is continuous across the mark.
        let jump = (s.inputTime(atOutputTime: at) + s.spliceCorrectionAhead(ofOutputTime: at))
            - (s.inputTime(atOutputTime: before) + s.spliceCorrectionAhead(ofOutputTime: before))
        XCTAssertEqual(jump, 0.75 / Self.rate, accuracy: 1e-9, "only the ¾ frame the reads are apart")
        XCTAssertEqual(Double(delta) / Self.rate, 0.2)
        // The inverse map agrees on the far side.
        XCTAssertEqual(s.outputTime(atInputTime: after + 0.2), after, accuracy: 1e-9)
    }

    // MARK: - Equal power

    func testCrossfadeIsEqualPower() {
        let sp = LiveAudioSplicer(channels: 1, crossfade: Self.fade, maximumSplice: 48_000)
        let (o, i) = sp.gains
        XCTAssertEqual(o.count, Self.fade)
        var worst = 0.0
        for k in 0..<Self.fade {
            worst = max(worst, abs(Double(o[k]) * Double(o[k]) + Double(i[k]) * Double(i[k]) - 1))
            if k > 0 { XCTAssertLessThan(o[k], o[k - 1]); XCTAssertGreaterThan(i[k], i[k - 1]) }
        }
        XCTAssertLessThan(worst, 1e-6, "cos² + sin² = 1 at every frame, to Float precision")
        XCTAssertGreaterThan(o[0], 0.9999); XCTAssertLessThan(i[0], 0.002)
        XCTAssertLessThan(o[Self.fade - 1], 0.002); XCTAssertGreaterThan(i[Self.fade - 1], 0.9999)
        XCTAssertEqual(o[Self.fade / 2 - 1], i[Self.fade / 2], accuracy: 1e-6, "symmetric about the middle")
    }

    // MARK: - No discontinuity on a sine

    /// A 1 kHz sine through a drop and an insert whose sizes land the two positions 82° and 36° out
    /// of phase. The largest sample-to-sample step anywhere in the output must stay under the bound
    ///
    ///     1.5 · A · 2πf/fs
    ///
    /// — 1.5× the sine's own largest step. The fade's worst case is √2·A·2πf/fs (both positions at
    /// full weight, in phase) + √2·A·(π/2)/F (the gains' own slope): 0.0926 + 0.0023 = 0.095 at
    /// A = 0.5, under the bound's 0.098. A hard cut at the same points would step by up to 2A; the
    /// test asserts it would have failed, so the bound is not vacuous.
    func testASineThroughASpliceHasNoStepLargerThanTheBound() {
        let a = 0.5, f = 1000.0
        let w = 2 * Double.pi * f / Self.rate
        func sine(_ tick: Int64) -> Int32 { Int32((a * sin(w * Double(tick)) * 2_147_483_648).rounded()) }
        let fmt = T.makeFormat(rate: Self.rate, channels: 1)
        func input(_ tick: Int64, _ n: Int) -> CMSampleBuffer {
            let pcm = (0..<n).map { sine(tick + Int64($0)) }
            return LiveAudioResampleStage.makeSampleBuffer(pcm, frames: n, channels: 1, timescale: 48_000,
                                                           ptsTicks: tick, format: fmt)!
        }
        let s = stage()
        var pcm: [Int32] = []
        var tick: Int64 = 0
        func feed(_ count: Int) {
            for _ in 0..<count { for sb in s.process(input(tick, 960)) { pcm += T.read(sb).pcm }; tick += 960 }
        }
        feed(20)
        let r1 = tick
        _ = s.requestSplice(contentSeconds: 9_611 / Self.rate)        // drop, 11/48 cycle off
        feed(30)
        let r2 = tick
        _ = s.requestSplice(contentSeconds: -4_805 / Self.rate)       // insert, 5/48 cycle off
        feed(30)
        XCTAssertEqual(s.totals.spliceDrops, 1); XCTAssertEqual(s.totals.spliceInserts, 1)

        let bound = 1.5 * a * w
        var worst = 0.0
        for k in (Self.latency + 1)..<pcm.count {
            worst = max(worst, abs(Double(pcm[k]) - Double(pcm[k - 1])) / 2_147_483_648)
        }
        XCTAssertLessThan(worst, bound, String(format: "worst step %.4f against bound %.4f", worst, bound))
        // The hard cut at each point, for scale.
        let cut1 = abs(Double(sine(r1 + 9_611)) - Double(sine(r1 - 1))) / 2_147_483_648
        let cut2 = abs(Double(sine(r2 - 4_805)) - Double(sine(r2 - 1))) / 2_147_483_648
        XCTAssertGreaterThan(max(cut1, cut2), 2 * bound, "the bound would catch a hard cut")
        print(String(format: "[step 5] sine through a drop and an insert: worst step %.4f A-units "
                     + "(bound %.4f, plain sine %.4f, hard cut %.4f / %.4f)",
                     worst, bound, a * w, cut1, cut2))
    }

    // MARK: - Buffer boundaries and back-to-back

    /// 256-frame buffers, so the 480-frame fade has to gather its material across two or three of
    /// them and the fade itself straddles buffer edges on the way out. Two splices requested before
    /// either has run — a 1000-frame drop, then a 700-frame insert that starts where the drop ends.
    func testSplicesAcrossBufferBoundariesAndBackToBack() {
        let fmt = T.makeFormat(rate: Self.rate, channels: 2)
        let s = stage()
        var outs: [T.Out] = []
        var tick: Int64 = 0
        let n = 256
        for _ in 0..<75 { outs += s.process(T.makeInput(tick: tick, frames: n, format: fmt)).map(T.read); tick += Int64(n) }
        let fadeStart = tick
        XCTAssertNotNil(s.requestSplice(contentSeconds: 1_000 / Self.rate))
        XCTAssertNotNil(s.requestSplice(contentSeconds: -700 / Self.rate))
        for _ in 0..<150 { outs += s.process(T.makeInput(tick: tick, frames: n, format: fmt)).map(T.read); tick += Int64(n) }

        let out = outs.reduce(0) { $0 + Int64($1.frames) }
        XCTAssertEqual(out, tick - 300, "input − 1000 + 700")
        let t = s.totals
        XCTAssertEqual(t.spliceDrops, 1); XCTAssertEqual(t.spliceDropFrames, 1_000)
        XCTAssertEqual(t.spliceInserts, 1); XCTAssertEqual(t.spliceInsertFrames, 700)
        XCTAssertEqual(t.splicesAbandoned, 0)
        assertContiguous(outs, "back-to-back across 256-frame buffers")
        // The drop's fade occupies output ticks [fadeStart, +480); the insert starts at the drop's
        // read position and its fade occupies the next 480. After both, tick k carries input k + 300.
        assertCarries(outs, ticks: 0..<fadeStart, shift: 0, "before both")
        assertCarries(outs, ticks: (fadeStart + 2 * Int64(Self.fade))..<(out - 32), shift: 300, "after both")
        XCTAssertEqual(s.spliceCorrectionAhead(ofOutputTime: Double(out) / Self.rate), 0, accuracy: 1e-12)
    }

    /// A splice requested exactly as a buffer ends, whose fade material is exactly the next buffer:
    /// an insert of one buffer, in 480-frame buffers.
    func testASpliceWhoseFadeIsExactlyOneBuffer() {
        let r = run(delta: -480, bufferFrames: 480)
        let out = r.outs.reduce(0) { $0 + Int64($1.frames) }
        XCTAssertEqual(out, r.input + 480)
        assertContiguous(r.outs, "fade = one buffer")
        let fadeStart = r.start + 20 * 960
        assertCarries(r.outs, ticks: (fadeStart + 480)..<(r.start + out - 32), shift: -480, "after")
    }

    // MARK: - The bound, and abandonment

    /// Past `maximumSpliceSeconds` the stage refuses an INSERT, and past `maximumDropSeconds` a DROP
    /// (the coarse branch applies its own 1 s and re-anchors; its own test). At the insert bound it
    /// is granted, and the ring holds enough history for a full-second insert.
    func testTheSpliceBoundIsOneSecond() {
        let s = stage()
        let fmt = T.makeFormat(rate: Self.rate, channels: 2)
        var tick: Int64 = 0
        var outs: [T.Out] = []
        for _ in 0..<100 { outs += s.process(T.makeInput(tick: tick, frames: 960, format: fmt)).map(T.read); tick += 960 }
        XCTAssertNil(s.requestSplice(contentSeconds: -1.0001))
        XCTAssertNil(s.requestSplice(contentSeconds: -1.5))
        XCTAssertNil(s.requestSplice(contentSeconds: LiveAudioResampleStage.maximumDropSeconds + 0.001))
        XCTAssertNil(s.requestSplice(contentSeconds: 0.1 / Self.rate), "under one frame")
        let fadeStart = tick
        XCTAssertEqual(s.requestSplice(contentSeconds: -1.0)?.frames, -48_000)
        for _ in 0..<20 { outs += s.process(T.makeInput(tick: tick, frames: 960, format: fmt)).map(T.read); tick += 960 }
        XCTAssertEqual(s.totals.spliceInserts, 1)
        XCTAssertEqual(s.totals.splicesAbandoned, 0)
        assertCarries(outs, ticks: (fadeStart + 480)..<(tick + 48_000 - 32), shift: -48_000,
                      "a full second replayed from the ring")
    }

    /// A DROP longer than the ring (§18.19's whole-debt cut): its fade-out is kept aside, the skipped
    /// 2.5 s streams through unfed, and the fade-in lands on exactly input + delta. Output = input −
    /// delta, contiguous, bit for bit outside the fade, and the fade itself is cos·x[r0] + sin·x[to].
    func testADropLongerThanTheRingExecutesExactly() {
        let s = stage()
        let fmt = T.makeFormat(rate: Self.rate, channels: 2)
        let start: Int64 = 96_000
        var tick = start
        var outs: [T.Out] = []
        for _ in 0..<20 { outs += s.process(T.makeInput(tick: tick, frames: 960, format: fmt)).map(T.read); tick += 960 }
        let delta: Int64 = 120_000                                  // 2.5 s
        XCTAssertGreaterThan(Double(delta) / Self.rate, LiveAudioResampleStage.maximumSpliceSeconds)
        XCTAssertEqual(s.requestSplice(contentSeconds: 2.5)?.frames, delta)
        for _ in 0..<200 { outs += s.process(T.makeInput(tick: tick, frames: 960, format: fmt)).map(T.read); tick += 960 }
        let t = s.totals
        XCTAssertEqual(t.spliceDrops, 1)
        XCTAssertEqual(t.spliceDropFrames, delta)
        XCTAssertEqual(t.splicesAbandoned, 0)
        let out = outs.reduce(0) { $0 + Int64($1.frames) }
        XCTAssertEqual(out, (tick - start) - delta, "output frames = input − delta")
        assertContiguous(outs, "through a 2.5 s drop")
        let fadeStart = start + 20 * 960
        assertCarries(outs, ticks: start..<fadeStart, shift: 0, "before")
        assertCarries(outs, ticks: (fadeStart + Int64(Self.fade))..<(start + out - 32), shift: delta, "after")
        // The fade: the kept fade-out against the fade-in from the ring.
        var worst = 0.0, checked = 0
        for o in outs {
            for f in 0..<o.frames {
                let k = Int(o.pts.value + Int64(f) - fadeStart)
                guard k >= 0, k < Self.fade else { continue }
                let th = (Double(k) + 0.5) / Double(Self.fade) * Double.pi / 2
                for c in 0..<o.channels {
                    let tk = fadeStart + Int64(k)
                    let want = cos(th) * Double(T.sample(tick: tk, channel: c))
                        + sin(th) * Double(T.sample(tick: tk + delta, channel: c))
                    worst = max(worst, abs(Double(o.pcm[f * o.channels + c]) - want)); checked += 1
                }
            }
        }
        XCTAssertEqual(checked, Self.fade * 2)
        // Float arithmetic on 2^31-scale samples: ≤ a few ulps at 24 bits, i.e. ~10^-6 of full scale.
        XCTAssertLessThan(worst, 2048, "the fade mixes the kept fade-out with the fade-in")
    }

    /// A format change before a drop's material has arrived abandons it: counted, its correction no
    /// longer reported ahead, and the content it held back fed on rather than lost.
    func testAPendingSpliceIsAbandonedByAFormatReset() {
        let s = stage()
        let f2 = T.makeFormat(rate: Self.rate, channels: 2)
        let f6 = T.makeFormat(rate: Self.rate, channels: 6)
        var tick: Int64 = 0
        var outs: [T.Out] = []
        for _ in 0..<10 { outs += s.process(T.makeInput(tick: tick, frames: 960, format: f2)).map(T.read); tick += 960 }
        _ = s.requestSplice(contentSeconds: 0.2)
        outs += s.process(T.makeInput(tick: tick, frames: 960, format: f2)).map(T.read); tick += 960
        XCTAssertEqual(s.spliceCorrectionAhead(ofOutputTime: 0), 0.2, accuracy: 1e-12)
        outs += s.process(T.makeInput(tick: tick, frames: 960, format: f6)).map(T.read); tick += 960
        XCTAssertEqual(s.totals.splicesAbandoned, 1)
        XCTAssertEqual(s.totals.spliceDrops, 0)
        XCTAssertEqual(s.spliceCorrectionAhead(ofOutputTime: 0), 0, "abandoned: nothing ahead")
        assertContiguous(outs, "across the abandon and the reset")
        assertCarries(outs, ticks: 0..<(11 * 960), shift: 0, "the held-back buffer was fed, not lost")
    }
}
