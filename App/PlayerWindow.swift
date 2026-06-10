import SwiftUI
import AppKit

/// Full-bleed NSWindow tweaks paired with .windowStyle(.hiddenTitleBar):
/// black background, draggable by video, traffic-light buttons that fade with
/// the HUD, and — when a clip's `displaySize` is known — locks the window's
/// aspect ratio to the video and sizes it sensibly to the screen.
struct WindowConfigurator: NSViewRepresentable {
    var buttonsVisible: Bool
    var displaySize: CGSize?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }

        // Fade the traffic-light buttons with the HUD.
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

        // When we know the clip's display size, match the window to it.
        guard let size = displaySize, size.width > 0, size.height > 0 else { return }
        let aspect = NSSize(width: size.width, height: size.height)

        // Only resize when the aspect actually changed, so the user's manual
        // resizing isn't fought on every state update.
        if window.contentAspectRatio != aspect {
            window.contentAspectRatio = aspect

            // Initial size: fit within ~80% of the visible screen, preserving aspect.
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
