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

    /// The single source of truth for the NDI runtime download page (Vizrt redistributable).
    /// Referenced by BOTH the "Install NDI Runtime…" menu item (ManifoldApp) and the Settings
    /// button (SettingsView) — no duplicated string literal.
    static let runtimeInstallURL = URL(string: "https://ndi.link/NDIRedistV6")!

    /// Whether the NDI runtime dylib is present and loadable. Published for the picker empty state
    /// and the Settings status row. Detection is LAZY and RELAUNCH-ONLY by design: the underlying
    /// `+[NDIBridge loadRuntime]` is `dispatch_once`, so a machine that gains the runtime mid-session
    /// won't flip this until relaunch. Set from `refreshRuntimeStatus()` and the `startDiscovery()`
    /// load. Main-thread only (SwiftUI observes it).
    @Published private(set) var runtimeAvailable: Bool = false

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
    func connectToFirstSource() {
        if let first = discoveredSources.first {
            connect(to: first)
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let connected = NDIBridge.connectToFirstSource(withTimeout: 5.0)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isConnecting = false
                guard let connected else {
                    NSLog("[NDI] no source found — is OmniScope sending on this network?")
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
    func connect(to source: NDISource) {
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
    /// Each wake we drain exactly what FrameSync has buffered SINCE THE LAST WAKE
    /// (`framesync_audio_queue_depth`, inside `captureAudioFrame`), then sleep ~`pollInterval`. That
    /// is drift-free real-time pacing WITHOUT a busy-spin, and it is the pattern the SDK documents:
    ///   • No faster than real-time: the sleep bounds how often we pull; we never spin.
    ///   • No slower / no drift: because we drain the *queue depth* (whatever accumulated during the
    ///     sleep) rather than a fixed count, the average pull rate self-corrects to the true production
    ///     rate — if a sleep runs long, the next pull is correspondingly bigger and we're back level.
    /// The sleep interval therefore sets only the GRANULARITY (and thus how small `held` stays), not
    /// the rate. At 10 ms, `held` sits around one–two NDI audio frames rather than climbing. The
    /// 4800-sample cap passed to the bridge is a pure safety ceiling for a startup/stall backlog (it
    /// bounds a single iteration's work); steady-state pulls are far below it, so it never paces.
    ///
    /// AUDIO PTS — stamped `monotonicNow()` at pull time, the SAME free-running clock the video tick
    /// stamps frames with (NOT the NDI frame's sender-clock timestamp). The tap→DeckLink read aligns
    /// audio to video by that source PTS, so both must live on one clock. The pump and the video tick
    /// now read that clock at DIFFERENT moments, but both label "real-time-now" samples/frames with
    /// "now", so the pair still lands together on the wire within the poll interval — a small constant
    /// offset, not drift (FrameSync keeps the underlying A/V timing coherent).
    private func runAudioPump(_ bridge: NDIBridge, finished: DispatchSemaphore) {
        let pollInterval = 0.010   // 100 Hz poll — steady, well below any busy-spin, keeps `held` tiny
        while true {
            audioRunLock.lock(); let run = audioShouldRun; audioRunLock.unlock()
            if !run { break }
            autoreleasepool {
                // Convert happens INSIDE the bridge, OUTSIDE the tap lock; only the finished Int32
                // buffer is copied into the ring under the lock (see AudioTapBuffer.append).
                if let tap = audioTap,
                   let audio = bridge.captureAudioFrame(forMaxSamples: 4800) {
                    tap.pushInterleavedInt32(audio.samples,
                                             frameCount: Int(audio.frameCount),
                                             channelCount: Int(audio.channelCount),
                                             sampleRate: Double(audio.sampleRate),
                                             pts: Self.monotonicNow(),
                                             path: .ndi)
                }
            }
            Thread.sleep(forTimeInterval: pollInterval)
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
