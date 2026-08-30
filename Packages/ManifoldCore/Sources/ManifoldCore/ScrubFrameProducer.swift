import AVFoundation
import CoreGraphics

/// One decoded scrub frame, in the app's decode contract (`FrameEngine.videoPixelFormat`, x420).
///
/// `pts` is the SOURCE time of the frame the producer actually delivered, which is **not** the
/// time that was asked for. Both scrub producers seek at infinite tolerance, so the delivered
/// frame is the nearest one the decoder could reach cheaply — 0.5 frames away on all-intra,
/// up to 10.4 on 4K H.264 (measured; docs/BUGS.md). Carrying the real time rather than the
/// requested one is what lets the renderer's DeckLink path key audio to the frame on the wire,
/// and it is the number a future release-seek-to-delivered-frame change would need.
public struct ScrubFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let pts: Double
    public init(pixelBuffer: CVPixelBuffer, pts: Double) {
        self.pixelBuffer = pixelBuffer
        self.pts = pts
    }
}

/// A decoder that can be asked for the frame at an arbitrary media time, out of band from
/// playback, while the transport sits paused.
///
/// ── WHY THIS IS A SEAM AND NOT A CLASS ────────────────────────────────────────────────────────
///
/// The corpus needs two of them and they share nothing but this shape. `AVPlayerItemVideoOutput`
/// on a scrub-only `AVPlayer` covers everything AVFoundation can open (ProRes, H.264, HEVC);
/// **MXF it cannot open at all** — AVFoundation has no MXF demuxer — so that half needs a libav
/// producer with its own `AVFormatContext` and its own serial queue. Their asynchrony is not even
/// the same KIND: AVPlayer is an async seek plus a pull, libav is a synchronous decode on a queue.
/// What they agree on is the destination: a `CVPixelBuffer` in the app's x420 contract, which goes
/// to `MetalVideoRenderer.presentImmediate` and from there through the same shader, the same
/// offscreen, the same scopes and the same SDI convert as a playback frame.
///
/// ⚠️ EVERY IMPLEMENTATION OWES THE GEOMETRY RULE at `presentImmediate`: the decoder's own buffer,
/// at ENCODED geometry — no pixel-aspect applied, no clean-aperture crop. Both planned producers
/// satisfy it by construction (neither `AVPlayerItemVideoOutput` nor libav applies an aperture
/// rule), and the ARRI open-gate ProRes 4444 XQ fixture is the check that says so out loud.
///
/// ── THE CONTRACT ──────────────────────────────────────────────────────────────────────────────
///
/// Everything here is called on the MAIN ACTOR, and `decode` must return to it immediately: the
/// work happens elsewhere and `completion` comes back on main. That is not a stylistic choice —
/// AVPlayer delivers seek completions and item KVO on the main queue, so a producer that blocked
/// main would deadlock against its own decoder (trap 3 in docs/scrub-fixtures/README.md, where it
/// made the whole route look broken).
@MainActor
public protocol ScrubFrameProducer: AnyObject {
    /// False until the decoder can serve a request. The coalescer holds the position rather than
    /// dropping it, and re-pumps when `onReadyChanged` fires — so a grab in the first few hundred
    /// milliseconds after a load is late, never lost.
    var isReady: Bool { get }

    /// Set by the coalescer. Called on main when `isReady` flips true.
    var onReadyChanged: (() -> Void)? { get set }

    /// Decode the frame at `seconds`. Returns immediately. `completion` runs on MAIN exactly once,
    /// with nil if the decoder produced nothing (a seek that landed back on the frame already
    /// delivered, a timeout, or a producer closed mid-flight).
    func decode(at seconds: Double, completion: @escaping (ScrubFrame?) -> Void)

    /// Retire the decoder. Idempotent. Must not block main — see the contract above. Any
    /// completion still in flight either does not fire or fires with nil.
    func close()
}

/// ⚠️ STAGE 1 FLAG. The scrub producer is built and OFF by default: this stage exists so the
/// producer and the `CGImage` overlay can run at the same time and be compared, not to switch
/// over. Stage 2 flips the default for AVFoundation files and deletes the overlay for them.
///
/// Lives in the package rather than the app's `ScrubDebug` because the thing it gates — producer
/// construction — is engine-owned. `ScrubDebug.producerEnabled` mirrors it for the view's half of
/// the instrument, and the two read the same variable.
///
/// `DEBUG || MANIFOLD_TELEMETRY`, not bare `DEBUG`: Xcode maps a package target's configuration by
/// NAME, so only a config literally called "Debug" gets DEBUG here and Profile — the configuration
/// every build to date has been cut in — would not. See the note on `.define("MANIFOLD_TELEMETRY")`
/// in Package.swift.
public enum ScrubProducerFlags {
    #if DEBUG || MANIFOLD_TELEMETRY
    /// `MANIFOLD_SCRUB_PRODUCER=1` — build the producer at load and feed `presentImmediate`.
    public static let enabled = ProcessInfo.processInfo.environment["MANIFOLD_SCRUB_PRODUCER"] == "1"
    /// `MANIFOLD_SCRUB_STATS=1` — per-drag `[SCRUB]` rate and latency summary at release.
    /// Implied by `enabled`, so the common case is one variable.
    public static let stats = enabled
        || ProcessInfo.processInfo.environment["MANIFOLD_SCRUB_STATS"] == "1"
    #else
    public static let enabled = false
    public static let stats = false
    #endif
}

/// The rate policy for scrub requests — **one per seam, not one per producer**, which is the whole
/// argument for it.
///
/// ── WHAT IT REPLACES ──────────────────────────────────────────────────────────────────────────
///
/// Two gates in `ContentView`, neither of which was a rate limit:
///
/// ```
/// guard !previewRequestInFlight else { return }            // in-flight latch — DROPS the position
/// guard abs(time - lastPreviewTime) > 0.05 else { return } // MEDIA-time distance — 1.20 frames
/// ```
///
/// The distance gate is a *media* distance, so a slow drag suppresses requests outright while a
/// fast one makes it irrelevant; between the two, the last frame the user saw was the last request
/// that happened to COMPLETE, sitting ~1.2 frames behind the release point at any speed. That is
/// the staleness the 2026-08-28 position fix was written against, and it is deleted here rather
/// than tuned.
///
/// ── WHAT IT IS ────────────────────────────────────────────────────────────────────────────────
///
///   * the in-flight latch is KEPT — one decode at a time is a real constraint, not a heuristic;
///   * a position arriving mid-decode OVERWRITES a single pending slot instead of being dropped,
///     and is issued the moment the decode completes. Latest wins, and the newest position is
///     always the one in hand;
///   * at most one issue per DISPLAY REFRESH — producing faster than the layer presents is wasted
///     work, and the scopes sample per render anyway.
///
/// ⚠️ THERE IS NO CONSTANT TO TUNE, AND THAT IS THE POINT. The obvious alternative — a wall-clock
/// interval per producer, ~10 ms for AVPlayer and ~25 ms for libav — is two numbers that must stay
/// in agreement with two measured latencies on two codec families on hardware we do not control. A
/// machine slower than the M4 Max moves both; a 6K HEVC file moves one of them by 4×. This is
/// correct on every machine and every codec without being told anything, because **the decoder's
/// own completion is the clock**: the producer self-paces at exactly its own throughput.
@MainActor
public final class ScrubCoalescer {
    private let producer: ScrubFrameProducer
    /// Delivery sink. Called on main with each decoded frame that survives the token check.
    private let deliver: (ScrubFrame) -> Void

    private var pending: Double?
    private var inFlight = false
    private var lastIssueTime: CFTimeInterval = 0
    /// Set when a wake has already been scheduled for the refresh cap, so a burst of slider
    /// callbacks inside one refresh period schedules ONE timer rather than dozens.
    private var wakeScheduled = false

    // ── Display refresh period, DERIVED and not configured ─────────────────────────────────────
    // The cap is "one issue per refresh", so the number has to come from the display rather than
    // from a constant. Cached with a short TTL because `CGDisplayCopyDisplayMode` allocates and a
    // drag asks often, and because a window can move to a 120 Hz panel mid-session.
    private var cachedRefresh: Double = 1.0 / 60.0
    private var cachedRefreshAt: CFTimeInterval = 0

    // ── Stats. `[SCRUB]`, DEBUG/telemetry only; flushed at release by `FrameEngine.exactSeek`. ──
    private var statIssueTimes: [CFTimeInterval] = []
    private var statLatencies: [Double] = []
    private var statSubmits = 0
    private var statCoalesced = 0
    private var statCapped = 0
    private var statEmpty = 0
    private var statSizes: Set<String> = []

    public init(producer: ScrubFrameProducer, deliver: @escaping (ScrubFrame) -> Void) {
        self.producer = producer
        self.deliver = deliver
        producer.onReadyChanged = { [weak self] in self?.pump() }
    }

    /// THE VIEW'S ENTIRE JOB, ARRIVING HERE: a position. No throttle state, no in-flight flag, no
    /// generation stamp — those were view state only because the overlay's `CGImage` was.
    public func submit(_ seconds: Double) {
        statSubmits += 1
        if pending != nil { statCoalesced += 1 }
        pending = seconds
        pump()
    }

    /// Issue the pending position if the latch is clear and the refresh cap allows it. Idempotent
    /// and cheap: every path that could change the answer calls it (a submit, a completion, a
    /// readiness change, the cap's own wake).
    private func pump() {
        guard !inFlight, let target = pending, producer.isReady else { return }

        let now = CACurrentMediaTime()
        let period = refreshPeriod(now)
        let since = now - lastIssueTime
        if since < period {
            // Inside the current refresh. Hold the position — it is the newest one either way —
            // and come back when the refresh is over. Exactly one timer per period.
            statCapped += 1
            guard !wakeScheduled else { return }
            wakeScheduled = true
            let delay = period - since
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.wakeScheduled = false
                self.pump()
            }
            return
        }

        pending = nil
        inFlight = true
        lastIssueTime = now
        statIssueTimes.append(now)

        producer.decode(at: target) { [weak self] frame in
            guard let self else { return }
            self.inFlight = false
            if let frame {
                self.statLatencies.append((CACurrentMediaTime() - now) * 1000)
                self.statSizes.insert("\(CVPixelBufferGetWidth(frame.pixelBuffer))x"
                                    + "\(CVPixelBufferGetHeight(frame.pixelBuffer))")
                self.deliver(frame)
            } else {
                self.statEmpty += 1
            }
            // The decoder's completion IS the clock — servicing the pending slot here is what
            // makes the producer self-pacing.
            self.pump()
        }
    }

    private func refreshPeriod(_ now: CFTimeInterval) -> Double {
        if now - cachedRefreshAt < 1.0 { return cachedRefresh }
        cachedRefreshAt = now
        let rate = CGDisplayCopyDisplayMode(CGMainDisplayID())?.refreshRate ?? 0
        // 0 is what a variable-refresh or virtual display reports. 60 Hz is then the floor of what
        // any panel presents at, so it caps conservatively rather than not at all.
        cachedRefresh = rate > 0 ? 1.0 / rate : 1.0 / 60.0
        return cachedRefresh
    }

    public func close() {
        pending = nil
        producer.onReadyChanged = nil
        producer.close()
    }

    /// One line per drag, printed at release. Reports what was ASKED and what was DELIVERED, so
    /// the coalescer's claim ("self-paces at the producer's own throughput") is a measurement.
    ///
    /// `sizes` is the ARRI open-gate check in its arithmetic form: every delivered buffer's
    /// dimensions, as a set. One entry that equals the encoded raster is a pass; a second entry,
    /// or a single entry smaller than the encoded frame, is the clean-aperture crop coming back —
    /// which on screen would read as a slightly soft preview rather than as a geometry bug.
    public func flushStats(label: String) {
        guard ScrubProducerFlags.stats, !statIssueTimes.isEmpty else { resetStats(); return }
        let lat = statLatencies.sorted()
        func pct(_ p: Double) -> Double {
            guard !lat.isEmpty else { return .nan }
            return lat[min(lat.count - 1, max(0, Int((p * Double(lat.count - 1)).rounded())))]
        }
        let span = (statIssueTimes.last! - statIssueTimes.first!)
        let hz = span > 0 ? Double(statIssueTimes.count - 1) / span : 0
        let mean = lat.isEmpty ? Double.nan : lat.reduce(0, +) / Double(lat.count)
        print(String(format:
            "[SCRUB] %@ submits=%d issued=%d delivered=%d coalesced=%d refresh-capped=%d empty=%d "
            + "| rate=%.1f Hz | seek→deliver mean=%.1f p50=%.1f p90=%.1f max=%.1f ms | sizes=%@",
            label, statSubmits, statIssueTimes.count, lat.count, statCoalesced, statCapped,
            statEmpty, hz, mean, pct(0.5), pct(0.9), lat.last ?? .nan,
            statSizes.sorted().joined(separator: ",")))
        resetStats()
    }

    private func resetStats() {
        statIssueTimes.removeAll(); statLatencies.removeAll()
        statSubmits = 0; statCoalesced = 0; statCapped = 0; statEmpty = 0
        statSizes.removeAll()
    }
}
