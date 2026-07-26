//
//  WHEPClient.swift
//  Manifold
//
//  WHEP client — the streaming-URL transport behind the Stream Sources UI.
//
//  SHIPS IN RELEASE. The functional path (connect/disconnect, signalling, the media-stall watchdog,
//  the PLI backstop) is compiled in every configuration. Only the in-file [WHEP-*] diagnostics stay
//  behind #if DEBUG || MANIFOLD_TELEMETRY — see logDecodeStatsTick and disconnect().
//
//  Standard WHEP (draft-ietf-wish-whep), not a client for any particular server: POST the
//  recvonly SDP offer as `application/sdp`, read the SDP answer back from the response body,
//  apply it, watch ICE and DTLS come up. Nothing here assumes a vendor's URL layout, headers,
//  or response shape. It is TESTED against one server; it is not built for one.
//
//  Division of labour, per the step-2 plan: HTTP lives here in URLSession (Manifold already
//  does its HTTP this way — see LicenseManager). WebRTC lives in ManifoldWHEPSession, on the
//  far side of the pure-C bridge. This file never sees a libdatachannel type.
//
//  Step 2 succeeded when the transport connected. Step 3a adds the receive side, and it all
//  lives on the far side of the bridge: ManifoldWHEPSession attaches an RTP handler to the
//  recvonly video track and runs an RFC 6184 depacketizer over it, logging NAL counts under
//  `[WHEP-RTP]`. This file only starts it, and prints the totals on the way out.
//
//  Step 3a succeeds when those counts look like real H.264 — SPS/PPS/IDR present, slices
//  flowing, reassembly errors at zero.
//
//  Step 3b adds WHEPVideoDecoder: access units arrive on the session's decode queue and go
//  through VideoToolbox to CVPixelBuffers, counted under `[WHEP-DECODE]`. Success is that
//  counter tracking the stream rate at the right dimensions — plus ⌃⌥⇧E, which writes one
//  decoded frame to a PNG so "decoding" can be checked against actual pixels.
//
//  Step 4 puts it on screen. WHEPFrameRouter takes each decoded frame, promotes it into the
//  renderer's 10-bit domain, maps its RTP sender timestamp through LiveClock, and enqueues it
//  on the same MetalVideoRenderer the file and NDI paths feed. This file's part is only the
//  wiring and the lifecycle: install the route before the answer (RTP can arrive the instant
//  DTLS completes), release it before the decoder is torn down. Success is live pixels.
//

import Combine
import Foundation
import QuartzCore      // CACurrentMediaTime — the monotonic host clock the media watchdog measures on

final class WHEPClient: ObservableObject {

    static let shared = WHEPClient()
    private init() {}

    /// Published connection state — the WHEP analog of NDIService.isConnected, and the only
    /// cross-module signal that WHEP is a live source. ContentView folds it into `hasSource` so the
    /// empty-state overlay hides while
    /// WHEP drives the shared renderer, exactly as it does for NDI. Set true when WHEP takes the
    /// display in connect(); cleared by disconnect() and by any spontaneous transport
    /// failure/close, so it cannot stick true. Main-thread only — connect()/disconnect() assert
    /// main and the pc-state callback is delivered on main, which is what @Published requires.
    @Published private(set) var isConnected = false

    /// User-facing connection error, published so the UI can surface a failed connect without the
    /// user reading the Xcode log. Carries the SERVER'S OWN message where there is one (e.g.
    /// Cloudflare's "Live broadcast not started yet" on a 409 — it tells the user the fix), else a
    /// clear generic. REDACTION HOLDS: it never contains the full URL (host at most), the same rule
    /// the logs follow. Set at each failure site on the main thread BEFORE teardown; cleared at the
    /// start of a fresh connect() and on a successful `.connected`. disconnect() does NOT touch it,
    /// so a failure that ends in disconnect() leaves the message standing for the UI to show.
    @Published private(set) var lastError: String?

    /// Dismiss a shown connection error (the banner's close button).
    func clearError() { lastError = nil }

    // MARK: - State

    private var session: ManifoldWHEPSession?
    private var resourceURL: URL?      // WHEP resource from the Location header, for DELETE
    private var startedAt: Date?

    /// Step 3b. Owned here, but touched ONLY on `session.decodeQueue` — see WHEPVideoDecoder's
    /// threading note. The two exceptions (`snapshot`, `requestStillExport`) are locked.
    private var decoder: WHEPVideoDecoder?

    /// RTP-timestamp unwrapping, which is WHEP's problem and not the decoder's — see
    /// RTPTimestampUnwrapper. Built fresh in `connect()` and released in `disconnect()`, so the
    /// instance's lifetime IS the connection's and there is no separate reset to forget. Like
    /// `decoder`, owned here but touched only on `session.decodeQueue`, from the
    /// `onVideoAccessUnit` closure below.
    private var rtpUnwrapper: RTPTimestampUnwrapper?

    private var decodeStatsTimer: Timer?
    private var previousDecodeStats = WHEPVideoDecoder.Stats()
    private var decodeStatsTicks = 0
    private var keyframeRequests = 0

    /// Bounded backstop for a stuck `.disconnected`. WebRTC treats `.disconnected` as transient and
    /// normally recovers to `.connected` within a second or two, so we do NOT tear down on it. But
    /// we have not observed that libdatachannel always escalates a genuinely dead link to `.failed`,
    /// and if it doesn't, `isConnected` would stay true over a frozen picture with no way back to the
    /// empty state. If the connection sits disconnected past this window without recovering, we treat
    /// it as failed ourselves. Main-thread only, cancelled on recovery and on any teardown.
    private static let disconnectRecoveryWindow: TimeInterval = 10
    private var disconnectBackstop: DispatchWorkItem?

    /// Media-stall watchdog window — a DIFFERENT fault from the transport backstop above. Here the
    /// link is healthy — ICE connected, DTLS up — but the publisher (OBS, a DC Color Live session)
    /// stopped and Cloudflare's SFU holds the subscriber session open carrying no media. Nothing
    /// fires (.closed/.failed/.disconnected all stay silent, so the 10s backstop never arms either),
    /// so without this the picture freezes on its last frame with isConnected stuck true and ⌃⌥H
    /// dead (connect() guards on session == nil). LONGER than disconnectRecoveryWindow (10s) on
    /// purpose: it must tolerate what a healthy transport legitimately does — an encoder stall, a
    /// long scene change, a brief source gap — none of which are a dead session. The transport
    /// backstop grants no such tolerance because it does not need to: a link sitting .disconnected
    /// for 10s is simply failed. Measured from the last DECODED frame — see logDecodeStatsTick.
    private static let mediaStallWindow: TimeInterval = 15
    /// Watchdog state, main-thread only (it runs on the decode-stats timer): the framesDecoded count
    /// at, and the monotonic host time of, the last tick that saw the count advance. Armed lazily on
    /// the first frame (framesDecoded > 0); reset in startDecodeStatsTimer for the next connection.
    private var mediaWatchdogLastFrames = 0
    private var mediaWatchdogSinceHost: CFTimeInterval = 0

    private func elapsed() -> String {
        guard let startedAt else { return "?" }
        return String(format: "%.2fs", Date().timeIntervalSince(startedAt))
    }

    // MARK: - Connect

    /// Connect to a WHEP endpoint. The URL is supplied by the caller (a saved bookmark or the paste
    /// field) — never sourced internally: the old ~/.manifold-whep-config dotfile and the
    /// MANIFOLD_WHEP_URL/STUN environment variables are gone, so a shipping app reads no connection
    /// backdoor from the user's home directory.
    /// ⚠️ REACHABLE ONLY THROUGH `LiveSource.connectWeb` — the `Arbitration` argument cannot be
    /// constructed outside LiveSource.swift, so no other call site compiles. Any live NDI or SRT
    /// source has been retired by the time this runs.
    func connect(to url: URL, arbitratedBy _: LiveSource.Arbitration) {
        dispatchPrecondition(condition: .onQueue(.main))

        // WEB→WEB IS STILL A REFUSAL, and deliberately unchanged by the arbitration pass:
        // `connectWeb` passes `except: .web`, so a live WHEP session reaches this guard intact and
        // a second connect refuses. SRT's equivalent refusal was removed because its teardown can be
        // JOINED (see SRTClient.disconnect's ORDER note) and a swap is therefore definable; WHEP's
        // cannot be, so making this a swap is a change to WHEP's own lifecycle and belongs with that
        // work, not with this one. Named here so the asymmetry is visible rather than looking like
        // an oversight.
        //
        // BUT IT REFUSES VISIBLY. It used to return after an NSLog, so from the user's side picking
        // a second bookmark did nothing whatsoever: no picture change, no message, no sign the click
        // had registered — indistinguishable from a bug, and unlike SRT's old refusal this pair is
        // reachable in RELEASE, from the shipping bookmark menu. The banner stands until the user
        // dismisses it or starts another attempt: nothing clears `lastError` on the strength of the
        // EXISTING stream continuing to play, because that stream is the reason for the message,
        // not evidence against it.
        guard session == nil else {
            NSLog("[WHEP] a session is already running — disconnect it first")
            lastError = "A web stream is already connected — disconnect it before connecting another."
            return
        }
        lastError = nil   // fresh attempt — clear any error banner from a previous try
        // Defensive last gate before the network: the store already validated scheme + host, but
        // connect must not trust that, and must never be handed an srt:// / .m3u8 URL to dial.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else {
            NSLog("[WHEP] refusing to connect — not an http(s) stream URL")
            lastError = "That isn’t a web stream URL."
            return
        }

        startedAt = Date()
        NSLog("[WHEP] ───── connecting: receive RTP + depacketize to NALs ─────")
        // Host only. The path carries the stream key and must never reach a log.
        NSLog("[WHEP] endpoint host %@ (path withheld — it carries the stream key)", url.host ?? "?")

        var createError: NSString?
        // No client STUN: a WHEP server returns its own candidates in the answer, and host
        // candidates plus those are enough on the networks this targets. (The per-config STUN
        // override went away with the dotfile; if ICE ever needs it, it becomes a per-bookmark
        // field, not a home-directory backdoor.)
        guard let session = ManifoldWHEPSession(stunServer: nil, error: &createError) else {
            NSLog("[WHEP] FAILED at PeerConnection create: %@", createError ?? "unknown")
            lastError = "Couldn’t start the connection."
            return
        }
        self.session = session

        // ── Step 3b: the decoder, wired before the answer is applied ────────────────────
        //
        // Ordering is not incidental: `onVideoAccessUnit` must be in place before
        // setRemoteAnswer, because RTP can start arriving the instant DTLS completes, and an
        // access unit delivered with no handler installed is simply dropped on the floor.
        let decoder = WHEPVideoDecoder()
        self.decoder = decoder
        // Fresh per connection: the previous stream's wrap accumulator and origin must not
        // carry over into this one.
        let unwrapper = RTPTimestampUnwrapper()
        self.rtpUnwrapper = unwrapper
        // The block runs on session.decodeQueue — already off libdatachannel's thread. It
        // captures the decoder and the unwrapper strongly so a frame in flight at teardown
        // still has both. This is also the only site that touches the unwrapper: once per
        // access unit, in arrival order, on one thread, which is exactly what its state needs.
        session.onVideoAccessUnit = { avcc, sps, pps, parameterSetsChanged, keyframe, rtpTimestamp in
            decoder.decode(accessUnit: avcc,
                           sps: sps,
                           pps: pps,
                           parameterSetsChanged: parameterSetsChanged,
                           keyframe: keyframe,
                           pts: unwrapper.unwrap(rtpTimestamp),
                           // RTP carries no decode timestamp for H.264 — every access unit is
                           // handed over in decode order with nothing to say about display
                           // order. `.invalid` is CoreMedia's word for exactly that, and is
                           // what this path has always sent.
                           dts: .invalid)
        }
        // ── Step 4: decoded frames → the display ────────────────────────────────────────
        //
        // Also wired BEFORE the answer, and activated before it too (below), for the same
        // reason the decoder is: with no clock installed, `deliver` counts the frame and
        // drops it, so a frame racing the handshake would be lost rather than displayed.
        // `pts` is the sender timeline — the unwrapped RTP 90 kHz clock (see deliver).
        decoder.onDecodedFrame = { pixelBuffer, pts in
            WHEPFrameRouter.shared.deliver(pixelBuffer, pts: pts)
        }
        // The decoder fires this on session.decodeQueue when it needs an IDR it does not have:
        // no format description yet, the startup keyframe gate still closed, or — the case this
        // wiring is really for — a mid-stream decode failure that just re-armed that gate
        // (WHEPVideoDecoder.handleDecoded, Surface 2). HOP TO MAIN: requestKeyframe and the
        // bridge's _closed/_videoTrack lifecycle are main-thread state (see requestKeyframe's
        // assert), and routing every PLI through main is what lets the shared throttle there
        // stay lock-free. The gate means this fires about once per freeze, not once per frame,
        // so the async hop is free; the throttle collapses any overlap with the two stats-timer
        // triggers, so it never double-requests. Weak self: if the client is gone, so is the
        // need for a keyframe.
        decoder.onNeedsKeyframe = { [weak self] in
            DispatchQueue.main.async {
                _ = self?.session?.requestKeyframe()
            }
        }
        // WHEP takes the display, retiring whatever else is driving it. Mirrors NDI's
        // takeover; for this first-light there is no source-switching UI, so connecting
        // WHEP simply shows WHEP.
        WHEPFrameRouter.shared.activate()
        // WHEP now owns the renderer (activate() stopped any loaded file via onWillActivateStream):
        // from here it IS the active source. Publish that BEFORE the async handshake below, or the
        // empty state would flash over the black takeover screen until DTLS comes up. Cleared on
        // every teardown/failure path — see disconnect() and onConnectionState.
        isConnected = true
        startDecodeStatsTimer()

        session.onIceState = { [weak self] state, name in
            guard let self else { return }
            NSLog("[WHEP] ICE state → %@  (+%@)", name, self.elapsed())
            if state == .connected || state == .completed {
                let pair = self.session?.selectedCandidatePair() ?? "pair unavailable"
                NSLog("[WHEP] ICE %@ — selected pair: %@", name, pair)
            } else if state == .failed {
                NSLog("[WHEP] FAILED at ICE — no working candidate pair.")
                NSLog("[WHEP]   On a NAT'd network the host candidates plus the server's answer found no route.")
                self.lastError = "Couldn’t find a network route to the stream (it may be behind a firewall)."
            }
        }

        session.onConnectionState = { [weak self] state, name in
            guard let self else { return }
            NSLog("[WHEP] pc state → %@  (+%@)", name, self.elapsed())
            switch state {
            case .connected:
                // DTLS is up — step 2's success condition, and step 3a's starting gun: RTP
                // begins flowing into the depacketizer the moment SRTP keys are derived.
                // Recovery (including .disconnected→.connected) — stand down the stuck-disconnect backstop.
                self.cancelDisconnectBackstop()
                self.lastError = nil   // success — clear any error from an earlier attempt
                NSLog("[WHEP] connected — ICE + DTLS established in %@. Transport is up.", self.elapsed())
                NSLog("[WHEP] watching for RTP — the [WHEP-RTP] lines below are step 3a's checkpoint")
                NSLog("[WHEP] (still no decode and no picture: NALs are built and counted, then dropped)")
            case .failed:
                NSLog("[WHEP] FAILED at DTLS/transport.")
                // Keep a more specific ICE message if one was already set (ICE .failed fires first in
                // that cascade); otherwise a clear generic.
                self.lastError = self.lastError ?? "The connection to the stream failed."
                // A spontaneous transport failure does not route through disconnect() on its own,
                // so the source flag would stick true. Tear down: clears isConnected, releases the
                // display, and frees the session so ⌃⌥H can retry (connect() guards on session==nil).
                // disconnect() also cancels the backstop below.
                self.disconnect()
            case .disconnected:
                // Transient — may still recover to .connected, so we do NOT tear down here (that would
                // kill sessions that recover) and leave the source live so a brief blip does not flash
                // the empty state. But arm a BOUNDED backstop: if it never recovers and never escalates
                // to .failed, treat it as failed after disconnectRecoveryWindow so isConnected cannot
                // stay true over a dead picture.
                self.scheduleDisconnectBackstop()
            case .closed:
                // Far-side close (our own teardown nils these callbacks first, so this only arrives
                // from the peer — the server ended the stream, the resource expired, and so on).
                // Route it through the SAME teardown .failed uses, NOT a bare `isConnected = false`:
                // that alone left the last decoded frame frozen on screen (clearToBlack, in
                // deactivate(), never ran) AND leaked the session, so the next ⌃⌥H could not reconnect
                // (connect() guards on session == nil). disconnect() clears the flag, wipes the
                // picture, frees the session, and stands down the backstop — and is idempotent, so a
                // teardown that has already run makes this a no-op.
                self.disconnect()
            default:
                break
            }
        }

        NSLog("[WHEP] building recvonly offer, gathering ICE candidates (non-trickle)…")
        session.generateRecvOnlyOffer(withTimeout: 15) { [weak self] offerSDP, error in
            guard let self else { return }
            guard let offerSDP else {
                NSLog("[WHEP] FAILED at offer/gathering: %@", error ?? "unknown")
                self.lastError = "Couldn’t set up the connection (no network route)."
                self.disconnect()
                return
            }
            let candidates = offerSDP.components(separatedBy: "a=candidate").count - 1
            NSLog("[WHEP] offer ready — %d bytes, %d candidate line(s), gathering took %@",
                  offerSDP.utf8.count, candidates, self.elapsed())
            if candidates == 0 {
                NSLog("[WHEP] WARNING: offer has zero candidates; the connection will not come up")
            }
            Task { await self.postOffer(offerSDP, to: url) }
        }
    }

    // MARK: - Decode instrumentation (step 3b's checkpoint)

    /// Arms a one-shot PNG of the next decoded frame (⌃⌥⇧E). The counter proves NALs became
    /// frames; this proves the frames are a picture.
    func exportNextDecodedFrame() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let decoder else {
            NSLog("[WHEP-DECODE] no session — ⌃⌥H to connect first")
            return
        }
        decoder.requestStillExport()
    }

    // MARK: - Stuck-disconnect backstop (main thread only)

    /// Arm (or re-arm) the bounded `.disconnected` backstop. Cancels any prior one first, so the
    /// window is measured from the most recent `.disconnected`. Fires at most once; the `guard`
    /// makes it a no-op if it was cancelled out from under a firing that had already begun.
    private func scheduleDisconnectBackstop() {
        dispatchPrecondition(condition: .onQueue(.main))
        cancelDisconnectBackstop()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.disconnectBackstop != nil else { return }
            self.disconnectBackstop = nil
            NSLog("[WHEP] disconnected for %.0fs without recovery — treating as failed",
                  Self.disconnectRecoveryWindow)
            self.disconnect()   // same teardown .failed runs; clears isConnected, frees the session
        }
        disconnectBackstop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.disconnectRecoveryWindow, execute: work)
    }

    /// Stand the backstop down. Safe to call when none is armed. Called on recovery to `.connected`,
    /// on `.closed`, and from disconnect() — so a fire cannot happen after teardown has run.
    private func cancelDisconnectBackstop() {
        disconnectBackstop?.cancel()
        disconnectBackstop = nil
    }

    private func startDecodeStatsTimer() {
        decodeStatsTimer?.invalidate()
        previousDecodeStats = WHEPVideoDecoder.Stats()
        decodeStatsTicks = 0
        keyframeRequests = 0
        // Disarm the media watchdog for the fresh connection — it re-arms on this stream's first
        // frame, not here (see logDecodeStatsTick).
        mediaWatchdogLastFrames = 0
        mediaWatchdogSinceHost = 0
        decodeStatsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.logDecodeStatsTick()
        }
    }

    private func logDecodeStatsTick() {
        guard let decoder else { return }
        let now = decoder.snapshot()
        let was = previousDecodeStats
        previousDecodeStats = now
        decodeStatsTicks += 1

        // ── MEDIA-STALL WATCHDOG ─────────────────────────────────────────────────────────────
        // Runs BEFORE the AU guard below on purpose: a media stall means NO access units are
        // arriving, so that guard's early return would skip this exact case on every tick.
        //
        // Signal is framesDecoded — the single monotonic counter EVERY decoded frame increments
        // (WHEPVideoDecoder.handleDecoded, 1:1 with the onDecodedFrame that reaches the screen),
        // read here through the same locked snapshot the stats already take: no per-frame work, no
        // new cross-thread field. ARMS ONLY once framesDecoded > 0 — the first frame — so a
        // connection that never delivers one is left to the startup path (PLI retries, preIDR
        // gating), not killed here. Stamped whenever the count advances; if it sits still for
        // mediaStallWindow while armed, tear down through the SAME disconnect() every other path
        // uses — which also invalidates THIS timer (safe from inside its own callback), so the
        // watchdog cannot fire again or twice, and cancels the .disconnected backstop for free.
        if now.framesDecoded > 0 {
            if now.framesDecoded > mediaWatchdogLastFrames {
                mediaWatchdogLastFrames = now.framesDecoded
                mediaWatchdogSinceHost = CACurrentMediaTime()
            } else if CACurrentMediaTime() - mediaWatchdogSinceHost >= Self.mediaStallWindow {
                NSLog("[WHEP] no media for %.0fs on a healthy transport — publisher likely stopped; tearing down",
                      Self.mediaStallWindow)
                lastError = "The stream stopped sending video (the broadcaster may have ended it)."
                disconnect()
                return
            }
        }

        // Nothing arriving at all: no PLI to send, and the diagnostics below have nothing to report.
        // Total silence is the media watchdog's job (handled above). This guard ALSO gates the PLI
        // backstop, which is correct — there is nothing to decode when no AUs are arriving. SHIPPING.
        guard now.accessUnitsReceived > was.accessUnitsReceived else { return }

        let decoded = now.framesDecoded - was.framesDecoded

        // ── STARTUP/RECOVERY PLI BACKSTOP (LOAD-BEARING — ships in Release) ──────────────────────
        // Access units are arriving but nothing is decoding — no format description yet, or the
        // keyframe gate is closed. Ask for an IDR, throttled to every other tick. Pulled OUT of the
        // diagnostic logging below so it is unmistakably on the shipping path; only its log line is
        // telemetry. The decoder/bridge request PLIs on their own too; this covers a keyframe that
        // was rejected or arrived before the format description, via the SAME throttle in
        // requestKeyframe (so within 250 ms of the decoder's own request it is simply suppressed).
        if decoded == 0, (!now.haveFormatDescription || now.awaitingKeyframe), decodeStatsTicks % 2 == 0 {
            if session?.requestKeyframe() == true {
                #if DEBUG || MANIFOLD_TELEMETRY
                keyframeRequests += 1
                NSLog("[WHEP-DECODE]   PLI request %d sent (backstop)", keyframeRequests)
                #endif
            }
        }

        // ── DIAGNOSTIC DECODE STATS (telemetry-only) ─────────────────────────────────────────────
        #if DEBUG || MANIFOLD_TELEMETRY
        let accessUnits = now.accessUnitsReceived - was.accessUnitsReceived
        NSLog("""
              [WHEP-DECODE] +%ds  decoded=%d/s (total=%d)  %dx%d %@  |  AUs=%d/s  \
              dropped: preIDR=%d noFmt=%d sbFail=%d  |  errors=%d
              """,
              decodeStatsTicks, decoded, now.framesDecoded,
              now.width, now.height, WHEPVideoDecoder.formatName(now.pixelFormat),
              accessUnits,
              now.droppedAwaitingKeyframe - was.droppedAwaitingKeyframe,
              now.droppedNoFormatDescription - was.droppedNoFormatDescription,
              now.sampleBufferFailures - was.sampleBufferFailures,
              now.decodeErrors - was.decodeErrors)

        if now.decodeErrors > was.decodeErrors {
            NSLog("[WHEP-DECODE]   last decode error: %d", now.lastDecodeError)
        }

        // Access units arriving but nothing decoding — name the cause the PLI above is chasing.
        if decoded == 0 {
            if !now.haveFormatDescription {
                NSLog("[WHEP-DECODE]   waiting for SPS/PPS — no format description yet")
            } else if now.awaitingKeyframe {
                NSLog("[WHEP-DECODE]   waiting for keyframe — slices dropped until the next IDR")
            }
        }
        #endif
    }

    // MARK: - Signalling (WHEP: POST offer → 201 + answer)

    /// Turn a server error-response BODY into a user-facing line, or nil if there is nothing usable.
    /// Prefers a known human field from a JSON body, else the trimmed plain text (Cloudflare's 409 is
    /// plain "Live broadcast not started yet"). Length-capped. The body is the SERVER's own text — it
    /// does not carry our endpoint URL — and it is never concatenated with the URL.
    private static func serverMessage(fromBody body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        func cap(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count > 200 ? String(t.prefix(200)) + "…" : t
        }
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["errorDescription", "error", "message", "detail", "reason"] {
                if let s = obj[key] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                    return cap(s)
                }
            }
            return nil   // JSON with no known human field — don't dump raw JSON at the user
        }
        return cap(trimmed)
    }

    private func postOffer(_ offer: String, to endpoint: URL) async {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.setValue("application/sdp", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        request.httpBody = Data(offer.utf8)

        NSLog("[WHEP] POSTing offer (%d bytes)…", request.httpBody?.count ?? 0)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            NSLog("[WHEP] FAILED at POST — %@", error.localizedDescription)
            let host = endpoint.host ?? "the stream server"
            await MainActor.run { self.lastError = "Couldn’t reach \(host)."; self.disconnect() }
            return
        }

        guard let http = response as? HTTPURLResponse else {
            NSLog("[WHEP] FAILED at POST — non-HTTP response")
            await MainActor.run {
                self.lastError = "The stream server gave an unexpected response."
                self.disconnect()
            }
            return
        }
        NSLog("[WHEP] HTTP %d — %d bytes back (+%@)", http.statusCode, data.count, elapsed())

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            NSLog("[WHEP] FAILED at POST — HTTP %d: %@", http.statusCode, String(body.prefix(500)))
            // Surface the SERVER'S message where it has one (e.g. Cloudflare's "Live broadcast not
            // started yet" on 409 — it tells the user the fix); else a clear status-coded generic.
            let message = Self.serverMessage(fromBody: body)
                ?? "The stream server refused the connection (HTTP \(http.statusCode))."
            await MainActor.run { self.lastError = message; self.disconnect() }
            return
        }
        // WHEP specifies 201 Created. Accept any 2xx carrying an SDP body rather than being
        // stricter than the servers are — but say so, because a non-201 is worth noticing.
        if http.statusCode != 201 {
            NSLog("[WHEP] note: WHEP specifies 201 Created; this server returned %d — continuing",
                  http.statusCode)
        }

        // The WHEP resource, for DELETE at teardown. Relative URLs are legal here.
        if let location = http.value(forHTTPHeaderField: "Location"),
           let resolved = URL(string: location, relativeTo: endpoint)?.absoluteURL {
            await MainActor.run { self.resourceURL = resolved }
            NSLog("[WHEP] resource Location received (will DELETE on teardown)")
        } else {
            NSLog("[WHEP] note: no Location header — cannot DELETE the session on teardown")
        }

        guard let answer = String(data: data, encoding: .utf8), answer.contains("v=0") else {
            NSLog("[WHEP] FAILED at answer — body is not SDP (%d bytes)", data.count)
            await MainActor.run {
                self.lastError = "The stream server’s response wasn’t a valid stream."
                self.disconnect()
            }
            return
        }
        NSLog("[WHEP] answer SDP received — %d bytes", answer.utf8.count)

        await MainActor.run { self.applyAnswer(answer) }
    }

    private func applyAnswer(_ answer: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let session else { return }
        var error: NSString?
        guard session.setRemoteAnswer(answer, error: &error) else {
            NSLog("[WHEP] FAILED at setRemoteDescription: %@", error ?? "unknown")
            lastError = "Couldn’t negotiate the stream with the server."
            disconnect()
            return
        }
        NSLog("[WHEP] answer applied — ICE checks + DTLS handshake now in flight…")
    }

    // MARK: - Teardown

    func disconnect() {
        dispatchPrecondition(condition: .onQueue(.main))
        // Clear the source flag FIRST, before the no-session early-out below, so a redundant
        // disconnect — or one after a connect that failed before a session existed — can never
        // leave `isConnected` stuck true. Stand down the .disconnected backstop in the same breath,
        // so it can never fire after teardown has already run (both are main-thread only).
        isConnected = false
        cancelDisconnectBackstop()
        guard let session else { return }
        NSLog("[WHEP] tearing down (+%@)", elapsed())

        decodeStatsTimer?.invalidate()
        decodeStatsTimer = nil

        // Session totals — diagnostic-only. Read BEFORE close(), which frees the depacketizer they
        // live in (so the read must stay inside this gate, not just the logging).
        #if DEBUG || MANIFOLD_TELEMETRY
        if let summary = session.rtpStatsSummary() {
            NSLog("[WHEP-RTP] session totals: %@", summary)
        } else {
            NSLog("[WHEP-RTP] session totals: no RTP was ever received")
        }
        if let decoder {
            let stats = decoder.snapshot()
            NSLog("""
                  [WHEP-DECODE] session totals: %d access units → %d frames decoded (%dx%d %@) | \
                  dropped: preIDR=%d noFmt=%d sbFail=%d | errors=%d | \
                  formatDescriptions=%d sessions=%d
                  """,
                  stats.accessUnitsReceived, stats.framesDecoded,
                  stats.width, stats.height, WHEPVideoDecoder.formatName(stats.pixelFormat),
                  stats.droppedAwaitingKeyframe, stats.droppedNoFormatDescription,
                  stats.sampleBufferFailures, stats.decodeErrors,
                  stats.formatDescriptionBuilds, stats.sessionBuilds)
        }
        #endif

        // WHEP teardown is DELETE on the resource. Fire-and-forget: the local side goes away
        // regardless, but a compliant client should not leave the session dangling server-side.
        if let resourceURL {
            var request = URLRequest(url: resourceURL)
            request.httpMethod = "DELETE"
            request.timeoutInterval = 5
            Task {
                if let (_, response) = try? await URLSession.shared.data(for: request),
                   let http = response as? HTTPURLResponse {
                    NSLog("[WHEP] DELETE resource → HTTP %d", http.statusCode)
                }
            }
        }

        // Release the display FIRST (on main, where we already are): the renderer's clock and
        // depth hook stop pointing at a LiveClock that is about to go away, and the screen is
        // wiped. Frames still in flight on the decode queue then find no clock and are dropped
        // by `deliver`, which is exactly the intended behaviour.
        WHEPFrameRouter.shared.deactivate()

        // ORDER MATTERS. close() clears onVideoAccessUnit, so nothing new reaches the decode
        // queue; the decoder is then torn down ON that queue, which puts it behind every
        // frame already in flight. Invalidating it from here instead would pull a
        // VTDecompressionSession out from under a decode in progress. The router's promote
        // session + pool are decode-queue-owned too, so they are released in the same block,
        // behind the same in-flight frames.
        let decodeQueue = session.decodeQueue
        session.close()
        if let decoder {
            decodeQueue.async {
                decoder.invalidate()
                WHEPFrameRouter.shared.releaseResources()
            }
        } else {
            decodeQueue.async { WHEPFrameRouter.shared.releaseResources() }
        }

        self.decoder = nil
        // Dropped here rather than reset: the closure holding the last reference dies with
        // the session, so the next connect() starts from a genuinely new accumulator.
        self.rtpUnwrapper = nil
        self.session = nil
        self.resourceURL = nil
        self.startedAt = nil
    }
}
