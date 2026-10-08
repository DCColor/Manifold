//
//  SRTFrameRouter.swift
//  Manifold
//
//  SRT stage 3d: demuxed access units → decoded pictures → SCREEN.
//
//  ── WHAT IS NEW HERE, AND WHAT IS REUSE ────────────────────────────────────────────────
//
//  Almost nothing is new, and that is the point of the four stages before this one:
//
//    * LiveDisplayRoute   — the renderer save/restore, the LiveClock's four seams, the queue
//                           bound, the flush and the colorimetry. Written for WHEP, moved out
//                           verbatim so this file could use it rather than clone it. What this
//                           file supplies is a Config; it does not reimplement activate/deactivate.
//    * LiveDepthTelemetry — the surplus ledger and the underrun accountant, likewise moved out of
//                           WHEPFrameRouter. `targetDepth` below is a STARTING VALUE to be
//                           measured, exactly as WHEP's 0.400 was, and this is the instrument
//                           that measures it.
//    * LiveVideoDecoder   — used AS-IS. It already takes `pts`/`dts` as CMTime (stage 3b) and is
//                           documented as transport-agnostic; it has no RTP in it. Its WHEP-shaped
//                           NAME and log prefix, deferred out of this stage, have since been fixed:
//                           it is `LiveVideoDecoder` and it logs under `[SRT-DECODE]` here.
//    * the promote        — VTPixelTransferSession into a pooled x420 buffer, the shape NDIService
//                           and WHEPFrameRouter both use to reach the shader's 10-bit domain.
//
//  Genuinely new: reading the stream's declared colorimetry (from its SPS, since §6.9 Stage SPS —
//  see the colorimetry block for why codecpar never had it) instead of assuming it, and measuring
//  the REORDER DELAY — because unlike WHEP, an SRT contribution feed routinely carries B-frames,
//  and the buffer has to be deep enough to hold the reorder window. See `targetDepth`.
//
//  ── THREADING ──────────────────────────────────────────────────────────────────────────
//
//  Two threads, meeting at one lock — WHEPFrameRouter's shape, for the same reason.
//
//    * The SESSION THREAD (`com.manifold.srt.session`, owned by ManifoldSRTSession) does
//      everything downstream of the socket: demux, access-unit assembly, VideoToolbox decode,
//      promote, enqueue. It is ONE thread by construction — the read callback is invoked
//      synchronously from inside av_read_frame — which is exactly the "one thread owns the
//      decoder" rule LiveVideoDecoder requires, satisfied without a queue or a handoff.
//    * `activate` / `deactivate` / `adjustTargetDepth` run on MAIN.
//
//  `stateLock` guards ONLY the (clock, renderer) pair those two exchange, and is never held
//  across `enqueue` — the references are copied out, the lock released, then the work is done.
//
//  BACKPRESSURE IS THE SOCKET. Decoding inline on the session thread means a slow decode stops
//  us draining libsrt's receive buffer, which is the honest place for the pressure to land: SRT's
//  own buffer is sized for it (SRTO_RCVBUF, ~8 MB by default) and it will report the loss if it
//  overflows. A second thread would have moved the queue into our process and hidden it.
//

import CoreMedia
import CoreVideo
import Foundation
import ManifoldCore   // LiveClock
import ColorimetryModel   // SourceColorimetry (buffer tags), SourceColorProvenance
import H264SPSColor       // the decoder's per-SPS colour reading
import DisplayProviders   // LiveCushion — the packing rule and the readout's Buffer row
import QuartzCore
import VideoToolbox

final class SRTFrameRouter {

    static let shared = SRTFrameRouter()
    private init() {}

    /// The display path. Set once at startup (ContentView.onAppear), the SAME instance the file
    /// path, NDI, WHEP and DeckLink use. Weak: ContentView owns it.
    weak var renderer: MetalVideoRenderer?

    /// Called on main just before SRT takes the display, to retire whatever else is driving it
    /// (a loaded file). Set once by ContentView — this type has no engine handle. Identical role
    /// to WHEPFrameRouter.onWillActivateStream and NDIService.onWillActivateStream.
    var onWillActivateStream: (() -> Void)?

    // MARK: - Depth preset
    //
    // 0.250 s — A DECISION, NOT A COPY OF WHEP'S 0.400, AND A STARTING VALUE TO BE MEASURED.
    //
    // ── WHY NOT 0.400 ────────────────────────────────────────────────────────────────────────
    //
    // WHEP's 0.400 is a MEASURED answer to a question SRT asks differently. It was derived from a
    // lateness distribution (p50 0.057, p90 0.121, max 0.162 → cushion ≥ 0.362) whose cause the
    // [WHEP-DRIFT] work identified as NETWORK BURSTINESS arriving raw at the app: WebRTC's own
    // de-jitter buffering lives in the SFU, and what reaches WHEPFrameRouter is whatever the
    // network did to it. There was nothing between the wire and the depth loop.
    //
    // SRT HAS SOMETHING BETWEEN THE WIRE AND US, and it is the whole design of the protocol. The
    // handshake negotiates a receive latency — 120 ms by default on both libsrt and OBS — and
    // TSBPD (time-stamp-based packet delivery) holds every packet until its scheduled delivery
    // instant, using that window to retransmit what was lost and to reorder what arrived out of
    // order. Packets therefore leave libsrt on a SMOOTHED schedule, not the network's. The
    // negotiated value is logged on every connect (`[SRT] CONNECTED in … negotiated rcv latency
    // N ms`) precisely because it is the term this number is chosen against: it is doing the job
    // the larger part of WHEP's 0.400 was paying for.
    //
    // ── WHAT 0.250 STILL HAS TO COVER ───────────────────────────────────────────────────────
    //
    // (1) THE REORDER WINDOW — A HARD REQUIREMENT ON THIS CONFIG, NOT A CUSHION.
    //
    //     VideoToolbox is driven SYNCHRONOUSLY here with no temporal processing, so it emits
    //     pictures in DECODE order; display order is produced downstream by the renderer's
    //     PTS-ordered insert. That insert has a specific failure mode. `performDisplayTick`
    //     selects the NEWEST queued frame with `pts <= now` and REMOVES EVERYTHING UP TO AND
    //     INCLUDING IT as consumed-or-stale. So a B-frame that arrives after the clock has already
    //     swept past its PTS is inserted behind the sweep and silently discarded — a dropped
    //     picture, not a late one.
    //
    //     The arithmetic is exact. A frame arriving with sender PTS P finds the clock at
    //     `now ≈ P − targetDepth`. A frame arriving later with PTS `P − d` (reorder delay d)
    //     becomes eligible only once `now ≥ P − d`, which it already is unless
    //
    //         targetDepth > d = max(pts − dts)
    //
    //     0.250 s is 6 frame intervals at 23.98, 6¼ at 25, 7½ at 30 and 15 at 60 — comfortably
    //     past the 2–3 reorder frames of a typical High-profile pyramid, and past the 4 of a
    //     deep one. But "comfortably" is not a measurement, so `recordReorderDelay` below tracks
    //     max(pts − dts) on EVERY access unit, COUNTS the ones that exceed the live target, and
    //     surfaces a user-facing banner when any do. This is a stated requirement on this config,
    //     checked at runtime in every build configuration, not an assumption hidden under a large
    //     number — and it is REPORTED, never silently corrected: see `recordReorderDelay`.
    //
    // (2) DECODE + PROMOTE JITTER, and whatever residual arrival unevenness survives TSBPD (a
    //     packet lost twice is delivered late or not at all; TSBPD smooths, it does not erase).
    //
    // (3) MARGIN, because this value is a starting point and not a result.
    //
    // ── AND IT IS LOWER END-TO-END, NOT HIGHER ──────────────────────────────────────────────
    //
    // 120 ms (negotiated SRT) + 250 ms (here) ≈ 370 ms of deliberate buffering, against WHEP's
    // 400 ms here PLUS whatever the SFU held. Choosing the smaller local number is only defensible
    // BECAUSE the transport-level number exists and is logged; if a sender ever negotiates a much
    // larger latency, this one should come DOWN, not stay put.
    //
    // ── HOW TO RE-DERIVE IT ─────────────────────────────────────────────────────────────────
    //
    // Exactly as WHEP's was, with the same instrument: ⌃⌥[ / ⌃⌥] (Debug configuration only — not in
    // Profile or Release, decided 2026-10-08) step the live target by ±0.05 s
    // inside one connection, and [SRT-UNDERRUN] / [SRT-JITTER] report the observed lateness
    // distribution and the running-max "cushion needed" the choice must clear. Re-derive, don't
    // guess. That is why LiveDepthTelemetry was moved out of WHEPFrameRouter rather than left
    // there: this path needs the measurement on day one, not later.
    //
    // STARTUP == TARGET, as everywhere else: the initial fill lands ON the setpoint instead of
    // draining to it at ±maxSlew. One constant supplies both (LiveDisplayRoute.Config.targetDepth).
    private static let targetDepth = 0.250

    /// The configured target, for callers that have to reason about it before a clock exists —
    /// SRTClient's connect-time comparison against the negotiated SRT latency, above all. Read-only
    /// and static: the LIVE target, once a stream is running, is `LiveClock.currentTargetDepth`,
    /// which the stepper moves and this does not track.
    static var configuredTargetDepth: Double { targetDepth }

    /// LiveClock's default rail, named here only so the depth accountant can compute its residual
    /// bound (residual is the integrated slew, so |residual| ≤ maxSlew × elapsed). UNCHANGED at
    /// LiveClock's 0.005, and the WHEP diagnosis settles that it stays there: slew is a ppm-scale
    /// trim for crystal drift, and DISCARD is the instrument for backlog.
    private static let maxSlew = 0.005

    /// Warn once the measured reorder delay reaches this fraction of the live target. Below 1.0 on
    /// purpose — a warning that only fires once frames are ALREADY being discarded is a post-mortem,
    /// not a warning.
    private static let reorderWarnFraction = 0.75

    // MARK: - Colorimetry
    //
    // ── READ FROM THE STREAM'S OWN SPS, AND STATED ONCE IT HAS BEEN READ ───────────────────
    //
    // `StreamColorimetry` (App/Live) holds the reading and its three-state honesty: an axis the SPS
    // declares is `declared`; one it leaves absent, unspecified (2) or reserved is undeclared and
    // ASSUMED 709. Undeclared axes reach the renderer as nil (`route(undeclaredAxisCode: nil)`), as
    // they always have on this transport.
    //
    // ⚠️ CORRECTED 2026-10-07 (§6.9, Stage SPS). This block used to say SRT "reaches libavformat,
    // which fills `codecpar->color_primaries` / `color_trc` / `color_space` / `color_range` from the
    // same VUI, so this path CAN state the truth". It could not. libavformat fills those fields only
    // by DECODING, the vendored FFmpeg has the H.264 parser and no decoder, and every SRT stream
    // arrived undeclared on all three axes — a PQ stream was shown and scoped as SDR 709 (docs/BUGS.md,
    // "SRT colour always reads UNDECLARED"). The colour now comes from the SPS the access-unit builder
    // already carries, through `LiveVideoDecoder.onSPSColor`. Range still comes from codecpar, which
    // has the same defect and so reads unspecified → limited; `[SPS-COLOR]` logs the SPS's
    // `video_full_range_flag` beside it and nothing acts on it yet.
    //
    // ⚠️ AND THE OBS FINDING THIS BLOCK USED TO CITE IS SUSPECT FOR THE SAME REASON. The stage-2 spike
    // read every axis of a real OBS→SRT feed as UNSPECIFIED; it read them from codecpar, which this
    // build never fills. What OBS actually declares is measured again in §6.9, Stage SPS.
    //
    // ── WHY THE ROUTE WAITS FOR THE FIRST SPS ──────────────────────────────────────────────
    //
    // The route states its colour at activation. Activating at `onVideoFormat`, as this used to, would
    // state "assumed" and then restate "tagged" a moment later when the first SPS arrived — two source
    // announcements for one connect, and scope headers that describe a guess first. Waiting costs no
    // picture: nothing decodes before an SPS, and audio before the video anchor is dropped anyway. So
    // the first SPS reading is what activates the route (see `noteSPSColor`).
    //
    // ── A LATER SPS THAT CHANGES THE COLOUR ────────────────────────────────────────────────
    //
    // The buffer tags change on the very next frame decoded (this thread). The renderer's half has to
    // change on main, and the frames still queued ahead of it were decoded under the OLD colour —
    // `targetDepth` of them. So the announcement is timed for the presentation of the first new-colour
    // frame (`deliver`), not for its decode: the two halves land together, to within the hop, rather
    // than a quarter-second of old pictures being drawn under the new colour.

    // MARK: - The route's per-source configuration

    private static func routeConfig(colorimetry: StreamColorimetry, cushion: Double) -> LiveDisplayRoute.Config {
        LiveDisplayRoute.Config(
            // The floor, or the packing rule's figure when the stream's first PES arrived before the
            // route did (Stage 0b-2a; see `considerCushion`). Startup and target both, as always.
            targetDepth: cushion,

            // SETTLED, and settled by WHEP's measurement rather than re-argued here: slew is a
            // ppm-scale trim for crystal drift, and a ±0.5% rail drains 0.005 s of buffer per
            // second — eight minutes to absorb a 2.5 s connect backlog. DISCARD is the instrument
            // for backlog (the snap, the queue-full re-anchor, the freeze guard), and every
            // overfill is finite because the sender cannot exceed its own frame rate indefinitely.
            maxSlew: maxSlew,

            // SNAP-TO-LIVE, on. The SRT case for it is stronger than WHEP's, not weaker: an
            // encoder that pauses and resumes leaves a slab of buffered latency, and libsrt's
            // TSBPD will deliver that slab as fast as it can once the link recovers. The ±0.5%
            // slew cannot drain it; a jump can.
            snapEnabled: true,
            // Snaps above ~0.45 s (0.250 target + 0.2 threshold). The threshold is "how far above
            // target is a GROSS overfill the P-loop cannot drain", which scales with the target
            // rather than being an absolute depth — so it is carried over unchanged from WHEP and
            // the trip point moves down with the target, which is the intended behaviour.
            snapThreshold: 0.2,
            snapDebounce: 0.75,      // sustained, not a burst

            // Headroom above the shallow file-path bound (12) so the control loop can correct a
            // filling buffer before drop-oldest fires. 30 frames is ~1.25 s at 24 fps — five times
            // the target, which is the point: the queue bound must never be what limits depth.
            // Scaled with a raised cushion (`queueBound`).
            maxQueued: queueBound(for: cushion),

            colorimetry: colorimetry.route(undeclaredAxisCode: nil))
    }

    /// The renderer's queue bound for a cushion: 30 frames at the 0.250 floor, the same 120 frames per
    /// second of cushion above it. A raised cushion with the bound left at 30 would hit drop-oldest at
    /// high frame rates — 0.513 s at 60p is 31 frames — and every drop is a queue-full re-anchor that
    /// throws away the depth the raise just bought.
    private static func queueBound(for cushion: Double) -> Int {
        max(30, Int((cushion * 120).rounded(.up)))
    }

    // MARK: - Live state (main thread, except where noted)

    private let stateLock = NSLock()
    /// The clock, published to the session thread under `stateLock`. nil = not active, which is how
    /// `deliver` cheaply drops frames that arrive before activate or after deactivate.
    private var liveClock: LiveClock?

    /// The shared live-push display plumbing. Supplied a Config; NOT reimplemented.
    private let route = LiveDisplayRoute()

    /// The surplus ledger + underrun accountant, shared with WHEP. `cushion` is the anchor offset,
    /// which is `targetDepth` at activate() — a runtime step of the live target is accounted for
    /// separately as a signed clock jump.
    private let telemetry = LiveDepthTelemetry(prefix: "SRT",
                                               cushion: SRTFrameRouter.targetDepth,
                                               maxSlew: SRTFrameRouter.maxSlew)

    /// The measured "cushion needed" a future adaptive-depth controller will consume — nil when
    /// telemetry is compiled out, never a plausible measured 0.0.
    var measuredCushionNeeded: Double? { telemetry.measuredCushionNeeded }

    // MARK: - The cushion for this stream's packing (Stage 0b-2a)
    //
    // docs/COLOR_MANAGEMENT_FINDINGS.md §6.10, "Buffer policy — the review and its decisions". The
    // rule is `LiveCushion`'s: max(0.250, 1.5 × largest PES this session + 0.08 s), clamped to 1.0 s,
    // grow-only. The PES figure is `notePacking`'s, which runs on decode — ahead of the pre-anchor
    // audio drop — so on almost every stream the first PES is known before the clock anchors, and the
    // clock simply starts on the raised cushion. A raise after the anchor is a `target-step`: `now()`
    // moves back by the raise (the picture holds that long, once), `onPositionJump` fires, and the
    // audio splice is matched against it.
    //
    // All under `stateLock`: the session thread raises, main activates and publishes.

    /// The cushion the rule asks for this stream. The floor until a PES says otherwise.
    private var cushionWanted = SRTFrameRouter.targetDepth
    /// The largest PES behind `cushionWanted`, seconds; nil while the floor stands.
    private var cushionRaisedForPES: Double?
    /// SRT's negotiated receive latency, for the readout ("+ SRT 120 ms"). nil until connect states it.
    private var transportLatencyMs: Int?

    /// What the stream's SPS declares, for the buffer tags. SESSION THREAD ONLY — written by
    /// `noteSPSColor` (the decoder's `onSPSColor`, before the access unit is decoded) and read by
    /// `deliver` and the promote, all on that thread. No lock, same discipline as `currentSPS` in
    /// the decoder.
    private var colorimetry = StreamColorimetry.undeclared(isFullRange: false, rangeDeclared: false)
    /// Range as codecpar states it, latched at `prepareDecoder`. The SPS does not set it (see the
    /// colorimetry block).
    private var formatRange: (isFullRange: Bool, declared: Bool) = (false, false)
    /// Whether this stream has had an SPS read yet. The FIRST reading activates the route.
    private var haveSPSColor = false
    /// What the renderer has been (or is about to be) told, so `deliver` can see a change. nil until
    /// the first SPS. Session thread only.
    private var announcedColorimetry: LiveDisplayRoute.Colorimetry?
    /// SRTClient's hop to main, carrying its session generation: `first` activates the route, a later
    /// change updates it, after `delay` seconds (the first new-colour frame's presentation).
    private var onStreamColorimetry: ((StreamColorimetry, _ first: Bool, _ delay: Double) -> Void)?

    // MARK: - Decode + promote state (SESSION THREAD only)

    /// The shared VideoToolbox decoder, logging under `[SRT-DECODE]` on this path.
    ///
    /// It used to be `WHEPVideoDecoder` with a hardcoded `[WHEP-DECODE]` prefix, so an SRT
    /// session's log carried WHEP-labelled decode lines — noted here as the one visible wart of
    /// stage 3d and deferred out of it. Since fixed as it was described: the type is
    /// transport-neutral (`LiveVideoDecoder`, in App/Live) and takes its prefix as an init
    /// parameter, so the SRT path's decode lines now sort with its `[SRT-AU]` and `[SRT-FLOW]`
    /// ones instead of against WHEP's.
    private var decoder: LiveVideoDecoder?

    private var transferSession: VTPixelTransferSession?
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int) = (0, 0)
    /// One line the first time a frame is promoted (or found already 10-bit), then silence.
    private var reportedPromote = false

    // MARK: - Reorder measurement (SESSION THREAD)
    //
    // THE NUMBER `targetDepth` IS REQUIRED TO EXCEED. See the depth-preset block for the
    // derivation; this is the instrument that checks it against the actual stream rather than
    // against an assumption about typical encoders.
    //
    // Measured from (pts − dts) on the ACCESS UNIT, which is where both timestamps exist and
    // before anything has been remapped. Not from `codecpar->video_delay`: that is a header claim
    // sourced from the SPS VUI's bitstream_restriction_flag, which a great many real encoders never
    // emit — a 0 there means "not stated", not "no B-frames". The spike established that the header
    // is not to be trusted; this is the empirical answer, continuously.

    /// "No timestamp", spelled in Swift rather than through the C macro.
    /// MANIFOLD_SRT_NO_TIMESTAMP is `#define`d to INT64_MIN — bit-identical to libavformat's
    /// AV_NOPTS_VALUE, which is the whole point of it existing — and function-like/derived C macros
    /// do not reliably survive the Clang importer. Restating it as `Int64.min` is the same value
    /// with no import to depend on; the C header's own test harness is what asserts the equality
    /// against the real <libavutil/avutil.h>.
    private static let noTimestamp = Int64.min

    /// What the reorder measurement has established so far. Read on MAIN (SRTClient's 1 Hz tick,
    /// which turns a non-zero `exceedances` into the connect banner); written on the SESSION
    /// THREAD. Published as one struct under `stateLock` so main can never see a max from one
    /// instant paired with a count from another.
    struct ReorderReport {
        /// Largest (pts − dts) seen this stream, seconds. 0 means no reorder observed at all.
        let maxSeconds: Double
        /// Access units whose (pts − dts) reached or exceeded the ACTIVE target — i.e. pictures the
        /// renderer's PTS-ordered insert placed behind the swept position and discarded. Not a
        /// count of new maxima: every late picture counts, because the user is losing every one.
        let exceedances: Int
        /// The live target the comparison was made against (the ⌃⌥[ / ⌃⌥] stepper moves it).
        let targetSeconds: Double
    }

    /// NOT GATED. This is the evidence behind a user-facing banner and behind the "is targetDepth
    /// big enough for this stream" question, both of which have to work in a shipped build. Only
    /// the `[SRT-AU]` lines that narrate it are diagnostics.
    var reorderReport: ReorderReport {
        stateLock.lock(); defer { stateLock.unlock() }
        return publishedReorder
    }
    private var publishedReorder = ReorderReport(maxSeconds: 0, exceedances: 0,
                                                 targetSeconds: SRTFrameRouter.targetDepth)

    /// Session-thread working copies of the two published numbers. Kept separately so the hot path
    /// updates plain locals and takes `stateLock` once, to publish.
    private var reorderMaxSeconds: Double = 0
    private var reorderExceedances = 0
    /// Latched so the warning is one line per stream, not one per access unit once it trips.
    private var reorderWarned = false
    /// Latched separately: the "within reach" warning fires at most once and must not be re-armed
    /// by the harder EXCEEDED case that follows it.
    private var reorderNearWarned = false
    /// Header claim, kept only to be compared against the measurement.
    private var declaredVideoDelay: Int32 = 0

    // MARK: - Flow telemetry (session thread)

    private var accessUnitsReceived = 0
    private var accessUnitsWithoutPTS = 0
    private var framesDelivered = 0
    private var framesEnqueued = 0
    private var promoteFailures = 0
    private var lastFlowLogHost: CFTimeInterval = 0
    private var lastFlowLogEnqueued = 0
    /// Latest depth sample, written on the render thread and read on the session thread by the 1 Hz
    /// flow log. A benign cross-thread read of telemetry-only scalars — the same concession
    /// WHEPFrameRouter and SyntheticLiveSource both make.
    private var lastDepthSpan: Double = 0
    private var lastDepthCount: Int = 0

    /// Pictures decoded, for SRTClient's media-stall watchdog. Written on the session thread, read
    /// on main from a 1 Hz timer — a monotonic Int, benign to read torn, and the alternative (a
    /// lock on the per-frame path for a watchdog) is the worse trade. `framesEnqueued` is the wrong
    /// signal for that watchdog because it stops advancing when the route is inactive.
    private(set) var picturesDecoded = 0

    // MARK: - Activation (main thread)

    /// Claim the display BEFORE the route can be configured. Called from SRTClient.connect().
    ///
    /// ── WHY THIS EXISTS, AND WHY WHEP HAS NO EQUIVALENT ──────────────────────────────────
    ///
    /// WHEP activates its route inside `connect()`, before the answer is even applied, because
    /// nothing about its Config depends on the stream: it states assumed 709 and corrects itself
    /// when the first SPS arrives. SRT's Config CANNOT be built that early — it carries the stream's
    /// declared colorimetry, which is not knowable until the first SPS has been read, and that is
    /// after `avformat_find_stream_info`: up to 3 s of connect plus up to 5 s of analysis away.
    ///
    /// Leaving the display alone across that window would be wrong twice: the user would keep
    /// watching the OLD source after asking for a new one, and at the moment SRT did take over
    /// there would be a live file pump and an SRT push both feeding `MetalVideoRenderer.enqueue` —
    /// the double-source flashing `LiveSource` exists to prevent.
    ///
    /// So the takeover is split from the configuration: retire now, configure later. `clearToBlack`
    /// makes the intervening seconds honestly black rather than a frozen last frame of something
    /// else, and `activate` below lands on a display that is already ours.
    func beginTakeover() {
        dispatchPrecondition(condition: .onQueue(.main))
        onWillActivateStream?()
        renderer?.clearToBlack()
    }

    /// SRT takes the display. Called from SRTClient once the decoder has read the stream's first
    /// SPS (`noteSPSColor`) — LATER than WHEP's equivalent, and necessarily so: the colorimetry that
    /// goes into the Config is what that SPS declares. Until 2026-10-07 this ran as soon as the
    /// demuxer identified the stream, with colour copied from codecpar, which never held any.
    ///
    /// THERE IS A SHORT WINDOW WHERE ACCESS UNITS ARRIVE AND THIS HAS NOT RUN — the session thread
    /// keeps demuxing across the async hop to main. `deliver` handles it the way WHEP's does: no
    /// clock means the frame is counted and dropped. In practice the window is a few milliseconds
    /// and the decoder is still waiting for its first IDR through all of it, so nothing displayable
    /// is lost. The DECODER, by contrast, is built synchronously on the session thread before this
    /// hop (see prepareDecoder) — it has no such tolerance.
    func activate(format: ManifoldSRTVideoFormat, colorimetry: StreamColorimetry) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let renderer else {
            NSLog("[SRT] no renderer wired — decoded frames will be counted but not displayed")
            return
        }

        stateLock.lock()
        let cushionAtActivate = cushionWanted
        stateLock.unlock()
        let config = Self.routeConfig(colorimetry: colorimetry, cushion: cushionAtActivate)
        let clock = route.activate(
            renderer: renderer,
            config: config,
            // One active source. `beginTakeover()` already did this at connect time, seconds ago —
            // this is the second, idempotent call, and it stays because the retire-then-repoint
            // ordering is LiveDisplayRoute's contract and must not depend on a caller having
            // primed it. `engine.stop()` on a stopped engine is a no-op.
            retireCurrentSource: { self.onWillActivateStream?() },
            // RENDER THREAD, once per display tick. The clock call already happened inside the
            // route; `event` is non-nil only on a coarse action (snap / freeze-guard re-anchor).
            onDepth: { [weak self] sample, event in
                self?.lastDepthSpan = sample.spanSeconds   // telemetry only
                self?.lastDepthCount = sample.count
                self?.telemetry.recordSelection(count: sample.count,
                                                presented: sample.hadEligibleFrame)
                if let event {
                    self?.telemetry.recordClockJump(event.jumped)
                    Self.log(event)
                }
            },
            // SESSION THREAD (renderer.enqueue's caller), after the renderer's queue lock is
            // released.
            onOverflow: { [weak self] event in
                self?.telemetry.recordClockJump(event.jumped)
                Self.log(event)
            })

        // Before the first frame of this stream can arrive. See LiveDepthTelemetry.reset().
        telemetry.reset()
        // The anchor will be built on this cushion, not the configured one, when a PES raised it first.
        if cushionAtActivate != Self.targetDepth { telemetry.setAnchorCushion(cushionAtActivate) }

        // Publishing the clock and re-reading the wanted cushion in one critical section: a raise that
        // landed after `cushionAtActivate` was read found no clock to raise, so it is applied here,
        // still before the anchor (no frame can register before this clock is published).
        stateLock.lock()
        liveClock = clock
        let cushionNow = cushionWanted
        let raisedFor = cushionRaisedForPES
        stateLock.unlock()
        if cushionNow > cushionAtActivate, let pes = raisedFor {
            applyCushion(cushionNow, pes: pes, clock: clock)
        }

        // ⚠️ INSTALLED AT ACTIVATE, NOT WHEN AUDIO STARTS — the same ordering WHEP needs. The
        // mapping's FIRST change is the initial anchor, which `registerFrame` performs on the first
        // presented video frame; that can precede the audio session. Installing here means the
        // first anchor is not missed. The engine side no-ops until a live-audio session is open.
        clock.onMappingChange = { [weak self] mapping in
            self?.mirrorLiveAudio?(mapping, false)
        }
        // ⚠️ AND THE HEARTBEAT, INSTALLED ON THE SAME SEAM. Publication stops while the clock is
        // settled or railed; this fires at the control cadence regardless. On SRT's loop it runs the
        // first-anchor gate's time fallback and the mirror's log cadence — the audio loop itself
        // evaluates per buffer and does not need it (re-derived at resampler step 7 — see
        // `LiveClock.onMappingTick`). Same thread contract, same teardown ordering — see
        // `deactivate`.
        clock.onMappingTick = { [weak self] mapping in
            self?.mirrorLiveAudio?(mapping, true)
        }
        // ⚠️ AND THE FIRST PRESENTATION: the audio's first anchor waits for it (§2.7). SRT has no
        // startup realigns by construction (§10.10), so here the gate costs only the few ms between
        // the first mapping and the first presentation — this transport is its no-regression check.
        clock.onFirstPresentation = { [weak self] mapping in
            self?.liveAudioPresented?(mapping)
        }
        // ⚠️ AND EVERY POSITION JUMP (snap, freeze guard, queue-full, target step), for the audio
        // splice each one causes to be matched against (resampler step 5, §2.4). The clock fires it
        // before publishing the moved mapping, so the event is on record first.
        clock.onPositionJump = { [weak self] jump in
            self?.liveAudioPositionJump?(jump)
        }

        // ── `cushion: 0` — AND IT IS NOT "NO CUSHION" ───────────────────────────────────────
        //
        // ⚠️ READ `FrameEngine.beginLiveAudio`'s parameter note before changing this. Despite the
        // name, this argument is not the live clock's buffer depth. Its only two consumers are
        // `mirrorLiveAudio` (`let target = m.senderPTS - cushion`) and `liveAudioDrift`, and in
        // both its actual meaning is: HOW FAR BEHIND THE MAPPING'S `senderPTS` DOES THIS TRANSPORT
        // STAMP ITS AUDIO PTS?
        //
        // This used to pass `targetDepth`, under a comment saying "the cushion must match the
        // transport whose clock is being mirrored, because it is the steady-state lead the control
        // loop holds for THIS route." That is the reasoning `beginLiveAudio`'s note explicitly
        // retracts, and it was wrong for the audio this file produces: since the sample-counted
        // axis landed, `audioPTSTicks` pins to the program's own absolute `sourcePTS`, so SRT
        // stamps ABSOLUTE SENDER TIME and the offset is zero. WHEP took this identical edit when
        // its receiver moved to the same axis; SRT's call site was never revisited.
        //
        // ⚠️ MEASURED BEFORE THE CHANGE, THREE WAYS AGREEING: desktop audio ran ~200 ms BEHIND the
        // picture — flash-and-beep against a file-playback control read +203.9 ms on local SRT and
        // +165.8 ms on Cloudflare, and the arithmetic `cushion − (timebase−clock)` read +246 ms on
        // both from their own logs. See `docs/AV_SYNC_FINDINGS.md` §3.1.
        //
        // ⚠️ AND `timebase−clock` CANNOT CATCH A REGRESSION OF THIS. `liveAudioDrift` returns
        // `(timebase + cushion) − clock`, so the cushion cancels and the line reads a healthy ±4 ms
        // whichever value is passed. It read +3.8/+4.0 ms across the broken sessions. The instrument
        // for this argument is a device-level A/V measurement, not any number in this log.
        //
        // THE RENDERER'S QUEUE IS NOT WHAT THIS BUYS, and removing it does not starve the renderer:
        // `now()` already runs `targetDepth` behind the sender's live edge, so the renderer still
        // holds ~250 ms of audio — above the ~150 ms floor the NDI lead ladder measured for this
        // same `AVSampleBufferAudioRenderer` (docs/BUGS.md). It was ~500 ms before.
        audioSink = beginLiveAudio?(0)

        NSLog("[SRT] display route ACTIVE — LiveClock target=%.3fs, maxQueued=%d",
              cushionAtActivate, config.maxQueued)
        NSLog("[SRT] colorimetry: %@", colorimetry.summary)
        // The reorder budget, stated at connect so the number the runtime check is measuring
        // against is in the log next to the stream it applies to.
        NSLog("""
              [SRT] reorder budget: targetDepth %.3fs must exceed max(pts − dts). Header claims \
              video_delay=%d (a claim only, often absent) — [SRT-AU] reports the measured value.
              """, cushionAtActivate, format.videoDelay)
        publishBufferReadout()
    }

    /// The stream's SPS colour changed mid-stream. MAIN, from SRTClient, timed for the first
    /// new-colour frame's presentation. The buffer tags already changed on the session thread; this
    /// is the renderer's half (`LiveDisplayRoute.updateColorimetry`).
    func updateColorimetry(_ colorimetry: StreamColorimetry) {
        dispatchPrecondition(condition: .onQueue(.main))
        stateLock.lock(); let active = liveClock != nil; stateLock.unlock()
        guard active else { return }
        route.updateColorimetry(colorimetry.route(undeclaredAxisCode: nil))
        NSLog("[SRT] colorimetry changed mid-stream: %@", colorimetry.summary)
    }

    /// SRT releases the display. Restores the file-path providers verbatim so playback can resume,
    /// and wipes the last streamed frame. Idempotent-safe.
    func deactivate() {
        dispatchPrecondition(condition: .onQueue(.main))
        stateLock.lock()
        let wasActive = liveClock != nil
        // Drop the mapping callback BEFORE releasing the clock: it captures self, and a mapping
        // arriving after teardown would reach a torn-down engine seam.
        liveClock?.onMappingChange = nil
        liveClock?.onMappingTick = nil
        liveClock?.onFirstPresentation = nil
        liveClock?.onPositionJump = nil
        // Clears the clock's per-STREAM state, freeze-guard arming included, so a reconnect
        // re-disarms the guard for its own startup fill rather than tripping it.
        liveClock?.reset()
        liveClock = nil
        stateLock.unlock()
        guard wasActive else { return }

        // Retire the audio session with the clock it was mirroring, not after it.
        audioSink = nil
        endLiveAudio?()

        if let renderer { LiveBufferReadout.publish(nil, renderer: renderer, logPrefix: "SRT") }
        route.deactivate(renderer: renderer)
        // No picture, so no shape. On main, after the route teardown, where a size still hopping in
        // from the session thread cannot overtake it — see LiveDisplaySize's generation counter.
        LiveDisplaySize.shared.clear()
        NSLog("[SRT] display route released — file-playback clock restored")
    }

    // MARK: - Session-thread lifecycle

    /// Build the decoder and wire it to `deliver`. SESSION THREAD, from onVideoFormat — the same
    /// thread that will call `decode`, which is what LiveVideoDecoder's "one thread owns the
    /// session" rule requires.
    ///
    /// `onColorimetry` is called on THIS thread with each change of the stream's SPS colour — the
    /// first one activates the route; see the colorimetry block.
    func prepareDecoder(format: ManifoldSRTVideoFormat,
                        onColorimetry: @escaping (StreamColorimetry, _ first: Bool, _ delay: Double) -> Void) {
        // AVColorRange: 0 unspecified, 1 MPEG/limited, 2 JPEG/full. UNDECLARED ASSUMES LIMITED: H.264
        // with no `video_full_range_flag` IS limited by the standard's own default.
        formatRange = (isFullRange: format.colorRange == 2, declared: format.colorRange != 0)
        colorimetry = .undeclared(isFullRange: formatRange.isFullRange, rangeDeclared: formatRange.declared)
        haveSPSColor = false
        announcedColorimetry = nil
        onStreamColorimetry = onColorimetry
        declaredVideoDelay = format.videoDelay
        reorderMaxSeconds = 0
        reorderExceedances = 0
        reorderWarned = false
        reorderNearWarned = false
        stateLock.lock()
        publishedReorder = ReorderReport(maxSeconds: 0, exceedances: 0,
                                         targetSeconds: Self.targetDepth)
        stateLock.unlock()
        accessUnitsReceived = 0
        accessUnitsWithoutPTS = 0
        picturesDecoded = 0

        // ── STARTUP ANCHOR: ARM THE DEFERRAL FOR THIS STREAM ────────────────────────────────
        // Here rather than in `activate` because this is the session-thread half, it runs before
        // the first access unit by contract, and the deferral state is session-thread-owned.
        startupAnchored = false
        lastArrivalHost = nil
        deferredFrames = 0
        deferralBeganHost = 0
        deferralFirstPTS = 0
        // `guessedFrameRate` is `av_guess_frame_rate`, which is 0 when libavformat could not work
        // one out — common on a short probe. Anything outside a plausible range is treated the same
        // way as absent: an implausible rate is a worse basis for a threshold than a known guess.
        let guessed = format.guessedFrameRate
        anchorRateWasDeclared = guessed.isFinite && Self.anchorPlausibleFrameRates.contains(guessed)
        anchorNominalRate = anchorRateWasDeclared ? guessed : Self.anchorFallbackFrameRate
        anchorGapThreshold = Self.anchorGapFraction / anchorNominalRate

        // ── THE SAME READING, PUBLISHED FOR THE DECKLINK OUTPUT MODE ────────────────────────
        //
        // SRT is the ONE live transport with a declared rate, so it is the one that can drive
        // "Follow source" on the card. This deliberately publishes the DECLARED value or NOTHING —
        // never `anchorNominalRate`, which substitutes a 60 fps fallback when the demuxer had no
        // answer. That substitution is right for the anchor's gap threshold (a threshold wants a
        // number and 60 is the conservative one) and WRONG here: it would reconfigure a broadcast
        // output to 60p for a stream nobody measured, and the operator would have no way to tell
        // that from a real 60p source. Unknown stays unknown and the mode picker takes over.
        publishedFrameRate = anchorRateWasDeclared ? guessed : nil
        if let publishedFrameRate {
            print(String(format: "[SRT-FORMAT] frame rate %.3f fps declared by the demuxer "
                                 + "(av_guess_frame_rate) — DeckLink Follow source can use it",
                         publishedFrameRate))
        } else {
            print("[SRT-FORMAT] frame rate NOT declared "
                + "(av_guess_frame_rate returned \(guessed), outside \(Self.anchorPlausibleFrameRates)) — "
                + "publishing no rate; DeckLink Follow source will be unavailable for this stream")
        }

        let decoder = LiveVideoDecoder(logTag: "SRT-DECODE")
        decoder.onDecodedFrame = { [weak self] pixelBuffer, pts in
            self?.deliver(pixelBuffer, pts: pts)
        }
        // ── NO PLI, AND NOTHING TO PUT IN ITS PLACE ─────────────────────────────────────────
        // WHEP wires this to `session.requestKeyframe()`. SRT has no back-channel: it is a
        // one-way media transport with no RTCP and no picture-loss indication, so there is
        // nobody to ask. Recovery means WAITING OUT THE SENDER'S GOP — ~1 s on OBS defaults
        // (measured from the `[WHEP-RTP]` per-second key-NAL counts; this used to say ~2 s),
        // longer on a 5 s or 10 s keyframe interval. Counted and logged so a freeze has a stated
        // cause and an expected duration, rather than being wired to a no-op that reads as if a
        // request went out.
        decoder.onNeedsKeyframe = { [weak self] in self?.noteKeyframeWait() }
        // Each new SPS's colour, on this thread, before the access unit carrying it is decoded.
        decoder.onSPSColor = { [weak self] sps in self?.noteSPSColor(sps) }
        self.decoder = decoder
    }

    /// A new SPS has been read. SESSION THREAD, from the decoder, before its access unit decodes —
    /// so the frames that follow are tagged with what they were encoded as.
    ///
    /// The FIRST reading activates the route, carrying this colour (see the colorimetry block). A
    /// later reading only changes the tags here; `deliver` announces it to the renderer when the
    /// first frame decoded under it is due.
    private func noteSPSColor(_ sps: H264SPSColor) {
        let next = StreamColorimetry(sps: sps, isFullRange: formatRange.isFullRange,
                                     rangeDeclared: formatRange.declared)
        // Once per change. A repeat of the same SPS never reaches here (the decoder compares bytes);
        // a new SPS saying the same colour stops here.
        guard !haveSPSColor || next != colorimetry else { return }
        colorimetry = next
        NSLog("%@", next.spsColorLine(transport: "SRT"))
        guard !haveSPSColor else { return }
        haveSPSColor = true
        announcedColorimetry = next.route(undeclaredAxisCode: nil)
        onStreamColorimetry?(next, true, 0)
    }

    /// Release everything the session thread owns. SESSION THREAD, from onEnded — the last instant
    /// at which that thread is both alive and guaranteed idle, which is why the C layer fires
    /// onEnded before signalling its join rather than after.
    func releaseSessionResources() {
        // Audio's decode side is single-thread-owned by this same session thread and is retired
        // here for the same reason the video decoder is — this is the one instant at which the
        // owning thread is both alive and guaranteed idle.
        teardownAudio()
        decoder?.invalidate()
        decoder = nil
        haveSPSColor = false
        announcedColorimetry = nil
        onStreamColorimetry = nil
        transferSession = nil
        pixelBufferPool = nil
        poolSize = (0, 0)
        reportedPromote = false
        framesDelivered = 0
        framesEnqueued = 0
        promoteFailures = 0
        // Per-STREAM, like every counter around it. A reconnect must re-run the deferral rather
        // than inherit a `startupAnchored` left true by the session that just ended — which would
        // hand the next stream's first backlog frame straight to `registerFrame`.
        startupAnchored = false
        lastArrivalHost = nil
        deferredFrames = 0
        lastFlowLogHost = 0
        lastFlowLogEnqueued = 0
        telemetry.reset()
        // Per-STREAM, like the packing figures it is computed from: the next stream starts on the
        // floor and raises on its own first PES.
        stateLock.lock()
        cushionWanted = Self.targetDepth
        cushionRaisedForPES = nil
        stateLock.unlock()
    }

    // MARK: - Access units (session thread)

    /// One demuxed access unit → the decoder. Called inline from the C reader's handler, on the
    /// session thread.
    ///
    /// TIMESTAMPS ARE IN THE STREAM'S OWN TIME BASE, WHICH FOR MPEG-TS IS 1/90000 NATIVELY AND
    /// ALWAYS, and they are deliberately NOT rescaled — see the note in SRTAccessUnitReader.h. The
    /// demuxer has already unwrapped MPEG-TS's 33-bit PTS field into a monotonic int64, so these
    /// are usable directly; CMTime(value:timescale: 90_000) is exact on both transports.
    func handleAccessUnit(_ accessUnit: ManifoldSRTAccessUnit) {
        accessUnitsReceived += 1
        guard let decoder else { return }

        // ── AN ACCESS UNIT WITH NO PTS CANNOT BE SCHEDULED ─────────────────────────────────
        // The reader emits it rather than swallowing it, with a counter, and explicitly leaves
        // the decision here (SRTAccessUnitReader.c, AV_NOPTS_VALUE POLICY). This is the decision:
        // DROP IT. LiveClock anchors and paces on the sender's PTS, and a picture with no
        // presentation time has nothing to be placed against — decoding it would produce a buffer
        // the renderer's PTS-ordered insert could only put at an invented position. Counted, and
        // reported in [SRT-FLOW], so "the picture is missing frames" has evidence rather than a
        // shrug. In practice this is vanishingly rare: MPEG-TS PES forbids a DTS without a PTS,
        // so the reader's DTS-stands-in rule already covers the only case that can legitimately
        // arise.
        guard accessUnit.pts != Self.noTimestamp else {
            accessUnitsWithoutPTS += 1
            return
        }

        let hasDTS = accessUnit.dts != Self.noTimestamp
        if hasDTS {
            // THE REORDER MEASUREMENT, ON EVERY ACCESS UNIT — not only when a new maximum appears.
            // The count has to be a count of LATE PICTURES, because that is what the user loses;
            // counting new maxima would report "1" for a stream dropping a B-frame every GOP.
            // Negative (pts < dts) is impossible in a well-formed stream and is ignored rather than
            // folded into a max.
            let delta = Double(accessUnit.pts - accessUnit.dts) / 90_000.0
            if delta > 0 { recordReorderDelay(delta) }
        }

        let pts = CMTime(value: accessUnit.pts, timescale: 90_000)
        // `.invalid` when the stream carries no DTS, which CoreMedia reads as "decode order ==
        // presentation order" — the same assertion WHEP makes on every frame, and the honest one
        // for a stream that declares no reordering.
        let dts = hasDTS ? CMTime(value: accessUnit.dts, timescale: 90_000) : CMTime.invalid

        let data = Data(bytes: accessUnit.data, count: accessUnit.size)
        let sps = accessUnit.sps.map { Data(bytes: $0, count: accessUnit.spsSize) }
        let pps = accessUnit.pps.map { Data(bytes: $0, count: accessUnit.ppsSize) }

        decoder.decode(accessUnit: data,
                       sps: sps,
                       pps: pps,
                       parameterSetsChanged: accessUnit.parameterSetsChanged,
                       keyframe: accessUnit.keyframe,
                       pts: pts,
                       dts: dts)
    }

    /// The runtime half of the reorder requirement, run per access unit on the session thread.
    ///
    /// COUNTS AND MEASURES UNCONDITIONALLY; ONLY THE NARRATION IS GATED. `reorderExceedances` and
    /// `reorderMaxSeconds` are what SRTClient turns into a user-facing banner, so they cannot live
    /// behind `#if DEBUG || MANIFOLD_TELEMETRY` — a Release user is exactly the person who needs to
    /// be told the buffer is too shallow for their stream.
    ///
    /// IT DOES NOT TOUCH THE DEPTH — YET. The cushion follows the audio packing from Stage 0b-2a
    /// (`considerCushion`); following this measurement is Stage 0b-2b's reorder term (decided
    /// 2026-10-08, docs/COLOR_MANAGEMENT_FINDINGS.md §6.10), which will size it from max(pts − dts)
    /// with a margin rather than from one access unit. Until then it is reported, and nothing in a
    /// tester or Release build can raise it: ⌃⌥] exists only in the Debug configuration.
    ///
    /// Reads the LIVE target (the stepper moves it), not the configured constant, because the
    /// requirement is against whatever the clock is actually holding right now.
    private func recordReorderDelay(_ delta: Double) {
        // COPY THE CLOCK OUT AND RELEASE BEFORE ASKING IT. `currentTargetDepth` takes LiveClock's
        // own lock, and holding `stateLock` across it would nest two locks on the hot path — the
        // discipline `deliver` already follows and the reason it copies its references out.
        stateLock.lock()
        let clock = liveClock
        stateLock.unlock()
        let target = clock?.currentTargetDepth ?? Self.targetDepth

        let isNewMax = delta > reorderMaxSeconds
        if isNewMax { reorderMaxSeconds = delta }
        let exceeded = delta >= target
        if exceeded { reorderExceedances += 1 }

        stateLock.lock()
        publishedReorder = ReorderReport(maxSeconds: reorderMaxSeconds,
                                         exceedances: reorderExceedances,
                                         targetSeconds: target)
        stateLock.unlock()

        #if DEBUG || MANIFOLD_TELEMETRY
        if exceeded {
            // Already losing pictures: a frame arriving this late lands behind the renderer's
            // swept position and is discarded by the selection loop, not merely shown late.
            // Latched to one line per stream — the banner and the [SRT-FLOW] counters carry the
            // ongoing story, and one line per dropped B-frame would bury them.
            if !reorderWarned {
                reorderWarned = true
                NSLog("""
                      [SRT-AU] ⚠️ REORDER DELAY %.3fs REACHES targetDepth %.3fs — B-frames are \
                      landing behind the renderer's swept position and being DISCARDED. The \
                      requirement is targetDepth > max(pts − dts); the cushion does not follow the \
                      reorder delay yet (Stage 0b-2b). Header claimed video_delay=%d.
                      """, delta, target, declaredVideoDelay)
            }
        } else if isNewMax, !reorderNearWarned, delta >= target * Self.reorderWarnFraction {
            reorderNearWarned = true
            NSLog("""
                  [SRT-AU] reorder delay %.3fs is within %.0f%% of targetDepth %.3fs — the margin \
                  protecting the PTS-ordered insert is thin. Header claimed video_delay=%d.
                  """, delta, Self.reorderWarnFraction * 100, target, declaredVideoDelay)
        }
        #endif
    }

    /// The decoder asked for a keyframe it cannot get. SESSION THREAD.
    ///
    /// Fires on three occasions: no format description yet (the first access units of a mid-GOP
    /// join, which is normal), the startup keyframe gate still closed, and — the one that matters
    /// — a mid-stream decode failure that re-armed that gate. The gate means this is about once
    /// per freeze, not once per frame.
    private func noteKeyframeWait() {
        // Throttled to the flow log's cadence so a startup join does not print per access unit.
        // Deliberately NOT silent: on this transport a decode error means the picture freezes for
        // up to one sender GOP with nothing we can do to shorten it, and that has to be a stated
        // event in the log rather than an unexplained gap.
        let now = CACurrentMediaTime()
        guard now - lastKeyframeWaitLog >= 1.0 else { return }
        lastKeyframeWaitLog = now
        NSLog("""
              [SRT-AU] waiting for an IDR — SRT has no back-channel, so there is no PLI to send. \
              The picture holds until the sender's next keyframe (≈1s on OBS defaults, longer on a \
              5s or 10s interval).
              """)
    }
    private var lastKeyframeWaitLog: CFTimeInterval = 0

    // MARK: - Startup anchor (session thread)
    //
    // ── WHY THE FIRST FRAME IS THE WRONG ONE TO ANCHOR TO ON THIS TRANSPORT ─────────────────
    //
    // `LiveClock.registerFrame` anchors on the first PTS it is handed, and on every other source
    // that is right, because the first frame to arrive IS live. Not here. `avformat_find_stream_info`
    // spends up to ~2.5 s identifying the stream, buffering everything that arrives meanwhile, and
    // hands the whole backlog over the instant it returns. The first frame the decoder produces is
    // therefore the OLDEST frame of that backlog, and anchoring to it starts the clock ~2.4 s behind
    // live.
    //
    // The system already recovered from that — via the queue-full re-anchor (seven times), then the
    // debounced snap. Every one of those computes the same correction, `newest − targetDepth`. So
    // the clock knew where live was; nothing asked it at anchor time. THIS IS NOT A NEW MECHANISM.
    // It is that same answer, taken once and deliberately, before the first present rather than
    // after seven visible jumps.
    //
    // ── WHAT "NEWEST" MEANS WHEN YOU CAN ONLY SEE ONE FRAME AT A TIME ───────────────────────
    //
    // `deliver` has no lookahead — one frame, then the next. So "the newest frame" is not a
    // quantity that can be read at frame one; it can only be recognised AFTERWARDS, by how the
    // frames arrive:
    //
    //   * BACKLOG frames arrive DECODE-BOUND — back to back, a millisecond or two apart, because
    //     the bytes are already in libavformat's buffer;
    //   * LIVE frames arrive NETWORK-BOUND — one frame interval apart, because the demuxer is
    //     blocked on the wire waiting for them.
    //
    // So the newest frame is THE FIRST ONE WE HAD TO WAIT FOR, and the test is the inter-arrival
    // gap. Until that test passes the anchor is withheld: frames are still decoded (they are
    // reference frames, and the ones after them need them) and still enqueued, but `LiveClock` stays
    // unanchored, `now()` returns -.infinity, and nothing reaches the screen.
    //
    // ── WHY THE ROUTER KEEPS NO "IS IT ANCHORED" STATE OF ITS OWN BEYOND THIS ───────────────
    //
    // `registerFrame` is idempotent after the first call — it only assigns when `anchorSenderPTS`
    // is nil. So the rule is simply: WITHHOLD THE FIRST CALL until the gap test passes, then call it
    // unconditionally forever. `startupAnchored` exists only to skip this block's arithmetic on the
    // hot path, not to duplicate the clock's state.

    /// A gap this fraction of a frame interval or longer means the frame was WAITED for.
    /// Half an interval separates decode-bound (~1 ms) from network-bound (~42 ms at 24 fps) by
    /// more than an order of magnitude, so the exact fraction is not delicate.
    private static let anchorGapFraction = 0.5

    /// ── THE CAPS, AND WHY THERE ARE TWO ─────────────────────────────────────────────────────
    /// The gap test rests on a NOMINAL frame interval that the sender is not obliged to honour. If
    /// the real cadence is faster than declared, every live gap looks like a burst and the deferral
    /// would never end on its own. Both caps end it: elapsed time bounds the black, frame count
    /// bounds it for a sender fast enough to make the time cap slow in frame terms. Hitting either
    /// degrades to EXACTLY today's behaviour — anchor on the frame in hand — and says so distinctly
    /// in the log, because "the cap fired" and "a gap was found" are different facts about the
    /// stream and must never read the same.
    private static let anchorDeferralMaxSeconds: CFTimeInterval = 0.5
    private static let anchorDeferralMaxFrames = 300

    /// Used when the demuxer's `guessedFrameRate` is absent or implausible. 60 fps is chosen as the
    /// SAFE end: it makes the threshold small (8.3 ms), so a real live stream at any rate up to
    /// 60 fps still clears it on its first inter-frame gap and anchors immediately — the assumption
    /// degrades toward today's behaviour rather than toward indefinite deferral.
    private static let anchorFallbackFrameRate = 60.0
    private static let anchorPlausibleFrameRates = 1.0...240.0

    private var startupAnchored = false
    /// Half a nominal frame interval, in seconds. Set in `prepareDecoder`.
    private var anchorGapThreshold: Double = 0.5 / anchorFallbackFrameRate
    private var anchorRateWasDeclared = false
    private var anchorNominalRate: Double = anchorFallbackFrameRate
    /// The rate handed to `LiveDisplaySize` for the DeckLink output mode: the DECLARED value, or nil.
    /// ⚠️ NOT `anchorNominalRate` — see where this is set. Session thread, like every anchor field.
    private var publishedFrameRate: Double?
    /// Host time of the previous DELIVERED frame, or nil when none has been delivered yet.
    private var lastArrivalHost: CFTimeInterval?
    private var deferralBeganHost: CFTimeInterval = 0
    private var deferralFirstPTS: Double = 0
    private var deferredFrames = 0

    /// Called from `deliver` for every frame until the anchor is taken. Returns the presentation PTS.
    ///
    /// SESSION THREAD, and every field it touches is session-thread-owned — the same ownership
    /// `framesDelivered` and the promote state already have.
    // ══════════════════════════════════════════════════════════════════════════════════════════
    // MARK: - Audio (STAGE 1: tap only — no renderer, no clock, no sync)
    // ══════════════════════════════════════════════════════════════════════════════════════════
    //
    // ⚠️ THIS STAGE FEEDS THE TAP AND NOTHING ELSE, AND THAT IS THE WHOLE POINT. The analogue is
    // NDI, not WHEP: NDI "feeds the tap alone (metered and SDI-capable, but silent on the
    // desktop)". Nothing here touches `AVSampleBufferAudioRenderer`, `beginLiveAudio`, LiveClock
    // or the synchronizer — so nothing is audible, and a PASS is the meters moving.
    //
    // ── STAGE 2: AUDIBLE ON THE LIVE CLOCK ────────────────────────────────────────────────────
    //
    // The seams below are the WHEP ones, wired identically in `WindowDeck`. Audio no longer goes to
    // the tap directly; it goes through `FrameEngine.LiveAudioSink`, which tees to the tap FIRST
    // and then the shared renderer — so metering, SDI and mute keep behaving exactly as they did in
    // stage 1 and the only new consumer is the speaker.
    //
    // ⚠️ SRT IS IN A BETTER POSITION THAN WHEP AND THE CODE MUST NOT COPY WHEP'S WORKAROUND.
    // WHEP audio and video arrive on separate SSRCs with independent random RTP timestamp bases, so
    // WHEP has to LATCH an epoch on its first packet and ASSUME the two streams start aligned —
    // `WHEPAudioReceiver`'s stage-1 assumption, the thing its lip-sync measurement exists to test.
    // MPEG-TS has no such problem: audio and video PTS are both in the program's single 90 kHz
    // clock, so `packet.pts * audioTimeBase` is ALREADY in the same timeline `LiveClock` reads.
    // There is no epoch, no crossover, and no assumption to test. Audio is stamped with its own
    // PTS, unmodified.

    /// Opens the shared renderer to live audio; returns the sink. Wired in `WindowDeck`.
    var beginLiveAudio: ((Double) -> FrameEngine.LiveAudioSink?)?
    /// Forwards `LiveClock`'s mapping to the engine's audio timebase. The `Bool` is `true` for a
    /// HEARTBEAT (`onMappingTick`) and `false` for a publication (`onMappingChange`) — the engine
    /// treats both identically and uses it only to keep its change→push ratio readable.
    var mirrorLiveAudio: ((LiveClock.Mapping?, Bool) -> Void)?
    /// The clock's first presentation, with the mapping the picture started on — opens the first
    /// audio anchor's gate (docs/AUDIO_RESAMPLER_DESIGN.md §2.7). Called from the display tick.
    var liveAudioPresented: ((LiveClock.Mapping) -> Void)?
    /// The clock's discontinuous moves, to the engine's splice matcher (step 5). Any thread.
    var liveAudioPositionJump: ((LiveClock.PositionJump) -> Void)?
    /// Closes the session. Must be called on teardown or the renderer keeps a dead timebase.
    var endLiveAudio: (() -> Void)?
    /// Publishes the decoded channel count so the meters size their bars.
    var liveAudioEstablished: ((Int) -> Void)?
    /// Publishes positive ABSENCE — this program carries no audio stream.
    var liveAudioAbsent: (() -> Void)?
    /// Synchronizer-timebase minus live-clock, for the lip-sync measurement.
    var liveAudioDrift: ((Double) -> Double?)?

    /// The sink for this session. Non-nil only while a live-audio session is open.
    private var audioSink: FrameEngine.LiveAudioSink?

    /// The engine's tap. Weak, like `renderer`: the engine owns it. Wired in `WindowDeck`.
    weak var audioTap: AudioTapBuffer?

    /// Session-thread-owned, exactly like `decoder`. Built in `prepareAudioDecoder` on the session
    /// thread and used by `handleAudioPacket` on that same thread.
    ///
    /// ⚠️ THE CONCRETE TYPE, DELIBERATELY. This was briefly `(any SRTAudioDecoding)` with a
    /// libavcodec sibling behind it; that experiment is reverted and the protocol is deleted. See
    /// `SRTAudioDecoder`'s header for why, and do not re-introduce the seam without a reason of
    /// its own — the one it had turned out to be aimed at the wrong stage.
    private var audioDecoder: SRTAudioDecoder?

    #if DEBUG
    /// DEBUG-only .wav capture of the exact bytes handed to the tap. Nil unless armed by
    /// preference before launch — see `LiveAudioWAVCaptureGate`. Built ONCE and outlives a
    /// reconnect deliberately: the capture is one 10 s window per launch, not per connection.
    private let audioWAVCapture: LiveAudioWAVCapture? =
        LiveAudioWAVCaptureGate.isEnabled ? LiveAudioWAVCapture(tag: "SRT") : nil
    #endif
    private var audioPacketsReceived = 0
    private var audioFramesIngested = 0
    /// Packets discarded because the video anchor had not landed. Reported, never silent.
    private var audioPacketsBeforeAnchor = 0
    private var audioLoggedAnchorDrop = false
    private var audioEstablishedPublished = false
    private var audioLastHeartbeat: CFTimeInterval = 0
    private var audioPacketsUndecodable = 0
    /// Of those packets: ADTS frames the converter produced nothing for, and bytes after the last
    /// whole frame of a payload that the walk could not use.
    private var audioFramesUndecodable = 0
    private var audioBytesUnwalked = 0
    private var audioLoggedMultiFramePES = false
    private var audioLoggedUnwalked = false
    private var audioPacketsWithoutPTS = 0
    private var audioLoggedFirstFrames = false
    private var audioTimeBase: Double = 1.0 / 90_000.0

    /// The sender's packing: AAC frames per PES, as walked (docs/BUGS.md, "SRT audio breaks up when
    /// the sender packs ≥ ~170 ms of AAC into each PES"). Logged when the count changes; the session
    /// figures go on the session-end line. Stage 0b-1, instrumentation only.
    private var audioPackingPES = 0
    private var audioPackingFrames = 0
    private var audioPackingSeconds = 0.0
    private var audioPackingLast = 0
    private var audioPackingLogged = 0
    private var audioPackingMaxFrames = 0
    private var audioPackingMaxSeconds = 0.0
    private var audioPackingChanges = 0
    private var audioPackingUnlogged = 0
    private var audioPackingLastLogHost: CFTimeInterval = 0
    /// At most one packing line per second: a sender whose count moves on every PES (programme audio
    /// packed by size, 5–7 frames) would otherwise log ~6 lines a second.
    private static let audioPackingLogSpacing: CFTimeInterval = 1.0

    /// ⚠️ THE DECLARED LAYOUT, AND WHERE IT GOES NOW (STAGE 3 CONNECTED IT).
    ///
    /// The mux declares the layout and `fillAudioFormat` carries it here intact — the AVChannelOrder
    /// and, for a NATIVE-order layout, the channel mask, plus libavformat's own description string
    /// ("stereo", "5.1(side)"). Stage 1 logged them and stopped, because `AudioTapBuffer.Format` had
    /// no layout field and a live source has no `metadata.audioTracks` for the meters' role closure
    /// to read. Both halves now exist:
    ///
    ///   * `AudioChannelLayoutBridge` translates this mask to CoreAudio positions, refusing any
    ///     position outside the eighteen WAVE ones instead of approximating it.
    ///   * `SRTAudioDecoder` REQUESTS that order from AudioToolbox and READS IT BACK, then hands the
    ///     verified layout to `makeAudioSampleBuffer`, which attaches it to the format description.
    ///   * `AudioTapBuffer.Format.roles` reads it off that description; `ContentView` prefers the
    ///     file's `metadata.audioTracks` roles and falls back to the tap's, so a live source reaches
    ///     the meters by the same closure a file does.
    ///
    /// ⚠️ THE MASK IS *NOT* THE INTERLEAVE ORDER, AND THAT IS WHY THE DECODER HAS THE LAST WORD.
    /// `AV_CH_LAYOUT_5POINT1_BACK` reads L R C LFE Ls Rs — libav's native order, i.e. what libav's
    /// OWN decoder would emit. AudioToolbox decodes the same bitstream to `AAC_5_1` order,
    /// **C L R Ls Rs LFE**, unless told otherwise. Labelling the converter's output from this mask
    /// directly would put dialogue on Left and LFE on a surround, with six bars all confidently
    /// named. See the long note at the top of `SRTAudioDecoder`'s layout section.
    ///
    /// >>> A FEED THAT DECLARES NOTHING USABLE STILL METERS AS NUMBERS, ON PURPOSE. That is not the
    /// >>> stage-1 gap; it is the finished behaviour. Count-implies-layout is the inference this
    /// >>> codebase refuses, and per-channel labels are the one place it would be invisible.
    private(set) var declaredChannelOrder: Int32 = 0
    private(set) var declaredChannelMask: UInt64 = 0
    private(set) var declaredLayoutName = ""

    /// SESSION THREAD, inline from `onAudioFormat`. Mirrors `prepareDecoder`'s contract exactly.
    func prepareAudioDecoder(format: ManifoldSRTAudioFormat) {
        audioPacketsReceived = 0; audioFramesIngested = 0
        audioPacketsUndecodable = 0; audioPacketsWithoutPTS = 0
        audioFramesUndecodable = 0; audioBytesUnwalked = 0
        audioLoggedMultiFramePES = false; audioLoggedUnwalked = false
        audioPackingPES = 0; audioPackingFrames = 0; audioPackingSeconds = 0
        audioPackingLast = 0; audioPackingLogged = 0; audioPackingMaxFrames = 0; audioPackingMaxSeconds = 0
        audioPackingChanges = 0; audioPackingUnlogged = 0; audioPackingLastLogHost = 0
        // The axis is per-STREAM. Carrying an anchor across a format change or a reconnect would
        // stamp the new stream's first buffer from the old stream's count — the same reasoning
        // NDIService resets its counter under.
        audioAnchorTicks = nil; audioCumulativeFrames = 0
        audioAxisRate = 0; audioAxisChannels = 0
        audioAxisResyncCount = 0; audioAxisFirstDivergenceLogged = false
        audioLoggedFirstFrames = false

        let codec = withUnsafePointer(to: format.codecName) {
            $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
        }
        let profile = withUnsafePointer(to: format.profileName) {
            $0.withMemoryRebound(to: CChar.self, capacity: 48) { String(cString: $0) }
        }
        let layout = withUnsafePointer(to: format.layoutName) {
            $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
        }
        declaredChannelOrder = format.channelOrder
        declaredChannelMask = format.channelMask
        declaredLayoutName = layout
        if format.timeBaseNum > 0 && format.timeBaseDen > 0 {
            audioTimeBase = Double(format.timeBaseNum) / Double(format.timeBaseDen)
        }

        // ── THE FRAMING QUESTION, ANSWERED BY THE DEMUXER RATHER THAN GUESSED ─────────────────
        //
        // libavformat's mpegts demuxer sets the codec id from the PMT stream type: 0x0F → `aac`
        // (ADTS-framed) and 0x11 → `aac_latm` (LATM/LOAS). So this line reports which framing the
        // feed actually uses, on the first connect, with no probing.
        //
        // ⚠️ LATM IS NOT DECODED IN STAGE 1, AND IT SAYS SO RATHER THAN GOING QUIET. AudioToolbox
        // wants raw AAC access units plus a magic cookie; LATM carries its own multiplex layer that
        // has to be unwrapped first, and the vendored build's `aac_latm` PARSER exists precisely
        // because that is real work. Refusing loudly is the correct stage-1 behaviour: a silent
        // meter that might mean "no audio" or might mean "unhandled framing" is the failure mode
        // this codebase keeps writing entries about.
        let isLATM = codec == "aac_latm"
        let formatID: AudioFormatID = kAudioFormatMPEG4AAC

        var extradata: [UInt8] = []
        if let ptr = format.extradata, format.extradataSize > 0 {
            extradata = Array(UnsafeBufferPointer(start: ptr, count: Int(format.extradataSize)))
        }

        // ⚠️ THE TIME BASE IS ON THIS LINE BECAUSE IT DECIDES WHETHER THE SENDER'S PTS CAN TILE AT
        // ALL. `1/90000` can express a 1024-frame step at 48 kHz exactly (1920 ticks); `1/1000`
        // cannot express it at all (21.3333 ms), and every buffer boundary is then rounded before
        // this app ever sees it. Comparing this field between two senders is what separates "that
        // transport was always contiguous" from "it was quantised and merely sounded acceptable".
        NSLog("[SRT-AUDIO] stream %d pid=0x%x codec=%@ profile=%@ %d Hz %d ch layout=%@ "
            + "framing=%@ extradata=%d B timeBase=%d/%d (%.6f s/tick — %@)",
              format.streamIndex, UInt32(bitPattern: format.pid), codec, profile,
              format.sampleRate, format.channelCount, layout.isEmpty ? "?" : layout,
              isLATM ? "LATM/LOAS" : "ADTS-or-raw", format.extradataSize,
              format.timeBaseNum, format.timeBaseDen,
              format.timeBaseDen > 0 ? Double(format.timeBaseNum) / Double(format.timeBaseDen) : 0,
              Self.timeBaseVerdict(num: format.timeBaseNum, den: format.timeBaseDen,
                                   sampleRate: Double(format.sampleRate)))

        guard !isLATM else {
            audioDecoder = nil
            NSLog("[SRT-AUDIO] ⚠️ LATM/LOAS framing is NOT decoded in stage 1 — no audio will "
                + "reach the tap. This is a stated limitation, not a failure. Unwrapping LATM is "
                + "the work stage 1 deliberately did not do; report this line if you see it.")
            return
        }
        guard codec == "aac" else {
            audioDecoder = nil
            NSLog("[SRT-AUDIO] ⚠️ codec '%@' is not handled in stage 1 (AAC only) — no audio will "
                + "reach the tap. NOTE: this machine's AudioToolbox CAN decode mp2/mp3, so this is "
                + "a scope boundary rather than a capability one.", codec)
            return
        }

        // ── ONE DECODER, NO SELECTION ─────────────────────────────────────────────────────
        //
        // ⚠️ THERE WAS A BRANCH HERE (2026-09-21, for part of one evening): `channelCount <= 2`
        // routed stereo to a libavcodec decoder and left multichannel on AudioToolbox. It was
        // adopted because AudioToolbox appeared to mis-decode the Cloudflare feed, and that
        // premise was wrong — the distortion was the sender's PTS grid, upstream of both decoders.
        // AudioToolbox was then measured clean on the same feed and the branch was reverted. The
        // full account is in `SRTAudioDecoder`'s header and in docs/BUGS.md; the point of writing
        // it down is that the inference looked correct at the time, so it will look correct again.
        //
        // NOTHING IS ASSUMED — rate and channels come from the stream.
        audioDecoder = SRTAudioDecoder(sampleRate: Double(format.sampleRate),
                                       channelCount: Int(format.channelCount),
                                       formatID: formatID,
                                       extradata: extradata,
                                       channelMask: format.channelMask,
                                       channelOrder: format.channelOrder)

        // ⚠️ NO `[SRT-AUDIO] decoder: …` LINE ANY MORE, ON PURPOSE. It existed to name which of two
        // decoders ran, because both produced an identical buffer shape and were otherwise
        // indistinguishable downstream. With one decoder it would report a compile-time constant,
        // and the `[SRT-AUDIO] stream …` line above already carries the rate, channel count and
        // framing that were the only variable parts of it. The failure line below is what remains
        // worth saying.
        if audioDecoder == nil {
            NSLog("[SRT-AUDIO] decoder construction FAILED — no audio will reach the tap")
        }
    }

    #if DEBUG
    /// ⌃⌥U — pin the RUNNING SRT session's clock rate to exactly 1.0, or release it.
    ///
    /// ⚠️ ⌃⌥U DID NOT REACH THIS CLOCK BEFORE, AND THE REASON IS WORTH STATING. The shortcut called
    /// `SyntheticLiveSource.toggleForceUnityRate`, which applies to the SYNTHETIC HARNESS's own
    /// `LiveClock` — a different instance from the one `activate()` builds for a live stream, and
    /// one that is not running at all during an SRT session. So the gate existed, was compiled into
    /// Profile, and was inert for every real transport. This is the forwarder that fixes that.
    ///
    /// ⚠️ IT DISABLES THE VIDEO DEPTH LOOP TOO, WHICH IS NOT A SIDE EFFECT — IT IS WHAT THE FLAG
    /// MEANS. With the loop off nothing drains the buffer, so on a transport that runs deep the
    /// video latency creeps for as long as this is on. Fine for an A/B of a minute or two; not a
    /// setting to leave on.
    func setForceUnityRate(_ on: Bool) {
        stateLock.lock(); let clock = liveClock; stateLock.unlock()
        guard let clock else {
            NSLog("[SRT] ⌃⌥U: no SRT session is running — nothing to pin.")
            return
        }
        clock.setForceUnityRate(on)
        NSLog("[SRT] ⌃⌥U: LiveClock control loop %@ for the RUNNING SRT session. %@",
              on ? "DISABLED — rate pinned to exactly 1.0" : "RE-ENABLED",
              on ? "Audio follows the pinned line through the resampler's loop; the renderer's rate "
                 + "is 1.0 either way. smoothedRate on the [SRT-AUDIO] mirror line (a logged "
                 + "30 s EMA of this rate) will come down to 1.0 over ~30-60 s."
                 : "smoothedRate will drift back up over the same ~30 s.")
    }
    #endif

    /// SESSION THREAD, inline from `onAudioAbsent`.
    func handleAudioAbsent() {
        audioDecoder = nil
        // ⚠️ SRT LEARNS ABSENCE EARLIER AND MORE RELIABLY THAN WHEP DOES, AND THIS USES THAT.
        // WHEP infers it from the SDP answer — a negotiation outcome, available only after the
        // answer is applied, and only as reliable as the server's honesty about a section it may
        // simply have omitted. SRT reads it from the DEMUXED PROGRAM at stream discovery: the PMT
        // either lists an audio elementary stream or it does not, and that is known before a single
        // audio packet could have arrived. So the meters can say "no audio track" from the first
        // moment there is anything to say, rather than after a timeout.
        Task { @MainActor in SRTFrameRouter.shared.liveAudioAbsent?() }
        NSLog("[SRT-AUDIO] this program carries NO audio stream — stated positively, not inferred "
            + "from silence, and known at stream discovery rather than after a wait. The meters "
            + "will read NO AUDIO TRACK.")
    }

    // MARK: - The audio PTS axis: SAMPLE-COUNTED, not read off the source PTS per buffer

    /// Anchor of the sample axis, IN SAMPLE TICKS on the sample rate's own timescale, and the
    /// count of frames delivered since it was set. `ptsTicks = anchorTicks + cumulative` — an
    /// integer add, which is the whole fix.
    private var audioAnchorTicks: Int64?
    private var audioCumulativeFrames: Int64 = 0
    private var audioAxisRate = 0.0
    private var audioAxisChannels = 0
    private var audioAxisResyncCount = 0
    private var audioAxisFirstDivergenceLogged = false

    /// How far the sample axis may drift from the SOURCE PTS before it is re-pinned.
    ///
    /// 25 ms — deliberately HALF of `AudioTapBuffer.append`'s 50 ms PTS/sample disagreement
    /// threshold, the same value and the same reasoning as `NDIService.audioAxisResyncTolerance`.
    /// The tap re-anchor DROPS the retained window, which is what DeckLink reads from, so an axis
    /// that only corrected at the tap's own threshold would trade a renderer glitch for an SDI
    /// dropout.
    private static let audioAxisResyncTolerance = 0.025

    /// ── ⚠️ WHY THE PTS IS COUNTED IN SAMPLES AND NOT CONVERTED FROM THE SOURCE PTS ────────────
    ///
    /// THIS REPLACED `CMTime(seconds: packet.pts × timeBase, preferredTimescale: 90_000)`, AND
    /// THAT CONVERSION WAS THE DISTORTION BUG. `AVSampleBufferAudioRenderer` schedules by PTS
    /// exactly, so buffer n+1 must begin where buffer n ended TO THE SAMPLE. MEASURED on the
    /// Cloudflare feed, before the fix:
    ///
    ///     PTS 36.263000, 36.284000, 36.306000 …   — a 1 ms grid
    ///     true buffer duration 1024/48000         = 21.3333 ms
    ///     → steps of 21 ms and 22 ms, alternating
    ///     → gaps of −16 and +32 samples, alternating, cumulative ≈ 0
    ///     → ZERO contiguous buffers out of 468
    ///
    /// The renderer must splice every single buffer, ~47 times a second, which is continuous
    /// distortion rather than clicks. 1 ms is 48 samples at 48 kHz; rounding 21.3333 ms down loses
    /// 16 and rounding up gains 32, which is exactly the pair observed.
    ///
    /// ⚠️ THE ROUNDING IS NOT NECESSARILY OURS, AND THE FIX DOES NOT DEPEND ON WHOSE IT IS. Either
    /// the stream declares a millisecond `time_base` (so `packet.pts` cannot express a sample) or
    /// the sender's muxer quantised its own PTS to milliseconds before we ever saw it. In both
    /// cases the per-buffer source PTS is incapable of tiling, and in both cases counting samples
    /// fixes it — which is why this does not try to distinguish them.
    ///
    /// ⚠️ AND IT IS STILL PINNED TO THE SOURCE TIMELINE, WHICH IS NOT OPTIONAL. SRT's VIDEO is
    /// paced from the same sender PTS axis, so a sample axis allowed to free-run would take
    /// lip-sync with it. Sample-exact in the small, source-pinned in the large — the same contract
    /// NDI's axis has with the wall clock, with the sender's timeline in place of `monotonicNow()`
    /// because that is what SRT's video actually uses.
    ///
    /// The old comment block in `makeAudioSampleBuffer` predicted this exactly ("the desktop would
    /// crackle exactly as NDI's did — with the tap, the meters and SDI all still perfect, because
    /// only the renderer uses per-buffer timing") and concluded "SRT's audio is measured working on
    /// the wire and is left alone". The wire was never the part that was broken.
    private func audioPTSTicks(forFrames frames: Int, sampleRate: Double, channels: Int,
                               sourcePTS: Double) -> Int64 {
        // (Re)anchor: first buffer of a session, or the format moved under us. A rate change makes
        // `cumulative / sampleRate` meaningless — the divisor is no longer the one the frames were
        // counted at — so the counter restarts rather than being converted.
        if audioAnchorTicks == nil || sampleRate != audioAxisRate || channels != audioAxisChannels {
            if audioAnchorTicks != nil {
                NSLog("[SRT-AUDIO] audio format moved %.0fHz·%dch → %.0fHz·%dch — sample axis "
                    + "restarted and re-anchored to the source PTS",
                      audioAxisRate, audioAxisChannels, sampleRate, channels)
            }
            // The ONE conversion from seconds in the whole axis. Rounded to the nearest sample
            // tick, because a tick is the finest thing the axis can express and a fractional
            // anchor would reintroduce exactly the rounding this replaced.
            audioAnchorTicks = Int64((sourcePTS * sampleRate).rounded())
            audioCumulativeFrames = 0
            audioAxisRate = sampleRate
            audioAxisChannels = channels
        }

        var ticks = audioAnchorTicks! + audioCumulativeFrames
        let divergence = Double(ticks) / sampleRate - sourcePTS

        // ⚠️ REPORTED ONCE, EARLY, BECAUSE IT IS THE MEASUREMENT THAT NAMES THE SENDER. A source
        // whose PTS tiles exactly diverges by 0; one quantising to milliseconds diverges by up to
        // half a grid step immediately. This is what distinguishes "this transport was always
        // contiguous" from "it was quantised and merely sounded acceptable".
        if !audioAxisFirstDivergenceLogged && audioCumulativeFrames > 0 {
            audioAxisFirstDivergenceLogged = true
            NSLog("[SRT-AUDIO] sample axis: after 1 buffer the source PTS is %+.4f ms from the "
                + "sample-counted axis (%.0f samples). ZERO means the sender's PTS already tiled "
                + "exactly; anything else is the sender's own quantisation, which the axis now "
                + "absorbs.", divergence * 1000, divergence * sampleRate)
        }

        if abs(divergence) > Self.audioAxisResyncTolerance {
            audioAxisResyncCount += 1
            // Re-pin so THIS buffer lands on the source PTS, keeping the running count intact —
            // the axis moves, the counter does not restart. Still an integer tick, so the grid
            // property survives a re-pin.
            audioAnchorTicks = Int64((sourcePTS * sampleRate).rounded()) - audioCumulativeFrames
            ticks = audioAnchorTicks! + audioCumulativeFrames
            // On record before the re-pinned buffer reaches the sink (step 5's splice matcher).
            audioSink?.noteInputAxisRePin(divergenceSeconds: divergence)
            NSLog("[SRT-AUDIO] sample axis RE-PINNED — it had run %+.1f ms %@ the source PTS "
                + "(tolerance %.0f ms) · re-pin #%d. A one-off is a sender discontinuity; a steady "
                + "cadence means the declared sample rate is not the rate the sender is producing "
                + "at, and the fault is upstream of this axis.",
                  divergence * 1000, divergence > 0 ? "AHEAD OF" : "BEHIND",
                  Self.audioAxisResyncTolerance * 1000, audioAxisResyncCount)
        }

        audioCumulativeFrames += Int64(frames)
        return ticks
    }

    /// SESSION THREAD, inline, per packet. The hot path — no hop, exactly like `handleAccessUnit`.
    func handleAudioPacket(_ packet: ManifoldSRTAudioPacket) {
        audioPacketsReceived += 1
        // ⚠️ BOUND EXPLICITLY FROM `audioDecoder`. A bare `guard let decoder` resolves to this
        // type's VIDEO decoder property, which compiles and is wrong — it was caught by the
        // type checker here only because LiveVideoDecoder has no `sampleRate`.
        guard let decoder = audioDecoder, let tap = audioTap else { return }
        guard packet.pts != Self.noTimestamp else { audioPacketsWithoutPTS += 1; return }
        guard let data = packet.data, packet.size > 0 else { return }

        let pcm = UnsafeRawBufferPointer(start: data, count: packet.size)
        // The stream's own time base. Used to PIN the sample axis, never as the per-buffer stamp —
        // see `audioPTSTicks` for why the conversion that used to happen here was the bug.
        let packetPTS = Double(packet.pts) * audioTimeBase
        // ⚠️ ONE PES, POSSIBLY SEVERAL AAC FRAMES (docs/BUGS.md, "SRT audio decodes nothing when a
        // PES carries more than one ADTS frame"). The PES PTS stamps the FIRST frame's first sample
        // (ISO/IEC 13818-1 §2.4.3.7); frame k starts after the samples of frames 0…k−1, so each is
        // pinned at the packet PTS plus the samples already decoded from this packet. The sample
        // axis then advances exactly as with one frame per PES.
        var samplesBefore = 0
        let result = decoder.decode(pcm) { frames in
            let frameCount = frames.count / decoder.channelCount
            guard frameCount > 0 else { return }
            let pts = packetPTS + Double(samplesBefore) / decoder.sampleRate
            samplesBefore += frameCount
            ingestDecodedAudio(frames, frameCount: frameCount, pts: pts, decoder: decoder, tap: tap)
        }
        notePacking(frames: result.frames, seconds: Double(samplesBefore) / decoder.sampleRate)
        if result.frames > 1 && !audioLoggedMultiFramePES {
            audioLoggedMultiFramePES = true
            NSLog("[SRT-AUDIO] this sender packs %d AAC frames into one PES — each is decoded and "
                + "stamped on its own (packet PTS + the samples before it). Logged once per session.",
                  result.frames)
        }
        if result.failed > 0 || result.leftoverBytes > 0 {
            audioPacketsUndecodable += 1
            audioFramesUndecodable += result.failed
            audioBytesUnwalked += result.leftoverBytes
            if !audioLoggedUnwalked {
                audioLoggedUnwalked = true
                NSLog("[SRT-AUDIO] ⚠️ a %d-byte payload: %d of %d ADTS frame(s) decoded, %d produced "
                    + "nothing, %d byte(s) after the last whole frame not used (%@). Counted as "
                    + "undecodable, never silently dropped; logged once per session, the totals are "
                    + "on the chain line.",
                      packet.size, result.decoded, result.frames, result.failed, result.leftoverBytes,
                      result.stop.map { "\($0)" } ?? "no walk stop")
            }
        }
    }

    /// One PES's packing: `frames` walked, `seconds` decoded from them. SESSION THREAD, inline from
    /// `handleAudioPacket`. A payload the walk could not split (raw AAC, LATM) has no count and is
    /// not recorded.
    private func notePacking(frames: Int, seconds: Double) {
        guard frames > 0 else { return }
        audioPackingPES += 1
        audioPackingFrames += frames
        audioPackingSeconds += seconds
        audioPackingMaxFrames = max(audioPackingMaxFrames, frames)
        audioPackingMaxSeconds = max(audioPackingMaxSeconds, seconds)
        considerCushion(largestPES: audioPackingMaxSeconds)
        if frames != audioPackingLast {
            audioPackingLast = frames
            audioPackingChanges += 1
            audioPackingUnlogged += 1
        }
        // A change held back by the spacing is logged at the first PES after it, so the count the
        // sender settles on always reaches the log.
        guard audioPackingUnlogged > 0 else { return }
        let now = CACurrentMediaTime()
        guard audioPackingLastLogHost == 0 || now - audioPackingLastLogHost >= Self.audioPackingLogSpacing
        else { return }
        audioPackingLastLogHost = now
        let skipped = audioPackingUnlogged - 1
        NSLog("[SRT-AUDIO] packing — %d AAC frame(s) per PES (%.1f ms) at PES #%d, last logged %@ · "
            + "session max %d frame(s) (%.1f ms)%@",
              frames, seconds * 1000, audioPackingPES,
              audioPackingLogged == 0 ? "—" : "\(audioPackingLogged)",
              audioPackingMaxFrames, audioPackingMaxSeconds * 1000,
              skipped > 0 ? " · \(skipped) change(s) in between not logged (1 line/s)" : "")
        audioPackingLogged = frames
        audioPackingUnlogged = 0
    }

    /// One decoded AAC frame, stamped and handed on. SESSION THREAD, inline from `handleAudioPacket`.
    private func ingestDecodedAudio(_ frames: UnsafeBufferPointer<Int32>, frameCount: Int, pts: Double,
                                    decoder: SRTAudioDecoder, tap: AudioTapBuffer) {
        let ptsTicks = audioPTSTicks(forFrames: frameCount, sampleRate: decoder.sampleRate,
                                     channels: decoder.channelCount, sourcePTS: pts)
        guard let sb = Self.makeAudioSampleBuffer(frames, frames: frameCount,
                                                  channels: decoder.channelCount,
                                                  sampleRate: decoder.sampleRate,
                                                  ptsTicks: ptsTicks,
                                                  layout: decoder.channelLayoutData)
        else { audioFramesUndecodable += 1; return }

        // ── THE STARTUP WINDOW ────────────────────────────────────────────────────────────
        //
        // ⚠️ DROPPED, NOT HELD, AND THE REASON IS NOT WHEP'S REASON. WHEP holds packets because it
        // CANNOT COMPUTE A PTS until the live clock is finite — its epoch latch needs a clock
        // reading. SRT never has that problem: `pts` above is already correct and absolute in the
        // program's 90 kHz clock, whether or not anything is anchored.
        //
        // These packets are dropped because of what the VIDEO path is about to do. `anchorOrDefer`
        // has not chosen its anchor yet, and when it does it DISCARDS every frame from the first
        // delivered one up to that anchor — 64 frames / 2.669 s of content on the run that
        // motivated this. Audio for discarded video must be discarded with it; enqueue it and
        // either the renderer drops it as already-past (harmless but invisible) or, if the anchor
        // lands early enough, a burst of stale audio plays against picture that was skipped.
        //
        // So the WHEP hold-and-count shape transfers, the justification does not, and the window is
        // shorter: it closes on the first video frame that clears the gap test, with no crossover
        // to establish afterwards.
        guard startupAnchored else {
            audioPacketsBeforeAnchor += 1   // per AAC frame: a PES may carry several
            return
        }
        if audioPacketsBeforeAnchor > 0 && !audioLoggedAnchorDrop {
            audioLoggedAnchorDrop = true
            NSLog("[SRT-AUDIO] startup: dropped %d AAC frame(s) that arrived before the video anchor "
                + "— they belong to the content span the anchor discarded, and playing them would "
                + "put audio against picture that was skipped.", audioPacketsBeforeAnchor)
        }

        #if DEBUG
        // ⚠️ BEFORE THE HANDOFF, NOT AFTER, AND NOT INSIDE THE SINK. This is the last point at
        // which the buffer is provably untouched by anything downstream — `LiveAudioSink.enqueue`
        // tees to the tap AND the renderer, and a capture taken past this line could not tell a
        // bad decode from something either consumer did to it. No-op (one nil check) unless the
        // capture was armed by preference before launch.
        audioWAVCapture?.capture(sb, sampleRate: decoder.sampleRate, channels: decoder.channelCount)
        #endif

        // Tee: tap FIRST, then the renderer — the sink does both, so metering, SDI and mute are
        // unchanged from stage 1 and the speaker is the only new consumer. Falls back to the tap
        // alone if no sink was opened, which keeps stage-1 behaviour rather than losing metering.
        if let sink = audioSink {
            sink.enqueue(sb)
        } else {
            tap.ingest(sb, path: .srt)
        }
        audioFramesIngested += frameCount

        // The channel count comes from what actually DECODED, so the meters size from the decoder
        // rather than from the stream header's claim.
        if !audioEstablishedPublished {
            audioEstablishedPublished = true
            let ch = decoder.channelCount
            Task { @MainActor in SRTFrameRouter.shared.liveAudioEstablished?(ch) }
        }

        // ── THE LIP-SYNC HEARTBEAT ────────────────────────────────────────────────────────
        //
        // ⚠️ WALL CLOCK, NOT DECODED AUDIO. WHEP's line was originally gated on `framesDecoded`
        // advancing, which meant it went silent exactly when decode stalled — the one failure it
        // existed to report. Keyed to the host clock, this keeps talking through a stall.
        //
        // `timebase−clock` is THE checkpoint number: the audio timebase minus the live clock, with
        // the cushion already removed by `liveAudioDrift`, so it reads as mirror ERROR around zero
        // rather than as a constant −0.250.
        let hostNow = CACurrentMediaTime()
        if hostNow - audioLastHeartbeat >= 1.0 {
            audioLastHeartbeat = hostNow
            stateLock.lock(); let clock = liveClock; stateLock.unlock()
            let drift = clock.map { c in SRTFrameRouter.shared.liveAudioDrift?(c.now()) } ?? nil
            NSLog("[SRT-AUDIO] chain — rx=%d frames=%d (%.1f s) undecodable=%d (aacFrames=%d "
                + "unwalkedBytes=%d) noPTS=%d droppedPreAnchor=%d · pts=%.3fs · timebase−clock=%@",
                  audioPacketsReceived, audioFramesIngested,
                  Double(audioFramesIngested) / decoder.sampleRate,
                  audioPacketsUndecodable, audioFramesUndecodable, audioBytesUnwalked,
                  audioPacketsWithoutPTS, audioPacketsBeforeAnchor, pts,
                  drift.map { String(format: "%+.1f ms", $0 * 1000) } ?? "n/a")
        }

        if !audioLoggedFirstFrames {
            audioLoggedFirstFrames = true
            // ⚠️ THIS LINE ONCE CLAIMED "the meters should now be moving" ON A SESSION WHERE THEY
            // READ "NO SOURCE" FOR ITS ENTIRE LENGTH. The claim was never checked — it asserted a
            // downstream consequence this code cannot see, and the ✅ made a broken checkpoint read
            // as a passing one, which is worse than having no line at all.
            //
            // It now reports ONLY what it has verified by reading the tap back, and names the
            // remaining condition instead of assuming it. The tap is the half we can prove; whether
            // the METER reads it depends on `AudioMeterModel.isLive`, which lives in the App layer
            // and is not observable from here.
            let f = tap.format
            let verified = f != nil && tap.hasAudio
            NSLog("[SRT-AUDIO] %@ FIRST FRAMES IN THE TAP — %d frames, %d ch, %.0f Hz, pts=%.3f s. "
                + "Tap read back: %@. Meters follow only if this transport is reported live "
                + "(LiveSource.connected).",
                  verified ? "✅" : "⚠️",
                  frameCount, decoder.channelCount, decoder.sampleRate, pts,
                  verified
                    ? String(format: "format %.0f Hz / %d ch, hasAudio=YES, roles %@",
                             f!.sampleRate, f!.channelCount,
                             // STAGE 3: read back from the TAP, not from the decoder — the whole
                             // point is whether the layout survived the trip through the format
                             // description, and asking the decoder again would not test that.
                             f!.roles.isEmpty ? "NONE (bars show numbers)"
                                              : f!.roles.joined(separator: " "))
                    : "NO FORMAT — the ingest did not land; this is a FAILURE, not a checkpoint")
        }
    }

    /// Interleaved Int32 → CMSampleBuffer. Same five CoreMedia calls as the WHEP path, with rate
    /// and channel count taken from the DECODER rather than from constants.
    ///
    /// STAGE 3: `layout` IS THE FORMER STOPPING POINT, NOW CONNECTED. It is the decoder's
    /// VERIFIED output layout — requested from the mux's mask and read back from the converter, in
    /// CoreAudio's descriptions spelling — and attaching it here is what carries the declaration
    /// into `CMAudioFormatDescriptionGetChannelLayout`, which is what `AudioChannelLayoutBridge`
    /// (and through it the tap, and through that the meters) reads.
    ///
    /// ⚠️ nil IS STILL A FIRST-CLASS ANSWER AND MUST STAY ONE. It means the decoder could not
    /// establish an order it is willing to stand behind, and the correct consequence is channel
    /// NUMBERS on the meters. Do not add a "sensible default for 6 channels" here.
    private static func makeAudioSampleBuffer(_ pcm: UnsafeBufferPointer<Int32>,
                                              frames: Int, channels: Int,
                                              sampleRate: Double, ptsTicks: Int64,
                                              layout: Data?) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)

        var format: CMAudioFormatDescription?
        let created: OSStatus
        if let layout, !layout.isEmpty {
            created = layout.withUnsafeBytes { raw in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault, asbd: &asbd,
                    layoutSize: raw.count,
                    layout: raw.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self),
                    magicCookieSize: 0, magicCookie: nil, extensions: nil,
                    formatDescriptionOut: &format)
            }
        } else {
            created = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                     asbd: &asbd, layoutSize: 0, layout: nil,
                                                     magicCookieSize: 0, magicCookie: nil,
                                                     extensions: nil,
                                                     formatDescriptionOut: &format)
        }
        guard created == noErr, let format else { return nil }

        let byteCount = frames * channels * MemoryLayout<Int32>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: byteCount,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block,
              CMBlockBufferReplaceDataBytes(with: pcm.baseAddress!, blockBuffer: block,
                                            offsetIntoDestination: 0,
                                            dataLength: byteCount) == noErr else { return nil }

        var sb: CMSampleBuffer?
        // ── ⚠️ THE PTS IS AN INTEGER SAMPLE COUNT ON THE SAMPLE RATE'S OWN TIMESCALE ──────────
        //
        // This block used to read `CMTime(seconds: pts, preferredTimescale: 90_000)`, above a
        // comment arguing that a 90 kHz audio PTS was safe "by two coincidences" at 48 kHz, and
        // predicting that at 44.1 kHz "every buffer boundary would be rounded and the desktop
        // would crackle exactly as NDI's did". The prediction was right and the premise was wrong:
        // the rounding did not need 44.1 kHz, because the SOURCE PTS was already quantised to a
        // 1 ms grid before it reached that line, so `preferredTimescale: 90_000` was faithfully
        // preserving a value that could not tile. It also closed with "SRT's audio is measured
        // working on the wire and is left alone" — and the wire was never the broken part.
        //
        // Ticks and this timescale make consecutive buffers abut BY CONSTRUCTION, for any frame
        // size and any rate, because the PTS *is* the running sample count. `duration` is one
        // sample on the same timescale and `sampleCount` multiplies it, so the buffer's total
        // duration is exactly `frames` ticks and the next buffer's tick is exactly this one plus
        // `frames`. Nothing rounds anywhere. See `audioPTSTicks`, `NDIService.audioPTSTicks` and
        // docs/BUGS.md #NDI-AUDIO.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: ptsTicks, timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid)
        // BYTES PER SAMPLE (one interleaved frame), not the frame count — see the WHEP note.
        var sampleSize = channels * MemoryLayout<Int32>.size
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                        formatDescription: format, sampleCount: frames,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }

    /// Can a 1024-frame AAC step be expressed exactly on this time base? Stated as a verdict on
    /// the discovery line so the answer does not have to be recomputed from two integers at 1am.
    ///
    /// ⚠️ A "cannot" here is NOT a fault this app can fix at the source, and it is no longer a
    /// fault it suffers from either — `audioPTSTicks` counts samples precisely so the sender's grid
    /// stops mattering. The verdict is diagnostic, not a gate.
    private static func timeBaseVerdict(num: Int32, den: Int32, sampleRate: Double) -> String {
        guard num > 0, den > 0, sampleRate > 0 else { return "no time base declared" }
        let ticksPerFrame = Double(den) / Double(num) / sampleRate   // ticks per audio sample
        let step = 1024.0 * ticksPerFrame
        return step == step.rounded()
            ? "a 1024-frame step is \(Int(step)) ticks, EXACT"
            : String(format: "a 1024-frame step is %.4f ticks, NOT EXACT — the sender's PTS is "
                   + "quantised and cannot tile; the sample-counted axis absorbs it", step)
    }

    /// Retire the decode side. SESSION THREAD, from the same place the video decoder is torn down.
    func teardownAudio() {
        if audioPacketsReceived > 0 || audioDecoder != nil {
            let n = Double(max(audioPackingPES, 1))
            NSLog("[SRT-AUDIO] session end — packets=%d framesIngested=%d undecodable=%d noPTS=%d "
                + "axisRePins=%d · packing: %d PES, %.2f AAC frames per PES (%.1f ms) mean, max %d "
                + "(%.1f ms), %d change(s) · cushion %.0f ms",
                  audioPacketsReceived, audioFramesIngested,
                  audioPacketsUndecodable, audioPacketsWithoutPTS, audioAxisResyncCount,
                  audioPackingPES, Double(audioPackingFrames) / n, audioPackingSeconds / n * 1000,
                  audioPackingMaxFrames, audioPackingMaxSeconds * 1000, audioPackingChanges,
                  stateLock.withLock { cushionWanted } * 1000)
        }
        audioDecoder = nil
    }

    private func anchorOrDefer(senderPTS: Double, arrivalHost: CFTimeInterval,
                               clock: LiveClock) -> Double {
        // ── THE FIRST DELIVERED FRAME ALWAYS DEFERS, AND THE REASON IS NOT PEDANTRY ──────────
        // A gap needs two arrivals. The tempting shortcut is to measure the first one against some
        // earlier reference — `prepareDecoder` returning, say — but every such reference is a
        // MAIN-THREAD-SCHEDULING measurement, not a network one: `activate` hops to main, and if
        // main is busy standing the route up, the first frame appears to have been "waited for"
        // and the anchor lands on the oldest backlog frame after all. Requiring a measured
        // frame-to-frame gap is immune to that, at a cost of exactly one frame (~42 ms at 24 fps)
        // on a stream that had no backlog. That frame shows in the log and in `netJump`; it is not
        // hidden.
        guard let previous = lastArrivalHost else {
            lastArrivalHost = arrivalHost
            deferralBeganHost = arrivalHost
            deferralFirstPTS = senderPTS
            deferredFrames = 1
            return senderPTS      // identity — exactly what registerFrame returns at rate 1.0
        }
        lastArrivalHost = arrivalHost

        let gap = arrivalHost - previous
        let waited = gap >= anchorGapThreshold
        let heldFor = arrivalHost - deferralBeganHost
        let cappedByTime = heldFor >= Self.anchorDeferralMaxSeconds
        let cappedByCount = deferredFrames >= Self.anchorDeferralMaxFrames

        guard waited || cappedByTime || cappedByCount else {
            deferredFrames += 1
            return senderPTS
        }

        startupAnchored = true

        // ── TWO DIFFERENT NUMBERS, AND THE LEDGER WANTS THE SECOND ONE ──────────────────────
        //
        // `discarded` is the CONTENT span we chose not to present — first delivered frame to this
        // one, PTS to PTS. It is the honest answer to "how much of the stream did we skip", and it
        // is what the log reports.
        //
        // IT IS NOT THE CLOCK JUMP. `netJump` is defined as presentation time crossed by an
        // INSTANTANEOUS coarse clock action, and every other contributor is one: the snap and the
        // queue-full re-anchor both evaluate before and after at the SAME instant `t`. THIS
        // DEFERRAL IS NOT INSTANTANEOUS — it occupies `heldFor` of real time, during which a
        // normally-running clock would have advanced by exactly that much on its own. Reporting
        // the whole content span charges the ledger twice for the part that merely ELAPSED: once
        // in `wall`, once again in `netJump`.
        //
        // The arithmetic, with P/H for PTS and host time at the first (₁), anchoring (A) and
        // latest (L) frames, cushion c, rate 1:
        //
        //     surplus  = (P_L − P₁) − (H_L − H₁)
        //     inBuffer = P_L − now(H_L) = P_L − P_A − H_L + H_A + c
        //     residual = surplus + c − netJump − inBuffer
        //
        // With `netJump = P_A − P₁` everything cancels except `residual = −(H_A − H₁)` — a
        // CONSTANT negative offset equal to the deferral's wall duration, on every window, for the
        // life of the stream. That is what flagged OVER on every connect, on the one line whose
        // whole job is to catch accounting bugs.
        //
        // The correct entry is what the anchor choice bought RELATIVE TO ANCHORING ON FRAME 1,
        // which is the same quantity by a second route:
        //
        //     now_ours(t) − now_ifAnchoredOnFirstFrame(t) = (P_A − P₁) − (H_A − H₁)
        //
        // NOT CLAMPED. `netJump` is signed by design. A negative value needs PTS advancing slower
        // than wall while inter-arrival gaps stay under threshold, which the gap test makes very
        // nearly unreachable — but if it ever happens it is the truthful reading, and clamping it
        // would hide precisely the kind of thing `residual` exists to surface. In the no-backlog
        // case the two terms cancel to ~0 all by themselves, which is right: the clock started one
        // frame later in real time and skipped no content at all.
        let discarded = max(0, senderPTS - deferralFirstPTS)
        let netJump = discarded - heldFor
        let presentationPTS = clock.registerFrame(senderPTS: senderPTS)
        telemetry.recordClockJump(netJump)

        // All three numbers, so a future ledger dispute is settleable from the log alone rather
        // than by re-deriving which of them `netJump` should have been.
        let ledgerNote = String(format: "discarded %d frame(s) — %.3fs of content over %.3fs of "
                                      + "wall time, net clock jump %+.3fs",
                                deferredFrames, discarded, heldFor, netJump)

        let rateNote = anchorRateWasDeclared
            ? String(format: "%.3f fps declared", anchorNominalRate)
            : String(format: "%.0f fps assumed — the stream declared none", anchorNominalRate)
        if waited {
            NSLog("""
                  [SRT] startup anchor: GAP — waited %.3fs for this frame (≥ %.3fs, half a frame \
                  at %@), so the clock starts at live instead of behind it. %@.
                  """, gap, anchorGapThreshold, rateNote, ledgerNote)
        } else {
            NSLog("""
                  [SRT] startup anchor: CAP — no gap ≥ %.3fs in %.3fs / %d frame(s), so the \
                  deferral hit its %@ bound and anchored on the frame in hand (today's behaviour, \
                  NOT a measured live edge). Nominal %@ — if the sender is genuinely faster than \
                  that, this is why. %@.
                  """, anchorGapThreshold, heldFor, deferredFrames,
                  cappedByTime ? "time" : "frame-count", rateNote, ledgerNote)
        }
        return presentationPTS
    }

    // MARK: - Per-frame (session thread)

    /// One decoded frame → the screen. Called from the decoder's output callback, inline on the
    /// session thread, with the sender-timeline PTS it carried.
    private func deliver(_ decoded: CVPixelBuffer, pts: CMTime) {
        framesDelivered += 1
        picturesDecoded += 1

        stateLock.lock()
        let clock = liveClock
        let renderer = self.renderer
        stateLock.unlock()
        // Not active (a frame racing activate, or arriving after deactivate). Counting it and
        // dropping it is correct.
        guard let clock, let renderer else { logFlowIfDue(); return }

        // THE PICTURE'S SHAPE, from the DECODED buffer and not from `format.width/height`. The
        // codecpar dimensions are read once, at `avformat_find_stream_info` time, and describe what
        // the demuxer believed then; the decoded buffer is what the renderer will draw, and it
        // follows an in-band SPS change (which this transport gets too — `parameterSetsChanged`
        // exists for it). Placed AFTER the active guard so a frame racing teardown cannot publish a
        // shape for a stream that has already released the display.
        //
        // ⚠️ SQUARE PIXELS ASSUMED. SAR is in the same SPS VUI the colour is now read from
        // (`H264SPSColor` steps over it on the way to the colour fields). Whether this build's
        // codecpar carries `sample_aspect_ratio` is UNMEASURED — it was once claimed to, by the same
        // reasoning that wrongly said codecpar carried the colour (colorimetry block). It is not in
        // `ManifoldSRTVideoFormat` either way, so there is nothing to apply; when it is, this is the call
        // site that would apply it (and `FrameEngine.setLiveDisplaySize` documents what the file
        // path's equivalent value does and does not include).
        //
        // THE RATE TRAVELS WITH IT, from `publishedFrameRate` — the demuxer's declared value latched
        // at stream open, or nil. It is stated on EVERY publish and not once at connect because
        // `LiveVideoFormat` is one value: a raster change mid-stream must re-state the rate or the
        // latch would deliver a format whose rate had gone missing.
        LiveDisplaySize.shared.publish(width: CVPixelBufferGetWidth(decoded),
                                       height: CVPixelBufferGetHeight(decoded),
                                       frameRate: publishedFrameRate)

        let senderPTS = CMTimeGetSeconds(pts)
        guard senderPTS.isFinite else { logFlowIfDue(); return }

        // ONE `now()` READ, SHARED. Both the ledger's inBuffer and the underrun lateness are
        // differences against the clock AT THIS INSTANT, so they must use the SAME reading — two
        // separate `now()` calls would be microseconds apart and would silently stop being
        // comparable. It is also one lock acquisition instead of two.
        let clockNow = clock.now()
        let target = clock.currentTargetDepth
        telemetry.recordArrival(senderPTS: senderPTS, clockNow: clockNow)
        telemetry.closeUnderrunIfOpen(senderPTS: senderPTS, clockNow: clockNow, target: target)

        // Sender timeline → presentation timeline. Identity at rate 1.0; a genuine remap once the
        // control loop has slewed.
        //
        // STRAIGHT THROUGH ONCE ANCHORED. Before that, `anchorOrDefer` decides whether this frame
        // is the one to anchor on — and while it defers it does NOT call `registerFrame`, because
        // calling it IS anchoring. The frame is still promoted, tagged and enqueued below: it may
        // be a reference frame, and the queue it lands in is the cushion the clock will present
        // from the moment the anchor is taken.
        let presentationPTS: Double
        if startupAnchored {
            presentationPTS = clock.registerFrame(senderPTS: senderPTS)
        } else {
            presentationPTS = anchorOrDefer(senderPTS: senderPTS,
                                            arrivalHost: CACurrentMediaTime(), clock: clock)
        }

        // A COLOUR CHANGE REACHES THE RENDERER WHEN ITS FIRST FRAME IS DUE. This frame was decoded
        // under a later SPS than the renderer has been told about; the frames ahead of it in the
        // queue were not. See the colorimetry block.
        let stated = colorimetry.route(undeclaredAxisCode: nil)
        if let announced = announcedColorimetry, stated != announced {
            announcedColorimetry = stated
            onStreamColorimetry?(colorimetry, false, LiveDisplayRoute.secondsUntilDue(presentationPTS, clock))
        }

        guard let promoted = promoteIfNeeded(decoded) else {
            promoteFailures += 1
            logFlowIfDue()
            return
        }
        // Tag the buffer every downstream consumer actually reads (shader matrix, layer colorspace,
        // scopes, EDR gate). A pooled buffer starts untagged and VT's attachment propagation is
        // measured behavior rather than a documented contract, so tagging the OUTPUT last is the
        // ordering that holds either way — NDIService.tagOutput's reasoning, verbatim. What is
        // stamped is what the SPS this frame was decoded under DECLARED, and 709 for any axis it did
        // not; the provenance of that choice is in its `[SPS-COLOR]` line.
        colorimetry.bufferTags.apply(to: promoted)

        guard let sampleBuffer = Self.makeSampleBuffer(
                promoted,
                pts: CMTime(seconds: presentationPTS, preferredTimescale: 1_000_000)) else {
            logFlowIfDue()
            return
        }

        renderer.enqueue(sampleBuffer)
        framesEnqueued += 1
        logFlowIfDue()
    }

    // MARK: - Promote (session thread)

    /// 8-bit → the renderer's 10-bit sample domain, via the SAME VTPixelTransferSession shape NDI
    /// and WHEP use. Destination is x420 — 10-bit biplanar 4:2:0 — so 4:2:0 in becomes 4:2:0 out
    /// with no chroma resample; the 8→10 promotion is an exact ×4 code shift, not a filter.
    ///
    /// A NO-OP when VideoToolbox already gave us 10-bit: the decoder REQUESTS x420 output and only
    /// falls back to VT's native 8-bit choice if the session refuses it.
    ///
    /// ⚠️ 4:2:2 IS NOT HANDLED, AND SRT IS THE TRANSPORT WHERE THAT WILL FIRST BITE. A real
    /// contribution feed can be High 4:2:2 10-bit. The transfer session would resample it to 4:2:0
    /// here — silently, and destructively for a chroma-critical monitoring tool. The decoder would
    /// have to request x422 for such a stream and this destination would have to follow. Out of
    /// scope for first-light; stated here so it is found rather than discovered.
    private func promoteIfNeeded(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let sourceFormat = CVPixelBufferGetPixelFormatType(source)
        if sourceFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || sourceFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange {
            if !reportedPromote {
                reportedPromote = true
                NSLog("[SRT] decoded as %@ — already in the renderer's 10-bit domain, no promote needed",
                      LiveVideoDecoder.formatName(sourceFormat))
            }
            return source
        }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)

        if transferSession == nil {
            var session: VTPixelTransferSession?
            let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault,
                                                      pixelTransferSessionOut: &session)
            guard status == noErr, let session else {
                NSLog("[SRT] VTPixelTransferSessionCreate failed (%d) — no picture", status)
                return nil
            }
            transferSession = session
        }
        guard let transferSession else { return nil }

        if pixelBufferPool == nil || poolSize != (width, height) {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any]() as CFDictionary,
            ]
            // MinimumBufferCount matches the other live pools: maxQueued (30) + the in-flight frame
            // + lead. A pool that recycles a small FIXED IOSurface set is what keeps the render
            // thread re-mapping known surfaces instead of first-mapping a fresh one every frame.
            let poolAttrs: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 34]
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary,
                                                 attrs as CFDictionary, &pool)
            guard status == kCVReturnSuccess, let pool else {
                NSLog("[SRT] CVPixelBufferPoolCreate failed (%d) — no picture", status)
                return nil
            }
            pixelBufferPool = pool
            poolSize = (width, height)
        }
        guard let pixelBufferPool else { return nil }

        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &destination)
                == kCVReturnSuccess, let destination else { return nil }

        // Tag the SOURCE before the transfer, so VT converts from a buffer whose colorimetry is
        // stated rather than absent. (The output is re-tagged after, in `deliver` — see there.)
        colorimetry.bufferTags.apply(to: source)

        let status = VTPixelTransferSessionTransferImage(transferSession, from: source, to: destination)
        guard status == noErr else {
            NSLog("[SRT] pixel transfer failed (%d)", status)
            return nil
        }

        if !reportedPromote {
            reportedPromote = true
            NSLog("[SRT] promoting %@ → 'x420' (10-bit 4:2:0) at %dx%d — the shader's sample domain",
                  LiveVideoDecoder.formatName(sourceFormat), width, height)
        }
        return destination
    }

    // MARK: - The packing cushion (Stage 0b-2a)

    /// The largest PES so far asks for `LiveCushion`'s cushion: raise to it if that is more than this
    /// stream holds. SESSION THREAD, from `notePacking`, once per PES; the common case is one compare.
    /// A digital-silence PES is counted like any other — it is the lump that starves.
    private func considerCushion(largestPES: Double) {
        stateLock.lock()
        let current = cushionWanted
        guard let next = LiveCushion.raise(current: current, transportDefault: Self.targetDepth,
                                           largestPES: largestPES) else {
            stateLock.unlock()
            return
        }
        cushionWanted = next
        cushionRaisedForPES = largestPES
        let clock = liveClock
        stateLock.unlock()
        guard let clock else {
            // No route yet (it activates at the first SPS): `activate` builds the clock on this.
            NSLog("[SRT-BUFFER] cushion %.0f → %.0f ms before the display route is up — the clock will "
                + "start on it, no step · the sender packs %.1f ms of audio per PES (largest this "
                + "session) × %.1f + %.0f ms",
                  current * 1000, next * 1000, largestPES * 1000, LiveCushion.packingFactor,
                  LiveCushion.packingMarginSeconds * 1000)
            return
        }
        applyCushion(next, pes: largestPES, clock: clock)
    }

    /// Raise a running route's clock to `cushion`. Any thread.
    ///
    /// Before the anchor `raiseTargetDepth` moves the startup fill with the target (no jump), so the
    /// ledger's anchor cushion follows it. After the anchor it is a re-anchor, and its jump goes to the
    /// ledger exactly as the manual stepper's does — leaving it out would flag OVER on a deliberate
    /// action. Either way the renderer's queue bound grows with the cushion and the readout says so.
    private func applyCushion(_ cushion: Double, pes: Double, clock: LiveClock) {
        let reason = String(format: "the sender packs %.1f ms of audio per PES", pes * 1000)
        guard let change = clock.raiseTargetDepth(to: cushion, reason: reason) else { return }
        let stepped = change.jumped != 0
        if stepped { telemetry.recordClockJump(change.jumped) } else { telemetry.setAnchorCushion(change.to) }
        let bound = Self.queueBound(for: change.to)
        if stepped {
            NSLog("[SRT-BUFFER] cushion %.0f → %.0f ms AFTER the first anchor — now() moved %+.0f ms, one "
                + "target-step (the picture holds once; the audio splice is matched to it) · the sender "
                + "packs %.1f ms of audio per PES (largest this session) × %.1f + %.0f ms · queue bound %d",
                  change.from * 1000, change.to * 1000, change.jumped * 1000, pes * 1000,
                  LiveCushion.packingFactor, LiveCushion.packingMarginSeconds * 1000, bound)
        } else {
            NSLog("[SRT-BUFFER] cushion %.0f → %.0f ms BEFORE the first anchor — the clock starts on it, "
                + "no step · the sender packs %.1f ms of audio per PES (largest this session) × %.1f + %.0f "
                + "ms · queue bound %d",
                  change.from * 1000, change.to * 1000, pes * 1000,
                  LiveCushion.packingFactor, LiveCushion.packingMarginSeconds * 1000, bound)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let stillOurs = self.liveClock === clock
            self.stateLock.unlock()
            guard stillOurs, let renderer = self.renderer else { return }
            renderer.maxQueuedOverride = max(renderer.maxQueuedOverride ?? 0, bound)
            self.publishBufferReadout(stepped: stepped)
        }
    }

    /// SRT's negotiated receive latency, for the readout's "+ SRT 120 ms". MAIN, from SRTClient at
    /// connect, which may be before or after the route activates.
    func noteTransportLatency(ms: Int32) {
        dispatchPrecondition(condition: .onQueue(.main))
        stateLock.lock()
        transportLatencyMs = ms > 0 ? Int(ms) : nil
        stateLock.unlock()
        publishBufferReadout()
    }

    /// The readout's Buffer row for this route, from the clock's live target. MAIN. Silent with no
    /// active route: `deactivate` clears the row itself.
    private func publishBufferReadout(stepped: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        stateLock.lock()
        let clock = liveClock
        let pes = cushionRaisedForPES
        let latency = transportLatencyMs
        stateLock.unlock()
        guard let clock, let renderer else { return }
        let report = LiveCushion.Report(transport: "SRT", cushion: clock.currentTargetDepth,
                                        transportDefault: Self.targetDepth,
                                        transportLatencyMs: latency, raisedForPES: pes)
        LiveBufferReadout.publish(report, renderer: renderer, logPrefix: "SRT", stepped: stepped)
    }

    // MARK: - Runtime target adjustment (⌃⌥[ / ⌃⌥], main thread)

    /// Step the live clock's `targetDepth` by `delta`. The whole point is to A/B several cushion
    /// values inside ONE connection, so the underrun accountant's "cushion needed" figures are
    /// comparable against a moving setpoint rather than requiring a reconnect per value — which
    /// matters more here than it did for WHEP, because 0.250 is an argued starting value and not
    /// yet a measured one.
    ///
    /// The resulting clock jump is fed into the ledger: a target RAISE re-anchors backward, which
    /// is a negative coarse clock action, and leaving it out would trip the residual's OVER flag on
    /// a deliberate keypress.
    /// Whether this router's LiveClock is live. Debug ▸ Force Video Jump asks each push router.
    var hasLiveClock: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return liveClock != nil
    }

    func adjustTargetDepth(by delta: Double) {
        dispatchPrecondition(condition: .onQueue(.main))
        stateLock.lock()
        let clock = liveClock
        stateLock.unlock()
        guard let clock else {
            NSLog("[SRT] no live SRT session — ⌃⌥[ / ⌃⌥] adjust the active push source's target only")
            return
        }
        guard let change = clock.adjustTargetDepth(by: delta) else {
            NSLog("[SRT] targetDepth already at the %@ (%.3fs) — not stepped",
                  delta > 0 ? "ceiling" : "floor", clock.currentTargetDepth)
            return
        }
        telemetry.recordClockJump(change.jumped)
        publishBufferReadout(stepped: true)
    }

    // MARK: - Latency-control reporting (render thread, coarse actions only)

    /// One line per coarse clock action. These are RARE and each one is a real event in the
    /// session's latency story, so they are logged unconditionally rather than folded into the
    /// 1 Hz flow line.
    private static func log(_ event: LiveClock.Event) {
        #if DEBUG || MANIFOLD_TELEMETRY
        switch event {
        case .snapped(let snap):
            NSLog("[SRT] snap-to-live: flushed %.3fs excess (depth %.3f → %.3f) after %.2fs sustained overfill",
                  snap.excess, snap.depthBefore, snap.depthAfter, snap.sustainedFor)
        case .freezeGuard(let fg):
            NSLog("""
                  [SRT] FREEZE-GUARD: clock had fallen behind the entire queue — no eligible \
                  frame for %d ticks / %.3fs with %d queued (oldest +%.3fs ahead). Re-anchored \
                  +%.3fs (depth %.3f → %.3f).
                  """, fg.ticks, fg.heldFor, fg.queued, fg.oldestAhead,
                  fg.jumped, fg.depthBefore, fg.target)
        case .overflowReanchor(let ov):
            NSLog("[SRT] queue-full re-anchor: over-buffered at count=%d — flushed %.3fs (depth %.3f → %.3f)",
                  ov.queued, ov.jumped, ov.depthBefore, ov.target)
        case .startupRealign(let sr):
            // Before the first presentation only — the anchor's offset removed by position rather
            // than by 20+ s of rail. One to a few per connect. See LiveClock's startup-fill block.
            NSLog("[SRT] startup realign: moved %+.1f ms (depth %.4f → %.3f), before first presentation",
                  sr.jumped * 1e3, sr.depthBefore, sr.target)
        }
        #endif
    }

    // MARK: - Helpers

    /// Wrap a pixel buffer in a ready CMSampleBuffer at `pts`. Same three CoreMedia calls as the
    /// other live sources, and deliberately NOT unified with them — the arguments differ in ways
    /// that are not cosmetic (timescale, duration, allocator), and those PTS values feed the
    /// renderer's ordered insert and its median inter-frame-Δ tracking, i.e. the depth signal
    /// LiveClock regulates. See the same note on WHEPFrameRouter.makeSampleBuffer.
    ///
    /// DTS is .invalid, and NOT because the sender has no B-frames — this stream very well may.
    /// By this point there is no decode order left to describe: the input was a compressed access
    /// unit whose DTS said when to DECODE it, and what is being wrapped here is the decoded picture
    /// that came out. Its only remaining property is when to SHOW it, which is the PTS.
    private static func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }

    /// 1 Hz `[SRT-FLOW]`. The staged-diagnosis line: if no pixels appear, it says WHICH stage is
    /// empty. AUs climbing with delivered at zero puts the problem in the decoder (which logs
    /// under its own — WHEP-prefixed — tag). delivered > 0 with enqueued == 0 means the promote or
    /// the sample build is failing. Both climbing with depth/count at zero means frames reach the
    /// queue but the clock never lets them come due.
    ///
    /// `reorder` is on this line rather than only in the warning because it is the number
    /// `targetDepth` is required to exceed, and it should be readable at a glance next to the depth
    /// it is being compared against. Session thread only.
    private func logFlowIfDue() {
        #if DEBUG || MANIFOLD_TELEMETRY
        let now = CACurrentMediaTime()
        if lastFlowLogHost == 0 { lastFlowLogHost = now; lastFlowLogEnqueued = framesEnqueued; return }
        let elapsed = now - lastFlowLogHost
        guard elapsed >= 1.0 else { return }
        let rate = Double(framesEnqueued - lastFlowLogEnqueued) / elapsed
        lastFlowLogHost = now
        lastFlowLogEnqueued = framesEnqueued

        stateLock.lock(); let clockRate = liveClock?.rate; stateLock.unlock()
        NSLog("""
              [SRT-FLOW] enqueued=%.1f/s (total=%d, delivered=%d, AUs=%d, noPTS=%d, promoteFail=%d) \
              | depth=%.3fs count=%d rate=%@ | reorder max=%.3fs (budget %.3fs)
              """,
              rate, framesEnqueued, framesDelivered, accessUnitsReceived, accessUnitsWithoutPTS,
              promoteFailures, lastDepthSpan, lastDepthCount,
              clockRate.map { String(format: "%.4f", $0) } ?? "inactive",
              reorderMaxSeconds, Self.targetDepth)
        #endif
    }
}
