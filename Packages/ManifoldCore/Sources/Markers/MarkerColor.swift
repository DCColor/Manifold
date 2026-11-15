//
//  MarkerColor.swift — DaVinci Resolve's 16 marker colours, in its order and spelling (docs/MARKERS_PLAN.md §1).
//
//  NAMES AND ORDER: Resolve 21.1's scripting stub, `MarkerColor = Literal['Blue', 'Cyan', …, 'Cream']`
//  (/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/DaVinciResolveScript.pyi:7).
//  Colours travel between apps BY NAME (`ResolveColor<Name>` in an EDL), never by value.
//
//  VALUES: R0 (Robbie, 2026-11-15), read from a screenshot of Resolve's marker dialog swatches, converted from the LG's
//  profile to sRGB. Close, not exact — good enough for a swatch, and nothing exported depends on them.
//

import Foundation

public enum MarkerColor: String, CaseIterable, Codable, Sendable, Identifiable {
    case blue = "Blue", cyan = "Cyan", green = "Green", yellow = "Yellow", red = "Red", pink = "Pink",
         purple = "Purple", fuchsia = "Fuchsia", rose = "Rose", lavender = "Lavender", sky = "Sky", mint = "Mint",
         lemon = "Lemon", sand = "Sand", cocoa = "Cocoa", cream = "Cream"

    public var id: String { rawValue }

    /// Resolve's own name, as its marker dialog and its EDLs spell it.
    public var name: String { rawValue }

    /// Resolve's default for a new marker.
    public static let defaultColor: MarkerColor = .blue

    /// sRGB, 0xRRGGBB (R0, see the header).
    public var hex: UInt32 {
        switch self {
        case .blue: return 0x078AE7
        case .cyan: return 0x08D4D6
        case .green: return 0x02B601
        case .yellow: return 0xF2A701
        case .red: return 0xE42900
        case .pink: return 0xFF4DCF
        case .purple: return 0x9B0FFE
        case .fuchsia: return 0xC7347A
        case .rose: return 0xFFABC1
        case .lavender: return 0xAB9DCF
        case .sky: return 0x9DE6FD
        case .mint: return 0x7DE002
        case .lemon: return 0xE0EC65
        case .sand: return 0xCB9C69
        case .cocoa: return 0x795B4C
        case .cream: return 0xF6EEE5
        }
    }

    /// sRGB components, 0…1.
    public var rgb: (red: Double, green: Double, blue: Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    /// The EDL token: `ResolveColorBlue`.
    public var resolveToken: String { "ResolveColor" + rawValue }

    /// From an EDL token (`ResolveColorBlue`) or a bare name (`Blue`), any case. Nil for anything else.
    public init?(resolveToken token: String) {
        var t = token.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("resolvecolor") { t = String(t.dropFirst("ResolveColor".count)) }
        guard let c = MarkerColor.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(t) == .orderedSame }) else {
            return nil
        }
        self = c
    }
}
