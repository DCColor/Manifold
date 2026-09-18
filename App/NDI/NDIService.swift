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
                if let tap = audioTap,
                   let audio = bridge.captureAudioFrame(forInterval: pollInterval) {
                    // Stamped ONCE into a local so the trace below reports the value the ring
                    // actually received, not a second, later reading of the same clock.
                    let pts = Self.monotonicNow()
                    tap.pushInterleavedInt32(audio.samples,
                                             frameCount: Int(audio.frameCount),
                                             channelCount: Int(audio.channelCount),
                                             sampleRate: Double(audio.sampleRate),
                                             pts: pts,
                                             path: .ndi)
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
