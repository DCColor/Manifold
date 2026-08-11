import SwiftUI
import AppKit

/// Full-bleed NSWindow locked to the clip's aspect for BOTH modes (overlay and
/// docked are now both overlays over the video, so the window is always just the
/// video — it scales as one piece). Traffic-light buttons fade with the controls.
struct WindowConfigurator: NSViewRepresentable {
    var buttonsVisible: Bool
    var displaySize: CGSize?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let hasClip = (displaySize != nil)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
            if !hasClip {
                // Clear any aspect constraint the RIGHT way. This used to assign
                // `contentAspectRatio = .zero`, which is NOT "no constraint" — it marks the window
                // as aspect-CONSTRAINED with a degenerate 0/0 ratio, and AppKit's resize math then
                // trips over the resulting invalid geometry and hits an internal __builtin_trap
                // (EXC_BREAKPOINT in -[NSWindow _adjustNeedsDisplayRegionForNewFrame:]) on the
                // first resize. Aspect ratio and resize increments are mutually exclusive in
                // AppKit, so setting increments to 1×1 is the documented way to drop the aspect
                // lock and allow free resizing.
                window.resizeIncrements = NSSize(width: 1, height: 1)
                let defaultSize: NSSize
                if let screen = window.screen ?? NSScreen.main {
                    let w = min(screen.visibleFrame.width * 0.6, 1280)
                    defaultSize = NSSize(width: w, height: (w * 9.0 / 16.0).rounded())
                } else {
                    defaultSize = NSSize(width: 960, height: 540)
                }
                window.setContentSize(defaultSize)
                window.center()
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }

        let buttons: [NSButton?] = [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton)
        ]
        let target: CGFloat = buttonsVisible ? 1 : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.30
            for button in buttons { button?.animator().alphaValue = target }
        }

        guard let size = displaySize, size.width > 0, size.height > 0 else { return }
        let aspect = NSSize(width: size.width, height: size.height)
        // ── COMPARED AS A RATIO, NOT AS A SIZE, AND THAT DISTINCTION IS NOW LOAD-BEARING ──────
        //
        // `contentAspectRatio` is a RATIO: 1920×1080 and 1280×720 are the same constraint, and
        // AppKit treats them as such. The old `!=` on the raw NSSize did not — so any change of
        // RESOLUTION re-locked the window and, with it, ran the resize-and-centre below.
        //
        // That was harmless while only files wrote `displaySize` (one value per open). It is not
        // harmless now that live sources publish theirs per frame: a WHEP sender switching spatial
        // layer, or an SRT encoder changing resolution, changes the numbers without changing the
        // shape, and the window would jump and re-centre itself under the user mid-stream — while
        // they are grading, on a stream whose picture did not change shape at all.
        //
        // The visible consequence for FILES is deliberate and small: opening a 4K file after a
        // 1080p one no longer resizes and re-centres the window, because nothing about the frame
        // it must be drawn in has changed. The window stays where the user put it. Absolute sizing
        // is the window-sizing arc's subject, not this guard's.
        let current = window.contentAspectRatio
        let sameShape = current.width > 0 && current.height > 0
            && abs(current.width / current.height - aspect.width / aspect.height) < 0.0001
        if !sameShape {
            window.contentAspectRatio = aspect
            if let screen = window.screen ?? NSScreen.main {
                let maxW = screen.visibleFrame.width * 0.8
                let maxH = screen.visibleFrame.height * 0.8
                let scale = min(maxW / size.width, maxH / size.height, 1.0)
                let contentSize = NSSize(width: size.width * scale, height: size.height * scale)
                window.setContentSize(contentSize)
                window.center()
            }
        }
    }
}
