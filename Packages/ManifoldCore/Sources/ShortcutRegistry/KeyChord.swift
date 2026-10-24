//
//  KeyChord.swift — a key and its modifiers, and a key press, as values (docs/SHORTCUTS_AUDIT.md §4.4).
//
//  ── TWO WAYS TO NAME A KEY, AND EVERY BINDING SAYS WHICH ────────────────────────────────────
//
//  `.character` matches what the layout types for the key (`charactersIgnoringModifiers`, lower-cased),
//  so "D" is D on every Latin layout wherever it sits. `.code` matches the physical key, so the
//  arrows, Space and the audio nudge's ⌥[ / ⌥] stay where they are whatever the layout prints on them.
//  Before the registry the app mixed the two without saying so (audit C9).
//

import Foundation

public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option  = KeyModifiers(rawValue: 1 << 1)
    public static let shift   = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    /// ⌘, ⌃ or ⌥. A chord carrying one is a key equivalent; a chord without is a bare (or ⇧) key, which a
    /// text field would otherwise type.
    public static let commandLike: KeyModifiers = [.command, .control, .option]

    /// Apple's order: ⌃ ⌥ ⇧ ⌘.
    public var glyphs: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }

    static let storedNames: [(KeyModifiers, String)] = [(.command, "command"), (.control, "control"),
                                                        (.option, "option"), (.shift, "shift")]
    var storedNames: [String] { Self.storedNames.filter { contains($0.0) }.map(\.1).sorted() }
    init?(storedNames: [String]) {
        var m = KeyModifiers()
        for name in storedNames {
            guard let entry = Self.storedNames.first(where: { $0.1 == name }) else { return nil }
            m.insert(entry.0)
        }
        self = m
    }
}

/// Virtual key codes (Carbon `kVK_*`) the catalog names.
public enum KeyCode {
    public static let space: UInt16 = 49, tab: UInt16 = 48, returnKey: UInt16 = 36, keypadEnter: UInt16 = 76
    public static let escape: UInt16 = 53, delete: UInt16 = 51, forwardDelete: UInt16 = 117
    public static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    public static let home: UInt16 = 115, end: UInt16 = 119, pageUp: UInt16 = 116, pageDown: UInt16 = 121
    /// ANSI positions. On German these keys carry Ü and +; the nudge is the physical key either way.
    public static let leftBracket: UInt16 = 33, rightBracket: UInt16 = 30
    public static let functionKeys: [UInt16: String] = [122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
                                                        97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
                                                        103: "F11", 111: "F12"]
    static let named: [UInt16: String] = [space: "Space", tab: "Tab", returnKey: "Return", keypadEnter: "Enter",
                                          escape: "Esc", delete: "Delete", forwardDelete: "⌦", left: "←",
                                          right: "→", down: "↓", up: "↑", home: "Home", end: "End",
                                          pageUp: "Page Up", pageDown: "Page Down"]
    /// Keys with no character of their own: always matched by code.
    public static func isSpecial(_ code: UInt16) -> Bool { named[code] != nil || functionKeys[code] != nil }
    public static func isArrow(_ code: UInt16) -> Bool { (left...up).contains(code) }
    /// Home, End, Page Up, Page Down and ⌦ are Fn + a key on Apple laptop keyboards
    /// (support.apple.com/en-us/102650, text editing).
    public static func needsFn(_ code: UInt16) -> Bool { [home, end, pageUp, pageDown, forwardDelete].contains(code) }

    /// The ANSI letter on each letter key, for a layout that types a non-Latin letter there (Cyrillic, Greek):
    /// the same fallback macOS gives ⌘ shortcuts on those layouts.
    static let ansiLetters: [UInt16: String] = [0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h",
                                                34: "i", 38: "j", 40: "k", 37: "l", 46: "m", 45: "n", 31: "o",
                                                35: "p", 12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v",
                                                13: "w", 7: "x", 16: "y", 6: "z"]
}

public enum KeyIdentity: Hashable, Sendable {
    /// One character, lower-cased, as `charactersIgnoringModifiers` gives it (with ⇧ applied).
    case character(String)
    case code(UInt16)
}

public struct KeyChord: Hashable, Sendable {
    public var key: KeyIdentity
    public var modifiers: KeyModifiers

    public init(_ key: KeyIdentity, _ modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
    public static func char(_ c: String, _ modifiers: KeyModifiers = []) -> KeyChord {
        KeyChord(.character(c.lowercased()), modifiers)
    }
    public static func code(_ c: UInt16, _ modifiers: KeyModifiers = []) -> KeyChord { KeyChord(.code(c), modifiers) }

    /// No ⌘, ⌃ or ⌥.
    public var isBare: Bool { modifiers.isDisjoint(with: .commandLike) }
    public var isShiftedArrow: Bool { isArrow && modifiers.contains(.shift) }
    public var isArrow: Bool {
        if case .code(let c) = key { return KeyCode.isArrow(c) }
        return false
    }
    /// A key a text field uses: anything without ⌘ or ⌃ (a character, ⌥ included), or an arrow, Home, End, Page Up,
    /// Page Down or Delete with ⌘, ⌥ or ⇧ (moving and deleting by word, line and document).
    public var isTextFieldKey: Bool {
        if modifiers.isDisjoint(with: [.command, .control]) { return true }
        guard !modifiers.contains(.control), case .code(let c) = key else { return false }
        return KeyCode.isArrow(c) || [KeyCode.home, KeyCode.end, KeyCode.pageUp, KeyCode.pageDown, KeyCode.delete,
                                      KeyCode.forwardDelete].contains(c)
    }
    public var needsFn: Bool {
        if case .code(let c) = key { return KeyCode.needsFn(c) }
        return false
    }
}

/// A key press or release, taken from an `NSEvent` (see KeyEvent+AppKit.swift) or built by a test.
public struct KeyEvent: Equatable, Sendable {
    public enum Phase: Sendable { case down, up }
    public var phase: Phase
    public var keyCode: UInt16
    /// `charactersIgnoringModifiers`: ⇧ is applied, ⌃ and ⌥ are not.
    public var characters: String
    public var modifiers: KeyModifiers
    public var isRepeat: Bool

    public init(_ phase: Phase, keyCode: UInt16, characters: String, modifiers: KeyModifiers = [],
                isRepeat: Bool = false) {
        self.phase = phase
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }

    /// The character a `.character` binding compares against.
    public var character: String? {
        guard characters.count == 1 else { return nil }
        let c = characters.lowercased()
        if let scalar = c.unicodeScalars.first, !scalar.isASCII, scalar.properties.isAlphabetic,
           let ansi = KeyCode.ansiLetters[keyCode] {
            return ansi
        }
        return c
    }

    /// Exact modifiers: ⌘D is not D, and ⇧D is not D.
    public func matches(_ chord: KeyChord) -> Bool {
        guard modifiers == chord.modifiers else { return false }
        switch chord.key {
        case .code(let c): return keyCode == c
        case .character(let s): return !KeyCode.isSpecial(keyCode) && character == s
        }
    }

    /// The chord a recorder takes from this press: special keys by code, a typed character by character, anything
    /// else (a dead key, no character) by code.
    public var recordedChord: KeyChord {
        if KeyCode.isSpecial(keyCode) { return .code(keyCode, modifiers) }
        if let c = character, let scalar = c.unicodeScalars.first, !scalar.properties.isWhitespace,
           scalar.value >= 0x20 {
            return .char(c, modifiers)
        }
        return .code(keyCode, modifiers)
    }
}
