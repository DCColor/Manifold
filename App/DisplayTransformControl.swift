//
//  DisplayTransformControl.swift — §6.3 tiers 1–3 in the control bar. Phase 2b.
//
//  Tier 1: the mode name, always visible, small, with a warning marker in Bypass.
//  Tier 2: the pulldown, plain language, MEANING as the subtitle rather than mechanism.
//  Tier 3: the chain, one disclosure inside the pulldown's popover.
//
//  ── ⚠️ ITS OWN FILE, AND ITS OWN View STRUCTS, ON PURPOSE ───────────────────────────────────
//
//  `ContentView`'s body is at the Swift type-checker's limit — §6.7 records the build failing
//  outright ("unable to type-check this expression in reasonable time") when Phase 2a tried to add
//  one `.onChange` to it, and that file already documents the same constraint on
//  `transportKeys.attach`. Everything here is therefore a separate `View` with its own body, and
//  `ContentView` gains exactly one element in the control-bar `HStack` and no modifiers.
//
//  ── ⚠️ EVERY MODE CHANGE GOES THROUGH `DeckRegistry.setDisplayTransform` ────────────────────
//
//  §6.7's Phase 2b constraint, and it is not a style preference. That function writes the owning
//  `WindowChrome` *and* forwards to that deck's renderer, because `ContentView` cannot afford the
//  `.onChange` that would otherwise carry the value. **A direct write to `chrome.displayTransform`
//  moves this control and the menu checkmark and NOT the picture, with no observer to catch it** —
//  it would look like it works. There are no writes to `chrome.displayTransform` in this file.
//

import SwiftUI
import AppKit

// MARK: - The control-bar item

/// The display-transform pulldown for ONE window, plus its standing Bypass marker.
///
/// Reads this window's `WindowChrome` directly (it is in scope — this view is inside the window),
/// and writes only through the registry. That asymmetry is the constraint above: the READ side can
/// observe, the WRITE side must go through the one mutator.
struct DisplayTransformControl: View {
    let deck: WindowDeck
    @ObservedObject var chrome: WindowChrome
    /// Per window, owned here. Lifetime is this control's, which is the window's.
    @StateObject private var chainModel = DisplayChainModel()
    @State private var showChain = false

    private var mode: DisplayTransformMode { chrome.displayTransform }
    private var isBypass: Bool { mode == .bypass }

    var body: some View {
        HStack(spacing: 5) {
            // ⚠️ THE BADGE IS A SIBLING OF THE MENU, NOT ITS LABEL, AND THAT IS A MEASURED FIX.
            //
            // It was inside the `Menu`'s label first, as an amber `Capsule` with black text. It
            // rendered as PLAIN WHITE TEXT: `.menuStyle(.borderlessButton)` strips a label's
            // background and foreground and lets the control bar's own
            // `.foregroundStyle(.white.opacity(0.9))` win. Caught by sampling the capture —
            // **zero non-grey pixels anywhere in the indicator** — not by looking at it, because
            // bold white "⚠ BYPASS" looks deliberate in a screenshot.
            //
            // Outside the menu label it is an ordinary view and keeps its colours, the same way
            // the scopes-tray button keeps its green.
            if isBypass { bypassBadge }

            Menu {
                menuContent
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .help(isBypass
              ? "Display transform: BYPASS — no colour management. Diagnostic only."
              : "Display transform: as macOS shows it — what your client will see")
        .onAppear { chainModel.bind(deck: deck) }
        // Keeps the chain's Transform line honest when the mode is changed from the Color MENU
        // rather than from this pulldown. `chrome` is observed, so this fires for both routes.
        .onChange(of: chrome.displayTransform) { _, _ in chainModel.refresh() }
        // ⚠️ TIER 3 IS PRESENTED FROM HERE, NOT FROM `ContentView`. The presentation modifier has
        // to live on a view in this file — see the header on why `ContentView` cannot take one.
        .popover(isPresented: $showChain, arrowEdge: .bottom) {
            DisplayChainReadout(model: chainModel)
                // Recompute on OPEN as well as on the screen events: the window may have been
                // dragged to another display while the popover was closed, and a readout that is
                // stale the moment it is opened is worse than none.
                .onAppear { chainModel.refresh() }
        }
    }

    // MARK: Tier 1 — always visible

    /// ⚠️ **THE STANDING BYPASS INDICATOR — §6.1 REQUIRES IT AND SAYS WHY.** Bypass "is never
    /// *correct*, only diagnostic", and on a display already calibrated to 709/2.4 it is close to
    /// Reference *by coincidence* — so it "needs a standing indicator so nobody judges a picture in
    /// it three days after leaving it there."
    ///
    /// It is deliberately loud: filled amber capsule, warning glyph, the word BYPASS. Not a tint on
    /// an icon, which is what the rest of this control bar uses for ordinary state and which is
    /// exactly what someone stops seeing after an hour. **Nothing is drawn in OS mode** — the
    /// default state carries no marker at all, so the marker's presence always means something.
    private var bypassBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .imageScale(.small)
            Text("BYPASS")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.orange))
        .foregroundStyle(.black)
        .accessibilityLabel("Display transform: Bypass, no colour management")
        .accessibilityAddTraits(.isStaticText)
    }

    /// The menu's own label — tier 1's "mode name in the control bar". Kept plain, because
    /// anything styled here is stripped by the borderless menu style; the marker is the badge.
    @ViewBuilder
    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: "display")
            Text(isBypass ? "Bypass" : "macOS")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .fixedSize()
        }
        .accessibilityLabel(isBypass
                            ? "Display transform: Bypass, no colour management"
                            : "Display transform: as macOS shows it")
    }

    // MARK: Tier 2 — the pulldown

    /// §6.3's pulldown, minus Reference.
    ///
    /// ⚠️ **NO Reference ENTRY, NOT EVEN DISABLED.** It is Phase 3 and does not exist; a greyed
    /// row advertising a mode that cannot be chosen is a support question, and a placeholder is how
    /// a stub gets written. `DisplayTransformMode` has two cases for the same reason.
    ///
    /// The separator before Bypass is load-bearing and §6.3 says so: it "says 'different kind of
    /// thing' before anyone reads a word."
    @ViewBuilder
    private var menuContent: some View {
        Toggle(isOn: binding(for: .os)) {
            Text(Self.rowLabel("As macOS Shows It", "what your client will see"))
        }
        Divider()
        Toggle(isOn: binding(for: .bypass)) {
            Text(Self.rowLabel("Bypass", "no colour management"))
        }
        Divider()
        // Tier 3 lives behind one more step, per §6.3's progressive disclosure: "available, not
        // prominent".
        // ⚠️ DEFERRED BY ONE RUNLOOP TURN, AND WITHOUT THIS THE POPOVER NEVER APPEARS.
        // Setting the presentation flag synchronously inside a menu action loses the race with the
        // menu's own dismissal: the state flips while the `NSMenu` is tearing down, the anchor is
        // mid-transition, and nothing is presented. Measured — the first version simply did
        // nothing when the item was clicked, with no error anywhere.
        Button("Show Transform Chain…") {
            DispatchQueue.main.async { showChain = true }
        }
    }

    /// ⚠️ **THE SUBTITLE IS ONE `AttributedString` IN ONE `Text`, AND THAT IS THE THIRD ATTEMPT.**
    ///
    /// Attempt 1 drew its own `Image(systemName: "checkmark")` at `.opacity(checked ? 1 : 0)` with
    /// the subtitle in a `VStack`: a checkmark on BOTH rows (AppKit does not honour a zero-opacity
    /// image in a menu item) and no subtitles (a `VStack` label is flattened to its first `Text`).
    ///
    /// Attempt 2 — §6.8's recorded fix — moved to `Toggle` for a real checkmark and put the
    /// subtitle in a **second `Text`** in the label, which is the documented form. **§6.8 recorded
    /// that as fixed and it was not.** A luminance scan of the rendered menu shows the row at
    /// single-line height with no subtitle pixels anywhere: title text peaks at 227, the band
    /// beneath it never leaves the menu's own gradient. The second `Text` was silently dropped.
    ///
    /// Attempt 3, measured against four alternatives in an isolated harness before it was written
    /// here (a second `Text`, a `Label`, a plain `"\n"` in one `Text`, and an `AttributedString`):
    /// **a plain newline draws both lines but in one style, and only the `AttributedString` draws a
    /// real subtitle** — smaller, secondary-coloured, and still under `Toggle`'s own checkmark.
    /// §6.3 is explicit that "the subtitles do the teaching", so this is the difference between a
    /// control that explains itself and one that merely looks like it does.
    ///
    /// ⚠️ **AND IT IS ONLY EVER TRUE IF IT IS MEASURED.** Two of the three attempts above rendered
    /// as something plausible. Anything that changes this construction gets a luminance scan of the
    /// subtitle band, not a look.
    static func rowLabel(_ title: String, _ subtitle: String) -> AttributedString {
        var t = AttributedString(title)
        t.font = .system(size: 13)
        var s = AttributedString("\n" + subtitle)
        s.font = .system(size: 11)
        s.foregroundColor = .secondaryLabelColor
        return t + s
    }

    /// `Toggle` is what makes AppKit draw a REAL checkmark — the same mechanism `RasterSizeCommands`
    /// and the Color menu already use, which is also what keeps this pulldown and the Color menu
    /// looking identical rather than merely agreeing in state.
    private func binding(for m: DisplayTransformMode) -> Binding<Bool> {
        Binding(
            get: { mode == m },
            set: { isOn in
                guard isOn else { return }   // unchecking a radio item is not a command
                set(m)
            }
        )
    }

    /// THE ONLY WRITE PATH. See the file header.
    ///
    /// `on: deck` names THIS window rather than relying on the key-window lookup. The pulldown is
    /// physically inside one window's control bar, so the deck it applies to is not in question —
    /// and making it explicit removes any dependence on what `NSApp.keyWindow` reports while an
    /// `NSMenu` is tracking.
    private func set(_ m: DisplayTransformMode) {
        DeckRegistry.shared.setDisplayTransform(m, on: deck)
        chainModel.refresh()
    }
}

// MARK: - Tier 3 — the chain

/// The transform chain, as a popover attached to the control.
///
/// Presented from `ContentView`'s control bar via `.popover` on the item — see `chainPopover`
/// below, which exists so the presentation modifier is attached HERE and not in `ContentView`.
struct DisplayChainReadout: View {
    @ObservedObject var model: DisplayChainModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Transform chain")
                .font(.headline)

            row("Source",    model.chain.source)
            row("Transform", model.chain.transform)
            row("Display",   model.chain.display)

            if let verdict = model.chain.verdict {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: model.chain.isConverting
                          ? "arrow.triangle.branch" : "equal.circle")
                        .foregroundStyle(model.chain.isConverting ? Color.orange : Color.secondary)
                    Text(verdict)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // ⚠️ SAID HERE BECAUSE THIS IS WHERE SOMEONE IS LOOKING WHEN THE PICTURE MOVED AND THE
            // WAVEFORM DID NOT. §6.5 finding 4: the scopes sample upstream of the display
            // transform, so they measure what is in the file and are immune to this control. "A
            // user who sees the picture change and the waveform hold still will otherwise read it
            // as a bug."
            Divider()
            Text("Scopes are unaffected by this setting — they measure the file, not the display.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 430, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
