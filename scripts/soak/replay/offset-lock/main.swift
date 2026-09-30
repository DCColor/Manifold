import Foundation
// OPEN-LOOP replay: the working tree's SR fit (the level hold observe-only, as the app ships) against the
// candidate OFFSET LOCK (AUDIO_RESAMPLER_DESIGN.md §18.22). Both are fed the logged SR pairs; the figure
// is the APPLIED OFFSET itself, not queue depth: on MediaMTX lip-sync moves 1:1 with the applied offset
// and the queue is not lip-sync (§18.21).
//   [LOCK_MODE=integrate|gated|anchored] replay-offset-lock <name> [refStart refEnd]
//   from <name>.pairs.tsv; reference span default 60–120 s
// Offset lock:
//   - the offset is the fit's applied offset at the end of the reference span, taken once;
//   - after that only the slope comes from the SRs: OLS over the trailing `slopeWindow` of Δ with every
//     confirmed step removed. A step is a pair-to-pair jump over max(50 µs, 8σ) (σ from the MAD of the
//     session's first differences so far) that PERSISTS: the median of the next `confirm` pairs sits
//     over the threshold from the median of the previous `confirm`. A one- or two-pair spike is not a step;
//   - the applied offset never re-levels on a step. LOCK_MODE picks how the slope enters it:
//       integrate  integrate the trailing-window slope (default);
//       gated      the same, the slope used only once its OLS standard error ≤ 10 ppm (the fit's bound);
//       anchored   a line through the reference point, sloped by OLS over everything since the span;
//       stepfree   no lock: a second copy of the fit, fed the step-free Δ `confirm` pairs late (each pair
//                  once its step decision is made). Offset and slope still come from the SRs; a step is
//                  never followed. On a session with no step it is the fit, `confirm` pairs behind;
//   - before the reference ends, the lock applies what the fit applies.
// The lock's real-discontinuity re-level (RTP timestamp jump, restart, SSRC change) is not in this
// replay: no logged session contains one inside it, and a restart is a new session here.
// Prints one TSV row and writes <name>.offset-lock-<mode>.trace.tsv (x, Δ, fit applied, lock applied, lock slope).
func rows(_ path: String) -> [[Double]] {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return s.split(separator: "\n").map { $0.split(separator: "\t").compactMap { Double($0) } }
}
func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }
func mean(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count) }

let args = CommandLine.arguments
let name = args[1]
let refStart = args.count > 3 ? Double(args[2])! : 60, refEnd = args.count > 3 ? Double(args[3])! : 120
let pairs = rows(name + ".pairs.tsv")
/// LOCK_MODE: integrate (default) | gated | anchored | stepfree — how the slope becomes the applied offset.
let mode = ProcessInfo.processInfo.environment["LOCK_MODE"] ?? "integrate"
let slopeWindow = 600.0, slopeMinSpan = 60.0, slopeClamp = 150e-6, slopeSEBound = 10e-6, confirm = 5

let fit = SenderReportLineFit.make(timeline: .rtpSenderReports, tag: "[R]", reportsWindows: false,
                                   log: { _ in })!
let stepFree = SenderReportLineFit.make(timeline: .rtpSenderReports, tag: "[S]", reportsWindows: false,
                                        log: { _ in })!
var xs: [Double] = [], ds: [Double] = []
var clean: [Double] = []            // Δ with confirmed steps removed (slope input only)
var removed = 0.0, steps: [(x: Double, size: Double)] = []
var lockRef: Double?, lockRefX = 0.0, lockApplied = 0.0, lockSlope = 0.0, lastX = 0.0
var trace: [(x: Double, d: Double, fit: Double, lock: Double, slope: Double)] = []
var decided = 0                     // pairs whose step decision is made (lags by `confirm`)

func sigma(upTo n: Int) -> Double {
    let lo = max(1, n - 300)
    guard n - lo >= 20 else { return .infinity }
    let dif = (lo..<n).map { ds[$0] - ds[$0 - 1] }
    let m = median(dif)
    return 1.4826 * median(dif.map { abs($0 - m) })
}

for p in pairs {
    let x = p[0], d = p[1]
    fit.notePair(videoTime: x, delta: d)
    xs.append(x); ds.append(d); clean.append(d - removed)
    // Decide the pair `confirm` back, now that the pairs after it are known.
    while decided < xs.count - confirm {
        let i = decided; decided += 1
        defer { stepFree.notePair(videoTime: xs[i], delta: clean[i]) }
        guard i >= confirm else { continue }
        let thr = max(50e-6, 8 * sigma(upTo: i))
        guard abs(ds[i] - ds[i - 1]) > thr else { continue }
        // On the step-free series: raw Δ would count a step within the last `confirm` pairs twice.
        let pre = median(Array(clean[(i - confirm)..<i])), post = median(Array(clean[i..<(i + confirm)]))
        guard abs(post - pre) > thr else { continue }        // a spike, not a step
        let size = post - pre
        steps.append((xs[i], size)); removed += size
        for k in i..<clean.count { clean[k] -= size }
    }
    guard let e = fit.evaluate(atVideoTime: x) else { continue }
    if mode == "stepfree" {
        let f = stepFree.evaluate(atVideoTime: x)
        if lockRef == nil, x >= refEnd { lockRef = f?.offset ?? e.offset; lockRefX = x }
        trace.append((x, d, e.offset, f?.offset ?? e.offset, f?.slope ?? e.slope)); continue
    }
    if lockRef == nil {
        if x >= refEnd { lockRef = e.offset; lockRefX = x; lockApplied = e.offset; lastX = x }
        trace.append((x, d, e.offset, e.offset, e.slope)); continue
    }
    // Slope from the decided, step-free pairs: the trailing window (integrate, gated) or everything
    // since the reference span began (anchored).
    let n = decided
    let window = mode == "anchored" ? Double.infinity : slopeWindow
    var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, c = 0.0, first = Double.infinity
    for k in stride(from: n - 1, through: 0, by: -1) {
        guard xs[k] >= refStart else { break }
        guard xs[k] >= x - window else { break }
        sx += xs[k]; sy += clean[k]; sxx += xs[k] * xs[k]; sxy += xs[k] * clean[k]; c += 1; first = xs[k]
    }
    if c > 10, n > 0, xs[n - 1] - first >= slopeMinSpan {
        let sxxc = sxx - sx * sx / c
        let b = (sxy - sx * sy / c) / sxxc, a = (sy - b * sx) / c
        var use = true
        if mode == "gated" {
            // The fit's discipline: a slope is used only once its standard error is within the bound.
            var rss = 0.0
            for k in stride(from: n - 1, through: 0, by: -1) {
                guard xs[k] >= first else { break }
                let r = clean[k] - (a + b * xs[k]); rss += r * r
            }
            use = (rss / max(1, c - 2) / sxxc).squareRoot() <= slopeSEBound
        }
        if use { lockSlope = min(slopeClamp, max(-slopeClamp, b)) }
    }
    if mode == "anchored" {
        lockApplied = lockRef! + lockSlope * (x - lockRefX)
    } else {
        lockApplied += lockSlope * (x - lastX); lastX = x
    }
    trace.append((x, d, e.offset, lockApplied, lockSlope))
}

func at(_ a: Double, _ b: Double, _ f: (Int) -> Double) -> Double {
    mean(trace.indices.filter { trace[$0].x >= a && trace[$0].x < b }.map(f))
}
let end = trace.last!
let refF = at(refEnd - 1, refEnd + 1) { trace[$0].fit }
let refL = lockRef ?? .nan
let hasB = end.x >= 1692
let aF = at(180, 312) { trace[$0].fit }, aL = at(180, 312) { trace[$0].lock }
let bF = hasB ? at(1560, 1692) { trace[$0].fit } : .nan, bL = hasB ? at(1560, 1692) { trace[$0].lock } : .nan
let maxDiff = trace.map { abs($0.fit - $0.lock) }.max()!
print(String(format: "%@\t%@\t%.0f s\tsteps %d (%+.1f ms)\tref %+.2f / %+.2f\tref→end fit %+.1f lock %+.1f ms\tA→B fit %+.1f lock %+.1f ms\tend slope fit %+.1f lock %+.1f ppm\tmax |fit−lock| %.1f ms",
    name, mode, end.x, steps.count, steps.map(\.size).reduce(0, +) * 1e3, refF * 1e3, refL * 1e3,
    (end.fit - refF) * 1e3, (end.lock - refL) * 1e3, (bF - aF) * 1e3, (bL - aL) * 1e3,
    fit.snapshot.appliedSlope * 1e6, end.slope * 1e6, maxDiff * 1e3))
var out = ""
for t in trace { out += String(format: "%.3f\t%.6f\t%.6f\t%.6f\t%.9f\n", t.x, t.d, t.fit, t.lock, t.slope) }
try! out.write(toFile: "\(name).offset-lock-\(mode).trace.tsv", atomically: true, encoding: .utf8)
