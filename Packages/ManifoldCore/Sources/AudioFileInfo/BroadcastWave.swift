//
//  BroadcastWave.swift
//  AudioFileInfo
//
//  A RIFF chunk scanner for the facts AVFoundation does not report about a Broadcast Wave file: `bext` TimeReference and
//  origination stamp, and iXML TIMECODE_RATE / TIMECODE_FLAG (docs/STILLS_AND_AUDIO_ONLY_PLAN.md §5.2). `afinfo` does not
//  show `bext` either (measured), so nothing else in the system reads these.
//
//  Reads through a closure, so the walk takes byte arrays in tests and never loads a whole file: a WAV can be many GB and
//  only its small chunks are read. Foundation only, a leaf target so `swift test` reaches it.
//
//  Inspector only. It never drives the transport readout.
//

import Foundation

/// What a RIFF-family WAV states about its own timing. Every field is nil when the file does not state it.
public struct BroadcastWaveInfo: Equatable, Sendable {
    /// `bext` TimeReference: samples since midnight of the first sample.
    public var timeReference: UInt64?
    /// `bext` OriginationDate and OriginationTime, as written, with padding removed.
    public var originationDate: String?
    public var originationTime: String?
    /// The rate in `fmt `, in Hz: the rate TimeReference counts in.
    public var sampleRate: UInt32?
    /// iXML TIMECODE_RATE as a rational, for example 24000/1001.
    public var timecodeRate: TimecodeRate?
    /// iXML TIMECODE_FLAG was "DF".
    public var dropFrame = false

    public init() {}

    /// Nothing worth an Inspector row: a plain WAV.
    public var isEmpty: Bool { timeReference == nil && originationDate == nil && originationTime == nil }
}

public struct TimecodeRate: Equatable, Sendable {
    public let numerator: UInt64
    public let denominator: UInt64

    public init?(numerator: UInt64, denominator: UInt64) {
        guard numerator > 0, denominator > 0 else { return nil }
        self.numerator = numerator
        self.denominator = denominator
    }

    /// "24000/1001", "25/1" or "25". iXML's form is the rational; a bare number is tolerated. Decimals are refused:
    /// 23.976 is not a rate this can state exactly, and a guess must not reach a Timecode row.
    public init?(iXML text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              let n = UInt64(parts[0].trimmingCharacters(in: .whitespaces)),
              let d = parts.count == 2 ? UInt64(parts[1].trimmingCharacters(in: .whitespaces)) : 1 else { return nil }
        self.init(numerator: n, denominator: d)
    }

    public var framesPerSecond: Double { Double(numerator) / Double(denominator) }
    /// The whole-number count a timecode's frame field runs to: 24 for 23.976, 30 for 29.97.
    public var nominal: UInt64 { (numerator + denominator / 2) / denominator }
}

public enum BroadcastWaveReader {

    /// How much of a chunk is read. `bext` is 602 bytes plus coding history, and only its first 346 matter. iXML is
    /// usually under 10 KB, and a file claiming more than this is not worth holding in memory for one tag.
    private static let bextPrefix: UInt64 = 346
    private static let ixmlLimit: UInt64 = 1 << 20
    /// A chunk walk that has not ended by here is walking garbage.
    private static let chunkLimit = 4096

    /// Read a file on disk. Nil when it is not a RIFF-family WAVE or cannot be opened.
    public static func read(url: URL) -> BroadcastWaveInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        return parse(size: size) { offset, count in
            guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
            return try? handle.read(upToCount: count)
        }
    }

    /// Walk the chunks. `read(offset, count)` returns up to `count` bytes, fewer at the end of the file.
    /// Truncated and absent chunks leave their fields nil and never fail the rest of the walk.
    public static func parse(size: UInt64, read: (UInt64, Int) -> Data?) -> BroadcastWaveInfo? {
        guard let head = read(0, 12), head.count == 12 else { return nil }
        let form = String(decoding: head.prefix(4), as: UTF8.self)
        guard ["RIFF", "RF64", "BW64"].contains(form),
              String(decoding: head.suffix(4), as: UTF8.self) == "WAVE" else { return nil }

        var info = BroadcastWaveInfo()
        // RF64: a `data` chunk over 4 GB states 0xFFFFFFFF, and `ds64` holds the real size. Its optional table covers
        // other chunks; only `data` is ever that large in practice, so the table is not read.
        var ds64DataSize: UInt64?
        var offset: UInt64 = 12
        var walked = 0
        while offset &+ 8 <= size, walked < chunkLimit {
            walked += 1
            guard let header = read(offset, 8), header.count == 8 else { break }
            let id = String(decoding: header.prefix(4), as: UTF8.self)
            var chunkSize = UInt64(le32(header, 4))
            let body = offset + 8
            let available = size - body

            switch id {
            case "ds64":
                if let d = read(body, 16), d.count == 16 { ds64DataSize = le64(d, 8) }
            case "fmt ":
                if let d = read(body, 8), d.count == 8 { info.sampleRate = le32(d, 4) }
            case "bext":
                if let d = read(body, Int(min(chunkSize, available, bextPrefix))) { readBext(d, into: &info) }
            case "iXML":
                if let d = read(body, Int(min(chunkSize, available, ixmlLimit))) { readIXML(d, into: &info) }
            case "data":
                if form != "RIFF", chunkSize == 0xFFFF_FFFF, let real = ds64DataSize { chunkSize = real }
            default:
                break
            }

            // Chunks pad to an even size. A size past the end of the file ends the walk on the next test.
            let (next, overflow) = body.addingReportingOverflow(chunkSize &+ (chunkSize & 1))
            guard !overflow else { break }
            offset = next
        }
        return info
    }

    private static func readBext(_ d: Data, into info: inout BroadcastWaveInfo) {
        // Description 256, Originator 32, OriginatorReference 32, then the stamp, then TimeReference low and high.
        if d.count >= 330 { info.originationDate = ascii(d, 320, 10) }
        if d.count >= 338 { info.originationTime = ascii(d, 330, 8) }
        if d.count >= 346 {
            info.timeReference = UInt64(le32(d, 338)) | UInt64(le32(d, 342)) << 32
        }
    }

    private static func readIXML(_ d: Data, into info: inout BroadcastWaveInfo) {
        let xml = String(decoding: d, as: UTF8.self)
        if let rate = element("TIMECODE_RATE", in: xml) { info.timecodeRate = TimecodeRate(iXML: rate) }
        if let flag = element("TIMECODE_FLAG", in: xml) {
            info.dropFrame = flag.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "DF"
        }
    }

    /// A leaf element's text. iXML's timing elements are flat and unattributed, so this is a search, not a parser.
    private static func element(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>"),
              let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex) else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    private static func ascii(_ d: Data, _ at: Int, _ length: Int) -> String? {
        let start = d.startIndex + at
        let bytes = d[start..<(start + length)].prefix { $0 != 0 }
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func le32(_ d: Data, _ at: Int) -> UInt32 {
        let i = d.startIndex + at
        return UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }

    private static func le64(_ d: Data, _ at: Int) -> UInt64 {
        UInt64(le32(d, at)) | UInt64(le32(d, at + 4)) << 32
    }
}

// MARK: - Inspector rows

public extension BroadcastWaveInfo {

    /// The Inspector's rows. **Timecode** only when the file states a rate; otherwise **Time Reference** as
    /// `HH:MM:SS.mmm`, because `bext` carries no frame rate and one must not be assumed.
    ///
    /// `fallbackSampleRate` is the track's, for a file whose `fmt ` was not read.
    func inspectorRows(fallbackSampleRate: Double) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        let rate = sampleRate.map(Double.init) ?? fallbackSampleRate
        if let timeReference, rate > 0 {
            if let timecodeRate, let tc = Self.timecode(samples: timeReference, sampleRate: rate, rate: timecodeRate,
                                                        dropFrame: dropFrame) {
                rows.append(("Timecode", tc + " @ " + Self.rateText(timecodeRate) + (dropFrame ? " DF" : "")))
            } else if let time = Self.clockTime(samples: timeReference, sampleRate: rate) {
                rows.append(("Time Reference", time))
            }
        }
        let stamp = [originationDate, originationTime].compactMap { $0 }.joined(separator: " ")
        if !stamp.isEmpty { rows.append(("Origination Date", stamp)) }
        return rows
    }

    /// `HH:MM:SS.mmm`. Nil for a count too large to be a time of day by many orders of magnitude.
    static func clockTime(samples: UInt64, sampleRate: Double) -> String? {
        let milliseconds = (Double(samples) / sampleRate * 1000).rounded(.down)
        guard milliseconds < 1e15 else { return nil }
        let ms = UInt64(milliseconds)
        return String(format: "%02llu:%02llu:%02llu.%03llu", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// `HH:MM:SS:FF`, or `HH:MM:SS;FF` for drop frame. The sample count becomes a frame count at the real rate, to the
    /// nearest frame (a 29.97 frame is not a whole number of samples, so a recorder's value is rounded either way), and
    /// the count is labelled at the nominal rate, which is what a timecode is.
    static func timecode(samples: UInt64, sampleRate: Double, rate: TimecodeRate, dropFrame: Bool) -> String? {
        let frames = (Double(samples) / sampleRate * rate.framesPerSecond).rounded()
        guard frames < 1e15 else { return nil }
        var count = UInt64(frames)
        let nominal = rate.nominal
        guard nominal > 0 else { return nil }
        let drops = dropFrame && nominal % 30 == 0
        if drops {
            // Two frame numbers (four at 60) are skipped each minute, except every tenth.
            let drop = nominal / 15
            let perMinute = 60 * nominal - drop
            let perTen = 10 * perMinute + drop
            let tens = count / perTen
            let rest = count % perTen
            count += 9 * drop * tens + (rest > drop ? drop * ((rest - drop) / perMinute) : 0)
        }
        return String(format: "%02llu:%02llu:%02llu%@%02llu",
                      count / (3600 * nominal), count / (60 * nominal) % 60, count / nominal % 60,
                      drops ? ";" : ":", count % nominal)
    }

    /// "25", "23.976", "29.97".
    static func rateText(_ rate: TimecodeRate) -> String {
        if rate.numerator % rate.denominator == 0 { return "\(rate.numerator / rate.denominator)" }
        var text = String(format: "%.3f", rate.framesPerSecond)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }
}
