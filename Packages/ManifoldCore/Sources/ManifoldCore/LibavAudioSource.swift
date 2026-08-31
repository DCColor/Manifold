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
///
/// WHICH audio stream is decoded can change after `open()` — see `selectStream`. The demuxer,
/// the packet and the frame are kept across that; only the decoder and everything derived from
/// the stream are rebound.
public final class LibavAudioSource: @unchecked Sendable {

    public enum LibavError: Error { case open, noAudioStream, noDecoder, decoderOpen }

    /// What `open()` established about the file's audio.
    ///
    /// ⚠️ TWO SCOPES IN ONE STRUCT, AND THE DIFFERENCE BETWEEN THEM IS THE POINT. `streams`
    /// describes EVERY audio stream the container carries; `decoded` is the ONE this source
    /// actually decodes and renders. The forwarding properties below (`codecName`, `channels`, …)
    /// are `decoded`'s facts and mean exactly what they meant before `streams` existed — the
    /// engine's log line, `audioPresence` and the meters read them unchanged.
    ///
    /// `decoded` is an ELEMENT of `streams`, not a second description built alongside it. One
    /// pass, one builder, so the row the inspector prints for the monitored stream cannot disagree
    /// with the facts the engine logs.
    ///
    /// ⚠️ `decoded` DESCRIBES THE STREAM `open()` BOUND, AND `selectStream` DOES NOT UPDATE IT.
    /// This is a value type returned once; a switch changes the DECODER's state, not a struct the
    /// caller is already holding. The engine keeps this whole value as its record of the file's
    /// streams and tracks the monitored one by ARRAY POSITION (`selectedAudioTrackIndex`), which
    /// is the same index the inspector rows are built at — see `FrameEngine.libavAudioInfo`.
    /// Reading `decoded` after a switch gives you the stream that was decoding at OPEN.
    public struct AudioInfo: @unchecked Sendable {

        /// One audio stream as the CONTAINER declares it.
        ///
        /// ⚠️ EVERYTHING HERE COMES FROM `AVCodecParameters`, WHICH COSTS NOTHING PER STREAM.
        /// `avformat_find_stream_info` has already filled `codecpar` for every stream by the time
        /// `open()` looks, so building one of these opens no decoder, allocates no
        /// `AVCodecContext`, reads no packets and demuxes nothing a second time. That is why the
        /// inspector can describe all four streams of an MXF while exactly one is decoded.
        public struct StreamInfo: @unchecked Sendable {

            /// ⚠️ THE `AVStream` INDEX, NOT THE POSITION IN `streams`. The two diverge the moment
            /// a non-audio stream sits between two audio ones — an MXF's video stream is #0, so
            /// its first audio stream is #1 — and this is the number `av_read_frame` stamps on
            /// packets and `av_seek_frame` takes. `selectStream` binds a decoder with it; binding
            /// the array position instead would pick the wrong stream on the first file that
            /// interleaves.
            public let streamIndex: Int32

            public let codecName: String
            public let sampleRate: Int
            public let channels: Int
            public let layoutName: String

            /// The SOURCE's sample depth (`AVCodecParameters.bits_per_raw_sample`), or 0 when the
            /// container does not state one.
            ///
            /// ⚠️ NOT THE DECODE WIDTH, AND THE DIFFERENCE IS VISIBLE. `formatDescription` below
            /// describes this source's OUTPUT — interleaved float32, because that is what
            /// swresample produces and the renderer consumes — so reading a bit depth off it would
            /// report 32 for a 24-bit file. The inspector's "24-bit" is a fact about the FILE. 0
            /// renders as "—", which is the honest answer for a container that declared nothing.
            public let bitsPerRawSample: Int

            /// CoreAudio's spelling of this codec, or nil when there is no equivalent.
            ///
            /// ⚠️ A KEY, NOT A NAME — and that distinction is the whole design. `codecName` above
            /// is `avcodec_get_name` output ("pcm_s24le", "aac"), FFmpeg's INTERNAL identifier,
            /// which must not reach a user-facing surface. Rather than write a second table of
            /// display names here, this translates the KEY into the one
            /// `MediaInspector.audioCodecName(_:)` already uses, so there is exactly one list of
            /// names in the app and the libav and AVFoundation paths cannot drift apart. Nil means
            /// "no CoreAudio equivalent" and the caller falls back to `codecName` — an honest
            /// unfamiliar identifier, never a guessed name. See `audioFormatID(for:name:)`.
            public let audioFormatID: AudioFormatID?

            /// The output format description this stream WOULD produce, built from the same three
            /// facts the decode path uses. Carries the channel layout, so it is the input
            /// `MediaInspector.audioLayout(from:channelCount:)` and
            /// `AudioChannelLayoutBridge.roles(from:)` need — which is how this path names a layout
            /// with the SAME functions the AVFoundation path uses instead of a second vocabulary.
            /// Nil when the description could not be built.
            ///
            /// ⚠️ NONE OF THESE IS THE DECODE PATH'S INSTANCE, INCLUDING THE MONITORED STREAM'S.
            /// `ensureSwr` still builds and owns its own on the pump queue, at first decode,
            /// exactly as before — nothing about the decoder's lifecycle moved to satisfy the
            /// inspector, and building one of these for a stream does NOT mean that stream is
            /// open. They come out of one function fed identical inputs, so they cannot disagree.
            public let formatDescription: CMAudioFormatDescription?
        }

        /// Every audio stream in the container, in `AVStream` order. Never empty — `open()` throws
        /// `noAudioStream` before constructing this if there are none.
        public let streams: [StreamInfo]

        /// The stream feeding the renderer. An element of `streams`; today always its first,
        /// because `open()` decodes the first audio stream it finds.
        public let decoded: StreamInfo

        // The decoded stream's facts under their original names, so every existing reader is
        // untouched and there is no second copy to keep in step.
        public var codecName: String { decoded.codecName }
        public var sampleRate: Int { decoded.sampleRate }
        public var channels: Int { decoded.channels }
        public var layoutName: String { decoded.layoutName }
        public var bitsPerRawSample: Int { decoded.bitsPerRawSample }
        public var audioFormatID: AudioFormatID? { decoded.audioFormatID }
        public var formatDescription: CMAudioFormatDescription? { decoded.formatDescription }
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

    // ── ⚠️ EVERYTHING BELOW IS PER-STREAM STATE AND `selectStream` MUST REBIND ALL OF IT ──────
    //
    // These were write-once in `open()` for as long as this source decoded exactly one stream, and
    // NOTHING clears them. A switch that frees `codecCtx` and `swr` but leaves the rest builds
    // buffers with the OLD stream's channel count, timescale and layout out of the NEW stream's
    // samples — no error anywhere, just a plausibly-wrong result. `rebindOnPump` is the one place
    // they are written after `open()`, and it writes every one of them.
    private var audioStreamIndex: Int32 = -1
    private var timeBase = AVRational(num: 1, den: 44100)
    private var startTimeTicks: Int64 = 0
    private var sampleRate: Int32 = 0
    private var channels: Int32 = 0
    /// ⚠️ A LATCH, NOT A FACT: `ensureSwr` returns early while this is non-nil, so a switch must
    /// clear it (with `swr`) or the new stream's samples go through the old stream's resampler.
    private var formatDesc: CMAudioFormatDescription?
    /// ⚠️ MUST GO BACK TO -1 ON A SWITCH. Left holding the old stream's target, `nextFrame`
    /// silently discards the new stream's frames until a timestamp from a different timeline
    /// happens to pass it.
    private var skipToSeconds: Double = -1

    /// The source's channel layout in CoreAudio's DESCRIPTIONS spelling, built once in `open()`
    /// from `par.ch_layout`, or nil when the container named nothing this can translate. Attached
    /// to every `CMFormatDescription` this source creates — see `ensureSwr`.
    private var channelLayoutData: Data?

    // Output PCM contract the AVSampleBufferAudioRenderer consumes: interleaved
    // 32-bit float at the source rate/channel count (swresample normalizes any
    // source format — PCM/AAC/etc. — planar or packed — into this).
    private let outSampleFmt = AV_SAMPLE_FMT_FLT
    // STATIC because the format-description builder below is static — see the note there. It was
    // always a constant of the output contract, never a fact about one instance.
    private static let bytesPerSample: Int32 = 4

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

    /// Open the container, describe EVERY audio stream it carries, and open a decoder on the one
    /// that will be rendered. Throws `noAudioStream` if the file has no audio (the engine then
    /// plays video-only).
    ///
    /// ⚠️ ENUMERATING AND DECODING ARE SEPARATE STEPS, AND ONLY THE SECOND COSTS ANYTHING. The
    /// loop below reads `codecpar` — already filled for every stream by
    /// `avformat_find_stream_info` — and builds one `StreamInfo` per audio stream. Exactly ONE
    /// decoder is opened, on the FIRST audio stream, exactly as before: no second demux, no
    /// second `AVCodecContext`, and which stream plays is unchanged by the enumeration.
    public func open() throws -> AudioInfo {
        var ctx: UnsafeMutablePointer<AVFormatContext>? = nil
        guard avformat_open_input(&ctx, url.path, nil, nil) == 0, ctx != nil else { throw LibavError.open }
        guard avformat_find_stream_info(ctx, nil) >= 0 else { avformat_close_input(&ctx); throw LibavError.open }

        // ONE pass over `nb_streams`, collecting every audio stream rather than breaking at the
        // first. The first collected stream is also the one decoded below, so nothing searches
        // twice and the monitored stream is still chosen by exactly the rule it always was.
        var audioStreams: [(index: Int32,
                            stream: UnsafeMutablePointer<AVStream>,
                            par: UnsafeMutablePointer<AVCodecParameters>)] = []
        for i in 0..<Int(ctx!.pointee.nb_streams) {
            guard let st = ctx!.pointee.streams[i], let par = st.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            audioStreams.append((Int32(i), st, par))
        }
        guard let monitored = audioStreams.first else {
            avformat_close_input(&ctx); throw LibavError.noAudioStream
        }
        let par = monitored.par
        let stream = monitored.stream

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
        self.audioStreamIndex = monitored.index
        self.timeBase = stream.pointee.time_base
        let st = stream.pointee.start_time
        self.startTimeTicks = (st == Int64.min) ? 0 : st
        self.sampleRate = par.pointee.sample_rate
        self.channels = par.pointee.ch_layout.nb_channels

        // ⚠️ THE MONITORED STREAM'S LAYOUT, AND ONLY ITS. This is decode-path state — `ensureSwr`
        // attaches it to the buffers the renderer and the meters see — so it must track
        // `codecCtx`, not the enumeration. Every OTHER stream's layout is read into its own
        // `StreamInfo` below and touches nothing here.
        self.channelLayoutData = Self.declaredChannelLayout(&par.pointee.ch_layout)

        // Built here, on the OPENING thread, from `codecpar` alone. Reads no pump-queue state and
        // assigns none, so it does not cross the queue discipline the rest of this type keeps —
        // and it opens nothing: a `StreamInfo` for a stream is not that stream being decoded.
        let streams = audioStreams.map { Self.streamInfo(index: $0.index, par: $0.par) }
        // `audioStreams` is non-empty (guarded above) and `map` preserves count, so element 0 is
        // the first audio stream — the one the decoder was just opened on.
        return AudioInfo(streams: streams, decoded: streams[0])
    }

    /// Everything the container states about one audio stream, read from `AVCodecParameters`.
    ///
    /// ⚠️ PURE, AND IT MUST STAY THAT WAY. It touches no instance state, opens nothing and frees
    /// nothing — it is called once per audio stream while exactly one of them has a decoder. A
    /// version of this that read `self.sampleRate` (as `makeOutputFormatDescription` used to)
    /// would describe every stream with the monitored stream's numbers.
    private static func streamInfo(index: Int32,
                                   par: UnsafeMutablePointer<AVCodecParameters>) -> AudioInfo.StreamInfo {
        var layoutBuf = [CChar](repeating: 0, count: 64)
        _ = av_channel_layout_describe(&par.pointee.ch_layout, &layoutBuf, 64)
        // ⚠️ `layoutBuf` IS A DISPLAY STRING AND NOTHING READS IT AS DATA. The line below is the
        // one that carries the declaration: per-channel labels, in interleave order, in the form
        // `AudioChannelLayoutBridge.roles(from:)` reads FIRST. Without it every libav file reported
        // "roles NONE DECLARED" no matter what the container said.
        let layoutData = Self.declaredChannelLayout(&par.pointee.ch_layout)
        let sampleRate = par.pointee.sample_rate
        let channels = par.pointee.ch_layout.nb_channels
        let ffmpegName = String(cString: avcodec_get_name(par.pointee.codec_id))
        return AudioInfo.StreamInfo(
            streamIndex: index,
            codecName: ffmpegName,
            sampleRate: Int(sampleRate),
            channels: Int(channels),
            layoutName: String(cString: layoutBuf),
            bitsPerRawSample: Int(par.pointee.bits_per_raw_sample),
            audioFormatID: Self.audioFormatID(for: par.pointee.codec_id, name: ffmpegName),
            formatDescription: Self.makeOutputFormatDescription(
                sampleRate: sampleRate, channels: channels, channelLayoutData: layoutData))
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

    /// `AVCodecID` → the `AudioFormatID` CoreAudio would use for the same codec, or nil.
    ///
    /// ⚠️ THIS MAPS KEYS AND NAMES NOTHING. Every display string lives in
    /// `MediaInspector.audioCodecName(_:)`, keyed on `AudioFormatID`; this supplies that key from
    /// the libav side so both paths read one list. Adding a codec means adding it in BOTH — a row
    /// here and, if CoreAudio's name is not already there, a case there — which is the intended
    /// friction: the alternative is a parallel name table that silently disagrees.
    ///
    /// ── ⚠️ EVERY PCM VARIANT COLLAPSES TO ONE FORMAT, DELIBERATELY ────────────────────────────
    ///
    /// `kAudioFormatLinearPCM` is a SINGLE `FourCharCode` (`lpcm`) for every depth, sign and
    /// endianness, so the AVFoundation path has always shown a bare "PCM" for 16-, 24- and 32-bit
    /// alike. Mapping FFmpeg's 37 `pcm_*` ids onto it reproduces that exactly rather than inventing
    /// a finer vocabulary for one path — a MOV and an MXF of the same 24-bit master must not read
    /// "PCM" and "pcm_s24le" in the same panel.
    ///
    /// **Nothing is lost by the collapse.** The depth is a SEPARATE field on the row: `bitDepth`,
    /// filled on this path from `bits_per_raw_sample` (24 for the MXF fixture, measured) and
    /// rendered by `AudioTrackInfo.summary` as its own "· 24-bit" component. The bit depth was
    /// never inside the codec name on either path.
    ///
    /// ⚠️ THE PCM FAMILY IS MATCHED ON FFmpeg'S OWN IDENTIFIER, NOT ENUMERATED, AND NOT A RANGE.
    /// All 37 share the `pcm_` prefix of the name `avcodec_get_name` returns — that is FFmpeg's
    /// canonical, API-visible naming for the family, and no non-PCM codec is named `pcm_*`.
    /// Enumerating 37 cases would go stale the moment upstream adds one; a raw-value RANGE would
    /// hardcode an assumption about enum ORDERING that `codec_id.h` does not promise. (This is not
    /// the `strings | grep opus` mistake recorded in `ThirdParty/ffmpeg/README.md`: that read a
    /// string out of a BINARY, where its presence said nothing about the build. This reads the
    /// documented return value of the function whose entire job is to name the codec in hand.)
    private static func audioFormatID(for cid: AVCodecID, name: String) -> AudioFormatID? {
        if name.hasPrefix("pcm_") { return kAudioFormatLinearPCM }
        switch cid {
        // `aac_latm` is AAC with a different transport framing, not a different codec family, and
        // it is one of only two AAC decoders in the vendored build — an SRT feed carrying LATM
        // would otherwise show "aac_latm" in the inspector.
        case AV_CODEC_ID_AAC, AV_CODEC_ID_AAC_LATM: return kAudioFormatMPEG4AAC
        case AV_CODEC_ID_ALAC:                      return kAudioFormatAppleLossless
        case AV_CODEC_ID_AC3:                       return kAudioFormatAC3
        case AV_CODEC_ID_EAC3:                      return kAudioFormatEnhancedAC3
        case AV_CODEC_ID_FLAC:                      return kAudioFormatFLAC
        case AV_CODEC_ID_OPUS:                      return kAudioFormatOpus
        // Everything else keeps FFmpeg's identifier at the call site. The AVFoundation path's own
        // default arm does the same thing for the same reason — it falls back to the raw four
        // characters — so an unfamiliar codec reads as an honest unknown identifier on both paths
        // rather than as a name someone guessed.
        default: return nil
        }
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

    /// Decode a DIFFERENT audio stream of the same file from now on: retire the current decoder,
    /// rebind every per-stream fact to `streamIndex`, then seek + arm at `time`.
    ///
    /// ── ⚠️ THE SERIAL QUEUE IS THE ORDERING, NOT THE CALL ORDER HERE ──────────────────────────
    ///
    /// The swap is enqueued on `pumpQueue` and `arm` enqueues `seekOnPump` on the SAME queue
    /// immediately after, so the swap is guaranteed to have finished before the seek — and before
    /// the first `requestMediaDataWhenReady` callback, which also runs there. That is why this is
    /// one call rather than two the caller must sequence: swap, then arm, enforced by the queue.
    ///
    /// ⚠️ ARMING IS THE FLUSH. `seekOnPump` already calls `avcodec_flush_buffers` on whatever
    /// decoder is bound by the time it runs — the NEW one — so there is no separate flush and
    /// none is needed. The swap deliberately does not flush a context it is about to free.
    ///
    /// ⚠️ THE CALLER MUST HAVE RETIRED THE PREVIOUS ARM. `arm` calls `requestMediaDataWhenReady`
    /// with no preceding `stopRequestingMediaData`, which was safe only while it ran once per
    /// `beginLibavReading` — every one of those is preceded by the engine's `teardownAudioReading`,
    /// which stops the renderer's request block and bumps the audio session token. Re-arming a
    /// live renderer without that is re-entering the API on an installed block. `FrameEngine`
    /// calls `teardownAudioReading()` before this for exactly that reason.
    ///
    /// `completion` reports whether the rebind actually happened, on the PUMP QUEUE. False means
    /// the stream has no usable decoder and the PREVIOUS stream is still bound and still playing —
    /// see `rebindOnPump`. The caller owns putting its own selection state back.
    public func selectStream(_ streamIndex: Int32, fromSeconds time: Double,
                             isCurrent: @escaping @Sendable () -> Bool,
                             completion: @escaping @Sendable (Bool) -> Void) {
        pumpQueue.async { [weak self] in
            guard let self else { completion(false); return }
            completion(self.rebindOnPump(to: streamIndex))
        }
        arm(fromSeconds: time, isCurrent: isCurrent)
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

    /// Bind the decoder to `streamIndex` and rebind everything derived from the stream.
    /// Returns false — having changed NOTHING — when the stream cannot be decoded.
    ///
    /// ── ⚠️ THIS MUST NOT CALL `freeContexts` ──────────────────────────────────────────────────
    ///
    /// `freeContexts` closes `fmtCtx`, which is the demuxer we are KEEPING, and closing it frees
    /// every `AVStream` with it — so the new stream's `time_base` and `start_time`, read three
    /// lines later, would be reads of freed memory. Only `codecCtx` and `swr` are freed here.
    /// `pkt` and `frame` stay alive: they have no stream affinity.
    ///
    /// ⚠️ BUT THE FRAME IS UNREFFED. `nextFrame`'s EOF and EAGAIN arms both `return` without
    /// unreffing `frame`, so a switch that lands after one of those inherits a frame still holding
    /// the old stream's buffer — one frame's data leaked per switch, and libav would only reuse it
    /// on the next successful `avcodec_receive_frame`. `av_frame_unref` on a clean frame is a
    /// documented no-op, so this is unconditional.
    ///
    /// ⚠️ BUILD FIRST, COMMIT SECOND. Every failure exit above the commit leaves the old decoder
    /// bound and playing — `open()` enumerated streams from `codecpar`, which says nothing about
    /// whether a decoder EXISTS for them, so "the container describes it" and "we can decode it"
    /// are genuinely different questions and this is where the second one is asked. A half-swapped
    /// source (freed decoder, no replacement) would be silence with the per-stream facts of a
    /// stream nothing is reading.
    private func rebindOnPump(to streamIndex: Int32) -> Bool {
        guard let fmtCtx else { return false }
        guard streamIndex >= 0, streamIndex < Int32(fmtCtx.pointee.nb_streams),
              let stream = fmtCtx.pointee.streams[Int(streamIndex)],
              let par = stream.pointee.codecpar,
              par.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { return false }
        // Already there. Cheap, and it keeps this safe to call redundantly; `arm` still re-seeks.
        guard streamIndex != audioStreamIndex else { return true }

        guard let codec = avcodec_find_decoder(par.pointee.codec_id),
              let cctx = avcodec_alloc_context3(codec) else { return false }
        var newCtx: UnsafeMutablePointer<AVCodecContext>? = cctx
        avcodec_parameters_to_context(cctx, par)
        guard avcodec_open2(cctx, codec, nil) == 0 else {
            avcodec_free_context(&newCtx); return false
        }

        // ── COMMIT. Nothing below can fail. ──────────────────────────────────────────────────
        if let frame { av_frame_unref(frame) }
        if swr != nil { swr_free(&swr) }
        formatDesc = nil                      // with `swr`, the pair `ensureSwr` latches on
        if codecCtx != nil { avcodec_free_context(&codecCtx) }
        codecCtx = newCtx

        audioStreamIndex = streamIndex        // what `nextFrame` filters packets on, and seeks with
        timeBase = stream.pointee.time_base   // a different stream may keep time differently
        let st = stream.pointee.start_time
        startTimeTicks = (st == Int64.min) ? 0 : st
        sampleRate = par.pointee.sample_rate  // read BEFORE the latch above is rebuilt — see `ensureSwr`
        channels = par.pointee.ch_layout.nb_channels
        channelLayoutData = Self.declaredChannelLayout(&par.pointee.ch_layout)
        skipToSeconds = -1                    // back to the sentinel; `seekOnPump` sets the new one
        return true
    }

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
        let bytesPerFrame = ch * Int(Self.bytesPerSample)
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
    ///
    /// ⚠️ THE INPUT FORMAT COMES FROM THE LIVE FRAME; THE OUTPUT RATE COMES FROM `sampleRate`.
    /// Reading the input off the frame is robust for a first decode and says nothing about a
    /// SWITCH: `sampleRate` is per-stream state, so a swap that cleared this latch without
    /// rebinding it first would resample the new stream's 96 kHz frames to the old stream's
    /// 48 kHz output rate and hand the renderer buffers timed at the wrong rate. `rebindOnPump`
    /// therefore rebinds `sampleRate`/`channels`/`channelLayoutData` BEFORE it nils `formatDesc`
    /// and frees `swr`; the ordering there is load-bearing, not stylistic.
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

        guard let fd = makeOutputFormatDescription() else { return false }
        self.formatDesc = fd
        return true
    }

    /// The MONITORED stream's output format description, from this instance's decode-path state.
    /// `ensureSwr`'s call site is unchanged — this was its inline body, and the three values it
    /// forwards are the ones `open()` fixed for the stream that is actually decoding.
    private func makeOutputFormatDescription() -> CMAudioFormatDescription? {
        Self.makeOutputFormatDescription(sampleRate: sampleRate, channels: channels,
                                         channelLayoutData: channelLayoutData)
    }

    /// The OUTPUT format description — interleaved float32 at the given rate and channel count,
    /// with that stream's declared channel layout attached.
    ///
    /// ⚠️ ONE BUILDER, AND THAT IS THE POINT. `ensureSwr` reaches it through the wrapper above on
    /// the pump queue at first decode (as it always did — this was its inline body), and
    /// `streamInfo` calls it on the opening thread, once per audio stream, so the engine has
    /// something to hand `MediaInspector.audioLayout(from:)` for each inspector row. Hand-written
    /// copies of this could drift, and then the layout the inspector NAMES would stop being the
    /// layout the decoder ATTACHES to the samples the meters label.
    ///
    /// ⚠️ AND IT TAKES ITS THREE FACTS AS PARAMETERS RATHER THAN READING `self`. It used to read
    /// `sampleRate`/`channels`/`channelLayoutData` — instance state `open()` sets for the ONE
    /// stream it decodes — so calling it per stream in that form would have described all four of
    /// an MXF's streams with the FIRST one's rate, channel count and layout, silently and
    /// plausibly. The parameters make the stream being described the caller's choice, which is the
    /// only way one builder can serve four streams.
    private static func makeOutputFormatDescription(sampleRate: Int32, channels: Int32,
                                                    channelLayoutData: Data?) -> CMAudioFormatDescription? {
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
            // No declaration to make, so none is made up.
            status = CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil,
                formatDescriptionOut: &fd)
        }
        return status == noErr ? fd : nil
    }
}
