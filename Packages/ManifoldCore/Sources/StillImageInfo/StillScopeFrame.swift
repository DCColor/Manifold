//
//  StillScopeFrame.swift
//  StillImageInfo
//
//  What the scopes read for a still: the FILE's stored code values, not the display's picture. Principle as for video
//  (Robbie, 2026-11-05): scopes show the file. The window's route C decode is a separate image and never comes here.
//

import CoreGraphics
import Foundation
import ImageIO

/// What the scope maths and headers use for a still. Nil codes mean nothing was stated, and the scopes resolve them as
/// Rec. 709, which `note` then says.
public struct StillScopeColor: Sendable, Equatable {
    public var primaries: Int?
    public var transfer: Int?
    public var matrix: Int?
    /// Said on every scope header when the reading needs a caveat.
    public var note: String?

    public init(primaries: Int?, transfer: Int?, matrix: Int?, note: String?) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.note = note
    }
}

/// A CICP triple as a file states it.
public struct StatedCICP: Sendable, Equatable {
    public var primaries: Int
    public var transfer: Int
    public var matrix: Int
    public init(primaries: Int, transfer: Int, matrix: Int) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
    }
}

/// One frame for the scopes: RGBX, 16 bits a channel, native-endian unsigned, top row first, EXIF orientation applied.
public struct StillScopeFrame: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: Data
    public let color: StillScopeColor

    public var bytesPerRow: Int { width * 8 }
}

public enum StillScopeTags {
    public static let gainMapNote = "SDR base image (gain map not applied)"
    static let untaggedNote = "Untagged: read as Rec. 709"

    /// CICP has no code for a profile it did not name (Adobe RGB), so the scopes have no primaries for it.
    static func unmappedNote(_ profile: String) -> String { "\(profile): no CICP code, read as Rec. 709" }

    /// An RGB file carries no YCbCr matrix of its own, so luma weights follow its primaries.
    private static func defaultMatrix(primaries: Int?) -> Int? { primaries == 9 ? 9 : 1 }

    /// Tags from the file, most direct first: the CICP it states, then its profile.
    public static func resolve(cicp: StatedCICP?, profile: ICCProfileFacts?, spaceName: String?, profileName: String?,
                               hasGainMap: Bool) -> StillScopeColor {
        var primaries: Int?
        var transfer: Int?
        var matrix: Int?

        if let cicp, cicp.primaries != 2 || cicp.transfer != 2 {
            primaries = cicp.primaries == 2 ? nil : cicp.primaries
            transfer = cicp.transfer == 2 ? nil : cicp.transfer
            // 0 is identity (the file is stored as RGB), and 2 unspecified: neither gives luma weights.
            matrix = (cicp.matrix == 0 || cicp.matrix == 2) ? defaultMatrix(primaries: primaries) : cicp.matrix
        } else if let named = named(spaceName) {
            (primaries, transfer, matrix) = (named.primaries, named.transfer, named.matrix)
        } else if let profile, profile.primaries != nil {
            primaries = profile.primaries
            transfer = profile.transfer
            matrix = defaultMatrix(primaries: primaries)
        }

        let tagged = primaries != nil || transfer != nil
        let note: String?
        if hasGainMap {
            note = gainMapNote
        } else if tagged {
            note = nil
        } else if let profileName {
            note = unmappedNote(profileName)
        } else {
            note = untaggedNote
        }
        return StillScopeColor(primaries: primaries, transfer: transfer, matrix: matrix, note: note)
    }

    private static func named(_ name: String?) -> StatedCICP? {
        switch name.map({ $0 as CFString }) {
        case CGColorSpace.sRGB?: return StatedCICP(primaries: 1, transfer: 13, matrix: 1)
        case CGColorSpace.displayP3?: return StatedCICP(primaries: 12, transfer: 13, matrix: 1)
        case CGColorSpace.itur_709?: return StatedCICP(primaries: 1, transfer: 1, matrix: 1)
        case CGColorSpace.itur_2020?: return StatedCICP(primaries: 9, transfer: 1, matrix: 9)
        case CGColorSpace.itur_2100_PQ?: return StatedCICP(primaries: 9, transfer: 16, matrix: 9)
        case CGColorSpace.itur_2100_HLG?: return StatedCICP(primaries: 9, transfer: 18, matrix: 9)
        default: return nil
        }
    }
}

/// What an ICC profile's tags say, for a profile macOS gives no name to, such as GradeShare's "Display P3 Gamut with sRGB
/// Transfer".
public struct ICCProfileFacts: Sendable, Equatable {
    public var primaries: Int?
    public var transfer: Int?

    public init(primaries: Int?, transfer: Int?) {
        self.primaries = primaries
        self.transfer = transfer
    }

    /// Red, green and blue colorants, PCS (D50) XYZ, per CICP primaries code.
    private static let colorants: [(code: Int, xyz: [Double])] = [
        (1, [0.4360, 0.2225, 0.0139, 0.3851, 0.7169, 0.0971, 0.1431, 0.0606, 0.7139]),
        (12, [0.5151, 0.2412, -0.0011, 0.2920, 0.6922, 0.0419, 0.1571, 0.0666, 0.7841]),
        (9, [0.6734, 0.2790, -0.0019, 0.1656, 0.6753, 0.0298, 0.1251, 0.0456, 0.7973]),
    ]

    /// Nil when the bytes are not a readable ICC profile. Unknown colorants or curve leave that half nil.
    public init?(icc data: Data) {
        let bytes = [UInt8](data)
        func u32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= bytes.count else { return nil }
            return (0..<4).reduce(0) { ($0 << 8) | Int(bytes[o + $1]) }
        }
        func s15(_ o: Int) -> Double? { u32(o).map { Double(Int32(truncatingIfNeeded: $0)) / 65536 } }
        guard let count = u32(128), count < 1000 else { return nil }
        var tags: [String: Int] = [:]
        for i in 0..<count {
            let entry = 132 + i * 12
            guard entry + 12 <= bytes.count, let offset = u32(entry + 4) else { return nil }
            tags[String(decoding: bytes[entry..<(entry + 4)], as: UTF8.self)] = offset
        }

        var xyz: [Double] = []
        for tag in ["rXYZ", "gXYZ", "bXYZ"] {
            guard let at = tags[tag], let x = s15(at + 8), let y = s15(at + 12), let z = s15(at + 16) else { break }
            xyz += [x, y, z]
        }
        if xyz.count == 9 {
            primaries = Self.colorants.first { known in zip(known.xyz, xyz).allSatisfy { abs($0 - $1) < 0.003 } }?.code
        }

        if let at = tags["rTRC"], at + 12 <= bytes.count {
            let kind = String(decoding: bytes[at..<(at + 4)], as: UTF8.self)
            // The sRGB curve as ICC writes it: `para` function type 3 or 4, γ 2.4, a = 1/1.055. GradeShare writes type 4.
            if kind == "para", let function = u32(at + 8).map({ $0 >> 16 }), function == 3 || function == 4,
               let g = s15(at + 12), let a = s15(at + 16), abs(g - 2.4) < 0.01, abs(a - 1 / 1.055) < 0.001 {
                transfer = 13
            }
        }
    }
}

enum StillScopeDecode {
    /// A larger still is taken every Nth pixel, never filtered, so what the scopes read are still the file's values.
    static let largestSide = 8192

    /// How EXIF `orientation` maps a `width` × `height` image onto its upright canvas, y up.
    static func transform(orientation: Int, width: CGFloat, height: CGFloat) -> CGAffineTransform {
        switch orientation {
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
        case 3: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 4: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        case 5: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: height, ty: width)
        case 6: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        case 7: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        default: return .identity
        }
    }

    /// The stored picture, with no colour conversion: ImageIO's plain decode, so no gain map, drawn into a context in the
    /// image's OWN colour space, where the draw has nothing to convert.
    ///
    /// Nil for what has no RGB code values to show: CMYK, Lab. Alpha is not read; a transparent pixel reads as black.
    static func frame(_ source: CGImageSource, index: Int, orientation: Int, color: StillScopeColor) -> StillScopeFrame? {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil), let stored = image.colorSpace else { return nil }
        let space: CGColorSpace?
        switch stored.model {
        case .rgb, .monochrome: space = stored
        case .indexed: space = stored.baseColorSpace
        default: space = nil
        }
        guard let space else { return nil }

        let swaps = StillText.orientationSwapsAxes(orientation)
        let upright = (w: swaps ? image.height : image.width, h: swaps ? image.width : image.height)
        let scale = min(1, Double(largestSide) / Double(max(upright.w, upright.h)))
        let width = max(1, Int(Double(upright.w) * scale)), height = max(1, Int(Double(upright.h) * scale))

        let gray = space.model == .monochrome
        let channels = gray ? 1 : 4
        let rowBytes = width * channels * 2
        var pixels = Data(count: rowBytes * height)
        let drew: Bool = pixels.withUnsafeMutableBytes { buffer in
            let info = (gray ? CGImageAlphaInfo.none : .noneSkipLast).rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 16,
                                          bytesPerRow: rowBytes, space: space, bitmapInfo: info) else { return false }
            context.interpolationQuality = .none
            context.scaleBy(x: scale, y: scale)
            context.concatenate(transform(orientation: orientation, width: CGFloat(image.width), height: CGFloat(image.height)))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drew else { return nil }
        if gray { pixels = expandGray(pixels, count: width * height) }
        return StillScopeFrame(width: width, height: height, pixels: pixels, color: color)
    }

    private static func expandGray(_ gray: Data, count: Int) -> Data {
        var out = Data(count: count * 8)
        gray.withUnsafeBytes { source in
            out.withUnsafeMutableBytes { target in
                let from = source.bindMemory(to: UInt16.self), to = target.bindMemory(to: UInt16.self)
                for i in 0..<count {
                    let v = from[i]
                    to[i * 4] = v; to[i * 4 + 1] = v; to[i * 4 + 2] = v; to[i * 4 + 3] = .max
                }
            }
        }
        return out
    }
}
