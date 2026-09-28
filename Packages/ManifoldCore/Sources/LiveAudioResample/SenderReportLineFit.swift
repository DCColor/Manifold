//
//  SenderReportLineFit.swift
//  LiveAudioResample
//
//  Build step 4e-2 of docs/AUDIO_RESAMPLER_DESIGN.md §7: the WHEP audio↔video line from RTCP Sender
//  Reports (§2.6), fitted per session and handed to the steering as its target (§2.8).
//
//  ── WHAT IS FITTED ────────────────────────────────────────────────────────────────────────────
//
//  One point per SR pair (one audio SR and one video SR, each used once):
//
//      Δ = [ ntp_a + (T_a0 − rtp_a)/48000 ] − [ ntp_v + (T_v0 − rtp_v)/90000 ]
//      x = (rtp_v − T_v0)/90000                     the video content time the pair describes
//
//  T_a0 / T_v0 are the raw RTP timestamps the receivers rebase to zero, so video PTS is
//  (rtp_v − T_v0)/90000 and audio PTS is (rtp_a − T_a0)/48000. Extrapolating the audio SR to the
//  video SR's NTP instant at the nominal rate, the audio PTS of the content captured with video PTS x
//  is x − Δ. So Δ(x) IS the offset: "how far behind the mapping's senderPTS this transport stamps its
//  audio", `cushion`'s definition. The extrapolation costs (clock error) × |ntp_a − ntp_v|, which is
//  ≤ 100 ppm × 1 s = 0.1 ms on the servers measured, and 0 on Cloudflare (bit-identical NTP).
//
//  x is VIDEO CONTENT TIME, not host time, because the target is evaluated at the mapping's
//  `senderPTS`, which is video content time. No host clock enters the fit.
//
//  ── THE TWO TIMESCALES (§2.6, "FIT WINDOW CHOSEN") ────────────────────────────────────────────
//
//    slope b   least squares over the last `slopeWindow` (600 s) of pairs; used only once its own
//              standard error is ≤ `slopeStandardErrorBound`, until then b = 0
//    offset a  the mean residual about the in-use slope over the last `offsetWindow` (60 s)
//
//      offset(x) = a + b·(x − x̄₆₀)
//
//  A noisier sender reaches the SE bound later, so it gets the longer effective slope window — the
//  "sized from the measured residual sd" rule. Nothing here knows or asks which server it is.
//
//  ── THE NUMBERS, AND WHERE EACH COMES FROM ────────────────────────────────────────────────────
//
//  * slope SE bound 10 ppm. The slope reaches lip-sync only by extrapolating the offset from the
//    centre of its 60 s window to now: ≤ 30 s, plus one SR interval (≤ 7.5 s: RFC 3550 §6.3.1
//    randomises the 5 s minimum over [0.5, 1.5]). At 2σ, 10 ppm × 2 × 37.5 s = 0.75 ms, under half
//    of Cloudflare's measured ~2 ms offset wander floor (§2.6) and 1/20 of §5.3's ±15 ms. It is also
//    §2.2's stated condition for a measured slope, so the document carries one number, not two.
//    Released only above 2× the bound, so a slope hovering at the bound does not toggle.
//  * slope clamp ±150 ppm, §2.2's (2.3× the largest slope measured).
//  * the SE is the white-noise OLS SE × √v, v the batch-means variance ratio of the residuals in
//    30 s batches (≥ 4 batches, else "not yet"). Cloudflare's residual is not white (block means level
//    off at ~2 ms from 60 s out), and a white-noise SE would claim a precision the data does not have.
//  * outliers: |residual| > 5 × max(s, 1/48000 s), s the residual sd about the slope fit, once ≥ 10
//    pairs are in it. Gaussian false-rejection rate 5.7e-7 per pair — one per ~20 days at 1 pair/s.
//    The floor is the audio timestamp quantum, so a clean sender (6.7 µs sd) does not reject jitter
//    smaller than one sample.
//  * a step: 8 consecutive rejections whose own sd is within the bound → the fit restarts from them.
//  * unstable: the offset's own SE (s₆₀/√n₆₀) > 5 ms (a third of §5.3's ±15 ms; Cloudflare measures
//    ~9.5/√60 ≈ 1.2 ms, 4× inside), or ≥ 5 scattered rejections in the last 20 pairs (a consecutive
//    run is the step test's), or 8 consecutive rejections that are not self-consistent → hold the
//    last good line, or 0 if none was ever good.
//  * a gap: no pair for 10 s of video content time (> the 7.5 s longest compliant SR interval) →
//    logged; the last line keeps extrapolating on its in-use slope.
//
//  "Good" means verified: ≥ 10 pairs in the offset window and none of the unstable conditions. The
//  first pair's line is used at once (the first offset comes from the first pair, §2.7) but it is
//  provisional until verified, which is what makes "0 if none" reachable: a sender whose SRs are
//  noise from the start never had a good line.
//

import Foundation

/// How a live session's audio and video timelines are related — the one question that decides
/// whether a Sender Report line exists at all (§2.6, last paragraph).
public enum LiveAVTimeline: Sendable, Equatable {
    /// RFC 3550: audio and video are separate RTP streams with independent random timestamp bases,
    /// related only through their Sender Reports' common NTP axis.
    case rtpSenderReports
    /// Audio and video already share one timeline. Nothing to fit, and nothing is constructed.
    case oneTimeline(String)
}

public final class SenderReportLineFit: @unchecked Sendable {

    public enum Stream: String, Sendable { case audio, video }

    public struct Parameters: Sendable {
        public var audioClockRate: Int64 = 48_000     // RFC 7587: Opus RTP is always 48 kHz
        public var videoClockRate: Int64 = 90_000     // RFC 6184 §8.2.1
        public var slopeWindow = 600.0
        public var offsetWindow = 60.0
        public var slopeStandardErrorBound = 10e-6
        public var slopeReleaseBound = 20e-6
        public var slopeClamp = 150e-6
        public var batchSeconds = 30.0
        public var minimumBatches = 4
        public var rejectSigmas = 5.0
        public var rejectFloor = 1.0 / 48_000
        public var rejectAfterPairs = 10
        public var stepRejections = 8
        public var rejectRateWindow = 20
        public var rejectRateLimit = 5
        public var offsetStandardErrorBound = 0.005
        public var verifyPairs = 10
        public var gapSeconds = 10.0
        public init() {}
        public static let adopted = Parameters()
    }

    /// The line in use: offset `level` at video content time `center`, sloping at `slope`.
    public struct Line: Sendable, Equatable {
        public let level: Double
        public let center: Double
        public let slope: Double
        public func offset(at x: Double) -> Double { level + slope * (x - center) }
    }

    public enum State: Sendable, Equatable {
        /// No pair yet: the caller keeps its constant offset (0 on WHEP).
        case noLine
        /// A line from the current fit (provisional until verified).
        case tracking
        /// The fit is unstable: the last good line, or none (→ 0).
        case holding(String)
    }

    public struct Evaluation: Sendable, Equatable {
        public let offset: Double
        public let slope: Double
        public let state: State
    }

    // MARK: - The target line (§2.6) — the sign, derived

    /// The steering's reference line from the video mapping and the SR line.
    ///
    /// ── THE SIGN OF b, FROM FIRST PRINCIPLES ────────────────────────────────────────────────────
    ///
    /// Let the sender's video RTP clock run at (1 + ε_v) and its audio RTP clock at (1 + ε_a)
    /// against its NTP clock n. Then at NTP instant n the video PTS is p_v = (1+ε_v)(n − n_v) and the
    /// audio PTS is p_a = (1+ε_a)(n − n_a). The audio that belongs with video PTS p is the audio
    /// captured at the same n, so its PTS is
    ///
    ///     p_a*(p) = p − Δ(p),     Δ(p) = p − (1+ε_a)(p/(1+ε_v) + n_v − n_a)
    ///     dΔ/dp  = 1 − (1+ε_a)/(1+ε_v) ≈ ε_v − ε_a  =: b
    ///
    /// So b > 0 means the video clock runs fast of the audio clock, and the audio belonging with the
    /// picture advances SLOWER than the picture, by b. The mapping shows video PTS
    /// p(t) = S + (t − H)·r, so the target is
    ///
    ///     target(t) = p(t) − a − b·(p(t) − x̄) = [S − offset(S)] + (t − H)·r·(1 − b)
    ///
    /// — media S − offset(S) at host H, rate r·(1 − b). The slope enters the REFERENCE RATE with a
    /// minus sign and never the ratio (§2.2): the loop nulls a sloped target like any other.
    /// Pinned by `testPlus69ppmSlopeGivesZeroAudioVideoDrift`, which fails at the opposite sign.
    ///
    /// Measured check: on the 2026-09-26 Cloudflare soak the video RTP clock ran +62 ppm on mach and
    /// the audio within a few ppm of it (§13.3), and the SR slope was +69 ppm (§2.6) — ε_v − ε_a > 0,
    /// as the formula says it must be.
    public static func reference(videoMedia s: Double, rate r: Double,
                                 offset: Double, slope b: Double) -> (media: Double, rate: Double) {
        (s - offset, r * (1 - b))
    }

    // MARK: - Construction

    /// The fit for a session, or nil — ABSENT, NOT NEUTRAL — where audio and video already share a
    /// timeline. A degenerate fit over a stream that never reports would be a silent source of noise.
    public static func make(timeline: LiveAVTimeline, tag: String, reportsWindows: Bool,
                            parameters: Parameters = .adopted,
                            log: (@Sendable (String) -> Void)?) -> SenderReportLineFit? {
        guard timeline == .rtpSenderReports else { return nil }
        return SenderReportLineFit(tag: tag, reportsWindows: reportsWindows,
                                   parameters: parameters, log: log)
    }

    /// The session-start line naming which case the session is in. One per session, every transport.
    public static func sessionLine(tag: String, timeline: LiveAVTimeline) -> String {
        switch timeline {
        case .rtpSenderReports:
            return "\(tag) session: audio and video are separate RTP streams — the SR line fit is "
                + "ACTIVE (§2.6): offset(t) replaces the constant cushion, the slope enters the "
                + "reference rate, fitted fresh this session with no prior"
        case let .oneTimeline(why):
            return "\(tag) session: \(why) — ONE timeline, so NO SR line fit exists (§2.6: absent, "
                + "not neutral); the target is the mapping line with the transport's constant cushion"
        }
    }

    /// `a=ssrc:<id> cname:<name>` per m-section (RFC 5576 §4.1), first of each.
    public static func sdpCNAMEs(_ sdp: String) -> (audio: String?, video: String?) {
        var audio: String?, video: String?
        var section: Stream?
        // `isNewline`, not `== "\n"`: SDP lines end in CRLF (RFC 8866 §5), and Swift reads "\r\n"
        // as ONE Character that equals neither "\r" nor "\n".
        for raw in sdp.split(whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                section = line.hasPrefix("m=audio") ? .audio : line.hasPrefix("m=video") ? .video : nil
                continue
            }
            guard let s = section, line.hasPrefix("a=ssrc:"),
                  let r = line.range(of: " cname:") else { continue }
            let name = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if s == .audio, audio == nil { audio = name }
            if s == .video, video == nil { video = name }
        }
        return (audio, video)
    }

    public let parameters: Parameters
    private let tag: String
    private let reportsWindows: Bool
    private let log: (@Sendable (String) -> Void)?
    private let lock = UnfairLockBox()

    /// Called once, outside the lock, on the thread whose SR completed the first pair.
    public var onFirstLine: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return firstLineSink }
        set { lock.lock(); firstLineSink = newValue; lock.unlock() }
    }
    private var firstLineSink: (@Sendable () -> Void)?

    init(tag: String, reportsWindows: Bool, parameters: Parameters,
         log: (@Sendable (String) -> Void)?) {
        self.tag = tag; self.reportsWindows = reportsWindows
        self.parameters = parameters; self.log = log
    }

    // MARK: - Per-stream SR state (under `lock`)

    private struct StreamState {
        var origin: UInt32?
        var unwrapping = false
        var lastRaw: UInt32 = 0
        var lastExt: Int64 = 0
        var haveLatest = false
        var latestNTP: UInt64 = 0
        var latestRaw: UInt32 = 0
        var latestExt: Int64?
        var fresh = false
        var count = 0
        var sinceLastPair = 0

        /// Extended RTP ticks since the origin. The signed 32-bit step from the previous SR survives
        /// the counter wrap in either direction and any session length, as long as consecutive SRs
        /// are < 2³¹ ticks apart (6.6 h of video, 12.4 h of audio).
        mutating func unwrap(_ raw: UInt32) -> Int64 {
            if !unwrapping, let o = origin { lastRaw = o; lastExt = 0; unwrapping = true }
            lastExt += Int64(Int32(bitPattern: raw &- lastRaw))
            lastRaw = raw
            return lastExt
        }
    }

    private var audio = StreamState()
    private var video = StreamState()

    // MARK: - Fit state (under `lock`)

    private var xs: [Double] = []
    private var ds: [Double] = []
    private var rejectedRun: [(x: Double, d: Double)] = []
    private var recentRejected: [Bool] = []

    private var line: Line?
    private var lastGood: Line?
    private var state: State = .noLine
    private var slopeInUse = false
    private var firstLineDone = false

    // Latest fit figures, for the window line and the summary.
    private var slopeFit = 0.0, slopeSE = Double.infinity, residualSD = 0.0, inflation = 1.0
    private var offsetSD = 0.0, offsetN = 0
    private var slopeFirstInUseAt: Double?
    private var firstX: Double?, lastX: Double?

    // Counters.
    private var pairs = 0, rejectedTotal = 0, rejectedWindow = 0
    private var steps = 0, unstableEpisodes = 0, gaps = 0, longestGap = 0.0
    private var inGap = false
    private var maxStepWindow = 0.0, maxStepSession = 0.0, maxStepSteady = 0.0
    private var cnameNoted = false

    // MARK: - Input

    /// One Sender Report, matched to its stream by SSRC upstream. `audioOrigin` / `videoOrigin` are
    /// T_a0 / T_v0 when the bridge has seen them (nil until then); they latch once.
    public func noteSenderReport(_ stream: Stream, ntp: UInt64, rtp: UInt32,
                                 audioOrigin: UInt32?, videoOrigin: UInt32?) {
        var events: [String] = []
        var fireFirst: (@Sendable () -> Void)?
        lock.lock()
        latchOriginLocked(&audio, audioOrigin)
        latchOriginLocked(&video, videoOrigin)
        switch stream {
        case .audio: recordLocked(&audio, ntp: ntp, rtp: rtp)
        case .video: recordLocked(&video, ntp: ntp, rtp: rtp)
        }
        if audio.fresh, video.fresh, let ea = audio.latestExt, let ev = video.latestExt {
            audio.fresh = false; video.fresh = false
            let p = parameters
            // NTP difference in 32.32, as the wire carries it, BEFORE any double: NTP seconds since
            // 1900 are ~3.9e9, and a double holds that with ~1 µs left.
            let ntpDiff = Double(Int64(bitPattern: audio.latestNTP &- video.latestNTP)) / 4_294_967_296.0
            // (x − p_a) as one exact integer ratio over the two clock rates, again before any double.
            let rtpDiff = Double(ev * p.audioClockRate - ea * p.videoClockRate)
                / Double(p.audioClockRate * p.videoClockRate)
            let x = Double(ev) / Double(p.videoClockRate)
            ingestLocked(x: x, delta: ntpDiff + rtpDiff, events: &events)
            audio.sinceLastPair = 0; video.sinceLastPair = 0
            if !firstLineDone, line != nil {
                firstLineDone = true
                fireFirst = firstLineSink
            }
        }
        lock.unlock()
        events.forEach(emit)
        fireFirst?()
    }

    /// One pair already reduced to (x, Δ). The SR path above calls the same code; this entry exists
    /// for replaying logged Δ series, which carry no raw SR fields.
    public func notePair(videoTime x: Double, delta: Double) {
        var events: [String] = []
        var fireFirst: (@Sendable () -> Void)?
        lock.lock()
        ingestLocked(x: x, delta: delta, events: &events)
        if !firstLineDone, line != nil { firstLineDone = true; fireFirst = firstLineSink }
        lock.unlock()
        events.forEach(emit)
        fireFirst?()
    }

    /// Decision (b): CNAMEs that differ are logged once and the line is applied anyway.
    public func noteSDPCNAMEs(audio a: String?, video v: String?) {
        lock.lock()
        let first = !cnameNoted
        cnameNoted = true
        lock.unlock()
        guard first else { return }
        let text: String
        switch (a, v) {
        case let (a?, v?) where a == v:
            text = "SDP CNAMEs match (\"\(a)\") — the sender declares these streams synchronisable"
        case let (a?, v?):
            text = "SDP CNAMEs DIFFER (audio \"\(a)\", video \"\(v)\") — RFC 3550 §6.5.1 does not "
                + "declare these streams synchronisable. Applying the SR line anyway (§2.6 decision "
                + "b): it is used whenever both streams send SRs, and fallbacks key on the fit's own "
                + "measured sd, never on the server"
        default:
            text = String(format: "SDP CNAMEs not declared for both streams (audio %@, video %@) — "
                + "applying the SR line whenever both streams send SRs (§2.6 decision b)",
                a.map { "\"\($0)\"" } ?? "none", v.map { "\"\($0)\"" } ?? "none")
        }
        emit("\(tag) \(text)")
    }

    // MARK: - Output

    /// The offset and slope to use at video content time `x`, or nil when there has never been a
    /// line (the caller keeps its constant). Also where a gap is noticed: nothing else knows "now".
    public func evaluate(atVideoTime x: Double) -> Evaluation? {
        var event: String?
        lock.lock()
        defer {
            lock.unlock()
            if let event { emit(event) }
        }
        if let last = lastX, line != nil || lastGood != nil, x.isFinite,
           x - last > parameters.gapSeconds, !inGap {
            inGap = true
            gaps += 1
            let use = usableLineLocked()
            event = String(format: "%@ ⚠️ SR GAP — no SR pair for %.1f s of video content time "
                + "(audio SRs since the last pair: %d, video: %d; %@). Holding the last line, "
                + "extrapolated on its in-use slope %+.2f ppm; it resumes at the next pair",
                tag, x - last, audio.sinceLastPair, video.sinceLastPair,
                audio.sinceLastPair == 0 && video.sinceLastPair == 0 ? "BOTH streams silent"
                    : audio.sinceLastPair == 0 ? "the AUDIO SRs stopped"
                    : video.sinceLastPair == 0 ? "the VIDEO SRs stopped" : "SRs arriving, unpaired",
                (use?.slope ?? 0) * 1e6)
        }
        guard let l = usableLineLocked() else {
            if case .holding = state { return Evaluation(offset: 0, slope: 0, state: state) }
            return nil
        }
        return Evaluation(offset: l.offset(at: x), slope: l.slope, state: state)
    }

    /// What is missing for the first pair, for the gate's fallback line.
    public var missingForFirstPair: String {
        lock.lock(); defer { lock.unlock() }
        switch (audio.count, video.count) {
        case (0, 0): return "NO Sender Report on EITHER stream (audio 0, video 0)"
        case (0, let v): return "NO AUDIO Sender Report (video SRs: \(v))"
        case (let a, 0): return "NO VIDEO Sender Report (audio SRs: \(a))"
        default:
            if audio.origin == nil || video.origin == nil {
                return String(format: "SRs on both streams (audio %d, video %d) but %@ not received yet",
                              audio.count, video.count,
                              audio.origin == nil ? (video.origin == nil
                                  ? "the first audio packet and video access unit"
                                  : "the first audio packet") : "the first video access unit")
            }
            return "SRs on both streams, pair pending"
        }
    }

    public var hasLine: Bool { lock.lock(); defer { lock.unlock() }; return line != nil }

    public struct Snapshot: Sendable, Equatable {
        public var pairs = 0, rejected = 0, steps = 0, unstableEpisodes = 0, gaps = 0
        public var audioReports = 0, videoReports = 0
        public var slopeFit = 0.0, slopeSE = Double.infinity, slopeInUse = false
        public var residualSD = 0.0, inflation = 1.0
        public var maxOffsetStep = 0.0, maxOffsetStepSteady = 0.0
        public var slopeFirstInUseAt: Double?
        public var state: State = .noLine
        public var line: Line?
    }

    public var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshotLocked()
    }

    /// The `[WHEP-SRFIT]` line for one steering window; nil when windows are not reported.
    public func windowLine() -> String? {
        guard reportsWindows else { return nil }
        lock.lock()
        let text = describeLocked(prefix: "window")
        rejectedWindow = 0; maxStepWindow = 0
        lock.unlock()
        return text
    }

    /// Session summary, on close.
    public func finish() {
        lock.lock()
        let s = snapshotLocked()
        let text = String(format: "%@ session END — fitted slope %+.2f ± %.2f ppm (SE ×%.2f batch "
            + "inflation), %@ · offset %@ · residual sd %.3f ms · pairs %d accepted + %d rejected "
            + "(SR audio %d, video %d) · steps %d · unstable episodes %d · gaps %d (longest %.1f s) · "
            + "max offset step %.3f ms (session), %.3f ms after the first 60 s · final state %@",
            tag, s.slopeFit * 1e6, s.slopeSE.isFinite ? s.slopeSE * 1e6 : .nan, s.inflation,
            s.slopeFirstInUseAt.map { String(format: "slope IN USE from video t=%.0f s", $0) }
                ?? "slope NEVER in use (SE never ≤ bound)",
            line.map { String(format: "%+.3f ms at t=%.1f s", $0.offset(at: lastX ?? $0.center) * 1e3,
                              lastX ?? $0.center) } ?? "none",
            s.residualSD * 1e3, xs.count, s.rejected, s.audioReports, s.videoReports,
            s.steps, s.unstableEpisodes, s.gaps, longestGap,
            s.maxOffsetStep * 1e3, s.maxOffsetStepSteady * 1e3, describe(s.state))
        lock.unlock()
        emit(text)
    }

    // MARK: - Internals

    private func snapshotLocked() -> Snapshot {
        var s = Snapshot()
        s.pairs = pairs; s.rejected = rejectedTotal; s.steps = steps
        s.unstableEpisodes = unstableEpisodes; s.gaps = gaps
        s.audioReports = audio.count; s.videoReports = video.count
        s.slopeFit = slopeFit; s.slopeSE = slopeSE; s.slopeInUse = slopeInUse
        s.residualSD = residualSD; s.inflation = inflation
        s.maxOffsetStep = maxStepSession; s.maxOffsetStepSteady = maxStepSteady
        s.slopeFirstInUseAt = slopeFirstInUseAt; s.state = state; s.line = line
        return s
    }

    private func describe(_ s: State) -> String {
        switch s {
        case .noLine: return "NO LINE (constant offset)"
        case .tracking: return lastGood == nil ? "TRACKING (provisional)" : "TRACKING"
        case let .holding(why): return "HOLDING — \(why)"
        }
    }

    private func describeLocked(prefix: String) -> String {
        let l = usableLineLocked()
        let x = lastX ?? 0
        let slopeState: String
        if slopeInUse {
            slopeState = "IN USE"
        } else if !slopeSE.isFinite {
            slopeState = "not in use (fewer than \(parameters.minimumBatches) × "
                + "\(Int(parameters.batchSeconds)) s batches)"
        } else {
            slopeState = "not in use (SE above bound)"
        }
        return String(format: "%@ %@ video t=%.0f s · offset %@ · slope %+.2f ppm (SE %@ ppm, bound "
            + "%.0f; batch inflation ×%.2f) %@ · residual sd %.3f ms (offset window %.3f ms, n %d) · "
            + "N %d over %.0f s · rejected %d this window, %d session · pairs %d (SR a %d v %d) · "
            + "max offset step %.3f ms this window · state %@",
            tag, prefix, x,
            l.map { String(format: "%+.3f ms", $0.offset(at: x) * 1e3) } ?? "— (0 applied)",
            slopeFit * 1e6, slopeSE.isFinite ? String(format: "%.2f", slopeSE * 1e6) : "∞",
            parameters.slopeStandardErrorBound * 1e6, inflation, slopeState,
            residualSD * 1e3, offsetSD * 1e3, offsetN,
            xs.count, (xs.last ?? 0) - (xs.first ?? 0), rejectedWindow, rejectedTotal,
            pairs, audio.count, video.count, maxStepWindow * 1e3, describe(state))
    }

    private func usableLineLocked() -> Line? {
        switch state {
        case .noLine: return nil
        case .tracking: return line
        case .holding: return lastGood
        }
    }

    private func latchOriginLocked(_ s: inout StreamState, _ origin: UInt32?) {
        guard s.origin == nil, let o = origin else { return }
        s.origin = o
        // An SR that arrived before its origin was known is unwrapped now, so it can still pair.
        if s.haveLatest, s.latestExt == nil { s.latestExt = s.unwrap(s.latestRaw) }
    }

    private func recordLocked(_ s: inout StreamState, ntp: UInt64, rtp: UInt32) {
        s.count += 1
        s.sinceLastPair += 1
        s.haveLatest = true
        s.latestNTP = ntp
        s.latestRaw = rtp
        s.latestExt = s.origin != nil ? s.unwrap(rtp) : nil
        s.fresh = true
    }

    private func ingestLocked(x: Double, delta: Double, events: inout [String]) {
        guard x.isFinite, delta.isFinite else { return }
        pairs += 1
        if firstX == nil { firstX = x }
        if inGap, let last = lastX {
            inGap = false
            longestGap = max(longestGap, x - last)
            events.append(String(format: "%@ SR pairs RESUMED after %.1f s of video content time",
                                 tag, x - last))
        }
        lastX = x
        let p = parameters

        // ── Outlier test against the running fit ──────────────────────────────────────────────
        if xs.count >= p.rejectAfterPairs {
            let predicted = predictLocked(x)
            let bound = p.rejectSigmas * max(residualSD, p.rejectFloor)
            let r = delta - predicted
            if abs(r) > bound {
                rejectedTotal += 1; rejectedWindow += 1
                rejectedRun.append((x, delta))
                noteRejectionLocked(true)
                if rejectedRun.count >= p.stepRejections {
                    let run = rejectedRun.map(\.d)
                    let mean = run.reduce(0, +) / Double(run.count)
                    let sd = (run.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
                              / Double(max(1, run.count - 1))).squareRoot()
                    if sd <= bound {
                        // A step: the new pairs agree with each other and not with the line.
                        steps += 1
                        events.append(String(format: "%@ ⚠️ Δ STEPPED — %d consecutive pairs %+.1f ms "
                            + "off the line (their own sd %.3f ms, bound %.3f ms). The fit restarts "
                            + "from them; the slope leaves use until it re-qualifies",
                            tag, run.count, (mean - predicted) * 1e3, sd * 1e3, bound * 1e3))
                        xs = rejectedRun.map(\.x); ds = run
                        rejectedRun.removeAll()
                        recentRejected.removeAll()
                        slopeInUse = false
                        refitLocked(events: &events, restarted: true)
                    } else {
                        enterHoldingLocked(String(format: "%d consecutive rejections that disagree "
                            + "with each other too (sd %.3f ms > %.3f ms)", run.count, sd * 1e3,
                            bound * 1e3), events: &events)
                    }
                } else if scatteredRejectionsLocked() >= p.rejectRateLimit {
                    enterHoldingLocked(String(format: "%d scattered rejections in the last %d pairs "
                        + "at %.0f × sd", scatteredRejectionsLocked(), recentRejected.count,
                        p.rejectSigmas), events: &events)
                }
                return
            }
        }
        rejectedRun.removeAll()
        noteRejectionLocked(false)
        xs.append(x); ds.append(delta)
        var drop = 0
        while drop < xs.count - 1, xs[drop] < x - p.slopeWindow { drop += 1 }
        if drop > 0 { xs.removeFirst(drop); ds.removeFirst(drop) }
        refitLocked(events: &events, restarted: false)
    }

    /// Rejections among the recent pairs that are NOT the current consecutive run. A run is the step
    /// test's to judge (it becomes a step, or unstable, at `stepRejections`); counting it here too
    /// would call a genuine step unstable before the step test could see it — which replaying the
    /// 4e-1 MediaMTX log did, on a real 0.3 ms shift in Δ.
    private func scatteredRejectionsLocked() -> Int {
        max(0, recentRejected.filter { $0 }.count - rejectedRun.count)
    }

    private func noteRejectionLocked(_ rejected: Bool) {
        recentRejected.append(rejected)
        if recentRejected.count > parameters.rejectRateWindow { recentRejected.removeFirst() }
    }

    /// The slope-window OLS line at x (not the in-use line): what outliers are judged against.
    private var olsMeanX = 0.0, olsMeanD = 0.0
    private func predictLocked(_ x: Double) -> Double { olsMeanD + slopeFit * (x - olsMeanX) }

    private func refitLocked(events: inout [String], restarted: Bool) {
        let p = parameters
        let n = xs.count
        guard n > 0 else { return }
        let before = usableLineLocked()
        let xNow = xs[n - 1]

        // ── Slope: OLS over the slope window ──────────────────────────────────────────────────
        let mx = xs.reduce(0, +) / Double(n)
        let md = ds.reduce(0, +) / Double(n)
        var sxx = 0.0, sxy = 0.0
        for i in 0..<n {
            let dx = xs[i] - mx
            sxx += dx * dx; sxy += dx * (ds[i] - md)
        }
        let b = n >= 2 && sxx > 0 ? sxy / sxx : 0
        olsMeanX = mx; olsMeanD = md; slopeFit = b
        var ssr = 0.0
        for i in 0..<n {
            let r = ds[i] - (md + b * (xs[i] - mx))
            ssr += r * r
        }
        residualSD = n > 2 ? (ssr / Double(n - 2)).squareRoot() : 0

        // Batch means: v = mean over batches of n_j·m_j² / s². White residuals give v ≈ 1.
        var v = 1.0
        var batches = 0
        if n > 2, residualSD > 0 {
            let x0 = xs[0]
            var sums: [Int: (Double, Int)] = [:]
            for i in 0..<n {
                let k = Int(((xs[i] - x0) / p.batchSeconds).rounded(.down))
                let r = ds[i] - (md + b * (xs[i] - mx))
                let e = sums[k] ?? (0, 0)
                sums[k] = (e.0 + r, e.1 + 1)
            }
            let full = sums.values.filter { $0.1 >= 2 }
            batches = full.count
            if batches > 0 {
                let s2 = residualSD * residualSD
                v = full.map { let m = $0.0 / Double($0.1); return Double($0.1) * m * m / s2 }
                    .reduce(0, +) / Double(batches)
            }
        }
        inflation = max(1, v).squareRoot()
        slopeSE = batches >= p.minimumBatches && sxx > 0
            ? (residualSD / sxx.squareRoot()) * inflation : .infinity

        let wasInUse = slopeInUse
        if !slopeInUse, slopeSE <= p.slopeStandardErrorBound {
            slopeInUse = true
        } else if slopeInUse, !(slopeSE <= p.slopeReleaseBound) {
            slopeInUse = false
        }
        if slopeInUse, !wasInUse {
            if slopeFirstInUseAt == nil { slopeFirstInUseAt = xNow }
            events.append(String(format: "%@ slope IN USE at video t=%.0f s: %+.2f ppm, SE %.2f ppm ≤ "
                + "%.0f (batch inflation ×%.2f, N %d over %.0f s)%@", tag, xNow, b * 1e6,
                slopeSE * 1e6, p.slopeStandardErrorBound * 1e6, inflation, n, xNow - xs[0],
                abs(b) > p.slopeClamp ? String(format: " — CLAMPED to ±%.0f ppm", p.slopeClamp * 1e6)
                                      : ""))
        } else if wasInUse, !slopeInUse, !restarted {
            events.append(String(format: "%@ slope LEFT use at video t=%.0f s: SE %.2f ppm > %.0f",
                                 tag, xNow, slopeSE * 1e6, p.slopeReleaseBound * 1e6))
        }
        let bUse = slopeInUse ? min(p.slopeClamp, max(-p.slopeClamp, b)) : 0

        // ── Offset: mean residual about the in-use slope over the offset window ───────────────
        var lo = n - 1
        while lo > 0, xs[lo - 1] >= xNow - p.offsetWindow { lo -= 1 }
        let m = n - lo
        var cx = 0.0
        for i in lo..<n { cx += xs[i] }
        cx /= Double(m)
        var level = 0.0
        for i in lo..<n { level += ds[i] - bUse * (xs[i] - cx) }
        level /= Double(m)
        var s2 = 0.0
        for i in lo..<n {
            let r = ds[i] - (level + bUse * (xs[i] - cx))
            s2 += r * r
        }
        offsetSD = m > 1 ? (s2 / Double(m - 1)).squareRoot() : 0
        offsetN = m
        let fresh = Line(level: level, center: cx, slope: bUse)
        line = fresh

        // ── Stability ────────────────────────────────────────────────────────────────────────
        let offsetSE = m > 1 ? offsetSD / Double(m).squareRoot() : 0
        let noisy = m >= p.verifyPairs && offsetSE > p.offsetStandardErrorBound
        let recentRejections = scatteredRejectionsLocked()
        if noisy {
            enterHoldingLocked(String(format: "the offset's own SE %.2f ms > %.1f ms (sd %.2f ms over "
                + "%d pairs)", offsetSE * 1e3, p.offsetStandardErrorBound * 1e3, offsetSD * 1e3, m),
                events: &events)
        } else if recentRejections >= p.rejectRateLimit {
            enterHoldingLocked(String(format: "%d scattered rejections in the last %d pairs at %.0f × sd",
                recentRejections, recentRejected.count, p.rejectSigmas), events: &events)
        } else {
            if case .holding = state {
                events.append(String(format: "%@ line STABLE again at video t=%.0f s (offset SE %.2f ms)",
                                     tag, xNow, offsetSE * 1e3))
            }
            if state == .noLine {
                events.append(String(format: "%@ FIRST LINE from the first SR pair at video t=%.3f s: "
                    + "offset %+.3f ms (provisional until %d pairs verify it)",
                    tag, xNow, level * 1e3, p.verifyPairs))
            }
            state = .tracking
            if m >= p.verifyPairs { lastGood = fresh }
        }

        // Offset step at the newest pair, as the loop sees it.
        if let before, let after = usableLineLocked() {
            let step = abs(after.offset(at: xNow) - before.offset(at: xNow))
            maxStepWindow = max(maxStepWindow, step)
            maxStepSession = max(maxStepSession, step)
            if let f = firstX, xNow - f > p.offsetWindow { maxStepSteady = max(maxStepSteady, step) }
        }
    }

    private func enterHoldingLocked(_ why: String, events: inout [String]) {
        if case .holding = state { state = .holding(why); return }
        unstableEpisodes += 1
        state = .holding(why)
        if let g = lastGood, let x = lastX {
            events.append(String(format: "%@ ⚠️ FIT UNSTABLE — %@. Falling back to the LAST GOOD LINE "
                + "(offset %+.3f ms here, slope %+.2f ppm)", tag, why, g.offset(at: x) * 1e3,
                g.slope * 1e6))
        } else {
            events.append("\(tag) ⚠️ FIT UNSTABLE — \(why). No line was ever verified good: "
                + "falling back to offset 0")
        }
    }

    private func emit(_ line: String) { log?(line) }
}
