//
//  ReferencePlan.swift — colour S1, docs/COLOR_MANAGEMENT_FINDINGS.md §6.11.
//
//  What the Reference display transform does for ONE source on ONE display: what the layer is
//  told (its colorspace), and what the display stage's shader does (nothing, BT.1886, or a
//  primaries conversion). A pure function of five facts, so the renderer, the chain readout and the
//  log all describe the same decision, and none of them re-derives it.
//
//  ── THE FOUR OUTCOMES ────────────────────────────────────────────────────────────────────────
//
//   PQ / HLG source           → exactly OS: source colorspace, identity copy (§6.2: OS ≈ Reference
//                               on HDR, because their profiles declare the transfer exactly).
//   calibrated display, 709   → no colorspace, identity copy: the code values reach the display
//                               untouched and the display's own BT.1886 does the rest. Byte-for-byte
//                               what Bypass sends, on purpose.
//   calibrated display, P3 or → no colorspace; the shader converts the primaries to 709 in
//   2020 primaries              2.4-linear light and re-encodes with 1/2.4 (mode 1).
//   display described by its  → BT.1886 drive from Lb/Lw, encoded for the DECLARED source profile's
//   profile (the default)       own curve, and today's source colorspace declared (mode 0). §6.6's
//                               design: the declaration stays; only the transform before it changes.
//
//  If the declared source profile's curve is not a single power law (never seen for an SDR source:
//  every SDR arm of `makeColorSpace` lands on γ1.960938, measured in S0), Reference refuses rather
//  than guess, shows the picture as OS does, and says so in the readout and the log.
//

import CoreGraphics
import simd
import ColorimetryModel

/// The shader's uniform block — field order and size must match `ReferenceParams` in
/// PassthroughShader.metal (80 bytes).
struct ReferenceShaderParams: Equatable {
    var a: Float
    var b: Float
    var blackRatio: Float
    var invGamma: Float
    var mode: UInt32
    var pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0
    var row0: SIMD4<Float> = .zero
    var row1: SIMD4<Float> = .zero
    var row2: SIMD4<Float> = .zero
}

struct ReferencePlan: Equatable {
    /// What the layer is told. nil = no colorspace, no conversion — the same value Bypass installs.
    let layerColorSpace: CGColorSpace?
    /// nil = the identity copy (`displayCopyFragment`), the pipeline OS and Bypass use.
    let shader: ReferenceShaderParams?
    /// The chain readout's Transform line.
    let summary: String
    /// One `[REFERENCE]` log line.
    let logLine: String

    static func == (l: ReferencePlan, r: ReferencePlan) -> Bool {
        l.shader == r.shader && l.summary == r.summary
            && (l.layerColorSpace.map { cs in r.layerColorSpace.map { CFEqual(cs, $0) } ?? false }
                ?? (r.layerColorSpace == nil))
    }

    static func make(transferCode: Int?, primariesCode: Int?,
                     sourceColorSpace cs: CGColorSpace,
                     calibration raw: DisplayCalibration, displayName: String?) -> ReferencePlan {
        let cal = raw.sanitized
        let on = displayName.map { " on \"\($0)\"" } ?? ""

        // PQ / HLG — Reference is OS.
        if transferCode == 16 || transferCode == 18 {
            let curve = transferCode == 16 ? "PQ" : "HLG"
            return ReferencePlan(
                layerColorSpace: cs, shader: nil,
                summary: "Reference — \(curve) passed to macOS unchanged (on HDR, Reference = As macOS shows it)",
                logLine: "[REFERENCE] \(curve) source\(on): identical to OS — source colorspace declared, identity copy")
        }

        // A display calibrated in its own hardware.
        if cal.calibrated {
            if let m = ReferenceGamut.toRec709(fromPrimariesCode: primariesCode) {
                let gamut = primariesCode == 9 ? "Rec.2020" : "P3-D65"
                var p = ReferenceShaderParams(a: 1, b: 0, blackRatio: 0, invGamma: 1 / 2.4, mode: 1)
                p.row0 = SIMD4(Float(m[0][0]), Float(m[0][1]), Float(m[0][2]), 0)
                p.row1 = SIMD4(Float(m[1][0]), Float(m[1][1]), Float(m[1][2]), 0)
                p.row2 = SIMD4(Float(m[2][0]), Float(m[2][1]), Float(m[2][2]), 0)
                return ReferencePlan(
                    layerColorSpace: nil, shader: p,
                    summary: "Reference — display calibrated to Rec.709 / BT.1886: \(gamut) converted to "
                           + "Rec.709 in 2.4-linear, no colorspace declared (Lb/Lw applied by the display)",
                    logLine: "[REFERENCE] calibrated display\(on): \(gamut) → Rec.709 in 2.4-linear, layer colorspace nil")
            }
            return ReferencePlan(
                layerColorSpace: nil, shader: nil,
                summary: "Reference — display calibrated to Rec.709 / BT.1886: code values sent untouched, "
                       + "no colorspace declared (Lb/Lw applied by the display)",
                logLine: "[REFERENCE] calibrated display\(on): code values untouched, layer colorspace nil, identity copy")
        }

        // A display described by its profile: BT.1886, encoded for the declared curve.
        guard let gamma = declaredGamma(cs) else {
            let why = ICCTransferCurve.parseRTRC(colorSpace: cs).plainDescription
            return ReferencePlan(
                layerColorSpace: cs, shader: nil,
                summary: "Reference unavailable — the source profile's curve is not a single power law "
                       + "(\(why)); shown as macOS shows it",
                logLine: "[REFERENCE] ⚠️ refused\(on): source profile curve is \(why) — showing as OS")
        }
        let c = BT1886(cal)
        let p = ReferenceShaderParams(a: Float(c.a), b: Float(c.b), blackRatio: Float(c.blackRatio),
                                      invGamma: Float(1 / gamma), mode: 0)
        let lbLw = String(format: "Lw %g · Lb %g", cal.whiteNits, cal.blackNits)
        let shape = c.isPurePower ? " (= γ2.4)" : ""
        return ReferencePlan(
            layerColorSpace: cs, shader: p,
            summary: "Reference — BT.1886, \(lbLw)\(shape), encoded for the declared "
                   + String(format: "γ%.3f", gamma) + ", source colorspace declared to the layer",
            logLine: "[REFERENCE] profile-described display\(on): BT.1886 \(lbLw)\(shape), a=\(c.a) b=\(c.b), "
                   + String(format: "encoded for declared γ%.6f (exponent 2.4/γ = %.6f at Lb 0)", gamma, 2.4 / gamma))
    }

    /// γ of a profile whose rTRC is one power law — `curv` count 1, or `para` function type 0.
    static func declaredGamma(_ cs: CGColorSpace) -> Double? {
        switch ICCTransferCurve.parseRTRC(colorSpace: cs).shape {
        case .purePower(let g): return g
        case .parametric(let ft, let p) where ft == 0 && !p.isEmpty: return p[0]
        default: return nil
        }
    }
}
