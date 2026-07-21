//
//  WHEPClient.swift
//  Manifold
//
//  DEBUG-only WHEP client — step 2 of 4: THE HANDSHAKE.
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
//  Step 2 succeeds when the transport connects. There is no depacketization and no decode.
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
        NSLog("[WHEP] ───── step 2: handshake ─────")
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
                // DTLS is up. This is step 2's success condition.
                NSLog("[WHEP] connected — ICE + DTLS established in %@. Transport is up.", self.elapsed())
                NSLog("[WHEP] (step 2 ends here: no depacketization, no decode, no picture yet)")
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

        session.close()
        self.session = nil
        self.resourceURL = nil
        self.startedAt = nil
    }
}
#endif
