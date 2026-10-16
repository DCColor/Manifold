//
//  SampleDescriptionSlack.swift
//  ContainerRepair
//
//  A QuickTime / ISO-BMFF video sample-description table (`stsd`) whose declared size is larger than
//  the entries it holds. docs/BUGS.md, "A video `stsd` longer than its entries hides the video track".
//
//  ── WHAT THE DEFECT IS ─────────────────────────────────────────────────────────────────────────
//
//  `stsd` is a full box: 4 bytes version/flags, 4 bytes entry count, then that many sample entries,
//  each with its own size. The box's size should equal its header plus those entries. MEASURED on two
//  ARRI ALEXA Mini clips rewrapped by FFmpeg (`Lavf57.25.100`): `stsd` 1 744 bytes, header 16 + one
//  `ap4h` entry of 1 720 = 1 736, so 8 bytes past the last entry, all zero. AVFoundation (macOS 26.5.1)
//  then drops the WHOLE video track: the asset lists only the timecode track, AVPlayer is ready with
//  no picture, Spotlight lists the codecs as "Timecode". Any slack does it — 1 to 16 bytes, zeros or
//  0xFF, all measured — so it is the size mismatch that is refused, not a zero-sized box. libav
//  ignores the slack, which is why a stream-copy remux (ffmpeg, Flip) repairs the file.
//
//  ── WHAT THIS FILE DOES ────────────────────────────────────────────────────────────────────────
//
//  Reads the movie box and reports, for every VIDEO track (`mdia/hdlr` handler `vide`), whether its
//  `stsd` is longer than its entries. Structure only: no codec, vendor, camera or encoder is
//  consulted, and nothing here is specific to the file that prompted it.
//
//  ── WHAT IS DONE WITH THE ANSWER ───────────────────────────────────────────────────────────────
//
//  `FrameEngine` asks this ONLY after AVFoundation has exposed no video track for a `.mov` / `.mp4`.
//  Slack of 8 bytes or more routes the file to the libav path, which reads past it, with ProRes
//  decoded by VideoToolbox (`ContainerSlackRoute`, `ProResVideoToolboxDecoder`). Anything else is
//  refused with a banner that says what the scan found. Nothing is ever written to the file.
//
//  ⚠️ THIS FILE ONLY READS. Two ways of handing AVFoundation corrected bytes were measured on
//  2026-10-16 before the libav route was chosen. A same-size patch (`stsd` shrunk by the slack, the
//  freed bytes turned into a `free` box header) works on disk. Served in flight through an
//  `AVAssetResourceLoader` proxy it does NOT: AVAssetReader over a resource-loader asset fails
//  (-11800 / -12876) after 1–9 frames whenever it is read at 20 ms a frame or slower, patched or
//  not, while AVPlayer over the same proxy plays every frame. Playback reads at the display's pace.
//

import Foundation

/// One video track's sample-description table, as declared and as accounted for.
public struct VideoSampleDescriptionSlack: Equatable, Sendable {
    /// Absolute file offset of the `stsd` box's size field.
    public let stsdOffset: UInt64
    /// The box size the file declares.
    public let declaredSize: UInt64
    /// Header (16) plus the sizes of the declared entries: what the box should have said.
    public let accountedSize: UInt64
    /// True when the box used the 64-bit size form. Reported, not acted on.
    public let usesLargeSize: Bool

    public var slackBytes: UInt64 { declaredSize - accountedSize }

    public init(stsdOffset: UInt64, declaredSize: UInt64, accountedSize: UInt64, usesLargeSize: Bool) {
        self.stsdOffset = stsdOffset
        self.declaredSize = declaredSize
        self.accountedSize = accountedSize
        self.usesLargeSize = usesLargeSize
    }
}

/// What the movie box says about the file's video sample descriptions.
public enum SampleDescriptionFinding: Equatable, Sendable {
    /// No `moov` box was found at the top level, or the file could not be read.
    case noMovieBox
    /// The movie has no track whose media handler is `vide`. Not malformed: there is no picture.
    case noVideoTrack
    /// Every video `stsd` is exactly as long as its entries.
    case consistent
    /// At least one video `stsd` declares more bytes than its entries (listed in file order).
    case slack([VideoSampleDescriptionSlack])
    /// A box inside the movie overruns its parent, or an entry's size is impossible. Named so the
    /// banner can say what is wrong; never routed.
    case malformed(String)
}

public enum SampleDescriptionSlackScanner {

    /// Upper bound on the movie box this reads into memory. The ARRI clips' `moov` is 439 KB, most of
    /// it vendor metadata; a long-GOP feature's sample tables can reach tens of MB. Past this the scan
    /// reports `.malformed` rather than allocating without limit.
    public static let maxMovieBoxBytes: UInt64 = 256 << 20

    /// Scan the file at `url`. Reads the top-level box headers and the `moov` box only.
    public static func scan(url: URL) -> SampleDescriptionFinding {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .noMovieBox }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return .noMovieBox }
        let read: (UInt64, Int) -> Data? = { offset, count in
            guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
            return try? handle.read(upToCount: count)
        }
        return scan(fileSize: fileSize, read: read)
    }

    /// The scan over any byte source — the tests feed it synthetic movies.
    public static func scan(fileSize: UInt64, read: (UInt64, Int) -> Data?) -> SampleDescriptionFinding {
        // ── Top level: find `moov`. ──
        var offset: UInt64 = 0
        var moov: (offset: UInt64, headerSize: UInt64, size: UInt64)?
        while offset + 8 <= fileSize {
            guard let h = read(offset, 16), h.count >= 8 else { return .noMovieBox }
            let b = [UInt8](h)
            var size = UInt64(be32(b, 0)), header: UInt64 = 8
            if size == 1 {
                guard b.count >= 16 else { return .noMovieBox }
                size = be64(b, 8); header = 16
            } else if size == 0 {
                size = fileSize - offset
            }
            guard size >= header, offset + size <= fileSize else {
                // A truncated last box is common (an interrupted recording); only `moov` matters.
                if fourCC(b, 4) == "moov" { return .malformed("the movie box runs past the end of the file") }
                break
            }
            if fourCC(b, 4) == "moov" { moov = (offset, header, size); break }
            offset += size
        }
        guard let m = moov else { return .noMovieBox }
        guard m.size <= maxMovieBoxBytes else { return .malformed("the movie box is larger than \(maxMovieBoxBytes >> 20) MB") }
        guard let data = read(m.offset, Int(m.size)), UInt64(data.count) == m.size else { return .noMovieBox }
        let bytes = [UInt8](data)

        // ── Inside `moov`: every `trak`. ──
        var slacks: [VideoSampleDescriptionSlack] = []
        var sawVideo = false
        do {
            for trak in try children(bytes, from: Int(m.headerSize), to: bytes.count) where trak.type == "trak" {
                guard let mdia = try children(bytes, from: trak.payload, to: trak.end).first(where: { $0.type == "mdia" })
                else { continue }
                let mdiaKids = try children(bytes, from: mdia.payload, to: mdia.end)
                // The media handler: version/flags (4), component type (4), handler type (4).
                guard let hdlr = mdiaKids.first(where: { $0.type == "hdlr" }), hdlr.payload + 12 <= hdlr.end,
                      fourCC(bytes, hdlr.payload + 8) == "vide" else { continue }
                sawVideo = true
                guard let minf = mdiaKids.first(where: { $0.type == "minf" }),
                      let stbl = try children(bytes, from: minf.payload, to: minf.end).first(where: { $0.type == "stbl" }),
                      let stsd = try children(bytes, from: stbl.payload, to: stbl.end).first(where: { $0.type == "stsd" })
                else { continue }
                // version/flags (4), entry count (4), then the entries.
                guard stsd.payload + 8 <= stsd.end else { return .malformed("a video sample-description table is too short for its header") }
                let count = be32(bytes, stsd.payload + 4)
                var cursor = stsd.payload + 8
                for _ in 0..<count {
                    guard cursor + 8 <= stsd.end else {
                        return .malformed("a video sample-description table declares \(count) entries but holds fewer")
                    }
                    let entrySize = Int(be32(bytes, cursor))
                    guard entrySize >= 8, cursor + entrySize <= stsd.end else {
                        return .malformed("a video sample description's size runs past its table")
                    }
                    cursor += entrySize
                }
                if cursor < stsd.end {
                    slacks.append(VideoSampleDescriptionSlack(
                        stsdOffset: m.offset + UInt64(stsd.start),
                        declaredSize: UInt64(stsd.end - stsd.start),
                        accountedSize: UInt64(cursor - stsd.start),
                        usesLargeSize: stsd.payload - stsd.start == 16))
                }
            }
        } catch let e as Overrun {
            return .malformed(e.what)
        } catch {
            return .malformed("the movie box could not be walked")
        }
        if !slacks.isEmpty { return .slack(slacks) }
        return sawVideo ? .consistent : .noVideoTrack
    }

    // MARK: - Box walking

    struct Box { let type: String; let start: Int; let payload: Int; let end: Int }
    struct Overrun: Error { let what: String }

    /// The boxes laid end to end in `bytes[from..<to]`. A box that overruns its parent throws: inside
    /// `moov` that is a malformed movie, not a truncated recording.
    static func children(_ bytes: [UInt8], from: Int, to: Int) throws -> [Box] {
        var out: [Box] = []
        var o = from
        while o + 8 <= to {
            var size = UInt64(be32(bytes, o)), header = 8
            if size == 1 {
                guard o + 16 <= to else { throw Overrun(what: "a box header runs past its parent") }
                size = be64(bytes, o + 8); header = 16
            } else if size == 0 {
                size = UInt64(to - o)
            }
            guard size >= UInt64(header), UInt64(o) + size <= UInt64(to) else {
                throw Overrun(what: "a '\(fourCC(bytes, o + 4))' box runs past its parent")
            }
            out.append(Box(type: fourCC(bytes, o + 4), start: o, payload: o + header, end: o + Int(size)))
            o += Int(size)
        }
        return out
    }

    static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
    static func be64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(be32(b, i)) << 32 | UInt64(be32(b, i + 4)) }
    static func fourCC(_ b: [UInt8], _ i: Int) -> String {
        String(decoding: b[i..<(i + 4)], as: UTF8.self)
    }
}
