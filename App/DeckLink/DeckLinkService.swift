import Foundation
import Combine
import ManifoldCore

/// App-side service for Blackmagic DeckLink OUTPUT. Hardware I/O lives in the App layer, decoupled
/// from ManifoldCore's engine logic. Owns the output on/off state + selected device as observable
/// so the toolbar control and the ⌃⌥O/⌃⌥⇧O shortcuts share one source of truth.
/// BMD output arc: D1 enumerate → D2 first frame → D3 scheduled playback → D-real real video → D5 709.
final class DeckLinkService: ObservableObject {

    /// A Swift-native snapshot of an output-capable device (mirrors DeckLinkDeviceInfo from the bridge).
    struct Device {
        let index: Int
        let modelName: String
        let displayName: String
    }

    static let shared = DeckLinkService()

    /// @AppStorage key for the "Enable output on launch" preference (Settings → DeckLink Output).
    /// Explicit opt-in default behavior — NOT last-session persistence. Default false. Shared with
    /// SettingsView so the key can't drift.
    static let enableOnLaunchKey = "manifold.decklink.enableOnLaunch"

    /// Fixed pixel-format part of the output signal (plain-speak, NO codec/"v210" jargon). The mode
    /// (varies per file — D4a) and the colorspace (varies per source — D5) are composed around it in
    /// `signalLine`.
    static let formatDetail = "10-bit 4:2:2"

    // Observable UI state (mutated on main).
    @Published private(set) var isOutputting = false     // reflects the ACTUAL scheduled-playback state
    @Published private(set) var selectedDeviceIndex = 0  // which enumerated device output targets
    @Published private(set) var devices: [Device] = []   // cached enumeration for the picker
    /// Plain-speak colorspace label for the current source (DISPLAY ONLY — the actual output tag is
    /// unchanged: D5 tags both 2020 and P3 as Rec.2020). Derived from the source colorPrimariesCode,
    /// so it can distinguish genuine 2020 from P3-in-2020 (which the collapsed tag cannot). nil → 709.
    @Published private(set) var colorspaceLabel = "Rec. 709"
    /// Plain-speak display-mode label for the current source (D4a), e.g. "2160p23.98" / "1080p25" /
    /// "2160p59.94". Tracks the resolved output mode whether or not output is running (the signal the
    /// output produces / would produce), mirroring `colorspaceLabel`. Updated by `sourceFormatChanged`.
    @Published private(set) var modeLabel = OutputMode.default2160p2398.label

    /// The full Signal line for the output menu: active display mode · fixed format · source colorspace.
    var signalLine: String { "\(modeLabel) · \(Self.formatDetail) · \(colorspaceLabel)" }

    /// Map a source CICP primaries code → plain-speak label. "(P3 limited)" flags P3 content sitting
    /// inside the Rec.2020 container (what's actually on the wire is Rec.2020, per D5's tag).
    static func colorspaceLabel(forPrimaries code: Int?) -> String {
        switch code {
        case 9:       return "Rec. 2020"              // genuine Rec.2020
        case 11, 12:  return "Rec. 2020 (P3 limited)" // DCI-P3 / P3-D65 → P3-in-2020
        default:      return "Rec. 709"               // 1 / nil / 2 (unspecified) / unknown
        }
    }

    /// One bridge instance holds the output state across start/stop calls. Serial queue so
    /// start/stop can't race and never block the UI thread.
    private let bridge = DeckLinkBridge()
    private let queue = DispatchQueue(label: "com.graviton.manifold.decklink")

    /// The renderer that produces the real video frames (set by the App at startup). Weak — the
    /// renderer owns its lifecycle; the fill block sources v210 frames from it.
    weak var renderer: MetalVideoRenderer?

    // MARK: - D4b-2: SDI audio

    /// The engine's PCM ring (D4b-1), set by the App at startup alongside `renderer`. The card's audio
    /// callback pulls from it by SOURCE TIME. Nil → video-only output.
    var audioTap: AudioTapBuffer?

    /// The transport gate, read on the card's audio-callback thread (FrameEngine.isCardAudioSilent).
    /// True → schedule silence. Set by the App at startup, like `renderer.clock`.
    var isCardAudioSilentProvider: (() -> Bool)?

    /// D4b-3: hands the system (computer) renderer's mute authority to the engine. Called with
    /// `deckLinkOutputEnabled && destination == .sdi`. Set by the App at startup, like the providers
    /// above. This is the ONLY way the destination touches the system path.
    var systemAudioRouting: ((Bool) -> Void)?

    // MARK: - D4b-3: audio destination (SDI vs Computer — mutually exclusive)

    /// Where the program audio goes while DeckLink output is enabled. There is deliberately no "Both":
    /// the same program on two paths is never wanted (comb-filtered double audio, and the two clocks
    /// drift apart). The choice only has authority while output is ON — with DeckLink off, audio is
    /// plain desktop playback governed by the mute button alone.
    enum AudioDestination: String {
        case sdi        // embedded on the SDI signal, clock-locked to the video on the wire (default)
        case computer   // the Mac's normal audio path; the SDI stream carries digital silence
    }

    /// Default .sdi: enabling a broadcast output and hearing the program from the laptop speakers,
    /// half a pipeline-depth out of sync with the monitor, is never what was meant.
    @Published private(set) var audioDestination: AudioDestination = .sdi

    /// Thread-safe mirror of `audioDestination` for the card's audio-callback thread (which cannot read
    /// main-actor/published state), same discipline as the engine's gate mirrors.
    private let destinationLock = NSLock()
    private var sdiIsAudioDestinationMirror = true

    /// Read on the SDK audio-callback thread: is SDI the live audio destination?
    private func sdiIsAudioDestination() -> Bool {
        destinationLock.lock(); defer { destinationLock.unlock() }
        return sdiIsAudioDestinationMirror
    }

    /// Flip the destination live (toolbar menu). A destination change is ROUTING ONLY — it never
    /// re-enables/prerolls/restarts the card (that would blip video and dump the preroll depth). The
    /// card's audio output stays enabled for BOTH destinations; only which path emits real PCM changes:
    ///   .sdi      → SDI serves PCM, system renderer muted.
    ///   .computer → SDI serves SILENCE (the same silence path the pause/shuttle gate already uses),
    ///               system renderer unmuted (subject to the user's mute).
    func setAudioDestination(_ destination: AudioDestination) {
        guard destination != audioDestination else { return }
        audioDestination = destination
        destinationLock.lock(); sdiIsAudioDestinationMirror = (destination == .sdi); destinationLock.unlock()
        print("DeckLink D4b-3: audio destination → \(destination.rawValue)")
        applyAudioRouting()
    }

    /// The SINGLE place the system-renderer mute is re-evaluated from the DeckLink side. Every
    /// transition that can change the answer routes through here — output start, output start FAILURE,
    /// output stop, and a destination flip — so a stale destination can never leave desktop audio muted.
    ///
    /// The rule, exactly: the card owns the program only when `isOutputting && destination == .sdi`.
    /// With output OFF the first term is false, the DeckLink term drops out of the engine's mute rule
    /// entirely, and Mac audio returns to being governed by the user's mute alone — regardless of what
    /// `audioDestination` still holds.
    private func applyAudioRouting() {
        let owns = isOutputting && audioDestination == .sdi
        if Thread.isMainThread {
            systemAudioRouting?(owns)
        } else {
            DispatchQueue.main.async { self.systemAudioRouting?(owns) }
        }
    }

    /// The ONE residual-latency knob (seconds). The audio callback already measures and compensates the
    /// two pipelines' queue depths every callback (card audio buffer vs card video queue), so this only
    /// absorbs what those depths don't describe: the staging hop, and the card's own embedder/DAC delay.
    /// It is 0 by default because the two depths are matched by construction — a 200 ms audio target
    /// against a 4-frame video pool (~208 ms at 24p).
    ///
    /// POSITIVE → pull audio from EARLIER in the source, i.e. audio arrives SOONER on the wire. So if a
    /// lip-sync test shows audio LATE by 2 frames at 24p, set it to +0.083.
    ///
    /// Tunable in the field WITHOUT a rebuild (the point of a trim):
    ///   defaults write com.graviton.manifold manifold.decklink.audioTrimSeconds -float 0.02
    /// Read at output START, so toggle output off/on to apply.
    static let audioTrimKey = "manifold.decklink.audioTrimSeconds"
    static var audioTrimSeconds: Double {
        (UserDefaults.standard.object(forKey: audioTrimKey) as? Double) ?? 0.0
    }

    /// The audio format the card is CURRENTLY enabled with (nil = video-only). Touched only on `queue`.
    /// Compared against the tap's live format to decide whether a format change needs a restart — the
    /// card's rate/channel count is fixed at EnableAudioOutput time and cannot be changed under a
    /// running stream.
    private var enabledAudioFormat: AudioTapBuffer.Format?

    /// The parameters the CURRENT output was started with. Touched only on `queue`, so an audio-format
    /// restart (which arrives on the decode thread, not main) can re-establish the identical video
    /// output without reading main-actor state off-thread. Every start path records them.
    private var activeStart: (deviceIndex: Int, mode: OutputMode, primariesCode: Int)?

    /// D4a: the output DISPLAY MODE derived from the loaded file (video cadence). Resolution follows
    /// the file's family (2160p or 1080p, native 1:1 — no scaling); rate follows the file's frame rate
    /// snapped to a standard broadcast rate. `standardRate` + `width`/`height` drive the bridge's mode
    /// selection and scheduling; `label` is the plain-speak status string.
    struct OutputMode: Equatable {
        let width: Int          // output-family width (3840 or 1920)
        let height: Int         // output-family height (2160 or 1080)
        let standardRate: Double // snapped standard rate (23.976 / 24 / 25 / 29.97 / 30 / 50 / 59.94 / 60)
        let label: String       // "2160p23.98", "1080p25", …

        /// Default when no file is loaded / rate can't be matched — matches the pre-D4a fixed output.
        static let default2160p2398 = OutputMode(width: 3840, height: 2160, standardRate: 24000.0 / 1001.0, label: "2160p23.98")
    }

    /// The standard broadcast frame rates D4a targets, as EXACT fps (the fractional NTSC rates use
    /// their true n/1001 value, NOT a rounded literal) paired with the status token. Nearest-match
    /// against these exact values has no seam: 30000/1001 = 29.970 sits ~0 from the 29.97 entry and
    /// ~0.03 from the 30 entry, so it can never be trapped on a boundary and fall through to a
    /// fallback. The BMD mode is chosen from the same matched rate on the bridge side
    /// (BMDModeForFamilyRate, exact-fraction rows), so the label and the mode always agree.
    private static let standardRates: [(fps: Double, token: String)] = [
        (24000.0 / 1001.0, "23.98"),   // 23.976…
        (24.0,             "24"),
        (25.0,             "25"),
        (30000.0 / 1001.0, "29.97"),   // 29.970…
        (30.0,             "30"),
        (50.0,             "50"),
        (60000.0 / 1001.0, "59.94"),   // 59.940…
        (60.0,             "60"),
    ]

    /// The output mode resolved from the CURRENT source (or the default when none is loaded). Read on
    /// the serial queue when (re)starting; written on `sourceFormatChanged`.
    private var currentMode = OutputMode.default2160p2398

    /// Map a file's (width, height, frameRate) → the output display mode.
    /// - Resolution family: nearest of the two D4a families by height (≥1620 → 2160p, else 1080p). The
    ///   output is NATIVE (1:1) for true 3840×2160 / 1920×1080 sources; a non-standard resolution (e.g.
    ///   DCI 4096) maps to the nearest family and outputs a valid signal at the right rate (the render
    ///   convert holds neutral for a genuine pixel-dim mismatch — true scaling is a later stage).
    /// - Rate: NEAREST-MATCH to a standard broadcast rate by minimum absolute fps difference — no
    ///   ranges, no boundaries, no seams. Every input maps to exactly one closest standard rate, so a
    ///   30000/1001 = 29.970 source resolves to 29.97 (→ p2997), never trapped on a bucket edge and
    ///   never falling through to a fallback. Weird rates (23.9, 26, …) also map to their nearest.
    static func resolveOutputMode(width: Int, height: Int, frameRate: Double) -> OutputMode {
        let is2160 = height >= 1620
        let outW = is2160 ? 3840 : 1920
        let outH = is2160 ? 2160 : 1080
        let famToken = is2160 ? "2160p" : "1080p"

        // Nearest standard rate by minimum |Δfps|. The matched entry supplies BOTH the canonical rate
        // (passed to the bridge for mode selection) and the status token — one source of truth, so the
        // label and the selected BMD mode can't disagree. frameRate ≤ 0 (no/unknown) → the 23.976 entry.
        var best = standardRates[0]
        if frameRate > 0 {
            var bestDist = Double.greatestFiniteMagnitude
            for cand in standardRates {
                let d = abs(frameRate - cand.fps)
                if d < bestDist { bestDist = d; best = cand }
            }
        }
        return OutputMode(width: outW, height: outH, standardRate: best.fps,
                          label: "\(famToken)\(best.token)")
    }

    /// Enumerate output-capable DeckLink devices. Synchronous SDK walk; returns [] if the driver
    /// isn't reachable or no card is present.
    func outputDevices() -> [Device] {
        DeckLinkBridge.enumerateOutputDevices().map {
            Device(index: $0.index, modelName: $0.modelName, displayName: $0.displayName)
        }
    }

    /// Refresh the cached device list for the picker (call at startup / when the menu opens). Clamps
    /// the selection if the list shrank. Publishes on main.
    func refreshDevices() {
        let ds = outputDevices()
        DispatchQueue.main.async {
            self.devices = ds
            if self.selectedDeviceIndex >= ds.count { self.selectedDeviceIndex = 0 }
        }
    }

    private var hasAutoStarted = false   // one-shot guard so launch auto-start fires at most once

    /// Launch behavior for the "Enable output on launch" preference. Fires at most once per launch.
    /// Guard sequence: pref TRUE → a capable device is PRESENT (enumeration non-empty) → start via
    /// the normal path (device 0 by default, which does 2160p; a non-capable pick reverts on failure
    /// via the existing revert-on-failure). NEVER auto-starts when the pref is off, and never into
    /// absent hardware. No file required — if none is loaded yet, the neutral-black fallback shows
    /// until frames arrive (the same behavior as a manual start before loading).
    func autoStartOnLaunchIfEnabled() {
        guard !hasAutoStarted else { return }
        hasAutoStarted = true
        guard UserDefaults.standard.bool(forKey: Self.enableOnLaunchKey) else { return }   // pref off → nothing
        guard !outputDevices().isEmpty else {                                               // no hardware → skip
            print("DeckLink: enable-on-launch is on but no output device is present — skipping")
            return
        }
        print("DeckLink: enable-on-launch — starting output on device \(selectedDeviceIndex)")
        startScheduledOutput()   // revert-on-failure handles a present-but-incapable device gracefully
    }

    // MARK: - Shared action path (button, chevron device-switch, and ⌃⌥O/⌃⌥⇧O all route here)

    /// Toggle output on/off — the primary action shared by the toolbar button and ⌃⌥O.
    func toggleOutput() {
        if isOutputting { stopScheduledOutput() } else { startScheduledOutput() }
    }

    /// Pick the output device. If output is ON, cleanly stop and restart on the new device (the
    /// serial queue guarantees stop completes before the restart). No-op if unchanged.
    func selectDevice(_ index: Int) {
        guard index != selectedDeviceIndex else { return }
        let wasOn = isOutputting
        if wasOn { stopScheduledOutput() }
        selectedDeviceIndex = index
        if wasOn { startScheduledOutput() }
    }

    /// Start CONTINUOUS scheduled playback of REAL video on the selected device — each output frame
    /// is filled from the renderer's latest converted v210 staging buffer (push-on-render /
    /// pull-latest). Requires a file rendering; until the first frame is ready the fill shows neutral
    /// black. `isOutputting` flips true optimistically and reverts if the bridge start fails.
    func startScheduledOutput() {
        guard !isOutputting else { return }
        isOutputting = true
        applyAudioRouting()   // D4b-3: ENABLE transition — with .sdi (the default), the Mac goes silent
        let deviceIndex = selectedDeviceIndex
        // D5 output-signal TAG ← source PRIMARIES code ONLY (never the matrix; the kernel picks the
        // encoding matrix from the matrix code, independently). nil → 709.
        let primariesCode = renderer?.sourcePrimariesCode ?? 1
        let mode = currentMode   // D4a: display mode derived from the current source (or default)
        queue.async {
            self.startOutputOnQueue(deviceIndex: deviceIndex, mode: mode, primariesCode: primariesCode)
        }
    }

    /// Establish scheduled output at `mode` on the serial queue. Shared by the initial start and the
    /// D4a mode-switch (which stops the old output on the same queue first, guaranteeing teardown
    /// completes before this re-establishes). Arms the renderer's convert at the mode's resolution
    /// (native 1:1) and drives the bridge's mode/scheduling from the mode's family + standard rate.
    private func startOutputOnQueue(deviceIndex: Int, mode: OutputMode, primariesCode: Int) {
        self.activeStart = (deviceIndex, mode, primariesCode)   // so an audio restart can replay it

        // Arm the renderer's push convert (allocate v210 staging sized to the OUTPUT frame = the mode's
        // resolution; the source offscreen is the same size for a native file → 1:1, no scaling).
        self.renderer?.beginDeckLinkOutput(width: mode.width, height: mode.height)

        // The fill block runs on the SDK callback thread → cheap: a memcpy from the renderer's front
        // staging buffer, or a neutral fallback if no converted frame is ready yet.
        let fill: DeckLinkFillBlock = { [weak self] _, buffer, rowBytes, width, height in
            if let r = self?.renderer,
               r.copyLatestDeckLinkFrame(into: UnsafeMutableRawPointer(buffer),
                                         rowBytes: Int(rowBytes), width: Int(width), height: Int(height)) {
                return true
            }
            Self.fillNeutralV210(buffer, rowBytes: Int(rowBytes), width: Int(width), height: Int(height))
            return false
        }

        // D4b-2: resolve the audio stream for THIS start. Remembered so a later format change can tell
        // whether it needs to re-establish the output (the card's rate/channels are fixed at enable).
        let audioFormat = self.audioTap?.format
        self.enabledAudioFormat = Self.isSupportedForSDI(audioFormat) ? audioFormat : nil
        let audio = self.makeAudioConfig(for: self.enabledAudioFormat)

        let result = self.bridge.startScheduledPlayback(withDeviceIndex: deviceIndex, fill: fill,
                                                        primariesCode: primariesCode,
                                                        outputWidth: mode.width, outputHeight: mode.height,
                                                        standardRate: mode.standardRate,
                                                        audio: audio)
        for line in result.log { print("DeckLink D-real: \(line)") }
        print("DeckLink D-real: \(result.success ? "SUCCESS — real-video scheduled playback on device \(deviceIndex) @ \(result.activeModeName ?? mode.label)" : "FAILED")")
        if result.success {
            // Reflect the mode actually established (honors any bridge-side support fallback).
            if let active = result.activeModeName {
                DispatchQueue.main.async { self.modeLabel = active }
            }
        } else {
            self.renderer?.stopDeckLinkOutput()
            DispatchQueue.main.async {
                self.isOutputting = false      // keep the button honest
                self.applyAudioRouting()       // D4b-3: a FAILED start must not leave the Mac muted
            }
        }
    }

    /// Stop scheduled playback cleanly + disarm the renderer's push convert (D3 race-safe stop). Audio
    /// tears down inside the bridge's stop, symmetric with setup (stop playback → unset the audio
    /// callback → flush → DisableAudioOutput → DisableVideoOutput).
    func stopScheduledOutput() {
        guard isOutputting else { return }
        isOutputting = false
        // D4b-3 — THE critical transition. Re-evaluate the system-renderer mute the instant output goes
        // off, BEFORE the async teardown: `isOutputting` is now false, so the DeckLink term drops out of
        // the engine's mute rule and desktop audio returns to being governed by the user's mute alone.
        // The destination enum keeps whatever value it had and now has no authority over either path —
        // which is exactly why this call is unconditional and not guarded on `audioDestination == .sdi`.
        applyAudioRouting()
        queue.async {
            self.bridge.stopScheduledPlayback()
            self.renderer?.stopDeckLinkOutput()
            self.enabledAudioFormat = nil
            self.activeStart = nil
            print("DeckLink D-real: output stopped")
        }
    }

    // MARK: - D4b-2: audio stream configuration

    /// The SDK's audio-output constraints, checked ONCE here so the bridge never mis-signals the wire:
    ///  • Sample rate: BMDAudioSampleRate defines exactly ONE value — 48 kHz. A 44.1k/96k source cannot
    ///    be embedded without resampling (a real DSP stage, deliberately out of scope for D4b-2), so it
    ///    is REFUSED with a clear log rather than silently declared as 48k, which would play back at the
    ///    wrong pitch AND drift against the video forever.
    ///  • Channel count: only 2/8/16/32/64 are legal; the tap already computes the padded count.
    private static func isSupportedForSDI(_ format: AudioTapBuffer.Format?) -> Bool {
        guard let format else { return false }
        guard format.channelCount > 0 else { return false }
        guard Int(format.sampleRate.rounded()) == 48_000 else {
            print("DeckLink D4b-2: source audio is \(Int(format.sampleRate)) Hz — the DeckLink SDK embeds "
                + "48 kHz ONLY (BMDAudioSampleRate has a single member). Refusing to mis-signal it: SDI "
                + "audio is DISABLED for this file (video-only output). Resampling to 48 kHz is a "
                + "separate DSP stage; system audio is unaffected.")
            return false
        }
        return true
    }

    /// Build the bridge's audio config from a validated format. The three blocks are the entire seam the
    /// card's audio callback has into the app — each is a cheap, lock-guarded read, safe to call at
    /// ~50 Hz on the SDK's thread:
    ///   sourceTime — the SOURCE pts of the frame in the DeckLink staging buffer (i.e. on the wire).
    ///   isSilent   — the transport gate (mute / pause / off-speed shuttle) AND the destination (D4b-3).
    ///   read       — the PTS-keyed ring read (D4b-1), returning how many frames actually existed.
    private func makeAudioConfig(for format: AudioTapBuffer.Format?) -> DeckLinkAudioConfig? {
        guard let format, let tap = audioTap else { return nil }
        let trim = Self.audioTrimSeconds
        return DeckLinkAudioConfig(
            sampleRate: format.sampleRate,
            sourceChannelCount: format.channelCount,
            deckLinkChannelCount: format.deckLinkChannelCount,
            trimSeconds: trim,
            sourceTime: { [weak self] in self?.renderer?.currentDeckLinkSourcePts() ?? .nan },
            isSilent: { [weak self] in
                guard let self else { return true }
                // D4b-3: the destination is an ADDITIONAL AND on the existing PCM gate, never a
                // replacement for it. .computer → silence on SDI, served by the very same
                // scheduleSilence() path the pause/shuttle gate already uses: the card's audio output
                // stays ENABLED and fed with zeros, so a destination flip never starves it, never
                // re-prerolls, and never touches the video.
                if !self.sdiIsAudioDestination() { return true }
                return self.isCardAudioSilentProvider?() ?? true
            },
            read: { startTime, frameCount, dst in
                Int32(tap.read(framesStartingAt: startTime, frameCount: Int(frameCount), into: dst))
            })
    }

    /// The tap's capture format appeared or changed (new file, or the first decoded buffer of one). The
    /// card's sample rate + channel count are FIXED at EnableAudioOutput and cannot change under a
    /// running stream, so a genuine change means re-establishing the output — the same stop-then-start
    /// hop the D4a mode switch uses, on the same serial queue (teardown completes before re-establish).
    ///
    /// This is what makes the natural order work: enable output first, load a file second. Without it,
    /// output started before any audio was decoded would stay video-only for the life of the session.
    func audioFormatChanged(_ format: AudioTapBuffer.Format) {
        queue.async {
            // Not running → nothing to re-establish; the next start reads the tap's format directly.
            // `activeStart` is the queue's own record of the live output, so no main-actor state is
            // touched from the decode thread this call arrives on.
            guard self.isOutputting, let start = self.activeStart else { return }
            let wanted = Self.isSupportedForSDI(format) ? format : nil
            // Only the wire-visible parts matter; the decode path (AVF vs libav) does not.
            let same = (wanted?.sampleRate == self.enabledAudioFormat?.sampleRate)
                && (wanted?.channelCount == self.enabledAudioFormat?.channelCount)
            guard !same else { return }

            print("DeckLink D4b-2: audio format → "
                + (wanted.map { "\(Int($0.sampleRate))Hz \($0.channelCount)ch" } ?? "none")
                + "; re-establishing output to (re)enable the SDI audio stream")
            self.bridge.stopScheduledPlayback()
            self.renderer?.stopDeckLinkOutput()
            self.startOutputOnQueue(deviceIndex: start.deviceIndex, mode: start.mode,
                                    primariesCode: start.primariesCode)
        }
    }

    /// The source color tags changed (new file / re-inspect). Updates the DISPLAY label always
    /// (independent of output state), and — if output is running — re-applies the colorspace TAG
    /// from the new primaries. Both read colorPrimariesCode ONLY (the encoding matrix follows the
    /// matrix code, separately). Call after setSourceColorSpace.
    func sourceColorChanged() {
        let primariesCode = renderer?.sourcePrimariesCode
        // Display label tracks the current source whether or not output is on (it's the signal that
        // output produces / would produce). DISPLAY ONLY — does not touch the actual tag.
        let label = Self.colorspaceLabel(forPrimaries: primariesCode)
        DispatchQueue.main.async { self.colorspaceLabel = label }
        // Re-tag the live output signal only if currently playing.
        guard isOutputting else { return }
        queue.async { self.bridge.setOutputColorspaceForPrimaries(primariesCode ?? 1) }
    }

    /// D4a: the source video FORMAT changed (new file / re-inspect). Recompute the output display mode
    /// from the file's resolution + frame rate. Always updates the status label (the mode output
    /// produces / would produce, whether or not it's running). If output IS running and the mode
    /// actually changed, cleanly SWITCH: stop the old scheduled playback then re-establish at the new
    /// mode — both hops on the serial queue so teardown finishes before re-establish (no race). If
    /// output is off, just remember the target so the next start uses it. Call after setSourceColorSpace.
    func sourceFormatChanged(width: Int, height: Int, frameRate: Double) {
        let mode = Self.resolveOutputMode(width: width, height: height, frameRate: frameRate)
        let changed = (mode != currentMode)
        currentMode = mode
        DispatchQueue.main.async { self.modeLabel = mode.label }

        // Only a running output needs a live switch; an off output just adopts `currentMode` on start.
        guard isOutputting, changed else { return }
        let deviceIndex = selectedDeviceIndex
        let primariesCode = renderer?.sourcePrimariesCode ?? 1
        print("DeckLink D4a: source mode → \(mode.label); switching live output")
        queue.async {
            // Race-safe stop (clear running → StopScheduledPlayback → unset callback → DisableVideoOutput
            // → release pool), then re-establish at the new mode. isOutputting stays true across the
            // switch (it's a re-mode, not a user stop).
            self.bridge.stopScheduledPlayback()
            self.renderer?.stopDeckLinkOutput()
            self.startOutputOnQueue(deviceIndex: deviceIndex, mode: mode, primariesCode: primariesCode)
        }
    }

    /// Neutral legal-black v210 fill (10-bit Y=64, Cb=Cr=512) — shown until the first real converted
    /// frame is ready, so the card never gets garbage. For solid black the four v210 words are a
    /// fixed pattern: w0=w2=0x20010200 (Cb|Y|Cr = 512|64|512), w1=w3=0x04080040 (Y|Cb|Y = 64|512|64),
    /// repeated per 6-pixel group (16 bytes), across the 128-byte-aligned rowBytes.
    private static func fillNeutralV210(_ buffer: UnsafeMutablePointer<UInt8>, rowBytes: Int, width: Int, height: Int) {
        let w0: UInt32 = 0x2001_0200   // Cb0(512) | Y0(64)<<10 | Cr0(512)<<20
        let w1: UInt32 = 0x0408_0040   // Y1(64)  | Cb2(512)<<10 | Y2(64)<<20
        let groupsPerRow = rowBytes / 16
        buffer.withMemoryRebound(to: UInt32.self, capacity: (rowBytes / 4) * height) { words in
            for y in 0..<height {
                var p = y * (rowBytes / 4)
                for _ in 0..<groupsPerRow {
                    words[p + 0] = w0; words[p + 1] = w1; words[p + 2] = w0; words[p + 3] = w1
                    p += 4
                }
            }
        }
    }

    /// D1 probe: log the connected output devices once at startup. Runs off the main thread so a
    /// slow driver query never delays launch.
    func logDevicesAtStartup() {
        DispatchQueue.global(qos: .utility).async {
            let devices = self.outputDevices()
            if devices.isEmpty {
                print("DeckLink: found 0 output device(s) (no card / driver not reachable)")
            } else {
                let list = devices
                    .map { "\($0.modelName) (\($0.displayName))" }
                    .joined(separator: ", ")
                print("DeckLink: found \(devices.count) output device(s): \(list)")
            }
        }
    }
}
