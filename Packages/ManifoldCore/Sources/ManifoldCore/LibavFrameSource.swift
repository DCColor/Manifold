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

    /// Color/format facts read from the stream — the engine uses `declaredRange` to
    /// set its range flag. `hasAudio` reports whether an audio decode path would be
    /// needed (Stage 3a is video-only).
    public struct StreamInfo: Sendable {
        public let width: Int
        public let height: Int
        /// What the SOURCE declared — THREE STATES, and `.untagged` is a real answer meaning
        /// *the file did not say*, not a synonym for legal.
        ///
        /// ⚠️ **THIS REPLACED AN `isFullRange: Bool` AND THE BOOL IS NOT COMING BACK.** libav has
        /// three range states and this struct used to have two, so `UNSPECIFIED` and `MPEG` both
        /// arrived as `false` and the libav path could never reach
        /// `MediaInspector.SourceColorRange.untagged` — the AVFoundation path could, which is what
        /// made it a defect rather than a simplification. Same three-state honesty as
        /// `DeclaredPixelAspect`, `LayoutConfidence`, `CaptionDataPresence` and `KeychainRead`.
        public let declaredRange: MediaInspector.SourceColorRange
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

        /// Full range only. ⚠️ **`.untagged` is FALSE here, and that is a LOSS, not a default** —
        /// this getter re-collapses the three states on purpose, so that reaching for it reads as
        /// a deliberate choice at the call site rather than as the only route available. Callers
        /// that need to tell "the file said legal" from "the file said nothing" must read
        /// `declaredRange`. Same shape and same reasoning as `KeychainRead.value`.
        public var isFullRange: Bool { declaredRange == .full }
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

    /// The VideoToolbox route for DNxHR 4:4:4 — nil for every other file, and nil for a 4:4:4 file
    /// once the route has failed at runtime. See `nextFrame()`.
    private var vtDecoder: DNxHRVideoToolboxDecoder?
    /// Said once, not per frame.
    private var vtFallbackAnnounced = false
    /// The x420 contract is CONFIRMED on the first frame rather than assumed. See `nextFrame()`.
    private var vtFormatConfirmed = false
    /// What the FILE declared, kept so the buffer range can revert to it if the VT route falls back.
    private var declaredRangeAtOpen: MediaInspector.SourceColorRange = .untagged
    private let bufferRangeLock = NSLock()
    private var _bufferColorRange: MediaInspector.SourceColorRange = .untagged
    private var _pictureCaveat: String?
    private var routeChanged: (() -> Void)?

    /// **The range of the PIXELS THIS SOURCE IS PRODUCING**, which is not always the range the
    /// FILE declares — and the difference is the whole reason this property exists.
    ///
    /// ⚠️ **THIS IS NOT `StreamInfo.declaredRange` AND MUST NOT BE CONFLATED WITH IT.**
    /// `declaredRange` is the truth about the FILE and feeds the inspector's Range row; it is
    /// correct and does not change. This is the truth about the BUFFER and feeds the render
    /// decision. On every path but one they are identical, which is why one value served both
    /// until now:
    ///
    /// | path | buffer carries | so this returns |
    /// |---|---|---|
    /// | libav + swscale (everything today) | the source's own codes, unconverted | `declaredRange` |
    /// | the DNxHR 4:4:4 VideoToolbox route | **legal**, because VT compresses full→legal on the way to a VIDEO-RANGE pixel format | `.videoLegal` |
    ///
    /// MEASURED on `Mixed Captions.mxf` frame 10: asked for `x420` VideoToolbox returns luma
    /// 78…908, asked for `xf20` it returns 16…987 — and 64 + 16×876/1023 = 77.7, 64 + 987×876/1023
    /// = 909. The compression is exact, so the buffer really is legal and the shader was expanding
    /// it a second time (lifted blacks, compressed highlights).
    public var bufferColorRange: MediaInspector.SourceColorRange {
        bufferRangeLock.lock(); defer { bufferRangeLock.unlock() }; return _bufferColorRange
    }

    /// Why this file's picture cannot be trusted, or nil when it can.
    ///
    /// ⚠️ **NON-NIL MEANS "WE ARE DECODING THIS WRONG AND WE KNOW IT".** Today the one producer is
    /// DNxHR 4:4:4 on a machine without Pro Video Formats: libav refuses the variable ACT flag and
    /// returns green and magenta. The file is fine; our decoder is not. See
    /// `DNxHRVideoToolboxDecoder.PictureCaveat`.
    ///
    /// ⚠️ **IT IS THE EXACT COMPLEMENT OF THE VT ROUTE AND CANNOT COEXIST WITH IT.** Both are set
    /// from one branch on `vtDecoder == nil`, so a machine where the routing works never sees this
    /// and a machine where it does not always does.
    public var pictureCaveat: String? {
        bufferRangeLock.lock(); defer { bufferRangeLock.unlock() }; return _pictureCaveat
    }

    /// Fired when the decode route changes mid-file — which happens exactly once, if the VT route
    /// falls back to libav. Both `bufferColorRange` and `pictureCaveat` change together at that
    /// moment, so one notification covers both. Called from the decode pump.
    public func onDecodeRouteChanged(_ handler: @escaping () -> Void) {
        bufferRangeLock.lock(); routeChanged = handler; bufferRangeLock.unlock()
    }

    /// Set both route-derived facts together. They are always decided by the same branch, so
    /// setting them separately would make it possible for them to disagree.
    private func setRouteState(bufferRange: MediaInspector.SourceColorRange, caveat: String?) {
        bufferRangeLock.lock()
        let changed = _bufferColorRange != bufferRange || _pictureCaveat != caveat
        _bufferColorRange = bufferRange
        _pictureCaveat = caveat
        let handler = routeChanged
        bufferRangeLock.unlock()
        if changed { handler?() }
    }
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
        // Multithreaded decode: HQX frame/slice-threads give ~11×, so the 4K 10-bit decode
        // cost stops contending with the render pipeline (locks 23.976fps). BUT thread_count=0
        // (= one thread per core) saturated EVERY core at decode priority, starving the Metal
        // scope-compute completion callbacks — they waited ~190ms for a free GCD thread,
        // landing the scopes ~5 frames behind the picture. Leave ONE core free so completion
        // callbacks + UI get scheduled promptly. Re-verify 24fps holds: decode has ample
        // headroom (one fewer worker on an N-core machine), and the freed core removes the
        // scope-latency starvation. (Cores−1, floor 1.)
        let decodeThreads = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        cctx.pointee.thread_count = Int32(decodeThreads)
        print("FrameEngine: libav decode threads = \(decodeThreads) (of \(ProcessInfo.processInfo.activeProcessorCount) cores)")
        var cctxOpt: UnsafeMutablePointer<AVCodecContext>? = cctx
        guard avcodec_open2(cctx, codec, nil) == 0 else {
            avcodec_free_context(&cctxOpt); avformat_close_input(&ctx); throw LibavError.decoderOpen
        }

        // ── THE ROUTE DECISION. Once per file, and this is the ONLY place it is made. ──
        //
        // ⚠️ ONE PROFILE: DNxHR 4:4:4 (libav profile 5 → CID 1270), and only when Apple's plug-in
        // decoder is actually present. HQX and everything else stay on libav, which decodes them
        // correctly today. When Pro Video Formats is absent this is false and the file takes
        // exactly the path it takes today — unchanged behaviour, not a regression.
        //
        // ⚠️ THE libav DECODER IS OPENED ABOVE REGARDLESS, INCLUDING FOR FILES THAT TAKE THIS
        // ROUTE. It is the runtime fallback: if the session dies mid-file, `nextFrame()` hands the
        // very packet that failed to `avcodec_send_packet` and carries on. Skipping `avcodec_open2`
        // to save the allocation would remove the only thing that keeps a dead deck off screen.
        // ⚠️ ONE CONDITION, TWO OUTCOMES, AND THAT IS HOW THE ROUTING AND THE WARNING STAY
        // MUTUALLY EXCLUSIVE. `isProfile444` is a fact about the FILE. Inside it, either we get a
        // working plug-in decoder or we do not, and `vtDecoder == nil` decides which of the two
        // halves applies. There is no path on which both fire and none on which neither does.
        //
        // ⚠️ AND THE TEST IS THE PROFILE, NEVER libav's WARNING TEXT. `Unsupported: variable ACT
        // flag.` is decoder log output with no stability guarantee and is not reachable as a value.
        if DNxHRVideoToolboxDecoder.isProfile444(codecID: cid, profile: par.pointee.profile) {
            if ProVideoDecoderAvailability.isAvailable {
                self.vtDecoder = DNxHRVideoToolboxDecoder(width: par.pointee.width,
                                                          height: par.pointee.height)
            }
            if self.vtDecoder == nil {
                // Either the package is absent, or it is present and the session would not open.
                // Both land here, because both mean the same thing to the person watching: libav
                // is about to decode this and the colour will be wrong.
                print("[DNX-VT] DNxHR 4:4:4 with no usable plug-in decoder — libav will decode it "
                    + "and the colour will be wrong. Telling the user.")
            }
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
        // RANGE — libav first, and the container consulted ONLY when libav said nothing.
        //
        // ⚠️ libav is NOT uniformly blind here and must not be treated as if it were: `mxfdec`
        // maps the CDCIDescriptor's Black/WhiteRefLevel correctly, and was right on every fixture
        // where it spoke. It is silent only for the RGBADescriptor (4:4:4 DNxHR), whose
        // ComponentMin/MaxRef it does not read. So the fallback FILLS SILENCE and never overrides
        // a stated answer — the two can never disagree, because the second reader is not asked
        // unless the first abstained. See MXFDeclaredRange for why that is deliberate.
        let declaredRange: MediaInspector.SourceColorRange
        let rangeProvenance: String
        switch range {
        case AVCOL_RANGE_JPEG:
            declaredRange = .full;       rangeProvenance = "libav"
        case AVCOL_RANGE_MPEG:
            declaredRange = .videoLegal; rangeProvenance = "libav"
        default:
            declaredRange = MXFDeclaredRange.read(url: url)
            rangeProvenance = declaredRange == .untagged
                ? "libav silent, container declares nothing"
                : "libav silent, MXF picture descriptor"
        }

        // ⚠️ THE RENDER DECISION FOLLOWS THE BUFFER; THE INSPECTOR KEEPS FOLLOWING THE FILE.
        // `declaredRange` goes into StreamInfo untouched. This is the separate, parallel fact —
        // and note the default is `declaredRange`, so every path that is not the VT route behaves
        // EXACTLY as it does today. The absence of a conversion means "nothing changed", never a
        // new default.
        declaredRangeAtOpen = declaredRange
        setRouteState(
            bufferRange: vtDecoder != nil ? .videoLegal : declaredRange,
            caveat: DNxHRVideoToolboxDecoder.isProfile444(codecID: cid, profile: par.pointee.profile)
                    && vtDecoder == nil ? DNxHRVideoToolboxDecoder.PictureCaveat.short : nil)

        return StreamInfo(
            width: width, height: height,
            declaredRange: declaredRange,
            hasAudio: hasAudio,
            rangeName: "\(declaredRange.displayName) (\(rangeProvenance))",
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
        // Watchdogged — see DNxHRVideoToolboxDecoder.shutdown(). Bounded at 3 s even if the
        // decoder process has died, so closing a file can never stall the deck indefinitely.
        vtDecoder?.shutdown()
        vtDecoder = nil
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
        // ⚠️ ONE Bool TEST — this is the whole per-frame cost on files that do not take the route.
        if vtDecoder != nil, let sb = nextFrameViaVideoToolbox() { return sb }
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

    /// The DNxHR 4:4:4 route: read compressed packets with libav, decode them with Apple's plug-in.
    ///
    /// ⚠️ **NOTHING ELSE MOVES.** The demux, the range read, the ANC caption scan, the audio
    /// tracks, the geometry and the clean aperture all still come from libav exactly as before —
    /// this changes the destination of the compressed packet and nothing else.
    ///
    /// Returns nil to mean **"fall back"**, having already disabled the route and pushed the
    /// offending packet into the libav decoder, so the caller's normal loop picks up seamlessly.
    private func nextFrameViaVideoToolbox() -> CMSampleBuffer? {
        guard let fmtCtx, let codecCtx, let pkt, let decoder = vtDecoder else { return nil }
        while true {
            let rret = av_read_frame(fmtCtx, pkt)
            if rret < 0 { return nil }                          // EOF: let the libav loop drain
            guard pkt.pointee.stream_index == videoStreamIndex else {
                av_packet_unref(pkt); continue
            }
            let ts = pkt.pointee.pts != Int64.min ? pkt.pointee.pts : pkt.pointee.dts
            let sec = ptsSeconds(ts)
            // Same seek-discard rule as the libav path, applied BEFORE decoding rather than after:
            // DNxHR is all-intra, so a pre-target packet can be dropped without decoding it at all.
            if skipToSeconds >= 0, sec + 1e-6 < skipToSeconds {
                av_packet_unref(pkt); continue
            }
            let pts = ptsCMTime(ts)
            let duration = pkt.pointee.duration > 0
                ? CMTime(value: pkt.pointee.duration &* Int64(timeBase.num), timescale: timeBase.den)
                : CMTime.invalid

            guard let pixelBuffer = decoder.decode(packet: pkt, pts: pts, duration: duration) else {
                // ⚠️ RUNTIME FALLBACK. Said ONCE, not per frame, and the packet that failed is not
                // dropped — it goes straight to libav so the picture continues from this frame.
                if !vtFallbackAnnounced {
                    vtFallbackAnnounced = true
                    print("[DNX-VT] decode failed — falling back to libav for the rest of this "
                        + "file. The picture will be wrong on 4:4:4 (green/magenta) but the deck "
                        + "keeps playing. See docs/BUGS.md → \"the narrow MXF plan is VIABLE\".")
                }
                decoder.shutdown()
                vtDecoder = nil
                // The buffers revert to libav's (source range again) AND the picture becomes
                // untrustworthy, at the same instant and for the same reason.
                setRouteState(bufferRange: declaredRangeAtOpen,
                              caveat: DNxHRVideoToolboxDecoder.PictureCaveat.short)
                _ = avcodec_send_packet(codecCtx, pkt)
                av_packet_unref(pkt)
                return nil
            }
            av_packet_unref(pkt)

            // ⚠️ CONFIRMED, NOT ASSUMED — once per file. If the decoder ever hands back something
            // other than the contract, treat it as a failure and fall back rather than pushing an
            // unexpected format at the renderer.
            if !vtFormatConfirmed {
                vtFormatConfirmed = true
                let got = CVPixelBufferGetPixelFormatType(pixelBuffer)
                guard got == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange else {
                    print("[DNX-VT] expected x420, got \(fourCCString(got)) — falling back to libav")
                    decoder.shutdown()
                    vtDecoder = nil
                    setRouteState(bufferRange: declaredRangeAtOpen,
                                  caveat: DNxHRVideoToolboxDecoder.PictureCaveat.short)
                    return nil
                }
                print("[DNX-VT] decoding DNxHR 4:4:4 through Apple's plug-in; x420 confirmed "
                    + "(\(CVPixelBufferGetWidth(pixelBuffer))×\(CVPixelBufferGetHeight(pixelBuffer)))")
            }
            skipToSeconds = -1
            return Self.makeSampleBuffer(pixelBuffer, pts: pts, duration: duration)
        }
    }

    private func fourCCString(_ code: OSType) -> String {
        let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                     UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        return String(bytes: bytes.map { $0 >= 32 && $0 < 127 ? $0 : UInt8(ascii: "?") },
                      encoding: .ascii) ?? "????"
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

        guard let pool = ensurePool(width: W, height: H),
              let pixelBuffer = makePixelBuffer(from: pool) else { return nil }

        // ⚠️ SHARED WITH `LibavScrubProducer`, DELIBERATELY. The scrub frame and the playback
        // frame have to be the same pixels through the same conversion or the whole argument for
        // the producer collapses; two copies of this is how they would drift apart silently.
        guard LibavPixelConversion.fillPixelBuffer(pixelBuffer, from: frame,
                                                   cvFormat: pixelFormat) else { return nil }
        return Self.makeSampleBuffer(pixelBuffer, pts: pts, duration: duration)
    }

    private func ensurePool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool, self.width == width, self.height == height { return pool }
        // Pre-warm enough buffers for the frames in flight (Metal frameQueue caps at
        // 12, plus the reference renderer's queue + decode headroom) so steady-state
        // playback recycles instead of churning fresh 4K 10-bit (~16MB) IOSurfaces.
        guard let newPool = LibavPixelConversion.makePool(width: width, height: height,
                                                          cvFormat: pixelFormat,
                                                          minimumBufferCount: 20) else { return nil }
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

    // MARK: - libav color enum → human-readable names (logging only; the CoreVideo
    // attachment mapping lives in LibavPixelConversion, shared with the scrub producer)

    /// ⚠️ **`ACLR` DOES NOT CARRY THE RANGE — this used to say it did.** A matched full/legal
    /// fixture pair (`TEST OMNISCOPE_FULL/LEGAL.mxf`) carries BYTE-IDENTICAL `ACLR` atoms and
    /// differs only in the picture descriptor's reference levels. Measured 2026-09-09; the old
    /// strings named `ACLR=1`/`ACLR=2` and would have sent the next reader to the wrong atom.
    /// `StreamInfo.rangeName` is now built from the resolved state plus its provenance, so a log
    /// line says which reader answered. Kept for any caller that has only an `AVColorRange`.
    private static func rangeName(_ r: AVColorRange) -> String {
        switch r {
        case AVCOL_RANGE_JPEG: return "Full (libav JPEG)"
        case AVCOL_RANGE_MPEG: return "Legal (libav MPEG)"
        default: return "Unspecified (libav)"
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
}
