//
//  ContainerColorPolicy.swift
//  ColorimetryModel
//
//  Which colour the picture follows when a file's CONTAINER and its DECODER disagree (decided, Robbie, 2026-10-12;
//  docs/COLOR_MANAGEMENT_FINDINGS.md §6.11, *MXF / DNx: the container drives the picture*).
//
//  The container drives the picture, on every path. AVFoundation does it by construction (CoreMedia takes the
//  `colr` over the bitstream, S0). The libav path (MXF, DNx) used to tag each buffer from the decoder's frame, and
//  ffmpeg's DNxHR decoder stamps every frame `bt709`, so a DNx MXF whose descriptor said 601 or 2020 was decoded
//  with the 709 matrix while the scopes, SDI and readout used the descriptor's. Now each axis the container STATES
//  is taken from the container; an axis it does not state falls back to the frame's, as before. A disagreement is
//  logged and shown in the readout; the override covers a container that is wrong.
//

/// One CICP axis.
public enum CICPAxis: String, Sendable {
    case primaries, transfer, matrix
}

/// One axis on which the container and the decoder state different values.
public struct ColorAxisDisagreement: Equatable, Sendable {
    public let axis: CICPAxis
    public let container: Int
    public let decoder: Int
}

public enum ContainerColorPolicy {

    /// Whether `code` is a STATEMENT on `axis` (ITU-T H.273): not unspecified (2), not reserved. The same rules the
    /// SPS colour readers apply. Matrix 0 (identity / GBR) is a statement; primaries and transfer 0 are reserved.
    public static func isStated(_ code: Int, _ axis: CICPAxis) -> Bool {
        switch axis {
        case .primaries: return code == 1 || (4...12).contains(code) || code == 22
        case .transfer:  return code == 1 || (4...18).contains(code)
        case .matrix:    return code == 0 || code == 1 || (4...14).contains(code)
        }
    }

    /// The code the picture uses on one axis: the container's when it states one, else the decoder's.
    public static func resolve(container: Int, decoder: Int, _ axis: CICPAxis) -> Int {
        isStated(container, axis) ? container : decoder
    }

    /// The axes on which both sides make a statement and the statements differ. Two equivalences, because they are
    /// one value spelled two ways: transfer 1 / 6 / 14 / 15 are all the BT.709 curve, and matrix 5 / 6 are one matrix.
    public static func disagreements(container: (primaries: Int, transfer: Int, matrix: Int),
                                     decoder: (primaries: Int, transfer: Int, matrix: Int)) -> [ColorAxisDisagreement] {
        let curve709: Set<Int> = [1, 6, 14, 15]
        func same(_ a: Int, _ b: Int, _ axis: CICPAxis) -> Bool {
            if a == b { return true }
            switch axis {
            case .transfer:  return curve709.contains(a) && curve709.contains(b)
            case .matrix:    return Set([a, b]).isSubset(of: [5, 6])
            case .primaries: return false
            }
        }
        var out: [ColorAxisDisagreement] = []
        for (axis, c, d) in [(CICPAxis.primaries, container.primaries, decoder.primaries),
                             (.transfer, container.transfer, decoder.transfer),
                             (.matrix, container.matrix, decoder.matrix)]
        where isStated(c, axis) && isStated(d, axis) && !same(c, d, axis) {
            out.append(ColorAxisDisagreement(axis: axis, container: c, decoder: d))
        }
        return out
    }

    /// The chain readout's Tags line for a container / decoder disagreement, in the words the H.264 / HEVC
    /// container / bitstream line uses. nil when they agree.
    public static func readout(_ d: [ColorAxisDisagreement], decoder name: String) -> String? {
        guard !d.isEmpty else { return nil }
        let axes = d.map { "\($0.axis.rawValue) \($0.container) vs \($0.decoder)" }.joined(separator: ", ")
        return "⚠️ container disagrees with the \(name) decoder: \(axes)"
             + " — the container's tags are used; the override can assert the other"
    }
}
