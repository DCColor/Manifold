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
    /// ── WHERE 204 COMES FROM, AND WHY THE 240 BEFORE IT WAS DERIVED WRONG ────────────────
    ///
    /// 204 is what the old proportional layout gave at the window size actually in use when the
    /// fixed tray was reported as too short. It is a MEASUREMENT of what was lost, not a taste
    /// judgement, and it restores that rather than inventing a number.
    ///
    /// The 240 it replaced was 33% of the app's EMPTY-window default (1280×720 → 238). That is the
    /// wrong window to have measured: a window with a source in it is never that size, because
    /// `WindowSizer.sizeToSource` fits the source into 80% of the visible frame at up to 1:1. The
    /// constant was calibrated against a window nobody grades in.
    ///
    /// This is now the SEED for `trayHeight` (the per-window value the divider drags), not the tray
    /// height itself — a fresh install, and any window opened before anyone has dragged a divider,
    /// gets exactly what Arc B shipped.
    static let defaultTrayHeight: CGFloat = 204

    /// ── THE FLOOR THE DIVIDER STOPS AT, AND WHAT IT IS MEASURED FROM ─────────────────────
    ///
    /// Below this the value-axis ruler stops being readable, and that is a measurable event rather
    /// than a matter of taste. The derivation, all of it from constants in this app:
    ///
    ///   * A graticule label renders in `.system(size: 11, design: .monospaced)`
    ///     (`graticuleLabelFontSize`). MEASURED height of that font's layout box: **14.000 pt**.
    ///   * `drawGraticuleLabel` draws each label on a backing pill of `height + 2` → **16 pt** per
    ///     labelled major, and that pill is what has to not collide with its neighbour.
    ///   * The default scale is `.bit10`, whose `majors` are
    ///     0/128/256/384/512/640/768/896/1023 — **9 labelled lines**. (8-bit also has 9. IRE has 11
    ///     and is the outlier; see the note below.)
    ///   * So the plot needs 9 × 16 = **144 pt** before the ruler's own labels start overlapping.
    ///   * A slot is not all plot: `scopeHeaderHeight` (22) is the name/slider band, and
    ///     `scopePlotInset` (10) is applied top AND bottom → 20.
    ///
    ///     144 + 22 + 20 = **186**
    ///
    /// ⚠️ IRE (11 majors) NEEDS 176 pt OF PLOT, i.e. a 218-pt tray, and is therefore already tight
    /// at the 204 default. It degrades by touching rather than by becoming illegible — the labels
    /// keep their backing pills and `drawGraticuleLabel` clamps the end ones inside the plot — so it
    /// is not what the floor is set by. If IRE ever becomes the default, this number moves to 218.
    static let minTrayHeight: CGFloat = 186

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
        static let trayHeight  = "manifold.scope.trayHeight"
        /// Owned by `RasterSize` rather than spelled out here: the Settings picker binds the same
        /// key through `@AppStorage`, and two literals that must match is one literal too many.
        static let rasterSize  = RasterSize.defaultsKey
    }

    /// Scopes tray open/close for THIS window. Toggled by ⌃⌥T and the control-bar scopes button.
    @Published var showTray: Bool { didSet { defaults.set(showTray, forKey: Key.showTray) } }

    /// Height of the scopes tray in THIS window, in points — what the divider drags (Arc C).
    ///
    /// Seeded and written back exactly like `showTray` above: last writer wins, so the height a
    /// window is left at becomes the height the next window opens with, and there is no separate
    /// "default" record to keep in step. Two open windows are independent, which is the whole
    /// reason this class exists.
    ///
    /// ⚠️ CLAMPED BY THE VIEW, NOT HERE, and the asymmetry is deliberate. The FLOOR
    /// (`minTrayHeight`) is a constant and could live here; the CEILING cannot — it is "the point
    /// at which the window can no longer grow", which depends on the window's current width, the
    /// docked bar, and which screen the window is on. `ContentView.clampedTrayHeight` is where all
    /// four are in scope. A stored value from a bigger screen is therefore re-clamped on use rather
    /// than on load, so moving a window between displays does not permanently shrink its tray.
    @Published var trayHeight: CGFloat { didSet { defaults.set(trayHeight, forKey: Key.trayHeight) } }

    /// HOW LARGE THE PICTURE IS DRAWN in THIS window, as a percentage of the source raster. See
    /// RasterSize.swift for what the percentage means (and the two things it deliberately does not
    /// mean); `WindowSizer` is what turns it into a window size.
    ///
    /// Seeded and written back like everything else here — last writer wins, so the size a window
    /// was set to is the size the next window opens at — with ONE exception, which is the `guard`:
    ///
    /// ⚠️ `.custom` IS NEVER PERSISTED. It is not a size, it is the ABSENCE of a policy ("the user
    /// dragged this window's edge; leave it alone"), and seeding a new window with it would mean a
    /// window that opens at no particular size and reports `Custom` before anyone has touched it.
    /// Skipping the write leaves the stored value at the last size actually CHOSEN, which is both
    /// the useful seed and the honest answer for the Settings picker that reads the same key.
    @Published var rasterSize: RasterSize {
        didSet {
            guard rasterSize != .custom else { return }
            defaults.set(rasterSize.rawValue, forKey: Key.rasterSize)
        }
    }

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
        // ⚠️ `double(forKey:)` RETURNS 0 FOR A MISSING KEY, and 0 is a legal-looking tray height that
        // would collapse the tray on every fresh install. The `bool(forKey:)` line above gets away
        // with it because `false` IS the intended default; this one cannot, so the absence of the
        // key is tested directly rather than inferred from the value. Values below the floor are
        // also rejected here, so a defaults file hand-edited to 12 does not produce an unusable
        // window that the user then has to discover the divider to fix.
        let storedTrayHeight = defaults.object(forKey: Key.trayHeight) as? Double
        trayHeight = max(CGFloat(storedTrayHeight ?? Double(Self.defaultTrayHeight)),
                         Self.minTrayHeight)
        // ⚠️ A STORED `custom` IS TREATED AS "NO CHOICE MADE". The `didSet` above cannot write one,
        // so the only way the key holds it is a hand-edited defaults file — and `.custom` as a SEED
        // would open a window with no sizing policy and a readout claiming the user had dragged it.
        // `.automatic` is the honest reading of "nothing has been chosen here": the app's original
        // opening rule, which is also what a fresh install gets from the `??`.
        let storedRaster = RasterSize(rawValue: defaults.string(forKey: Key.rasterSize) ?? "")
        rasterSize = (storedRaster == .custom ? nil : storedRaster) ?? .automatic
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
