//
//  ShareJPEG.swift
//  FrameShareFormat — what Share Frame sends (Robbie, 2026-11-15): an 8-bit SDR JPEG, Rec. 709 primaries, tagged sRGB,
//  quality 0.9. Export Frame is unchanged (the full-quality 16-bit PNG, tagged with the picture's own colour space).
//
//  ── THE CONVERSION IS ONE COREGRAPHICS DRAW ─────────────────────────────────────────────────────────────────────────────
//
//  The frame (Export Frame's CGImage: the picture's pixels under the picture's colour space) is drawn with
//  `CGContext.draw(_:in:)` into an 8-bit RGB bitmap context whose colour space is sRGB. ColorSync converts on the way in,
//  and for an HDR picture applies its default HDR → SDR tone mapping (`CGContextDrawImage`, the behaviour
//  `kCGToneMappingDefault` names in `CGToneMapping.h`). No Core Image, no hand-written curve.
//
//  WHAT IT MATCHES, measured offline 2026-11-15 (grey ramps into sRGB; docs/HLG_MACOS_MODE_PLAN.md §3.10e):
//    * SDR: the same ColorSync conversion the compositor applies to the layer.
//    * HLG: As macOS Shows It on an SDR display (§3.6a T3, `.ifSupported`), within 1 code at every 5 % bar.
//    * PQ:  the compositor's `.ifSupported` curve (§3.10b (c)), NOT the `.automatic` + HDR10 curve As macOS Shows It uses
//           for PQ (§3.10b (b)). Darker below ~200 nits (100 nits 140 against 152, 10 nits 49 against 64) and up to 6 codes
//           brighter from 300 to 600 nits. No CoreGraphics, Core Image or ImageIO call measured reproduces (b); see §3.10e.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ShareJPEG {

    /// JPEG quality (Robbie, 2026-11-15: "high quality, about 0.9").
    public static let quality: Double = 0.9

    /// The colour space every shared JPEG carries.
    public static let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// `image` drawn into an 8-bit sRGB bitmap: converted, and tone-mapped when it is HDR, by ColorSync. nil only if the
    /// context cannot be made.
    public static func sdrImage(from image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none   // same size: no resampling, only the colour conversion
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// The JPEG bytes for `image`: `sdrImage`, then ImageIO at `quality`. `properties` are passed through to the
    /// destination (Export Frame's pixel-aspect DPI pair, which JPEG writes as JFIF density). nil on any failure.
    public static func encode(_ image: CGImage, properties: [CFString: Any]? = nil) -> Data? {
        guard let sdr = sdrImage(from: image) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        var props = properties ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(dest, sdr, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
