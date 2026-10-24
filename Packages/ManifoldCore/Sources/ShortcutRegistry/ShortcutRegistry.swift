//
//  ShortcutRegistry.swift — the one source of truth for Manifold's shortcuts (docs/SHORTCUTS_AUDIT.md §4.4).
//
//  Defaults live in `ShortcutCatalog`; the user's changes live in `ShortcutStore`; this joins them, answers "what
//  key does this action have" for the menus and the dispatcher, and judges a proposed key for the Keyboard
//  Shortcuts window: refused (reserved by macOS, or unusable), in conflict, or accepted with warnings.
//
//  ── WHY THE CHECKS ARE HERE AND NOT IN A COMMENT ─────────────────────────────────────────────
//
//  Before the registry, "is this key free?" was a hand-written list in a doc comment (RasterSize.swift, audit C6),
//  and it was out of date within weeks. The same checks now run on every proposed key, and on the defaults in
//  `ShortcutRegistryTests`.
//
//  ⚠️ ⇧ + AN ARROW CANNOT BE A MENU KEY (audit C7). MEASURED on the built app before this file existed: AppKit's
//  key-equivalent matcher does not tell ⇧← from ←, so of two key equivalents differing only by ⇧ on an arrow, one
//  wins for both presses. The dispatcher reads exact modifier flags and has no such problem, so ⇧-arrows are
//  `.key` actions, and `propose` refuses an arrow on a `.menu` action unless it carries ⌘, ⌃ or ⌥.
//
//  ── A MENU ITEM SHOWS ITS KEY, BARE OR NOT (2026-10-24, §8 item 5) ─────────────────────────
//
//  Every menu action's key is its menu item's key equivalent, N included, so the menu always says what the key is.
//  A bare key equivalent would take that letter from a text field, so while a text field is being typed into the
//  dispatcher hands such a key straight to the field (`KeyDispatcher.textFieldTakes`): typing N in a bookmark name
//  types "n", as it did when N had no menu key.
//

import Foundation
import Combine

@MainActor
public final class ShortcutRegistry: ObservableObject {
    public let definitions: [ShortcutDefinition]
    /// Bumped on every change: menus and the window observe it.
    @Published public private(set) var revision = 0
    /// While the window records a key, the dispatcher takes nothing.
    @Published public var isRecording = false

    private var overrides: [ShortcutID: KeyChord?]
    private let store: ShortcutStore
    private let debugTierEnabled: (DebugTier) -> Bool
    private let layout: KeyLayout

    public init(definitions: [ShortcutDefinition] = ShortcutCatalog.all, store: ShortcutStore = ShortcutStore(),
                layout: KeyLayout = CurrentKeyLayout(), debugTierEnabled: @escaping (DebugTier) -> Bool) {
        self.definitions = definitions
        self.store = store
        self.layout = layout
        self.debugTierEnabled = debugTierEnabled
        // Only rebindable rows take an override: a stored key for a debug or fixed row is ignored (and kept).
        self.overrides = store.overrides().filter { ShortcutCatalog.byID[$0.key]?.rebindable == true }
    }

    public func definition(_ id: ShortcutID) -> ShortcutDefinition {
        definitions.first { $0.id == id } ?? ShortcutCatalog.byID[id]!
    }

    public func isDebugEnabled(_ tier: DebugTier) -> Bool { debugTierEnabled(tier) }

    /// The key an action has now: the user's, else the default.
    public func chord(for id: ShortcutID) -> KeyChord? {
        if let override = overrides[id] { return override }
        return definition(id).defaultChord
    }

    public func isCustomised(_ id: ShortcutID) -> Bool { overrides[id] != nil }

    public func label(for id: ShortcutID) -> String? {
        let def = definition(id)
        if let fixed = def.fixedLabel { return fixed }
        guard let chord = chord(for: id) else { return nil }
        return label(chord, holdFor: def)
    }

    public func label(_ chord: KeyChord, holdFor def: ShortcutDefinition? = nil) -> String {
        KeyLabel.label(chord, layout: layout) + (def?.dispatch == .hold ? " (hold)" : "")
    }

    /// Labels for tooltips: "Pin controls (⌥⌘T)", or the bare text when the action has no key.
    public func helpText(_ text: String, _ id: ShortcutID) -> String {
        guard let l = label(for: id) else { return text }
        return "\(text) (\(l))"
    }

    // MARK: Dispatch

    /// The actions the key dispatcher matches against, in catalog order: `.key` and `.hold` actions, and `.menu`
    /// actions whose key cannot be a menu key equivalent (bare or ⇧ only). Debug actions only when their tier is on.
    public func dispatcherBindings() -> [(ShortcutDefinition, KeyChord)] {
        definitions.flatMap { def -> [(ShortcutDefinition, KeyChord)] in
            guard def.dispatch != .fixed else { return [] }
            if let tier = def.debug, !debugTierEnabled(tier) { return [] }
            let chord = chord(for: def.id)
            switch def.dispatch {
            // A `.key` row's fixed chords are aliases it always answers to (⌃⌘F for full screen).
            case .key, .hold: return (chord.map { [$0] } ?? []).map { (def, $0) } + def.fixedChords.map { (def, $0) }
            case .menu: return chord.flatMap { $0.isBare ? [(def, $0)] : nil } ?? []
            case .fixed: return []
            }
        }
    }

    /// The key a menu item carries: its binding, whatever it is (§8 item 5), or nil when it has none. A bare key is
    /// shown too; the dispatcher performs it outside text fields and hands it to a field being typed into.
    public func menuChord(for id: ShortcutID) -> KeyChord? {
        guard definition(id).dispatch == .menu else { return nil }
        return chord(for: id)
    }

    /// A menu item's key that a text field also uses (a typed character, or an arrow or Delete with ⌘ ⌥ ⇧) and that
    /// `event` is. While a field is being typed into, the field gets it, not the menu.
    public func menuKeyATextFieldUses(_ event: KeyEvent) -> Bool {
        definitions.contains { def in
            guard def.dispatch == .menu, let chord = chord(for: def.id), chord.isTextFieldKey else { return false }
            if let tier = def.debug, !debugTierEnabled(tier) { return false }
            return event.matches(chord)
        }
    }

    // MARK: Judging a key

    public enum Verdict: Equatable {
        /// The action keeps the key it has.
        case unchanged
        case accepted(warnings: [String])
        /// The key is in use by these actions in a scope that overlaps. Replace unbinds them.
        case conflict(with: [ShortcutID], warnings: [String])
        case refused(String)
    }

    public func propose(_ chord: KeyChord?, for id: ShortcutID) -> Verdict {
        let def = definition(id)
        guard def.rebindable else { return .refused("This shortcut cannot be changed.") }
        guard let chord else { return self.chord(for: id) == nil ? .unchanged : .accepted(warnings: []) }
        if chord == self.chord(for: id) { return .unchanged }
        if let reason = Self.reserved[normalized(chord)] ?? Self.reserved[chord] {
            return .refused("\(label(chord)) is used by macOS (\(reason)).")
        }
        if def.dispatch == .menu, chord.isArrow, chord.isBare {
            return .refused("A menu shortcut cannot tell ⇧ + an arrow from the arrow alone. Add ⌘, ⌃ or ⌥.")
        }
        if def.dispatch == .hold, chord.modifiers.contains(.command) {
            return .refused("macOS does not report releasing a ⌘ key, so a ⌘ shortcut cannot be held.")
        }
        let clashes = conflicts(for: chord, scope: def.scope, excluding: id)
        let fixed = clashes.filter { !definition($0).rebindable }
        if let first = fixed.first {
            return .refused("\(label(chord)) is used by “\(definition(first).title)”, which cannot be changed.")
        }
        let w = warnings(for: chord, on: def)
        return clashes.isEmpty ? .accepted(warnings: w) : .conflict(with: clashes, warnings: w)
    }

    /// Every other action holding `chord` in a scope that overlaps `scope`. Debug actions count only when their tier
    /// is on: a key a Release build never answers is not taken there.
    public func conflicts(for chord: KeyChord, scope: ShortcutScope, excluding id: ShortcutID? = nil) -> [ShortcutID] {
        let wanted = normalized(chord)
        return definitions.compactMap { other in
            guard other.id != id, other.scope.overlaps(scope) else { return nil }
            if let tier = other.debug, !debugTierEnabled(tier) { return nil }
            let held = (self.chord(for: other.id).map { [$0] } ?? []) + other.fixedChords
            return held.contains { normalized($0) == wanted } ? other.id : nil
        }
    }

    public func warnings(for chord: KeyChord, on def: ShortcutDefinition) -> [String] {
        var w: [String] = []
        if chord.modifiers.isSuperset(of: [.control, .option]) {
            w.append("⌃⌥ is VoiceOver’s modifier, and window managers such as Rectangle take ⌃⌥ with letters and arrows.")
        }
        if chord.needsFn {
            w.append("On a laptop keyboard this key is Fn with an arrow (or ⌫).")
        }
        if chord.isBare, def.dispatch != .hold {
            w.append("While you type in a text field this key types there instead.")
        }
        if case .code(KeyCode.tab) = chord.key, chord.isBare {
            w.append("Tab moves between controls when Keyboard navigation is on.")
        }
        switch chord.key {
        case .character(let c):
            if let s = c.unicodeScalars.first, !s.properties.isAlphabetic, !CharacterSet.decimalDigits.contains(s) {
                w.append("“\(c)” is on a different key, or needs ⇧ or ⌥, on some keyboard layouts.")
            }
        case .code(let code):
            if !KeyCode.isSpecial(code) {
                w.append("This is a physical key: other keyboard layouts print a different character on it.")
            }
        }
        return w
    }

    // MARK: Changing keys

    /// Give `id` the key (nil = no key). With `replacing`, every conflicting action loses the key. Returns false when
    /// the verdict refuses it, or when it conflicts and `replacing` is false, or when the store refuses to write.
    @discardableResult
    public func assign(_ chord: KeyChord?, to id: ShortcutID, replacing: Bool = false) -> Bool {
        var changes: [ShortcutID: Change] = [:]
        switch propose(chord, for: id) {
        case .unchanged: return true
        case .refused: return false
        case .accepted: break
        case .conflict(let others, _):
            guard replacing else { return false }
            for other in others { changes[other] = .set(nil) }
        }
        changes[id] = .set(chord)
        return commit(changes)
    }

    @discardableResult
    public func reset(_ id: ShortcutID) -> Bool { commit([id: .reset]) }

    @discardableResult
    public func reset(category: ShortcutCategory) -> Bool {
        commit(Dictionary(uniqueKeysWithValues: definitions.filter { $0.category == category && overrides[$0.id] != nil }
            .map { ($0.id, Change.reset) }))
    }

    @discardableResult
    public func resetAll() -> Bool { commit(Dictionary(uniqueKeysWithValues: overrides.keys.map { ($0, Change.reset) })) }

    public var hasOverrides: Bool { !overrides.isEmpty }
    public func hasOverrides(in category: ShortcutCategory) -> Bool {
        definitions.contains { $0.category == category && overrides[$0.id] != nil }
    }

    private enum Change { case reset, set(KeyChord?) }

    /// A `.set` equal to the default is stored as no override, so it reads as not customised.
    @discardableResult
    private func commit(_ changes: [ShortcutID: Change]) -> Bool {
        guard !changes.isEmpty else { return true }
        var stored: [ShortcutID: KeyChord??] = [:]
        for (id, change) in changes {
            switch change {
            // `updateValue`, not the subscript: assigning a nil through the subscript would REMOVE the entry, and
            // `.none` here is the instruction "remove the override", which has to reach the store.
            case .reset:
                stored.updateValue(.none, forKey: id)
            case .set(let chord):
                stored.updateValue(chord == definition(id).defaultChord ? .none : .some(chord), forKey: id)
            }
        }
        guard store.apply(stored) else { return false }
        for (id, value) in stored {
            if let value { overrides.updateValue(value, forKey: id) } else { overrides.removeValue(forKey: id) }
        }
        revision += 1
        return true
    }

    // MARK: Layout

    /// A `.code` chord compared as the character it types on this layout, so ⌥[ by code and ⌥[ by character are
    /// one key. Special keys stay codes.
    func normalized(_ chord: KeyChord) -> KeyChord {
        guard case .code(let code) = chord.key, !KeyCode.isSpecial(code),
              let c = layout.character(for: code, shift: chord.modifiers.contains(.shift)) else { return chord }
        return .char(c, chord.modifiers)
    }

    // MARK: Reserved

    /// Keys macOS owns. MEASURED on this app's menu bar (2026-10-23, HEAD `9e7c9fc`, Accessibility read of every
    /// item's key equivalent) for the menu items; the system-wide ones from support.apple.com/en-us/102650.
    public static let reserved: [KeyChord: String] = {
        let cmd: KeyModifiers = [.command], oc: KeyModifiers = [.option, .command], sc: KeyModifiers = [.shift, .command]
        let osc: KeyModifiers = [.option, .shift, .command]
        let r: [KeyChord: String] = [
            .char("q", cmd): "Quit", .char("q", oc): "Quit and Keep Windows", .char("h", cmd): "Hide",
            .char("h", oc): "Hide Others", .char(",", cmd): "Settings", .char("n", cmd): "New Window",
            .char("w", cmd): "Close", .char("w", oc): "Close All", .char("m", cmd): "Minimize",
            .char("m", oc): "Minimize All", .char("z", cmd): "Undo", .char("z", sc): "Redo", .char("x", cmd): "Cut",
            .char("c", cmd): "Copy", .char("v", cmd): "Paste", .char("a", cmd): "Select All",
            .char("d", oc): "Show or Hide the Dock", .code(KeyCode.space, oc): "Finder search window",
            .char("\\", sc): "Show All Tabs", .char("|", sc): "Show All Tabs", .char("f", [.control, .command]): "Enter Full Screen",
            .code(KeyCode.space, cmd): "Spotlight", .code(KeyCode.space, [.control]): "previous input source",
            .code(KeyCode.space, [.control, .option]): "next input source",
            .code(KeyCode.space, [.control, .command]): "Emoji & Symbols",
            .code(KeyCode.up, [.control]): "Mission Control", .code(KeyCode.down, [.control]): "App windows",
            .code(KeyCode.left, [.control]): "move to the Space on the left",
            .code(KeyCode.right, [.control]): "move to the Space on the right",
            .code(KeyCode.tab, cmd): "switch apps", .code(KeyCode.tab, sc): "switch apps",
            .code(KeyCode.tab, [.control]): "Show Next Tab", .code(KeyCode.tab, [.control, .shift]): "Show Previous Tab",
            .char("`", cmd): "next window", .char("3", sc): "screenshot", .char("4", sc): "screenshot",
            .char("5", sc): "screenshot", .char("#", sc): "screenshot", .char("$", sc): "screenshot",
            .char("%", sc): "screenshot", .char("/", sc): "Help", .char("?", sc): "Help",
            .code(KeyCode.escape, oc): "Force Quit", .code(KeyCode.escape, osc): "Force Quit",
            .char("q", [.control, .command]): "Lock Screen", .char("q", sc): "Log Out", .char("q", osc): "Log Out",
            .char(".", cmd): "Cancel",
        ]
        return r
    }()
}
