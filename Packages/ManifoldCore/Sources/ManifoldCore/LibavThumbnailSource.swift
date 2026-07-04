import Foundation
import CoreGraphics
import CFFmpeg

/// Detached libav decoder that produces downscaled scrub-preview thumbnails for DNx/MXF files
/// (which AVFoundation's `AVAssetImageGenerator` can't decode — VideoToolbox rejects DNxHR).
///
/// It opens its OWN `AVFormatContext` + decoder on the file — completely separate from the
/// playback `LibavFrameSource` — so thumbnail seeks/decodes never disturb playback (mirrors how
/// `LibavAudioSource` opens its own context on the same file). All libav state is touched ONLY on
/// a private serial `thumbQueue`, so open + every decode request are serialized and can't race;
/// `openAsync`, `thumbnail`, and `close` all funnel through it.
///
/// A thumbnail is exactly the playback op at preview size: `av_seek_frame(…BACKWARD)` →
/// decode-forward to the target → swscale straight to a small RGBA buffer → `CGImage`. DNxHR HQX
/// is all-intra, so the BACKWARD seek lands on the target frame and decode-forward is a single
/// fast frame (no GOP walk). The output box matches the AVFoundation path (960×540, aspect-fit).
public final class LibavThumbnailSource: @unchecked Sendable {

    private let url: URL
    private let thumbQueue = DispatchQueue(label: "com.graviton.manifold.thumb", qos: .userInitiated)

    // libav state — touched ONLY on thumbQueue.
    private var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var pkt: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var videoStreamIndex: Int32 = -1
    private var timeBase = AVRational(num: 1, den: 600)
    private var startTimeTicks: Int64 = 0

    // Cache the last thumbnail so a barely-moved scrub position reuses it (avoids re-decoding
    // the same frame). thumbQueue-only.
    private var lastThumbSeconds: Double = -1
    private var lastThumbImage: CGImage?

    // Preview box — matches AVAssetImageGenerator.maximumSize on the .mov path (aspect-fit,
    // never upscale). The overlay stretches it to the video rect either way; matching the size
    // keeps the visual result identical to ProRes/H.264.
    private let maxThumbW = 960
    private let maxThumbH = 540
    // Reuse the cached thumbnail if the request is within ~half a frame of it.
    private let cacheEpsSeconds = 0.02

    // AVERROR codes (macros that don't import to Swift) — mirror LibavFrameSource.
    private static let errEAGAIN: Int32 = -Int32(EAGAIN)
    private static let errEOF: Int32 = {
        let tag = UInt32(UInt8(ascii: "E")) | (UInt32(UInt8(ascii: "O")) << 8)
            | (UInt32(UInt8(ascii: "F")) << 16) | (UInt32(UInt8(ascii: " ")) << 24)
        return -Int32(bitPattern: tag)
    }()

    public init(url: URL) { self.url = url }
    deinit { freeContexts() }

    /// Open the container + decoder on thumbQueue (non-blocking; the caller returns immediately).
    /// Serialized before any thumbnail request, so the contexts are ready by the time one runs.
    public func openAsync() {
        thumbQueue.async { [weak self] in self?.openLocked() }
    }

    // thumbQueue only.
    private func openLocked() {
        var ctx: UnsafeMutablePointer<AVFormatContext>? = nil
        guard avformat_open_input(&ctx, url.path, nil, nil) == 0, ctx != nil,
              avformat_find_stream_info(ctx, nil) >= 0 else {
            avformat_close_input(&ctx)
            print("LibavThumbnailSource: open failed for \(url.lastPathComponent)")
            return
        }

        var vIdx: Int32 = -1
        var par: UnsafeMutablePointer<AVCodecParameters>? = nil
        var stream: UnsafeMutablePointer<AVStream>? = nil
        for i in 0..<Int(ctx!.pointee.nb_streams) {
            guard let st = ctx!.pointee.streams[i] else { continue }
            if st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO, vIdx < 0 {
                vIdx = Int32(i); par = st.pointee.codecpar; stream = st
            }
        }
        guard vIdx >= 0, let par, let stream,
              let codec = avcodec_find_decoder(par.pointee.codec_id),
              let cctx = avcodec_alloc_context3(codec) else {
            avformat_close_input(&ctx)
            print("LibavThumbnailSource: no decodable video stream for \(url.lastPathComponent)")
            return
        }
        avcodec_parameters_to_context(cctx, par)
        // Thumbnails run one at a time during a (paused) scrub — use HALF the cores so a stray
        // decode never saturates the machine or contends with resumed playback.
        cctx.pointee.thread_count = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        var cctxOpt: UnsafeMutablePointer<AVCodecContext>? = cctx
        guard avcodec_open2(cctx, codec, nil) == 0 else {
            avcodec_free_context(&cctxOpt); avformat_close_input(&ctx)
            print("LibavThumbnailSource: decoder open failed for \(url.lastPathComponent)")
            return
        }

        self.fmtCtx = ctx
        self.codecCtx = cctx
        self.pkt = av_packet_alloc()
        self.frame = av_frame_alloc()
        self.videoStreamIndex = vIdx
        self.timeBase = stream.pointee.time_base
        let st = stream.pointee.start_time
        self.startTimeTicks = (st == Int64.min) ? 0 : st   // AV_NOPTS_VALUE → 0
    }

    /// Free the contexts (thumbQueue). Idempotent (deinit also frees). Enqueued after any
    /// in-flight decode, so it can't tear against one.
    public func close() {
        thumbQueue.async { [weak self] in self?.freeContexts() }
    }

    private func freeContexts() {
        if codecCtx != nil { avcodec_free_context(&codecCtx) }
        if fmtCtx != nil { avformat_close_input(&fmtCtx) }
        if pkt != nil { av_packet_free(&pkt) }
        if frame != nil { av_frame_free(&frame) }
        lastThumbImage = nil
        lastThumbSeconds = -1
    }

    /// Decode a downscaled preview frame at `seconds` (async, off-main). Serialized on
    /// thumbQueue; a near-duplicate position reuses the cached image. Returns nil on failure.
    public func thumbnail(at seconds: Double) async -> CGImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
            thumbQueue.async { [weak self] in
                cont.resume(returning: self?.decodeThumbnail(at: seconds))
            }
        }
    }

    // MARK: - Decode (thumbQueue only)

    private func decodeThumbnail(at seconds: Double) -> CGImage? {
        guard let fmtCtx, let codecCtx, let pkt, let frame else { return nil }
        // Cache: reuse if the position barely moved (same frame).
        if let img = lastThumbImage, abs(seconds - lastThumbSeconds) < cacheEpsSeconds { return img }

        let target = startTimeTicks
            + Int64((seconds * Double(timeBase.den) / Double(timeBase.num)).rounded())
        av_seek_frame(fmtCtx, videoStreamIndex, target, AVSEEK_FLAG_BACKWARD)
        avcodec_flush_buffers(codecCtx)

        // Decode forward to the target, discarding pre-target frames (a single frame for
        // all-intra HQX). Same send/receive loop as LibavFrameSource.nextFrame.
        var got = false
        while true {
            let ret = avcodec_receive_frame(codecCtx, frame)
            if ret == 0 {
                let ts = frame.pointee.best_effort_timestamp != Int64.min
                    ? frame.pointee.best_effort_timestamp : frame.pointee.pts
                let sec = Double(ts - startTimeTicks) * Double(timeBase.num) / Double(timeBase.den)
                if sec + 1e-6 < seconds { av_frame_unref(frame); continue }   // pre-target
                got = true
                break
            }
            if ret == Self.errEOF { break }
            if ret != Self.errEAGAIN { break }                  // unexpected decode error
            let rret = av_read_frame(fmtCtx, pkt)
            if rret < 0 { _ = avcodec_send_packet(codecCtx, nil); continue }   // drain at EOF
            if pkt.pointee.stream_index == videoStreamIndex {
                _ = avcodec_send_packet(codecCtx, pkt)
            }
            av_packet_unref(pkt)
        }
        guard got else { return nil }

        let img = makeCGImage(from: frame)
        av_frame_unref(frame)
        if let img { lastThumbSeconds = seconds; lastThumbImage = img }
        return img
    }

    /// swscale the decoded YUV frame straight to a downscaled RGBA buffer, then wrap it in a
    /// CGImage. Proper YUV→RGB with range expansion (limited→full) so the preview looks right
    /// on screen (unlike the playback path, which keeps range in the shader).
    private func makeCGImage(from f: UnsafeMutablePointer<AVFrame>) -> CGImage? {
        let W = Int(f.pointee.width), H = Int(f.pointee.height)
        guard W > 0, H > 0 else { return nil }
        // Aspect-fit inside the preview box; never upscale. Even dimensions for swscale.
        let scale = min(Double(maxThumbW) / Double(W), Double(maxThumbH) / Double(H), 1.0)
        let tW = max(2, (Int(Double(W) * scale) / 2) * 2)
        let tH = max(2, (Int(Double(H) * scale) / 2) * 2)

        let srcFmt = AVPixelFormat(f.pointee.format)
        guard let sws = sws_getContext(Int32(W), Int32(H), srcFmt,
                                       Int32(tW), Int32(tH), AV_PIX_FMT_RGBA,
                                       Int32(SWS_BILINEAR.rawValue), nil, nil, nil) else { return nil }
        defer { sws_freeContext(sws) }
        // 709 coefficients (matches the playback path's fixed choice); expand the source's
        // YUV range to full-range RGB (dstRange = 1) so the thumbnail isn't washed/dark.
        let coeff = sws_getCoefficients(SWS_CS_ITU709)
        let srcRange: Int32 = (f.pointee.color_range == AVCOL_RANGE_JPEG) ? 1 : 0
        _ = sws_setColorspaceDetails(sws, coeff, srcRange, coeff, 1, 0, 1 << 16, 1 << 16)

        let bytesPerRow = tW * 4
        var buf = [UInt8](repeating: 0, count: bytesPerRow * tH)
        let srcData: [UnsafePointer<UInt8>?] = [
            UnsafePointer(f.pointee.data.0), UnsafePointer(f.pointee.data.1),
            UnsafePointer(f.pointee.data.2), UnsafePointer(f.pointee.data.3)
        ]
        var srcStride: [Int32] = [
            f.pointee.linesize.0, f.pointee.linesize.1, f.pointee.linesize.2, f.pointee.linesize.3
        ]
        let scaled: Int32 = buf.withUnsafeMutableBytes { raw in
            var dst: [UnsafeMutablePointer<UInt8>?] = [raw.baseAddress?.assumingMemoryBound(to: UInt8.self), nil, nil, nil]
            var dstStride: [Int32] = [Int32(bytesPerRow), 0, 0, 0]
            return sws_scale(sws, srcData, &srcStride, 0, Int32(H), &dst, &dstStride)
        }
        guard scaled > 0 else { return nil }

        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
        return CGImage(width: tW, height: tH, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: cs, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
