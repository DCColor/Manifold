import Foundation

/// The range convention an MXF **declares in its picture descriptor**, read straight off the
/// container — THREE STATES, and the third is the point.
///
/// ⚠️ **THIS EXISTS BECAUSE LIBAV IS SILENT ON ONE DESCRIPTOR KIND, NOT BECAUSE IT IS WRONG.**
/// `mxfdec` maps the **CDCIDescriptor**'s `BlackRefLevel`/`WhiteRefLevel` onto `color_range`
/// correctly. It does **not** map the **RGBADescriptor**'s `ComponentMinRef`/`ComponentMaxRef`,
/// which is what 4:4:4 DNxHR carries — so those files arrive as `AVCOL_RANGE_UNSPECIFIED` while
/// the container has stated the answer plainly. MEASURED 2026-09-09 across four fixtures; see
/// `docs/BUGS.md` → *"an MXF whose range libav reports as UNSPECIFIED renders as legal range"*.
///
/// ⚠️ **IT IS A FALLBACK FOR THE SILENT CASE, NOT A SECOND OPINION.** `LibavFrameSource` calls it
/// **only** when libav reported `UNSPECIFIED`, so this reader and libav can never disagree —
/// there is no precedence rule because there is no contest. That is deliberate: libav is correct
/// on every fixture where it speaks, and letting a second parser override a stated answer would
/// change behaviour on files that are right today in order to fix files that are not.
///
/// ⚠️ **AND IT NEVER GUESSES.** Anything it does not positively recognise — no descriptor, absent
/// reference levels, an excursion matching neither convention — returns `.untagged`, which is a
/// real answer meaning *the file did not say*. It is not a synonym for legal. See
/// `DeclaredPixelAspect` and `KeychainRead` for the same rule on other axes.
public enum MXFDeclaredRange {

    /// Read the declared range from `url`'s MXF header. Returns `.untagged` for anything that is
    /// not a recognisable MXF, so callers need not sniff the container first.
    ///
    /// Reads the header partition only — sized from the partition pack's `HeaderByteCount`, not
    /// guessed — so this is a bounded read of a few hundred KB, never a scan of the essence.
    public static func read(url: URL) -> MediaInspector.SourceColorRange {
        guard let bytes = headerBytes(url) else { return .untagged }
        return classify(scanDescriptor(bytes))
    }

    // MARK: - MXF structure

    /// `06.0E.2B.34.02.05.01.01.0D.01.02.01.01.02` — the Header Partition Pack, minus the two
    /// trailing bytes that vary by partition status.
    private static let partitionPackPrefix: [UInt8] =
        [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01, 0x02]
    /// `06.0E.2B.34.02.53.01.01` — the prefix shared by every structural-metadata set key.
    private static let metadataSetPrefix: [UInt8] =
        [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01]

    /// Upper bound on the header read, so a malformed `HeaderByteCount` cannot ask for the file.
    private static let headerReadCap = 16 * 1024 * 1024

    /// BER length at `offset`: returns (length, offsetOfValue).
    private static func ber(_ d: [UInt8], _ offset: Int) -> (Int, Int)? {
        guard offset < d.count else { return nil }
        let first = d[offset]
        if first < 0x80 { return (Int(first), offset + 1) }
        let n = Int(first & 0x7F)
        guard n > 0, n <= 8, offset + 1 + n <= d.count else { return nil }
        var v = 0
        for i in 0..<n { v = (v << 8) | Int(d[offset + 1 + i]) }
        guard v >= 0 else { return nil }
        return (v, offset + 1 + n)
    }

    private static func be(_ d: ArraySlice<UInt8>) -> Int? {
        guard !d.isEmpty, d.count <= 8 else { return nil }
        return d.reduce(0) { ($0 << 8) | Int($1) }
    }

    /// Read the partition pack, take `HeaderByteCount`, and return exactly the header metadata.
    private static func headerBytes(_ url: URL) -> [UInt8]? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        // Partition pack key (16) + BER length (<=9) + enough of the value to reach
        // HeaderByteCount, which sits 32 bytes in (versions 4, KAGSize 4, three 8-byte offsets).
        guard let head = try? fh.read(upToCount: 64), head.count >= 64 else { return nil }
        let h = [UInt8](head)
        guard Array(h[0..<14]) == partitionPackPrefix else { return nil }  // not an MXF
        guard let (_, valueOffset) = ber(h, 16), valueOffset + 40 <= h.count else { return nil }
        guard let headerByteCount = be(h[(valueOffset + 32)..<(valueOffset + 40)]),
              headerByteCount > 0 else { return nil }
        let total = min(valueOffset + headerByteCount, headerReadCap)
        try? fh.seek(toOffset: 0)
        guard let data = try? fh.read(upToCount: total), data.count > valueOffset else { return nil }
        return [UInt8](data)
    }

    // MARK: - The descriptor

    /// What a picture descriptor declared. `depth` is bits per component.
    private struct Excursion { var minRef: Int; var maxRef: Int; var depth: Int }

    /// Walk the header's KLV triplets and return the FIRST picture descriptor's excursion.
    ///
    /// ⚠️ First, not merged. A multi-descriptor file could carry more than one picture descriptor;
    /// picking the first matches what the single-video-stream path downstream assumes, and
    /// combining them would invent an answer no descriptor gave.
    private static func scanDescriptor(_ d: [UInt8]) -> Excursion? {
        var o = 0
        while o + 17 < d.count {
            guard let (len, valueOffset) = ber(d, o + 16), valueOffset + len <= d.count else { return nil }
            let isMetadataSet = Array(d[o..<(o + 8)]) == metadataSetPrefix
            let kind = d[o + 14]                      // 0x28 = CDCIDescriptor, 0x29 = RGBADescriptor
            if isMetadataSet, kind == 0x28 || kind == 0x29 {
                var tags: [UInt16: ArraySlice<UInt8>] = [:]
                var q = valueOffset
                let end = valueOffset + len
                while q + 4 <= end {
                    let tag = (UInt16(d[q]) << 8) | UInt16(d[q + 1])
                    let tl = (Int(d[q + 2]) << 8) | Int(d[q + 3])
                    q += 4
                    guard q + tl <= end else { break }
                    tags[tag] = d[q..<(q + tl)]
                    q += tl
                }
                if kind == 0x28,
                   let black = tags[0x3304].flatMap(be),      // BlackRefLevel
                   let white = tags[0x3305].flatMap(be),      // WhiteRefLevel
                   let depth = tags[0x3301].flatMap(be),      // ComponentDepth
                   depth >= 8, depth <= 16 {
                    return Excursion(minRef: black, maxRef: white, depth: depth)
                }
                if kind == 0x29,
                   let lo = tags[0x3407].flatMap(be),         // ComponentMinRef
                   let hi = tags[0x3406].flatMap(be),         // ComponentMaxRef
                   let depth = tags[0x3401].flatMap(pixelLayoutDepth) {
                    return Excursion(minRef: lo, maxRef: hi, depth: depth)
                }
            }
            o = valueOffset + len
        }
        return nil
    }

    /// `PixelLayout` is up to 8 (component code, depth) byte pairs, terminated by a zero code.
    /// `'F'` is fill/padding and carries its own depth, so it is skipped rather than measured.
    private static func pixelLayoutDepth(_ layout: ArraySlice<UInt8>) -> Int? {
        var i = layout.startIndex
        while i + 1 < layout.endIndex {
            let code = layout[i], depth = Int(layout[i + 1])
            if code == 0 { return nil }
            if code != UInt8(ascii: "F"), depth >= 8, depth <= 16 { return depth }
            i += 2
        }
        return nil
    }

    // MARK: - Classification

    /// ⚠️ Recognise, do not infer. Only the two standard excursions map to an answer; anything
    /// else is a file we do not understand, and `.untagged` says so honestly.
    private static func classify(_ e: Excursion?) -> MediaInspector.SourceColorRange {
        guard let e, e.depth >= 8, e.depth <= 16 else { return .untagged }
        let shift = e.depth - 8
        if e.minRef == 0, e.maxRef == (1 << e.depth) - 1 { return .full }
        if e.minRef == (16 << shift), e.maxRef == (235 << shift) { return .videoLegal }
        return .untagged
    }
}
