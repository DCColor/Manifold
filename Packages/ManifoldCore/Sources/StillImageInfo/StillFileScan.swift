//
//  StillFileScan.swift
//  StillImageInfo
//
//  What a still's own bytes state, which ImageIO does not report: which gain-map standard it uses, and its stated light
//  levels (docs/STILLS_AND_AUDIO_ONLY_PLAN.md, B0 result). Read-only, bounds-checked, and every parser stops quietly at
//  anything malformed: an absent answer is a true report of "the scan found nothing".
//

import Foundation

public struct StillFileFacts: Sendable, Equatable {
    public var gainMaps: GainMapFormats = []
    public var light = StatedLight()
    /// The primary picture's stated CICP: `colr nclx` in HEIF and AVIF, `cICP` in PNG.
    public var cicp: StatedCICP?
    public init() {}
}

public enum StillFileScan {
    /// The file's type is taken from its first bytes, not its name: a misnamed file is scanned for what it is.
    public static func scan(url: URL) -> StillFileFacts {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return StillFileFacts() }
        return data.withUnsafeBytes { scan(bytes: $0) }
    }

    public static func scan(bytes: UnsafeRawBufferPointer) -> StillFileFacts {
        let reader = Reader(bytes)
        if reader.fourCC(at: 4) == "ftyp" { return isoBMFF(reader) }
        if bytes.count >= 8, bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return png(reader) }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xD8 { return jpeg(bytes) }
        return StillFileFacts()
    }

    // MARK: JPEG

    private static let isoURN = "urn:iso:std:iso:ts:21496:-1"
    private static let appleAux = ":aux:hdrgainmap"
    private static let adobeNamespace = "hdr-gain-map"

    /// A search and not a segment walk, because the gain map is a second JPEG after the first one's image data, and it is
    /// that image's segments that hold its metadata. These strings are long enough not to turn up in compressed data.
    private static func jpeg(_ bytes: UnsafeRawBufferPointer) -> StillFileFacts {
        var facts = StillFileFacts()
        if contains(bytes, isoURN) { facts.gainMaps.insert(.iso21496) }
        if contains(bytes, adobeNamespace) { facts.gainMaps.insert(.adobeXMP) }
        if contains(bytes, appleAux) { facts.gainMaps.insert(.apple) }
        return facts
    }

    private static func contains(_ bytes: UnsafeRawBufferPointer, _ needle: String) -> Bool {
        guard let base = bytes.baseAddress else { return false }
        return needle.withCString { memmem(base, bytes.count, $0, strlen($0)) != nil }
    }

    // MARK: PNG

    /// `cLLI` and `mDCV`, which precede the image data. Both state luminance in units of 0.0001 nit.
    private static func png(_ r: Reader) -> StillFileFacts {
        var facts = StillFileFacts()
        var offset = 8
        while let length = r.u32(at: offset), let type = r.fourCC(at: offset + 4), type != "IDAT", type != "IEND" {
            let body = offset + 8
            if type == "cLLI", let cll = r.u32(at: body) { facts.light.maxCLL = nits(cll) }
            if type == "mDCV", let peak = r.u32(at: body + 16) { facts.light.masteringPeak = nits(peak) }
            if type == "cICP", let p = r.u8(at: body), let t = r.u8(at: body + 1), let m = r.u8(at: body + 2) {
                facts.cicp = StatedCICP(primaries: Int(p), transfer: Int(t), matrix: Int(m))
            }
            offset = body + Int(length) + 4
        }
        return facts
    }

    private static func nits(_ tenThousandths: UInt32) -> Int? {
        let value = Int((Double(tenThousandths) / 10000).rounded())
        return value > 0 ? value : nil
    }

    // MARK: HEIF and AVIF

    private struct Box { let type: String; let body: Range<Int> }

    /// One level of boxes in `range`. Stops at the first box that does not fit.
    private static func boxes(_ r: Reader, in range: Range<Int>) -> [Box] {
        var out: [Box] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound, let size32 = r.u32(at: offset), let type = r.fourCC(at: offset + 4) {
            var header = 8
            var size = Int(size32)
            if size32 == 1 {
                guard let size64 = r.u64(at: offset + 8), size64 <= UInt64(Int.max) else { break }
                header = 16
                size = Int(size64)
            } else if size32 == 0 {
                size = range.upperBound - offset
            }
            guard size >= header, offset + size <= range.upperBound else { break }
            out.append(Box(type: type, body: (offset + header)..<(offset + size)))
            offset += size
        }
        return out
    }

    /// The primary item's light levels, through `pitm` and `ipma`: a property sitting in `ipco` may belong to the gain
    /// map or a thumbnail, so its presence alone says nothing about the picture.
    private static func isoBMFF(_ r: Reader) -> StillFileFacts {
        var facts = StillFileFacts()
        guard let meta = boxes(r, in: 0..<r.count).first(where: { $0.type == "meta" }), meta.body.count >= 4 else { return facts }
        let children = boxes(r, in: (meta.body.lowerBound + 4)..<meta.body.upperBound)

        if let iinf = children.first(where: { $0.type == "iinf" }), itemTypes(r, iinf).contains("tmap") {
            facts.gainMaps.insert(.iso21496)
        }
        guard let iprp = children.first(where: { $0.type == "iprp" }) else { return facts }
        let properties = boxes(r, in: iprp.body)
        guard let ipco = properties.first(where: { $0.type == "ipco" }) else { return facts }
        let table = boxes(r, in: ipco.body)

        for box in table where box.type == "auxC" {
            guard let urn = r.cString(at: box.body.lowerBound + 4, upTo: box.body.upperBound) else { continue }
            if urn.contains(appleAux) { facts.gainMaps.insert(.apple) }
            if urn.contains("urn:iso:std:iso:ts:21496") { facts.gainMaps.insert(.iso21496) }
        }

        guard let pitm = children.first(where: { $0.type == "pitm" }), let primary = primaryItem(r, pitm),
              let ipma = properties.first(where: { $0.type == "ipma" }) else { return facts }
        for index in associations(r, ipma, item: primary) where table.indices.contains(index - 1) {
            let box = table[index - 1]
            if box.type == "clli", let cll = r.u16(at: box.body.lowerBound), cll > 0 { facts.light.maxCLL = Int(cll) }
            if box.type == "mdcv", let peak = r.u32(at: box.body.lowerBound + 16) { facts.light.masteringPeak = nits(peak) }
            if box.type == "colr", r.fourCC(at: box.body.lowerBound) == "nclx", let p = r.u16(at: box.body.lowerBound + 4),
               let t = r.u16(at: box.body.lowerBound + 6), let m = r.u16(at: box.body.lowerBound + 8) {
                facts.cicp = StatedCICP(primaries: Int(p), transfer: Int(t), matrix: Int(m))
            }
        }
        return facts
    }

    private static func primaryItem(_ r: Reader, _ pitm: Box) -> UInt32? {
        guard let version = r.u8(at: pitm.body.lowerBound) else { return nil }
        let at = pitm.body.lowerBound + 4
        return version == 0 ? r.u16(at: at).map(UInt32.init) : r.u32(at: at)
    }

    private static func itemTypes(_ r: Reader, _ iinf: Box) -> [String] {
        guard let version = r.u8(at: iinf.body.lowerBound) else { return [] }
        let first = iinf.body.lowerBound + (version == 0 ? 6 : 8)
        guard first <= iinf.body.upperBound else { return [] }
        return boxes(r, in: first..<iinf.body.upperBound).filter { $0.type == "infe" }.compactMap { infe in
            guard let v = r.u8(at: infe.body.lowerBound), v >= 2 else { return nil }
            // full box header, item id (2 or 4 bytes), protection index (2).
            return r.fourCC(at: infe.body.lowerBound + 4 + (v == 2 ? 2 : 4) + 2)
        }
    }

    /// The 1-based `ipco` indices associated with `item`.
    private static func associations(_ r: Reader, _ ipma: Box, item: UInt32) -> [Int] {
        var at = ipma.body.lowerBound
        guard let version = r.u8(at: at), let flags = r.u8(at: at + 3), let count = r.u32(at: at + 4) else { return [] }
        at += 8
        let wide = flags & 1 == 1
        for _ in 0..<count {
            let id: UInt32?
            if version < 1 { id = r.u16(at: at).map(UInt32.init); at += 2 } else { id = r.u32(at: at); at += 4 }
            guard let id, let n = r.u8(at: at) else { return [] }
            at += 1
            var found: [Int] = []
            for _ in 0..<n {
                if wide {
                    guard let v = r.u16(at: at) else { return [] }
                    found.append(Int(v & 0x7FFF))
                    at += 2
                } else {
                    guard let v = r.u8(at: at) else { return [] }
                    found.append(Int(v & 0x7F))
                    at += 1
                }
            }
            if id == item { return found }
        }
        return []
    }
}

/// Big-endian reads that answer nil past the end.
private struct Reader {
    let bytes: UnsafeRawBufferPointer
    init(_ bytes: UnsafeRawBufferPointer) { self.bytes = bytes }

    var count: Int { bytes.count }

    func u8(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < bytes.count else { return nil }
        return bytes[offset]
    }

    private func value(at offset: Int, length: Int) -> UInt64? {
        guard offset >= 0, length <= bytes.count, offset <= bytes.count - length else { return nil }
        return (0..<length).reduce(UInt64(0)) { ($0 << 8) | UInt64(bytes[offset + $1]) }
    }

    func u16(at offset: Int) -> UInt16? { value(at: offset, length: 2).map { UInt16($0) } }
    func u32(at offset: Int) -> UInt32? { value(at: offset, length: 4).map { UInt32($0) } }
    func u64(at offset: Int) -> UInt64? { value(at: offset, length: 8) }

    func fourCC(at offset: Int) -> String? {
        guard offset >= 0, offset <= bytes.count - 4 else { return nil }
        return String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
    }

    func cString(at offset: Int, upTo end: Int) -> String? {
        guard offset >= 0, offset < end, end <= bytes.count else { return nil }
        let slice = bytes[offset..<end]
        return String(decoding: slice.prefix { $0 != 0 }, as: UTF8.self)
    }
}
