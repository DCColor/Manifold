//
//  ExactFrameGrabber.swift — the picture at ONE exact frame of a file AVFoundation can read (docs/MARKERS_PLAN.md §4.4).
//
//  ── WHY NOT THE SCRUB PRODUCER (found 2026-11-15, marker thumbnails) ──────────────────────────────────────────
//
//  Marker thumbnails first used `AVPlayerScrubProducer`, which seeks with INFINITE tolerance on purpose (scrub speed): on
//  long-GOP it lands on the nearest SYNC SAMPLE. On `mk-25-notc.mp4` (H.264, a keyframe every 250 frames) a marker at
//  frame 751 got the seek's snap to 750, the frame that producer had just delivered, so it answered nil ("already on
//  screen") and the thumbnail stayed blank, Regenerate or not. Worse and silent: markers at frames 158 and 1321 got the
//  pictures of the keyframes near them. Scrub is right to work that way; a thumbnail is not.
//
//  So this reads the frame itself: an `AVAssetReader` over a one-frame time range at the frame's presentation time. The
//  reader decodes from the preceding sync sample on its own and vends the frames overlapping the range; the one taken is
//  the frame whose time is within a quarter frame of the index asked for (see the note in `grab`), and if there is none
//  the grab fails: a wrong picture is never shown.
//
//  Synchronous and blocking: call it OFF the main thread. One reader per grab, so grabs never share decoder state.
//

import AVFoundation
import CoreMedia

public enum ExactFrameGrabber {

    public struct Frame: @unchecked Sendable {
        public let pixelBuffer: CVPixelBuffer
        /// Presentation time of the vended frame, seconds from the start of the track's timeline.
        public let pts: Double
        public let index: Int
    }

    public enum GrabError: Error, Equatable {
        case noVideoTrack
        case readerFailed
        /// The reader vended no frame at that index (past the end, or a gap).
        case noFrame
    }

    /// The frame index a presentation time is, at `rate`: `round(t × rate)`, the rule every frame index in the app uses.
    public static func frameIndex(pts: Double, rate: Double) -> Int {
        let v = (pts * rate).rounded()
        return v.isFinite ? Int(v) : Int.min
    }

    /// Frame `index` (0-based, at `rate`) of `url`'s first video track, decoded to `pixelFormat`. Blocking.
    public static func grab(url: URL, index: Int, rate: Double, pixelFormat: OSType) throws -> Frame {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try syncLoadTracks(asset)
        guard let track = tracks.first else { throw GrabError.noVideoTrack }
        guard let reader = try? AVAssetReader(asset: asset) else { throw GrabError.readerFailed }
        // From half a frame before the frame's time to half a frame after: exactly one frame's presentation time.
        let half = 0.5 / rate
        let start = CMTime(seconds: max(Double(index) / rate - half, 0), preferredTimescale: 600_000)
        reader.timeRange = CMTimeRange(start: start, duration: CMTime(seconds: 2 * half, preferredTimescale: 600_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw GrabError.readerFailed }
        reader.add(output)
        guard reader.startReading() else { throw GrabError.readerFailed }
        defer { reader.cancelReading() }
        // ⚠️ NOT THE FIRST FRAME THAT ROUNDS TO `index`. A time-ranged reader also vends the PREVIOUS frame, whose span
        // overlaps the range's start, with its time CLIPPED to that start: at 25 fps, asking for frame 5 gave frame 4
        // stamped 0.18 s (0.18 × 25 = 4.5, which rounds to 5), then frame 5 at 0.20 s (measured 2026-11-15, an
        // AVAssetWriter H.264 file with an edit list). So the frame taken is the one whose time is CLOSEST to the
        // frame's own, and only within a quarter frame of it; a clipped neighbour sits half a frame away.
        let target = Double(index) / rate
        var best: (pb: CVPixelBuffer, pts: Double)?
        while let sample = output.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite else { continue }
            if abs(pts - target) * rate < 0.25, best.map({ abs(pts - target) < abs($0.pts - target) }) ?? true {
                best = (pb, pts)
            }
        }
        if let best { return Frame(pixelBuffer: best.pb, pts: best.pts, index: index) }
        if reader.status == .failed { throw GrabError.readerFailed }
        throw GrabError.noFrame
    }

    /// `AVAsset.loadTracks` from a synchronous context (we are already off main, on a queue that may block).
    private static func syncLoadTracks(_ asset: AVURLAsset) throws -> [AVAssetTrack] {
        let box = TrackBox()
        let done = DispatchSemaphore(value: 0)
        asset.loadTracks(withMediaType: .video) { tracks, error in
            box.tracks = tracks ?? []
            box.failed = error != nil
            done.signal()
        }
        done.wait()
        if box.failed { throw GrabError.readerFailed }
        return box.tracks
    }

    private final class TrackBox: @unchecked Sendable {
        var tracks: [AVAssetTrack] = []
        var failed = false
    }
}
