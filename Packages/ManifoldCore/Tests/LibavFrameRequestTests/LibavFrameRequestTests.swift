import XCTest
import CFFmpeg
@testable import FrameGrab

/// Marker thumbnails on MXF (Robbie, 2026-11-15; docs/MARKERS_PLAN.md §15). The fixture, `df-bars-2997.mxf`, was made once
/// with the Martin Riedl static FFmpeg 8.1.1 (`/opt/homebrew/bin/ffmpeg`, run only): ProRes Proxy, 160×90, 29.97 fps,
/// 60 frames, material package timecode 00:59:59;00 (so frame 30 is 01:00:00;00), each frame's index drawn as ten 16-px
/// luma bars (`geq` on N). This decodes it through the vendored libav exactly as `LibavScrubProducer.decodeOnQueue` does —
/// backward seek to the request, decode forward to the first frame that `FrameRequest.reaches` it — and reads the bars.
final class LibavFrameRequestTests: XCTestCase {

    static let rate = 30000.0 / 1001

    func testEveryFrameIncludingNeighboursAndBothSidesOfTheHour() throws {
        let decoder = try MXFDecoder(url: try XCTUnwrap(Bundle.module.url(forResource: "df-bars-2997", withExtension: "mxf",
                                                                           subdirectory: "Fixtures")))
        // The reported pair is one frame apart; 29/30 straddle 00:59:59;29 → 01:00:00;00; both ends.
        for index in [0, 1, 12, 13, 29, 30, 31, 58, 59] {
            let got = try XCTUnwrap(decoder.decode(at: FrameRequest.firstAtOrAfter(index: index, rate: Self.rate)),
                                    "frame \(index)")
            XCTAssertEqual(ExactFrameGrabber.frameIndex(pts: got.seconds, rate: Self.rate), index, "time of frame \(index)")
            XCTAssertEqual(got.barsIndex, index, "picture of frame \(index)")
        }
    }

    /// The first build's request, (N + 0.25) / rate, against the same decoder: it returns frame N + 1. This is the bug.
    func testTheOldRequestGaveTheNextFrame() throws {
        let decoder = try MXFDecoder(url: try XCTUnwrap(Bundle.module.url(forResource: "df-bars-2997", withExtension: "mxf",
                                                                           subdirectory: "Fixtures")))
        let got = try XCTUnwrap(decoder.decode(at: (12.0 + 0.25) / Self.rate))
        XCTAssertEqual(got.barsIndex, 13)
    }

    func testTheFirstFrameIsAtZero() throws {
        let decoder = try MXFDecoder(url: try XCTUnwrap(Bundle.module.url(forResource: "df-bars-2997", withExtension: "mxf",
                                                                           subdirectory: "Fixtures")))
        XCTAssertEqual(try XCTUnwrap(decoder.decode(at: 0)).seconds, 0, accuracy: 1e-9)
    }
}

/// The libav part of `LibavScrubProducer.decodeOnQueue`, software decode only (the app's ProRes VideoToolbox route applies
/// the same `FrameRequest.reaches` rule to packet times).
private final class MXFDecoder {
    struct Frame { let seconds: Double; let barsIndex: Int }

    private var fmt: UnsafeMutablePointer<AVFormatContext>?
    private var codec: UnsafeMutablePointer<AVCodecContext>?
    private let stream: Int32
    private let timeBase: AVRational
    private let startTicks: Int64

    init(url: URL) throws {
        guard avformat_open_input(&fmt, url.path, nil, nil) == 0, let fmt, avformat_find_stream_info(fmt, nil) >= 0 else {
            throw NSError(domain: "mxf", code: 1)
        }
        stream = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard stream >= 0, let st = fmt.pointee.streams[Int(stream)], let par = st.pointee.codecpar,
              let dec = avcodec_find_decoder(par.pointee.codec_id), let ctx = avcodec_alloc_context3(dec) else {
            throw NSError(domain: "mxf", code: 2)
        }
        avcodec_parameters_to_context(ctx, par)
        guard avcodec_open2(ctx, dec, nil) == 0 else { throw NSError(domain: "mxf", code: 3) }
        codec = ctx
        timeBase = st.pointee.time_base
        let s = st.pointee.start_time
        startTicks = s == Int64.min ? 0 : s
    }

    deinit {
        avcodec_free_context(&codec)
        avformat_close_input(&fmt)
    }

    func decode(at seconds: Double) -> Frame? {
        guard let fmt, let codec, let pkt = av_packet_alloc(), let frame = av_frame_alloc() else { return nil }
        var p: UnsafeMutablePointer<AVPacket>? = pkt, f: UnsafeMutablePointer<AVFrame>? = frame
        defer { av_packet_free(&p); av_frame_free(&f) }
        let target = startTicks + Int64((seconds * Double(timeBase.den) / Double(timeBase.num)).rounded())
        av_seek_frame(fmt, stream, target, AVSEEK_FLAG_BACKWARD)
        avcodec_flush_buffers(codec)
        while true {
            let ret = avcodec_receive_frame(codec, frame)
            if ret == 0 {
                let ts = frame.pointee.best_effort_timestamp != Int64.min ? frame.pointee.best_effort_timestamp : frame.pointee.pts
                let sec = Double(ts - startTicks) * Double(timeBase.num) / Double(timeBase.den)
                if !FrameRequest.reaches(sec, seconds) { av_frame_unref(frame); continue }
                defer { av_frame_unref(frame) }
                return Frame(seconds: sec, barsIndex: bars(frame))
            }
            if ret != -Int32(EAGAIN) { return nil }
            if av_read_frame(fmt, pkt) < 0 { avcodec_send_packet(codec, nil); continue }
            if pkt.pointee.stream_index == stream { avcodec_send_packet(codec, pkt) }
            av_packet_unref(pkt)
        }
    }

    /// The index the bars spell: 10-bit luma (yuv422p10le), bar k white when bit k is set.
    private func bars(_ frame: UnsafeMutablePointer<AVFrame>) -> Int {
        guard let plane = frame.pointee.data.0 else { return -1 }
        let stride = Int(frame.pointee.linesize.0)
        let row = Int(frame.pointee.height) / 2
        var index = 0
        for k in 0..<10 {
            let x = k * 16 + 8
            let v = plane.advanced(by: row * stride + x * 2).withMemoryRebound(to: UInt16.self, capacity: 1) { $0.pointee }
            if v > 512 { index |= 1 << k }
        }
        return index
    }
}
