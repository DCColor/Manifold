//
//  AppearanceProbe.swift — DEBUG: which appearance each window and menu is drawn in (2026-10-27, checklist item 3).
//
//  `MANIFOLD_DEBUG_APPEARANCE=1`: every visible window's effective appearance, logged when it changes (one line per window,
//  `[APPEARANCE] window …`), and each menu's when it opens (`[APPEARANCE] menu …`). Accessibility does not expose
//  appearance, and screenshots are not used, so this is how the player window's dark-always rule is measured.
//

#if DEBUG
import AppKit

@MainActor
enum AppearanceProbe {
    private static var last: [ObjectIdentifier: String] = [:]
    private static var observer: NSObjectProtocol?

    static func startIfAsked() {
        guard ProcessInfo.processInfo.environment["MANIFOLD_DEBUG_APPEARANCE"] == "1", observer == nil else { return }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { sample() } }
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                                                          queue: .main) { note in
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu else { return }
                NSLog("[APPEARANCE] menu '%@' (%d items) %@", menu.title, menu.items.count, name(menu.effectiveAppearance))
            }
        }
        // Not `NSApp` here: this runs from `ManifoldApp.init`, before the application object exists (reading it there
        // crashed the 2026-10-27 run). The app's appearance is logged with the first sample instead.
        NSLog("[APPEARANCE] probe on")
    }

    private static var loggedApp = false

    private static func sample() {
        if !loggedApp, let app = NSApp { loggedApp = true; NSLog("[APPEARANCE] app %@", name(app.effectiveAppearance)) }
        for window in NSApp.windows where window.isVisible {
            let line = "window '\(window.title)' \(type(of: window)) set \(window.appearance?.name.rawValue ?? "none") → \(name(window.effectiveAppearance))"
            let id = ObjectIdentifier(window)
            if last[id] != line { last[id] = line; NSLog("[APPEARANCE] %@", line) }
        }
    }

    private static func name(_ a: NSAppearance) -> String {
        a.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight])?.rawValue ?? a.name.rawValue
    }
}
#endif

