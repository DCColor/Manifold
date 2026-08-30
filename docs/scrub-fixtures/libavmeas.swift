// libavmeas — can the LIBAV path seek, decode and reach `renderPixelBuffer` at drag rate?
//
// The sibling question to `avpvomeas.swift`, and the reason it exists: that spike passed, but
// AVFoundation CANNOT OPEN MXF AT ALL (`FrameEngine.loadMXF`: "AVFoundation has no MXF demuxer, so
// it can't open the file at all — MXF routes DIRECTLY to libav"). So the approved route covers only
// part of the corpus. For the fix to be invisible to the user, MXF must reach the SAME destination
// — `MetalVideoRenderer.renderPixelBuffer`, same shader, same offscreen, same layer, no CGImage
// overlay anywhere — with a DIFFERENT producer: libav seeking and decoding one frame at the scrub
// position and handing over a `CVPixelBuffer`.
//
// That seam already exists and is already used by three producers (NDI, WHEP, SRT), so the question
// is not whether the renderer will accept the frame. It is only: HOW LONG DOES LIBAV TAKE.
//
// ⚠️ THIS MEASURES AND NOTHING ELSE. It builds no app, links no app CODE (it links the same
// vendored libav dylibs and #includes the app's own `CFFmpeg/include/shim.h`, so the decode surface
// is identical), and changes no app behaviour. Same convention as `scrubmeas.swift` /
// `avpvomeas.swift` / `wincap.swift`: single-file script, built on demand, binary not committed,
// not in the target (`project.yml`'s `sources:` is `App` plus one DeckLink .cpp — nothing under
// `docs/` is globbed in, so no `xcodegen` run is needed).
//
// ── BUILD AND RUN ───────────────────────────────────────────────────────────────────────────────
//
//   cd docs/scrub-fixtures
//   ./build-libavmeas.sh          # the compile line is long enough to be worth a script
//
//   MODE=probe                     ./libavmeas FILE...   # what libav sees, and whether AVF can open it
//   MODE=latency N=40 SHADER=1     ./libavmeas FILE...   # THE QUESTION
//   MODE=memory  T=20              ./libavmeas FILE...   # second decode alongside playback
//   MODE=hdr                       ./libavmeas FILE...   # what the decode produces, and what x420 costs
//   MODE=threads N=40              ./libavmeas FILE...   # what thread_count buys, since the two
//                                                        # existing libav clients disagree about it
//
// ⚠️ Do NOT pass `-parse-as-library`. Single-file script; top-level code is only legal without it,
// and the failure message ("statements are not allowed at the top level") does not name the flag.
// Same trap as `scrubmeas.swift` and `avpvomeas.swift`.
//
// ── WHAT "LATENCY" MEANS HERE, PRECISELY, AND WHY IT IS COMPARABLE TO YESTERDAY'S NUMBER ────────
//
// t0 is the instant the seek is issued (`av_seek_frame`). t1 is the instant a `CVPixelBuffer` in
// the app's x420 contract is IN HAND — decoded, converted, colour attachments set. That is the same
// span `avpvomeas.swift` timed: seek requested → buffer in hand, ready for `renderPixelBuffer`.
// Positions, distribution shape (mean / p50 / p90 / max) and the 50 ms budget are identical, so the
// two tables can be read side by side.
//
// ⚠️ THE STOP CONDITION HAS THE OPPOSITE TRAP FROM YESTERDAY'S. `avpvomeas.swift` had to guard
// against ACCEPTING TOO EARLY (`copyPixelBuffer` hands back the pre-seek frame, a perfectly valid
// buffer, and accepting it reports ~0 ms for a picture that never changed). libav cannot do that —
// `avcodec_receive_frame` returns a frame with its own PTS, so there is no ambiguity about WHICH
// frame is in hand. The trap here is the mirror image: ACCEPTING THE WRONG FRAME AND NOT NOTICING.
// `av_seek_frame(…BACKWARD)` can land arbitrarily far before the target on a file whose index is
// coarse or absent, and the decode-forward loop will happily walk to the target — cheap on
// all-intra, and NOT cheap otherwise. So every position reports `delivered frame − requested` in
// frames (same column `avpvomeas.swift` reports) AND the number of frames the loop had to decode
// and throw away to get there. A latency number without that column cannot tell a fast seek from a
// short walk.
//
// ── THE DECODE CONTRACT AND THE CONVERSION ARE COPIED FROM THE APP ──────────────────────────────
//
// x420 (`kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`) — `FrameEngine.videoPixelFormat` /
// `FileFrameSource.defaultPixelFormat`, and what `PassthroughShader.metal`'s constants are written
// for. `LibavScrubDecoder.convert` below is COPIED FROM `LibavFrameSource.convert`, including its
// swscale destination format, its "force src/dst range EQUAL → no range remap" line and its three
// colour attachments. `thumbnailPath` is COPIED FROM `LibavThumbnailSource.makeCGImage`. If either
// changes, change these, or this measures a pipeline the app does not have.
import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics
import Darwin
import Foundation
import Metal
import QuartzCore

// ── The app's decode contract. FrameEngine.swift / FileFrameSource.swift ────────────────────────
let kPixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

let env = ProcessInfo.processInfo.environment
let MODE = env["MODE"] ?? "latency"
let N = Int(env["N"] ?? "40") ?? 40
let T = Double(env["T"] ?? "20") ?? 20
let WANT_SHADER = (env["SHADER"] ?? "0") != "0"
let CORES = ProcessInfo.processInfo.activeProcessorCount
/// Default matches `LibavThumbnailSource.openLocked` — `max(2, cores/2)`, the SHIPPING choice for
/// the detached scrub decoder. `MODE=threads` sweeps it.
let THREADS = Int(env["THREADS"] ?? "") ?? max(2, CORES / 2)

// ⚠️ `thread_type` — THE FIELD NEITHER EXISTING libav CLIENT SETS, AND THE ONE THIS MEASUREMENT
// TURNED OUT TO BE ABOUT.
//
// `LibavFrameSource` and `LibavThumbnailSource` both set `thread_count` and leave `thread_type` at
// its default, which is `FF_THREAD_FRAME | FF_THREAD_SLICE` — libav then picks whichever the codec
// supports, preferring FRAME. avcodec.h states the consequence in one line above the field:
//
//     "Use of FF_THREAD_FRAME will increase decoding delay by one frame per thread"
//
// For CONTINUOUS PLAYBACK that delay is free — it is a pipeline, and it fills once. For a
// SINGLE-FRAME SEEK it is not: after `avcodec_flush_buffers` the pipeline is empty, so getting ONE
// frame out costs `thread_count` frames of decode. That is a property of the seek, not of the
// codec, and it does not appear anywhere in the two clients' comments.
//
//   THREADTYPE=default   leave it alone — what both shipping clients do
//   THREADTYPE=slice     FF_THREAD_SLICE only — no frame-delay, threads within one frame
//   THREADTYPE=frame     FF_THREAD_FRAME only — the pathological case, stated explicitly
//
// FF_THREAD_FRAME = 1, FF_THREAD_SLICE = 2 (avcodec.h:1584 — #defines, so they do not import).
let kThreadFrame: Int32 = 1
let kThreadSlice: Int32 = 2
let THREADTYPE = env["THREADTYPE"] ?? "default"
func threadTypeValue(_ s: String) -> Int32? {
    switch s {
    case "slice": return kThreadSlice
    case "frame": return kThreadFrame
    case "both":  return kThreadFrame | kThreadSlice
    default:      return nil          // leave the field at libav's default
    }
}

// MARK: - formatting
//
// Identical to avpvomeas.swift on purpose: the two outputs are meant to be read as one table.

func fmt(_ d: Double, _ n: Int = 1) -> String { d.isFinite ? String(format: "%.\(n)f", d) : "  nan" }
/// For vmmap rows that may legitimately not exist. ⚠️ `CoreMedia memory pool` DOES NOT APPEAR ON
/// THIS PATH AT ALL and its absence is a finding, not a failure: libav's decoder is not CoreMedia,
/// so the frames live in libav's own buffers and then in OUR `CVPixelBufferPool`, which vmmap
/// accounts as `IOSurface`. avpvomeas.swift's table has a CoreMedia column because ITS decoder is
/// VideoToolbox's. The two tables therefore do not have the same rows, and printing "nan" as if a
/// measurement had failed would misread that.
func fmtOpt(_ d: Double, _ n: Int = 1) -> String { d.isFinite ? String(format: "%.\(n)f", d) : "—" }
func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
func lpad(_ s: String, _ w: Int) -> String { s.count >= w ? s : String(repeating: " ", count: w - s.count) + s }

/// mean / p50 / p90 / max — the shape `../BUGS.md`'s `exactSeek` table and the AVPlayerItemVideoOutput
/// spike table are both stated in. `max` is reported because it is what killed the reader-rebuild
/// route (117.7 ms on all-intra); a mean inside budget with a max outside it is a FAILING result.
struct Dist {
    let n: Int, mean: Double, p50: Double, p90: Double, mn: Double, mx: Double
    init(_ v: [Double]) {
        n = v.count
        guard !v.isEmpty else { mean = .nan; p50 = .nan; p90 = .nan; mn = .nan; mx = .nan; return }
        let s = v.sorted()
        mean = v.reduce(0, +) / Double(v.count)
        func pct(_ p: Double) -> Double { s[min(s.count - 1, max(0, Int((p * Double(s.count - 1)).rounded())))] }
        p50 = pct(0.5); p90 = pct(0.9); mn = s.first!; mx = s.last!
    }
    var row: String {
        "n=\(lpad(String(n),3))  mean \(lpad(fmt(mean),6))  p50 \(lpad(fmt(p50),6))  p90 \(lpad(fmt(p90),6))  max \(lpad(fmt(mx),6))  min \(lpad(fmt(mn),6))"
    }
}

// MARK: - process metrics
//
// Copied from avpvomeas.swift, including the warning that motivates vmmap. Repeated rather than
// factored out because these are single-file scripts by convention and a shared file would put
// docs/ into a build graph it is deliberately outside of.
//
// ⚠️ `phys_footprint` and `resident_size` DO NOT SEE IOSURFACE-BACKED PIXEL BUFFERS. A
// CVPixelBufferPool is IOSurface-backed and charged elsewhere. They are a FLOOR, not a ceiling;
// `vmmap --summary` by region type is the instrument that can see the pool.

func residentMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1048576 : .nan
}
func residentPeakMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size_max) / 1048576 : .nan
}
func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576 : .nan
}
/// Bytes read from a BLOCK DEVICE. ⚠️ SMB reads DO NOT APPEAR HERE — smbfs is not a block device,
/// so on /Volumes/DCCOLOR this stays ~0 and the network counter below is the instrument.
func diskReadMB() -> Double {
    var rui = rusage_info_current()
    let r = withUnsafeMutablePointer(to: &rui) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
        }
    }
    return r == 0 ? Double(rui.ri_diskio_bytesread) / 1048576 : .nan
}
/// MACHINE-WIDE inbound bytes on every non-loopback link. Not per-process; meaningful only as a
/// DELTA across a phase on an otherwise quiet machine, and labelled that way in the output.
func netInMB() -> Double {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat"); p.arguments = ["-ibn"]
    let pipe = Pipe(); p.standardOutput = pipe
    guard (try? p.run()) != nil else { return .nan }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    var total: Double = 0
    for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count > 6, f[0].hasPrefix("en") || f[0].hasPrefix("bridge"),
              f[2].hasPrefix("<Link") || f[2].hasPrefix("Link") else { continue }
        total += Double(f[6]) ?? 0
    }
    return total / 1048576
}

struct VMMap {
    var footprintMB = Double.nan, peakFootprintMB = Double.nan
    var coreMediaDirtyMB = Double.nan, ioSurfaceVirtualMB = Double.nan
    var graphicsDirtyMB = Double.nan, totalDirtyMB = Double.nan
}
func parseSize(_ t: String) -> Double {
    guard let last = t.last else { return .nan }
    let mult: Double = last == "G" ? 1024 : last == "M" ? 1 : last == "K" ? 1.0 / 1024 : 1.0 / 1048576
    return (Double(last.isLetter ? String(t.dropLast()) : t) ?? .nan) * mult
}
/// VIRTUAL / RESIDENT / DIRTY for one region-type row. The row LABEL is stripped BY NAME before
/// splitting — region names contain spaces and digits, so a positional parse reads the name as a
/// column.
func vmmapRow(_ line: Substring, _ label: String) -> (v: Double, r: Double, d: Double)? {
    guard line.hasPrefix(label) else { return nil }
    let cols = line.dropFirst(label.count).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard cols.count >= 3 else { return nil }
    return (parseSize(cols[0]), parseSize(cols[1]), parseSize(cols[2]))
}
/// ⚠️ vmmap BRIEFLY SUSPENDS the target task, which is us — called ONCE per phase, never on a
/// sampling loop, or the instrument becomes part of what it measures.
func vmmapSummary() -> VMMap {
    var out = VMMap()
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
    p.arguments = ["--summary", String(getpid())]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return out }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
        if line.hasPrefix("Physical footprint (peak):") {
            out.peakFootprintMB = parseSize(String(line.dropFirst("Physical footprint (peak):".count)).trimmingCharacters(in: .whitespaces))
        } else if line.hasPrefix("Physical footprint:") {
            out.footprintMB = parseSize(String(line.dropFirst("Physical footprint:".count)).trimmingCharacters(in: .whitespaces))
        } else if let r = vmmapRow(line, "CoreMedia memory pool") { out.coreMediaDirtyMB = r.d }
        else if let r = vmmapRow(line, "IOSurface") { out.ioSurfaceVirtualMB = r.v }
        else if let r = vmmapRow(line, "owned unmapped (graphics)") { out.graphicsDirtyMB = r.d }
        // FIRST "TOTAL" only — vmmap prints three, and the later ones are different tables.
        else if out.totalDirtyMB.isNaN, let r = vmmapRow(line, "TOTAL") { out.totalDirtyMB = r.d }
    }
    return out
}

// MARK: - shader stage
//
// The verdict for the PICTURE and the verdict for the SCOPES are not the same number. The picture
// needs a `CVPixelBuffer`; the scopes read the OFFSCREEN RING (`MetalVideoRenderer.renderPixelFormat`:
// "Display, export, DeckLink and the SCOPES all read this target"). This stage carries the frame the
// rest of the way — two `CVMetalTextureCache` plane textures and one render into an `rgba16Float`
// offscreen at SOURCE resolution, WAITED TO GPU COMPLETION, because a number that stopped at
// `commit()` would leave out the part that has to finish.
//
// ⚠️ COPIED FROM avpvomeas.swift, which copied it from App/PassthroughShader.metal (legal-range
// Rec.709 branch). It exists to COST THE RIGHT AMOUNT OF WORK, not to be colour-correct for every
// file. Keeping it byte-identical to yesterday's is deliberate: the shader-stage cost is then
// directly comparable between the two producers.
let kShaderSource = """
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 position [[position]]; float2 uv; };
constant float kCodeMax     = 1023.984375;
constant float kLumaBlack   = 64.0 / kCodeMax;
constant float kLumaSwing   = kCodeMax / 876.0;
constant float kChromaMid   = 512.0 / kCodeMax;
constant float kChromaSwing = kCodeMax / 896.0;
vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    float2 t[4] = { float2(0,1), float2(1,1), float2(0,0), float2(1,0) };
    VOut o; o.position = float4(p[vid], 0, 1); o.uv = t[vid]; return o;
}
fragment half4 fmain(VOut in [[stage_in]],
                     texture2d<float> luma   [[texture(0)]],
                     texture2d<float> chroma [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y  = (luma.sample(s, in.uv).r - kLumaBlack) * kLumaSwing;
    float2 c = (chroma.sample(s, in.uv).rg - kChromaMid) * kChromaSwing;
    float r = y + 1.5748 * c.y;
    float g = y - 0.1873 * c.x - 0.4681 * c.y;
    float b = y + 1.8556 * c.x;
    return half4(half(r), half(g), half(b), 1.0h);
}
"""

final class ShaderStage {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    var cache: CVMetalTextureCache?
    var offscreen: MTLTexture?
    var offSize: (Int, Int) = (0, 0)

    init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { return nil }
        device = d; queue = q
        guard let lib = try? d.makeLibrary(source: kShaderSource, options: nil),
              let vf = lib.makeFunction(name: "vmain"), let ff = lib.makeFunction(name: "fmain") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vf; desc.fragmentFunction = ff
        desc.colorAttachments[0].pixelFormat = .rgba16Float   // MetalVideoRenderer.renderPixelFormat
        guard let ps = try? d.makeRenderPipelineState(descriptor: desc) else { return nil }
        pipeline = ps
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, d, nil, &cache)
        if cache == nil { return nil }
    }

    private func plane(_ pb: CVPixelBuffer, _ i: Int, _ f: MTLPixelFormat, _ w: Int, _ h: Int) -> (CVMetalTexture, MTLTexture)? {
        guard let cache else { return nil }
        var ct: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, f, w, h, i, &ct) == kCVReturnSuccess,
              let ct, let t = CVMetalTextureGetTexture(ct) else { return nil }
        return (ct, t)
    }

    /// "Buffer in hand" → "GPU write of the offscreen COMPLETE", in ms.
    func render(_ pb: CVPixelBuffer) -> Double? {
        let t0 = CACurrentMediaTime()
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard CVPixelBufferGetPlaneCount(pb) >= 2 else { return nil }
        let cw = CVPixelBufferGetWidthOfPlane(pb, 1), ch = CVPixelBufferGetHeightOfPlane(pb, 1)
        guard let (kl, lt) = plane(pb, 0, .r16Unorm, w, h),
              let (kc, ct) = plane(pb, 1, .rg16Unorm, cw, ch) else { return nil }
        _ = kl; _ = kc
        if offscreen == nil || offSize != (w, h) {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            offscreen = device.makeTexture(descriptor: d); offSize = (w, h)
        }
        guard let off = offscreen else { return nil }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = off
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(lt, index: 0); enc.setFragmentTexture(ct, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        CVMetalTextureCacheFlush(cache!, 0)
        return (CACurrentMediaTime() - t0) * 1000
    }
}

// MARK: - libav error codes
//
// AVERROR(EAGAIN) and AVERROR_EOF are macros that do not import to Swift — mirrored exactly as
// `LibavFrameSource` and `LibavThumbnailSource` mirror them.
let errEAGAIN: Int32 = -Int32(EAGAIN)
let errEOF: Int32 = {
    let tag = UInt32(UInt8(ascii: "E")) | (UInt32(UInt8(ascii: "O")) << 8)
        | (UInt32(UInt8(ascii: "F")) << 16) | (UInt32(UInt8(ascii: " ")) << 24)
    return -Int32(bitPattern: tag)
}()

func avErr(_ code: Int32) -> String {
    var buf = [CChar](repeating: 0, count: 128)
    av_strerror(code, &buf, 128)
    return String(cString: buf)
}

// MARK: - THE DECODER UNDER TEST
//
// One class, three products from the same seek+decode, so the SEEK cost is measured once and the
// three destinations are priced against each other rather than against three different runs:
//
//   1. `AVFrame` in hand                  — what the seek and decode alone cost.
//   2. → x420 `CVPixelBuffer`             — THE DESTINATION. `renderPixelBuffer`'s contract.
//                                           Conversion copied from `LibavFrameSource.convert`.
//   3. → 960×540 RGBA8 `CGImage`          — THE SHIPPING PATH. Copied from
//                                           `LibavThumbnailSource.makeCGImage`, so the proposed
//                                           route is priced against what it would REPLACE.
//
// ⚠️ IT OPENS ITS OWN `AVFormatContext`, exactly as `LibavThumbnailSource` does, and for the
// documented reason ("completely separate from the playback `LibavFrameSource` — so thumbnail
// seeks/decodes never disturb playback"). `MODE=memory` is where that claim is actually tested;
// everything else here runs the scrub decoder alone.
final class LibavScrubDecoder {

    private(set) var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var pkt: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private(set) var videoStreamIndex: Int32 = -1
    private var timeBase = AVRational(num: 1, den: 600)
    private var startTimeTicks: Int64 = 0
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    /// Cached swscale context. `LibavFrameSource.convert` builds a FRESH ONE PER FRAME and frees it
    /// on the way out; a seek-to-renderer path obviously would not. Both are measured — see
    /// `convert(_:reuseSws:)` — because the difference is a real, avoidable per-seek cost.
    private var sws: UnsafeMutablePointer<SwsContext>?
    private var swsKey = (0, 0, Int32(0))
    private var swsThumb: UnsafeMutablePointer<SwsContext>?
    private var swsThumbKey = (0, 0, Int32(0))

    // Facts, filled by open().
    private(set) var width = 0, height = 0
    private(set) var frameRate = 0.0
    private(set) var durationSeconds = 0.0
    private(set) var codecName = "?"
    private(set) var pixFmtName = "?"
    private(set) var rangeName = "?"
    private(set) var trcName = "?", priName = "?", matName = "?"
    private(set) var nbStreams = 0
    private(set) var openInputMs = 0.0, findInfoMs = 0.0, codecOpenMs = 0.0
    var openTotalMs: Double { openInputMs + findInfoMs + codecOpenMs }

    private let url: URL
    private(set) var threads: Int
    private let threadType: Int32?
    private(set) var activeThreadType: Int32 = 0
    private(set) var codecDelay: Int32 = 0
    init(url: URL, threads: Int, threadType: Int32? = threadTypeValue(THREADTYPE)) {
        self.url = url; self.threads = threads; self.threadType = threadType
    }
    deinit { free() }

    /// Open container + decoder, timing the three stages separately. They are separated because
    /// `avformat_find_stream_info` is the one that scales with the file and the transport — on a
    /// 26 GB MXF over SMB it is not in the same class as the other two, and folding it into a
    /// single "open cost" would hide the only part of it that matters.
    @discardableResult
    func open() -> Bool {
        var ctx: UnsafeMutablePointer<AVFormatContext>? = nil
        var t = CACurrentMediaTime()
        guard avformat_open_input(&ctx, url.path, nil, nil) == 0, ctx != nil else {
            print("    !! avformat_open_input failed"); return false
        }
        openInputMs = (CACurrentMediaTime() - t) * 1000
        t = CACurrentMediaTime()
        guard avformat_find_stream_info(ctx, nil) >= 0 else {
            avformat_close_input(&ctx); print("    !! find_stream_info failed"); return false
        }
        findInfoMs = (CACurrentMediaTime() - t) * 1000

        nbStreams = Int(ctx!.pointee.nb_streams)
        var vIdx: Int32 = -1
        var par: UnsafeMutablePointer<AVCodecParameters>? = nil
        var stream: UnsafeMutablePointer<AVStream>? = nil
        for i in 0..<nbStreams {
            guard let st = ctx!.pointee.streams[i] else { continue }
            if st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO, vIdx < 0 {
                vIdx = Int32(i); par = st.pointee.codecpar; stream = st
            }
        }
        guard vIdx >= 0, let par, let stream, let codec = avcodec_find_decoder(par.pointee.codec_id),
              let cctx = avcodec_alloc_context3(codec) else {
            avformat_close_input(&ctx); print("    !! no decodable video stream"); return false
        }
        avcodec_parameters_to_context(cctx, par)
        cctx.pointee.thread_count = Int32(threads)
        if let tt = threadType { cctx.pointee.thread_type = tt }
        var cctxOpt: UnsafeMutablePointer<AVCodecContext>? = cctx
        t = CACurrentMediaTime()
        guard avcodec_open2(cctx, codec, nil) == 0 else {
            avcodec_free_context(&cctxOpt); avformat_close_input(&ctx)
            print("    !! avcodec_open2 failed"); return false
        }
        codecOpenMs = (CACurrentMediaTime() - t) * 1000
        // What libav ACTUALLY chose, which is not always what was asked for.
        activeThreadType = cctx.pointee.active_thread_type
        codecDelay = cctx.pointee.delay

        fmtCtx = ctx; codecCtx = cctx
        pkt = av_packet_alloc(); frame = av_frame_alloc()
        videoStreamIndex = vIdx
        timeBase = stream.pointee.time_base
        let st = stream.pointee.start_time
        startTimeTicks = (st == Int64.min) ? 0 : st
        width = Int(par.pointee.width); height = Int(par.pointee.height)
        let fr = av_guess_frame_rate(ctx, stream, nil)
        frameRate = fr.den != 0 ? Double(fr.num) / Double(fr.den) : 0
        let d = ctx!.pointee.duration
        durationSeconds = (d == Int64.min) ? 0 : Double(d) / 1_000_000
        codecName = String(cString: avcodec_get_name(par.pointee.codec_id))
        pixFmtName = av_get_pix_fmt_name(AVPixelFormat(par.pointee.format)).map { String(cString: $0) } ?? "?"
        rangeName = par.pointee.color_range == AVCOL_RANGE_JPEG ? "full/JPEG"
            : par.pointee.color_range == AVCOL_RANGE_MPEG ? "legal/MPEG" : "unspecified"
        trcName = Self.name(av_color_transfer_name(par.pointee.color_trc))
        priName = Self.name(av_color_primaries_name(par.pointee.color_primaries))
        matName = Self.name(av_color_space_name(par.pointee.color_space))
        return true
    }

    private static func name(_ p: UnsafePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "?" }

    /// What libav actually negotiated. FRAME threading is the one that costs a seek `thread_count`
    /// frames of decode instead of one.
    var threadingLabel: String {
        var parts: [String] = []
        if activeThreadType & kThreadFrame != 0 { parts.append("FRAME") }
        if activeThreadType & kThreadSlice != 0 { parts.append("SLICE") }
        if parts.isEmpty { parts.append("none") }
        return "\(parts.joined(separator: "+")) x\(threads), decoder delay \(codecDelay)"
    }

    func free() {
        if let s = sws { sws_freeContext(s); sws = nil }
        if let s = swsThumb { sws_freeContext(s); swsThumb = nil }
        if codecCtx != nil { avcodec_free_context(&codecCtx) }
        if fmtCtx != nil { avformat_close_input(&fmtCtx) }
        if pkt != nil { av_packet_free(&pkt) }
        if frame != nil { av_frame_free(&frame) }
        pool = nil
    }

    struct SeekResult {
        var seekMs = 0.0          // av_seek_frame + avcodec_flush_buffers alone
        var decodeMs = 0.0        // to an AVFrame at/after the target, in hand
        var convertMs = 0.0       // AVFrame → destination
        var totalMs: Double { seekMs + decodeMs + convertMs }
        var deliveredSeconds = 0.0
        var framesWalked = 0      // decoded and DISCARDED to reach the target
        var packetsRead = 0
    }

    /// ⚠️ THE SEEK AND THE DECODE ARE TIMED SEPARATELY, and the frames walked are counted, because
    /// "the seek is cheap" and "the path is cheap" are different claims and DNxHR being all-intra
    /// only supports the first one directly. Copied structurally from
    /// `LibavThumbnailSource.decodeThumbnail` / `LibavFrameSource.nextFrame` — same
    /// `AVSEEK_FLAG_BACKWARD`, same flush, same send/receive loop, same "discard pre-target" rule.
    func seekAndDecode(to seconds: Double) -> SeekResult? {
        guard let fmtCtx, let codecCtx, let pkt, let frame else { return nil }
        var r = SeekResult()

        let t0 = CACurrentMediaTime()
        let target = startTimeTicks + Int64((seconds * Double(timeBase.den) / Double(timeBase.num)).rounded())
        av_seek_frame(fmtCtx, videoStreamIndex, target, AVSEEK_FLAG_BACKWARD)
        avcodec_flush_buffers(codecCtx)
        let t1 = CACurrentMediaTime()
        r.seekMs = (t1 - t0) * 1000

        var got = false
        while true {
            let ret = avcodec_receive_frame(codecCtx, frame)
            if ret == 0 {
                let ts = frame.pointee.best_effort_timestamp != Int64.min
                    ? frame.pointee.best_effort_timestamp : frame.pointee.pts
                let sec = Double(ts - startTimeTicks) * Double(timeBase.num) / Double(timeBase.den)
                if sec + 1e-6 < seconds { av_frame_unref(frame); r.framesWalked += 1; continue }
                r.deliveredSeconds = sec
                got = true
                break
            }
            if ret == errEOF { break }
            if ret != errEAGAIN { break }
            let rret = av_read_frame(fmtCtx, pkt)
            if rret < 0 { _ = avcodec_send_packet(codecCtx, nil); continue }
            r.packetsRead += 1
            if pkt.pointee.stream_index == videoStreamIndex { _ = avcodec_send_packet(codecCtx, pkt) }
            av_packet_unref(pkt)
        }
        guard got else { return nil }
        r.decodeMs = (CACurrentMediaTime() - t1) * 1000
        return r
    }

    /// Plain "decode the next frame" — no seek, no discard. The playback pump in `MODE=memory`
    /// uses it to model `LibavFrameSource.nextFrame` running continuously.
    func seekAndDecodeInternalNext() -> SeekResult? {
        guard let fmtCtx, let codecCtx, let pkt, let frame else { return nil }
        var r = SeekResult()
        let t1 = CACurrentMediaTime()
        while true {
            let ret = avcodec_receive_frame(codecCtx, frame)
            if ret == 0 {
                let ts = frame.pointee.best_effort_timestamp != Int64.min
                    ? frame.pointee.best_effort_timestamp : frame.pointee.pts
                r.deliveredSeconds = Double(ts - startTimeTicks) * Double(timeBase.num) / Double(timeBase.den)
                r.decodeMs = (CACurrentMediaTime() - t1) * 1000
                return r
            }
            if ret == errEOF || ret != errEAGAIN { return nil }
            let rret = av_read_frame(fmtCtx, pkt)
            if rret < 0 { _ = avcodec_send_packet(codecCtx, nil); continue }
            r.packetsRead += 1
            if pkt.pointee.stream_index == videoStreamIndex { _ = avcodec_send_packet(codecCtx, pkt) }
            av_packet_unref(pkt)
        }
    }

    /// Call after `seekAndDecode` — the decoded frame is still held (not unref'd) until `release()`.
    func release() { if let frame { av_frame_unref(frame) } }
    var heldFrame: UnsafeMutablePointer<AVFrame>? { frame }

    // MARK: destination 2 — x420 CVPixelBuffer
    //
    // ⚠️ COPIED FROM `LibavFrameSource.convert`, including the swscale destination format, the
    // "force src/dst range EQUAL → no range remap" line and the three colour attachments. The ONE
    // deliberate difference is `reuseSws`: the app builds a fresh `sws_getContext` for EVERY frame
    // and frees it on the way out. Both are measured.
    func convertToPixelBuffer(reuseSws: Bool) -> (ms: Double, pb: CVPixelBuffer)? {
        guard let f = frame else { return nil }
        let t0 = CACurrentMediaTime()
        let W = Int(f.pointee.width), H = Int(f.pointee.height)
        let srcFmt = AVPixelFormat(f.pointee.format)
        guard let pool = ensurePool(width: W, height: H) else { return nil }
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess,
              let pixelBuffer = pbOut else { return nil }

        let dstFmt: AVPixelFormat = (kPixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || kPixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12

        var ctxToUse: UnsafeMutablePointer<SwsContext>?
        if reuseSws {
            if sws == nil || swsKey != (W, H, srcFmt.rawValue) {
                if let s = sws { sws_freeContext(s) }
                sws = sws_getContext(Int32(W), Int32(H), srcFmt, Int32(W), Int32(H), dstFmt,
                                     Int32(SWS_BILINEAR.rawValue), nil, nil, nil)
                swsKey = (W, H, srcFmt.rawValue)
                if let s = sws {
                    let coeff = sws_getCoefficients(SWS_CS_ITU709)
                    let rr: Int32 = (f.pointee.color_range == AVCOL_RANGE_JPEG) ? 1 : 0
                    _ = sws_setColorspaceDetails(s, coeff, rr, coeff, rr, 0, 1 << 16, 1 << 16)
                }
            }
            ctxToUse = sws
        } else {
            ctxToUse = sws_getContext(Int32(W), Int32(H), srcFmt, Int32(W), Int32(H), dstFmt,
                                      Int32(SWS_BILINEAR.rawValue), nil, nil, nil)
            if let s = ctxToUse {
                let coeff = sws_getCoefficients(SWS_CS_ITU709)
                let rr: Int32 = (f.pointee.color_range == AVCOL_RANGE_JPEG) ? 1 : 0
                _ = sws_setColorspaceDetails(s, coeff, rr, coeff, rr, 0, 1 << 16, 1 << 16)
            }
        }
        guard let swsCtx = ctxToUse else { return nil }
        defer { if !reuseSws { sws_freeContext(swsCtx) } }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let srcData: [UnsafePointer<UInt8>?] = [
            UnsafePointer(f.pointee.data.0), UnsafePointer(f.pointee.data.1),
            UnsafePointer(f.pointee.data.2), UnsafePointer(f.pointee.data.3)
        ]
        var srcStride: [Int32] = [f.pointee.linesize.0, f.pointee.linesize.1, f.pointee.linesize.2, f.pointee.linesize.3]
        var dst: [UnsafeMutablePointer<UInt8>?] = [
            CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
            CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self),
            nil, nil
        ]
        var dstStride: [Int32] = [
            Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)),
            Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)), 0, 0
        ]
        let scaled = sws_scale(swsCtx, srcData, &srcStride, 0, Int32(H), &dst, &dstStride)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        guard scaled > 0 else { return nil }

        // The three attachments LibavFrameSource sets — they are what makes the buffer honest to
        // the renderer, and they cost nothing, but omitting them here would measure a cheaper
        // buffer than the app produces.
        if let m = Self.cvMatrix(f.pointee.colorspace) {
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, m, .shouldPropagate)
        }
        if let p = Self.cvPrimaries(f.pointee.color_primaries) {
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, p, .shouldPropagate)
        }
        if let t = Self.cvTransfer(f.pointee.color_trc) {
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, t, .shouldPropagate)
        }
        return ((CACurrentMediaTime() - t0) * 1000, pixelBuffer)
    }

    // MARK: destination 3 — the SHIPPING thumbnail path
    //
    // ⚠️ COPIED FROM `LibavThumbnailSource.makeCGImage`: swscale straight to 8-bit RGBA in a
    // 960×540 aspect-fit box, 709 coefficients, source range expanded to full (dstRange = 1), then
    // a `CGImage` over a `Data` copy. It is here to PRICE THE PATH BEING REPLACED, and it is also
    // the mechanism behind the HDR answer — 8-bit RGBA is SDR by construction.
    func thumbnailPath() -> (ms: Double, image: CGImage?)? {
        guard let f = frame else { return nil }
        let t0 = CACurrentMediaTime()
        let W = Int(f.pointee.width), H = Int(f.pointee.height)
        guard W > 0, H > 0 else { return nil }
        let scale = min(960.0 / Double(W), 540.0 / Double(H), 1.0)
        let tW = max(2, (Int(Double(W) * scale) / 2) * 2)
        let tH = max(2, (Int(Double(H) * scale) / 2) * 2)
        let srcFmt = AVPixelFormat(f.pointee.format)
        if swsThumb == nil || swsThumbKey != (W, H, srcFmt.rawValue) {
            if let s = swsThumb { sws_freeContext(s) }
            swsThumb = sws_getContext(Int32(W), Int32(H), srcFmt, Int32(tW), Int32(tH), AV_PIX_FMT_RGBA,
                                      Int32(SWS_BILINEAR.rawValue), nil, nil, nil)
            swsThumbKey = (W, H, srcFmt.rawValue)
            if let s = swsThumb {
                let coeff = sws_getCoefficients(SWS_CS_ITU709)
                let srcRange: Int32 = (f.pointee.color_range == AVCOL_RANGE_JPEG) ? 1 : 0
                _ = sws_setColorspaceDetails(s, coeff, srcRange, coeff, 1, 0, 1 << 16, 1 << 16)
            }
        }
        guard let s = swsThumb else { return nil }
        let bytesPerRow = tW * 4
        var buf = [UInt8](repeating: 0, count: bytesPerRow * tH)
        let srcData: [UnsafePointer<UInt8>?] = [
            UnsafePointer(f.pointee.data.0), UnsafePointer(f.pointee.data.1),
            UnsafePointer(f.pointee.data.2), UnsafePointer(f.pointee.data.3)
        ]
        var srcStride: [Int32] = [f.pointee.linesize.0, f.pointee.linesize.1, f.pointee.linesize.2, f.pointee.linesize.3]
        let scaled: Int32 = buf.withUnsafeMutableBytes { raw in
            var dst: [UnsafeMutablePointer<UInt8>?] = [raw.baseAddress?.assumingMemoryBound(to: UInt8.self), nil, nil, nil]
            var dstStride: [Int32] = [Int32(bytesPerRow), 0, 0, 0]
            return sws_scale(s, srcData, &srcStride, 0, Int32(H), &dst, &dstStride)
        }
        guard scaled > 0 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
        let img = CGImage(width: tW, height: tH, bitsPerComponent: 8, bitsPerPixel: 32,
                          bytesPerRow: bytesPerRow, space: cs, bitmapInfo: bitmapInfo,
                          provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        return ((CACurrentMediaTime() - t0) * 1000, img)
    }

    private func ensurePool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool, poolSize == (width, height) { return pool }
        let pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kPixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]() as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        // ⚠️ 20, from LibavFrameSource.ensurePool. A scrub producer needs far fewer, but a smaller
        // pool would under-report the memory a copy of that code would actually cost.
        let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 20]
        var newPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, pbAttrs as CFDictionary, &newPool) == kCVReturnSuccess else { return nil }
        pool = newPool; poolSize = (width, height)
        return newPool
    }

    private static func cvMatrix(_ s: AVColorSpace) -> CFString? {
        switch s {
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: return kCVImageBufferYCbCrMatrix_ITU_R_2020
        case AVCOL_SPC_SMPTE170M, AVCOL_SPC_BT470BG: return kCVImageBufferYCbCrMatrix_ITU_R_601_4
        default: return kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }
    }
    private static func cvPrimaries(_ p: AVColorPrimaries) -> CFString? {
        switch p {
        case AVCOL_PRI_BT709: return kCVImageBufferColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_BT2020: return kCVImageBufferColorPrimaries_ITU_R_2020
        case AVCOL_PRI_SMPTE432: return kCVImageBufferColorPrimaries_P3_D65
        default: return nil
        }
    }
    private static func cvTransfer(_ t: AVColorTransferCharacteristic) -> CFString? {
        switch t {
        case AVCOL_TRC_BT709: return kCVImageBufferTransferFunction_ITU_R_709_2
        case AVCOL_TRC_SMPTE2084: return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_ARIB_STD_B67: return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        default: return nil
        }
    }
}

// MARK: - positions
//
// ⚠️ IDENTICAL to scrubmeas.swift / avpvomeas.swift: spread across the duration and jittered OFF
// the frame grid by a golden-ratio sub-frame offset. Boundary-only sampling cannot see a rounding
// disagreement at all, and these runs are meant to be read next to those tables.
func positions(_ n: Int, dur: Double, fd: Double) -> [Double] {
    (0..<n).map { i -> Double in
        let base = dur * (Double(i) + 0.5) / Double(n)
        let phi = (Double(i) * 0.6180339887498949).truncatingRemainder(dividingBy: 1.0)
        return max(fd, min(base + (phi - 0.5) * fd, dur - 2 * fd))
    }
}

/// Can AVFoundation open this file at all? THE reason this harness exists — for MXF the answer is
/// no, and it is asserted per file rather than assumed from the extension.
func avfOpens(_ url: URL) -> (ok: Bool, detail: String) {
    let asset = AVURLAsset(url: url)
    let sem = DispatchSemaphore(value: 0)
    var ok = false, detail = "no video track"
    Task {
        if let t = try? await asset.loadTracks(withMediaType: .video).first {
            ok = true
            let size = (try? await t.load(.naturalSize)) ?? .zero
            var codec = "????"
            if let fds = try? await t.load(.formatDescriptions), let fd = fds.first {
                let c = CMFormatDescriptionGetMediaSubType(fd)
                codec = String(bytes: [UInt8((c >> 24) & 0xff), UInt8((c >> 16) & 0xff),
                                       UInt8((c >> 8) & 0xff), UInt8(c & 0xff)], encoding: .ascii) ?? "????"
            }
            detail = "\(codec) \(Int(size.width))x\(Int(size.height))"
        }
        sem.signal()
    }
    sem.wait()
    return (ok, detail)
}

func fileGB(_ url: URL) -> Double {
    let b = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? 0
    return Double(b) / 1e9
}

func header(_ url: URL) {
    print("\n" + String(repeating: "=", count: 108))
    print("FILE  \(url.path)")
}

// MARK: - MODE=probe

func probeRun(_ url: URL) {
    let d = LibavScrubDecoder(url: url, threads: THREADS)
    guard d.open() else { print("  \(pad(url.lastPathComponent, 46)) !! libav could not open"); return }
    defer { d.free() }
    let gb = fileGB(url)
    let mbps = d.durationSeconds > 0 ? gb * 1e9 * 8 / d.durationSeconds / 1e6 : .nan
    let avf = avfOpens(url)
    print("  \(pad(url.lastPathComponent, 46)) \(pad(d.codecName, 8)) \(pad("\(d.width)x\(d.height)", 11)) \(lpad(fmt(d.frameRate, 3), 7)) fps  \(lpad(fmt(d.durationSeconds, 1), 8))s  \(lpad(fmt(gb, 2), 6)) GB  \(lpad(fmt(mbps, 0), 6)) Mb/s")
    print("      pix \(pad(d.pixFmtName, 14)) range \(pad(d.rangeName, 12)) trc \(pad(d.trcName, 12)) pri \(pad(d.priName, 12)) mat \(d.matName)")
    print("      threading: \(d.threadingLabel)\(d.activeThreadType & kThreadFrame != 0 ? "   ⚠️ FRAME threading — a flushed decoder emits nothing until \(d.threads) frames are in" : "")")
    print("      streams \(d.nbStreams)   open \(fmt(d.openInputMs)) + find_stream_info \(fmt(d.findInfoMs)) + codec_open \(fmt(d.codecOpenMs)) = \(fmt(d.openTotalMs)) ms")
    print("      AVFoundation can open it: \(avf.ok ? "YES — \(avf.detail)" : "NO  ← this file has no route but libav")")
}

// MARK: - MODE=latency  — THE QUESTION

func latencyRun(_ url: URL) {
    header(url)
    probeRun(url)

    // Facts needed for positions, from a throwaway open — so the COLD trials below are genuinely
    // the first open of the run for their own contexts.
    let facts = LibavScrubDecoder(url: url, threads: THREADS)
    guard facts.open() else { return }
    let dur = facts.durationSeconds
    let fps = facts.frameRate > 0 ? facts.frameRate : 24
    let fd = 1.0 / fps
    facts.free()
    guard dur > 0.5 else { print("  !! unusable duration"); return }

    let stage: ShaderStage? = WANT_SHADER ? ShaderStage() : nil
    if WANT_SHADER && stage == nil { print("  !! Metal stage unavailable — shader pass skipped") }
    print("\n  decode threads \(THREADS) of \(CORES) cores (LibavThumbnailSource's shipping choice: max(2, cores/2) = \(max(2, CORES/2)))   THREADTYPE=\(THREADTYPE)")

    // ── COLD ────────────────────────────────────────────────────────────────────────────────────
    //
    // ⚠️ WHAT "COLD" EVEN MEANS ON THIS PATH IS A FINDING, NOT A SETTING. avpvomeas.swift's cold
    // case was a FRESH AVPlayer per trial, because the premise of that route is a decoder that
    // stays warm across a drag. The libav equivalent is a fresh AVFormatContext + decoder per
    // trial, and it is measured the same way here. But the two are not the same kind of cold, and
    // the difference is reported rather than smoothed over — see the WARM note below.
    var coldTotal: [Double] = [], coldOpen: [Double] = [], coldFind: [Double] = []
    let coldPos = positions(5, dur: dur, fd: fd)
    for p in coldPos {
        let d = LibavScrubDecoder(url: url, threads: THREADS)
        guard d.open() else { continue }
        coldOpen.append(d.openTotalMs); coldFind.append(d.findInfoMs)
        if let r = d.seekAndDecode(to: p), let c = d.convertToPixelBuffer(reuseSws: true) {
            coldTotal.append(r.totalMs + c.ms)
        }
        d.release(); d.free()
    }
    print("\n  ── COLD (fresh AVFormatContext + decoder each trial) " + String(repeating: "─", count: 52))
    print("    seek→decode→x420 buffer in hand          \(Dist(coldTotal).row)")
    print("    install cost (open + find_stream_info + codec_open, NOT in the per-seek budget)")
    print("        total                                \(Dist(coldOpen).row)")
    print("        of which find_stream_info            \(Dist(coldFind).row)")

    // ── WARM ────────────────────────────────────────────────────────────────────────────────────
    //
    // ⚠️ "WARM" IS A WEAKER PROPERTY HERE THAN IT IS FOR AVPlayer, AND THE DIFFERENCE IS THE POINT
    // OF THIS SECTION. What a held libav context keeps across a seek is: the demuxer and its index,
    // the open file handle, the decoder's threads and tables, the pixel-buffer pool and the swscale
    // context. What it DOES NOT keep is decoder STATE — `avcodec_flush_buffers` after every
    // `av_seek_frame` discards it by design and by necessity. On all-intra that costs nothing
    // (there is no reference state to lose). On long-GOP it means every seek re-enters at a
    // keyframe and walks, which is exactly what the `framesWalked` column reports.
    let warm = LibavScrubDecoder(url: url, threads: THREADS)
    guard warm.open() else { return }
    defer { warm.free() }
    _ = warm.seekAndDecode(to: positions(3, dur: dur, fd: fd)[1]); warm.release()   // prime; discarded

    struct PassCfg { let label: String; let pace: Double; let reuseSws: Bool; let thumb: Bool; let shade: Bool }
    var passes: [PassCfg] = [
        PassCfg(label: "back-to-back  → x420 CVPixelBuffer", pace: 0.0, reuseSws: true, thumb: false, shade: false),
        PassCfg(label: "paced 20 Hz   → x420 CVPixelBuffer", pace: 0.050, reuseSws: true, thumb: false, shade: false),
        PassCfg(label: "paced 20 Hz   → x420, FRESH sws ctx", pace: 0.050, reuseSws: false, thumb: false, shade: false),
        PassCfg(label: "paced 20 Hz   → 960x540 RGBA CGImage", pace: 0.050, reuseSws: true, thumb: true, shade: false)
    ]
    if stage != nil {
        passes.append(PassCfg(label: "paced 20 Hz   → x420 + SHADER→offscreen", pace: 0.050, reuseSws: true, thumb: false, shade: true))
    }

    print("\n  ── WARM (one held context for the whole drag) " + String(repeating: "─", count: 59))
    for cfg in passes {
        var tot: [Double] = [], seek: [Double] = [], dec: [Double] = [], conv: [Double] = [], sh: [Double] = []
        var off: [Double] = [], walked: [Double] = [], pkts: [Double] = []
        var fails = 0
        let pos = positions(N, dur: dur, fd: fd)
        let runStart = CACurrentMediaTime()
        for (i, p) in pos.enumerated() {
            if cfg.pace > 0 {
                let due = runStart + Double(i) * cfg.pace
                let wait = due - CACurrentMediaTime()
                if wait > 0 { usleep(useconds_t(wait * 1e6)) }
            }
            guard let r = warm.seekAndDecode(to: p) else { fails += 1; continue }
            var t = r.seekMs + r.decodeMs
            if cfg.thumb {
                guard let th = warm.thumbnailPath() else { warm.release(); fails += 1; continue }
                conv.append(th.ms); t += th.ms
            } else {
                guard let c = warm.convertToPixelBuffer(reuseSws: cfg.reuseSws) else { warm.release(); fails += 1; continue }
                conv.append(c.ms); t += c.ms
                if cfg.shade, let s = stage, let sm = s.render(c.pb) { sh.append(sm); t += sm }
            }
            warm.release()
            seek.append(r.seekMs); dec.append(r.decodeMs); tot.append(t)
            off.append((r.deliveredSeconds - p) / fd)
            walked.append(Double(r.framesWalked)); pkts.append(Double(r.packetsRead))
        }
        let elapsed = CACurrentMediaTime() - runStart
        print("    \(pad(cfg.label, 40)) \(Dist(tot).row)")
        print("        achieved \(fmt(Double(pos.count) / elapsed, 1)) seeks/s   failures \(fails)   OVER 50 ms: \(tot.filter { $0 > 50 }.count)/\(tot.count)")
        print("        breakdown  seek \(lpad(fmt(Dist(seek).mean, 2), 6))   decode \(lpad(fmt(Dist(dec).mean, 2), 6))   \(cfg.thumb ? "thumb " : "convert")\(lpad(fmt(Dist(conv).mean, 2), 6))\(cfg.shade ? "   shader \(lpad(fmt(Dist(sh).mean, 2), 6))" : "")   (mean ms)")
        print("        delivered frame − requested, |frames|:   \(Dist(off.map { abs($0) }).row)")
        print("        frames decoded and DISCARDED to reach it: \(Dist(walked).row)")
        print("        packets read per seek:                    \(Dist(pkts).row)")
    }
}

// MARK: - MODE=threads
//
// The two existing libav clients DISAGREE about thread_count and both comments give reasons:
// `LibavFrameSource` uses cores−1 ("thread_count=0 saturated EVERY core at decode priority,
// starving the Metal scope-compute completion callbacks"), `LibavThumbnailSource` uses cores/2
// ("so a stray decode never saturates the machine or contends with resumed playback"). A
// seek-to-renderer path inherits that choice and it is the cheapest lever on the latency number,
// so it is swept rather than assumed.
func threadsRun(_ url: URL) {
    header(url)
    let facts = LibavScrubDecoder(url: url, threads: 1)
    guard facts.open() else { return }
    let dur = facts.durationSeconds, fps = facts.frameRate > 0 ? facts.frameRate : 24
    print("  \(facts.codecName) \(facts.width)x\(facts.height) \(fmt(fps,3)) fps   \(CORES) cores")
    facts.free()
    let fd = 1.0 / fps
    var sweep = [1, 2, 4, max(2, CORES / 2), max(1, CORES - 1), CORES]
    sweep = Array(Set(sweep)).sorted()
    // ⚠️ BOTH AXES, because they interact and only one of them is currently set by the app.
    // `default` is what both shipping clients get; `slice` is the one-line change under test.
    for (ttName, tt) in [("default", threadTypeValue("default")), ("slice", kThreadSlice)] as [(String, Int32?)] {
    print("    ── thread_type = \(ttName) " + String(repeating: "─", count: 40))
    for th in sweep {
        let d = LibavScrubDecoder(url: url, threads: th, threadType: tt)
        guard d.open() else { continue }
        _ = d.seekAndDecode(to: positions(3, dur: dur, fd: fd)[1]); d.release()
        var tot: [Double] = []
        let pos = positions(N, dur: dur, fd: fd)
        let runStart = CACurrentMediaTime()
        for (i, p) in pos.enumerated() {
            let due = runStart + Double(i) * 0.050
            let wait = due - CACurrentMediaTime()
            if wait > 0 { usleep(useconds_t(wait * 1e6)) }
            guard let r = d.seekAndDecode(to: p), let c = d.convertToPixelBuffer(reuseSws: true) else { d.release(); continue }
            tot.append(r.totalMs + c.ms); d.release()
        }
        let tag = th == max(2, CORES / 2) ? "  ← LibavThumbnailSource thread_count" : th == max(1, CORES - 1) ? "  ← LibavFrameSource thread_count" : ""
        print("      threads \(lpad(String(th), 2))  \(Dist(tot).row)   [\(d.threadingLabel)]\(tag)")
        d.free()
    }
    }
}

// MARK: - MODE=memory
//
// Same three phases as avpvomeas.swift, and deliberately the same shape so the two tables subtract:
// playback alone, playback PLUS a live scrub decoder dragging at 20 Hz, playback again with the
// scrub decoder released. Cost of the second pipeline = P2 − P1.
//
// ⚠️ "PLAYBACK" HERE IS A LIBAV PUMP, NOT AN AVAssetReader — because on MXF there is no
// AVAssetReader to have. It is modelled on `LibavFrameSource`: its decoder settings (cores−1
// threads), its x420 conversion, its 20-buffer pool, each frame rendered through the shader, paced
// to real time by PTS. No audio decode, no `AVSampleBufferDisplayLayer`, no DeckLink staging, no
// scopes — so the ABSOLUTE footprint is a floor and the DELTA is the measurement.
//
// ⚠️ AND THIS PHASE IS THE ONLY PLACE THE "THUMBNAILS DELIBERATELY OPEN THEIR OWN CONTEXT SO SEEKS
// NEVER TOUCH THE PLAYBACK ONE" CLAIM IS ACTUALLY TESTED. Everything else in this harness runs the
// scrub decoder alone, where the claim is untestable by construction.
final class LibavPlaybackPump {
    private var thread: Thread?
    private var stopFlag = false
    private let url: URL
    private let stage: ShaderStage?
    private(set) var framesDecoded = 0
    private(set) var restarts = 0
    /// Frames whose real-time due moment had ALREADY PASSED when they were ready — a late frame is
    /// what "playback lost a frame to the second pipeline" looks like on this pump.
    private(set) var lateFrames = 0

    init(url: URL, stage: ShaderStage?) { self.url = url; self.stage = stage }
    func start() {
        let t = Thread { [weak self] in self?.loop() }
        t.qualityOfService = .userInteractive
        thread = t; t.start()
    }
    func stop() { stopFlag = true; while thread?.isFinished == false { usleep(1000) } }

    private func loop() {
        var hold: [CVPixelBuffer] = []
        while !stopFlag {
            // ⚠️ cores−1 AND libav's DEFAULT thread_type — both of LibavFrameSource's actual
            // choices, pinned here rather than inherited from THREADTYPE. Frame threading is the
            // right choice for continuous playback (the delay is a pipeline that fills once) and it
            // is what ships; letting the scrub experiment's setting leak into the playback model
            // would change the thing the scrub decoder is supposed to be contending WITH.
            let d = LibavScrubDecoder(url: url, threads: max(1, CORES - 1), threadType: threadTypeValue("default"))
            guard d.open() else { return }
            restarts += 1
            _ = d.seekAndDecode(to: 0); d.release()
            let start = CACurrentMediaTime()
            var firstPts: Double? = nil
            // Sequential decode from the head. seekAndDecode(to: -1) never discards, so it is a
            // plain "next frame" — the same send/receive loop LibavFrameSource.nextFrame runs.
            while !stopFlag {
                guard let r = d.seekAndDecodeNext() else { break }
                if firstPts == nil { firstPts = r.deliveredSeconds }
                if let c = d.convertToPixelBuffer(reuseSws: true) {
                    _ = stage?.render(c.pb)
                    hold.append(c.pb); if hold.count > 3 { hold.removeFirst() }
                }
                d.release()
                framesDecoded += 1
                let due = start + (r.deliveredSeconds - (firstPts ?? 0))
                let wait = due - CACurrentMediaTime()
                if wait > 0 { usleep(useconds_t(min(wait, 0.5) * 1e6)) } else if wait < -0.010 { lateFrames += 1 }
            }
            d.free()
            if stopFlag { break }
        }
    }
}

final class MemSampler {
    private var thread: Thread?
    private var stop = false
    private(set) var peakRSS = 0.0, peakFootprint = 0.0
    func start() {
        peakRSS = 0; peakFootprint = 0; stop = false
        let t = Thread { [weak self] in
            while self?.stop == false {
                guard let s = self else { return }
                s.peakRSS = max(s.peakRSS, residentMB())
                s.peakFootprint = max(s.peakFootprint, footprintMB())
                usleep(50_000)
            }
        }
        thread = t; t.start()
    }
    func finish() { stop = true; while thread?.isFinished == false { usleep(1000) } }
}

func memoryRun(_ url: URL) {
    header(url)
    probeRun(url)
    let facts = LibavScrubDecoder(url: url, threads: THREADS)
    guard facts.open() else { return }
    let dur = facts.durationSeconds
    facts.free()
    print("  transport: \(url.path.hasPrefix("/Volumes/") ? "SMB (/Volumes)" : "local APFS")   phase length \(fmt(T, 0))s each")

    let stage = ShaderStage()
    if stage == nil { print("  !! Metal unavailable — playback model will not render") }

    var phaseVM: [String: VMMap] = [:]
    func phase(_ name: String, _ body: () -> String) {
        let s = MemSampler(); s.start()
        let d0 = diskReadMB(), n0 = netInMB()
        let extra = body()
        let vm = vmmapSummary()      // while THIS phase's load is still up
        phaseVM[name] = vm
        s.finish()
        let d1 = diskReadMB(), n1 = netInMB()
        print("    \(pad(name, 36)) peak RSS \(lpad(fmt(s.peakRSS, 0), 6)) MB   peak footprint \(lpad(fmt(s.peakFootprint, 0), 6)) MB   diskIO \(lpad(fmt(d1 - d0, 0), 6)) MB (\(lpad(fmt((d1 - d0) / T, 0), 5)) MB/s)   net(machine) \(lpad(fmt(n1 - n0, 0), 6)) MB (\(lpad(fmt((n1 - n0) / T, 0), 5)) MB/s)")
        print("        vmmap at phase end:  footprint \(lpad(fmt(vm.footprintMB, 0), 6))   CoreMedia pool \(lpad(fmtOpt(vm.coreMediaDirtyMB, 0), 6))   IOSurface mapped \(lpad(fmt(vm.ioSurfaceVirtualMB, 0), 6))   GPU \(lpad(fmt(vm.graphicsDirtyMB, 0), 6))   TOTAL dirty \(lpad(fmt(vm.totalDirtyMB, 0), 6))  (MB)")
        if !extra.isEmpty { print("        \(extra)") }
        // ⚠️ A phase reading ~0 after an earlier phase read the whole file is the PAGE CACHE, not a
        // pipeline that stopped reading. Flagged rather than left to be misread as a measurement.
        if (d1 - d0) < 1, (n1 - n0) < 1 { print("        ⚠️ ~0 bytes moved this phase — the file is in the page cache. THIS PHASE CARRIES NO IO INFORMATION.") }
    }

    print("\n    baseline at entry: RSS \(fmt(residentMB(), 0)) MB  footprint \(fmt(footprintMB(), 0)) MB")
    let pump = LibavPlaybackPump(url: url, stage: stage)
    phase("P1  playback alone") {
        pump.start(); usleep(useconds_t(T * 1e6))
        return "decoded \(pump.framesDecoded) frames, \(pump.restarts) decoder start(s), \(pump.lateFrames) late"
    }
    let f1 = pump.framesDecoded, l1 = pump.lateFrames

    var scrub: LibavScrubDecoder? = nil
    var lat: [Double] = []
    var installMs = 0.0
    phase("P2  playback + scrub decode @20Hz") {
        let s = LibavScrubDecoder(url: url, threads: THREADS)
        guard s.open() else { return "!! scrub decoder open FAILED" }
        scrub = s; installMs = s.openTotalMs
        let start = CACurrentMediaTime()
        var i = 0
        while CACurrentMediaTime() - start < T {
            let due = start + Double(i) * 0.050
            let wait = due - CACurrentMediaTime()
            if wait > 0 { usleep(useconds_t(wait * 1e6)) }
            let phi = (Double(i) * 0.6180339887498949).truncatingRemainder(dividingBy: 1.0)
            let p = max(0.1, min(phi * dur, dur - 0.2))
            if let r = s.seekAndDecode(to: p), let c = s.convertToPixelBuffer(reuseSws: true) {
                lat.append(r.totalMs + c.ms); _ = stage?.render(c.pb)
            }
            s.release()
            i += 1
        }
        return "scrub seeks UNDER PLAYBACK LOAD: \(Dist(lat).row)   over 50 ms \(lat.filter { $0 > 50 }.count)/\(lat.count)   install \(fmt(installMs, 0)) ms"
    }
    let f2 = pump.framesDecoded - f1, l2 = pump.lateFrames - l1

    scrub?.free(); scrub = nil
    phase("P3  playback alone (scrub released)") {
        usleep(useconds_t(T * 1e6))
        return "decoded \(pump.framesDecoded - f1 - f2) frames"
    }
    pump.stop()
    print("    playback frames: P1 \(f1)  P2 \(f2)   late frames: P1 \(l1)  P2 \(l2)  ← a drop in P2, or late frames appearing, is the second pipeline STEALING FROM PLAYBACK")
    print("    process peak RSS overall: \(fmt(residentPeakMB(), 0)) MB")

    if let a = phaseVM["P1  playback alone"], let b = phaseVM["P2  playback + scrub decode @20Hz"],
       let c = phaseVM["P3  playback alone (scrub released)"] {
        print("    ┌ COST OF THE SECOND PIPELINE (P2 − P1)")
        print("    │   physical footprint      \(lpad(fmt(b.footprintMB - a.footprintMB, 0), 7)) MB")
        print("    │   CoreMedia pool          \(lpad(fmtOpt(b.coreMediaDirtyMB - a.coreMediaDirtyMB, 0), 7)) MB   ← absent by construction: libav is not CoreMedia; its buffers land in IOSurface below")
        print("    │   IOSurface mapped        \(lpad(fmt(b.ioSurfaceVirtualMB - a.ioSurfaceVirtualMB, 0), 7)) MB")
        print("    │   GPU (owned unmapped)    \(lpad(fmt(b.graphicsDirtyMB - a.graphicsDirtyMB, 0), 7)) MB")
        print("    │   TOTAL dirty             \(lpad(fmt(b.totalDirtyMB - a.totalDirtyMB, 0), 7)) MB")
        print("    └ RETURNED ON RELEASE (P2 − P3): footprint \(fmt(b.footprintMB - c.footprintMB, 0)) MB   CoreMedia \(fmtOpt(b.coreMediaDirtyMB - c.coreMediaDirtyMB, 0)) MB   TOTAL dirty \(fmt(b.totalDirtyMB - c.totalDirtyMB, 0)) MB")
    }
}

// MARK: - MODE=io
//
// ⚠️ WHY THIS EXISTS SEPARATELY FROM `MODE=memory`, AND IT IS AN INSTRUMENT PROBLEM, NOT A NEW
// QUESTION. `MODE=memory` reads the second pipeline's IO as P2 − P1. That subtraction is only valid
// while NEITHER phase is served from cache — and EVERY 4K MXF IN THIS CORPUS IS SMALL ENOUGH
// (1.4–4.3 GB, on a 64 GB machine) THAT P1 CACHES THE FILE IT IS ABOUT TO MEASURE P2 AGAINST. The
// long-form 1080p files (26 GB, 42 GB) are immune and give a clean delta there; at 4K there is no
// such file, and `sudo purge` is not available to this harness.
//
// So at 4K the second pipeline's IO is measured DIRECTLY instead of by subtraction: the scrub
// decoder alone, at 20 Hz, on a file this process has not touched, for a short enough run that the
// positions it visits are mostly first reads. Playback's own rate does not need measuring — it is
// the file's bitrate, printed alongside — so the sum is the honest total.
func ioRun(_ url: URL) {
    header(url)
    let d = LibavScrubDecoder(url: url, threads: THREADS)
    guard d.open() else { return }
    defer { d.free() }
    let gb = fileGB(url)
    let mbps = d.durationSeconds > 0 ? gb * 1e9 * 8 / d.durationSeconds / 1e6 : .nan
    print("  \(d.codecName) \(d.width)x\(d.height) \(fmt(d.frameRate, 3)) fps  \(fmt(gb, 2)) GB  \(fmt(mbps, 0)) Mb/s = \(fmt(mbps / 8, 0)) MB/s  ← playback's own rate, by definition")
    print("  threading: \(d.threadingLabel)   transport: \(url.path.hasPrefix("/Volumes/") ? "SMB (/Volumes)" : "local APFS")")
    print("  SCRUB DECODER ALONE at 20 Hz for \(fmt(T, 0))s — no playback in this process.")

    // ⚠️ TWO DRAG SHAPES, BECAUSE THEY ARE NOT THE SAME IO PROBLEM AND ONLY ONE OF THEM IS WHAT A
    // COLOURIST DOES. `scatter` jumps to a pseudo-random position every tick — the worst case for
    // read-ahead, and the shape `MODE=memory` uses. `sweep` walks forward at ~2 frames per tick,
    // which is what a hand actually does to a scrubber: a short, mostly-sequential excursion. A
    // single number from the scatter case would be a true measurement of a gesture nobody makes.
    for shape in ["scatter", "sweep"] {
        let d0 = diskReadMB(), n0 = netInMB()
        var lat: [Double] = []
        let start = CACurrentMediaTime()
        // `sweep` starts mid-file so it is not reading what a prior phase already pulled.
        let sweepOrigin = d.durationSeconds * 0.37
        let fdur = d.frameRate > 0 ? 1.0 / d.frameRate : 1.0 / 24
        var i = 0
        while CACurrentMediaTime() - start < T {
            let due = start + Double(i) * 0.050
            let wait = due - CACurrentMediaTime()
            if wait > 0 { usleep(useconds_t(wait * 1e6)) }
            let p: Double
            if shape == "scatter" {
                let phi = (Double(i) * 0.6180339887498949).truncatingRemainder(dividingBy: 1.0)
                p = max(0.1, min(phi * d.durationSeconds, d.durationSeconds - 0.2))
            } else {
                p = max(0.1, min(sweepOrigin + Double(i) * 2 * fdur, d.durationSeconds - 0.2))
            }
            if let r = d.seekAndDecode(to: p), let c = d.convertToPixelBuffer(reuseSws: true) {
                lat.append(r.totalMs + c.ms); _ = c
            }
            d.release(); i += 1
        }
        let elapsed = CACurrentMediaTime() - start
        let dd = diskReadMB() - d0, nn = netInMB() - n0
        let onSMB = url.path.hasPrefix("/Volumes/")
        let scrubRate = onSMB ? nn / elapsed : dd / elapsed
        print("    ── \(pad(shape == "scatter" ? "SCATTER (random position each tick — worst case)" : "SWEEP (walks ~2 frames/tick — what a hand does)", 52))")
        print("       seeks \(lat.count) in \(fmt(elapsed, 1))s   \(Dist(lat).row)")
        print("       block IO \(fmt(dd, 0)) MB = \(fmt(dd / elapsed, 0)) MB/s     net(machine) \(fmt(nn, 0)) MB = \(fmt(nn / elapsed, 0)) MB/s")
        print("       ⇒ the drag adds \(fmt(scrubRate, 0)) MB/s = \(fmt(scrubRate * 8, 0)) Mb/s on top of playback's \(fmt(mbps, 0)) Mb/s  → total \(fmt(scrubRate * 8 + mbps, 0)) Mb/s")
        if scrubRate < 1 { print("       ⚠️ ~0 bytes moved — the file is in the page cache. THIS ROW CARRIES NO IO INFORMATION.") }
    }
    print("    ⚠️ read as a RATE, not a total: a drag lasts seconds, not minutes.")
}

// MARK: - MODE=hdr
//
// `LibavThumbnailSource` swscales to 8-BIT RGBA, which is SDR BY CONSTRUCTION — recorded in
// ../BUGS.md as the reason DNx/MXF HDR previews stay SDR and Part 3 of the HDR preview fix was
// deliberately not done. A pixel-buffer path would not do that. This mode answers the two questions
// that leaves open, by measurement rather than by reasoning about the format:
//
//   1. WHAT DOES THE LIBAV DECODE ACTUALLY PRODUCE for this content — pixel format, bit depth,
//      range, and the three colour tags that would ride on the buffer.
//   2. WHAT DOES REACHING x420 COST, and does it PRESERVE THE CODES. The second half is not
//      rhetorical: the conversion is a real resample (10-bit 4:2:2 planar → 10-bit 4:2:0
//      biplanar) and a path that silently remapped range or lost the top of the code space would
//      be an SDR path wearing a 10-bit format. Luma is compared code-for-code, source vs
//      destination, over the whole raster.
func hdrRun(_ url: URL) {
    header(url)
    let d = LibavScrubDecoder(url: url, threads: THREADS)
    guard d.open() else { return }
    defer { d.free() }
    print("  \(d.codecName)  \(d.width)x\(d.height)  \(fmt(d.frameRate, 3)) fps")
    print("  CONTAINER/STREAM tags:  pix \(d.pixFmtName)   range \(d.rangeName)   trc \(d.trcName)   pri \(d.priName)   mat \(d.matName)")

    let t = max(1.0, min(d.durationSeconds * 0.5, d.durationSeconds - 1))
    guard let r = d.seekAndDecode(to: t), let f = d.heldFrame else { print("  !! decode failed"); return }
    _ = r
    let srcFmt = AVPixelFormat(f.pointee.format)
    let srcName = av_get_pix_fmt_name(srcFmt).map { String(cString: $0) } ?? "?"
    let desc = av_pix_fmt_desc_get(srcFmt)
    let depth = desc != nil ? Int(desc!.pointee.comp.0.depth) : -1
    print("  DECODED FRAME:          pix \(srcName)   \(depth)-bit   range \(f.pointee.color_range == AVCOL_RANGE_JPEG ? "full/JPEG" : f.pointee.color_range == AVCOL_RANGE_MPEG ? "legal/MPEG" : "unspecified")   trc \(LibavScrubDecoder.trcLabel(f.pointee.color_trc))")

    // Mastering-display / content-light metadata, if the decode carried any. It is what an EDR
    // path would ultimately need; its ABSENCE is also an answer and is printed as one.
    var sawMDM = false, sawCLL = false
    for i in 0..<Int(f.pointee.nb_side_data) {
        guard let sd = f.pointee.side_data?[i] else { continue }
        if sd.pointee.type == AV_FRAME_DATA_MASTERING_DISPLAY_METADATA { sawMDM = true }
        if sd.pointee.type == AV_FRAME_DATA_CONTENT_LIGHT_LEVEL { sawCLL = true }
    }
    print("  frame side data:        mastering-display \(sawMDM ? "PRESENT" : "absent")   content-light \(sawCLL ? "PRESENT" : "absent")")

    guard let c = d.convertToPixelBuffer(reuseSws: true) else { print("  !! convert failed"); return }
    print("  → x420 CVPixelBuffer:   \(fmt(c.ms, 2)) ms   \(CVPixelBufferGetWidth(c.pb))x\(CVPixelBufferGetHeight(c.pb))")
    for (label, key) in [("matrix", kCVImageBufferYCbCrMatrixKey), ("primaries", kCVImageBufferColorPrimariesKey), ("transfer", kCVImageBufferTransferFunctionKey)] {
        let v = CVBufferCopyAttachment(c.pb, key, nil)
        print("      attachment \(pad(label, 10)) \(v.map { String(describing: $0) } ?? "— NOT SET")")
    }

    // ── CODE PRESERVATION. Only meaningful when both sides are 10-bit planar/biplanar 16-bit. ───
    // ⚠️ 10-bit AND 12-bit are both compared, because x420/P010 IS A 10-BIT CONTAINER and a 12-bit
    // DNxHR source therefore CANNOT survive it. That is not a defect introduced by a scrub path —
    // `LibavFrameSource.convert` sends playback through the identical P010 destination, so the
    // scrub frame and the playback frame agree exactly, which is the property being bought. It is
    // stated here so the truncation is a known, shared property rather than a discovery.
    if (depth == 10 || depth == 12), let sp = f.pointee.data.0 {
        let shift = depth - 10
        CVPixelBufferLockBaseAddress(c.pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(c.pb, .readOnly) }
        let W = Int(f.pointee.width), H = Int(f.pointee.height)
        let srcStride = Int(f.pointee.linesize.0)
        guard let dp = CVPixelBufferGetBaseAddressOfPlane(c.pb, 0) else { return }
        let dstStride = CVPixelBufferGetBytesPerRowOfPlane(c.pb, 0)
        var maxDiff = 0, sumDiff = 0.0, n = 0
        var srcMin = 65535, srcMax = 0, dstMin = 65535, dstMax = 0
        for y in stride(from: 0, to: H, by: 4) {
            let srow = sp.advanced(by: y * srcStride).withMemoryRebound(to: UInt16.self, capacity: W) { $0 }
            let drow = dp.advanced(by: y * dstStride).assumingMemoryBound(to: UInt16.self)
            for x in stride(from: 0, to: W, by: 4) {
                let s = Int(srow[x]) >> shift     // yuv*p1Xle: value in the LOW X bits, → 10-bit
                let dv = Int(drow[x]) >> 6        // P010: value in the HIGH 10 bits
                srcMin = min(srcMin, s); srcMax = max(srcMax, s)
                dstMin = min(dstMin, dv); dstMax = max(dstMax, dv)
                let diff = abs(s - dv)
                maxDiff = max(maxDiff, diff); sumDiff += Double(diff); n += 1
            }
        }
        print("  LUMA CODE PRESERVATION, source → x420 (\(n) samples, 10-bit codes\(shift > 0 ? "; source is \(depth)-bit and was >> \(shift) to compare — x420 IS A 10-BIT CONTAINER" : ""))")
        print("      source range  \(srcMin) … \(srcMax)     x420 range  \(dstMin) … \(dstMax)")
        print("      mean |diff| \(fmt(sumDiff / Double(max(n, 1)), 3))   MAX |diff| \(maxDiff)")
        print("      \(maxDiff == 0 ? "LOSSLESS on luma — no range remap, no truncation" : maxDiff <= 1 ? "±1 code: rounding only" : "⚠️ CODES MOVED — inspect before trusting this path for HDR")")
    } else {
        print("  (code comparison skipped — decoded depth \(depth) is neither the 10- nor the 12-bit case)")
    }

    // ── What the SHIPPING thumbnail path does with the same frame ───────────────────────────────
    if let th = d.thumbnailPath(), let img = th.image {
        print("  SHIPPING thumbnail path (LibavThumbnailSource.makeCGImage): \(fmt(th.ms, 2)) ms  \(img.width)x\(img.height)  \(img.bitsPerComponent)-bit/component  colorSpace \(img.colorSpace?.name.map { ($0 as String) } ?? "nil")")
        print("      ⚠️ 8-bit RGBA in DeviceRGB with dstRange=1 (legal→full expansion). Whatever the")
        print("         source transfer was, the tag does not survive and codes above legal white")
        print("         cannot: this is SDR by construction, which is the recorded reason DNx/MXF")
        print("         HDR previews stay SDR today.")
    }
    d.release()
}

extension LibavScrubDecoder {
    static func trcLabel(_ t: AVColorTransferCharacteristic) -> String {
        av_color_transfer_name(t).map { String(cString: $0) } ?? "?"
    }
    /// Plain "next frame", for the playback pump — no seek, no discard.
    func seekAndDecodeNext() -> SeekResult? { seekAndDecodeInternalNext() }
}

// MARK: - main

let files = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
guard !files.isEmpty else {
    print("usage: MODE=probe|latency|threads|memory|hdr|io [N=40] [T=20] [SHADER=1] [THREADS=n] ./libavmeas FILE...")
    exit(2)
}
print("libavmeas — \(MODE)   \(CORES) cores   N=\(N)  T=\(fmt(T,0))s  SHADER=\(WANT_SHADER ? 1 : 0)  THREADS=\(THREADS)")
print("libav: avformat \(String(cString: av_version_info()))")
if MODE == "probe" { print("\n  \(pad("file", 46)) \(pad("codec", 8)) \(pad("raster", 11))     fps       dur      size    rate") }
for f in files {
    switch MODE {
    case "probe":   probeRun(f)
    case "latency": latencyRun(f)
    case "threads": threadsRun(f)
    case "memory":  memoryRun(f)
    case "hdr":     hdrRun(f)
    case "io":      ioRun(f)
    default: print("unknown MODE \(MODE)"); exit(2)
    }
}
print("")
