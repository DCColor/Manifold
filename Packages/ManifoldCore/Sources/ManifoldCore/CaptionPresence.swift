import Foundation
import CFFmpeg

/// CLOSED-CAPTION **PRESENCE**, AND DELIBERATELY NOTHING MORE.
///
/// This file answers four questions about a file's caption services — what format, which
/// service, what language, and whether the service actually carries payload — and it answers
/// them WITHOUT DECODING A CHARACTER. There is no 608 state machine here (no displayed/
/// non-displayed memory, no PAC or control-code interpretation) and no 708 windowing (no
/// DefineWindow, no pen state, no compositor). Every byte past a header is counted and
/// discarded.
///
/// ── WHY PRESENCE IS WORTH ITS OWN LAYER ───────────────────────────────────────────────────
///
/// Manifold is a QC tool. The single most useful caption fact is not what the captions say,
/// it is whether a service that the file DECLARES is actually carrying anything. A valid,
/// correctly-timed, entirely null caption track is a real and common delivery failure, and it
/// is indistinguishable from a healthy one unless something counts. `Mixed Captions.mxf`
/// carries 720 CDPs — one per frame, all well-formed — and only 46 of them carry a non-null
/// 608 pair. Counting is free; decoding is not. So this layer counts.
///
/// ⚠️ "CARRIES DATA" MEANS BYTES, NOT WORDS. A service whose only payload is a DeleteWindows
/// command counts as carrying data here, because this layer does not know what a command is.
/// The vocabulary in `CaptionDataPresence` is worded to say exactly that and no more — see
/// `statement`. Do not restate it in the UI as "has captions".
///
/// ── THE MEASURED LAYERING (see the probe report, 2026-09-08) ──────────────────────────────
///
///   MXF → SMPTE 436M ANC element → VANC line 9, DID/SDID 0x61/0x01
///       → SMPTE 334-1 CDP → cc_data triplets → 608 pairs and DTVCC service blocks
///
///   .mov `clcp` track → per-sample QuickTime atoms → 'cdat' (line 21 field 1),
///       'cdt2' (field 2), 'ccdp' (a whole CDP, for `c708` tracks)
///
/// Both containers converge on the SAME two payloads, which is why one scanner serves both:
/// `CaptionCDPScanner` is fed 436M elements by `CaptionPresenceReader` (the libav/MXF path)
/// and raw 608 pairs by `MediaInspector` (the AVFoundation/.mov path).

// MARK: - Presence vocabulary

/// Whether a declared caption service carries payload, and the count behind the claim.
///
/// The three states are genuinely different statements and the UI must not collapse them:
/// `unknown` is "nobody looked", `measured(carrying: 0, observed: n)` is "looked at n units
/// and every one was null", and `measured(carrying: 0, observed: 0)` is "the file declares
/// this service and it never appears in the stream at all". Absent is a fourth statement and
/// is expressed by there being no row.
public enum CaptionDataPresence: Equatable, Sendable {
    /// Not scanned. The honest default for track kinds this layer does not read
    /// (`.subtitle`, `.text`) — those get a row with no data claim attached.
    case unknown
    /// `carrying` of `observed` units held a non-null payload. `unit` names what was counted
    /// so the number is readable without knowing which container it came from.
    case measured(carrying: Int, observed: Int, unit: String)

    public var carriesData: Bool {
        if case .measured(let c, _, _) = self { return c > 0 }
        return false
    }

    /// True once something actually counted — i.e. the absence of data is a FINDING rather
    /// than a gap in what we looked at.
    public var wasMeasured: Bool {
        if case .measured = self { return true }
        return false
    }

    /// The inspector's second line, or nil when there is nothing honest to say.
    ///
    /// ⚠️ WORDED AS BYTES, NOT MEANING. "carries data" is the strongest claim this layer can
    /// support; it has not read a caption and must not imply it has.
    ///
    /// ⚠️ **PRESENT-OR-EMPTY AND NOTHING MORE. THE COUNTS MOVED — THEY DID NOT GO AWAY.** This
    /// used to read "carries data — 46 of 720 line-21 pairs", which is diagnostic evidence rather
    /// than something a colourist acts on, and it wrapped to a second line at the inspector's
    /// 280 pt. The numbers are still measured and are still reported, in `diagnosticDetail` →
    /// the captured log → the diagnostics export, which is where a tester looks for evidence.
    ///
    /// ⚠️ **THE EMPTY CASE IS THE FINDING AND MUST NOT BE QUIETER THAN THE POSITIVE ONE.** Both
    /// no-data cases print the same flat "NO DATA": a declared service carrying nothing is the
    /// thing this row exists to surface, and the caller renders it in amber while "carries data"
    /// stays dim. The difference between "all null" and "never appears" is preserved in the MODEL
    /// (the enum is unchanged) and stated in the diagnostics line — it is a question for whoever
    /// cut the file, not a distinction that changes what the operator does next.
    public var statement: String? {
        switch self {
        case .unknown:
            return nil
        case .measured(let carrying, _, _):
            return carrying > 0 ? "carries data" : "NO DATA"
        }
    }

    /// The evidence behind `statement`, for the diagnostics export. Nil when nothing was counted.
    ///
    /// This is where the counts the inspector used to print now live — same numbers, same units,
    /// and here the "all null" and "never appears" cases stay distinct because a tester reading a
    /// bug report needs to tell them apart.
    public var diagnosticDetail: String? {
        switch self {
        case .unknown:
            return nil
        case .measured(let carrying, let observed, let unit):
            if carrying > 0 { return "\(carrying) of \(observed) \(unit) carried data" }
            if observed > 0 { return "\(observed) \(unit) observed, ALL NULL" }
            return "declared, but never appears in the stream (0 \(unit) observed)"
        }
    }
}

// MARK: - The scanner

/// Accumulates caption-service facts across a whole file. Fed either whole SMPTE 436M ANC
/// elements (`ingest(ancElement:)`) or bare 608 pairs (`ingest(pairField:_:_:)`), so the MXF
/// and `.mov` paths share one roster, one counter and one output shape.
///
/// Stateful across calls on purpose: a DTVCC packet is assembled from triplets that SPAN
/// FRAMES (measured — the fixture's packets run frames 443→444 and 597→598), so the assembly
/// buffer cannot be per-element.
struct CaptionCDPScanner {

    // ── Declared roster, from the CDP service info section ────────────────────────────────
    /// line-21 field (1 or 2) → language, as the CDP spells it.
    private var declared608: [Int: String] = [:]
    /// 708 caption service number → language.
    private var declared708: [Int: String] = [:]
    /// True once any CDP carried a service info section. When false the roster is synthesised
    /// from what the stream actually carried instead — see `rows(defaultLanguage:)`.
    private var sawServiceInfo = false

    // ── Counts ───────────────────────────────────────────────────────────────────────────
    private var total608: [Int: Int] = [:]
    private var nonNull608: [Int: Int] = [:]
    private var blocks708: [Int: Int] = [:]
    private var nonNullBlocks708: [Int: Int] = [:]

    // ── DTVCC packet assembly (spans elements) ───────────────────────────────────────────
    private var dtvcc: [UInt8] = []
    private var dtvccWant = 0

    // MARK: Feeding — SMPTE 436M

    /// One SMPTE 436M ANC frame element, exactly as libav hands it over on the
    /// `smpte_436m_anc` stream. Layout (measured against the fixture):
    ///
    ///     UINT16  number of ANC packets
    ///       per packet:
    ///         UINT16 line number · UINT8 wrapping type · UINT8 payload sample coding
    ///         UINT16 payload sample count
    ///         UINT32 array element count · UINT32 array element size
    ///         bytes  payload (count × size)
    ///
    /// The payload is the ANC packet in 8-bit form: DID, SDID, DC, then DC user-data bytes.
    /// Only DID/SDID 0x61/0x01 (SMPTE 334-1, a CDP) is of interest; everything else on the
    /// track — AFD, timecode, whatever else the VANC carried — is skipped without comment.
    mutating func ingest(ancElement b: UnsafeBufferPointer<UInt8>) {
        guard b.count >= 2 else { return }
        let packetCount = Int(b[0]) << 8 | Int(b[1])
        var o = 2
        for _ in 0..<packetCount {
            // 6 bytes of packet header + 8 bytes of array header before the payload.
            guard o + 14 <= b.count else { return }
            o += 6
            let elementCount = Int(b[o])     << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
            let elementSize  = Int(b[o + 4]) << 24 | Int(b[o + 5]) << 16 | Int(b[o + 6]) << 8 | Int(b[o + 7])
            o += 8
            // ⚠️ THE MULTIPLY IS CHECKED, NOT ASSUMED. Both operands are 32-bit fields read
            // off disk, so their product can exceed Int.max — and in Swift that TRAPS rather
            // than wrapping, which would turn a corrupt ANC header into a crash. Overflow is
            // treated as "this element is not parseable" and abandons the element.
            let (payloadLength, overflowed) = elementCount.multipliedReportingOverflow(by: elementSize)
            guard !overflowed, payloadLength >= 0, o + payloadLength <= b.count else { return }
            let payload = o
            o += payloadLength
            guard payloadLength >= 4, b[payload] == 0x61, b[payload + 1] == 0x01 else { continue }
            let dataCount = Int(b[payload + 2])
            guard payloadLength >= 3 + dataCount else { continue }
            ingest(cdp: b, from: payload + 3, count: dataCount)
        }
    }

    // MARK: Feeding — a bare CDP

    /// A SMPTE 334-1 CDP. Reachable two ways: unwrapped from a 436M ANC packet (MXF), or
    /// lifted straight out of a `'ccdp'` atom in a `c708` `clcp` track (.mov).
    ///
    /// Sections appear in a fixed order after the 7-byte header and each is announced by its
    /// own id byte, so the walk is positional and every step is bounds-checked — this parses
    /// bytes off a user's disk and must not trust a single length in them.
    mutating func ingest(cdp b: UnsafeBufferPointer<UInt8>, from start: Int, count: Int) {
        let end = start + count
        guard count >= 11, end <= b.count,
              b[start] == 0x96, b[start + 1] == 0x69 else { return }   // cdp_identifier
        let flags = b[start + 4]
        var p = start + 7

        if flags & 0x80 != 0 { p += 5 }                                // time code section

        if flags & 0x40 != 0 {                                         // ccdata section
            guard p + 1 < end, b[p] == 0x72 else { return }
            let ccCount = Int(b[p + 1] & 0x1f)
            p += 2
            guard p + ccCount * 3 <= end else { return }
            for _ in 0..<ccCount {
                ingest(triplet: b[p], b[p + 1], b[p + 2])
                p += 3
            }
        }

        if flags & 0x20 != 0 {                                         // service info section
            guard p + 1 < end, b[p] == 0x73 else { return }
            let serviceCount = Int(b[p + 1] & 0x0f)
            p += 2
            guard p + serviceCount * 7 <= end else { return }
            for _ in 0..<serviceCount {
                ingest(serviceInfo: b, at: p)
                p += 7
            }
        }
    }

    // MARK: Feeding — a bare 608 pair

    /// One line-21 byte pair for `field` (1 or 2) — what a `.mov` `'cdat'`/`'cdt2'` atom holds.
    mutating func ingest(pairField field: Int, _ b0: UInt8, _ b1: UInt8) {
        total608[field, default: 0] += 1
        // Odd parity lives in bit 7 and is not payload: 0x80 0x80 is the standard null pair and
        // must count as null, not as data.
        if (b0 & 0x7f) != 0 || (b1 & 0x7f) != 0 { nonNull608[field, default: 0] += 1 }
    }

    // MARK: Internals

    /// One cc_data triplet: a validity/type header byte and two payload bytes.
    /// cc_type 0/1 are line 21 fields 1/2; 2 is DTVCC packet data, 3 is DTVCC packet start.
    private mutating func ingest(triplet header: UInt8, _ b0: UInt8, _ b1: UInt8) {
        guard header & 0x04 != 0 else { return }            // cc_valid — padding is not a unit
        switch header & 0x03 {
        case 0:
            ingest(pairField: 1, b0, b1)
        case 1:
            ingest(pairField: 2, b0, b1)
        case 3:                                             // DTVCC_PACKET_START
            flushDTVCC()
            dtvcc = [b0, b1]
            let sizeCode = Int(b0 & 0x3f)
            dtvccWant = sizeCode == 0 ? 128 : sizeCode * 2
        default:                                            // 2 — DTVCC_PACKET_DATA
            // Data before any start byte belongs to a packet whose head we never saw; drop it
            // rather than attributing its blocks to a service by accident.
            if dtvccWant > 0 { dtvcc.append(b0); dtvcc.append(b1) }
        }
        if dtvccWant > 0, dtvcc.count >= dtvccWant { flushDTVCC() }
    }

    /// Walk a completed DTVCC packet's SERVICE BLOCK HEADERS and count, per service, how many
    /// blocks arrived and how many carried any payload. The block bodies are stepped over
    /// without being read — this is the 708 half of "no decoder".
    private mutating func flushDTVCC() {
        defer { dtvcc = []; dtvccWant = 0 }
        guard dtvccWant > 0, !dtvcc.isEmpty else { return }
        let end = min(dtvcc.count, dtvccWant)
        var r = 1                                           // byte 0 is the packet header
        while r < end {
            let header = dtvcc[r]
            r += 1
            var service = Int((header >> 5) & 0x07)
            let blockSize = Int(header & 0x1f)
            if service == 0, blockSize == 0 { break }       // null block — packet padded out
            if service == 7 {                               // extended service block
                guard r < end else { break }
                service = Int(dtvcc[r] & 0x3f)
                r += 1
            }
            blocks708[service, default: 0] += 1
            if blockSize > 0 { nonNullBlocks708[service, default: 0] += 1 }
            r += blockSize
        }
    }

    /// One 7-byte svc_info entry: `reserved(2)|caption_service_number(6)`, a 3-byte language
    /// code, then a byte whose top bit selects how the rest reads.
    ///
    /// ⚠️ THE line21_field BIT'S POLARITY IS TAKEN AS 1 = FIELD 1, and that reading is
    /// inferred from the fixture rather than from a second source: `Mixed Captions.mxf`
    /// declares one 608 service with this bit SET, and every non-null 608 pair in the file is
    /// in cc_type 0 (field 1) while all 720 field-2 triplets are null. The opposite polarity
    /// would make the file declare a service that carries nothing while its actual content
    /// sits in an undeclared one. Worth re-checking against a field-2 fixture if one appears.
    private mutating func ingest(serviceInfo b: UnsafeBufferPointer<UInt8>, at p: Int) {
        sawServiceInfo = true
        let language = Self.languageCode(b[p + 1], b[p + 2], b[p + 3])
        let descriptor = b[p + 4]
        if descriptor & 0x80 != 0 {                         // digital_cc — a 708 service
            declared708[Int(descriptor & 0x3f)] = language
        } else {                                            // analogue — a line 21 field
            declared608[(descriptor & 0x01) != 0 ? 1 : 2] = language
        }
    }

    /// The CDP's 3-byte language code, normalised to the SAME spelling AVFoundation reports.
    ///
    /// ⚠️ NORMALISED ON PURPOSE, AND THIS IS NOT COSMETIC. The fixture writes `65 6e 00` —
    /// "en" with a NUL pad — while `AVAssetTrack.languageCode` returns "eng" for the same
    /// language. Reporting both spellings in one panel is how an MXF and a MOV of the same
    /// programme come to look like they disagree; `audioTrackRow` avoids the identical trap
    /// for codec names. `Locale.LanguageCode.identifier(.alpha3)` is idempotent on "eng", so
    /// both paths can run through it. A code it does not recognise is passed through verbatim
    /// rather than dropped — the file said something, and inventing nothing is not the same as
    /// hiding it.
    private static func languageCode(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> String {
        let raw = String(bytes: [a, b, c].filter { $0 > 0x20 && $0 < 0x7f }, encoding: .ascii) ?? ""
        guard !raw.isEmpty else { return "—" }
        return Locale.LanguageCode(raw.lowercased()).identifier(.alpha3) ?? raw
    }

    // MARK: Output

    /// The roster as inspector rows, 608 first then 708, each ascending by service.
    ///
    /// `defaultLanguage` is used only where the CDP declared none — it is how the `.mov` path
    /// supplies the language `AVAssetTrack` knows and a bare `'cdat'` stream cannot carry.
    ///
    /// ⚠️ WHEN NO CDP DECLARED A ROSTER, ROWS ARE SYNTHESISED FROM WHAT THE STREAM CARRIED,
    /// and nothing is invented to fill the gap: the field number comes from cc_type and the
    /// 708 service number from the service block header — both are read, not guessed — while
    /// the language stays `defaultLanguage` (usually "—"). A file with no service info
    /// section is common; a file whose services we made up would be worse than no rows.
    func rows(defaultLanguage: String = "—") -> [TextTrackInfo] {
        var out: [TextTrackInfo] = []
        let fields = sawServiceInfo ? declared608.keys.sorted() : total608.keys.sorted()
        for field in fields {
            var row = TextTrackInfo()
            row.kind = "Closed Caption"
            row.format = "CEA-608"
            row.service = "Line 21 field \(field)"
            row.language = declared608[field] ?? defaultLanguage
            row.dataPresence = .measured(carrying: nonNull608[field] ?? 0,
                                         observed: total608[field] ?? 0,
                                         unit: "line-21 pairs")
            out.append(row)
        }
        let services = sawServiceInfo ? declared708.keys.sorted() : blocks708.keys.sorted()
        for service in services {
            var row = TextTrackInfo()
            row.kind = "Closed Caption"
            row.format = "CEA-708"
            row.service = "Service \(service)"
            row.language = declared708[service] ?? defaultLanguage
            row.dataPresence = .measured(carrying: nonNullBlocks708[service] ?? 0,
                                         observed: blocks708[service] ?? 0,
                                         unit: "service blocks")
            out.append(row)
        }
        return out
    }
}

// MARK: - The libav reader (MXF)

/// Caption presence for containers AVFoundation cannot open — which in this app means MXF,
/// where `AVURLAsset` fails at `assetProperty_Tracks` with -11828 and can therefore report
/// nothing about captions at all.
///
/// This is the caption sibling of `HDR10MetadataReader`: a small, self-contained libav read
/// that opens the URL itself rather than borrowing a decode context, so it can be called from
/// either path without coupling to one.
public enum CaptionPresenceReader {

    /// Scan a file's SMPTE 436M ANC track and report its caption services.
    /// Returns [] for a file with no ANC track, which is the correct answer for "no captions"
    /// — the caller renders no section rather than an empty one.
    ///
    /// ── ⚠️ NO `avformat_find_stream_info`, AND THAT IS THE WHOLE PERFORMANCE STORY ─────────
    ///
    /// Measured on `Mixed Captions.mxf` (5.2 GB, 720 ANC packets):
    ///
    ///     open_input 2.0 ms · find_stream_info 120–143 ms · packet loop 1.8 ms
    ///
    /// The probe is 25× the cost of everything else combined and buys nothing HERE: the MXF
    /// demuxer resolves every stream's `codec_id` from the header during `open_input`, so the
    /// ANC track is already identifiable (verified — all three streams typed, ANC found).
    /// Skipping it takes the whole scan to **4.9–6.5 ms**, steady state.
    ///
    /// ⚠️ THAT IS THE WARM NUMBER, AND THE WARMTH IS NOT LUCK. A genuinely cold first open of
    /// this file measured ~150 ms, all of it I/O latency reaching the container header on an
    /// external volume. It does not apply at the call site: `applyLibavTextTracks` runs a few
    /// lines after `LibavFrameSource.open()` has already opened the SAME file, so the header is
    /// in the page cache by the time this asks for it. Called from somewhere that had not just
    /// opened the file, this would want a Task.
    ///
    /// ⚠️ AND SKIPPING THE PROBE IS SAFE BECAUSE THIS IS THE MXF PATH, not because probing is
    /// generally optional. A container that only resolves stream types during
    /// `find_stream_info` would leave `ancIndex` at -1 here and report no captions — silently,
    /// and wrongly. This is called from `loadMXF`'s decode path and nowhere else.
    ///
    /// `AVDISCARD_ALL` on every other stream is the other half: the demuxer then skips the
    /// video and audio essence instead of reading it, so the loop cost tracks ANC packet count
    /// (0.0026 ms each) rather than file size. A two-hour file scans in well under a second.
    public static func services(inANCTrackOf url: URL) -> [TextTrackInfo] {
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&ctx, url.path, nil, nil) == 0, let fmt = ctx else { return [] }
        defer { avformat_close_input(&ctx) }

        var ancIndex = -1
        for i in 0..<Int(fmt.pointee.nb_streams) {
            guard let stream = fmt.pointee.streams[i] else { continue }
            if stream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_SMPTE_436M_ANC, ancIndex < 0 {
                ancIndex = i
            }
            stream.pointee.discard = AVDISCARD_ALL
        }
        guard ancIndex >= 0, let ancStream = fmt.pointee.streams[ancIndex] else { return [] }
        ancStream.pointee.discard = AVDISCARD_DEFAULT

        guard let packet = av_packet_alloc() else { return [] }
        defer { var p: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&p) }

        var scanner = CaptionCDPScanner()
        while av_read_frame(fmt, packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == Int32(ancIndex),
                  let data = packet.pointee.data, packet.pointee.size > 0 else { continue }
            scanner.ingest(ancElement: UnsafeBufferPointer(start: data, count: Int(packet.pointee.size)))
        }
        return scanner.rows()
    }
}

/// Emits the caption measurement into the captured log, and therefore into the diagnostics export.
///
/// ⚠️ **THIS IS WHERE THE INSPECTOR'S COUNTS WENT.** The panel answers present-or-empty; the
/// evidence for that answer belongs where a tester reads evidence. `DiagnosticsReport` has no
/// per-file section — the CAPTURED LOG is where per-file facts land today — so this prints, and the
/// export carries it.
///
/// Called from BOTH readers (the libav/ANC one and the AVFoundation one) so an MXF and a .mov of
/// the same master produce the same line.
public enum CaptionPresenceLog {
    public static func emit(_ rows: [TextTrackInfo], source: String) {
        guard !rows.isEmpty else { return }
        for row in rows {
            let detail = row.dataPresence.diagnosticDetail ?? "not scanned"
            print("[CAPTIONS] \(source): \(row.summary) — \(detail)")
        }
    }
}
