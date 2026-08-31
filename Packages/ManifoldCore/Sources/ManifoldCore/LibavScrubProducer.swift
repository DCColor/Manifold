import AVFoundation
import CFFmpeg

/// The MXF half of the scrub seam: libav seeking, decoding one frame, and handing over a
/// `CVPixelBuffer` in the app's own x420 contract.
///
/// It exists because `AVPlayerScrubProducer` covers ProRes, H.264 and HEVC and covers **nothing**
/// in MXF — AVFoundation has no MXF demuxer, so `FrameEngine.loadMXF` routes those files to libav
/// for playback and this does the same for scrub. Same seam, same coalescer, same delivery-side
/// token, same destination: `MetalVideoRenderer.presentImmediate`.
///
/// ── FOUR DESIGN POINTS, EACH A MEASUREMENT RATHER THAN A PREFERENCE ───────────────────────────
///
///  1. **`FF_THREAD_SLICE`, not the default.** Neither existing libav client sets `thread_type`, so
///     both get `FF_THREAD_FRAME` — which the header itself warns "will increase decoding delay by
///     one frame per thread". Frame threading pipelines ACROSS frames, and a seek flushes the
///     pipeline, so a single-frame decode after a seek pays the whole delay and gets none of the
///     throughput back. MEASURED on 4K DNxHR: **47.4 ms at 8 threads and 56.6 ms at 15 with the
///     default — more threads monotonically SLOWER — against 19.2 ms and 17.4 ms with SLICE.**
///     Slice threading splits ONE frame across cores, which is the shape of this workload.
///  2. **A HELD `AVFormatContext`, not one per request.** The warm-vs-cold gap is entirely
///     `avformat_find_stream_info` install cost; a per-request context does not fit the drag
///     budget and a held one fits with 2× margin. So it is opened at LOAD, exactly like
///     `AVPlayerScrubProducer`'s item, and for the same reason: paid where it is invisible.
///  3. **Its OWN context, never the playback one.** `LibavThumbnailSource` opened its own
///     deliberately so that scrub seeks could never disturb the playback decoder's position, and
///     that property has to survive the rewrite — a drag issues tens of seeks, and doing them on
///     the context the pump is reading from would be a data race and a stutter at once.
///  4. **x420, not RGBA.** See `LibavPixelConversion.swsDestFormat`. The 8-bit RGBA `CGImage` is
///     what made MXF HDR previews SDR *by construction*, and deleting it is how the deferred Part 3
///     of the HDR scrub entry closes.
///
/// ── THREADING ─────────────────────────────────────────────────────────────────────────────────
///
/// Every libav call happens on `scrubQueue` and nowhere else — open, seek, decode, teardown — so
/// they are serialized by construction and cannot race. That is the invariant commit `8896163`
/// established for the pumps, restated: **a producer's teardown is enqueued onto the same serial
/// queue its decode runs on.** The protocol's main-actor surface just hands work to it.
@MainActor
public final class LibavScrubProducer: ScrubFrameProducer {

    /// ⚠️ THE STATE LIVES IN A SEPARATE, NON-ISOLATED BOX AND THAT IS NOT A WORKAROUND.
    /// This type's protocol surface is main-actor (the seam's contract), while every libav call
    /// belongs to `scrubQueue` and to nothing else. Those are two different isolation domains, and
    /// putting the contexts on the main actor would have said the opposite of what is true — as
    /// well as making `deinit` unable to free them, since a main-actor method cannot be called
    /// from a nonisolated deinit. `Decoder` owns the queue and the pointers; this class owns the
    /// readiness flag and the hand-off.
    private let decoder: Decoder

    public private(set) var isReady = false
    public var onReadyChanged: (() -> Void)?

    /// Opens asynchronously and returns immediately — the container walk is the install cost this
    /// design exists to pay at load rather than on the first grab. Requests arriving before it
    /// finishes are held by the coalescer, not dropped: `isReady` gates them and `onReadyChanged`
    /// releases them.
    public init(url: URL, pixelFormat: OSType) {
        decoder = Decoder(url: url, cvFormat: pixelFormat)
        decoder.openAsync { [weak self] ok in
            guard let self, ok else { return }
            self.isReady = true
            self.onReadyChanged?()
        }
    }

    public func decode(at seconds: Double, completion: @escaping (ScrubFrame?) -> Void) {
        guard isReady else { completion(nil); return }
        decoder.decodeAsync(at: seconds, completion: completion)
    }

    public func close() {
        onReadyChanged = nil
        isReady = false
        decoder.close()
    }
}

/// The queue-owned half. Every libav call happens on `scrubQueue` and nowhere else — open, seek,
/// decode, teardown — so they are serialized by construction and cannot race. That is the
/// invariant commit `8896163` established for the pumps, restated: **a producer's teardown is
/// enqueued onto the same serial queue its decode runs on.**
private final class Decoder: @unchecked Sendable {

    private let url: URL
    private let cvFormat: OSType
    /// Serial. `.userInitiated` because a human is dragging.
    private let scrubQueue = DispatchQueue(label: "com.graviton.manifold.scrub.libav", qos: .userInitiated)

    // libav state — scrubQueue ONLY.
    private var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var pkt: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var videoStreamIndex: Int32 = -1
    private var timeBase = AVRational(num: 1, den: 600)
    private var startTimeTicks: Int64 = 0
    private var pool: CVPixelBufferPool?
    private var poolW = 0
    private var poolH = 0

    /// Read on `scrubQueue`, written on main at `close()`. A teardown request has to stop an
    /// in-flight decode from touching contexts that are about to be freed.
    private let closedLock = NSLock()
    private var _closed = false
    private var closed: Bool { closedLock.lock(); defer { closedLock.unlock() }; return _closed }

    // AVERROR codes (macros that do not import to Swift) — mirrors LibavFrameSource.
    private static let errEAGAIN: Int32 = -Int32(EAGAIN)
    private static let errEOF: Int32 = {
        let tag = UInt32(UInt8(ascii: "E")) | (UInt32(UInt8(ascii: "O")) << 8)
            | (UInt32(UInt8(ascii: "F")) << 16) | (UInt32(UInt8(ascii: " ")) << 24)
        return -Int32(bitPattern: tag)
    }()

    init(url: URL, cvFormat: OSType) {
        self.url = url
        self.cvFormat = cvFormat
    }

    deinit { freeOnQueue() }

    func openAsync(_ done: @escaping @MainActor (Bool) -> Void) {
        scrubQueue.async { [weak self] in
            guard let self else { return }
            let ok = self.openOnQueue() && !self.closed
            Task { @MainActor in done(ok) }
        }
    }

    // MARK: - Open (scrubQueue)

    private func openOnQueue() -> Bool {
        var ctx: UnsafeMutablePointer<AVFormatContext>? = nil
        guard avformat_open_input(&ctx, url.path, nil, nil) == 0, ctx != nil,
              avformat_find_stream_info(ctx, nil) >= 0 else {
            avformat_close_input(&ctx)
            print("LibavScrubProducer: open failed for \(url.lastPathComponent)")
            return false
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
            print("LibavScrubProducer: no decodable video stream for \(url.lastPathComponent)")
            return false
        }
        avcodec_parameters_to_context(cctx, par)

        // ── THE THREADING DECISION, WRITTEN WHERE IT TAKES EFFECT ────────────────────────────
        // FF_THREAD_SLICE (=2). Point 1 in the header: frame threading adds a frame of delay per
        // thread and a seek flushes the pipeline, so a one-frame decode pays it all and recovers
        // none of it. 47.4 → 19.2 ms at 8 threads on 4K DNxHR, measured.
        cctx.pointee.thread_type = Int32(FF_THREAD_SLICE)
        // Cores−1, the same floor `LibavFrameSource` uses and for the same reason — one core left
        // free so the Metal scope-compute completions and the UI still get scheduled. That matters
        // MORE here than it did for the thumbnail decoder: the scopes now sample every scrub frame,
        // so a saturated machine would starve exactly the thing this stage adds. (The measurement
        // ran 8 and 15 threads on a 16-core machine and found 19.2 vs 17.4 ms — a 1.8 ms spread,
        // far too small to buy back a starved completion callback.)
        cctx.pointee.thread_count = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))

        var cctxOpt: UnsafeMutablePointer<AVCodecContext>? = cctx
        guard avcodec_open2(cctx, codec, nil) == 0 else {
            avcodec_free_context(&cctxOpt); avformat_close_input(&ctx)
            print("LibavScrubProducer: decoder open failed for \(url.lastPathComponent)")
            return false
        }

        self.fmtCtx = ctx
        self.codecCtx = cctx
        self.pkt = av_packet_alloc()
        self.frame = av_frame_alloc()
        self.videoStreamIndex = vIdx
        self.timeBase = stream.pointee.time_base
        let st = stream.pointee.start_time
        self.startTimeTicks = (st == Int64.min) ? 0 : st   // AV_NOPTS_VALUE → 0
        // Reported once per load, like the playback path's thread line, so the SLICE decision is
        // visible in a diagnostics export rather than only in this comment.
        print("LibavScrubProducer: \(url.lastPathComponent) ready — FF_THREAD_SLICE, "
            + "\(cctx.pointee.thread_count) threads")
        return true
    }

    // MARK: - Decode

    func decodeAsync(at seconds: Double, completion: @escaping @MainActor (ScrubFrame?) -> Void) {
        scrubQueue.async { [weak self] in
            let result = self?.decodeOnQueue(at: seconds)
            Task { @MainActor in completion(result ?? nil) }
        }
    }

    /// Seek backward to the target, decode forward to it, convert. One frame in, one frame out.
    ///
    /// ⚠️ NO CACHE, UNLIKE `LibavThumbnailSource`. That class skipped a decode when the position
    /// had barely moved, because its consumer was a throttle that could ask for the same position
    /// twice. The coalescer cannot: it issues one position at a time and the pending slot always
    /// holds the newest, so a repeat request means the user genuinely came back to that frame and
    /// the honest answer is to decode it. A cache here would also have to be invalidated against
    /// the pixel-buffer pool, which is a second lifetime to get wrong for no measured gain.
    private func decodeOnQueue(at seconds: Double) -> ScrubFrame? {
        guard !closed, let fmtCtx, let codecCtx, let pkt, let frame else { return nil }

        let target = startTimeTicks
            + Int64((seconds * Double(timeBase.den) / Double(timeBase.num)).rounded())
        av_seek_frame(fmtCtx, videoStreamIndex, target, AVSEEK_FLAG_BACKWARD)
        avcodec_flush_buffers(codecCtx)

        // Decode forward to the target, discarding anything earlier. DNxHR is ALL-INTRA, so the
        // BACKWARD seek lands on the target frame itself and this loop runs once — which is why
        // the measured accuracy is 0.5 frames mean / 1.0 max with zero same-frame returns, against
        // the AVFoundation producer's up-to-10 on long-GOP. Same send/receive shape as
        // `LibavFrameSource.nextFrame`.
        var got = false
        var framePts = Double.nan
        while true {
            if closed { return nil }
            let ret = avcodec_receive_frame(codecCtx, frame)
            if ret == 0 {
                let ts = frame.pointee.best_effort_timestamp != Int64.min
                    ? frame.pointee.best_effort_timestamp : frame.pointee.pts
                let sec = Double(ts - startTimeTicks) * Double(timeBase.num) / Double(timeBase.den)
                if sec + 1e-6 < seconds { av_frame_unref(frame); continue }   // pre-target
                framePts = sec
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
        defer { av_frame_unref(frame) }

        let W = Int(frame.pointee.width), H = Int(frame.pointee.height)
        guard let pb = makePixelBuffer(width: W, height: H),
              LibavPixelConversion.fillPixelBuffer(pb, from: frame, cvFormat: cvFormat) else { return nil }
        // ⚠️ THE DELIVERED TIME, NOT THE REQUESTED ONE — `ScrubFrame.pts` is defined as what the
        // decoder actually produced. On all-intra those are the same frame, which is the point of
        // the accuracy measurement; carrying the real value anyway is what keeps the DeckLink audio
        // alignment and the `[SETTLE]` measurement honest rather than circular.
        return ScrubFrame(pixelBuffer: pb, pts: framePts)
    }

    /// A small pool, unlike playback's 20. Only one scrub frame is decoded at a time and the
    /// renderer holds at most the current one plus the last presented; 4 covers that with slack
    /// and keeps a 4K 10-bit (~16 MB) buffer from being reallocated on every position.
    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolW != width || poolH != height {
            pool = LibavPixelConversion.makePool(width: width, height: height,
                                                 cvFormat: cvFormat, minimumBufferCount: 4)
            poolW = width; poolH = height
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess else { return nil }
        return pb
    }

    // MARK: - Teardown

    func close() {
        closedLock.lock(); _closed = true; closedLock.unlock()
        // ENQUEUED, not performed here. The queue is serial and owns every libav call, so this
        // lands after any decode already running instead of tearing against it.
        scrubQueue.async { [weak self] in self?.freeOnQueue() }
    }

    private func freeOnQueue() {
        if codecCtx != nil { avcodec_free_context(&codecCtx) }
        if fmtCtx != nil { avformat_close_input(&fmtCtx) }
        if pkt != nil { av_packet_free(&pkt) }
        if frame != nil { av_frame_free(&frame) }
        pool = nil; poolW = 0; poolH = 0
    }
}
