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
/// ⚠️ BOTH HEADROOM ROUTES ARE NOW SATISFIED — a REVISION, and the reasoning it replaced is worth
/// knowing. `preferredDynamicRange` activates only on content "that have headroom tagging greater
/// than 1.0", so an untagged image makes it a silent no-op. A CGImage carries its own tagging as
/// one of three qualifying routes, and the generator's output was measured: `.matchSource` on a PQ
/// source returns `contentHeadroom = 4.9261084` (= `kCGDefaultHDRImageContentHeadroom`) against 1.0
/// under the old `.forceSDR`. That measurement stands, and on it the layer's own `contentsHeadroom`
/// is redundant — which is what this comment used to say, and why it was left at its default.
///
/// It is now set anyway, along with a wide `contentsFormat`. NEITHER is established as the cause of
/// anything: the reported failure persists with the content route alone, and 0.0 is the DOCUMENTED
/// default meaning "not overriding", not a missing tag. They are set because they are the two
/// remaining implicit assumptions in this layer's configuration and removing a variable costs
/// nothing. If EDR is working when you read this, they are the first two lines to try removing.
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

    /// The pre-26 opt-in, in one place. Marked deprecated-from-26 so the A/B switch can call it from
    /// an unguarded context without a warning — the annotation is the suppression, and it keeps the
    /// deprecation visible in the signature where a reader will meet it.
    @available(macOS, deprecated: 26.0)
    private func setLegacyEDROptIn(_ layer: CALayer) {
        layer.wantsExtendedDynamicRangeContent = true
    }

    func setPreviewImage(_ image: CGImage) {
        guard let layer else { return }
        // Belt and braces around the per-property `actions` above: this runs from `updateNSView`,
        // i.e. inside a SwiftUI update where an enclosing animation transaction may be in flight,
        // and an inherited animation would re-introduce the cross-fade the actions dictionary is
        // there to prevent.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // ── WIDE BACKING FORMAT ───────────────────────────────────────────────────────────────
        //
        // ⚠️ THE HEADER SAYS THIS SHOULD NOT MATTER FOR AN ASSIGNED `contents`, AND IT IS SET
        // ANYWAY. `contentsFormat` is documented as "a hint for the desired storage format of the
        // layer contents provided by -drawLayerInContext" which "does not affect the
        // interpretation of the `contents' property directly" — and we never draw into this layer,
        // we assign a CGImage. So on the header's account an 8-bit default cannot be what flattens
        // a 16-bit PQ image. It is set because the default was observed as `RGBA8` on a layer whose
        // EDR was not working, the header is a hint rather than a guarantee, and the cost is
        // nothing measurable here — NOT because the mechanism is established. If EDR starts working
        // and you are minimising the change, this is the line to test removing first.
        //
        // `kCAContentsFormatRGBA16Float` is macos(10.12) — no availability guard needed.
        layer.contentsFormat = .RGBA16Float
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
        // ⚠️ TEMPORARY A/B SWITCH — REMOVE with the [EDRDIAG] block. `MANIFOLD_SCRUB_EDR_LEGACY=1`
        // forces the DEPRECATED boolean on every OS, 26+ included.
        //
        // The choice between the two opt-ins is UNPROVEN on 26+.
        // `wantsExtendedDynamicRangeContent` is demonstrably working in this app right now — it is
        // what `MetalVideoRenderer.setSourceColorSpace` sets, and HDR playback is correct on this
        // machine. `preferredDynamicRange` is what this layer uses on 26+, and NOTHING has ever
        // confirmed it activates for CALayer `contents`, and the A/B was run: forcing the legacy
        // boolean on 26+ did NOT change the result, so the opt-in API is not the discriminator.
        // Kept because it costs nothing and re-testing it is one env var.
        if ScrubDebug.forceLegacyEDR {
            setLegacyEDROptIn(layer)
        } else if #available(macOS 26.0, *) {
            // ── EXPLICIT HEADROOM TAG ─────────────────────────────────────────────────────────
            //
            // ⚠️ 0.0 WAS NEVER EVIDENCE OF A FAULT, AND THIS IS STILL NOT ESTABLISHED AS THE FIX.
            // `contentsHeadroom` "defaults to 0, which means untagged", and its own header says
            // "if the `contents' is a CGImageRef with content headroom … this property does not
            // need to be set". Our image carries 4.926, so a 0.0 readback is the DOCUMENTED
            // default meaning "not overriding — use the content's own tagging", not a missing tag.
            //
            // It is set regardless, for one reason: it removes a variable. The content route and
            // the layer route are the two ways to satisfy `preferredDynamicRange`, and with the
            // fix not working there is no value in leaving one of them implicit. Copied FROM the
            // image, never invented — the header says values >0 and <1.0 are undefined, and a
            // number picked by hand would be a colour decision in disguise.
            layer.contentsHeadroom = CGFloat(image.contentHeadroom)
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
            setLegacyEDROptIn(layer)
        }
        CATransaction.commit()

        #if DEBUG
        logEDRState(image)
        #endif
    }

    #if DEBUG
    // ⚠️ TEMPORARY DIAGNOSTIC — REMOVE once the HDR scrub failure is diagnosed. Answers checks 2, 4
    // and 5 of the triage list at runtime, on the REAL image and the REAL layer during a drag,
    // rather than on a test frame. Profile defines DEBUG, so it is live in a tester build and
    // absent from Release.
    private static var lastDiag: String = ""

    private func logEDRState(_ image: CGImage) {
        guard let layer else { NSLog("[EDRDIAG] NO LAYER"); return }

        // ── CHECK 2: the image actually handed to the layer ────────────────────────────────────
        let cs = image.colorSpace
        let csName = cs.flatMap { $0.name as String? } ?? "nil"
        let is2100 = cs.map { CGColorSpaceUsesITUR_2100TF($0) } ?? false
        let headroom = image.contentHeadroom
        // bpc DISCRIMINATES THE PRODUCER without needing new API: the AVFoundation generator
        // returns 16-bit here, LibavThumbnailSource builds 8-bit RGBA (SDR by construction, the
        // deferred part 3). An 8-bit image means this file is on the libav path and the HDR fix
        // was never expected to cover it.
        let producer = image.bitsPerComponent >= 16 ? "AVF-generator" : "libav-8bit(PART-3-NOT-DONE)"

        // ── CHECK 4: the opt-in, read back off the layer AT SET TIME ───────────────────────────
        var optIn = "n/a"
        if #available(macOS 26.0, *) {
            optIn = "preferredDynamicRange=\(layer.preferredDynamicRange.rawValue)"
                  + " contentsHeadroom=\(layer.contentsHeadroom)"
        }
        // Read the deprecated one too, on every OS: if something is resetting the layer or if the
        // 26+ property is not doing what we think, this says so.
        let wantsEDR: String = {
            if #available(macOS 26.0, *) { return "n/a(26+)" }
            return "\(layer.wantsExtendedDynamicRangeContent)"
        }()

        // ── CHECK 5: the ancestor chain, and whether EDR is even available right now ───────────
        var chain: [String] = []
        var node: CALayer? = layer
        var hops = 0
        while let l = node, hops < 8 {
            var desc = "\(type(of: l))"
            if l.opacity != 1 { desc += " opacity=\(l.opacity)" }
            if l.masksToBounds { desc += " masks" }
            if l.compositingFilter != nil { desc += " compFilter!" }
            if (l.filters?.isEmpty == false) { desc += " filters!" }
            if l.shouldRasterize { desc += " RASTERIZE!" }
            if #available(macOS 26.0, *), l.preferredDynamicRange.rawValue != "CADynamicRangeStandard" {
                desc += " pdr=\(l.preferredDynamicRange.rawValue)"
            }
            chain.append(desc)
            node = l.superlayer
            hops += 1
        }
        // ── maxEDR IS A REAL MEASUREMENT. READ IT, BUT READ IT WITH THE DISPLAY MODE ──────────
        //
        // ⚠️ THIS COMMENT PREVIOUSLY SAID THE METRIC WAS INERT AND SHOULD BE IGNORED. THAT WAS
        // WRONG, AND THE ERROR IS WORTH KNOWING BECAUSE IT COST A WORKING INSTRUMENT.
        // `maximumExtendedDynamicRangeColorComponentValue` was probed across every layer
        // configuration, including the known-good `wantsExtendedDynamicRangeContent`, and read
        // exactly 1.0000 every time — which was taken as proof the metric could not distinguish
        // anything. It was not: THE DISPLAY WAS IN SDR MODE FOR THE WHOLE PROBE. A screen that is
        // not in HDR mode grants no headroom to anything, so 1.0 everywhere was the correct answer
        // to a question asked under the wrong conditions. In HDR mode this field reads real values
        // (4.4827 was observed here during a drag).
        //
        // So: a 1.0 means "no headroom is being granted RIGHT NOW", which is a fact about the
        // display's mode first and the layer second. Check `potential` in the same line before
        // concluding anything — potential=1.0 means the display cannot do EDR at this moment and
        // NOTHING about the layer can be inferred from the line at all.
        //
        // This machine has two displays (an LG TV and an ASUS PA147) and reads the one hosting THIS
        // view's window, which is the right screen but not necessarily the one another tool sampled.
        let screen = window?.screen ?? NSScreen.main
        let maxEDR = screen?.maximumExtendedDynamicRangeColorComponentValue ?? -1
        let potEDR = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? -1

        let line = "[EDRDIAG] img{cs=\(csName) 2100TF=\(is2100) headroom=\(headroom) bpc=\(image.bitsPerComponent) \(producer)}"
                 + " layer{\(type(of: layer)) \(optIn) wantsEDR=\(wantsEDR) scale=\(layer.contentsScale) fmt=\(layer.contentsFormat.rawValue)}"
                 + " screen{maxEDR=\(maxEDR) potential=\(potEDR)}"
                 + " chain[\(chain.joined(separator: " < "))]"
        // Only when something CHANGES, plus the first one — a drag fires this at up to ~20 Hz and a
        // line per preview would bury the one fact that differs.
        if line != Self.lastDiag {
            Self.lastDiag = line
            NSLog("%@", line)
        }
    }
    #endif
}
