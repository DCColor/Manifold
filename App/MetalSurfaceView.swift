import SwiftUI
import QuartzCore

/// Hosts a MetalVideoRenderer's CAMetalLayer. Temporary M1 test surface.
struct MetalSurfaceView: NSViewRepresentable {
    let renderer: MetalVideoRenderer

    func makeNSView(context: Context) -> MetalHostView {
        let view = MetalHostView()
        view.wantsLayer = true
        view.metalLayer = renderer.metalLayer
        view.renderer = renderer
        view.layer = renderer.metalLayer
        renderer.metalLayer.frame = view.bounds
        return view
    }

    func updateNSView(_ nsView: MetalHostView, context: Context) {
        nsView.renderer = renderer
        renderer.metalLayer.frame = nsView.bounds
    }
}

final class MetalHostView: NSView {
    var metalLayer: CAMetalLayer?

    /// The renderer whose drawable this view's size governs. Weak: the view is owned by the view
    /// tree and the renderer by the deck, and neither outlives the window — a strong reference here
    /// would close a cycle through `renderer.metalLayer === self.layer`.
    weak var renderer: MetalVideoRenderer?

    override func layout() {
        super.layout()
        // Keep the metal layer filling the view; account for backing scale.
        guard let metalLayer else { return }
        metalLayer.frame = bounds
        let scale = window?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale

        // ⚠️ THE VIEW'S SIZE IS WHAT SIZES THE DRAWABLE, AND THIS IS THE ONLY PLACE IT IS REPORTED.
        //
        // `metalLayer.autoResizeDrawable` is FALSE (see MetalVideoRenderer's init), so nothing else
        // derives the drawable from these bounds — if this call is lost the picture keeps rendering
        // at whatever raster it last had and Core Animation scales it, which looks like "the video
        // went slightly soft" and nothing else.
        //
        // NOT written to the layer here. `setLayoutSize` parks the value and the RENDER THREAD
        // installs it, because `drawableSize` is a CAMetalLayer property and the render thread is
        // inside `nextDrawable()` on that same layer. This is main; it hands over and touches
        // nothing. (`frame` and `contentsScale` above are ordinary layer-tree geometry that AppKit
        // owns and Core Animation serialises; `drawableSize` is neither.)
        renderer?.setLayoutSize(points: bounds.size, scale: scale)
    }
}
