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

// MARK: - Scrub preview surface (EDR-capable)

/// Hosts the scrub-preview `CGImage` on a plain `CALayer` that can opt into EDR.
///
/// ── WHY THIS IS NOT `Image(decorative:)` ANY MORE ─────────────────────────────────────────────
///
/// SwiftUI's `Image` exposes NO dynamic-range API, and `CALayer` tone-maps ITU-R 2100 content to
/// SDR unless the layer opts in. So even a correctly-tagged HDR CGImage — which
/// `dynamicRangePolicy = .matchSource` now produces, see `makeScrubPreviewGenerator` — was still
/// being tone-mapped on the way to the screen. Tagging the image and hosting it in a layer that
/// asks for the headroom are two halves of one fix; neither works alone.
///
/// ⚠️ BOTH EDR PROPERTIES ARE USED, ONE PER OS RANGE — see `setPreviewImage`. There are two
/// declarations of `wantsExtendedDynamicRangeContent` and only one is deprecated: `CAMetalLayer`'s
/// is current (which is why `MetalVideoRenderer` keeps using it and is NOT touched here), while the
/// plain `CALayer` one — the declaration a layer like this one picks up — is
/// `API_DEPRECATED("Use preferredDynamicRange instead", macos(14.0, 26.0))`. That annotation means
/// available FROM 14.0, deprecated AS OF 26.0, so on 15–25 it is the only opt-in that exists and
/// this layer uses it there. On 26+ it uses `preferredDynamicRange`. Deprecated is not unavailable,
/// and "don't copy the renderer's API" was never a reason to leave most of the supported OS range
/// with no opt-in at all.
///
/// ⚠️ WHAT PART 1 DOES ON ITS OWN, ON EVERY VERSION — worth keeping straight, because it is what
/// changed for users before this layer existed. `dynamicRangePolicy` is macos(15.0) and is NOT
/// guarded, so `.matchSource` applies across the whole supported range. Under the old `.forceSDR`
/// the generator CONVERTED PQ/HLG to 709 and highlights were CLIPPED by that conversion; now the
/// image arrives correctly PQ-tagged, and a layer with no opt-in TONE-MAPS it (roll-off) instead.
/// Both land on an SDR picture, so part 1 alone never fixed the report — but the two are not the
/// same operation, and describing the un-opted-in case as "what it did before" is wrong.
///
/// ⚠️ NO `contentsHeadroom` IS SET, AND THAT IS MEASURED RATHER THAN ASSUMED.
/// `preferredDynamicRange` activates only on content "that have headroom tagging greater than
/// 1.0", so an untagged image would make this a silent no-op — the worst failure shape available.
/// A CGImage carries its own tagging as one of the three qualifying routes, and the generator's
/// output was checked: `.matchSource` on a PQ source returns `contentHeadroom = 4.9261084`
/// (= `kCGDefaultHDRImageContentHeadroom`), against 1.0 under the shipping `.forceSDR`. The
/// content route is live, so the layer route is redundant here.
///
/// This deliberately covers the AVFoundation producer ONLY. `LibavThumbnailSource` (DNx/MXF) builds
/// an 8-bit RGBA CGImage and is SDR by construction — no layer opt-in can rescue 8-bit RGBA, and
/// giving it a float path is a separate producer's worth of work. HDR previews for those formats
/// stay SDR; that is a recorded choice, not an oversight (docs/BUGS.md).
struct ScrubPreviewSurface: NSViewRepresentable {
    let image: CGImage

    func makeNSView(context: Context) -> ScrubPreviewHostView {
        let view = ScrubPreviewHostView()
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .never
        view.setPreviewImage(image)
        return view
    }

    func updateNSView(_ nsView: ScrubPreviewHostView, context: Context) {
        nsView.setPreviewImage(image)
    }
}

final class ScrubPreviewHostView: NSView {

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        // RESIZE, not aspect-fit. The caller pins the aspect with SwiftUI's
        // `.aspectRatio(videoAspect, contentMode: .fit)` — the same authority the video rect uses,
        // and deliberately NOT the preview image's own pixel aspect (the two producers disagree
        // about PAR). So by the time these bounds exist they are already the correct shape, and the
        // layer's job is to fill them exactly, which is what the old `.resizable()` did.
        layer.contentsGravity = .resize
        // A preview swap is a CONTENT REPLACEMENT, not a transition. Without this every new frame
        // during a drag would cross-fade through CALayer's default 0.25 s `contents` animation —
        // a visible smear on a control whose whole purpose is to answer "which frame am I on".
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        return layer
    }

    override var wantsUpdateLayer: Bool { true }

    func setPreviewImage(_ image: CGImage) {
        guard let layer else { return }
        // Belt and braces around the per-property `actions` above: this runs from `updateNSView`,
        // i.e. inside a SwiftUI update where an enclosing animation transaction may be in flight,
        // and an inherited animation would re-introduce the cross-fade the actions dictionary is
        // there to prevent.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        layer.contentsScale = window?.backingScaleFactor ?? 2.0
        // ── THE EDR OPT-IN. AN ORDINARY AVAILABILITY BRANCH, NOT A FALLBACK ───────────────────
        //
        // Two properties, each current for its own range, and they mean the same thing. This
        // target's floor is macOS 15.0, so BOTH branches ship.
        //
        // ⚠️ THEY ARE EQUIVALENT AT THE SETTING WE USE — checked against the headers, not assumed.
        // `wantsExtendedDynamicRangeContent = YES` displays contents "up to its NSScreen's
        // maximumExtendedDynamicRangeColorComponentValue", i.e. the display's FULL headroom with no
        // modulation. That is `CADynamicRangeHigh` ("provides the best HDR quality"), not
        // `CADynamicRangeConstrainedHigh` ("brightness is modulated to optimize for co-existence
        // with other composited content") — the boolean has no modulated mode at all. So the
        // boolean is the UNCONSTRAINED one, and the two branches below land in the same place.
        //
        // Unconstrained is what we want on both, because it is what the picture UNDERNEATH is
        // already doing: `MetalVideoRenderer.setSourceColorSpace` sets
        // `wantsExtendedDynamicRangeContent` on the CAMetalLayer. The whole point of this fix is
        // that the overlay and the layer revealed on release look the same — a constrained overlay
        // would just relocate the brightness step from release to grab.
        if #available(macOS 26.0, *) {
            layer.preferredDynamicRange = .high
        } else {
            // NOT DEAD CODE, AND NOT A DEPRECATED-API MISTAKE. The annotation on this property is
            // `API_DEPRECATED("Use preferredDynamicRange instead", macos(14.0, 26.0))`, which means
            // AVAILABLE FROM 14.0, deprecated AS OF 26.0 — so across all of 15–25 it is the current
            // API and the only one that exists. `preferredDynamicRange` is macos(26.0); without
            // this branch every system below 26 got no opt-in at all and the overlay stayed SDR,
            // which is most of the supported range.
            //
            // ⚠️ UNVERIFIED ON REAL HARDWARE. The build Mac runs macOS 26.5.1, so this branch has
            // never been executed — it is written from the header contract. See docs/BUGS.md.
            layer.wantsExtendedDynamicRangeContent = true
        }
        CATransaction.commit()
    }
}
