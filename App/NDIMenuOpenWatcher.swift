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
//  attached, and `ContentView.ndiSourceListItems` — whose content SwiftUI composes as the menu opens —
//  asks `fallbackNeeded(composedAt:)` 0.3 s later. A menu that was open then and could not be watched
//  means discovery starts, with a ⚠️ FALLBACK line in the log. That gives up the P1 refinement (picking
//  a saved stream also starts discovery), never NDI itself. A composition with NO menu open starts
//  nothing (the 2026-10-29 leak; see `fallbackNeeded`).
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

    /// The last menu tracking pass: when it began and ended, whether it found an "NDI" submenu and has it
    /// wrapped, and whether it was a menu-bar menu (which never holds the NDI list). Main thread only.
    private struct TrackingPass {
        let menu: ObjectIdentifier
        let began: CFTimeInterval
        var ended: CFTimeInterval?
        let attached: Bool
        let inMenuBar: Bool
    }
    @MainActor private static var lastPass: TrackingPass?

    /// Whether the NDI list composed at `composedAt` (`CACurrentMediaTime()`) needs the fallback: a menu was
    /// tracking at that moment, it is not a menu-bar menu, and no "NDI" submenu in it is watched. Read by
    /// `ContentView` 0.3 s after the list is composed.
    ///
    /// ⚠️ "NO MENU OPEN" IS NOT "A MENU WE COULD NOT WATCH" (privacy P1, fixed 2026-10-29). This used to ask whether
    /// a menu had BEGUN tracking in the last 2 s and fall back when none had. But SwiftUI composes the list at other
    /// moments too. Measured: open the control bar's NDI flyout while the window is not key (the watcher's
    /// notification is then ignored, `ContentView`), and the list's `.onAppear` fires when the window next becomes
    /// key, with no menu open. The old test read that as "not watched" and started discovery: the 2026-10-29 leak
    /// (docs/BUGS.md). It also read a list first realized more than 2 s into a WATCHED pass (the control bar
    /// composes it when the NDI flyout first opens, not when the parent does) as unwatched.
    @MainActor static func fallbackNeeded(composedAt: CFTimeInterval) -> Bool {
        guard let pass = lastPass, !pass.attached, !pass.inMenuBar else { return false }
        // The pass was in progress at the composition: began before it (allowing for the order the two
        // notifications land in) and had not ended by then.
        return pass.began <= composedAt + 0.3 && (pass.ended.map { $0 >= composedAt } ?? true)
    }

    static func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                               object: nil, queue: .main) { note in
            guard let menu = note.object as? NSMenu else { return }
            MainActor.assumeIsolated {
                lastPass = TrackingPass(menu: ObjectIdentifier(menu), began: CACurrentMediaTime(), ended: nil,
                                        attached: wrapNDISubmenus(in: menu), inMenuBar: isInMenuBar(menu))
                #if DEBUG
                MenuProbe.trackingBegan(menu)
                #endif
            }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification,
                                               object: nil, queue: .main) { note in
            guard let menu = note.object as? NSMenu else { return }
            MainActor.assumeIsolated {
                if lastPass?.menu == ObjectIdentifier(menu) { lastPass?.ended = CACurrentMediaTime() }
            }
        }
        #if DEBUG
        MainActor.assumeIsolated { MenuProbe.install() }
        #endif
    }

    /// Whether `menu` is the menu bar or one of its menus.
    @MainActor
    private static func isInMenuBar(_ menu: NSMenu) -> Bool {
        guard let bar = NSApp.mainMenu else { return false }
        var m: NSMenu? = menu
        while let current = m {
            if current === bar { return true }
            m = current.supermenu
        }
        return false
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
                    #if DEBUG
                    MenuProbe.log("NDI submenu will open \(MenuProbe.id(submenu))")
                    #endif
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

#if DEBUG
/// `MANIFOLD_DEBUG_NDI_MENU_PROBE=1` (pre-ship removal, docs/BUGS.md): one `[NDI-MENU]` line for every item SwiftUI adds,
/// removes or changes in a menu that holds an "NDI" submenu, or in that submenu, while it is tracking; for each tracking
/// pass's start and end; and for each time the NDI item's submenu is a different `NSMenu` from the one wrapped (a flyout
/// replaced under the pointer). `NDIService` adds one line per discovery poll, and `ContentView` its `_printChanges()`, so
/// every menu change can be put beside what caused it. Measured the NDI flyout jitter (2026-10-29).
@MainActor
enum MenuProbe {
    static let enabled = ProcessInfo.processInfo.environment["MANIFOLD_DEBUG_NDI_MENU_PROBE"] == "1"
    private static var parents = NSHashTable<NSMenu>.weakObjects()
    private static var submenus = NSHashTable<NSMenu>.weakObjects()
    private static let t0 = CACurrentMediaTime()

    static func id(_ menu: NSMenu) -> String { String(UInt(bitPattern: ObjectIdentifier(menu).hashValue), radix: 16) }

    static func log(_ s: String) {
        guard enabled else { return }
        NSLog("[NDI-MENU] %.3f %@", CACurrentMediaTime() - t0, s)
    }

    static func install() {
        guard enabled else { return }
        setvbuf(stdout, nil, _IOLBF, 0)   // `_printChanges()` lines land in order with the NSLog lines
        let center = NotificationCenter.default
        for (name, what) in [(NSMenu.didAddItemNotification, "add"), (NSMenu.didRemoveItemNotification, "remove"),
                             (NSMenu.didChangeItemNotification, "change")] {
            center.addObserver(forName: name, object: nil, queue: nil) { note in
                guard let menu = note.object as? NSMenu,
                      let index = note.userInfo?["NSMenuItemIndex"] as? Int else { return }
                MainActor.assumeIsolated { itemNote(menu, what, index) }
            }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { note in
            guard let menu = note.object as? NSMenu else { return }
            MainActor.assumeIsolated {
                if parents.contains(menu) { log("parent tracking ended \(id(menu))") }
                else { log("menu tracking ended \(id(menu)) \"\(menu.title)\"") }
            }
        }
        // What else happens around an NDI list composition (the P1 fallback trigger, 2026-10-29). Windows by pointer,
        // never by title (a player window's title is the file name).
        let windowNotes: [(Notification.Name, String)] = [
            (NSWindow.didChangeScreenNotification, "changed screen"), (NSWindow.didBecomeKeyNotification, "became key"),
            (NSWindow.didResignKeyNotification, "resigned key"), (NSWindow.willBeginSheetNotification, "will begin sheet"),
            (NSWindow.didEndSheetNotification, "did end sheet"), (NSWindow.didChangeBackingPropertiesNotification,
            "changed backing properties"), (NSWindow.didMoveNotification, "moved")]
        for (name, what) in windowNotes {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    log("window \(String(UInt(bitPattern: ObjectIdentifier(window).hashValue), radix: 16)) \(what)")
                }
            }
        }
    }

    static func trackingBegan(_ menu: NSMenu) {
        guard enabled else { return }
        if !menu.items.contains(where: { $0.title == NDIMenuOpenWatcher.submenuTitle && $0.submenu != nil }) {
            log("menu tracking began \(id(menu)) \"\(menu.title)\" items=\(menu.items.count) (no NDI item)")
        }
        for item in menu.items where item.title == NDIMenuOpenWatcher.submenuTitle {
            guard let submenu = item.submenu else { continue }
            parents.add(menu)
            submenus.add(submenu)
            log("parent tracking began \(id(menu)) items=\(menu.items.count); NDI submenu \(id(submenu)) "
                + "items=\(submenu.items.map(\.title))")
        }
    }

    private static func itemNote(_ menu: NSMenu, _ what: String, _ index: Int) {
        let title = index < menu.items.count ? menu.items[index].title : "?"
        if submenus.contains(menu) {
            log("NDI submenu \(id(menu)) \(what) [\(index)] \"\(PrivacyLog.ndiSourceName(title))\" "
                + "→ \(menu.items.count) items")
        } else if parents.contains(menu) {
            var line = "parent \(id(menu)) \(what) [\(index)] \"\(title)\" → \(menu.items.count) items"
            if index < menu.items.count, menu.items[index].title == NDIMenuOpenWatcher.submenuTitle,
               let sub = menu.items[index].submenu, !submenus.contains(sub) {
                submenus.add(sub)
                line += " — NDI SUBMENU REPLACED by \(id(sub))"
            }
            log(line)
        }
    }
}
#endif

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

    #if DEBUG
    func menuDidClose(_ menu: NSMenu) {
        MenuProbe.log("NDI submenu did close \(MenuProbe.id(menu))")
        original?.menuDidClose?(menu)
    }
    #endif

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }
}
