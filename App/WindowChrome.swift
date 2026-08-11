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
