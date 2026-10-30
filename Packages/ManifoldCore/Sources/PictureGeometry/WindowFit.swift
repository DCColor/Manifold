//
//  WindowFit.swift
//  PictureGeometry
//
//  THE PLAYER WINDOW'S SIZE SOLVE, moved out of `WindowSizer` so `swift test` can hold it to a laptop's screen.
//  `WindowSizer`'s header is the design (the affine constraint, the invariant that chrome never shrinks the picture,
//  the two routes by which chrome touches the geometry). This file is that solve, unchanged in shape, with two floors
//  where it had one. docs/BUGS.md, "iPhone clips open rotated or flipped" (the window half).
//
//  ── THE TWO FLOORS ────────────────────────────────────────────────────────────────────────────────────────────
//
//  Until 2026-10-29 the PICTURE could never be narrower than the WINDOW's minimum width (720 pt, the control bar's
//  single row: `ContentView().frame(minWidth: 720, …)`), and neither could the screen cap's width budget. For a
//  landscape picture that is harmless. For a 9:16 picture it means 720 × 1280 at the least, on any screen: MEASURED by
//  Robbie and Joey on a MacBook Air at 2048 × 1332, IMG_9457.MOV opened taller than the screen and could not be made
//  smaller. Now:
//
//    * THE WINDOW FLOOR (`.window`): a FRESH size (a source opening, a raster preset, a new source's shape) fills at
//      least the window's minimum width, exactly as before. Landscape files open as they always did.
//    * THE PICTURE FLOOR (`.picture`): the user's own resize, and a re-solve that keeps the picture the user left, may
//      shrink the picture until its SHORTER side is `pictureMinimumShortSide`. The window never goes below its own
//      minimum; a picture narrower than it is pillarboxed in it, which `.aspectRatio(.fit)` already does.
//    * THE SCREEN CAP outranks both: a window never opens or grows past the visible frame. The picture shrinks to fit,
//      on-shape, down to `absoluteMinimumWidth`, which only a screen too small to hold the window's own minimum reaches.
//

import CoreGraphics

public enum WindowFit {

    /// The picture's smallest shorter side under the user's hand, in points. 320 fits a 9:16 picture with the control
    /// bar on any Mac laptop's screen (a 13-inch Air at its smallest scaled resolution is 1280 × 800 pt).
    public static let pictureMinimumShortSide: CGFloat = 320

    /// The screen cap's last resort, so a degenerate screen still yields a finite, positive picture.
    public static let absoluteMinimumWidth: CGFloat = 64

    public enum Floor: Sendable { case window, picture }

    public struct Solution: Equatable, Sendable {
        /// The window's content size: the picture's box plus the chrome below it, padded to the window's minimum.
        public let content: CGSize
        /// The picture's width inside it. Less than `content.width` exactly when the picture is pillarboxed.
        public let pictureWidth: CGFloat
        /// The screen cap's width budget this solve ran under (for `WindowSizer`'s DEBUG invariant check).
        public let widthBudget: CGFloat
        public var isPillarboxed: Bool { pictureWidth + 0.5 < content.width }
    }

    /// The picture floor's width for a shape: the width at which the shorter side is `pictureMinimumShortSide`.
    public static func pictureFloorWidth(aspect: CGFloat) -> CGFloat {
        let aspect = max(aspect, 0.01)
        return aspect >= 1 ? pictureMinimumShortSide * aspect : pictureMinimumShortSide
    }

    /// The floor a request is clamped to. The window floor is the window's minimum width, as it always was. The picture
    /// floor is the 320-pt short side, but never wider than the window floor: a picture wider than 2.25:1 already has a
    /// short side under 320 at the window's minimum width, and the floor must not make it wider than it could be before.
    public static func floorWidth(_ floor: Floor, aspect: CGFloat, minContent: CGSize) -> CGFloat {
        floor == .window ? minContent.width : min(pictureFloorWidth(aspect: aspect), minContent.width)
    }

    /// THE CONSTRAINT: `contentH = pictureW / aspect + chrome`, at (or as near as possible to) the requested picture
    /// width, clamped to the floor, the window's minimum and the screen.
    public static func solve(pictureWidth requested: CGFloat, aspect: CGFloat, chrome: CGFloat, floor: Floor,
                             minContent: CGSize, maxContent: CGSize) -> Solution {
        let aspect = max(aspect, 0.01)
        let chrome = max(chrome, 0)
        let floorW = floorWidth(floor, aspect: aspect, minContent: minContent)

        // ── ROUTE 2 — THE SCREEN CAP, AND THE ONLY PLACE CHROME MAY COST PICTURE ──────────────────────────────────
        // Charged against the screen's height and spent as a WIDTH the picture may not exceed, so the picture stays
        // on-shape while it shrinks. No longer floored at the window's minimum width: that floor is what let a 9:16
        // picture overflow a laptop screen.
        let heightBudget = max(maxContent.height - chrome, 1)
        let widthBudget = max(min(maxContent.width, VideoBox.width(height: heightBudget, aspect: aspect)),
                              absoluteMinimumWidth)

        // ── THE PICTURE, SIZED WITHOUT REFERENCE TO CHROME ───────────────────────────────────────────────────────
        var videoW = min(max(requested, floorW), widthBudget)

        // The window's own minimum height can exceed the constraint at this width. Honour it by GROWING the picture,
        // never by shrinking it, inside the screen cap.
        if VideoBox.height(width: videoW, aspect: aspect) + chrome < minContent.height {
            videoW = min(max(videoW, VideoBox.width(height: minContent.height - chrome, aspect: aspect)), widthBudget)
        }

        // ── ROUTE 1 — CHROME IS ADDED. THE OPERATOR IS `+`. ─────────────────────────────────────────────────────
        let videoH = VideoBox.height(width: videoW, aspect: aspect)
        // Both maxes are WINDOW-MINIMUM effects, not chrome effects: the window is at least its minimum, and a picture
        // smaller than that sits in it pillarboxed (or, past the screen cap, letterboxed).
        let content = CGSize(width: max(videoW, minContent.width).rounded(),
                             height: max(videoH + chrome, minContent.height).rounded())
        return Solution(content: content, pictureWidth: videoW.rounded(), widthBudget: widthBudget)
    }

    /// The width of the picture a window of this content size is showing, for a re-solve that must keep it. Exactly
    /// the content width unless the last solve pillarboxed the picture and the window has not moved since.
    public static func currentPictureWidth(contentWidth: CGFloat, last: Solution?) -> CGFloat {
        guard let last, last.isPillarboxed, abs(contentWidth - last.content.width) < 1 else { return contentWidth }
        return last.pictureWidth
    }
}

/// The picture's geometry. No member of this type can see the chrome height (`WindowSizer`'s header).
enum VideoBox {
    static func height(width: CGFloat, aspect: CGFloat) -> CGFloat { width / max(aspect, 0.01) }
    static func width(height: CGFloat, aspect: CGFloat) -> CGFloat { height * max(aspect, 0.01) }
}
