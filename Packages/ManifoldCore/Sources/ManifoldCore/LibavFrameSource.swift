import Foundation
import CoreMedia
import CoreVideo
@preconcurrency import AVFoundation
import CFFmpeg

/// A `FrameSource` that decodes with static libav (FFmpeg) instead of
/// AVFoundation/VideoToolbox — for formats VT can't decode (DNxHR → -12906).
///
/// Stage 3a: CONTINUOUS, clock-driven playback. The decode pump is paced by the
/// SAME backpressure the AVFoundation `FileFrameSource` uses — an
/// `AVSampleBufferVideoRenderer`'s `requestMediaDataWhenReady` / `isReadyForMore`
/// readiness — so it fills the renderer's queue without runaway decode, and the
/// `AVSampleBufferRenderSynchronizer` is the master clock. Each emitted frame
/// carries the file's real PTS (best-effort timestamp × stream timebase → CMTime),
/// so the synchronizer and the Metal frameQueue (pts ≤ clock) select correctly.
/// Frames convert to the proven 10-bit x420 contract. Seeking is av_seek_frame to
/// the keyframe + avcodec_flush_buffers + decode-forward to the target.
///
/// Lifecycle/currency matches Stage 1: gated by the engine's session token
/// (injected per arm()), never a per-source flag (that caused the Stage 1 race).
/// The source persists for the file's lifetime; each play/seek re-arms the pump
/// with a fresh token. All libav state is touched only on `pumpQueue` (decode +
/// seek + teardown), never concurrently.
///
/// Note: it deliberately does NOT conform to the bare `FrameSource` protocol
/// (`start()`/`stop()`). Unlike the AVFoundation source (recreated per seek, with a
/// fixed currency baked in at init), this one is PERSISTENT (re-opening the
/// container per scrub would be wasteful) and re-armed with a fresh seek target +
/// session token each time — `arm(fromSeconds:isCurrent:)`. The engine drives it
/// concretely; the seam still holds (frames leave via `onVideoFrame` to the same
/// consumers), the entry shape is just richer.
public final class LibavFrameSource: @unchecked Sendable {

    public enum LibavError: Error { case open, noVideoStream, noDecoder, decoderOpen }

    /// Color/format facts read from the stream — the engine uses `isFullRange` to
    /// set its range flag (DNxHR/MXF ACLR: JPEG=full, MPEG=legal). `hasAudio`
    /// reports whether an audio decode path would be needed (Stage 3a is video-only).
    public struct StreamInfo: Sendable {
        public let width: Int
        public let height: Int
        public let isFullRange: Bool
        public let hasAudio: Bool
        public let rangeName: String
        public let sourcePixelFormat: String
        public let matrixName: String
        // Container-sourced facts the engine needs when AVFoundation can't open the
        // file at all (MXF) — for the UI (duration/size/fps) and layer colorspace.
        public let durationSeconds: Double
        public let frameRate: Double
        public let codecName: String
        public let primariesCode: Int?   // CICP (libav enum rawValue == CICP)
        public let transferCode: Int?
        public let matrixCode: Int?
        /// Start timecode as libav formats it (HH:MM:SS:FF, ';FF' for drop-frame) —
        /// the MXF Material Package TC. Nil if the file carries none.
        public let startTimecode: String?
    }

    public var onVideoFrame: ((CMSampleBuffer) -> Void)?

    private let url: URL
    /// Decoded CVPixelBuffer format — the SAME parameter `FileFrameSource` carries.
    /// M3b: 10-bit x420 (P010-compatible), keeping HQX's native 10-bit precision.
    private let pixelFormat: OSType
    /// Provides the readiness backpressure that paces the pump — same as the AVF source.
    private let pacingRenderer: AVSampleBufferVideoRenderer
    private let pumpQueue: DispatchQueue

    // libav state. Opened on the main actor in `open()`, then only touched on
    // `pumpQueue` (decode/seek) and freed there + in deinit — never concurrently.
    private var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var pkt: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var videoStreamIndex: Int32 = -1
    private var timeBase = AVRational(num: 1, den: 600)
    private var startTimeTicks: Int64 = 0
    private var pool: CVPixelBufferPool?
    private var width = 0
    private var height = 0
    /// After a seek, frames earlier than this (seconds) are decoded-and-discarded so
    /// playback resumes exactly at the target. pumpQueue-only. -1 = no skip pending.
    private var skipToSeconds: Double = -1

    // AVERROR codes (macros that don't import to Swift): AVERROR(EAGAIN) = -EAGAIN;
    // AVERROR_EOF = -FFERRTAG('E','O','F',' ').
    private static let errEAGAIN: Int32 = -Int32(EAGAIN)
    private static let errEOF: Int32 = {
        let tag = UInt32(UInt8(ascii: "E")) | (UInt32(UInt8(ascii: "O")) << 8)
            | (UInt32(UInt8(ascii: "F")) << 16) | (UInt32(UInt8(ascii: " ")) << 24)
        return -Int32(bitPattern: tag)
    }()

    public init(url: URL,
                pixelFormat: OSType,
                pacingRenderer: AVSampleBufferVideoRenderer,
                pumpQueue: DispatchQueue) {
        self.url = url
        self.pixelFormat = pixelFormat
        self.pacingRenderer = pacingRenderer
        self.pumpQueue = pumpQueue
    }

    deinit { freeContexts() }

    /// Open the container + decoder and read the stream facts (color, timebase,
    /// start time, audio presence). Cheap (no decode). Called synchronously by the
    /// engine so it can set its range flag before playback. Throws on failure.
    public func open() throws -> StreamInfo {
        var ctx: UnsafeMutablePointer<AVFormatContext>? = nil
        guard avformat_open_input(&ctx, url.path, nil, nil) == 0, ctx != nil else { throw LibavError.open }
        guard avformat_find_stream_info(ctx, nil) >= 0 else { avformat_close_input(&ctx); throw LibavError.open }

        var vIdx: Int32 = -1
        var hasAudio = false
        var par: UnsafeMutablePointer<AVCodecParameters>? = nil
        var stream: UnsafeMutablePointer<AVStream>? = nil
        for i in 0..<Int(ctx!.pointee.nb_streams) {
            guard let st = ctx!.pointee.streams[i] else { continue }
            let type = st.pointee.codecpar.pointee.codec_type
            if type == AVMEDIA_TYPE_VIDEO, vIdx < 0 {
                vIdx = Int32(i); par = st.pointee.codecpar; stream = st
            } else if type == AVMEDIA_TYPE_AUDIO {
                hasAudio = true
            }
        }
        guard vIdx >= 0, let par, let stream else { avformat_close_input(&ctx); throw LibavError.noVideoStream }

        let cid = par.pointee.codec_id
        guard let codec = avcodec_find_decoder(cid) else { avformat_close_input(&ctx); throw LibavError.noDecoder }
        guard let cctx = avcodec_alloc_context3(codec) else { avformat_close_input(&ctx); throw LibavError.noDecoder }
        avcodec_parameters_to_context(cctx, par)
        // Auto multithreaded decode: HQX frame/slice-threads ~11×, so the 4K 10-bit
        // decode cost stops contending with the render pipeline (locks 23.976fps).
        cctx.pointee.thread_count = 0
        var cctxOpt: UnsafeMutablePointer<AVCodecContext>? = cctx
        guard avcodec_open2(cctx, codec, nil) == 0 else {
            avcodec_free_context(&cctxOpt); avformat_close_input(&ctx); throw LibavError.decoderOpen
        }

        self.fmtCtx = ctx
        self.codecCtx = cctx
        self.pkt = av_packet_alloc()
        self.frame = av_frame_alloc()
        self.videoStreamIndex = vIdx
        self.timeBase = stream.pointee.time_base
        let st = stream.pointee.start_time
        self.startTimeTicks = (st == Int64.min) ? 0 : st     // AV_NOPTS_VALUE → 0
        self.width = Int(par.pointee.width)
        self.height = Int(par.pointee.height)

        let range = par.pointee.color_range
        let srcPix = av_get_pix_fmt_name(AVPixelFormat(par.pointee.format)).map { String(cString: $0) } ?? "?"

        // Container facts for the AVFoundation-blind (MXF) load path.
        let durTicks = ctx!.pointee.duration
        let durationSeconds = (durTicks == Int64.min) ? 0 : Double(durTicks) / 1_000_000
        // MXF often leaves avg_frame_rate unset; av_guess_frame_rate falls back to
        // r_frame_rate / codec timebase so we get 23.976 like the .mov path.
        let fr = av_guess_frame_rate(ctx, stream, nil)
        let frameRate = fr.den != 0 ? Double(fr.num) / Double(fr.den) : 0
        var codecName = String(cString: avcodec_get_name(cid))
        if codecName == "dnxhd" { codecName = "DNxHR" }
        func cicp(_ raw: some BinaryInteger) -> Int? {   // 0 reserved, 2 unspecified → nil
            let v = Int(raw); return (v == 0 || v == 2) ? nil : v
        }
        // Start timecode: libav's mxf demuxer surfaces the MATERIAL PACKAGE TC at the
        // format metadata "timecode" (pre-formatted, drop-frame ';' handled). Fall
        // back to a stream-level "timecode" (e.g. MOV tmcd) for robustness.
        var startTimecode: String? = av_dict_get(ctx!.pointee.metadata, "timecode", nil, 0)
            .map { String(cString: $0.pointee.value) }
        if startTimecode == nil {
            for i in 0..<Int(ctx!.pointee.nb_streams) {
                if let st = ctx!.pointee.streams[i],
                   let e = av_dict_get(st.pointee.metadata, "timecode", nil, 0) {
                    startTimecode = String(cString: e.pointee.value); break
                }
            }
        }
        return StreamInfo(
            width: width, height: height,
            isFullRange: range == AVCOL_RANGE_JPEG,
            hasAudio: hasAudio,
            rangeName: Self.rangeName(range),
            sourcePixelFormat: srcPix,
            matrixName: Self.matrixName(par.pointee.color_space),
            durationSeconds: durationSeconds,
            frameRate: frameRate,
            codecName: codecName,
            primariesCode: cicp(par.pointee.color_primaries.rawValue),
            transferCode: cicp(par.pointee.color_trc.rawValue),
            matrixCode: cicp(par.pointee.color_space.rawValue),
            startTimecode: startTimecode)
    }

    /// Seek to `time` and arm the continuous decode pump for this session. The pump
    /// is paced by the renderer's readiness (identical to the AVF source) and gated
    /// by `isCurrent` (the engine's session token) so rapid seek/stop churn is safe.
    /// Must be called after the engine has stopped the renderer's prior arm.
    public func arm(fromSeconds time: Double, isCurrent: @escaping @Sendable () -> Bool) {
        let renderer = pacingRenderer
        let emit = onVideoFrame
        let current = isCurrent
        // Seek runs on pumpQueue BEFORE the first pump pull (serial queue ordering).
        pumpQueue.async { [weak self] in self?.seekOnPump(toSeconds: time) }
        renderer.requestMediaDataWhenReady(on: pumpQueue) { [weak self] in
            // Superseded / deallocated: bow out WITHOUT stopping the shared renderer
            // (the new session already re-armed it) — the Stage 1 race fix.
            guard let self, current() else { return }
            while renderer.isReadyForMoreMediaData {
                guard current() else { return }
                guard let sb = self.nextFrame() else {
                    renderer.stopRequestingMediaData(); return   // genuine end-of-stream
                }
                emit?(sb)
            }
        }
    }

    /// Stop the pump and free libav resources. The renderer is stopped by the engine
    /// (ordered, main actor); this frees the C contexts on pumpQueue so it can't
    /// overlap an in-flight decode. Idempotent (deinit also frees as a safety net).
    public func stop() {
        pumpQueue.async { [weak self] in self?.freeContexts() }
    }

    private func freeContexts() {
        if codecCtx != nil { avcodec_free_context(&codecCtx) }
        if fmtCtx != nil { avformat_close_input(&fmtCtx) }
        if pkt != nil { av_packet_free(&pkt) }
        if frame != nil { av_frame_free(&frame) }
        pool = nil
    }

    // MARK: - Decode + seek (pumpQueue only)

    private func seekOnPump(toSeconds time: Double) {
        guard let fmtCtx, let codecCtx else { return }
        let target = startTimeTicks
            + Int64((time * Double(timeBase.den) / Double(timeBase.num)).rounded())
        av_seek_frame(fmtCtx, videoStreamIndex, target, AVSEEK_FLAG_BACKWARD)
        avcodec_flush_buffers(codecCtx)
        skipToSeconds = time
    }

    /// Decode the next video frame and convert it, discarding frames before a pending
    /// seek target. Returns nil at end-of-stream. Robust send/receive loop (works for
    /// intra DNxHR and reordered codecs alike).
    private func nextFrame() -> CMSampleBuffer? {
        guard let fmtCtx, let codecCtx, let pkt, let frame else { return nil }
        while true {
            let ret = avcodec_receive_frame(codecCtx, frame)
            if ret == 0 {
                let ts = frame.pointee.best_effort_timestamp != Int64.min
                    ? frame.pointee.best_effort_timestamp : frame.pointee.pts
                let sec = ptsSeconds(ts)
                if skipToSeconds >= 0, sec + 1e-6 < skipToSeconds {
                    av_frame_unref(frame); continue            // pre-target: discard
                }
                skipToSeconds = -1
                let sb = convert(frame, pts: ptsCMTime(ts), duration: durationCMTime(frame))
                av_frame_unref(frame)
                return sb
            }
            if ret == Self.errEOF { return nil }
            if ret != Self.errEAGAIN { return nil }            // unexpected decode error
            // Decoder wants input: feed one packet (NULL at input EOF to drain).
            let rret = av_read_frame(fmtCtx, pkt)
            if rret < 0 { _ = avcodec_send_packet(codecCtx, nil); continue }
            if pkt.pointee.stream_index == videoStreamIndex {
                _ = avcodec_send_packet(codecCtx, pkt)
            }
            av_packet_unref(pkt)
        }
    }

    private func ptsSeconds(_ ticks: Int64) -> Double {
        Double(ticks - startTimeTicks) * Double(timeBase.num) / Double(timeBase.den)
    }

    /// Exact PTS as CMTime in stream-timebase units (engine timeline: 0 at start).
    private func ptsCMTime(_ ticks: Int64) -> CMTime {
        CMTime(value: (ticks - startTimeTicks) &* Int64(timeBase.num), timescale: timeBase.den)
    }

    private func durationCMTime(_ frame: UnsafeMutablePointer<AVFrame>) -> CMTime {
        let d = frame.pointee.duration
        guard d > 0 else { return .invalid }
        return CMTime(value: d &* Int64(timeBase.num), timescale: timeBase.den)
    }

    // MARK: - AVFrame → x420 CVPixelBuffer / CMSampleBuffer (pumpQueue only)

    /// swscale does the whole format conversion (→ P010/x420 10-bit, 422→420
    /// subsample, planar→biplanar) in one pass, straight into the pixel buffer's
    /// planes — no intermediate copy, range preserved (the shader expands).
    private func convert(_ frame: UnsafeMutablePointer<AVFrame>, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        let W = Int(frame.pointee.width)
        let H = Int(frame.pointee.height)
        let srcFmt = AVPixelFormat(frame.pointee.format)

        guard let pool = ensurePool(width: W, height: H),
              let pixelBuffer = makePixelBuffer(from: pool) else { return nil }

        let dstFmt = Self.swsDestFormat(for: pixelFormat)
        guard let sws = sws_getContext(Int32(W), Int32(H), srcFmt,
                                       Int32(W), Int32(H), dstFmt,
                                       Int32(SWS_BILINEAR.rawValue), nil, nil, nil) else { return nil }
        defer { sws_freeContext(sws) }
        // Force src/dst range EQUAL → no range remap; preserve stored values unclipped.
        let coeff = sws_getCoefficients(SWS_CS_ITU709)
        let r: Int32 = (frame.pointee.color_range == AVCOL_RANGE_JPEG) ? 1 : 0
        _ = sws_setColorspaceDetails(sws, coeff, r, coeff, r, 0, 1 << 16, 1 << 16)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let srcData: [UnsafePointer<UInt8>?] = [
            UnsafePointer(frame.pointee.data.0), UnsafePointer(frame.pointee.data.1),
            UnsafePointer(frame.pointee.data.2), UnsafePointer(frame.pointee.data.3)
        ]
        var srcStride: [Int32] = [
            frame.pointee.linesize.0, frame.pointee.linesize.1,
            frame.pointee.linesize.2, frame.pointee.linesize.3
        ]
        var dst: [UnsafeMutablePointer<UInt8>?] = [
            CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
            CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self),
            nil, nil
        ]
        var dstStride: [Int32] = [
            Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)),
            Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)),
            0, 0
        ]
        let scaled = sws_scale(sws, srcData, &srcStride, 0, Int32(H), &dst, &dstStride)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        guard scaled > 0 else { return nil }

        attach(pixelBuffer, key: kCVImageBufferYCbCrMatrixKey, value: Self.cvMatrix(frame.pointee.colorspace))
        attach(pixelBuffer, key: kCVImageBufferColorPrimariesKey, value: Self.cvPrimaries(frame.pointee.color_primaries))
        attach(pixelBuffer, key: kCVImageBufferTransferFunctionKey, value: Self.cvTransfer(frame.pointee.color_trc))

        return Self.makeSampleBuffer(pixelBuffer, pts: pts, duration: duration)
    }

    private func ensurePool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool, self.width == width, self.height == height { return pool }
        let pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]() as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        // Pre-warm enough buffers for the frames in flight (Metal frameQueue caps at
        // 12, plus the reference renderer's queue + decode headroom) so steady-state
        // playback recycles instead of churning fresh 4K 10-bit (~16MB) IOSurfaces.
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 20
        ]
        var newPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, pbAttrs as CFDictionary, &newPool) == kCVReturnSuccess else { return nil }
        self.pool = newPool
        self.width = width
        self.height = height
        return newPool
    }

    private func makePixelBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess else { return nil }
        return pb
    }

    private func attach(_ pb: CVPixelBuffer, key: CFString, value: CFString?) {
        guard let value else { return }
        CVBufferSetAttachment(pb, key, value, .shouldPropagate)
    }

    private static func makeSampleBuffer(_ pb: CVPixelBuffer, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: pb, formatDescriptionOut: &formatDesc) == noErr,
            let formatDesc else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pb, formatDescription: formatDesc,
            sampleTiming: &timing, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }

    /// swscale destination format matching `pixelFormat` (P010 ↔ x420 10-bit, NV12 ↔ 420v).
    private static func swsDestFormat(for cvFormat: OSType) -> AVPixelFormat {
        switch cvFormat {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return AV_PIX_FMT_P010LE
        default:
            return AV_PIX_FMT_NV12
        }
    }

    // MARK: - libav color enum → CoreVideo attachment mapping

    private static func rangeName(_ r: AVColorRange) -> String {
        switch r {
        case AVCOL_RANGE_JPEG: return "Full (ACLR=2/JPEG)"
        case AVCOL_RANGE_MPEG: return "Legal (ACLR=1/MPEG)"
        default: return "Unspecified"
        }
    }

    private static func matrixName(_ s: AVColorSpace) -> String {
        switch s {
        case AVCOL_SPC_BT709: return "Rec.709"
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: return "Rec.2020"
        case AVCOL_SPC_SMPTE170M, AVCOL_SPC_BT470BG: return "Rec.601"
        default: return "Unspecified→709"
        }
    }

    private static func cvMatrix(_ s: AVColorSpace) -> CFString {
        switch s {
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: return kCVImageBufferYCbCrMatrix_ITU_R_2020
        case AVCOL_SPC_SMPTE170M, AVCOL_SPC_BT470BG: return kCVImageBufferYCbCrMatrix_ITU_R_601_4
        default: return kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }
    }

    private static func cvPrimaries(_ p: AVColorPrimaries) -> CFString? {
        switch p {
        case AVCOL_PRI_BT709: return kCVImageBufferColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_BT2020: return kCVImageBufferColorPrimaries_ITU_R_2020
        case AVCOL_PRI_SMPTE432: return kCVImageBufferColorPrimaries_P3_D65
        default: return nil
        }
    }

    private static func cvTransfer(_ t: AVColorTransferCharacteristic) -> CFString? {
        switch t {
        case AVCOL_TRC_BT709: return kCVImageBufferTransferFunction_ITU_R_709_2
        case AVCOL_TRC_SMPTE2084: return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_ARIB_STD_B67: return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        default: return nil
        }
    }
}
