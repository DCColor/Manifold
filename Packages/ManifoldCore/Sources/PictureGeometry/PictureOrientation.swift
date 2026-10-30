//
//  PictureOrientation.swift
//  PictureGeometry
//
//  WHICH WAY UP A FILE'S PICTURE IS: the 2×2 part of its display matrix, reduced to one of the eight axis-aligned
//  transforms (four rotations, each with or without a mirror). docs/BUGS.md, "iPhone clips open rotated or flipped".
//
//  ── THE CONVENTION, STATED ONCE ───────────────────────────────────────────────────────────────────────────────
//
//  QuickTime's track matrix, AVFoundation's `preferredTransform` and libav's display matrix are the same nine numbers,
//  row-major `a b u / c d v / tx ty w`, and map a stored pixel (x, y) to the displayed one as
//
//      x' = a·x + c·y + tx        y' = b·x + d·y + ty
//
//  in image coordinates, y DOWN. So `a=0 b=1 c=−1 d=0` is a 90° CLOCKWISE turn: what an iPhone held upright writes,
//  what exiftool calls "Rotation 90" and what ffmpeg calls "rotation of -90.00 degrees" (ffmpeg counts the other way).
//  MEASURED 2026-10-29 on IMG_9457.MOV: tkhd `0 1 0 -1 0 0 2160 0 1`, QuickTime shows it upright as 2160×3840.
//
//  The translation is not used. It only moves the turned picture back onto the canvas, and every player draws the
//  turned picture into its own bounding box; ffmpeg writes 0 there (measured), Apple writes the size.
//
//  ── WHAT IS NOT APPLIED ───────────────────────────────────────────────────────────────────────────────────────
//
//  Anything that is not one of the eight (a 45° turn, a skew, a degenerate matrix) is REFUSED, not rounded: the file
//  is drawn as stored, as it always was, and the caller logs the matrix. Manifold applies the standard; it does not
//  guess at a non-standard one. A uniform scale is not a refusal: it is divided out, because it changes no direction.
//

import Foundation

public struct PictureOrientation: Equatable, Hashable, Sendable, CustomStringConvertible {

    /// The matrix's 2×2 part, each entry −1, 0 or 1, in the file's own naming (see the header).
    public let a: Int, b: Int, c: Int, d: Int

    public static let identity = PictureOrientation(uncheckedA: 1, b: 0, c: 0, d: 1)

    private init(uncheckedA a: Int, b: Int, c: Int, d: Int) {
        self.a = a; self.b = b; self.c = c; self.d = d
    }

    /// The result of reading a matrix: one of the eight, or the reason it is not applied.
    public enum Reading: Equatable, Sendable {
        case orientation(PictureOrientation)
        /// Not axis-aligned, or degenerate. The picture is drawn as stored.
        case notApplied(String)

        /// What to draw with: the orientation, or identity for a refused matrix.
        public var applied: PictureOrientation {
            if case .orientation(let o) = self { return o }
            return .identity
        }
    }

    /// From the 2×2 part of a matrix in the file's naming (AVFoundation's `CGAffineTransform.a…d`).
    public static func read(a: Double, b: Double, c: Double, d: Double) -> Reading {
        let det = a * d - b * c
        guard [a, b, c, d].allSatisfy(\.isFinite), abs(det) > 1e-9 else {
            return .notApplied("degenerate matrix \(format(a, b, c, d))")
        }
        let scale = sqrt(abs(det))
        func unit(_ v: Double) -> Int? {
            let n = v / scale
            for k in [-1, 0, 1] where abs(n - Double(k)) < 1e-3 { return k }
            return nil
        }
        guard let ia = unit(a), let ib = unit(b), let ic = unit(c), let id = unit(d),
              // Exactly one non-zero per row and per column: a turn by a multiple of 90°, with or without a mirror.
              (ia != 0) == (id != 0), (ib != 0) == (ic != 0), (ia != 0) != (ib != 0)
        else { return .notApplied("not a multiple of 90° \(format(a, b, c, d))") }
        return .orientation(PictureOrientation(uncheckedA: ia, b: ib, c: ic, d: id))
    }

    /// From libav's `AV_PKT_DATA_DISPLAYMATRIX`: nine `int32`, row-major, `a b c d` in 16.16 fixed point.
    public static func read(displayMatrix m: [Int32]) -> Reading {
        guard m.count == 9 else { return .notApplied("display matrix has \(m.count) entries, not 9") }
        let f = { (i: Int) in Double(m[i]) / 65536.0 }
        return read(a: f(0), b: f(1), c: f(3), d: f(4))
    }

    // MARK: - What it does to the raster

    /// True for a quarter turn: the displayed raster is the stored one with width and height exchanged.
    public var swapsAxes: Bool { a == 0 }

    /// True when the picture is mirrored (the determinant is −1).
    public var isMirrored: Bool { a * d - b * c < 0 }

    public var isIdentity: Bool { self == .identity }

    /// The displayed raster for a stored one.
    public func displayedSize(width: Int, height: Int) -> (width: Int, height: Int) {
        swapsAxes ? (height, width) : (width, height)
    }

    /// A pixel aspect ratio (h:v of the STORED pixel) as the displayed pixel has it: exchanged by a quarter turn.
    public func displayedPixelAspect(horizontal h: Int, vertical v: Int) -> (horizontal: Int, vertical: Int) {
        swapsAxes ? (v, h) : (h, v)
    }

    /// THE SAMPLING RULE, the one the offscreen pass's vertex stage applies. For a displayed position `o` and the stored
    /// position `s` it shows, both normalised to their own raster and centred (−½…½):
    ///
    ///     s.x = m00·o.x + m01·o.y        s.y = m10·o.x + m11·o.y
    ///
    /// The inverse of the file's map, which for these eight is its transpose — hence `a b / c d` in that order. The
    /// identity is `1 0 / 0 1`, so an unrotated file computes exactly the texture coordinates it always did.
    public var sampling: (m00: Int, m01: Int, m10: Int, m11: Int) { (a, b, c, d) }

    /// The stored pixel a displayed pixel shows, by the sampling rule at pixel centres. The CPU reference the shader is
    /// held to, and what the tests check against explicitly written rotations.
    public func storedPixel(forDisplayed x: Int, _ y: Int, storedWidth w: Int, storedHeight h: Int) -> (x: Int, y: Int) {
        let out = displayedSize(width: w, height: h)
        let ox = (Double(x) + 0.5) / Double(out.width) - 0.5
        let oy = (Double(y) + 0.5) / Double(out.height) - 0.5
        let sx = Double(a) * ox + Double(b) * oy + 0.5
        let sy = Double(c) * ox + Double(d) * oy + 0.5
        return (Int((sx * Double(w)).rounded(.down)), Int((sy * Double(h)).rounded(.down)))
    }

    // MARK: - Said in words

    /// The clockwise turn, before any mirror: the file's map is "turn, then mirror left to right (if mirrored)".
    public var clockwiseDegrees: Int {
        // Undo the mirror (x′ → −x′, applied last, so it negates the x′ row: a and c) and read the turn from where the
        // stored x axis lands, (a, b).
        let (ra, rb) = isMirrored ? (-a, b) : (a, b)
        switch (ra, rb) {
        case (1, 0):  return 0
        case (0, 1):  return 90
        case (-1, 0): return 180
        default:      return 270
        }
    }

    /// The Inspector's words for it.
    public var description: String {
        switch (clockwiseDegrees, isMirrored) {
        case (0, false):   return "None"
        case (180, false): return "Rotated 180°"
        case (let r, false): return "Rotated \(r)° clockwise"
        case (0, true):    return "Mirrored left to right"
        case (180, true):  return "Mirrored top to bottom"
        case (let r, true): return "Rotated \(r)° clockwise, then mirrored left to right"
        }
    }

    /// One log token, e.g. `rot90cw`, `hflip`, `rot90cw+hflip`.
    public var logToken: String {
        switch (clockwiseDegrees, isMirrored) {
        case (0, false):     return "none"
        case (let r, false): return "rot\(r)cw"
        case (0, true):      return "hflip"
        case (let r, true):  return "rot\(r)cw+hflip"
        }
    }

    private static func format(_ v: Double...) -> String {
        "[" + v.map { String(format: "%.4g", $0) }.joined(separator: " ") + "]"
    }
}
