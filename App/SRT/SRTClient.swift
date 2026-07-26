//
//  SRTClient.swift
//  Manifold
//
//  SRT client — the transport lifecycle, and the ObservableObject the UI reads.
//
//  SHIPS IN RELEASE. The functional path (connect/disconnect, the URL parse, the passphrase, the
//  media-stall watchdog, the first-picture grace) is compiled in every configuration. Only the
//  [SRT-*] rollups stay behind `#if DEBUG || MANIFOLD_TELEMETRY`. There is no `#ifdef DEBUG` around
//  any of this — the stage-2 spike was debug-only and has been deleted; this replaces it.
//
//  ── DIVISION OF LABOUR ─────────────────────────────────────────────────────────────────
//
//  This file is WHEPClient's opposite number and is deliberately shaped like it:
//
//    * HERE:              the URL (scheme, host, port, passphrase), the session lifecycle, the
//                         published `isConnected` / `lastError`, the watchdogs, the 1 Hz rollups.
//    * ManifoldSRTSession (pure C): libsrt caller socket → AVIOContext → mpegts demux, on its own
//                         thread. This file never sees an <srt/*> or <libav*/*> type.
//    * SRTFrameRouter:    everything downstream of an access unit — decode, promote, LiveClock,
//                         the display route. It owns what runs on the session thread.
//
//  Caller only: srt_startup, srt_create_socket, srt_connect. No listener, no rendezvous. Those are
//  different lifecycles (a listener has N peers and no connect failure to report) and adding them
//  means a second mode here, not a flag.
//
//  ── PASSPHRASE REDACTION ───────────────────────────────────────────────────────────────
//
//  Same rule the WHEP endpoint path has: the value never reaches a log, a `lastError`, or any
//  user-visible string. It is lifted out of the query, handed to the C layer, and wiped there the
//  moment libsrt has derived its key material. The only encryption fact that ever surfaces is
//  SRTO_KMSTATE — whether the link is encrypted, never what with.
//
//  ── THREADING ──────────────────────────────────────────────────────────────────────────
//
//  Every method here is MAIN THREAD ONLY and asserts it, which is what `@Published` requires. The
//  C callbacks arrive on the session thread; each one either does session-thread work (the access
//  unit, the decode-side teardown) or hops to main, and the hop is marked at every site.
//

import Combine
import Foundation
import QuartzCore      // CACurrentMediaTime — the monotonic host clock the watchdogs measure on

final class SRTClient: ObservableObject {

    static let shared = SRTClient()
    private init() {}

    /// Published connection state — the SRT analog of NDIService.isConnected and
    /// WHEPClient.isConnected, and the only cross-module signal that SRT is a live source.
    /// ContentView folds it into `hasSource` so the empty-state overlay hides while SRT drives the
    /// shared renderer, and `LiveSource.srt` reads it for arbitration.
    ///
    /// SET TRUE AT `connect()`, BEFORE THE HANDSHAKE, and the reasoning is WHEP's: by that point we
    /// have already retired whatever was driving the renderer and blacked it, so publishing false
    /// until the transport comes up would flash the "Open… to begin" empty state over our own black
    /// takeover screen. Cleared by disconnect() and by every session-end path, so it cannot stick.
    @Published private(set) var isConnected = false

    /// User-facing connection error, published so the UI can surface a failed connect without the
    /// user reading the Xcode log.
    ///
    /// CARRIES LIBSRT'S OWN MESSAGE where there is one, which is the same choice WHEP makes with a
    /// server's response body: `srt_strerror` and `srt_rejectreason_str` know things our generics
    /// do not ("Connection rejected: bad secret" is the whole diagnosis for a wrong passphrase),
    /// they are short and in English, and they contain nothing secret. REDACTION HOLDS: never the
    /// passphrase, never the full URL — host and port at most, which is what the user typed.
    /// Cleared at the start of a fresh connect() and on the first decoded picture.
    @Published private(set) var lastError: String?

    /// Dismiss a shown connection error (the banner's close button).
    func clearError() { lastError = nil; lastErrorSurvivesPictures = false }

    /// ── WHY A BANNER NEEDS TO SAY WHETHER A PICTURE DISPROVES IT ────────────────────────
    ///
    /// The 1 Hz tick treats "a picture arrived" as the definitive success signal and retires the
    /// banner — correct for every message ABOUT NOT HAVING A PICTURE (still probing, waiting for a
    /// keyframe, nothing arriving). It is WRONG for the two messages that are true precisely WHILE
    /// pictures flow:
    ///
    ///   * the reorder shortfall — frames are arriving AND some are being discarded;
    ///   * the already-connected refusal — the refusal happened BECAUSE a stream is running, so a
    ///     picture is not evidence against it. Without this the second ⌃⌥D would flash a banner for
    ///     under a second and vanish, which reads as a glitch rather than as an answer.
    ///
    /// So every message says which kind it is. Set through `showError`; never assigned directly,
    /// or the flag and the message drift apart.
    private var lastErrorSurvivesPictures = false

    /// The one place `lastError` is set. `survivesPictures` defaults to false because the common
    /// case is a message a picture genuinely disproves.
    private func showError(_ message: String, survivesPictures: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        lastError = message
        lastErrorSurvivesPictures = survivesPictures
    }

    /// Retire the banner without the user dismissing it — a new attempt, a phase completing, or a
    /// picture arriving. No-op when nothing is showing, so it is safe on a 1 Hz path: `@Published`
    /// fires objectWillChange on every write, nil-to-nil included, and an unguarded assignment
    /// would re-render the view once a second for the life of the session.
    private func retireError() {
        guard lastError != nil else { return }
        lastError = nil
        lastErrorSurvivesPictures = false
    }

    /// What the stream declared about its colour, published for the SCOPES.
    ///
    /// The shader, the layer colorspace and the scope KERNELS all get this through the pixel
    /// buffer's CICP attachments and the renderer's per-source codes, with no help from the UI. The
    /// scope HEADERS and the waveform/parade auto vertical scale do NOT read the buffer — they read
    /// ContentView's scope models. So an SRT source needs the same wiring NDI already has, from the
    /// same codes, or the scopes would do PQ math under a "Rec.709" label on a stream that declared
    /// PQ. nil while nothing is streaming.
    @Published private(set) var colorimetry: SRTFrameRouter.StreamColorimetry?

    // MARK: - State (main thread)

    private var session: OpaquePointer?
    private var startedAt: Date?
    private var statsTimer: Timer?
    private var statsTicks = 0

    /// Media-stall watchdog — the SAME fault WHEP's 15 s watchdog covers, and SRT can genuinely
    /// hit it: the link is healthy and TS packets keep arriving (PAT/PMT, null padding, an audio
    /// PID) while the video encoder has stopped. libsrt's own SRTO_PEERIDLETIMEO does NOT fire —
    /// bytes are flowing — so without this the picture freezes with `isConnected` stuck true.
    ///
    /// 15 s, matching WHEP, and the margin matters here for a reason WHEP did not have: a decode
    /// error on this transport is recovered by WAITING OUT THE SENDER'S GOP, because SRT has no
    /// PLI. That wait is ~2 s on OBS defaults and can be 10 s on a long keyframe interval, and it
    /// must NOT be mistaken for a dead stream. 15 s clears the common cases with room; a sender
    /// running a keyframe interval longer than that would need this raised, and the
    /// `[SRT-AU] waiting for an IDR` line is what would say so.
    private static let mediaStallWindow: TimeInterval = 15
    private var watchdogLastPictures = 0
    private var watchdogSinceHost: CFTimeInterval = 0

    // ── TWO GRACE PERIODS, BECAUSE THERE ARE TWO DIFFERENT SILENCES ────────────────────────
    //
    // A connect that legitimately shows black passes through two distinct phases, and a banner that
    // named the wrong one would be worse than no banner:
    //
    //   PHASE 1 — CONNECTED, NOT YET IDENTIFIED. The transport is up and `avformat_open_input` /
    //     `avformat_find_stream_info` are running inside the session thread's read callback. If the
    //     publisher is silent this phase NEVER ENDS: `max_analyze_duration` bounds the analysis of
    //     data that arrived, not the wait for data that never does, so the read callback loops on
    //     SRTO_RCVTIMEO indefinitely. From outside it is indistinguishable from a hang.
    //
    //   PHASE 2 — IDENTIFIED, NO PICTURE YET. The video stream is known and access units may be
    //     arriving, but a decoder cannot start on a P-frame and there is no PLI to hurry an IDR
    //     along. ~2 s on OBS defaults; up to 10 s on a long keyframe interval.
    //
    // THE PHASE-2 GRACE ARMS AT IDENTIFICATION, NOT AT CONNECT, and that is the whole reason there
    // are two. Armed at connect, a slow probe would spend its own seconds on phase 2's clock and
    // produce "no video is arriving" while the probe was still running — a banner asserting
    // something nobody had yet checked.

    /// PHASE 1. Shorter than the phase-2 grace because there is less to legitimately wait for:
    /// identification needs bytes, and bytes either flow or they do not.
    private static let probeGrace: TimeInterval = 8
    /// PHASE 2. LONGER THAN THE COMMON GOP ON PURPOSE — 12 s clears a 10 s keyframe interval.
    private static let firstPictureGrace: TimeInterval = 12

    /// Neither grace is a teardown. Nothing is stopped, the session keeps running, and the message
    /// is retired the instant the next phase begins or a picture lands.
    private var announcedProbeWait = false
    private var announcedFirstPictureWait = false
    /// Host time the transport came up (phase 1's origin) and the host time the video stream was
    /// identified (phase 2's). Zero until that phase begins, which is also how each check knows
    /// whether it applies yet.
    private var connectedAtHost: CFTimeInterval = 0
    private var videoIdentifiedAtHost: CFTimeInterval = 0
    private var haveConnected = false
    private var haveVideoStream = false

    /// Announced once per stream: the reorder budget is too shallow for what is arriving.
    private var announcedReorderShortfall = false

    /// Below this the transport buffer is doing little for us — a LAN sender, or one explicitly
    /// configured for minimum latency. libsrt's live default is 120 ms; OBS ships the same.
    private static let thinTransportLatency: TimeInterval = 0.050
    /// Above `cushion × this`, the transport is holding so much that our own cushion is mostly
    /// redundant latency.
    private static let largeTransportLatencyFactor: Double = 3

    private func elapsed() -> String {
        guard let startedAt else { return "?" }
        return String(format: "%.2fs", Date().timeIntervalSince(startedAt))
    }

    // MARK: - URL

    /// What a `srt://` URL means to us. Strict: anything unparseable fails loudly at the door
    /// rather than being half-understood three layers down.
    struct Endpoint {
        let host: String
        let port: Int
        /// SRTO_PASSPHRASE, or nil. ⚠️ Never log, never interpolate into a user-visible string.
        let passphrase: String?
        /// Query keys present that we do NOT act on. Reported, never ignored silently — a
        /// `streamid` that quietly went nowhere would surface as an unexplained server rejection.
        let unhandledParameters: [String]

        /// SRT's own limits on a passphrase: 10–79 characters. Checked here so the failure names
        /// the rule at the moment the user's input is read, instead of arriving as a libsrt errno.
        static let passphraseLengthRange = 10...79
    }

    /// Why a `srt://` URL was refused — distinct cases with the text ON THE TYPE, which is the
    /// shape `StreamValidationError` (Preferences.swift) and `LicenseVerifyError` already use.
    ///
    /// A NAMED TYPE RATHER THAN THE BARE MESSAGE, because `Result`'s failure must conform to
    /// `Error` and `String` does not. The one-line alternative — `extension String: Error` — would
    /// make every string in the app throwable to buy this one signature.
    enum ParseError: Error {
        case notAnSRTURL
        case noHost
        case noPort
        /// ⚠️ NO ASSOCIATED VALUE, DELIBERATELY — see the check in `parse`. Nothing derived from
        /// the passphrase, its length above all, may ride out of that scope, and a case that
        /// cannot carry anything enforces that better than a rule about what to interpolate.
        case passphraseLength

        /// User-facing: reaches both `lastError` and NSLog. Contains at most what the user typed,
        /// and never the passphrase.
        var message: String {
            switch self {
            case .notAnSRTURL: return "That isn’t an SRT stream URL."
            case .noHost:      return "That SRT address has no host."
            case .noPort:      return "An SRT address needs a port — srt://host:port."
            case .passphraseLength:
                // STATES THE RULE, AND THE SECRET IS NOT IN SCOPE HERE TO MEASURE. The rule is
                // also the part that tells the user what to do about it.
                return "That stream passphrase isn’t the right length; "
                     + "SRT requires 10 to 79 characters."
            }
        }
    }

    /// Parse, or explain why not. The message is user-facing and contains at most the host.
    static func parse(_ url: URL) -> Result<Endpoint, ParseError> {
        guard url.scheme?.lowercased() == "srt" else {
            return .failure(.notAnSRTURL)
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty else {
            return .failure(.noHost)
        }
        // NO DEFAULT PORT. SRT has no registered one, and inventing 9000 (or OBS's habit) would
        // dial somewhere the user did not ask for and time out with a misleading "nothing
        // answered".
        guard let port = components.port, port > 0, port <= 65535 else {
            return .failure(.noPort)
        }

        let items = components.queryItems ?? []
        var passphrase: String?
        var unhandled: [String] = []
        for item in items {
            switch item.name.lowercased() {
            case "passphrase":
                let value = item.value ?? ""
                guard !value.isEmpty else { continue }
                guard Endpoint.passphraseLengthRange.contains(value.count) else {
                    // ⚠️ THE ONLY SCOPE IN THE SRT PATH THAT HOLDS THE PLAINTEXT IN A POSITION TO
                    // DESCRIBE IT. `value.count` is right here, and the failure that leaves this
                    // scope must not carry it: the message reaches BOTH `lastError` (a banner
                    // someone may be screen-sharing) and NSLog, so a length interpolated here is
                    // disclosed to anyone reading either. Length is weak metadata, but it is
                    // metadata derived from the secret and it buys the user nothing — they can
                    // count their own input, and the rule is what tells them what to do. Hence a
                    // valueless case: the wording lives on `ParseError` where no secret is in
                    // scope, and nothing measured here can follow it out. Keep it that way.
                    return .failure(.passphraseLength)
                }
                passphrase = value
            case "mode" where (item.value ?? "").lowercased() == "caller":
                break   // what we already are; nothing to do
            default:
                unhandled.append(item.name)
            }
        }
        return .success(Endpoint(host: host, port: port, passphrase: passphrase,
                                 unhandledParameters: unhandled))
    }

    // MARK: - Connect

    func connect(to url: URL) {
        dispatchPrecondition(condition: .onQueue(.main))

        guard session == nil else {
            // VISIBLE, not just logged. This used to return after an NSLog, so from the user's
            // side the second connect did nothing at all: no picture change, no message, no
            // indication the request had even been received. A refusal the user cannot see is
            // indistinguishable from a bug.
            //
            // A REFUSAL, NOT A QUEUE AND NOT A SWAP. Auto-swapping would mean tearing down a live
            // session — including a main-thread join of up to one SRTO_RCVTIMEO period — on the
            // strength of a second click, and deciding what happens if the new URL then fails to
            // connect (the user has lost the stream they had). That is a real design question and
            // it belongs with 3e, where the bookmark UI makes stream-to-stream switching a first
            // -class action. WHEPClient.connect has the identical guard and the identical gap; both
            // should be answered in the same pass.
            NSLog("[SRT] a session is already running — disconnect it first")
            showError("An SRT stream is already connected — disconnect it before connecting another.",
                      survivesPictures: true)
            return
        }
        retireError()   // fresh attempt — clear any banner from a previous try

        let endpoint: Endpoint
        switch Self.parse(url) {
        case .success(let parsed): endpoint = parsed
        case .failure(let error):
            NSLog("[SRT] refusing to connect — %@", error.message)
            showError(error.message)
            return
        }

        startedAt = Date()
        NSLog("[SRT] ───── connecting to %@:%d ─────", endpoint.host, endpoint.port)
        if endpoint.passphrase != nil {
            // Presence only. Never the value, never its length in a log line.
            NSLog("[SRT] a passphrase was supplied (value withheld)")
        }
        if !endpoint.unhandledParameters.isEmpty {
            // LOUD, because the failure mode of ignoring these is a server rejection with no
            // obvious cause. `streamid` in particular is how most hosted SRT ingests route a
            // publisher, and it is NOT implemented in this stage — see the stage note in
            // SRTSession.h. Named so the gap is visible rather than mysterious.
            NSLog("""
                  [SRT] ⚠️ ignoring URL parameter(s): %@. Only `passphrase` is acted on in this \
                  build — a stream that needs `streamid` or a non-default `latency` will not \
                  connect, and the server's rejection will not say why.
                  """, endpoint.unhandledParameters.joined(separator: ", "))
        }

        // TAKE THE DISPLAY NOW, not when the first picture arrives. The route itself cannot be
        // activated until the demuxer has told us the stream's colorimetry (see
        // SRTFrameRouter.activate), and that is up to 3 s of connect plus up to 5 s of analysis
        // away. Leaving a loaded file playing across that window would show the user the OLD
        // source after they asked for a new one, and would put two producers on the renderer the
        // moment SRT did take over. So the file is retired and the screen blacked here, and the
        // route lands on a display that is already ours.
        SRTFrameRouter.shared.beginTakeover()
        isConnected = true
        haveConnected = false
        haveVideoStream = false
        startStatsTimer()   // also clears every per-stream announce latch — see there

        // UNRETAINED CONTEXT, and safe for the same reason WHEPVideoDecoder's output-callback
        // refcon is: this is a process-lifetime singleton, and the C session is joined in
        // disconnect() before anything is released, so no callback can outlive its target.
        let context = Unmanaged.passUnretained(self).toOpaque()
        var callbacks = ManifoldSRTSessionCallbacks(
            context: context,
            // ── SESSION THREAD ──────────────────────────────────────────────────────────
            onConnected: { ctx, info in
                guard let ctx, let info else { return }
                let client = Unmanaged<SRTClient>.fromOpaque(ctx).takeUnretainedValue()
                let latency = info.pointee.negotiatedLatencyMs
                DispatchQueue.main.async { client.handleConnected(negotiatedLatencyMs: latency) }
            },
            // ── SESSION THREAD. Two halves, and the split is load-bearing. ──────────────
            // The DECODER must be built on this thread (it is single-thread-owned, and this is
            // the thread that will call decode). The DISPLAY ROUTE must be activated on main
            // (it repoints the renderer's providers). So the format lands here, prepares the
            // decode side synchronously, and hops for the display side. Access units cannot
            // arrive before this returns — the C layer emits onVideoFormat before the first
            // one — so the decoder is always ready in time. The route may be a few milliseconds
            // behind, which `deliver` already tolerates by dropping frames with no clock.
            onVideoFormat: { ctx, format in
                guard let ctx, let format else { return }
                let client = Unmanaged<SRTClient>.fromOpaque(ctx).takeUnretainedValue()
                let f = format.pointee
                let colorimetry = SRTFrameRouter.StreamColorimetry(f)
                SRTFrameRouter.shared.prepareDecoder(format: f, colorimetry: colorimetry)
                DispatchQueue.main.async { client.handleVideoFormat(f, colorimetry: colorimetry) }
            },
            // ── SESSION THREAD, inline, per access unit. No hop: this is the hot path. ──
            onAccessUnit: { _, accessUnit in
                guard let accessUnit else { return }
                SRTFrameRouter.shared.handleAccessUnit(accessUnit.pointee)
            },
            // ── SESSION THREAD, last callback, exactly once. ────────────────────────────
            onEnded: { ctx, reason, message in
                guard let ctx else { return }
                let client = Unmanaged<SRTClient>.fromOpaque(ctx).takeUnretainedValue()
                // DECODE-SIDE TEARDOWN HAPPENS HERE, ON THIS THREAD, BEFORE THE HOP. The
                // VTDecompressionSession, the pixel-transfer session and the pool are all
                // single-thread-owned by this thread, and this is the only instant at which it
                // is both still alive and guaranteed idle. Doing it from main after the join
                // would mean tearing down a session from a thread that never owned it.
                SRTFrameRouter.shared.releaseSessionResources()
                let text = message.map { String(cString: $0) }
                DispatchQueue.main.async { client.handleSessionEnded(reason: reason, message: text) }
            })

        guard let created = ManifoldSRTSessionCreate(&callbacks) else {
            NSLog("[SRT] session create failed")
            showError("Couldn’t start the SRT connection.")
            teardownDisplayAndState()
            return
        }
        session = created

        // The C layer copies every string during Start and does not reference them after it
        // returns, which is what makes these nested `withCString` scopes sufficient — and what
        // keeps the passphrase's Swift lifetime as short as this one call. The config is built
        // fresh INSIDE the innermost scope rather than mutated from within the closures, so there
        // is no captured `var` under simultaneous inout access.
        func start(_ host: UnsafePointer<CChar>,
                   _ port: UnsafePointer<CChar>,
                   _ passphrase: UnsafePointer<CChar>?) -> Bool {
            var config = ManifoldSRTSessionConfig(host: host, port: port, passphrase: passphrase)
            return ManifoldSRTSessionStart(created, &config)
        }
        let portText = String(endpoint.port)
        let started = endpoint.host.withCString { hostPtr -> Bool in
            portText.withCString { portPtr -> Bool in
                if let passphrase = endpoint.passphrase {
                    return passphrase.withCString { start(hostPtr, portPtr, $0) }
                }
                return start(hostPtr, portPtr, nil)
            }
        }
        guard started else {
            NSLog("[SRT] session start failed")
            showError("Couldn’t start the SRT connection.")
            ManifoldSRTSessionDestroy(created)
            session = nil
            teardownDisplayAndState()
            return
        }
        NSLog("[SRT] session thread started — connect in flight (+%@)", elapsed())
    }

    // MARK: - Session callbacks, main-thread half

    private func handleConnected(negotiatedLatencyMs: Int32) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard session != nil else { return }   // raced a disconnect
        haveConnected = true
        connectedAtHost = CACurrentMediaTime()
        retireError()
        NSLog("[SRT] transport up in %@. Waiting for the demuxer to identify the stream…", elapsed())
        logLatencyBudget(negotiatedLatencyMs: negotiatedLatencyMs)
    }

    /// ── THE ONE LINE THAT MAKES `targetDepth` ARGUABLE FROM A LOG ─────────────────────────
    ///
    /// SRTFrameRouter's 0.250 s is chosen ON THE ASSUMPTION that SRT's own de-jitter buffer is
    /// absorbing the network burstiness WHEP had to absorb locally. That assumption is only as good
    /// as the latency the handshake ACTUALLY negotiated — which is a maximum of the two sides'
    /// wishes and can be nothing like the 120 ms default. So the two numbers are printed together,
    /// with a verdict, in BOTH directions:
    ///
    ///   UNUSUALLY LARGE (> 3× our cushion). The transport is already holding far more than we
    ///     assumed. Our cushion is then mostly redundant latency and could come DOWN — the argument
    ///     for 0.250 over WHEP's 0.400 applies again, harder.
    ///
    ///   UNUSUALLY SMALL (< 50 ms — a LAN sender, or one configured for minimum latency). TSBPD is
    ///     doing very little smoothing and has almost no window to retransmit in, so arrival
    ///     unevenness reaches us close to raw. Our cushion is then THIN, not generous, and an
    ///     underrun here means "raise it", not "the network is bad".
    ///
    /// Not a warning and not an error — it changes nothing and adjusts nothing. It is the context
    /// [SRT-UNDERRUN] and [SRT-JITTER] have to be read against.
    private func logLatencyBudget(negotiatedLatencyMs: Int32) {
        #if DEBUG || MANIFOLD_TELEMETRY
        let transport = Double(negotiatedLatencyMs) / 1000.0
        let cushion = SRTFrameRouter.configuredTargetDepth
        let verdict: String
        if transport < Self.thinTransportLatency {
            verdict = "UNUSUALLY SMALL — TSBPD is doing little smoothing and has almost no "
                    + "retransmit window, so our cushion is thin, not generous; treat an underrun "
                    + "here as a reason to RAISE the target (⌃⌥]), not as a bad network"
        } else if transport > cushion * Self.largeTransportLatencyFactor {
            verdict = "UNUSUALLY LARGE — the transport is already holding far more than our cushion "
                    + "assumes, so the target could likely come DOWN (⌃⌥[) for less end-to-end delay"
        } else {
            verdict = "nominal — the transport is absorbing burstiness roughly as the target assumes"
        }
        NSLog("[SRT] latency budget: transport %d ms (negotiated) + cushion %.0f ms (targetDepth) = %.0f ms deliberate. %@",
              negotiatedLatencyMs, cushion * 1000, Double(negotiatedLatencyMs) + cushion * 1000, verdict)
        #endif
    }

    private func handleVideoFormat(_ format: ManifoldSRTVideoFormat,
                                   colorimetry: SRTFrameRouter.StreamColorimetry) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard session != nil else { return }

        // ── CODEC GATE. H.264 ONLY, AND IT FAILS LOUDLY RATHER THAN SHOWING BLACK ─────────
        // H264AccessUnitBuilder is H.264-only and the assumption is load-bearing there: HEVC has
        // a two-byte NAL header, the type in different bits, VPS/SPS/PPS at 32/33/34, and IDR
        // split across two types. Feeding it an HEVC stream produces an access unit of nothing,
        // forever — a permanently black picture with a healthy transport, which is the worst
        // possible failure to debug. HEVC over SRT is common enough that this WILL be hit.
        let codec = Self.text(format.codecName)
        guard codec == "h264" else {
            NSLog("[SRT] stream is %@ — this build decodes H.264 only; refusing", codec)
            // USER-VISIBLE, through the SAME non-fatal banner a connect error uses. A log line
            // alone would leave the user with a black window and no stated reason — the worse of
            // the two outcomes this gate exists to prevent. Set BEFORE disconnect(), which does not
            // touch `lastError`, so the message survives the teardown and is what the user reads.
            showError("That stream is \(Self.codecDisplayName(codec)) — Manifold’s SRT support "
                      + "is H.264 only.")
            disconnect()
            return
        }

        NSLog("[SRT] video: %@ %@ %dx%d @ %.3f fps (stream %d, time_base %d/%d)",
              codec, Self.text(format.profileName), format.width, format.height,
              format.guessedFrameRate, format.streamIndex,
              format.timeBaseNum, format.timeBaseDen)

        self.colorimetry = colorimetry
        SRTFrameRouter.shared.activate(format: format, colorimetry: colorimetry)

        // PHASE 2 BEGINS HERE, AND ITS GRACE IS ARMED HERE — not at connect. Everything before this
        // instant was the probe's time to spend; charging it to the first-picture clock would
        // produce "no video is arriving" about a stream nobody had finished looking at yet.
        haveVideoStream = true
        videoIdentifiedAtHost = CACurrentMediaTime()
        announcedProbeWait = false
        retireError()   // phase 1 is over; retire its banner if it showed

        NSLog("[SRT] a decoder cannot start on a P-frame and SRT has no PLI, so the picture stays "
              + "BLACK until the sender's next keyframe (≈2s on OBS defaults). This is not a hang.")
    }

    /// The session thread has finished. Called on main, always after the decode side has already
    /// been released on that thread.
    private func handleSessionEnded(reason: ManifoldSRTEndReason, message: String?) {
        dispatchPrecondition(condition: .onQueue(.main))
        // A MANUAL disconnect() got here first: it joined the thread and tore everything down
        // synchronously, so this is the queued tail of the same event. Nothing to do.
        guard session != nil else { return }

        if reason == ManifoldSRTEndReasonStopped {
            NSLog("[SRT] session stopped")
        } else {
            NSLog("[SRT] session ended (reason %d): %@", reason, message ?? "no detail")
            // Surface libsrt's own words where the C layer produced them. A reason of Stopped
            // never carries a message, so this cannot show a banner for a deliberate teardown.
            if let message { showError(message) }
        }
        disconnect()
    }

    // MARK: - Teardown

    /// The single teardown path. Every other one routes through it: manual (⌃⌥⇧D, the Disconnect
    /// menu item, LiveSource.retireActive), a failed connect, a peer close, a lost connection, the
    /// media-stall watchdog, and an unsupported codec.
    ///
    /// ── THE FIVE WHEP PATHS, AND WHAT SRT ACTUALLY HAS ───────────────────────────────────
    ///
    ///   1. MANUAL                     → identical. This method.
    ///   2. ICE `.failed`              → the connect failure. srt_connect returns SRT_ERROR with a
    ///                                   reject reason, reported through onEnded(ConnectFailed).
    ///                                   Post-connect there is no ICE to fail; the equivalent is 4.
    ///   3. peer `.closed`             → srt_recvmsg2 returns 0. onEnded(PeerClosed).
    ///   4. the `.disconnected` 10 s backstop → NO APP-LEVEL EQUIVALENT, AND NONE IS NEEDED.
    ///                                   That backstop exists because we could not establish that
    ///                                   libdatachannel always escalates a dead link to `.failed`.
    ///                                   libsrt does, by contract: SRTO_PEERIDLETIMEO (set
    ///                                   explicitly in SRTSession.m, at libsrt's own 5 s default)
    ///                                   turns silence into SRT_ECONNLOST, which arrives as
    ///                                   onEnded(ConnectionLost). Adding a timer on top would be a
    ///                                   second, slower opinion about the same fact.
    ///   5. the 15 s media watchdog    → GENUINE EQUIVALENT, AND KEPT. Bytes can keep arriving with
    ///                                   no video in them (PAT/PMT/padding, or an audio-only PID
    ///                                   after the encoder stopped), so the peer-idle timeout never
    ///                                   fires. See `mediaStallWindow`.
    ///
    /// A sixth path exists that WHEP has no version of: an unsupported codec, refused at
    /// `handleVideoFormat` rather than left to show black forever.
    func disconnect() {
        dispatchPrecondition(condition: .onQueue(.main))
        // Clear the source flag FIRST, before the no-session early-out, so a redundant disconnect —
        // or one after a connect that failed before a session existed — can never leave
        // `isConnected` stuck true.
        isConnected = false
        guard let session else { return }
        self.session = nil
        NSLog("[SRT] tearing down (+%@)", elapsed())

        statsTimer?.invalidate()
        statsTimer = nil

        // BEFORE the Stop below, and it has to be: Stop destroys the access-unit reader once the
        // join proves nobody is inside it, so these counters do not exist afterwards.
        logSessionTotals(session)

        // ── ORDER: JOIN FIRST, THEN RELEASE THE DISPLAY. ─────────────────────────────────
        // The opposite of WHEP's order, and better, because here we CAN join. Stop() blocks until
        // the session thread has exited (bounded by one SRTO_RCVTIMEO period), and its onEnded has
        // already released everything that thread owned. So by the time the display route is
        // touched there is provably no producer left — no in-flight `enqueue`, no decode in
        // progress, nothing racing `route.deactivate`. WHEP deactivates first precisely BECAUSE it
        // cannot join libdatachannel's threads and has to rely on `deliver` dropping frames that
        // find no clock.
        ManifoldSRTSessionStop(session)
        ManifoldSRTSessionDestroy(session)

        SRTFrameRouter.shared.deactivate()
        colorimetry = nil
        startedAt = nil
        haveConnected = false
        haveVideoStream = false
    }

    /// Undo the display takeover when a connect fails before a session ever ran.
    private func teardownDisplayAndState() {
        isConnected = false
        statsTimer?.invalidate()
        statsTimer = nil
        SRTFrameRouter.shared.deactivate()
        startedAt = nil
    }

    // MARK: - 1 Hz instrumentation + watchdogs (main thread)

    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTicks = 0
        watchdogLastPictures = 0
        watchdogSinceHost = 0
        // Every per-stream announce latch, cleared in one place so no connect path can miss one.
        announcedProbeWait = false
        announcedFirstPictureWait = false
        announcedReorderShortfall = false
        haveVideoStream = false
        videoIdentifiedAtHost = 0
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let session else { return }
        statsTicks += 1

        let pictures = SRTFrameRouter.shared.picturesDecoded
        let now = CACurrentMediaTime()

        // ── MEDIA-STALL WATCHDOG ─────────────────────────────────────────────────────────
        // ARMS ONLY once a picture has been seen — a connection that never delivers one is left to
        // the graces below, not killed here. Identical reasoning to WHEP's.
        //
        // ALL OF THIS IS FUNCTIONAL AND NONE OF IT IS GATED: the arming, the stamping, the banner
        // and the teardown are outside every `#if`, exactly as the WHEP media watchdog was
        // restructured out of its logging block. Only `logStatsIfDue` at the bottom is compiled out
        // of Release, and it is pure narration.
        if pictures > 0 {
            // A picture is the definitive success signal — it retires any banner a picture
            // DISPROVES. Not the ones a picture is compatible with (the reorder shortfall, the
            // already-connected refusal); see `lastErrorSurvivesPictures`.
            if !lastErrorSurvivesPictures { retireError() }
            announcedFirstPictureWait = false
            announcedProbeWait = false
            if pictures > watchdogLastPictures {
                watchdogLastPictures = pictures
                watchdogSinceHost = now
            } else if now - watchdogSinceHost >= Self.mediaStallWindow {
                NSLog("[SRT] no video for %.0fs on a healthy link — publisher likely stopped; tearing down",
                      Self.mediaStallWindow)
                showError("The stream stopped sending video (the broadcaster may have ended it).")
                disconnect()
                return
            }
        } else if haveVideoStream {
            // PHASE 2 — identified, waiting for an IDR. Measured from the identification instant,
            // never from connect. See the grace block at the top of this file.
            if !announcedFirstPictureWait, now - videoIdentifiedAtHost >= Self.firstPictureGrace {
                announcedFirstPictureWait = true
                var stats = ManifoldSRTAccessUnitReaderStats()
                ManifoldSRTSessionCopyReaderStats(session, &stats)
                NSLog("[SRT] %.0fs since the stream was identified, still no picture — %llu access units, %llu keyframes",
                      Self.firstPictureGrace, stats.accessUnits, stats.keyframes)
                showError(stats.accessUnits > 0
                    ? "Connected, but still waiting for a keyframe from the sender."
                    : "Connected, but no video is arriving from the sender.")
            }
        } else if haveConnected {
            // PHASE 1 — connected, the demuxer has not identified the stream yet. NAMES THE PHASE
            // rather than claiming anything about video, because nothing has looked at the video
            // yet. This is also the state a silent publisher leaves us in permanently: the read
            // callback loops on receive timeouts inside find_stream_info and never returns.
            if !announcedProbeWait, now - connectedAtHost >= Self.probeGrace {
                announcedProbeWait = true
                var messages: UInt64 = 0, bytes: UInt64 = 0, timeouts: UInt64 = 0
                ManifoldSRTSessionCopyTransportStats(session, &messages, &bytes, &timeouts)
                NSLog("[SRT] %.0fs connected, stream not identified yet — %llu messages, %llu bytes received",
                      Self.probeGrace, messages, bytes)
                showError(bytes > 0
                    ? "Connected — still identifying the stream."
                    : "Connected, but the sender hasn’t sent anything yet.")
            }
        }

        checkReorderBudget()
        logStatsIfDue(session)
    }

    /// ── THE REORDER BANNER ───────────────────────────────────────────────────────────────
    ///
    /// SRTFrameRouter counts, on every access unit and in EVERY build configuration, how many
    /// pictures arrived with a (pts − dts) at or beyond the live target. Those pictures are not
    /// shown late — the renderer's PTS-ordered insert places them behind its swept position and
    /// DISCARDS them, so the user is watching a stream with frames missing and no reason given.
    ///
    /// This is the reason, in the user's words, through the same non-fatal banner a connect error
    /// uses. Announced ONCE per stream: the count keeps climbing, and re-raising the banner every
    /// second would make the app unusable while telling the user nothing new.
    ///
    /// IT DOES NOT ADJUST THE DEPTH. Deliberately — see `SRTFrameRouter.recordReorderDelay`. Raising
    /// the cushion spends the user's latency, and on this evidence that stays the user's call, with
    /// ⌃⌥] to make it.
    private func checkReorderBudget() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !announcedReorderShortfall else { return }
        let report = SRTFrameRouter.shared.reorderReport
        guard report.exceedances > 0 else { return }
        announcedReorderShortfall = true

        NSLog("[SRT] reorder shortfall: %d access unit(s) arrived with pts−dts ≥ targetDepth (max %.3fs vs target %.3fs) — those pictures were discarded by the renderer's PTS-ordered insert",
              report.exceedances, report.maxSeconds, report.targetSeconds)

        let neededMs = Int((report.maxSeconds * 1000).rounded(.up))
        let targetMs = Int((report.targetSeconds * 1000).rounded())
        showError("Frames are arriving too late to be displayed — the buffer is too shallow for "
                  + "this stream (it reorders by up to \(neededMs) ms; the buffer holds \(targetMs) ms).",
                  survivesPictures: true)
    }

    private func logStatsIfDue(_ session: OpaquePointer) {
        #if DEBUG || MANIFOLD_TELEMETRY
        var messages: UInt64 = 0, bytes: UInt64 = 0, timeouts: UInt64 = 0
        ManifoldSRTSessionCopyTransportStats(session, &messages, &bytes, &timeouts)
        var stats = ManifoldSRTAccessUnitReaderStats()
        ManifoldSRTSessionCopyReaderStats(session, &stats)

        NSLog("""
              [SRT-AU] +%ds  transport: msgs=%llu bytes=%llu recvTimeouts=%llu | reader: pkts=%llu \
              AUs=%llu key=%llu | noStartCode=%llu noVCL=%llu ptsFromDTS=%llu noDTS=%llu noPTS=%llu
              """,
              statsTicks, messages, bytes, timeouts,
              stats.packetsReceived, stats.accessUnits, stats.keyframes,
              stats.packetsWithoutStartCode, stats.packetsWithoutAccessUnit,
              stats.accessUnitsPTSFromDTS, stats.accessUnitsWithoutDTS, stats.accessUnitsWithoutPTS)

        // A non-zero packetsWithoutStartCode means libavformat handed us AVCC (length-prefixed)
        // bytes rather than Annex-B, which the scanner cannot read — the stream would be silently
        // undecodable. Named once rather than left as a number in a rollup.
        if stats.packetsWithoutStartCode > 0, statsTicks % 5 == 0 {
            NSLog("""
                  [SRT-AU] ⚠️ %llu packets carried no Annex-B start code. The demuxer is emitting \
                  AVCC, which this path cannot read — the extradata route would be needed.
                  """, stats.packetsWithoutStartCode)
        }
        #endif
    }

    private func logSessionTotals(_ session: OpaquePointer) {
        #if DEBUG || MANIFOLD_TELEMETRY
        var messages: UInt64 = 0, bytes: UInt64 = 0, timeouts: UInt64 = 0
        ManifoldSRTSessionCopyTransportStats(session, &messages, &bytes, &timeouts)
        var stats = ManifoldSRTAccessUnitReaderStats()
        ManifoldSRTSessionCopyReaderStats(session, &stats)
        var builder = ManifoldH264AccessUnitBuilderStats()
        ManifoldSRTSessionCopyReaderBuilderStats(session, &builder)
        NSLog("""
              [SRT-AU] session totals: msgs=%llu bytes=%llu | AUs=%llu (key=%llu) → %d pictures | \
              NALs: SPS=%llu PPS=%llu IDR=%llu slice=%llu SEI=%llu AUD=%llu | oversize=%llu
              """,
              messages, bytes, stats.accessUnits, stats.keyframes,
              SRTFrameRouter.shared.picturesDecoded,
              builder.nalSPS, builder.nalPPS, builder.nalIDR, builder.nalSlice,
              builder.nalSEI, builder.nalAUD, builder.accessUnitsOversize)
        #endif
    }

    // MARK: - Helpers

    /// libavformat's short codec name → something worth showing a user. Falls back to the raw name
    /// uppercased, so an unlisted codec still names itself rather than reading "unknown".
    private static func codecDisplayName(_ name: String) -> String {
        switch name {
        case "hevc":       return "HEVC (H.265)"
        case "av1":        return "AV1"
        case "vp9":        return "VP9"
        case "vp8":        return "VP8"
        case "mpeg2video": return "MPEG-2"
        case "prores":     return "ProRes"
        default:           return name.uppercased()
        }
    }

    /// A fixed-size C `char[]` field arrives in Swift as a tuple. The C side always NUL-terminates
    /// (strlcpy), so reading it as a C string is safe.
    private static func text<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { raw in
            guard let base = raw.baseAddress else { return "?" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
