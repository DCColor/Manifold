//
//  KeyLayout.swift — what the current keyboard layout types on a key, for labels and for comparing a `.code`
//  binding with a `.character` one (docs/SHORTCUTS_AUDIT.md §2.2: key code 42 types # on German, ç on Spanish).
//

import Foundation
import Carbon.HIToolbox

public protocol KeyLayout {
    /// The character the key types, with or without ⇧, or nil for a dead key or a key with none.
    func character(for keyCode: UInt16, shift: Bool) -> String?
}

/// The layout selected now, through `UCKeyTranslate`. Read on each call: the user can switch input source at any
/// time, and a label should follow.
public struct CurrentKeyLayout: KeyLayout {
    public init() {}

    public func character(for keyCode: UInt16, shift: Bool) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let modifierState: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), modifierState, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        guard let scalar = s.unicodeScalars.first, scalar.value >= 0x20, !scalar.properties.isWhitespace else { return nil }
        return s
    }
}

/// US ANSI, for tests and as the comparison layout when the current one cannot be read.
public struct USKeyLayout: KeyLayout {
    public init() {}
    static let plain: [UInt16: String] = [18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8",
                                          25: "9", 29: "0", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";",
                                          39: "'", 43: ",", 47: ".", 44: "/", 50: "`"]
    static let shifted: [UInt16: String] = [18: "!", 19: "@", 20: "#", 21: "$", 23: "%", 22: "^", 26: "&", 28: "*",
                                            25: "(", 29: ")", 27: "_", 24: "+", 33: "{", 30: "}", 42: "|", 41: ":",
                                            39: "\"", 43: "<", 47: ">", 44: "?", 50: "~"]
    public func character(for keyCode: UInt16, shift: Bool) -> String? {
        if let letter = KeyCode.ansiLetters[keyCode] { return shift ? letter.uppercased() : letter }
        return (shift ? Self.shifted : Self.plain)[keyCode]
    }
}

public enum KeyLabel {
    /// "⌥⌘E", "D", "⇧←", "⌥]" — the key as this layout prints it.
    public static func label(_ chord: KeyChord, layout: KeyLayout = CurrentKeyLayout()) -> String {
        chord.modifiers.glyphs + keyName(chord, layout: layout)
    }

    public static func keyName(_ chord: KeyChord, layout: KeyLayout = CurrentKeyLayout()) -> String {
        switch chord.key {
        case .character(let c):
            switch c {
            case " ": return "Space"
            default: return c.uppercased()
            }
        case .code(let code):
            if let name = KeyCode.named[code] ?? KeyCode.functionKeys[code] { return name }
            if let c = layout.character(for: code, shift: false) { return c.uppercased() }
            return "Key \(code)"
        }
    }
}
