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

    /// The source's channel layout in CoreAudio's DESCRIPTIONS spelling, built once in `open()`
    /// from `par.ch_layout`, or nil when the container named nothing this can translate. Attached
    /// to every `CMFormatDescription` this source creates — see `ensureSwr`.
    private var channelLayoutData: Data?

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
        // ⚠️ `layoutBuf` IS A DISPLAY STRING AND NOTHING READS IT AS DATA. The line below is the
        // one that carries the declaration: per-channel labels, in interleave order, in the form
        // `AudioChannelLayoutBridge.roles(from:)` reads FIRST. Without it every libav file reported
        // "roles NONE DECLARED" no matter what the container said.
        self.channelLayoutData = Self.declaredChannelLayout(&par.pointee.ch_layout)
        return AudioInfo(
            codecName: String(cString: avcodec_get_name(cid)),
            sampleRate: Int(sampleRate),
            channels: Int(channels),
            layoutName: String(cString: layoutBuf))
    }

    /// libav's `AVChannelLayout` → a CoreAudio DESCRIPTIONS layout, or nil when it named no
    /// channel this bridge covers.
    ///
    /// ── WHY PER-CHANNEL DESCRIPTIONS AND NOT A LAYOUT TAG ────────────────────────────────────
    ///
    /// Because the order is part of the declaration and a tag cannot carry it. Two of the four
    /// audio streams in `decl_5_5_5F_51_51F.mxf` are `AV_CHANNEL_ORDER_CUSTOM` in FILM order
    /// (`L C R Ls Rs LFE`) — libav has no canonical name for that layout, and neither does
    /// CoreAudio: there is no tag whose expansion is that sequence. Descriptions state each
    /// channel positionally, so the order survives the round trip with no table and no naming
    /// convention in the middle. `av_channel_layout_channel_from_index` is what makes this work
    /// for every `AVChannelOrder` — NATIVE, CUSTOM and UNSPEC answer the same question through it.
    ///
    /// ⚠️ NEVER INFER A LABEL FROM A COUNT OR A POSITION. A channel whose `AVChannel` is outside
    /// the 18 WAVE positions `AudioChannelLayoutBridge.positions` covers gets
    /// `kAudioChannelLabel_Unused` — not a guess from where it sits in the interleave. And when
    /// NOTHING maps (an `UNSPEC` layout, an ambisonic bed, a binaural pair) this returns nil and
    /// the format description is built with no layout at all, exactly as it was before this
    /// existed: the tap then reports NONE DECLARED and the meters show channel NUMBERS. That is
    /// the honest answer. A wrong label on the instrument someone uses to decide which channel is
    /// which is worse than no label — the rule is stated on `AudioTapBuffer.Format.roles` and this
    /// is a second site that has to keep it.
    ///
    /// ⚠️ A REFUSAL AND AN ABSENCE LOOK THE SAME DOWNSTREAM. "The container declared nothing" and
    /// "the container declared something outside the table" both arrive at the tap as NONE
    /// DECLARED. `AudioChannelLayoutBridge.MaskRefusal` exists because that distinction is worth
    /// carrying on the SRT path; this source is silent by construction (it logs nothing; the
    /// engine prints its `AudioInfo`), so the distinction is not available here today.
    private static func declaredChannelLayout(_ layout: UnsafePointer<AVChannelLayout>) -> Data? {
        let count = Int(layout.pointee.nb_channels)
        guard count > 0 else { return nil }

        var labels: [AudioChannelLabel] = []
        labels.reserveCapacity(count)
        var named = 0
        for i in 0..<count {
            // Answers for CUSTOM order (the `u.map` array) and NATIVE order (the mask's i-th set
            // bit) alike, which is the reason this walks indices instead of reading `u.mask` —
            // the mask is meaningless for the two Film-order streams and reading it would refuse
            // exactly the layouts this change exists to carry.
            let channel = av_channel_layout_channel_from_index(layout, UInt32(i))
            if let position = AudioChannelLayoutBridge.positions
                .first(where: { $0.ffmpegBit == Int(channel.rawValue) }) {
                labels.append(position.label)
                named += 1
            } else {
                // AV_CHAN_NONE (-1), AV_CHAN_UNKNOWN, the ambisonic range, and everything above
                // bit 17 land here. Present in the layout, named by nothing we will stand behind.
                labels.append(kAudioChannelLabel_Unused)
            }
        }
        // All-Unused is a declaration in form only — the same thing `isUsable` refuses one layer
        // up. Attaching it would replace "no layout" with "a layout that says nothing", which is
        // strictly more work to read and no more informative.
        guard named > 0 else { return nil }
        return AudioChannelLayoutBridge.descriptionsLayoutData(for: labels)
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
        // ⚠️ `layoutSize` IS THE TRUE BYTE COUNT OF A VARIABLE-LENGTH STRUCT, NOT
        // `MemoryLayout<AudioChannelLayout>.size`. `AudioChannelLayout` declares ONE
        // `AudioChannelDescription` inline, so a 6-channel layout is `offsetof(mChannelDescriptions)`
        // plus SIX strides — `descriptionsLayoutData` allocates exactly that and `Data.count` is it.
        // Passing the struct's own size instead would hand CoreMedia a buffer five descriptions
        // short of what its header claims and it would read past the end.
        let status: OSStatus
        if let channelLayoutData {
            status = channelLayoutData.withUnsafeBytes { raw in
                CMAudioFormatDescriptionCreate(
                    allocator: nil, asbd: &asbd,
                    layoutSize: raw.count,
                    layout: raw.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self),
                    magicCookieSize: 0, magicCookie: nil, extensions: nil,
                    formatDescriptionOut: &fd)
            }
        } else {
            // Unchanged from before: no declaration to make, so none is made up.
            status = CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil,
                formatDescriptionOut: &fd)
        }
        guard status == noErr else { return false }
        self.formatDesc = fd
        return true
    }
}
