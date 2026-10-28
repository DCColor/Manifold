//
//  ShortcutCenter.swift — the app's half of the shortcut registry (docs/SHORTCUTS_AUDIT.md §4.4).
//
//  ONE registry (`ShortcutRegistry`, in the package, unit-tested) says which key every action has. ONE `NSEvent`
//  local monitor, installed here, feeds every key the menus do not take to the registry's `KeyDispatcher`. Menu items
//  carry the registry's key (`registryShortcut`) and call `runFromMenu`. Both paths end in the same place: the key
//  window's `WindowDeck.shortcutHandlers`, which its ContentView registers, or one of the app-level actions below.
//
//  Before this there were four mechanisms and three hand-kept lists: hidden zero-opacity buttons in ContentView,
//  `TransportKeyMonitor`'s monitor, `HoldToCompare`'s monitor, and the menus (audit §1.1).
//

import AppKit
import SwiftUI
import ShortcutRegistry

/// One action a window can perform for a shortcut.
struct DeckShortcut {
    let isEnabled: @MainActor () -> Bool
    let perform: @MainActor () -> Void

    init(enabled: @escaping @MainActor () -> Bool = { true }, _ perform: @escaping @MainActor () -> Void) {
        self.isEnabled = enabled
        self.perform = perform
    }
}

/// ── THE ONE PLACE THE DEBUG HOOKS ARE SWITCHED ON ────────────────────────────────────────────────
///
/// ⚠️ PROFILE DEFINES `DEBUG`, AND EVERY BUILD CUT TO DATE HAS BEEN PROFILE (CLAUDE.md). So the `.profile` tier below
/// is ON IN EVERY TESTER BUILD, exactly as the hidden ⌃⌥ buttons it replaces were. Before a public release this
/// predicate must be switched to a flag that only a developer build carries — that is a release-gate item in
/// docs/BUGS.md, not a change made here. The `.configDebug` tier is the real Debug-only gate
/// (`MANIFOLD_CONFIG_DEBUG`, carried by the Debug configuration alone): the LiveClock setpoint mutators. Do not
/// "simplify" it to `#if DEBUG`; that would put them in front of testers (docs/BUGS.md).
enum ShortcutDebugGate {
    static func isEnabled(_ tier: DebugTier) -> Bool {
        switch tier {
        case .profile:
            #if DEBUG
            return true
            #else
            return false
            #endif
        case .configDebug:
            #if MANIFOLD_CONFIG_DEBUG
            return true
            #else
            return false
            #endif
        }
    }

    /// Whether the Keyboard Shortcuts window lists the debug hooks: the same opt-in as the Debug menu.
    static var showsDebugSection: Bool {
        #if DEBUG
        return DebugMenuGate.isEnabled
        #else
        return false
        #endif
    }
}

@MainActor
final class ShortcutCenter: KeyDispatchHost {
    static let shared = ShortcutCenter()

    let registry: ShortcutRegistry
    let dispatcher: KeyDispatcher
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    private init() {
        registry = ShortcutRegistry(debugTierEnabled: ShortcutDebugGate.isEnabled)
        dispatcher = KeyDispatcher(registry: registry)
    }

    /// Once, from `ManifoldApp.init`.
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            // `KeyEvent` is Sendable and `NSEvent` is not: convert first, so only a Bool crosses into the actor.
            guard let key = KeyEvent(event) else { return event }
            let center = ShortcutCenter.shared
            // A menu item's key that the field being typed into uses itself (N, ⌘↑): straight to the field, ahead of
            // AppKit's key-equivalent matching, which would otherwise give it to the menu (§8 item 5).
            let toField = MainActor.assumeIsolated { center.dispatcher.textFieldTakes(key, host: center) }
            if toField {
                MainActor.assumeIsolated { NSApp.keyWindow?.firstResponder?.keyDown(with: event) }
                return nil
            }
            let consumed = MainActor.assumeIsolated { center.dispatcher.handle(key, host: center) }
            return consumed ? nil : event
        }
        NSLog("[SHORTCUTS] key monitor %@ — %d actions, %@ customised, debug hooks: profile %@, debug-config %@",
              monitor == nil ? "⚠️ NOT installed" : "installed", registry.definitions.count,
              registry.hasOverrides ? "some" : "none",
              ShortcutDebugGate.isEnabled(.profile) ? "on" : "off", ShortcutDebugGate.isEnabled(.configDebug) ? "on" : "off")
        // A hold, and K held for K+J/L, always end: while a menu tracks, or another window or app is key, the key-up
        // goes elsewhere and the window would be left comparing or slow-playing.
        let nc = NotificationCenter.default
        let enders: [(Notification.Name, String)] = [(NSWindow.didResignKeyNotification, "window not key"),
                                                     (NSApplication.didResignActiveNotification, "app not active"),
                                                     (NSMenu.didBeginTrackingNotification, "a menu opened")]
        MenuKeyKeeper.shared.start(registry: registry)
        #if DEBUG
        // `MANIFOLD_MENU_AUDIT=1`: the menu bar judged against the registry every 3 s (`MenuKeyAudit`), one line a pass.
        if ProcessInfo.processInfo.environment["MANIFOLD_MENU_AUDIT"] == "1" {
            var pass = 0
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let bar = NSApp.mainMenu else { return }
                    pass += 1
                    let items = MenuItemSnapshot.all(in: bar)
                    let problems = MenuKeyAudit.audit(items, registry: ShortcutCenter.shared.registry)
                    // The item Robbie's checklist found without its key, every instance of it, as the menu bar holds it.
                    let scopes = items.filter { $0.title == "Show/Hide Scopes" }
                        .map { "\($0.menu) key '\($0.keyEquivalent)' mods \($0.modifiers)\($0.isHidden ? " hidden" : "")" }
                    NSLog("[MENU-AUDIT] pass %d: %d items, %d problem(s)%@ · Show/Hide Scopes: %@", pass, items.count, problems.count,
                          problems.isEmpty ? "" : " — " + problems.map(\.description).joined(separator: "; "),
                          scopes.joined(separator: " | "))
                }
            }
        }
        #endif
        for (name, reason) in enders {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ShortcutCenter.shared.dispatcher.reset(host: ShortcutCenter.shared, reason: reason) }
            })
        }
    }

    // MARK: Which window

    /// The deck a KEY goes to: the key window's, and only when the key window is a deck's. A sheet, Settings, About
    /// or the Keyboard Shortcuts window being key means the key is not this deck's (as `TransportKeyMonitor` held).
    private var keyWindowDeck: WindowDeck? {
        guard let key = NSApp.keyWindow, let deck = DeckRegistry.shared.keyDeck, deck.window === key else { return nil }
        return deck
    }

    /// The deck a MENU COMMAND goes to: `DeckRegistry.keyDeck`, the lookup every menu command already uses.
    private var menuDeck: WindowDeck? { DeckRegistry.shared.keyDeck }

    // MARK: Menus

    /// "Mode · ⌥⌘X" for a heading or label that teaches its key, or plain "Mode" while the action has none.
    static func hint(_ text: String, _ id: ShortcutID) -> String {
        shared.registry.label(for: id).map { "\(text) · \($0)" } ?? text
    }

    /// A menu item's action. Beeps when this window cannot do it now, as a disabled shortcut always did.
    func runFromMenu(_ id: ShortcutID) {
        if canPerform(id, on: menuDeck) { perform(id, on: menuDeck) } else { NSSound.beep() }
    }

    // MARK: KeyDispatchHost

    var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        // An `NSTextField` being edited installs the window's FIELD EDITOR — an `NSTextView` — as first responder,
        // which catches SwiftUI's `TextField` and `TextEditor` both.
        if let textView = responder as? NSTextView { return textView.isFieldEditor || textView.isEditable }
        return responder is NSTextField
    }

    var isTimecodeEntryOpen: Bool { keyWindowDeck?.transportKeys?.isActive ?? false }
    func timecodeEntryKey(_ event: KeyEvent) -> Bool { keyWindowDeck?.transportKeys?.entryKey(event) ?? false }
    func timecodeEntryOpen(_ event: KeyEvent) -> Bool { keyWindowDeck?.transportKeys?.openKey(event) ?? false }

    func canPerform(_ id: ShortcutID) -> Bool { canPerform(id, on: keyWindowDeck) }
    func perform(_ id: ShortcutID) { perform(id, on: keyWindowDeck) }

    func beginHold(_ id: ShortcutID) -> Bool {
        guard keyWindowDeck != nil else { return false }
        return HoldToCompare.shared.begin(id)
    }
    func endHold(reason: String) { HoldToCompare.shared.release(reason: reason) }
    func stepFrames(_ frames: Int) { keyWindowDeck?.engine?.stepFrame(by: frames) }
    func shuttle(rate: Float) { keyWindowDeck?.engine?.setShuttleRate(rate) }

    // MARK: Actions

    /// App-level actions are answered here; everything else is the window's.
    private func canPerform(_ id: ShortcutID, on deck: WindowDeck?) -> Bool {
        guard let deck else { return false }
        if RasterSize.forShortcut(id) != nil { return deck.engine?.displaySize != nil }
        if DisplayTransformMode.forShortcut(id) != nil { return deck.engine?.displaySize != nil }
        if id == .fullScreen { return deck.window != nil }
        return deck.shortcutHandlers[id]?.isEnabled() ?? false
    }

    private func perform(_ id: ShortcutID, on deck: WindowDeck?) {
        guard let deck else { return }
        // The same write `DeckRegistry.setRasterSize` makes, to this deck rather than the menu's.
        if let size = RasterSize.forShortcut(id) { deck.chrome?.rasterSize = size; return }
        if let mode = DisplayTransformMode.forShortcut(id) { DeckRegistry.shared.setDisplayTransform(mode, on: deck); return }
        if id == .fullScreen { deck.window?.toggleFullScreen(nil); return }
        deck.shortcutHandlers[id]?.perform()
    }
}

// MARK: - Menu items

extension View {
    /// The registry's key for a menu item, or none: no key, or a bare / ⇧ key (the dispatcher's, see
    /// `ShortcutRegistry.menuChord`). Re-evaluated whenever the Commands holding it observe the registry.
    func registryShortcut(_ id: ShortcutID, _ registry: ShortcutRegistry) -> some View {
        keyboardShortcut(registry.menuChord(for: id)?.menuShortcut())
    }
}

/// A menu item for a shortcut: the registry's title and key, and `runFromMenu`.
struct ShortcutMenuItem: View {
    let id: ShortcutID
    @ObservedObject var registry: ShortcutRegistry
    var title: String? = nil

    var body: some View {
        Button(title ?? registry.definition(id).title) { ShortcutCenter.shared.runFromMenu(id) }
            .registryShortcut(id, registry)
    }
}

extension RasterSize {
    var shortcutID: ShortcutID? {
        switch self {
        case .percent100: return .raster100
        case .percent75: return .raster75
        case .percent50: return .raster50
        case .percent25: return .raster25
        case .fitToScreen: return .rasterFit
        case .automatic, .custom: return nil
        }
    }
    static func forShortcut(_ id: ShortcutID) -> RasterSize? { menuChoices.first { $0.shortcutID == id } }
}

extension DisplayTransformMode {
    var shortcutID: ShortcutID {
        switch self {
        case .os: return .displayOS
        case .reference: return .displayReference
        case .bypass: return .displayBypass
        }
    }
    static func forShortcut(_ id: ShortcutID) -> DisplayTransformMode? { allCases.first { $0.shortcutID == id } }
}

// MARK: - Menu keys

/// KEEPS EVERY REGISTRY MENU ITEM'S KEY ON IT (Robbie's checklist item 1, 2026-10-27).
///
/// ⚠️ WHY APPKIT, AFTER SWIFTUI. SwiftUI builds a hidden "Toggle Sidebar" item (`toggleSidebar:`, ⌥⌘S — the Finder's
/// sidebar key) into the menu bar of every app, and no `CommandGroup` removes it (replacing `.sidebar` only moved it from
/// View to Help, measured). Two items with one key: on each rebuild SwiftUI gives the key to ONE of them, so on some
/// launches Show/Hide Scopes came up with no key, its menu showed none, and ⌥⌘S went to the hidden item, which does
/// nothing here. It is the key, not the item: Show/Hide Inspector moved to ⌥⌘S (argument domain) lost its key the same
/// way, and Show/Hide Scopes moved to ⌥⌘X kept its own (measured).
///
/// So whenever SwiftUI adds or changes menu items, this puts each `.menu` action's registry key back on its item if it was
/// left off, and takes that key off any OTHER item that holds it — an item that is not a registry action's, which can
/// only be one SwiftUI or AppKit added. `MenuKeyAudit` judges the result (`MANIFOLD_MENU_AUDIT=1`, and the tests).
@MainActor
final class MenuKeyKeeper {
    static let shared = MenuKeyKeeper()
    private var registry: ShortcutRegistry?
    private var observers: [NSObjectProtocol] = []
    private var pending = false
    private var logged: Set<String> = []

    func start(registry: ShortcutRegistry) {
        guard self.registry == nil else { return }
        self.registry = registry
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MenuKeyKeeper.shared.schedule() }
            })
        }
        schedule()
    }

    /// One pass per run-loop turn, however many items SwiftUI touched in it.
    private func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { MainActor.assumeIsolated { MenuKeyKeeper.shared.keep() } }
    }

    private func keep() {
        pending = false
        guard let registry, let bar = NSApp.mainMenu else { return }
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        var ours: [ObjectIdentifier] = []
        var wants: [(item: NSMenuItem, key: String, mods: NSEvent.ModifierFlags, title: String)] = []
        for def in registry.definitions where def.dispatch == .menu {
            if let tier = def.debug, !registry.isDebugEnabled(tier) { continue }
            guard let home = MenuKeyAudit.menuHomes[def.id],
                  let top = bar.items.first(where: { $0.title == home })?.submenu,
                  let item = items(top).first(where: { $0.title == def.title && !$0.isHidden }) else { continue }
            ours.append(ObjectIdentifier(item))
            guard let chord = registry.menuChord(for: def.id), let want = MenuKeyAudit.expected(chord) else { continue }
            wants.append((item, want.key, want.modifiers, def.title))
        }
        let everything = items(bar)
        for want in wants {
            for other in everything where !ours.contains(ObjectIdentifier(other))
                && other.keyEquivalent.lowercased() == want.key.lowercased()
                && other.keyEquivalentModifierMask.intersection(MenuKeyAudit.relevant) == want.mods {
                other.keyEquivalent = ""
                note("'\(other.title)'\(other.isHidden ? " (hidden)" : "") had \(want.title)'s key; cleared")
            }
            // Case-insensitive, as `MenuKeyAudit` judges: only a key that is MISSING or different is put back; SwiftUI's
            // own spelling of one it kept (⇧⌘D as "d" or "D") is left as SwiftUI set it.
            if want.item.keyEquivalent.lowercased() != want.key.lowercased()
                || want.item.keyEquivalentModifierMask.intersection(MenuKeyAudit.relevant) != want.mods {
                want.item.keyEquivalent = want.key
                want.item.keyEquivalentModifierMask = want.mods
                note("'\(want.title)' had lost its key; put back")
            }
        }
    }

    /// Once per distinct event per launch: a rebuild repeats them, and the log should say it happened, not count it.
    private func note(_ text: String) {
        guard logged.insert(text).inserted else { return }
        NSLog("[SHORTCUTS] menu key: %@", text)
    }
}

