//
//  CalibrationMode.swift — calibration mode for the per-source audio offset, stage D
//  (docs/AUDIO_RESAMPLER_DESIGN.md §19.2, §19.10).
//
//  Play a Manifold sync clip through the encoder, open A/V ▸ Calibrate…, press Start. Manifold pairs
//  the clip's flashes with its beeps, measures what is HEARD (O included), and once the figure can
//  be trusted offers a new offset. ⚠️ IT NEVER APPLIES ONE BY ITSELF: Apply and Save, Apply for Session
//  and Cancel are the user's.
//
//    * THE DETECTORS RUN ONLY WHILE A RUN IS ON. Start installs the beep detector on the engine's
//      live sink (`CalibrationBeepTap`) and the flash detector on the renderer
//      (`CalibrationFlashTap`); a result, Stop, Cancel, closing the sheet or a disconnect removes both.
//      Off, neither exists: no taps, no buffers, no timers. `SyncCalibrationCounters` is the evidence.
//    * WHAT IS MEASURED: heard A/V = beep − (flash pts + heard − clock), the stage A heard figure, so
//      O is in it. Proposed = O − measured, rounded to 1 ms, clamped to the range. An advance beyond
//      the queue's low point (the stage B refusal figure) is shown as not applicable, with the figure.
//    * A FIGURE ONLY WHEN CONFIDENT: ≥ 10 pairs, p90 − p10 under one frame, the last 5 pairs within
//      ±2 ms of the median (`CalibrationMeasurement`). Until then: pairs found and the spread.
//    * NDI: Apply for Session only (NDI connects have no saved stream, by decision). HLS: no
//      calibration, with the offset control's note — Apple's player owns the audio.
//    * The O the run started on is watched: a change (a nudge, the menu) restarts the measurement.
//

import SwiftUI
import AppKit
import Combine
import ManifoldCore
import SyncCalibration

// MARK: - The clips: bundled, saved, downloaded

enum SyncClipLibrary {
    /// ⚠️ ROBBIE: CONFIRM BEFORE RELEASE — the zip is NOT uploaded yet (docs/BUGS.md, pre-ship).
    ///
    /// The ONE download link: "Download ProRes Sync Clips…" (A/V menu), "Download Sync Clips…" (Help)
    /// and the sheet's link all open it in the browser; there is no in-app downloader (§19.9 Decisions
    /// 3). "v1" ties the zip to the current coded pattern (`SyncClips.patternVersion`): a changed
    /// pattern is a NEW v2 zip and a new constant, never a replaced v1 (§19.10).
    static let downloadURL = URL(string: "https://releases.graviton.tools/manifold/manifold-sync-clips-v1.zip")!

    static let notBundledNote = "Sync clips aren’t included in this build."

    /// `Contents/Resources/SyncClips`, where the build copies build/syncclips/*-h264.mov (project.yml):
    /// H.264 + PCM, whole code cycles, so a clip loops sample-exactly in an encoder (§19.11).
    static var directory: URL? { Bundle.main.resourceURL?.appendingPathComponent("SyncClips", isDirectory: true) }

    static func bundledURL(_ clip: SyncClips.Clip) -> URL? {
        guard let u = directory?.appendingPathComponent(clip.bundledName),
              FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }

    /// Every rate's clip is in the bundle.
    static var isBundled: Bool { SyncClips.all.allSatisfy { bundledURL($0) != nil } }

    static func openDownload() {
        NSLog("[CALIBRATION] opening the sync clip download: %@", downloadURL.absoluteString)
        NSWorkspace.shared.open(downloadURL)
    }

    /// What the stream's rate maps to, in words: "This stream is 23.976 fps." / "This stream is 60 fps:
    /// there is no 60 fps clip, 59.94p is the nearest." nil when the rate is not known.
    static func rateNote(frameInterval: Double) -> (SyncClips.Match, String)? {
        guard frameInterval > 0, let m = SyncClips.clip(forRate: 1 / frameInterval) else { return nil }
        let fps = String(format: "%.3f", 1 / frameInterval)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        return (m, m.exact ? "This stream is \(m.clip.label) fps."
                    : "This stream is \(fps) fps: there is no \(fps) fps clip, \(m.clip.displayName) is the nearest.")
    }

    /// "Save Sync Clip…" / "Get Sync Clip…": the bundled clip for the stream's rate (nearest supported,
    /// said so when it is not the stream's own), through a save panel with the rate on a menu.
    @MainActor
    static func saveClip(frameInterval: Double, window: NSWindow?) {
        guard isBundled else {
            let a = NSAlert()
            a.messageText = notBundledNote
            a.informativeText = "Download the free Manifold sync clips (one per frame rate) from releases.graviton.tools. "
                + "Calibration works with a clip from anywhere."
            a.addButton(withTitle: "Download Sync Clips…")
            a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { openDownload() }
            return
        }
        let match = rateNote(frameInterval: frameInterval)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for c in SyncClips.all { popup.addItem(withTitle: "\(c.displayName) — \(c.bundledName)") }
        popup.selectItem(at: SyncClips.all.firstIndex { $0 == match?.0.clip } ?? 0)
        let label = NSTextField(wrappingLabelWithString: match?.1 ?? "The stream’s frame rate isn’t known yet: choose the clip’s rate.")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 420).isActive = true
        let panel = NSSavePanel()
        panel.title = "Save Sync Clip"
        panel.message = "Play it through your encoder, then calibrate while connected."
        panel.accessoryView = stack
        panel.nameFieldStringValue = (match?.0.clip ?? SyncClips.all[0]).bundledName
        panel.allowedContentTypes = [.quickTimeMovie]
        let target = NotificationCenter.default.addObserver(forName: NSMenu.didSendActionNotification,
                                                            object: popup.menu, queue: .main) { _ in
            MainActor.assumeIsolated { panel.nameFieldStringValue = SyncClips.all[popup.indexOfSelectedItem].bundledName }
        }
        defer { NotificationCenter.default.removeObserver(target) }
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let clip = SyncClips.all[popup.indexOfSelectedItem]
        guard let src = bundledURL(clip) else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: src, to: dest)
            NSLog("[CALIBRATION] saved the %@ sync clip", clip.displayName)
        } catch {
            let a = NSAlert(error: error)
            a.runModal()
        }
    }
}

// MARK: - The run, per window

@MainActor
final class SyncCalibrationModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case listening
        case result(CalibrationProposal)
        case applied(Int, saved: Bool)
    }

    /// Where calibration can be used from this window, and how far a result can go.
    enum Availability: Equatable {
        case notConnected
        case hls
        /// NDI (no saved streams, by decision) or a connect with no saved stream.
        case sessionOnly(ndi: Bool)
        case bookmark(name: String)
    }

    @Published var isPresented = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var snapshot: CalibrationMeasurement.Snapshot?
    @Published private(set) var note: String?

    private weak var deck: WindowDeck?
    private var measurement: CalibrationMeasurement?
    private var run = 0
    private var startedAtMs = 0
    private var offsetWatch: AnyCancellable?

    init(deck: WindowDeck) { self.deck = deck }

    var availability: Availability {
        guard let deck, DeckRegistry.shared.liveLabel(for: deck) != nil, let source = deck.audioOffset.source
        else { return .notConnected }
        switch source {
        case .hls: return .hls
        case .ndi: return .sessionOnly(ndi: true)
        case .web, .srt:
            if let name = deck.audioOffset.bookmarkName { return .bookmark(name: name) }
            return .sessionOnly(ndi: false)
        }
    }

    var currentOffsetMs: Int { deck?.audioOffset.sessionMs ?? 0 }

    /// The stream's frame interval, seconds; 0 when unknown. The TRANSPORT's stated rate first (what
    /// `LiveDisplaySize` carries for DeckLink Follow source: NDI's declared N/D, SRT's and WHEP's
    /// estimates), the renderer's measured PTS interval only as a fallback.
    ///
    /// ⚠️ NOT THE RENDERER'S MEDIAN FIRST. Measured (§19.10): NDI frames are stamped on host time at
    /// pull, so an 8-delta median read 41.594 ms (24.04 fps) on a 24000/1001 sender, and the clip
    /// offered was 24p. 23.976 and 24 are 0.1 % apart; only the declared rational separates them there.
    var frameInterval: Double {
        if let fps = LiveDisplaySize.shared.current?.frameRate, fps.isFinite, fps > 0 { return 1 / fps }
        return deck?.renderer?.measuredFrameInterval ?? 0
    }

    /// The stream's frame interval as last read (at open, and on each event while listening): the
    /// sheet's "This stream is 23.976 fps." Published, so no timer polls the renderer.
    @Published private(set) var shownFrameInterval = 0.0

    func present() {
        if phase != .listening { phase = .idle; note = nil; snapshot = nil }
        shownFrameInterval = frameInterval
        NSLog("[CALIBRATION] sheet opened — %@, frame interval %@", String(describing: availability),
              shownFrameInterval > 0 ? String(format: "%.3f ms", shownFrameInterval * 1000)
                                     : (deck?.renderer == nil ? "no renderer" : "not known yet"))
        isPresented = true
    }

    // MARK: Start / stop — the detectors exist only between these

    func start() {
        guard let deck, let engine = deck.engine, let renderer = deck.renderer else { return }
        switch availability {
        case .notConnected, .hls: return
        default: break
        }
        stopDetectors()
        run += 1
        let token = run
        startedAtMs = currentOffsetMs
        note = nil
        lastLoggedPairs = 0
        let m = CalibrationMeasurement(frameSeconds: frameInterval > 0 ? frameInterval : nil)
        measurement = m
        snapshot = m.snapshot
        phase = .listening
        engine.calibrationBeepTap.start { [weak self] tone in
            DispatchQueue.main.async { self?.tone(tone, run: token) }
        }
        renderer.calibrationFlash = MetalVideoRenderer.CalibrationFlashTap(
            heard: { [weak engine] c in engine?.liveAudioHeardMinusClock(against: c) },
            onFlash: { [weak self] pts, h in
                DispatchQueue.main.async { self?.flash(pts: pts, heard: h, run: token) }
            })
        offsetWatch = deck.audioOffset.$sessionMs.dropFirst().removeDuplicates().sink { [weak self] ms in
            self?.offsetChanged(to: ms, run: token)
        }
        NSLog("[CALIBRATION] START run %d (%@) — O %@, frame %@ · detector work this launch: %@", token,
              String(describing: deck.audioOffset.source.map { "\($0)" } ?? "?"),
              LiveAudioOffsetModel.text(startedAtMs),
              frameInterval > 0 ? String(format: "%.3f ms", frameInterval * 1000) : "not known yet",
              SyncCalibrationCounters.snapshot.text)
    }

    /// Remove both detectors. Idempotent.
    private func stopDetectors() {
        let wasOn = deck?.engine?.calibrationBeepTap.isOn == true || deck?.renderer?.calibrationFlash != nil
        deck?.engine?.calibrationBeepTap.stop()
        deck?.renderer?.calibrationFlash = nil
        offsetWatch = nil
        if wasOn {
            NSLog("[CALIBRATION] detectors off — detector work this launch: %@", SyncCalibrationCounters.snapshot.text)
        }
    }

    func stop() {
        stopDetectors()
        run += 1
        if phase == .listening { phase = .idle }
    }

    func cancel() {
        stop()
        isPresented = false
    }

    /// The sheet went away by any route.
    func sheetClosed() {
        stop()
    }

    /// The connection ended (`DeckRegistry`'s release of the live claim).
    func connectionEnded() {
        guard phase == .listening else { return }
        stop()
        note = "The stream disconnected."
    }

    // MARK: Events (main)

    private func tone(_ t: ToneOnset, run token: Int) {
        guard token == run, let m = measurement else { return }
        NSLog("[CALIBRATION] tone %.6f s (level %.1f dBFS, width %.1f ms)", t.time, 20 * log10(max(t.peak, 1e-9)),
              t.widthSeconds * 1000)
        m.addBeep(t.time)
        evaluate(m)
    }

    private func flash(pts: Double, heard h: Double, run token: Int) {
        guard token == run, let m = measurement else { return }
        NSLog("[CALIBRATION] flash pts %.6f s, heard−clock %+.3f ms", pts, h * 1000)
        m.addFlash(pts: pts, heardMinusClock: h)
        evaluate(m)
    }

    private func offsetChanged(to ms: Int, run token: Int) {
        guard token == run, phase == .listening, ms != startedAtMs else { return }
        NSLog("[CALIBRATION] the audio offset changed (%@ → %@) — measuring again",
              LiveAudioOffsetModel.text(startedAtMs), LiveAudioOffsetModel.text(ms))
        start()
        note = "The audio offset changed — measuring again."
    }

    private var lastLoggedPairs = 0
    private var loggedLock = false

    private func evaluate(_ m: CalibrationMeasurement) {
        let fi = frameInterval
        if fi > 0, fi != shownFrameInterval { shownFrameInterval = fi }
        if m.frameSeconds == nil, fi > 0 { m.frameSeconds = fi }
        let s = m.snapshot
        snapshot = s
        if let r = m.lockResult, m.pairs.count > 0, lastLoggedPairs == 0 {
            NSLog("[CALIBRATION] paired by the code: offset %+.2f ms, score %.2f ms, wrong-pairing margin %@ "
                  + "(shift %d, %d pairs in the window)", r.best.offset * 1000, r.best.score * 1000,
                  r.margin.map { String(format: "%.1f ms", $0 * 1000) } ?? "none", r.best.shift, r.best.pairs)
        }
        if s.pairs > lastLoggedPairs, let last = m.pairs.last {
            NSLog("[CALIBRATION] pair %d: heard A/V %+.2f ms · last-10 median %+.2f ms, p10–p90 %.2f ms", s.pairs,
                  last.heard * 1000, (s.median ?? .nan) * 1000, (s.spread ?? .nan) * 1000)
        }
        lastLoggedPairs = s.pairs
        guard s.verdict == .confident, let med = s.median else { return }
        let available = deck?.engine?.liveAudioAvailableAdvance()
        let p = CalibrationProposal(currentMs: startedAtMs, residualSeconds: med,
                                    range: FrameEngine.liveAudioOffsetRangeMs, availableAdvanceSeconds: available)
        NSLog("[CALIBRATION] RESULT heard A/V %+.2f ms (last 10 of %d pairs, p10 %+.2f, p90 %+.2f ms, frame %.3f ms) · O %@ → "
              + "proposed %@%@ · %@", med * 1000, s.pairs, (s.p10 ?? .nan) * 1000, (s.p90 ?? .nan) * 1000,
              (s.frameSeconds ?? .nan) * 1000, LiveAudioOffsetModel.text(p.currentMs),
              LiveAudioOffsetModel.text(p.proposedMs), p.clamped ? " (clamped)" : "",
              p.inSync ? "in sync, nothing to apply"
                : p.applicable ? "applicable"
                : String(format: "NOT APPLICABLE: a %d ms advance, at most %.1f ms available", p.advanceMs,
                         p.availableAdvanceMs ?? .nan))
        stopDetectors()
        lastLoggedPairs = 0
        phase = .result(p)
    }

    // MARK: Apply — only ever on the user's press

    func apply(save: Bool) {
        guard case let .result(p) = phase, p.applicable, let deck else { return }
        let offset = deck.audioOffset
        offset.set(p.proposedMs)
        guard offset.sessionMs == p.proposedMs else {
            // Refused (the banner says why): the result stays on screen.
            NSLog("[CALIBRATION] apply %@ refused — O stays %@", LiveAudioOffsetModel.text(p.proposedMs),
                  LiveAudioOffsetModel.text(offset.sessionMs))
            return
        }
        var saved = false
        if save, case .bookmark = availability {
            offset.saveToBookmark()
            saved = offset.savedMs == p.proposedMs || (offset.savedMs == nil && p.proposedMs == 0)
        }
        NSLog("[CALIBRATION] APPLIED %@ (%@) by the user", LiveAudioOffsetModel.text(p.proposedMs),
              saved ? "this session and the saved stream" : "this session only")
        phase = .applied(p.proposedMs, saved: saved)
    }
}

// MARK: - The sheet

struct CalibrationSheet: View {
    @ObservedObject var model: SyncCalibrationModel
    @ObservedObject var offset: LiveAudioOffsetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.magnifyingglass").font(.title2)
                Text("Calibrate A/V").font(.title2).bold()
            }
            switch model.availability {
            case .hls:
                Label(LiveAudioOffsetModel.hlsNote, systemImage: "nosign")
                    .foregroundStyle(.secondary)
                Text("Calibration isn’t available on HLS.").foregroundStyle(.secondary)
            case .notConnected:
                Text("Connect to a stream that is playing a Manifold sync clip, then calibrate.")
                    .foregroundStyle(.secondary)
            default:
                instructions
                Divider()
                content
            }
            clips
            Spacer(minLength: 0)
            buttons
        }
        .padding(20)
        .frame(width: 540)
        .frame(minHeight: 340)
        .onDisappear { model.sheetClosed() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Play a Manifold sync clip through your encoder at the stream’s frame rate, then press Start. "
                 + "Manifold matches the clip’s flashes to its beeps and measures what you hear, including the "
                 + "current offset (\(LiveAudioOffsetModel.text(offset.sessionMs))).")
                .fixedSize(horizontal: false, vertical: true)
            if case .sessionOnly(let ndi) = model.availability {
                Text(ndi ? "NDI: a result applies to this session only."
                         : "Not a saved stream: a result applies to this connection only.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            if let note = model.note { Text(note).foregroundStyle(.secondary) }
            Text("Not listening.").foregroundStyle(.secondary)
        case .listening:
            progress
        case .result(let p):
            result(p)
        case .applied(let ms, let saved):
            VStack(alignment: .leading, spacing: 6) {
                Label("Applied \(LiveAudioOffsetModel.text(ms))"
                      + (saved ? " to this session and the saved stream." : " for this session."),
                      systemImage: "checkmark.circle")
                Text("Start again to check: it should read close to 0 ms.").foregroundStyle(.secondary)
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Listening…").bold()
            }
            if let note = model.note { Text(note).foregroundStyle(.secondary) }
            if let s = model.snapshot {
                Text(Self.progressLine(s)).monospacedDigit()
                Text(Self.waitingReason(s)).font(.callout).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("calibration.progress")
    }

    static func progressLine(_ s: CalibrationMeasurement.Snapshot) -> String {
        var line = "Pairs found: \(s.pairs) of 10"
        if let sp = s.spread, s.pairs >= 2 { line += String(format: " · spread %.1f ms", sp * 1000) }
        if let f = s.frameSeconds { line += String(format: " (one frame is %.1f ms)", f * 1000) }
        return line
    }

    static func waitingReason(_ s: CalibrationMeasurement.Snapshot) -> String {
        switch s.verdict {
        case .waiting(.pairing(let f, let b)):
            return f + b == 0 ? "Waiting for the clip’s flashes and beeps."
                : "Flashes seen: \(f), beeps heard: \(b). Matching them by the clip’s code…"
        case .waiting(.pairs): return "Collecting pairs."
        case .waiting(.spread): return "The pairs disagree by more than a frame: still listening."
        case .waiting(.unstable): return "Waiting for the figure to hold within ±2 ms over five pairs."
        case .waiting(.walking(let w)):
            return String(format: "The figure is still moving (%.1f ms a second): the stream is settling.", w * 1000)
        case .waiting(.frameRate): return "Waiting for the stream’s frame rate."
        case .confident: return ""
        }
    }

    private func result(_ p: CalibrationProposal) -> some View {
        let late = p.residualMs
        let word = abs(late) < 0.5 ? "in sync" : late > 0 ? "late" : "early"
        return VStack(alignment: .leading, spacing: 6) {
            Text(abs(late) < 0.5 ? "Sound is in sync with the picture."
                 : String(format: "Sound is heard %.0f ms %@.", abs(late), word))
                .font(.headline)
            if let s = model.snapshot {
                // A true minus (U+2212), as every user-facing negative is printed (§19.8 follow-up).
                Text(String(format: "Measured %@ ms over the last 10 pairs (%d found; p10–p90 %.1f ms).",
                            String(format: "%+.1f", late).replacingOccurrences(of: "-", with: "−"),
                            s.pairs, (s.spread ?? 0) * 1000))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Text(Self.proposalLine(p)).monospacedDigit()
            if p.applicable, case .bookmark(let name) = model.availability {
                Text("Apply and Save also stores it in “\(name)”; Apply for Session lasts until you disconnect.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if p.inSync {
                Text("Nothing to change.").foregroundStyle(.secondary)
            } else if !p.applicable {
                Label("Not applicable: moving sound \(p.advanceMs) ms earlier needs more of the stream "
                      + "buffered than it has. At most \(Int((p.availableAdvanceMs ?? 0).rounded(.down))) ms "
                      + "is available on this stream right now.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("calibration.result")
    }

    static func proposalLine(_ p: CalibrationProposal) -> String {
        var line = "Current offset " + LiveAudioOffsetModel.text(p.currentMs)
        line += " → proposed " + LiveAudioOffsetModel.text(p.proposedMs)
        if p.clamped {
            let lo = LiveAudioOffsetModel.signed(p.range.lowerBound)
            let hi = LiveAudioOffsetModel.signed(p.range.upperBound)
            line += " (the limit: " + LiveAudioOffsetModel.text(p.unclampedMs) + " is outside " + lo + " to " + hi + " ms)"
        }
        return line + "."
    }

    @ViewBuilder
    private var clips: some View {
        VStack(alignment: .leading, spacing: 4) {
            if SyncClipLibrary.isBundled {
                HStack {
                    Button("Get Sync Clip…") {
                        SyncClipLibrary.saveClip(frameInterval: model.shownFrameInterval, window: NSApp.keyWindow)
                    }
                    if let (_, text) = SyncClipLibrary.rateNote(frameInterval: model.shownFrameInterval) {
                        Text(text).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(SyncClipLibrary.notBundledNote).font(.callout)
                Link("Download the sync clips (releases.graviton.tools)", destination: SyncClipLibrary.downloadURL)
                    .font(.callout)
                Text("Calibration works with a Manifold sync clip from anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            switch model.phase {
            case .listening:
                Button("Stop") { model.stop() }.accessibilityIdentifier("calibration.stop")
            case .result(let p):
                Button("Measure Again") { model.start() }.accessibilityIdentifier("calibration.again")
                Spacer()
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("calibration.cancel")
                if case .bookmark(let name) = model.availability {
                    Button("Apply for Session") { model.apply(save: false) }.disabled(!p.applicable)
                        .accessibilityIdentifier("calibration.applySession")
                    Button("Apply and Save") { model.apply(save: true) }
                        .help("Apply now and save it to “\(name)”")
                        .disabled(!p.applicable).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("calibration.applySave")
                } else {
                    Button("Apply for Session") { model.apply(save: false) }
                        .disabled(!p.applicable).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("calibration.applySession")
                }
            default:
                Button("Start") { model.start() }
                    .disabled({ if case .hls = model.availability { return true }
                                if case .notConnected = model.availability { return true }
                                return false }())
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("calibration.start")
            }
            if !({ if case .result = model.phase { return true }; return false }()) {
                Spacer()
                Button("Close") { model.cancel() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("calibration.close")
            }
        }
    }
}

/// Hosts the sheet on a window without growing `ContentView`'s body (at the type-checker's limit).
struct CalibrationSheetHost: View {
    @ObservedObject var model: SyncCalibrationModel
    let offset: LiveAudioOffsetModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: $model.isPresented) {
                CalibrationSheet(model: model, offset: offset)
            }
    }
}
