//
//  StillImageInfo.swift
//  StillImageInfo
//
//  What the Inspector and the transport line say about a still (docs/STILLS_AND_AUDIO_ONLY_PLAN.md §4.3, B0 result).
//  Every sentence here states where its number came from, because the numbers ImageIO hands back mix file data with
//  macOS's own assumptions: a PQ file's reported 4.93 is a default, not something the file said.
//

import Foundation

/// How a file carries its gain map, as the file's own bytes say. A file can carry more than one.
///
/// ⚠️ NOT FROM IMAGEIO'S ISO KEY ALONE. ImageIO answers `kCGImageAuxiliaryDataTypeISOGainMap` for an Ultra HDR JPEG that
/// has Adobe `hdrgm` XMP and no ISO 21496-1 segment at all (measured, B0), so that key says "there is a gain map" and
/// nothing about which kind.
public struct GainMapFormats: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let iso21496 = GainMapFormats(rawValue: 1 << 0)
    public static let adobeXMP = GainMapFormats(rawValue: 1 << 1)
    public static let apple = GainMapFormats(rawValue: 1 << 2)

    var names: [String] {
        var out: [String] = []
        if contains(.iso21496) { out.append("ISO 21496-1") }
        if contains(.adobeXMP) { out.append("Adobe XMP") }
        if contains(.apple) { out.append("Apple") }
        return out
    }
}

public enum StillHDRKind: Sendable, Equatable {
    case sdr
    case pq
    case hlg
    /// Empty formats: ImageIO found a gain map and the file's bytes did not say which kind.
    case gainMap(GainMapFormats)

    /// The Inspector's HDR Type row.
    public var typeRow: String {
        switch self {
        case .sdr: return "SDR"
        case .pq: return "PQ"
        case .hlg: return "HLG"
        case .gainMap(let formats):
            return formats.isEmpty ? "Gain map (format not identified)" : "Gain map (\(formats.names.joined(separator: " + ")))"
        }
    }

    /// The short form the transport line uses.
    var shortLabel: String {
        switch self {
        case .sdr: return "SDR"
        case .pq: return "HDR (PQ)"
        case .hlg: return "HDR (HLG)"
        case .gainMap: return "HDR (gain map)"
        }
    }
}

/// Light levels a file states for itself, in nits. Nil when it states none. A stated 0 means "unknown" (CTA-861.3), so
/// the scan drops it.
public struct StatedLight: Sendable, Equatable {
    public var maxCLL: Int?
    public var masteringPeak: Int?
    public init(maxCLL: Int? = nil, masteringPeak: Int? = nil) {
        self.maxCLL = maxCLL
        self.masteringPeak = masteringPeak
    }
}

public enum StillText {
    /// macOS's scale: extended linear 1.0 is 203 nits (measured, B0: PQ 100 nits lands at 0.4925, 10,000 at 49.26). A gain
    /// map states a ratio to SDR white and no nits, so this is what turns its capacity into the number the row shows.
    public static let referenceWhiteNits = 203.0

    /// `kCGDefaultHDRImageContentHeadroom` as measured on macOS 26: 1000 ÷ 203.
    public static let measuredDefaultHeadroom = 1000.0 / referenceWhiteNits

    /// 1,000 in every locale: the row is a technical readout and its wording is fixed.
    static func grouped(_ value: Int) -> String {
        var digits = String(abs(value))
        var groups: [String] = []
        while digits.count > 3 {
            groups.insert(String(digits.suffix(3)), at: 0)
            digits.removeLast(3)
        }
        groups.insert(digits, at: 0)
        return (value < 0 ? "-" : "") + groups.joined(separator: ",")
    }

    static func nits(headroom: Double) -> Int { Int((headroom * referenceWhiteNits).rounded()) }

    /// The Inspector's Headroom row, or nil for SDR. Each answer says whether the number is the file's or macOS's.
    ///
    /// - Parameters:
    ///   - gainMapHeadroom: the file's HDR capacity as a linear ratio to SDR white.
    ///   - reportedHeadroom: what ImageIO reports for the file. For PQ it tells apart "macOS fell back on its default" from
    ///     "macOS read something this scan cannot see into" (a stated peak in a container with no scan here).
    ///   - defaultHeadroom: macOS's default, passed in so the sentence follows the system.
    public static func headroomRow(kind: StillHDRKind, gainMapHeadroom: Double?, light: StatedLight,
                                   reportedHeadroom: Double?,
                                   defaultHeadroom: Double = measuredDefaultHeadroom) -> String? {
        switch kind {
        case .sdr:
            return nil
        case .gainMap:
            guard let gainMapHeadroom, gainMapHeadroom > 0 else { return "HDR capacity not stated" }
            return "HDR capacity \(grouped(nits(headroom: gainMapHeadroom))) nits (from file)"
        case .pq, .hlg:
            if let cll = light.maxCLL { return "MaxCLL \(grouped(cll)) nits (from file)" }
            // With `mdcv` alone macOS uses the mastering peak, so "macOS assumes 1,000 nits" would be false (B0).
            if let peak = light.masteringPeak { return "Mastering peak \(grouped(peak)) nits (from file)" }
            let onTheDefault = reportedHeadroom.map { abs($0 - defaultHeadroom) < 0.001 } ?? true
            guard kind == .pq, onTheDefault else { return "Peak not stated" }
            return "Peak not stated; macOS assumes \(grouped(nits(headroom: defaultHeadroom))) nits"
        }
    }

    /// EXIF orientations 5 to 8 turn the picture a quarter, swapping width and height.
    public static func orientationSwapsAxes(_ orientation: Int) -> Bool { (5...8).contains(orientation) }

    /// "2024:05:01 12:34:56" as EXIF writes it, in the form people read. The file states no time zone here, so none is
    /// applied. Anything else is passed through: it is the file's text, and a wrong guess would be worse.
    public static func captureDate(_ exif: String) -> String {
        let parts = exif.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 10, parts[0].filter({ $0 == ":" }).count == 2 else { return exif }
        return parts[0].replacingOccurrences(of: ":", with: "-") + " " + parts[1]
    }
}

/// Everything the UI says about an open still.
public struct StillImageInfo: Sendable, Equatable {
    public var fileName: String
    /// The system's name for the file's type, such as "JPEG image".
    public var format: String
    /// With EXIF orientation applied, so this is the shape on screen.
    public var displayWidth: Int
    public var displayHeight: Int
    public var rotated: Bool
    public var colorProfile: String?
    public var bitDepth: Int?
    public var hdr: StillHDRKind
    public var headroomRow: String?
    public var captureDate: String?
    public var fileCreated: Date?
    public var fileModified: Date?

    public init(fileName: String, format: String, displayWidth: Int, displayHeight: Int, rotated: Bool,
                colorProfile: String?, bitDepth: Int?, hdr: StillHDRKind, headroomRow: String?, captureDate: String?,
                fileCreated: Date?, fileModified: Date?) {
        self.fileName = fileName
        self.format = format
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.rotated = rotated
        self.colorProfile = colorProfile
        self.bitDepth = bitDepth
        self.hdr = hdr
        self.headroomRow = headroomRow
        self.captureDate = captureDate
        self.fileCreated = fileCreated
        self.fileModified = fileModified
    }

    public var dimensions: String { "\(displayWidth) × \(displayHeight)" + (rotated ? " (rotated)" : "") }

    /// What sits where the scrubber does: "Still image · 4032 × 3024 · HDR (gain map)".
    public var transportLine: String { "Still image · \(displayWidth) × \(displayHeight) · \(hdr.shortLabel)" }

    /// The Inspector's rows between the file name and the file dates, in order. Absent facts are absent rows.
    public var inspectorRows: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = [("Format", format), ("Dimensions", dimensions),
                                                      ("Color Profile", colorProfile ?? "Untagged")]
        if let bitDepth { rows.append(("Bit Depth", "\(bitDepth)-bit")) }
        rows.append(("HDR Type", hdr.typeRow))
        if let headroomRow { rows.append(("Headroom", headroomRow)) }
        if let captureDate { rows.append(("Capture Date", captureDate)) }
        return rows
    }
}
