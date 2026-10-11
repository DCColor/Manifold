// Stage 3b S2 measurement (COLOR_MANAGEMENT_FINDINGS.md §6.10, *S2 — results*): one ⌃⌥E dump stem
// (<stem>.rgba16f, .v210, .v210.json, written by a Profile build) against a fixture pattern.
//   swiftc -O -o /tmp/measure scripts/chroma/measure.swift
//   /tmp/measure <lines|checker|none> <stem> [tol=2]
// Export: the rgba16Float readback converted to 10-bit Y'CbCr codes with the dump's own kr/kb, limited
// range (64 + 876·Y, 512 + 896·C), chroma rounded to the nearest code. Wire: the v210 words as written.
import Foundation
let a = CommandLine.arguments
let pattern = a[1], stem = a[2], tol = a.count > 3 ? Double(a[3])! : 2
let meta = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: stem + ".v210.json"))) as! [String: Any]
let w = meta["width"] as! Int, h = meta["height"] as! Int
let rbpr = meta["readbackBytesPerRow"] as! Int, rowBytes = meta["rowBytes"] as! Int
let kr = meta["kr"] as! Double, kb = meta["kb"] as! Double, kg = 1 - kr - kb
let raw = try! Data(contentsOf: URL(fileURLWithPath: stem + ".rgba16f"))
let wire = try! Data(contentsOf: URL(fileURLWithPath: stem + ".v210"))

func expected(_ x: Int, _ y: Int) -> (Double, Double) {
    let even = pattern == "lines" ? y % 2 == 0 : (x + y) % 2 == 0
    return even ? (724, 300) : (300, 724)
}
var ys = [Double](), cbE = [[Double]](repeating: [], count: h), crE = cbE
raw.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
    for y in 0..<h {
        let row = p.baseAddress!.advanced(by: y * rbpr).assumingMemoryBound(to: Float16.self)
        var cbs = [Double](repeating: 0, count: w), crs = cbs
        for x in 0..<w {
            let r = Double(row[x*4]), g = Double(row[x*4+1]), b = Double(row[x*4+2])
            let yy = kr*r + kg*g + kb*b
            // Rounded to the nearest code: a 10-bit code is an integer, and comparing an unrounded
            // 726.1 with "±2 of 724" would fail a sample the wire (which rounds) carries as 726.
            cbs[x] = (512 + 896 * (b - yy) / (2 * (1 - kb))).rounded()
            crs[x] = (512 + 896 * (r - yy) / (2 * (1 - kr))).rounded()
            if x % 8 == 0 && y % 8 == 0 { ys.append(64 + 876 * yy) }
        }
        cbE[y] = cbs; crE[y] = crs
    }
}
// v210: 6 pixels per 16 bytes; chroma sample k (pixels 2k, 2k+1).
var cbW = [[Double]](repeating: [], count: h), crW = cbW, yW = [Double]()
wire.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
    for y in 0..<h {
        let words = p.baseAddress!.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt32.self)
        var cb = [Double](), cr = [Double]()
        for g in 0..<(w / 6) {
            func c(_ i: Int, _ s: Int) -> Double { Double((words[g*4+i] >> UInt32(s)) & 0x3FF) }
            cb += [c(0,0), c(1,10), c(2,20)]; cr += [c(0,20), c(2,0), c(3,10)]
            if y % 8 == 0 && g % 4 == 0 { yW.append(c(0,10)) }
        }
        cbW[y] = cb; crW[y] = cr
    }
}
func pct(_ n: Int, _ d: Int) -> String { String(format: "%.3f%%", 100 * Double(n) / Double(max(d, 1))) }
func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(max(v.count, 1)) }
print(String(format: "%@ %dx%d  Y export mean %.1f [%.0f…%.0f]  wire mean %.1f", (stem as NSString).lastPathComponent, w, h,
             mean(ys), ys.min()!, ys.max()!, mean(yW)))
print(String(format: "  export row0 Cb/Cr %.1f/%.1f row1 %.1f/%.1f | wire row0 %.1f/%.1f row1 %.1f/%.1f",
             mean(cbE[0]), mean(crE[0]), mean(cbE[1]), mean(crE[1]), mean(cbW[0]), mean(crW[0]), mean(cbW[1]), mean(crW[1])))
switch pattern {
case "lines":
    var rowsE = 0, rowsW = 0
    for y in 0..<h {
        let (ecb, ecr) = expected(0, y)
        let okE = (0..<w).filter { abs(cbE[y][$0] - ecb) <= tol && abs(crE[y][$0] - ecr) <= tol }.count
        let okW = (0..<cbW[y].count).filter { abs(cbW[y][$0] - ecb) <= tol && abs(crW[y][$0] - ecr) <= tol }.count
        if Double(okE) >= 0.99 * Double(w) { rowsE += 1 }
        if Double(okW) >= 0.99 * Double(cbW[y].count) { rowsW += 1 }
    }
    print("  P3 rows within ±\(Int(tol)) of their own line: export \(rowsE)/\(h) (\(pct(rowsE, h)))  wire \(rowsW)/\(h) (\(pct(rowsW, h)))")
case "checker":
    var okE = 0, okW = 0, nW = 0
    for y in 0..<h {
        for x in 0..<w { let (ecb, ecr) = expected(x, y); if abs(cbE[y][x] - ecb) <= tol && abs(crE[y][x] - ecr) <= tol { okE += 1 } }
        for k in 0..<cbW[y].count { nW += 1; if abs(cbW[y][k] - 512) <= tol && abs(crW[y][k] - 512) <= tol { okW += 1 } }
    }
    print("  P4 export samples within ±\(Int(tol)) of the checker: \(pct(okE, w*h))   P5 wire within 512±\(Int(tol)): \(pct(okW, nW))")
default: break
}
