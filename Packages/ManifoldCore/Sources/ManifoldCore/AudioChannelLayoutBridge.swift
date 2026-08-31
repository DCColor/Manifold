import Foundation
import CoreMedia
import AudioToolbox

/// STAGE 3: the missing half of the multichannel path — FFmpeg's channel MASK ⟷ CoreAudio's
/// channel LAYOUT, and one shared vocabulary for turning either into per-channel role names.
///
/// ── WHY THIS IS A TABLE AND NOT AN ARITHMETIC IDENTITY ────────────────────────────────────────
///
/// For the first eighteen positions FFmpeg's `AV_CH_*` bits and CoreAudio's `kAudioChannelBit_*`
/// are the SAME bits in the SAME order — both are the WAVE `dwChannelMask` — and Apple's
/// `AudioChannelLabel` for position *n* happens to be *n + 1*. So `mask` could be cast across and
/// the labels computed with a `+ 1`, in about four lines.
///
/// ⚠️ THAT IS THE SHORTCUT `SRTFrameRouter.declaredChannelMask` REFUSED TO TAKE, in exactly those
/// words: "the two bitmaps agree for the common layouts and 'mostly agree' is exactly the kind of
/// assumption this codebase has paid for before". They stop agreeing above bit 17 — FFmpeg's
/// `AV_CHAN_WIDE_LEFT`, `AV_CHAN_SURROUND_DIRECT_LEFT`, `AV_CHAN_LOW_FREQUENCY_2`,
/// `AV_CHAN_TOP_SIDE_LEFT`, `AV_CHAN_SIDE_SURROUND_LEFT` and the ambisonic range have no WAVE bit
/// at all — and an arithmetic bridge would keep producing confident answers there. The table below
/// covers the eighteen positions where the correspondence is a definition rather than a
/// coincidence, and REFUSES everything else. A 5.1 or 7.1 feed is entirely inside the table; an
/// Atmos bed is not, and gets numbers.
///
/// ── THE ROLE NAMES ARE KEYED ON THE RAW LABEL, NEVER ON THE DISPLAY STRING ───────────────────
///
/// ⚠️ "Lss" READS AS "left SIDE surround" AND IT IS APPLE'S **REAR** SURROUND
/// (`kAudioChannelLabel_RearSurroundLeft`, 33). Apple's *side* pair is
/// `kAudioChannelLabel_LeftSurroundDirect` (10), which this file names "Lsd", and Apple's
/// `LeftSurround` (5) is WAVE's **back** left. Every lookup here therefore keys on the numeric
/// `AudioChannelLabel`; nothing in this file matches on a name. Three of those four names would
/// mislead a reader who matched on the string, and two of them appear in 7.1.
public enum AudioChannelLayoutBridge {

    // MARK: - The correspondence table

    /// One WAVE speaker position, in all three spellings this app has to move between.
    ///
    /// `ffmpegBit` is the bit index in `AVChannelLayout.u.mask` (i.e. the `AVChannel` enumerator).
    /// `appleBit` is the `AudioChannelBitmap` member. `label` is the `AudioChannelLabel` used in an
    /// `AudioChannelDescription`. All three are written out; none is computed from another.
    public struct Position: Sendable {
        public let ffmpegBit: Int
        public let appleBit: AudioChannelBitmap
        public let label: AudioChannelLabel
    }

    /// The eighteen positions WAVE defines, in ascending bit order — which is also FFmpeg's
    /// native channel ORDER and CoreAudio's bitmap order, so an array built by walking this table
    /// is already in interleave order for both.
    public static let positions: [Position] = [
        Position(ffmpegBit:  0, appleBit: .bit_Left,                 label: kAudioChannelLabel_Left),
        Position(ffmpegBit:  1, appleBit: .bit_Right,                label: kAudioChannelLabel_Right),
        Position(ffmpegBit:  2, appleBit: .bit_Center,               label: kAudioChannelLabel_Center),
        Position(ffmpegBit:  3, appleBit: .bit_LFEScreen,            label: kAudioChannelLabel_LFEScreen),
        // AV_CHAN_BACK_LEFT / WAVE BACK_LEFT. Apple calls it LeftSurround — see the header's own
        // "WAVE: 0x10" annotation. This is the pair a 5.1 mix calls Ls.
        Position(ffmpegBit:  4, appleBit: .bit_LeftSurround,         label: kAudioChannelLabel_LeftSurround),
        Position(ffmpegBit:  5, appleBit: .bit_RightSurround,        label: kAudioChannelLabel_RightSurround),
        Position(ffmpegBit:  6, appleBit: .bit_LeftCenter,           label: kAudioChannelLabel_LeftCenter),
        Position(ffmpegBit:  7, appleBit: .bit_RightCenter,          label: kAudioChannelLabel_RightCenter),
        Position(ffmpegBit:  8, appleBit: .bit_CenterSurround,       label: kAudioChannelLabel_CenterSurround),
        // AV_CHAN_SIDE_LEFT / WAVE SIDE_LEFT. Apple's *Direct* surround, named "Lsd" — NOT "Lss",
        // which is the REAR pair (label 33) and is not reachable from a WAVE bitmap at all.
        Position(ffmpegBit:  9, appleBit: .bit_LeftSurroundDirect,   label: kAudioChannelLabel_LeftSurroundDirect),
        Position(ffmpegBit: 10, appleBit: .bit_RightSurroundDirect,  label: kAudioChannelLabel_RightSurroundDirect),
        Position(ffmpegBit: 11, appleBit: .bit_TopCenterSurround,    label: kAudioChannelLabel_TopCenterSurround),
        Position(ffmpegBit: 12, appleBit: .bit_VerticalHeightLeft,   label: kAudioChannelLabel_VerticalHeightLeft),
        Position(ffmpegBit: 13, appleBit: .bit_VerticalHeightCenter, label: kAudioChannelLabel_VerticalHeightCenter),
        Position(ffmpegBit: 14, appleBit: .bit_VerticalHeightRight,  label: kAudioChannelLabel_VerticalHeightRight),
        Position(ffmpegBit: 15, appleBit: .bit_TopBackLeft,          label: kAudioChannelLabel_TopBackLeft),
        Position(ffmpegBit: 16, appleBit: .bit_TopBackCenter,        label: kAudioChannelLabel_TopBackCenter),
        Position(ffmpegBit: 17, appleBit: .bit_TopBackRight,         label: kAudioChannelLabel_TopBackRight),
    ]

    // MARK: - FFmpeg mask → CoreAudio

    /// The reason a mask was refused. Carried rather than collapsed to nil so the log can say
    /// WHICH kind of "no layout" this is — the difference between "the mux declared nothing" and
    /// "the mux declared something this bridge will not translate" is the difference between a
    /// non-event and a thing to go and look at.
    public enum MaskRefusal: Error, Equatable, Sendable {
        case notNativeOrder(order: Int32)
        case noMask
        /// A set bit above 17, or one with no WAVE position. `bit` is the lowest offender.
        case positionOutsideWAVE(bit: Int)
        /// The mask's population count disagrees with the stream's channel count.
        case countMismatch(maskChannels: Int, declaredChannels: Int)

        public var reason: String {
            switch self {
            case .notNativeOrder(let o):
                return "channel order \(o) is not AV_CHANNEL_ORDER_NATIVE, so `u.mask` is a "
                     + "different union member and means nothing as a layout"
            case .noMask:
                return "the mux declared no channel mask"
            case .positionOutsideWAVE(let b):
                return "AVChannel bit \(b) has no WAVE/CoreAudio position — this bridge covers "
                     + "the 18 WAVE positions and refuses the rest rather than approximating"
            case .countMismatch(let m, let d):
                return "the mask names \(m) position(s) but the stream declares \(d) channel(s)"
            }
        }
    }

    /// FFmpeg's `AVChannelLayout` (NATIVE order + mask) → CoreAudio labels in interleave order.
    ///
    /// `channelOrder` is the raw `AVChannelOrder`; `AV_CHANNEL_ORDER_NATIVE` is 1. Anything else
    /// is refused, because `u.mask` is only the mask member for a native-order layout — the same
    /// reasoning `fillAudioFormat` applies when it zeroes the mask for other orders.
    public static func labels(fromFFmpegMask mask: UInt64, channelOrder: Int32,
                              channelCount: Int) -> Result<[AudioChannelLabel], MaskRefusal> {
        guard channelOrder == avChannelOrderNative else { return .failure(MaskRefusal.notNativeOrder(order: channelOrder)) }
        guard mask != 0 else { return .failure(MaskRefusal.noMask) }

        var labels: [AudioChannelLabel] = []
        labels.reserveCapacity(channelCount)
        var remaining = mask
        var bit = 0
        while remaining != 0 {
            if remaining & 1 != 0 {
                guard let p = positions.first(where: { $0.ffmpegBit == bit }) else {
                    return .failure(MaskRefusal.positionOutsideWAVE(bit: bit))
                }
                labels.append(p.label)
            }
            remaining >>= 1
            bit += 1
        }
        guard labels.count == channelCount else {
            return .failure(MaskRefusal.countMismatch(maskChannels: labels.count, declaredChannels: channelCount))
        }
        return .success(labels)
    }

    /// `AV_CHANNEL_ORDER_NATIVE`. Spelled out because the FFmpeg headers are not visible from the
    /// package — the App target passes the raw value straight through from `AVCodecParameters`.
    public static let avChannelOrderNative: Int32 = 1

    // MARK: - Labels → an AudioChannelLayout blob

    /// The BITMAP spelling: `kAudioChannelLayoutTag_UseChannelBitmap` + the OR of the positions.
    /// This is the form AudioConverter is most likely to accept as an output layout. Returns nil
    /// if any label has no bitmap position (which the mask bridge above cannot produce, but a
    /// caller supplying labels from elsewhere can).
    public static func bitmapLayoutData(for labels: [AudioChannelLabel]) -> Data? {
        var bitmap = AudioChannelBitmap()
        for label in labels {
            guard let p = positions.first(where: { $0.label == label }) else { return nil }
            bitmap.insert(p.appleBit)
        }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap
        layout.mChannelBitmap = bitmap
        layout.mNumberChannelDescriptions = 0
        // A bitmap layout needs only the fixed header; the flexible array is empty.
        return withUnsafeBytes(of: &layout) { Data($0.prefix(headerSize)) }
    }

    /// The DESCRIPTIONS spelling: `kAudioChannelLayoutTag_UseChannelDescriptions` plus one
    /// `AudioChannelDescription` per channel, in order.
    ///
    /// ⚠️ THIS IS THE FORM ATTACHED TO THE CMFormatDescription, ON PURPOSE. It is the only one
    /// that states a per-channel role POSITIONALLY, and `roles(from:)` reads it back with no
    /// table lookup and no tag interpretation — the label that went in is the label that comes
    /// out. A bitmap would survive the round trip only through an ordering convention, and a tag
    /// only through a name table; both are extra places to be wrong about a 5.1 mix.
    public static func descriptionsLayoutData(for labels: [AudioChannelLabel]) -> Data {
        var data = Data(count: headerSize + labels.count * MemoryLayout<AudioChannelDescription>.stride)
        data.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            base.storeBytes(of: kAudioChannelLayoutTag_UseChannelDescriptions,
                            toByteOffset: 0, as: AudioChannelLayoutTag.self)
            base.storeBytes(of: UInt32(0), toByteOffset: 4, as: UInt32.self)
            base.storeBytes(of: UInt32(labels.count), toByteOffset: 8, as: UInt32.self)
            for (i, label) in labels.enumerated() {
                var desc = AudioChannelDescription()
                desc.mChannelLabel = label
                desc.mChannelFlags = AudioChannelFlags()
                withUnsafeBytes(of: &desc) { src in
                    base.advanced(by: headerSize + i * MemoryLayout<AudioChannelDescription>.stride)
                        .copyMemory(from: src.baseAddress!, byteCount: src.count)
                }
            }
        }
        return data
    }

    /// `offsetof(AudioChannelLayout, mChannelDescriptions)` — 12, computed from the struct rather
    /// than written down, the same way `MediaInspector` computes it when reading one back.
    public static var headerSize: Int { MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)! }

    // MARK: - An AudioChannelLayout → labels → role names

    /// Read any of the three AudioChannelLayout spellings back to ordered labels.
    ///
    /// Descriptions are read positionally. A BITMAP or a TAG is expanded by **CoreAudio itself**
    /// (`kAudioFormatProperty_ChannelLayoutFor…`) rather than by a table here: Apple owns the
    /// meaning of its own tags, and asking is the difference between reporting a declaration and
    /// re-deriving one. `nil` means the layout said nothing this can use.
    public static func labels(fromLayout raw: UnsafeRawPointer, size: Int) -> [AudioChannelLabel]? {
        labels(fromLayout: raw, size: size, allowExpansion: true)
    }

    private static func labels(fromLayout raw: UnsafeRawPointer, size: Int,
                               allowExpansion: Bool) -> [AudioChannelLabel]? {
        guard size >= headerSize else { return nil }
        let tag = raw.loadUnaligned(fromByteOffset: 0, as: AudioChannelLayoutTag.self)
        let bitmap = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)

        // ⚠️ DESCRIPTIONS FIRST, AND *NOT* GATED ON THE TAG — WHICH IS WHERE THIS RECURSED
        // FOREVER. `kAudioFormatProperty_ChannelLayoutForTag` fills in the descriptions but LEAVES
        // THE ORIGINAL TAG IN PLACE (measured: asking it to expand `MPEG_5_1_A` returns a 132-byte
        // layout still tagged `MPEG_5_1_A`, with `mNumberChannelDescriptions = 6` and the six
        // descriptions after it). A reader that dispatched on the tag alone therefore handed that
        // result straight back to the expander and blew the stack. Present descriptions are the
        // most specific statement a layout can make; read them whenever they are there.
        if let labels = descriptions(fromLayout: raw, size: size) { return labels }
        guard allowExpansion else { return nil }
        if tag == kAudioChannelLayoutTag_UseChannelBitmap {
            return expand(kAudioFormatProperty_ChannelLayoutForBitmap, bitmap)
        }
        guard tag != kAudioChannelLayoutTag_UseChannelDescriptions else { return nil }
        return expand(kAudioFormatProperty_ChannelLayoutForTag, tag)
    }

    /// The `mChannelDescriptions` flexible array, if this layout actually carries one.
    private static func descriptions(fromLayout raw: UnsafeRawPointer, size: Int) -> [AudioChannelLabel]? {
        let count = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
        let stride = MemoryLayout<AudioChannelDescription>.stride
        guard count > 0, size >= headerSize + count * stride else { return nil }
        return (0..<count).map {
            raw.advanced(by: headerSize + $0 * stride)
               .loadUnaligned(as: AudioChannelDescription.self).mChannelLabel
        }
    }

    /// Ask CoreAudio to turn a tag or a bitmap into a descriptions layout, then read the labels
    /// out of it. Returns nil when CoreAudio declines — which is the honest answer for a tag it
    /// has no positional expansion for.
    private static func expand(_ property: AudioFormatPropertyID, _ input: UInt32) -> [AudioChannelLabel]? {
        var value = input
        let inSize = UInt32(MemoryLayout<UInt32>.size)
        var outSize: UInt32 = 0
        guard AudioFormatGetPropertyInfo(property, inSize, &value, &outSize) == noErr,
              outSize >= UInt32(headerSize) else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(outSize))
        var size = outSize
        let status = bytes.withUnsafeMutableBytes { out in
            AudioFormatGetProperty(property, inSize, &value, &size, out.baseAddress!)
        }
        guard status == noErr else { return nil }
        return bytes.withUnsafeBytes { out in
            // `allowExpansion: false` — one level only, belt-and-braces on top of the
            // descriptions-first rule above.
            labels(fromLayout: out.baseAddress!, size: Int(size), allowExpansion: false)
        }
    }

    /// Short role names in channel order for a format description's AudioChannelLayout, or nil
    /// when it carries none. THE single reader — `MediaInspector` (files) and `AudioTapBuffer`
    /// (every path, including live) both come through here, so a file and a stream describing the
    /// same 5.1 mix cannot print different names for it.
    public static func roles(from fmt: CMFormatDescription) -> [String]? {
        var size = 0
        guard let raw = CMAudioFormatDescriptionGetChannelLayout(fmt, sizeOut: &size),
              let labels = labels(fromLayout: UnsafeRawPointer(raw), size: size),
              !labels.isEmpty else { return nil }
        return roleNames(for: labels)
    }

    /// ⚠️ THE SET-AWARE NAMER. **Every site holding a full ordered label set calls this**, never
    /// `roleName(for:)` in a `map`. The rule below cannot be decided one label at a time — it turns
    /// on whether the layout has ONE surround pair or TWO — so a caller that maps the single-label
    /// namer over an array silently opts out of it, and then a file and a stream describing the
    /// same 5.1 print different names. That is the exact failure this type's header says it exists
    /// to prevent, which is why all four call sites were converted together.
    ///
    /// ── THE RULE ──────────────────────────────────────────────────────────────────────────────
    ///
    ///   * A layout with ONE surround pair names it **Ls/Rs** — whether the source declared SIDE
    ///     (Apple 10/11) or BACK (Apple 5/6).
    ///   * A layout with BOTH names the side pair **Ls/Rs** and the rear pair **Lss/Rss**.
    ///   * **`Lsd`/`Rsd` never reach a user-facing surface.**
    ///
    /// ── WHY, AND THE PRECEDENT ────────────────────────────────────────────────────────────────
    ///
    /// **Flip already made this decision, and this matches it deliberately.** Flip's `ROLE_LABELS`
    /// is a TRANSLATION LAYER, not a mirror of Apple's header: its entry for Apple label 33 is
    /// commented Apple `"Rls"` and displayed as `Lss`. Apple's vocabulary in, industry vocabulary
    /// out. This function is Manifold's copy of that seam.
    ///
    /// **Flip keeps one exception — `Lsd`/`Rsd` read-only — and it does not transfer.** Flip WRITES
    /// files, so normalising 10/11 to 5/6 there would make its encoder write 5/6 back on the next
    /// save, silently converting a side-declared file to back surrounds. **Manifold has no writing
    /// path at all** — verified across every Swift/ObjC/C file: no `AVAssetWriter`, no
    /// `AVAssetExportSession`, no `avformat_write_header`. Nothing this names can be saved, so the
    /// reason for the exception is absent and the general rule applies.
    ///
    /// **And the distinction does not belong on a meter.** SMPTE delivery layouts have exactly ONE
    /// surround pair at 5.1; surround-direct is not a delivery channel. A colourist reading a bar
    /// row wants to know which speaker a bar is, and at 5.1 there is only one candidate — so
    /// printing `Lsd` there states a distinction the layout does not contain, in the one place
    /// someone uses to decide which channel is which.
    ///
    /// ── ⚠️ DISPLAY ONLY. THE NUMERIC VOCABULARY IS UNTOUCHED, ON PURPOSE ──────────────────────
    ///
    /// This function renames; it does not remap. `positions` still maps `AV_CHAN_SIDE_LEFT` to
    /// `kAudioChannelLabel_LeftSurroundDirect` and must keep doing so, because
    /// `bitmapLayoutData(for:)` feeds `kAudioConverterOutputChannelLayout`
    /// (`SRTAudioDecoder.swift`, the request beside `AudioConverterSetProperty`). Changing which
    /// Apple label a side channel maps to would change **the physical channel order AudioToolbox is
    /// asked to emit** — moving audio in order to change a word. The labels going in are exactly
    /// the labels the file declared; only the strings coming out change.
    ///
    /// ⚠️ **THE HONESTY RULE IS UNCHANGED AND MUST STAY THAT WAY.** This decides what a DECLARED
    /// channel is CALLED. It never gives a name to something undeclared: `Discrete_0…n`, unmapped
    /// labels (`?(n)`) and `Unused` (`—`) pass through exactly as `roleName(for:)` renders them,
    /// `isUsable` still refuses an all-unnamed set, and an undeclared layout still meters as
    /// NUMBERS. Nothing here infers a role from a count or a position.
    public static func roleNames(for labels: [AudioChannelLabel]) -> [String] {
        let hasSide = labels.contains(kAudioChannelLabel_LeftSurroundDirect)
                   || labels.contains(kAudioChannelLabel_RightSurroundDirect)
        let hasBack = labels.contains(kAudioChannelLabel_LeftSurround)
                   || labels.contains(kAudioChannelLabel_RightSurround)
        let hasRear = labels.contains(kAudioChannelLabel_RearSurroundLeft)
                   || labels.contains(kAudioChannelLabel_RearSurroundRight)

        // Nothing to resolve unless the SIDE pair is present: with side absent, the existing
        // single-label names are already the rule's answer (5/6 → Ls/Rs as the lone pair, 33/34 →
        // Lss/Rss as the rear pair), which is why an AVFoundation 5.1 and an SRT 5.1 are unaffected.
        //
        // ⚠️ THREE SURROUND PAIRS AT ONCE IS OUT OF SCOPE AND SAYS SO. Apple has three (5/6, 10/11,
        // 33/34); a layout declaring all three has more surround pairs than "one pair or two" can
        // assign without two of them colliding on Lss/Rss. That is beyond the delivery layouts this
        // rule serves, so it keeps the raw Apple vocabulary — three distinct names — rather than
        // forcing an industry one. Exotic and honest beats tidy and wrong.
        guard hasSide, !(hasBack && hasRear) else { return labels.map(roleName(for:)) }

        return labels.map { label in
            switch label {
            // The side pair IS the delivery surround pair — what a 5.1 or 7.1 mix calls Ls/Rs.
            case kAudioChannelLabel_LeftSurroundDirect:  return "Ls"
            case kAudioChannelLabel_RightSurroundDirect: return "Rs"
            // Reached ONLY when both pairs are present (WAVE 7.1: BL BR SL SR). Apple's
            // `LeftSurround` is WAVE's BACK left — see `positions` — so in a two-pair layout it is
            // the REAR pair and takes the rear pair's name. With side absent this branch is not
            // entered at all and 5/6 keeps Ls/Rs.
            case kAudioChannelLabel_LeftSurround:  return "Lss"
            case kAudioChannelLabel_RightSurround: return "Rss"
            default: return roleName(for: label)
            }
        }
    }

    /// Apple `AudioChannelLabel` → short role name (Flip vocabulary, normalized).
    ///
    /// ⚠️ **SINGLE-LABEL, AND THEREFORE SET-BLIND.** It cannot apply the one-pair/two-pair rule,
    /// so it renders the SIDE pair as `Lsd`/`Rsd`. Correct for a caller that genuinely has one
    /// label and no set context; **wrong for anything holding a whole layout** — that calls
    /// `roleNames(for:)`. Do not reintroduce `labels.map(roleName(for:))`.
    ///
    /// ⚠️ KEYED ON THE NUMBER, AND THE NAMES ARE NOT SELF-EXPLANATORY. `LeftSurround` (5) is
    /// WAVE's BACK left and prints "Ls"; `LeftSurroundDirect` (10) is the SIDE pair and prints
    /// "Lsd"; `RearSurroundLeft` (33) is REAR and prints "Lss" — which reads as "side" and is not.
    public static func roleName(for label: AudioChannelLabel) -> String {
        switch label {
        case kAudioChannelLabel_Left: return "L"
        case kAudioChannelLabel_Right: return "R"
        case kAudioChannelLabel_Center: return "C"
        case kAudioChannelLabel_LFEScreen: return "LFE"
        case kAudioChannelLabel_LeftSurround: return "Ls"
        case kAudioChannelLabel_RightSurround: return "Rs"
        case kAudioChannelLabel_CenterSurround: return "Cs"
        case kAudioChannelLabel_LeftSurroundDirect: return "Lsd"
        case kAudioChannelLabel_RightSurroundDirect: return "Rsd"
        case kAudioChannelLabel_RearSurroundLeft: return "Lss"   // Apple Rls -> Flip Lss
        case kAudioChannelLabel_RearSurroundRight: return "Rss"  // Apple Rrs -> Flip Rss
        case kAudioChannelLabel_LeftCenter: return "Lc"
        case kAudioChannelLabel_RightCenter: return "Rc"
        case kAudioChannelLabel_Mono: return "Mono"
        case kAudioChannelLabel_Unused: return "—"
        default: return "?(\(label))"   // unmapped label — show raw value
        }
    }

    /// True when `roles` says something a listener could act on. An array that is entirely
    /// `?(…)`/`—` is a declaration in form only, and publishing it would put unreadable text where
    /// a channel NUMBER belongs.
    public static func isUsable(_ roles: [String]) -> Bool {
        roles.contains { !$0.hasPrefix("?(") && $0 != "—" }
    }
}
