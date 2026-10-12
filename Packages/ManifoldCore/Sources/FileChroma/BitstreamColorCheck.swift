//
//  BitstreamColorCheck.swift
//  FileChroma
//
//  A file's container colour tags against its own bitstream's (colour S3, docs/COLOR_MANAGEMENT_FINDINGS.md
//  §6.11, *Decided for S3*). Where the app's own SPS reader can see the bitstream — the SPS in an `avcC`
//  or `hvcC` — a disagreement with the container is logged and shown in the chain readout, and NOTHING
//  ELSE CHANGES: the container's tags still drive the picture, and the user decides through the override.
//
//  WHY THE CONTAINER IS NOT OVERRULED: S0 found CoreMedia takes the container's `colr` over the VUI for
//  both the format description and every decoded buffer, so on this path the shader, the scopes and the
//  layer already agree with each other. A file tagged one way and encoded another is decoded with the
//  container's matrix, as any CoreMedia player would. Saying so is this file's job; choosing is the user's.
//

import CoreVideo   // FourCharCode
import SPSColor

/// One axis on which the container and the bitstream state different values.
public struct ColorTagDisagreement: Equatable, Sendable {
    public enum Axis: String, Sendable { case primaries, transfer, matrix }
    public let axis: Axis
    public let container: Int
    public let bitstream: Int
}

/// The comparison, and the words the log and the readout use.
public struct BitstreamColorReport: Equatable, Sendable {
    /// What the bitstream was read from: "avcC SPS", "hvcC SPS".
    public let basis: String
    public let container: (primaries: Int?, transfer: Int?, matrix: Int?)
    public let bitstream: SPSColor
    public let disagreements: [ColorTagDisagreement]

    public static func == (a: Self, b: Self) -> Bool {
        a.basis == b.basis && a.container == b.container && a.bitstream == b.bitstream
            && a.disagreements == b.disagreements
    }

    /// The chain readout's line, or nil when they agree (or one side states nothing to compare).
    public var readout: String? {
        guard !disagreements.isEmpty else { return nil }
        let axes = disagreements.map { "\($0.axis.rawValue) \($0.container) vs \($0.bitstream)" }
                                .joined(separator: ", ")
        return "⚠️ container \(Self.triple(container)) disagrees with the bitstream (\(basis)) "
             + "\(Self.triple((bitstream.primaries, bitstream.transfer, bitstream.matrix))): \(axes)"
             + " — the container's tags are used; the override can assert the other"
    }

    /// The `[COLOR-BITSTREAM]` log line: always one per file the reader could see into.
    public var logLine: String {
        let b = (bitstream.primaries, bitstream.transfer, bitstream.matrix)
        let verdict: String
        if !disagreements.isEmpty {
            verdict = "⚠️ DISAGREE on " + disagreements.map(\.axis.rawValue).joined(separator: ", ")
                    + " — container used, nothing changed"
        } else if bitstream.reach != .colourDescription {
            verdict = "bitstream states no colour (\(bitstream.reach)) — nothing to compare"
        } else {
            verdict = "agree"
        }
        return "[COLOR-BITSTREAM] container \(Self.triple(container)) · \(basis) \(Self.triple(b)) — \(verdict)"
    }

    static func triple(_ t: (Int?, Int?, Int?)) -> String {
        func s(_ v: Int?) -> String { v.map(String.init) ?? "—" }
        return "\(s(t.0))-\(s(t.1))-\(s(t.2))"
    }
}

public enum BitstreamColorCheck {

    /// Compare a file's container codes with the SPS colour in its `avcC` / `hvcC`. nil for a codec
    /// whose bitstream this app does not read (ProRes, DNx, anything else) or an SPS that cannot be found.
    public static func check(codecType: FourCharCode, atoms: [String: [UInt8]],
                             container: (primaries: Int?, transfer: Int?, matrix: Int?)) -> BitstreamColorReport? {
        let read: (SPSColor, String)?
        switch FileChromaResolver.fourCCName(codecType) {
        case "avc1", "avc3":
            read = atoms["avcC"].flatMap { FileChromaResolver.h264SPS(avcC: $0) }
                .map { (H264SPSColor.parse(nal: $0), "avcC SPS") }
        case "hvc1", "hev1":
            read = atoms["hvcC"].flatMap { hevcSPS(hvcC: $0) }
                .map { (HEVCSPSColor.parse(nal: $0), "hvcC SPS") }
        default:
            read = nil
        }
        guard let (sps, basis) = read else { return nil }
        return BitstreamColorReport(basis: basis, container: container, bitstream: sps,
                                    disagreements: compare(container: container, bitstream: sps))
    }

    /// Axis by axis, and only where BOTH sides declare a value. A side that says nothing is not a
    /// disagreement: the container then carries the app's default, and the readout's tier says so.
    ///
    /// Two equivalences, because they are one value spelled two ways and not a disagreement:
    /// * **transfer 1, 6, 14 and 15 are all the BT.709 curve.** CoreMedia respells 14 and 15 as 1 in a
    ///   file's format description (S0, measured), so a 2020 SDR file whose `colr` says 14 reads 1 here
    ///   while its SPS says 14.
    /// * **matrix 5 and 6 are one matrix** (`YCbCrMatrix`).
    public static func compare(container: (primaries: Int?, transfer: Int?, matrix: Int?),
                               bitstream: SPSColor) -> [ColorTagDisagreement] {
        var out: [ColorTagDisagreement] = []
        func check(_ axis: ColorTagDisagreement.Axis, _ c: Int?, _ b: Int?, _ same: (Int, Int) -> Bool) {
            guard let c, let b, !same(c, b) else { return }
            out.append(ColorTagDisagreement(axis: axis, container: c, bitstream: b))
        }
        let curve709: Set<Int> = [1, 6, 14, 15]
        check(.primaries, container.primaries, bitstream.primaries) { $0 == $1 }
        check(.transfer, container.transfer, bitstream.transfer) {
            $0 == $1 || (curve709.contains($0) && curve709.contains($1))
        }
        check(.matrix, container.matrix, bitstream.matrix) {
            $0 == $1 || (Set([$0, $1]).isSubset(of: [5, 6]))
        }
        return out
    }

    /// The first SPS (NAL type 33) in an `hvcC`, as a slice — the walk `FileChromaResolver.hevcFormat`
    /// makes, returning the NAL instead of its format.
    static func hevcSPS(hvcC: [UInt8]) -> ArraySlice<UInt8>? {
        guard hvcC.count >= 23 else { return nil }
        var at = 23
        for _ in 0..<Int(hvcC[22]) {
            guard at + 3 <= hvcC.count else { return nil }
            let type = hvcC[at] & 0x3F
            let nalus = Int(hvcC[at + 1]) << 8 | Int(hvcC[at + 2])
            at += 3
            for _ in 0..<nalus {
                guard at + 2 <= hvcC.count else { return nil }
                let length = Int(hvcC[at]) << 8 | Int(hvcC[at + 1])
                at += 2
                guard at + length <= hvcC.count else { return nil }
                if type == 33 { return hvcC[at..<(at + length)] }
                at += length
            }
        }
        return nil
    }
}
