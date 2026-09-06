//
//  AudioMeterScope.swift
//  Manifold
//
//  Per-channel peak meters, as the fourth scope kind. One vertical bar per channel, dBFS.
//
//  ── SCOPE, DELIBERATELY NARROW ─────────────────────────────────────────────────────────
//
//  What a colourist needs from a meter is three things: is there audio, WHICH channel is it on,
//  and am I peaking. That is all this does. NO LUFS, no loudness standards, no true-peak, no
//  correlation. Those are mix decisions made in a different room by someone with a different
//  tool, and a half-implemented loudness readout in a colour bay is worse than none — it invites
//  a judgement the instrument cannot support.
//
//  ── WHY THIS IS THE ONE SCOPE THAT IS NOT RENDER-COUPLED ───────────────────────────────
//
//  Waveform, parade, vectorscope and CIE all hang off `MetalVideoRenderer.onFrameRendered`: they
//  describe the frame on screen, so sampling when that frame is drawn is exactly right. Audio is
//  not on that clock. It moves while no frame is being drawn, and — the case that settles it — a
//  PAUSED file draws nothing at all, yet the meter still has something true to say (see
//  `Status.paused`). So this model runs its own timer. It is the only structural difference from
//  the other four, and everything else — the slot header, the start/stop gating, the rounded
//  panel — is the shared shape.
//
//  ── WHERE THE SAMPLES COME FROM ───────────────────────────────────────────────────────
//
//  `FrameEngine.audioTap`, the PTS-keyed PCM ring that already tees every decoded audio buffer.
//  Two things about it are load-bearing here:
//
//    * THE TEE IS UNCONDITIONAL. It is NOT gated on DeckLink — `tap.ingest` sits inside the audio
//      enqueue closures themselves. Metering works with no card attached, and costs nothing extra
//      on the ingest side because that work was already happening.
//    * IT IS KEYED TO SOURCE TIME, so the meter can be read AT THE PLAYHEAD rather than at the
//      newest sample held. That matters: the audio renderer is fed as fast as it will accept, so
//      the newest samples in the ring can be most of a second ahead of the picture. A meter that
//      leads the picture answers the wrong question. See `AudioTapBuffer.peaks(endingAt:)`.
//

import SwiftUI
import Combine
import ManifoldCore

// MARK: - The dBFS scale

/// The meter's dB→position mapping, and the graticule that labels it.
///
/// ── RANGE: −60 … 0 dBFS ───────────────────────────────────────────────────────────────
///
/// What every NLE a colourist already reads uses. −60 is below any dither or room floor worth
/// seeing, and the top 20 dB — where every decision actually lives — stays legible.
///
/// ── THE SCALE IS COMPRESSED, NOT LINEAR IN dB, AND THAT IS THE POINT ──────────────────
///
/// Linear-in-dB spends 90% of the bar on material that is merely "present" and squeezes the
/// region a peak decision is made in into the last tenth. This scale gives the TOP 6 dB **44%**
/// of the bar, because "am I peaking" is the question being asked.
///
/// ⚠️ A POWER CURVE WAS TRIED FIRST AND IS WRONG AT THE BOTTOM. The exponent that puts −6 dBFS at
/// 56% (k ≈ 5.5) puts −30 dBFS at 2.2% of the bar and −40 at 0.24% — i.e. quiet dialogue reads as
/// no audio at all, which defeats the first of the three things this instrument is for. The
/// piecewise table below hits the same 44% at the top while leaving −30 dBFS at a readable 14%.
///
/// The breakpoints double as the graticule ticks, so the labels sit exactly where the slope
/// changes and the compression is self-evident rather than mysterious.
enum MeterScale {
    /// (dBFS, fraction of bar from the bottom). Must be ascending in dB.
    static let breakpoints: [(db: Double, pos: Double)] = [
        (-60, 0.00), (-42, 0.06), (-30, 0.14), (-20, 0.26), (-12, 0.40), (-6, 0.56), (0, 1.00)
    ]

    static let floorDB: Double = -60
    static let ceilingDB: Double = 0

    /// Ticks that get a printed label. −42 is a breakpoint but not labelled: it earns its slope
    /// change without earning space in a 60-pixel-wide slot.
    static let labelledTicks: [Double] = [0, -6, -12, -20, -30, -60]

    /// dBFS → 0…1 up the bar. Clamped at both ends; −∞ (silence) maps to 0.
    static func position(ofDB db: Double) -> Double {
        guard db.isFinite else { return 0 }
        if db <= floorDB { return 0 }
        if db >= ceilingDB { return 1 }
        for i in 0..<(breakpoints.count - 1) {
            let lo = breakpoints[i], hi = breakpoints[i + 1]
            if db >= lo.db && db <= hi.db {
                let t = (db - lo.db) / (hi.db - lo.db)
                return lo.pos + t * (hi.pos - lo.pos)
            }
        }
        return 1
    }

    /// Linear magnitude (0…1, 1 = full scale) → dBFS. Returns −infinity for true silence, which
    /// `position(ofDB:)` maps to the floor.
    static func db(fromMagnitude m: Float) -> Double {
        guard m > 0 else { return -.infinity }
        return 20 * log10(Double(m))
    }
}

// MARK: - Model

/// Drives the meters. Owns the sampling timer, the ballistics and the clip latches.
///
/// MAIN THREAD ONLY. The timer fires on main, the peak scan is a bounded non-blocking call into
/// the tap, and every published value is written here — so there is no cross-thread state to
/// guard beyond what `AudioTapBuffer` already guards internally.
final class AudioMeterModel: ObservableObject {

    /// What the meter is able to say right now. ⚠️ THE FIRST THREE ARE NOT INTERCHANGEABLE AND
    /// MUST NOT RENDER AS SILENT BARS — a bar at the floor reads as "this source is quiet", which
    /// is a claim about the material. Only `metering` and `paused` are entitled to draw bars.
    enum Status: Equatable {
        case noSource          // nothing loaded
        case waiting           // loaded, but the decoder has not reached the audio yet
        case noAudio           // the demuxer opened it and there is no audio stream
        case metering          // samples flowing
        case paused            // audio present, transport stopped — see the note on `tick`
    }

    struct Channel: Equatable {
        var db: Double = -.infinity        // bar level, after fall ballistics
        var holdDB: Double = -.infinity    // peak-hold line
        var clipped = false                // latched
    }

    @Published private(set) var channels: [Channel] = []
    @Published private(set) var status: Status = .noSource

    /// Declared roles for the monitored track, refreshed each tick. Empty = the file declared none.
    @Published private(set) var roles: [String] = []

    /// What to print under bar `index`: the DECLARED role, or the channel NUMBER.
    ///
    /// ── TWO KINDS OF TRUE, NOT TWO CONFIDENCE LEVELS ──────────────────────────────────────────
    ///
    /// "C" and "3" are both facts. "C" is what the FILE says channel 3 carries; "3" is its position,
    /// which is true unconditionally. Neither is a guess, so neither is dimmed — the app's
    /// three-state honesty pattern (declared bright / inferred muted + italic / undeclared) applies
    /// to values that MIGHT BE WRONG, and a channel number never is. Letters and digits already
    /// distinguish the two on sight.
    ///
    /// ⚠️ WHAT MUST NEVER APPEAR HERE IS AN INFERRED ROLE. `MediaInspector` will name a LAYOUT from
    /// a channel count alone when nothing is declared (6 → "5.1 (inferred)"), and turning that into
    /// per-channel labels would print "C" over a bar on the strength of the count — a guess wearing
    /// the same face as a declaration, over the one instrument a colourist uses to decide which
    /// channel is which. The inference stops at the layout NAME. Per-channel labels come only from
    /// `roles`, which is populated only from what the file actually declared, and the fallback is
    /// the number rather than a guess.
    ///
    /// Falls back per-channel rather than per-track: a file that labels five channels and leaves the
    /// sixth unmapped shows five roles and one number, which is more informative than discarding all
    /// six. An `Unused` channel is KEPT as "—" — that is a declaration, and it explains a silent bar.
    /// `allowRole: false` forces the number — used when the bar is too narrow to print a role
    /// legibly. A truncated "LF…" is worse than "4": it looks like a role and names the wrong thing.
    func channelLabel(_ index: Int, allowRole: Bool = true) -> String {
        guard allowRole, roles.indices.contains(index) else { return "\(index + 1)" }
        let role = roles[index]
        // "?(1234)" is `roleName(for:)`'s marker for a label it has no name for — real information,
        // but not something to print in a 26pt-wide column. That channel falls back to its number.
        return role.hasPrefix("?(") ? "\(index + 1)" : role
    }

    /// Widest declared role, in characters — the view's input for deciding whether roles fit.
    var widestRoleLength: Int {
        roles.filter { !$0.hasPrefix("?(") }.map(\.count).max() ?? 0
    }

    /// Tooltip that states which of the two the label is, so the distinction is available without
    /// having to know the convention.
    func channelHelp(_ index: Int) -> String {
        let n = index + 1
        guard roles.indices.contains(index), !roles[index].hasPrefix("?(") else {
            return "Channel \(n) — this file declares no role for it"
        }
        return "Channel \(n) — \(roles[index]) (declared by the file)"
    }

    // ── Ballistics ────────────────────────────────────────────────────────────────────
    //
    // Instant rise, damped fall. A meter that falls as fast as it rises flickers and cannot be
    // read; one that falls too slowly stops describing the present.

    /// Bar fall rate. Fast enough to track a real level change within a shot.
    private let barFallDBPerSecond: Double = 30
    /// How long the peak-hold line sits at a new maximum before it starts to move. Long enough to
    /// read a transient you were not watching for.
    private let holdSeconds: Double = 1.5
    /// Hold decay once the dwell expires. 20 dB/s crosses the whole scale in three seconds, so
    /// the line tracks the material rather than lingering over it.
    private let holdFallDBPerSecond: Double = 20

    /// 30 Hz. A meter with a 1.5 s hold gains nothing from 60, and this halves both the scan cost
    /// and the time spent holding the tap's lock — which DeckLink's audio callback also takes.
    private let tickHz: Double = 30

    /// Seconds of audio each scan looks at. Slightly MORE than one tick's worth so consecutive
    /// scans overlap and a peak landing on a tick boundary cannot fall between them.
    private var scanWindow: Double { (1.0 / tickHz) * 1.5 }

    /// Consecutive at-ceiling samples that latch the clip indicator. Three, not one: a single
    /// full-scale sample is legitimate in normalised material and latching on it would leave the
    /// indicator permanently lit on perfectly good files.
    private let clipRunToLatch = 3

    // ── Inputs, injected by ContentView ───────────────────────────────────────────────

    var tap: AudioTapBuffer?
    /// Playhead in source seconds. Used to read the ring AT THE PICTURE rather than ahead of it.
    var playhead: () -> Double = { 0 }
    var isPlaying: () -> Bool = { false }
    /// True for NDI/WHEP/SRT. Live sources have no playhead to key against — see `tick`.
    var isLive: () -> Bool = { false }
    /// What the DECODER established, not what an inspector guessed. Drives the empty states.
    var presence: () -> AudioPresence = { .unknown }

    /// Per-channel roles the FILE declared for the MONITORED track, or empty where it declared
    /// none. Supplied by ContentView from `metadata.audioTracks[selected].roles`.
    var channelRoles: () -> [String] = { [] }

    /// Identifies the loaded source. A CHANGE HERE CLEARS THE CLIP LATCHES.
    ///
    /// ⚠️ POLLED RATHER THAN CALLED FROM THE LOAD SITES, ON PURPOSE. There is no single load
    /// path — open panel, drag-and-drop, recents, bookmarks, deck re-use and stream takeover all
    /// reach the engine differently — so a `resetForNewSource()` wired at one call site would be
    /// correct until the next path was added, and then silently wrong. A clip indicator carried
    /// over from a previous file is a claim about material no longer on screen, which is exactly
    /// the sort of stale UI a colourist would act on, so this is checked every tick instead.
    var sourceIdentity: () -> String? = { nil }

    private var active = false
    private var timer: Timer?
    private var lastTickHost: CFTimeInterval = 0
    private var holdSince: [CFTimeInterval] = []
    private var clipRun: [Int] = []
    private var lastSourceIdentity: String??

    // MARK: - Lifecycle

    /// Idempotent, matching the other four scope models. Registers a meter subscriber on the tap
    /// so the peak scan is skipped entirely while no meter is on screen.
    func start() {
        guard !active else { return }
        active = true
        tap?.addMeterSubscriber()
        lastTickHost = CACurrentMediaTime()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / tickHz, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // The tray lives inside a scroll/resize-capable window; without .common the meter would
        // stop dead for the duration of a live resize or a menu tracking loop.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        guard active else { return }
        active = false
        timer?.invalidate()
        timer = nil
        tap?.removeMeterSubscriber()
        // Leave `channels` alone: the view is going away, and clearing it would make a slot
        // flicker through an empty state on every tray toggle.
    }

    /// A NEW FILE CLEARS THE LATCHES. A clip indicator carried over from the previous file is
    /// actively misleading — it is a claim about material no longer on screen, and it is exactly
    /// the sort of stale UI a colourist would act on. Called from the load path.
    func resetForNewSource() {
        clipRun.removeAll()
        holdSince.removeAll()
        channels.removeAll()
        // Roles belong to the track that just went away. Carrying them onto the next source would
        // print "C" over a channel of material that never declared one — the same class of stale
        // claim as a carried-over clip latch. The next tick re-polls.
        roles.removeAll()
        status = .noSource
    }

    /// Clear ONE channel's latch, from a click on its indicator.
    func clearClip(channel: Int) {
        guard channels.indices.contains(channel) else { return }
        channels[channel].clipped = false
        if clipRun.indices.contains(channel) { clipRun[channel] = 0 }
    }

    func clearAllClips() {
        for i in channels.indices { channels[i].clipped = false }
        for i in clipRun.indices { clipRun[i] = 0 }
    }

    // MARK: - Sampling

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = max(0, min(now - lastTickHost, 0.25))   // clamp: a stalled main thread must not
        lastTickHost = now                               // teleport the ballistics

        // A NEW SOURCE CLEARS THE LATCHES. See `sourceIdentity` for why this is polled.
        let identity = sourceIdentity()
        if lastSourceIdentity == nil || lastSourceIdentity! != identity {
            lastSourceIdentity = .some(identity)
            resetForNewSource()
        }

        // Polled with the identity above, and for the same reason: the roles arrive with
        // `metadata`, which lands asynchronously AFTER the decoder has already sized the bars, and
        // they change again whenever the monitored track changes. Assigned only on a real change so
        // an unchanged array does not republish at 30 Hz.
        let declaredRoles = channelRoles()
        if roles != declaredRoles { roles = declaredRoles }

        let declared = presence()

        switch declared {
        case .unknown:
            // Nothing loaded, or audio not reached yet. If the tap already has a format, trust
            // the tap — it is the one source that is right on every path.
            if tap?.format == nil {
                if status != .noSource && status != .waiting { status = .noSource }
                else { status = tap?.hasAudio == true ? .waiting : status }
                if channels.isEmpty { status = .noSource }
                decayAll(dt: dt)
                return
            }
        case .absent:
            status = .noAudio
            channels = []
            return
        case .present(let n):
            // Size the bars from the DECODER's channel count immediately, so the meter shows the
            // right number of (silent) bars before the first buffer lands rather than growing
            // into shape as audio starts.
            if channels.count != n { resize(to: n) }
        }

        // ⚠️ PLAYHEAD-KEYED FOR FILES, NEWEST-KEYED FOR LIVE, AND THE TWO ARE NOT THE SAME
        // QUESTION. A file's ring runs ahead of the picture, so keying to the playhead is what
        // makes the meter describe the shot on screen. A live source has no playhead — NDI pushes
        // with a monotonic host timestamp, not a source time, so a playhead-keyed read would miss
        // the window every time and report "no data" forever. For live, newest IS now.
        let scanned: AudioTapBuffer.Peaks?
        if isLive() {
            scanned = tap?.peaksOfNewest(windowSeconds: scanWindow, clipRunIn: clipRun)
        } else if isPlaying() {
            scanned = tap?.peaks(endingAt: playhead(), windowSeconds: scanWindow, clipRunIn: clipRun)
        } else {
            // ── PAUSED ────────────────────────────────────────────────────────────────────
            //
            // No samples are flowing, so there is no level to show — and reading the ring anyway
            // would be WORSE than showing nothing: the playhead is static, so every tick would
            // rescan the SAME window and the bars would sit frozen at whatever the last audible
            // level was, which reads as "this source is holding a steady tone".
            //
            // So the bars fall to silence on the normal ballistics. Because "fell to silence"
            // and "is silent" look identical once they get there, the HEADER says PAUSED — the
            // status carries the distinction, not the bars. Clip latches deliberately survive:
            // they are a claim about material already seen, and pausing does not unsee it.
            scanned = nil
        }

        if let peaks = scanned, peaks.framesScanned > 0 {
            if channels.count != peaks.magnitudes.count { resize(to: peaks.magnitudes.count) }
            clipRun = peaks.clipRun
            status = .metering
            apply(magnitudes: peaks.magnitudes, dt: dt, now: now)
        } else {
            // No data for this tick. Either paused, or the playhead is outside the retained
            // window (a scrub that outran the ring). Decay rather than snap to silence.
            if !channels.isEmpty { status = isPlaying() || isLive() ? .metering : .paused }
            decayAll(dt: dt)
        }
    }

    private func resize(to n: Int) {
        channels = (0..<n).map { i in i < channels.count ? channels[i] : Channel() }
        holdSince = (0..<n).map { i in i < holdSince.count ? holdSince[i] : 0 }
        clipRun = (0..<n).map { i in i < clipRun.count ? clipRun[i] : 0 }
    }

    private func apply(magnitudes: [Float], dt: Double, now: CFTimeInterval) {
        for i in channels.indices where i < magnitudes.count {
            let sampleDB = MeterScale.db(fromMagnitude: magnitudes[i])

            // Bar: instant rise, damped fall.
            var db = channels[i].db
            if sampleDB >= db || !db.isFinite { db = sampleDB }
            else { db = max(sampleDB, db - barFallDBPerSecond * dt) }
            channels[i].db = db

            // Hold: jump to a new maximum and dwell, then decay.
            if sampleDB >= channels[i].holdDB || !channels[i].holdDB.isFinite {
                channels[i].holdDB = sampleDB
                holdSince[i] = now
            } else if now - holdSince[i] > holdSeconds {
                channels[i].holdDB = max(sampleDB, channels[i].holdDB - holdFallDBPerSecond * dt)
            }

            if clipRun[i] >= clipRunToLatch { channels[i].clipped = true }
        }
    }

    /// Fall toward silence with the same ballistics used when samples ARE arriving, so a pause
    /// looks like the level ending rather than like the meter being switched off.
    private func decayAll(dt: Double) {
        for i in channels.indices {
            if channels[i].db.isFinite {
                let next = channels[i].db - barFallDBPerSecond * dt
                channels[i].db = next <= MeterScale.floorDB ? -.infinity : next
            }
            if channels[i].holdDB.isFinite {
                let next = channels[i].holdDB - holdFallDBPerSecond * dt
                channels[i].holdDB = next <= MeterScale.floorDB ? -.infinity : next
            }
        }
    }
}

// MARK: - View

/// Peak meters panel. Same shape as the other four scopes — pinned header band, plot area below,
/// rounded panel — so a slot looks the same whichever kind fills it.
struct AudioMeterScopeView: View {
    @ObservedObject var model: AudioMeterModel
    var slotSelection: Binding<ScopeKind>? = nil

    /// ── THE USER REFERENCE MARKER: TWO SCALARS, IN dBFS ───────────────────────────────────
    ///
    /// The user-line spelling from the waveform and parade (`manifold.<scope>.line1.enabled` /
    /// `.position`), one scope over: an enable flag and a value, both `@AppStorage`, so the marker
    /// is app-wide and a second window opens with the one you set.
    ///
    /// ⚠️ THE VALUE IS STORED IN dBFS, NOT AS A NORMALIZED 0…1 HEIGHT, AND THAT DIVERGES FROM THE
    /// WAVEFORM DELIBERATELY. Do not "fix" the two into agreement.
    ///
    /// The waveform stores normalized because it has FIVE rulers (8-bit, 10-bit, IRE, PQ nits,
    /// HLG %), and its own comment states the reason: "Storage is a normalized height, so switching
    /// rulers re-labels a line rather than moving it." A line typed as 203 nits must not MOVE when
    /// the ruler becomes 10-bit code.
    ///
    /// The meters have ONE ruler. `MeterScale` is absolute and fixed — −18 dBFS means one thing
    /// forever, on every source, under every setting in this app — and `MeterScale.position(ofDB:)`
    /// already converts on the way to the screen, so pre-converting buys nothing. What a stored
    /// FRACTION would cost is specific: `MeterScale.breakpoints` is a tuned piecewise table that has
    /// already been revised once (the power curve that put −30 dBFS at 2.2% of the bar and was
    /// wrong), and a stored 0.30 would silently become a different dB value the next time anyone
    /// touched it — the marker moving with no edit, on a measurement instrument. A stored −18.0
    /// cannot. The dB is the fact; the height is a rendering of it.
    ///
    /// DEFAULT −18 dBFS: the SMPTE RP 155 / EBU R68 alignment level, so the seed is a number a
    /// colourist recognises rather than an arbitrary one, and it sits clear of the gradient's own
    /// breaks at −20 and −6 so it cannot be mistaken for structure. It is A SEED, NOT A
    /// RECOMMENDATION. Off by default, like the waveform's lines: nothing appears until it is asked
    /// for.
    ///
    /// ⚠️ "MARKER", NOT "PEAK MARKER", AND THE KEYS SAY SO — this is the one identifier here that is
    /// expensive to change later, because renaming a `@AppStorage` key ORPHANS every value already
    /// saved under the old one. The first cut of this spelled them `manifold.meters.peak.*` while
    /// every other identifier in the feature said "marker", and the doc block was simultaneously
    /// arguing that the line is NOT a peak ceiling: this meter measures SAMPLE peak, does not
    /// measure TRUE peak (see the SCOPE note at the top of this file), and a key called `peak` on an
    /// instrument that declines to make that measurement is a claim in the one place a user cannot
    /// see it and a future reader cannot cheaply correct it. It is a marker. It marks whatever the
    /// user says it marks — an alignment level, a delivery ceiling, a dialogue floor — and the app
    /// takes no position on which.
    @AppStorage("manifold.meters.marker.enabled") private var markerOn = false
    @AppStorage("manifold.meters.marker.db")      private var markerDB = -18.0

    /// Bar geometry. Bars are capped rather than stretched: eight channels in a narrow slot
    /// should stay readable, and 24 should not become hairlines.
    private let maxBarWidth: CGFloat = 26
    private let minBarWidth: CGFloat = 4
    private let barSpacing: CGFloat = 3
    /// Room under the bars for the channel NUMBER.
    private let labelStripHeight: CGFloat = 13
    /// Room above the bars for the clip indicators.
    private let clipStripHeight: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    ScopeSlotHeader(name: "METERS", suffix: headerSuffix, selection: slotSelection)
                    // ⚠️ THE GEAR GOES HERE — immediately after the slot header and BEFORE the
                    // Spacer, the same index the other four use (waveform and parade's
                    // `ScopeValueAxisGear`, `vectorscopeOptions`, `cieOptions`). That keeps the
                    // conditional CLIP button on the trailing edge exactly where it was, and it
                    // keeps the five slot headers reading as one row across a tray.
                    //
                    // ⚠️ DO NOT ENLARGE ITS HIT TARGET — no frame, no padding, no `.contentShape`.
                    // Five points of the tray divider's grab band lie over the top of EVERY scope
                    // header and swallow `mouseDown`; the reasoning and the margin are written out
                    // on `ScopeGear` itself.
                    MeterOptionsGear(markerOn: $markerOn, markerDB: $markerDB)
                    Spacer(minLength: 4)
                    if model.channels.contains(where: { $0.clipped }) {
                        Button { model.clearAllClips() } label: {
                            Text("CLIP")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.red, in: RoundedRectangle(cornerRadius: 2))
                        }
                        .buttonStyle(.plain)
                        .help("Clear all clip indicators")
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: scopeHeaderHeight)

                ZStack {
                    Color.black
                    if model.channels.isEmpty {
                        emptyState
                    } else {
                        meters
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15)))
            .onAppear { _ = geo.size }
        }
    }

    private var headerSuffix: String {
        switch model.status {
        case .noSource:  return " · —"
        case .waiting:   return " · waiting for audio"
        case .noAudio:   return " · no audio track"
        case .paused:    return " · paused"
        case .metering:  return model.channels.count == 1 ? " · 1 ch dBFS" : " · \(model.channels.count) ch dBFS"
        }
    }

    /// ⚠️ NEVER SILENT BARS. Each of these is a DIFFERENT statement, and a meter sitting at the
    /// floor would collapse all three into "this source is quiet" — a claim about the material
    /// rather than about what we know.
    private var emptyState: some View {
        VStack(spacing: 3) {
            Image(systemName: model.status == .noAudio ? "speaker.slash" : "waveform")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.25))
            Text(emptyStateText)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
        }
        .padding(8)
    }

    private var emptyStateText: String {
        switch model.status {
        case .noAudio:  return "NO AUDIO TRACK"
        case .waiting:  return "WAITING FOR AUDIO"
        default:        return "NO SOURCE"
        }
    }

    private var meters: some View {
        GeometryReader { geo in
            let n = model.channels.count
            let available = geo.size.width - 8
            let raw = (available - CGFloat(n - 1) * barSpacing) / CGFloat(max(n, 1))
            let barWidth = max(minBarWidth, min(maxBarWidth, raw))
            let plotHeight = geo.size.height - labelStripHeight - clipStripHeight - 4
            // Roles only where the widest one actually FITS. The label font is SF Mono, whose
            // advance is exactly 0.6 em, so character-count × size × 0.6 is the true width — the
            // same arithmetic `graticuleLabelWidth` uses for the graticule. Below that the column
            // shows numbers, which always fit and are never a truncated half-name. A very narrow
            // slot (many channels, or a shrunk window) is the case this covers.
            let roleFits = CGFloat(model.widestRoleLength) * 10 * 0.6 <= barWidth

            HStack(alignment: .bottom, spacing: barSpacing) {
                ForEach(Array(model.channels.enumerated()), id: \.offset) { index, ch in
                    VStack(spacing: 2) {
                        clipIndicator(for: ch, index: index)
                        bar(ch, width: barWidth, height: max(plotHeight, 1))
                        // The element that answers "WHICH channel is it" — a declared role where
                        // the file states one, the channel number where it does not. See
                        // `channelLabel(_:)`. Same legibility standard as the graticule labels:
                        // it has to be readable at a glance rather than merely present.
                        Text(model.channelLabel(index, allowRole: roleFits))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(graticuleLabelOpacity))
                            .lineLimit(1)
                            .fixedSize()
                            .frame(height: labelStripHeight)
                            .help(model.channelHelp(index))
                    }
                    .frame(width: barWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
            .overlay(alignment: .bottom) {
                graticule(plotHeight: max(plotHeight, 1),
                          markerOn: markerOn, markerDB: markerDB)
                    .padding(.bottom, labelStripHeight + 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private func clipIndicator(for ch: AudioMeterModel.Channel, index: Int) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(ch.clipped ? Color.red : Color.white.opacity(0.10))
            .frame(height: clipStripHeight)
            .contentShape(Rectangle())
            .onTapGesture { model.clearClip(channel: index) }
            .help(ch.clipped ? "Clipped — click to reset" : "No clipping")
    }

    private func bar(_ ch: AudioMeterModel.Channel, width: CGFloat, height: CGFloat) -> some View {
        let level = MeterScale.position(ofDB: ch.db)
        let hold = MeterScale.position(ofDB: ch.holdDB)
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.06))
            // The gradient's colour breaks sit ON the scale, so green→amber→red land at −20 and
            // −6 dBFS wherever the compression puts them, rather than at fixed fractions of the
            // bar that would drift off the numbers.
            LinearGradient(stops: [
                .init(color: Color(red: 0.20, green: 0.85, blue: 0.35), location: 0),
                .init(color: Color(red: 0.20, green: 0.85, blue: 0.35),
                      location: MeterScale.position(ofDB: -20)),
                .init(color: Color(red: 0.95, green: 0.75, blue: 0.15),
                      location: MeterScale.position(ofDB: -6)),
                .init(color: Color(red: 0.95, green: 0.25, blue: 0.20), location: 1.0)
            ], startPoint: .bottom, endPoint: .top)
            .mask(alignment: .bottom) {
                Rectangle().frame(height: height * CGFloat(level))
            }
            if ch.holdDB.isFinite {
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(height: 1)
                    .offset(y: -height * CGFloat(hold) + 1)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 1))
    }

    /// Tick lines + dB labels, drawn across the whole plot so the compression is visible as
    /// unevenly spaced rules rather than having to be inferred from the bars.
    ///
    /// ── STYLED FROM THE SHARED SCOPE CONSTANTS, NOT FROM VALUES INVENTED HERE ──────────────
    ///
    /// ⚠️ THE FIRST VERSION OF THIS PICKED ITS OWN NUMBERS AND THEY WERE FAR TOO FAINT TO READ:
    /// 7 pt labels at 0.35 white on black, with 0.13 lines and no backing. The waveform and
    /// parade graticules had already been through exactly this problem and been fixed — their
    /// constants carry the evidence in the source ("was 8", "was 0.5 — brighter than the 0.22
    /// lines"). Re-deriving a look for a fifth scope is how a tray ends up with five different
    /// legibility standards, so this uses the SAME four constants they do:
    ///
    ///     graticuleLabelFontSize      11    (this had 7)
    ///     graticuleLabelOpacity       0.6   (this had 0.35)
    ///     graticuleMajorOpacity       0.22  (this had 0.13)
    ///     graticuleLabelBackingOpacity 0.45 (this had none at all)
    ///
    /// The dark backing pill is the part that matters most here and the part this was missing
    /// entirely: a meter label sits over the BARS, which run bright green through red, so a label
    /// with no plate behind it is unreadable exactly when the meter is doing something.
    ///
    /// 0 dBFS is drawn at label opacity rather than major-line opacity — it is the one line a
    /// peak decision is made against, and it reads as a limit rather than as another tick.
    ///
    /// ── THE USER REFERENCE MARKER IS DRAWN HERE, AT THE `.key` TIER ────────────────────────
    ///
    /// This Canvas already spans the whole strip and strokes x 0 → `size.width`, so a line drawn
    /// here crosses EVERY BAR BY CONSTRUCTION, at any channel count, with no bar geometry threaded
    /// into it. That is why the marker lives in the graticule and not in `bar(_:width:height:)`
    /// beside the peak-hold line, which is the other place a horizontal rule already draws.
    ///
    /// ⚠️ WEIGHT: `graticuleEmphasisStyle(.key)` — a 0.60 line at 1.0 pt with a 0.9 label — ASKED
    /// FOR BY NAME rather than spelled out as three numbers. 0.22 (`graticuleMajorOpacity`) is the
    /// weight for ALWAYS-ON STRUCTURE that is on screen unasked and exists to be looked PAST; this
    /// marker is off by default, so the only reason it is drawn at all is that someone switched it
    /// on TO READ IT — a foreground reference. The vectorscope's skintone axis shipped at 0.22 first
    /// and was reported unreadable: it disappeared into the trace, which is exactly what background
    /// structure is supposed to do.
    ///
    /// ── WHAT ASKING FOR `.key` COUPLES THIS TO, AND HOW STRONGLY ───────────────────────────
    ///
    /// ⚠️ THE TIER HAS THREE CONSUMERS NOW AND THEY ARE NOT ALL THE SAME KIND OF THING. Stated
    /// because the shorthand ("it moves all three together") is true and still misleading about WHY:
    ///
    ///   * THE WAVEFORM AND PARADE USER LINES — coupled DELIBERATELY and tightly. They are the same
    ///     class of object as this marker: a reference A USER PLACED and reads against. If this
    ///     marker and those lines ever draw at different weights, something is wrong.
    ///   * THE BT.2408 203-NIT LINE — shares the tier because it shares a RENDERING ROLE, not
    ///     because it is the same kind of thing. It is a FIXED STANDARD reference the app draws
    ///     UNASKED under a PQ ruler; nobody placed it, and it is not switched off. That coupling
    ///     PREDATES this marker — `drawUserLines` already tied the user lines to it, "the weight the
    ///     203-nit BT.2408 line uses" — and this change extended it to a third consumer rather than
    ///     creating it.
    ///
    /// So `.key` can no longer be tuned for one of the three alone, which is the intended cost for
    /// the marker and the user lines and an accepted side effect for the 203-nit line. ⚠️ IF THE
    /// 203-NIT LINE EVER NEEDS TO MOVE INDEPENDENTLY, THE FIX IS A FOURTH CASE ON `GratEmphasis`,
    /// NOT A TWEAK TO `.key`: `graticuleEmphasisStyle` is already shaped for that, and editing
    /// `.key` in place would silently move two user-placed references to adjust a standards line.
    ///
    /// It lands at the SAME opacity as the 0 dBFS line, at twice its width, and that is deliberate:
    /// both are limits read AGAINST rather than ticks read past, so they belong at one opacity, and
    /// the width separates them without inventing a sixth number for this file to own.
    ///
    /// ⚠️ ITS LABEL IS ON THE TRAILING EDGE and every tick's is on the leading one. That is the
    /// whole disambiguation and it costs nothing: a ruler has more than one entry, so a single
    /// number alone against the right edge cannot be read as a second scale. No COLOUR is
    /// introduced — the bars own colour in this scope (the gradient's green/amber/red breaks sit ON
    /// the dB scale, at −20 and −6), and a coloured line would read as a threshold in that
    /// vocabulary rather than as a mark someone placed.
    ///
    /// Drawn AFTER the tick loop, so it wins every overlap.
    private func graticule(plotHeight: CGFloat, markerOn: Bool, markerDB: Double) -> some View {
        Canvas { ctx, size in
            for db in MeterScale.labelledTicks {
                let y = size.height - size.height * CGFloat(MeterScale.position(ofDB: db))
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(line,
                           with: .color(.white.opacity(db == 0 ? graticuleLabelOpacity
                                                               : graticuleMajorOpacity)),
                           lineWidth: 0.5)
                drawGraticuleLabel(ctx, size: size, y: y,
                                   text: db == 0 ? "0" : "\(Int(db))",
                                   trailing: false, opacity: graticuleLabelOpacity)
            }

            guard markerOn else { return }
            let my = size.height - size.height * CGFloat(MeterScale.position(ofDB: markerDB))
            let style = graticuleEmphasisStyle(.key)
            var marker = Path()
            marker.move(to: CGPoint(x: 0, y: my))
            marker.addLine(to: CGPoint(x: size.width, y: my))
            ctx.stroke(marker, with: .color(.white.opacity(style.lineOpacity)),
                       lineWidth: style.lineWidth)
            drawGraticuleLabel(ctx, size: size, y: my, text: meterMarkerLabel(markerDB),
                               trailing: true, opacity: style.labelOpacity)
        }
        .frame(height: plotHeight)
    }
}

// MARK: - The user reference marker: the commit decision, and the gear that edits it

/// What a marker commit attempt decided. Pure data, so `meterMarkerCommitDecision` can be
/// exercised directly instead of only through a live text field — the same reason
/// `UserLineCommitOutcome` exists, and the same reason it is not buried inside the `View`.
///
/// ⚠️ THERE IS NO `.discarded` CASE, AND ITS ABSENCE IS A FINDING RATHER THAN AN OMISSION — stated
/// here so nobody re-derives it or "restores" it for symmetry. The waveform's fields carry one
/// because their buffer is typed IN THE ACTIVE RULER'S UNITS, and the ruler radio rows share a
/// popover with the field: clicking a ruler BLURS a half-typed value whose meaning has just changed
/// underneath it, which is how "378" typed as a code value commits as 378 PQ nits and stores 661
/// code (measured). The meters have ONE ruler. `MeterScale` is fixed and absolute, this field always
/// edits dBFS, and there is NO control anywhere in this app that can change what a number typed here
/// means. So there is no stale-unit state to detect and nothing for a discard to protect.
enum MeterMarkerCommitOutcome: Equatable {
    /// Nothing was typed, or what was typed means the value already stored. Write NOTHING.
    case unchanged
    /// Unparseable, or outside `MeterScale`'s floor…ceiling. Write NOTHING.
    ///
    /// ⚠️ AND NOTHING TELLS THE USER IT HAPPENED. This case is distinct from `.unchanged` in the
    /// source and NOT distinct on screen — both leave the field showing the stored value. The gap,
    /// why it is deferred, and why it is not the meters' alone to close are on
    /// `MeterMarkerRow.commit()`.
    case rejected
    /// A genuinely new dBFS value.
    case write(Double)
}

/// THE WHOLE COMMIT DECISION, WITH NO VIEW STATE IN IT — `userLineCommitDecision`'s discipline minus
/// the ruler half (see `MeterMarkerCommitOutcome`).
///
/// ── `text != seeded` IS THE ONLY DEFINITION OF "THE USER TYPED SOMETHING" ──────────────────
///
/// ⚠️ AND IT IS STILL LOAD-BEARING HERE, EVEN THOUGH NOTHING CONVERTS UNITS. `meterMarkerLabel`
/// rounds to one decimal, so a stored −18.04 displays as "-18" and parses back to −18.0: a
/// value-difference guard ALONE would read merely focusing the field and leaving as an edit, and
/// move the marker — the exact bug the waveform's version was written to close. Comparing the BUFFER
/// against WHAT IT WAS SEEDED WITH asks the right question, because a buffer nobody edited is
/// byte-identical to its seed whatever rounding produced it. The value test below is then a genuine
/// no-op check rather than a substitute for this one.
///
/// ── OUT OF RANGE IS REJECTED, NOT CLAMPED ─────────────────────────────────────────────────
///
/// Same reasoning as the user lines, with a different commonest mistake: dBFS below full scale is
/// NEGATIVE, so the way to land out of range here is a sign error — typing "18" for −18. A clamp
/// would answer that by parking the marker at 0 dBFS, on top of the one line a peak decision is
/// already made against, and the only evidence would be a number you have stopped looking at.
/// Reverting is visible, costs one retype, and never leaves the marker somewhere unintended.
func meterMarkerCommitDecision(text: String, seeded: String,
                               stored: Double) -> MeterMarkerCommitOutcome {
    // (1) Nobody typed anything. This is the guard that makes focus-and-leave a no-op.
    guard text != seeded else { return .unchanged }

    let trimmed = text.trimmingCharacters(in: .whitespaces)
    // Locale-aware first (a decimal-comma locale types "-1,5"), then the plain parse as a fallback
    // so a "-1.5" typed on such a system is still understood. Lifted from `userLineCommitDecision`.
    let entered = (try? Double(trimmed, format: .number)) ?? Double(trimmed)
    guard let v = entered, v.isFinite,
          v >= MeterScale.floorDB, v <= MeterScale.ceilingDB else { return .rejected }

    // (2) A retype of the value already stored must not reach UserDefaults — see the note on
    // `MeterMarkerRow` for what a write costs the OTHER four scopes.
    guard abs(v - stored) > 1e-9 else { return .unchanged }
    return .write(v)
}

/// dBFS → the marker's printed label. A trailing ".0" is dropped, so an integer entry reads "-18"
/// like the graticule's own ticks while a fractional ceiling reads "-1.5". THE FIELD FORMATS WITH
/// THIS SAME FUNCTION, so the line's label and the number in the gear can never disagree about one
/// stored value — the same reason `userLineFieldValue` is shared between the waveform's field and
/// its line label.
func meterMarkerLabel(_ db: Double) -> String {
    let r = (db * 10).rounded() / 10
    return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
}

/// The meters' options gear — the FIRST one this scope has had; it was the only one of the five
/// without a gear. Contents: the user reference marker.
///
/// ⚠️ ONE LINE ACROSS EVERY CHANNEL, NOT A PER-CHANNEL OVERRIDE, AND THAT IS THE FEATURE RATHER THAN
/// A FIRST CUT OF IT. The thing a marker is usually set to — a delivery ceiling, an alignment level
/// — is a property of the DELIVERABLE, not of a channel: the same number applies to L, to LFE and to
/// channel 7 alike. The per-channel rules that DO exist in the standards are LOUDNESS rules — LFE
/// excluded from a BS.1770 sum, dialogue gating — and loudness is a measurement this instrument
/// deliberately does not make (see the SCOPE note at the top of this file). Eight fields would
/// suggest it did. One line is also the cheap shape: the graticule Canvas already spans the whole
/// strip, so the marker crosses every bar by construction at any channel count, with no bar geometry
/// threaded into it.
///
/// The two values live in `AudioMeterScopeView` and arrive here as BINDINGS, following the user
/// lines rather than declaring the keys in this struct — the graticule has to read them too, and one
/// declaration site is what keeps the drawn line and the edited number over the same two keys.
struct MeterOptionsGear: View {
    @Binding var markerOn: Bool
    @Binding var markerDB: Double

    var body: some View {
        ScopeGear(title: "Meter options",
                  help: "Reference marker: one line across every channel, typed in dBFS. Read against SAMPLE peak — this meter does not measure true peak, so a marker set to a true-peak delivery ceiling is not a true-peak check.") {
            ScopeGearSectionHeader("Reference marker", isFirst: true)
            MeterMarkerRow(isOn: $markerOn, db: $markerDB)
        }
    }
}

/// The reference marker's row in the gear popover: a checkbox that draws it, and a field carrying its
/// value in dBFS. `UserLineRow`'s shape and commit discipline, deliberately — `.roundedBorder`, the
/// fixed 60 pt field, the caption unit beside it, and a LOCAL STRING BUFFER assigned only by
/// `commit()`, called from `.onSubmit` and from focus leaving.
///
/// ⚠️ THE DEFERRED WRITE MATTERS HERE TOO, THOUGH THE COST LANDS ONE SCOPE OVER. The meters model
/// runs its own 30 Hz timer and does NOT observe UserDefaults, so a per-keystroke write would cost
/// the METERS nothing — but every other scope model subscribes to `UserDefaults.didChangeNotification`
/// and re-samples the current frame on it (see `WaveformScopeModel.start`). This popover opens over a
/// tray whose other two slots are normally full, so a binding that wrote per keystroke would fire a
/// GPU compute pass per slot per character: typing "-18" would re-sample twice on the way to the
/// value that was meant, with the traces jumping beside a meter that showed nothing at all.
///
/// ⚠️ THERE IS NO SEEDED-RULER GUARD, AND THAT ABSENCE IS THE POINT, NOT A GAP. `UserLineRow` carries
/// `seededActive` / `seededSdrScale` to catch a buffer typed under one ruler and committed under
/// another; this field edits one fixed unit and nothing in the app can change what a typed number
/// means, so there is no analogue and none is missing. See `MeterMarkerCommitOutcome`. `seeded`
/// ITSELF STAYS — it is a different guard, and it is what makes focus-and-leave a no-op.
struct MeterMarkerRow: View {
    @Binding var isOn: Bool
    /// ⚠️ dBFS, NOT a normalized height — see the note on the two keys in `AudioMeterScopeView`.
    @Binding var db: Double

    /// What is being typed. Not the stored value, and deliberately allowed to disagree with it while
    /// a caret is in the field — that disagreement IS the deferred write.
    @State private var text = ""
    /// ⚠️ THE BUFFER AS IT WAS LAST SEEDED. Written ONLY by `seed(from:)`, so it cannot drift out of
    /// step with `text`; a stale seed reads as "the user typed something", which is the bug.
    @State private var seeded = ""

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Toggle("Marker", isOn: $isOn)
                .font(.caption)
                .fixedSize()
            Spacer(minLength: 4)
            TextField("", text: $text)
                .frame(width: 60)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .focused($focused)
                .onSubmit { commit() }
            Text("dBFS")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
        }
        // NOT `.disabled(!isOn)`. A position is a property of the line whether or not the line is
        // being drawn, and setting a value before switching it on is a natural order — the same
        // deliberate divergence from `GuidesPanel` that `UserLineRow` makes, for the same reason.
        .onAppear { reseed() }
        // Re-format when the STORED value changes under us — another window editing the same
        // @AppStorage key, or this row's own commit. Skipped while focused so it cannot overwrite
        // what is being typed. `UserLineRow` additionally reseeds on a RULER change; there is no
        // ruler here, so this is the whole list rather than a shortened copy of it.
        .onChange(of: db) { _, _ in if !focused { reseed() } }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    /// Fill the buffer from a stored dBFS and record it, so a later commit can tell whether anything
    /// was typed. ⚠️ THE ONLY WRITER OF `text` AND `seeded`.
    private func seed(from value: Double) {
        let s = meterMarkerLabel(value)
        text = s
        seeded = s
    }

    /// Seed from what is actually stored.
    private func reseed() { seed(from: db) }

    /// The ONLY writer of `db`. Every decision lives in `meterMarkerCommitDecision`; this applies
    /// the answer and nothing more.
    ///
    /// ── THE THREE OUTCOMES ARE THREE DIFFERENT THINGS AND DO NOT SHARE A BRANCH ────────────
    ///
    /// `.unchanged` and `.rejected` were ONE `case` here at first, both calling `reseed()`, so "you
    /// typed the value that was already stored" and "this instrument REFUSES what you typed"
    /// produced byte-identical screen output. Split, because that conflation is a trap for whoever
    /// adds feedback later: a shared branch reads as though the two had been considered and found
    /// equivalent, when only one of them has anything to say.
    ///
    ///   * `.rejected` → `reseed()`. The buffer goes back to what IS stored, so a refused entry
    ///     visibly does not stick.
    ///   * `.unchanged` → NOTHING. There is nothing to correct: either nobody typed (the buffer
    ///     already equals its seed), or what was typed parses to the value already stored — and
    ///     reformatting a just-typed "-18.0" to "-18" under the caret would be a gratuitous edit of
    ///     an entry that was not wrong. `seeded` is deliberately left as it was; a later commit with
    ///     nothing typed still lands on `.unchanged`, via the value test rather than the buffer test
    ///     — see guard (2) in `meterMarkerCommitDecision`.
    ///
    /// ── ⚠️ WHAT THE SPLIT DOES NOT FIX — DO NOT READ IT AS HAVING FIXED THIS ────────────────
    ///
    /// ⚠️ THE REJECTION IS STILL UNSIGNALLED, AND THE CASE REJECTION EXISTS TO CATCH IS STILL
    /// INVISIBLE. dBFS below full scale is NEGATIVE, so the commonest bad entry is a sign error:
    /// typing "18" for −18. That is refused, and the field snaps back to "-18" — WHICH LOOKS
    /// PLAUSIBLE, and reads as success to the person who meant −18 all along. Nothing beeps, nothing
    /// highlights, nothing says a value was refused. `.unchanged` and `.rejected` remain
    /// indistinguishable TO THE USER; what changed is only that they are no longer indistinguishable
    /// IN THIS SOURCE. This is a code-level fix for a conflation, not a user-facing fix for the
    /// defect.
    ///
    /// THE REAL FIX IS FEEDBACK ON `.rejected` — some visible, transient statement that the entry
    /// was refused — AND IT IS DEFERRED ON PURPOSE. This popover has no such idiom and neither does
    /// any other numeric field in the app, so building it means DESIGNING the app's first one rather
    /// than reaching for an existing pattern, which is more than this change had earned.
    ///
    /// ⚠️ NOT A METERS PROBLEM, AND DO NOT FIX IT HERE ALONE. `UserLineRow` has the IDENTICAL gap —
    /// this row inherited its shape, snap-back and all — so feedback worth building belongs to both
    /// fields at once; one that alone reported refusals would just relocate the inconsistency.
    ///
    /// The app's other numeric fields are NOT a precedent to copy either way: `GuidesPanel`'s
    /// `customField` and `percentField` CLAMP (1–32, 50–100%), so they never refuse anything and
    /// have nothing to signal. That is the policy this field and the user lines deliberately do not
    /// follow — see the rejection note on `meterMarkerCommitDecision` — which is exactly why the
    /// two of them are the only places in the app where "refused" is a state that needs saying.
    private func commit() {
        switch meterMarkerCommitDecision(text: text, seeded: seeded, stored: db) {
        case .rejected:
            // Put the buffer back to what IS stored. This snap-back is the ONLY evidence a refusal
            // produces — see the ⚠️ above for why that is not yet enough.
            reseed()
        case .unchanged:
            // Deliberately nothing. Not a missing `reseed()`; see the bullets above.
            break
        case .write(let v):
            db = v
            // Seed from the value just written, not from `db`: a `@Binding` over `@AppStorage` is
            // not guaranteed to read back the new value within the same update.
            seed(from: v)
        }
    }
}
