//
//  DisplayTransform.swift — Phase 2a of docs/COLOR_MANAGEMENT_FINDINGS.md §6.4.
//
//  THE SECOND OF TWO STAGES, AND ONLY THE SECOND. §6.1 is explicit that a player has two stages,
//  not three: how the source is INTERPRETED, and what is sent to the DISPLAY. This type governs
//  only the second. Interpretation — the CICP tags, the `tagged`/`assumed`/`overridden` honesty
//  model, the NDI colorimetry override — is identical in every mode, which is exactly why §6
//  rejected the name "Embedded": reading the file's tags is what every mode does, so the name
//  pointed at the wrong axis.
//
//  ── WHY THERE ARE TWO CASES HERE AND NOT THREE ──────────────────────────────────────────────
//
//  §6.4's Phase 2 is "infrastructure, with OS and Bypass only", and Reference is Phase 3. Both
//  cases below are reachable and neither needs any colour science: OS is today's behaviour made
//  explicit, and Bypass is the REMOVAL of an assignment. Reference is the one that needs a shader
//  EOTF, and adding its case now would put an unreachable arm in every switch in the app —
//  which is an invitation to fill it with a stub that silently renders as OS.
//
//  ⚠️ WHEN REFERENCE ARRIVES, READ §6.6's TRAP FIRST. A shader that applies BT.1886 2.4 and then
//  declares γ2.4 has its work undone — ColorSync converts straight back to display encoding and
//  the net light is as if nothing had happened. Measured: 10 codes on the LG. It looks like a
//  Reference mode that does nothing, which is much harder to notice than one that looks broken.
//  Phase 1 settled that Reference keeps today's declaration and changes only the transform that
//  runs before it.
//

import SwiftUI

/// What the display path does with the decoded picture on its way to the screen.
///
/// ⚠️ **DESKTOP ONLY.** SDI never goes through ColorSync — the DeckLink output tags each scheduled
/// frame with a `BMDColorspace` derived from the source's primaries alone
/// (`DeckLinkBridge.mm BMDColorspaceForPrimaries`), on a path that never touches a `CGColorSpace`
/// and never reads `CAMetalLayer.colorspace`. A mode set here cannot reach it, and must not:
/// a broadcast output is not a viewing preference.
///
/// ⚠️ **SCOPES ARE UNAFFECTED, AND THAT IS CORRECT** — measured, §6.5 finding 4. The scopes sample
/// the offscreen ring (`MetalVideoRenderer.offscreenTexture`), which is UPSTREAM of the layer:
/// they measure what is in the file, not what the display emits. So they are the one instrument in
/// the app immune to this control, which is why the picture and the waveform can legitimately
/// disagree, and why the scopes stay trustworthy while the picture sits in Bypass. A user who sees
/// the picture change while the waveform holds still will otherwise read it as a bug.
enum DisplayTransformMode: String, CaseIterable, Identifiable, Sendable {

    /// Declare the source's colorspace on the layer and let ColorSync convert to the display
    /// profile. **This is today's behaviour, unchanged, and it is the default.**
    ///
    /// On SDR this is the γ1.9609 path §2 measured: every SDR arm of `makeColorSpace` lands on a
    /// profile whose rTRC is a single power law of 1.960938, and ColorSync transforms that to
    /// whatever the display's own profile asks for. Whether that is *right* for a reference tool
    /// is §2 and §4's claim and the reason Reference exists — but it is what every colour-managed
    /// macOS application does, so it is the honest answer to "what will my client see?".
    case os

    /// Install no colorspace at all: `CAMetalLayer.colorspace = nil`. **No conversion is
    /// performed** — measured in Phase 1 (§6.6) to the limit it can be measured.
    ///
    /// ⚠️ **NEVER *CORRECT*, ONLY DIAGNOSTIC** (§6.1). OS and Reference both trust the file's tags,
    /// so a mistagged file gets a confidently wrong transform in both and neither will say so.
    /// Bypass is the only path where nothing interprets anything, which makes it the control
    /// condition: when OS and Reference disagree, Bypass tells you which one moved. On a display
    /// already calibrated to 709/2.4 it is close to Reference *by coincidence*, which is precisely
    /// why it needs to be hard to leave switched on.
    case bypass

    var id: String { rawValue }

    /// The name in the menu. Plain enough to be chosen from without a manual; §6.3's pulldown with
    /// its meaning-carrying subtitles ("what your client will see" / "no colour management") is
    /// Phase 2b and lives in the control bar, not here.
    var menuTitle: String {
        switch self {
        case .os:     return "As macOS Shows It"
        case .bypass: return "Bypass — No Colour Management"
        }
    }

    /// Short form for logs and diagnostics.
    var logLabel: String {
        switch self {
        case .os:     return "OS"
        case .bypass: return "BYPASS"
        }
    }

    /// ⚠️ THE ONLY MODE THAT PERSISTS IS THE ONE THAT IS ALSO THE DEFAULT — see
    /// `WindowChrome.displayTransform`, which deliberately neither seeds nor writes back.
    /// Stated here as well because this is the type a future case is added to, and a new case
    /// arrives with the same question attached.
    static let defaultMode: DisplayTransformMode = .os
}

// MARK: - The menu's mirror of the key window's mode

/// App-level mirror of the KEY window's `displayTransform`, so a `CommandMenu` — which is built in
/// the App scene and has no window's state in scope — can draw a checkmark against it.
///
/// A direct copy of `RasterMenuState` (RasterSize.swift), including both of the constraints that
/// file measured the hard way. Neither is optional here:
///
///   1. **ALWAYS DEFERRED.** Every trigger fires from inside a SwiftUI update pass, and writing a
///      `@Published` there is "Publishing changes from within view updates is not allowed".
///   2. **COMPARE BEFORE ASSIGN.** `@Published` publishes on every assignment, and the `Commands`
///      struct holds this as `@ObservedObject` — so a redundant publish rebuilds the main menu, and
///      AppKit then drops its injected Window-menu items for the rest of that tracking session.
///      The equality guards below are load-bearing, not tidiness.
@MainActor
final class DisplayTransformMenuState: ObservableObject {
    static let shared = DisplayTransformMenuState()

    /// The key window's mode, mirrored. nil when no deck is key — the menu is then disabled, and
    /// no item is checked, which is the honest reading of "there is no window to apply this to".
    @Published private(set) var current: DisplayTransformMode?

    /// Whether the menu items are live. A display transform is a transform OF something, so the
    /// menu is dead until the key window has a source — the same rule `RasterMenuState` applies.
    @Published private(set) var enabled = false

    private var refreshQueued = false

    private init() {}

    /// Coalesce a re-derivation onto the next main-actor turn. See constraint 1 above.
    func setNeedsRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        Task { @MainActor in
            self.refreshQueued = false
            self.refresh()
        }
    }

    /// Recompute everything from current facts. See constraint 2 above for the guards.
    private func refresh() {
        let deck = DeckRegistry.shared.keyDeck
        let newCurrent = deck?.chrome?.displayTransform
        let newEnabled = (deck?.engine?.displaySize != nil)
        if current != newCurrent { current = newCurrent }
        if enabled != newEnabled { enabled = newEnabled }
    }
}

// MARK: - The menu

/// The Color menu.
///
/// ⚠️ **A NEW TOP-LEVEL `CommandMenu`, AND THAT IS A DELIBERATE CHOICE, NOT A DEFAULT.** Two facts
/// decided it:
///
///   * **There is no Color menu to extend.** The app's `.commands` block carries appInfo,
///     appSettings, newItem, `RasterSizeCommands` and a DEBUG-gated Debug menu. Nothing colour.
///   * **The existing Color CONTROL is NDI-only.** `ContentView.colorControl` is placed under
///     `if activeLiveSource == .ndi`, and it governs INTERPRETATION (`NDIColorimetryOverride`),
///     which is §6.3's *first* section. Its own doc comment marks a seam for a second section —
///     but that seam sits inside the NDI gate, so hanging the display transform off it would make
///     the mode unreachable during file playback, which is the case §6.5 and §6.6 were measured
///     on and the case this control exists to serve.
///
/// `CommandMenu("View")` was measured to append a SECOND View menu rather than merge
/// (RasterSize.swift:347), which is why raster size uses `CommandGroup(after: .toolbar)`. That trap
/// does not apply here: SwiftUI synthesizes no menu titled "Color", so there is nothing to collide
/// with.
///
/// ⚠️ **WHEN §6.3's CONTROL-BAR PULLDOWN LANDS (Phase 2b), THIS MENU STAYS.** They are two surfaces
/// onto one per-window value, exactly as ⌃⌥T and the control-bar scopes button are onto
/// `showTray`. The pulldown is the discoverable one; the menu is the one that appears in Help's
/// menu search and can carry a shortcut.
struct DisplayTransformCommands: Commands {
    @ObservedObject private var state = DisplayTransformMenuState.shared

    var body: some Commands {
        CommandMenu("Color") {
            ForEach(DisplayTransformMode.allCases) { mode in
                // `Toggle` and not `Button`, so AppKit draws a real checkmark — the same reason
                // `RasterSizeCommands` uses one.
                Toggle(mode.menuTitle, isOn: binding(for: mode))
                    // ⚠️ PER ITEM. `Commands` has no `.disabled`; the modifier exists on `View`.
                    .disabled(!state.enabled)
            }
        }
    }

    /// Get compares against the mirror; set routes through the registry and never writes the
    /// mirror back — the window's own `WindowChrome` is the single owner, and the mirror
    /// re-derives from it. Copied from `RasterSizeCommands.binding(for:)`.
    private func binding(for mode: DisplayTransformMode) -> Binding<Bool> {
        Binding(
            get: { state.current == mode },
            set: { isOn in
                guard isOn else { return }   // unchecking a radio item is not a command
                DeckRegistry.shared.setDisplayTransform(mode)
            }
        )
    }
}
