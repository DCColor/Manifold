import SwiftUI
import AVFoundation

/// A display surface backed by an AVSampleBufferDisplayLayer.
///
/// Unlike VideoSurfaceView (which hosts an AVPlayerLayer and is driven by an
/// AVPlayer), this surface is fed decoded frames one at a time via `enqueue`.
/// It is the display end of the future frame-level engine (Step 4c).
///
/// NOT yet used by the app — built in isolation so the frame engine can target
/// it next. The existing AVPlayer path is untouched.
struct SampleBufferSurfaceView: NSViewRepresentable {
    /// Handed back on make so the owner can enqueue frames into this surface.
    let onMake: (SampleBufferNSView) -> Void

    func makeNSView(context: Context) -> SampleBufferNSView {
        let view = SampleBufferNSView()
        view.displayLayer.videoGravity = .resizeAspect
        onMake(view)
        return view
    }

    func updateNSView(_ nsView: SampleBufferNSView, context: Context) {
        // Nothing to push on state change yet; frames arrive via enqueue().
    }
}

/// An NSView whose backing layer is an AVSampleBufferDisplayLayer.
final class SampleBufferNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = AVSampleBufferDisplayLayer()
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // ⚠️⚠️ TEMPORARY DIAGNOSTIC — REMOVE BEFORE COMMIT. Grep `[GEOM-DIAG]`. ⚠️⚠️
    //
    // This class had NO `layout()` override; one is added purely to print. The question it answers:
    // this view is the SIBLING of `MetalHostView` in the same inner ZStack, and a ZStack sizes
    // itself to the UNION of its children and centres each one — so a sibling that comes back
    // LARGER would leave the Metal child inset inside the stack, which is the symptom. If these
    // bounds match the Metal view's, the sibling is not the cause and the inset is the Metal
    // child's own returned size.
    //
    // Same de-duplication and the same removal note as `MetalHostView.layout()`.
    private static var geomDiagSeen: Set<String> = []

    override func layout() {
        super.layout()
        let diagKey = "S/\(ObjectIdentifier(self))/\(bounds.size)/\(window?.backingScaleFactor ?? -1)"
        if Self.geomDiagSeen.insert(diagKey).inserted {
            NSLog("[GEOM-DIAG] SampleBufferView bounds=%.1f×%.1f  scale=%@  id=%@",
                  bounds.size.width, bounds.size.height,
                  window?.backingScaleFactor.description ?? "nil-window",
                  String(describing: ObjectIdentifier(self)))
        }
    }

    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    /// Enqueue one decoded frame for display. The frame engine calls this.
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }
        renderer.enqueue(sampleBuffer)
    }

    /// Clear any pending frames (e.g. on seek or load of a new file).
    func flush() {
        displayLayer.sampleBufferRenderer.flush()
    }
}
