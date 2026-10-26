//
//  InterlacedRate.swift
//  FileScan
//
//  An interlaced file's frame rate (docs/INTERLACED_FINDINGS.md §5, decision 3; stage I2). Internally Manifold keeps
//  the FRAME rate (29.97 for 1080i59.94) plus the scan; labels use the field rate, as Blackmagic does.
//
//  THE RULE: an interlaced source of woven frames reporting 50 / 59.94 / 60 is counting fields — no 1080i standard has
//  50 or more frames a second — so its frame rate is halved to 25 / 29.97 / 30, and the halving is logged. A field
//  sequence (each coded picture one field, `SourceScan.picturesAreFields`) really does deliver pictures at the field
//  rate; how it is shown and sent is I4 / I6, so it is left as reported.
//

import Foundation

/// The frame rate a file's metadata carries, after decision 3.
public struct InterlacedRate: Equatable, Sendable {
    /// The frame rate to use everywhere (Inspector, timecode, Follow source).
    public let frameRate: Double
    /// What the file or decoder reported, when it was halved; nil when used as reported.
    public let halvedFrom: Double?

    /// Field rates that are really frame rates counted in fields, with the frame rate each halves to.
    static let fieldRates: [(fields: Double, frames: Double)] = [(50, 25), (60000.0 / 1001.0, 30000.0 / 1001.0), (60, 30)]

    public static func resolve(reported: Double, scan: SourceScan) -> InterlacedRate {
        guard scan.isInterlaced, !scan.picturesAreFields, reported > 0,
              let hit = fieldRates.first(where: { abs(reported - $0.fields) <= $0.fields * 0.001 })
        else { return InterlacedRate(frameRate: reported, halvedFrom: nil) }
        return InterlacedRate(frameRate: hit.frames, halvedFrom: reported)
    }

    /// The `[SCAN]` rate line, or nil when nothing was halved.
    public var logLine: String? {
        guard let from = halvedFrom else { return nil }
        return String(format: "[SCAN] rate: interlaced, reported %.3f fps — counting fields (decision 3); "
                              + "frame rate %.3f, %.3f fields/s", from, frameRate, frameRate * 2)
    }
}

extension SourceScan {
    /// The Frame Rate row's suffix for woven interlaced pictures: " (59.94 fields/s)". Empty otherwise.
    public func fieldRateSuffix(frameRate: Double) -> String {
        guard isInterlaced, !picturesAreFields, frameRate > 0 else { return "" }
        var t = String(format: "%.2f", frameRate * 2)
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return " (\(t) fields/s)"
    }
}
