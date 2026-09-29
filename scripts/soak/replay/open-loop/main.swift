import Foundation
// OPEN-LOOP replay of the SR fit alone (README.md): the "before" build (a git revision's fit) or the
// "after" build (-D NEWFIT, the working tree's fit, cross-check log-only, no fallback).
//   replay-before|replay-after <name>
// Reads <name>.pairs.tsv (+ <name>.windows.tsv, from analysis/extract.py), prints one TSV row,
// writes <name>.<variant>.trace.tsv (x, applied offset, applied slope, Δ, holding).
#if NEWFIT
let variant = "new"
#else
let variant = "old"
#endif
func rows(_ path: String) -> [[Double]] {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return s.split(separator: "\n").map { $0.split(separator: "\t").compactMap { Double($0) } }
}
func ols(_ x: [Double], _ y: [Double]) -> Double {
    let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
    var sxx = 0.0, sxy = 0.0
    for i in x.indices { sxx += (x[i] - mx) * (x[i] - mx); sxy += (x[i] - mx) * (y[i] - my) }
    return sxy / sxx
}
func theil(_ x: [Double], _ y: [Double]) -> Double {
    var s: [Double] = []
    for i in x.indices { for j in (i + 1)..<x.count where x[j] > x[i] { s.append((y[j] - y[i]) / (x[j] - x[i])) } }
    s.sort(); return s.isEmpty ? .nan : s[s.count / 2]
}
let name = CommandLine.arguments[1]
let pairs = rows(name + ".pairs.tsv")
var log: [String] = []
#if NEWFIT
var logOnly = SenderReportSlopeCrossCheck.Parameters(); logOnly.fallbackEnabled = false
let fit = SenderReportLineFit.make(timeline: .rtpSenderReports, tag: "[REPLAY]", reportsWindows: false,
                                   crossCheckParameters: logOnly, log: { log.append($0) })!
#else
let fit = SenderReportLineFit.make(timeline: .rtpSenderReports, tag: "[REPLAY]", reportsWindows: false,
                                   log: { log.append($0) })!
#endif
var trace: [(x: Double, off: Double, slope: Double, d: Double, holding: Bool)] = []
var zeroAfterUse = 0, afterUse = 0, holdingPairs = 0
for p in pairs {
    fit.notePair(videoTime: p[0], delta: p[1])
    guard let e = fit.evaluate(atVideoTime: p[0]) else { continue }
    var holding = false
    if case .holding = e.state { holding = true; holdingPairs += 1 }
    trace.append((p[0], e.offset, e.slope, p[1], holding))
    if fit.snapshot.slopeFirstInUseAt != nil { afterUse += 1; if e.slope == 0 { zeroAfterUse += 1 } }
}
let snap = fit.snapshot
// Residual A/V drift against the SR data: trend of (applied offset − Δ) from 180 s on, × 1800 s.
let late = trace.filter { $0.x >= 180 }
let driftSR = ols(late.map(\.x), late.map { $0.off - $0.d }) * 1800
let offsetSlope = ols(late.map(\.x), late.map(\.off))
// Against the renderer queue: b_phys from the logged run (offset − depth), invariant to the line.
let wins = rows(name + ".windows.tsv").filter { $0[0] > 60 }
var phys = "—", driftPhys = "—", cross = "—"
if wins.count > 30 {
    let b = theil(wins.map { $0[0] }, wins.map { $0[2] - $0[1] })
    phys = String(format: "%+.2f", b * 1e6)
    driftPhys = String(format: "%+.1f", (offsetSlope - b) * 1800 * 1e3)
    #if NEWFIT
    // Replay the cross-check: the depth this line would have produced, from the invariant
    // depth_new = offset_new − (offset_old − depth_old), at each logged window.
    var warnings = 0, checks = 0
    var worst = 0.0
    for w in wins {
        let x = w[0]
        guard let tr = trace.last(where: { $0.x <= x }) else { continue }
        let offNew = tr.off + tr.slope * (x - tr.x)
        let depthNew = offNew - (w[2] - w[1])
        let lines = fit.crossCheck.note(time: x, videoTime: x, rendererDepth: depthNew,
                                        appliedOffset: offNew, srOffset: offNew,
                                        appliedSlope: tr.slope, reportsInfo: true)
        for l in lines { checks += 1; if l.contains("WARNING") { warnings += 1 } }
        if let c = fit.crossCheck.latest, abs(c.disagreement) > abs(worst) { worst = c.disagreement }
    }
    cross = String(format: "%d/%d warn, worst %+.1f ppm", warnings, checks, worst * 1e6)
    #endif
}
let episodes = snap.unstableEpisodes
let fmt = String(format: "%@\t%@\t%+.2f\t%@\t%@\t%.3f\t%.3f\t%d\t%d\t%d\t%d/%d\t%d\t%+.1f\t%@\t%@\t%@",
    name, variant, snap.slopeFit * 1e6, snap.slopeInUse ? "IN USE" : "not",
    snap.slopeFirstInUseAt.map { String(format: "%.0f", $0) } ?? "never",
    snap.maxOffsetStep * 1e3, snap.maxOffsetStepSteady * 1e3, snap.rejected, snap.steps, episodes,
    zeroAfterUse, afterUse, holdingPairs, driftSR * 1e3, phys, driftPhys, cross)
print(fmt)
let final = trace.last.map { String(format: "applied slope at end %+.2f ppm", $0.slope * 1e6) } ?? ""
FileHandle.standardError.write("  \(final); state \(snap.state)\n".data(using: .utf8)!)
for l in log where l.contains("STEPPED") || l.contains("UNSTABLE") || l.contains("STABLE again") || l.contains("LEFT") || l.contains("IN USE at") {
    FileHandle.standardError.write("  | \(l.prefix(230))\n".data(using: .utf8)!)
}
var out = ""
for t in trace { out += String(format: "%.3f\t%.6f\t%.9f\t%.6f\t%d\n", t.x, t.off, t.slope, t.d, t.holding ? 1 : 0) }
try! out.write(toFile: "\(name).\(variant).trace.tsv", atomically: true, encoding: .utf8)
