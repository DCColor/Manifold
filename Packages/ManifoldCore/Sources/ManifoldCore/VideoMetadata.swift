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

    /// The declared ratio in lowest terms, or nil when nothing was declared. Nil is the same
    /// "the file said nothing" answer `ratio` gives, and for the same reason: a caller that wants
    /// to assume square has to say so itself.
    ///
    /// Reduced because both consumers are about IDENTITY rather than arithmetic — the `_par` tag
    /// in an exported frame's filename and the exact integer ratio written into its PNG `pHYs`
    /// chunk. `4:2` and `2:1` are the same declaration and must not produce two different
    /// filenames for the same squeeze.
    public var reduced: (horizontal: Int, vertical: Int)? {
        guard case .declared(let h, let v) = self, h > 0, v > 0 else { return nil }
        let g = Self.gcd(h, v)
        return (h / g, v / g)
    }

    /// The filename marker for an exported frame — `"par2-1"` — or NIL when it would say nothing.
    ///
    /// ⚠️ NIL ON SQUARE, AND THAT IS THE WHOLE DESIGN OF THE MARKER. Tagging every ordinary export
    /// `_par1-1` would put noise on the common case and make the marker's presence meaningless;
    /// tagging only the anamorphic ones makes it informative — a filename carrying `_par` is a
    /// frame that needs a desqueeze, and one that does not, does not. Nil is therefore returned
    /// for BOTH `.undeclared` and a declared 1:1: the marker answers "does this need
    /// desqueezing?", which is one question with one answer, not the three-state question the
    /// inspector row and the `pHYs` chunk answer.
    public var filenameTag: String? {
        guard let r = reduced, r.horizontal != r.vertical else { return nil }
        return "par\(r.horizontal)-\(r.vertical)"
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = abs(a), b = abs(b)
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
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

/// ── THE DECLARATION RESOLVED INTO A RECT THE SAMPLER CAN HONOUR EXACTLY ───────────────────────
///
/// `DeclaredCleanAperture` is what the file SAYS. This is what can be DONE about it: a pixel rect
/// inside the encoded raster, on the 2-px grid, which `MetalVideoRenderer` allocates the offscreen
/// from and which `InspectorPanel` reports when it differs from the declaration.
///
/// ⚠️ ONE RESOLVER, TWO CALLERS, ON PURPOSE. The renderer crops and the inspector describes the
/// crop. If each did its own arithmetic the inspector could describe a rect the renderer did not
/// use, which is the one failure mode a "clean aperture" row must not have.
///
/// ── WHY THE 2-PX GRID, AND WHY ROUNDING RATHER THAN DECLINING ────────────────────────────────
///
/// A `clap` offset is a rational and need not be integral. The decode contract is 4:2:0, so the
/// chroma plane is half-resolution and only an EVEN luma offset leaves the chroma sample phase
/// where it already is. That is the whole of the constraint, and it is exact rather than a
/// tolerance:
///
///   * On an even, integral rect the offscreen pass is bit-exact. Fragment `i` of a `w`-wide
///     offscreen samples normalized `(x + i + 0.5) / encodedWidth`, which is the CENTRE of luma
///     texel `x + i` — bilinear returns that texel unchanged. In chroma texel units the same
///     coordinate is `x/2 + (i + 0.5)/2`, i.e. the identical fractional phase the UNCROPPED path
///     samples today, so chroma is byte-for-byte what it was before the crop existed.
///   * An ODD offset moves that phase by half a chroma texel and re-blends every chroma sample in
///     the frame. Silently. That is a measurement corruption in four scopes and the SDI output.
///
/// So the rect is snapped to the even grid. ROUNDED, not refused, and the argument is that the two
/// errors are not the same size: rounding places the crop within 1 px of where the file said, and
/// the crop stays bit-exact because it is still integral; declining to crop reports 32 columns of
/// alignment padding as picture, which is precisely the defect this exists to remove. A 1 px
/// placement error is a smaller lie than a 64 px one.
///
/// **`isExact` is how the rounding stops being silent.** The inspector shows the applied rect
/// whenever it is false, and the renderer logs `[CLAP]` once per source.
public struct CleanApertureCrop: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    /// FALSE when the declaration did not already sit on the 2-px grid and was snapped onto it.
    /// TRUE means the rect below IS the declaration, to the pixel.
    public let isExact: Bool

    public init(x: Int, y: Int, width: Int, height: Int, isExact: Bool) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.isExact = isExact
    }

    public var displayString: String { "\(width) × \(height) at \(x), \(y)" }

    /// The crop to apply to `encodedWidth` × `encodedHeight`, or NIL when there is nothing to do —
    /// no `clap`, a `clap` that crops nothing, or a declaration that survives neither the grid nor
    /// the raster bounds. Nil is the "use the whole buffer" answer and every caller reads it so.
    ///
    /// ⚠️ THE OFFSETS ARE CENTRE-RELATIVE. QuickTime's `clap` states the displacement of the clean
    /// aperture's CENTRE from the encoded raster's centre, not a top-left origin. On both ARRI
    /// open-gate fixtures the offsets are 0 and the entire crop comes from the centring term —
    /// `(2944 − 2880) / 2 = 32`, which is the number measured at the left edge of the picture.
    public static func resolve(encodedWidth: Int, encodedHeight: Int,
                               aperture: DeclaredCleanAperture) -> CleanApertureCrop? {
        guard encodedWidth > 0, encodedHeight > 0,
              case .declared(let cw, let ch, let hOff, let vOff) = aperture,
              cw > 0, ch > 0 else { return nil }

        let left = (Double(encodedWidth) - cw) / 2 + hOff
        let top  = (Double(encodedHeight) - ch) / 2 + vOff

        // Recorded BEFORE any snapping, so `isExact` describes the declaration and not the result.
        let exact = isEvenIntegral(left) && isEvenIntegral(top)
                 && isEvenIntegral(cw) && isEvenIntegral(ch)

        var x = roundToEven(left)
        var y = roundToEven(top)
        var w = roundToEven(cw)
        var h = roundToEven(ch)

        // Clamp into the raster, then re-even: the clamp can produce an odd extent, and an odd
        // extent puts the RIGHT edge off the chroma grid the same way an odd offset puts the left
        // edge off it.
        x = min(max(0, x), max(0, encodedWidth - 2))
        y = min(max(0, y), max(0, encodedHeight - 2))
        w = min(w, encodedWidth - x); w -= w % 2
        h = min(h, encodedHeight - y); h -= h % 2
        guard w >= 2, h >= 2 else { return nil }

        // A rect equal to the raster is a declaration that nothing is cropped — see
        // `DeclaredCleanAperture`. Returning nil keeps that file on the identical code path as a
        // file with no `clap` at all, rather than on a "crop of everything".
        guard x != 0 || y != 0 || w != encodedWidth || h != encodedHeight else { return nil }
        return CleanApertureCrop(x: x, y: y, width: w, height: h, isExact: exact)
    }

    private static func roundToEven(_ v: Double) -> Int { Int((v / 2).rounded()) * 2 }

    private static func isEvenIntegral(_ v: Double) -> Bool {
        let r = v.rounded()
        return abs(v - r) < 1e-6 && Int(r).isMultiple(of: 2)
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
    /// WHICH service inside the format — "Line 21 field 1" for 608, "Service 1" for 708.
    /// A caption stream carries several of these and they can say different things (measured:
    /// `Mixed Captions.mxf`'s 708 service carries text its 608 service does not), so a row
    /// that named only the format would be describing a container rather than a service.
    /// "—" for track kinds with no service concept (`.subtitle`, `.text`).
    public var service: String = "—"
    /// Whether this service actually carries payload, and the count behind the claim.
    /// `.unknown` where nothing counted — see `CaptionDataPresence`, which is careful about
    /// the difference between "empty", "never appears" and "not looked at".
    public var dataPresence: CaptionDataPresence = .unknown

    /// The row's headline value: what it is, which service, and in what language — the three
    /// facts the file DECLARES. Whether the service is actually carrying anything is a
    /// measurement rather than a declaration and is rendered separately, so that a file which
    /// declares a service and delivers nothing cannot read as healthy at a glance.
    public var summary: String {
        var parts = [format]
        if service != "—" && !service.isEmpty { parts.append(service) }
        if language != "—" && !language.isEmpty { parts.append(language) }
        return parts.joined(separator: " · ")
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

    /// THE SHAPE OF THE ROW ABOVE, SPOKEN THE WAY COLOURISTS SPEAK IT — "1.78", "2.39". A decimal
    /// to two places rather than a ratio, because that is the vocabulary: a grade is delivered at
    /// 2.39, not at 1024:429, and "16:9" is the one form of it nobody says at a monitor.
    ///
    /// ⚠️ DIVIDED FROM `displaySize`, NOT FROM `width`/`height`, AND THE DIFFERENCE IS THE WHOLE
    /// REASON THE ROW EXISTS. On a file with no `clap` and square pixels the two divisions agree
    /// and the row is a convenience; on a file with either one they do NOT, and the encoded
    /// division is the wrong answer — ARRI open-gate ProRes encodes 2944×2160 (1.36) and displays
    /// 5760×2160 (2.67). Anyone reading a DAR wants the second number. Dividing the raster would
    /// print a squeeze factor wearing an aspect ratio's label, on exactly the files the row is for.
    ///
    /// NIL WHERE THERE IS NO DISPLAY SIZE, so the inspector omits the row rather than inventing
    /// one. That is not hypothetical: the libav/MXF path sets no `displaySize` at all (see
    /// `FrameEngine.applyLibavMetadata` — `StreamInfo` carries neither transform, so the engine's
    /// own `displaySize` there is the ENCODED size and the metadata's is left nil). Falling back to
    /// `width`/`height` would restore the row on that path by printing the encoded aspect under a
    /// display label — the precise lie described above, told on the path least able to detect it.
    /// An absent row says "not established here"; a wrong number would not.
    public var displayAspectRatioString: String? {
        guard let d = displaySize, d.width > 0, d.height > 0 else { return nil }
        return String(format: "%.2f", Double(d.width / d.height))
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

    /// THE CROP THE RENDERER ACTUALLY APPLIES, resolved from the two rows above it. Nil where
    /// nothing is cropped.
    ///
    /// The inspector reads this so the panel can never describe a rect the offscreen does not
    /// use: `MetalVideoRenderer` resolves the same declaration through the same function, from
    /// the same two encoded dimensions this struct reports as `width`/`height`.
    public var activeCrop: CleanApertureCrop? {
        CleanApertureCrop.resolve(encodedWidth: width, encodedHeight: height,
                                  aperture: cleanAperture)
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
