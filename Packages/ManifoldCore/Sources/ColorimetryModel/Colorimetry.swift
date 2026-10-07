//
//  Colorimetry.swift
//  ColorimetryModel
//
//  A live source's colorimetry as the app reasons about it: three CICP axes, where each one came
//  from, the user's override presets, and the one place an override meets a declaration
//  (`SourceColorimetry.resolve`). Transport-neutral: NDI, SRT, WHEP and HLS all speak it, and
//  the renderer's provenance vocabulary (`SourceColorProvenance`) lives here too so the readout's
//  tier and this type cannot drift apart. docs/COLOR_MANAGEMENT_FINDINGS.md §6.9, Stage A.
//
//  Moved out of App/NDI/NDIColorInfo.swift and App/MetalVideoRenderer.swift so `swift test` can
//  reach it — before this the override and the tiers were verified by measurement only (§6.9
//  finding 9). What stays in the app is what needs CoreVideo or a transport's own vocabulary: NDI's
//  `<ndi_color_info/>` parse, the buffer tagging, and the log wording
//  (App/Live/SourceColorimetry+App.swift).
//

/// Where one colorimetry axis's value came from.
///
/// The same three-state honesty the audio layout (`LayoutConfidence`) and the HDR10 mastering
/// block (`HDR10Presence`) already keep: a DEFAULT is not a FACT. A source's colour signalling is
/// OPTIONAL — NDI's `p_metadata` may be NULL, may carry no color element, or may name a value we
/// don't recognize — and in every one of those cases we still have to tag the buffer with SOMETHING
/// or the display is wrong. So we tag the sensible default AND record that we made it up.
public enum ColorAxisProvenance: Equatable, Sendable {
    /// The source declared it, in the source's own vocabulary.
    case declared
    /// Nothing was declared for this axis (absent metadata, absent attribute, or a word we don't
    /// know) — the value below is Manifold's default, not the source's statement.
    case assumed
    /// The USER asserted it, overriding whatever the stream said or didn't say. The third tier the
    /// range model already has (Auto / Full / Legal): an assertion is not a reading, and it outranks
    /// both — including a declaration, because senders mis-declare too.
    case overridden
}

/// One axis of the signal: the CICP code the pipeline consumes, where it came from, and — when
/// declared — the source's raw word, kept verbatim so the (later) inspector can show what the
/// sender ACTUALLY said rather than our re-spelling of it.
public struct ColorimetryAxis: Equatable, Sendable {
    public let code: Int
    public let provenance: ColorAxisProvenance
    /// The source's word (e.g. "bt_2100_pq"), or nil when assumed.
    public let declared: String?

    public init(code: Int, provenance: ColorAxisProvenance, declared: String?) {
        self.code = code; self.provenance = provenance; self.declared = declared
    }

    public static func declaredValue(_ code: Int, _ raw: String) -> ColorimetryAxis {
        ColorimetryAxis(code: code, provenance: .declared, declared: raw)
    }
    public static func assumed(_ code: Int) -> ColorimetryAxis {
        ColorimetryAxis(code: code, provenance: .assumed, declared: nil)
    }
    public static func overridden(_ code: Int) -> ColorimetryAxis {
        ColorimetryAxis(code: code, provenance: .overridden, declared: nil)
    }

    public var isDeclared: Bool { provenance == .declared }
}

/// Where the source colour codes the renderer is using CAME FROM — §6's three-tier honesty model,
/// carried NEXT TO the codes rather than inferred from them.
///
/// ⚠️ **INFERRING IT FROM THE CODES IS WRONG FOR HALF THE SOURCES, AND WAS A SHIPPED DEFECT.**
/// §6.8's Phase 2c part 1 measured it: NDI and WHEP **resolve before they publish**, so the
/// renderer receives non-nil codes for an assumption and for a user override alike, and a
/// nil-test calls both "tagged". An assumed 709 stream read `CICP 1/1 — tagged` and a user
/// assertion read `CICP 9/16 — tagged`, which is the one thing the readout exists to prevent.
///
/// Only a source whose UNDECLARED AXES ARRIVE AS nil can be read from the codes — a file (absent
/// CICP is absent), SRT (`codeIfDeclared` passes nil through), HLS-from-buffer. That is what
/// `fromCodes` is for, and why it names the condition instead of being the default.
public enum SourceColorProvenance: Equatable, Sendable {
    /// The source declared it.
    case tagged
    /// Nobody declared it; these are Manifold's defaults.
    case assumed
    /// Some axes declared, some not.
    case partlyAssumed
    /// The user asserted it, over whatever the source said or didn't.
    case overridden

    /// ⚠️ **ONLY FOR A SOURCE WHOSE UNDECLARED AXES ARRIVE AS `nil`.** See the type's note.
    public static func fromCodes(primaries: Int?, transfer: Int?, matrix: Int?) -> SourceColorProvenance {
        switch [primaries, transfer, matrix].filter({ $0 != nil }).count {
        case 0:  return .assumed
        case 3:  return .tagged
        default: return .partlyAssumed
        }
    }

    /// The one word the chain readout prints.
    public var label: String {
        switch self {
        case .tagged:        return "tagged"
        case .assumed:       return "assumed"
        case .partlyAssumed: return "partly assumed"
        case .overridden:    return "overridden"
        }
    }
}

/// The live transports, as far as colorimetry is concerned. The app's `LiveSource` is not visible
/// from a package; this names the same four so preset availability can be stated as data here.
public enum ColorimetryTransport: CaseIterable, Sendable {
    case ndi, srt, whep, hls
}

/// A user assertion of a live stream's colorimetry — the colour twin of `RangeOverride`, and
/// deliberately the same shape: resolved against what the stream said, and labelled as an
/// assertion everywhere it shows. On NDI it is transient per connection (reset to `.auto` on every
/// connect); SRT, WHEP and HLS will hold it per window and save it per bookmark (§6.9, decisions 1–2).
///
/// WHY IT EXISTS: most senders declare nothing. OmniScope — measured, 299 frames — sends no
/// `ndi_color_info` at all, on any channel. The parse then correctly falls back to assumed-709, and
/// a PQ feed from such a sender is displayed and scoped as SDR 709 because that is genuinely all
/// anyone said about it. Someone has to be able to say "no, this is a 2020/PQ feed", and that
/// someone is the user in front of the picture.
///
/// PRESETS, NOT AXES. Users think in feeds ("it's an HLG stream"), not in three orthogonal CICP
/// codes, and a preset cannot produce the incoherent triples free axis pickers invite. The axes are
/// still set INDEPENDENTLY and correctly by each preset — note P3-D65 PQ, which carries a
/// 709-class matrix, not a P3 one.
///
/// EXTENSION POINT: an `.custom(SourceColorimetry)` case (independent axis pickers) is the obvious
/// next step and is deliberately NOT built. It slots in without touching any caller: `preset` is
/// the only thing that maps a case to a triple, and `SourceColorimetry.resolve` is the only thing
/// that consumes it. Pickers already iterate `available(on:)` rather than `allCases`, which is what
/// a payload case would have required anyway.
public enum ColorimetryOverride: CaseIterable, Identifiable, Hashable, Sendable {
    /// Trust the stream: declared if it declared, assumed-709 if it didn't. The default.
    case auto
    case rec709
    case rec2020PQ
    case rec2020HLG
    case p3d65PQ
    case rec2020SDR

    public var id: String { storageID ?? "auto" }

    /// The (primaries, transfer, matrix) CICP triple this preset asserts — nil for `.auto`, which
    /// asserts nothing. Each axis is stated explicitly: no axis is ever derived from another.
    public var preset: (primaries: Int, transfer: Int, matrix: Int)? {
        switch self {
        case .auto:       return nil
        case .rec709:     return (1, 1, 1)      // 709 primaries · 709 transfer · 709 matrix
        case .rec2020PQ:  return (9, 16, 9)     // HDR10: 2020 · PQ (ST 2084) · 2020
        case .rec2020HLG: return (9, 18, 9)     // 2020 · HLG · 2020
        case .p3d65PQ:    return (12, 16, 1)    // P3-D65 primaries · PQ · 709-CLASS MATRIX (not P3)
        case .rec2020SDR: return (9, 14, 9)     // 2020 · 2020 SDR transfer (the 709 curve) · 2020
        }
    }

    public var label: String {
        switch self {
        case .auto:       return "Auto"
        case .rec709:     return "Rec.709 (SDR)"
        case .rec2020PQ:  return "Rec.2020 PQ (HDR10)"
        case .rec2020HLG: return "Rec.2020 HLG"
        case .p3d65PQ:    return "P3-D65 PQ"
        case .rec2020SDR: return "Rec.2020 SDR"
        }
    }

    /// Toolbar-width label — the picker button face, not the menu rows.
    public var shortLabel: String {
        switch self {
        case .auto:       return "Auto"
        case .rec709:     return "709"
        case .rec2020PQ:  return "2020 PQ"
        case .rec2020HLG: return "2020 HLG"
        case .p3d65PQ:    return "P3 PQ"
        case .rec2020SDR: return "2020 SDR"
        }
    }

    // MARK: - Persistence (Stage D)

    /// The string a saved stream stores. **nil for `.auto`, which is stored as ABSENT** — the
    /// `audioOffsetMs` rule: an untouched bookmark round-trips byte-for-byte. These spellings are a
    /// storage format: never rename one. A new preset gets a new string.
    public var storageID: String? {
        switch self {
        case .auto:       return nil
        case .rec709:     return "rec709"
        case .rec2020PQ:  return "rec2020-pq"
        case .rec2020HLG: return "rec2020-hlg"
        case .p3d65PQ:    return "p3d65-pq"
        case .rec2020SDR: return "rec2020-sdr"
        }
    }

    /// The preset a stored string names. Absent, empty or unknown → `.auto`, never a throw: a
    /// bookmark written by a later build (a preset this build does not have) must still load, and
    /// the honest reading of a word we don't know is "assert nothing".
    public init(storageID: String?) {
        self = Self.allCases.first { $0.storageID != nil && $0.storageID == storageID } ?? .auto
    }

    // MARK: - Availability

    /// The presets a transport offers, in picker and ⌃⌥C order.
    ///
    /// Rec.2020 SDR is NDI-only until §7.3 is fixed (decision 3): `makeColorSpace` has no arm for
    /// (9,14), so the layer is tagged 709 primaries and the preset does not do what it says. NDI
    /// keeps it because it already shipped it; the other three do not gain a known-broken preset.
    /// When §7.3 is fixed, every transport returns `allCases`.
    public static func available(on transport: ColorimetryTransport) -> [ColorimetryOverride] {
        switch transport {
        case .ndi:              return allCases
        case .srt, .whep, .hls: return allCases.filter { $0 != .rec2020SDR }
        }
    }
}

/// A source's colour signalling — THREE INDEPENDENT AXES.
///
/// Independent is the load-bearing word. Primaries, transfer and matrix are tagged separately and
/// they do not have to agree: 2020-primaries content can legitimately carry a 709-class matrix,
/// and each axis can be declared while the others are silent. Nothing here infers one axis from
/// another; each is parsed, mapped and defaulted on its own.
///
/// Was `NDIColorInfo`. SRT and WHEP already used it for buffer tagging, which is why it has a
/// transport-neutral name now. Where it comes from is the transport's business (NDI's parse lives
/// in App/NDI); where it goes — the CoreVideo attachments — is an app extension.
public struct SourceColorimetry: Equatable, Sendable {
    public let primaries: ColorimetryAxis
    public let transfer: ColorimetryAxis
    public let matrix: ColorimetryAxis

    public init(primaries: ColorimetryAxis, transfer: ColorimetryAxis, matrix: ColorimetryAxis) {
        self.primaries = primaries; self.transfer = transfer; self.matrix = matrix
    }

    /// The default a source gets when it declares nothing: HD-ish SDR Rec.709, all three axes
    /// ASSUMED. Tagging it is what keeps an untagged source displaying correctly; marking it
    /// assumed is what keeps us from presenting that default as the sender's word.
    public static let assumedRec709 = SourceColorimetry(primaries: .assumed(1),
                                                        transfer: .assumed(1),
                                                        matrix: .assumed(1))

    /// True when the source declared at least one axis.
    public var isDeclared: Bool { primaries.isDeclared || transfer.isDeclared || matrix.isDeclared }

    /// True when this is a user assertion rather than anything the stream said.
    public var isOverridden: Bool { primaries.provenance == .overridden }

    /// The one word the Color control's face prints: which of the three tiers this colorimetry came
    /// from. A partly-declared source reads "Declared" here (any axis declared) — the chain readout's
    /// `sourceProvenance` is the finer answer.
    public var tier: String {
        if isOverridden { return "Overridden" }
        return isDeclared ? "Declared" : "Assumed"
    }

    /// The same fact in the renderer's vocabulary, so the chain readout and this type cannot
    /// drift apart. `isDeclared` is true when ANY axis was declared, so a partly-declared sender
    /// resolves to `.partlyAssumed` rather than claiming the whole triple was stated.
    public var sourceProvenance: SourceColorProvenance {
        if isOverridden { return .overridden }
        let declared = [primaries, transfer, matrix].filter(\.isDeclared).count
        switch declared {
        case 0:  return .assumed
        case 3:  return .tagged
        default: return .partlyAssumed
        }
    }

    /// The three-layer resolution, and the ONLY place an override meets a declaration:
    ///   1. `.auto` → whatever the stream gave us (declared, or the assumed-709 default).
    ///   2. a preset → the user's triple, over the assumed default AND over a declaration.
    ///
    /// The user winning over a DECLARED tag is deliberate, and is what `RangeOverride` already
    /// does: senders mis-declare, and a viewer looking at the picture is better placed to know than
    /// a string in an XML blob. It is honest because it is LABELLED — the result reads "Overridden",
    /// never "Declared".
    public static func resolve(declared: SourceColorimetry, override: ColorimetryOverride) -> SourceColorimetry {
        guard let p = override.preset else { return declared }
        return SourceColorimetry(primaries: .overridden(p.primaries),
                                 transfer: .overridden(p.transfer),
                                 matrix: .overridden(p.matrix))
    }
}
