import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox
import QuartzCore

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

    /// True while an NDI source is connected and feeding the display.
    ///
    /// STOPGAP: the UI needs to know "is something on screen" and, until the source-switching work
    /// lands, there is no unified is-any-source-active concept — the empty state just ORs this with
    /// the engine's file state. Main-thread only (start/disconnect both run there), so it is safe
    /// for SwiftUI to observe.
    @Published private(set) var isConnected = false

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

    private var bridge: NDIBridge?
    private var transferSession: VTPixelTransferSession?
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int) = (0, 0)

    private var isConnecting = false
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

    // MARK: - Debug trigger (⌃⌥N)

    /// Discover, connect to the first source, and start pulling frames onto the display.
    /// Throwaway trigger — the real source picker comes with source switching.
    ///
    /// NDI TAKES OVER the display while active: it repoints the renderer's clock and range
    /// providers at itself. Clean file<->NDI handoff is explicitly out of scope for this step.
    func connectToFirstSource() {
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

    private func start(with connected: NDIBridge) {
        guard let renderer else { return }
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

        // Pull on the display tick: FrameSync hands us the current frame on OUR clock.
        renderer.onDisplayTick = { [weak self] in self?.pullFrame() }

        isConnected = true
        NSLog("[NDI] receiving from \"\(connected.sourceName)\" — pulling on the display tick")
    }

    func disconnect() {
        isConnected = false
        renderer?.onDisplayTick = nil
        bridge?.disconnect()
        bridge = nil
        transferSession = nil
        pixelBufferPool = nil
        poolSize = (0, 0)
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
