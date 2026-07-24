//
//  WHEPClient.swift
//  Manifold
//
//  DEBUG-only WHEP client — step 4 of 4: PICTURE.
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

#if DEBUG
import Foundation

final class WHEPClient {

    static let shared = WHEPClient()
    private init() {}

    // MARK: - Configuration

    /// The endpoint URL is a secret — it embeds the stream key — so it lives OUTSIDE the repo
    /// entirely rather than in a gitignored file inside it. A file that is not in the working
    /// tree cannot be committed by a stray `git add -f`, and cannot leak through an archive of
    /// the source directory.
    ///
    /// Two sources, env wins:
    ///   * `MANIFOLD_WHEP_URL` / `MANIFOLD_WHEP_STUN` — convenient in an Xcode scheme
    ///   * `~/.manifold-whep-config`:
    ///
    ///         url  = https://example.org/whep/<id>
    ///         stun = stun:stun.example.org:19302   # optional
    ///
    /// A bare line containing just the URL also works.
    ///
    /// (The target is not sandboxed — no app-sandbox entitlement — so NSHomeDirectory() is the
    /// real home directory, not a container.)
    struct Config {
        var endpoint: URL
        /// nil means no client-side STUN. This is the DEFAULT and is a legitimate setting, not
        /// a degraded one: a WHEP server returns its own candidates in the answer, so host
        /// candidates plus those are often enough. Only set `stun` if ICE fails to find a pair
        /// — any public STUN server will do, e.g. stun:stun.l.google.com:19302.
        var stunServer: String?
    }

    static let configPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".manifold-whep-config")

    private static func loadConfig() -> Config? {
        let env = ProcessInfo.processInfo.environment
        var urlString = env["MANIFOLD_WHEP_URL"].flatMap { $0.isEmpty ? nil : $0 }
        var stun = env["MANIFOLD_WHEP_STUN"].flatMap { $0.isEmpty ? nil : $0 }

        if let text = try? String(contentsOfFile: configPath, encoding: .utf8) {
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                var line = String(rawLine)
                if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
                line = line.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }

                guard let equals = line.firstIndex(of: "=") else {
                    // Tolerate a bare URL on its own line.
                    if urlString == nil, line.lowercased().hasPrefix("http") { urlString = line }
                    continue
                }
                let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if value.isEmpty { continue }
                switch key {
                case "url":  if urlString == nil { urlString = value }
                case "stun": if stun == nil { stun = value }
                default:     NSLog("[WHEP] ignoring unknown config key '%@'", key)
                }
            }
        }

        guard let urlString, let endpoint = URL(string: urlString), endpoint.host != nil else { return nil }
        return Config(endpoint: endpoint, stunServer: stun)
    }

    // MARK: - State

    private var session: ManifoldWHEPSession?
    private var resourceURL: URL?      // WHEP resource from the Location header, for DELETE
    private var startedAt: Date?

    /// Step 3b. Owned here, but touched ONLY on `session.decodeQueue` — see WHEPVideoDecoder's
    /// threading note. The two exceptions (`snapshot`, `requestStillExport`) are locked.
    private var decoder: WHEPVideoDecoder?
    private var decodeStatsTimer: Timer?
    private var previousDecodeStats = WHEPVideoDecoder.Stats()
    private var decodeStatsTicks = 0
    private var keyframeRequests = 0

    private func elapsed() -> String {
        guard let startedAt else { return "?" }
        return String(format: "%.2fs", Date().timeIntervalSince(startedAt))
    }

    // MARK: - Connect

    func connect() {
        dispatchPrecondition(condition: .onQueue(.main))

        guard session == nil else {
            NSLog("[WHEP] a session is already running — ⌃⌥⇧H to tear it down first")
            return
        }
        guard let config = Self.loadConfig() else {
            NSLog("""
                  [WHEP] no endpoint configured — nothing to connect to.
                  [WHEP]   Set MANIFOLD_WHEP_URL in the scheme's environment, or create %@ :
                  [WHEP]       url  = https://<your-whep-server>/<path>
                  [WHEP]       stun = stun:stun.l.google.com:19302   # optional; omit to try host-only first
                  """, Self.configPath)
            return
        }

        startedAt = Date()
        NSLog("[WHEP] ───── step 3a: receive RTP + depacketize to NALs ─────")
        // Host only. The path carries the stream key and must never reach a log.
        NSLog("[WHEP] endpoint host %@ (path withheld — it carries the stream key)",
              config.endpoint.host ?? "?")
        NSLog("[WHEP] client STUN: %@",
              config.stunServer ?? "none — host candidates + whatever the answer supplies")

        var createError: NSString?
        guard let session = ManifoldWHEPSession(stunServer: config.stunServer, error: &createError) else {
            NSLog("[WHEP] FAILED at PeerConnection create: %@", createError ?? "unknown")
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
        // The block runs on session.decodeQueue — already off libdatachannel's thread. It
        // captures the decoder strongly so a frame in flight at teardown still has one.
        session.onVideoAccessUnit = { avcc, sps, pps, parameterSetsChanged, keyframe, rtpTimestamp in
            decoder.decode(accessUnit: avcc,
                           sps: sps,
                           pps: pps,
                           parameterSetsChanged: parameterSetsChanged,
                           keyframe: keyframe,
                           rtpTimestamp: rtpTimestamp)
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
        startDecodeStatsTimer()

        session.onIceState = { [weak self] state, name in
            guard let self else { return }
            NSLog("[WHEP] ICE state → %@  (+%@)", name, self.elapsed())
            if state == .connected || state == .completed {
                let pair = self.session?.selectedCandidatePair() ?? "pair unavailable"
                NSLog("[WHEP] ICE %@ — selected pair: %@", name, pair)
            } else if state == .failed {
                NSLog("[WHEP] FAILED at ICE — no working candidate pair.")
                NSLog("[WHEP]   If this is a NAT'd network, try adding a STUN server to %@",
                      Self.configPath)
            }
        }

        session.onConnectionState = { [weak self] state, name in
            guard let self else { return }
            NSLog("[WHEP] pc state → %@  (+%@)", name, self.elapsed())
            switch state {
            case .connected:
                // DTLS is up — step 2's success condition, and step 3a's starting gun: RTP
                // begins flowing into the depacketizer the moment SRTP keys are derived.
                NSLog("[WHEP] connected — ICE + DTLS established in %@. Transport is up.", self.elapsed())
                NSLog("[WHEP] watching for RTP — the [WHEP-RTP] lines below are step 3a's checkpoint")
                NSLog("[WHEP] (still no decode and no picture: NALs are built and counted, then dropped)")
            case .failed:
                NSLog("[WHEP] FAILED at DTLS/transport.")
            case .disconnected, .closed:
                break
            default:
                break
            }
        }

        NSLog("[WHEP] building recvonly offer, gathering ICE candidates (non-trickle)…")
        session.generateRecvOnlyOffer(withTimeout: 15) { [weak self] offerSDP, error in
            guard let self else { return }
            guard let offerSDP else {
                NSLog("[WHEP] FAILED at offer/gathering: %@", error ?? "unknown")
                self.disconnect()
                return
            }
            let candidates = offerSDP.components(separatedBy: "a=candidate").count - 1
            NSLog("[WHEP] offer ready — %d bytes, %d candidate line(s), gathering took %@",
                  offerSDP.utf8.count, candidates, self.elapsed())
            if candidates == 0 {
                NSLog("[WHEP] WARNING: offer has zero candidates; the connection will not come up")
            }
            Task { await self.postOffer(offerSDP, to: config.endpoint) }
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

    private func startDecodeStatsTimer() {
        decodeStatsTimer?.invalidate()
        previousDecodeStats = WHEPVideoDecoder.Stats()
        decodeStatsTicks = 0
        keyframeRequests = 0
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

        // Nothing arriving is [WHEP-RTP]'s story to tell, not this one.
        guard now.accessUnitsReceived > was.accessUnitsReceived else { return }

        let decoded = now.framesDecoded - was.framesDecoded
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

        // Access units are arriving but nothing decodes. Two distinct causes, worth telling
        // apart in the log, and both fixed by the same thing: an IDR.
        if decoded == 0 {
            if !now.haveFormatDescription {
                NSLog("[WHEP-DECODE]   waiting for SPS/PPS — no format description yet")
            } else if now.awaitingKeyframe {
                NSLog("[WHEP-DECODE]   waiting for keyframe — slices dropped until the next IDR")
            }
            // Backstop only. The decoder now re-arms and requests a PLI itself on a mid-stream
            // decode failure (onNeedsKeyframe), and the bridge requests one while the
            // depacketizer has assembled no keyframe. This covers the remaining case — a
            // keyframe the decoder rejected, or one that arrived before the format description —
            // and routes through the SAME shared throttle in requestKeyframe, so within 250 ms
            // of the decoder's own request it is simply suppressed and never double-requests.
            // No lifetime cap now: the old `keyframeRequests < 5` went silent for the rest of the
            // session after five tries, which is exactly wrong for a recurring fault. The count
            // survives only to number the log line; the throttle does the gating.
            if (!now.haveFormatDescription || now.awaitingKeyframe), decodeStatsTicks % 2 == 0 {
                if session?.requestKeyframe() == true {
                    keyframeRequests += 1
                    NSLog("[WHEP-DECODE]   PLI request %d sent (backstop)", keyframeRequests)
                }
            }
        }
    }

    // MARK: - Signalling (WHEP: POST offer → 201 + answer)

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
            await MainActor.run { self.disconnect() }
            return
        }

        guard let http = response as? HTTPURLResponse else {
            NSLog("[WHEP] FAILED at POST — non-HTTP response")
            await MainActor.run { self.disconnect() }
            return
        }
        NSLog("[WHEP] HTTP %d — %d bytes back (+%@)", http.statusCode, data.count, elapsed())

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            NSLog("[WHEP] FAILED at POST — HTTP %d: %@", http.statusCode, String(body.prefix(500)))
            await MainActor.run { self.disconnect() }
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
            await MainActor.run { self.disconnect() }
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
            disconnect()
            return
        }
        NSLog("[WHEP] answer applied — ICE checks + DTLS handshake now in flight…")
    }

    // MARK: - Teardown

    func disconnect() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let session else { return }
        NSLog("[WHEP] tearing down (+%@)", elapsed())

        decodeStatsTimer?.invalidate()
        decodeStatsTimer = nil

        // Read the totals BEFORE close(), which frees the depacketizer they live in.
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
        self.session = nil
        self.resourceURL = nil
        self.startedAt = nil
    }
}
#endif
