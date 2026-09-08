// mxfmeas — does an MXF opened through AVFoundation report the same facts, the same pixels and
// the same audio as `LibavFrameSource` does today?
//
// Written after the 2026-09-08 finding in ../BUGS.md → "CAUSE CONFIRMED — VideoToolbox plug-in
// codecs and MediaToolbox plug-in format readers are OPT-IN PER PROCESS". Before that finding
// this comparison was not possible, because AVFoundation could not open an MXF at all.
//
// ── ⚠️ THE REGISTRATION CALLS COME FIRST, ALWAYS, AND THE HARNESS SAYS SO ────────────────────
//
// Every AVFoundation number in here is meaningless without them. A run that silently forgot would
// report "AVFoundation cannot open MXF" and look like a finding rather than like an omission —
// which is exactly the error the BUGS entry records as having cost the most time. `main` calls
// both before anything else and prints that it did; there is no flag to skip them.
//
// ── BUILD AND RUN ───────────────────────────────────────────────────────────────────────────
//
//   docs/mxf-fixtures/build-mxfmeas.sh          # links the VENDORED libav; see the script
//
//   MODE=facts    ./mxfmeas FILE...
//   MODE=calibrate ./mxfmeas PRORES.mov         # REQUIRED before pixels means anything
//   MODE=pixels CALIBRATE=PRORES.mov N=4 ./mxfmeas FILE...
//   MODE=audio SECONDS=1.0 ./mxfmeas FILE...
//
// ⚠️ Do NOT pass -parse-as-library. Single-file script; top-level code is only legal without it,
// and the failure message ("statements are not allowed at the top level") does not name the flag.
// Same trap as scrubmeas.swift, avpvomeas.swift and libavmeas.swift.
//
// ⚠️ IT IS NOT PART OF THE APP TARGET. `project.yml`'s `sources:` is `App` plus one explicit
// DeckLink `.cpp`; nothing under `docs/` is globbed in. Editing this file does not require
// `xcodegen` and cannot affect a Debug, Profile or Release build.
//
// ── WHAT IT CANNOT DO, STATED ONCE ──────────────────────────────────────────────────────────
//
// It cannot link ManifoldCore (a SwiftPM package; linking it would mean building the app's
// dependency graph, which this convention exists to avoid). So the "what Manifold reports today"
// column is produced by code COPIED VERBATIM from the app, each copy marked `⚠️ COPIED FROM`.
// A copy that drifts from its original measures the wrong thing — check them if a row surprises
// you.

import Foundation
import AVFoundation
import VideoToolbox
import MediaToolbox
import CoreMedia
import AudioToolbox

// ═══════════════════════════════════════════════════════════════════════════════════════════
// MARK: - Registration
// ═══════════════════════════════════════════════════════════════════════════════════════════

func registerProfessionalVideoWorkflow() {
    VTRegisterProfessionalVideoWorkflowVideoDecoders()
    MTRegisterProfessionalVideoWorkflowFormatReaders()
    print("REGISTERED  VTRegisterProfessionalVideoWorkflowVideoDecoders()")
    print("REGISTERED  MTRegisterProfessionalVideoWorkflowFormatReaders()")
    print("            (both called before any AVFoundation or VideoToolbox use below)")
    let dir = "/Library/Video/Professional Video Workflow Plug-Ins"
    let bundles = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
        .filter { $0.hasSuffix(".bundle") }.sorted() ?? []
    print("            plug-ins installed: \(bundles.isEmpty ? "NONE — every AVF result below will fail" : "\(bundles.count) in \(dir)")")
    if !bundles.isEmpty { print("            \(bundles.joined(separator: ", "))") }
    print("")
}

// ═══════════════════════════════════════════════════════════════════════════════════════════
// MARK: - Small utilities
// ═══════════════════════════════════════════════════════════════════════════════════════════

func fourCC(_ s: String) -> FourCharCode {
    var r: FourCharCode = 0
    for ch in s.utf16 { r = (r << 8) + FourCharCode(ch) }
    return r
}

func fourCCString(_ code: FourCharCode) -> String {
    let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                 UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
    return "'" + (String(bytes: bytes, encoding: .macOSRoman) ?? "????") + "'"
}

func env(_ key: String) -> String? { ProcessInfo.processInfo.environment[key] }
func envInt(_ key: String, _ fallback: Int) -> Int { env(key).flatMap { Int($0) } ?? fallback }
func envDouble(_ key: String, _ fallback: Double) -> Double { env(key).flatMap { Double($0) } ?? fallback }

/// Blocking bridge for the async AVFoundation surface. This is a measurement script; there is no
/// UI to keep responsive and a semaphore keeps the output in file order.
func sync<T>(_ body: @escaping () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    var out: T!
    Task { out = await body(); sem.signal() }
    sem.wait()
    return out
}

func gcdInt(_ a: Int, _ b: Int) -> Int {
    var a = abs(a), b = abs(b)
    while b != 0 { (a, b) = (b, a % b) }
    return max(a, 1)
}

/// A rational printed as it is stored, INCLUDING 0/1. See the pixel-aspect row: reducing or
/// defaulting a 0/1 to 1/1 is precisely how a "both paths say square" gets manufactured out of
/// one path saying nothing at all.
func rationalString(_ num: Int, _ den: Int) -> String {
    if den == 0 { return "\(num)/0 (invalid)" }
    if num == 0 { return "0/\(den) — UNSPECIFIED, not 1:1" }
    let g = gcdInt(num, den)
    let reduced = (num / g == num && den / g == den) ? "" : "  (= \(num / g):\(den / g))"
    return "\(num)/\(den)\(reduced)"
}

/// ⚠️ TRUNCATES as well as pads. A cell that overruns its column runs into the next one and the
/// table stops being readable as a table — which on a three-column report is how two columns get
/// misread as one. "…" marks anything cut.
func pad(_ s: String, _ n: Int) -> String {
    if s.count == n { return s }
    if s.count > n { return n <= 1 ? String(s.prefix(n)) : String(s.prefix(n - 2)) + "… " }
    return s + String(repeating: " ", count: n - s.count)
}

// ═══════════════════════════════════════════════════════════════════════════════════════════
// MARK: - libav log capture
// ═══════════════════════════════════════════════════════════════════════════════════════════

/// Decoder complaints, captured rather than left on stderr.
///
/// ⚠️ THIS IS THE PRIMARY EVIDENCE FOR "libav IS KNOWN-INCORRECT ON THIS FILE". The 444 fixture's
/// defect announces itself — `Unsupported: variable ACT flag.` — and a harness that let that scroll
/// past on stderr would go on to run a tolerance analysis on a frame the decoder has already said
/// it could not decode. See `KnownIncorrect`.
final class LibavLog {
    static var lines: [String] = []
    static let lock = NSLock()
    static func add(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, !lines.contains(t) { lines.append(t) }
    }
    static func matching(_ needle: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines.filter { $0.range(of: needle, options: .caseInsensitive) != nil }
    }
    static func reset() { lock.lock(); lines = []; lock.unlock() }
}

func installLibavLogCapture() {
    av_log_set_level(AV_LOG_WARNING)
    av_log_set_callback { ptr, level, fmt, vl in
        guard level <= AV_LOG_WARNING, let fmt, let vl else { return }
        var buf = [CChar](repeating: 0, count: 1024)
        var printPrefix: Int32 = 1
        _ = av_log_format_line2(ptr, level, fmt, vl, &buf, 1024, &printPrefix)
        LibavLog.add(String(cString: buf))
    }
}

// ═══════════════════════════════════════════════════════════════════════════════════════════
// MARK: - What libav can report
// ═══════════════════════════════════════════════════════════════════════════════════════════

struct LibavAudioStreamFacts {
    var streamIndex: Int32 = -1
    var codecName = "—"
    var sampleRate = 0
    var channels = 0
    var bitsPerRawSample = 0
    var layoutDescribe = "—"     // av_channel_layout_describe — FFmpeg's own vocabulary
    var channelOrder = "—"       // NATIVE / CUSTOM / UNSPEC — CUSTOM is what MCA labels produce
    var roles: [String] = []     // through the app's own bridge, so both columns share a vocabulary
    var layoutName = "—"
    var layoutConfidence = "—"
}

struct LibavFacts {
    var opened = false
    var error = "—"
    // video
    var videoStreamIndex: Int32 = -1
    var codecName = "—"
    var codecProfile = "—"
    var parWidth = 0, parHeight = 0
    var pixFmt = "—"
    var sarNum = 0, sarDen = 1          // codecpar.sample_aspect_ratio, RAW
    var streamSarNum = 0, streamSarDen = 1
    var colorRangeRaw = "—"
    var colorRangeEnum: Int32 = 0
    var primaries: Int?, transfer: Int?, matrix: Int?
    var primariesRaw = 0, transferRaw = 0, matrixRaw = 0
    var frameRateNum = 0, frameRateDen = 1
    var durationSeconds = 0.0
    var videoBitRate: Int64 = 0
    var startTimecode: String?
    var timecodeSource = "—"
    // audio
    var audio: [LibavAudioStreamFacts] = []
    // other streams
    var hasANC = false
    var ancStreamIndex: Int32 = -1
    var streamKinds: [String] = []
}

/// 0 reserved, 2 unspecified → nil.
/// ⚠️ COPIED FROM `LibavFrameSource.open()`'s local `cicp(_:)`. Same folding, so the "Manifold
/// reports today" column is what the app would actually publish.
func cicp(_ raw: some BinaryInteger) -> Int? {
    let v = Int(raw)
    return (v == 0 || v == 2) ? nil : v
}

func readLibavFacts(_ url: URL) -> LibavFacts {
    var f = LibavFacts()
    var ctx: UnsafeMutablePointer<AVFormatContext>?
    guard avformat_open_input(&ctx, url.path, nil, nil) == 0, let fmt = ctx else {
        f.error = "avformat_open_input failed"
        return f
    }
    defer { var c: UnsafeMutablePointer<AVFormatContext>? = fmt; avformat_close_input(&c) }
    guard avformat_find_stream_info(fmt, nil) >= 0 else {
        f.error = "avformat_find_stream_info failed"
        return f
    }
    f.opened = true

    for i in 0..<Int(fmt.pointee.nb_streams) {
        guard let st = fmt.pointee.streams[i] else { continue }
        let par = st.pointee.codecpar!
        let type = par.pointee.codec_type
        let cid = par.pointee.codec_id
        let name = String(cString: avcodec_get_name(cid))
        switch type {
        case AVMEDIA_TYPE_VIDEO:
            f.streamKinds.append("#\(i) video \(name)")
            if f.videoStreamIndex < 0 {
                f.videoStreamIndex = Int32(i)
                var codecName = name
                if codecName == "dnxhd" { codecName = "DNxHR" }   // ⚠️ COPIED FROM LibavFrameSource.open()
                f.codecName = codecName
                if let p = avcodec_profile_name(cid, par.pointee.profile) {
                    f.codecProfile = String(cString: p)
                } else {
                    f.codecProfile = "profile \(par.pointee.profile)"
                }
                f.parWidth = Int(par.pointee.width)
                f.parHeight = Int(par.pointee.height)
                f.pixFmt = av_get_pix_fmt_name(AVPixelFormat(par.pointee.format))
                    .map { String(cString: $0) } ?? "?"
                f.sarNum = Int(par.pointee.sample_aspect_ratio.num)
                f.sarDen = Int(par.pointee.sample_aspect_ratio.den)
                f.streamSarNum = Int(st.pointee.sample_aspect_ratio.num)
                f.streamSarDen = Int(st.pointee.sample_aspect_ratio.den)
                let r = par.pointee.color_range
                f.colorRangeEnum = Int32(r.rawValue)
                f.colorRangeRaw = r == AVCOL_RANGE_JPEG ? "AVCOL_RANGE_JPEG (full)"
                    : r == AVCOL_RANGE_MPEG ? "AVCOL_RANGE_MPEG (legal)"
                    : "AVCOL_RANGE_UNSPECIFIED"
                f.primariesRaw = Int(par.pointee.color_primaries.rawValue)
                f.transferRaw = Int(par.pointee.color_trc.rawValue)
                f.matrixRaw = Int(par.pointee.color_space.rawValue)
                f.primaries = cicp(par.pointee.color_primaries.rawValue)
                f.transfer = cicp(par.pointee.color_trc.rawValue)
                f.matrix = cicp(par.pointee.color_space.rawValue)
                let fr = av_guess_frame_rate(fmt, st, nil)
                f.frameRateNum = Int(fr.num)
                f.frameRateDen = Int(fr.den)
                f.videoBitRate = par.pointee.bit_rate
            }
        case AVMEDIA_TYPE_AUDIO:
            f.streamKinds.append("#\(i) audio \(name)")
            var a = LibavAudioStreamFacts()
            a.streamIndex = Int32(i)
            a.codecName = name
            a.sampleRate = Int(par.pointee.sample_rate)
            a.channels = Int(par.pointee.ch_layout.nb_channels)
            a.bitsPerRawSample = Int(par.pointee.bits_per_raw_sample)
            var buf = [CChar](repeating: 0, count: 128)
            _ = av_channel_layout_describe(&par.pointee.ch_layout, &buf, 128)
            a.layoutDescribe = String(cString: buf)
            switch par.pointee.ch_layout.order {
            case AV_CHANNEL_ORDER_NATIVE: a.channelOrder = "NATIVE"
            case AV_CHANNEL_ORDER_CUSTOM: a.channelOrder = "CUSTOM"
            case AV_CHANNEL_ORDER_UNSPEC: a.channelOrder = "UNSPEC"
            default: a.channelOrder = "order \(par.pointee.ch_layout.order.rawValue)"
            }
            if let fd = makeLibavAudioFormatDescription(par) {
                a.roles = layoutRoles(from: fd) ?? []
                let l = audioLayout(from: fd, channelCount: a.channels)
                a.layoutName = l.name
                a.layoutConfidence = l.confidence
            }
            f.audio.append(a)
        default:
            if cid == AV_CODEC_ID_SMPTE_436M_ANC {
                f.streamKinds.append("#\(i) data smpte_436m_anc")
                if !f.hasANC { f.hasANC = true; f.ancStreamIndex = Int32(i) }
            } else {
                f.streamKinds.append("#\(i) \(type.rawValue) \(name)")
            }
        }
    }

    f.durationSeconds = fmt.pointee.duration == Int64.min ? 0
        : Double(fmt.pointee.duration) / 1_000_000

    // ⚠️ COPIED FROM `LibavFrameSource.open()` — the Material Package TC, with the stream-level
    // fallback, in the same order. Which of the file's several timecodes this picks is one of the
    // rows the comparison exists to examine.
    if let e = av_dict_get(fmt.pointee.metadata, "timecode", nil, 0) {
        f.startTimecode = String(cString: e.pointee.value)
        f.timecodeSource = "format metadata (Material Package)"
    } else {
        for i in 0..<Int(fmt.pointee.nb_streams) {
            if let st = fmt.pointee.streams[i],
               let e = av_dict_get(st.pointee.metadata, "timecode", nil, 0) {
                f.startTimecode = String(cString: e.pointee.value)
                f.timecodeSource = "stream #\(i) metadata"
                break
            }
        }
    }
    return f
}

// ═══════════════════════════════════════════════════════════════════════════════════════════
// MARK: - ⚠️ COPIED FROM AudioChannelLayoutBridge / LibavAudioSource / MediaInspector
//
// The whole point of the audio comparison is that BOTH paths are named by the SAME functions —
// otherwise a difference in the report could be a difference in two naming tables rather than in
// two files. These are verbatim copies, and they are copies only because this harness cannot link
// ManifoldCore. If a role name here disagrees with the app, the app is right and this is stale.
// ═══════════════════════════════════════════════════════════════════════════════════════════

struct BridgePosition { let ffmpegBit: Int; let label: AudioChannelLabel }

/// ⚠️ COPIED FROM `AudioChannelLayoutBridge.positions`.
let bridgePositions: [BridgePosition] = [
    .init(ffmpegBit:  0, label: kAudioChannelLabel_Left),
    .init(ffmpegBit:  1, label: kAudioChannelLabel_Right),
    .init(ffmpegBit:  2, label: kAudioChannelLabel_Center),
    .init(ffmpegBit:  3, label: kAudioChannelLabel_LFEScreen),
    .init(ffmpegBit:  4, label: kAudioChannelLabel_LeftSurround),
    .init(ffmpegBit:  5, label: kAudioChannelLabel_RightSurround),
    .init(ffmpegBit:  6, label: kAudioChannelLabel_LeftCenter),
    .init(ffmpegBit:  7, label: kAudioChannelLabel_RightCenter),
    .init(ffmpegBit:  8, label: kAudioChannelLabel_CenterSurround),
    .init(ffmpegBit:  9, label: kAudioChannelLabel_LeftSurroundDirect),
    .init(ffmpegBit: 10, label: kAudioChannelLabel_RightSurroundDirect),
    .init(ffmpegBit: 11, label: kAudioChannelLabel_TopCenterSurround),
    .init(ffmpegBit: 12, label: kAudioChannelLabel_VerticalHeightLeft),
    .init(ffmpegBit: 13, label: kAudioChannelLabel_VerticalHeightCenter),
    .init(ffmpegBit: 14, label: kAudioChannelLabel_VerticalHeightRight),
    .init(ffmpegBit: 15, label: kAudioChannelLabel_TopBackLeft),
    .init(ffmpegBit: 16, label: kAudioChannelLabel_TopBackCenter),
    .init(ffmpegBit: 17, label: kAudioChannelLabel_TopBackRight),
]

var bridgeHeaderSize: Int { MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)! }

/// ⚠️ COPIED FROM `AudioChannelLayoutBridge.roleName(for:)`.
func roleName(for label: AudioChannelLabel) -> String {
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
    case kAudioChannelLabel_RearSurroundLeft: return "Lss"
    case kAudioChannelLabel_RearSurroundRight: return "Rss"
    case kAudioChannelLabel_LeftCenter: return "Lc"
    case kAudioChannelLabel_RightCenter: return "Rc"
    case kAudioChannelLabel_Mono: return "Mono"
    case kAudioChannelLabel_Unused: return "—"
    default: return "?(\(label))"
    }
}

/// ⚠️ COPIED FROM `AudioChannelLayoutBridge.roleNames(for:)` — the SET-AWARE namer. Mapping the
/// single-label namer over an array silently opts out of the one-pair/two-pair rule.
func roleNames(for labels: [AudioChannelLabel]) -> [String] {
    let hasSide = labels.contains(kAudioChannelLabel_LeftSurroundDirect)
               || labels.contains(kAudioChannelLabel_RightSurroundDirect)
    let hasBack = labels.contains(kAudioChannelLabel_LeftSurround)
               || labels.contains(kAudioChannelLabel_RightSurround)
    let hasRear = labels.contains(kAudioChannelLabel_RearSurroundLeft)
               || labels.contains(kAudioChannelLabel_RearSurroundRight)
    guard hasSide, !(hasBack && hasRear) else { return labels.map(roleName(for:)) }
    return labels.map { label in
        switch label {
        case kAudioChannelLabel_LeftSurroundDirect:  return "Ls"
        case kAudioChannelLabel_RightSurroundDirect: return "Rs"
        case kAudioChannelLabel_LeftSurround:  return "Lss"
        case kAudioChannelLabel_RightSurround: return "Rss"
        default: return roleName(for: label)
        }
    }
}

/// ⚠️ COPIED FROM `AudioChannelLayoutBridge.labels(fromLayout:size:)` — descriptions first, then
/// CoreAudio's own expansion of a bitmap or a tag.
func bridgeLabels(fromLayout raw: UnsafeRawPointer, size: Int, allowExpansion: Bool = true) -> [AudioChannelLabel]? {
    guard size >= bridgeHeaderSize else { return nil }
    let tag = raw.loadUnaligned(fromByteOffset: 0, as: AudioChannelLayoutTag.self)
    let bitmap = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
    let count = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
    let descStride = MemoryLayout<AudioChannelDescription>.stride
    if count > 0, size >= bridgeHeaderSize + count * descStride {
        return (0..<count).map {
            raw.advanced(by: bridgeHeaderSize + $0 * descStride)
               .loadUnaligned(as: AudioChannelDescription.self).mChannelLabel
        }
    }
    guard allowExpansion else { return nil }
    if tag == kAudioChannelLayoutTag_UseChannelBitmap { return bridgeExpand(kAudioFormatProperty_ChannelLayoutForBitmap, bitmap) }
    guard tag != kAudioChannelLayoutTag_UseChannelDescriptions else { return nil }
    return bridgeExpand(kAudioFormatProperty_ChannelLayoutForTag, tag)
}

func bridgeExpand(_ property: AudioFormatPropertyID, _ input: UInt32) -> [AudioChannelLabel]? {
    var value = input
    let inSize = UInt32(MemoryLayout<UInt32>.size)
    var outSize: UInt32 = 0
    guard AudioFormatGetPropertyInfo(property, inSize, &value, &outSize) == noErr,
          outSize >= UInt32(bridgeHeaderSize) else { return nil }
    var bytes = [UInt8](repeating: 0, count: Int(outSize))
    var size = outSize
    let status = bytes.withUnsafeMutableBytes { out in
        AudioFormatGetProperty(property, inSize, &value, &size, out.baseAddress!)
    }
    guard status == noErr else { return nil }
    return bytes.withUnsafeBytes { out in
        bridgeLabels(fromLayout: out.baseAddress!, size: Int(size), allowExpansion: false)
    }
}

/// ⚠️ COPIED FROM `AudioChannelLayoutBridge.roles(from:)`.
func layoutRoles(from fmt: CMFormatDescription) -> [String]? {
    var size = 0
    guard let raw = CMAudioFormatDescriptionGetChannelLayout(fmt, sizeOut: &size),
          let labels = bridgeLabels(fromLayout: UnsafeRawPointer(raw), size: size),
          !labels.isEmpty else { return nil }
    return roleNames(for: labels)
}

/// ⚠️ COPIED FROM `MediaInspector.layoutName(forRoles:)` — the SEQUENCE decides the layout, which
/// is what distinguishes SMPTE from Film. This table is the reason `decl_5_5_5F_51_51F.mxf` exists.
func layoutName(forRoles roles: [String]) -> String? {
    let table: [String: String] = [
        "Mono": "Mono", "L R": "Stereo", "L C R": "3.0", "L R C": "3.0",
        "L C R Cs": "4.0 (LCRS)", "L R C Cs": "4.0 (LRCS)", "L R Ls Rs": "4.0 (Quad)",
        "L C R Ls Rs": "5.0 Film", "L R C Ls Rs": "5.0 SMPTE",
        "L R C LFE Ls Rs": "5.1 SMPTE", "L C R Ls Rs LFE": "5.1 Film",
        "L R C Ls Rs Lss Rss": "7.0 SMPTE", "L C R Ls Rs Lss Rss": "7.0 Film",
        "L R C LFE Ls Rs Lss Rss": "7.1 SMPTE", "L C R LFE Ls Rs Lss Rss": "7.1 Film",
        "L C R Ls Rs Lss Rss LFE": "7.1 Film"
    ]
    return table[roles.joined(separator: " ")]
}

/// ⚠️ COPIED FROM `MediaInspector.inferredLayoutName(forChannels:)`.
func inferredLayoutName(forChannels n: Int) -> String? {
    switch n {
    case 1: return "Mono"
    case 2: return "Stereo"
    case 6: return "5.1"
    case 8: return "7.1"
    default: return nil
    }
}

/// ⚠️ COPIED FROM `MediaInspector.audioLayout(from:channelCount:)` — the three tiers, unchanged.
/// The confidence is the interesting half: `.declared` means the FILE said it.
func audioLayout(from fmt: CMFormatDescription, channelCount: Int) -> (name: String, confidence: String) {
    if let roles = layoutRoles(from: fmt) {
        let meaningful = roles.filter { $0 != "?" && !$0.hasPrefix("?(") && $0 != "—" }
        if !meaningful.isEmpty, let name = layoutName(forRoles: roles) { return (name, "declared") }
    }
    if let inferred = inferredLayoutName(forChannels: channelCount) { return ("\(inferred) (inferred)", "inferred") }
    return (channelCount > 0 ? "\(channelCount) ch" : "—", "undeclared")
}

/// ⚠️ COPIED FROM `LibavAudioSource.declaredChannelLayout(_:)` + `makeOutputFormatDescription`,
/// reduced to what a description needs. Walks channel INDICES rather than the mask, so CUSTOM
/// order (MCA labels — the Film-order streams) survives.
func makeLibavAudioFormatDescription(_ par: UnsafeMutablePointer<AVCodecParameters>) -> CMAudioFormatDescription? {
    let count = Int(par.pointee.ch_layout.nb_channels)
    guard count > 0 else { return nil }
    var labels: [AudioChannelLabel] = []
    var named = 0
    for i in 0..<count {
        let channel = av_channel_layout_channel_from_index(&par.pointee.ch_layout, UInt32(i))
        if let position = bridgePositions.first(where: { $0.ffmpegBit == Int(channel.rawValue) }) {
            labels.append(position.label); named += 1
        } else {
            labels.append(kAudioChannelLabel_Unused)
        }
    }
    var asbd = AudioStreamBasicDescription(
        mSampleRate: Double(par.pointee.sample_rate),
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(4 * count), mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(4 * count), mChannelsPerFrame: UInt32(count),
        mBitsPerChannel: 32, mReserved: 0)
    var fd: CMAudioFormatDescription?
    guard named > 0 else {
        // No layout at all — the honest state, and the app builds the description without one.
        return CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0,
                                              layout: nil, magicCookieSize: 0, magicCookie: nil,
                                              extensions: nil, formatDescriptionOut: &fd) == noErr ? fd : nil
    }
    var data = Data(count: bridgeHeaderSize + labels.count * MemoryLayout<AudioChannelDescription>.stride)
    data.withUnsafeMutableBytes { raw in
        let base = raw.baseAddress!
        base.storeBytes(of: kAudioChannelLayoutTag_UseChannelDescriptions, as: AudioChannelLayoutTag.self)
        base.advanced(by: 4).storeBytes(of: UInt32(0), as: UInt32.self)
        base.advanced(by: 8).storeBytes(of: UInt32(labels.count), as: UInt32.self)
        for (i, label) in labels.enumerated() {
            var desc = AudioChannelDescription()
            desc.mChannelLabel = label
            withUnsafeBytes(of: &desc) { src in
                base.advanced(by: bridgeHeaderSize + i * MemoryLayout<AudioChannelDescription>.stride)
                    .copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
        }
    }
    return data.withUnsafeBytes { raw -> CMAudioFormatDescription? in
        var out: CMAudioFormatDescription?
        let st = CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: data.count,
            layout: raw.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self),
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &out)
        return st == noErr ? out : nil
    }
}

/// ⚠️ COPIED FROM `MediaInspector.primariesName/transferName/matrixName(forCode:)`.
func primariesName(_ c: Int?) -> String {
    switch c { case 1: return "Rec. 709"; case 9: return "Rec. 2020"; case 6: return "SMPTE-C"
    case 5: return "EBU 3213"; case 12: return "P3 D65"; case 11: return "DCI-P3"
    case 10: return "ST 428-1"; default: return "—" }
}
func transferName(_ c: Int?) -> String {
    switch c { case 1: return "Rec. 709"; case 16: return "PQ (ST 2084)"; case 18: return "HLG"
    case 13: return "sRGB"; case 8: return "Linear"; case 17: return "ST 428-1"
    case 7: return "SMPTE 240M"; default: return "—" }
}
func matrixName(_ c: Int?) -> String {
    switch c { case 1: return "Rec. 709"; case 9: return "Rec. 2020"; case 7: return "SMPTE 240M"
    case 6: return "SMPTE-C / 170M"; default: return "—" }
}

// ═══════════════════════════════════════════════════════════════════════════════════════════
// MARK: - What AVFoundation reports
// ═══════════════════════════════════════════════════════════════════════════════════════════

struct AVFAudioTrackFacts {
    var trackID: CMPersistentTrackID = 0
    var codec = "—"
    var sampleRate = 0.0
    var channels = 0
    var bitDepth = 0
    var dataRate = 0.0
    var hasLayout = false
    var layoutTag = "—"
    var roles: [String] = []
    var layoutName = "—"
    var layoutConfidence = "—"
}

struct AVFTextTrackFacts {
    var kind = "—"
    var subtype = "—"
    var language = "—"
}

struct AVFFacts {
    var opened = false
    var error = "—"
    var trackSummary: [String] = []
    // video
    var hasVideo = false
    var codecFourCC = "—"
    var codecName = "—"
    var width = 0, height = 0
    var naturalSize = CGSize.zero
    var presentationSize = CGSize.zero
    var paspPresent = false
    var paspH = 0, paspV = 0
    var clapPresent = false
    var clapW = 0.0, clapH = 0.0, clapHOff = 0.0, clapVOff = 0.0
    var primaries: Int?, transfer: Int?, matrix: Int?
    var primariesRaw = "—", transferRaw = "—", matrixRaw = "—"
    var rangeState = "—"          // Full / Video (Legal) / Untagged — the genuine three states
    var nominalFrameRate: Float = 0
    var minFrameDurationValue: Int64 = 0, minFrameDurationScale: Int32 = 0
    var durationSeconds = 0.0
    var videoDataRate = 0.0
    // timecode
    var hasTimecodeTrack = false
    var timecodeString: String?
    var timecodeDetail = "—"
    // audio + text
    var audio: [AVFAudioTrackFacts] = []
    var text: [AVFTextTrackFacts] = []
}

/// ⚠️ COPIED FROM `MediaInspector.colorTags(for:)` — the string→code maps. Codes are what the
/// comparison uses; the names exist only so an unmapped string is visible as itself.
func avfColorCodes(_ fmt: CMFormatDescription) -> (Int?, String, Int?, String, Int?, String) {
    func ext(_ key: CFString) -> String? {
        CMFormatDescriptionGetExtension(fmt, extensionKey: key) as? String
    }
    let primMap: [String: Int] = ["ITU_R_709_2": 1, "ITU_R_2020": 9, "SMPTE_C": 6,
                                  "EBU_3213": 5, "P3_D65": 12, "DCI_P3": 11, "SMPTE_ST_428_1": 10]
    let transMap: [String: Int] = ["ITU_R_709_2": 1, "SMPTE_ST_2084_PQ": 16, "ITU_R_2100_HLG": 18,
                                   "ARIB_STD_B67_HLG": 18, "sRGB": 13, "Linear": 8,
                                   "SMPTE_ST_428_1": 17, "SMPTE_240M_1995": 7]
    let matMap: [String: Int] = ["ITU_R_709_2": 1, "ITU_R_2020": 9, "SMPTE_240M_1995": 7, "SMPTE_C": 6]
    let p = ext(kCMFormatDescriptionExtension_ColorPrimaries)
    let t = ext(kCMFormatDescriptionExtension_TransferFunction)
    let m = ext(kCMFormatDescriptionExtension_YCbCrMatrix)
    return (p.flatMap { primMap[$0] }, p ?? "—",
            t.flatMap { transMap[$0] }, t ?? "—",
            m.flatMap { matMap[$0] }, m ?? "—")
}

/// ⚠️ COPIED FROM `MediaInspector.sourceColorRange(for:)` — genuinely three-state, which is the
/// half of the comparison the libav column cannot express.
func avfRangeState(_ fmt: CMFormatDescription) -> String {
    guard let raw = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) else {
        return "Untagged"
    }
    guard let isFull = raw as? Bool else { return "Untagged" }
    return isFull ? "Full" : "Video (Legal)"
}

/// The `tmcd` track, read as a timecode. Manifold's own `TimecodeReader` is a MOV ATOM WALK and
/// returns nil for MXF whatever the reader vends, so this is deliberately NOT the app's reader —
/// it exists to answer "does AVFoundation have a timecode to give, and which one is it?"
func readAVFTimecode(_ asset: AVURLAsset) async -> (String, String)? {
    guard let track = try? await asset.loadTracks(withMediaType: .timecode).first else {
        return ("—", "no track of media type timecode")
    }
    guard let fmt = (try? await track.load(.formatDescriptions))?.first else {
        return ("—", "tmcd track present but has NO format description")
    }
    let quanta = CMTimeCodeFormatDescriptionGetFrameQuanta(fmt)
    let frameDuration = CMTimeCodeFormatDescriptionGetFrameDuration(fmt)
    let flags = CMTimeCodeFormatDescriptionGetTimeCodeFlags(fmt)
    let dropFrame = (flags & kCMTimeCodeFlag_DropFrame) != 0
    let base = "tmcd track, quanta \(quanta), frameDuration \(frameDuration.value)/\(frameDuration.timescale), dropFrame \(dropFrame)"
    guard let reader = try? AVAssetReader(asset: asset) else { return ("—", base + " — AVAssetReader init failed") }
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    guard reader.canAdd(out) else { return ("—", base + " — reader will not take a tmcd output") }
    reader.add(out)
    guard reader.startReading() else {
        return ("—", base + " — startReading failed: \(reader.error.map { "\(($0 as NSError).code)" } ?? "?")")
    }
    guard let sb = out.copyNextSampleBuffer() else {
        return ("—", base + " — the tmcd track vends NO SAMPLES (status \(reader.status.rawValue))")
    }
    guard let block = CMSampleBufferGetDataBuffer(sb) else {
        return ("—", base + " — first tmcd sample has no data buffer")
    }
    var length = 0
    var pointer: UnsafeMutablePointer<CChar>?
    guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                      totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
          let pointer, length >= 4 else { return ("—", base + " — tmcd sample shorter than 4 bytes") }
    let b = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
    let frames = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
    reader.cancelReading()
    let q = Int(quanta)
    guard q > 0 else { return ("—", base + " — frame quanta is 0") }
    // Non-drop labelling. Drop-frame label arithmetic is TimecodeReader's job; this prints the
    // raw start frame beside it so a drop-frame file cannot be silently mislabelled here.
    let ff = frames % q, ss = (frames / q) % 60, mm = (frames / (q * 60)) % 60, hh = frames / (q * 3600)
    let sep = dropFrame ? ";" : ":"
    let s = String(format: "%02d:%02d:%02d%@%02d", hh, mm, ss, sep, ff)
    let detail = "tmcd track, quanta \(q), frameDuration \(frameDuration.value)/\(frameDuration.timescale), "
        + "dropFrame \(dropFrame), startFrame \(frames)"
    return (s, detail)
}

func readAVFFacts(_ url: URL) -> AVFFacts {
    sync {
        var f = AVFFacts()
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.load(.tracks)
            f.opened = true
            f.durationSeconds = (try await asset.load(.duration)).seconds
            for t in tracks {
                var sub = "—"
                if let fd = (try? await t.load(.formatDescriptions))?.first {
                    sub = fourCCString(CMFormatDescriptionGetMediaSubType(fd))
                }
                f.trackSummary.append("\(t.mediaType.rawValue) \(sub)")
            }
        } catch {
            f.error = "\((error as NSError).code) \((error as NSError).localizedDescription)"
            return f
        }

        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            f.hasVideo = true
            f.nominalFrameRate = (try? await track.load(.nominalFrameRate)) ?? 0
            let mfd = (try? await track.load(.minFrameDuration)) ?? .invalid
            if mfd.isValid { f.minFrameDurationValue = mfd.value; f.minFrameDurationScale = mfd.timescale }
            f.videoDataRate = Double((try? await track.load(.estimatedDataRate)) ?? 0)
            f.naturalSize = (try? await track.load(.naturalSize)) ?? .zero
            if let fmt = (try? await track.load(.formatDescriptions))?.first {
                let sub = CMFormatDescriptionGetMediaSubType(fmt)
                f.codecFourCC = fourCCString(sub)
                f.codecName = sub == fourCC("AVdh") || sub == fourCC("AVdn") ? "DNxHR"
                    : sub == fourCC("apch") ? "ProRes 422 HQ"
                    : sub == fourCC("apcn") ? "ProRes 422"
                    : sub == fourCC("ap4h") ? "ProRes 4444" : fourCCString(sub)
                let dims = CMVideoFormatDescriptionGetDimensions(fmt)
                f.width = Int(dims.width); f.height = Int(dims.height)
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                let pres = CMVideoFormatDescriptionGetPresentationDimensions(
                    fmt, usePixelAspectRatio: true, useCleanAperture: true)
                let r = CGRect(origin: .zero, size: pres).applying(transform)
                f.presentationSize = CGSize(width: abs(r.width), height: abs(r.height))
                if let d = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? [CFString: Any],
                   let h = (d[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing] as? NSNumber)?.intValue,
                   let v = (d[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing] as? NSNumber)?.intValue {
                    f.paspPresent = true; f.paspH = h; f.paspV = v
                }
                if let d = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_CleanAperture) as? [CFString: Any],
                   let w = (d[kCMFormatDescriptionKey_CleanApertureWidth] as? NSNumber)?.doubleValue,
                   let h = (d[kCMFormatDescriptionKey_CleanApertureHeight] as? NSNumber)?.doubleValue {
                    f.clapPresent = true; f.clapW = w; f.clapH = h
                    f.clapHOff = (d[kCMFormatDescriptionKey_CleanApertureHorizontalOffset] as? NSNumber)?.doubleValue ?? 0
                    f.clapVOff = (d[kCMFormatDescriptionKey_CleanApertureVerticalOffset] as? NSNumber)?.doubleValue ?? 0
                }
                let c = avfColorCodes(fmt)
                f.primaries = c.0; f.primariesRaw = c.1
                f.transfer = c.2; f.transferRaw = c.3
                f.matrix = c.4; f.matrixRaw = c.5
                f.rangeState = avfRangeState(fmt)
            }
        }

        if let tc = await readAVFTimecode(asset) {
            f.hasTimecodeTrack = true; f.timecodeString = tc.0; f.timecodeDetail = tc.1
        }

        for track in (try? await asset.loadTracks(withMediaType: .audio)) ?? [] {
            var a = AVFAudioTrackFacts()
            a.trackID = track.trackID
            a.dataRate = Double((try? await track.load(.estimatedDataRate)) ?? 0)
            if let fmt = (try? await track.load(.formatDescriptions))?.first {
                a.codec = fourCCString(CMFormatDescriptionGetMediaSubType(fmt))
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
                    a.sampleRate = asbd.mSampleRate
                    a.channels = Int(asbd.mChannelsPerFrame)
                    a.bitDepth = Int(asbd.mBitsPerChannel)
                }
                var size = 0
                if let raw = CMAudioFormatDescriptionGetChannelLayout(fmt, sizeOut: &size), size >= 4 {
                    a.hasLayout = true
                    let tag = UnsafeRawPointer(raw).loadUnaligned(fromByteOffset: 0, as: AudioChannelLayoutTag.self)
                    a.layoutTag = tag == kAudioChannelLayoutTag_UseChannelDescriptions ? "UseChannelDescriptions"
                        : tag == kAudioChannelLayoutTag_UseChannelBitmap ? "UseChannelBitmap"
                        : "tag 0x\(String(tag, radix: 16))"
                }
                a.roles = layoutRoles(from: fmt) ?? []
                let l = audioLayout(from: fmt, channelCount: a.channels)
                a.layoutName = l.name; a.layoutConfidence = l.confidence
            }
            f.audio.append(a)
        }

        // CAPTIONS. Measured 2026-09-08: AppleMXFImport vends tmcd, vide and soun and NO clcp for
        // both DNxHR fixtures — so this enumeration is expected to come back empty and the harness
        // says so rather than testing for it. It is still enumerated, because a different file or a
        // future version of the reader would show up here and nowhere else.
        for (type, kind) in [(AVMediaType.closedCaption, "Closed Caption"),
                             (AVMediaType.subtitle, "Subtitle"),
                             (AVMediaType.text, "Timed Text")] {
            for track in (try? await asset.loadTracks(withMediaType: type)) ?? [] {
                var t = AVFTextTrackFacts()
                t.kind = kind
                if let fmt = (try? await track.load(.formatDescriptions))?.first {
                    t.subtype = fourCCString(CMFormatDescriptionGetMediaSubType(fmt))
                }
                t.language = ((try? await track.load(.languageCode)) ?? nil) ?? "—"
                f.text.append(t)
            }
        }
        return f
    }
}

// ═══════════════════════════════════════════════════════════════════════════════════════════
// MARK: - FACTS mode — three columns
//
// ⚠️ THREE, NOT TWO, AND THE MIDDLE ONE IS THE POINT. Several rows differ from AVFoundation only
// because `LibavFrameSource.StreamInfo` does not CARRY the field — libav has it to give and the
// app does not ask. Collapsing "what libav can report" into "what Manifold reports" would turn a
// known, documented gap (see `applyLibavMetadata`'s own comment on geometry) into a false finding
// about libav. Where the two libav columns differ, the gap is ours.
// ═══════════════════════════════════════════════════════════════════════════════════════════

let COL1 = 30, COL2 = 34, COL3 = 34

func factsHeader() {
    print("  " + pad("FACT", COL1) + pad("libav CAN report", COL2) + pad("Manifold libav path TODAY", COL3) + "AVFoundation reports")
    print("  " + String(repeating: "─", count: COL1 + COL2 + COL3 + 24))
}

func row(_ fact: String, _ canReport: String, _ today: String, _ avf: String) {
    print("  " + pad(fact, COL1) + pad(canReport, COL2) + pad(today, COL3) + avf)
}

func note(_ s: String) { print("      ⤷ \(s)") }

func runFacts(_ url: URL) {
    print("═══ FACTS — \(url.lastPathComponent)")
    print("")
    let lav = readLibavFacts(url)
    let avf = readAVFFacts(url)
    guard lav.opened else { print("  libav could not open: \(lav.error)"); return }
    print("  libav streams: \(lav.streamKinds.joined(separator: ", "))")
    print("  AVF tracks:    \(avf.opened ? avf.trackSummary.joined(separator: ", ") : "COULD NOT OPEN — \(avf.error)")")
    print("")
    factsHeader()

    // ── geometry ──────────────────────────────────────────────────────────────────────────
    row("encoded dimensions",
        "\(lav.parWidth)×\(lav.parHeight)",
        "\(lav.parWidth)×\(lav.parHeight)",
        avf.hasVideo ? "\(avf.width)×\(avf.height)" : "—")
    if avf.hasVideo && (avf.width != lav.parWidth || avf.height != lav.parHeight) {
        note("⚠️ MISMATCH — the two paths do not agree on the raster. Pixel mode will refuse to run.")
    }
    row("naturalSize (AVF only)", "n/a", "n/a",
        avf.hasVideo ? "\(Int(avf.naturalSize.width))×\(Int(avf.naturalSize.height))" : "—")
    row("presentation size", "not exposed", "= encoded (neither transform applied)",
        avf.hasVideo ? "\(Int(avf.presentationSize.width))×\(Int(avf.presentationSize.height))" : "—")

    row("clean aperture",
        "not surfaced by mxfdec",
        "CANNOT EXPRESS (.undeclared)",
        avf.clapPresent ? "\(Int(avf.clapW))×\(Int(avf.clapH)) @ \(avf.clapHOff),\(avf.clapVOff)" : "absent")
    if avf.clapPresent && (Int(avf.clapW) != avf.width || Int(avf.clapH) != avf.height) {
        note("⚠️ AVF DECLARES A CROP THE LIBAV PATH CANNOT SEE. On the AVF path the renderer would")
        note("   crop to it; on the libav path it would not. Same file, two rasters at the offscreen.")
    }

    // ⚠️ RAW RATIONALS, 0/1 INCLUDED. `rationalString` prints an unspecified SAR as
    // "0/1 — UNSPECIFIED, not 1:1" precisely so a "both paths say square" cannot be manufactured
    // out of one path having said nothing at all.
    row("pixel aspect (raw)",
        "codecpar " + rationalString(lav.sarNum, lav.sarDen),
        "CANNOT EXPRESS (.undeclared)",
        avf.paspPresent ? "pasp \(avf.paspH):\(avf.paspV) (DECLARED)" : "no pasp atom — undeclared")
    row("  stream SAR", "stream " + rationalString(lav.streamSarNum, lav.streamSarDen), "—", "—")

    // ── colour: CODES, not names ──────────────────────────────────────────────────────────
    func codeCell(_ code: Int?, _ raw: Int) -> String {
        guard let code else { return "nil (raw \(raw)\(raw == 2 ? " unspecified" : raw == 0 ? " reserved" : ""))" }
        return "\(code)"
    }
    func avfCodeCell(_ code: Int?, _ raw: String) -> String {
        guard let code else { return raw == "—" ? "nil (extension absent)" : "nil (unmapped \"\(raw)\")" }
        return "\(code)"
    }
    row("colour primaries (code)", codeCell(lav.primaries, lav.primariesRaw),
        codeCell(lav.primaries, lav.primariesRaw), avf.hasVideo ? avfCodeCell(avf.primaries, avf.primariesRaw) : "—")
    row("transfer (code)", codeCell(lav.transfer, lav.transferRaw),
        codeCell(lav.transfer, lav.transferRaw), avf.hasVideo ? avfCodeCell(avf.transfer, avf.transferRaw) : "—")
    row("matrix (code)", codeCell(lav.matrix, lav.matrixRaw),
        codeCell(lav.matrix, lav.matrixRaw), avf.hasVideo ? avfCodeCell(avf.matrix, avf.matrixRaw) : "—")
    note("names for reference — libav \(primariesName(lav.primaries))/\(transferName(lav.transfer))/\(matrixName(lav.matrix))"
         + "   AVF \(primariesName(avf.primaries))/\(transferName(avf.transfer))/\(matrixName(avf.matrix))")
    if lav.primaries != avf.primaries || lav.transfer != avf.transfer || lav.matrix != avf.matrix {
        note("⚠️ CODE MISMATCH — one path recognised a UL the other did not. Coverage, not contradiction;")
        note("   check which side has nil before calling either wrong.")
    }

    // ⚠️ THE RAW ENUM BESIDE THE BOOLEAN — this is the three-state collapse made visible.
    let manifoldRange = lav.colorRangeEnum == AVCOL_RANGE_JPEG.rawValue ? "Full" : "Video (Legal)"
    row("colour range", lav.colorRangeRaw, "\(manifoldRange)  (isFullRange bool)",
        avf.hasVideo ? avf.rangeState : "—")
    let avfRangeDisagrees = avf.hasVideo && avf.rangeState != manifoldRange
    if avfRangeDisagrees {
        note("⚠️ THE TWO PATHS DISAGREE ABOUT RANGE — libav \(lav.colorRangeRaw), AVFoundation \(avf.rangeState).")
        note("   \"Untagged\" and \"Video (Legal)\" are different statements: one is the file declining to")
        note("   say, the other is the file saying legal. The engine's range flag is derived from this.")
    }
    if lav.colorRangeEnum != AVCOL_RANGE_JPEG.rawValue && lav.colorRangeEnum != AVCOL_RANGE_MPEG.rawValue {
        note("⚠️ THREE STATES COLLAPSED TO TWO. libav says UNSPECIFIED; `isFullRange = (range == JPEG)`")
        note("   makes that false, and `applyLibavMetadata` prints false as \"Video (Legal)\". The libav")
        note("   path has no \"Untagged\" — the honesty `SourceColorRange` keeps on the AVF path is lost.")
    }

    // ── rate ──────────────────────────────────────────────────────────────────────────────
    // ⚠️ RATIONAL AGAINST CMTime, NOT Double AGAINST Double. nominalFrameRate is a Float32 and
    // 23.976 comes back as 23.976023…; comparing doubles needs a tolerance that hides whether the
    // file is 24000/1001 or 23.98.
    // ⚠️ AN ABSENT minFrameDuration IS A FACT ABOUT THE READER, NOT A BLANK CELL. Printing "—"
    // here would read as "not compared" when what happened is that AVFoundation declined to state
    // an exact rate and only the Float32 nominal is available.
    let avfRate = avf.minFrameDurationScale > 0
        ? "\(avf.minFrameDurationScale)/\(avf.minFrameDurationValue)"
        : "no minFrameDuration; nominal \(avf.nominalFrameRate)"
    row("frame rate (rational)", "\(lav.frameRateNum)/\(lav.frameRateDen)",
        String(format: "%.6f (Double)", lav.frameRateDen != 0 ? Double(lav.frameRateNum) / Double(lav.frameRateDen) : 0),
        avfRate)
    if avf.minFrameDurationScale > 0 {
        let a = Double(lav.frameRateNum) * Double(avf.minFrameDurationValue)
        let b = Double(lav.frameRateDen) * Double(avf.minFrameDurationScale)
        note(abs(a - b) < 1e-9 ? "rationals are EQUAL (cross-multiplied exactly — no tolerance used)"
                               : "⚠️ rationals DIFFER: libav \(lav.frameRateNum)/\(lav.frameRateDen) vs AVF \(avf.minFrameDurationScale)/\(avf.minFrameDurationValue)")
    } else if avf.hasVideo {
        note("⚠️ AVFoundation vends NO minFrameDuration for this file, so the exact-rational comparison")
        note("   is unavailable and only the Float32 nominal can be compared.")
        let nominal = Double(avf.nominalFrameRate)
        let exact = lav.frameRateDen != 0 ? Double(lav.frameRateNum) / Double(lav.frameRateDen) : 0
        note(String(format: "   nominal %.6f vs libav %.6f — differ by %.2e (Float32 rounding is ~1e-6 here)",
                    nominal, exact, abs(nominal - exact)))
    }
    if avf.hasVideo { note("nominalFrameRate (Float32) = \(avf.nominalFrameRate)") }
    row("duration (s)", String(format: "%.3f", lav.durationSeconds),
        String(format: "%.3f", lav.durationSeconds),
        avf.opened ? String(format: "%.3f", avf.durationSeconds) : "—")

    // ── codec + rate ──────────────────────────────────────────────────────────────────────
    row("codec", "\(lav.codecName) / \(lav.codecProfile)", lav.codecName,
        avf.hasVideo ? "\(avf.codecFourCC) → \(avf.codecName)" : "—")
    row("source pixel format", lav.pixFmt, "not reported", "not reported (decoder-internal)")

    var fileSize: Int64 = 0
    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
        fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }
    // ⚠️ COPIED FROM `applyLibavMetadata` — file size × 8 ÷ duration. NOT a per-track number, and
    // therefore NOT the same quantity AVFoundation reports.
    let manifoldRate = (fileSize > 0 && lav.durationSeconds > 0) ? Double(fileSize) * 8 / lav.durationSeconds : 0
    row("video data rate",
        lav.videoBitRate > 0 ? String(format: "%.1f Mb/s (codecpar)", Double(lav.videoBitRate) / 1e6) : "0 (codecpar unset)",
        String(format: "%.1f Mb/s (file÷dur)", manifoldRate / 1e6),
        avf.hasVideo ? (avf.videoDataRate > 0
            ? String(format: "%.1f Mb/s (est., per-track)", avf.videoDataRate / 1e6)
            : "0 — reader supplies no estimate") : "—")
    note("DIFFERENT QUANTITIES BY CONSTRUCTION — the middle column includes audio, ANC and container overhead.")

    // ── timecode ──────────────────────────────────────────────────────────────────────────
    row("start timecode", lav.startTimecode ?? "none", lav.startTimecode ?? "none",
        avf.timecodeString ?? (avf.hasTimecodeTrack ? "tmcd present, unreadable" : "no tmcd track"))
    note("libav source: \(lav.timecodeSource)")
    if avf.hasTimecodeTrack { note("AVF: \(avf.timecodeDetail)") }
    note("⚠️ Manifold's own AVF timecode reader is a MOV ATOM WALK (`TimecodeReader.readStartTimecode`)")
    note("   and returns nil for MXF whatever the reader vends. The AVF column above is THIS harness.")

    // ── audio ─────────────────────────────────────────────────────────────────────────────
    print("")
    row("audio track count", "\(lav.audio.count) AVStream(s)", "\(lav.audio.count) row(s)",
        avf.opened ? "\(avf.audio.count) AVAssetTrack(s)" : "—")
    if avf.opened && avf.audio.count != lav.audio.count {
        note("⚠️ COUNTS DIFFER — this says nothing yet about whether it is the same audio grouped")
        note("   differently. MODE=audio is the only thing that can answer that.")
    }
    for (i, a) in lav.audio.enumerated() {
        let roles = a.roles.isEmpty ? "no roles" : a.roles.joined(separator: " ")
        row("  libav #\(a.streamIndex) (row \(i))",
            "\(a.channels)ch \(a.layoutDescribe) [\(a.channelOrder)]",
            "\(a.layoutName) · \(a.layoutConfidence)", roles)
    }
    for (i, a) in avf.audio.enumerated() {
        let roles = a.roles.isEmpty ? "no roles" : a.roles.joined(separator: " ")
        row("  AVF track \(i) (id \(a.trackID))", "—",
            "—", "\(a.channels)ch \(a.codec) \(a.layoutName) · \(a.layoutConfidence) · \(roles) [\(a.hasLayout ? a.layoutTag : "NO LAYOUT")]")
    }

    // ── captions ──────────────────────────────────────────────────────────────────────────
    print("")
    row("SMPTE 436M ANC", lav.hasANC ? "stream #\(lav.ancStreamIndex)" : "none",
        lav.hasANC ? "CaptionPresenceReader reads it" : "none",
        "NO ANC MEDIA TYPE EXISTS")
    note("MEASURED 2026-09-08: AppleMXFImport vends tmcd, vide, soun and NO clcp. AVFoundation has")
    note("no route to a 436M element — the caption work depends on libav whichever path decodes.")
    row("AVF caption/text tracks", "n/a", "n/a",
        avf.text.isEmpty ? "none (as expected)" : avf.text.map { "\($0.kind) \($0.subtype) \($0.language)" }.joined(separator: ", "))
    if !avf.text.isEmpty {
        note("⚠️ A READER VENDED CAPTION TRACKS. This is new — the 2026-09-08 measurement found none.")
        note("   Compare its rows against CaptionPresenceReader before trusting either.")
    }
    print("")
}

// ═══════════════════════════════════════════════════════════════════════════════════════════
// MARK: - The decode contract, and the two decoders
// ═══════════════════════════════════════════════════════════════════════════════════════════

/// ⚠️ COPIED FROM `FrameEngine.videoPixelFormat`. Both paths are asked for THIS and nothing else.
/// The comparison is at the app's own contract not because it is neutral — it is not, it discards
/// 444 chroma and two bits — but because it is what the scopes, the v210 convert and the frame
/// export actually read. A difference here is a difference in the instrument.
let CONTRACT_FORMAT = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

struct DecodedFrame {
    let pixelBuffer: CVPixelBuffer
    let pts: CMTime
}

/// libav → x420, through the app's own conversion.
///
/// ⚠️ `fillPixelBuffer` IS COPIED VERBATIM FROM `LibavPixelConversion`, INCLUDING THE LINE THAT
/// FORCES SRC AND DST RANGE EQUAL. That line looks like a no-op and is load-bearing: it tells
/// swscale not to remap legal↔full, because the SHADER does the expansion. A harness that let
/// swscale expand would report an affine relation between the two paths that the app does not have.
final class LibavPathDecoder {
    private var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var pkt: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var videoStreamIndex: Int32 = -1
    private var timeBase = AVRational(num: 1, den: 600)
    private var startTimeTicks: Int64 = 0
    private var pool: CVPixelBufferPool?
    private(set) var sourcePixFmt = "?"
    private(set) var width = 0, height = 0

    func open(_ url: URL) -> String? {
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&ctx, url.path, nil, nil) == 0, ctx != nil else { return "open_input failed" }
        guard avformat_find_stream_info(ctx, nil) >= 0 else { return "find_stream_info failed" }
        var vIdx: Int32 = -1
        var par: UnsafeMutablePointer<AVCodecParameters>?
        var stream: UnsafeMutablePointer<AVStream>?
        for i in 0..<Int(ctx!.pointee.nb_streams) {
            guard let st = ctx!.pointee.streams[i] else { continue }
            if st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO, vIdx < 0 {
                vIdx = Int32(i); par = st.pointee.codecpar; stream = st
            }
        }
        guard vIdx >= 0, let par, let stream else { return "no video stream" }
        guard let codec = avcodec_find_decoder(par.pointee.codec_id) else { return "no decoder" }
        guard let cctx = avcodec_alloc_context3(codec) else { return "alloc context failed" }
        avcodec_parameters_to_context(cctx, par)
        cctx.pointee.thread_count = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        guard avcodec_open2(cctx, codec, nil) == 0 else { return "avcodec_open2 failed" }
        fmtCtx = ctx; codecCtx = cctx
        pkt = av_packet_alloc(); frame = av_frame_alloc()
        videoStreamIndex = vIdx
        timeBase = stream.pointee.time_base
        startTimeTicks = stream.pointee.start_time == Int64.min ? 0 : stream.pointee.start_time
        width = Int(par.pointee.width); height = Int(par.pointee.height)
        sourcePixFmt = av_get_pix_fmt_name(AVPixelFormat(par.pointee.format)).map { String(cString: $0) } ?? "?"
        return nil
    }

    deinit {
        if codecCtx != nil { avcodec_free_context(&codecCtx) }
        if fmtCtx != nil { avformat_close_input(&fmtCtx) }
        if pkt != nil { av_packet_free(&pkt) }
        if frame != nil { av_frame_free(&frame) }
    }

    func next() -> DecodedFrame? {
        guard let fmtCtx, let codecCtx, let pkt, let frame else { return nil }
        while true {
            let ret = avcodec_receive_frame(codecCtx, frame)
            if ret == 0 {
                let ts = frame.pointee.best_effort_timestamp != Int64.min
                    ? frame.pointee.best_effort_timestamp : frame.pointee.pts
                let pts = CMTime(value: (ts - startTimeTicks) * Int64(timeBase.num), timescale: timeBase.den)
                let out = convert(frame).map { DecodedFrame(pixelBuffer: $0, pts: pts) }
                av_frame_unref(frame)
                return out
            }
            if ret != -Int32(EAGAIN) { return nil }
            let rret = av_read_frame(fmtCtx, pkt)
            if rret < 0 { _ = avcodec_send_packet(codecCtx, nil); continue }
            if pkt.pointee.stream_index == videoStreamIndex { _ = avcodec_send_packet(codecCtx, pkt) }
            av_packet_unref(pkt)
        }
    }

    private func convert(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let W = Int(frame.pointee.width), H = Int(frame.pointee.height)
        if pool == nil {
            let pbAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: CONTRACT_FORMAT,
                kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]() as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            var p: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary,
                                          pbAttrs as CFDictionary, &p) == kCVReturnSuccess else { return nil }
            pool = p
        }
        var pb: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess,
              let pixelBuffer = pb else { return nil }
        // ⚠️ COPIED FROM LibavPixelConversion.fillPixelBuffer
        let srcFmt = AVPixelFormat(frame.pointee.format)
        guard let sws = sws_getContext(Int32(W), Int32(H), srcFmt, Int32(W), Int32(H),
                                       AV_PIX_FMT_P010LE, Int32(SWS_BILINEAR.rawValue), nil, nil, nil) else { return nil }
        defer { sws_freeContext(sws) }
        let coeff = sws_getCoefficients(SWS_CS_ITU709)
        let r: Int32 = (frame.pointee.color_range == AVCOL_RANGE_JPEG) ? 1 : 0
        _ = sws_setColorspaceDetails(sws, coeff, r, coeff, r, 0, 1 << 16, 1 << 16)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let srcData: [UnsafePointer<UInt8>?] = [
            UnsafePointer(frame.pointee.data.0), UnsafePointer(frame.pointee.data.1),
            UnsafePointer(frame.pointee.data.2), UnsafePointer(frame.pointee.data.3)]
        var srcStride: [Int32] = [frame.pointee.linesize.0, frame.pointee.linesize.1,
                                  frame.pointee.linesize.2, frame.pointee.linesize.3]
        var dst: [UnsafeMutablePointer<UInt8>?] = [
            CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
            CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self), nil, nil]
        var dstStride: [Int32] = [Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)),
                                  Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)), 0, 0]
        let scaled = sws_scale(sws, srcData, &srcStride, 0, Int32(H), &dst, &dstStride)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return scaled > 0 ? pixelBuffer : nil
    }
}

/// AVFoundation → x420, through `AVAssetReader`. The registration calls have already run.
final class AVFPathDecoder {
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?

    func open(_ url: URL) -> String? {
        let asset = AVURLAsset(url: url)
        return sync {
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return "no video track" }
            guard let r = try? AVAssetReader(asset: asset) else { return "AVAssetReader init failed" }
            let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: CONTRACT_FORMAT])
            guard r.canAdd(o) else { return "cannot add output" }
            r.add(o)
            guard r.startReading() else {
                return "startReading failed — \(r.error.map { "\(($0 as NSError).code)" } ?? "?")"
            }
            self.reader = r; self.output = o
            return nil
        }
    }

    func next() -> DecodedFrame? {
        guard let output, let sb = output.copyNextSampleBuffer(),
              let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
        return DecodedFrame(pixelBuffer: pb, pts: CMSampleBufferGetPresentationTimeStamp(sb))
    }

    func cancel() { reader?.cancelReading() }
}

// ═══════════════════════════════════════════════════════════════════════════════════════════
// MARK: - Plane comparison
// ═══════════════════════════════════════════════════════════════════════════════════════════

/// One plane read back as 10-bit code values. x420 stores 10 bits in the HIGH bits of each UInt16,
/// so every sample is shifted down by 6 — getting this wrong is a bit-depth shift that the affine
/// fit would report as a ≈4× or ≈¼× gain, which is why the fit is worth having even for a harness bug.
struct Plane {
    let width: Int, height: Int, componentsPerSample: Int
    var samples: [UInt16]

    static func read(_ pb: CVPixelBuffer, plane: Int, componentsPerSample: Int) -> Plane? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, plane)
        let h = CVPixelBufferGetHeightOfPlane(pb, plane)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
        var out = [UInt16](repeating: 0, count: w * h * componentsPerSample)
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
            for x in 0..<(w * componentsPerSample) { out[y * w * componentsPerSample + x] = row[x] >> 6 }
        }
        return Plane(width: w, height: h, componentsPerSample: componentsPerSample, samples: out)
    }
}

struct PlaneStats {
    var count = 0
    var exact = 0
    var maxDelta = 0
    var maxAtX = 0, maxAtY = 0
    var p50 = 0, p99 = 0, p999 = 0
    var meanA = 0.0, meanB = 0.0
    var affineA = 1.0, affineB = 0.0, affineResidual = 0.0

    var exactPercent: Double { count > 0 ? 100.0 * Double(exact) / Double(count) : 0 }
}

/// Compare two planes, and FIT `b ≈ a·x + β` while doing it.
///
/// ⚠️ THE FIT IS THE POINT, NOT THE PASS/FAIL. A pass/fail number says they differ; the fit says
/// HOW, in one line:
///   a ≈ 219/255 with β ≈ 64   → one path applied a legal↔full RANGE REMAP
///   a ≈ 1, β ≈ 0, flat residual → a rounding difference (12→10 bit), expect ≤1 code
///   a ≈ 1, β ≈ 0, residual at edges only → the CHROMA FILTER, which is expected and not a defect
///   a ≈ 4 or ≈ ¼            → a BIT-DEPTH SHIFT, and it is probably this harness, not the file
func comparePlanes(_ a: Plane, _ b: Plane, mask: [Bool]? = nil) -> PlaneStats? {
    guard a.width == b.width, a.height == b.height,
          a.componentsPerSample == b.componentsPerSample else { return nil }
    var s = PlaneStats()
    var deltas: [Int] = []
    deltas.reserveCapacity(a.samples.count)
    var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
    let perRow = a.width * a.componentsPerSample
    for i in 0..<a.samples.count {
        if let mask, !mask[i / a.componentsPerSample] { continue }
        let x = Double(a.samples[i]), y = Double(b.samples[i])
        let d = abs(Int(a.samples[i]) - Int(b.samples[i]))
        if d == 0 { s.exact += 1 }
        if d > s.maxDelta { s.maxDelta = d; s.maxAtX = (i % perRow) / a.componentsPerSample; s.maxAtY = i / perRow }
        deltas.append(d)
        sx += x; sy += y; sxx += x * x; sxy += x * y
        s.count += 1
    }
    guard s.count > 0 else { return s }
    let n = Double(s.count)
    s.meanA = sx / n; s.meanB = sy / n
    let den = n * sxx - sx * sx
    if abs(den) > 1e-9 {
        s.affineA = (n * sxy - sx * sy) / den
        s.affineB = (sy - s.affineA * sx) / n
    }
    var resid = 0.0
    for i in 0..<a.samples.count {
        if let mask, !mask[i / a.componentsPerSample] { continue }
        let predicted = s.affineA * Double(a.samples[i]) + s.affineB
        let e = Double(b.samples[i]) - predicted
        resid += e * e
    }
    s.affineResidual = (resid / n).squareRoot()
    deltas.sort()
    s.p50 = deltas[deltas.count / 2]
    s.p99 = deltas[min(deltas.count - 1, Int(Double(deltas.count) * 0.99))]
    s.p999 = deltas[min(deltas.count - 1, Int(Double(deltas.count) * 0.999))]
    return s
}

/// Flat vs edge, from the LOCAL GRADIENT of the reference plane.
///
/// ⚠️ THIS IS WHAT SEPARATES "THE FILTER" FROM "WRONG". Any 444→420 downsample filter disagrees at
/// edges; NO filter may disagree on a flat field. Reporting one number over the whole frame cannot
/// tell those apart, so the chroma comparison is run twice against this mask.
func gradientMask(_ p: Plane, threshold: Int, flat: Bool) -> [Bool] {
    var mask = [Bool](repeating: false, count: p.width * p.height)
    let c = p.componentsPerSample
    for y in 0..<p.height {
        for x in 0..<p.width {
            // ⚠️ THE GRADIENT IS TAKEN OVER EVERY COMPONENT, NOT JUST THE FIRST — CAUGHT BY THE
            // CALIBRATION GATE, 2026-09-08. The x420 chroma plane is INTERLEAVED CbCr, and an
            // earlier version measured the gradient on Cb alone while comparing both components.
            // A sample flat in Cb but sitting on a Cr edge was therefore classified "flat" and its
            // Cr difference counted against the flat-field tolerance: the ProRes calibration
            // reported max |Δ| 14 on a "flat" field with p99 = 1, which is an edge population
            // leaking into the flat one. A pixel is flat only where EVERY component is flat.
            let i = (y * p.width + x) * c
            var g = 0
            for k in 0..<c {
                let here = Int(p.samples[i + k])
                let right = x + 1 < p.width ? Int(p.samples[i + c + k]) : here
                let down = y + 1 < p.height ? Int(p.samples[i + p.width * c + k]) : here
                g = max(g, abs(here - right) + abs(here - down))
            }
            mask[y * p.width + x] = flat ? (g <= threshold) : (g > threshold)
        }
    }
    return mask
}

func maskCount(_ m: [Bool]) -> Int { m.reduce(0) { $0 + ($1 ? 1 : 0) } }

/// The difference plane, as an 8-bit PGM. No dependencies, and any image viewer opens it.
/// ⚠️ STRUCTURE IN THIS IMAGE IS THE TELL. A flat grey field is a uniform offset; edges are a
/// filter; a gradient is a range remap; a shape is a decoder disagreement.
func writeDifferencePGM(_ a: Plane, _ b: Plane, scale: Int, to path: String) {
    var header = "P5\n\(a.width) \(a.height)\n255\n"
    var bytes = [UInt8]()
    bytes.reserveCapacity(a.width * a.height)
    let c = a.componentsPerSample
    for i in stride(from: 0, to: a.samples.count, by: c) {
        let d = abs(Int(a.samples[i]) - Int(b.samples[i])) * scale
        bytes.append(UInt8(min(255, d)))
    }
    var data = Data(header.utf8)
    data.append(contentsOf: bytes)
    try? data.write(to: URL(fileURLWithPath: path))
    header = ""
}

// ═══════════════════════════════════════════════════════════════════════════════════════════
// MARK: - Known-incorrect registry
//
// ⚠️ A DECODER THAT HAS ALREADY SAID IT COULD NOT DECODE THE FILE IS NOT A CANDIDATE FOR
// AGREEMENT. `Mixed Captions.mxf` is DNxHR 444 12-bit with a variable ACT flag; libav's dnxhd
// decoder refuses it (`Unsupported: variable ACT flag.`, identical across FFmpeg 5.2 → 8.1.1 →
// trunk) and renders it green and magenta, while the Avid plug-in decoder handles it. Running a
// tolerance analysis on that pair would imply the two are candidates for agreement. They are not:
// libav is WRONG and the expected result is a gross difference.
// ═══════════════════════════════════════════════════════════════════════════════════════════

struct KnownIncorrect {
    let reason: String
    let evidence: String
}

/// PRIMARY evidence is the decoder's own complaint, captured off the libav log. The 444 heuristic
/// is a SECONDARY net for a build that has gone quiet — it names what it matched so a false
/// positive is visible rather than silent.
func detectLibavKnownIncorrect(sourcePixFmt: String, codecName: String) -> KnownIncorrect? {
    let act = LibavLog.matching("ACT")
    if !act.isEmpty {
        return KnownIncorrect(reason: "libav's decoder reported it cannot handle this file",
                              evidence: "libav log: \"\(act.joined(separator: " / "))\"")
    }
    let is444 = sourcePixFmt.contains("444")
    if is444, codecName.lowercased().contains("dnx") || codecName == "dnxhd" {
        return KnownIncorrect(reason: "DNxHR 4:4:4 — the variable-ACT profile libav refuses",
                              evidence: "source pixel format \(sourcePixFmt) (heuristic; the decoder logged nothing)")
    }
    return nil
}

// ═══════════════════════════════════════════════════════════════════════════════════════════
// MARK: - PIXELS
// ═══════════════════════════════════════════════════════════════════════════════════════════

struct PixelResult {
    var ran = false
    var abortReason: String?
    var frames = 0
    var lumaStats: PlaneStats?
    var chromaAll: PlaneStats?
    var chromaFlat: PlaneStats?
    var chromaEdge: PlaneStats?
    var flatCount = 0, edgeCount = 0
    var knownIncorrect: KnownIncorrect?
    var libavRaster = "—", avfRaster = "—"
    var ptsLines: [String] = []
    var dumps: [String] = []
}

func comparePixels(_ url: URL, frames wanted: Int, outDir: String, label: String) -> PixelResult {
    var result = PixelResult()
    LibavLog.reset()

    let lav = LibavPathDecoder()
    if let err = lav.open(url) { result.abortReason = "libav: \(err)"; return result }
    let avfDec = AVFPathDecoder()
    if let err = avfDec.open(url) { result.abortReason = "AVFoundation: \(err)"; return result }
    defer { avfDec.cancel() }

    var lumaA: Plane?, lumaB: Plane?, chromaA: Plane?, chromaB: Plane?
    var n = 0
    while n < wanted {
        guard let lf = lav.next() else { break }
        guard let af = avfDec.next() else { break }

        // ⚠️ RASTER FIRST, AND ABORT RATHER THAN COMPARE. Comparing a cropped rect against a full
        // raster produces plausible-looking numbers for two different pictures. If the sizes
        // differ, the clean-aperture row in FACTS is the finding, not anything here.
        let lw = CVPixelBufferGetWidth(lf.pixelBuffer), lh = CVPixelBufferGetHeight(lf.pixelBuffer)
        let aw = CVPixelBufferGetWidth(af.pixelBuffer), ah = CVPixelBufferGetHeight(af.pixelBuffer)
        result.libavRaster = "\(lw)×\(lh)"; result.avfRaster = "\(aw)×\(ah)"
        if lw != aw || lh != ah {
            result.abortReason = "RASTER MISMATCH — libav \(lw)×\(lh) vs AVFoundation \(aw)×\(ah). "
                + "Refusing to compare: see the clean-aperture row in MODE=facts."
            return result
        }

        // ⚠️ PTS BEFORE PIXELS. A frame-count or start-PTS disagreement is a bigger finding than
        // any code value, and comparing frame k to frame k without checking would hide it.
        let ls = lf.pts.seconds, asec = af.pts.seconds
        let agree = abs(ls - asec) < 1e-6
        result.ptsLines.append(String(format: "frame %d — libav %.6f s (%d/%d)  AVF %.6f s (%d/%d)  %@",
                                      n, ls, lf.pts.value, lf.pts.timescale,
                                      asec, af.pts.value, af.pts.timescale,
                                      agree ? "match" : "⚠️ DIFFER"))

        if n == 0 {
            lumaA = Plane.read(lf.pixelBuffer, plane: 0, componentsPerSample: 1)
            lumaB = Plane.read(af.pixelBuffer, plane: 0, componentsPerSample: 1)
            chromaA = Plane.read(lf.pixelBuffer, plane: 1, componentsPerSample: 2)
            chromaB = Plane.read(af.pixelBuffer, plane: 1, componentsPerSample: 2)
        }
        n += 1
    }
    result.frames = n
    guard n > 0, let lumaA, let lumaB, let chromaA, let chromaB else {
        result.abortReason = result.abortReason ?? "no frames decoded by one or both paths"
        return result
    }
    result.ran = true

    result.knownIncorrect = detectLibavKnownIncorrect(sourcePixFmt: lav.sourcePixFmt, codecName: "dnxhd")
    result.lumaStats = comparePlanes(lumaA, lumaB)
    result.chromaAll = comparePlanes(chromaA, chromaB)

    // Gradient segmentation on the AVFoundation chroma — the reference, since on the fixtures where
    // this matters libav is the path under suspicion.
    let flatThreshold = envInt("FLAT_T", 4)
    let flat = gradientMask(chromaB, threshold: flatThreshold, flat: true)
    let edge = gradientMask(chromaB, threshold: flatThreshold, flat: false)
    result.flatCount = maskCount(flat); result.edgeCount = maskCount(edge)
    result.chromaFlat = comparePlanes(chromaA, chromaB, mask: flat)
    result.chromaEdge = comparePlanes(chromaA, chromaB, mask: edge)

    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let scale = envInt("PGM_SCALE", 8)
    let lumaPath = "\(outDir)/\(label)-luma-diff-x\(scale).pgm"
    let chromaPath = "\(outDir)/\(label)-chroma-diff-x\(scale).pgm"
    writeDifferencePGM(lumaA, lumaB, scale: scale, to: lumaPath)
    writeDifferencePGM(chromaA, chromaB, scale: scale, to: chromaPath)
    result.dumps = [lumaPath, chromaPath]
    return result
}

func printPlaneStats(_ title: String, _ s: PlaneStats?, indent: String = "    ") {
    guard let s, s.count > 0 else { print("\(indent)\(title): no samples"); return }
    print("\(indent)\(title)")
    print("\(indent)  samples \(s.count)   exact \(String(format: "%.4f", s.exactPercent))%   "
        + "max |Δ| \(s.maxDelta) at (\(s.maxAtX),\(s.maxAtY))")
    print("\(indent)  |Δ| p50 \(s.p50)   p99 \(s.p99)   p99.9 \(s.p999)   "
        + "means libav \(String(format: "%.1f", s.meanA)) / AVF \(String(format: "%.1f", s.meanB))")
    print("\(indent)  affine fit  AVF ≈ \(String(format: "%.6f", s.affineA))·libav + \(String(format: "%.2f", s.affineB))"
        + "   residual RMS \(String(format: "%.3f", s.affineResidual))")
    // The interpretations the fit exists to distinguish, named rather than left to the reader.
    if abs(s.affineA - 1) > 0.02 {
        if abs(s.affineA - 4) < 0.4 || abs(s.affineA - 0.25) < 0.05 {
            print("\(indent)  ⤷ ⚠️ gain ≈ 4× or ¼× — a BIT-DEPTH SHIFT. Suspect this harness before the file.")
        } else if abs(s.affineA - (219.0 / 255.0)) < 0.03 || abs(s.affineA - (255.0 / 219.0)) < 0.04 {
            print("\(indent)  ⤷ ⚠️ gain ≈ 219/255 — a LEGAL↔FULL RANGE REMAP. One path remapped; the app's")
            print("\(indent)     contract says neither should (the shader expands).")
        } else {
            print("\(indent)  ⤷ ⚠️ gain is not 1 — the two paths are not on the same scale.")
        }
    } else if abs(s.affineB) > 1.0 {
        print("\(indent)  ⤷ ⚠️ offset ≈ \(String(format: "%.1f", s.affineB)) code values at unit gain — a level shift.")
    }
}

func runPixels(_ url: URL, frames: Int, outDir: String, floor: CalibrationFloor) {
    print("═══ PIXELS — \(url.lastPathComponent)")
    let label = url.deletingPathExtension().lastPathComponent
        .replacingOccurrences(of: " ", with: "_")
    let r = comparePixels(url, frames: frames, outDir: outDir, label: label)
    print("  raster: libav \(r.libavRaster)   AVFoundation \(r.avfRaster)")
    if let abort = r.abortReason {
        print("  ⛔️ ABORTED — \(abort)")
        print("")
        return
    }
    for line in r.ptsLines { print("  \(line)") }
    print("  frames compared: \(r.frames)")
    print("")

    if let k = r.knownIncorrect {
        // ⚠️ NO TOLERANCE ANALYSIS HERE, AND THAT IS DELIBERATE.
        print("  ⛔️ libav IS KNOWN-INCORRECT ON THIS FIXTURE — \(k.reason)")
        print("     evidence: \(k.evidence)")
        print("")
        print("  The two paths are NOT candidates for agreement on this file, so no tolerance")
        print("  analysis is reported. The difference below is the SIZE of a known defect, not a")
        print("  measurement of two decoders disagreeing. AVFoundation (the Avid plug-in decoder)")
        print("  is the correct one here; libav renders this green and magenta.")
        print("")
        if let l = r.lumaStats, let c = r.chromaAll {
            print("     luma   exact \(String(format: "%.2f", l.exactPercent))%  max |Δ| \(l.maxDelta)  "
                + "means libav \(String(format: "%.1f", l.meanA)) / AVF \(String(format: "%.1f", l.meanB))")
            print("     chroma exact \(String(format: "%.2f", c.exactPercent))%  max |Δ| \(c.maxDelta)  "
                + "means libav \(String(format: "%.1f", c.meanA)) / AVF \(String(format: "%.1f", c.meanB))")
        }
        for d in r.dumps { print("     wrote \(d)") }
        print("")
        return
    }

    // Two correct decoders: the tolerance analysis the design was written for.
    print("  Both decoders are believed correct on this file — tolerance analysis applies.")
    print("")
    printPlaneStats("LUMA — expect exact, or |Δ| ≤ 1 with NO spatial structure", r.lumaStats)
    print("")
    printPlaneStats("CHROMA, whole plane — 444/422→420 subsample, so edges will differ", r.chromaAll)
    print("")
    printPlaneStats("CHROMA, FLAT regions only (\(r.flatCount) samples) — MUST be within 1 code", r.chromaFlat)
    print("")
    printPlaneStats("CHROMA, EDGE regions only (\(r.edgeCount) samples) — the filter lives here", r.chromaEdge)
    print("")
    // The verdict, stated as the design states it.
    // ⚠️ JUDGED AGAINST THE MEASURED FLOOR, NOT AGAINST A CONSTANT. The floor came from a file
    // both decoders get right, through this same contract and this same harness, minutes ago.
    if let l = r.lumaStats, let flat = r.chromaFlat {
        let lumaOK = l.maxDelta <= max(1, floor.lumaMax)
        let flatOK = flat.count == 0 || flat.maxDelta <= max(1, floor.chromaFlatMax)
        print("  VERDICT — against the floor measured on \(floor.file)")
        print("    luma        \(lumaOK ? "PASS" : "⚠️ FAIL") — max |Δ| \(l.maxDelta), floor \(floor.lumaMax)")
        if !lumaOK {
            print("      ⤷ Two intra decoders that neither resample nor remap luma should not differ here.")
            print("        Read the difference plane: STRUCTURE means a decoder disagreement, a flat field")
            print("        means a level shift, a gradient means a range remap.")
        }
        print("    chroma flat \(flatOK ? "PASS" : "⚠️ FAIL") — max |Δ| \(flat.maxDelta) (p99.9 \(flat.p999)), floor \(floor.chromaFlatMax) (p99.9 \(floor.chromaFlatP999))")
        if !flatOK {
            print("      ⤷ Exceeds what two correct decoders differ by on a flat field. A downsample")
            print("        filter cannot explain a flat-field difference; this is a real disagreement.")
        }
        if let edge = r.chromaEdge {
            print("    chroma edge — max |Δ| \(edge.maxDelta), p99.9 \(edge.p999)  (NOT a pass/fail: this is")
            print("      where the 422/444→420 filter difference lives and it is expected to be non-zero)")
        }
    }
    for d in r.dumps { print("    wrote \(d)  (|Δ| × \(envInt("PGM_SCALE", 8)), 8-bit PGM — look for STRUCTURE)") }
    print("")
}

/// What a run of the harness against two decoders KNOWN to be correct actually measures.
///
/// ⚠️ THE FLOOR IS MEASURED, NOT ASSUMED, AND THAT IS THE WHOLE REASON CALIBRATION IS A GATE.
/// The first version of this asserted a hardcoded "flat chroma within 1 code" and the ProRes
/// calibration failed at max |Δ| 2 with p99.9 = 1. Two responses were available: loosen the
/// constant until it passed — which is the dishonest one, and which would have moved the same
/// unexplained 2 codes into the MXF result as an unstated allowance — or measure what two correct
/// decoders actually differ by and judge the MXF against THAT. This is the second.
///
/// The residue is explained rather than merely tolerated: the app's contract is 420, both fixtures
/// and this calibration file are 422, and the vertical chroma downsample is where swscale and
/// VideoToolbox legitimately differ. `gradientMask` classifies flatness on the ALREADY DOWNSAMPLED
/// output plane, so a region flat in the output can still straddle two input rows the two filters
/// weight differently. A tighter mask would need libav's input plane, which the AVFoundation side
/// cannot see.
struct CalibrationFloor {
    let file: String
    let lumaMax: Int
    let chromaFlatMax: Int
    let chromaFlatP999: Int
    let gain: Double
    let offset: Double
}

/// ⚠️ THE CALIBRATION IS A GATE, NOT A SUGGESTION.
///
/// Run on a file both paths already decode — a ProRes `.mov` — where the answer is known in
/// advance. Any tolerance, alignment, stride or bit-packing error in this harness shows up HERE as
/// a harness bug rather than downstream as an MXF finding. It has already earned its place once:
/// it caught `gradientMask` measuring the interleaved chroma plane's gradient on Cb alone, which
/// had been leaking edge samples into the flat population at max |Δ| 14.
///
/// `MODE=pixels` refuses to run without `CALIBRATE=` and aborts if this fails, so a stale result
/// cannot be carried forward: the calibration runs in THIS process, on THIS build, every time.
///
/// ⚠️ PICK A CALIBRATION FILE WITH THE SAME CHROMA GEOMETRY AS THE FIXTURE. A 422 file calibrates
/// a 422 fixture, because the 422→420 vertical resample is precisely the step whose floor is being
/// measured. Calibrating a 420 file and then testing a 422 one would measure a floor that does not
/// include the resample and would report the resample as a finding.
func runCalibration(_ url: URL, outDir: String) -> CalibrationFloor? {
    print("═══ CALIBRATION — \(url.lastPathComponent)")
    print("  A file BOTH decoders get right. This does two things: it proves the harness reads both")
    print("  paths on the same scale (gain ≈ 1.000, offset ≈ 0, luma within a code), and it MEASURES")
    print("  the floor — what two correct decoders differ by through this contract — which the MXF")
    print("  comparison is then judged against instead of against an assumed constant.")
    print("")
    let label = "calibrate-" + url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ", with: "_")
    let r = comparePixels(url, frames: 2, outDir: outDir, label: label)
    if let abort = r.abortReason { print("  ⛔️ CALIBRATION COULD NOT RUN — \(abort)"); print(""); return nil }
    guard let luma = r.lumaStats, let flat = r.chromaFlat else { print("  ⛔️ no stats"); print(""); return nil }
    printPlaneStats("LUMA", luma)
    printPlaneStats("CHROMA, flat regions (\(r.flatCount) samples)", flat)

    // STRUCTURAL checks only — the things that mean the harness itself is wrong. A scale error, a
    // stride error or a bit-depth shift shows up here as a gain that is not 1 or a luma plane that
    // does not match; none of them is a "tolerance" question.
    let gainOK = abs(luma.affineA - 1) < 0.02 && abs(luma.affineB) < 1.0
    let lumaOK = luma.maxDelta <= 2
    let sane = flat.maxDelta <= 8 && flat.p999 <= 2
    print("")
    guard gainOK, lumaOK, sane else {
        print("  CALIBRATION ⛔️ FAILED — this is a harness or pipeline fault, not a tolerance question")
        print("    gain/offset \(gainOK ? "ok" : "⚠️ a=\(String(format: "%.4f", luma.affineA)) b=\(String(format: "%.2f", luma.affineB))")")
        print("    luma        \(lumaOK ? "ok" : "⚠️ max |Δ| \(luma.maxDelta) between two decoders that agree on this file")")
        print("    flat chroma \(sane ? "ok" : "⚠️ max |Δ| \(flat.maxDelta), p99.9 \(flat.p999) — too large to be a resample floor")")
        print("    ⤷ Suspect, in order: the >> 6 bit-depth shift in Plane.read, the plane strides,")
        print("      the swscale range flags, and gradientMask's component handling.")
        print("")
        return nil
    }
    let floor = CalibrationFloor(file: url.lastPathComponent, lumaMax: luma.maxDelta,
                                 chromaFlatMax: flat.maxDelta, chromaFlatP999: flat.p999,
                                 gain: luma.affineA, offset: luma.affineB)
    print("  CALIBRATION PASSED — the harness reads both paths on one scale, and the floor is:")
    print("    luma max |Δ| \(floor.lumaMax)   flat-chroma max |Δ| \(floor.chromaFlatMax) (p99.9 \(floor.chromaFlatP999))")
    print("    gain \(String(format: "%.6f", floor.gain))   offset \(String(format: "%.2f", floor.offset))")
    print("    ⤷ Measured on \(floor.file), 422 10-bit. The non-zero chroma floor is the 422→420")
    print("      VERTICAL RESAMPLE, where swscale and VideoToolbox legitimately differ; it is not")
    print("      an allowance for the MXF result, it is the yardstick the MXF result is read against.")
    print("")
    return floor
}

// ═══════════════════════════════════════════════════════════════════════════════════════════
// MARK: - AUDIO — the cross-correlation matrix
//
// ⚠️ THIS IS THE AUDIO HALF OF THE PIXEL TEST, AND IT EXISTS BECAUSE COUNTS CANNOT ANSWER THE
// QUESTION. `Mixed Captions.mxf` is measured to arrive as ONE `soun` track through AVFoundation
// against FIVE libav streams. That is either the same audio grouped differently or different
// audio, and only correlating the decoded samples can say which. A verdict alone would be an
// assertion; the full matrix is the measurement, so the permutation can be checked by eye.
// ═══════════════════════════════════════════════════════════════════════════════════════════

struct ChannelSignal {
    let label: String          // "libav #1 ch0" / "AVF t0 ch2"
    let role: String           // the declared role, or "—"
    var samples: [Float]
    var sampleRate: Double

    /// ⚠️ LEVELS ARE PRINTED BESIDE THE MATRIX, AND THEY ARE NOT DECORATION. A correlation matrix
    /// of zeros has two completely different causes — the content is SILENT (correlation is
    /// undefined, and that is not a finding) or one path DECODED NOTHING (which is a harness bug).
    /// Without levels those are indistinguishable, and the first version of this reported silence
    /// as "the two paths are delivering different content", which is a false finding.
    var rms: Double {
        guard !samples.isEmpty else { return 0 }
        var acc = 0.0
        for v in samples { acc += Double(v) * Double(v) }
        return (acc / Double(samples.count)).squareRoot()
    }
    var peak: Double { samples.reduce(0.0) { max($0, abs(Double($1))) } }
    /// Below this a channel carries no signal a correlation could be computed from.
    var isSilent: Bool { peak < 1e-7 }
    var dBFS: String {
        let r = rms
        return r < 1e-12 ? "  −inf" : String(format: "%6.1f", 20 * log10(r))
    }
}

/// Decode the first `seconds` of every libav audio stream to per-channel float.
func libavAudioSignals(_ url: URL, seconds: Double) -> [ChannelSignal] {
    var out: [ChannelSignal] = []
    var ctx: UnsafeMutablePointer<AVFormatContext>?
    guard avformat_open_input(&ctx, url.path, nil, nil) == 0, let fmt = ctx else { return out }
    defer { var c: UnsafeMutablePointer<AVFormatContext>? = fmt; avformat_close_input(&c) }
    guard avformat_find_stream_info(fmt, nil) >= 0 else { return out }

    for i in 0..<Int(fmt.pointee.nb_streams) {
        guard let st = fmt.pointee.streams[i] else { continue }
        let par = st.pointee.codecpar!
        guard par.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
        guard let codec = avcodec_find_decoder(par.pointee.codec_id),
              let cctx = avcodec_alloc_context3(codec) else { continue }
        var cctxOpt: UnsafeMutablePointer<AVCodecContext>? = cctx
        defer { avcodec_free_context(&cctxOpt) }
        avcodec_parameters_to_context(cctx, par)
        guard avcodec_open2(cctx, codec, nil) == 0 else { continue }

        let channels = Int(par.pointee.ch_layout.nb_channels)
        let rate = Double(par.pointee.sample_rate)
        let want = Int(seconds * rate)
        var buffers = [[Float]](repeating: [], count: channels)

        // Roles through the app's own bridge, so both sides of the matrix share one vocabulary.
        var roles = [String](repeating: "—", count: channels)
        if let fd = makeLibavAudioFormatDescription(par), let r = layoutRoles(from: fd), r.count == channels {
            roles = r
        }

        var swr: OpaquePointer?
        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, Int32(channels))
        var inLayout = par.pointee.ch_layout
        guard swr_alloc_set_opts2(&swr, &outLayout, AV_SAMPLE_FMT_FLTP, Int32(rate),
                                  &inLayout, AVSampleFormat(par.pointee.format), Int32(rate),
                                  0, nil) == 0, let swr, swr_init(swr) == 0 else { continue }
        defer { var s: OpaquePointer? = swr; swr_free(&s) }

        let pkt = av_packet_alloc()
        let frame = av_frame_alloc()
        defer { var p = pkt; av_packet_free(&p); var f = frame; av_frame_free(&f) }

        // ⚠️ av_seek_frame to 0 is NOT used: both paths must start where the file starts, and a
        // seek would introduce its own semantics into a test that is about content, not seeking.
        readLoop: while av_read_frame(fmt, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            guard pkt!.pointee.stream_index == Int32(i) else { continue }
            guard avcodec_send_packet(cctx, pkt) == 0 else { continue }
            while avcodec_receive_frame(cctx, frame) == 0 {
                let n = Int(frame!.pointee.nb_samples)
                var outPtrs = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: channels)
                var flat = [Float](repeating: 0, count: n * channels)
                flat.withUnsafeMutableBufferPointer { fb in
                    for c in 0..<channels {
                        outPtrs[c] = UnsafeMutableRawPointer(fb.baseAddress! + c * n).assumingMemoryBound(to: UInt8.self)
                    }
                    var inPtrs = [UnsafePointer<UInt8>?](repeating: nil, count: 8)
                    withUnsafePointer(to: &frame!.pointee.data) { dataTuple in
                        dataTuple.withMemoryRebound(to: UnsafeMutablePointer<UInt8>?.self, capacity: 8) { arr in
                            for k in 0..<8 { inPtrs[k] = UnsafePointer(arr[k]) }
                        }
                    }
                    _ = swr_convert(swr, &outPtrs, Int32(n), &inPtrs, Int32(n))
                }
                for c in 0..<channels {
                    buffers[c].append(contentsOf: flat[(c * n)..<((c + 1) * n)])
                }
                av_frame_unref(frame)
                if buffers[0].count >= want { break readLoop }
            }
        }
        for c in 0..<channels {
            out.append(ChannelSignal(label: "libav #\(i) ch\(c)", role: roles[c],
                                     samples: Array(buffers[c].prefix(want)), sampleRate: rate))
        }
    }
    return out
}

/// Decode the first `seconds` of every AVFoundation audio track to per-channel float.
func avfAudioSignals(_ url: URL, seconds: Double) -> [ChannelSignal] {
    sync {
        var out: [ChannelSignal] = []
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return out }
        for (t, track) in tracks.enumerated() {
            var channels = 0
            var rate = 48000.0
            var roles: [String] = []
            if let fmt = (try? await track.load(.formatDescriptions))?.first {
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
                    channels = Int(asbd.mChannelsPerFrame); rate = asbd.mSampleRate
                }
                roles = layoutRoles(from: fmt) ?? []
            }
            guard channels > 0, let reader = try? AVAssetReader(asset: asset) else { continue }
            // Interleaved float32 at the source rate. No channel layout is requested, deliberately:
            // asking for one invites a downmix, and the question here is what the track CONTAINS.
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: rate
            ]
            let o = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            guard reader.canAdd(o) else { continue }
            reader.add(o)
            guard reader.startReading() else { continue }
            var buffers = [[Float]](repeating: [], count: channels)
            let want = Int(seconds * rate)
            while buffers[0].count < want, let sb = o.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                var length = 0
                var pointer: UnsafeMutablePointer<CChar>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                                  totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                      let pointer, length > 0 else { continue }
                let floats = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
                let frames = length / (4 * channels)
                for f in 0..<frames {
                    for c in 0..<channels { buffers[c].append(floats[f * channels + c]) }
                }
            }
            reader.cancelReading()
            for c in 0..<channels {
                out.append(ChannelSignal(label: "AVF t\(t) ch\(c)",
                                         role: c < roles.count ? roles[c] : "—",
                                         samples: Array(buffers[c].prefix(want)), sampleRate: rate))
            }
        }
        return out
    }
}

/// Pearson correlation at the best lag within ±maxLag. The lag is reported, not hidden: a perfect
/// correlation at a non-zero lag is a different statement from one at lag 0.
func bestCorrelation(_ a: [Float], _ b: [Float], maxLag: Int) -> (r: Double, lag: Int, defined: Bool) {
    guard !a.isEmpty, !b.isEmpty else { return (0, 0, false) }
    var best = -2.0, bestLag = 0
    var anyDefined = false
    let step = max(1, maxLag / 64)
    var lag = -maxLag
    while lag <= maxLag {
        let aStart = max(0, -lag), bStart = max(0, lag)
        let n = min(a.count - aStart, b.count - bStart)
        if n > 64 {
            var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
            for i in 0..<n {
                let x = Double(a[aStart + i]), y = Double(b[bStart + i])
                sa += x; sb += y; saa += x * x; sbb += y * y; sab += x * y
            }
            let nd = Double(n)
            let num = nd * sab - sa * sb
            let den = ((nd * saa - sa * sa) * (nd * sbb - sb * sb)).squareRoot()
            // A zero denominator means one side is CONSTANT over this window — silence, or a
            // channel that decoded to nothing. Undefined, not zero, and reported as such.
            if den > 1e-12 {
                anyDefined = true
                let r = num / den
                if r > best { best = r; bestLag = lag }
            }
        }
        lag += step
    }
    return (anyDefined ? best : 0, bestLag, anyDefined)
}

func runAudio(_ url: URL, seconds: Double) {
    print("═══ AUDIO — \(url.lastPathComponent)")
    let lav = libavAudioSignals(url, seconds: seconds)
    let avf = avfAudioSignals(url, seconds: seconds)
    print("  libav: \(lav.count) channel(s) across \(Set(lav.map { $0.label.split(separator: " ")[1] }).count) stream(s)")
    print("  AVF:   \(avf.count) channel(s) across \(Set(avf.map { $0.label.split(separator: " ")[1] }).count) track(s)")
    guard !lav.isEmpty, !avf.isEmpty else { print("  one side produced nothing — cannot correlate"); print(""); return }

    print("")
    print("  LEVELS (first \(String(format: "%.2f", seconds)) s) — read these BEFORE the matrix")
    print("    libav: " + lav.map { "\($0.label.dropFirst(6))=\($0.dBFS)dB" }.joined(separator: "  "))
    print("    AVF:   " + avf.map { "\($0.label.dropFirst(4))=\($0.dBFS)dB" }.joined(separator: "  "))
    let lavSilent = lav.allSatisfy { $0.isSilent }, avfSilent = avf.allSatisfy { $0.isSilent }
    if lavSilent && avfSilent {
        print("    ⚠️ BOTH PATHS ARE SILENT over this window. Correlation is UNDEFINED, not zero, and")
        print("       nothing below can say whether the channels correspond. Re-run with a larger")
        print("       SECONDS, or seek into a part of the file that carries signal.")
    } else if lavSilent != avfSilent {
        print("    ⛔️ ONE PATH IS SILENT AND THE OTHER IS NOT — \(lavSilent ? "libav" : "AVFoundation") decoded")
        print("       nothing. That is a decode failure (or a harness bug), NOT a grouping difference.")
    }

    print("")
    print("  DECLARED ROLES")
    print("    libav: " + lav.map { "\($0.label.dropFirst(6))=\($0.role)" }.joined(separator: "  "))
    print("    AVF:   " + avf.map { "\($0.label.dropFirst(4))=\($0.role)" }.joined(separator: "  "))
    let lavRoles = lav.map { $0.role }, avfRoles = avf.map { $0.role }
    if lavRoles != avfRoles {
        print("    ⚠️ ROLE SEQUENCES DIFFER. Both sides were named by the SAME copied bridge, so this is")
        print("       the files' declarations differing, not two naming tables.")
    } else {
        print("    ✅ ROLE SEQUENCES AGREE, CHANNEL FOR CHANNEL — including any Film-vs-SMPTE ordering")
        print("       above. Both were named by the same bridge from each path's own layout, so this")
        print("       is agreement about the FILE, not a shared default.")
    }

    // ⚠️ THE FULL MATRIX, NOT A VERDICT. It is printed even when undefined, because the shape of
    // the undefined region is itself informative.
    let maxLag = Int(lav.first!.sampleRate * 0.1)
    print("")
    print("  CROSS-CORRELATION (Pearson at best lag, ±100 ms) — \"·\" = UNDEFINED (a constant/silent side)")
    print("    " + pad("", 16) + lav.map { pad(String($0.label.dropFirst(6)), 10) }.joined())
    var matrix = [[(r: Double, lag: Int, defined: Bool)]]()
    for a in avf {
        var rowVals: [(r: Double, lag: Int, defined: Bool)] = []
        var cells = ""
        for l in lav {
            let c = bestCorrelation(a.samples, l.samples, maxLag: maxLag)
            rowVals.append(c)
            cells += pad(c.defined ? String(format: "%+.3f", c.r) : "  ·", 10)
        }
        matrix.append(rowVals)
        print("    " + pad(String(a.label.dropFirst(4)), 16) + cells)
    }

    let anyDefined = matrix.contains { $0.contains { $0.defined } }
    guard anyDefined else {
        print("")
        print("  ⤷ EVERY CELL IS UNDEFINED. No claim is made about channel correspondence — see the")
        print("    levels above for why. This is NOT evidence that the paths disagree.")
        print("")
        return
    }

    print("")
    print("  BEST MATCH PER AVFoundation CHANNEL")
    var used = Set<Int>()
    var allStrong = true, anyCollision = false
    for (i, a) in avf.enumerated() {
        let defined = matrix[i].filter { $0.defined }
        guard !defined.isEmpty,
              let j = matrix[i].indices.filter({ matrix[i][$0].defined })
                       .max(by: { matrix[i][$0].r < matrix[i][$1].r }) else {
            print("    \(pad(String(a.label.dropFirst(4)), 16)) → no defined correlation (silent channel)")
            continue
        }
        let c = matrix[i][j]
        let dup = used.contains(j)
        if dup { anyCollision = true }
        used.insert(j)
        if c.r < 0.99 { allStrong = false }
        print("    \(pad(String(a.label.dropFirst(4)), 16)) → \(pad(String(lav[j].label.dropFirst(6)), 12))"
            + String(format: "r=%+.4f  lag=%d", c.r, c.lag)
            + (dup ? "   ⚠️ ALREADY CLAIMED by an earlier AVF channel" : ""))
        if a.role != "—" || lav[j].role != "—" {
            let agree = a.role == lav[j].role
            print("      roles: AVF \(a.role) vs libav \(lav[j].role)"
                + (agree ? "" : "   ⚠️ THE SAME AUDIO IS GIVEN DIFFERENT ROLES BY THE TWO PATHS"))
        }
    }
    print("")
    if allStrong && !anyCollision && used.count == avf.count {
        print("  ⤷ Every AVFoundation channel matched a DISTINCT libav channel at r ≥ 0.99: this is the")
        print("    SAME AUDIO, grouped differently. Any count or ordering difference above is a")
        print("    presentation difference, not a content one.")
    } else if anyCollision {
        print("  ⤷ ⚠️ Two AVFoundation channels claimed the same libav channel. Either the content is")
        print("    duplicated across channels (common in test tone fixtures, and not a fault), or the")
        print("    correlation is not discriminating. Check the levels and the matrix by eye.")
    } else {
        print("  ⤷ ⚠️ At least one AVFoundation channel has no strong match. Read that with the levels:")
        print("    with signal present on both sides it means the paths deliver different content.")
    }
    print("")
}

// ═══════════════════════════════════════════════════════════════════════════════════════════
// MARK: - main
// ═══════════════════════════════════════════════════════════════════════════════════════════

// ⚠️ FIRST, BEFORE ANY AVFoundation OR VideoToolbox USE. There is no flag to skip this.
registerProfessionalVideoWorkflow()
installLibavLogCapture()

let mode = env("MODE") ?? "facts"
let files = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
let outDir = env("OUTDIR") ?? FileManager.default.currentDirectoryPath + "/mxfmeas-out"

guard !files.isEmpty else {
    print("usage: MODE=facts|calibrate|pixels|audio ./mxfmeas FILE...")
    print("  MODE=pixels additionally REQUIRES CALIBRATE=<a ProRes .mov both paths decode>")
    exit(2)
}

switch mode {
case "facts":
    for f in files { runFacts(f) }

case "calibrate":
    for f in files { _ = runCalibration(f, outDir: outDir) }

case "pixels":
    // ⚠️ THE GATE. Not a suggestion, and not a stamp file that could go stale — the calibration
    // runs in THIS process, on THIS build of the harness, every time.
    guard let cal = env("CALIBRATE") else {
        print("⛔️ MODE=pixels requires CALIBRATE=<path to a ProRes .mov>.")
        print("")
        print("   A pixel comparison is only as trustworthy as the harness reading the planes. Run it")
        print("   first on a file BOTH paths already decode, where the answer is known: any tolerance,")
        print("   alignment, stride or bit-packing error shows up there as a harness bug rather than")
        print("   here as an MXF finding. This is the one step the design calls non-optional.")
        exit(2)
    }
    guard let floor = runCalibration(URL(fileURLWithPath: cal), outDir: outDir) else {
        print("⛔️ Calibration failed — refusing to report MXF pixel numbers from an uncalibrated harness.")
        exit(1)
    }
    let n = envInt("N", 4)
    for f in files { runPixels(f, frames: n, outDir: outDir, floor: floor) }

case "audio":
    for f in files { runAudio(f, seconds: envDouble("SECONDS", 1.0)) }

default:
    print("unknown MODE=\(mode) — one of facts, calibrate, pixels, audio")
    exit(2)
}

if !LibavLog.lines.isEmpty {
    print("── libav decoder log (captured, not left on stderr) ──")
    for l in LibavLog.lines { print("   \(l)") }
}
