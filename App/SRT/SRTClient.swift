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
    /// keyframe, nothing arriving). It is WRONG for a message that is true precisely WHILE pictures
    /// flow, and today exactly one is: THE REORDER SHORTFALL. Frames are arriving AND some are
    /// being discarded, so an arriving picture is not evidence against it — it is the thing the
    /// message is about.
    ///
    /// There was a second such message, the already-connected refusal, and it is gone: a second SRT
    /// connect is now a swap arbitrated by `LiveSource.connectSRT`, not an error to explain. The
    /// flag stays because the reorder case is unchanged and the distinction is real; a one-member
    /// category is still a category.
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
    ///
    /// ── PROGRESS DOES NOT RETIRE A MESSAGE THAT PROGRESS DOESN'T DISPROVE ───────────────────
    ///
    /// The unguarded call honours `lastErrorSurvivesPictures`, and every phase-progress caller uses
    /// it. The transport coming up and the stream being identified are the same KIND of evidence a
    /// picture is — "it is working" — and they refute exactly the same messages: the ones about not
    /// having a picture yet. They say nothing about the ignored-parameter notice or the reorder
    /// shortfall, both of which stay true through a perfectly healthy session. Without this, an
    /// ignored `?foo=` banner raised at connect vanished a second later when the transport came up,
    /// which is indistinguishable from a UI glitch.
    ///
    /// `force: true` is for a FRESH ATTEMPT, which invalidates every message including those —
    /// they described a URL we are no longer dialling.
    private func retireError(force: Bool = false) {
        guard lastError != nil else { return }
        guard force || !lastErrorSurvivesPictures else { return }
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

    /// ── WHICH SESSION A LATE CALLBACK BELONGS TO ────────────────────────────────────────────
    ///
    /// Incremented once per `connect`, handed to the C layer in the config, and echoed back by
    /// every callback that hops to main. A handler compares it against this value and drops
    /// anything from an older session.
    ///
    /// THE BUG THIS EXISTS FOR, because it is not hypothetical and it was not obvious. `onEnded`
    /// fires on the session thread INSIDE `ManifoldSRTSessionStop`, before the join completes — so
    /// during `disconnect()`, while main is blocked in the join. Its `DispatchQueue.main.async`
    /// hop therefore cannot run until main is free, which on a SWAP is after `connectSRT` has
    /// already stood the replacement up. The old session's "I have stopped" then arrived at a
    /// `handleSessionEnded` whose only staleness check was `session != nil` — true, but of the NEW
    /// session — and tore down a stream that was 20 ms old. `LiveSource.connectSRT` making SRT→SRT
    /// a swap is what put a new session inside that window; before it, the sequence was refused.
    ///
    /// A COUNTER AND NOT THE SESSION POINTER. `Destroy` frees the struct and the next `Create` can
    /// be handed the same address, so a stale pointer can compare EQUAL to a live one — the swap
    /// path, where free and malloc are microseconds apart, is exactly where that is most likely.
    /// A monotonic counter has no such failure.
    ///
    /// ⚠️ MAIN THREAD ONLY, read and write. Every access is inside a method that opens with
    /// `dispatchPrecondition(condition: .onQueue(.main))`: the write in `connect`, the reads in
    /// `handleConnected`, `handleVideoFormat` and `handleSessionEnded`. That is the whole set — no
    /// session-thread code path touches it, and the C callbacks receive their copy as an argument
    /// rather than reading this. `connect` is reachable only through `LiveSource`, which is
    /// UI-driven and main-only, and the assertion holds it to that rather than trusting it. No
    /// lock, because a lock would suggest the invariant is doubted.
    ///
    /// Starts at 0 and is incremented BEFORE any session is created, so 0 is never a live
    /// generation — it means "no session has ever run".
    private var sessionGeneration: UInt64 = 0

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
    /// PLI. That wait is ~1 s on OBS defaults and can be 10 s on a long keyframe interval, and it
    /// must NOT be mistaken for a dead stream. 15 s clears the common cases with room; a sender
    /// running a keyframe interval longer than that would need this raised, and the
    /// `[SRT-AU] waiting for an IDR` line is what would say so.
    ///
    /// ⚠️ THE "~1 s" IS MEASURED, AND IT USED TO SAY "~2 s". OBS's shipped keyframe interval is
    /// 1 s, counted from the `[WHEP-RTP]` per-second key-NAL totals — one IDR per second, not one
    /// per two. THE 15 s IS UNCHANGED AND NEEDS NO CHANGE: it was sized against the 10 s
    /// long-interval worst case above, never against the OBS figure, so correcting the OBS figure
    /// moves the reasoning and not the number. Same for the 12 s first-picture grace below.
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
    //     along. ~1 s on OBS defaults (measured — see the watchdog note above); up to 10 s on a
    //     long keyframe interval.
    //
    // THE PHASE-2 GRACE ARMS AT IDENTIFICATION, NOT AT CONNECT, and that is the whole reason there
    // are two. Armed at connect, a slow probe would spend its own seconds on phase 2's clock and
    // produce "no video is arriving" while the probe was still running — a banner asserting
    // something nobody had yet checked.

    /// PHASE 1. Shorter than the phase-2 grace because there is less to legitimately wait for:
    /// identification needs bytes, and bytes either flow or they do not.
    private static let probeGrace: TimeInterval = 8
    /// PHASE 2. LONGER THAN THE COMMON GOP ON PURPOSE — 12 s clears a 10 s keyframe interval, which
    /// is the worst case it was sized against and still is. (The OBS default it also has to clear
    /// is 1 s, not the ~2 s this file used to assert; the correction moves neither bound.)
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

        /// SRTO_STREAMID, or nil.
        ///
        /// ⚠️ MAY CARRY A CREDENTIAL. An earlier version of this comment called it "an address, not
        /// a credential", which is true for a plain resource name and false in two common cases:
        ///
        ///   * SRT's access-control convention, `#!::u=…,r=…,s=…`, defines `s` as a SESSION
        ///     IDENTIFIER used for server-side verification — a bearer token in a query parameter;
        ///   * a great many hosted ingests expect the raw publish key AS the entire streamid, with
        ///     no syntax around it to tell you that is what it is.
        ///
        /// It is still logged, because a stream id you cannot see is exactly how a routing mistake
        /// becomes an unexplained server rejection — but through `redactedStreamId`, and see what
        /// that can and cannot promise.
        let streamId: String?

        /// Requested SRTO_RCVLATENCY in milliseconds, or nil to leave libsrt's default.
        let latencyMs: Int?

        /// Query keys present that we do NOT act on. Reported, never ignored silently.
        let unhandledParameters: [String]

        /// SRT's own limits on a passphrase: 10–79 characters. Checked here so the failure names
        /// the rule at the moment the user's input is read, instead of arriving as a libsrt errno.
        static let passphraseLengthRange = 10...79

        /// SRT's own ceiling on a stream id: 512 BYTES, not characters — the option is a byte
        /// buffer, so a multi-byte id hits it sooner than its character count suggests.
        static let streamIdMaxBytes = 512

        /// ── WHY LATENCY IS RANGE-CHECKED AT ALL ─────────────────────────────────────────────
        ///
        /// libsrt accepts a far wider range than is ever meaningful here, and both ends of the
        /// useful one fail in ways that do not look like a bad number. Below ~20 ms TSBPD has no
        /// window to retransmit in, so the link degrades to something worse than plain UDP while
        /// reporting itself healthy. Above 8 s the buffer holds more than any live monitoring
        /// workflow can use, and the picture arrives seconds after the thing it shows — which reads
        /// as a frozen stream, not as a latency setting. A typo (`?latency=25000`, or a value
        /// someone meant as microseconds) lands squarely in that second case.
        static let latencyMsRange = 20...8000
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
        /// A `mode=` we cannot honour. Carries the value because it is the user's own text and
        /// naming it back is what makes the message actionable — see the discussion on listener
        /// mode in `message`.
        case unsupportedMode(String)
        case badLatency
        case streamIdTooLong
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

            // ── LISTENER MODE IS THE ONE THAT MUST BE REFUSED BY NAME ───────────────────────
            // It used to fall through to the ignored-parameter path, which meant Manifold dialled
            // as a caller anyway — at an address that, in listener mode, is by definition NOT
            // listening. The result was a connect timeout against a peer waiting for US to be the
            // server: a silent 3 s failure whose message ("nobody answered") was true and
            // completely misleading. Naming the mode is the whole fix.
            case .unsupportedMode(let mode) where mode == "listener":
                return "Listener mode isn’t supported yet — Manifold connects to a sender, "
                     + "not the reverse."
            case .unsupportedMode(let mode):
                return "This build dials SRT as a caller; it can’t use mode “\(mode)”."

            case .badLatency:
                return "That stream latency isn’t usable — give a value in milliseconds between "
                     + "\(Endpoint.latencyMsRange.lowerBound) and \(Endpoint.latencyMsRange.upperBound)."
            case .streamIdTooLong:
                return "That stream ID is too long — SRT allows at most "
                     + "\(Endpoint.streamIdMaxBytes) bytes."
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
        var streamId: String?
        var latencyMs: Int?
        var unhandled: [String] = []
        for item in items {
            switch item.name.lowercased() {
            case "streamid":
                let value = item.value ?? ""
                guard !value.isEmpty else { continue }
                // BYTES, not `count` — the option is a byte buffer and a multi-byte id hits SRT's
                // ceiling sooner than its character count suggests.
                guard value.utf8.count <= Endpoint.streamIdMaxBytes else {
                    return .failure(.streamIdTooLong)
                }
                streamId = value

            case "latency":
                let value = item.value ?? ""
                // MILLISECONDS, integer, no unit suffix — which is what OBS, ffmpeg and every
                // hosted ingest's copy-paste URL write. A float or a "250ms" is a typo we should
                // name rather than silently round or ignore.
                guard let ms = Int(value), Endpoint.latencyMsRange.contains(ms) else {
                    return .failure(.badLatency)
                }
                latencyMs = ms

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
            case "mode":
                let mode = (item.value ?? "").lowercased()
                // Caller is what we already are; anything else is refused HERE, at the door, where
                // it can be named. Falling through to `unhandled` would dial as a caller regardless
                // and fail as a timeout — see the note on `.unsupportedMode`.
                guard mode == "caller" else { return .failure(.unsupportedMode(mode)) }

            default:
                unhandled.append(item.name)
            }
        }
        return .success(Endpoint(host: host, port: port, passphrase: passphrase,
                                 streamId: streamId, latencyMs: latencyMs,
                                 unhandledParameters: unhandled))
    }

    // MARK: - Connect

    /// ⚠️ REACHABLE ONLY THROUGH `LiveSource.connectSRT`, and not by convention — the `Arbitration`
    /// argument cannot be constructed outside LiveSource.swift, so no other call site compiles.
    /// That is what lets everything below assume arbitration has already run.
    ///
    /// ── WHY THERE IS NO LONGER A `guard session == nil` HERE ────────────────────────────────
    ///
    /// There was one, and it refused a second connect with a banner ("disconnect it before
    /// connecting another"). It is gone, because the question it was deferring has been answered:
    /// a second SRT connect is a SWAP, on the same full-replacement rule stream-over-file follows.
    ///
    /// The refusal's own argument was that swapping means tearing down a live session — a
    /// main-thread join of up to one SRTO_RCVTIMEO period — on the strength of a second click.
    /// That cost is real and it is still paid; what changed is WHERE. `LiveSource.connectSRT`
    /// retires every live source, `.srt` included, BEFORE this runs, so the join happens in the
    /// arbitration step rather than inside a connect that is also trying to stand a session up.
    /// By the time this line executes, `session` is nil because the funnel made it nil.
    ///
    /// ── WHY THE CHECK BELOW IS DEFENSIVE AND NOT `assert` OR `precondition` ─────────────────
    ///
    /// The token proves the caller came through `LiveSource`; it does NOT prove `retireActive`
    /// retired anything. A `LiveSource` case added later with no arm in `disconnect()` would satisfy
    /// the type system and still arrive here with a live session — the double-source bug again, in
    /// the one form the token cannot catch.
    ///
    /// `assert` is the wrong instrument for that because it COMPILES OUT OF RELEASE, which is
    /// exactly where the surviving hole would live. `precondition` would cover Release by crashing —
    /// and that is worse than the fault it guards. This condition is recoverable, by the same single
    /// teardown path arbitration itself would have used, and killing a monitoring tool mid-session
    /// is not a proportionate answer to a state we know how to fix in one call.
    ///
    /// So: tear the old session down and carry on, unconditionally in every configuration, with a
    /// log line that names it as a BUG rather than a condition. THE LOG IS THE POINT — it fires in
    /// Release, which is more than an assertion would ever have done.
    func connect(to url: URL, arbitratedBy _: LiveSource.Arbitration) {
        dispatchPrecondition(condition: .onQueue(.main))

        if session != nil {
            NSLog("[SRT] BUG: connect reached with a live session — arbitration did not retire it. "
                  + "Tearing it down here; the swap still happens, but a LiveSource case is missing "
                  + "a disconnect arm.")
            disconnect()   // the single teardown path, join included — see its ORDER note
        }

        retireError(force: true)   // fresh attempt — clear any banner from a previous try

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
        if let streamId = endpoint.streamId {
            NSLog("[SRT] stream id: %@", Self.redactedStreamId(streamId))
        }
        if !endpoint.unhandledParameters.isEmpty {
            let named = endpoint.unhandledParameters.joined(separator: ", ")
            NSLog("[SRT] ⚠️ ignoring URL parameter(s): %@", named)
            // ── AND IN THE UI, NOT ONLY THE LOG ────────────────────────────────────────────
            // `passphrase`, `streamid`, `latency` and `mode` are all acted on now, so anything
            // still landing here is genuinely being dropped. With bookmarks these parameters are
            // USER-TYPED — someone pasted a URL from their ingest provider — and the failure mode
            // of dropping one silently is a connection that either fails for no stated reason or,
            // worse, succeeds while quietly ignoring something the user asked for.
            //
            // NON-FATAL: the connect proceeds. It may well work.
            //
            // `survivesPictures: true` because this is true WHILE the stream plays — it is a
            // statement about what we did with the URL, and a picture arriving is not evidence
            // against it. Same category as the reorder shortfall.
            showError("Ignoring URL parameter(s) this build doesn’t use: \(named).",
                      survivesPictures: true)
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

        // UNRETAINED CONTEXT, and safe for the same reason LiveVideoDecoder's output-callback
        // refcon is: this is a process-lifetime singleton, and the C session is joined in
        // disconnect() before anything is released, so no callback can outlive its target.
        let context = Unmanaged.passUnretained(self).toOpaque()
        var callbacks = ManifoldSRTSessionCallbacks(
            context: context,
            // ── SESSION THREAD ──────────────────────────────────────────────────────────
            // EVERY HOP CARRIES ITS GENERATION ACROSS. The C function pointers capture nothing, so
            // the token cannot be closed over — it arrives as an argument and is forwarded into the
            // async block, which is the only way the far side can know whose callback this is.
            onConnected: { ctx, generation, info in
                guard let ctx, let info else { return }
                let client = Unmanaged<SRTClient>.fromOpaque(ctx).takeUnretainedValue()
                let latency = info.pointee.negotiatedLatencyMs
                let requested = info.pointee.requestedLatencyMs
                DispatchQueue.main.async {
                    client.handleConnected(generation: generation,
                                           negotiatedLatencyMs: latency, requestedLatencyMs: requested)
                }
            },
            // ── SESSION THREAD. Two halves, and the split is load-bearing. ──────────────
            // The DECODER must be built on this thread (it is single-thread-owned, and this is
            // the thread that will call decode). The DISPLAY ROUTE must be activated on main
            // (it repoints the renderer's providers). So the format lands here, prepares the
            // decode side synchronously, and hops for the display side. Access units cannot
            // arrive before this returns — the C layer emits onVideoFormat before the first
            // one — so the decoder is always ready in time. The route may be a few milliseconds
            // behind, which `deliver` already tolerates by dropping frames with no clock.
            onVideoFormat: { ctx, generation, format in
                guard let ctx, let format else { return }
                let client = Unmanaged<SRTClient>.fromOpaque(ctx).takeUnretainedValue()
                let f = format.pointee
                let colorimetry = SRTFrameRouter.StreamColorimetry(f)
                // The decode-side preparation is NOT generation-gated, and does not need to be: it
                // runs INLINE on this session's own thread, so it cannot be reached after the join
                // that proves this thread is gone. Only the hop below can outlive the session.
                SRTFrameRouter.shared.prepareDecoder(format: f, colorimetry: colorimetry)
                DispatchQueue.main.async {
                    client.handleVideoFormat(generation: generation, f, colorimetry: colorimetry)
                }
            },
            // ── SESSION THREAD, inline, per access unit. No hop: this is the hot path. ──
            onAccessUnit: { _, accessUnit in
                guard let accessUnit else { return }
                SRTFrameRouter.shared.handleAccessUnit(accessUnit.pointee)
            },
            // ── SESSION THREAD, last callback, exactly once. ────────────────────────────
            onEnded: { ctx, generation, reason, message in
                guard let ctx else { return }
                let client = Unmanaged<SRTClient>.fromOpaque(ctx).takeUnretainedValue()
                // DECODE-SIDE TEARDOWN HAPPENS HERE, ON THIS THREAD, BEFORE THE HOP. The
                // VTDecompressionSession, the pixel-transfer session and the pool are all
                // single-thread-owned by this thread, and this is the only instant at which it
                // is both still alive and guaranteed idle. Doing it from main after the join
                // would mean tearing down a session from a thread that never owned it.
                SRTFrameRouter.shared.releaseSessionResources()
                let text = message.map { String(cString: $0) }
                DispatchQueue.main.async {
                    client.handleSessionEnded(generation: generation, reason: reason, message: text)
                }
            })

        // ── THE GENERATION IS CLAIMED HERE, AS LATE AS POSSIBLE ──────────────────────────────
        // Immediately before the session exists, so the window in which a generation is live with
        // no session behind it is as small as it can be made. It cannot be closed: `Create` or
        // `Start` can still fail below, and both leave `session` nil with this already bumped.
        // That is precisely why the handlers check BOTH this and `session != nil` — see them.
        // Main-thread only; the precondition at the top of this method is what enforces it.
        sessionGeneration &+= 1
        let generation = sessionGeneration

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
                   _ passphrase: UnsafePointer<CChar>?,
                   _ streamId: UnsafePointer<CChar>?) -> Bool {
            var config = ManifoldSRTSessionConfig(host: host, port: port, passphrase: passphrase,
                                                  streamId: streamId,
                                                  generation: generation,
                                                  latencyMs: Int32(endpoint.latencyMs ?? 0))
            return ManifoldSRTSessionStart(created, &config)
        }
        // NESTED SCOPES, NOT AN ARRAY OF POINTERS. Each `withCString` guarantees its buffer only
        // for the duration of its own closure, so the Start call has to happen at the innermost
        // point where every pointer is still valid — which is also what keeps the passphrase's
        // Swift lifetime as short as one call. The stream id gets the same treatment for
        // uniformity, though it is not a secret.
        let portText = String(endpoint.port)
        func withStreamId(_ host: UnsafePointer<CChar>,
                          _ port: UnsafePointer<CChar>,
                          _ passphrase: UnsafePointer<CChar>?) -> Bool {
            if let streamId = endpoint.streamId {
                return streamId.withCString { start(host, port, passphrase, $0) }
            }
            return start(host, port, passphrase, nil)
        }
        let started = endpoint.host.withCString { hostPtr -> Bool in
            portText.withCString { portPtr -> Bool in
                if let passphrase = endpoint.passphrase {
                    return passphrase.withCString { withStreamId(hostPtr, portPtr, $0) }
                }
                return withStreamId(hostPtr, portPtr, nil)
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

    /// Does this callback belong to the session we are currently running?
    ///
    /// A `false` is NOT a fault and is not logged as one: it is the expected outcome for the last
    /// callback of a session that has just been swapped out, which is a normal thing for a user to
    /// cause by picking a second stream. The line is gated to the measuring configurations because
    /// its value is confirming the drop happened, not warning about it.
    private func isCurrent(_ generation: UInt64, _ what: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard generation == sessionGeneration else {
            #if DEBUG || MANIFOLD_TELEMETRY
            NSLog("[SRT] ignoring '%@' from session %llu — session %llu is current",
                  what, generation, sessionGeneration)
            #endif
            return false
        }
        return true
    }

    private func handleConnected(generation: UInt64,
                                 negotiatedLatencyMs: Int32, requestedLatencyMs: Int32) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isCurrent(generation, "connected") else { return }
        guard session != nil else { return }   // raced a disconnect
        haveConnected = true
        connectedAtHost = CACurrentMediaTime()
        retireError()
        NSLog("[SRT] transport up in %@. Waiting for the demuxer to identify the stream…", elapsed())
        logLatencyBudget(negotiatedLatencyMs: negotiatedLatencyMs,
                         requestedLatencyMs: requestedLatencyMs)
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
    private func logLatencyBudget(negotiatedLatencyMs: Int32, requestedLatencyMs: Int32) {
        #if DEBUG || MANIFOLD_TELEMETRY
        // ── WHAT WE ASKED FOR, WHERE IT DIFFERS ─────────────────────────────────────────────
        // The handshake takes the MAXIMUM of the two sides' wishes, so a `?latency=` the user
        // typed is a FLOOR, not a setting — the sender can and often does raise it. Printing only
        // the negotiated number makes that look like the parameter was ignored, which is the one
        // conclusion this line must not invite. Silent when nothing was requested (libsrt's own
        // 120 ms default), because "requested 0" would be a fiction.
        let requestedNote: String
        if requestedLatencyMs <= 0 {
            requestedNote = ""
        } else if requestedLatencyMs == negotiatedLatencyMs {
            requestedNote = " (as requested)"
        } else {
            requestedNote = " (we asked for \(requestedLatencyMs) ms; the handshake takes the "
                          + "MAXIMUM of both sides, so the sender's is what stands)"
        }
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
        NSLog("[SRT] latency budget: transport %d ms (negotiated)%@ + cushion %.0f ms (targetDepth) = %.0f ms deliberate. %@",
              negotiatedLatencyMs, requestedNote, cushion * 1000,
              Double(negotiatedLatencyMs) + cushion * 1000, verdict)
        #endif
    }

    /// ⚠️ THE MOST DANGEROUS OF THE THREE TO RUN STALE, which is why the generation check leads.
    /// Everything below configures the DISPLAY: `self.colorimetry` drives the scope headers and
    /// `SRTFrameRouter.activate` repoints the render route. A hop from a retired session that got
    /// here would set the live stream up with the DEAD one's format and colorimetry — PQ maths on
    /// a 709 stream, a route configured for dimensions nothing is sending — and it would not fail
    /// visibly. It would just be quietly, confidently wrong about the picture on screen.
    private func handleVideoFormat(generation: UInt64,
                                   _ format: ManifoldSRTVideoFormat,
                                   colorimetry: SRTFrameRouter.StreamColorimetry) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isCurrent(generation, "video format") else { return }
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
              + "BLACK until the sender's next keyframe (≈1s on OBS defaults). This is not a hang.")
    }

    /// The session thread has finished. Called on main, always after the decode side has already
    /// been released on that thread.
    private func handleSessionEnded(generation: UInt64,
                                    reason: ManifoldSRTEndReason, message: String?) {
        dispatchPrecondition(condition: .onQueue(.main))

        // ── TWO DIFFERENT QUESTIONS, AND BOTH HAVE TO BE ASKED ─────────────────────────────
        //
        // "IS THIS MINE?" — the generation. This callback was queued from the session thread
        // during that session's Stop, and a swap can install a REPLACEMENT before the queued block
        // gets to run. The old comment here claimed a manual disconnect meant "the queued tail of
        // the same event, nothing to do", inferring that from `session == nil`. That inference died
        // when `LiveSource.connectSRT` made SRT→SRT a swap: after a swap `session` is non-nil, but
        // it is the NEW session, and acting on it tore down a stream 20 ms into its life.
        //
        // "DOES A SESSION STILL EXIST?" — the nil check below. Still needed and NOT implied by the
        // generation: `connect` bumps the generation before `Create`, so a create or start failure
        // leaves the current generation live with no session behind it. `disconnect()` would then
        // run against nothing.
        guard isCurrent(generation, "session ended") else { return }
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
        //
        // ── THE JOIN IS ALSO WHY THE FRAME PATH NEEDS NO GENERATION TOKEN ────────────────
        // `onAccessUnit` is consumed inline on the session thread and is NOT generation-checked.
        // What makes that safe is exactly this line: it blocks until that thread has exited, so by
        // the time anything can stand a REPLACEMENT session up, no frame from this one is in
        // flight. The hopping callbacks needed tokens precisely because they escape that ordering;
        // the frame path does not escape it.
        //
        // ⚠️ IF THIS JOIN IS EVER MADE ASYNCHRONOUS — and there is a real reason to want that, since
        // stopping a session still inside `srt_connect` blocks main for up to SRTO_CONNTIMEO (3 s,
        // not the 200 ms RCVTIMEO bound that applies once receiving) — THAT PROTECTION VANISHES
        // WITH NO COMPILER ERROR AND NO CRASH. A retired stream's pictures would simply start
        // arriving in a live session's renderer. Generation-check `handleAccessUnit` in the same
        // change, or leave this synchronous.
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
            // ignored-parameter notice); `retireError` itself honours that distinction now, so the
            // condition that used to sit here would only be a second copy of it.
            retireError()
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

    /// ── A STREAM ID, MADE AS SAFE TO LOG AS IT CAN HONESTLY BE MADE ─────────────────────────
    ///
    /// SRT defines an access-control syntax for streamid — `#!::` followed by comma-separated
    /// `key=value` pairs (`u` user, `r` resource, `h` host, `m` mode, `t` type, `s` session). `s`
    /// IS A BEARER TOKEN: the server verifies the session against it, so anyone who reads it out of
    /// a log can present it. Its value is replaced here; every other key is kept, because the whole
    /// diagnostic point of logging a stream id is seeing which resource and user were addressed.
    ///
    /// ⚠️ WHAT THIS CANNOT PROMISE. A FREEFORM STREAM ID IS RETURNED UNCHANGED, AND MANY HOSTED
    /// INGESTS USE THE PUBLISH KEY ITSELF AS THE WHOLE STREAM ID. There is no syntax to detect that
    /// — `abc123` is indistinguishable from a channel name — so this function cannot make the
    /// freeform case safe, and does not pretend to. The log line is therefore NOT guaranteed to be
    /// credential-free; it is guaranteed only that the one place SRT explicitly says "this is a
    /// token" is not printed. A user pasting a key-shaped streamid is trusting the log the way they
    /// would trust a URL in a screen share.
    ///
    /// The value handed to `SRTO_STREAMID` is always the original — redaction is for the log only,
    /// and never touches what is dialled.
    static func redactedStreamId(_ streamId: String) -> String {
        let prefix = "#!::"
        guard streamId.hasPrefix(prefix) else { return streamId }
        let body = String(streamId.dropFirst(prefix.count))
        let redacted = body.split(separator: ",", omittingEmptySubsequences: false).map { pair -> String in
            // Split on the FIRST "=" only: a value may legitimately contain one.
            guard let eq = pair.firstIndex(of: "=") else { return String(pair) }
            let key = pair[pair.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "s" else { return String(pair) }
            return "\(pair[pair.startIndex..<eq])=(redacted)"
        }
        return prefix + redacted.joined(separator: ",")
    }

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
