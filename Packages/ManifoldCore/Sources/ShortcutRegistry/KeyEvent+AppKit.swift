//
//  KeyEvent+AppKit.swift — the one place an `NSEvent` becomes a `KeyEvent`, and a chord becomes a SwiftUI menu key.
//

import AppKit
import SwiftUI

public extension KeyEvent {
    /// Key-down and key-up only. Caps Lock, Fn and the numeric-pad flag are dropped: a binding names ⌘ ⌃ ⌥ ⇧.
    init?(_ event: NSEvent) {
        let phase: Phase
        switch event.type {
        case .keyDown: phase = .down
        case .keyUp: phase = .up
        default: return nil
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods = KeyModifiers()
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        self.init(phase, keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "",
                  modifiers: mods, isRepeat: phase == .down && event.isARepeat)
    }
}

public extension KeyChord {
    /// The SwiftUI shortcut for a menu item, or nil when the chord cannot be one (see `ShortcutRegistry.menuChord`).
    func menuShortcut(layout: KeyLayout = CurrentKeyLayout()) -> KeyboardShortcut? {
        guard !isBare else { return nil }
        let key: KeyEquivalent
        switch self.key {
        case .character(let c):
            guard let ch = c.first else { return nil }
            key = KeyEquivalent(ch)
        case .code(let code):
            switch code {
            case KeyCode.space: key = .space
            case KeyCode.tab: key = .tab
            case KeyCode.returnKey, KeyCode.keypadEnter: key = .return
            case KeyCode.escape: key = .escape
            case KeyCode.delete: key = .delete
            case KeyCode.forwardDelete: key = .deleteForward
            case KeyCode.left: key = .leftArrow
            case KeyCode.right: key = .rightArrow
            case KeyCode.up: key = .upArrow
            case KeyCode.down: key = .downArrow
            case KeyCode.home: key = .home
            case KeyCode.end: key = .end
            case KeyCode.pageUp: key = .pageUp
            case KeyCode.pageDown: key = .pageDown
            default:
                guard let c = layout.character(for: code, shift: false)?.first else { return nil }
                key = KeyEquivalent(c)
            }
        }
        var m = EventModifiers()
        if modifiers.contains(.command) { m.insert(.command) }
        if modifiers.contains(.control) { m.insert(.control) }
        if modifiers.contains(.option) { m.insert(.option) }
        if modifiers.contains(.shift) { m.insert(.shift) }
        return KeyboardShortcut(key, modifiers: m)
    }
}
