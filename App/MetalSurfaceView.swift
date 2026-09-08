import SwiftUI
import QuartzCore
import AppKit

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

    // ⚠️⚠️ TEMPORARY DIAGNOSTIC — REMOVE BEFORE COMMIT. Grep `[GEOM-DIAG]`. ⚠️⚠️
    //
    // Chasing: the picture is correctly proportioned at 2.667:1 but does not fill an
    // aspect-fitted region that IS 2.667:1, so this view is inset within the inner ZStack.
    // `drawnVideoSize` measures the `.aspectRatio` modifier's frame, NOT this view's bounds —
    // nothing in the app measures this view, which is the number the diagnosis needs.
    //
    // ObjectIdentifier is as much the point as the size: `renderer.metalLayer` is ONE long-lived
    // layer owned by the renderer, and a CALayer has one superlayer. If two host views are alive
    // (the `if let renderer, !showReferenceLayer` child being re-created), the layer is re-parented
    // to the newer one while the older can still receive `layout()` and size the drawable from its
    // own stale bounds. Two distinct identifiers here is that, confirmed.
    //
    // De-duplicated on (identity, size, scale) so a live resize does not bury the signal; any NEW
    // identity or size still prints. The set is unbounded — another reason this is temporary.
    private static var geomDiagSeen: Set<String> = []

    override func layout() {
        super.layout()
        // ⚠️ TEMPORARY DIAGNOSTIC — REMOVE. See above.
        let diagKey = "M/\(ObjectIdentifier(self))/\(bounds.size)/\(window?.backingScaleFactor ?? -1)"
        if Self.geomDiagSeen.insert(diagKey).inserted {
            NSLog("[GEOM-DIAG] MetalHostView   bounds=%.1f×%.1f  scale=%@  id=%@",
                  bounds.size.width, bounds.size.height,
                  window?.backingScaleFactor.description ?? "nil-window",
                  String(describing: ObjectIdentifier(self)))
        }
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
