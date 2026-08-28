// scrubmeas — does the SCRUB PREVIEW and the RELEASE SEEK put the same frame on screen?
//
// Written for the "scrub release jumps the picture once, backwards" report (0.6.2, Joey). The
// question it answers, and what the numbers came back as, is in ../BUGS.md → "⚠️ UNCONFIRMED:
// scrub release jumps the picture once, backwards, on ProRes". This file is the mechanics.
//
// Moved here out of a session scratchpad, which does not survive — the same reason
// ../color-fixtures/ exists. It is NOT part of the app target: the target's `sources:` in
// project.yml is `App` plus one explicit DeckLink .cpp, so nothing under docs/ is compiled in.
// Building it needs no project regeneration.
//
// ── BUILD AND RUN ───────────────────────────────────────────────────────────────────────────────
//
//   cd docs/scrub-fixtures
//   xcrun swiftc -O -o scrubmeas scrubmeas.swift
//   N=40 ./scrubmeas "/path/to/clip.mov" ["/path/to/another.mp4" ...]
//
// N is the number of scrub positions per file (default 40). Do NOT pass -parse-as-library: this is
// a single-file script and top-level code is only legal without it.
//
// ── WHAT IT MEASURES ────────────────────────────────────────────────────────────────────────────
//
// For N positions spread across the duration — deliberately jittered OFF frame boundaries by a
// golden-ratio sub-frame offset, because a measurement that only samples boundaries cannot see a
// rounding disagreement at all — it reports, per position:
//
//   * the frame AVAssetImageGenerator returns (the scrub preview: FrameEngine.previewImage)
//   * the frame AVAssetReader delivers    (the release seek:  FrameEngine.beginReading)
//   * the signed difference, IN FRAMES  (negative = the picture moves BACKWARDS on release)
//
// under three tolerance settings, so the shipping ±0.5 s can be compared against the two candidate
// changes without rebuilding the app. It also replays ContentView's preview-throttle gates against
// a synthetic drag to size the OTHER candidate mechanism, staleness.
//
// ⚠️ THE GENERATOR CONFIG BELOW IS COPIED FROM FrameEngine.makeScrubPreviewGenerator. If that
// changes, change it here, or this measures a generator the app does not use.
import AVFoundation
import CoreMedia
import Foundation

func fmt(_ d: Double, _ n: Int = 3) -> String { d.isFinite ? String(format: "%.\(n)f", d) : "nan" }
func stats(_ v: [Double]) -> String {
    guard !v.isEmpty else { return "n=0" }
    let m = v.reduce(0,+)/Double(v.count)
    let sd = (v.map { ($0-m)*($0-m) }.reduce(0,+)/Double(v.count)).squareRoot()
    return "mean \(fmt(m)) sd \(fmt(sd))  min \(fmt(v.min()!)) max \(fmt(v.max()!))"
}
func makeGenerator(_ a: AVAsset, before: CMTime, after: CMTime) -> AVAssetImageGenerator {
    let g = AVAssetImageGenerator(asset: a)
    g.appliesPreferredTrackTransform = true; g.apertureMode = .encodedPixels
    g.requestedTimeToleranceBefore = before; g.requestedTimeToleranceAfter = after
    g.maximumSize = CGSize(width: 960, height: 540); return g
}
func genActual(_ g: AVAssetImageGenerator, at t: Double) async -> (Double, Double) {
    let t0 = CACurrentMediaTime()
    return await withCheckedContinuation { c in
        g.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: t, preferredTimescale: 600))]) { _,_,actual,result,_ in
            c.resume(returning: (result == .succeeded ? actual.seconds : .nan, (CACurrentMediaTime()-t0)*1000)) } }
}

/// The file's TRUE presentation grid, in PTS order (decode order != presentation order on long-GOP).
///
/// ⚠️ TRAP 3 — PASSTHROUGH (`outputSettings: nil`) IS CORRECT *HERE* AND WRONG FOR IDENTIFYING A
/// DELIVERED FRAME. Reading compressed samples is the cheap, exact way to enumerate the grid, and
/// with no `timeRange` set there is nothing to trim, so every PTS is the natural one. But do NOT
/// reach for passthrough when asking "which frame does a seek to t deliver" (see
/// `readerFrameIndex`): a compressed stream can only begin at a SYNC SAMPLE, so on long-GOP it
/// hands back the PRECEDING KEYFRAME — up to a GOP early, and nothing like what is displayed.
/// That produced a confident, entirely wrong long-GOP result before it was caught.
///
/// The dedupe at the end is not cosmetic: files carry duplicate/edit-list PTS at the head, and a
/// zero-width first step silently breaks any "half the grid step" tolerance computed from it.
func buildGrid(asset: AVAsset, track: AVAssetTrack) -> [Double] {
    guard let r = try? AVAssetReader(asset: asset) else { return [] }
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    guard r.canAdd(out) else { return [] }
    r.add(out); guard r.startReading() else { return [] }
    var pts: [Double] = []
    while let sb = out.copyNextSampleBuffer() {
        let p = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        if p.isFinite { pts.append(p) }
        if pts.count > 200_000 { break }
    }
    r.cancelReading()
    let sorted = pts.sorted()
    var uniq: [Double] = []
    for v in sorted where uniq.isEmpty || v - uniq[uniq.count-1] > 1e-6 { uniq.append(v) }
    return uniq
}
/// Index of the grid entry nearest `t`, tolerance = half the median grid step.
func gridIndex(_ grid: [Double], _ t: Double) -> Int {
    guard grid.count > 1, t.isFinite else { return -1 }
    var steps: [Double] = []
    for i in 1..<grid.count { steps.append(grid[i]-grid[i-1]) }
    let step = steps.sorted()[steps.count/2]
    var best = 0, bd = Double.infinity
    for (i,g) in grid.enumerated() { let d = abs(g-t); if d < bd { bd = d; best = i } }
    return bd <= 0.5*step + 1e-6 ? best : -1
}
/// Index of the frame CONTAINING t (the last grid entry at or before t).
func containingIndex(_ grid: [Double], _ t: Double) -> Int { grid.lastIndex(where: { $0 <= t + 1e-9 }) ?? -1 }

/// Which FRAME does the release path deliver? AVAssetReader trims the first sample's PTS to the
/// timeRange start, so the first PTS cannot identify the frame. The SECOND sample is untrimmed and
/// lands on the natural grid, so the delivered frame is the grid entry one step before it.
/// Which FRAME does the release path actually put on screen?
///
/// ⚠️⚠️ READ THIS BEFORE CHANGING ANYTHING HERE. Three separate ways of asking this question each
/// return a clean, plausible, WRONG number. All three were hit while writing this file, and two of
/// them produced a textbook "confirmation" of the hypothesis then under test.
///
///   TRAP 1 — THE EMPTY MARKER BUFFER. An `AVAssetReader` with a trimmed `timeRange` emits a
///   LEADING buffer with `CMSampleBufferGetNumSamples(sb) == 0`, duration 0, and its PTS clamped
///   to the range start. It is not a frame. Counting it as one — and then taking "the next PTS,
///   minus one frame" — yielded −1 FRAME IN 39 OF 40 POSITIONS: exactly the consistent backwards
///   jump the report described, manufactured entirely by the harness. Hence the `numSamples > 0`
///   filter below; it is load-bearing, not defensive.
///
///   TRAP 2 — THE FIRST REAL BUFFER'S PTS IS TRIMMED TO THE RANGE START, IN BOTH OUTPUT MODES. It
///   carries the containing frame's PIXELS but not that frame's timestamp, so it cannot identify
///   the frame. Nearest-matching that trimmed value to the grid flips to the NEXT frame whenever
///   the request lands in the later half of a frame — which fabricated a +1 with mean +0.525, a
///   uniform [0,1) distribution that is nothing but the sub-frame phase of the sample positions.
///   A result that looks like a real half-frame bias and is pure measurement artefact.
///
///   TRAP 3 — PASSTHROUGH OUTPUT LIES ON LONG-GOP. See `buildGrid`. Compressed samples can only
///   start at a sync sample, so passthrough returns the preceding keyframe, not the frame shown.
///
/// THE RULE THAT SURVIVES ALL THREE, and what this function implements: decode (so the reader can
/// trim to the frame actually requested), skip the marker, and read the SECOND real buffer — it is
/// untrimmed and lands on the natural grid, so the DELIVERED FRAME IS ONE GRID STEP BEFORE IT.
/// Cross-checked against the passthrough true-PTS on all-intra, where both methods are valid and
/// agree; that agreement is the only reason to trust this on long-GOP, where only this one works.
func readerFrameIndex(asset: AVAsset, track: AVAssetTrack, at t: Double, grid: [Double]) -> Int {
    guard let r = try? AVAssetReader(asset: asset) else { return -1 }
    r.timeRange = CMTimeRange(start: CMTime(seconds: t, preferredTimescale: 600), duration: .positiveInfinity)
    let out = AVAssetReaderTrackOutput(track: track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
    guard r.canAdd(out) else { return -1 }
    r.add(out); guard r.startReading() else { return -1 }
    defer { r.cancelReading() }
    var real: [Double] = []
    for _ in 0..<8 {
        guard let sb = out.copyNextSampleBuffer() else { break }
        // TRAP 1 lives on this line. Drop the numSamples == 0 marker; do not count it as a frame.
        if CMSampleBufferGetNumSamples(sb) > 0 { real.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds) }
        if real.count >= 2 { break }
    }
    guard real.count >= 2 else { return -1 }
    // TRAP 2 lives on this line. real[0] is the delivered frame's PIXELS but a TRIMMED timestamp,
    // so it is deliberately not used. real[1] is untrimmed → delivered frame is one step earlier.
    let second = gridIndex(grid, real[1])
    return second > 0 ? second - 1 : -1
}

func simulateDrag(speed: Double, latency: Double, fd: Double, wall: Double = 2.0, uiHz: Double = 60, start: Double = 30) -> Double {
    var inFlight = false, lastPreviewTime = -1.0, pending = Double.nan, completes = Double.infinity, lastCompleted = Double.nan
    let dt = 1/uiHz; var now = 0.0
    while now <= wall {
        if inFlight && now >= completes { inFlight = false; lastCompleted = pending }
        let s = start + speed*now
        if !inFlight && abs(s - lastPreviewTime) > 0.05 { inFlight = true; lastPreviewTime = s; pending = s; completes = now + latency }
        now += dt
    }
    guard lastCompleted.isFinite else { return .nan }
    return ((start + speed*wall) - lastCompleted)/fd
}

func run(path: String, samples: Int) async {
    let url = URL(fileURLWithPath: path); let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
          let dur = try? await asset.load(.duration).seconds,
          let nfr = try? await track.load(.nominalFrameRate),
          let minFD = try? await track.load(.minFrameDuration) else { print("!! load failed: \(url.lastPathComponent)"); return }
    var fd = minFD.seconds; if !(fd > 0) { fd = nfr > 0 ? 1/Double(nfr) : 1/24.0 }
    var codec = "?"
    if let fds = try? await track.load(.formatDescriptions), let f = fds.first {
        let c = CMFormatDescriptionGetMediaSubType(f)
        codec = String(bytes: [UInt8((c>>24)&0xff),UInt8((c>>16)&0xff),UInt8((c>>8)&0xff),UInt8(c&0xff)], encoding: .ascii) ?? "?" }
    let grid = buildGrid(asset: asset, track: track)
    print("\n================================================================================")
    print("FILE   \(url.lastPathComponent)")
    print("codec \(codec)  fps \(fmt(1/fd,4))  frameDur \(fmt(fd,6))s  duration \(fmt(dur,2))s  grid frames \(grid.count)")
    guard grid.count > 4 else { print("  !! no usable grid"); return }

    var times: [Double] = []
    for i in 0..<samples {
        let base = dur*(Double(i)+0.5)/Double(samples)
        let phi = (Double(i)*0.6180339887498949).truncatingRemainder(dividingBy: 1.0)
        times.append(max(grid[1], min(base + (phi-0.5)*fd, grid[grid.count-3])))
    }
    print("scrub positions: \(samples), landing exactly on a grid PTS: \(times.filter{ g in grid.contains{ abs($0-g) < 1e-9 } }.count)")

    var latA = 0.02
    for (label, before, after) in [
        ("A  before=0.5   after=0.5    (SHIPPING)", CMTime(seconds:0.5,preferredTimescale:600), CMTime(seconds:0.5,preferredTimescale:600)),
        ("B  before=0.5   after=.zero  (asymmetric)", CMTime(seconds:0.5,preferredTimescale:600), CMTime.zero),
        ("C  before=.zero after=.zero  (exact)", CMTime.zero, CMTime.zero)] {
        let g = makeGenerator(asset, before: before, after: after)
        var deltas: [Double] = [], genOff: [Double] = [], mss: [Double] = [], bad = 0
        var sample: [String] = []
        for t in times {
            let (a, ms) = await genActual(g, at: t); mss.append(ms)
            let gi = gridIndex(grid, a), ri = readerFrameIndex(asset: asset, track: track, at: t, grid: grid)
            let ti = containingIndex(grid, CMTime(seconds: t, preferredTimescale: 600).seconds)
            if gi < 0 || ri < 0 { bad += 1; continue }
            deltas.append(Double(ri - gi)); genOff.append(Double(gi - ti))
            if sample.count < 10 { sample.append("      \(fmt(t,4))    \(gi)      \(ri)       \(ri-gi)") }
        }
        let neg = deltas.filter{$0 < 0}.count, pos = deltas.filter{$0 > 0}.count
        let ms = mss.reduce(0,+)/Double(max(mss.count,1)); if label.hasPrefix("A") { latA = ms/1000 }
        print("\n  \(label)  [n=\(deltas.count)/\(times.count), unresolved \(bad)]")
        print("    preview frame - frame containing request: \(stats(genOff))")
        print("    RELEASE frame - PREVIEW frame  (frames):  \(stats(deltas))")
        print("    sign: backwards \(neg)  forwards \(pos)  identical \(deltas.count-neg-pos)")
        print("    generator latency: mean \(fmt(ms,1)) ms/request")
        if label.hasPrefix("A") { print("      requested  previewFr  releaseFr  delta"); sample.forEach { print($0) } }
    }
    print("\n  STALENESS — ContentView throttle replayed (latency \(fmt(latA*1000,1)) ms, 60 Hz slider, 2 s drag)")
    for sp in [0.25,0.5,1.0,2.0,5.0,20.0,100.0] { print("    \(fmt(sp,2))x realtime   \(fmt(simulateDrag(speed: sp, latency: latA, fd: fd),2)) frames behind") }
    print("    0.05 s media-time gate alone = \(fmt(0.05/fd,2)) frames at this rate")
}

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// MARK: - PIXEL DIFF — does the GENERATOR produce the same values the DECODER does?
// ═══════════════════════════════════════════════════════════════════════════════════════════════
//
// Run with MODE=pixdiff. Answers the question the side-by-side split could not: the split shows
// that the overlay and the Metal layer DISPLAY the same frame differently, but it cannot say
// whether the difference was introduced when the image was CREATED or when it was COMPOSITED.
// Every display-side control has been individually eliminated against the split (contentsHeadroom,
// toneMapMode, the preferredDynamicRange/wantsExtendedDynamicRangeContent A/B, and — measured in
// hrprobe.swift — the image's headroom, which cannot be cleared because it is DERIVED FROM the PQ
// colorspace). This asks the other half, numerically and with no display involved.
//
// ── WHAT IS COMPARED, AND WHY IT IS THE RIGHT SPACE ────────────────────────────────────────────
//
// Both paths hand PQ-ENCODED RGB in nominal [0,1] to a PQ-tagged layer. Neither applies an EOTF:
//
//   * METAL — `passthroughFragment` samples 10-bit YCbCr, range-expands, applies the YCbCr→RGB
//     matrix, and writes the result to an rgba16Float target. No transfer, no tone-map, no clamp.
//     `MetalVideoRenderer.setSourceColorSpace` then tags the LAYER PQ and lets macOS do the EOTF.
//   * OVERLAY — `AVAssetImageGenerator` with `dynamicRangePolicy = .matchSource` returns a
//     PQ-tagged CGImage, assigned to a CALayer's `contents`.
//
// So "PQ code value as RGB" is the one space in which the two are directly comparable, and it is
// the space in which any difference would have to already exist for CREATION to be the site.
// This file therefore replicates the SHADER'S ARITHMETIC on the decoder's buffer rather than
// asking CoreGraphics to convert anything — a CGBitmapContext draw would apply a colour transform
// and measure that instead.
//
// ⚠️ THE SHADER CONSTANTS BELOW ARE COPIED FROM PassthroughShader.metal AND THE COEFFICIENTS FROM
// MetalVideoRenderer.colorParams. If either changes, change it here, or this measures a pipeline
// the app does not have. Same standing hazard as `makeGenerator` at the top of this file.
//
// ── RESOLUTION: HANDLED BY REMOVING IT, NOT BY CORRECTING FOR IT ───────────────────────────────
//
// The shipping generator is capped at 960×540 while the decoder delivers the full raster, so a
// naive comparison would be measuring a RESAMPLE — and a resample difference and a colour
// difference look alike in a summary statistic. Rather than model the generator's unknown filter,
// PASS 1 removes the variable outright: `maximumSize = .zero` makes the generator return the full
// encoded raster, giving a 1:1 pixel correspondence with the decoder and NO resampling on either
// side. Any difference PASS 1 finds cannot be a resampling artefact, because nothing was resampled.
//
// PASS 2 then runs the SHIPPING 960×540 config for comparison, and reports it separately. If the
// two passes agree, the cap is not implicated; if PASS 2 differs from PASS 1, the difference is in
// the scaling and is the generator's filter, not its colour handling.
struct Plane { var w = 0, h = 0, v: [Double] = [] }

/// The shader's arithmetic, replicated exactly. See PassthroughShader.metal:90.
struct ShaderParams { var a = 1.4746, b = 0.1646, c = 0.5714, d = 1.8814; var isFullRange = false }

let kCodeMax = 1023.984375, kLumaBlack = 64.0/1023.984375, kLumaSwing = 1023.984375/876.0
let kChromaMid = 512.0/1023.984375, kChromaSwing = 1023.984375/896.0, kFullLumaSwing = 1023.984375/1023.0

/// Bilinear sample of a plane at normalized coords, matching `filter::linear` + clamp_to_edge.
func bilinear(_ p: Plane, _ u: Double, _ v: Double) -> Double {
    let x = u*Double(p.w) - 0.5, y = v*Double(p.h) - 0.5
    let x0 = Int(floor(x)), y0 = Int(floor(y)), fx = x - floor(x), fy = y - floor(y)
    func at(_ i: Int, _ j: Int) -> Double {
        let ii = min(max(i,0),p.w-1), jj = min(max(j,0),p.h-1); return p.v[jj*p.w+ii]
    }
    let top = at(x0,y0)*(1-fx) + at(x0+1,y0)*fx, bot = at(x0,y0+1)*(1-fx) + at(x0+1,y0+1)*fx
    return top*(1-fy) + bot*fy
}

/// Decoder → PQ RGB, via the shader's exact path.
func decoderRGB(luma: Plane, chroma: Plane, chromaB: Plane, x: Int, y: Int, W: Int, H: Int,
                _ p: ShaderParams) -> (Double, Double, Double) {
    let u = (Double(x)+0.5)/Double(W), v = (Double(y)+0.5)/Double(H)
    var yy = bilinear(luma, u, v)
    let cbRaw = bilinear(chroma, u, v), crRaw = bilinear(chromaB, u, v)
    var cb = 0.0, cr = 0.0
    if p.isFullRange {
        yy *= kFullLumaSwing
        cb = (cbRaw - kChromaMid) * (219.0/224.0); cr = (crRaw - kChromaMid) * (219.0/224.0)
    } else {
        yy = (yy - kLumaBlack) * kLumaSwing
        cb = (cbRaw - kChromaMid) * kChromaSwing; cr = (crRaw - kChromaMid) * kChromaSwing
    }
    return (yy + p.a*cr, yy - p.b*cb - p.c*cr, yy + p.d*cb)
}

func linfit(_ x: [Double], _ y: [Double]) -> (slope: Double, intercept: Double, r: Double) {
    let n = Double(x.count); guard n > 1 else { return (.nan,.nan,.nan) }
    let mx = x.reduce(0,+)/n, my = y.reduce(0,+)/n
    var sxy = 0.0, sxx = 0.0, syy = 0.0
    for i in 0..<x.count { let dx = x[i]-mx, dy = y[i]-my; sxy += dx*dy; sxx += dx*dx; syy += dy*dy }
    guard sxx > 0, syy > 0 else { return (.nan,.nan,.nan) }
    let m = sxy/sxx
    return (m, my - m*mx, sxy/(sxx.squareRoot()*syy.squareRoot()))
}

/// Pull the decoder's frame at `t` as three planes of NORMALIZED 10-bit samples (code/1023.984375),
/// which is the domain the shader's sampler works in — see the kCodeMax note in the shader.
func decodeFrame(asset: AVAsset, track: AVAssetTrack, at t: Double)
    -> (luma: Plane, cb: Plane, cr: Plane, W: Int, H: Int, matrix: String, full: Bool)? {
    guard let r = try? AVAssetReader(asset: asset) else { return nil }
    r.timeRange = CMTimeRange(start: CMTime(seconds: t, preferredTimescale: 600), duration: .positiveInfinity)
    let out = AVAssetReaderTrackOutput(track: track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
    guard r.canAdd(out) else { return nil }
    r.add(out); guard r.startReading() else { return nil }
    defer { r.cancelReading() }
    // TRAP 1/TRAP 2 (see readerFrameIndex): skip the empty marker; the FIRST REAL buffer carries
    // the delivered frame's PIXELS, which is exactly what we want here — only its timestamp is
    // untrustworthy, and we are not using the timestamp.
    var pb: CVPixelBuffer?
    for _ in 0..<8 {
        guard let sb = out.copyNextSampleBuffer() else { break }
        if CMSampleBufferGetNumSamples(sb) > 0, let b = CMSampleBufferGetImageBuffer(sb) { pb = b; break }
    }
    guard let buf = pb else { return nil }
    let matrix = (CVBufferCopyAttachment(buf, kCVImageBufferYCbCrMatrixKey, nil) as? String) ?? "(none)"
    CVPixelBufferLockBaseAddress(buf, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
    let W = CVPixelBufferGetWidth(buf), H = CVPixelBufferGetHeight(buf)
    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buf, 0),
          let cBase = CVPixelBufferGetBaseAddressOfPlane(buf, 1) else { return nil }
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(buf, 0), cStride = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
    let cW = CVPixelBufferGetWidthOfPlane(buf, 1), cH = CVPixelBufferGetHeightOfPlane(buf, 1)
    var luma = Plane(w: W, h: H, v: [Double](repeating: 0, count: W*H))
    var cb = Plane(w: cW, h: cH, v: [Double](repeating: 0, count: cW*cH))
    var cr = Plane(w: cW, h: cH, v: [Double](repeating: 0, count: cW*cH))
    // x420 is 10-bit MSB-aligned in a 16-bit word; Metal samples it as .r16Unorm, i.e. word/65535.
    for j in 0..<H {
        let row = yBase.advanced(by: j*yStride).assumingMemoryBound(to: UInt16.self)
        for i in 0..<W { luma.v[j*W+i] = Double(row[i])/65535.0 }
    }
    for j in 0..<cH {
        let row = cBase.advanced(by: j*cStride).assumingMemoryBound(to: UInt16.self)
        for i in 0..<cW { cb.v[j*cW+i] = Double(row[2*i])/65535.0; cr.v[j*cW+i] = Double(row[2*i+1])/65535.0 }
    }
    return (luma, cb, cr, W, H, matrix, false)
}

/// Read a 16-bit CGImage's RGB out RAW — no CGBitmapContext, which would apply a colour transform
/// and measure that instead of the image.
func generatorRGB(_ img: CGImage) -> (w: Int, h: Int, rgb: [(Double,Double,Double)], note: String)? {
    guard let dp = img.dataProvider, let data = dp.data else { return nil }
    let n = CFDataGetLength(data)
    guard let ptr = CFDataGetBytePtr(data) else { return nil }
    let w = img.width, h = img.height, bpr = img.bytesPerRow, bpp = img.bitsPerPixel/8
    guard img.bitsPerComponent == 16, bpp >= 6, n >= bpr*h else {
        return (w, h, [], "UNSUPPORTED bpc=\(img.bitsPerComponent) bpp=\(img.bitsPerPixel) bytes=\(n)")
    }
    let info = img.bitmapInfo
    let isFloat = info.contains(.floatComponents)
    let alphaFirst = [CGImageAlphaInfo.premultipliedFirst.rawValue, CGImageAlphaInfo.first.rawValue,
                      CGImageAlphaInfo.noneSkipFirst.rawValue].contains(info.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
    let littleEndian = (info.rawValue & CGBitmapInfo.byteOrderMask.rawValue) == CGBitmapInfo.byteOrder16Little.rawValue
    var outv: [(Double,Double,Double)] = []; outv.reserveCapacity(w*h)
    let comps = bpp/2
    for j in 0..<h {
        let row = ptr.advanced(by: j*bpr)
        row.withMemoryRebound(to: UInt16.self, capacity: w*comps) { r16 in
            for i in 0..<w {
                let base = i*comps + (alphaFirst ? 1 : 0)
                func val(_ k: Int) -> Double {
                    let raw = littleEndian ? UInt16(littleEndian: r16[base+k]) : r16[base+k]
                    if isFloat { return Double(Float16(bitPattern: raw)) }
                    return Double(raw)/65535.0
                }
                outv.append((val(0), val(1), val(2)))
            }
        }
    }
    let note = "bpc=16 bpp=\(img.bitsPerPixel) comps=\(comps) float=\(isFloat) alphaFirst=\(alphaFirst) LE=\(littleEndian)"
    return (w, h, outv, note)
}

/// One pass: generate at `maxSize` (.zero = native, no resample) and diff against the decoder.
func pixelPass(label: String, asset: AVAsset, track: AVAssetTrack, at t: Double,
               maxSize: CGSize, params: ShaderParams) async {
    let g = AVAssetImageGenerator(asset: asset)
    g.appliesPreferredTrackTransform = true
    g.apertureMode = .encodedPixels
    // ZERO tolerance so the generator returns the frame containing `t` exactly. On all-intra this
    // is a no-op (measured above: identical at every tolerance) but it removes the variable.
    g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
    g.maximumSize = maxSize
    g.dynamicRangePolicy = .matchSource

    let img: CGImage? = await withCheckedContinuation { c in
        g.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: t, preferredTimescale: 600))]) { _, i, _, _, _ in
            c.resume(returning: i)
        }
    }
    guard let image = img else { print("  \(label): generator returned nil"); return }
    guard let gen = generatorRGB(image), !gen.rgb.isEmpty else {
        print("  \(label): could not read generator pixels — \(generatorRGB(image)?.note ?? "nil")"); return }
    guard let dec = decodeFrame(asset: asset, track: track, at: t) else { print("  \(label): decode failed"); return }

    print("\n  ── \(label) ──")
    print("    generator: \(gen.w)×\(gen.h)  \(gen.note)")
    print("    decoder:   \(dec.W)×\(dec.H)  matrix=\(dec.matrix)  range=\(params.isFullRange ? "full" : "video/legal")")
    let resampled = (gen.w != dec.W || gen.h != dec.H)
    print("    resampling in play: \(resampled ? "YES — generator is scaled, differences may include filter error" : "NO — 1:1, nothing is resampled on either side")")

    // Sample a grid of points. At 1:1 these are exact pixel pairs; when the generator is scaled,
    // matched NORMALIZED coordinates (which is the best available correspondence).
    var gv: [Double] = [], dv: [Double] = []          // paired PQ code values, all channels pooled
    var perCh: [[Double]] = [[],[],[]], perChD: [[Double]] = [[],[],[]]
    let stepX = max(1, gen.w/256), stepY = max(1, gen.h/256)
    var flatOnly: [(Double,Double)] = []
    for j in stride(from: 0, to: gen.h, by: stepY) {
        for i in stride(from: 0, to: gen.w, by: stepX) {
            let (gr, gg, gb) = gen.rgb[j*gen.w+i]
            let dx = Int((Double(i)+0.5)/Double(gen.w)*Double(dec.W)), dy = Int((Double(j)+0.5)/Double(gen.h)*Double(dec.H))
            let (dr, dg, db) = decoderRGB(luma: dec.luma, chroma: dec.cb, chromaB: dec.cr,
                                          x: min(dx,dec.W-1), y: min(dy,dec.H-1), W: dec.W, H: dec.H, params)
            for (k,(a,b)) in [(gr,dr),(gg,dg),(gb,db)].enumerated() {
                gv.append(a); dv.append(b); perCh[k].append(a); perChD[k].append(b)
            }
            // Local flatness: if the decoder's 3×3 luma neighbourhood is uniform, no resampling
            // filter can change the value, so these pairs are resample-immune.
            if dx > 0, dy > 0, dx < dec.W-1, dy < dec.H-1 {
                let c = dec.luma.v[dy*dec.W+dx]
                var flat = true
                for jj in -1...1 { for ii in -1...1 where abs(dec.luma.v[(dy+jj)*dec.W+(dx+ii)] - c) > 1e-6 { flat = false } }
                if flat { flatOnly.append((gr, dr)); flatOnly.append((gg, dg)); flatOnly.append((gb, db)) }
            }
        }
    }
    guard !gv.isEmpty else { print("    no samples"); return }

    let diffs = zip(gv, dv).map { $0 - $1 }
    print("    samples: \(gv.count) channel-values (\(gv.count/3) pixels)")
    print("    GENERATOR - DECODER, PQ code units [0,1]:  \(stats(diffs))")
    let (m, b, r) = linfit(dv, gv)
    print("    least-squares fit  gen = \(fmt(m,6))·dec + \(fmt(b,6))    r = \(fmt(r,6))")
    let maxAbs = diffs.map { abs($0) }.max() ?? 0
    print("    max |difference| = \(fmt(maxAbs,8))  (1 ten-bit code = \(fmt(1.0/1023.0,8)))")
    print("    → \(fmt(maxAbs*1023.0,3)) ten-bit codes")

    if !flatOnly.isEmpty {
        let fd = flatOnly.map { $0.0 - $0.1 }
        print("    RESAMPLE-IMMUNE subset (flat 3×3 decoder neighbourhood), n=\(flatOnly.count):")
        print("      \(stats(fd))   max|Δ| = \(fmt(fd.map{abs($0)}.max() ?? 0, 8))")
    }

    // SHAPE: mean difference binned by decoder value. A flat row = offset; a rising row = scale or
    // curve; a row that saturates at the top = clipping at a ceiling.
    print("    SHAPE — mean(gen-dec) binned by decoder PQ value:")
    var bins = [[Double]](repeating: [], count: 10)
    for i in 0..<dv.count { bins[min(9, max(0, Int(dv[i]*10)))].append(gv[i]-dv[i]) }
    for (k, bin) in bins.enumerated() where !bin.isEmpty {
        let mm = bin.reduce(0,+)/Double(bin.count)
        let bar = String(repeating: "█", count: min(40, Int(abs(mm)*2000)))
        print(String(format: "      dec %.1f–%.1f  n=%7d  mean %+.6f  %@",
                     Double(k)/10, Double(k+1)/10, bin.count, mm, bar))
    }
    let gClip = gv.filter { $0 >= 0.9999 }.count, dClip = dv.filter { $0 >= 0.9999 }.count
    let gNeg = gv.filter { $0 <= 0.0 }.count, dNeg = dv.filter { $0 <= 0.0 }.count
    print("    ceiling/floor: gen at≥1.0 \(gClip), dec at≥1.0 \(dClip)   |   gen at≤0.0 \(gNeg), dec at≤0.0 \(dNeg)")
    print("    range: gen [\(fmt(gv.min()!,6)), \(fmt(gv.max()!,6))]   dec [\(fmt(dv.min()!,6)), \(fmt(dv.max()!,6))]")

    // ── SUPERWHITE: THE ONE ASYMMETRY THE TWO PATHS HAVE BY CONSTRUCTION ──────────────────────
    //
    // ⚠️ A FIXTURE THAT PEAKS AT EXACTLY 1.0 CANNOT TEST THIS, AND wedge-pq-24track.mov IS ONE.
    // Legal-range expansion maps code 940 → 1.0, so codes 941–1023 expand ABOVE 1.0. The two
    // paths then diverge by their own documented contracts:
    //
    //   * METAL keeps it. `passthroughFragment` returns half4 into an rgba16Float target and the
    //     shader comment is explicit: "NOT clamped: the rgba16Float target carries >1.0 and
    //     negatives, which is the whole point of E1."
    //   * THE GENERATOR cannot. CGImage.h, on the PQ/HLG float case: "16-bit or 32-bit float
    //     image components values will be CLIPPED to [0.0, 1.0] range."
    //
    // So on content containing superwhite, the overlay is clipped where the Metal layer is not —
    // a difference introduced at CREATION that no layer property can undo. This line is what says
    // whether the file under test can exercise that at all.
    let decSuper = dv.filter { $0 > 1.0 }.count, genSuper = gv.filter { $0 > 1.0 }.count
    if decSuper > 0 {
        let over = dv.filter { $0 > 1.0 }
        print("    ⚠️ SUPERWHITE PRESENT: decoder has \(decSuper) channel-values > 1.0 "
            + "(max \(fmt(over.max()!,6)) = code \(fmt(over.max()!*940.0,1))), generator has \(genSuper).")
        print("       The generator CLIPS these to 1.0 by documented contract; the Metal path keeps them.")
        print("       THIS IS A CREATION-SIDE DIFFERENCE and no layer property can undo it.")
    } else {
        print("    superwhite: NONE — decoder peaks at \(fmt(dv.max()!,6)) (≤ 1.0), so this file")
        print("       CANNOT exercise the generator's [0,1] float clip. A file graded above legal")
        print("       white is required to test it; this result does not clear that mechanism.")
    }
}

func pixdiff(path: String) async {
    let url = URL(fileURLWithPath: path); let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
          let dur = try? await asset.load(.duration).seconds else { print("!! load failed"); return }
    var codec = "?"
    if let fds = try? await track.load(.formatDescriptions), let f = fds.first {
        let c = CMFormatDescriptionGetMediaSubType(f)
        codec = String(bytes: [UInt8((c>>24)&0xff),UInt8((c>>16)&0xff),UInt8((c>>8)&0xff),UInt8(c&0xff)], encoding: .ascii) ?? "?" }
    let t = Double(ProcessInfo.processInfo.environment["T"] ?? "") ?? min(1.0, dur/2)
    print("\n================================================================================")
    print("PIXEL DIFF   \(url.lastPathComponent)   codec \(codec)   t = \(fmt(t,4))s")
    print("Comparing PQ CODE VALUES: generator CGImage vs shader arithmetic on the decoder buffer.")

    // Matrix coefficients, chosen the way MetalVideoRenderer.colorParams chooses them.
    var params = ShaderParams()
    if let dec = decodeFrame(asset: asset, track: track, at: t) {
        let m2020 = kCVImageBufferYCbCrMatrix_ITU_R_2020 as String
        let m601 = kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String
        if dec.matrix == m2020 { params = ShaderParams(a: 1.4746, b: 0.1646, c: 0.5714, d: 1.8814, isFullRange: false) }
        else if dec.matrix == m601 { params = ShaderParams(a: 1.5960, b: 0.3917, c: 0.8129, d: 2.0172, isFullRange: false) }
        else { params = ShaderParams(a: 1.5748, b: 0.1873, c: 0.4681, d: 1.8556, isFullRange: false) }
    }
    await pixelPass(label: "PASS 1 — NATIVE RASTER (maximumSize = .zero, no resampling anywhere)",
                    asset: asset, track: track, at: t, maxSize: .zero, params: params)
    await pixelPass(label: "PASS 2 — SHIPPING CONFIG (maximumSize = 960×540)",
                    asset: asset, track: track, at: t, maxSize: CGSize(width: 960, height: 540), params: params)
}

let n = Int(ProcessInfo.processInfo.environment["N"] ?? "40") ?? 40
let mode = ProcessInfo.processInfo.environment["MODE"] ?? "frames"
for p in CommandLine.arguments.dropFirst() {
    if mode == "pixdiff" { await pixdiff(path: p) } else { await run(path: p, samples: n) }
}
