import SwiftUI
import QuartzCore

/// Hosts a MetalVideoRenderer's CAMetalLayer. Temporary M1 test surface.
struct MetalSurfaceView: NSViewRepresentable {
    let renderer: MetalVideoRenderer

    func makeNSView(context: Context) -> MetalHostView {
        let view = MetalHostView()
        view.wantsLayer = true
        view.metalLayer = renderer.metalLayer
        view.layer = renderer.metalLayer
        renderer.metalLayer.frame = view.bounds
        return view
    }

    func updateNSView(_ nsView: MetalHostView, context: Context) {
        renderer.metalLayer.frame = nsView.bounds
    }
}

final class MetalHostView: NSView {
    var metalLayer: CAMetalLayer?

    override func layout() {
        super.layout()
        // Keep the metal layer filling the view; account for backing scale.
        if let metalLayer {
            metalLayer.frame = bounds
            let scale = window?.backingScaleFactor ?? 2.0
            metalLayer.contentsScale = scale
        }
    }
}
