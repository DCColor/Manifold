//
//  WHEPVideoDecoder.swift
//  Manifold
//
//  WHEP step 3b of 4: H.264 access units → decoded CVPixelBuffers, via VideoToolbox.
//
//  ── WHY THIS IS NEW CODE AND NOT A REUSED DECODER ──────────────────────────────────────
//
//  Manifold had no VTDecompressionSession before this file. The file path decodes through
//  libav (ManifoldCore/LibavFrameSource), which is a demuxer + software decoder built around
//  seeking a container — the wrong shape for a live elementary stream with no container, no
//  seek, and parameter sets that arrive in-band and can change mid-stream. The one other
//  VideoToolbox user, NDIService, uses VTPixelTransferSession (format conversion), not
//  decompression. So this is a live-oriented decode path, deliberately separate.
//
//  ── THREADING ──────────────────────────────────────────────────────────────────────────
//
//  EVERY method here must be called on ManifoldWHEPSession.decodeQueue — the serial queue
//  the bridge hands access units off on. Nothing here locks except the stats snapshot, and
//  that is the reason: one thread owns the session, the format description, and the
//  keyframe state. The only cross-thread entry points are `snapshot()` and
//  `requestStillExport()`, both explicitly locked.
//
//  Decode is SYNCHRONOUS (no kVTDecodeFrame_EnableAsynchronousDecompression). Cloudflare
//  sends Constrained Baseline with no B-frames, so decode order == display order and there
//  is nothing for a reorder buffer to do; synchronous decode also means the serial queue
//  itself is the backpressure signal, which is what the bridge's shed-on-backlog counts.
//
//  Step 3b ends at a decoded CVPixelBuffer and a counter. Step 4 takes `onDecodedFrame`
//  and wires it to LiveClock + the renderer.
//

#if DEBUG
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

final class WHEPVideoDecoder {

    /// Counters for the 1 Hz `[WHEP-DECODE]` line. Value type: copied out under the lock.
    struct Stats {
        var accessUnitsReceived = 0
        var framesDecoded = 0
        var droppedAwaitingKeyframe = 0
        var droppedNoFormatDescription = 0
        var sampleBufferFailures = 0
        var decodeErrors = 0
        var formatDescriptionBuilds = 0
        var sessionBuilds = 0
        var awaitingKeyframe = true
        var haveFormatDescription = false
        var width = 0
        var height = 0
        var pixelFormat: OSType = 0
        var lastDecodeError: OSStatus = noErr
    }

    /// Fires on the decode queue with each decoded frame, carrying the SENDER-timeline PTS
    /// (see `presentationTime`). Step 4 attaches WHEPFrameRouter.deliver here, which promotes
    /// the buffer, maps the PTS through LiveClock and enqueues it on the renderer. The decoder
    /// itself stays display-agnostic: it does not know a renderer exists.
    var onDecodedFrame: ((CVPixelBuffer, CMTime) -> Void)?

    /// Fires on the decode queue when the decoder needs an IDR it does not have: no format
    /// description yet, or a decode error forced a resync. The client turns this into a PLI.
    var onNeedsKeyframe: (() -> Void)?

    // MARK: - Output pixel format
    //
    // x420 (10-bit 4:2:0 biplanar, video range) is REQUESTED even though the stream is 8-bit,
    // because that is the format the rest of Manifold already carries: LibavFrameSource,
    // FileFrameSource and SyntheticLiveSource all produce x420, and MetalVideoRenderer's
    // range-expansion constants live in the 10-bit domain (see the kCodeMax block in
    // PassthroughShader.metal). Its 8-bit r8/rg8 branch is documented as currently
    // unreachable and would need those constants made per-bit-depth to be correct — so
    // handing step 4 a native 420v buffer would produce a picture with cast grays and legal
    // white a few codes low, and the fix would be shader work, not decoder work.
    //
    // VideoToolbox does the 8→10 promotion in its own pipeline, which is cheaper and simpler
    // than us doing it downstream. If the session refuses it, we fall back to VT's native
    // choice and say so loudly, because that fallback has the colour consequence above.
    private static let preferredPixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    private static let rtpClockRate: Int32 = 90_000

    // MARK: - State (decode queue only)

    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private var currentSPS: Data?
    private var currentPPS: Data?
    private var awaitingKeyframe = true

    /// RTP timestamps are 32-bit, start at a random value, and wrap every ~13 hours at
    /// 90 kHz. Unwrapped into a monotonic 64-bit tick count and rebased to zero at the first
    /// frame, so PTS is sane from the start. This IS the sender timeline step 4 anchors:
    /// LiveClock pins its own origin to the first frame it sees, so the rebase costs nothing
    /// and keeps the numbers readable in a log.
    private var previousRTP: UInt32?
    private var unwrappedRTP: Int64 = 0

    // MARK: - Cross-thread state

    private let lock = NSLock()
    private var stats = Stats()
    private var exportRequested = false

    // MARK: - Lifecycle

    init() {}

    deinit {
        // Belt and braces — the client invalidates explicitly on the decode queue.
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Decode queue only. Safe to call twice.
    func invalidate() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        currentSPS = nil
        currentPPS = nil
        awaitingKeyframe = true
    }

    /// Main thread. The next decoded frame is written to a PNG.
    func requestStillExport() {
        lock.lock(); exportRequested = true; lock.unlock()
        NSLog("[WHEP-DECODE] still export armed — the next decoded frame will be written to disk")
    }

    /// Any thread.
    func snapshot() -> Stats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    // MARK: - Decode entry point (decode queue only)

    func decode(accessUnit: Data,
                sps: Data?,
                pps: Data?,
                parameterSetsChanged: Bool,
                keyframe: Bool,
                rtpTimestamp: UInt32) {

        mutateStats { $0.accessUnitsReceived += 1 }

        // (1) In-band parameter sets → format description, rebuilt only on a real change.
        updateFormatDescriptionIfNeeded(sps: sps, pps: pps, changed: parameterSetsChanged)

        guard let formatDescription, let session else {
            // No SPS/PPS yet. Normal for the first few packets of a mid-GOP join; slices
            // before the parameter sets are undecodable by definition, not an error.
            mutateStats { $0.droppedNoFormatDescription += 1 }
            onNeedsKeyframe?()
            return
        }

        // (5) A decoder cannot start on a P-frame: it has no reference picture, and feeding
        // it one produces a stream of confusing kVTVideoDecoderBadDataErr. Drop until the
        // first IDR after the format description is valid.
        if awaitingKeyframe {
            guard keyframe else {
                mutateStats { $0.droppedAwaitingKeyframe += 1 }
                onNeedsKeyframe?()
                return
            }
            awaitingKeyframe = false
            mutateStats { $0.awaitingKeyframe = false }
            NSLog("[WHEP-DECODE] keyframe acquired — decoding from here")
        }

        // (2) Access unit → CMSampleBuffer → VTDecompressionSession.
        guard let sampleBuffer = makeSampleBuffer(accessUnit: accessUnit,
                                                  formatDescription: formatDescription,
                                                  rtpTimestamp: rtpTimestamp) else {
            mutateStats { $0.sampleBufferFailures += 1 }
            return
        }

        // No flags: synchronous, in decode order, which for a B-frame-free stream is also
        // display order. The output callback runs before this call returns.
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(session,
                                                       sampleBuffer: sampleBuffer,
                                                       flags: [],
                                                       frameRefcon: nil,
                                                       infoFlagsOut: &infoFlags)
        if status != noErr {
            mutateStats {
                $0.decodeErrors += 1
                $0.lastDecodeError = status
            }
            // Resync rather than keep feeding a session that just rejected a frame: whatever
            // reference state it had is now suspect.
            awaitingKeyframe = true
            mutateStats { $0.awaitingKeyframe = true }
            onNeedsKeyframe?()
        }
    }

    // MARK: - (1) In-band SPS/PPS → CMVideoFormatDescription

    private func updateFormatDescriptionIfNeeded(sps: Data?, pps: Data?, changed: Bool) {
        guard let sps, let pps, !sps.isEmpty, !pps.isEmpty else { return }

        // The bytes are compared as well as trusting `changed`, so that a decoder attached
        // mid-stream — which never sees a change event, only a steady repeat of the same
        // parameter sets — still builds its first format description.
        let haveCurrent = formatDescription != nil && session != nil
        if haveCurrent, !changed, currentSPS == sps, currentPPS == pps { return }

        guard let newFormat = Self.makeFormatDescription(sps: sps, pps: pps) else { return }

        currentSPS = sps
        currentPPS = pps
        formatDescription = newFormat
        mutateStats { $0.formatDescriptionBuilds += 1; $0.haveFormatDescription = true }

        let dimensions = CMVideoFormatDescriptionGetDimensions(newFormat)
        NSLog("[WHEP-DECODE] format description built — %dx%d, SPS %d bytes, PPS %d bytes",
              dimensions.width, dimensions.height, sps.count, pps.count)

        // An existing session can often absorb a new format description (same resolution,
        // trivially different SPS). Asking is cheaper and less disruptive than tearing down.
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newFormat) {
            NSLog("[WHEP-DECODE] existing session accepts the new format description — kept")
            return
        }

        if session != nil {
            NSLog("[WHEP-DECODE] format changed incompatibly — rebuilding the session")
            invalidateSessionOnly()
        }
        makeSession(for: newFormat)

        // A fresh session has no reference frames whatever the bitstream says.
        awaitingKeyframe = true
        mutateStats { $0.awaitingKeyframe = true }
    }

    private static func makeFormatDescription(sps: Data, pps: Data) -> CMFormatDescription? {
        var format: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsBase = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return OSStatus(-1)
                }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            // 4, matching the depacketizer's AVCC length prefix. Get this
                            // wrong and VT reads garbage NAL lengths, not an error.
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format)
                    }
                }
            }
        }
        guard status == noErr, let format else {
            NSLog("[WHEP-DECODE] CMVideoFormatDescriptionCreateFromH264ParameterSets failed (%d)", status)
            return nil
        }
        return format
    }

    // MARK: - VTDecompressionSession

    private func invalidateSessionOnly() {
        guard let session else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
        self.session = nil
    }

    private func makeSession(for format: CMFormatDescription) {
        // Hardware is a REQUEST, not a requirement: `Enable…` lets VT fall back to software
        // rather than fail creation, which `Require…` would do.
        let specification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true
        ]

        // Output callback record. The C function pointer must not capture, so `self` travels
        // as an unretained refcon — safe because decode is synchronous on this queue, so the
        // callback cannot outlive the -decode call that is holding us alive.
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, infoFlags, imageBuffer, pts, _ in
                guard let refCon else { return }
                Unmanaged<WHEPVideoDecoder>.fromOpaque(refCon)
                    .takeUnretainedValue()
                    .handleDecoded(status: status, infoFlags: infoFlags, imageBuffer: imageBuffer, pts: pts)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())

        func attributes(pixelFormat: OSType?) -> CFDictionary? {
            guard let pixelFormat else { return nil }
            return [
                kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                // IOSurface + Metal compatibility now, so step 4 can make a texture from
                // this buffer without a copy. Costs nothing to ask for here.
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any]() as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true
            ] as CFDictionary
        }

        for requested in [Self.preferredPixelFormat, nil] as [OSType?] {
            var created: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                      formatDescription: format,
                                                      decoderSpecification: specification as CFDictionary,
                                                      imageBufferAttributes: attributes(pixelFormat: requested),
                                                      outputCallback: &callback,
                                                      decompressionSessionOut: &created)
            if status == noErr, let created {
                session = created
                mutateStats { $0.sessionBuilds += 1 }
                // RealTime tells VT this is live: prefer low latency over throughput, and do
                // not batch frames waiting for a fuller pipeline.
                VTSessionSetProperty(created,
                                     key: kVTDecompressionPropertyKey_RealTime,
                                     value: kCFBooleanTrue)
                if requested == nil {
                    NSLog("""
                          [WHEP-DECODE] WARNING: VT would not output x420 — using its native format. \
                          Step 4 will need MetalVideoRenderer's 8-bit branch, whose range-expansion \
                          constants are still 10-bit-domain (see MetalVideoRenderer.swift ~L981).
                          """)
                } else {
                    NSLog("[WHEP-DECODE] session created — requesting x420 output (10-bit 4:2:0), hardware preferred")
                }
                return
            }
            NSLog("[WHEP-DECODE] VTDecompressionSessionCreate failed (%d)%@", status,
                  requested != nil ? " for x420 — retrying with VT's native format" : "")
        }
    }

    // MARK: - (4) Decoded frame → count, and optionally a PNG

    private func handleDecoded(status: OSStatus,
                               infoFlags: VTDecodeInfoFlags,
                               imageBuffer: CVImageBuffer?,
                               pts: CMTime) {
        guard status == noErr else {
            mutateStats { $0.decodeErrors += 1; $0.lastDecodeError = status }
            return
        }
        if infoFlags.contains(.frameDropped) { return }
        guard let pixelBuffer = imageBuffer else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        mutateStats {
            $0.framesDecoded += 1
            $0.width = width
            $0.height = height
            $0.pixelFormat = format
        }

        lock.lock()
        let shouldExport = exportRequested
        if shouldExport { exportRequested = false }
        lock.unlock()
        if shouldExport { exportStill(pixelBuffer, width: width, height: height, format: format) }

        // Step 4: WHEPFrameRouter.deliver — promote → LiveClock → renderer.enqueue. Called
        // synchronously on this (decode) queue, which is the handoff contract the router
        // documents; it does its own work there and never blocks on the render thread.
        onDecodedFrame?(pixelBuffer, pts)
    }

    /// One-shot PNG of a decoded frame, so "the counter is climbing" can be checked against
    /// actual pixels. This is a SANITY CHECK, not a colour-managed export: VideoToolbox
    /// picks the RGB conversion, unlike MetalVideoRenderer's ⌃⌥E, which tags the layer's
    /// source-derived colorspace. Judge geometry and content here, not code values.
    private func exportStill(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int, format: OSType) {
        var image: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        guard status == noErr, let image else {
            NSLog("[WHEP-DECODE] still export failed — VTCreateCGImageFromCVPixelBuffer (%d)", status)
            return
        }

        let filename = "Manifold_WHEP_\(width)x\(height)_\(Int(Date().timeIntervalSince1970)).png"
        // Preferences (and its security-scoped bookmark) is main-thread state.
        DispatchQueue.main.async {
            Preferences.shared.withExportDirectory { directory in
                let url = directory.appendingPathComponent(filename)
                guard let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    NSLog("[WHEP-DECODE] still export failed — destination create")
                    return
                }
                CGImageDestinationAddImage(destination, image, nil)
                if CGImageDestinationFinalize(destination) {
                    NSLog("[WHEP-DECODE] still exported → %@ (%dx%d, decoded as %@)",
                          url.path, width, height, Self.formatName(format))
                } else {
                    NSLog("[WHEP-DECODE] still export failed — PNG finalize")
                }
            }
        }
    }

    // MARK: - (2) Access unit → CMSampleBuffer

    private func makeSampleBuffer(accessUnit: Data,
                                  formatDescription: CMFormatDescription,
                                  rtpTimestamp: UInt32) -> CMSampleBuffer? {
        // The AVCC bytes are COPIED into a block buffer the sample buffer owns rather than
        // aliased. Synchronous decode would make aliasing safe today, but a sample buffer
        // that outlives its backing Data is the kind of bug that only shows up under load.
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                        memoryBlock: nil,
                                                        blockLength: accessUnit.count,
                                                        blockAllocator: kCFAllocatorDefault,
                                                        customBlockSource: nil,
                                                        offsetToData: 0,
                                                        dataLength: accessUnit.count,
                                                        flags: 0,
                                                        blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            NSLog("[WHEP-DECODE] CMBlockBufferCreateWithMemoryBlock failed (%d)", status)
            return nil
        }

        status = accessUnit.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(with: base,
                                                 blockBuffer: blockBuffer,
                                                 offsetIntoDestination: 0,
                                                 dataLength: accessUnit.count)
        }
        guard status == kCMBlockBufferNoErr else {
            NSLog("[WHEP-DECODE] CMBlockBufferReplaceDataBytes failed (%d)", status)
            return nil
        }

        // DTS is deliberately invalid: CoreMedia reads that as "decode order == presentation
        // order", which is exactly true for a stream with no B-frames. Duration is unknown
        // (RTP does not carry one); step 4 derives it from the frame rate.
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: presentationTime(for: rtpTimestamp),
                                        decodeTimeStamp: .invalid)
        var sampleSize = accessUnit.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                           dataBuffer: blockBuffer,
                                           formatDescription: formatDescription,
                                           sampleCount: 1,
                                           sampleTimingEntryCount: 1,
                                           sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1,
                                           sampleSizeArray: &sampleSize,
                                           sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else {
            NSLog("[WHEP-DECODE] CMSampleBufferCreateReady failed (%d)", status)
            return nil
        }
        return sampleBuffer
    }

    /// 32-bit 90 kHz RTP timestamp → monotonic CMTime, unwrapped across the ~13-hour wrap
    /// and rebased so the first frame is zero.
    private func presentationTime(for rtpTimestamp: UInt32) -> CMTime {
        if let previous = previousRTP {
            // Signed 32-bit difference handles the wrap in both directions.
            unwrappedRTP += Int64(Int32(bitPattern: rtpTimestamp &- previous))
        } else {
            unwrappedRTP = 0
        }
        previousRTP = rtpTimestamp
        return CMTime(value: unwrappedRTP, timescale: Self.rtpClockRate)
    }

    // MARK: - Helpers

    private func mutateStats(_ body: (inout Stats) -> Void) {
        lock.lock(); body(&stats); lock.unlock()
    }

    /// FourCC as text — '420v', 'x420', etc. Cheaper to read in a log than a decimal OSType.
    static func formatName(_ format: OSType) -> String {
        guard format != 0 else { return "none" }
        let bytes = [UInt8((format >> 24) & 0xFF), UInt8((format >> 16) & 0xFF),
                     UInt8((format >> 8) & 0xFF), UInt8(format & 0xFF)]
        let text = String(bytes: bytes, encoding: .ascii) ?? "?"
        return text.allSatisfy { $0.isASCII && !$0.isNewline } ? "'\(text)'" : "\(format)"
    }
}
#endif
