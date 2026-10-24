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
