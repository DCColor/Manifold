// avpvomeas — can `AVPlayerItemVideoOutput` on a scrub-only `AVPlayer` replace the CGImage overlay?
//
// The route is BANKED and gated in ../BUGS.md → "⏸ BANKED: feed the scrub gesture from
// `AVPlayerItemVideoOutput` — one decoder, one display path", on exactly two unmeasured risks:
//
//   RISK 1  latency at drag rate      — seek → CVPixelBuffer in hand, against the 50 ms / 20 Hz
//                                       preview throttle, warm AND cold.
//   RISK 2  memory and IO of a SECOND decode pipeline on large sources, on a network volume.
//
// This file measures both and NOTHING else. It builds no app, links no app code, changes no app
// behaviour. Same convention as scrubmeas.swift / wincap.swift: single-file script, built on
// demand, not committed as a binary, not in the target (`project.yml`'s `sources:` is `App` plus
// one DeckLink .cpp — nothing under docs/ is globbed in, so no xcodegen run is needed).
//
// ── BUILD AND RUN ───────────────────────────────────────────────────────────────────────────────
//
//   cd docs/scrub-fixtures
//   xcrun swiftc -O -o avpvomeas avpvomeas.swift
//
//   MODE=probe                    ./avpvomeas FILE...     # codec / raster / fps / duration
//   MODE=latency N=40 SHADER=1    ./avpvomeas FILE...     # RISK 1
//   MODE=memory  T=15             ./avpvomeas FILE...     # RISK 2
//
// ⚠️ Do NOT pass -parse-as-library. Single-file script; top-level code is only legal without it,
// and the failure message ("statements are not allowed at the top level") does not name the flag.
// Same trap as scrubmeas.swift.
//
// ── WHAT "LATENCY" MEANS HERE, PRECISELY ────────────────────────────────────────────────────────
//
// t0 is the instant `player.seek(...)` is CALLED. t1 is the instant a `CVPixelBuffer` FOR A FRAME
// WE HAVE NOT ALREADY SEEN is in hand. That span is the whole cost the gesture pays: the async
// seek, the decode, and the vend. It is deliberately measured WITHOUT trusting the seek completion
// handler as the stop signal — a completion callback that fires before the frame is vendable would
// measure the wrong thing, and the completion handler lands on the main queue, which a real 20 Hz
// scrub loop is also competing for.
//
// ⚠️ THE ACCEPTANCE TEST IS A CHANGED DISPLAY TIME, NOT A NON-NIL BUFFER. `copyPixelBuffer` will
// hand back the PRE-SEEK frame if you ask before the new one has decoded, and it is a perfectly
// valid buffer — accepting it would report a latency of ~0 ms for a picture that never changed.
// So each poll reads `itemTimeForDisplay` and only stops when that time differs from the frame we
// accepted last. This is the same class of trap as scrubmeas.swift's marker buffer: a plausible
// wrong number produced by a stop condition that was too easy to satisfy.
//
// A consequence worth stating: when a toleranced seek legitimately lands back on the frame already
// displayed, there is no changed display time to wait for. Those are counted as `same-frame`
// (using the seek completion handler as the stop signal) and reported SEPARATELY rather than being
// folded into the latency distribution or miscounted as timeouts.
//
// ── THE DECODE CONTRACT IS COPIED FROM THE APP ──────────────────────────────────────────────────
//
// x420 (`kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`) — `FrameEngine.videoPixelFormat` and
// `FileFrameSource.defaultPixelFormat`, and the format PassthroughShader.metal's constants are
// written for. Requesting anything else would measure a conversion the app does not do.
import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Metal
import QuartzCore

// ── The app's decode contract. FrameEngine.swift:283 / FileFrameSource.swift:40 ─────────────────
let kPixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

let env = ProcessInfo.processInfo.environment
let MODE = env["MODE"] ?? "latency"
let N = Int(env["N"] ?? "40") ?? 40
let T = Double(env["T"] ?? "15") ?? 15
let WANT_SHADER = (env["SHADER"] ?? "0") != "0"
let SEEK_DEADLINE = Double(env["DEADLINE"] ?? "3.0") ?? 3.0

// MARK: - formatting

func fmt(_ d: Double, _ n: Int = 1) -> String { d.isFinite ? String(format: "%.\(n)f", d) : "  nan" }
func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
func lpad(_ s: String, _ w: Int) -> String { s.count >= w ? s : String(repeating: " ", count: w - s.count) + s }

/// mean / p50 / p90 / max — the shape ../BUGS.md's `exactSeek` table is stated in, so the two are
/// directly comparable. `max` is reported because it is what killed the reader-rebuild route
/// (117.7 ms on all-intra); a mean that fits the budget and a max that does not is a FAILING result.
struct Dist {
    let n: Int, mean: Double, p50: Double, p90: Double, mn: Double, mx: Double
    init(_ v: [Double]) {
        n = v.count
        guard !v.isEmpty else { mean = .nan; p50 = .nan; p90 = .nan; mn = .nan; mx = .nan; return }
        let s = v.sorted()
        mean = v.reduce(0, +) / Double(v.count)
        func pct(_ p: Double) -> Double { s[min(s.count - 1, max(0, Int((p * Double(s.count - 1)).rounded()))) ] }
        p50 = pct(0.5); p90 = pct(0.9); mn = s.first!; mx = s.last!
    }
    /// Fixed-width so a run over several files reads as a table.
    var row: String {
        "n=\(lpad(String(n),3))  mean \(lpad(fmt(mean),6))  p50 \(lpad(fmt(p50),6))  p90 \(lpad(fmt(p90),6))  max \(lpad(fmt(mx),6))  min \(lpad(fmt(mn),6))"
    }
}

// MARK: - process metrics
//
// ⚠️ `phys_footprint` and `resident_size` DO NOT ACCOUNT FOR IOSURFACE-BACKED PIXEL BUFFERS THE
// SAME WAY. A decoder's CVPixelBufferPool is IOSurface-backed and much of it is charged to the
// window server / accounted as purgeable-shared, not to this task's footprint. So these numbers
// are a FLOOR on what a second decode pipeline costs, not a ceiling. They are still the right
// instrument for the question asked — "how much MORE, with the scrub player alive" — because both
// conditions are measured the same way and the difference is what is being read.

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
/// Bytes this process has read from a BLOCK DEVICE. ⚠️ SMB reads DO NOT APPEAR HERE — smbfs is not
/// a block device, so on /Volumes/DCCOLOR this returns ~0 and the network counter below is the
/// instrument. Reporting both makes which transport carried the bytes explicit rather than assumed.
func diskReadMB() -> Double {
    var rui = rusage_info_current()
    let r = withUnsafeMutablePointer(to: &rui) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
        }
    }
    return r == 0 ? Double(rui.ri_diskio_bytesread) / 1048576 : .nan
}
/// MACHINE-WIDE inbound bytes on every non-loopback link. Not per-process — macOS has no cheap
/// per-process network byte counter — so it is only meaningful as a DELTA across a phase on an
/// otherwise quiet machine, and it is labelled that way in the output.
func netInMB() -> Double {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat"); p.arguments = ["-ibn"]
    let pipe = Pipe(); p.standardOutput = pipe
    guard (try? p.run()) != nil else { return .nan }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    var total: Double = 0
    for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count > 6, f[0].hasPrefix("en") || f[0].hasPrefix("bridge"), f[2].hasPrefix("<Link") || f[2].hasPrefix("Link") else { continue }
        total += Double(f[6]) ?? 0
    }
    return total / 1048576
}

/// ⚠️ THE REASON `resident_size` AND `phys_footprint` ARE NOT ENOUGH ON THEIR OWN.
///
/// A decoder's `CVPixelBufferPool` is IOSURFACE-BACKED, and IOSurface pages are not charged to this
/// task's footprint the way malloc'd pages are — they are a separate, shared accounting. Measured
/// on the first smoke run: RSS 34 MB and footprint 320 MB for a pipeline decoding 4K ProRes, which
/// is obviously not the whole story. A verdict about "memory for a second decode pipeline" read off
/// RSS alone would be reading the one number that cannot see the pixel buffers.
///
/// `vmmap --summary` on our own pid can: it breaks resident/dirty pages out BY REGION TYPE, and
/// `IOSurface` is a row in that table. It needs no privilege on a process we own (checked).
///
/// ⚠️ It BRIEFLY SUSPENDS the target task, which is us — so it is called ONCE per phase, at the end
/// while the load is still running, never on the sampling loop. Sampling with it would make the
/// instrument part of what it measures.
/// The `vmmap --summary` rows a second decode pipeline actually shows up in. Which rows those are
/// was found by DUMPING the table during a live 4K ProRes run rather than assumed — see the note
/// above `vmmapSummary`.
///
///   * `CoreMedia memory pool`      — the decoder's own buffers. THE row for "a second decoder".
///   * `IOSurface`                  — VIRTUAL, deliberately: a mapped IOSurface reports 0 resident
///                                    and 0 dirty in this task because the pages are charged to the
///                                    surface's owner. Its virtual size is how much surface this
///                                    process has mapped, and it is the only column that moves.
///   * `owned unmapped (graphics)`  — Metal/GPU allocations, i.e. the offscreen ring.
///   * `TOTAL` dirty                — everything this task is actually holding.
struct VMMap {
    var footprintMB = Double.nan, peakFootprintMB = Double.nan
    var coreMediaDirtyMB = Double.nan, ioSurfaceVirtualMB = Double.nan
    var graphicsDirtyMB = Double.nan, totalDirtyMB = Double.nan
}
func parseSize(_ t: String) -> Double {
    guard let last = t.last else { return .nan }
    let mult: Double = last == "G" ? 1024 : last == "M" ? 1 : last == "K" ? 1.0/1024 : 1.0/1048576
    return (Double(last.isLetter ? String(t.dropLast()) : t) ?? .nan) * mult
}
/// VIRTUAL / RESIDENT / DIRTY for one region-type row. The row LABEL is stripped by name before
/// splitting — region names contain both spaces and digits ("Memory Tag 22", "owned unmapped
/// (graphics)"), so a positional parse of the whole line reads the name as a column.
func vmmapRow(_ line: Substring, _ label: String) -> (v: Double, r: Double, d: Double)? {
    guard line.hasPrefix(label) else { return nil }
    let cols = line.dropFirst(label.count).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard cols.count >= 3 else { return nil }
    return (parseSize(cols[0]), parseSize(cols[1]), parseSize(cols[2]))
}
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
        else if let r = vmmapRow(line, "IOSurface")             { out.ioSurfaceVirtualMB = r.v }
        else if let r = vmmapRow(line, "owned unmapped (graphics)") { out.graphicsDirtyMB = r.d }
        // FIRST "TOTAL" only. vmmap prints three: the region table's, then "TOTAL, minus reserved
        // VM space", then the MALLOC ZONE table's — which has different columns and was silently
        // overwriting the one we want with a number from another table.
        else if out.totalDirtyMB.isNaN, let r = vmmapRow(line, "TOTAL") { out.totalDirtyMB = r.d }
    }
    return out
}

// MARK: - shader stage
//
// RISK 1 FOR THE SCOPES IS NOT THE SAME QUESTION AS RISK 1 FOR THE PICTURE. The scopes read the
// OFFSCREEN RING (`MetalVideoRenderer.renderPixelFormat`: "Display, export, DeckLink and the
// SCOPES all read this target"), so for the scopes-during-a-drag verdict the frame has to reach
// that target, not merely be copied out of the video output. This stage is the difference: two
// CVMetalTextureCache plane textures and one render pass into an rgba16Float offscreen at SOURCE
// resolution, waited to GPU completion.
//
// ⚠️ THE SHADER BELOW IS COPIED FROM App/PassthroughShader.metal (the legal-range Rec.709 branch)
// AND EXISTS TO COST THE RIGHT AMOUNT OF WORK, NOT TO BE COLOUR-CORRECT FOR EVERY FILE. It is not
// steered by the source's real matrix and it has no full-range branch. If the app's shader changes
// shape — more sampling, a LUT stage — this measures a pipeline the app no longer has.
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

    /// Returns the time from "buffer in hand" to "GPU write of the offscreen COMPLETE", in ms.
    /// `waitUntilCompleted` is deliberate: the scopes read a FINISHED offscreen, so a number that
    /// stopped at `commit()` would leave the part that actually has to finish out of the budget.
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

// MARK: - the scrub player under test

/// An `AVPlayer` used as a DECODER AND NEVER AS A TRANSPORT — rate stays 0, no layer, no audio.
/// This is the shape ../BUGS.md proposes, and `ManifoldCore/AVPlayerEngine.swift`'s unused
/// `scrubSeek` already spells the seek: tolerance `.positiveInfinity` both sides, which is what
/// AVPlayer's own scrub (and QuickTime's) does.
final class ScrubPlayer {
    let player: AVPlayer
    let item: AVPlayerItem
    let output: AVPlayerItemVideoOutput
    private var lastDisplay = CMTime.invalid

    /// Wall time from `AVURLAsset` to `readyToPlay`, in ms — the ONE-OFF cost of installing the
    /// scrub player when a file is opened. It is not part of the per-seek budget and is reported
    /// separately so it cannot be confused with one.
    let readyMs: Double

    init?(url: URL) {
        let t0 = CACurrentMediaTime()
        // PreferPreciseDurationAndTiming is a FILE option. On an HLS URL it forces a walk the
        // playlist cannot cheaply serve, so it is dropped for remote assets.
        let opts: [String: Any] = url.isFileURL ? [AVURLAssetPreferPreciseDurationAndTimingKey: true] : [:]
        let asset = AVURLAsset(url: url, options: opts)
        item = AVPlayerItem(asset: asset)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kPixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.rate = 0
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        let deadline = Date().addingTimeInterval(30)
        while item.status != .readyToPlay && Date() < deadline {
            if item.status == .failed { return nil }
            usleep(500)
        }
        guard item.status == .readyToPlay else { return nil }
        readyMs = (CACurrentMediaTime() - t0) * 1000
    }

    enum Outcome { case newFrame(ms: Double, display: Double, pb: CVPixelBuffer)
                   case sameFrame(ms: Double)
                   case timeout }

    /// One scrub step: seek at AVPlayer's own scrub tolerance, then poll until a frame we have not
    /// already accepted is in hand. See the header for why a changed display time is the stop
    /// condition and a non-nil buffer is not.
    func seekAndPull(to seconds: Double, deadline: Double) -> Outcome {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        var seekDone = false
        let t0 = CACurrentMediaTime()
        player.seek(to: target, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity) { _ in
            seekDone = true
        }
        var disp = CMTime.invalid
        while CACurrentMediaTime() - t0 < deadline {
            let it = player.currentTime()
            if let pb = output.copyPixelBuffer(forItemTime: it, itemTimeForDisplay: &disp) {
                if !lastDisplay.isValid || disp != lastDisplay {
                    let ms = (CACurrentMediaTime() - t0) * 1000
                    lastDisplay = disp
                    return .newFrame(ms: ms, display: disp.seconds, pb: pb)
                }
                // The pre-seek frame. Keep waiting — accepting it here is the trap in the header.
                if seekDone {
                    // Seek finished AND the output still has only the old frame: the toleranced
                    // seek legitimately landed back on it. Not a latency sample, not a timeout.
                    return .sameFrame(ms: (CACurrentMediaTime() - t0) * 1000)
                }
            }
            usleep(150)
        }
        return .timeout
    }
}

// MARK: - probe

func probe(_ url: URL) {
    let asset = AVURLAsset(url: url)
    let sem = DispatchSemaphore(value: 0)
    var line = "?"
    Task {
        let dur = (try? await asset.load(.duration))?.seconds ?? .nan
        if let t = try? await asset.loadTracks(withMediaType: .video).first {
            let size = (try? await t.load(.naturalSize)) ?? .zero
            let fps = (try? await t.load(.nominalFrameRate)) ?? 0
            var codec = "????"
            if let fds = try? await t.load(.formatDescriptions), let fd = fds.first {
                let c = CMFormatDescriptionGetMediaSubType(fd)
                codec = String(bytes: [UInt8((c >> 24) & 0xff), UInt8((c >> 16) & 0xff), UInt8((c >> 8) & 0xff), UInt8(c & 0xff)], encoding: .ascii) ?? "????"
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let mbps = dur > 0 ? Double(bytes) * 8 / dur / 1e6 : .nan
            line = "\(codec)  \(Int(size.width))x\(Int(size.height))  \(fmt(Double(fps), 3)) fps  \(fmt(dur, 2))s  \(fmt(Double(bytes) / 1e9, 2)) GB  \(fmt(mbps, 0)) Mb/s"
        }
        sem.signal()
    }
    sem.wait()
    print("  \(pad(url.lastPathComponent, 52)) \(line)")
}

// MARK: - RISK 1

func latencyRun(_ url: URL) {
    print("\n" + String(repeating: "=", count: 100))
    print("FILE  \(url.path)")
    probe(url)

    // Duration and frame duration, for off-boundary positions.
    let asset = AVURLAsset(url: url)
    var dur = 0.0, fd = 1.0 / 24.0
    let sem = DispatchSemaphore(value: 0)
    Task {
        dur = (try? await asset.load(.duration))?.seconds ?? 0
        if let t = try? await asset.loadTracks(withMediaType: .video).first,
           let f = try? await t.load(.minFrameDuration), f.seconds > 0 { fd = f.seconds }
        sem.signal()
    }
    sem.wait()
    guard dur > 0.5 else { print("  !! unusable duration"); return }

    // Same position generator as scrubmeas.swift: spread across the duration and jittered OFF the
    // frame grid by a golden-ratio sub-frame offset. Boundary-only sampling cannot see a rounding
    // disagreement at all, and this run is meant to be read next to that table.
    func positions(_ n: Int) -> [Double] {
        (0..<n).map { i -> Double in
            let base = dur * (Double(i) + 0.5) / Double(n)
            let phi = (Double(i) * 0.6180339887498949).truncatingRemainder(dividingBy: 1.0)
            return max(fd, min(base + (phi - 0.5) * fd, dur - 2 * fd))
        }
    }

    let stage: ShaderStage? = WANT_SHADER ? ShaderStage() : nil
    if WANT_SHADER && stage == nil { print("  !! Metal stage unavailable — shader pass skipped") }

    for passIsShader in (WANT_SHADER && stage != nil) ? [false, true] : [false] {
        let passName = passIsShader ? "COPY + SHADER→OFFSCREEN (what the SCOPES need)" : "COPY ONLY (what the PICTURE needs)"
        print("\n  ── \(passName) " + String(repeating: "─", count: max(0, 60 - passName.count)))

        // ── COLD ────────────────────────────────────────────────────────────────────────────────
        // A FRESH PLAYER PER TRIAL. Reusing one player and calling its first seek measures a
        // decoder that is already up; the premise under test is that warmth is what makes this
        // route cheap, so the cold case has to actually be cold.
        var coldSeek: [Double] = [], coldReady: [Double] = [], coldShader: [Double] = []
        let coldPos = positions(5)
        for p in coldPos {
            guard let sp = ScrubPlayer(url: url) else { print("  !! player init failed"); return }
            coldReady.append(sp.readyMs)
            switch sp.seekAndPull(to: p, deadline: SEEK_DEADLINE) {
            case .newFrame(let ms, _, let pb):
                if passIsShader, let s = stage, let sm = s.render(pb) { coldShader.append(sm); coldSeek.append(ms + sm) }
                else { coldSeek.append(ms) }
            case .sameFrame(let ms): coldSeek.append(ms)
            case .timeout: print("    cold TIMEOUT at \(fmt(p,2))s")
            }
        }
        print("    COLD  (fresh AVPlayer each, first seek)   \(Dist(coldSeek).row)")
        print("          install cost (asset → readyToPlay)  \(Dist(coldReady).row)")
        if passIsShader { print("          of which shader stage                \(Dist(coldShader).row)") }

        // ── WARM ────────────────────────────────────────────────────────────────────────────────
        guard let sp = ScrubPlayer(url: url) else { print("  !! player init failed"); return }
        // Prime: one seek, discarded. It is the cold sample and is reported above.
        _ = sp.seekAndPull(to: positions(3)[1], deadline: SEEK_DEADLINE)

        for (label, pace) in [("WARM  back-to-back (as fast as it will go)", 0.0),
                              ("WARM  paced at 20 Hz (the shipping throttle)", 0.050)] {
            var lat: [Double] = [], shaderMs: [Double] = [], off: [Double] = []
            var same = 0, timeouts = 0
            let pos = positions(N)
            let runStart = CACurrentMediaTime()
            for (i, p) in pos.enumerated() {
                if pace > 0 {
                    let due = runStart + Double(i) * pace
                    let wait = due - CACurrentMediaTime()
                    if wait > 0 { usleep(useconds_t(wait * 1e6)) }
                }
                switch sp.seekAndPull(to: p, deadline: SEEK_DEADLINE) {
                case .newFrame(let ms, let d, let pb):
                    off.append((d - p) / fd)
                    if passIsShader, let s = stage, let sm = s.render(pb) { shaderMs.append(sm); lat.append(ms + sm) }
                    else { lat.append(ms) }
                case .sameFrame: same += 1
                case .timeout: timeouts += 1
                }
            }
            let elapsed = CACurrentMediaTime() - runStart
            print("    \(pad(label, 44)) \(Dist(lat).row)")
            let rate = Double(pos.count) / elapsed
            print("        achieved \(fmt(rate,1)) seeks/s   same-frame \(same)   timeouts \(timeouts)   over 50 ms: \(lat.filter{$0 > 50}.count)/\(lat.count)")
            if passIsShader { print("        of which shader stage                    \(Dist(shaderMs).row)") }
            let od = Dist(off.map { abs($0) })
            print("        delivered frame − requested, |frames|:    \(od.row)")
        }
    }
}

// MARK: - RISK 2
//
// The comparison is PLAYBACK ALONE vs PLAYBACK + A LIVE SCRUB PLAYER, in one process, measured the
// same way in both phases. "Playback" is modelled the way the app actually plays: an AVAssetReader
// decoding x420 in real time, each frame rendered through the shader into an offscreen, with a
// short hold to stand in for MetalVideoRenderer's 2-deep ring plus `lastPixelBuffer`.
//
// ⚠️ THIS IS A MODEL OF THE APP'S PLAYBACK, NOT THE APP. It has no audio reader, no
// AVSampleBufferDisplayLayer, no DeckLink staging and no scopes, so its absolute footprint is
// BELOW the app's. The DELTA is the measurement — the second pipeline's cost does not depend on
// what else is resident — and the absolute numbers should be read as a floor.

final class PlaybackPump {
    private var thread: Thread?
    private var stopFlag = false
    private let url: URL
    private let stage: ShaderStage?
    private(set) var framesDecoded = 0
    private(set) var restarts = 0

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
            let asset = AVURLAsset(url: url)
            guard let reader = try? AVAssetReader(asset: asset) else { return }
            let sem = DispatchSemaphore(value: 0)
            var track: AVAssetTrack?
            Task { track = try? await asset.loadTracks(withMediaType: .video).first; sem.signal() }
            sem.wait()
            guard let track else { return }
            let out = AVAssetReaderTrackOutput(track: track,
                                               outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kPixelFormat])
            out.alwaysCopiesSampleData = false   // FileFrameSource.swift
            guard reader.canAdd(out) else { return }
            reader.add(out); guard reader.startReading() else { return }
            restarts += 1
            let start = CACurrentMediaTime()
            var firstPts: Double? = nil
            while !stopFlag, let sb = out.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                if firstPts == nil { firstPts = pts }
                // Pace to real time. A pump that runs flat out is not a playback session; it is a
                // transcode, and it would over-report both IO and the pool's high-water mark.
                let due = start + (pts - (firstPts ?? 0))
                let wait = due - CACurrentMediaTime()
                if wait > 0 { usleep(useconds_t(min(wait, 0.5) * 1e6)) }
                _ = stage?.render(pb)
                hold.append(pb); if hold.count > 3 { hold.removeFirst() }
                framesDecoded += 1
            }
            reader.cancelReading()
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
    print("\n" + String(repeating: "=", count: 100))
    print("FILE  \(url.path)")
    probe(url)
    let onSMB = url.path.hasPrefix("/Volumes/")
    print("  transport: \(onSMB ? "SMB (/Volumes)" : "local APFS")   phase length: \(fmt(T,0))s each")

    let stage = ShaderStage()
    if stage == nil { print("  !! Metal unavailable — playback model will not render") }

    var phaseVM: [String: VMMap] = [:]
    func phase(_ name: String, _ body: () -> String) {
        let s = MemSampler(); s.start()
        let d0 = diskReadMB(), n0 = netInMB()
        let extra = body()
        // Taken while the load of THIS phase is still up — see the warning on vmmapSummary().
        let vm = vmmapSummary()
        phaseVM[name] = vm
        s.finish()
        let d1 = diskReadMB(), n1 = netInMB()
        print("    \(pad(name, 34)) peak RSS \(lpad(fmt(s.peakRSS,0),6)) MB   peak footprint \(lpad(fmt(s.peakFootprint,0),6)) MB   diskIO \(lpad(fmt(d1-d0,0),6)) MB   net(machine) \(lpad(fmt(n1-n0,0),6)) MB")
        print("        vmmap at phase end:  footprint \(lpad(fmt(vm.footprintMB,0),6))   CoreMedia pool \(lpad(fmt(vm.coreMediaDirtyMB,0),6))   IOSurface mapped \(lpad(fmt(vm.ioSurfaceVirtualMB,0),6))   GPU \(lpad(fmt(vm.graphicsDirtyMB,0),6))   TOTAL dirty \(lpad(fmt(vm.totalDirtyMB,0),6))  (MB)")
        if !extra.isEmpty { print("        \(extra)") }
    }

    print("\n    baseline at entry: RSS \(fmt(residentMB(),0)) MB  footprint \(fmt(footprintMB(),0)) MB")

    // P1 — playback alone.
    let pump = PlaybackPump(url: url, stage: stage)
    phase("P1  playback alone") {
        pump.start()
        usleep(useconds_t(T * 1e6))
        return "decoded \(pump.framesDecoded) frames, \(pump.restarts) reader start(s)"
    }
    let f1 = pump.framesDecoded

    // P2 — playback + a live scrub player dragging at 20 Hz. THE MEASUREMENT.
    var scrubLat: [Double] = []
    var scrubTimeouts = 0, scrubSame = 0
    var sp: ScrubPlayer? = nil
    var installMs = Double.nan
    phase("P2  playback + scrub player @20Hz") {
        guard let s = ScrubPlayer(url: url) else { return "!! scrub player init FAILED" }
        sp = s; installMs = s.readyMs
        var dur = 0.0
        let sem = DispatchSemaphore(value: 0)
        let a = AVURLAsset(url: url)
        Task { dur = (try? await a.load(.duration))?.seconds ?? 0; sem.signal() }
        sem.wait()
        let start = CACurrentMediaTime()
        var i = 0
        while CACurrentMediaTime() - start < T {
            let due = start + Double(i) * 0.050
            let wait = due - CACurrentMediaTime()
            if wait > 0 { usleep(useconds_t(wait * 1e6)) }
            let phi = (Double(i) * 0.6180339887498949).truncatingRemainder(dividingBy: 1.0)
            switch s.seekAndPull(to: max(0.1, min(phi * dur, dur - 0.2)), deadline: SEEK_DEADLINE) {
            case .newFrame(let ms, _, let pb): scrubLat.append(ms); _ = stage?.render(pb)
            case .sameFrame: scrubSame += 1
            case .timeout: scrubTimeouts += 1
            }
            i += 1
        }
        return "scrub seeks: \(Dist(scrubLat).row)   same-frame \(scrubSame)  timeouts \(scrubTimeouts)   install \(fmt(installMs,0)) ms"
    }
    let f2 = pump.framesDecoded - f1

    // P3 — scrub player released, playback continues. Does the memory come back?
    sp = nil
    _ = sp
    phase("P3  playback alone (scrub released)") {
        usleep(useconds_t(T * 1e6))
        return "decoded \(pump.framesDecoded - f1 - f2) frames"
    }
    pump.stop()
    print("    playback frames: P1 \(f1)  P2 \(f2)  — a drop in P2 is the second pipeline STEALING FROM PLAYBACK")
    print("    process peak RSS overall: \(fmt(residentPeakMB(),0)) MB")

    // THE ANSWER TO RISK 2, stated as the one subtraction the decision turns on.
    if let a = phaseVM["P1  playback alone"], let b = phaseVM["P2  playback + scrub player @20Hz"],
       let c = phaseVM["P3  playback alone (scrub released)"] {
        print("    ┌ COST OF THE SECOND PIPELINE (P2 − P1)")
        print("    │   physical footprint      \(lpad(fmt(b.footprintMB - a.footprintMB, 0),7)) MB")
        print("    │   CoreMedia pool (decoder)\(lpad(fmt(b.coreMediaDirtyMB - a.coreMediaDirtyMB, 0),7)) MB")
        print("    │   IOSurface mapped        \(lpad(fmt(b.ioSurfaceVirtualMB - a.ioSurfaceVirtualMB, 0),7)) MB")
        print("    │   GPU (owned unmapped)    \(lpad(fmt(b.graphicsDirtyMB - a.graphicsDirtyMB, 0),7)) MB")
        print("    │   TOTAL dirty             \(lpad(fmt(b.totalDirtyMB - a.totalDirtyMB, 0),7)) MB")
        print("    └ RETURNED ON RELEASE (P2 − P3): footprint \(fmt(b.footprintMB - c.footprintMB,0)) MB   CoreMedia \(fmt(b.coreMediaDirtyMB - c.coreMediaDirtyMB,0)) MB   TOTAL dirty \(fmt(b.totalDirtyMB - c.totalDirtyMB,0)) MB")
    }
}

// MARK: - HLS
//
// ⚠️ THIS IS A DIFFERENT MECHANISM FROM THE ONE ABOVE AND IT IS MEASURED SEPARATELY ON PURPOSE.
// ../BUGS.md's HLS entry is gated on the same route but stresses it differently: no drag, so
// per-seek latency is nearly irrelevant, and the source is a NETWORK STREAM rather than a second
// decode of a local file. The question here is not "how fast is a seek" — it is the prior one:
// does `AVPlayerItemVideoOutput` vend `CVPixelBuffer`s from an HLS item AT ALL, and at what cost?
// Without that, HLS is "a picture with no instruments attached to it", which is the opposite of
// the feature. Nothing in the file measurements answers it, so it is not inferred from them.
//
// The pull loop is the real shape: a ~60 Hz tick asking `itemTime(forHostTime:)` and copying only
// when `hasNewPixelBuffer` says so — i.e. what a CVDisplayLink-driven consumer would do, not a
// seek-and-wait.
func fourcc(_ t: OSType) -> String {
    String(bytes: [UInt8((t >> 24) & 0xff), UInt8((t >> 16) & 0xff), UInt8((t >> 8) & 0xff), UInt8(t & 0xff)],
           encoding: .ascii) ?? "????"
}

func hlsRun(_ urlString: String) {
    print("\n" + String(repeating: "=", count: 100))
    print("HLS   \(urlString)")
    guard let url = URL(string: urlString) else { print("  !! bad URL"); return }

    let mem0 = vmmapSummary(), net0 = netInMB()
    guard let sp = ScrubPlayer(url: url) else { print("  !! item never reached readyToPlay"); return }
    print("  asset → readyToPlay: \(fmt(sp.readyMs,0)) ms")

    let stage = ShaderStage()
    var pullMs: [Double] = [], shaderMs: [Double] = []
    var frames = 0, nilPulls = 0
    var firstFormat = "none", firstSize = "?"
    var displayTimes: [Double] = []

    sp.player.play()
    let start = CACurrentMediaTime()
    while CACurrentMediaTime() - start < T {
        let host = CACurrentMediaTime()
        let it = sp.output.itemTime(forHostTime: host)
        if sp.output.hasNewPixelBuffer(forItemTime: it) {
            var disp = CMTime.invalid
            let t0 = CACurrentMediaTime()
            if let pb = sp.output.copyPixelBuffer(forItemTime: it, itemTimeForDisplay: &disp) {
                pullMs.append((CACurrentMediaTime() - t0) * 1000)
                if frames == 0 {
                    firstFormat = fourcc(CVPixelBufferGetPixelFormatType(pb))
                    firstSize = "\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))"
                }
                if let s = stage, let sm = s.render(pb) { shaderMs.append(sm) }
                displayTimes.append(disp.seconds)
                frames += 1
            } else { nilPulls += 1 }
        }
        usleep(16_000)   // ~60 Hz tick, the display-link cadence
    }
    let elapsed = CACurrentMediaTime() - start
    sp.player.pause()
    let mem1 = vmmapSummary(), net1 = netInMB()

    print("  played \(fmt(elapsed,1))s   frames pulled \(frames)  (\(fmt(Double(frames)/elapsed,1)) fps)   empty pulls \(nilPulls)")
    print("  vended buffer: \(firstFormat)  \(firstSize)   \(firstFormat == "x420" ? "— the app's decode contract, unchanged" : "⚠️ NOT x420 — the requested format was NOT honoured")")
    print("  copyPixelBuffer cost:  \(Dist(pullMs).row)")
    if !shaderMs.isEmpty { print("  shader → offscreen:    \(Dist(shaderMs).row)") }
    // Monotonic display times with no repeats is what "the scopes would see every frame" means.
    var backwards = 0, repeats = 0
    for i in 1..<max(1, displayTimes.count) {
        if displayTimes[i] < displayTimes[i-1] { backwards += 1 }
        if displayTimes[i] == displayTimes[i-1] { repeats += 1 }
    }
    print("  display times: \(backwards) backwards, \(repeats) repeated — a repeat is a frame the SCOPES would show twice")
    print("  memory:  footprint \(fmt(mem0.footprintMB,0)) → \(fmt(mem1.footprintMB,0)) MB   CoreMedia pool \(fmt(mem0.coreMediaDirtyMB,0)) → \(fmt(mem1.coreMediaDirtyMB,0)) MB   IOSurface \(fmt(mem0.ioSurfaceVirtualMB,0)) → \(fmt(mem1.ioSurfaceVirtualMB,0)) MB")
    print("  network (machine-wide): \(fmt(net1-net0,0)) MB over \(fmt(elapsed,0))s = \(fmt((net1-net0)*8/elapsed,0)) Mb/s")

    // Scrubbing an HLS VOD item — not required by the feature, but it is free to ask and it is the
    // one place the two entries' risks overlap.
    var lat: [Double] = []; var to = 0
    let dur = sp.item.duration.seconds
    if dur.isFinite && dur > 5 {
        for i in 0..<10 {
            let phi = (Double(i) * 0.6180339887498949).truncatingRemainder(dividingBy: 1.0)
            switch sp.seekAndPull(to: 1 + phi * (dur - 2), deadline: SEEK_DEADLINE) {
            case .newFrame(let ms, _, _): lat.append(ms)
            case .sameFrame: break
            case .timeout: to += 1
            }
        }
        print("  seek on HLS VOD (10 positions): \(Dist(lat).row)  timeouts \(to)")
    } else {
        print("  seek on HLS: duration is \(fmt(dur,1)) — LIVE playlist, not seekable this way")
    }
}

// MARK: - main

let files = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
guard !files.isEmpty else {
    print("usage: [MODE=probe|latency|memory|hls] [N=40] [T=15] [SHADER=1] avpvomeas FILE|URL...")
    exit(2)
}

// ⚠️ ALL WORK RUNS OFF THE MAIN THREAD AND THE MAIN THREAD RUNS ITS RUN LOOP. AVPlayer delivers
// seek completion handlers and item KVO on the MAIN QUEUE; a measurement loop that blocks the main
// thread never sees them, and `seekAndPull` would then time out on every position and report that
// the route does not work. That is a harness bug that looks exactly like a result.
let worker = Thread {
    print("avpvomeas — MODE=\(MODE) N=\(N) T=\(fmt(T,0)) SHADER=\(WANT_SHADER ? 1 : 0)  pixel format x420")
    switch MODE {
    case "probe":   print("\nPROBE"); for f in files { probe(f) }
    case "memory":  for f in files { memoryRun(f) }
    case "hls":     for a in CommandLine.arguments.dropFirst() { hlsRun(a) }
    default:        for f in files { latencyRun(f) }
    }
    print("\ndone.")
    exit(0)
}
worker.stackSize = 4 << 20
worker.start()
CFRunLoopRun()
