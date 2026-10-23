import Foundation
import Combine
import ManifoldCore
import ColorimetryModel   // OutputSignal — what each frame is tagged with (colour S7)

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

    /// A device the driver returned that would not open for output (mirrors
    /// DeckLinkRejectedDeviceInfo). Carried, not counted-and-discarded: the HRESULT is the sentence
    /// that says "this is a driver version, not a cable".
    struct RejectedDevice: Equatable {
        let index: Int
        let modelName: String
        let hresultHex: String
        /// One log/diagnostics line. `modelName` is "" when the driver would not name it.
        var summary: String {
            let name = modelName.isEmpty ? "unnamed device" : modelName
            return "[\(index)] \(name) — no IDeckLinkOutput (\(hresultHex))"
        }
    }

    /// One enumeration walk, whole. THE POINT IS `total`: `usable.count` alone cannot tell "nothing
    /// is plugged in" from "three cards are plugged in and this driver cannot present any of them",
    /// and those two have completely different answers for the user.
    struct Enumeration {
        var total: Int = 0
        var usable: [Device] = []
        var rejected: [RejectedDevice] = []

        static func probe() -> Enumeration {
            let r = DeckLinkBridge.enumerateDevices()
            return Enumeration(
                total: r.totalCount,
                usable: r.usable.map { Device(index: $0.index, modelName: $0.modelName,
                                              displayName: $0.displayName) },
                rejected: r.rejected.map { RejectedDevice(index: $0.index, modelName: $0.modelName,
                                                          hresultHex: $0.hresultHex) })
        }
    }

    static let shared = DeckLinkService()

    init() {
        // SDI scaling: the Settings choices (mode set, scaling) take effect at once (an @AppStorage write posts this).
        modeSetObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            self?.sdiSettingsMayHaveChanged()
        }
    }

    /// The Blackmagic Desktop Video download page — single source of truth for the Settings
    /// "Download Desktop Video…" button (state (a), driver absent). Analogous to NDIService.runtimeInstallURL.
    static let driverInstallURL = URL(string: "https://www.blackmagicdesign.com/support")!

    /// @AppStorage key for the "Enable output on launch" preference (Settings → DeckLink Output).
    /// Explicit opt-in default behavior — NOT last-session persistence. Default false. Shared with
    /// SettingsView so the key can't drift.
    static let enableOnLaunchKey = "manifold.decklink.enableOnLaunch"

    /// Fixed pixel-format part of the output signal (plain-speak, NO codec/"v210" jargon). The mode
    /// (varies per file — D4a) and the colorspace (varies per source — D5) are composed around it in
    /// `signalLine`.
    static let formatDetail = "10-bit 4:2:2"

    /// How long a start waits for a PAUSED frame's v210 convert before prerolling (`primeDeckLinkFrame`). A render
    /// is one display tick plus a GPU pass, a few ms; the bound only matters when nothing is on screen to render.
    static let primeTimeout: TimeInterval = 0.25

    // Observable UI state (mutated on main).
    @Published private(set) var isOutputting = false     // reflects the ACTUAL scheduled-playback state
    @Published private(set) var selectedDeviceIndex = 0  // which enumerated device output targets
    @Published private(set) var devices: [Device] = []   // cached enumeration for the picker
    /// How many devices the last walk returned BEFORE the output filter, and the ones it dropped.
    /// Published alongside `devices` from the same walk, so the two counts in any message the UI
    /// builds are always from one snapshot.
    @Published private(set) var devicesEnumerated = 0
    @Published private(set) var rejectedDevices: [RejectedDevice] = []
    /// Whether the Desktop Video framework loaded (driver installed), independent of any card being
    /// present. Distinguishes state (a) "driver absent" from (b) "driver present, no device" — which
    /// `devices.isEmpty` alone cannot. Published by `refreshDevices()`. Relaunch-only for install/uninstall
    /// (the framework load is pthread_once-cached); card plug/unplug is live via re-enumeration.
    @Published private(set) var driverInstalled = false
    /// The INSTALLED Desktop Video version ("12.8.1"), or nil when the driver is absent or the
    /// version couldn't be read. Read at startup and on every `refreshDevices()` — the query needs no
    /// card and no output attempt, so there is no reason to withhold it until the user clicks Output.
    /// nil is reported as "unknown", never as "old".
    @Published private(set) var driverVersion: String?
    /// Whether the installed driver satisfies the output floor. False when the driver is absent OR
    /// when the version couldn't be read (fail closed — the bridge would abort anyway).
    @Published private(set) var driverMeetsFloor = false
    /// Plain-speak colorspace label for the picture (DISPLAY ONLY — each frame carries its own tag, colour S7 D1).
    /// From the picture's primaries, so it tells genuine 2020 from P3 converted into 2020 (D4). nil → 709.
    @Published private(set) var colorspaceLabel = "Rec. 709"
    /// Colour S7-3: the EOTF the output signals ("SDR" / "PQ" / "HLG"), from the renderer's output signal.
    @Published private(set) var eotfLabel = OutputEOTF.sdr.name
    /// Colour S7-3: the static metadata a PQ signal sends (HDMI's InfoFrame; SDI carries none, D6), in words, and
    /// whether the defaults were sent; nil when none is sent (SDR, HLG).
    @Published private(set) var hdrMetadataLine: String?
    /// Plain-speak display-mode label for the current source (D4a), e.g. "2160p23.98" / "1080p25" /
    /// "2160p59.94". Tracks the resolved output mode whether or not output is running (the signal the
    /// output produces / would produce), mirroring `colorspaceLabel`. Updated by `sourceFormatChanged`.
    @Published private(set) var modeLabel = OutputMode.default2160p2398.label

    /// The full Signal line for the output menu: active display mode · fixed format · colorspace · EOTF.
    var signalLine: String { "\(modeLabel) · \(Self.formatDetail) · \(colorspaceLabel) · \(eotfLabel)" }

    /// SDI scaling (§6.11, *SDI scaling*; D8): where the picture sits in the output, from the renderer, each time it
    /// changes; nil while output is off. Its readout row is `placementLine`.
    @Published private(set) var placement: SDIPlacement?

    /// D8: "SDI 1920×1080p23.98 · source 1280×720 1:1, windowboxed" — whenever the output is NOT the source 1:1 at its
    /// own raster; nil when it is (native) or output is off. Never silent about a placed or scaled picture.
    var placementLine: String? {
        guard let p = placement, !p.isNative else { return nil }
        return "SDI \(p.outputWidth)×\(p.outputHeight)\(Self.rateSuffix(modeLabel)) · \(p.summary)"
    }

    /// "1080p23.98" → "p23.98", "2K DCI p23.98" → "p23.98 (2K DCI)": the rate half of a mode label, for the
    /// placement line, which states the raster itself.
    static func rateSuffix(_ label: String) -> String {
        guard let i = label.lastIndex(of: "p") else { return "" }
        let rate = String(label[i...])
        return label.hasPrefix("2K DCI") ? rate + " (2K DCI)" : label.hasPrefix("4K DCI") ? rate + " (4K DCI)" : rate
    }

    /// The Signal line, or the mismatch warning when there is one. The warning REPLACES the healthy
    /// reading rather than sitting beside it: "2160p23.98 · 10-bit 4:2:2 · Rec. 709" is not a true
    /// statement about a black output, and showing both would let the reassuring half be the one
    /// that gets read.
    var signalLineOrWarning: String { rasterMismatch ?? signalLine }

    // MARK: - Driver readiness (the honest tri-state, plus the two "we don't know" cases)

    /// The minimum Desktop Video version output requires, as text ("16.0"). Comes from the bridge, which
    /// owns the constant — the number is never typed out in Swift.
    static var requiredDriverVersion: String { DeckLinkBridge.requiredDriverVersion() }

    /// Every distinguishable state of the DeckLink stack, kept apart instead of collapsed. The three
    /// the tester's report asked for are `.notInstalled`, `.belowFloor` and `.noDevice`; the two extra
    /// cases exist because collapsing them would be the same dishonesty in a new place:
    ///   • `.versionUnreadable` — the framework loaded but BMDDeckLinkAPIVersion didn't answer. We do
    ///     not know the version, so we say that rather than guessing "old" or waving it through.
    ///   • `.ready` — driver current AND at least one output-capable device.
    /// All five are decided from data we hold at STARTUP (framework load + API version + enumeration).
    /// None of it waits for an output attempt.
    ///
    /// `.belowFloor` and `.noDevice` both carry `enumerated` — the RAW count from the bus walk,
    /// before the output filter. It is the fact that separates a version problem from a hardware
    /// problem, and neither case can be worded honestly without it.
    enum DriverStatus: Equatable {
        case notInstalled
        case versionUnreadable
        case belowFloor(installed: String, enumerated: Int)
        case noDevice(installed: String, enumerated: Int)
        case ready(installed: String, deviceCount: Int)

        /// Only `.ready` can drive a signal. Everything else fails, and now fails BEFORE the click.
        var canOutput: Bool { if case .ready = self { return true }; return false }

        /// Driver present but too old — the one state that gets an "Update…" affordance rather than
        /// "Download…", and the one the tester's 12.8.1 machine was actually in.
        var isBelowFloor: Bool { if case .belowFloor = self { return true }; return false }

        /// A DRIVER-side blocker: absent, unreadable, or below the floor. These are the states that
        /// cannot change under a running app — the framework load (and therefore the version it
        /// reports) is pthread_once-cached, so installing or updating Desktop Video needs a relaunch
        /// to take effect. That is what makes them safe to GREY THE BUTTON OUT on: a cached "no" can
        /// never go stale within the session.
        ///
        /// `.noDevice` is deliberately NOT in here. A card can be plugged in at any second, and the
        /// device cache behind it is only as fresh as the last refresh — disabling on it would leave
        /// the button dead after a mid-session plug. That case stays clickable and is caught by the
        /// fresh probe in `startScheduledOutput()`.
        var isDriverBlocked: Bool {
            switch self {
            case .notInstalled, .versionUnreadable, .belowFloor: return true
            case .noDevice, .ready:                              return false
            }
        }

        /// Short value text for the Settings row.
        ///
        /// ⚠️ "n found, 0 usable" IS THE WHOLE SENTENCE. A tester who reads it should reach "version
        /// problem" without being told, because the hardware count is non-zero right there next to
        /// the driver version — which is precisely what "No device detected" concealed.
        var headline: String {
            switch self {
            case .notInstalled:      return "Desktop Video not installed"
            case .versionUnreadable: return "Desktop Video installed (version unknown)"
            case .belowFloor(let v, let n):
                return n > 0 ? "\(Self.deviceCount(n)) found, 0 usable with Desktop Video \(v)"
                             : "Desktop Video \(v) — too old"
            case .noDevice(let v, let n):
                return n > 0 ? "\(Self.deviceCount(n)) found, 0 usable with Desktop Video \(v)"
                             : "No device detected (Desktop Video \(v))"
            case .ready(let v, let n):
                return "\(Self.deviceCount(n)) (Desktop Video \(v))"
            }
        }

        /// "1 device" / "3 devices". One speller, so no message in the app can disagree with another
        /// about the plural.
        static func deviceCount(_ n: Int) -> String { n == 1 ? "1 device" : "\(n) devices" }

        /// The explanatory caption — what the user can DO about this state.
        var detail: String? {
            switch self {
            case .notInstalled:
                return "Install Blackmagic Desktop Video \(DeckLinkService.requiredDriverVersion) or later, then relaunch Manifold."
            case .versionUnreadable:
                return "The Desktop Video driver loaded but did not report its version. Output requires "
                     + "\(DeckLinkService.requiredDriverVersion) or later; Manifold can't confirm the installed version, so output is disabled."
            case .belowFloor(let v, let n):
                let floor = DeckLinkService.requiredDriverVersion
                guard n > 0 else {
                    return "DeckLink output requires Desktop Video \(floor) or later; you have \(v). "
                         + "Update Desktop Video, then relaunch Manifold."
                }
                // THE SENTENCE THIS WHOLE CHANGE EXISTS FOR. It names the hardware count first so
                // the reader knows their device was SEEN, then the version, then the verdict — and
                // it says outright which kind of problem this is not, because the failure the old
                // wording produced was a tester checking cables for an afternoon.
                return "Desktop Video \(v) can see \(Self.deviceCount(n)), but this build of Manifold "
                     + "needs Desktop Video \(floor) or later to open an output on \(n == 1 ? "it" : "them"). "
                     + "This is a driver version problem, not a hardware or cabling problem. "
                     + "Update Desktop Video, then relaunch Manifold."
            case .noDevice(let v, let n):
                guard n > 0 else { return "Connect a DeckLink or UltraStudio device." }
                // Driver at or above the floor and STILL rejecting every device: not a case we can
                // explain, so this says what happened and asks for the file that records the reason
                // rather than inventing a cause. Reachable if Blackmagic revises IDeckLinkOutput
                // again — see the floor note in DeckLinkBridge.mm.
                return "Desktop Video \(v) returned \(Self.deviceCount(n)), but would not open an "
                     + "output on \(n == 1 ? "it" : "any of them"). This is unexpected on a driver "
                     + "that meets the \(DeckLinkService.requiredDriverVersion) floor — please send "
                     + "a diagnostics report, which records the reason for each device."
            case .ready:
                return nil
            }
        }

        /// One-line reason output is unavailable — used for the disabled button's tooltip. nil when
        /// output IS available.
        var blockedReason: String? {
            switch self {
            case .notInstalled:      return "DeckLink output — requires Blackmagic Desktop Video \(DeckLinkService.requiredDriverVersion) or later (not installed)"
            case .versionUnreadable: return "DeckLink output — Desktop Video version could not be read; \(DeckLinkService.requiredDriverVersion) or later is required"
            case .belowFloor(let v, let n):
                return n > 0
                    ? "DeckLink output — \(Self.deviceCount(n)) found, 0 usable with Desktop Video \(v); requires \(DeckLinkService.requiredDriverVersion) or later"
                    : "DeckLink output — requires Desktop Video \(DeckLinkService.requiredDriverVersion) or later (you have \(v))"
            case .noDevice(_, let n):
                return n > 0
                    ? "DeckLink output — \(Self.deviceCount(n)) found, 0 usable; see diagnostics for the reason"
                    : "DeckLink output — no DeckLink or UltraStudio device connected"
            case .ready:             return nil
            }
        }
    }

    /// The current readiness state, composed from the three facts refreshDevices() gathers. Order
    /// matters: driver absence outranks version, version outranks device presence — reporting "no
    /// device" to someone whose driver is too old (the exact bug this replaces) would be a fresh lie.
    var driverStatus: DriverStatus {
        Self.status(driverInstalled: driverInstalled, version: driverVersion,
                    meetsFloor: driverMeetsFloor,
                    enumerated: devicesEnumerated, usableCount: devices.count)
    }

    /// The composition rule itself, as a pure function so the startup log (which probes the bridge
    /// off-main, before anything is published) reaches the same verdict by the same path.
    ///
    /// `enumerated` is the RAW walk count and `usableCount` the filtered one. Both are carried
    /// through rather than one being derived from the other: they differ exactly when the
    /// interesting failure is happening, and that difference is the whole message.
    static func status(driverInstalled: Bool, version: String?, meetsFloor: Bool,
                       enumerated: Int, usableCount: Int) -> DriverStatus {
        guard driverInstalled else { return .notInstalled }
        guard let version else { return .versionUnreadable }
        guard meetsFloor else { return .belowFloor(installed: version, enumerated: enumerated) }
        guard usableCount > 0 else { return .noDevice(installed: version, enumerated: enumerated) }
        return .ready(installed: version, deviceCount: usableCount)
    }

    /// One frame's signal in the bridge's terms (colour S7). The bridge applies it to the frame it was filled into.
    static func bridgeSignal(_ s: OutputSignal) -> DeckLinkOutputSignal {
        var out = DeckLinkOutputSignal()
        out.rec2020 = ObjCBool(s.colorimetry == .rec2020)
        out.eotf = Int32(s.eotf.rawValue)
        if let m = s.staticMetadata {
            out.hasStaticMetadata = ObjCBool(true)
            let k = m.mastering
            (out.redX, out.redY) = (k.red.x, k.red.y)
            (out.greenX, out.greenY) = (k.green.x, k.green.y)
            (out.blueX, out.blueY) = (k.blue.x, k.blue.y)
            (out.whiteX, out.whiteY) = (k.white.x, k.white.y)
            out.maxMasteringLuminance = k.maxLuminance
            out.minMasteringLuminance = k.minLuminance
            out.maxCLL = Double(m.maxCLL)
            out.maxFALL = Double(m.maxFALL)
        }
        return out
    }

    /// One bridge instance holds the output state across start/stop calls. Serial queue so
    /// start/stop can't race and never block the UI thread.
    private let bridge = DeckLinkBridge()
    private let queue = DispatchQueue(label: "com.graviton.manifold.decklink")

    /// The renderer that produces the real video frames (set by the App at startup). Weak — the
    /// renderer owns its lifecycle; the fill block sources v210 frames from it.
    weak var renderer: MetalVideoRenderer? {
        didSet {
            // Take the renderer's raster-mismatch report and publish it. Installed HERE rather than
            // at the App's wiring site so it cannot be forgotten when a renderer is re-pointed:
            // the warning describes THIS renderer's output and must move with it.
            // Colour S7: the Signal line follows THIS renderer's colour announcements, whatever caused them — a file, an
            // override, a LUT, or a stream's mid-session change, which never reached the label before (BUGS.md).
            if let o = colorObserver { NotificationCenter.default.removeObserver(o); colorObserver = nil }
            if let r = renderer {
                colorObserver = NotificationCenter.default.addObserver(
                    forName: MetalVideoRenderer.sourceColorStateDidChange, object: r, queue: .main) { [weak self] _ in
                    self?.sourceColorChanged()
                }
            }
            renderer?.setDeckLinkScaling(scalingInForce)
            oldValue?.onDeckLinkPlacement = nil
            renderer?.onDeckLinkPlacement = { [weak self] placement in
                guard let self, self.placement != placement else { return }
                self.placement = placement
                if let line = self.placementLine { print("DeckLink D4a: \(line)") }
            }
            oldValue?.onDeckLinkRasterMismatch = nil
            renderer?.onDeckLinkRasterMismatch = { [weak self] message in
                guard let self else { return }
                guard self.rasterMismatch != message else { return }
                self.rasterMismatch = message
                if let message {
                    print("DeckLink D4a: ⚠️ \(message) — the card is enabled and locked, and the "
                        + "picture is BLACK. Pick a matching output mode, or change the source.")
                } else {
                    print("DeckLink D4a: raster mismatch cleared")
                }
            }
        }
    }

    /// The raster mismatch the renderer is currently refusing to copy for, as one operator-facing
    /// sentence — or nil when the picture is reaching the card.
    ///
    /// ⚠️ THIS EXISTS BECAUSE THE FAILURE LOOKED LIKE SUCCESS. The card enables at a valid mode, a
    /// downstream monitor locks cleanly, `signalLine` reads healthy, and the only symptom is that
    /// the frame is empty. Nothing on screen said otherwise; the single log line at the first
    /// mismatch scrolled away. See docs/BUGS.md.
    @Published private(set) var rasterMismatch: String?

    /// ── THE ADVISORY CHANNEL: "THE OUTPUT IS FINE, THE SOURCE IS NOT WHAT IT CLAIMS" ────────
    ///
    /// One operator-facing sentence about the SOURCE that the operator would otherwise have no way
    /// to learn, or nil. DISTINCT FROM `rasterMismatch`, which says the wire is carrying black —
    /// an advisory means the output is working and something upstream deserves a second look.
    ///
    /// The first entry is WHEP's declared-vs-measured frame rate disagreement. The shape is
    /// deliberately general because the class of problem is: docs/BUGS.md records the 5.1-Opus
    /// case, where a publisher was configured one way and sending another with every counter in
    /// the pipeline clean, and concluded that a misconfiguration nothing can fix must at least be
    /// STATED. This is where such statements go.
    ///
    /// ⚠️ ADVISORIES DESCRIBE, THEY DO NOT ACT. Nothing here changes output behaviour. If a future
    /// advisory tempts someone to also "correct" the thing it describes, that is a different
    /// decision and needs its own justification — see `crossCheckRate`'s note on why the WHEP case
    /// deliberately publishes the declared rate it is warning about.
    @Published private(set) var sourceAdvisory: String?

    /// Set or clear the advisory. MAIN THREAD — callers hop (the WHEP one arrives on the decode
    /// queue). Idempotent, so an edge-triggered producer can call it freely.
    func setSourceAdvisory(_ message: String?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard sourceAdvisory != message else { return }
        sourceAdvisory = message
    }

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
        let owns = ownsSystemAudio
        if Thread.isMainThread {
            systemAudioRouting?(owns)
        } else {
            DispatchQueue.main.async { self.systemAudioRouting?(owns) }
        }
    }

    /// THE RULE `applyAudioRouting` APPLIES, as a value: the card owns the program audio only when
    /// output is running AND the destination is SDI. Exposed (rather than left inline above)
    /// because an OWNERSHIP TRANSFER has to re-evaluate it for the INCOMING engine, and the answer
    /// must come from this one expression rather than from a second copy of the rule at the
    /// registry. See `DeckRegistry.attachDeviceHooks`.
    ///
    /// The transfer's other half is the outgoing engine, which is told `false` unconditionally: it
    /// is no longer wired to the card, so whatever the card is doing is none of its business, and
    /// leaving it holding `deckLinkOwnsAudio == true` would mute that window's desktop audio for
    /// the rest of the session.
    var ownsSystemAudio: Bool { isOutputting && audioDestination == .sdi }

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
    ///
    /// Colour S7: no colour here any more. It held the primaries code of the first start, and an audio re-establish
    /// replayed it, putting back the tag of whatever was on screen when output was switched on (BUGS.md). Each start
    /// now reads the renderer's current signal (`deckLinkStartSignal`), and each picture brings its own.
    private var activeStart: (deviceIndex: Int, mode: OutputMode)?
    private var colorObserver: NSObjectProtocol?

    /// D4a: the output DISPLAY MODE derived from the loaded file (video cadence). Resolution follows
    /// the file's family (2160p or 1080p, native 1:1 — no scaling); rate follows the file's frame rate
    /// snapped to a standard broadcast rate. `standardRate` + `width`/`height` drive the bridge's mode
    /// selection and scheduling; `label` is the plain-speak status string.
    struct OutputMode: Equatable {
        let width: Int          // output raster width (1280, 1920, 2048, 3840 or 4096 — SDI scaling)
        let height: Int         // output raster height (720, 1080 or 2160)
        let standardRate: Double // snapped standard rate (`SDIStandardRate.all`: 23.976 … 120)
        let label: String       // "2160p23.98", "1080p25", …

        /// Default when no file is loaded / rate can't be matched — matches the pre-D4a fixed output.
        static let default2160p2398 = OutputMode(width: 3840, height: 2160, standardRate: 24000.0 / 1001.0, label: "2160p23.98")

        /// Stable identity for the picker and for persistence. The label already uniquely names the
        /// (family, rate) pair — it is built from exactly those two — so it is the id, and nothing
        /// second has to be kept in step with it.
        var id: String { label }

        /// The selector's mode (`SDIOutputModeSelector`, ColorimetryModel) as the service carries it.
        init(_ m: SDIOutputMode) {
            self.init(width: m.width, height: m.height, standardRate: m.rate.fps, label: m.label)
        }
        init(width: Int, height: Int, standardRate: Double, label: String) {
            self.width = width; self.height = height; self.standardRate = standardRate; self.label = label
        }
    }

    /// Every mode the operator may pick by hand under a mode set (SDI scaling follow-up F3): 2160p, 1080p and 720p at
    /// every rate the card offers each, then 2K DCI and 4K DCI only when DCI is included. Built from the SAME table
    /// the selector chooses from (`SDIOutputMode.table`), so a mode can never appear in the picker that Follow source
    /// cannot produce, or vice versa. The ids (labels) of the 2160p and 1080p rows are the ones stored before.
    static func selectableModes(for set: SDIOutputModeSet) -> [OutputMode] {
        [SDIModeFamily.p2160, .p1080, .p720, .dci2K, .dci4K].filter { $0.isAvailable(in: set) }.flatMap { family in
            SDIOutputMode.table.filter { $0.family == family }.map(OutputMode.init)
        }
    }

    /// The manual picker's rows under the mode set in force. Re-published when the set changes.
    @Published private(set) var pickerModes = DeckLinkService.selectableModes(for: DeckLinkService.currentModeSet)

    /// The standard broadcast frame rates are `SDIStandardRate.all` (ColorimetryModel): EXACT fps (the fractional NTSC
    /// rates at their true n/1001 value) paired with the status token, matched nearest by |Δfps| with no seam, and
    /// matched the same way on the bridge side (`BMDModeForRasterRate`), so the label and the mode always agree.

    /// The output mode the card is (or would be) started at. Read on the serial queue when
    /// (re)starting; written ONLY by `applyEffectiveMode` and `restoreManualMode`, both main-thread,
    /// and `applyEffectiveMode` is the one place the auto/manual decision is made.
    ///
    /// PUBLISHED, AND READ BY THE MODE PICKER, because it is the answer to "what is the output
    /// actually set to" — which the picker has to be able to state when there is no manual pick and
    /// nothing to follow. `modeLabel` is NOT that answer and must not be used for it: it is
    /// overwritten with the bridge's `activeModeName`, which is the card's own spelling of the mode
    /// it settled on and need not be one of `selectableModes`' ids.
    @Published private(set) var currentMode = OutputMode.default2160p2398

    // MARK: - Mode selection: follow the source, or the operator's pick

    /// @AppStorage-style key for the operator's manual mode pick. Stores the mode's LABEL (which is
    /// its id), or is absent for "Follow source". A label that no longer resolves — the rate table
    /// changed under a stored preference — is treated as absent rather than as an error.
    static let manualModeKey = "manifold.decklink.manualOutputMode"

    /// ── WHY THERE IS A MANUAL PICKER AT ALL ────────────────────────────────────────────────
    ///
    /// Follow-source needs a RATE, and when this was written three of the four live transports could
    /// not state one. All four can now — SRT from `av_guess_frame_rate`, WHEP from SPS VUI timing,
    /// HLS from the master playlist's FRAME-RATE, NDI from the sender's `frame_rate_N/D` — but NONE
    /// of them can state one ALWAYS: a demuxer probe can come up empty, VUI is optional, a playlist
    /// may omit FRAME-RATE (HLS then measures, and only after a 120-frame window has closed), and an
    /// NDI sender may leave the rational zero-filled. Every transport therefore still has a
    /// rate-unknown state, and the picker is the answer in it. Follow-source is the answer whenever
    /// a rate IS known, and for files always.
    ///
    /// nil = follow the source. Non-nil = the operator has chosen, and the choice WINS over any
    /// source-derived mode until they clear it.
    @Published private(set) var manualMode: OutputMode?

    /// What the current source says the mode should be, or nil when it cannot say. Files always can
    /// (metadata carries both raster and rate); live transports can only when they published a rate.
    @Published private(set) var sourceDerivedMode: OutputMode?

    /// Why follow-source is unavailable right now, in one line for the menu — or nil when it IS
    /// available. The menu greys the "Follow source" row and shows this beneath it.
    @Published private(set) var followSourceUnavailableReason: String?

    /// True when a source-derived mode exists to follow.
    var followSourceAvailable: Bool { sourceDerivedMode != nil }

    /// ── LIVE SOURCES: ONE MODE PER SESSION (SDI scaling follow-up F4, Robbie 2026-10-23) ────────
    ///
    /// An HLS ladder moves under us — MEASURED: 416x234 → 960x540 → 1920x1080 inside one
    /// connection. Re-establishing the card on each rung would stop and restart scheduled playback
    /// three times in a few seconds, which drops the video output, re-prerolls the audio, and is
    /// visibly worse on the wire than any placement of the picture inside the mode already running.
    ///
    /// So a live source's mode is chosen ONCE per session (`SDILiveModeHold`): from the first format
    /// that states a rate — for HLS sized from the master playlist's largest rendition when it states
    /// one, else from the frame — and held until the source goes away. A later rendition, raster or
    /// rate is placed or scaled within the held mode by the renderer, and logged as absorbed. Only an
    /// operator action (the Settings mode set or scaling, a manual pick) re-resolves. This replaces the
    /// 2 s settle window, which let a ladder crossing a mode boundary re-establish the card mid-session.
    ///
    /// ⚠️ DELIBERATELY NOT `preferredMaximumResolution` / `preferredPeakBitRate`. Pinning the
    /// rendition would stop the raster moving, but it does so by REFUSING the quality the network is
    /// offering — on a QC tool, where the entire job is to show what the source actually looks like,
    /// capping the ladder silently degrades the thing being judged. It also cannot help the other
    /// three transports, which have no ladder and the same rate problem. The hold is local to the
    /// mode decision, changes nothing about the stream, and works for all four.
    ///
    /// Main-thread only (every writer is a main-thread delivery from `LiveDisplaySize`).
    private var liveHold = SDILiveModeHold()

    /// Map a source's (width, height, pixel aspect, frameRate) → the output display mode: SDI scaling's selector
    /// (`SDIOutputModeSelector`, §6.11). The rate is the nearest standard one (D1, as before); the raster is the mode
    /// the picture is native at (D2), else the smallest that holds it unscaled, else the largest, fitted (D3). Which
    /// modes it may pick is the Settings choice (`SDIOutputModeSet`: HD/UHD only, or include DCI). The renderer places
    /// the picture in whatever mode is in force (`SDIPlacement`), so a raster that is not the mode's is no longer black.
    static func resolveOutputMode(width: Int, height: Int, pixelAspect: Double? = nil, frameRate: Double,
                                  set: SDIOutputModeSet = currentModeSet,
                                  scaling: SDIScaling = currentScaling) -> OutputMode {
        OutputMode(SDIOutputModeSelector.select(width: width, height: height, pixelAspect: pixelAspect,
                                                frameRate: frameRate, set: set, scaling: scaling))
    }

    /// Settings ▸ DeckLink Output ▸ SDI output modes (default HD/UHD only).
    static var currentModeSet: SDIOutputModeSet {
        SDIOutputModeSet.stored(UserDefaults.standard.string(forKey: SDIOutputModeSet.defaultsKey))
    }

    /// Settings ▸ DeckLink Output ▸ SDI scaling (default Fit to mode; F1).
    static var currentScaling: SDIScaling {
        SDIScaling.stored(UserDefaults.standard.string(forKey: SDIScaling.defaultsKey))
    }

    /// F2: a source rate the card has no mode at (12, 15, 72 fps) goes out at the nearest, which changes its cadence on
    /// SDI. Said once per resolve, never silent. nil when the rate is a mode's.
    static func rateWarning(_ fps: Double, mode: OutputMode) -> String? {
        let r = SDIStandardRate.nearest(to: fps)
        guard !r.matches(fps) else { return nil }
        return String(format: "⚠️ source rate %.3f fps has no output mode — nearest is %@ (%@): SDI repeats or "
                              + "drops frames to that cadence", fps, r.token, mode.label)
    }

    /// The last source format Follow source resolved, kept so a change of the Settings re-resolves it.
    private enum LastFormat { case file(Int, Int, Double?, Double), live(LiveVideoFormat) }
    private var lastFormat: LastFormat?
    private var modeSetInForce = DeckLinkService.currentModeSet
    private var scalingInForce = DeckLinkService.currentScaling
    private var modeSetObserver: NSObjectProtocol?

    /// A Settings choice changed (mode set or scaling): re-resolve the current source under it. Main thread.
    /// A live session re-resolves from the format its mode was chosen from (F4), not from the latest rung.
    private func sdiSettingsMayHaveChanged() {
        let set = Self.currentModeSet, scaling = Self.currentScaling
        guard set != modeSetInForce || scaling != scalingInForce else { return }
        var clearManual = false
        if set != modeSetInForce {
            modeSetInForce = set
            pickerModes = Self.selectableModes(for: set)
            print("DeckLink D4a: SDI output modes → \(set.label)")
            // F3: a manual DCI pick has no row once DCI is off, and the setting says DCI is not in use: back to Follow.
            if let m = manualMode, !pickerModes.contains(m) {
                print("DeckLink D4a: manual pick \(m.label) is not offered under \(set.label) — back to Follow source")
                clearManual = true
            }
        }
        if scaling != scalingInForce {
            scalingInForce = scaling
            renderer?.setDeckLinkScaling(scaling)
            print("DeckLink D4a: SDI scaling → \(scaling.label)")
        }
        switch lastFormat {
        case .file(let w, let h, let par, let fps)?:
            resolveFileMode(width: w, height: h, pixelAspect: par, frameRate: fps)
        case .live?:
            if let m = liveHold.reresolve(set: set, scaling: scaling) {
                sourceDerivedMode = OutputMode(m)
                print("DeckLink D4a: live session re-resolved from its basis under \(set.label), \(scaling.label) → "
                    + "mode \(m.label)")
            }
        case nil:
            break
        }
        if clearManual { setManualMode(nil) } else { applyEffectiveMode(trigger: "SDI settings changed") }
    }

    /// Enumerate output-capable DeckLink devices. Synchronous SDK walk; returns [] if the driver
    /// isn't reachable or no card is present.
    func outputDevices() -> [Device] { Enumeration.probe().usable }

    /// Refresh the cached device list for the picker (call at startup / when the menu opens). Clamps
    /// the selection if the list shrank. Publishes on main.
    func refreshDevices() {
        let walk = Enumeration.probe()
        let ds = walk.usable
        // Same enumeration also settles the pthread_once framework load, so the driver-present read is
        // valid here — publish it alongside `devices` so state (a) vs (b) is distinguishable in the UI.
        let installed = DeckLinkBridge.isDriverInstalled()
        // The version comes from the same loaded framework — no card, no output attempt, so it is
        // available here and belongs here. Gathering it with the enumeration keeps the three facts
        // (framework loaded / version / devices) a single consistent snapshot.
        let version = DeckLinkBridge.installedDriverVersion()
        let meetsFloor = DeckLinkBridge.installedDriverMeetsOutputFloor()
        DispatchQueue.main.async {
            self.devices = ds
            self.devicesEnumerated = walk.total
            self.rejectedDevices = walk.rejected
            self.driverInstalled = installed
            self.driverVersion = version
            self.driverMeetsFloor = meetsFloor
            if self.selectedDeviceIndex >= ds.count { self.selectedDeviceIndex = 0 }
        }
    }

    /// A fresh, SYNCHRONOUS readiness probe — the same three bridge reads `refreshDevices()` publishes,
    /// taken now rather than trusted from published state. Used by the start paths, which must not act
    /// on a snapshot that predates a driver update or a card being unplugged. All three calls are cheap
    /// (the framework load is pthread_once-cached; the version is a struct read; only the enumeration
    /// walks the bus), and the pre-existing auto-start path already did the enumeration on this thread.
    func probeDriverStatus() -> DriverStatus { probeDriverStatusAndEnumeration().status }

    /// The same probe, also handing back the walk it made — status plus usable plus rejected, from ONE
    /// bus walk, so the counts in a message built from it cannot disagree. What the diagnostics export
    /// and the startup log call, because both have to state the rejected devices individually.
    ///
    /// ⚠️ THIS REPLACED A `…AndDevices` VARIANT THAT HANDED BACK THE FILTERED LIST ALONE. Keeping both
    /// would have left the lossy one in reach of the next caller who only thinks they want the list —
    /// which is how the reporting sites came to be unable to describe their own failure.
    func probeDriverStatusAndEnumeration() -> (status: DriverStatus, enumeration: Enumeration) {
        let walk = Enumeration.probe()
        let status = Self.status(driverInstalled: DeckLinkBridge.isDriverInstalled(),
                                 version: DeckLinkBridge.installedDriverVersion(),
                                 meetsFloor: DeckLinkBridge.installedDriverMeetsOutputFloor(),
                                 enumerated: walk.total, usableCount: walk.usable.count)
        return (status, walk)
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
        // Not just "is a card present" — the full readiness verdict, so a below-floor driver is named
        // as such at launch instead of being reported as absent hardware.
        let status = probeDriverStatus()
        guard status.canOutput else {
            print("DeckLink: enable-on-launch is on but output is unavailable — "
                + (status.blockedReason ?? status.headline) + "; skipping")
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
        // Refuse BEFORE flipping any state, and say why. The toolbar button is already disabled in
        // every non-ready state, but ⌃⌥O and the auto-start path reach here directly — and the probe
        // is fresh, so a driver updated or a card unplugged mid-session is caught here too. Publishing
        // the refreshed facts keeps the Settings row and diagnostics in step with what just happened.
        let status = probeDriverStatus()
        guard status.canOutput else {
            print("DeckLink: output not started — " + (status.blockedReason ?? status.headline))
            refreshDevices()
            return
        }
        isOutputting = true
        applyAudioRouting()   // D4b-3: ENABLE transition — with .sdi (the default), the Mac goes silent
        let deviceIndex = selectedDeviceIndex
        let mode = currentMode   // D4a: display mode derived from the current source (or default)
        queue.async {
            self.startOutputOnQueue(deviceIndex: deviceIndex, mode: mode)
        }
    }

    /// Establish scheduled output at `mode` on the serial queue. Shared by the initial start and the
    /// D4a mode-switch (which stops the old output on the same queue first, guaranteeing teardown
    /// completes before this re-establishes). Arms the renderer's convert at the mode's resolution
    /// (native 1:1) and drives the bridge's mode/scheduling from the mode's family + standard rate.
    private func startOutputOnQueue(deviceIndex: Int, mode: OutputMode) {
        self.activeStart = (deviceIndex, mode)   // so an audio restart can replay it

        // Arm the renderer's push convert (allocate v210 staging sized to the OUTPUT frame = the mode's
        // resolution; the source offscreen is the same size for a native file → 1:1, no scaling).
        self.renderer?.beginDeckLinkOutput(width: mode.width, height: mode.height)

        // A PAUSED picture reaches the card only if something renders it after the convert is armed: prime it here,
        // before the preroll, so frame #0 carries it (docs/BUGS.md, L4). Every start comes through here — a click,
        // ⌃⌥O, Enable output on launch, a mode change, an audio re-establish.
        // ⚠️ NOT WHILE PLAYING. Frames arrive within a frame period anyway, and a frame already staged at the card's
        // first audio callback is the case that snaps the SDI audio cursor (docs/BUGS.md, "the SDI audio cursor
        // snaps"): priming playing starts would make every one of them that case.
        if let r = self.renderer, r.isPausedProvider?() == true {
            if let ms = r.primeDeckLinkFrame(timeout: Self.primeTimeout) {
                print(String(format: "DeckLink: primed — paused frame converted in %.1f ms, before the preroll", ms))
            } else {
                print("DeckLink: primed — no frame within \(Int(Self.primeTimeout * 1000)) ms (nothing on screen yet); "
                    + "neutral until one renders")
            }
        }

        // The fill block runs on the SDK callback thread → cheap: a memcpy from the renderer's front
        // staging buffer, or a neutral fallback if no converted frame is ready yet.
        // Colour S7 (D1): each picture hands back its own signal, which the bridge tags its frame with; a neutral fill
        // keeps the signal in force (D5).
        let probe = FirstFrameProbe()
        #if DEBUG
        let trace = SignalTrace.enabled ? SignalTrace() : nil
        let dump = FrameDump.directory.map { FrameDump(directory: $0, mode: mode.label) }
        #endif
        let fill: DeckLinkFillBlock = { [weak self] index, buffer, rowBytes, width, height, signal in
            if let r = self?.renderer,
               let s = r.copyLatestDeckLinkFrame(into: UnsafeMutableRawPointer(buffer),
                                                 rowBytes: Int(rowBytes), width: Int(width), height: Int(height)) {
                signal.pointee = Self.bridgeSignal(s)
                probe.note(index: index, picture: true, buffer: buffer, rowBytes: Int(rowBytes), height: Int(height))
                #if DEBUG
                trace?.note(index: index, picture: true, buffer: buffer, rowBytes: Int(rowBytes), height: Int(height), signal: s)
                trace?.noteCadence(index: index, sourcePts: r.currentDeckLinkSourcePts())
                dump?.note(index: index, buffer: buffer, rowBytes: Int(rowBytes), width: Int(width), height: Int(height),
                           placement: FrameDump.onPlacement ? r.deckLinkPlacementForDebug : nil)
                #endif
                return true
            }
            Self.fillNeutralV210(buffer, rowBytes: Int(rowBytes), width: Int(width), height: Int(height))
            probe.note(index: index, picture: false, buffer: buffer, rowBytes: Int(rowBytes), height: Int(height))
            #if DEBUG
            trace?.note(index: index, picture: false, buffer: buffer, rowBytes: Int(rowBytes), height: Int(height), signal: nil)
            #endif
            return false
        }

        // D4b-2: resolve the audio stream for THIS start. Remembered so a later format change can tell
        // whether it needs to re-establish the output (the card's rate/channels are fixed at enable).
        let audioFormat = self.audioTap?.format
        self.enabledAudioFormat = Self.isSupportedForSDI(audioFormat) ? audioFormat : nil
        let audio = self.makeAudioConfig(for: self.enabledAudioFormat)

        // What frames carry until the first picture: the renderer's current signal, read now (D5). An audio
        // re-establish or a mode change reads it again here, never a value saved at an earlier start.
        let startSignal = self.renderer?.deckLinkStartSignal() ?? .sdr709
        print("DeckLink: output start — signal until the first picture: \(startSignal.logLine)")
        let result = self.bridge.startScheduledPlayback(withDeviceIndex: deviceIndex, fill: fill,
                                                        initialSignal: Self.bridgeSignal(startSignal),
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
            self.startOutputOnQueue(deviceIndex: start.deviceIndex, mode: start.mode)
        }
    }

    /// The picture's colour changed. Updates the Signal line's labels (independent of output state: the signal the
    /// output produces, or would produce) from the renderer's output signal. Call after setSourceColorSpace; the
    /// renderer's own colour announcement also arrives here (`renderer`'s observer), so a stream's change reaches it.
    ///
    /// Colour S7 (D1): DISPLAY ONLY. It no longer re-tags the output: each frame carries the signal it was rendered
    /// under, so the tag changes on the first frame with the new pixels, and on no other.
    func sourceColorChanged() {
        let primariesCode = renderer?.picturePrimariesCode
        let signal = renderer?.pictureOutputSignal ?? .sdr709
        let label = signal.colorimetryLabel
        // Colour S5: the SDI tag in the log, once per change, so an unattended run reads what the output
        // tags (or would tag) beside the picture, scopes and readout it must agree with.
        DispatchQueue.main.async {
            if self.colorspaceLabel != label {
                NSLog("[DeckLink] colorspace → %@ (primaries %@)%@", label,
                      primariesCode.map(String.init) ?? "absent", self.isOutputting ? "" : " — output off: the tag it would send")
            }
            self.colorspaceLabel = label
            self.eotfLabel = signal.eotf.name
            self.hdrMetadataLine = signal.staticMetadataLabel
        }
    }

    /// D4a: the source video FORMAT changed (new file / re-inspect). Recompute the output display mode
    /// from the file's resolution + frame rate. Always updates the status label (the mode output
    /// produces / would produce, whether or not it's running). If output IS running and the mode
    /// actually changed, cleanly SWITCH: stop the old scheduled playback then re-establish at the new
    /// mode — both hops on the serial queue so teardown finishes before re-establish (no race). If
    /// output is off, just remember the target so the next start uses it. Call after setSourceColorSpace.
    func sourceFormatChanged(width: Int, height: Int, pixelAspect: Double? = nil, frameRate: Double) {
        // A FILE's format change is immediate. A file's raster and rate are facts read once at load,
        // they do not step the way an ABR ladder does, and there is no session to hold: the live
        // path's one-mode-per-session rule (F4) is for the live path only.
        liveHold.end()
        resolveFileMode(width: width, height: height, pixelAspect: pixelAspect, frameRate: frameRate)
        applyEffectiveMode(trigger: "file source format")
    }

    /// A file's mode under the Settings in force, into `sourceDerivedMode`; the caller applies it.
    private func resolveFileMode(width: Int, height: Int, pixelAspect: Double?, frameRate: Double) {
        lastFormat = .file(width, height, pixelAspect, frameRate)
        let mode = Self.resolveOutputMode(width: width, height: height, pixelAspect: pixelAspect, frameRate: frameRate,
                                          set: modeSetInForce, scaling: scalingInForce)
        sourceDerivedMode = mode
        followSourceUnavailableReason = nil
        print("DeckLink D4a: FILE source format \(width)x\(height) @ "
            + String(format: "%.3f fps", frameRate) + " → mode \(mode.label) (\(modeSetInForce.label), \(scalingInForce.label)"
            + (pixelAspect.map { String(format: ", pixel aspect %.4f", $0) } ?? ", pixel aspect not declared — square") + ")")
        if let warning = Self.rateWarning(frameRate, mode: mode) { print("DeckLink D4a: \(warning)") }
    }

    // MARK: - The live path into the same decision

    /// A live transport stated its video format, or lost it. Routed here by `DeckRegistry` from the
    /// one `LiveDisplaySize` latch, on main.
    ///
    /// ⚠️ THIS IS THE CALL THAT DID NOT EXIST, AND ITS ABSENCE WAS THE BUG. `sourceFormatChanged`'s
    /// only caller was `ContentView`'s `.onChange(of: engine.metadata)`, and `metadata` is written
    /// by the three FILE load paths and by nothing else — so a stream never reconfigured the card.
    /// It kept the last file's mode, or `default2160p2398` on a session where no file had ever been
    /// opened; the raster then mismatched, `MetalVideoRenderer` refused the copy and held neutral,
    /// no frame ever staged, and the SDI audio ring read failed its anchor with "no staged video PTS
    /// to anchor to". One missing call, black picture AND silence. See docs/BUGS.md.
    ///
    /// ⚠️ A nil RATE IS NOT A REASON TO RECONFIGURE ANYTHING. Every transport has a rate-unknown
    /// state, however good its usual signal. Guessing would set a broadcast output to a cadence no
    /// source has — worse than the stale mode, because it looks deliberate. So: raster without rate
    /// updates NOTHING except the reason string the menu shows, and the operator's manual pick is
    /// how a source in that state gets a correct mode.
    func liveFormatChanged(_ format: LiveVideoFormat?) {
        dispatchPrecondition(condition: .onQueue(.main))

        guard let format else {
            // The live source is gone. Drop the derived mode but leave `currentMode` exactly where
            // it is: tearing the card back to a default on disconnect would be a second, pointless
            // re-establish at the worst possible moment, and the next source will set it anyway.
            // The session ends here (F4): the next source chooses its own mode.
            if let held = liveHold.held { print("DeckLink D4a: live session over — mode \(held.label) released") }
            liveHold.end()
            sourceDerivedMode = nil
            followSourceUnavailableReason = "No source is connected."
            // An advisory describes a SOURCE. With the source gone it cannot still be true, and a
            // stale one would be the same class of misleading indicator this channel exists to
            // remove. Cleared centrally here as well as by the transport, so a transport that
            // forgets cannot leave one on screen.
            sourceAdvisory = nil
            print("DeckLink D4a: live source gone — holding output mode \(currentMode.label)")
            return
        }

        guard let frameRate = format.frameRate else {
            // A session whose mode is already chosen keeps it: a rate that goes unknown mid-session (an estimator
            // window reset) is a change like any other, absorbed (F4).
            if let held = liveHold.held {
                print("DeckLink D4a: LIVE source format \(format.describedForLog) — absorbed: mode held at "
                    + "\(held.label) for this session")
                return
            }
            sourceDerivedMode = nil
            followSourceUnavailableReason =
                "This source does not report a frame rate, so the output mode cannot follow it. "
                + "Pick a mode below."
            print("DeckLink D4a: live source \(format.describedForLog) — NO RATE, not reconfiguring; "
                + "output stays at \(currentMode.label)"
                + (manualMode == nil ? " (pick a mode by hand to match the source)" : " (manual pick)"))
            return
        }

        lastFormat = .live(format)
        let observed = SDILiveModeHold.Format(width: Int(format.size.width), height: Int(format.size.height),
                                              frameRate: frameRate,
                                              sizingWidth: format.largestRendition.map { Int($0.width) },
                                              sizingHeight: format.largestRendition.map { Int($0.height) })
        switch liveHold.observe(observed, set: modeSetInForce, scaling: scalingInForce) {
        case .apply(let m):
            // The session's mode: chosen once, from the largest rendition when the source states one (HLS), else from
            // this frame, and applied at once — the whole point is to get a picture up.
            let mode = OutputMode(m)
            sourceDerivedMode = mode
            followSourceUnavailableReason = nil
            let from = format.largestRendition.map { "the largest rendition \(Int($0.width))x\(Int($0.height))" }
                ?? "this frame"
            print("DeckLink D4a: LIVE source format \(format.describedForLog) → mode \(mode.label), chosen from "
                + "\(from) (\(modeSetInForce.label), \(scalingInForce.label)) and held for this session")
            if let warning = Self.rateWarning(frameRate, mode: mode) { print("DeckLink D4a: \(warning)") }
            applyEffectiveMode(trigger: "live source format (session mode)")
        case .absorbed(let held, let resolved):
            // Never a mode change: the renderer places or scales this raster within the held mode.
            print("DeckLink D4a: LIVE source format \(format.describedForLog) — absorbed: mode held at "
                + "\(held.label) for this session"
                + (resolved != held ? " (a fresh choice would be \(resolved.label))" : "")
                + "; the picture is placed or scaled within it")
        }
    }

    // MARK: - The operator's pick

    /// Choose a mode by hand, or pass nil to go back to following the source. Persisted.
    func setManualMode(_ mode: OutputMode?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard mode != manualMode else { return }
        manualMode = mode
        if let mode {
            UserDefaults.standard.set(mode.id, forKey: Self.manualModeKey)
            print("DeckLink D4a: operator picked output mode \(mode.label) "
                + "(manual pick now WINS over the source"
                + (sourceDerivedMode.map { ", which says \($0.label)" } ?? ", which states none") + ")")
        } else {
            UserDefaults.standard.removeObject(forKey: Self.manualModeKey)
            print("DeckLink D4a: operator cleared the manual pick — following the source again "
                + (sourceDerivedMode.map { "(\($0.label))" } ?? "(which states no mode yet)"))
        }
        applyEffectiveMode(trigger: mode == nil ? "manual pick cleared" : "manual pick")
    }

    /// Restore the stored pick at startup. A stored label that no longer resolves to a selectable
    /// mode is dropped silently — the rate table is allowed to change between versions, and a
    /// preference is not worth an error dialog.
    func restoreManualMode() {
        guard let stored = UserDefaults.standard.string(forKey: Self.manualModeKey) else { return }
        guard let mode = pickerModes.first(where: { $0.id == stored }) else {
            UserDefaults.standard.removeObject(forKey: Self.manualModeKey)
            print("DeckLink D4a: stored output mode \"\(stored)\" is no longer offered under \(modeSetInForce.label) — "
                + "falling back to Follow source")
            return
        }
        manualMode = mode
        currentMode = mode
        modeLabel = mode.label
        print("DeckLink D4a: restored manual output mode \(mode.label) from preferences")
    }

    // MARK: - One place the mode is decided, and one place output is re-established for it

    /// THE decision: the operator's pick if there is one, else what the source says, else the
    /// pre-D4a default. Called by every input that can change the answer.
    ///
    /// ⚠️ EVERY SDI RE-ESTABLISH FOR A MODE CHANGE GOES THROUGH HERE, and says what triggered it.
    /// Before this there was one path (a file's metadata) and it logged one line; there are now four
    /// inputs (file format, live format, the Settings, the manual picker) and a log that did not
    /// name which one fired would be useless for exactly the question this change has to answer.
    private func applyEffectiveMode(trigger: String) {
        let mode = manualMode ?? sourceDerivedMode ?? .default2160p2398
        let source = manualMode != nil ? "manual pick"
                   : sourceDerivedMode != nil ? "follow source" : "default (nothing to follow)"
        let changed = (mode != currentMode)
        currentMode = mode
        modeLabel = mode.label

        guard isOutputting else {
            print("DeckLink D4a: mode → \(mode.label) via \(source) [\(trigger)]; "
                + "output is OFF, so the next start will use it")
            return
        }
        guard changed else {
            print("DeckLink D4a: mode stays \(mode.label) via \(source) [\(trigger)] — "
                + "no re-establish needed")
            return
        }

        let deviceIndex = selectedDeviceIndex
        print("DeckLink D4a: RE-ESTABLISHING SDI output at \(mode.label) via \(source) [\(trigger)]")
        queue.async {
            // Race-safe stop (clear running → StopScheduledPlayback → unset callback → DisableVideoOutput
            // → release pool), then re-establish at the new mode. isOutputting stays true across the
            // switch (it's a re-mode, not a user stop).
            self.bridge.stopScheduledPlayback()
            self.renderer?.stopDeckLinkOutput()
            self.startOutputOnQueue(deviceIndex: deviceIndex, mode: mode)
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

    /// D1 probe: log the DeckLink stack's real state once at startup. Runs off the main thread so a
    /// slow driver query never delays launch.
    ///
    /// This used to print "found 0 output device(s) (no card / driver not reachable)" for every
    /// non-working case, including a driver that was installed, reachable, and cheerfully reporting a
    /// version we simply hadn't asked for yet. Each distinguishable state now gets its own line, and
    /// the version is named wherever we have it.
    func logDevicesAtStartup() {
        DispatchQueue.global(qos: .utility).async {
            let (status, walk) = self.probeDriverStatusAndEnumeration()
            switch status {
            case .notInstalled:
                print("DeckLink: Desktop Video driver not installed — output unavailable "
                    + "(requires \(Self.requiredDriverVersion) or later)")
            case .versionUnreadable:
                print("DeckLink: Desktop Video driver is installed but did not report a version; "
                    + "output requires \(Self.requiredDriverVersion) or later — output disabled")
            case .belowFloor(let v, let n):
                // The case the tester hit. The driver was never unreachable; it was too old, it said
                // so the whole time, and the card was in the slot the whole time too — which is the
                // half this line used to leave out.
                print("DeckLink: Desktop Video \(v) installed — below the \(Self.requiredDriverVersion) "
                    + "floor DeckLink output requires; output disabled "
                    + "(\(n) enumerated, \(walk.usable.count) usable"
                    + (n > 0 ? " — driver version, not hardware)" : ")"))
            case .noDevice(let v, let n):
                print("DeckLink: Desktop Video \(v) installed (meets the \(Self.requiredDriverVersion) floor) — "
                    + (n > 0 ? "\(n) enumerated, 0 usable — every device refused IDeckLinkOutput"
                             : "no output-capable device connected"))
            case .ready(let v, _):
                let list = walk.usable.map { "\($0.modelName) (\($0.displayName))" }.joined(separator: ", ")
                print("DeckLink: Desktop Video \(v) — \(walk.total) enumerated, "
                    + "\(walk.usable.count) usable: \(list)")
            }
            // ALWAYS, AND ONE LINE EACH. A rejection can coexist with a healthy device (a mixed bag of
            // cards, or a future driver revision that only some hardware follows), so these are
            // printed after EVERY verdict above — including `.ready`, where the count line alone
            // would otherwise hide a card that quietly did not make it.
            for r in walk.rejected { print("DeckLink:   rejected \(r.summary)") }
        }
    }
}

/// Once per start: says whether the card's first scheduled frame carried the picture or neutral, with an FNV-1a 64
/// of that frame's v210 rows (comparable with an export's `.v210` of the same frame), and if it was neutral, which
/// later frame first carried the picture. The fill block runs on the DeckLink queue for the preroll and on the SDK
/// callback thread after; the lock covers both. Only the first frame is hashed: it is filled during the preroll,
/// before playback starts, so the hash costs no frame time.
final class FirstFrameProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Int64?
    private var pictureSeen = false

    func note(index: Int64, picture: Bool, buffer: UnsafeMutablePointer<UInt8>, rowBytes: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        if pictureSeen { return }
        if first == nil {
            first = index
            if picture {
                pictureSeen = true
                print(String(format: "DeckLink: first scheduled frame #%lld — picture (v210 FNV-1a %016llx)",
                             index, Self.fnv1a(buffer, count: rowBytes * height)))
            } else {
                print("DeckLink: first scheduled frame #\(index) — neutral (no converted frame yet)")
            }
        } else if picture {
            pictureSeen = true
            print("DeckLink: first picture at scheduled frame #\(index)")
        }
    }

    static func fnv1a(_ p: UnsafeMutablePointer<UInt8>, count: Int) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for i in 0..<count { h = (h ^ UInt64(p[i])) &* 0x0000_0100_0000_01b3 }
        return h
    }
}

#if DEBUG
/// Colour S7, P5 (DEBUG; pre-ship removal, docs/BUGS.md): `MANIFOLD_DECKLINK_SIGNAL_TRACE=1` logs the scheduled-frame
/// index at which a frame's pixels change (an FNV-1a over every 64th word of the v210) and at which its signal
/// changes, so a run can show the two move on the same frame. The bridge's `[DeckLink] signal on scheduled frame #N`
/// line is the tag actually applied.
final class SignalTrace: @unchecked Sendable {
    static let enabled = ProcessInfo.processInfo.environment["MANIFOLD_DECKLINK_SIGNAL_TRACE"] == "1"
    private let lock = NSLock()
    private var lastHash: UInt64?
    private var lastSignal: OutputSignal?
    /// SDI scaling follow-up F2: distinct source frames per 120 scheduled frames, so a high-rate run says whether the
    /// card got a new picture each frame or repeats (the render loop runs at the display's refresh).
    private var cadenceStart: Int64?
    private var cadenceLastPts = Double.nan
    private var cadenceDistinct = 0

    func noteCadence(index: Int64, sourcePts: Double) {
        lock.lock(); defer { lock.unlock() }
        if cadenceStart == nil { cadenceStart = index }
        if sourcePts.isFinite, sourcePts != cadenceLastPts { cadenceDistinct += 1; cadenceLastPts = sourcePts }
        guard let start = cadenceStart, index - start + 1 >= 120 else { return }
        print("[SIGNAL-TRACE] cadence: scheduled frames #\(start)–#\(index): \(cadenceDistinct) distinct source frames of 120")
        cadenceStart = nil; cadenceDistinct = 0
    }

    func note(index: Int64, picture: Bool, buffer: UnsafeMutablePointer<UInt8>, rowBytes: Int, height: Int,
              signal: OutputSignal?) {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        buffer.withMemoryRebound(to: UInt32.self, capacity: rowBytes * height / 4) { w in
            var i = 0
            while i < rowBytes * height / 4 { h = (h ^ UInt64(w[i])) &* 0x0000_0100_0000_01b3; i += 64 }
        }
        lock.lock(); defer { lock.unlock() }
        if h != lastHash {
            print(String(format: "[SIGNAL-TRACE] pixels changed at scheduled frame #%lld (%@, sampled FNV %016llx)",
                         index, picture ? "picture" : "neutral", h))
            lastHash = h
        }
        if let signal, signal != lastSignal {
            print("[SIGNAL-TRACE] signal changed at scheduled frame #\(index): \(signal.logLine)")
            lastSignal = signal
        }
    }
}

/// SDI scaling (§6.11; DEBUG; pre-ship removal, docs/BUGS.md): `MANIFOLD_DECKLINK_DUMP_DIR=<dir>` writes the first
/// picture frame of each output start, exactly as the fill block handed it to the card, as `sdi-<n>.v210` (rowBytes ×
/// height bytes) and `sdi-<n>.json` (mode, width, height, rowBytes, scheduled index, FNV-1a). Written once per start:
/// on a paused start that is the preroll, before playback, so it costs no frame time.
final class FrameDump: @unchecked Sendable {
    static let directory = ProcessInfo.processInfo.environment["MANIFOLD_DECKLINK_DUMP_DIR"]
    private static let counterLock = NSLock()
    private static var counter = 0
    private let directory: String
    private let mode: String
    private let lock = NSLock()
    private var done = false
    /// `MANIFOLD_DECKLINK_DUMP_ON_PLACEMENT=1` (added 2026-10-23, the in-app HLS ladder check): also dump one frame
    /// after each change of the renderer's placement, so every rendition of a live session is read back as the card
    /// got it. Taken `placementSettle` scheduled frames after the change is first seen, so the front buffer carries it.
    static let onPlacement = ProcessInfo.processInfo.environment["MANIFOLD_DECKLINK_DUMP_ON_PLACEMENT"] == "1"
    private static let placementSettle: Int64 = 6
    private var lastPlacement: String?
    private var pendingAt: Int64?

    init(directory: String, mode: String) { self.directory = directory; self.mode = mode }

    /// `placement`: the renderer's current placement, described, or nil when it has none (DUMP_ON_PLACEMENT only).
    func note(index: Int64, buffer: UnsafeMutablePointer<UInt8>, rowBytes: Int, width: Int, height: Int,
              placement: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if done {
            guard Self.onPlacement, let placement else { return }
            if placement != lastPlacement { lastPlacement = placement; pendingAt = index + Self.placementSettle }
            guard let at = pendingAt, index >= at else { return }
            pendingAt = nil
        } else {
            lastPlacement = placement
        }
        done = true
        Self.counterLock.lock(); Self.counter += 1; let n = Self.counter; Self.counterLock.unlock()
        let data = Data(bytes: buffer, count: rowBytes * height)
        let fnv = FirstFrameProbe.fnv1a(buffer, count: rowBytes * height)
        let base = (directory as NSString).appendingPathComponent(String(format: "sdi-%03d", n))
        let json = "{\"mode\":\"\(mode)\",\"width\":\(width),\"height\":\(height),\"rowBytes\":\(rowBytes),"
            + "\"index\":\(index),\"fnv1a\":\"\(String(format: "%016llx", fnv))\""
            + (placement.map { ",\"placement\":\"\($0)\"" } ?? "") + "}"
        do {
            try data.write(to: URL(fileURLWithPath: base + ".v210"))
            try json.write(toFile: base + ".json", atomically: true, encoding: .utf8)
            print("[SDI-DUMP] \(base).v210 — \(mode) \(width)x\(height) frame #\(index) FNV-1a \(String(format: "%016llx", fnv))"
                + (placement.map { " · placement \($0)" } ?? ""))
        } catch {
            print("[SDI-DUMP] write failed: \(error)")
        }
    }
}
#endif
