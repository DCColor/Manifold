//
//  ICCTransferCurve.swift — read the red tone reproduction curve out of an ICC profile and say,
//  in plain words, what shape it is.
//
//  ── WHY THIS EXISTS AS SHIPPING CODE ────────────────────────────────────────────────────────
//
//  Phase 2b's chain readout has to tell the user what curve macOS assigned to their display. There
//  is already an ICC parser in `MetalVideoRenderer` — the `[CSPROBE]` block — and it CANNOT be used
//  here: it is inside `#if DEBUG`, it carries a "⚠️ TEMPORARY DIAGNOSTIC — DELETE WHOLESALE"
//  banner, and `docs/BUGS.md` records that it predates the colour-management arc and was
//  deliberately left untouched by it. Building a shipping readout on top of something marked for
//  deletion would either pin the probe in place or break the readout when it goes.
//
//  ⚠️ **THE NAME OF A PROFILE IS NOT EVIDENCE ABOUT ITS CURVE.** §6.5 measured the LG's profile as
//  a parametric γ1.960999 and the source as `curv count=1` γ1.960938 — the same curve to about one
//  hundredth of a 10-bit code, under two different ICC spellings and two different names. And in
//  §6.7 the same display, renamed nothing, switched to a 1024-entry sRGB table when macOS HDR was
//  turned on. Everything here is read from the bytes.
//
//  ── THE FAILURE THIS FILE IS SHAPED TO AVOID ────────────────────────────────────────────────
//
//  §6.5 records the probe's first version comparing the two TRCs **as encoding strings**, which
//  called `curv/count=1/gamma=1.960938` and `para/ft=0/[1.960999]` different and reported the A/B
//  as visible when it is invisible — "exactly backwards". So `maxDeviation(from:)` below evaluates
//  both curves NUMERICALLY over [0,1] and never compares representations. Two profiles that spell
//  one curve two ways must compare equal, because they ARE equal.
//

import Foundation
import CoreGraphics

// MARK: - Big-endian reads, bounds-checked

private extension Data {
    func be16(_ o: Int) -> UInt16? {
        guard o >= 0, o + 2 <= count else { return nil }
        return (UInt16(self[startIndex + o]) << 8) | UInt16(self[startIndex + o + 1])
    }
    func be32(_ o: Int) -> UInt32? {
        guard o >= 0, o + 4 <= count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(self[startIndex + o + i]) }
        return v
    }
    func ascii4(_ o: Int) -> String? {
        guard o >= 0, o + 4 <= count else { return nil }
        let b = (0..<4).map { self[startIndex + o + $0] }
        guard b.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
        return String(bytes: b, encoding: .ascii)
    }
    /// s15Fixed16Number — SIGNED. Reading it unsigned silently turns every negative parameter into
    /// a huge positive one, and `para` types 1–4 carry negative `b` routinely.
    func s15f16(_ o: Int) -> Double? {
        guard let raw = be32(o) else { return nil }
        return Double(Int32(bitPattern: raw)) / 65536.0
    }
}

// MARK: - The curve

/// The transfer curve of one channel of an ICC profile, plus the arithmetic needed to compare it
/// with another one and to describe it to a person.
struct ICCTransferCurve {

    /// What the encoding says the curve IS. Deliberately mirrors the ICC types rather than
    /// flattening everything to a gamma: `curv count=1` and `para functionType=0` are both pure
    /// power laws and are reported as such, but a 1024-entry table is not a power law and must not
    /// be described as though it were.
    enum Shape {
        /// `curv` with count 0 — the ICC identity curve.
        case identity
        /// A single exponent: `curv count=1` (u8Fixed8) or `para functionType=0`.
        case purePower(gamma: Double)
        /// `para` functionType 1–4 — the piecewise families, sRGB's shape among them.
        case parametric(functionType: Int, params: [Double])
        /// `curv` with count > 1 — a sampled table. The most common display-profile encoding.
        case table(count: Int)
        /// No rTRC, or one this parser will not guess at. **Carries its reason**, because a
        /// readout that says "unknown" without saying why sends someone to the wrong place.
        case unavailable(reason: String)
    }

    let shape: Shape

    /// The sampled values, normalised to [0,1], when `shape` is `.table`.
    private let table: [Double]?

    // MARK: Evaluation

    /// Evaluate the curve at `x` in [0,1]. Linear interpolation between table entries, which is
    /// what the ICC spec prescribes for `curv`.
    func eval(_ x: Double) -> Double {
        let x = min(max(x, 0.0), 1.0)
        switch shape {
        case .identity:
            return x
        case .purePower(let g):
            return pow(x, g)
        case .parametric(let ft, let p):
            return Self.evalParametric(functionType: ft, params: p, x: x)
        case .table:
            guard let t = table, t.count > 1 else { return x }
            let pos = x * Double(t.count - 1)
            let i = min(Int(pos), t.count - 2)
            let f = pos - Double(i)
            return t[i] * (1 - f) + t[i + 1] * f
        case .unavailable:
            return x
        }
    }

    /// The ICC parametricCurveType families, spelled out so the arithmetic can be checked against
    /// the spec rather than trusted.
    private static func evalParametric(functionType ft: Int, params p: [Double], x: Double) -> Double {
        func at(_ i: Int) -> Double { i < p.count ? p[i] : 0 }
        let g = at(0)
        switch ft {
        case 0:                                    // Y = X^g
            return pow(x, g)
        case 1:                                    // Y = (aX+b)^g   for X >= -b/a, else 0
            let a = at(1), b = at(2)
            return x >= (a == 0 ? .infinity : -b / a) ? pow(max(a * x + b, 0), g) : 0
        case 2:                                    // Y = (aX+b)^g + c  for X >= -b/a, else c
            let a = at(1), b = at(2), c = at(3)
            return x >= (a == 0 ? .infinity : -b / a) ? pow(max(a * x + b, 0), g) + c : c
        case 3:                                    // Y = (aX+b)^g for X >= d, else cX   (sRGB shape)
            let a = at(1), b = at(2), c = at(3), d = at(4)
            return x >= d ? pow(max(a * x + b, 0), g) : c * x
        case 4:                                    // Y = (aX+b)^g + e for X >= d, else cX + f
            let a = at(1), b = at(2), c = at(3), d = at(4), e = at(5), f = at(6)
            return x >= d ? pow(max(a * x + b, 0), g) + e : c * x + f
        default:
            return x
        }
    }

    /// Is this curve usable for comparison at all?
    var isUsable: Bool {
        if case .unavailable = shape { return false }
        return true
    }

    // MARK: Comparison

    /// Max |self(x) − other(x)| over [0,1], sampled uniformly.
    ///
    /// ⚠️ **NUMERIC, NEVER BY ENCODING** — see the header. Returns nil when either curve is
    /// unavailable, because "no answer" and "they agree" are different and must not be conflated.
    func maxDeviation(from other: ICCTransferCurve, samples: Int = 1024) -> Double? {
        guard isUsable, other.isUsable else { return nil }
        var worst = 0.0
        for i in 0...samples {
            let x = Double(i) / Double(samples)
            worst = max(worst, abs(eval(x) - other.eval(x)))
        }
        return worst
    }

    /// Half of one 10-bit code. The threshold `[CSPROBE]`'s verdict already uses for "these are the
    /// same curve", kept identical so the readout and the probe cannot disagree about one display.
    static let sameCurveThreshold = 0.5 / 1023.0

    // MARK: Description

    /// Candidate curves a display profile is likely to be, for the "what does it match" half of the
    /// readout. sRGB first because it is what vendor profiles overwhelmingly are — and, per §6.7,
    /// what macOS hands the LG in HDR mode.
    private static let candidates: [(name: String, f: (Double) -> Double)] = [
        ("sRGB", { x in x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }),
        ("gamma 1.8", { pow($0, 1.8) }),
        ("gamma 1.961", { pow($0, 1.960938) }),
        ("gamma 2.2", { pow($0, 2.2) }),
        ("gamma 2.4", { pow($0, 2.4) }),
    ]

    /// Closest named candidate and its max deviation.
    private var bestMatch: (name: String, err: Double)? {
        guard isUsable else { return nil }
        var best: (String, Double)?
        for c in Self.candidates {
            var worst = 0.0
            for i in 0...1024 {
                let x = Double(i) / 1024.0
                worst = max(worst, abs(eval(x) - c.f(x)))
            }
            if best == nil || worst < best!.1 { best = (c.name, worst) }
        }
        return best.map { (name: $0.0, err: $0.1) }
    }

    private static func fmtErr(_ e: Double) -> String {
        e == 0 ? "0" : String(format: "%.1e", e)
    }

    /// One line, for a person, describing the shape — and, when it is a table or a piecewise
    /// family, what standard curve it actually matches.
    ///
    /// The task this serves is "tell me what my display is doing", so a table that matches sRGB to
    /// 7.6e-06 should SAY sRGB. But it still says "sampled table" first, because the two are not
    /// the same thing and a future profile could be a table that matches nothing.
    var plainDescription: String {
        switch shape {
        case .identity:
            return "identity (no transfer)"
        case .purePower(let g):
            return String(format: "pure power law, gamma %.6g", g)
        case .table(let n):
            guard let m = bestMatch else { return "sampled table, \(n) entries" }
            return m.err <= 1e-3
                ? "sampled table, \(n) entries — matches \(m.name) to \(Self.fmtErr(m.err))"
                : "sampled table, \(n) entries — matches no standard curve (closest \(m.name), \(Self.fmtErr(m.err)))"
        case .parametric(let ft, let p):
            // functionType 0 is reported as a pure power law by `parse`, so anything arriving here
            // is genuinely piecewise.
            let g = p.first.map { String(format: "g=%.6g", $0) } ?? ""
            guard let m = bestMatch else { return "parametric type \(ft) \(g)" }
            return m.err <= 1e-3
                ? "parametric type \(ft) — matches \(m.name) to \(Self.fmtErr(m.err))"
                : "parametric type \(ft) \(g) — matches no standard curve (closest \(m.name), \(Self.fmtErr(m.err)))"
        case .unavailable(let why):
            return "other — \(why)"
        }
    }

    // MARK: Parsing

    /// Read the rTRC out of raw ICC bytes.
    ///
    /// Only the red channel: the readout is one line, all three channels agree on every profile
    /// this app has encountered, and claiming to have checked three when the line shows one would
    /// be a bigger lie than the simplification.
    static func parseRTRC(iccData: Data) -> ICCTransferCurve {
        guard iccData.count >= 132 else {
            return ICCTransferCurve(shape: .unavailable(reason: "ICC too short"), table: nil)
        }
        guard let tagCount = iccData.be32(128), tagCount > 0, tagCount < 1024 else {
            return ICCTransferCurve(shape: .unavailable(reason: "no readable tag table"), table: nil)
        }
        var tagOffset: Int?
        var tagSize = 0
        for i in 0..<Int(tagCount) {
            let e = 132 + i * 12
            guard let sig = iccData.ascii4(e),
                  let off = iccData.be32(e + 4), let sz = iccData.be32(e + 8) else { continue }
            if sig == "rTRC" { tagOffset = Int(off); tagSize = Int(sz); break }
        }
        guard let off = tagOffset, off + 12 <= iccData.count else {
            // PQ and HLG profiles legitimately land here: §3 established they declare transfer
            // through `cicp` and an A2B LUT, not through an rTRC. That is not a parse failure and
            // the reason string has to say so, or someone will go looking for a corrupt profile.
            return ICCTransferCurve(
                shape: .unavailable(reason: "profile declares no rTRC (PQ/HLG use cicp + LUT)"),
                table: nil)
        }
        guard let type = iccData.ascii4(off) else {
            return ICCTransferCurve(shape: .unavailable(reason: "unreadable rTRC type"), table: nil)
        }

        switch type {
        case "curv":
            guard let n = iccData.be32(off + 8) else {
                return ICCTransferCurve(shape: .unavailable(reason: "curv with no count"), table: nil)
            }
            if n == 0 { return ICCTransferCurve(shape: .identity, table: nil) }
            if n == 1 {
                // u8Fixed8Number — NOT a plain integer. /256.
                guard let raw = iccData.be16(off + 12) else {
                    return ICCTransferCurve(shape: .unavailable(reason: "curv count=1 truncated"), table: nil)
                }
                return ICCTransferCurve(shape: .purePower(gamma: Double(raw) / 256.0), table: nil)
            }
            let count = Int(n)
            guard off + 12 + count * 2 <= iccData.count, count <= 65536 else {
                return ICCTransferCurve(shape: .unavailable(reason: "curv table truncated"), table: nil)
            }
            var t = [Double](); t.reserveCapacity(count)
            for i in 0..<count {
                guard let v = iccData.be16(off + 12 + i * 2) else { break }
                t.append(Double(v) / 65535.0)
            }
            guard t.count == count else {
                return ICCTransferCurve(shape: .unavailable(reason: "curv table short read"), table: nil)
            }
            return ICCTransferCurve(shape: .table(count: count), table: t)

        case "para":
            guard let ftRaw = iccData.be16(off + 8) else {
                return ICCTransferCurve(shape: .unavailable(reason: "para with no functionType"), table: nil)
            }
            let ft = Int(ftRaw)
            let counts = [0: 1, 1: 3, 2: 4, 3: 5, 4: 7]
            guard let want = counts[ft] else {
                return ICCTransferCurve(shape: .unavailable(reason: "para functionType \(ft) unknown"), table: nil)
            }
            guard off + 12 + want * 4 <= iccData.count, tagSize == 0 || off + tagSize <= iccData.count else {
                return ICCTransferCurve(shape: .unavailable(reason: "para params truncated"), table: nil)
            }
            var p = [Double]()
            for i in 0..<want {
                guard let v = iccData.s15f16(off + 12 + i * 4) else { break }
                p.append(v)
            }
            guard p.count == want else {
                return ICCTransferCurve(shape: .unavailable(reason: "para param short read"), table: nil)
            }
            // functionType 0 IS a pure power law. Reporting it as "parametric" would make the LG's
            // profile and the source profile read as different kinds of thing when §6.5 measured
            // them as the same curve to 1.1e-05 — the string-comparison error, reintroduced through
            // the description instead of the comparison.
            if ft == 0 { return ICCTransferCurve(shape: .purePower(gamma: p[0]), table: nil) }
            return ICCTransferCurve(shape: .parametric(functionType: ft, params: p), table: nil)

        default:
            return ICCTransferCurve(shape: .unavailable(reason: "rTRC type '\(type)'"), table: nil)
        }
    }

    /// Read the rTRC of a `CGColorSpace`, when it can produce ICC bytes at all.
    static func parseRTRC(colorSpace: CGColorSpace) -> ICCTransferCurve {
        guard let icc = colorSpace.copyICCData() as Data? else {
            return ICCTransferCurve(shape: .unavailable(reason: "colorspace exposes no ICC data"),
                                    table: nil)
        }
        return parseRTRC(iccData: icc)
    }
}
