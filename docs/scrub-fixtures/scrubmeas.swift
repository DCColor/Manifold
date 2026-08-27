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
let n = Int(ProcessInfo.processInfo.environment["N"] ?? "40") ?? 40
for p in CommandLine.arguments.dropFirst() { await run(path: p, samples: n) }
