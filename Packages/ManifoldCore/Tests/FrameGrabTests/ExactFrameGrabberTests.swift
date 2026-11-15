import XCTest
import AVFoundation
import CoreVideo
@testable import FrameGrab

/// Marker thumbnails on long-GOP (Robbie, 2026-11-15): two markers ONE FRAME APART each get their own frame, at 23.976 and
/// 25, mid-GOP and across a keyframe. The fixture is written here: H.264, a keyframe every 50 frames, B-frames allowed,
/// each frame's index drawn as ten black/white bars, so the test reads back WHICH frame it got.
final class ExactFrameGrabberTests: XCTestCase {

    static let bars = 10
    static let width = 320, height = 180

    func testConsecutiveFramesInALongGOPFileAt25() throws {
        try check(rate: 25, timescale: 25, frameTicks: 1)
    }

    func testConsecutiveFramesInALongGOPFileAt23976() throws {
        try check(rate: 24000.0 / 1001, timescale: 24000, frameTicks: 1001)
    }

    private func check(rate: Double, timescale: Int32, frameTicks: Int64) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("longgop-\(UUID().uuidString).mp4")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try writeLongGOP(url: url, frames: 120, timescale: timescale, frameTicks: frameTicks)
        // Long-GOP: most frames are not sync samples (VideoToolbox adds a few keyframes of its own beyond the interval).
        let syncs = try syncSampleIndices(url, rate: Double(timescale) / Double(frameTicks))
        XCTAssertLessThan(syncs.count * 8, 120, "the fixture must be long-GOP: \(syncs.sorted())")
        // Two consecutive NON-keyframes (the reported case: 751 after keyframe 750), a keyframe and the frame after it,
        // the frame before a keyframe, and the ends.
        let midGOP = try XCTUnwrap((1..<118).first { !syncs.contains($0) && !syncs.contains($0 + 1) && !syncs.contains($0 - 1) })
        let key = try XCTUnwrap(syncs.sorted().first { $0 > 0 && $0 < 119 })
        for pair in [(midGOP, midGOP + 1), (key, key + 1), (key - 1, key), (0, 1), (118, 119)] {
            for index in [pair.0, pair.1] {
                let f = try ExactFrameGrabber.grab(url: url, index: index, rate: rate,
                                                   pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                XCTAssertEqual(f.index, index)
                XCTAssertEqual(ExactFrameGrabber.frameIndex(pts: f.pts, rate: rate), index)
                XCTAssertEqual(readIndex(f.pixelBuffer), index, "picture of frame \(index) at \(rate)")
            }
        }
        XCTAssertThrowsError(try ExactFrameGrabber.grab(url: url, index: 500, rate: rate,
                                                        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
    }

    // MARK: Fixture

    private func writeLongGOP(url: URL, frames: Int, timescale: Int32, frameTicks: Int64) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.width, AVVideoHeightKey: Self.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoMaxKeyFrameIntervalKey: 50,
                AVVideoAllowFrameReorderingKey: true,
                AVVideoAverageBitRateKey: 2_000_000,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.width, kCVPixelBufferHeightKey as String: Self.height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            let buffer = try XCTUnwrap(pb)
            draw(index: i, into: buffer)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i) * frameTicks, timescale: timescale)))
        }
        input.markAsFinished()
        let done = expectation(description: "written")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(writer.status, .completed)
    }

    /// Ten vertical bars, bar k white when bit k of `index` is set.
    private func draw(index: Int, into pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        let barWidth = Self.width / Self.bars
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let bit = (index >> min(x / barWidth, Self.bars - 1)) & 1
                let v: UInt8 = bit == 1 ? 255 : 0
                let p = base + y * rowBytes + x * 4
                p[0] = v; p[1] = v; p[2] = v; p[3] = 255
            }
        }
    }

    /// The index the bars spell, read from the luma plane at each bar's centre.
    private func readIndex(_ pb: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let barWidth = Self.width / Self.bars
        var index = 0
        for k in 0..<Self.bars where base[(Self.height / 2) * rowBytes + k * barWidth + barWidth / 2] > 128 {
            index |= 1 << k
        }
        return index
    }

    /// Which frames are sync samples (keyframes), by index.
    private func syncSampleIndices(_ url: URL, rate: Double) throws -> Set<Int> {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let sem = DispatchSemaphore(value: 0)
        var tracks: [AVAssetTrack] = []
        asset.loadTracks(withMediaType: .video) { t, _ in tracks = t ?? []; sem.signal() }
        sem.wait()
        let out = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: nil)
        reader.add(out)
        reader.startReading()
        var syncs = Set<Int>()
        while let s = out.copyNextSampleBuffer() {
            let att = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: false) as? [[CFString: Any]]
            let pts = CMSampleBufferGetPresentationTimeStamp(s).seconds
            guard pts.isFinite, CMSampleBufferGetNumSamples(s) > 0 else { continue }   // a timing-only buffer
            if att?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true {
                syncs.insert(ExactFrameGrabber.frameIndex(pts: pts, rate: rate))
            }
        }
        return syncs
    }
}
