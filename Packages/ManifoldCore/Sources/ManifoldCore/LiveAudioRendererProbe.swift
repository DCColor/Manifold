//
//  LiveAudioRendererProbe.swift
//  ManifoldCore
//
//  Observes the desktop audio renderer path for a live push source. READ-ONLY: it records what
//  goes into `AVSampleBufferAudioRenderer` and what the renderer says about itself, and changes
//  nothing about either.
//
//  ── WHY THIS EXISTS, AND WHAT IS ALREADY ELIMINATED ────────────────────────────────────────────
//
//  SRT audio from Cloudflare is distorted and the fault has been walked forward one stage at a
//  time. Each of these is settled; none of them should be re-investigated:
//
//    * THE TRANSPORT — the same stream plays clean in another client.
//    * THE FRAMING — `[SRT-AUDIO-PROBE]` read the packets as received: 7-byte ADTS, `frame_length`
//      matching the packet, `rdblocks = 0`, 1024 frames × 2 ch.
//    * THE DECODE AND THE FLOAT→INT CONVERSION — a WAV captured at the handoff to this sink is
//      CLEAN on Cloudflare: peak, RMS, sample-to-sample continuity and spectrum all match the
//      known-good local capture to within 1 dB below 20 kHz, zero repeated blocks, zero samples at
//      the rails.
//    * THE TIMING OF THE CLOCK — `timebase−clock` holds within 5 ms, frames and PTS agreeing to
//      the sample.
//    * SDI — the distorted 19:05 Cloudflare session had no DeckLink output claimed.
//
//  The samples entering this renderer are correct and what comes out is not. So the question is no
//  longer "are the bytes good" but "what does the renderer do with a correct buffer stream", and
//  the two things it can do that nothing upstream would notice are RESOLVE A DISCONTINUITY and
//  FLUSH ITSELF.
//
//  ── ⚠️ WHY THE GAP IS REPORTED AS A HISTOGRAM AND NEVER AS A MEAN ──────────────────────────────
//
//  A stream that alternates a small hole with a small overlap has a mean gap of approximately
//  zero, and so does a perfectly contiguous one. They are indistinguishable by average and not at
//  all alike: the first makes the renderer resolve a discontinuity ~47 times a second, which is
//  precisely the shape of fault that would sound like gravel while every upstream number reads
//  clean. So the buckets are SIGNED and separated, the sign ALTERNATION count is reported on its
//  own, and no mean is printed anywhere in this file.
//
//  ── COMPILED IN PROFILE, SILENT IN RELEASE ─────────────────────────────────────────────────────
//
//  ⚠️ `#if DEBUG` ALONE WOULD NOT REACH THE BUILD THIS IS FOR. Xcode decides a package target's
//  DEBUG by CONFIGURATION NAME, so only a config literally called "Debug" gets it — this project's
//  Profile does not, and Profile is what every build to date has been cut as. `MANIFOLD_TELEMETRY`
//  is the package's own switch and is defined unconditionally, INCLUDING IN RELEASE (see
//  `Package.swift`). So the compile gate cannot be what keeps this out of a shipping build, and
//  the runtime gate is: `LiveClock.telemetryEnabled` is set only by `ManifoldApp.init` under
//  `#if DEBUG`. Same two-part arrangement, and the same reasoning, as `[LIVECLOCK]` itself.
#if DEBUG || MANIFOLD_TELEMETRY
import AVFoundation
import Foundation

public final class LiveAudioRendererProbe: @unchecked Sendable {

    /// Report cadence. 10 s, matching `mirrorLiveAudio`'s stats line so the three views of the
    /// same session — what the clock published, what the mirror pushed, what the renderer received
    /// — line up in the log at the same boundaries.
    private static let windowSeconds = 10.0

    /// Per-buffer rows are kept in memory and written at the window boundary.
    ///
    /// ⚠️ NOT LOGGED AS THEY ARRIVE, AND THAT IS NOT A LIBERTY WITH THE BRIEF. `enqueue` runs on the
    /// transport's session thread ~47 times a second; an `NSLog` there is a syscall on the exact
    /// path whose timing is under investigation, and 47 of them a second would add jitter to the
    /// thing being measured. Every row still reaches the log, in order, with nothing summarised
    /// away — it is written from a background queue a few milliseconds later. This is the same
    /// discipline `LiveClock` uses (format outside the lock) and the WAV capture uses (buffer in
    /// memory, write at stop), for the same reason.
    private struct Row {
        let index: Int
        let ptsSeconds: Double
        let durationSeconds: Double
        let samples: Int
        let gapSeconds: Double
        let isFirst: Bool
        let cumulativeGapSeconds: Double
    }

    /// A rate set on the synchronizer, with when it happened and who asked.
    private struct RateSet {
        let hostTime: Double
        let rate: Float
        let mediaTime: Double
        let origin: String
    }

    /// Something the renderer said about itself. Real signals only — see `attach`.
    private struct RendererEvent {
        let hostTime: Double
        let text: String
    }

    private let lock = UnfairLock()
    private let tag: String

    private var rows: [Row] = []
    private var rateSets: [RateSet] = []
    private var events: [RendererEvent] = []

    private var bufferIndex = 0
    private var previousEndSeconds: Double?
    private var cumulativeGap = 0.0
    private var windowStartHost: Double?
    private var sampleRate = 0.0

    /// Signed gap buckets, in SAMPLES at the stream's own rate. Sample units rather than seconds
    /// because a one-sample hole is the smallest discontinuity that can exist and "−1 sample" is
    /// an unambiguous reading where "−20.8 µs" invites rounding arguments.
    private struct Histogram {
        var holeOver1000 = 0, hole100to1000 = 0, hole10to100 = 0, hole1to10 = 0, holeUnder1 = 0
        var exactlyZero = 0
        var overlapUnder1 = 0, overlap1to10 = 0, overlap10to100 = 0
        var overlap100to1000 = 0, overlapOver1000 = 0

        var maxHoleSamples = 0.0
        var maxOverlapSamples = 0.0
        /// Consecutive gaps with opposite signs — the alternating case a mean would hide.
        var signAlternations = 0
        var total = 0

        mutating func add(_ samples: Double) {
            total += 1
            let m = abs(samples)
            if samples == 0 { exactlyZero += 1; return }
            if samples > 0 {
                maxHoleSamples = max(maxHoleSamples, samples)
                switch m {
                case ..<1:     holeUnder1 += 1
                case ..<10:    hole1to10 += 1
                case ..<100:   hole10to100 += 1
                case ..<1000:  hole100to1000 += 1
                default:       holeOver1000 += 1
                }
            } else {
                maxOverlapSamples = max(maxOverlapSamples, m)
                switch m {
                case ..<1:     overlapUnder1 += 1
                case ..<10:    overlap1to10 += 1
                case ..<100:   overlap10to100 += 1
                case ..<1000:  overlap100to1000 += 1
                default:       overlapOver1000 += 1
                }
            }
        }
    }
    private var histogram = Histogram()
    private var lastGapSign = 0

    /// Held so the observations can be torn down with the session. KVO and notification tokens
    /// that outlive the renderer would fire against a dead object.
    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private weak var renderer: AVSampleBufferAudioRenderer?

    public init(tag: String) {
        self.tag = tag
    }

    deinit { detach() }

    // MARK: - What the renderer will and will not tell us

    /// ── ⚠️ WHAT IS REAL HERE, AND WHAT IS NOT AVAILABLE ───────────────────────────────────────
    ///
    /// **Observed, and genuinely the renderer's own report:**
    ///
    ///   * `AVSampleBufferAudioRendererWasFlushedAutomatically` — THE ONE WORTH HAVING, and the
    ///     SDK header says why in its own words: *"To the listener, this will sound similar to
    ///     muting the audio for a short period of time."* The renderer discarded what it held, on
    ///     its own initiative, and names the time it flushed to. It leaves no trace anywhere
    ///     upstream — the decode, the conversion and the enqueue all read clean through one — which
    ///     makes it exactly the kind of event this investigation has been walking toward.
    ///   * `outputConfigurationDidChangeNotification` — the output device or its format changed
    ///     under the session.
    ///   * `status` / `error` — `.failed` with a reason, via KVO.
    ///   * `isReadyForMoreMediaData` — KVO'd transitions.
    ///   * `hasSufficientMediaDataForReliablePlaybackStart` — KVO'd transitions.
    ///
    /// **NOT available, and no proxy is invented for it:**
    ///
    ///   ⚠️ `requestMediaDataWhenReady` STARVATION CANNOT BE REPORTED, because this path does not
    ///   use `requestMediaDataWhenReady` AT ALL. `LiveAudioSink.enqueue` pushes unconditionally —
    ///   it consults neither `isReadyForMoreMediaData` nor a callback — and installing a
    ///   media-data request here to measure starvation would TAKE OVER the feed, which is a
    ///   behavioural change and would replace the thing under investigation with a different
    ///   thing. So there is no starvation count in this output. `isReadyForMoreMediaData` is
    ///   logged instead and is a DIFFERENT FACT: it says whether the renderer currently wants
    ///   more, not whether it ran dry waiting. Do not read one as the other.
    ///
    ///   ⚠️ There is also no public accounting of what the renderer did WITH a discontinuity —
    ///   whether it inserted silence, resampled across it or dropped. The gap histogram measures
    ///   what it was ASKED to resolve; the renderer does not say what it chose.
    public func attach(to renderer: AVSampleBufferAudioRenderer) {
        self.renderer = renderer
        let centre = NotificationCenter.default

        notificationTokens.append(centre.addObserver(
            forName: NSNotification.Name.AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: renderer, queue: nil) { [weak self] note in
                let flushTime = (note.userInfo?[AVSampleBufferAudioRendererFlushTimeKey]
                                 as? NSValue)?.timeValue
                self?.record("⚠️ FLUSHED AUTOMATICALLY — the renderer discarded what it held, on "
                           + "its own initiative, flushing to "
                           + (flushTime.map { String(format: "%.6f s", CMTimeGetSeconds($0)) }
                              ?? "an unreported time"))
            })

        notificationTokens.append(centre.addObserver(
            forName: NSNotification.Name.AVSampleBufferAudioRendererOutputConfigurationDidChange,
            object: renderer, queue: nil) { [weak self] _ in
                self?.record("output configuration CHANGED — device or format moved under the session")
            })

        observations.append(renderer.observe(\.status, options: [.new]) { [weak self] r, _ in
            let name: String
            switch r.status {
            case .unknown:   name = "unknown"
            case .rendering: name = "rendering"
            case .failed:    name = "FAILED — \(r.error.map(String.init(describing:)) ?? "no error")"
            @unknown default: name = "unhandled(\(r.status.rawValue))"
            }
            self?.record("status → \(name)")
        })

        observations.append(renderer.observe(\.isReadyForMoreMediaData, options: [.new]) {
            [weak self] r, _ in
            self?.record("isReadyForMoreMediaData → \(r.isReadyForMoreMediaData)")
        })

        observations.append(
            renderer.observe(\.hasSufficientMediaDataForReliablePlaybackStart, options: [.new]) {
                [weak self] r, _ in
                self?.record("hasSufficientMediaDataForReliablePlaybackStart → "
                           + "\(r.hasSufficientMediaDataForReliablePlaybackStart)")
            })

        NSLog("[%@-RENDERER] probe attached — every enqueued buffer's PTS/duration/gap is recorded, "
            + "with a signed gap histogram every %.0f s. Read-only: nothing here changes what is "
            + "enqueued, when, or at what rate.", tag, Self.windowSeconds)
    }

    public func detach() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
        flush(final: true)
    }

    private func record(_ text: String) {
        lock.lock()
        events.append(RendererEvent(hostTime: CACurrentMediaTime(), text: text))
        lock.unlock()
    }

    /// Called from `FrameEngine` wherever the live path sets a rate on the synchronizer.
    public func recordRateSet(rate: Float, mediaTime: Double, origin: String) {
        lock.lock()
        rateSets.append(RateSet(hostTime: CACurrentMediaTime(), rate: rate,
                                mediaTime: mediaTime, origin: origin))
        lock.unlock()
    }

    // MARK: - The buffer stream

    /// ⚠️ SESSION THREAD, AT THE ENQUEUE POINT. Everything here is arithmetic and an append into
    /// reserved capacity — no formatting, no I/O, no allocation in the steady state.
    public func willEnqueue(_ sb: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let dur = CMSampleBufferGetDuration(sb)
        let samples = CMSampleBufferGetNumSamples(sb)
        let ptsSeconds = CMTimeGetSeconds(pts)
        // Duration can be missing on a buffer that carries a per-sample size array; derive it from
        // the sample count in that case rather than treating the gap as unmeasurable.
        var durationSeconds = CMTimeGetSeconds(dur)

        lock.lock()
        if sampleRate == 0, samples > 0, durationSeconds > 0 {
            sampleRate = Double(samples) / durationSeconds
        }
        if !durationSeconds.isFinite || durationSeconds <= 0 {
            durationSeconds = sampleRate > 0 ? Double(samples) / sampleRate : 0
        }
        if windowStartHost == nil {
            windowStartHost = CACurrentMediaTime()
            rows.reserveCapacity(1024)
        }

        let isFirst = previousEndSeconds == nil
        let gap = previousEndSeconds.map { ptsSeconds - $0 } ?? 0
        if !isFirst {
            cumulativeGap += gap
            let gapSamples = sampleRate > 0 ? gap * sampleRate : 0
            histogram.add(gapSamples)
            let sign = gap == 0 ? 0 : (gap > 0 ? 1 : -1)
            if sign != 0 && lastGapSign != 0 && sign != lastGapSign { histogram.signAlternations += 1 }
            if sign != 0 { lastGapSign = sign }
        }
        previousEndSeconds = ptsSeconds + durationSeconds
        bufferIndex += 1

        // ⚠️ `isFirst` rather than a gap of 0 for buffer 1. Zero MEANS contiguous here, and the
        // first buffer of a session has nothing to be contiguous with — printing 0 would put a
        // spurious "perfectly contiguous" row at the head of every log and, worse, at the head of
        // every reconnect.
        rows.append(Row(index: bufferIndex, ptsSeconds: ptsSeconds,
                        durationSeconds: durationSeconds, samples: samples,
                        gapSeconds: gap, isFirst: isFirst,
                        cumulativeGapSeconds: cumulativeGap))

        let due = CACurrentMediaTime() - (windowStartHost ?? 0) >= Self.windowSeconds
        lock.unlock()
        if due { flush(final: false) }
    }

    // MARK: - Reporting

    private func flush(final: Bool) {
        lock.lock()
        guard !rows.isEmpty || !events.isEmpty || !rateSets.isEmpty else { lock.unlock(); return }
        let r = rows, rs = rateSets, ev = events, h = histogram
        let rate = sampleRate
        let cumulative = cumulativeGap
        rows.removeAll(keepingCapacity: true)
        rateSets.removeAll(keepingCapacity: true)
        events.removeAll(keepingCapacity: true)
        histogram = Histogram()
        windowStartHost = CACurrentMediaTime()
        lock.unlock()

        let tag = self.tag
        DispatchQueue.global(qos: .utility).async {
            func µs(_ s: Double) -> Double { s * 1_000_000 }
            func samples(_ s: Double) -> Double { rate > 0 ? s * rate : 0 }

            for row in r {
                if row.isFirst {
                    NSLog("[%@-RENDERER] buf %6d  pts=%.6f  dur=%.6f  n=%4d  gap=(first buffer "
                        + "— no predecessor)", tag, row.index, row.ptsSeconds,
                          row.durationSeconds, row.samples)
                } else {
                    NSLog("[%@-RENDERER] buf %6d  pts=%.6f  dur=%.6f  n=%4d  gap=%+.1f µs "
                        + "(%+.3f samples)  cumulative=%+.3f ms",
                          tag, row.index, row.ptsSeconds, row.durationSeconds, row.samples,
                          µs(row.gapSeconds), samples(row.gapSeconds),
                          row.cumulativeGapSeconds * 1000)
                }
            }

            for set in rs {
                NSLog("[%@-RENDERER] setRate  host=%.6f  rate=%.5f  mediaTime=%.6f  from %@",
                      tag, set.hostTime, set.rate, set.mediaTime, set.origin)
            }
            for e in ev {
                NSLog("[%@-RENDERER] event    host=%.6f  %@", tag, e.hostTime, e.text)
            }

            guard h.total > 0 else {
                if final { NSLog("[%@-RENDERER] window closed with no buffers.", tag) }
                return
            }
            let contiguous = h.exactlyZero
            let holes = h.holeUnder1 + h.hole1to10 + h.hole10to100 + h.hole100to1000 + h.holeOver1000
            let overlaps = h.overlapUnder1 + h.overlap1to10 + h.overlap10to100
                         + h.overlap100to1000 + h.overlapOver1000
            NSLog("""
                  [%@-RENDERER] ══ GAP HISTOGRAM%@ ══ %d gaps over %d buffer(s) @ %.0f Hz
                                gap = this PTS − (previous PTS + previous duration), in SAMPLES
                                  overlap >1000 : %d
                                  overlap 100…1000 : %d
                                  overlap 10…100 : %d
                                  overlap 1…10 : %d
                                  overlap <1 : %d
                                  EXACTLY ZERO (contiguous) : %d
                                  hole <1 : %d
                                  hole 1…10 : %d
                                  hole 10…100 : %d
                                  hole 100…1000 : %d
                                  hole >1000 : %d
                                contiguous %d · holes %d · overlaps %d
                                worst hole %+.3f samples · worst overlap %-.3f samples
                                SIGN ALTERNATIONS: %d  ← consecutive gaps flipping sign
                                cumulative gap this session: %+.3f ms
                                %@
                  """,
                  tag, final ? " (FINAL)" : "", h.total, r.count, rate,
                  h.overlapOver1000, h.overlap100to1000, h.overlap10to100, h.overlap1to10,
                  h.overlapUnder1, h.exactlyZero,
                  h.holeUnder1, h.hole1to10, h.hole10to100, h.hole100to1000, h.holeOver1000,
                  contiguous, holes, overlaps,
                  h.maxHoleSamples, -h.maxOverlapSamples,
                  h.signAlternations, cumulative * 1000,
                  Self.verdict(h))
        }
    }

    /// ⚠️ NAMES THE SHAPE, DOES NOT DIAGNOSE THE CAUSE. Each branch describes what the numbers are,
    /// not what is wrong — the point of this probe is to produce a comparison between two runs, and
    /// a line that guessed at a cause would be the first thing believed and the last thing checked.
    private static func verdict(_ h: Histogram) -> String {
        let nonZero = h.total - h.exactlyZero
        if nonZero == 0 {
            return "Every buffer is exactly contiguous. The renderer is being asked to resolve "
                 + "NOTHING, so a fault here is not discontinuity."
        }
        if h.signAlternations > nonZero / 4 {
            return "⚠️ GAPS ALTERNATE IN SIGN on \(h.signAlternations) of \(nonZero) non-zero gaps "
                 + "— holes and overlaps interleaved. This is the case a MEAN WOULD HIDE, and it "
                 + "means the renderer is resolving a discontinuity repeatedly rather than once."
        }
        if h.exactlyZero > h.total / 2 {
            return "Mostly contiguous with \(nonZero) exception(s) — read the per-buffer rows "
                 + "above at those indices."
        }
        return "Non-contiguous throughout, predominantly "
             + (h.maxHoleSamples > h.maxOverlapSamples ? "HOLES" : "OVERLAPS")
             + " — the renderer is resolving a discontinuity on most buffers."
    }
}
#endif
