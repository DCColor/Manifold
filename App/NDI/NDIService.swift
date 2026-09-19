import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox
import QuartzCore
import ManifoldCore

/// STEP A: minimal NDI receive — prove NDI integrates and that frames reach Manifold's Metal
/// display path. Discovery, a receiver on the first source found, a FrameSync pull on the display
/// tick, and the frames handed to the SAME MetalVideoRenderer.enqueue the file sources feed.
///
/// Deliberately NOT here (all later steps): source picking/switching, file<->NDI coexistence,
/// clock/drift correctness, audio, P216/10-bit, capability flags.
///
/// COLORIMETRY (read-and-tag). NDI signals primaries / transfer / matrix per frame, in the
/// `<ndi_color_info/>` element of the frame's metadata XML — three INDEPENDENT axes, all optional.
/// The receive path parses them (NDIColorInfo), maps them to the same CICP codes the file path
/// produces, and stamps them on the pixel buffer as standard CV attachments. The buffer is then
/// indistinguishable from a file's downstream: the shader's matrix, the layer colorspace, the GPU
/// scopes and the EDR gate all read the tags, and none of them knows or cares that NDI is upstream.
/// A source that declares nothing is tagged with the 709 SDR default and RECORDED as assumed —
/// tagged so it displays correctly, recorded so nothing presents the default as the sender's word.
///
/// THE FORMAT PROBLEM, and why there is a conversion in a "zero-copy" path
/// ----------------------------------------------------------------------
/// The brief assumed the renderer is source-agnostic downstream of enqueue. It is not, in two
/// ways that both bite an 8-bit packed UYVY buffer:
///
///   1. renderPixelBuffer samples TWO PLANES (luma + chroma). NDI's UYVY is single-plane packed
///      4:2:2, so a '2vuy' buffer fails makeTexture(planeIndex: 1) and renders NOTHING — a black
///      window, not a crash, which is the worst way for this to fail.
///   2. The shader's range-expansion constants are hard-wired to the 10-BIT MSB-ALIGNED sample
///      domain (kCodeMax = 1023.984375). PassthroughShader.metal says so explicitly, and says the
///      8-bit branch is unreachable and that reviving it means making those constants per-depth.
///      Feeding it 8-bit samples would expand them against the wrong code ceiling.
///
/// So the frame has to arrive in a format the existing shader already speaks. Rather than write a
/// packed-422 shader path (a bigger change to the hot display path, and it re-opens the 8-bit
/// constants problem the shader warns about), VideoToolbox converts UYVY into 'x422' —
/// 10-bit biplanar 4:2:2. That lands in EXACTLY the domain the shader's constants assume, with no
/// chroma decimation (4:2:2 in, 4:2:2 out; 'x420' would have thrown away half the chroma lines),
/// and needs no shader edit. The 8→10-bit promotion is an exact ×4 code shift, not a resample.
///
/// The zero-copy wrap still earns its keep: it is the SOURCE of that transfer, so NDI's bytes are
/// read straight out of the SDK's buffer with no intermediate memcpy, and the frame is handed back
/// to FrameSync the instant the transfer is done (see NDIVideoFrame's lifetime note).
final class NDIService: ObservableObject {

    static let shared = NDIService()
    private init() {}

    /// The single source of truth for the NDI runtime download. Referenced by BOTH the "Install NDI
    /// Runtime…" menu item (ManifoldApp) and the Settings button (SettingsView) — no duplicated
    /// string literal.
    ///
    /// ── ⚠️ THE `Apple` SUFFIX IS THE WHOLE POINT. IT SHIPPED WITHOUT IT ONCE. ────────────────
    ///
    /// This was `https://ndi.link/NDIRedistV6`, and that link is Vizrt's WINDOWS redistributable.
    /// Followed on a clean machine it 301s straight to
    /// `https://downloads.ndi.tv/SDK/NDI_SDK/NDI 6 Runtime.exe` and returns 9,648,232 bytes of
    /// `application/x-msdownload` — a Windows executable, silently, with no landing page to make the
    /// mistake visible. Manifold is macOS arm64 only, so that download can never be useful to anyone
    /// who clicks it.
    ///
    /// It is NOT a landing page and never was, for either platform: no email form, no interstitial,
    /// one redirect to a binary. So the failure was invisible until someone opened the file.
    ///
    /// ── WHAT THIS ONE ACTUALLY RETURNS, MEASURED RATHER THAN INFERRED ────────────────────────
    ///
    ///     https://ndi.link/NDIRedistV6Apple
    ///       → 200, application/octet-stream, 4,638,592 bytes
    ///       → https://downloads.ndi.tv/SDK/NDI_SDK_Mac/libNDI_for_Mac.pkg
    ///
    ///     file(1):    xar archive  (a real macOS installer package)
    ///     signature:  Developer ID Installer: NewTek, Inc. (W8U66ET244), notarized and trusted by
    ///                 the Apple notary service, timestamped 2026-04-13
    ///     installs:   libndi.dylib + libndi_licenses.txt, install-location /usr/local/lib
    ///
    /// THAT LAST LINE IS THE ONE THAT CLOSES THE LOOP: `/usr/local/lib/libndi.dylib` is exactly the
    /// path `NDIBridge.mm` dlopens at run time (see the entitlements file for why that dlopen needs
    /// disable-library-validation). The thing this link installs is the thing the app looks for.
    ///
    /// ── WHY THE ndi.link VANITY REDIRECT AND NOT THE downloads.ndi.tv PATH IT RESOLVES TO ────
    ///
    /// The vanity link is the one Vizrt publishes and maintains, so it follows the file if they move
    /// or re-version it; the direct path is an implementation detail that would rot silently. Note
    /// that `NDIRedistV5Apple` and `NDIRedistV6Apple` currently resolve to the SAME
    /// `libNDI_for_Mac.pkg`, which is evidence Vizrt keeps one stable Mac redistributable behind
    /// these — the failure mode to watch for is not a 404 but a link that quietly starts serving a
    /// different platform, which is what happened here. RE-FOLLOW IT, do not re-read it, if this is
    /// ever revisited.
    static let runtimeInstallURL = URL(string: "https://ndi.link/NDIRedistV6Apple")!

    /// Whether the NDI runtime dylib is present and loadable. Published for the picker empty state
    /// and the Settings status row. Detection is LAZY and RELAUNCH-ONLY by design: the underlying
    /// `+[NDIBridge loadRuntime]` is `dispatch_once`, so a machine that gains the runtime mid-session
    /// won't flip this until relaunch. Set from `refreshRuntimeStatus()` and the `startDiscovery()`
    /// load. Main-thread only (SwiftUI observes it).
    @Published private(set) var runtimeAvailable: Bool = false

    /// Whether the runtime is INSTALLED — three states, and the third is why this exists
    /// alongside `runtimeAvailable`.
    ///
    /// ⚠️ **`runtimeAvailable` CANNOT ANSWER THIS AT LAUNCH AND MUST NOT BE ASKED TO.** It is a
    /// `Bool` that defaults to `false` and is only set once something calls `refreshRuntimeStatus()`
    /// — Settings opening, or the streaming UI appearing. So before then, "no runtime" and "nobody
    /// has looked" are the same value, and a menu item keyed on it would offer to install NDI on
    /// every machine at launch, including machines that have it.
    ///
    /// This is a filesystem presence check (`NDIBridge.runtimeFilePresent`) run once at launch. It
    /// does NOT `dlopen` and does NOT call `NDIlib_initialize()`, so it does not violate the
    /// lazy-load rule `runtimeAvailable` documents — that rule exists to keep NDI's machinery from
    /// starting for users who never touch NDI, and nothing here starts it.
    ///
    /// ⚠️ **`runtimeAvailable` REMAINS THE AUTHORITATIVE ANSWER** to "can we use NDI". This one is
    /// only good enough to decide whether to OFFER a download. A dylib can be present and unloadable
    /// (too old to resolve a loader symbol), and only `loadRuntime()` knows.
    enum RuntimePresence: Equatable { case unknown, installed, notInstalled }

    @Published private(set) var runtimePresence: RuntimePresence = .unknown

    /// The loaded runtime's version string, or nil when unavailable. Main-thread only.
    @Published private(set) var runtimeVersion: String? = nil

    /// True while an NDI source is connected and feeding the display.
    ///
    /// STOPGAP: the UI needs to know "is something on screen" and, until the source-switching work
    /// lands, there is no unified is-any-source-active concept — the empty state just ORs this with
    /// the engine's file state. Main-thread only (start/disconnect both run there), so it is safe
    /// for SwiftUI to observe.
    @Published private(set) var isConnected = false

    /// The live source's NDI name while connected (nil when local). Drives the toolbar button's
    /// tooltip and the checkmark on the active row in the picker. Main-thread only.
    @Published private(set) var connectedSourceName: String?

    /// NDI sources currently visible on the network, for the toolbar picker. Refreshed on a light
    /// timer while the streaming control is on screen (startDiscovery/stopDiscovery). Empty is an
    /// honest answer — the picker shows "No NDI sources found" rather than a silent empty menu.
    /// Main-thread only (the refresh task hops to main to publish).
    @Published private(set) var discoveredSources: [NDISource] = []

    /// The live source's EFFECTIVE colorimetry — what the buffers are actually tagged with, after
    /// resolving the user's override against what the sender declared (or didn't). Republished on
    /// the main thread whenever it CHANGES: for a normal stream, once at the first frame, and again
    /// each time the override moves.
    ///
    /// The pipeline does not read this: the buffer's CICP attachments carry the colorimetry
    /// downstream, exactly as they do for a file. This is the DATA MODEL for the readouts — the
    /// toolbar picker and scope headers today, the inspector's rows in a later step. Its `tier`
    /// says which of Declared / Assumed / Overridden produced it, so nothing can present a default
    /// or an assertion as a reading.
    @Published private(set) var colorInfo: NDIColorInfo = .assumedRec709

    /// What the SENDER said (or the assumed default when it said nothing), independent of the
    /// override. Kept alongside the effective value so the UI can show what is being overridden —
    /// "Declared 709 → Overridden 2020 PQ" is a different fact from "Assumed 709 → Overridden".
    @Published private(set) var declaredColorInfo: NDIColorInfo = .assumedRec709

    /// The user's colorimetry assertion. Transient per connection — reset to `.auto` on every
    /// connect, exactly as `RangeOverride` resets per file, and for the same reason: the override
    /// that rescues this stream would silently corrupt the next one.
    @Published private(set) var colorimetryOverride: NDIColorimetryOverride = .auto

    /// The display path. Set once at startup (ContentView.onAppear), same instance DeckLink uses.
    weak var renderer: MetalVideoRenderer?

    /// Called on the main thread just before a stream becomes the active source, to retire whatever
    /// else was driving the display (a loaded file). Set once by ContentView — NDIService has no
    /// direct engine handle. This is the reverse of the file-open path disconnecting the stream:
    /// together they enforce one active source, so a file's frame pump and NDI's push never both
    /// feed the renderer (the double-source flashing). No-op-safe when nothing else is active.
    var onWillActivateStream: (() -> Void)?

    /// The engine's PTS-keyed PCM ring. Set once at startup (ContentView.onAppear) — the SAME
    /// instance the file paths tee into and the DeckLink SDI audio callback pulls from. NDI is just a
    /// third producer: it converts its float-planar audio to Int32 interleaved and pushes here, and
    /// everything downstream of the tap (clock-anchored SDI scheduling, SDI/Computer routing, mute)
    /// applies to NDI audio for free. Weak, like `renderer`: the engine owns it.
    weak var audioTap: AudioTapBuffer?

    // MARK: - Desktop audio seams (wired by WindowDeck, same shape as WHEP's and SRT's)

    /// Open the shared audio renderer for this stream. The argument is `beginLiveAudio`'s `cushion`
    /// — "how far behind the timebase's own axis does this transport stamp its audio PTS" — and NDI
    /// passes **0**, the value WHEP now passes: the pump stamps `monotonicNow()` at pull, which IS
    /// the axis the timebase is anchored on. SRT's 0.250 is right for SRT because SRT stamps on
    /// `LiveClock.now()`, which sits a buffer depth behind the sender timeline. NDI has no such
    /// offset to declare. The desktop presentation lead is a DIFFERENT quantity and is applied at
    /// the anchor, not here — see `desktopAudioLead`.
    var beginLiveAudio: ((Double) -> FrameEngine.LiveAudioSink?)?
    /// Retire the renderer session. Called on disconnect only, NOT on a source switch.
    var endLiveAudio: (() -> Void)?
    /// `FrameEngine.anchorLiveAudio(mediaTime:hostTime:)` — the direct timebase anchor NDI uses in
    /// place of the LiveClock mirror. See the note on that method for why the mirror cannot serve
    /// a transport that never slews.
    var anchorLiveAudio: ((Double, Double) -> Void)?
    /// `CMTimeGetSeconds(FrameEngine.currentSyncTime())` — the ACTUAL audio timebase, read from the
    /// pump thread. This is the closed half of the loop and the reason it is a loop at all: it is
    /// the only quantity in the system that is on the AUDIO DEVICE's clock rather than on mach time.
    var liveAudioTimebase: (() -> Double)?
    /// `FrameEngine.liveAudioRendererState()` — readiness, status, error and the MEASURED
    /// synchronizer rate. Nothing on the live path has ever read any of it; see the reporting note
    /// on `reportRendererState`.
    var liveAudioRendererState: (() -> FrameEngine.LiveAudioRendererState)?

    private var bridge: NDIBridge?
    private var transferSession: VTPixelTransferSession?
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int) = (0, 0)

    // MARK: - Audio pump (dedicated thread — decoupled from the video display tick)
    //
    // Audio is drained on its OWN thread, NOT on the CVDisplayLink tick, and this decoupling is the
    // whole point: when it shared the video tick, a slow tick let FrameSync's audio queue grow, so the
    // next pull handed back a bigger chunk, whose conversion slowed the tick further — a compounding
    // loop that collapsed fps to ~1. On a dedicated thread the audio cadence is independent of the
    // render rate: it drains at real-time 48 kHz no matter how fast or slow video is drawing.
    private var audioThread: Thread?
    private let audioRunLock = NSLock()          // guards `audioShouldRun` (main writes, pump reads)
    private var audioShouldRun = false
    private var audioThreadFinished: DispatchSemaphore?   // pump signals on exit; stop() joins on it

    private var isConnecting = false
    /// Discovery loop state (main thread). REFERENCE-COUNTED: more than one view can want discovery
    /// running (the toolbar streaming control and the empty-state "Connect Stream…"), and during the
    /// connect transition both are briefly on screen at once. Counting means the finder keeps running
    /// across that overlap instead of a departing view stopping it under an arriving one. All touched
    /// on main, alongside the finder they drive (NDIBridge's persistent discovery finder).
    private var discoveryClients = 0
    private var discoveryTask: Task<Void, Never>?
    private var frameCount = 0
    private var lastRateLogTime: CFTimeInterval = 0
    private var lastRateLogCount = 0

    // Colorimetry state — CVDisplayLink thread only (pullFrame). `activeColorInfo` is the EFFECTIVE
    // (post-override) info the buffers are being tagged with and the layer is configured for;
    // `parsedColorInfo` is what the stream itself said, kept separately so toggling the override
    // back to Auto restores the declaration without needing another parse. `lastMetadataXML` is the
    // raw string it was parsed from, so an unchanged metadata string — the overwhelmingly common
    // case, byte-identical on every frame of a stable stream — costs one string compare and skips
    // the parse.
    private var activeColorInfo: NDIColorInfo = .assumedRec709
    private var parsedColorInfo: NDIColorInfo = .assumedRec709
    private var lastMetadataXML: String?
    private var hasParsedColorInfo = false
    /// One "here is what this source says it is" line per connection, then only on change.
    private var reportedColorInfo = false
    /// Armed at connect and on every colorimetry change; disarmed after one frame. The readback it
    /// gates is cheap but this is a per-frame path, and the answer cannot change between frames.
    private var verifyNextOutputTags = true

    /// The override mirror — written on main (the picker), read on the CVDisplayLink thread (the
    /// tagging path), guarded by a lock it never holds for more than a read. This is the rangeLock
    /// pattern verbatim: the UI does not reach into the capture thread and the capture thread does
    /// not touch main-actor state; they meet at one small guarded value, and the next pulled frame
    /// picks the new value up and re-tags. No decode, no session, no pool is disturbed — an override
    /// changes nothing but three attachments, exactly as a range override changes nothing but a
    /// shader flag.
    private let colorLock = NSLock()
    private var overrideMirror: NDIColorimetryOverride = .auto

    private func currentOverride() -> NDIColorimetryOverride {
        colorLock.lock(); defer { colorLock.unlock() }
        return overrideMirror
    }

    /// Apply a manual colorimetry override. Main thread (the picker). Nothing is re-created and no
    /// frame is re-pulled: the mirror flips, and the next frame off the wire resolves against it,
    /// re-tags its buffer and — if the transfer or primaries moved — re-points the layer colorspace
    /// through the SAME mid-stream-change path a declared change already uses. An override is just
    /// another colour-info change; the receive path cannot tell the difference, and shouldn't.
    func setColorimetryOverride(_ override: NDIColorimetryOverride) {
        guard override != colorimetryOverride else { return }
        colorimetryOverride = override
        colorLock.lock(); overrideMirror = override; colorLock.unlock()
        NSLog("[NDI] colorimetry override → %@", override.label)
    }

    /// The renderer's normal clock is the file transport's. NDI is not on that clock, so while NDI
    /// is driving we substitute a free-running monotonic one and stamp frames with it at pull time
    /// — the frame is enqueued microseconds before displayTick reads the clock, so the renderer's
    /// `pts <= now` selection always accepts it. That is all the PTS has to do this step: FrameSync
    /// is doing the actual sync, and real timestamp handling is the deferred clock step.
    private static func monotonicNow() -> Double { CACurrentMediaTime() }

    // MARK: - Runtime status (lazy, relaunch-only)

    /// Read the bridge's one-time load result and publish it. Idempotent: `+[NDIBridge loadRuntime]`
    /// is `dispatch_once`, so repeated calls are cheap and always return the same cached answer for
    /// the process lifetime (install-then-relaunch is the detection model — never re-probed live).
    /// Call it lazily (Settings opening, streaming UI appearing), NOT at app launch. Publishes on the
    /// main thread; safe to call from any thread.
    func refreshRuntimeStatus() {
        let available = NDIBridge.loadRuntime()
        let version = available ? NDIBridge.runtimeVersion : nil
        if Thread.isMainThread {
            self.runtimeAvailable = available
            self.runtimeVersion = version
        } else {
            DispatchQueue.main.async {
                self.runtimeAvailable = available
                self.runtimeVersion = version
            }
        }
    }

    /// One filesystem probe at launch, off the main actor, so the app menu can decide whether to
    /// offer the runtime download.
    ///
    /// ⚠️ DELIBERATELY NOT `refreshRuntimeStatus()`, WHICH IS DIRECTLY ABOVE AND MUST STAY LAZY.
    /// That one calls `loadRuntime()`, which dlopens the runtime and calls `NDIlib_initialize()`.
    /// This one only stats a file. See `runtimePresence` for why the `Bool` cannot serve here.
    func probeRuntimePresenceAtLaunch() {
        Task.detached(priority: .utility) {
            let present = NDIBridge.runtimeFilePresent()
            await MainActor.run { self.runtimePresence = present ? .installed : .notInstalled }
        }
    }

    // MARK: - Discovery (main thread)

    /// Register a client that wants discovery running (toolbar streaming control or empty-state
    /// "Connect Stream…"), starting the finder on the first one. Pairs with `stopDiscovery()`. Keeps
    /// `discoveredSources` warm so a SwiftUI Menu — which captures its content at open time — is
    /// already populated when opened. No-op (empty list) when the runtime is absent.
    func startDiscovery() {
        discoveryClients += 1
        guard discoveryClients == 1 else { return }   // already running for an earlier client
        // Reuse THIS load result to publish runtime status — no second load call (see runtimeAvailable).
        let available = NDIBridge.loadRuntime()
        runtimeAvailable = available
        runtimeVersion = available ? NDIBridge.runtimeVersion : nil
        guard available else { discoveredSources = []; return }
        discoveredSources = NDIBridge.refreshDiscoveredSources()   // immediate first pass (often empty)
        discoveryTask = Task { @MainActor [weak self] in
            // The finder learns the network between polls; a light 1 s cadence tracks sources coming
            // and going without spinning. Ends when the last client leaves, the task is cancelled, or
            // the service goes away.
            while let self, self.discoveryClients > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.0))
                guard self.discoveryClients > 0, !Task.isCancelled else { break }
                self.discoveredSources = NDIBridge.refreshDiscoveredSources()
            }
        }
    }

    /// Deregister a discovery client; the finder is released only when the LAST one leaves (e.g.
    /// disconnecting with no file returns to the empty state, whose own client then keeps it alive).
    func stopDiscovery() {
        guard discoveryClients > 0 else { return }   // unbalanced call — ignore
        discoveryClients -= 1
        guard discoveryClients == 0 else { return }  // other clients still want it
        discoveryTask?.cancel()
        discoveryTask = nil
        NDIBridge.stopDiscovery()
        discoveredSources = []
    }

    // MARK: - Connect / disconnect (the toolbar control + ⌃⌥N/⌃⌥⇧N drive these)

    /// Keyboard quick-connect (⌃⌥N). Prefers a source the picker has already discovered — the SAME
    /// `connect(to:)` path the toolbar uses — so button and shortcut are one action. Falls back to a
    /// blocking discovery only when nothing has been discovered yet (shortcut used before the picker
    /// ran), so the shortcut still works cold.
    ///
    /// NDI TAKES OVER the display while active: it repoints the renderer's clock and range
    /// providers at itself. Clean file<->NDI handoff is explicitly out of scope for this step.
    /// ⚠️ REACHABLE ONLY THROUGH `LiveSource.connectNDIFirstSource` — the `Arbitration` argument
    /// cannot be constructed outside LiveSource.swift, so no other call site compiles. Any live
    /// WHEP or SRT source has been retired by the time this runs.
    func connectToFirstSource(arbitratedBy arbitration: LiveSource.Arbitration) {
        if let first = discoveredSources.first {
            connect(to: first, arbitratedBy: arbitration)
            return
        }
        guard !isConnecting else { return }
        guard bridge == nil else {
            NSLog("[NDI] already connected to \"\(bridge?.sourceName ?? "?")\" — ignoring")
            return
        }
        guard renderer != nil else {
            NSLog("[NDI] no renderer wired — cannot display")
            return
        }
        guard NDIBridge.loadRuntime() else {
            // Graceful absence: the runtime isn't there, the app keeps working, the trigger says so.
            NSLog("[NDI] runtime unavailable — trigger is a no-op (see the [NDI] log above for why)")
            return
        }

        isConnecting = true
        NSLog("[NDI] discovering sources (loader=\(NDIBridge.loaderSymbol ?? "?"), "
              + "runtime=\(NDIBridge.runtimeVersion ?? "?"))…")

        // Discovery blocks — keep it off the main thread.
        let discoveryTimeout = 5.0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let connected = NDIBridge.connectToFirstSource(withTimeout: discoveryTimeout)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isConnecting = false
                guard let connected else {
                    // Name the CONDITION, not one sender. This read "is OmniScope sending on this
                    // network?" — a development leftover that told every tester using a different NDI
                    // source that Manifold was looking for one specific product.
                    NSLog("[NDI] no source found on this network within \(Int(discoveryTimeout))s — "
                          + "check that an NDI sender is running and on the same subnet")
                    return
                }
                self.start(with: connected)
            }
        }
    }

    /// Connect to a SPECIFIC discovered source — the picker's action. Picking a different source
    /// while already connected SWITCHES (full-replacement model): the old receiver is torn down and
    /// the new one started in the same main-thread turn as the swap, so `isConnected` never dips to
    /// false in between and the control bar / empty state never flickers.
    /// ⚠️ REACHABLE ONLY THROUGH `LiveSource.connectNDI(to:)` — the `Arbitration` argument cannot be
    /// constructed outside LiveSource.swift, so no other call site compiles. Note the funnel passes
    /// `except: .ndi` precisely so the in-place switch described above still happens here.
    func connect(to source: NDISource, arbitratedBy _: LiveSource.Arbitration) {
        guard !isConnecting else { return }
        // Already on this exact source — nothing to do (avoids a needless tear-down/rebuild).
        if isConnected, connectedSourceName == source.name { return }
        guard renderer != nil else {
            NSLog("[NDI] no renderer wired — cannot display")
            return
        }
        guard NDIBridge.loadRuntime() else {
            NSLog("[NDI] runtime unavailable — cannot connect to \"\(source.name)\"")
            return
        }

        isConnecting = true
        NSLog("[NDI] connecting to \"\(source.name)\"…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let connected = NDIBridge.connect(to: source)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isConnecting = false
                guard let connected else {
                    NSLog("[NDI] failed to connect to \"\(source.name)\"")
                    return
                }
                // Switching sources: drop the old receiver WITHOUT flipping isConnected/empty state,
                // then start the new one — one atomic swap from the UI's point of view.
                if self.bridge != nil { self.tearDownReceiver() }
                self.start(with: connected)
            }
        }
    }

    private func start(with connected: NDIBridge) {
        guard let renderer else { return }
        // One active source: retire a loaded file BEFORE the stream takes the renderer, so the
        // file's frame pump and NDI's push don't both feed it (the double-source flashing). Runs
        // before any renderer repointing below. Harmless when no file is loaded, and on an NDI→NDI
        // switch (the old receiver is already gone; there is no file to retire).
        onWillActivateStream?()
        bridge = connected
        frameCount = 0
        lastRateLogTime = Self.monotonicNow()
        lastRateLogCount = 0

        // Start on the ASSUMED default (709 SDR) — a source that declares nothing keeps this, and a
        // source that declares something replaces it on its first frame (applyColorInfo). The layer
        // is never left carrying the PREVIOUS source's colorimetry, which is what a "set it once at
        // connect" hardcode would do on a second connect.
        resetColorimetry()
        renderer.setSourceColorSpace(primaries: 1, transfer: 1, matrix: 1)

        // Range is a SEPARATE axis from colorimetry and NDI does not signal it: UYVY is video-range
        // by definition. Pin the shader to legal-range expansion rather than letting it read the
        // file transport's override (which describes a file that may not even be loaded).
        renderer.isFullRangeProvider = { false }
        renderer.clock = { Self.monotonicNow() }
        renderer.isPausedProvider = { false }

        // Pull VIDEO on the display tick: FrameSync hands us the current frame on OUR clock.
        renderer.onDisplayTick = { [weak self] in self?.pullFrame() }

        // ── DESKTOP AUDIO: OPEN THE RENDERER BEFORE THE PUMP, NOT AFTER ─────────────────────
        //
        // `beginLiveAudio` FLUSHES the renderer and parks the synchronizer at rate 0, so it has to
        // happen before any buffer is enqueued or the first buffers would be flushed away behind
        // the pump. Re-entered on a SOURCE SWITCH too (`start(with:)` is the switch path as well),
        // which is correct: the flush drops the old sender's audio and the first pull of the new one
        // re-anchors. That is a brief silence across a switch, which is what a switch is.
        //
        // The pump-thread anchor state is reset HERE, on main, before the thread exists — the pump
        // owns it exclusively once it is running.
        anchoredDesktopAudio = false
        anchorCount = 0
        audioFormatCache = nil
        audioAnchorTicks = nil; audioCumulativeFrames = 0
        audioAxisRate = 0; audioAxisChannels = 0
        audioResyncCount = 0; lastAudioResyncHost = 0
        audioBuffersDumped = 0
        lastAudioPTS = nil; lastAudioFrames = 0; lastAudioRate = 0
        ptsSamples = 0; ptsResidualSum = 0; ptsResidualAbsSum = 0; ptsQuantisedAbsSum = 0
        ptsGaps = 0; ptsOverlaps = 0; ptsWorstResidual = 0; ptsWorstResidualSamples = 0
        liveAudioSink = beginLiveAudio?(0)
        if liveAudioSink == nil {
            NSLog("[NDI-AUDIO] no engine seam wired — audio will be metered and SDI-capable but "
                + "SILENT on the desktop (the pre-existing behaviour, not a new failure)")
        }

        // Pull AUDIO on its OWN thread, at real-time cadence, independent of the video tick.
        startAudioPump(connected)

        isConnected = true
        connectedSourceName = connected.sourceName
        NSLog("[NDI] receiving from \"\(connected.sourceName)\" — video on the display tick, audio on a dedicated pump")
    }

    /// What counts as a frame rate at all. The SAME range SRT screens `av_guess_frame_rate` with
    /// (`anchorPlausibleFrameRates`), deliberately: a rate that would be refused as implausible
    /// arriving one way must be refused arriving the other, or the card's behavior depends on which
    /// transport happened to be connected. Wide on purpose — it exists to catch a garbage rational,
    /// not to police unusual-but-real cadences; `resolveOutputMode` does the snapping.
    private static let plausibleFrameRates = 1.0...240.0

    /// The sender's declared rate for THIS frame, or nil when it declares none or declares nonsense.
    ///
    /// ⚠️ IT IS A RATIO AND IT IS DIVIDED HERE, ONCE, AND NOT ROUNDED. 24000/1001 is 23.976023…,
    /// 30000/1001 is 29.970029… — the two values that a "helpful" rounding to 23.98 / 29.97 would
    /// destroy. `resolveOutputMode` matches against the EXACT `n/1001` entries in its own table by
    /// minimum |Δfps|, so an unrounded quotient lands ~0 from the right entry and cannot be trapped
    /// on a boundary. Pre-rounding here would hand it a number that is merely near the table
    /// instead of on it, for no gain.
    ///
    /// nil, NOT A SUBSTITUTE, for every refusal: a zero denominator (the `memset` default — the
    /// sender said nothing), a zero or negative numerator, or a quotient outside
    /// `plausibleFrameRates`. Publishing a garbage rate would reconfigure a broadcast output to a
    /// cadence no source has, which is the one outcome worse than following nothing. Same refusal
    /// SRT makes on an implausible guess and WHEP makes on an absent VUI.
    private static func declaredFrameRate(numerator: Int32, denominator: Int32) -> Double? {
        guard numerator > 0, denominator > 0 else { return nil }
        let fps = Double(numerator) / Double(denominator)
        guard fps.isFinite, plausibleFrameRates.contains(fps) else { return nil }
        return fps
    }

    /// The rational last reported by `logDeclaredRate`, so a steady stream logs once. nil = nothing
    /// logged yet on this connection; cleared on disconnect beside the size latch.
    ///
    /// KEYED ON THE VALUE RATHER THAN A ONCE-FLAG, and that is not tidiness: a SOURCE SWITCH rebuilds
    /// the receiver through `tearDownReceiver` WITHOUT a disconnect (which is why `isConnected` never
    /// dips and why the raster is republished per frame), so a once-per-connection flag would never
    /// reset and the new sender's rate would go unreported. Comparing the pair logs exactly when the
    /// declared rate actually changes, which is the thing worth a line.
    private var loggedRational: (n: Int32, d: Int32)?

    /// ── DECLARED, WITH NOTHING TO CHECK IT AGAINST ─────────────────────────────────────────
    ///
    /// ⚠️ THIS IS A THIRD SHAPE AND IT IS DELIBERATE. HLS cross-checks its playlist FRAME-RATE
    /// against a 120-frame estimator, and WHEP cross-checks its SPS VUI timing the same way; both
    /// can say "the sender declares X and does Y". NDI cannot, and the reason is structural rather
    /// than unfinished work: frames arrive through FrameSync, which buffers, repeats and drops to
    /// keep our clock fed (see `captureVideoFrame`'s timestamp dedup — we do not even see every
    /// repeat). Inter-arrival gaps measured on this side describe the CVDisplayLink tick and
    /// FrameSync's smoothing, not the sender's cadence, so an estimator here would produce a
    /// confident number about the wrong thing and disagreements with it would be meaningless.
    ///
    /// The sender's 100ns `timestamp` IS a real clock and could in principle carry a cross-check —
    /// it is what the `[NDI-AUDIO]` trace uses to prove audio was not synthesised. Adding one is not
    /// part of this change, and on balance it does not look worth it: it would be checking an exact
    /// rational the sender states outright against a derivative of the same sender's clock, which is
    /// not an independent witness the way HLS's playlist-vs-media or WHEP's VUI-vs-arrival is.
    private func logDeclaredRate(_ rate: Double?, numerator: Int32, denominator: Int32) {
        guard loggedRational?.n != numerator || loggedRational?.d != denominator else { return }
        loggedRational = (numerator, denominator)
        if let rate {
            NSLog("%@", String(format: "[NDI-FORMAT] frame rate %.3f fps declared by the sender "
                                       + "(frame_rate_N/D = %d/%d) — DeckLink Follow source can use it",
                               rate, numerator, denominator))
        } else {
            NSLog("%@", "[NDI-FORMAT] frame rate NOT declared "
                + "(frame_rate_N/D = \(numerator)/\(denominator), which is "
                + (denominator <= 0 || numerator <= 0
                   ? "the zero-filled default — this sender states no rate"
                   : "outside \(Self.plausibleFrameRates) fps")
                + ") — publishing no rate; DeckLink Follow source will be unavailable for this "
                + "stream, pick a mode by hand.")
        }
    }

    /// Tear down the receiver, audio pump and display hook WITHOUT touching the published mode state
    /// (`isConnected` / `connectedSourceName`). Shared by disconnect() and the source-switch path:
    /// the switch rebuilds immediately afterwards, so it must NOT flip isConnected to false (which
    /// would drop the control bar to the empty state mid-switch).
    private func tearDownReceiver() {
        // Stop the audio pump and JOIN it BEFORE tearing down the receiver: the pump calls into the
        // framesync instance, so it must be fully exited before the bridge destroys it (below).
        stopAudioPump()
        renderer?.onDisplayTick = nil
        bridge?.disconnect()
        bridge = nil
        transferSession = nil
        pixelBufferPool = nil
        poolSize = (0, 0)
    }

    func disconnect() {
        isConnected = false
        connectedSourceName = nil
        tearDownReceiver()
        // Wipe the last streamed frame off the display: with the source gone and (usually) no file
        // behind it, the renderer would otherwise leave its final drawable frozen behind the empty
        // state. A file still playing repaints over the black on its next frame.
        renderer?.clearToBlack()
        // No picture, so no shape: the window must not stay locked to the departed source's aspect.
        // HERE AND NOT IN `tearDownReceiver`, deliberately — the source-SWITCH path goes through
        // that one, and clearing there would drop the window to the 16:9 fallback for the few
        // frames between receivers rather than holding the old shape until the new one states its
        // own. Same reasoning as `isConnected` not dipping across a switch.
        loggedRational = nil
        // HERE AND NOT IN `tearDownReceiver`, for the same reason the size latch is cleared here:
        // that one is the SOURCE-SWITCH path, and ending the renderer session mid-switch would
        // retire a session `start(with:)` is about to reopen two statements later.
        liveAudioSink = nil
        anchoredDesktopAudio = false
        audioFormatCache = nil
        endLiveAudio?()
        LiveDisplaySize.shared.clear()
        resetColorimetry()
        NSLog("[NDI] disconnected")
    }

    /// Back to a clean slate: no parse, no assertion. The override reset is the load-bearing part —
    /// a colorimetry assertion is about THIS stream, and carrying it into the next connection would
    /// silently mis-tag a source the user never looked at. Same rule, same reason, as RangeOverride
    /// resetting on every file load. Main thread (both callers are).
    private func resetColorimetry() {
        activeColorInfo = .assumedRec709
        parsedColorInfo = .assumedRec709
        lastMetadataXML = nil
        hasParsedColorInfo = false
        reportedColorInfo = false
        verifyNextOutputTags = true
        colorInfo = .assumedRec709
        declaredColorInfo = .assumedRec709
        colorimetryOverride = .auto
        colorLock.lock(); overrideMirror = .auto; colorLock.unlock()
    }

    // MARK: - Per-tick pull (CVDisplayLink thread)

    /// Called from MetalVideoRenderer's display tick, BEFORE it selects a frame — so a frame
    /// pulled here is available to the very same tick.
    private func pullFrame() {
        guard let bridge, let renderer else { return }
        // Audio is NOT pulled here any more — it runs on its own pump thread (startAudioPump). Keeping
        // it off this tick is the fix: audio work no longer steals from video rendering, and the
        // audio drain rate no longer follows the (possibly collapsing) video tick rate.

        // nil = no frame yet, or FrameSync is repeating one we already converted. Enqueuing
        // nothing is correct: the renderer keeps displaying the frame it has.
        guard let frame = bridge.captureVideoFrame() else { return }

        // THE FRAME'S SHAPE, RE-READ PER FRAME FOR THE SAME REASON THE COLORIMETRY IS. NDI has no
        // connect-time format description to read this from — `xres`/`yres` live on each frame —
        // and it genuinely changes under us: switching source rebuilds the receiver without a
        // disconnect (`tearDownReceiver`, which is why `isConnected` never dips), and a sender is
        // free to change resolution mid-stream. Latched inside `LiveDisplaySize`, so a steady
        // stream costs one comparison per tick and no main-thread hop.
        //
        // ⚠️ SQUARE PIXELS ASSUMED. NDI's `NDIlib_video_frame_v2_t` carries `picture_aspect_ratio`
        // (0 meaning "derive it from xres/yres"), which is the one honest PAR signal any of the
        // three transports has — and `NDIBridge` does not currently expose it. Until it does, this
        // is the decoded geometry and nothing more, which is exactly what the renderer draws.
        //
        // ⚠️ THE RATE RIDES THE SAME CALL, AND THAT IS THE WHOLE POINT OF ONE LATCH. `LiveVideoFormat`
        // carries raster and rate together because they are one fact about one stream (see
        // LiveDisplaySize's header on why a sibling latch would be worse than none). NDI is the
        // transport where that costs least: both quantities live on the SAME frame struct, so the
        // rate needs no second event, no settle window and no plumbing of its own — it is read
        // beside `xres`/`yres` and published beside them, per frame, for the same reason.
        //
        // PER FRAME AND NOT ONCE, for the rate as much as the raster: a source switch rebuilds the
        // receiver without a disconnect, so the next frame can legitimately be a different sender at
        // a different cadence. `LiveDisplaySize` dedups, so a steady stream costs one comparison.
        //
        // `declaredFrameRate` returns nil rather than a guess for a sender that states nothing — the
        // same refusal SRT and WHEP make, and the reason the four transports behave alike here.
        let declaredRate = Self.declaredFrameRate(numerator: frame.frameRateN,
                                                  denominator: frame.frameRateD)
        LiveDisplaySize.shared.publish(width: Int(frame.width), height: Int(frame.height),
                                       frameRate: declaredRate)
        logDeclaredRate(declaredRate, numerator: frame.frameRateN, denominator: frame.frameRateD)

        // What is this frame, actually? What the sender declared (re-read per frame — colorimetry
        // can change under us), resolved against whatever the user has asserted in the picker.
        let info = effectiveColorInfo(forFrameMetadata: frame.metadataXML)

        // Tag the SOURCE buffer with what the sender declared. This is the line that replaces the
        // unconditional Rec.709 the bridge used to stamp here — and that hardcode was the bug:
        // VideoToolbox propagates the source's attachments to its output, so a lie told here was
        // carried, intact and unquestioned, all the way to the display buffer and the scopes.
        info.apply(to: frame.pixelBuffer)

        guard let converted = convertToDisplayFormat(frame.pixelBuffer,
                                                     width: Int(frame.width),
                                                     height: Int(frame.height)) else { return }
        // `frame` (and with it NDI's buffer) is released at the end of this scope — the transfer
        // above has already read every byte out of it.

        // Tag the OUTPUT too, AFTER the transfer. Not redundant belt-and-braces: this is the buffer
        // every downstream consumer actually reads (shader matrix, layer colorspace, scopes, EDR
        // gate), a pooled buffer starts untagged, and VT's propagation is measured behavior rather
        // than a documented contract. Tagging last is the ordering that holds whether VT
        // propagates, stamps a default, or leaves the buffer bare — and tagOutput logs what the
        // output really carried, so the claim stays checked instead of assumed.
        tagOutput(converted, with: info)

        guard let sampleBuffer = makeSampleBuffer(converted, pts: Self.monotonicNow()) else { return }
        renderer.enqueue(sampleBuffer)
        logFrameRate()
    }

    // MARK: - Audio pump (dedicated thread)

    /// Spin up the audio pump thread. Started at connect, joined at disconnect. Runs whether or not
    /// the source actually carries audio — `captureAudioFrame` returns nil (cheaply) until audio
    /// arrives, so an audio-less source just polls an empty queue.
    // MARK: - Desktop audio: the closed-loop timebase anchor

    /// ── HOW FAR BEHIND REAL TIME THE DESKTOP TIMEBASE RUNS, i.e. THE RENDERER'S QUEUE ────────
    ///
    /// The pump stamps each buffer `monotonicNow()` at pull. If the timebase were anchored at
    /// exactly that axis, a buffer would be DUE THE INSTANT IT IS ENQUEUED: the renderer would hold
    /// no queue at all and every pump hiccup would be a gap. So the timebase is anchored `lead`
    /// BEHIND the stamp axis, which makes a buffer stamped `t` due at `t + lead` and leaves the
    /// renderer exactly `lead` of audio in hand.
    ///
    /// ⚠️ THIS IS A LIP-SYNC OFFSET AND IT IS NOT FREE: NDI video is stamped on the same clock and
    /// presented at the next display tick, so desktop audio lands `lead` LATE against the picture.
    /// SDI is unaffected — that path reads the tap keyed to video PTS and never consults this
    /// timebase.
    ///
    /// 40 ms, CHOSEN FROM THE PUMP'S OWN MEASURED BEHAVIOUR rather than from feel: the pull period
    /// measured ~10.9 ms against a nominal 10 ms, and the `[NDI-AUDIO]` trace's per-push deviation
    /// ran +0.01..+1.02 ms over 72 s. 40 ms is ~4 pull periods of queue and ~40× the largest
    /// deviation ever measured on that trace.
    ///
    /// ⚠️ THE ONE NUMBER HERE NOT SETTLED BY MEASUREMENT IS WHETHER 40 ms IS AUDIBLE AS LIP-SYNC.
    /// It is inside the range usually quoted as tolerable for audio-late, but this has NOT been
    /// confirmed by ear. If it reads late, lower it and expect the renderer to become more
    /// sensitive to pump jitter; that trade is the whole content of this constant.
    /// ── 250 ms: AN EVIDENCE-BACKED FLOOR, NOT A MEASURED OPTIMUM ─────────────────────────────
    ///
    /// It is SRT's `targetDepth` — the smallest lead anywhere in this app that is measured clean
    /// through this same `AVSampleBufferAudioRenderer` — and it sits comfortably above the observed
    /// threshold. It is chosen because it is defensible, not because it is minimal.
    ///
    /// ⚠️ THE TRUE THRESHOLD IS LOWER, AND IS NOT 291 ms. Measured on this machine with real
    /// programme, reproducible in both directions: 40 ms crackly · **150 ms clean** · 300/400/600 ms
    /// clean · back to 40 ms crackly again. So the boundary lies somewhere between 40 and 150 ms and
    /// has not been narrowed further.
    ///
    /// ⚠️ DO NOT DERIVE THIS FROM THE +291 ms RENDER-AHEAD THE HLS WORK MEASURED. That figure was
    /// the leading hypothesis for the mechanism and **150 ms being clean refutes it** — the
    /// threshold is nowhere near 291. The render-ahead may still be why *a* lead is needed at all,
    /// but it does not set the size of it, and presenting it as the explanation would be exactly the
    /// kind of confident mechanism-shaped claim this file has been bitten by three times already.
    ///
    /// ⚠️ AND IT IS A PROPERTY OF THE OUTPUT DEVICE. 150 ms clean is one machine and one interface.
    /// Keep the Debug lead ladder in the build: it is how this was found, and it is how the next
    /// person on different hardware checks whether 250 ms is still enough.
    private static let desktopAudioLeadDefault = 0.250

    /// ── ⚠️ 40 ms IS NOT ENOUGH — MEASURED, AND THE RENDERER HAD BEEN SAYING SO ───────────────
    ///
    /// The ladder settled it: 40 ms crackly, 150 ms and above clean, and crackly again on the way
    /// back down. The lead was being honoured exactly the whole time (`queue` held +42..50 ms
    /// against a 40 ms target) — it was simply far too small.
    ///
    /// ⚠️ `hasSufficientMediaDataForReliablePlaybackStart` IS **NOT** THE SIGNAL, AND THE EARLIER
    /// CLAIM THAT IT WAS IS RETRACTED. It reads NO at EVERY rung — 40, 150, 250, 300, 400, 600 —
    /// while only 40 ms is audibly distorted. It does not track the threshold, it does not track
    /// audible cleanliness, and it appears to read NO unconditionally on this path. It looked like
    /// evidence of starvation only because it was first observed at the one rung that was also
    /// broken. **No adaptive loop is built on it**, and nothing should be: it is a constant, not a
    /// measurement.
    ///
    /// For scale: WHEP runs a 400 ms lead (LiveClock's `targetDepth`) and SRT 250 ms, both clean
    /// through this same renderer.
    ///
    /// RUNTIME-ADJUSTABLE so the threshold can be found in ONE session instead of one value per
    /// build — see `cycleDesktopAudioLead`. Read on the pump thread under `toneLock`.
    private var desktopAudioLead = NDIService.desktopAudioLeadDefault
    /// Set on main when the lead changes; consumed by the pump, which re-anchors immediately.
    private var desktopAudioLeadChanged = false

    /// The ladder the Debug menu steps through. Spans the two known-good live leads (SRT's 250 ms,
    /// WHEP's 400 ms) and brackets the measured 291 ms render-ahead, with the current 40 ms at the
    /// bottom so the first step reproduces today's behaviour exactly.
    private static let desktopAudioLeadLadder = [0.040, 0.150, 0.250, 0.300, 0.400, 0.600]

    /// Debug ▸ Desktop Audio Lead — cycle the ladder. Main thread.
    ///
    /// ⚠️ RE-ANCHORS RATHER THAN REQUIRING A RECONNECT. The lead is only ever expressed as the
    /// offset between the timebase and the PTS axis, so moving it is one `setRate(...atHostTime:)`
    /// away — `desktopAudioLeadChanged` makes the pump take its first-anchor branch on the very next
    /// pull. Nothing about the sample axis, the cumulative counter or the sink is disturbed.
    ///
    /// Expect a brief discontinuity ON the change: enlarging the lead pushes already-enqueued
    /// buffers later (the renderer simply holds them), shrinking it makes some of them instantly
    /// past-due (the renderer drops those). That is inherent to moving a timebase under a running
    /// queue and is not what is being measured — judge each step after it settles.
    func cycleDesktopAudioLead() {
        toneLock.lock()
        let ladder = Self.desktopAudioLeadLadder
        let previous = desktopAudioLead
        let idx = ladder.firstIndex(where: { abs($0 - previous) < 1e-9 }) ?? 0
        let next = ladder[(idx + 1) % ladder.count]
        desktopAudioLead = next
        desktopAudioLeadChanged = true
        rendererForceReport = true
        toneLock.unlock()
        audioLeadTitle = String(format: "Desktop Audio Lead: %.0f ms", next * 1000)
        NSLog("%@", String(format: "[NDI-AUDIO] desktop audio lead → %.0f ms (was %.0f ms) — "
                           + "re-anchoring the timebase on the next pull, no reconnect. For "
                           + "reference: SRT runs 250 ms and WHEP 400 ms through this same renderer, "
                           + "and this machine's audio device measured a +291 ms render-ahead. Watch "
                           + "sufficientForStart and queue in the next [NDI-AUDIO] renderer: line.",
                           next * 1000, previous * 1000))
    }

    @Published private(set) var audioLeadTitle =
        String(format: "Desktop Audio Lead: %.0f ms", NDIService.desktopAudioLeadDefault * 1000)

    /// How far the timebase may sit from where it should be before an absolute re-anchor is worth
    /// the discontinuity it costs.
    ///
    /// 10 ms, WHICH IS THE NUMBER THIS CODEBASE ALREADY USES FOR EXACTLY THIS DECISION —
    /// `FrameEngine.liveAudioPositionTolerance` is 0.010 and governs when the LiveClock mirror stops
    /// smoothing and pushes position immediately. Adopting it means the two live-audio paths correct
    /// at the same threshold rather than at two numbers nobody can compare. It also sits under the
    /// ~12 ms that `liveAudioRateThreshold`'s own note already accepts as a tolerable standing error
    /// ("a full minute between pushes costs 12 ms — under a third of a frame"), and under one frame
    /// at every rate this app outputs (16.7 ms at 60p).
    ///
    /// ⚠️ THE CORRECTION RATE IS DELIBERATELY NOT A CONSTANT AND MUST NOT BECOME ONE. This is a
    /// tolerance on a MEASURED offset, so how often it trips is whatever this machine's two crystals
    /// dictate. At the −7.8 ppm one run of the HLS work measured it is roughly one correction per
    /// 21 minutes — but `HLSAudioTap` is explicit that such figures are properties of the output
    /// device, so a different interface will trip at a different rate and that is the system working,
    /// not a fault. The log line below reports the interval precisely so a far-apart pair of crystals
    /// shows up as a higher rate instead of silently.
    private static let desktopAudioAnchorTolerance = 0.010

    /// How often the loop LOOKS (it corrects only when the tolerance is exceeded). Reading
    /// `currentSyncTime()` is cheap but not free and the pump ticks at 100 Hz, so checking every
    /// pull would be 100× the rate any crystal offset can possibly need.
    ///
    /// 1 Hz is ~1260 samples per correction at 7.8 ppm, and still ~20 samples per correction at an
    /// absurd 500 ppm — so the sampling rate cannot become the limiting factor across any plausible
    /// pair of crystals. That headroom is the reason for the number.
    private static let desktopAudioCheckInterval = 1.0

    /// The renderer session for this connection, or nil when the engine seam is unwired (the pump
    /// then falls back to feeding the tap directly — see `runAudioPump`).
    private var liveAudioSink: FrameEngine.LiveAudioSink?
    /// Cached format description, rebuilt only when the source's rate/channel count changes. At 100
    /// pulls a second a fresh `CMAudioFormatDescriptionCreate` per buffer is pure waste.
    private var audioFormatCache: (rate: Double, channels: Int, desc: CMAudioFormatDescription)?
    /// Pump-thread state for the closed loop. Touched ONLY on the audio pump thread.
    private var anchoredDesktopAudio = false
    private var lastAnchorCheck = 0.0
    private var lastAnchorHost = 0.0
    private var anchorCount = 0

    /// Interleaved Int32 → a CMSampleBuffer the shared renderer accepts.
    ///
    /// ⚠️ DELIBERATELY THE SAME SHAPE AS `WHEPAudioReceiver.makeSampleBuffer`, not a new one — same
    /// ASBD flags, same 90 kHz PTS grid, same `sampleSize` = BYTES PER INTERLEAVED FRAME (passing
    /// the frame count there builds a buffer claiming frames×frames bytes and the renderer reads off
    /// the end; that trap is documented at WHEP's copy and is repeated here because it only bites
    /// once real audio flows).
    ///
    /// THE ONE REAL DIFFERENCE: rate and channel count come from the FRAME, not from a constant.
    /// WHEP is always 48 kHz Opus; NDI carries the source's native format and a source switch can
    /// change it mid-session without a disconnect.
    ///
    /// ── ⚠️ THE PTS IS BUILT FROM TICKS ON THE SAMPLE RATE'S OWN TIMESCALE. NOT FROM SECONDS. ──
    ///
    /// This is the second half of the splice fix and it is the half that is invisible in a debugger:
    /// `CMTime(seconds:preferredTimescale: 90_000)` was ROUNDING every PTS. For `n/48000` to land on
    /// an integer 90 kHz tick, `n` must be a multiple of 8 (90000/48000 = 1.875). NDI's per-pull
    /// counts are 480..530 and the running total is arbitrary, so SEVEN BUFFERS IN EIGHT were
    /// rounded — by up to 0.5 tick = 0.27 samples. Buffer n's end and buffer n+1's start were then
    /// independently rounded values that could not meet, and the renderer resolved each mismatch by
    /// dropping or duplicating a sample. Tens of times a second: crackle with the programme intact
    /// underneath, which is exactly what it sounded like.
    ///
    /// ⚠️ IT WAS EXACT AS A `Double` THE WHOLE TIME. The sample-counted axis (`audioPTSTicks`) is
    /// correct and the PTS-continuity instrumentation measured zero residual — because it measures
    /// Doubles. A PTS can be right to twelve decimal places in seconds and unrepresentable on the
    /// timescale it is stored at. **That is why the fix is the timescale and not the arithmetic.**
    ///
    /// On the sample rate's own timescale every value is exact by construction: `duration` is
    /// `1/sampleRate`, the PTS is an integer count of the same unit, so buffer n's end
    /// (`pts + numSamples × duration`) is BIT-IDENTICAL to buffer n+1's start rather than merely
    /// equal as a Double. There is nothing left to round.
    ///
    /// ⚠️ GENERAL RULE, AND IT IS THE LESSON OF THIS WHOLE CHAIN: **an audio CMTime belongs on the
    /// sample rate's timescale.** 90 kHz is the video/mux grid and it is the wrong unit for a
    /// quantity measured in samples. WHEP and SRT both pass through a 90 kHz audio PTS and both
    /// happen to be safe — WHEP because Opus is 960 samples and SRT because AAC-LC is 1024, and
    /// both are multiples of 8 at 48 kHz. Neither is safe BY DESIGN; see the notes added at those
    /// two call sites.
    private func makeAudioSampleBuffer(_ pcm: UnsafePointer<Int32>, frames: Int, channels: Int,
                                       sampleRate: Double, ptsTicks: Int64) -> CMSampleBuffer? {
        let format: CMAudioFormatDescription
        if let cached = audioFormatCache, cached.rate == sampleRate, cached.channels == channels {
            format = cached.desc
        } else {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: 32, mReserved: 0)
            var made: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                 asbd: &asbd, layoutSize: 0, layout: nil,
                                                 magicCookieSize: 0, magicCookie: nil,
                                                 extensions: nil,
                                                 formatDescriptionOut: &made) == noErr,
                  let made else { return nil }
            audioFormatCache = (sampleRate, channels, made)
            format = made
            // Fires on the first buffer of a connection and again only on a real format change, so
            // it is one line per format rather than per pull. It prints what we DECLARE beside what
            // the bridge actually HANDS US, because a mismatch between those two is invisible by
            // inspection and reads as distortion rather than as an error.
            logDeclaredAudioFormat(asbd, frames: frames, channels: channels, sampleRate: sampleRate)
        }

        let byteCount = frames * channels * MemoryLayout<Int32>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: byteCount,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block,
              CMBlockBufferReplaceDataBytes(with: pcm, blockBuffer: block,
                                            offsetIntoDestination: 0,
                                            dataLength: byteCount) == noErr else { return nil }

        var sb: CMSampleBuffer?
        // BOTH on the sample rate's timescale, so `pts + n × duration` is exact integer arithmetic.
        let timescale = CMTimeScale(sampleRate)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: timescale),
            presentationTimeStamp: CMTime(value: ptsTicks, timescale: timescale),
            decodeTimeStamp: .invalid)
        var sampleSize = channels * MemoryLayout<Int32>.size
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                        formatDescription: format, sampleCount: frames,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }

    /// Dump the EXACT ASBD handed to `CMAudioFormatDescriptionCreate`, every field, with the flag
    /// word decoded bit by bit — beside what `NDIAudioFrame` actually delivers. The two must agree;
    /// this exists so that agreement is checked rather than assumed.
    private func logDeclaredAudioFormat(_ asbd: AudioStreamBasicDescription,
                                        frames: Int, channels: Int, sampleRate: Double) {
        let f = asbd.mFormatFlags
        func on(_ flag: AudioFormatFlags) -> String { (f & flag) != 0 ? "YES" : "no" }
        let fourCC = withUnsafeBytes(of: asbd.mFormatID.bigEndian) { raw in
            String(bytes: raw, encoding: .ascii) ?? "????"
        }
        NSLog("""
        [NDI-AUDIO] ── DECLARED ASBD (what the renderer and the tap are told this buffer is) ──
          mFormatID        = 0x%08X '%@'  (kAudioFormatLinearPCM = 0x%08X 'lpcm')
          mFormatFlags     = 0x%08X → signedInteger=%@ float=%@ packed=%@ nonInterleaved=%@ bigEndian=%@ alignedHigh=%@
          mBitsPerChannel  = %u
          mChannelsPerFrame= %u
          mBytesPerFrame   = %u
          mBytesPerPacket  = %u
          mFramesPerPacket = %u
          mSampleRate      = %.1f
        [NDI-AUDIO] ── DELIVERED BY NDIAudioFrame (what the bytes actually are) ──
          element type     = int32_t (const int32_t *samples), SIGNED, native little-endian on arm64
          bit depth        = 32, full-scale (bridge converts float→Int32 as sample × 2147483647)
          interleaving     = INTERLEAVED, channel-major within each frame
          channelCount     = %d · sampleRate = %.1f · frameCount(this pull) = %d
          bytes per frame  = %d (= channelCount × 4)   block length = %d
        """,
              asbd.mFormatID, fourCC, kAudioFormatLinearPCM,
              f,
              on(kAudioFormatFlagIsSignedInteger), on(kAudioFormatFlagIsFloat),
              on(kAudioFormatFlagIsPacked), on(kAudioFormatFlagIsNonInterleaved),
              on(kAudioFormatFlagIsBigEndian), on(kAudioFormatFlagIsAlignedHigh),
              asbd.mBitsPerChannel, asbd.mChannelsPerFrame, asbd.mBytesPerFrame,
              asbd.mBytesPerPacket, asbd.mFramesPerPacket, asbd.mSampleRate,
              channels, sampleRate, frames,
              channels * 4, frames * channels * 4)
    }

    // MARK: - ⌃⌥A — TONE TEST: bisect the path by replacing the CONTENT and nothing else

#if DEBUG
    /// ── WHAT THIS ISOLATES, AND WHY IT IS BUILT THIS WAY ─────────────────────────────────────
    ///
    /// Timing is exhausted as an explanation: grid rounding 0.0000 samples on every dumped buffer,
    /// PTS continuity 0.000 ms in BOTH columns, `dev` +0.00 ms, zero re-anchors, `dataLength ==
    /// numSamples × mBytesPerFrame`, one timing entry. The buffers are, by every measurement
    /// available, correctly constructed — and the desktop still crackles while the SAME
    /// CMSampleBuffer plays cleanly to SDI.
    ///
    /// So substitute the CONTENT and change NOTHING ELSE. The tone rides the real pull: it is
    /// written into the buffer sizes `captureAudioFrameForInterval:` actually returned this tick
    /// (480..530, from the same elapsed calculation), at the source's real rate and channel count,
    /// on the same PTS ticks, through the same `makeAudioSampleBuffer`, the same `LiveAudioSink`,
    /// the same renderer. The ONLY difference from a live run is which bytes are in the block.
    ///
    ///   * TONE CLEAN   → construction, cadence and renderer are all fine and the fault is in the
    ///                    NDI samples themselves. That contradicts SDI playing the same buffer
    ///                    cleanly, and the contradiction is then the finding.
    ///   * TONE CRACKLY → the path is broken independently of content; the NDI samples are
    ///                    irrelevant and the next step is the 960-sample restructure.
    ///
    /// ⚠️ PHASE IS CONTINUOUS ACROSS BUFFERS AND THAT IS LOAD-BEARING. The phase accumulator is
    /// per-sample and survives from one buffer to the next, so the tone is a single unbroken sine
    /// across the whole session. A per-buffer phase reset would put a discontinuity at every buffer
    /// boundary — manufacturing exactly the artefact being hunted, and guaranteeing a false
    /// positive. If this is ever rewritten, that property is the test.
    ///
    /// ⚠️ THE TAP GETS THE TONE TOO. `LiveAudioSink.enqueue` tees before the renderer, so the
    /// meters will show the tone and, if DeckLink output is on, SDI WILL CARRY IT. That is useful
    /// — a tone that is clean on SDI and crackly on the desktop reproduces the whole problem in one
    /// keystroke with a known-perfect source — but do not leave it running into a real output.
    ///
    /// ⚠️ TWO AMPLITUDES, CYCLED, BECAUSE 0 dBFS ALONE CANNOT ANSWER THE QUESTION. A full-scale
    /// sine is the requested test, but if anything downstream applies gain > 1 it clips, and
    /// clipping sounds like exactly the crackle being diagnosed. −6 dBFS has 6 dB of headroom, so
    /// the pair separates "the path is broken" from "something downstream has gain": crackly at
    /// 0 dBFS and clean at −6 is a level problem, crackly at both is the path.
    private enum ToneTest: Int {
        case off = 0, fullScale = 1, minus6dB = 2
        var next: ToneTest { ToneTest(rawValue: (rawValue + 1) % 3) ?? .off }
        var amplitude: Double {
            switch self {
            case .off:       return 0
            case .fullScale: return 1.0
            case .minus6dB:  return 0.5
            }
        }
        var label: String {
            switch self {
            case .off:       return "OFF — real NDI samples"
            case .fullScale: return "ON — 1 kHz sine at 0 dBFS (full scale)"
            case .minus6dB:  return "ON — 1 kHz sine at −6 dBFS (6 dB of headroom)"
            }
        }
        /// Short form for the menu item, which states where the NEXT press goes as well as where
        /// it is now — a cycling item that only names its current state leaves you pressing it to
        /// find out what comes next.
        var menuTitle: String {
            switch self {
            case .off:       return "Off (next: 1 kHz 0 dBFS)"
            case .fullScale: return "1 kHz 0 dBFS (next: 1 kHz −6 dBFS)"
            case .minus6dB:  return "1 kHz −6 dBFS (next: Off)"
            }
        }
    }

    private static let toneFrequency = 1000.0
    /// Toggled on MAIN by the keystroke, read on the PUMP THREAD once per pull — hence the lock.
    /// `UnfairLock` for the same reason `LiveDisplaySize` uses one: the reader is latency-sensitive
    /// and must never block behind an unboosted holder.
    private let toneLock = UnfairLock()
    private var toneMode: ToneTest = .off
    /// Pump-thread only. Radians, wrapped to [0, 2π) so it cannot lose precision over a long run —
    /// at 48 kHz an unwrapped accumulator reaches 3e8 radians in an hour and the per-sample
    /// increment starts rounding away, which would itself become a slow distortion.
    private var tonePhase = 0.0
    /// Pump-thread only. Grown to fit, never shrunk — no allocation in the steady state.
    ///
    /// ⚠️ A MANUAL ALLOCATION, NOT AN `[Int32]`, AND THAT IS NOT A MICRO-OPTIMISATION. The pointer
    /// handed to `makeAudioSampleBuffer` has to outlive the call that produces it, and a Swift
    /// Array's `baseAddress` is valid ONLY inside `withUnsafeMutableBufferPointer` — returning it is
    /// undefined behaviour that happens to work until the optimiser or a reallocation says
    /// otherwise. Exactly the class of latent fault this whole investigation has been chasing, so
    /// it is not worth introducing one to save a `deallocate`.
    private var toneScratch: UnsafeMutablePointer<Int32>?
    private var toneScratchCapacity = 0

    /// The Debug menu item's title, carrying the CURRENT state so the menu itself is the readout —
    /// no need to find the log line to know whether the tone is on. Published, main-thread only.
    /// ⚠️ BUILT FROM `ToneTest.off.menuTitle`, NOT A LITERAL. A hand-written initial string drifted
    /// from what `cycleAudioToneTest` writes: the menu opened reading "Off" but, once cycled back to
    /// off, read "Off (next: 1 kHz 0 dBFS)". A tester meeting the first form cannot tell what
    /// pressing it will do, which is the whole job of this title.
    @Published private(set) var audioToneTestTitle = "NDI Audio Tone Test: " + ToneTest.off.menuTitle

    /// Debug ▸ NDI Audio Tone Test, and ⌃⌥A — cycle OFF → 0 dBFS → −6 dBFS → OFF. Main thread.
    func cycleAudioToneTest() {
        toneLock.lock()
        toneMode = toneMode.next
        let mode = toneMode
        toneLock.unlock()
        audioToneTestTitle = "NDI Audio Tone Test: " + mode.menuTitle
        NSLog("[NDI-AUDIO] ⌃⌥A TONE TEST %@ · %.0f Hz · same buffer sizes, same PTS ticks, same "
            + "makeAudioSampleBuffer → LiveAudioSink → renderer as the real samples. Only the BYTES "
            + "differ. The tap and (if output is on) SDI carry it too.",
              mode.label, Self.toneFrequency)
    }

    /// Fill `toneScratch` with a continuous sine and hand back a pointer to it, or nil when the
    /// test is off. Pump thread.
    private func toneSamples(frames: Int, channels: Int, sampleRate: Double) -> UnsafePointer<Int32>? {
        toneLock.lock(); let mode = toneMode; toneLock.unlock()
        guard mode != .off, frames > 0, channels > 0, sampleRate > 0 else { return nil }

        let count = frames * channels
        if toneScratchCapacity < count {
            toneScratch?.deallocate()
            toneScratch = UnsafeMutablePointer<Int32>.allocate(capacity: count)
            toneScratchCapacity = count
        }
        guard let scratch = toneScratch else { return nil }

        let step = 2.0 * Double.pi * Self.toneFrequency / sampleRate
        // 2^31 − 1, so a +1.0 peak is Int32.max exactly and cannot wrap. The same full-scale
        // convention the bridge uses for the real float→Int32 conversion.
        let peak = mode.amplitude * 2147483647.0
        var phase = tonePhase
        for f in 0..<frames {
            let v = Int32(sin(phase) * peak)
            // Same value to every channel — this is a path test, not a routing test.
            for c in 0..<channels { scratch[f * channels + c] = v }
            phase += step
            if phase >= 2.0 * Double.pi { phase -= 2.0 * Double.pi }
        }
        tonePhase = phase
        return UnsafePointer(scratch)
    }
#endif

    /// THE SUBSTITUTION POINT, and deliberately the only one. Everything downstream — sizes, rate,
    /// channels, PTS ticks, format description, block buffer, sink, renderer — is identical either
    /// way; the tone changes which bytes are copied and nothing else.
    ///
    /// Defined in ALL configurations even though the tone is DEBUG-only, because the pump's call
    /// site is unconditional. In Release it is `audio.samples` and the optimiser erases it.
    private func toneOrRealSamples(_ audio: NDIAudioFrame) -> UnsafePointer<Int32> {
        #if DEBUG
        return toneSamples(frames: Int(audio.frameCount), channels: Int(audio.channelCount),
                           sampleRate: Double(audio.sampleRate)) ?? audio.samples
        #else
        return audio.samples
        #endif
    }

    // MARK: - TEST 2 — regroup into WHEP's shape: fixed 960-sample buffers at 50 Hz

#if DEBUG
    /// ── WHAT THIS CHANGES, AND WHAT IT DELIBERATELY DOES NOT ─────────────────────────────────
    ///
    /// The WAV of the exact enqueued bytes plays CLEAN, so the samples, the float→Int32 conversion
    /// and the plane-stride handling are all correct and SDI has been carrying good audio the whole
    /// time. The fault is in `AVSampleBufferAudioRenderer`'s CONSUMPTION — which is also why the
    /// synthesised tone was distorted: the content never mattered.
    ///
    /// That leaves the SHAPE of what NDI hands the renderer as the thing to test, and there is a
    /// known-good reference for it in this very app: WHEP goes through the SAME `LiveAudioSink`, the
    /// SAME renderer, and is audibly fine. Its input differs from NDI's in exactly two ways —
    ///
    ///     WHEP:  fixed 960 samples, pushed every 20 ms  (50 Hz)
    ///     NDI:   variable 480..530,  pushed every ~10.9 ms (~92 Hz)
    ///
    /// — so this accumulates pulls into fixed 960-sample buffers and pushes at WHEP's cadence.
    /// A pull straddling a boundary is split, never padded and never dropped: the carry becomes the
    /// head of the next group, so the sample stream is bit-identical to the un-grouped one and only
    /// the packaging changes. That is what makes this a controlled A/B rather than a second variable.
    ///
    /// ⚠️ THE PTS AXIS IS UNCHANGED AND STAYS SAMPLE-COUNTED. `audioPTSTicks` is still the source of
    /// the stamp; a group's PTS is simply the tick of its FIRST sample. 960 is a multiple of 8, so a
    /// group boundary is additionally exact on a 90 kHz grid — which removes the timescale as a
    /// variable even for anyone who later moves this back to 90 kHz.
    ///
    /// ⚠️ IT ADDS LATENCY, AND THAT IS INHERENT TO THE TEST, NOT A DEFECT. A group cannot be pushed
    /// until it is full, so desktop audio sits up to 20 ms further behind the picture. Say so rather
    /// than let it read as a regression if the grouping turns out to help.
    private static let groupedFrameCount = 960

    /// Pump-thread only. Accumulates interleaved Int32 until `groupedFrameCount` frames are held.
    private var groupBuffer: UnsafeMutablePointer<Int32>?
    private var groupCapacityFrames = 0
    private var groupHeldFrames = 0
    private var groupChannels = 0
    private var groupFirstTicks: Int64 = 0

    /// Toggled on MAIN, read on the PUMP THREAD once per pull.
    private var groupedMode = false
    @Published private(set) var audioGroupedTitle = "Renderer Input: NDI-native (480..530 @ ~92 Hz)"

    /// Pump-thread copy of `groupedMode`, so a mode change is noticed ON the pump and the partial
    /// group is dropped THERE. `groupHeldFrames` is pump-thread-owned and must not be written from
    /// main — that was the first shape of this and it was a data race on the accumulator.
    private var groupedModeOnPump = false

    /// Debug ▸ Renderer Input — A/B the cadence live, without a rebuild. Main thread.
    func toggleGroupedAudio() {
        toneLock.lock()
        groupedMode.toggle()
        let on = groupedMode
        toneLock.unlock()
        audioGroupedTitle = on
            ? "Renderer Input: WHEP-shaped (fixed 960 @ 50 Hz)"
            : "Renderer Input: NDI-native (480..530 @ ~92 Hz)"
        NSLog("[NDI-AUDIO] renderer input shape → %@. %@",
              on ? "WHEP-SHAPED: fixed 960-sample buffers at 50 Hz"
                 : "NDI-NATIVE: variable 480..530 at ~92 Hz",
              on ? "Adds up to 20 ms of latency by construction — a group is pushed only once full."
                 : "The cadence the pull produces, pushed straight through.")
    }

    /// Accumulate into fixed-size groups. Returns the groups ready to push this tick, each with the
    /// sample tick of its first frame. Pump thread.
    ///
    /// A pull is SPLIT across groups rather than padded or dropped, so the sample stream is
    /// unchanged — `[Int32]` copies only, no resampling, no silence insertion.
    /// ⚠️ EMITS THROUGH A CALLBACK RATHER THAN RETURNING AN ARRAY, AND THAT IS CORRECTNESS, NOT
    /// STYLE. Every group is written into the SAME accumulator, so a returned array of pointers
    /// would alias — the second group would overwrite the first before the caller had enqueued it.
    /// Emitting inline guarantees each group is consumed before the buffer is refilled, whatever
    /// the pull size. (Today a 530-frame pull cannot fill two 960-frame groups, so it could never
    /// bite; this does not depend on that remaining true.)
    private func regroup(_ samples: UnsafePointer<Int32>, frames: Int, channels: Int,
                         startTicks: Int64,
                         emit: (_ ticks: Int64, _ frames: Int, _ data: UnsafePointer<Int32>) -> Void) {
        let target = Self.groupedFrameCount
        if groupCapacityFrames < target || groupChannels != channels {
            groupBuffer?.deallocate()
            groupBuffer = UnsafeMutablePointer<Int32>.allocate(capacity: target * channels)
            groupCapacityFrames = target
            groupChannels = channels
            groupHeldFrames = 0
        }
        guard let group = groupBuffer else { return }

        var consumed = 0
        while consumed < frames {
            if groupHeldFrames == 0 {
                // The group's PTS is the tick of its first sample — the axis is untouched.
                groupFirstTicks = startTicks + Int64(consumed)
            }
            let take = min(target - groupHeldFrames, frames - consumed)
            memcpy(group + groupHeldFrames * channels,
                   samples + consumed * channels,
                   take * channels * MemoryLayout<Int32>.size)
            groupHeldFrames += take
            consumed += take
            if groupHeldFrames == target {
                emit(groupFirstTicks, target, UnsafePointer(group))
                groupHeldFrames = 0
            }
        }
    }
#endif

    // MARK: - WAV capture: the exact bytes handed to the renderer, written to disk

#if DEBUG
    /// ── WHY THIS EXISTS: NOTHING SO FAR HAS SEPARATED "THE BYTES" FROM "THE PLAYBACK" ─────────
    ///
    /// Every measurement to date has been of METADATA — sample counts, PTS grids, strides, ring
    /// counters, meter levels — and all of them are now clean while the audio is still audibly
    /// wrong. `real=Nf` and `underruns=0` prove the ring was READ, not what was in it; the meters
    /// metered 82% synthesised audio without complaint. The one question never asked is whether the
    /// bytes themselves are good, and it is answerable only by listening to them somewhere other
    /// than through the renderer under suspicion.
    ///
    /// So: take the CMSampleBuffer's OWN block buffer contents at the enqueue point and write them
    /// to a .wav. Not regenerated, not re-derived from `audio.samples` — copied out of the exact
    /// object that goes to `LiveAudioSink`, after `makeAudioSampleBuffer` has built it.
    ///
    ///   * tone WAV clean       → the bytes are perfect and the renderer's CONSUMPTION is the fault
    ///   * tone WAV crackly     → the tone GENERATOR is the bug and this branch was a false positive
    ///   * real NDI WAV clean   → the samples were always fine, and SDI has been carrying good audio
    ///   * real crackly, tone clean → the conversion is wrong in a way the stride check misses
    ///
    /// ⚠️ `CMBlockBufferCopyDataBytes`, NOT `CMBlockBufferGetDataPointer`. A CMBlockBuffer may be
    /// non-contiguous; the pointer form hands back only the run at that offset and `lengthAtOffset`
    /// can be less than `totalLength`. Copying is the form that cannot silently truncate — and a
    /// diagnostic that truncates would manufacture exactly the discontinuities being hunted.
    ///
    /// ⚠️ BUFFERED IN MEMORY, WRITTEN AT STOP, AND THAT IS DELIBERATE. File I/O on the pump thread
    /// at 100 Hz would add its own jitter to the cadence under investigation — the measurement would
    /// perturb the thing it measures. The capacity is reserved up front so even the array growth
    /// cannot stall a pull. 48 kHz × 2ch × 4 bytes ≈ 384 KB/s, so the cap below is ~46 MB.
    private static let wavMaxSeconds = 120.0
    private let wavLock = UnfairLock()
    private var wavCapturing = false
    private var wavBytes = [UInt8]()
    private var wavRate = 0.0
    private var wavChannels = 0
    private var wavStartHost = 0.0
    private var wavLastTitleUpdate = 0.0
    private var wavToneModeAtStart = "real"

    /// Menu title, carrying the state and the size so the menu is the readout.
    @Published private(set) var audioCaptureTitle = "Record NDI Audio to WAV"

    /// Debug ▸ Record NDI Audio to WAV — start, or stop and write. Main thread.
    func toggleAudioWAVCapture() {
        wavLock.lock()
        let wasCapturing = wavCapturing
        wavLock.unlock()
        if wasCapturing { finishAudioWAVCapture() } else { beginAudioWAVCapture() }
    }

    private func beginAudioWAVCapture() {
        toneLock.lock(); let mode = toneMode; toneLock.unlock()
        let tag: String
        switch mode {
        case .off:       tag = "real"
        case .fullScale: tag = "tone-0dBFS"
        case .minus6dB:  tag = "tone-minus6dBFS"
        }
        wavLock.lock()
        wavBytes.removeAll(keepingCapacity: false)
        // Reserve for the cap at the commonest format so no append can trigger a realloc mid-pull.
        wavBytes.reserveCapacity(Int(Self.wavMaxSeconds * 48000 * 2 * 4))
        wavRate = 0; wavChannels = 0
        wavStartHost = Self.monotonicNow()
        wavLastTitleUpdate = 0
        wavToneModeAtStart = tag
        wavCapturing = true
        wavLock.unlock()
        audioCaptureTitle = "Stop Recording & Write WAV (0 s)"
        NSLog("[NDI-AUDIO] WAV capture STARTED (source: %@) — recording the exact block-buffer bytes "
            + "handed to LiveAudioSink. Stops automatically after %.0f s.", tag, Self.wavMaxSeconds)
    }

    /// PUMP THREAD, at the enqueue point. Copies the buffer's own bytes verbatim.
    private func captureEnqueuedAudio(_ sb: CMSampleBuffer, sampleRate: Double, channels: Int) {
        wavLock.lock()
        guard wavCapturing else { wavLock.unlock(); return }
        if wavRate == 0 { wavRate = sampleRate; wavChannels = channels }
        // A format change mid-capture would make one WAV header describe two formats. Stop rather
        // than write a file that silently misrepresents half its own contents.
        guard wavRate == sampleRate, wavChannels == channels else {
            wavCapturing = false
            wavLock.unlock()
            NSLog("[NDI-AUDIO] WAV capture STOPPED — the audio format changed mid-capture "
                + "(%.0fHz·%dch → %.0fHz·%dch). Writing what was captured before the change.",
                  wavRate, wavChannels, sampleRate, channels)
            DispatchQueue.main.async { [weak self] in self?.finishAudioWAVCapture() }
            return
        }
        let elapsed = Self.monotonicNow() - wavStartHost
        guard elapsed < Self.wavMaxSeconds else {
            wavCapturing = false
            wavLock.unlock()
            DispatchQueue.main.async { [weak self] in self?.finishAudioWAVCapture() }
            return
        }

        if let bb = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(bb)
            if len > 0 {
                let start = wavBytes.count
                wavBytes.append(contentsOf: repeatElement(UInt8(0), count: len))
                wavBytes.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len,
                                                   destination: raw.baseAddress!.advanced(by: start))
                }
            }
        }
        let bytes = wavBytes.count
        let due = elapsed - wavLastTitleUpdate >= 1.0
        if due { wavLastTitleUpdate = elapsed }
        wavLock.unlock()

        if due {
            DispatchQueue.main.async { [weak self] in
                self?.audioCaptureTitle = String(format: "Stop Recording & Write WAV (%.0f s, %.1f MB)",
                                                 elapsed, Double(bytes) / 1_048_576)
            }
        }
    }

    /// Stop and write. Main thread.
    private func finishAudioWAVCapture() {
        wavLock.lock()
        wavCapturing = false
        let bytes = wavBytes
        let rate = wavRate
        let channels = wavChannels
        let tag = wavToneModeAtStart
        wavBytes.removeAll(keepingCapacity: false)
        wavLock.unlock()

        audioCaptureTitle = "Record NDI Audio to WAV"
        guard !bytes.isEmpty, rate > 0, channels > 0 else {
            NSLog("[NDI-AUDIO] WAV capture stopped with nothing recorded — is a source connected "
                + "and carrying audio?")
            return
        }

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        // Colons are legal in HFS+ filenames but display as "/" in Finder — swap them out so the
        // name reads as a timestamp rather than as a path.
        let when = stamp.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "Manifold-NDI-\(tag)-\(when).wav"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop").appendingPathComponent(name)

        var file = Self.wavHeader(dataBytes: bytes.count, sampleRate: rate, channels: channels)
        file.append(contentsOf: bytes)
        do {
            try Data(file).write(to: url)
            let frames = bytes.count / (channels * 4)
            NSLog("[NDI-AUDIO] WAV WRITTEN → %@\n"
                + "            %d frames · %.3f s · %.0f Hz · %dch · 32-bit signed int · %.1f MB\n"
                + "            These are the EXACT bytes handed to LiveAudioSink, copied from the "
                + "CMSampleBuffer's own block buffer at the enqueue point.",
                  url.path, frames, Double(frames) / rate, rate, channels,
                  Double(file.count) / 1_048_576)
        } catch {
            NSLog("[NDI-AUDIO] WAV write FAILED at %@ — %@", url.path, error.localizedDescription)
        }
    }

    /// A 44-byte canonical PCM WAV header. Little-endian throughout, format tag 1 (PCM integer),
    /// 32 bits per sample — matching the ASBD the buffers actually carry
    /// (`kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked`, `mBitsPerChannel = 32`), so
    /// the file is a faithful container for the bytes rather than a conversion of them.
    private static func wavHeader(dataBytes: Int, sampleRate: Double, channels: Int) -> [UInt8] {
        var h = [UInt8]()
        func u32(_ v: UInt32) { h.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                                                      UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]) }
        func u16(_ v: UInt16) { h.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func ascii(_ s: String) { h.append(contentsOf: Array(s.utf8)) }

        let blockAlign = UInt16(channels * 4)
        ascii("RIFF"); u32(UInt32(36 + dataBytes)); ascii("WAVE")
        ascii("fmt "); u32(16)
        u16(1)                                  // PCM integer
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate) * UInt32(blockAlign))   // byte rate
        u16(blockAlign)
        u16(32)                                 // bits per sample
        ascii("data"); u32(UInt32(dataBytes))
        return h
    }
#endif

    // MARK: - The audio PTS axis: SAMPLE-COUNTED, not read off the wall clock per buffer

    /// How far the sample axis may drift from the wall clock before it is re-pinned.
    ///
    /// 25 ms — deliberately HALF of `AudioTapBuffer.append`'s 50 ms PTS/sample disagreement
    /// threshold, so the axis is corrected before the tap would ever consider re-anchoring. The tap
    /// re-anchor DROPS THE RETAINED WINDOW, which is what DeckLink reads from, so an axis that only
    /// corrected at the tap's own threshold would be trading a renderer glitch for an SDI dropout.
    /// Staying inside its tolerance means the tap never sees a step it has to act on.
    private static let audioAxisResyncTolerance = 0.025

    /// Anchor of the sample axis, IN SAMPLE TICKS on the sample rate's own timescale, and the count
    /// of frames delivered since it was set. `ptsTicks = anchorTicks + cumulative` — an integer add,
    /// which is the whole fix.
    ///
    /// ⚠️ TICKS, NOT SECONDS, AND THAT DISTINCTION IS THE SECOND BUG. Holding the anchor in seconds
    /// and converting per buffer is what put the PTS back on a grid that could not represent it —
    /// see `makeAudioSampleBuffer`. The conversion from seconds happens ONCE, here, at the anchor.
    private var audioAnchorTicks: Int64?
    private var audioCumulativeFrames: Int64 = 0
    private var audioAxisRate = 0.0
    private var audioAxisChannels = 0
    private var audioResyncCount = 0
    private var lastAudioResyncHost = 0.0

    /// ── WHY THE PTS IS COUNTED IN SAMPLES AND NOT READ OFF THE CLOCK ─────────────────────────
    ///
    /// ⚠️ THIS REPLACED A PER-PULL `monotonicNow()` STAMP AND THAT STAMP WAS THE DISTORTION BUG.
    /// `AVSampleBufferAudioRenderer` schedules by PTS exactly, so buffer n+1 must begin where
    /// buffer n ended — TO THE SAMPLE. A wall-clock read per pull cannot do that, and it could not
    /// even in principle: the SAMPLE COUNT comes from an elapsed measurement taken inside
    /// `captureAudioFrameForInterval:`, while the PTS was a second, later reading of the same clock
    /// taken in Swift after that call returned. Nothing tied the two together, so consecutive
    /// buffers overlapped or gapped by whatever the difference happened to be. MEASURED before the
    /// fix: mean |residual| 0.15–0.57 ms (7–27 samples), ~50 gaps and ~40 overlaps PER SECOND, mean
    /// residual ~0 — i.e. not a drift, just permanent jitter. The renderer must drop or pad samples
    /// to splice each one, 100 times a second, which is continuous distortion rather than clicks.
    ///
    /// The tap never noticed because `AudioTapBuffer.append` reconciles the two axes with a 50 ms
    /// tolerance and silently absorbs anything smaller; SDI reads the ring by sample position and
    /// never consults a per-buffer PTS at all. That asymmetry is why the same samples were clean on
    /// the wire and distorted on the desktop.
    ///
    /// Counting samples makes buffers tile BY CONSTRUCTION, because the PTS *is* the running sample
    /// count. It is the same property that makes WHEP's stamps tile perfectly — its PTS is
    /// `unwrap(rtpTimestamp) / 48000`, a sample counter, not a clock reading.
    ///
    /// ── THE WALL CLOCK KEEPS TWO JOBS AND LOSES THE THIRD ────────────────────────────────────
    ///
    /// It still sets the initial anchor, and it still drives `serviceDesktopAudioAnchor`. It is no
    /// longer the per-buffer timestamp.
    ///
    /// ⚠️ AND IT IS STILL THE AXIS THE SAMPLE COUNT IS PINNED TO, WHICH IS NOT OPTIONAL. NDI's
    /// VIDEO is stamped `monotonicNow()` and DeckLink aligns audio to video by that PTS, so a sample
    /// axis allowed to free-run would take SDI lip-sync with it. The per-pull check below is what
    /// keeps the two ends together: sample-exact in the small, wall-clock-pinned in the large.
    ///
    /// ── ⚠️ A STALL PAST `kNDIAudioMaxPullSeconds` (250 ms) IS ABSORBED HERE, NOT SPECIAL-CASED ──
    ///
    /// When the pump is starved past the clamp the bridge caps the request and **those samples are
    /// genuinely gone from the queue** — it says so in its own log line. The sample axis therefore
    /// falls behind the wall clock by the whole dropped duration, at once, and by more than this
    /// tolerance.
    ///
    /// THAT IS A RE-ANCHOR, AND IT NEEDS NO CODE OF ITS OWN, because a stall produces exactly the
    /// quantity this check already measures: `pts - wallNow` past tolerance. Special-casing it would
    /// mean detecting the stall a second way (Swift cannot even see it — the bridge clamps
    /// internally and returns a normal short frame) and acting on it with the same correction. The
    /// check is per-pull rather than per-second precisely so a stall is corrected on the very next
    /// buffer instead of up to a second later.
    ///
    /// The alternative — letting the closed loop absorb it — is wrong: `serviceDesktopAudioAnchor`
    /// moves the TIMEBASE to match the audio, so it would have followed the audio into the hole and
    /// left the desktop permanently late against a picture that never stalled.
    ///
    /// Format change and audio disappearing reset the counter and re-anchor, matching the bridge,
    /// which drops `_audioLastPullTime` and `_audioSampleCarry` at the same two points — the axis
    /// and the thing that feeds it must restart together or the first buffer after the change
    /// carries a PTS computed from the old stream's rate.
    private func audioPTSTicks(forFrames frames: Int, sampleRate: Double, channels: Int,
                               wallNow: Double) -> Int64 {
        // (Re)anchor: first buffer of a session, or the source's format moved under us. A rate
        // change makes `cumulative / sampleRate` meaningless — the divisor is no longer the one the
        // frames were counted at — so the counter restarts rather than being converted.
        if audioAnchorTicks == nil || sampleRate != audioAxisRate || channels != audioAxisChannels {
            if audioAnchorTicks != nil {
                NSLog("[NDI-AUDIO] audio format moved %.0fHz·%dch → %.0fHz·%dch — sample axis "
                    + "restarted and re-anchored to the wall clock",
                      audioAxisRate, audioAxisChannels, sampleRate, channels)
            }
            // The ONE conversion from seconds in the whole axis. Rounded to the nearest sample tick,
            // because a tick is the finest thing the axis can express and a fractional anchor would
            // reintroduce exactly the rounding this replaced.
            audioAnchorTicks = Int64((wallNow * sampleRate).rounded())
            audioCumulativeFrames = 0
            audioAxisRate = sampleRate
            audioAxisChannels = channels
        }

        var ticks = audioAnchorTicks! + audioCumulativeFrames
        let divergence = Double(ticks) / sampleRate - wallNow
        if abs(divergence) > Self.audioAxisResyncTolerance {
            let sinceLast = lastAudioResyncHost > 0 ? wallNow - lastAudioResyncHost : 0
            audioResyncCount += 1
            lastAudioResyncHost = wallNow
            // Re-pin the anchor so THIS buffer lands at the wall clock, keeping the running count
            // intact — the axis moves, the counter does not restart. Still an integer tick, so the
            // grid property survives a re-pin.
            audioAnchorTicks = Int64((wallNow * sampleRate).rounded()) - audioCumulativeFrames
            ticks = audioAnchorTicks! + audioCumulativeFrames
            // ⚠️ THE INTERVAL IS THE MEASUREMENT. A one-off is a stall (the bridge logs its own
            // line for that). A REGULAR cadence means the sample axis is genuinely running at a
            // different rate from the wall clock, and the implied ppm says by how much — in which
            // case the fault is in the pump's request sizing, not here, and this line is where it
            // becomes visible instead of silently costing lip-sync.
            let ppm = sinceLast > 0 ? divergence / sinceLast * 1e6 : 0
            NSLog("%@", String(format: "[NDI-AUDIO] sample axis RE-PINNED — it had run %+.1f ms "
                               + "%@ the wall clock (tolerance %.0f ms) after %.1f s → %.0f ppm "
                               + "· re-pin #%d. A one-off is a stall past the 250 ms pull clamp; "
                               + "a steady cadence is a rate error in the pull sizing.",
                               divergence * 1000, divergence > 0 ? "AHEAD OF" : "BEHIND",
                               Self.audioAxisResyncTolerance * 1000, sinceLast, ppm,
                               audioResyncCount))
        }

        audioCumulativeFrames += Int64(frames)
        return ticks
    }

    /// How many of a connection's first buffers get the full property dump. Enough to see the
    /// pattern repeat and to catch a first-buffer-only anomaly; few enough to cost nothing.
    private static let audioBufferDumpCount = 8
    private var audioBuffersDumped = 0

    /// Dump what the CMSampleBuffer ACTUALLY carries, read back off the finished object rather than
    /// from the values that went in — so a field CoreMedia reinterpreted is visible.
    ///
    /// ⚠️ THE PTS IS PRINTED AS RAW value/timescale, NOT AS SECONDS, AND THAT IS THE POINT. A PTS
    /// that is correct to 12 decimal places in seconds can still be UNREPRESENTABLE on its own
    /// timescale, and printing it in seconds hides exactly that. `exactOnGrid` below is the test.
    private func dumpSampleBuffer(_ sb: CMSampleBuffer, expectedFrames: Int, channels: Int,
                                  sampleRate: Double, cumulativeFrames: Int64) {
        // DEVELOPER DIAGNOSTIC — compiled to nothing in Release. Bounded to the first few buffers of
        // a connection, so the cost was never the issue; it is that these lines answer a question
        // (is the buffer built correctly) that is settled, and a tester's log is better spent on the
        // `renderer:` line, which answers one that is not.
        #if !DEBUG
        return
        #else
        guard audioBuffersDumped < Self.audioBufferDumpCount else { return }
        audioBuffersDumped += 1

        let numSamples = CMSampleBufferGetNumSamples(sb)
        let dataLength = CMSampleBufferGetDataBuffer(sb).map { CMBlockBufferGetDataLength($0) } ?? -1

        var timingCount: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil,
                                               entriesNeededOut: &timingCount)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(1, timingCount))
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: timingCount, arrayToFill: &timings,
                                               entriesNeededOut: nil)
        let t = timings[0]

        var bytesPerFrame: UInt32 = 0, framesPerPacket: UInt32 = 0, bytesPerPacket: UInt32 = 0
        if let fd = CMSampleBufferGetFormatDescription(sb),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
            bytesPerFrame = asbd.pointee.mBytesPerFrame
            framesPerPacket = asbd.pointee.mFramesPerPacket
            bytesPerPacket = asbd.pointee.mBytesPerPacket
        }

        // THE CHECK THAT MATTERS, AND IT IS KEPT AFTER THE FIX: is this PTS exactly representable
        // on the timescale it carries? The sample position `cumulative` must be a whole number of
        // ticks on that timescale. When it is not, the stored value has been ROUNDED and buffer n's
        // end can no longer equal buffer n+1's start.
        //
        // ⚠️ POST-FIX THIS MUST READ ZERO ON EVERY BUFFER — the timescale IS the sample rate, so
        // `ticksPerSample` is exactly 1 and a sample position is a tick by definition. A non-zero
        // here means something has put the PTS back on a foreign timescale, which is the failure
        // this whole chain ended in. It is the cheapest possible guard against a regression that is
        // otherwise audible-only.
        let ticksPerSample = Double(t.presentationTimeStamp.timescale) / sampleRate
        let ptsTicksExact = Double(cumulativeFrames) * ticksPerSample
        let gridErrorTicks = ptsTicksExact - ptsTicksExact.rounded()
        let gridErrorSamples = abs(gridErrorTicks) / ticksPerSample

        NSLog("""
        [NDI-AUDIO] ── CMSampleBuffer #%d AS BUILT ──
          numSamples        = %d   (expected %d)  %@
          dataLength        = %d   numSamples × mBytesPerFrame = %d  %@
          mBytesPerFrame    = %u · mFramesPerPacket = %u · mBytesPerPacket = %u
          timing entries    = %d  (1 = "every sample has this duration")
          duration          = %lld/%d  = %.9f s   one sample at %.0f Hz = %.9f s  %@
          PTS               = %lld/%d  = %.9f s
          decodeTS          = %@
          ── PTS GRID CHECK (the one that is not visible in seconds) ──
          timescale/rate    = %.4f ticks per audio sample (must be an integer for every PTS to land)
          cumulative frames = %lld → %.4f ticks exactly
          rounding error    = %+.4f ticks = %.4f samples  %@
        """,
              audioBuffersDumped,
              numSamples, expectedFrames,
              numSamples == expectedFrames ? "OK" : "⚠️ MISMATCH",
              dataLength, numSamples * Int(bytesPerFrame),
              dataLength == numSamples * Int(bytesPerFrame) ? "OK" : "⚠️ MISMATCH",
              bytesPerFrame, framesPerPacket, bytesPerPacket,
              timingCount,
              t.duration.value, t.duration.timescale, CMTimeGetSeconds(t.duration),
              sampleRate, 1.0 / sampleRate,
              abs(CMTimeGetSeconds(t.duration) - 1.0 / sampleRate) < 1e-12
                ? "OK — PER-SAMPLE, not the buffer total" : "⚠️ NOT the per-sample duration",
              t.presentationTimeStamp.value, t.presentationTimeStamp.timescale,
              CMTimeGetSeconds(t.presentationTimeStamp),
              CMTIME_IS_VALID(t.decodeTimeStamp) ? "valid (should be invalid)" : "invalid (correct)",
              ticksPerSample, cumulativeFrames, ptsTicksExact,
              gridErrorTicks, gridErrorSamples,
              abs(gridErrorTicks) < 1e-9
                ? "OK — lands on the grid"
                : "⚠️ OFF-GRID: this PTS was ROUNDED, so it cannot abut the previous buffer")
        #endif
    }

    /// ── PTS CONTINUITY: DOES BUFFER n+1 START WHERE BUFFER n ENDED? ──────────────────────────
    ///
    /// `AVSampleBufferAudioRenderer` schedules by PTS against the timebase, so the answer has to be
    /// YES TO THE SAMPLE. This measures the residual — `pts − (previousPTS + previousFrames/rate)` —
    /// both as computed and as QUANTISED to the 90 kHz grid the CMTime actually carries, because the
    /// quantisation is part of what the renderer sees.
    ///
    /// Positive = a GAP (silence the renderer must fill). Negative = an OVERLAP (samples it must
    /// drop). Either, repeated at the pull rate, is continuous distortion rather than a click.
    ///
    /// ⚠️ KEPT AFTER THE FIX, AND IT SHOULD NOW READ EXACTLY ZERO. With `audioPTS` counting samples
    /// the residual is zero BY CONSTRUCTION — `pts` is `anchor + cumulative/rate` and the next one
    /// adds exactly `frames/rate`, so the arithmetic cannot produce anything else. That is precisely
    /// why the line stays: a zero is cheap to print and a NON-zero means the construction has been
    /// broken by something not yet understood, which is the case worth catching. The two readings
    /// that are legitimately non-zero are a re-pin and a format restart, each of which prints its
    /// own line in the same window, so they can be told apart from an unexplained residual.
    ///
    /// MEASURED BEFORE THE FIX, for comparison: mean |residual| 0.15–0.57 ms (7–27 samples), ~50
    /// gaps and ~40 overlaps per second, mean residual ~0.
    private func recordPTSContinuity(pts: Double, frames: Int, sampleRate: Double) {
        // DEVELOPER DIAGNOSTIC — compiled to nothing in Release. Post-fix this is zero BY
        // CONSTRUCTION (see above), so in the field it can only ever confirm arithmetic that cannot
        // have changed without a code change. It earns its place in a dev build and nowhere else.
        #if !DEBUG
        return
        #else
        defer { lastAudioPTS = pts; lastAudioFrames = frames; lastAudioRate = sampleRate }
        guard let prevPTS = lastAudioPTS, lastAudioFrames > 0, lastAudioRate > 0 else {
            ptsWindowStart = pts
            return
        }
        let expected = prevPTS + Double(lastAudioFrames) / lastAudioRate
        let residual = pts - expected
        // What the renderer really receives: both ends rounded to 1/90000 s.
        let qActual = (pts * 90_000).rounded() / 90_000
        let qExpected = (expected * 90_000).rounded() / 90_000
        let qResidual = qActual - qExpected

        ptsSamples += 1
        ptsResidualSum += residual
        ptsResidualAbsSum += abs(residual)
        if residual > 0 { ptsGaps += 1 } else if residual < 0 { ptsOverlaps += 1 }
        if abs(residual) > abs(ptsWorstResidual) { ptsWorstResidual = residual }
        ptsQuantisedAbsSum += abs(qResidual)
        // In SAMPLES, which is the unit that decides whether the renderer can splice cleanly.
        let residualSamples = abs(residual) * sampleRate
        if residualSamples > ptsWorstResidualSamples { ptsWorstResidualSamples = residualSamples }

        guard pts - ptsWindowStart >= 1.0 else { return }
        let n = max(1, ptsSamples)
        NSLog("%@", String(format: "[NDI-AUDIO] PTS continuity over %d buffer(s): mean residual "
                           + "%+.3f ms · mean |residual| %.3f ms (%.1f samples) · worst %+.3f ms "
                           + "(%.1f samples) · gaps %d / overlaps %d · mean |residual| after 90kHz "
                           + "quantisation %.3f ms — buffer n+1 should start EXACTLY where n ended",
                           ptsSamples,
                           ptsResidualSum / Double(n) * 1000,
                           ptsResidualAbsSum / Double(n) * 1000,
                           ptsResidualAbsSum / Double(n) * sampleRate,
                           ptsWorstResidual * 1000, ptsWorstResidualSamples,
                           ptsGaps, ptsOverlaps,
                           ptsQuantisedAbsSum / Double(n) * 1000))
        ptsWindowStart = pts
        ptsSamples = 0; ptsResidualSum = 0; ptsResidualAbsSum = 0; ptsQuantisedAbsSum = 0
        ptsGaps = 0; ptsOverlaps = 0; ptsWorstResidual = 0; ptsWorstResidualSamples = 0
        #endif
    }

    /// PTS-continuity state. Pump thread only; reset on `start(with:)` before the thread exists.
    private var lastAudioPTS: Double?
    private var lastAudioFrames = 0
    private var lastAudioRate = 0.0
    private var ptsWindowStart = 0.0
    private var ptsSamples = 0
    private var ptsResidualSum = 0.0
    private var ptsResidualAbsSum = 0.0
    private var ptsQuantisedAbsSum = 0.0
    private var ptsGaps = 0
    private var ptsOverlaps = 0
    private var ptsWorstResidual = 0.0
    private var ptsWorstResidualSamples = 0.0

    /// ── WHAT THE RENDERER SAYS ABOUT ITSELF, WHICH NOTHING HAS EVER ASKED ────────────────────
    ///
    /// ⚠️ THE LIVE PATH PUSHES UNCONDITIONALLY AND ALWAYS HAS. `LiveAudioSink.enqueue` is
    /// `tap.ingest` then `renderer.enqueue`, with no `isReadyForMoreMediaData` test and no
    /// `requestMediaDataWhenReady` pump. EVERY FILE PATH IN THIS APP DOES THE OPPOSITE —
    /// `LibavAudioSource`, `FileFrameSource`, `LibavFrameSource` and `FrameEngine.beginAudioReading`
    /// each drive a `requestMediaDataWhenReady` + `while isReadyForMoreMediaData` loop. So the one
    /// class of failure that is structurally invisible here is the renderer refusing or failing,
    /// and it would present exactly as "the audio is wrong" with every upstream counter clean.
    ///
    /// ⚠️ AND IT BITES NDI HARDER THAN WHEP EVEN THOUGH BOTH USE THE SAME SINK: NDI pushes at
    /// ~92 Hz in 480..530-sample buffers, WHEP at 50 Hz in fixed 960s. Same samples per second,
    /// nearly twice the number of enqueue calls.
    ///
    /// Counted continuously, reported once a second — `notReady` is the number of pushes made while
    /// the renderer had said it did not want more, which is the count that distinguishes "the
    /// renderer is refusing us" from every other hypothesis.
    private var rendererPushes = 0
    private var rendererNotReadyPushes = 0
    private var rendererLastReport = 0.0
    private var rendererSawFailure = false
    /// Latched by `noteRendererPush` so the 1 Hz line has a value even on a pull that produced no
    /// buffer — stale is informative, absent is not.
    private var rendererLastNewestPTS = Double.nan
    /// Set by `cycleDesktopAudioLead` so every rung gets a reading IMMEDIATELY rather than up to a
    /// second later — the ladder is stepped by hand and a missing first line is what made the last
    /// run unreadable.
    private var rendererForceReport = false

    /// Per-push bookkeeping. CHEAP and unconditional — one property read and two increments.
    private func noteRendererPush(newestPTS: Double) {
        guard let read = liveAudioRendererState else { return }
        let st = read()
        rendererPushes += 1
        rendererLastNewestPTS = newestPTS
        if !st.isReadyForMoreMediaData { rendererNotReadyPushes += 1 }
        // A failure is stated the INSTANT it appears — it explains everything downstream of it.
        if st.statusRawValue == 2, !rendererSawFailure {
            rendererSawFailure = true
            NSLog("[NDI-AUDIO] ⚠️⚠️ AUDIO RENDERER STATUS = FAILED — %@. Nothing on the live path "
                + "reads this, so it would otherwise present only as bad audio.",
                  st.errorDescription ?? "no NSError supplied")
        }
    }

    /// ── ⚠️ CALLED FROM THE PUMP LOOP, NOT FROM INSIDE `push`, AND THAT IS THE BUG FIX ─────────
    ///
    /// This reporting used to live at the bottom of the `push` closure, which sits behind
    /// `if let sink`, behind `guard let sb = makeAudioSampleBuffer(...) else { return }`, and — in
    /// WHEP-shaped mode — behind "a group happened to complete this tick". **Any one of those
    /// declining silently took the instrumentation with it**, which is exactly what happened: five
    /// lines, all at 40 ms, then nothing, so the ladder ran with no reading at any clean rung and
    /// the correlation between `sufficientForStart` and audible cleanliness stayed unmeasured.
    ///
    /// It now runs from the pump loop itself, once per pull, outside every one of those guards. The
    /// only thing it needs from the push path is the newest PTS, which is latched by
    /// `noteRendererPush` and simply goes stale (not absent) if a pull produced no buffer.
    ///
    /// ⚠️ AND IT IS STRING INTERPOLATION, NOT `String(format:)`. The old line mixed `%@`, `%d` with
    /// 64-bit `Int`, `%.4f` with `Float` and `%.0f` with `Double` in one variadic call. The `%@`
    /// fields came first so `sufficientForStart` was trustworthy, but everything after the first
    /// `%d` depended on vararg slot alignment that is not worth relying on. Interpolation is
    /// type-checked and cannot silently shift a field.
    ///
    /// **A DIAGNOSTIC THAT CAN BE SUPPRESSED BY THE THING IT IS DIAGNOSING IS NOT A DIAGNOSTIC.**
    /// That is the third time this evening an instrument reported cleanly while the thing under it
    /// was broken — after `recordPTSContinuity` measuring Doubles and the meters metering
    /// synthesised audio.
    private func reportRendererStateIfDue(now: Double) {
        guard let read = liveAudioRendererState else { return }
        toneLock.lock()
        let lead = desktopAudioLead
        let forced = rendererForceReport
        rendererForceReport = false
        toneLock.unlock()

        guard forced || now - rendererLastReport >= 1.0 else { return }
        rendererLastReport = now
        let st = read()
        let pushes = rendererPushes, notReady = rendererNotReadyPushes
        rendererPushes = 0; rendererNotReadyPushes = 0

        // Queue depth as the renderer sees it: how far the newest stamped sample is ahead of the
        // timebase. This is the number the lead is supposed to hold, MEASURED rather than assumed.
        let queueMs = rendererLastNewestPTS.isFinite
            ? (rendererLastNewestPTS - st.timebaseSeconds) * 1000 : Double.nan
        let err = st.errorDescription.map { " (\($0))" } ?? ""
        let q = queueMs.isFinite ? String(format: "%+.1f", queueMs) : "n/a"
        NSLog("[NDI-AUDIO] renderer: lead=\(Int((lead * 1000).rounded()))ms · "
            + "sufficientForStart=\(st.hasSufficientMediaDataForReliablePlaybackStart ? "YES" : "NO") "
            + "· status=\(st.statusLabel)\(err) · ready=\(st.isReadyForMoreMediaData ? "YES" : "NO") "
            + "· pushes=\(pushes) (of which \(notReady) while NOT ready) "
            + "· syncRate=\(String(format: "%.4f", st.synchronizerRate)) "
            + "· queue=newestPTS−timebase=\(q) ms"
            + (forced ? "  ← first reading at this lead" : ""))
    }

    /// ── THE CLOSED LOOP, ON THE PUMP THREAD ──────────────────────────────────────────────────
    ///
    /// Compare the ACTUAL timebase against where it is supposed to be and re-anchor past the
    /// tolerance. Both readings are taken as close together as they can be, because the quantity
    /// being measured is the difference between the two clocks they each run on.
    ///
    /// ⚠️ THIS IS THE ONE THING IN THE LIVE-AUDIO PATH THAT IS ACTUALLY CLOSED. `mirrorLiveAudio`'s
    /// gate computes its `predicted` from what it last pushed plus host time — both mach-axis — so
    /// it is blind to the audio device crystal by construction, and WHEP and SRT are corrected only
    /// incidentally, by LiveClock's video-depth slew forcing absolute re-anchors. NDI has no slew,
    /// so nothing would correct it. Reading `currentSyncTime()` is what closes it, and it is why
    /// this is a loop rather than a one-shot anchor. See docs/BUGS.md, "NDI has no desktop playback
    /// path at all", and the slew-site note in LiveClock.
    ///
    /// ── ⚠️ A SAMPLE-COUNTED PTS AXIS DOES NOT MAKE THIS REDUNDANT. IT MAKES IT NECESSARY. ────
    ///
    /// A reader arriving from `audioPTS` will reasonably think the problem is solved: if the PTS is
    /// a running sample count, it is exact, so what is there to correct? The answer is that it is
    /// exact ON ITS OWN AXIS, and that axis is **frames ÷ the sender's nominal rate**, pinned to
    /// mach time. The timebase it is being played against advances on the AUDIO DEVICE's crystal
    /// (`AVSampleBufferRenderSynchronizer.h`: the timebase is driven by an added audio renderer's
    /// clock). Two independent oscillators, so 48000 counted samples and 48000 device samples are
    /// not the same duration — they differ by the crystal offset, measured at −7.8 ppm on one
    /// machine by the HLS work, and that is a PROPERTY OF THE OUTPUT DEVICE, not a constant.
    ///
    /// So the sample axis makes buffers tile perfectly against EACH OTHER and drifts, as a block,
    /// against the clock they are played on. Nothing about counting samples can fix that; only
    /// measuring the device clock can, and `currentSyncTime()` is the only reading in the system
    /// taken on it. **The two mechanisms address different seams and both are load-bearing:
    /// `audioPTS` removes the per-buffer splice, this removes the accumulating block offset.**
    ///
    /// ⚠️ IT COMPARES AGAINST THE SAMPLE AXIS, NOT THE WALL CLOCK, and that changed with the fix.
    /// The buffers are stamped on the sample axis, so that is the axis the timebase has to agree
    /// with; measuring against the wall clock would be measuring against something no buffer
    /// carries. `audioPTS` keeps the sample axis pinned to the wall clock separately, so the two
    /// corrections compose instead of fighting.
    private func serviceDesktopAudioAnchor(mediaNow: Double, wallNow: Double) {
        guard let anchor = anchorLiveAudio else { return }
        // The lead is runtime-adjustable (Debug ▸ Desktop Audio Lead), so it is read per call rather
        // than captured — and a change forces the first-anchor branch below, which is the whole of
        // "re-anchor cleanly instead of reconnecting".
        toneLock.lock()
        let lead = desktopAudioLead
        let leadChanged = desktopAudioLeadChanged
        desktopAudioLeadChanged = false
        toneLock.unlock()

        // FIRST ANCHOR. `beginLiveAudio` parks the synchronizer at rate 0 and holds it there until
        // something anchors the timebase, so without this NDI would be silent, not merely drifting.
        guard anchoredDesktopAudio, !leadChanged else {
            anchor(mediaNow - lead, wallNow)
            anchoredDesktopAudio = true
            lastAnchorCheck = wallNow
            lastAnchorHost = wallNow
            anchorCount = 1
            NSLog("%@", String(format: "[NDI-AUDIO] desktop timebase anchored %.0f ms behind the "
                               + "pull clock — closed loop armed (tolerance %.1f ms, checked every "
                               + "%.1f s)",
                               lead * 1000,
                               Self.desktopAudioAnchorTolerance * 1000,
                               Self.desktopAudioCheckInterval))
            return
        }
        guard wallNow - lastAnchorCheck >= Self.desktopAudioCheckInterval else { return }
        lastAnchorCheck = wallNow
        guard let readTimebase = liveAudioTimebase else { return }
        let timebase = readTimebase()
        guard timebase.isFinite else { return }

        // Where the timebase SHOULD read, given the axis the buffers are actually stamped on.
        let expected = mediaNow - lead
        let offset = timebase - expected
        guard abs(offset) > Self.desktopAudioAnchorTolerance else { return }

        let sinceLast = wallNow - lastAnchorHost
        anchor(expected, wallNow)
        anchorCount += 1
        lastAnchorHost = wallNow
        // ⚠️ THE INTERVAL IS THE POINT OF THIS LINE, NOT THE OFFSET. The offset is always ~the
        // tolerance by construction — that is what tripped it. How LONG it took to get there is the
        // measurement: it is this machine's two crystals, in ppm, and it is the number that differs
        // between machines. A pair further apart shows up as a shorter interval instead of silently.
        let ppm = sinceLast > 0 ? offset / sinceLast * 1e6 : 0
        NSLog("%@", String(format: "[NDI-AUDIO] desktop timebase RE-ANCHORED — offset %+.2f ms past "
                           + "a %.1f ms tolerance after %.1f s (%.1f ppm between the audio device "
                           + "clock and mach time on this machine) · re-anchor #%d",
                           offset * 1000, Self.desktopAudioAnchorTolerance * 1000,
                           sinceLast, ppm, anchorCount))
    }

    private func startAudioPump(_ bridge: NDIBridge) {
        audioRunLock.lock(); audioShouldRun = true; audioRunLock.unlock()
        let done = DispatchSemaphore(value: 0)
        audioThreadFinished = done
        let thread = Thread { [weak self] in self?.runAudioPump(bridge, finished: done) }
        thread.name = "com.manifold.ndi.audio"
        thread.qualityOfService = .userInteractive   // keep the audio drain off the low-priority pile
        audioThread = thread
        thread.start()
    }

    /// The pump loop. PACING — this is the load-bearing part, so it is explicit:
    ///
    /// Each wake we ask FrameSync for the audio that has ELAPSED since the previous pull — the
    /// bridge measures that itself and turns it into `elapsed * sampleRate`, carrying the
    /// sub-sample remainder — and then sleep whatever is left of `pollInterval` after the work.
    ///
    /// ⚠️ THE SLEEP IS CORRECTED FOR WORK TIME, AND THAT IS TIDINESS, NOT THE FIX. `Thread.sleep`
    /// used to sit unconditionally at the bottom of the loop, making the true period
    /// `pollInterval + pull + convert` ≈ 10.9 ms while the request assumed 10 ms — an 8.3% deficit
    /// (measured `cum=44030Hz`). Subtracting the work makes the period genuinely ~10 ms, but it
    /// CANNOT be relied on alone: the sleep cannot go negative, so any hiccup that pushes work past
    /// the interval reintroduces exactly the same deficit. The elapsed-derived count is the robust
    /// half and holds at any period; this just keeps the period close to what was intended.
    ///
    /// ⚠️ THE PREVIOUS MODEL WAS THE INVERSE OF THIS AND IT WAS WRONG. It drained
    /// `framesync_audio_queue_depth` each wake, on the theory that pulling "whatever accumulated"
    /// self-corrects to the production rate. `no_samples` is not a ceiling — it is a statement
    /// about the consumer's clock, which FrameSync satisfies by manufacturing samples. Asking for
    /// the backlog announced a consumer running at up to 480 kHz, and measured 8.1M samples
    /// delivered against 1.44M sent. Do not reintroduce a per-pull size that varies with anything.
    /// See BUGS.md #NDI-AUDIO and the contract note on `captureAudioFrameForInterval:`.
    ///
    /// AUDIO PTS — stamped `monotonicNow()` at pull time, the SAME free-running clock the video tick
    /// stamps frames with (NOT the NDI frame's sender-clock timestamp). The tap→DeckLink read aligns
    /// audio to video by that source PTS, so both must live on one clock. The pump and the video tick
    /// now read that clock at DIFFERENT moments, but both label "real-time-now" samples/frames with
    /// "now", so the pair still lands together on the wire within the poll interval — a small constant
    /// offset, not drift (FrameSync keeps the underlying A/V timing coherent).
    private func runAudioPump(_ bridge: NDIBridge, finished: DispatchSemaphore) {
        let pollInterval = 0.010   // 100 Hz poll — steady, well below any busy-spin, keeps `held` tiny
        #if DEBUG
        var trace = AudioPushTrace()
        #endif
        while true {
            audioRunLock.lock(); let run = audioShouldRun; audioRunLock.unlock()
            if !run { break }
            let cycleStart = Self.monotonicNow()
            autoreleasepool {
                // Convert happens INSIDE the bridge, OUTSIDE the tap lock; only the finished Int32
                // buffer is copied into the ring under the lock (see AudioTapBuffer.append).
                if let audio = bridge.captureAudioFrame(forInterval: pollInterval) {
                    // Stamped ONCE into a local so the trace below reports the value the ring
                    // actually received, not a second, later reading of the same clock.
                    let wallNow = Self.monotonicNow()
                    // ⚠️ NOT `wallNow` — THE PTS IS THE RUNNING SAMPLE COUNT. A per-pull clock read
                    // here is what made the desktop distort; see `audioPTS`. `wallNow` still pins
                    // that axis and still drives the timebase loop, and the tap gets the same
                    // stamped buffer either way.
                    let ptsTicks = audioPTSTicks(forFrames: Int(audio.frameCount),
                                                 sampleRate: Double(audio.sampleRate),
                                                 channels: Int(audio.channelCount),
                                                 wallNow: wallNow)
                    // Seconds are derived FROM the ticks, never the other way round — the two loops
                    // below and the continuity trace want a Double; the buffer never does.
                    let pts = Double(ptsTicks) / Double(audio.sampleRate)
                    // ── ONE ROUTE OR THE OTHER, NEVER BOTH ──────────────────────────────────
                    //
                    // `LiveAudioSink.enqueue` tees to the tap AND the renderer, so pushing to the
                    // tap here as well would double-feed the ring: every sample written twice, the
                    // PTS axis advancing at half the sample axis, and `append`'s 50 ms disagreement
                    // check wiping the window on a loop. The tap push below is the FALLBACK for an
                    // unwired seam, not a companion to the sink.
                    //
                    // The fallback is kept rather than refused (WHEP just logs and gives up) because
                    // NDI's tap feed is not only the desktop: it is the meters and the SDI embed,
                    // both of which worked before this change and must not regress to silence
                    // because a renderer could not be opened.
                    if let sink = liveAudioSink {
                        // The timebase must be anchored BEFORE the first buffer is due, not after:
                        // `beginLiveAudio` holds the synchronizer at rate 0, and a buffer enqueued
                        // against a stopped timebase simply waits.
                        serviceDesktopAudioAnchor(mediaNow: pts, wallNow: wallNow)
                        recordPTSContinuity(pts: pts, frames: Int(audio.frameCount),
                                            sampleRate: Double(audio.sampleRate))

                        let rate = Double(audio.sampleRate)
                        let ch = Int(audio.channelCount)
                        let src = toneOrRealSamples(audio)
                        // One closure, used by both shapes, so the ONLY difference between them is
                        // how the samples are packaged — same construction, same capture, same dump,
                        // same sink.
                        let push: (Int64, Int, UnsafePointer<Int32>) -> Void = { ticks, n, data in
                            guard let sb = self.makeAudioSampleBuffer(data, frames: n, channels: ch,
                                                                      sampleRate: rate,
                                                                      ptsTicks: ticks) else { return }
                            #if DEBUG
                            // AT THE ENQUEUE POINT, on the finished buffer — the same object, the
                            // same bytes, the same instant as the renderer receives them.
                            self.captureEnqueuedAudio(sb, sampleRate: rate, channels: ch)
                            #endif
                            self.dumpSampleBuffer(sb, expectedFrames: n, channels: ch,
                                                  sampleRate: rate,
                                                  cumulativeFrames: ticks - (self.audioAnchorTicks ?? 0))
                            self.noteRendererPush(newestPTS: Double(ticks + Int64(n)) / rate)
                            sink.enqueue(sb)
                        }

                        #if DEBUG
                        toneLock.lock(); let grouped = groupedMode; toneLock.unlock()
                        if grouped != groupedModeOnPump {
                            // Mode changed: the partial group describes the OTHER shape. Dropped HERE,
                            // on the thread that owns the accumulator, never from main.
                            groupedModeOnPump = grouped
                            groupHeldFrames = 0
                        }
                        if grouped {
                            regroup(src, frames: Int(audio.frameCount), channels: ch,
                                    startTicks: ptsTicks, emit: push)
                        } else {
                            push(ptsTicks, Int(audio.frameCount), src)
                        }
                        #else
                        push(ptsTicks, Int(audio.frameCount), src)
                        #endif
                    } else if let tap = audioTap {
                        tap.pushInterleavedInt32(audio.samples,
                                                 frameCount: Int(audio.frameCount),
                                                 channelCount: Int(audio.channelCount),
                                                 sampleRate: Double(audio.sampleRate),
                                                 pts: pts,
                                                 path: .ndi)
                    }
                    #if DEBUG
                    trace.record(pts: pts,
                                 frames: Int(audio.frameCount),
                                 sampleRate: Double(audio.sampleRate),
                                 senderTimestamp: audio.timestamp,
                                 queueDepth: Int(audio.queueDepthAtPull))
                    #endif
                }
            }
            // Sleep only the remainder of the interval. No floor and no minimum: if the work ever
            // exceeds `pollInterval` the loop simply runs at whatever rate the work allows, which
            // is not a busy-spin (the work dominates) and which the elapsed-derived request sizes
            // correctly anyway.
            // ⚠️ OUTSIDE the `if let audio` / `if let sink` / `guard let sb` chain above, and
            // outside `autoreleasepool` — once per pull, unconditionally, so nothing downstream can
            // silence it. See the note on `reportRendererStateIfDue`.
            if liveAudioSink != nil { reportRendererStateIfDue(now: Self.monotonicNow()) }

            let workElapsed = Self.monotonicNow() - cycleStart
            if workElapsed < pollInterval {
                Thread.sleep(forTimeInterval: pollInterval - workElapsed)
            }
        }
        finished.signal()   // release the join in stopAudioPump()
    }

    /// Signal the pump to stop and BLOCK until it has actually exited — the join guarantees no pull is
    /// in flight against the framesync instance when the caller (disconnect) destroys it. Idempotent:
    /// a no-op if the pump was never started. Bounded wait (≤ one poll interval + one pull).
    private func stopAudioPump() {
        guard audioThread != nil else { return }
        audioRunLock.lock(); audioShouldRun = false; audioRunLock.unlock()
        audioThreadFinished?.wait()
        audioThreadFinished = nil
        audioThread = nil
    }

    #if DEBUG
    /// PUSH TRACE (dev diagnostic, DEBUG builds only — Debug and Profile define DEBUG=1 for the app
    /// target; see project.yml). It answers the one question the `AudioTap[NDI]` line cannot:
    ///
    ///   Does the PTS stamped on each push advance in step with the SAMPLE COUNT that push carries?
    ///
    /// It must, because those are the ring's two independent notions of time and it silently
    /// reconciles them. `runAudioPump` stamps `monotonicNow()` — WHEN WE ASKED — while the ring
    /// advances its own clock by `framesWritten / sampleRate` — WHAT WE DELIVERED. `append` compares
    /// the two on every push and, past a 50 ms disagreement, DROPS THE ENTIRE WINDOW and re-anchors
    /// (AudioTapBuffer.swift:343-352). Nothing downstream reports that it happened: the periodic
    /// `AudioTap[NDI]` line prints `held≈` AFTER the wipe, so a ring that was just emptied still
    /// reads plausible, and DeckLink's `logPeriodic` only ever runs on the success path
    /// (DeckLinkBridge.mm:600), so a run that underran on 99 % of callbacks reports its 1 % as if it
    /// were the whole picture.
    ///
    /// So this mirrors the ring's anchor arithmetic EXACTLY — same expression, same tolerance, same
    /// pre-append ordering — and prints what the ring never says out loud: the per-push deviation
    /// and the re-anchor count. `implied` (frames ÷ Δpts) is the instantaneous rate and is EXPECTED
    /// to be a little noisy: the pull size is now fixed, but the poll is a sleeping thread, so the
    /// interval it divides by jitters. `cum` (total frames ÷ total elapsed) is the steady figure: if
    /// THAT is not ~48000 and flat, the two axes genuinely diverge and every re-anchor follows.
    ///
    /// ── `sndR` IS THE AUTHENTICITY COLUMN, AND IT IS THE ONE THAT CANNOT BE FAKED ─────────────
    ///
    /// Everything above is our own bookkeeping: it says whether the samples arrive at the right
    /// RATE, not whether they are the samples the source sent. FrameSync will manufacture audio to
    /// satisfy an over-large request, and `cum` reads a perfect 48000 either way, because we are
    /// dividing OUR sample count by OUR clock and both are consistent with a lie.
    ///
    /// `sndΔ` is the advance in NDI's sender-submit timestamp between consecutive pulls, and
    /// `sndR` = frames ÷ sndΔ is the rate implied by the SENDER's clock. That number comes from
    /// outside this process and FrameSync cannot invent it. Authentic audio reads ~48000. Audio
    /// stretched k× reads 48000 ÷ k; the old defect would have read ~8500. `sndR=n/a` means the
    /// sender supplies no timestamp (`NDIlib_recv_timestamp_undefined`), which is legal and leaves
    /// the question genuinely unanswerable rather than answered optimistically.
    ///
    /// `depth` is `framesync_audio_queue_depth` at the moment of the pull — the SDK side of the
    /// seam, carried for diagnosis only and used to size nothing. Low and flat means FrameSync is
    /// consuming what it hands us; a sawtooth climbing toward the request is the old failure.
    ///
    /// Volume: every push verbatim for the first `burst` (~2 s at the 100 Hz poll — long enough to
    /// see the chunk pattern), then one aggregate line per second carrying the range of every
    /// quantity plus the re-anchors since the last line, so throttling loses no evidence. Printed on
    /// the pump thread, which is exactly where the timing being measured lives — raise `burst` only
    /// as far as the print cost stays below the 10 ms poll.
    private struct AudioPushTrace {
        /// Pushes printed verbatim before falling back to the 1 Hz aggregate.
        static let burst = 200
        /// `AudioTapBuffer.discontinuityToleranceSeconds` — mirrored, not shared: the ring's copy is
        /// private, and a trace that drifted from it would report the wrong verdict convincingly.
        static let reanchorTolerance = 0.050

        /// `NDIlib_recv_timestamp_undefined` (Processing.NDI.structs.h:183) — the sender declined to
        /// stamp.
        static let senderTimestampUndefined = Int64.max
        /// Largest sender-clock gap accepted between consecutive pulls. Anything beyond this is not
        /// a slow pull, it is a corrupt endpoint (see `senderSeconds`), and it is discarded rather
        /// than averaged in.
        static let senderDeltaCeiling = 1.0
        /// NDI timestamps are in 100 ns units.
        static let senderTicksPerSecond = 10_000_000.0

        // Session totals.
        private var pushes = 0
        private var totalFrames = 0
        private var firstPTS = Double.nan
        private var lastPTS = Double.nan
        private var lastSenderTimestamp = Int64.max
        private var reanchors = 0

        // Mirror of the ring's anchor state (AudioTapBuffer's `basePTS` / `framesWritten`).
        private var sampleRate: Double = 0
        private var basePTS = Double.nan
        private var framesWritten = 0

        // Accumulated since the last printed line, so the 1 Hz throttle drops no extremes.
        private var windowStartPTS = Double.nan
        private var windowPushes = 0
        private var windowReanchors = 0
        private var devMin = Double.infinity, devMax = -Double.infinity
        private var deltaMin = Double.infinity, deltaMax = -Double.infinity
        private var framesMin = Int.max, framesMax = 0
        private var depthMin = Int.max, depthMax = 0
        /// Sender-clock rate accumulated over the window, so the aggregate line reports the ratio
        /// over a second rather than one jittery pull's worth of it.
        private var windowSenderSeconds = 0.0
        private var windowSenderFrames = 0
        /// Pulls whose sender stamp was unusable. PRINTED, not swallowed: `sndR` computed over a
        /// third of the window is a different claim from `sndR` over all of it, and the reader is
        /// entitled to know which one they are looking at.
        private var windowSenderDropped = 0

        /// Usable = strictly positive and not the SDK's "no timestamp" sentinel. See the note in
        /// `record` for why zero has to be excluded explicitly.
        static func isUsableSenderTimestamp(_ ts: Int64) -> Bool {
            ts > 0 && ts != senderTimestampUndefined
        }

        mutating func record(pts: Double, frames: Int, sampleRate rate: Double,
                             senderTimestamp: Int64, queueDepth: Int) {
            guard pts.isFinite, frames > 0, rate > 0 else { return }
            pushes += 1
            windowPushes += 1

            // A rate change resizes the ring and zeroes its anchor (`shapeChanged`,
            // AudioTapBuffer.swift:307-313) — mirror that so the deviation stays comparable.
            if rate != sampleRate { sampleRate = rate; basePTS = .nan; framesWritten = 0 }

            // ── THE RING'S OWN TEST, EVALUATED HERE ────────────────────────────────────────
            // Ordering matters: `append` compares BEFORE counting this chunk, so `expected` is the
            // time the ring believes this chunk's FIRST sample carries.
            var deviation = 0.0
            var reanchored = false
            if basePTS.isNaN {
                basePTS = pts
            } else {
                deviation = pts - (basePTS + Double(framesWritten) / rate)
                if abs(deviation) > Self.reanchorTolerance {
                    reanchors += 1
                    windowReanchors += 1
                    reanchored = true
                    framesWritten = 0
                    basePTS = pts
                }
            }
            framesWritten += frames

            let delta = lastPTS.isNaN ? Double.nan : pts - lastPTS
            lastPTS = pts
            if firstPTS.isNaN { firstPTS = pts; windowStartPTS = pts }
            totalFrames += frames

            let implied = (delta.isFinite && delta > 0) ? Double(frames) / delta : Double.nan
            let elapsed = pts - firstPTS
            let cumulative = elapsed > 0 ? Double(totalFrames) / elapsed : Double.nan

            // SENDER CLOCK. Δ between consecutive pulls, in seconds; `sndR` is frames ÷ that.
            //
            // ⚠️ BOTH ENDPOINTS MUST BE PLAUSIBLE, AND "PLAUSIBLE" IS NOT JUST "NOT THE SENTINEL".
            // This originally excluded only `NDIlib_recv_timestamp_undefined` (INT64_MAX), which
            // missed the case that actually happened: a pull whose timestamp comes back ZERO. We
            // `memset` the frame struct, so a frame FrameSync does not stamp reads 0 rather than
            // the sentinel. Zero then poisons the NEXT difference, which is measured against it and
            // comes out as the whole Unix epoch — ~1.7e9 seconds. One of those in a window drove
            // `windowSenderSeconds` to ~1e9 and printed the aggregate as `sndR=0.0Hz` while every
            // per-push line still read a correct 48000 Hz. That is the defect being fixed here, and
            // it is worth the paragraph because the symptom accused the FORMAT STRING, which was
            // fine: a single bad sample in a mean is invisible until the mean is the only thing
            // anyone reads.
            //
            // So: a usable stamp is strictly positive and not the sentinel, the difference must be
            // forward, and the gap must be smaller than `senderDeltaCeiling`. Anything else is
            // dropped from BOTH the per-push line and the window mean rather than averaged in.
            var senderDelta = Double.nan
            if Self.isUsableSenderTimestamp(senderTimestamp),
               Self.isUsableSenderTimestamp(lastSenderTimestamp) {
                let ticks = senderTimestamp - lastSenderTimestamp
                if ticks > 0 {
                    let seconds = Double(ticks) / Self.senderTicksPerSecond
                    if seconds <= Self.senderDeltaCeiling { senderDelta = seconds }
                }
            }
            lastSenderTimestamp = senderTimestamp
            let senderRate = senderDelta.isFinite ? Double(frames) / senderDelta : Double.nan
            if senderDelta.isFinite {
                windowSenderSeconds += senderDelta
                windowSenderFrames += frames
            } else {
                windowSenderDropped += 1
            }

            devMin = min(devMin, deviation); devMax = max(devMax, deviation)
            if delta.isFinite { deltaMin = min(deltaMin, delta); deltaMax = max(deltaMax, delta) }
            framesMin = min(framesMin, frames); framesMax = max(framesMax, frames)
            depthMin = min(depthMin, queueDepth); depthMax = max(depthMax, queueDepth)

            if pushes <= Self.burst {
                print(String(format:
                    "[NDI-AUDIO] push #%d · pts=%.6fs · \u{0394}=%.2fms · n=%df · implied=%.0fHz · "
                    + "cum=%.1fHz · snd\u{0394}=%@ sndR=%@ · depth=%df · dev=%+.2fms%@",
                    pushes, pts, delta * 1000.0, frames, implied, cumulative,
                    senderDelta.isFinite ? String(format: "%.2fms", senderDelta * 1000.0) : "n/a",
                    senderRate.isFinite ? String(format: "%.0fHz", senderRate) : "n/a",
                    queueDepth, deviation * 1000.0,
                    reanchored ? "  !! RING RE-ANCHORED (window dropped)" : ""))
                return
            }
            guard pts - windowStartPTS >= 1.0 else { return }
            // Sender rate over the WHOLE window, not one pull: a per-pull ratio is quantised by the
            // sender's own packetisation and reads noisy even when it is exactly right.
            let windowSenderRate = windowSenderSeconds > 0
                ? Double(windowSenderFrames) / windowSenderSeconds : Double.nan
            // `sndR` carries how many pulls it was computed over when any were dropped, so a mean
            // taken over a fraction of the window can never be read as a mean over all of it.
            let sndR: String
            if windowSenderRate.isFinite {
                let scope = windowSenderDropped > 0
                    ? " (\(windowPushes - windowSenderDropped)/\(windowPushes) pulls)" : ""
                sndR = String(format: "%.1fHz", windowSenderRate) + scope
            } else {
                sndR = "n/a (no usable sender stamp in \(windowPushes) pulls)"
            }
            print(String(format:
                "[NDI-AUDIO] pushes=%d (+%d in %.2fs) · n=[%d..%d]f · \u{0394}=[%.2f..%.2f]ms · "
                + "cum=%.1fHz over %.1fs · sndR=%@ · depth=[%d..%d]f · dev=[%+.2f..%+.2f]ms · "
                + "re-anchors=+%d (total %d)",
                pushes, windowPushes, pts - windowStartPTS, framesMin, framesMax,
                deltaMin * 1000.0, deltaMax * 1000.0, cumulative, elapsed, sndR,
                depthMin == .max ? 0 : depthMin, depthMax,
                devMin * 1000.0, devMax * 1000.0, windowReanchors, reanchors))
            windowStartPTS = pts; windowPushes = 0; windowReanchors = 0
            devMin = .infinity; devMax = -.infinity
            deltaMin = .infinity; deltaMax = -.infinity
            framesMin = .max; framesMax = 0
            depthMin = .max; depthMax = 0
            windowSenderSeconds = 0; windowSenderFrames = 0; windowSenderDropped = 0
        }
    }
    #endif

    // MARK: - Colorimetry (CVDisplayLink thread)

    /// The EFFECTIVE colorimetry to tag this frame with: what the stream declared (or the assumed
    /// default), resolved against the user's override.
    ///
    /// Two stages, and they are cached differently ON PURPOSE. The PARSE is cached on the raw
    /// metadata string, so a stable stream parses once and every later frame costs one string
    /// compare. The RESOLVE is not cached at all — it re-reads the override mirror every frame,
    /// which is what lets a picker change on the main thread reach the tagging path without any
    /// signalling between them: the very next frame off the wire simply resolves differently.
    ///
    /// Whatever the reason it moved — a genuine mid-stream re-declaration, or the user asserting a
    /// preset — a change lands in the same place: re-tag the buffers, re-point the layer colorspace
    /// and the EDR opt-in, republish the model. The receive path does not care which it was, and
    /// that is exactly why the override needed no new machinery.
    private func effectiveColorInfo(forFrameMetadata xml: String?) -> NDIColorInfo {
        if !hasParsedColorInfo || xml != lastMetadataXML {
            hasParsedColorInfo = true
            lastMetadataXML = xml
            parsedColorInfo = NDIColorInfo.parse(metadataXML: xml)
        }
        let declared = parsedColorInfo
        let effective = NDIColorInfo.resolve(declared: declared, override: currentOverride())

        let first = !reportedColorInfo
        guard effective != activeColorInfo || first else { return activeColorInfo }
        let previous = activeColorInfo
        activeColorInfo = effective
        reportedColorInfo = true
        verifyNextOutputTags = true   // re-verify the tags the next converted frame actually carries

        if first {
            NSLog("[NDI] color signaling %@: %@",
                  effective.isOverridden ? "(OVERRIDE — user assertion)"
                      : effective.isDeclared ? "(declared by sender)"
                                             : "(NOT declared — assuming SDR Rec.709)",
                  effective.summary)
        } else {
            NSLog("[NDI] colorimetry CHANGED (%@ → %@): %@",
                  previous.tier, effective.tier, effective.summary)
            NSLog("[NDI]                previously:       %@", previous.summary)
        }
        // What the SENDER said stays visible even while overridden — "Assumed 709, overridden to
        // 2020 PQ" and "Declared 709, overridden to 2020 PQ" are different facts about the stream,
        // and collapsing them would hide a sender that is actively lying.
        if effective.isOverridden {
            NSLog("[NDI]                stream itself says: %@", declared.summary)
        }

        // The layer colorspace + the EDR opt-in follow the CICP codes, on the main thread
        // (setSourceColorSpace runs a CATransaction). transfer 16/18 is what turns
        // wantsExtendedDynamicRangeContent on — i.e. this is where PQ-over-NDI becomes HDR,
        // whether the PQ came from the sender or from the user asserting it.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.colorInfo = effective
            self.declaredColorInfo = declared
            self.renderer?.setSourceColorSpace(primaries: effective.primaries.code,
                                               transfer: effective.transfer.code,
                                               matrix: effective.matrix.code)
        }
        return effective
    }

    /// Apply the parsed CICP tags to the VideoToolbox OUTPUT buffer, and — on the first frame and
    /// after every change — log what VT had left on that buffer next to what it carries afterwards.
    /// That before/after pair IS the verification: a "before" reading Rec.709 on a PQ source is the
    /// stamp this whole ordering exists to beat, and the "after" is what actually goes downstream.
    private func tagOutput(_ buffer: CVPixelBuffer, with info: NDIColorInfo) {
        guard verifyNextOutputTags else {
            info.apply(to: buffer)
            return
        }
        verifyNextOutputTags = false
        let before = NDIColorInfo.attachmentSummary(of: buffer)
        info.apply(to: buffer)
        NSLog("[NDI] x422 output tags — VideoToolbox left: %@", before)
        NSLog("[NDI] x422 output tags — after our tagging: %@", NDIColorInfo.attachmentSummary(of: buffer))
    }

    /// UYVY ('2vuy', 8-bit packed 4:2:2) → 'x422' (10-bit biplanar 4:2:2) — the format the
    /// existing shader path already speaks. See the type comment for why this conversion exists.
    private func convertToDisplayFormat(_ source: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        if transferSession == nil {
            var session: VTPixelTransferSession?
            let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault,
                                                      pixelTransferSessionOut: &session)
            guard status == noErr, let session else {
                NSLog("[NDI] VTPixelTransferSessionCreate failed (\(status))")
                return nil
            }
            transferSession = session
        }
        guard let transferSession else { return nil }

        if pixelBufferPool == nil || poolSize != (width, height) {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            guard status == kCVReturnSuccess, let pool else {
                NSLog("[NDI] CVPixelBufferPoolCreate failed (\(status))")
                return nil
            }
            pixelBufferPool = pool
            poolSize = (width, height)
            NSLog("[NDI] display pool: \(width)x\(height) x422 (10-bit biplanar 4:2:2)")
        }
        guard let pixelBufferPool else { return nil }

        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &destination)
                == kCVReturnSuccess, let destination else { return nil }

        let status = VTPixelTransferSessionTransferImage(transferSession, from: source, to: destination)
        guard status == noErr else {
            NSLog("[NDI] pixel transfer failed (\(status))")
            return nil
        }
        return destination
    }

    private func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer, pts: Double) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 90_000),
            decodeTimeStamp: .invalid)

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }

    /// Once a second: prove frames are LIVE, not one frozen frame. A steady rate here is the
    /// difference between "NDI connected" and "NDI is actually streaming".
    private func logFrameRate() {
        frameCount += 1
        let now = Self.monotonicNow()
        let elapsed = now - lastRateLogTime
        guard elapsed >= 1.0 else { return }
        let rate = Double(frameCount - lastRateLogCount) / elapsed
        NSLog(String(format: "[NDI] %.1f fps received (%d frames total)", rate, frameCount))
        lastRateLogTime = now
        lastRateLogCount = frameCount
    }
}
