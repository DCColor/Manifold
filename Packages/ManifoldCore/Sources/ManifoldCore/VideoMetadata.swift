import Foundation
import CoreMedia

public struct ChapterMarker: Equatable, Sendable {
    public var time: Double
    public var title: String
}

/// Whether an audio track's layout name came from a real declaration, a marked
/// inference from channel count, or is an honest unknown.
public enum LayoutConfidence: Equatable, Sendable {
    case declared      // from real channel descriptions / known tag
    case inferred      // guessed from channel count, no declaration
    case undeclared    // no declaration and no confident guess
}

/// A source's DECLARED pixel aspect ratio — THREE STATES, NOT TWO, and the third is the point.
///
/// ⚠️ `pasp 1:1` IS A DECLARATION, NOT AN ABSENCE. A file that carries a `pasp` atom saying square
/// pixels has STATED that its pixels are square; a file with no `pasp` atom has stated nothing and
/// is being assumed square by us. Those are different facts and an instrument must not print the
/// same thing for both — the same three-state honesty `LayoutConfidence` applies to audio layouts
/// and `colorRange` applies to the range flag ("Untagged" is not "Video (Legal)").
///
/// MEASURED, so the distinction is real and not merely principled: AVFoundation reports
/// `kCMFormatDescriptionExtension_PixelAspectRatio` as ABSENT when the atom is absent, and as
/// `{HorizontalSpacing 1, VerticalSpacing 1}` when the atom declares square. Verified 2026-09-07 by
/// stripping the atom from a ProRes file (renaming it to `free`, size-preserving) and re-reading:
/// the extension went from present-and-1:1 to absent, with `naturalSize` unchanged throughout.
public enum DeclaredPixelAspect: Equatable, Sendable {
    /// No `pasp` atom. We assume square pixels; the file did not say so.
    case undeclared
    /// A `pasp` atom, INCLUDING one that says 1:1.
    case declared(horizontal: Int, vertical: Int)

    /// h/v as a number, or nil when nothing was declared. Never defaults to 1.0 — a caller that
    /// wants "assume square" must say so itself, which is what keeps the assumption visible.
    public var ratio: Double? {
        guard case .declared(let h, let v) = self, v > 0 else { return nil }
        return Double(h) / Double(v)
    }

    /// Declared AND not square — i.e. this file needs a desqueeze. Undeclared is FALSE, because an
    /// undeclared file gets the square assumption and no transform.
    public var isAnamorphic: Bool {
        guard case .declared(let h, let v) = self else { return false }
        return h != v
    }

    /// Three visibly different strings, because the three states are three different facts.
    public var displayString: String {
        switch self {
        case .undeclared: return "Not declared"
        case .declared(let h, let v):
            return h == v ? "\(h):\(v) (square, declared)" : "\(h):\(v)"
        }
    }
}

/// A source's DECLARED clean aperture — the `clap` atom, or its absence.
///
/// Two states rather than three: unlike `pasp`, a `clap` equal to the encoded raster is not a
/// meaningfully different statement from no `clap` at all, because both mean "nothing is being
/// cropped". `MediaInspector` reports the atom when it is present; the inspector shows the row only
/// when it actually differs from the encoded size, which is the point at which it says something.
public enum DeclaredCleanAperture: Equatable, Sendable {
    case undeclared
    case declared(width: Double, height: Double, hOffset: Double, vOffset: Double)

    public var size: CGSize? {
        guard case .declared(let w, let h, _, _) = self else { return nil }
        return CGSize(width: w, height: h)
    }

    public var displayString: String {
        guard case .declared(let w, let h, _, _) = self else { return "Not declared" }
        return "\(Int(w.rounded())) × \(Int(h.rounded()))"
    }
}

/// What the DECODE PATH established about a source's audio, as distinct from what an inspector
/// guessed. The three cases are deliberately not two: "no audio" and "not determined yet" look
/// identical to a viewer if they are collapsed, and a meter has to say which it is.
public enum AudioPresence: Equatable, Sendable {
    /// Nothing loaded, or the decoder has not reached the audio stream yet. Say so; do not
    /// render silence, which reads as "this file is quiet".
    case unknown
    /// The demuxer opened the source and there is NO audio stream. Positive evidence.
    case absent
    /// An audio stream is present, with this many channels. The count is the DECODER's, so it is
    /// correct on the libav path too, where `AudioTrackInfo` is unavailable entirely.
    case present(channels: Int)

    public var channelCount: Int? {
        if case .present(let n) = self { return n }
        return nil
    }
}

public struct AudioTrackInfo: Equatable, Sendable {
    public var codecName: String = "—"
    public var channelCount: Int = 0
    public var layoutName: String = "—"
    public var layoutConfidence: LayoutConfidence = .undeclared

    /// Short role name per channel, in channel order — `["L","R","C","LFE","Ls","Rs"]`. EMPTY when
    /// the file declares no per-channel roles, which is the honest answer for a track carrying only
    /// a channel count.
    ///
    /// ⚠️ THIS IS A DIFFERENT QUESTION FROM `layoutConfidence`, AND CONFLATING THEM LOSES
    /// INFORMATION. `layoutConfidence` says whether we could put a NAME to the whole layout;
    /// `roles` says whether the FILE declared what each channel is. A track can declare every
    /// channel per-channel and still land on `.inferred` because its role sequence matches no entry
    /// in the layout-name table (an unusual order, or a channel count the table has no name for) —
    /// the roles there are still fully declared and per-channel accurate. Anything wanting to label
    /// individual channels must read THIS, not the confidence.
    public var roles: [String] = []
    public var sampleRate: Double = 0      // Hz
    public var bitDepth: Int = 0
    public var dataRate: Double = 0         // bits/sec (estimated)

    /// The libav `AVStream` index this row describes, or nil on the AVFoundation path.
    ///
    /// ⚠️ IT IS NOT THE ROW'S POSITION IN `audioTracks`, AND THAT IS THE ENTIRE REASON IT EXISTS.
    /// An MXF's video stream is #0, so its four audio streams are #1–#4 while their rows are 0–3;
    /// any file that interleaves audio with anything else makes the two disagree. `av_read_frame`,
    /// `av_seek_frame` and `avcodec_parameters_to_context` all speak the STREAM index, so the
    /// audio-stream switch binds with this number, not with the array position —
    /// `FrameEngine.selectLibavAudioStream` does that translation, reading the number from
    /// `libavAudioInfo` (which is where THIS field is filled from) so the UI keeps passing a
    /// position.
    ///
    /// NIL ON THE AVFOUNDATION PATH, deliberately. There the row's position IS the index into the
    /// engine's `AVAssetTrack` list, which is what `selectAudioTrack` already takes — inventing a
    /// number for it would create a second identifier for a track that already has one.
    public var sourceStreamIndex: Int?

    public var sampleRateString: String {
        sampleRate > 0 ? String(format: "%.1f kHz", sampleRate / 1000) : "—"
    }
    public var bitDepthString: String {
        bitDepth > 0 ? "\(bitDepth)-bit" : "—"
    }
    public var dataRateString: String {
        dataRate > 0 ? String(format: "%.0f kb/s", dataRate / 1000) : "—"
    }
    /// Compact summary, e.g. "Stereo · 48.0 kHz · 24-bit"
    public var summary: String {
        var parts: [String] = []
        if layoutName != "—" { parts.append(layoutName) }
        else if channelCount > 0 { parts.append("\(channelCount) ch") }
        if sampleRate > 0 { parts.append(sampleRateString) }
        if bitDepth > 0 { parts.append(bitDepthString) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

public struct TextTrackInfo: Equatable, Sendable {
    public var kind: String = "—"        // "Closed Caption", "Subtitle", "Timed Text"
    public var format: String = "—"      // "CEA-608", "CEA-708", "WebVTT", "TTML", etc.
    public var language: String = "—"

    public var summary: String {
        var s = format
        if language != "—" && !language.isEmpty { s += " · \(language)" }
        return s
    }
}

public struct VideoMetadata: Equatable, Sendable {
    public var codecName: String = "—"
    /// ⚠️ THE ENCODED RASTER — what the file's sample description says it stores, i.e.
    /// `CMVideoFormatDescriptionGetDimensions`. NOT `naturalSize`, and NOT what is on screen.
    ///
    /// This changed 2026-09-07 and the old value was neither of the two useful numbers.
    /// `naturalSize` applies the clean aperture and NOT the pixel aspect ratio, so on ARRI open-gate
    /// ProRes (encoded 2944×2160, `clap` 2880×2160, `pasp` 2:1) it reported 2880×2160 — not what the
    /// file encodes, and not what should be drawn either, which is 5760×2160. An inspector's job is
    /// to report what the file DECLARES; the transforms applied on top of it are `cleanAperture`,
    /// `pixelAspect` and `displaySize`, stated separately so each can be read on its own.
    ///
    /// ⚠️ THIS IS ALSO WHAT DECKLINK'S OUTPUT MODE IS DERIVED FROM (`ContentView` →
    /// `DeckLinkService.sourceFormatChanged`), and encoded is the CORRECT input there: the v210
    /// convert reads `offscreenTexture`, which is sized from the decoded buffer, and refuses a
    /// mismatch outright. Under `naturalSize` those two disagreed by the clean aperture on exactly
    /// the files that declare one.
    public var width: Int = 0
    public var height: Int = 0

    /// The `pasp` atom, three-state. See `DeclaredPixelAspect` for why 1:1 and absent are not the
    /// same answer.
    public var pixelAspect: DeclaredPixelAspect = .undeclared

    /// The `clap` atom, or its absence.
    public var cleanAperture: DeclaredCleanAperture = .undeclared

    /// WHAT IS ACTUALLY DRAWN: the encoded raster with the clean aperture and the pixel aspect ratio
    /// both applied — `CMVideoFormatDescriptionGetPresentationDimensions(_:usePixelAspectRatio:
    /// useCleanAperture:)` with both true, then the preferred transform. nil where no format
    /// description was readable.
    ///
    /// The same number `FrameEngine.displaySize` carries, reported here so the inspector can show
    /// the file's declaration and the app's response to it side by side rather than one number that
    /// is quietly both.
    public var displaySize: CGSize?
    public var frameRate: Double = 0
    public var fileName: String = "—"
    public var container: String = "—"
    public var videoDataRate: Double = 0    // bits/sec (estimated)

    public var creationDate: Date?       // embedded media creation date (from container)
    public var fileCreatedDate: Date?    // filesystem created (on this disk)
    public var fileModifiedDate: Date?   // filesystem modified (Finder's "modified")
    public var creator: String?          // author/creator tag, if present
    public var software: String?         // authoring tool / encoder, if present

    public var colorPrimaries: String = "—"
    public var transferFunction: String = "—"
    public var colorMatrix: String = "—"
    public var colorPrimariesCode: Int?
    public var transferFunctionCode: Int?
    public var colorMatrixCode: Int?
    /// Source-signaled color range, read from the file's format description
    /// (NOT the decoded buffer). One of "Full", "Video (Legal)", "Untagged"
    /// (flag absent), or "—" (no video format description).
    public var colorRange: String = "—"

    /// HDR10 static metadata (MDCV + CLLI) as DECLARED by the file, read via libav's
    /// side-data. Default is all-absent, which is the honest state for a file that
    /// declares none — the present flags live inside, so absence is never a defaulted
    /// value pretending to be a declaration. Read-only: displayed, never rendered from.
    public var hdr10 = HDR10StaticMetadata()

    /// Whether the file's transfer function is an HDR one (PQ or HLG). Drives whether
    /// the inspector shows the HDR10 section at all: on an SDR clip, "no HDR10 metadata"
    /// is not news; on a PQ clip it is.
    public var isHDRTransfer: Bool {
        transferFunctionCode == 16 || transferFunctionCode == 18
    }

    public var startTimecode: String?
    public var chapters: [ChapterMarker] = []
    public var audioTracks: [AudioTrackInfo] = []
    public var textTracks: [TextTrackInfo] = []

    /// The ENCODED raster. See `width`.
    public var resolutionString: String {
        (width > 0 && height > 0) ? "\(width) × \(height)" : "—"
    }

    /// What is drawn, once the clean aperture and the pixel aspect ratio are applied.
    public var displaySizeString: String {
        guard let d = displaySize, d.width > 0, d.height > 0 else { return "—" }
        return "\(Int(d.width.rounded())) × \(Int(d.height.rounded()))"
    }

    /// TRUE when the drawn geometry differs from the encoded raster — i.e. when a transform is
    /// actually being applied and the two numbers are worth showing together. Compared with a
    /// half-pixel tolerance because presentation dimensions are floating point.
    public var displayDiffersFromEncoded: Bool {
        guard let d = displaySize, width > 0, height > 0 else { return false }
        return abs(d.width - CGFloat(width)) > 0.5 || abs(d.height - CGFloat(height)) > 0.5
    }

    /// TRUE when the `clap` atom actually crops something. A `clap` equal to the encoded raster is
    /// a declaration that nothing is cropped, which is not news — see `DeclaredCleanAperture`.
    public var cleanApertureCrops: Bool {
        guard let c = cleanAperture.size, width > 0, height > 0 else { return false }
        return abs(c.width - CGFloat(width)) > 0.5 || abs(c.height - CGFloat(height)) > 0.5
    }
    public var frameRateString: String {
        frameRate > 0 ? String(format: "%.3f fps", frameRate) : "—"
    }
    public var videoDataRateString: String {
        videoDataRate > 0 ? String(format: "%.1f Mb/s", videoDataRate / 1_000_000) : "—"
    }
    public var nclcTriple: String {
        func s(_ c: Int?) -> String { c.map(String.init) ?? "—" }
        return "\(s(colorPrimariesCode))-\(s(transferFunctionCode))-\(s(colorMatrixCode))"
    }
    public func labeled(_ name: String, _ code: Int?) -> String {
        guard let code else { return name }
        return "\(name) (\(code))"
    }

    public static func dateString(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
