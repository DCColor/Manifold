//
//  DisplayChainModel.swift — §6.3 tier 3, the transform chain, for ONE window.
//
//  Three lines: what the source declares, what this window's mode does with it, and what macOS
//  will do on the way to the screen this window is actually on. Phase 2b.
//
//  ── WHY THIS IS RECOMPUTED ON EVENTS AND NOT READ PER FRAME ─────────────────────────────────
//
//  Every input is per-source or per-display: the CICP codes change when a source loads, the mode
//  changes when the user picks one, and the display profile changes when the window moves screens
//  or the screen's profile is reassigned. None of it is per-frame, and parsing a 1024-entry ICC
//  table on every frame to produce text nobody is looking at would be absurd. So the model is
//  driven by `NSWindow.didChangeScreenNotification` and `NSWindow.didChangeScreenProfileNotification`
//  plus an explicit `refresh()` from the control when it opens.
//
//  ⚠️ **THE PROFILE-CHANGE PATH IS WIRED BUT WAS NOT EXERCISED LIVE.** Changing a display's assigned
//  profile means changing a macOS display setting, and this work was done under an explicit
//  instruction not to. §6.8 records it as untested. The SCREEN-change path (dragging a window
//  between displays) was tested and is reported there.
//

import AppKit
import SwiftUI
import CoreGraphics
import ManifoldCore

/// The three lines of the chain readout, plus the sentence underneath them.
struct DisplayChain: Equatable {
    var source: String
    var transform: String
    var display: String
    /// The plain-language verdict — "macOS is converting…" / "macOS is passing…" — or nil when the
    /// question does not apply (Bypass) or cannot be answered honestly (no comparable curve).
    var verdict: String?
    /// True when the verdict is the "converting" one, so the view can weight it.
    var isConverting: Bool = false
}

@MainActor
final class DisplayChainModel: ObservableObject {

    @Published private(set) var chain = DisplayChain(
        source: "—", transform: "—", display: "—", verdict: nil)

    private weak var deck: WindowDeck?
    private var observers: [NSObjectProtocol] = []

    // MARK: Binding

    /// Attach to a window's deck and start following that window's screen.
    ///
    /// Idempotent — the control calls it from `.onAppear`, and calling it again must not stack
    /// observers.
    ///
    /// ⚠️ **OBSERVES UNFILTERED AND COMPARES THE WINDOW IN THE HANDLER, RATHER THAN REGISTERING
    /// WITH `object: window`.** The obvious version scopes each observer to this deck's `NSWindow`
    /// — but `deck.window` is nil for the first layout passes (it is populated from
    /// `viewDidMoveToWindow`), and it is a plain stored property, not `@Published`, so there is no
    /// event to re-bind on and no way for a view to notice it arriving. Scoped registration would
    /// therefore silently observe nothing on exactly the path that matters. Filtering in the
    /// handler resolves `deck.window` at delivery time, when it is always populated.
    ///
    /// The cost is that every window's model wakes for any window's screen change, and with a
    /// handful of windows that is a pointer comparison and a return.
    func bind(deck: WindowDeck) {
        self.deck = deck
        guard observers.isEmpty else { refresh(); return }

        // ⚠️ BOTH NOTIFICATIONS, AND THEY ARE NOT THE SAME EVENT.
        //   * didChangeScreen        — this window moved to a different display.
        //   * didChangeScreenProfile — the display it is already on was assigned a different
        //                              profile. §6.5's "one stray click in System Settings ▸
        //                              Displays ▸ Colour Profile" arrives here and nowhere else,
        //                              and §6.7 measured the macOS HDR switch doing exactly this
        //                              to the LG.
        for name in [NSWindow.didChangeScreenNotification,
                     NSWindow.didChangeScreenProfileNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let w = note.object as? NSWindow, w === self.deck?.window
                    else { return }
                    self.refresh()
                }
            })
        }

        // ⚠️ THE THIRD EVENT, AND IT IS THE SOURCE SIDE RATHER THAN THE DISPLAY SIDE.
        // Without it the Source line only moved when something re-opened the popover, so a
        // colorimetry override made with the readout OPEN changed the tags, the layer and the
        // picture and left the line reading the old value — measured, §6.8 Phase 2c part 1.
        // Filtered on the renderer the same way the two above filter on the window.
        observers.append(NotificationCenter.default.addObserver(
            forName: MetalVideoRenderer.sourceColorStateDidChange, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let r = note.object as? MetalVideoRenderer,
                      r === self.deck?.renderer else { return }
                self.refresh()
            }
        })
        refresh()
    }

    deinit {
        // `observers` holds opaque tokens, not self-references; removing them off the main actor is
        // safe and `NotificationCenter` is thread-safe for this call.
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: Recompute

    /// Rebuild all three lines from current facts. Cheap enough to call on any of the events above;
    /// never called per frame.
    func refresh() {
        guard let deck else { return }
        let mode = deck.chrome?.displayTransform ?? .os
        let renderer = deck.renderer

        // ── SOURCE ──────────────────────────────────────────────────────────────────────────
        // The codes the RENDERER is using, not the inspector's — they are the ones the layer was
        // configured from, and if the two ever disagree this readout should show the one that
        // decided the picture.
        let pCode = renderer?.sourcePrimariesCode
        let tCode = renderer?.sourceTransferCode
        let sourceCS = renderer?.sourceDerivedColorSpace
        let mCode = renderer?.sourceMatrixCode
        let sourceLine: String
        if sourceCS == nil && pCode == nil && tCode == nil && mCode == nil {
            sourceLine = "no source"
        } else {
            // ⚠️ NAMES THE CODES THE RENDERER IS ACTUALLY USING, NOT THE TAG. An untagged file has
            // no CICP, but it is not being rendered through "—": `makeColorSpace` resolves absent
            // and unknown codes to the full 709 set (§3, and §2 measured the untagged fallback as
            // BYTE-IDENTICAL to the 709 profile). Printing a dash for the curve would be the one
            // thing this readout exists to prevent — a line that says less than the app knows.
            // So an absent axis prints the resolved value, and the TIER carries the absence.
            //
            // ── THE ORDER IS CICP'S OWN: PRIMARIES, TRANSFER, MATRIX ───────────────────────
            //
            // Names first in that order, then range, then the numeric triple in the SAME order
            // with the same separator the codes are written with everywhere else, then the tier:
            //
            //   Rec. 709 · Rec. 709 · Rec. 709 · limited — CICP 1-1-1 — assumed
            //
            // The earlier form printed transfer first and primaries second while calling the
            // numbers "CICP p/t", so the words and the numbers disagreed about which axis was
            // which — readable only if you already knew the answer.
            let p = MediaInspector.primariesName(forCode: pCode ?? 1)
            let t = MediaInspector.transferName(forCode: tCode ?? 1)
            let m = MediaInspector.matrixName(forCode: mCode ?? 1)

            // ⚠️ RANGE IS A SEPARATE AXIS AND IT CAN BE GENUINELY UNKNOWN. nil from the renderer
            // means no source has stated one — print that rather than "limited", which would be a
            // guess wearing a fact's clothes. Everything else here is measured or resolved.
            let range = renderer?.sourceIsFullRange.map { $0 ? "full" : "limited" } ?? "range unknown"

            // ⚠️ THE TIER COMES FROM THE SOURCE'S OWN RESOLUTION, NEVER FROM WHETHER THE CODES ARE
            // nil. §6.8's Phase 2c part 1: NDI and WHEP resolve before they publish, so a nil-test
            // here called an assumption and a user override alike "tagged". `SourceColorProvenance`
            // carries the answer from the site that actually knows it.
            let tier = (renderer?.sourceColorProvenance ?? .assumed).label

            sourceLine = "\(p) · \(t) · \(m) · \(range)"
                       + " — CICP \(pCode ?? 1)-\(tCode ?? 1)-\(mCode ?? 1)"
                       + " — \(tier)"
        }

        // ── TRANSFORM ───────────────────────────────────────────────────────────────────────
        let transformLine: String
        switch mode {
        case .os:     transformLine = "As macOS shows it — source colorspace declared to the layer"
        case .bypass: transformLine = "Bypass — no colorspace declared, no conversion"
        }

        // ── DISPLAY ─────────────────────────────────────────────────────────────────────────
        // Resolved from THIS window's screen. `NSScreen.main` would be wrong the moment a second
        // window exists, which is the whole reason this model is per-window.
        let screen = deck.window?.screen
        var displayLine = "no screen"
        var displayCurve: ICCTransferCurve?
        if let screen {
            let name = screen.localizedName
            if let cs = Self.displayColorSpace(for: screen) {
                let curve = ICCTransferCurve.parseRTRC(colorSpace: cs)
                displayCurve = curve
                displayLine = "\(name) — \(curve.plainDescription)"
            } else {
                displayLine = "\(name) — no profile available"
            }
        }

        // ── THE VERDICT ─────────────────────────────────────────────────────────────────────
        var verdict: String?
        var converting = false
        if mode == .os, let displayCurve, let sourceCS {
            let sourceCurve = ICCTransferCurve.parseRTRC(colorSpace: sourceCS)
            // ⚠️ NUMERIC, over [0,1] — never a comparison of ICC encodings. §6.5's probe made
            // exactly that mistake and reported "TRCs differ, A/B should be visible" for two
            // spellings of one curve. `maxDeviation` is the shared arithmetic.
            if let dev = sourceCurve.maxDeviation(from: displayCurve) {
                converting = dev > ICCTransferCurve.sameCurveThreshold
                verdict = converting
                    ? "macOS is converting this picture for this display."
                    : "macOS is passing this picture through unchanged."
            } else {
                // Honest third case rather than a guess. A PQ or HLG source has no rTRC at all
                // (§3: transfer is declared through `cicp` and a LUT), so there is no curve to
                // compare and neither sentence above would be true.
                verdict = "Source declares its transfer outside the rTRC (PQ/HLG); "
                        + "no curve comparison is possible."
            }
        }

        let next = DisplayChain(source: sourceLine, transform: transformLine,
                                display: displayLine, verdict: verdict, isConverting: converting)
        // Equality guard: `@Published` publishes on every assignment, and this can fire from a
        // notification during a view update.
        if next != chain { chain = next }
    }

    /// The display's assigned profile. `CGDisplayCopyColorSpace` first, matching what
    /// `MetalVideoRenderer`'s `[CSPROBE]` destination probe resolves, so the readout and the probe
    /// describe the same profile.
    private static func displayColorSpace(for screen: NSScreen) -> CGColorSpace? {
        if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return CGDisplayCopyColorSpace(CGDirectDisplayID(num.uint32Value))
        }
        return screen.colorSpace?.cgColorSpace
    }
}
