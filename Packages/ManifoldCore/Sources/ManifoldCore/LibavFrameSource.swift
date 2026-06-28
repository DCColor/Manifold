import Foundation
import CoreMedia
import CoreVideo
import CFFmpeg

/// A `FrameSource` that decodes with static libav (FFmpeg) instead of
/// AVFoundation/VideoToolbox — for formats VT can't decode (DNxHR → -12906).
///
/// Stage 2b FIRST LIGHT: open a DNxHR file, decode ONE frame, convert it to the
/// SAME contract the AVFoundation `FileFrameSource` produces (IOSurface-backed
/// 420v 8-bit biplanar CVPixelBuffer in a CMSampleBuffer, carrying the YCbCr
/// matrix attachment), and emit it via `onVideoFrame`. No playback pacing yet —
/// that's Stage 3 (the synchronizer driving the decode).
///
/// Lifecycle matches Stage 1: currency is gated by the engine's session token
/// (injected `isCurrent`), never a per-source flag (that caused the Stage 1 race).
public final class LibavFrameSource: FrameSource, @unchecked Sendable {

    public enum LibavError: Error { case open, noVideoStream, noDecoder, decoderOpen, decodeFailed, convertSetup }

    /// Color/format facts read from the stream — the engine uses `isFullRange` to
    /// set its range flag (DNxHR/MXF ACLR: JPEG=full, MPEG=legal); the rest is for
    /// logging the first-light result (incl. the 10-bit source pix-fmt signal).
    public struct StreamInfo: Sendable {
        public let width: Int
        public let height: Int
        public let isFullRange: Bool
        public let rangeName: String
        public let sourcePixelFormat: String
        public let matrixName: String
    }

    public var onVideoFrame: ((CMSampleBuffer) -> Void)?

    private let url: URL
    /// Decoded CVPixelBuffer format — the SAME parameter `FileFrameSource` carries.
    /// 8-bit 420v today; M3b widens to 10-bit (420v10/p010) without touching callers.
    private let pixelFormat: OSType
    private let isCurrent: @Sendable () -> Bool
    private let pumpQueue: DispatchQueue

    // libav state. Opened on the main actor in `open()`, then only touched on
    // `pumpQueue` (decode) and freed there in `stop()` — never concurrently.
    private var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var videoStreamIndex: Int32 = -1
    private var pool: CVPixelBufferPool?
    private var width = 0
    private var height = 0

    public init(url: URL,
                pixelFormat: OSType,
                isCurrent: @escaping @Sendable () -> Bool,
                pumpQueue: DispatchQueue) {
        self.url = url
        self.pixelFormat = pixelFormat
        self.isCurrent = isCurrent
        self.pumpQueue = pumpQueue
    }

    /// Open the container + decoder and read the stream's color facts. Cheap
    /// (no decode). Called synchronously by the engine so it can set its range flag
    /// before the first frame displays. Throws on any libav failure.
    public func open() throws -> StreamInfo {
        var ctx: UnsafeMutablePointer<AVFormatContext>? = nil
        guard avformat_open_input(&ctx, url.path, nil, nil) == 0, ctx != nil else { throw LibavError.open }
        guard avformat_find_stream_info(ctx, nil) >= 0 else { avformat_close_input(&ctx); throw LibavError.open }

        // First video stream.
        var vIdx: Int32 = -1
        var par: UnsafeMutablePointer<AVCodecParameters>? = nil
        for i in 0..<Int(ctx!.pointee.nb_streams) {
            guard let st = ctx!.pointee.streams[i] else { continue }
            if st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                vIdx = Int32(i); par = st.pointee.codecpar; break
            }
        }
        guard vIdx >= 0, let par else { avformat_close_input(&ctx); throw LibavError.noVideoStream }

        let cid = par.pointee.codec_id
        guard let codec = avcodec_find_decoder(cid) else { avformat_close_input(&ctx); throw LibavError.noDecoder }
        guard let cctx = avcodec_alloc_context3(codec) else { avformat_close_input(&ctx); throw LibavError.noDecoder }
        avcodec_parameters_to_context(cctx, par)
        var cctxOpt: UnsafeMutablePointer<AVCodecContext>? = cctx
        guard avcodec_open2(cctx, codec, nil) == 0 else {
            avcodec_free_context(&cctxOpt); avformat_close_input(&ctx); throw LibavError.decoderOpen
        }

        self.fmtCtx = ctx
        self.codecCtx = cctx
        self.videoStreamIndex = vIdx
        self.width = Int(par.pointee.width)
        self.height = Int(par.pointee.height)

        let range = par.pointee.color_range
        let isFull = (range == AVCOL_RANGE_JPEG)
        let srcPix = av_get_pix_fmt_name(AVPixelFormat(par.pointee.format)).map { String(cString: $0) } ?? "?"

        return StreamInfo(
            width: width, height: height,
            isFullRange: isFull,
            rangeName: Self.rangeName(range),
            sourcePixelFormat: srcPix,
            matrixName: Self.matrixName(par.pointee.color_space))
    }

    /// FIRST LIGHT: decode the first frame, convert, emit. Runs the whole one-shot
    /// on `pumpQueue` (same queue the AVFoundation pump uses), bowing out if a newer
    /// session has superseded us. Must be called after `open()`.
    public func start() throws {
        let emit = onVideoFrame
        let current = isCurrent
        pumpQueue.async { [weak self] in
            guard let self, current() else { return }
            guard let sb = self.decodeFirstFrame() else {
                print("LibavFrameSource: decode/convert produced no frame"); return
            }
            guard current() else { return }
            emit?(sb)
        }
    }

    /// Free libav resources. Serialized behind `pumpQueue` so it can't overlap an
    /// in-flight decode. Currency is the engine's token, so a stale source never
    /// touches shared render state — this only releases its own C contexts.
    public func stop() {
        pumpQueue.async { [weak self] in
            guard let self else { return }
            if self.codecCtx != nil { avcodec_free_context(&self.codecCtx) }
            if self.fmtCtx != nil { avformat_close_input(&self.fmtCtx) }
            self.pool = nil
        }
    }

    // MARK: - Decode + convert (pumpQueue only)

    private func decodeFirstFrame() -> CMSampleBuffer? {
        guard let fmtCtx, let codecCtx else { return nil }

        let pkt = av_packet_alloc()
        var pktOpt: UnsafeMutablePointer<AVPacket>? = pkt
        let frame = av_frame_alloc()
        var frameOpt: UnsafeMutablePointer<AVFrame>? = frame
        defer { av_packet_free(&pktOpt); av_frame_free(&frameOpt) }

        // Intra-only DNxHR: one packet decodes to one frame.
        var got = false
        while av_read_frame(fmtCtx, pkt) >= 0 {
            if pkt!.pointee.stream_index == videoStreamIndex {
                if avcodec_send_packet(codecCtx, pkt) == 0,
                   avcodec_receive_frame(codecCtx, frame) == 0 {
                    av_packet_unref(pkt); got = true; break
                }
            }
            av_packet_unref(pkt)
        }
        guard got else { return nil }

        return convert(frame!, ptsSeconds: 0)
    }

    /// libav AVFrame → the 420v contract: an IOSurface-backed CVPixelBuffer wrapped
    /// as a CMSampleBuffer with the YCbCr matrix attachment. swscale does the whole
    /// format conversion (10→8 bit, 422→420 subsample, planar→biplanar NV12) in one
    /// pass, written straight into the pixel buffer's planes — no intermediate copy.
    private func convert(_ frame: UnsafeMutablePointer<AVFrame>, ptsSeconds: Double) -> CMSampleBuffer? {
        let W = Int(frame.pointee.width)
        let H = Int(frame.pointee.height)
        let srcFmt = AVPixelFormat(frame.pointee.format)

        guard let pool = ensurePool(width: W, height: H),
              let pixelBuffer = makePixelBuffer(from: pool) else { return nil }

        // swscale: source → NV12 (== 420v biplanar layout). Force src/dst range
        // EQUAL so it does NOT remap range — we preserve the file's stored values
        // unclipped (the shader expands legal/full via the engine's flag, exactly
        // like the AVFoundation 420v decode). 709 coefficients for the YUV repack.
        guard let sws = sws_getContext(Int32(W), Int32(H), srcFmt,
                                       Int32(W), Int32(H), AV_PIX_FMT_NV12,
                                       Int32(SWS_BILINEAR.rawValue), nil, nil, nil) else { return nil }
        defer { sws_freeContext(sws) }
        let coeff = sws_getCoefficients(SWS_CS_ITU709)
        let frameRange: Int32 = (frame.pointee.color_range == AVCOL_RANGE_JPEG) ? 1 : 0
        _ = sws_setColorspaceDetails(sws, coeff, frameRange, coeff, frameRange, 0, 1 << 16, 1 << 16)

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

        // Carry the color tags so the shader picks the right coefficients/space.
        // Matrix is what the Metal shader reads (kCVImageBufferYCbCrMatrixKey).
        attach(pixelBuffer, key: kCVImageBufferYCbCrMatrixKey,
               value: Self.cvMatrix(frame.pointee.colorspace))
        attach(pixelBuffer, key: kCVImageBufferColorPrimariesKey,
               value: Self.cvPrimaries(frame.pointee.color_primaries))
        attach(pixelBuffer, key: kCVImageBufferTransferFunctionKey,
               value: Self.cvTransfer(frame.pointee.color_trc))

        return Self.makeSampleBuffer(pixelBuffer, ptsSeconds: ptsSeconds)
    }

    // MARK: - CVPixelBuffer / CMSampleBuffer plumbing

    private func ensurePool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool, self.width == width, self.height == height { return pool }
        let pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            // IOSurface-backed + Metal-compatible → the renderer's zero-copy
            // CVMetalTextureCache path works (same as AVFoundation's buffers).
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]() as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var newPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, pbAttrs as CFDictionary, &newPool) == kCVReturnSuccess else { return nil }
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

    private static func makeSampleBuffer(_ pb: CVPixelBuffer, ptsSeconds: Double) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: pb, formatDescriptionOut: &formatDesc) == noErr,
            let formatDesc else { return nil }

        let pts = CMTime(seconds: ptsSeconds, preferredTimescale: 600)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pb, formatDescription: formatDesc,
            sampleTiming: &timing, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }

    // MARK: - First-light diagnostic (TEMPORARY — remove after verification)

    /// Decode+convert the first frame of `path` and report the center NV12 sample
    /// plus the RGB the shader would produce (709 coefficients, full-range = no
    /// expansion). Proves the decode→420v pipeline + range read end-to-end, headless.
    /// 75% red full should land ~RGB(191,0,0).
    public static func firstLightProbe(path: String) -> String {
        let q = DispatchQueue(label: "com.graviton.manifold.libav.probe")
        let src = LibavFrameSource(url: URL(fileURLWithPath: path),
                                   pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                   isCurrent: { true }, pumpQueue: q)
        let info: StreamInfo
        do { info = try src.open() } catch { return "open failed: \(error)" }
        defer { src.codecCtx.map { _ in avcodec_free_context(&src.codecCtx) }; avformat_close_input(&src.fmtCtx) }
        guard let sb = src.decodeFirstFrame(), let pb = CMSampleBufferGetImageBuffer(sb) else {
            return "decode failed (\(info.sourcePixelFormat))"
        }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb)
        let yB = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let yS = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let cB = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let cS = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        var sy = 0.0, scb = 0.0, scr = 0.0, n = 0.0
        for yy in (H/2 - 20)..<(H/2 + 20) {
            for xx in (W/2 - 20)..<(W/2 + 20) {
                sy += Double(yB[yy * yS + xx])
                let cx = (xx / 2) * 2
                scb += Double(cB[(yy / 2) * cS + cx])
                scr += Double(cB[(yy / 2) * cS + cx + 1])
                n += 1
            }
        }
        let Y = sy / n, Cb = scb / n, Cr = scr / n
        let r = Y + 1.5748 * (Cr - 128)
        let g = Y - 0.1873 * (Cb - 128) - 0.4681 * (Cr - 128)
        let b = Y + 1.8556 * (Cb - 128)
        return String(format: "%dx%d src=%@ range=%@ matrix=%@ | centerNV12 Y=%.0f Cb=%.0f Cr=%.0f"
            + " -> shaderRGB(full)=(%.0f,%.0f,%.0f)  [75%% red full ~ (191,0,0)]",
            W, H, info.sourcePixelFormat, info.rangeName, info.matrixName,
            Y, Cb, Cr, max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
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
        default: return kCVImageBufferYCbCrMatrix_ITU_R_709_2   // incl. 709 + unspecified
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
