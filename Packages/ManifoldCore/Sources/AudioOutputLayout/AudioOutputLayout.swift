import CoreAudioTypes
import Foundation

/// The channel layout the file audio reader asks AVFoundation for, and the check a source's own layout has to pass
/// before it is trusted (docs/BUGS.md, "a malformed channel layout silences a 1- or 2-channel file").
///
/// ⚠️ WHY THE OUTPUT ALWAYS STATES A LAYOUT. With no `AVChannelLayoutKey`, AVFoundation derives the output layout from
/// the SOURCE's, and a malformed source layout then fails `startReading` with -11800 / paramErr -50. Two measured
/// shapes, one family:
///   * the ARRI ALEXA Mini case (August): layout tag 0xFFFF0000, Unknown with a channel count of ZERO, on a
///     5-channel track;
///   * `TCMOP_NSS_Oriental_MKE_REF.mov` (2026-10-21): the Stereo tag with zero descriptions in a 52-byte layout,
///     40 trailing bytes past what the tag needs. The count agrees; only the size is wrong.
/// ANY explicit output layout reads both, so there is no configuration left that asks AVFoundation to derive one.
///
/// A leaf target, CoreAudioTypes only, for the same linking reason as the others: `swift test` cannot link ManifoldCore.
public enum AudioOutputLayout {

    /// What the source's own layout turned out to be.
    public enum SourceVerdict: Equatable, Sendable {
        /// No layout on the track at all.
        case none
        /// Well-formed: its size is exactly what its descriptions need, and it describes the track's channel count.
        case valid
        /// Longer than its descriptions need. The first `used` bytes are a well-formed layout of the right count, and
        /// that is what is trusted; the rest is not part of the layout.
        case oversized(size: Int, used: Int)
        /// Shorter than its own description count needs. Not trusted.
        case truncated(size: Int, needed: Int)
        /// The Unknown family (high 16 bits 0xFFFF): it claims nothing about speaker roles. Not trusted.
        case unknownTag(UInt32)
        /// Well-formed, but it describes a different number of channels than the track carries. Not trusted.
        case countMismatch(layoutChannels: Int)

        /// The layout bytes may be used (trimmed to `used` when oversized).
        public var isTrusted: Bool {
            switch self {
            case .valid, .oversized: return true
            default: return false
            }
        }
    }

    public struct Decision: Equatable, Sendable {
        /// The `AVChannelLayoutKey` value: an `AudioChannelLayout`, exactly as long as its descriptions need.
        public let layout: Data
        public let source: SourceVerdict
        /// Plain words for the log when the source's layout was not used as it stands. nil when nothing needs saying.
        public let note: String?
    }

    /// Bytes before `mChannelDescriptions`: tag, bitmap, count (3 × UInt32).
    public static let headerSize = 12
    /// One `AudioChannelDescription`: label, flags, three Float32 coordinates.
    public static let descriptionSize = 20

    /// The layout to ask for, for a track of `channels` channels whose own layout is `source` (`size` bytes; nil when
    /// the track has none). Never nil: there is always a layout.
    ///
    /// * The source's own layout when it passes `validate`, at EVERY channel count — trimmed to its declared size when
    ///   the box is longer. That is the layout AVFoundation would have derived anyway, so a well-formed file decodes
    ///   byte for byte as it did before.
    /// * Otherwise (none, truncated, Unknown, wrong count): Mono for 1 channel, Stereo for 2, DiscreteInOrder above
    ///   that — count and order kept, nothing claimed about roles, the honest answer when the file itself does not say.
    ///
    /// ⚠️ NOT "ALWAYS MONO OR STEREO FOR 1 OR 2 CHANNELS", which was the first plan, AND THE REASON IS MEASURED. The
    /// output layout is not a label: AVFoundation MAPS the source's channels onto it by role. Against a 2-channel
    /// track tagged DiscreteInOrder, a Stereo output decodes to SILENCE on both channels; against Center + LFE it
    /// copies the centre to both and drops the LFE; against a 1-channel track labelled Left the samples change.
    /// Asking for the source's own layout reproduced HEAD's output exactly on all of them (2026-10-21, the fixtures in
    /// docs/BUGS.md's entry). Mono and Stereo are only ever the fallback for a layout that cannot be trusted.
    ///
    /// `channels` must be > 0; the caller has already refused a track that reports none.
    public static func decide(source: UnsafeRawPointer?, size: Int, channels: Int) -> Decision {
        let verdict = source.map { validate($0, size: size, channels: channels) } ?? .none
        if verdict.isTrusted, let source {
            let used: Int
            if case .oversized(_, let u) = verdict { used = u } else { used = size }
            return Decision(layout: Data(bytes: source, count: used), source: verdict,
                            note: note(for: verdict, using: "the layout its tag declares"))
        }
        let fallback: (tag: AudioChannelLayoutTag, name: String)
        switch channels {
        case 1:  fallback = (kAudioChannelLayoutTag_Mono, "Mono")
        case 2:  fallback = (kAudioChannelLayoutTag_Stereo, "Stereo")
        default: fallback = (kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels), "DiscreteInOrder for its \(channels) channels")
        }
        return Decision(layout: tagOnly(fallback.tag), source: verdict, note: note(for: verdict, using: fallback.name))
    }

    /// Check a source layout against its own size and against the track's channel count.
    public static func validate(_ layout: UnsafeRawPointer, size: Int, channels: Int) -> SourceVerdict {
        guard size >= headerSize else { return .truncated(size: size, needed: headerSize) }
        let tag = layout.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        let bitmap = layout.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let count = Int(layout.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
        // A count no file could carry is a damaged header, and the multiplication below must not overflow.
        guard count <= 4096 else { return .truncated(size: size, needed: Int.max) }
        let needed = headerSize + count * descriptionSize
        if size < needed { return .truncated(size: size, needed: needed) }
        if tag >> 16 == 0xFFFF { return .unknownTag(tag) }
        let described: Int
        switch tag {
        case kAudioChannelLayoutTag_UseChannelDescriptions: described = count
        case kAudioChannelLayoutTag_UseChannelBitmap:       described = bitmap.nonzeroBitCount
        default:                                            described = Int(tag & 0xFFFF)
        }
        if described != channels { return .countMismatch(layoutChannels: described) }
        return size == needed ? .valid : .oversized(size: size, used: needed)
    }

    private static func tagOnly(_ tag: AudioChannelLayoutTag) -> Data {
        var bytes = Data(count: headerSize)
        bytes.withUnsafeMutableBytes { $0.storeBytes(of: tag, toByteOffset: 0, as: UInt32.self) }
        return bytes
    }

    private static func note(for verdict: SourceVerdict, using what: String) -> String? {
        switch verdict {
        case .none, .valid:
            return nil
        case .oversized(let size, let used):
            return "the channel layout is \(size) bytes, \(size - used) more than its descriptions need — using \(what)"
        case .truncated(let size, let needed):
            return "the channel layout is \(size) bytes, short of the \(needed) its descriptions need — using \(what)"
        case .unknownTag(let tag):
            return "the channel layout is unknown (tag 0x\(String(tag, radix: 16))) — using \(what)"
        case .countMismatch(let n):
            return "the channel layout describes \(n) channels — using \(what)"
        }
    }
}
