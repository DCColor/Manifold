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

            HStack(alignment: .bottom, spacing: barSpacing) {
                ForEach(Array(model.channels.enumerated()), id: \.offset) { index, ch in
                    VStack(spacing: 2) {
                        clipIndicator(for: ch, index: index)
                        bar(ch, width: barWidth, height: max(plotHeight, 1))
                        // ⚠️ NUMBERS, NOT ROLES. Channel COUNT is currently mapped to a layout
                        // NAME upstream (a 4-channel file reports "Quad" whatever it declares),
                        // so a role label here would inherit a guess and present it as fact.
                        // A number is always honest. Roles wait for that fix.
                        // Same legibility standard as the graticule labels: this is the element
                        // that answers "WHICH channel is it", so it has to be readable at a
                        // glance rather than merely present.
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(graticuleLabelOpacity))
                            .frame(height: labelStripHeight)
                    }
                    .frame(width: barWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
            .overlay(alignment: .bottom) {
                graticule(plotHeight: max(plotHeight, 1))
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
    private func graticule(plotHeight: CGFloat) -> some View {
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

                let resolved = ctx.resolve(
                    Text(verbatim: db == 0 ? "0" : "\(Int(db))")
                        .font(.system(size: graticuleLabelFontSize, design: .monospaced))
                        .foregroundColor(.white.opacity(graticuleLabelOpacity))
                )
                let ts = resolved.measure(in: CGSize(width: 200, height: 100))
                // Clamp so the -60 and 0 labels stay fully on the plot instead of half-clipped
                // at the edges — the same treatment drawGraticuleLabel gives the waveform's.
                let ly = Swift.min(Swift.max(y, ts.height / 2), size.height - ts.height / 2)
                let plate = CGRect(x: 1, y: ly - ts.height / 2 - 1,
                                   width: ts.width + 6, height: ts.height + 2)
                ctx.fill(Path(roundedRect: plate, cornerRadius: 3),
                         with: .color(.black.opacity(graticuleLabelBackingOpacity)))
                ctx.draw(resolved, at: CGPoint(x: 4, y: ly), anchor: .leading)
            }
        }
        .frame(height: plotHeight)
    }
}
