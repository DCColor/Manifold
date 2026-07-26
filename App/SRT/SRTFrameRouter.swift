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
//    * WHEPVideoDecoder   — used AS-IS. It already takes `pts`/`dts` as CMTime (stage 3b) and is
//                           documented as transport-agnostic; it has no RTP in it.
//                           ⚠️ ITS NAME AND ITS `[WHEP-DECODE]` LOG PREFIX ARE NOW WRONG on this
//                           path. Renaming it is deliberately NOT part of this stage — see the
//                           note above `decoder` below.
//    * the promote        — VTPixelTransferSession into a pooled x420 buffer, the shape NDIService
//                           and WHEPFrameRouter both use to reach the shader's 10-bit domain.
//
//  Genuinely new: reading the stream's declared colorimetry instead of assuming it, and measuring
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
//      decoder" rule WHEPVideoDecoder requires, satisfied without a queue or a handoff.
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
    // Exactly as WHEP's was, with the same instrument: ⌃⌥[ / ⌃⌥] step the live target by ±0.05 s
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
    // ── THE THREE-STATE HONESTY, WHICH IS THE WHOLE REASON THIS IS READ AND NOT ASSUMED ─────
    //
    // WHEP passes `.assumedRec709SDR` because H.264 signals colorimetry in the SPS VUI and its RTP
    // depacketizer does not parse it — a limitation of that transport, stated at that transport's
    // config site precisely so nothing shared would bake it in. SRT reaches libavformat, which
    // fills `codecpar->color_primaries` / `color_trc` / `color_space` / `color_range` from the same
    // VUI, so this path CAN state the truth. Stating it means being able to say "the sender said
    // nothing" as a distinct answer from "the sender said 709" — the same distinction NDIColorInfo
    // keeps with `declared` vs `assumed`, and for the same reason: A DEFAULT IS NOT A FACT.
    //
    // AND THE COMMON CASE IS "NOTHING". The stage-2 spike measured a real OBS→SRT feed and found
    // every axis UNSPECIFIED (CICP 2 for primaries/transfer/matrix, 0 for range). So the undeclared
    // branch is the normal one, not the exception, and it must not launder itself into a confident
    // Rec.709 anywhere a human reads it.
    //
    // WHERE THE DISTINCTION ACTUALLY LANDS, in all three places it can:
    //
    //   1. THE RENDERER'S SHADER + LAYER COLORSPACE — `LiveDisplayRoute.Colorimetry` takes
    //      `Int?` per axis, where nil means "unspecified, use your own default". An UNDECLARED
    //      axis is passed as nil, NOT as 1. Both produce the same picture (the renderer's default
    //      is 709), so this is not a display change — it is what makes the CIE scope's header read
    //      "untagged → 709 (assumed)" instead of a confident "Rec.709", because that header keys
    //      off `renderer.sourcePrimariesCode` being nil.
    //
    //   2. THE PIXEL-BUFFER ATTACHMENTS — these cannot be nil. Something must be stamped or the
    //      downstream consumers (shader matrix, layer colorspace, scopes, EDR gate) have nothing
    //      to read. So an undeclared axis is tagged 709 AND recorded as assumed, which is exactly
    //      what NDIColorInfo already does and why this file reuses it rather than inventing a
    //      second CICP vocabulary. (That type's NDI-prefixed name is now wrong — WHEPFrameRouter
    //      already uses it too. Renaming it is a separate, mechanical pass.)
    //
    //   3. THE LOG — one line per connect, saying per axis whether it was declared or assumed,
    //      in the same words NDIColorInfo.summary uses.

    /// One axis: the CICP code the pipeline consumes, and whether the STREAM said so.
    struct ColorAxis: Equatable {
        let code: Int
        let declared: Bool
        /// nil when assumed — which is what `LiveDisplayRoute.Colorimetry` wants for "unspecified".
        var codeIfDeclared: Int? { declared ? code : nil }
    }

    /// What the chosen video stream declared, axis by axis.
    /// Equatable so SRTClient can publish it and SwiftUI can key an `.onChange` off it, exactly as
    /// ContentView already does with `NDIService.colorInfo`.
    struct StreamColorimetry: Equatable {
        let primaries: ColorAxis
        let transfer: ColorAxis
        let matrix: ColorAxis
        /// Range is a SEPARATE axis from colorimetry — legal/video vs full swing.
        let isFullRange: Bool
        let rangeDeclared: Bool

        /// CICP "unspecified" is 2 for primaries/transfer/matrix. A 0 there is RESERVED, not
        /// unspecified, and is treated as undeclared too — a reserved value is not a statement.
        private static func axis(_ cicp: Int32, assuming fallback: Int) -> ColorAxis {
            let code = Int(cicp)
            let declared = code != 2 && code != 0
            return ColorAxis(code: declared ? code : fallback, declared: declared)
        }

        /// AVColorRange: 0 unspecified, 1 MPEG/limited, 2 JPEG/full.
        /// UNDECLARED ASSUMES LIMITED, and that is the right assumption rather than a coin toss:
        /// H.264 in MPEG-TS with no `video_full_range_flag` IS limited range by the standard's own
        /// default, and it is what WHEP pins for the same content.
        init(_ format: ManifoldSRTVideoFormat) {
            primaries = Self.axis(format.colorPrimaries, assuming: 1)
            transfer  = Self.axis(format.colorTransfer,  assuming: 1)
            matrix    = Self.axis(format.colorMatrix,    assuming: 1)
            rangeDeclared = format.colorRange != 0
            isFullRange = format.colorRange == 2
        }

        /// What the renderer is told. Undeclared axes go through as nil — see point 1 above.
        var routeColorimetry: LiveDisplayRoute.Colorimetry {
            LiveDisplayRoute.Colorimetry(primaries: primaries.codeIfDeclared,
                                         transfer: transfer.codeIfDeclared,
                                         matrix: matrix.codeIfDeclared,
                                         isFullRange: isFullRange)
        }

        /// What gets stamped on every pixel buffer. Cannot be nil — see point 2 above. Reuses
        /// NDIColorInfo's provenance vocabulary so an assumed axis reads "(assumed)" in a log line
        /// identically to an untagged NDI source's.
        var bufferTags: NDIColorInfo {
            func axis(_ a: ColorAxis, _ name: String) -> NDIColorAxis {
                a.declared ? .declaredValue(a.code, name) : .assumed(a.code)
            }
            return NDIColorInfo(
                primaries: axis(primaries, NDIColorInfo.primariesName(primaries.code)),
                transfer:  axis(transfer,  NDIColorInfo.transferName(transfer.code)),
                matrix:    axis(matrix,    NDIColorInfo.matrixName(matrix.code)))
        }

        /// The connect line. Says "undeclared" in words rather than printing a number that looks
        /// like the sender's statement.
        var summary: String {
            func axis(_ label: String, _ a: ColorAxis, _ name: String) -> String {
                a.declared ? "\(label)=\(name) (declared, code \(a.code))"
                           : "\(label)=UNDECLARED → assuming \(name)"
            }
            let range = rangeDeclared
                ? (isFullRange ? "range=full (declared)" : "range=limited (declared)")
                : "range=UNDECLARED → assuming limited"
            return axis("primaries", primaries, NDIColorInfo.primariesName(primaries.code)) + "  "
                 + axis("transfer", transfer, NDIColorInfo.transferName(transfer.code)) + "  "
                 + axis("matrix", matrix, NDIColorInfo.matrixName(matrix.code)) + "  " + range
        }
    }

    // MARK: - The route's per-source configuration

    private static func routeConfig(colorimetry: StreamColorimetry) -> LiveDisplayRoute.Config {
        LiveDisplayRoute.Config(
            targetDepth: targetDepth,

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
            maxQueued: 30,

            colorimetry: colorimetry.routeColorimetry)
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

    /// What the stream declared, latched at onVideoFormat and read on both threads for the buffer
    /// tags. Written once on the session thread before any access unit can arrive, read on that
    /// same thread thereafter — no lock, same discipline as `currentSPS` in the decoder.
    private var colorimetry = StreamColorimetry(ManifoldSRTVideoFormat())

    // MARK: - Decode + promote state (SESSION THREAD only)

    /// ⚠️ NAME AND LOG PREFIX ARE WRONG ON THIS PATH, AND DELIBERATELY LEFT THAT WAY.
    ///
    /// WHEPVideoDecoder is transport-agnostic — stage 3b gave it `pts`/`dts` as CMTime specifically
    /// so one signature would serve both, and there is no RTP in it. What is still WHEP-shaped is
    /// its NAME and its `[WHEP-DECODE]` log prefix, which means an SRT session's log carries
    /// `[WHEP-DECODE]` lines. That is confusing and it is the one visible wart in this stage.
    ///
    /// NOT FIXED HERE ON PURPOSE: the fix is a rename plus a `logTag` init parameter, it touches
    /// WHEPClient and every `[WHEP-DECODE]` line, and doing it inside a stage whose job is "first
    /// picture on screen" would make this diff unreviewable. This file's own `[SRT-FLOW]` and
    /// `[SRT-AU]` lines carry enough for the SRT path to be diagnosed without reading the
    /// mislabelled ones.
    private var decoder: WHEPVideoDecoder?

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
    /// nothing about its Config depends on the stream: the colorimetry is assumed. SRT's Config
    /// CANNOT be built that early — it carries the stream's declared colorimetry, and that is not
    /// knowable until `avformat_find_stream_info` has run, which is up to 3 s of connect plus up to
    /// 5 s of analysis away.
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

    /// SRT takes the display. Called from SRTClient once the demuxer has identified the video
    /// stream — LATER than WHEP's equivalent, and necessarily so: the colorimetry that goes into
    /// the Config is not knowable until `avformat_find_stream_info` has run.
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

        let config = Self.routeConfig(colorimetry: colorimetry)
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

        stateLock.lock(); liveClock = clock; stateLock.unlock()

        NSLog("[SRT] display route ACTIVE — LiveClock target=%.3fs, maxQueued=%d",
              Self.targetDepth, config.maxQueued)
        NSLog("[SRT] colorimetry: %@", colorimetry.summary)
        // The reorder budget, stated at connect so the number the runtime check is measuring
        // against is in the log next to the stream it applies to.
        NSLog("""
              [SRT] reorder budget: targetDepth %.3fs must exceed max(pts − dts). Header claims \
              video_delay=%d (a claim only, often absent) — [SRT-AU] reports the measured value.
              """, Self.targetDepth, format.videoDelay)
    }

    /// SRT releases the display. Restores the file-path providers verbatim so playback can resume,
    /// and wipes the last streamed frame. Idempotent-safe.
    func deactivate() {
        dispatchPrecondition(condition: .onQueue(.main))
        stateLock.lock()
        let wasActive = liveClock != nil
        // Clears the clock's per-STREAM state, freeze-guard arming included, so a reconnect
        // re-disarms the guard for its own startup fill rather than tripping it.
        liveClock?.reset()
        liveClock = nil
        stateLock.unlock()
        guard wasActive else { return }

        route.deactivate(renderer: renderer)
        NSLog("[SRT] display route released — file-playback clock restored")
    }

    // MARK: - Session-thread lifecycle

    /// Build the decoder and wire it to `deliver`. SESSION THREAD, from onVideoFormat — the same
    /// thread that will call `decode`, which is what WHEPVideoDecoder's "one thread owns the
    /// session" rule requires.
    func prepareDecoder(format: ManifoldSRTVideoFormat, colorimetry: StreamColorimetry) {
        self.colorimetry = colorimetry
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

        let decoder = WHEPVideoDecoder()
        decoder.onDecodedFrame = { [weak self] pixelBuffer, pts in
            self?.deliver(pixelBuffer, pts: pts)
        }
        // ── NO PLI, AND NOTHING TO PUT IN ITS PLACE ─────────────────────────────────────────
        // WHEP wires this to `session.requestKeyframe()`. SRT has no back-channel: it is a
        // one-way media transport with no RTCP and no picture-loss indication, so there is
        // nobody to ask. Recovery means WAITING OUT THE SENDER'S GOP — ~2 s on OBS defaults,
        // longer on a 5 s or 10 s keyframe interval. Counted and logged so a freeze has a stated
        // cause and an expected duration, rather than being wired to a no-op that reads as if a
        // request went out.
        decoder.onNeedsKeyframe = { [weak self] in self?.noteKeyframeWait() }
        self.decoder = decoder
    }

    /// Release everything the session thread owns. SESSION THREAD, from onEnded — the last instant
    /// at which that thread is both alive and guaranteed idle, which is why the C layer fires
    /// onEnded before signalling its join rather than after.
    func releaseSessionResources() {
        decoder?.invalidate()
        decoder = nil
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
    /// IT DOES NOT TOUCH THE DEPTH. Deliberately: raising `targetDepth` automatically would trade
    /// the user's latency away on the router's own initiative, silently, on evidence that could be
    /// one malformed packet. The measurement is reported; the decision stays with the user, who has
    /// ⌃⌥] to act on it.
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
                      landing behind the renderer's swept position and being DISCARDED. Raise the \
                      target with ⌃⌥] until this clears; the requirement is \
                      targetDepth > max(pts − dts). Header claimed video_delay=%d.
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
              The picture holds until the sender's next keyframe (≈2s on OBS defaults, longer on a \
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
    /// Host time of the previous DELIVERED frame, or nil when none has been delivered yet.
    private var lastArrivalHost: CFTimeInterval?
    private var deferralBeganHost: CFTimeInterval = 0
    private var deferralFirstPTS: Double = 0
    private var deferredFrames = 0

    /// Called from `deliver` for every frame until the anchor is taken. Returns the presentation PTS.
    ///
    /// SESSION THREAD, and every field it touches is session-thread-owned — the same ownership
    /// `framesDelivered` and the promote state already have.
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

        guard let promoted = promoteIfNeeded(decoded) else {
            promoteFailures += 1
            logFlowIfDue()
            return
        }
        // Tag the buffer every downstream consumer actually reads (shader matrix, layer colorspace,
        // scopes, EDR gate). A pooled buffer starts untagged and VT's attachment propagation is
        // measured behavior rather than a documented contract, so tagging the OUTPUT last is the
        // ordering that holds either way — NDIService.tagOutput's reasoning, verbatim. What is
        // stamped is the stream's DECLARED colorimetry where it declared any, and 709 where it did
        // not; the provenance of that choice was stated once at connect.
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
                      WHEPVideoDecoder.formatName(sourceFormat))
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
                  WHEPVideoDecoder.formatName(sourceFormat), width, height)
        }
        return destination
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
