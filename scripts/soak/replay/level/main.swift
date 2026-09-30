import Foundation
// CLOSED-LOOP replay of the working tree's fit + level hold (AUDIO_RESAMPLER_DESIGN.md §18.20).
// At each logged steering window the queue depth the new target would have produced is rebuilt from
// the invariant depth_new = offset_new − (offset_old − depth_old) and fed back (README.md, Replay).
//   replay-level <name> [logonly]                          from <name>.pairs/.windows.tsv
//   replay-level synth <label> <b ppm> <noise ms> <seconds> [logonly]   flat SRs, media slope b
//   replay-level sweep <name>                              §18.9's forced-engagement sweep
// Lip-sync walk ∝ depth change. "start" = median depth 60–120 s (§6.3), "+26" = 1560–1690 s.
func rows(_ path: String) -> [[Double]] {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return s.split(separator: "\n").map { $0.split(separator: "\t").compactMap { Double($0) } }
}
struct RNG { var s: UInt64; mutating func g() -> Double {
    func u(_ s: inout UInt64) -> Double { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53) }
    let a = max(u(&s), 1e-300), b = u(&s); return (-2 * log(a)).squareRoot() * cos(2 * .pi * b) } }

struct Result { var depth: [(t: Double, d: Double)] = []; var lines: [String] = []; var episodes = 0; var mode = "" }

func replay(_ pairs: [[Double]], _ wins: [[Double]], logOnly: Bool, forceAt: Double? = nil) -> Result {
    var cp = SenderReportSlopeCrossCheck.Parameters()
    cp.fallbackEnabled = !logOnly; cp.forceEngageAt = forceAt
    // A research replay: the hold APPLIED (the app is observe-only, `levelHoldApplies` false, §18.21).
    cp.applies = true
    var r = Result()
    let fit = SenderReportLineFit.make(timeline: .rtpSenderReports, tag: "[R]", reportsWindows: false,
                                       crossCheckParameters: cp, log: { _ in })!
    var wi = 0
    func doWindow(_ w: [Double]) {
        guard let e = fit.evaluate(atVideoTime: w[0]) else { return }
        let d = e.offset - (w[2] - w[1])       // offset_old − depth_old = b_true·t + c
        r.depth.append((w[0], d))
        r.lines += fit.windowLines(time: w[0], rendererDepth: d, appliedOffset: e.offset, appliedSlope: e.slope)
    }
    for p in pairs {
        while wi < wins.count, wins[wi][0] <= p[0] { doWindow(wins[wi]); wi += 1 }
        fit.notePair(videoTime: p[0], delta: p[1])
    }
    while wi < wins.count { doWindow(wins[wi]); wi += 1 }
    r.episodes = fit.crossCheck.engageCount; r.mode = fit.crossCheck.currentMode.rawValue
    return r
}
func med(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }
func at(_ r: Result, _ a: Double, _ b: Double) -> Double { med(r.depth.filter { $0.t >= a && $0.t <= b }.map(\.d)) }

let args = CommandLine.arguments
var name = args[1]
var pairs: [[Double]] = [], wins: [[Double]] = []
if name == "synth" {
    name = args[2]; let b = Double(args[3])! * 1e-6, noise = Double(args[4])! * 1e-3, T = Double(args[5])!
    var g = RNG(s: 7)
    var t = 0.0; while t < T { pairs.append([t, -0.020 + 7e-6 * g.g()]); t += 1 }
    t = 10; while t < T { let inv = b * t + noise * g.g(); wins.append([t, 0.420 - inv, 0]); t += 10 }
} else if name == "sweep" {
    name = args[2]; pairs = rows(name + ".pairs.tsv"); wins = rows(name + ".windows.tsv")
} else {
    pairs = rows(name + ".pairs.tsv"); wins = rows(name + ".windows.tsv")
}

if args[1] == "sweep" {
    // Forced at every minute from 300 s: error = forced depth − unforced depth, from the force on.
    let base = replay(pairs, wins, logOnly: false)
    guard base.episodes == 0 else { print("\(name): engages unforced — the sweep needs a clean reference"); exit(1) }
    let end = base.depth.last!.t
    var fromStart = 0.0
    var peaks: [Double] = [], ends: [Double] = [], released = 0, worst = (t: 0.0, e: 0.0), releaseAfter: [Double] = []
    var f = 300.0
    while f < end - 60 {
        let r = replay(pairs, wins, logOnly: false, forceAt: f)
        var pk = 0.0, offAt: Double?
        let start = at(base, 60, 120)
        if let l = r.lines.first(where: { $0.contains("LEVEL HOLD OFF") }),
           let m = l.range(of: #"t=(\d+)"#, options: .regularExpression) {
            offAt = Double(l[m].dropFirst(2))
        }

        for (i, p) in r.depth.enumerated() where p.t >= f {
            let e = p.d - base.depth[i].d
            if abs(e) > abs(pk) { pk = e }
        }
        // Against the SESSION START (§18.20, Robbie 2026-09-30): the forced run's level — a 300 s
        // rolling median, so a rail event or pause (common to every run, and short) does not count —
        // from 10 min after the force, while it is engaged or releasing.
        let offT = offAt ?? .infinity
        let held = r.depth.filter { $0.t >= f + 600 && $0.t < offT }
        for p in held {
            let lvl = med(r.depth.filter { $0.t > p.t - 300 && $0.t <= p.t }.map(\.d))
            fromStart = max(fromStart, abs(lvl - start))
        }
        if let o = offAt { released += 1; releaseAfter.append(o - f) }
        peaks.append(abs(pk)); ends.append(r.depth.last!.d - base.depth.last!.d)
        if abs(pk) > abs(worst.e) { worst = (f, pk) }
        f += 60
    }
    print(String(format: "%@ sweep: %d forced engagements · peak |error| worst %+.1f ms (forced at %.0f s), median %.1f, p90 %.1f ms · released by itself %d of %d (median %.0f min after) · |error| at the log's end worst %.1f ms · forced runs vs the SESSION START (300 s level, from 10 min after the force, while held) worst %.1f ms",
        name, peaks.count, worst.e * 1e3, worst.t, med(peaks) * 1e3,
        peaks.sorted()[Int(Double(peaks.count) * 0.9)] * 1e3, released, peaks.count,
        med(releaseAfter) / 60, (ends.map(abs).max() ?? 0) * 1e3, fromStart * 1e3))
    exit(0)
}

let logOnly = args.last == "logonly"
let r = replay(pairs, wins, logOnly: logOnly)
let start = at(r, 60, 120)
let a26 = r.depth.last!.t >= 1690 ? at(r, 1560, 1690) - start : .nan
let after = r.depth.filter { $0.t >= 120 }
let worst = after.max { abs($0.d - start) < abs($1.d - start) }!
let end = r.depth.last!
let engaged = r.lines.first { $0.contains("LEVEL HOLD ENGAGED") }
    .flatMap { l in l.range(of: #"t=\d+"#, options: .regularExpression).map { String(l[$0].dropFirst(2)) } } ?? "never"
print(String(format: "%@\t%@\tengaged %@ (episodes %d, %@ at end)\tstart→+26 %+.1f ms\tworst from start %+.1f ms at %.0f s\tend (%.0f s) %+.1f ms",
    name, logOnly ? "log-only" : "level", engaged, r.episodes, r.mode, a26 * 1e3,
    (worst.d - start) * 1e3, worst.t, end.t, (end.d - start) * 1e3))
for l in r.lines where l.contains("LEVEL HOLD") || l.contains("SR DEVIATION") {
    FileHandle.standardError.write("  | \(l.prefix(240))\n".data(using: .utf8)!) }
var out = ""; for d in r.depth { out += String(format: "%.1f\t%.6f\n", d.t, d.d) }
try! out.write(toFile: "\(name).\(logOnly ? "logonly" : "level").depth.tsv", atomically: true, encoding: .utf8)
