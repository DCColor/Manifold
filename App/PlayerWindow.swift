import SwiftUI
import AppKit

/// Full-bleed NSWindow tweaks. Overlay mode locks the window to the clip's pure
/// aspect. Docked mode locks the window to "clip aspect + bar height".
struct WindowConfigurator: NSViewRepresentable {
    var buttonsVisible: Bool
    var displaySize: CGSize?
    var mode: ControlDisplayMode
    var barHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let hasClip = (displaySize != nil)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
            if !hasClip {
                window.contentAspectRatio = .zero
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

        let extraH = (mode == .docked) ? barHeight : 0
        let targetAspect = NSSize(width: size.width, height: size.height + extraH)

        if window.contentAspectRatio != targetAspect {
            window.contentAspectRatio = targetAspect
            if let screen = window.screen ?? NSScreen.main {
                let maxW = screen.visibleFrame.width * 0.8
                let maxH = screen.visibleFrame.height * 0.8
                let scale = min(maxW / size.width, (maxH - extraH) / size.height, 1.0)
                let contentSize = NSSize(
                    width: size.width * scale,
                    height: size.height * scale + extraH
                )
                window.setContentSize(contentSize)
                window.center()
            }
        }
    }
}
