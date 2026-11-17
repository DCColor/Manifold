//
//  ChapterReader.swift — a file's embedded chapters, read through the vendored libav (docs/CHAPTER_MARKERS_PLAN.md §2.5).
//
//  D-C2 (Robbie, 2026-11-16): libav for every container. `AVFormatContext.chapters` from FFmpeg n8.1.1 is exactly what
//  Flip shows (its `readChapters` dumps the same list as ffmetadata, from the same commit), so a file shows the same
//  chapters in both apps. AVFoundation reads chapters only in the tests, as a cross-check.
//
//  A private AVFormatContext, opened, read and closed here: it never touches playback, and it opens the file the way
//  `LibavFrameSource` does (`avformat_open_input`, `avformat_find_stream_info`, the FIRST video stream), so the
//  `start_time` it reports is the one the libav sources subtract to make frame 0 (`LibavFrameSource.swift:359-360`).
//  Call it off the main thread.
//
//  WHY ITS OWN TARGET, NOT ManifoldCore (2026-11-16): no test target links ManifoldCore, and the reader must be tested on
//  real files through real libav. A leaf target with the same linker settings as `LibavFrameRequestTests` is how
//  `FrameRequest` was made testable too (MARKERS_PLAN §15).
//
//  ⚠️ PRIVACY: titles are the file's content. Nothing here logs.
//

import Foundation
import CFFmpeg
import Markers

public enum ChapterReader {

    public struct Result: Equatable, Sendable {
        /// In file order, times as the container states them.
        public var chapters: [FileChapter]
        /// The first video stream's `start_time`: what the libav path subtracts to make frame 0. `.zero` when the file
        /// states none (AV_NOPTS_VALUE) or has no video stream.
        public var videoStart: ChapterTime
        /// Whether a video stream was found (no video: the origin is a guess at zero).
        public var hasVideo: Bool
    }

    public enum ReadError: Error, Equatable { case open, streamInfo }

    public static func read(url: URL) throws -> Result {
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&ctx, url.path, nil, nil) == 0, let fmt = ctx else { throw ReadError.open }
        defer { avformat_close_input(&ctx) }
        guard avformat_find_stream_info(fmt, nil) >= 0 else { throw ReadError.streamInfo }

        var videoStart = ChapterTime.zero
        var hasVideo = false
        for i in 0..<Int(fmt.pointee.nb_streams) {
            guard let st = fmt.pointee.streams[i], st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO else { continue }
            hasVideo = true
            let start = st.pointee.start_time
            let tb = st.pointee.time_base
            if start != Int64.min, tb.den != 0 {   // AV_NOPTS_VALUE → 0, as LibavFrameSource
                videoStart = ChapterTime(value: start, num: Int64(tb.num), den: Int64(tb.den))
            }
            break
        }

        var chapters: [FileChapter] = []
        let n = Int(fmt.pointee.nb_chapters)
        if n > 0, let list = fmt.pointee.chapters {
            for i in 0..<n {
                guard let ch = list[i] else { continue }
                let tb = ch.pointee.time_base
                let start = ChapterTime(value: ch.pointee.start, num: Int64(tb.num), den: Int64(tb.den))
                let endValue = ch.pointee.end
                let end = endValue == Int64.min ? nil : ChapterTime(value: endValue, num: Int64(tb.num), den: Int64(tb.den))
                var title = ""
                if let e = av_dict_get(ch.pointee.metadata, "title", nil, 0), let v = e.pointee.value {
                    title = String(cString: v)
                }
                chapters.append(FileChapter(start: start, end: end, title: title))
            }
        }
        return Result(chapters: chapters, videoStart: videoStart, hasVideo: hasVideo)
    }
}
