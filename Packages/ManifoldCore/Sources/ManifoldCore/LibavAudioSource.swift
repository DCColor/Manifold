import Foundation
import CoreMedia
import AudioToolbox
@preconcurrency import AVFoundation
import CFFmpeg

/// The audio sibling of `LibavFrameSource` — decodes the file's audio stream with
/// libav and feeds an `AVSampleBufferAudioRenderer` on the engine's SHARED
/// `AVSampleBufferRenderSynchronizer`, so DNxHR files play with sound in A/V sync
/// (the synchronizer clocks both renderers off one timeline — sync is free).
///
/// It opens its OWN `AVFormatContext` on the same file rather than sharing the
/// video source's: the two pumps are paced independently by their respective
/// renderers' `requestMediaDataWhenReady`, and a single `av_read_frame` stream
/// can't be pulled by both without racing/stealing packets. A second demux of a
/// local file is cheap (page cache) and keeps A/V seek alignment simple.
///
/// Lifecycle/currency mirror the video source exactly: persistent per file, re-armed
/// per session with the engine's session token; libav state touched only on the
/// audio pump queue; freed there + in deinit.
public final class LibavAudioSource: @unchecked Sendable {

    public enum LibavError: Error { case open, noAudioStream, noDecoder, decoderOpen }

    public struct AudioInfo: Sendable {
        public let codecName: String
        public let sampleRate: Int
        public let channels: Int
        public let layoutName: String
    }

    /// Handed each decoded PCM CMSampleBuffer on the pump queue — the engine wires
    /// this to `audioRenderer.enqueue`.
    public var onAudioFrame: ((CMSampleBuffer) -> Void)?

    private let url: URL
    private let pacingRenderer: AVSampleBufferAudioRenderer
    private let pumpQueue: DispatchQueue

    private var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var pkt: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var swr: OpaquePointer?
    private var audioStreamIndex: Int32 = -1
    private var timeBase = AVRational(num: 1, den: 44100)
    private var startTimeTicks: Int64 = 0
    private var sampleRate: Int32 = 0
    private var channels: Int32 = 0
    private var formatDesc: CMAudioFormatDescription?
    private var skipToSeconds: Double = -1

    // Output PCM contract the AVSampleBufferAudioRenderer consumes: interleaved
    // 32-bit float at the source rate/channel count (swresample normalizes any
    // source format — PCM/AAC/etc. — planar or packed — into this).
    private let outSampleFmt = AV_SAMPLE_FMT_FLT
    private let bytesPerSample: Int32 = 4

    private static let errEAGAIN: Int32 = -Int32(EAGAIN)
    private static let errEOF: Int32 = {
        let tag = UInt32(UInt8(ascii: "E")) | (UInt32(UInt8(ascii: "O")) << 8)
            | (UInt32(UInt8(ascii: "F")) << 16) | (UInt32(UInt8(ascii: " ")) << 24)
        return -Int32(bitPattern: tag)
    }()

    /// TEMPORARY headless check: report the audio format + decode a few PCM frames
    /// (PTS sequence + total samples) to prove decode→PCM→CMSampleBuffer end-to-end.
    public static func audioProbe(path: String) -> String {
        // Report the file's audio codec + whether a decoder is present in the static
        // build (works even when the decoder is missing — the key diagnostic).
        var ctx: UnsafeMutablePointer<AVFormatContext>? = nil
        guard avformat_open_input(&ctx, path, nil, nil) == 0, ctx != nil else { return "open_input failed" }
        defer { avformat_close_input(&ctx) }
        guard avformat_find_stream_info(ctx, nil) >= 0 else { return "find_stream_info failed" }
        for i in 0..<Int(ctx!.pointee.nb_streams) {
            guard let st = ctx!.pointee.streams[i], let par = st.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            let cid = par.pointee.codec_id
            let name = String(cString: avcodec_get_name(cid))
            let rate = par.pointee.sample_rate
            let ch = par.pointee.ch_layout.nb_channels
            let hasDecoder = avcodec_find_decoder(cid) != nil
            if !hasDecoder {
                return "codec=\(name) \(rate)Hz \(ch)ch — DECODER NOT IN STATIC BUILD (rebuild FFmpeg with --enable-decoder=\(name))"
            }
            // Decoder present: exercise the real decode path.
            let q = DispatchQueue(label: "com.graviton.manifold.libav.audioprobe")
            let src = LibavAudioSource(url: URL(fileURLWithPath: path),
                                       pacingRenderer: AVSampleBufferAudioRenderer(), pumpQueue: q)
            guard let info = try? src.open() else { return "codec=\(name) — open failed" }
            defer { src.freeContexts() }
            var pts: [Double] = []; var totalSamples = 0
            for _ in 0..<5 {
                guard let sb = src.nextFrame() else { break }
                pts.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds)
                totalSamples += CMSampleBufferGetNumSamples(sb)
            }
            let seq = pts.prefix(4).map { String(format: "%.3f", $0) }.joined(separator: ",")
            return String(format: "%@ %dHz %dch (%@) | decoded %d frames PTS[%@…] samples=%d",
                info.codecName, info.sampleRate, info.channels, info.layoutName, pts.count, seq, totalSamples)
        }
        return "no audio stream"
    }

    public init(url: URL, pacingRenderer: AVSampleBufferAudioRenderer, pumpQueue: DispatchQueue) {
        self.url = url
        self.pacingRenderer = pacingRenderer
        self.pumpQueue = pumpQueue
    }

    deinit { freeContexts() }

    /// Open the container + audio decoder and read the audio facts. Throws
    /// `noAudioStream` if the file has no audio (the engine then plays video-only).
    public func open() throws -> AudioInfo {
        var ctx: UnsafeMutablePointer<AVFormatContext>? = nil
        guard avformat_open_input(&ctx, url.path, nil, nil) == 0, ctx != nil else { throw LibavError.open }
        guard avformat_find_stream_info(ctx, nil) >= 0 else { avformat_close_input(&ctx); throw LibavError.open }

        var aIdx: Int32 = -1
        var par: UnsafeMutablePointer<AVCodecParameters>? = nil
        var stream: UnsafeMutablePointer<AVStream>? = nil
        for i in 0..<Int(ctx!.pointee.nb_streams) {
            guard let st = ctx!.pointee.streams[i] else { continue }
            if st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                aIdx = Int32(i); par = st.pointee.codecpar; stream = st; break
            }
        }
        guard aIdx >= 0, let par, let stream else { avformat_close_input(&ctx); throw LibavError.noAudioStream }

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
        self.pkt = av_packet_alloc()
        self.frame = av_frame_alloc()
        self.audioStreamIndex = aIdx
        self.timeBase = stream.pointee.time_base
        let st = stream.pointee.start_time
        self.startTimeTicks = (st == Int64.min) ? 0 : st
        self.sampleRate = par.pointee.sample_rate
        self.channels = par.pointee.ch_layout.nb_channels

        var layoutBuf = [CChar](repeating: 0, count: 64)
        _ = av_channel_layout_describe(&par.pointee.ch_layout, &layoutBuf, 64)
        return AudioInfo(
            codecName: String(cString: avcodec_get_name(cid)),
            sampleRate: Int(sampleRate),
            channels: Int(channels),
            layoutName: String(cString: layoutBuf))
    }

    /// Seek to `time` and arm the continuous audio pump for this session, paced by
    /// the audio renderer's readiness and gated by `isCurrent` — same model as video.
    public func arm(fromSeconds time: Double, isCurrent: @escaping @Sendable () -> Bool) {
        let renderer = pacingRenderer
        let emit = onAudioFrame
        let current = isCurrent
        pumpQueue.async { [weak self] in self?.seekOnPump(toSeconds: time) }
        renderer.requestMediaDataWhenReady(on: pumpQueue) { [weak self] in
            guard let self, current() else { return }
            while renderer.isReadyForMoreMediaData {
                guard current() else { return }
                guard let sb = self.nextFrame() else {
                    renderer.stopRequestingMediaData(); return
                }
                emit?(sb)
            }
        }
    }

    public func stop() {
        pumpQueue.async { [weak self] in self?.freeContexts() }
    }

    private func freeContexts() {
        if swr != nil { swr_free(&swr) }
        if codecCtx != nil { avcodec_free_context(&codecCtx) }
        if fmtCtx != nil { avformat_close_input(&fmtCtx) }
        if pkt != nil { av_packet_free(&pkt) }
        if frame != nil { av_frame_free(&frame) }
    }

    // MARK: - Decode + seek (pumpQueue only)

    private func seekOnPump(toSeconds time: Double) {
        guard let fmtCtx, let codecCtx else { return }
        let target = startTimeTicks
            + Int64((time * Double(timeBase.den) / Double(timeBase.num)).rounded())
        av_seek_frame(fmtCtx, audioStreamIndex, target, AVSEEK_FLAG_BACKWARD)
        avcodec_flush_buffers(codecCtx)
        skipToSeconds = time
    }

    private func nextFrame() -> CMSampleBuffer? {
        guard let fmtCtx, let codecCtx, let pkt, let frame else { return nil }
        while true {
            let ret = avcodec_receive_frame(codecCtx, frame)
            if ret == 0 {
                let ts = frame.pointee.best_effort_timestamp != Int64.min
                    ? frame.pointee.best_effort_timestamp : frame.pointee.pts
                let sec = Double(ts - startTimeTicks) * Double(timeBase.num) / Double(timeBase.den)
                if skipToSeconds >= 0, sec + 1e-6 < skipToSeconds {
                    av_frame_unref(frame); continue
                }
                skipToSeconds = -1
                let pts = CMTime(value: (ts - startTimeTicks) &* Int64(timeBase.num), timescale: timeBase.den)
                let sb = convert(frame, pts: pts)
                av_frame_unref(frame)
                if sb != nil { return sb }
                continue   // conversion produced no samples; keep decoding
            }
            if ret == Self.errEOF { return nil }
            if ret != Self.errEAGAIN { return nil }
            let rret = av_read_frame(fmtCtx, pkt)
            if rret < 0 { _ = avcodec_send_packet(codecCtx, nil); continue }
            if pkt.pointee.stream_index == audioStreamIndex {
                _ = avcodec_send_packet(codecCtx, pkt)
            }
            av_packet_unref(pkt)
        }
    }

    // MARK: - AVFrame → interleaved-float PCM CMSampleBuffer (pumpQueue only)

    private func convert(_ frame: UnsafeMutablePointer<AVFrame>, pts: CMTime) -> CMSampleBuffer? {
        guard ensureSwr(frame), let formatDesc else { return nil }
        let ch = Int(channels)
        let inSamples = Int(frame.pointee.nb_samples)
        guard inSamples > 0, ch > 0 else { return nil }

        // Interleaved float output: one buffer, capacity = inSamples (same rate, 1:1).
        let bytesPerFrame = ch * Int(bytesPerSample)
        let capacityBytes = inSamples * bytesPerFrame
        guard let outBlock = malloc(capacityBytes) else { return nil }

        var inData: [UnsafePointer<UInt8>?] = [
            UnsafePointer(frame.pointee.data.0), UnsafePointer(frame.pointee.data.1),
            UnsafePointer(frame.pointee.data.2), UnsafePointer(frame.pointee.data.3),
            UnsafePointer(frame.pointee.data.4), UnsafePointer(frame.pointee.data.5),
            UnsafePointer(frame.pointee.data.6), UnsafePointer(frame.pointee.data.7)
        ]
        var outData: [UnsafeMutablePointer<UInt8>?] = [outBlock.assumingMemoryBound(to: UInt8.self)]
        let converted = inData.withUnsafeMutableBufferPointer { inPtr in
            outData.withUnsafeMutableBufferPointer { outPtr in
                swr_convert(swr, outPtr.baseAddress, Int32(inSamples), inPtr.baseAddress, Int32(inSamples))
            }
        }
        guard converted > 0 else { free(outBlock); return nil }

        let dataLength = Int(converted) * bytesPerFrame
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: outBlock, blockLength: capacityBytes,
            blockAllocator: kCFAllocatorMalloc, customBlockSource: nil,
            offsetToData: 0, dataLength: dataLength, flags: 0,
            blockBufferOut: &blockBuffer) == noErr, let blockBuffer else { free(outBlock); return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = bytesPerFrame
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: blockBuffer, formatDescription: formatDesc,
            sampleCount: CMItemCount(converted), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }

    /// Lazily build the resampler + audio format description from the first decoded
    /// frame's actual format (robust vs reading codecCtx before any decode).
    private func ensureSwr(_ frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        if swr != nil, formatDesc != nil { return true }
        guard let codecCtx else { return false }
        var s: OpaquePointer?
        let rc = swr_alloc_set_opts2(
            &s,
            &codecCtx.pointee.ch_layout, outSampleFmt, sampleRate,
            &codecCtx.pointee.ch_layout, AVSampleFormat(frame.pointee.format), frame.pointee.sample_rate,
            0, nil)
        guard rc == 0, let s, swr_init(s) == 0 else { if s != nil { var t: OpaquePointer? = s; swr_free(&t) }; return false }
        self.swr = s

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(Int(bytesPerSample) * Int(channels)),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(Int(bytesPerSample) * Int(channels)),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(bytesPerSample * 8),
            mReserved: 0)
        var fd: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &fd) == noErr else { return false }
        self.formatDesc = fd
        return true
    }
}
