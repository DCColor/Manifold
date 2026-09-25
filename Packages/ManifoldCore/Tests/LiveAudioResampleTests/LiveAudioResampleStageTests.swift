//
//  LiveAudioResampleStageTests.swift
//  LiveAudioResampleTests
//
//  Build step 3 of docs/AUDIO_RESAMPLER_DESIGN.md §7, offline: the output axis the renderer will
//  see, fed exactly as `LiveAudioSink.enqueue` feeds it — one transport-shaped CMSampleBuffer at a
//  time, packed Int32 interleaved, PTS as an integer tick count on the sample rate's timescale.
//
//  ⚠️ WHAT IS UNDER TEST IS THE STAGE, NOT THE SINK, AND THAT IS A LINKING FACT. `LiveAudioSink`
//  lives in ManifoldCore, which a test bundle cannot link (§9). Its whole enqueue is
//  `tap.ingest(sb)`, then `stage.process(sb)`, then the probes and `renderer.enqueue` on each
//  output — so every axis decision the renderer can observe is made in the stage, and the stage
//  is what these tests drive. Session boundaries are modelled the way FrameEngine makes them:
//  `beginLiveAudio` constructs a stage, `endLiveAudio` calls `retire()`.
//
//  Per §9.5's rule, every comparison checks LENGTHS (frame counts, buffer counts) before samples.
//

import XCTest
import CoreMedia
import AudioToolbox
@testable import LiveAudioResample

final class LiveAudioResampleStageTests: XCTestCase {

    // MARK: - Input construction (the transports' shape)

    /// A deterministic, full-range-ish signal that is EXACTLY representable in Float (multiples of
    /// 256 with |v| < 2^31, i.e. 24 significant bits) — what an AAC/Opus/NDI float decode produces
    /// once scaled to Int32. Distinct per channel and per absolute tick, so a misplaced sample
    /// cannot match by accident.
    static func sample(tick: Int64, channel: Int) -> Int32 {
        var x = UInt64(bitPattern: tick) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(channel) &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 31
        let v = Int32(truncatingIfNeeded: Int64(x & 0x00FF_FFFF) - 0x0080_0000)   // 24-bit signed
        return v << 7                                                               // < 2^31
    }

    static func makeFormat(rate: Double, channels: Int, layoutTag: AudioChannelLayoutTag? = nil) -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        var fd: CMAudioFormatDescription?
        if let layoutTag {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = layoutTag
            let st = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd,
                                                    layoutSize: MemoryLayout<AudioChannelLayout>.size,
                                                    layout: &layout, magicCookieSize: 0,
                                                    magicCookie: nil, extensions: nil,
                                                    formatDescriptionOut: &fd)
            precondition(st == noErr)
        } else {
            let st = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0,
                                                    layout: nil, magicCookieSize: 0,
                                                    magicCookie: nil, extensions: nil,
                                                    formatDescriptionOut: &fd)
            precondition(st == noErr)
        }
        return fd!
    }

    /// One input buffer of `frames` frames starting at `tick`, content from `sample(tick:channel:)`.
    static func makeInput(tick: Int64, frames: Int, format: CMAudioFormatDescription) -> CMSampleBuffer {
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee
        let ch = Int(asbd.mChannelsPerFrame)
        var pcm = [Int32](repeating: 0, count: frames * ch)
        for f in 0..<frames { for c in 0..<ch { pcm[f * ch + c] = sample(tick: tick + Int64(f), channel: c) } }
        return LiveAudioResampleStage.makeSampleBuffer(pcm, frames: frames, channels: ch,
                                                       timescale: CMTimeScale(asbd.mSampleRate),
                                                       ptsTicks: tick, format: format)!
    }

    // MARK: - Output inspection

    struct Out {
        let pts: CMTime
        let frames: Int
        let channels: Int
        let rate: Double
        let pcm: [Int32]
        let format: CMFormatDescription
        var endTime: CMTime { CMTimeAdd(pts, CMTime(value: Int64(frames), timescale: pts.timescale)) }
    }

    static func read(_ sb: CMSampleBuffer) -> Out {
        let fd = CMSampleBufferGetFormatDescription(sb)!
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)!.pointee
        let n = CMSampleBufferGetNumSamples(sb)
        let ch = Int(asbd.mChannelsPerFrame)
        var pcm = [Int32](repeating: 0, count: n * ch)
        let block = CMSampleBufferGetDataBuffer(sb)!
        _ = pcm.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * ch * 4, destination: $0.baseAddress!)
        }
        // The buffer's own declared duration must equal its frame count on its own timescale —
        // otherwise "contiguous by PTS arithmetic" would not be what the renderer computes.
        let dur = CMSampleBufferGetDuration(sb)
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        XCTAssertEqual(pts.timescale, CMTimeScale(asbd.mSampleRate), "output PTS must be on the sample-rate timescale")
        XCTAssertEqual(CMTimeCompare(dur, CMTime(value: Int64(n), timescale: pts.timescale)), 0,
                       "declared duration must be exactly the frame count")
        return Out(pts: pts, frames: n, channels: ch, rate: asbd.mSampleRate, pcm: pcm, format: fd)
    }

    /// Every consecutive pair abuts EXACTLY — `CMTimeCompare == 0`, rationals, no tolerance.
    func assertContiguous(_ outs: [Out], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for i in 1..<outs.count {
            let gap = CMTimeSubtract(outs[i].pts, outs[i - 1].endTime)
            XCTAssertEqual(CMTimeCompare(outs[i].pts, outs[i - 1].endTime), 0,
                           "\(what): buffer \(i) starts \(CMTimeGetSeconds(gap) * 1e6) µs off the previous end",
                           file: file, line: line)
        }
    }

    /// Output tick k must carry input sample k (ratio 1.0, group delay compensated), except for
    /// ticks listed in `silent`, which must be zero. Ticks before `firstReal` must be zero too
    /// (the session-start primer).
    func assertSamplesAtOriginalTicks(_ outs: [Out], firstReal: [Int: Int64] = [:],
                                      silent: Range<Int64>? = nil,
                                      file: StaticString = #filePath, line: UInt = #line) {
        var mismatches = 0, checked = 0
        for o in outs {
            let base = o.pts.value
            for f in 0..<o.frames {
                let tick = base + Int64(f)
                for c in 0..<o.channels {
                    let got = o.pcm[f * o.channels + c]
                    let rateKey = Int(o.rate)
                    let expectZero = (firstReal[rateKey].map { tick < $0 } ?? false)
                        || (silent?.contains(tick) ?? false)
                    let want: Int32 = expectZero ? 0 : Self.sample(tick: tick, channel: c)
                    if got != want { mismatches += 1 }
                    checked += 1
                }
            }
        }
        XCTAssertEqual(mismatches, 0, "\(mismatches) of \(checked) output samples are not the input sample at the same tick",
                       file: file, line: line)
    }

    func stage() -> LiveAudioResampleStage {
        LiveAudioResampleStage(tag: "[TEST-RESAMPLE]", reportsWindows: false, log: nil)
    }

    // MARK: - THE REQUESTED TEST: contiguous across a format change and a teardown

    /// Session A: 48 kHz × 2 → 48 kHz × 6 (channel-count change) → 44.1 kHz × 2 (rate change), the
    /// input axis contiguous in SECONDS throughout. Teardown (`retire`). Session B on a fresh
    /// stage, its input carrying straight on from where A's stopped.
    ///
    /// Asserts: every output buffer abuts the previous one EXACTLY across both format changes;
    /// session B's first output abuts session A's last; every sample sits at its original tick;
    /// the format changes cost resets and nothing else; a retired stage emits nothing.
    func testOutputAxisContiguousAcrossFormatChangeAndTeardown() {
        let f48x2 = Self.makeFormat(rate: 48000, channels: 2)
        let f48x6 = Self.makeFormat(rate: 48000, channels: 6)
        let f44x2 = Self.makeFormat(rate: 44100, channels: 2)

        // ── Session A ────────────────────────────────────────────────────────────────────────
        let a = stage()
        var outsA: [Out] = []
        var inFramesA: [Int: Int64] = [48000: 0, 44100: 0]
        // Irregular sizes on purpose — NDI's pulls are 480..530 frames, not a fixed packet.
        let sizes = [960, 480, 517, 1024, 960, 503, 960, 31, 960, 2048]

        // 48k×2 from tick 96000 (t = 2.000 s) — an arbitrary, non-zero absolute start like WHEP's RTP.
        var tick: Int64 = 96_000
        for n in sizes {
            outsA += a.process(Self.makeInput(tick: tick, frames: n, format: f48x2)).map(Self.read)
            tick += Int64(n); inFramesA[48000]! += Int64(n)
        }
        let firstFormatChangeIndex = outsA.count
        // 48k×6 continuing on the same axis: CHANNEL-COUNT change.
        for n in sizes {
            outsA += a.process(Self.makeInput(tick: tick, frames: n, format: f48x6)).map(Self.read)
            tick += Int64(n); inFramesA[48000]! += Int64(n)
        }
        // Pad the 48k axis to a whole second so the rate change lands on an instant BOTH timescales
        // can represent exactly — otherwise "contiguous in seconds" is not a question with a yes.
        let pad = 48_000 - tick % 48_000
        outsA += a.process(Self.makeInput(tick: tick, frames: Int(pad), format: f48x6)).map(Self.read)
        tick += pad; inFramesA[48000]! += pad
        let secondsAtRateChange = tick / 48_000
        // 44.1k×2 from the same instant: RATE change.
        var tick44 = secondsAtRateChange * 44_100
        for n in sizes {
            outsA += a.process(Self.makeInput(tick: tick44, frames: n, format: f44x2)).map(Self.read)
            tick44 += Int64(n); inFramesA[44100]! += Int64(n)
        }
        let totalsA = a.totals

        // ── Teardown ─────────────────────────────────────────────────────────────────────────
        a.retire()
        XCTAssertTrue(a.process(Self.makeInput(tick: tick44, frames: 960, format: f44x2)).isEmpty,
                      "a retired stage must emit nothing — a draining pump cannot reach a flushed renderer")

        // ── Session B: a fresh stage, input continuing from where A's input stopped ─────────────
        let b = stage()
        var outsB: [Out] = []
        let bStart = tick44
        for n in sizes {
            outsB += b.process(Self.makeInput(tick: tick44, frames: n, format: f44x2)).map(Self.read)
            tick44 += Int64(n)
        }

        // LENGTHS FIRST (§9.5).
        let latency = 32
        let outFramesA = outsA.reduce(0) { $0 + $1.frames }
        // Session start adds `latency` frames of primer silence; the two resets each drain the
        // `latency`-frame tail and discard the new primer, net zero; teardown strands one tail.
        // In frames of each rate:
        let outA48 = outsA.filter { $0.rate == 48000 }.reduce(0) { $0 + $1.frames }
        let outA44 = outsA.filter { $0.rate == 44100 }.reduce(0) { $0 + $1.frames }
        XCTAssertEqual(outA48, Int(inFramesA[48000]!) + latency, "48 kHz output = input + session-start primer")
        XCTAssertEqual(outA44, Int(inFramesA[44100]!) - latency, "44.1 kHz output = input − the tail stranded at teardown")
        XCTAssertEqual(outFramesA, outA48 + outA44)
        XCTAssertEqual(totalsA.formatResets, 2)
        XCTAssertEqual(totalsA.axisBreaks, 0)
        XCTAssertEqual(totalsA.fills, 0)
        XCTAssertEqual(totalsA.drops, 0)
        XCTAssertEqual(totalsA.clamps, 0, "ratio 1.0 cannot overshoot: a clamp here is a plumbing defect")
        XCTAssertEqual(totalsA.passthroughs, 0)
        XCTAssertEqual(totalsA.buildFailures, 0)

        // The axis.
        assertContiguous(outsA, "session A, across a channel-count change and a rate change")
        XCTAssertEqual(outsA.first!.pts.value, 96_000 - Int64(latency),
                       "session start anchors at first input − group delay, so sample k lands on tick k")
        let changeBuffer = outsA[firstFormatChangeIndex]
        XCTAssertEqual(changeBuffer.channels, 2, "the drain goes out in the OLD format")
        XCTAssertEqual(changeBuffer.frames, latency, "the drain is exactly the held tail")
        XCTAssertEqual(outsA[firstFormatChangeIndex + 1].channels, 6)
        XCTAssertEqual(outsA.last!.rate, 44100)

        XCTAssertEqual(outsB.first!.pts.value, bStart - Int64(latency))
        XCTAssertEqual(CMTimeCompare(outsB.first!.pts, outsA.last!.endTime), 0,
                       "across a teardown, a new session's output begins exactly where the old one's stopped")
        assertContiguous(outsA + outsB, "sessions A and B end to end")

        // The samples: tick k carries input sample k, bit-exact, on every buffer of both sessions.
        assertSamplesAtOriginalTicks(outsA, firstReal: [48000: 96_000])
        assertSamplesAtOriginalTicks(outsB, firstReal: [44100: bStart])

        print(String(format: "[step 3] contiguous: session A %d buffers (%d @48k, %d @44.1k frames) "
                     + "across 2 format resets, session B %d buffers; 0 gaps, 0 overlaps, all samples "
                     + "at their original tick", outsA.count, outA48, outA44, outsB.count))
    }

    // MARK: - Roles-only relabel must NOT reset (§4.4)

    func testRolesOnlyRelabelDoesNotReset() {
        let plain = Self.makeFormat(rate: 48000, channels: 2)
        let stereo = Self.makeFormat(rate: 48000, channels: 2, layoutTag: kAudioChannelLayoutTag_Stereo)
        let s = stage()
        var outs: [Out] = []
        var tick: Int64 = 480_000
        for i in 0..<20 {
            outs += s.process(Self.makeInput(tick: tick, frames: 960, format: i < 10 ? plain : stereo)).map(Self.read)
            tick += 960
        }
        let t = s.totals
        XCTAssertEqual(t.formatResets, 0, "a relabel is not a format change")
        XCTAssertEqual(outs.count, 20, "one output per input — no drain buffer, so no reset happened")
        assertContiguous(outs, "across a roles-only relabel")
        // No re-priming: a reset would have put 32 zero frames where real samples belong.
        assertSamplesAtOriginalTicks(outs, firstReal: [48000: 480_000])
        // The relabel reaches the renderer: output carries the latest input description.
        XCTAssertNotNil(CMAudioFormatDescriptionGetChannelLayout(outs.last!.format, sizeOut: nil),
                        "the declared layout must be carried onto the output")
    }

    // MARK: - Input discontinuities keep their timing on a contiguous output axis

    /// A lost WHEP packet (a 960-frame hole) and an SRT/NDI-style backward re-pin (a 25 ms overlap).
    func testInputHoleAndOverlapKeepSamplesAtTheirOriginalTicks() {
        let fmt = Self.makeFormat(rate: 48000, channels: 2)
        let s = stage()
        var outs: [Out] = []
        var tick: Int64 = 0
        for _ in 0..<5 { outs += s.process(Self.makeInput(tick: tick, frames: 960, format: fmt)).map(Self.read); tick += 960 }
        let holeStart = tick
        tick += 960                                                         // one packet lost
        for _ in 0..<5 { outs += s.process(Self.makeInput(tick: tick, frames: 960, format: fmt)).map(Self.read); tick += 960 }
        tick -= 1200                                                        // 25 ms backward re-pin
        for _ in 0..<5 { outs += s.process(Self.makeInput(tick: tick, frames: 960, format: fmt)).map(Self.read); tick += 960 }

        let t = s.totals
        XCTAssertEqual(t.fills, 1); XCTAssertEqual(t.fillFrames, 960)
        // 1200 frames of overlap is MORE than one 960-frame packet: the first packet after the re-pin
        // is wholly behind the axis and dropped whole (960), the next is trimmed (240). Two events,
        // 1200 frames — and the expected tick never moved while the first was discarded.
        XCTAssertEqual(t.drops, 2); XCTAssertEqual(t.dropFrames, 1200)
        XCTAssertEqual(t.axisBreaks, 0); XCTAssertEqual(t.formatResets, 0)
        let outFrames = outs.reduce(0) { $0 + $1.frames }
        XCTAssertEqual(outFrames, 15 * 960 + 960 - 1200 + 32 - 32,
                       "input + silence − dropped + session primer − tail still held")
        assertContiguous(outs, "across a hole and an overlap")
        // The overlap re-sends ticks already played; the stage keeps the FIRST copy, so the expected
        // content is the same function of tick either way. The hole must be silence.
        assertSamplesAtOriginalTicks(outs, firstReal: [48000: 0], silent: holeStart..<(holeStart + 960))
    }

    /// Past the bridge limit the input jumped rather than lost a packet: drain, re-anchor, and the
    /// output steps exactly as the input did — the pre-existing behaviour.
    func testAxisBreakReanchorsToTheInput() {
        let fmt = Self.makeFormat(rate: 48000, channels: 2)
        let s = stage()
        var outs: [Out] = []
        var tick: Int64 = 0
        for _ in 0..<5 { outs += s.process(Self.makeInput(tick: tick, frames: 960, format: fmt)).map(Self.read); tick += 960 }
        let beforeBreak = tick
        tick += 5 * 48_000                                                  // 5 s jump
        let afterBreakOuts = s.process(Self.makeInput(tick: tick, frames: 960, format: fmt)).map(Self.read)
        XCTAssertEqual(s.totals.axisBreaks, 1)
        XCTAssertEqual(afterBreakOuts.count, 2, "drain, then the re-anchored buffer")
        XCTAssertEqual(afterBreakOuts[0].pts.value, beforeBreak - 32, "the drain lands at its own ticks")
        XCTAssertEqual(afterBreakOuts[0].frames, 32)
        XCTAssertEqual(afterBreakOuts[1].pts.value, tick, "re-anchored exactly at the new input tick, primer discarded")
        XCTAssertEqual(afterBreakOuts[1].frames, 960 - 32)
        assertSamplesAtOriginalTicks(outs + afterBreakOuts, firstReal: [48000: 0])
    }

    /// Anything that is not the transports' packed Int32 shape is handed through untouched.
    func testUnsupportedFormatPassesThroughUnchanged() {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &fd)
        let pcm = [Int32](repeating: 0, count: 960 * 2)
        let sb = LiveAudioResampleStage.makeSampleBuffer(pcm, frames: 960, channels: 2,
                                                         timescale: 48000, ptsTicks: 0, format: fd!)!
        let s = stage()
        let out = s.process(sb)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0] === sb, "passthrough must hand over the very same buffer")
        XCTAssertEqual(s.totals.passthroughs, 1)
    }
}
