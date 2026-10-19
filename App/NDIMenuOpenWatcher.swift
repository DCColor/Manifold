//
//  NDIMenuOpenWatcher.swift
//  Manifold — tells the key window when an "NDI" submenu OPENS, so NDI discovery starts then and
//  not before (decided 2026-10-19, privacy P1).
//
//  ── WHY THIS EXISTS: SwiftUI GIVES NO SIGNAL FOR A SUBMENU OPENING ──────────────────────────────
//
//  Measured on this build, with a probe on NSMenu's tracking notifications:
//    • SwiftUI composes a Menu's whole tree, submenus included, when the PARENT opens — so
//      `.onAppear` inside the NDI submenu fired the moment "Connect Stream…" opened, and picking a
//      saved stream from that menu started NDI discovery.
//    • `NSMenu.didBeginTrackingNotification` is posted for the parent only, never for the submenu.
//    • The submenu's delegate is SwiftUI's private `MenuHoverDelegate`, which does NOT implement
//      `menuWillOpen(_:)`.
//  So: when a parent menu begins tracking, the "NDI" submenu's delegate is wrapped in a proxy that
//  adds `menuWillOpen(_:)` and forwards every other message to SwiftUI's delegate untouched.
//
//  ⚠️ THE PROXY FORWARDS, IT DOES NOT REPLACE. `responds(to:)` and `forwardingTarget(for:)` pass
//  everything it does not implement to the original delegate, which it holds strongly (an NSMenu's
//  delegate is weak, and the proxy is kept alive as an associated object of the submenu).
//  If SwiftUI ever swaps the delegate, the next tracking pass wraps the new one.
//
//  ── THE SAFETY NET: IF THIS CANNOT ATTACH, NDI MUST STILL WORK ──────────────────────────────────
//
//  All of the above leans on SwiftUI internals: a submenu item titled "NDI" that has a submenu, and a
//  delegate that tolerates being wrapped. A macOS update could change any of it, and the symptom
//  would be silent — "Searching for NDI sources…" forever. So every tracking pass records whether it
//  attached (`attachedForCurrentMenu`), and `ContentView.ndiSourceListItems` — whose content SwiftUI
//  composes when the PARENT opens — checks it at that moment. Not attached means discovery starts
//  then, on the parent opening, with a ⚠️ FALLBACK line in the log. That gives up the P1 refinement
//  (picking a saved stream also starts discovery), never NDI itself.
//

import AppKit
import ObjectiveC

enum NDIMenuOpenWatcher {

    /// Posted on the main thread when an "NDI" submenu is about to open. `ContentView` answers it
    /// in the key window only.
    static let ndiSubmenuWillOpen = Notification.Name("ManifoldNDISubmenuWillOpen")

    /// The submenu title both NDI menus use (`ContentView.streamingMenuContent`, the empty state).
    static let submenuTitle = "NDI"

    private static var installed = false
    private static var proxyKey: UInt8 = 0

    /// When the last menu began tracking, and whether that pass found an "NDI" submenu and has it
    /// wrapped. Main thread only.
    @MainActor private static var lastTrackingBegan: Date?
    @MainActor private static var attachedInLastTracking = false

    /// True when the menu that is opening right now has its NDI submenu watched. Read by
    /// `ContentView` as the NDI list is composed (the parent opening). False means: fall back.
    @MainActor static func attachedForCurrentMenu() -> Bool {
        guard let began = lastTrackingBegan, Date().timeIntervalSince(began) < 2 else { return false }
        return attachedInLastTracking
    }

    static func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                               object: nil, queue: .main) { note in
            guard let menu = note.object as? NSMenu else { return }
            MainActor.assumeIsolated {
                lastTrackingBegan = Date()
                attachedInLastTracking = wrapNDISubmenus(in: menu)
            }
        }
    }

    /// Wraps every "NDI" submenu in `menu`. Returns whether at least one is now watched.
    @MainActor
    private static func wrapNDISubmenus(in menu: NSMenu) -> Bool {
        #if DEBUG
        // MANIFOLD_DEBUG_NDI_WATCHER_DETACHED (pre-ship removal, docs/BUGS.md): behave as if SwiftUI
        // had changed under us — attach to nothing — so the fallback can be exercised.
        if ProcessInfo.processInfo.environment["MANIFOLD_DEBUG_NDI_WATCHER_DETACHED"] != nil { return false }
        #endif
        var attached = false
        for item in menu.items where item.title == submenuTitle {
            guard let submenu = item.submenu else { continue }
            if !(submenu.delegate is ForwardingMenuDelegate) {
                let proxy = ForwardingMenuDelegate(original: submenu.delegate) {
                    NotificationCenter.default.post(name: ndiSubmenuWillOpen, object: nil)
                }
                objc_setAssociatedObject(submenu, &proxyKey, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                submenu.delegate = proxy
            }
            // Read back, rather than assumed: a delegate that would not take is not watched.
            if submenu.delegate is ForwardingMenuDelegate { attached = true }
        }
        return attached
    }
}

/// Adds `menuWillOpen(_:)`; forwards everything else to the delegate it wraps.
private final class ForwardingMenuDelegate: NSObject, NSMenuDelegate {
    private let original: NSMenuDelegate?
    private let onWillOpen: () -> Void

    init(original: NSMenuDelegate?, onWillOpen: @escaping () -> Void) {
        self.original = original
        self.onWillOpen = onWillOpen
    }

    func menuWillOpen(_ menu: NSMenu) {
        onWillOpen()
        original?.menuWillOpen?(menu)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }
}
