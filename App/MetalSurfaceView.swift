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
/// asks for the headroom were intended as two halves of one fix.
///
/// ⚠️ THAT FIX DID NOT WORK, AND THE REASON IS BELOW. The opt-in is still correct and still here —
/// it is what lifts the overlay off SDR at all — but it does NOT make this layer match the played
/// picture, and no layer property does.
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
/// ⚠️ THE HEADROOM ROUTES — AND THE FINDING THAT CLOSED THE INVESTIGATION THEY BELONG TO.
/// `preferredDynamicRange` activates only on content "that have headroom tagging greater than 1.0".
/// The generator's output was measured: `.matchSource` on a PQ source returns
/// `contentHeadroom = 4.9261084` (= `kCGDefaultHDRImageContentHeadroom`) against 1.0 under the old
/// `.forceSDR`. So the content route is live and the layer's own `contentsHeadroom` is redundant —
/// it was set for a while, measured to change nothing, and has been removed.
///
/// ⚠️⚠️ THE TAG CANNOT BE REMOVED FROM THE IMAGE, BECAUSE THE TAG *IS* THE COLORSPACE. Measured in
/// `docs/scrub-fixtures/hrprobe.swift`: `CGImageCreateCopyWithContentHeadroom(0.0, …)` is silently
/// ignored (only values >= 1.0 take), and even plain `CGImageCreate` — an API with no headroom
/// parameter at all — returns an image reporting 4.9261084. The headroom is derived from
/// `kCGColorSpaceITUR_2100_PQ`.
///
/// >>> CONSEQUENCE, AND IT IS A PROPERTY OF THE PLATFORM RATHER THAN OF THIS FILE: a PQ CGImage on
/// >>> a CALayer is ALWAYS on Core Animation's TONE-MAPPED path, and nothing settable moves it off.
/// >>> `contentsHeadroom`, `toneMapMode = .never`, and the `preferredDynamicRange` /
/// >>> `wantsExtendedDynamicRangeContent` A/B were each measured against the side-by-side split
/// >>> (`MANIFOLD_SCRUB_SPLIT=1`) and each changed NOTHING.
///
/// So this overlay is tone-mapped and the CAMetalLayer is not — the Metal path declares no headroom
/// and no `edrMetadata`, so its drawables are excluded from tone mapping. **That is a DIFFERENT
/// COLOUR-MANAGEMENT MODE, not a rendering fault**, and the accepted consequence is that an HDR
/// scrub preview does not match the played picture. The decision to keep the played picture
/// untone-mapped (it is the reference: the scopes, the export and the DeckLink SDI output all read
/// the same offscreen) and to accept the preview being approximate is recorded in full, with the
/// reasoning and the rejected alternatives, in docs/BUGS.md → "✅ DECISION 2026-08-28: the desktop
/// picture is the REFERENCE and does not tone-map".
///
/// ⚠️ DO NOT ATTEMPT TO FIX THIS WITH A LAYER PROPERTY. Four have been eliminated by measurement.
/// The only route that closes it is removing this CGImage path entirely — see docs/BUGS.md →
/// "⏸ BANKED: feed the scrub gesture from `AVPlayerItemVideoOutput`".
///
/// This deliberately covers the AVFoundation producer ONLY. `LibavThumbnailSource` (DNx/MXF) builds
/// an 8-bit RGBA CGImage and is SDR by construction — no layer opt-in can rescue 8-bit RGBA, and
/// giving it a float path is a separate producer's worth of work. HDR previews for those formats
/// stay SDR; that is a recorded choice, not an oversight (docs/BUGS.md).
struct ScrubPreviewSurface: NSViewRepresentable {
    let image: CGImage

    /// ⚠️ DEBUG SPLIT ONLY — nil in every shipping path, and `ScrubDebug.splitEnabled` is the only
    /// thing that ever passes a value. The fraction of the image's WIDTH to show, measured from the
    /// left edge; the caller sizes this view to the same fraction of the video rect. See
    /// `setPreviewImage` for why this is `contentsRect` and not a mask.
    var splitFraction: CGFloat? = nil

    func makeNSView(context: Context) -> ScrubPreviewHostView {
        let view = ScrubPreviewHostView()
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .never
        view.setPreviewImage(image, splitFraction: splitFraction)
        return view
    }

    func updateNSView(_ nsView: ScrubPreviewHostView, context: Context) {
        nsView.setPreviewImage(image, splitFraction: splitFraction)
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
        // `contentsRect` joins the list for the DEBUG split: it changes exactly once, when the
        // split arms, and CALayer would otherwise animate the image sliding/scaling into its half
        // over 0.25 s. An instrument that transitions into position is an instrument you have to
        // wait for before you can trust it.
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                         "contentsRect": NSNull()]
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

    func setPreviewImage(_ image: CGImage, splitFraction: CGFloat? = nil) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        layer.contentsScale = window?.backingScaleFactor ?? 2.0
        // ── THE DEBUG SPLIT'S HALF — `contentsRect`, DELIBERATELY NOT A MASK OR A CLIP ─────────
        //
        // ⚠️ EVERY OBVIOUS WAY TO SHOW HALF A LAYER PERTURBS THE THING BEING MEASURED. SwiftUI's
        // `.mask`, `.clipped()` and `masksToBounds` all introduce a clip on the compositing path,
        // and at least the first can force an OFFSCREEN pass — which is precisely the class of
        // operation suspected of flattening this layer's EDR. An instrument that might tone-map
        // the half it is measuring answers a different question than the one asked, and would do
        // it silently. `logEDRState`'s ancestor walk already flags `masks`, `compFilter`,
        // `filters` and `RASTERIZE!` on the chain for this exact reason; adding one on purpose
        // would be tripping our own wire.
        //
        // `contentsRect` is not a clip. It is the sub-rectangle of `contents` that is MAPPED onto
        // the layer's bounds — a source-side crop applied where the image is sampled, with no
        // extra pass and no change to how the result is composited. The layer's EDR configuration
        // below is reached identically either way.
        //
        // GEOMETRY, AND WHY THE SEAM LINES UP. Unit coordinates, origin top-left of the image.
        // With `contentsGravity = .resize` the sub-rect is stretched to fill the bounds, and the
        // caller sizes this view to the SAME fraction of the video rect — so `f` of the image goes
        // into `f` of the rect and the scale factor is unchanged from the full-width case. At any
        // x in the left half the overlay shows the same picture content the Metal layer shows at
        // that x. A resolution difference across the seam is expected (960×540 upscaled vs.
        // native); a CONTENT offset would mean this arithmetic is wrong, not that the paths differ.
        //
        // Reset to the unit rect when not splitting — this view is reused across preview swaps and
        // a stranded half-rect would silently halve every later preview.
        layer.contentsRect = splitFraction.map { CGRect(x: 0, y: 0, width: $0, height: 1) }
                             ?? CGRect(x: 0, y: 0, width: 1, height: 1)
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
            // ⚠️ `layer.contentsHeadroom = CGFloat(image.contentHeadroom)` STOOD HERE AND WAS
            // REMOVED — MEASURED INERT, not tidied away. Setting it changed nothing (readback
            // confirmed 0.0, the split's seam did not move), because the image carries its own
            // 4.9261084 and `contentsHeadroom`'s header says a CGImage with content headroom does
            // not need it set. Do not put it back expecting an effect.
            //
            // ⚠️ AND THE IMAGE'S TAG CANNOT BE CLEARED EITHER, WHICH IS THE FINDING THAT CLOSED
            // THIS. `docs/scrub-fixtures/hrprobe.swift` measured it: the headroom is DERIVED FROM
            // the PQ colorspace, `CGImageCreateCopyWithContentHeadroom(0.0, …)` is silently
            // ignored, and even plain `CGImageCreate` — an API with no headroom parameter at all —
            // still yields 4.9261084. There is no such thing as a PQ-tagged CGImage with unknown
            // headroom, so this layer is pinned to Core Animation's tone-mapped path by the
            // platform. See docs/BUGS.md → "✅ DECISION 2026-08-28".
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
                 + " layer{\(type(of: layer)) \(optIn) wantsEDR=\(wantsEDR) scale=\(layer.contentsScale)}"
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
