import SwiftUI

/// PER-WINDOW chrome state: the arrangement of everything that surrounds the picture.
///
/// These four things used to be `@AppStorage` on ContentView, which made them app-wide — opening
/// the scopes tray in one window opened it in every window, and the three slot selections were a
/// single shared triple. That is wrong on its own terms (two windows exist so they can show
/// different things), and it is load-bearing for the window-sizing work that follows: the height of
/// the chrome below the video is a PER-WINDOW quantity, so if `showTray` stays global then toggling
/// the tray in one window has to resize every window at once.
///
/// The scope MODELS were already per-window (`@StateObject` in ContentView), so the state was
/// already half-split: each window computed its own traces, but whether the tray was open was
/// global. This class finishes the split for the presentation half.
///
/// ## Seeding and write-back — the exact semantics
///
/// Each window seeds from UserDefaults at construction, and every mutation writes straight back to
/// the same key. There is no separate "default" record: **the stored value is simply whatever the
/// most recent window wrote, and that is what the next window opens with.** Last writer wins.
///
/// Concretely, with two windows:
///   1. W1 opens with the tray closed (stored value `false`).
///   2. User opens the tray in W1 → `showTray = true` is written.
///   3. W2 opens → seeds `true`, tray open.
///   4. User closes the tray in W2 → `showTray = false` is written. **W1 is unaffected and keeps
///      its tray open** — that is the point of the change.
///   5. W3 would now open with the tray closed. On relaunch, the first window opens closed (W2's
///      write was last).
///
/// So "the default" is really "the last arrangement any window was left in", which is the ordinary
/// macOS document-window feel and needs no extra bookkeeping.
///
/// The KEYS ARE UNCHANGED from the `@AppStorage` era, deliberately: an existing install's saved
/// arrangement seeds the first window after this build, so nothing appears to reset on upgrade.
@MainActor
final class WindowChrome: ObservableObject {

    /// Height of the scopes tray, in points. **FIXED, NOT A PROPORTION**, and that is a deliberate
    /// reversal of the `trayHeightFraction = 0.33` this replaces.
    ///
    /// A proportional tray meant resizing the window rescaled the scopes along with the picture,
    /// which is backwards: a waveform does not get more useful when it is taller, and a colourist
    /// dragging a window bigger is asking for more PICTURE. Fixed height makes the window's height
    /// affine in its width (`contentH = contentW / videoAspect + chromeH`), which is exactly the
    /// relationship `WindowSizer` enforces and the one `contentAspectRatio` could not express.
    ///
    /// ── WHERE 204 COMES FROM, AND WHY THE PREVIOUS 240 WAS DERIVED WRONG ─────────────────
    ///
    /// 204 is what the old proportional layout gave at the window size actually in use when the
    /// fixed tray was reported as too short. It is a MEASUREMENT of what was lost, not a taste
    /// judgement, and it restores that rather than inventing a new number.
    ///
    /// The 240 it replaces was 33% of the app's EMPTY-window default (1280×720 → 238). That is the
    /// wrong window to have measured: a window with a source in it is never that size, because
    /// `WindowSizer.sizeToSource` fits the source into 80% of the visible frame at up to 1:1. The
    /// constant was calibrated against a window nobody grades in.
    ///
    /// ⚠️ INTERIM. This is a single app-wide number for a quantity that wants to be per-window and
    /// user-set. Arc C replaces it with a draggable divider that seeds from this constant — see
    /// docs/ARC-C-SCOPE-DIVIDER.md. Do not tune this further; move it to the divider instead.
    static let trayHeight: CGFloat = 204

    /// Opening estimate for the docked control bar's height, in points. The bar MEASURES itself and
    /// reports the real value (see `ContentView.dockedControlBar`), so this is a seed and not an
    /// authority: it only decides the window's height for the one layout pass before the measurement
    /// lands. It is here rather than inlined so the number that would produce a visible first-frame
    /// jump if it were wrong is at least written down next to the thing it estimates.
    static let dockedControlBarHeight: CGFloat = 76

    /// The persisted keys. Same strings the `@AppStorage` declarations used — see above.
    enum Key {
        static let showTray    = "showTray"
        static let slot0       = "manifold.scope.slot0"
        static let slot1       = "manifold.scope.slot1"
        static let slot2       = "manifold.scope.slot2"
        static let controlMode = "controlDisplayMode"
    }

    /// Scopes tray open/close for THIS window. Toggled by ⌃⌥T and the control-bar scopes button.
    @Published var showTray: Bool { didSet { defaults.set(showTray, forKey: Key.showTray) } }

    /// Which scope fills each of the three tray slots, for THIS window. Chosen live from each
    /// slot's header picker.
    @Published var slot0: ScopeKind { didSet { defaults.set(slot0.rawValue, forKey: Key.slot0) } }
    @Published var slot1: ScopeKind { didSet { defaults.set(slot1.rawValue, forKey: Key.slot1) } }
    @Published var slot2: ScopeKind { didSet { defaults.set(slot2.rawValue, forKey: Key.slot2) } }

    /// Overlay (floating auto-hide HUD) vs docked (fixed bar). Stored per window like the rest —
    /// but see `adoptExternalControlMode` below: it has no per-window control surface YET, so today
    /// it still tracks the app-wide Settings picker in every open window.
    @Published var controlMode: ControlDisplayMode {
        didSet { defaults.set(controlMode.rawValue, forKey: Key.controlMode) }
    }

    var isDocked: Bool { controlMode == .docked }

    private let defaults: UserDefaults
    private var controlModeObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Absent key → the SAME fallback the corresponding @AppStorage declaration carried, so a
        // fresh install is byte-identical to the old behaviour. (`bool(forKey:)` returns false for
        // a missing key, which is what `@AppStorage("showTray") = false` did.)
        showTray = defaults.bool(forKey: Key.showTray)
        slot0 = ScopeKind(rawValue: defaults.string(forKey: Key.slot0) ?? "") ?? .waveform
        slot1 = ScopeKind(rawValue: defaults.string(forKey: Key.slot1) ?? "") ?? .parade
        slot2 = ScopeKind(rawValue: defaults.string(forKey: Key.slot2) ?? "") ?? .cie
        controlMode = ControlDisplayMode(rawValue: defaults.string(forKey: Key.controlMode) ?? "")
            ?? .overlay

        // ⚠️ TEMPORARY, AND THE REASON IS THE MISSING CONTROL — NOT A PREFERENCE FOR GLOBAL STATE.
        //
        // Overlay-vs-docked is per-window in STORAGE here, but the only place a user can change it
        // is the app-wide Settings picker (SettingsView's "Controls"). Without this observer,
        // flipping that picker would write the key and change NOTHING in any open window — the
        // change would appear on the NEXT window opened, which reads as a dead control.
        //
        // So every window adopts an external write. Since no per-window writer exists today, that
        // reduces to exactly the old behaviour: Settings flips every window at once. When a
        // per-window control lands (a View-menu item or a control-bar toggle), DELETE THIS OBSERVER
        // — at that point adopting a global write would stomp a window's local choice.
        //
        // Self-write is not a loop: the guard in adoptExternalControlMode compares before assigning,
        // so this window's own didSet-triggered notification is a no-op.
        controlModeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            // Delivered on OperationQueue.main, i.e. the main thread, so the actor assertion holds.
            MainActor.assumeIsolated { self?.adoptExternalControlMode() }
        }
    }

    deinit {
        if let controlModeObserver {
            NotificationCenter.default.removeObserver(controlModeObserver)
        }
    }

    /// Re-read the stored control mode and adopt it if it differs. See the observer comment above.
    private func adoptExternalControlMode() {
        let stored = ControlDisplayMode(rawValue: defaults.string(forKey: Key.controlMode) ?? "")
            ?? .overlay
        if stored != controlMode { controlMode = stored }
    }
}
