//
//  FlashDetector.swift — SyncCalibration
//
//  The sync clip's flash: a full-white frame over black (docs/AUDIO_RESAMPLER_DESIGN.md §19.2,
//  §19.3). The renderer's `[AV-CONTENT]` flash test, moved here so it ships (calibration mode) and so
//  `swift test` and the offline truth check reach it: the mean of a 16 × 16 luma grid, a flash above
//  half scale, reported once, on the first new frame that is one.
//
//  The event's time is the frame's PTS, exactly — the clips put each flash on its frame (§19.9).
//

import CoreVideo

public final class FlashDetector {
    public static let threshold = 0.5
    private var lastPTS = -Double.infinity
    private var lastWasFlash = false

    public init() {}

    /// Whether a frame with this PTS is new (not the same frame selected again on a later tick).
    /// Cheap; ask before sampling, so a repeated frame costs nothing.
    public func isNew(pts: Double) -> Bool { pts != lastPTS }

    /// A new frame's mean luma. True on the first frame of a flash.
    public func observe(pts: Double, meanLuma: Double) -> Bool {
        lastPTS = pts
        let flash = meanLuma > Self.threshold
        defer { lastWasFlash = flash }
        return flash && !lastWasFlash
    }

    /// Mean luma of a 16 × 16 sample grid of plane 0, 0…1. 8-bit or 16-bit containers.
    public static func meanLuma(_ pb: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let planar = CVPixelBufferIsPlanar(pb)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb)
        else { return 0 }
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, 0) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb)
        let rb = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
        let wide = rb >= 2 * w
        var sum = 0.0
        for j in 0..<16 { for i in 0..<16 {
            let x = (2 * i + 1) * w / 32, y = (2 * j + 1) * h / 32
            sum += wide ? Double(base.load(fromByteOffset: y * rb + 2 * x, as: UInt16.self)) / 65_535
                        : Double(base.load(fromByteOffset: y * rb + x, as: UInt8.self)) / 255
        } }
        return sum / 256
    }
}
