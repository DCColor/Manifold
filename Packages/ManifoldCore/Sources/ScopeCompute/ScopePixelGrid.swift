import Foundation

/// Where to put a straight graticule line so it lands on whole device pixels (0.9.5, docs/SCOPES_095_PLAN.md §2.1).
///
/// A line is drawn centered on its coordinate. A 1-pt line is 1 px at 1× (the LG and the ASUS on the Mac Studio both
/// run at 1×), 2 px at 2×. Centered on an arbitrary fraction, Core Graphics anti-aliases it across two pixel rows at
/// partial intensity each, which is a large part of why the scope graticules read dim. So:
///
/// - an ODD number of device pixels wide is centered on a pixel's middle (`n + 0.5` px);
/// - an EVEN number is centered on a pixel boundary (`n` px).
///
/// Both hold at every scale, so the same call is right at 1×, 2× and 3×. A width under one device pixel counts as one.
/// The move is at most half a device pixel (odd) or half a pixel either way (even); positions are already rounded to
/// the plot's pixels by the trace image itself, so this does not cost measurement accuracy that was there.
///
/// Pure arithmetic in points and a scale factor; the app converts from `CGFloat`. Tested in ScopeComputeTests.
public enum ScopePixelGrid {

    /// The line width in whole device pixels, at least 1.
    public static func devicePixels(lineWidth: Double, scale: Double) -> Double {
        let s = scale > 0 ? scale : 1
        return max(1, (lineWidth * s).rounded())
    }

    /// The aligned center, in points, for a line of `lineWidth` points meant to sit at `coordinate` points.
    ///
    /// `extent`: the drawing area's size along the same axis, in points. When given, the line is kept wholly inside
    /// it — a line meant for the very edge (the 0 or the 1023 line, at y = height or 0) is moved inward rather than
    /// half clipped. The clamp keeps the result on the grid.
    public static func alignedCenter(_ coordinate: Double, lineWidth: Double, scale: Double,
                                     extent: Double? = nil) -> Double {
        let s = scale > 0 ? scale : 1
        let px = devicePixels(lineWidth: lineWidth, scale: s)
        let odd = Int(px) % 2 == 1
        var c = odd ? (coordinate * s).rounded(.down) + 0.5 : (coordinate * s).rounded()
        if let extent {
            let lo = px / 2
            let hi = (extent * s).rounded(.down) - px / 2
            if hi >= lo { c = min(max(c, lo), hi) }
        }
        return c / s
    }
}
