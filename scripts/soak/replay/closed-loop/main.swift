import Foundation
// CLOSED-LOOP replay of the working tree's fit + cross-check + depth-slope fallback (README.md).
// At each logged steering window the queue depth the new line would have produced is rebuilt from
// the invariant depth_new = offset_new − (offset_old − depth_old) and fed back to the check.
//   replay-closed <name> [logonly]                                from <name>.pairs/.windows.tsv
//   replay-closed synth <label> <b ppm> <noise ms> <seconds> [logonly]   flat SRs, media slope b
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
struct RNG { var s: UInt64; mutating func g() -> Double {
    func u(_ s: inout UInt64) -> Double { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53) }
    let a = max(u(&s), 1e-300), b = u(&s); return (-2 * log(a)).squareRoot() * cos(2 * .pi * b) } }
let args = CommandLine.arguments
var name = args[1]
var pairs: [[Double]] = [], wins: [[Double]] = []   // wins: t, depthOld, offOld
let logOnly = args.last == "logonly"
if name == "synth" {
    name = args[2]; let b = Double(args[3])! * 1e-6, noise = Double(args[4])! * 1e-3, T = Double(args[5])!
    var r = RNG(s: 7)
    var t = 0.0; while t < T { pairs.append([t, -0.020 + 7e-6 * r.g()]); t += 1 }
    // offset_old − depth_old = b·t + noise: offset_old 0 (flat SRs), depth_old = 0.42 − b·t − noise.
    t = 10; while t < T { let inv = b * t + noise * r.g(); wins.append([t, 0.420 - inv, 0]); t += 10 }
} else {
    pairs = rows(name + ".pairs.tsv"); wins = rows(name + ".windows.tsv")
}
var cp = SenderReportSlopeCrossCheck.Parameters(); cp.fallbackEnabled = !logOnly
cp.applies = true   // research replay: the hold applied (the app is observe-only, §18.21)
var lines: [String] = []
let fit = SenderReportLineFit.make(timeline: .rtpSenderReports, tag: "[R]", reportsWindows: false,
                                   crossCheckParameters: cp, log: { lines.append($0) })!
var depthNew: [(t: Double, d: Double)] = []
var engagedAt: Double?; var engagedSlope = 0.0
var wi = 0
func doWindow(_ w: [Double]) {
    guard let e = fit.evaluate(atVideoTime: w[0]) else { return }
    let inv = w[2] - w[1]                       // offset_old − depth_old = b_true·t + c
    let d = e.offset - inv                       // depth this line would have produced
    depthNew.append((w[0], d))
    for l in fit.windowLines(time: w[0], rendererDepth: d, appliedOffset: e.offset, appliedSlope: e.slope) {
        lines.append(l)
        if l.contains("ENGAGED at"), engagedAt == nil { engagedAt = w[0] }
    }
}
for p in pairs {
    while wi < wins.count, wins[wi][0] <= p[0] { doWindow(wins[wi]); wi += 1 }
    fit.notePair(videoTime: p[0], delta: p[1])
}
while wi < wins.count { doWindow(wins[wi]); wi += 1 }
let snap = fit.snapshot
let cc = fit.crossCheck
if let x = pairs.last?[0], let ev = fit.evaluate(atVideoTime: x) { engagedSlope = ev.slope }
func meanDepth(_ a: Double, _ b: Double) -> Double {
    let s = depthNew.filter { $0.t >= a && $0.t <= b }.map(\.d).sorted(); return s.isEmpty ? .nan : s[s.count / 2] }
func theil(_ x: [Double], _ y: [Double]) -> Double {
    var s: [Double] = []
    for i in x.indices { for j in (i + 1)..<x.count where x[j] > x[i] { s.append((y[j] - y[i]) / (x[j] - x[i])) } }
    s.sort(); return s.isEmpty ? .nan : s[s.count / 2] }
let late = depthNew.filter { $0.t >= 180 }
let trend = late.count > 3 ? theil(late.map(\.t), late.map(\.d)) * 1800 : .nan
let end = depthNew.last?.t ?? 0
let tail = depthNew.filter { $0.t >= end - 600 }
let steady = tail.count > 3 ? theil(tail.map(\.t), tail.map(\.d)) * 1800 : .nan
let se = end >= 1690 ? meanDepth(1560, 1690) - meanDepth(180, 310) : .nan
print(String(format: "%@\t%@\tslope %+.2f\tapplied(end) %+.2f\trej %d\tsteps %d\tunst %d\tmaxstep %.3f\tengaged %@\tepisodes %d\tdrift30(trend from 180s) %+.1f\tstart→end(+3→+26) %+.1f\tsteady(last 600 s) %+.1f\tWARN %d",
    name, logOnly ? "log-only" : "fallback", snap.slopeFit * 1e6, engagedSlope * 1e6, snap.rejected, snap.steps,
    snap.unstableEpisodes, snap.maxOffsetStep * 1e3,
    engagedAt.map { String(format: "at %.0f s", $0) } ?? "never", cc.engageCount, trend * 1e3, se * 1e3, steady * 1e3, cc.warningCount))
for l in lines where l.contains("ENGAGED") || l.contains("DISENGAGED") || l.contains("SR DEVIATION") {
    FileHandle.standardError.write("  | \(l.prefix(260))\n".data(using: .utf8)!) }
var out = ""; for d in depthNew { out += String(format: "%.1f\t%.6f\n", d.t, d.d) }
try! out.write(toFile: "\(name).\(logOnly ? "logonly" : "fallback").depth.tsv", atomically: true, encoding: .utf8)
