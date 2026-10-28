//
//  MenuKeyAudit.swift — every `.menu` action is in its menu, with its key, and no other menu item holds that key.
//
//  ⚠️ WHY THIS EXISTS (2026-10-27): View ▸ Show/Hide Scopes lost ⌥⌘S on some launches. SwiftUI puts a HIDDEN
//  "Toggle Sidebar" item in the View menu with the same ⌥⌘S; the two items share one key and, depending on which
//  SwiftUI updates last, one of them is left with no key at all. When it was ours, the menu showed no key and ⌥⌘S went
//  to the hidden item, which does nothing in a window with no sidebar. The registry was right; the menu bar was not. So
//  the menu bar itself is audited against the registry: the app snapshots `NSApp.mainMenu` (`ShortcutCenter`), this
//  judges it, and the tests judge synthetic menus, including that collision.
//

import AppKit
import SwiftUI

/// One menu item as the menu bar holds it.
public struct MenuItemSnapshot: Equatable, Sendable {
    /// The top-level menu it is in ("View"), however deep.
    public let menu: String
    public let title: String
    /// `NSMenuItem.keyEquivalent`: empty when the item has no key.
    public let keyEquivalent: String
    public let modifiers: NSEvent.ModifierFlags.RawValue
    public let isHidden: Bool

    public init(menu: String, title: String, keyEquivalent: String, modifiers: NSEvent.ModifierFlags, isHidden: Bool = false) {
        self.menu = menu; self.title = title; self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers.intersection(MenuKeyAudit.relevant).rawValue; self.isHidden = isHidden
    }

    /// Every item of a menu bar, submenus included, each tagged with its top-level menu.
    @MainActor
    public static func all(in bar: NSMenu) -> [MenuItemSnapshot] {
        func walk(_ menu: NSMenu, top: String) -> [MenuItemSnapshot] {
            menu.items.flatMap { item -> [MenuItemSnapshot] in
                guard !item.isSeparatorItem else { return [] }
                let me = MenuItemSnapshot(menu: top, title: item.title, keyEquivalent: item.keyEquivalent,
                                          modifiers: item.keyEquivalentModifierMask, isHidden: item.isHidden)
                return [me] + (item.submenu.map { walk($0, top: top) } ?? [])
            }
        }
        return bar.items.flatMap { top in top.submenu.map { walk($0, top: top.title) } ?? [] }
    }
}

public enum MenuKeyProblem: Equatable, Sendable, CustomStringConvertible {
    /// No visible item with the action's title in its menu.
    case missing(ShortcutID, menu: String)
    /// The item is there, without the registry's key (or with another).
    case wrongKey(ShortcutID, found: String)
    /// Another menu item, hidden ones included, holds the same key and modifiers.
    case keyTaken(ShortcutID, by: String)

    public var description: String {
        switch self {
        case .missing(let id, let menu): return "\(id.rawValue): not in the \(menu) menu"
        case .wrongKey(let id, let found): return "\(id.rawValue): wrong key in the menu (\(found))"
        case .keyTaken(let id, let by): return "\(id.rawValue): its key is also held by \(by)"
        }
    }
}

public enum MenuKeyAudit {
    /// The modifiers a key equivalent is matched on.
    public static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// The top-level menu each `.menu` action's item lives in. The tests hold it to the catalog: every `.menu` action has
    /// a home, and nothing else does.
    public static let menuHomes: [ShortcutID: String] = [
        .fileOpen: "File", .exportFrame: "File", .disconnectLive: "File", .toggleDeckLink: "File",
        .loop: "View", .raster100: "View", .raster75: "View", .raster50: "View", .raster25: "View", .rasterFit: "View",
        .inspector: "View", .fileName: "View", .alwaysShowControls: "View", .scopesTray: "View",
        .volumeUp: "View", .volumeDown: "View", .mute: "View",
        .displayOS: "Color", .displayReference: "Color", .displayBypass: "Color", .transformChain: "Color",
        .cycleInterpretation: "Color", .resetInterpretation: "Color",
        .exportFrameForSupport: "Help",
        .debugToneTest: "Debug", .debugScrubBench: "Debug",
    ]

    /// The key equivalent and modifiers a menu item carries for `chord`: what `KeyChord.menuShortcut` hands SwiftUI.
    public static func expected(_ chord: KeyChord, layout: KeyLayout = CurrentKeyLayout()) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard let shortcut = chord.menuShortcut(layout: layout) else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.command) }
        if shortcut.modifiers.contains(.option) { flags.insert(.option) }
        if shortcut.modifiers.contains(.control) { flags.insert(.control) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
        return (String(shortcut.key.character), flags)
    }

    /// The problems with `items` for every `.menu` action the registry offers now. Debug actions only when their tier is on,
    /// and then only if their menu is in the bar (the Debug menu is itself opt-in).
    @MainActor
    public static func audit(_ items: [MenuItemSnapshot], registry: ShortcutRegistry,
                             layout: KeyLayout = CurrentKeyLayout()) -> [MenuKeyProblem] {
        var problems: [MenuKeyProblem] = []
        let menus = Set(items.map(\.menu))
        for def in registry.definitions where def.dispatch == .menu {
            if let tier = def.debug, !registry.isDebugEnabled(tier) { continue }
            guard let home = menuHomes[def.id] else { problems.append(.missing(def.id, menu: "(no home)")); continue }
            if def.debug != nil, !menus.contains(home) { continue }
            guard let item = items.first(where: { $0.menu == home && $0.title == def.title && !$0.isHidden }) else {
                problems.append(.missing(def.id, menu: home)); continue
            }
            guard let chord = registry.menuChord(for: def.id), let want = expected(chord, layout: layout) else {
                if !item.keyEquivalent.isEmpty { problems.append(.wrongKey(def.id, found: describe(item))) }
                continue
            }
            if !same(item, want) { problems.append(.wrongKey(def.id, found: describe(item))); continue }
            let holders = items.filter { $0 != item && same($0, want) }
            for other in holders { problems.append(.keyTaken(def.id, by: "\(other.menu) ▸ \(other.title)\(other.isHidden ? " (hidden)" : "")")) }
        }
        return problems
    }

    private static func same(_ item: MenuItemSnapshot, _ want: (key: String, modifiers: NSEvent.ModifierFlags)) -> Bool {
        !item.keyEquivalent.isEmpty && item.keyEquivalent.lowercased() == want.key.lowercased()
            && item.modifiers == want.modifiers.intersection(relevant).rawValue
    }

    private static func describe(_ item: MenuItemSnapshot) -> String {
        item.keyEquivalent.isEmpty ? "no key" : "key \(item.keyEquivalent.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined()) mods \(item.modifiers)"
    }
}
