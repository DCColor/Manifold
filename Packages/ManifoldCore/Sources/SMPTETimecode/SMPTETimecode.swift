//
//  SMPTETimecode.swift — SMPTE frame-count ↔ label arithmetic, drop-frame included.
//
//  Moved here from `TimecodeReader` (ManifoldCore) on 2026-11-15 for markers (docs/MARKERS_PLAN.md §2), so that
//  `swift test` can reach it: a test target cannot link ManifoldCore (it resolves libav symbols the app binary links).
//  `TimecodeReader.format`, `.parse` and `.droppedFramesPerMinute` forward here unchanged, so the transport readout,
//  timecode entry, Export Frame names and markers share one copy of this arithmetic.
//
//  ⚠️ THE 24-HOUR WRAP (D17, 2026-11-15). `format` used to count hours without limit, so a file starting at
//  23:59:00:00 read 24:00:00:00 one minute in. SMPTE labels run 00:00:00:00 … 23:59:59:FF and then start again, and an
//  EDL cannot carry 24:00:00:00. A frame count is now taken modulo one day of labels before it is split, negative counts
//  included (a count one frame before 00:00:00:00 is 23:59:59:FF). Below 24 hours nothing changes.
//

import Foundation

public enum SMPTETimecode {

    /// HOW MANY FRAME LABELS DROP-FRAME SKIPS AT EACH MINUTE — 2 at 29.97, 4 at 59.94.
    ///
    /// The 0.066666 is 2/30, the ratio the SMPTE rule fixes, so multiplying by the rate and rounding covers 59.94
    /// without a table. (TimecodeReader's original, unchanged.)
    public static func droppedFramesPerMinute(fps: Double) -> Int {
        Int((fps * 0.066666).rounded())
    }

    /// Frame labels in one day: 24 hours of `nfr`-frame seconds, less the dropped labels for drop-frame.
    public static func framesPerDay(nfr: Int, fps: Double, dropFrame: Bool) -> Int {
        guard nfr > 0 else { return 0 }
        guard dropFrame else { return 24 * 3600 * nfr }
        let drop = droppedFramesPerMinute(fps: fps)
        let framesPer10Min = 10 * 60 * nfr - 9 * drop
        return 24 * 6 * framesPer10Min
    }

    /// A frame count as "HH:MM:SS:FF", or "HH:MM:SS;FF" for drop-frame (unless `separator` is given). Wraps at 24 hours.
    /// Flip's proven arithmetic (TimecodeReader's, unchanged below the wrap).
    public static func format(frameCount: Int, nfr: Int, fps: Double, dropFrame: Bool,
                              separator: Character? = nil) -> String {
        guard nfr > 0 else { return "—" }
        let day = framesPerDay(nfr: nfr, fps: fps, dropFrame: dropFrame)
        var fc = day > 0 ? ((frameCount % day) + day) % day : frameCount

        if dropFrame {
            let dropFrames = droppedFramesPerMinute(fps: fps)
            let framesPer10Min = 10 * 60 * nfr - 9 * dropFrames
            let framesPerMin = 60 * nfr - dropFrames
            let d = fc / framesPer10Min
            var m = fc % framesPer10Min
            if m < dropFrames { m = dropFrames }
            fc = fc + dropFrames * 9 * d + dropFrames * ((m - dropFrames) / framesPerMin)
        }

        let ff = fc % nfr
        let totalSecs = fc / nfr
        let ss = totalSecs % 60
        let totalMins = totalSecs / 60
        let mm = totalMins % 60
        let hh = totalMins / 60

        let sep = separator.map(String.init) ?? (dropFrame ? ";" : ":")
        return String(format: "%02d:%02d:%02d%@%02d", hh, mm, ss, sep, ff)
    }

    /// The frame count of "HH:MM:SS:FF" (";" or ":" before the frames), drop-frame inferred from ";". TimecodeReader's
    /// original `parse`: lenient, it accepts the labels drop-frame does not have and runs the inverse over them.
    public static func lenientFrameCount(timecode: String, fps: Double) -> (frameCount: Int, dropFrame: Bool, nfr: Int)? {
        guard fps > 0 else { return nil }
        let dropFrame = timecode.contains(";")
        let parts = timecode.split(whereSeparator: { $0 == ":" || $0 == ";" })
        guard parts.count == 4,
              let hh = Int(parts[0]), let mm = Int(parts[1]),
              let ss = Int(parts[2]), let ff = Int(parts[3]) else { return nil }
        let nfr = Int(fps.rounded())
        guard nfr > 0 else { return nil }
        var startFrame = (hh * 3600 + mm * 60 + ss) * nfr + ff
        if dropFrame {
            let dropFrames = droppedFramesPerMinute(fps: fps)
            let totalMinutes = 60 * hh + mm
            startFrame -= dropFrames * (totalMinutes - totalMinutes / 10)
        }
        return (startFrame, dropFrame, nfr)
    }

    /// STRICT: the frame count of a label under a STATED drop-frame setting, whatever its punctuation (Resolve writes
    /// drop-frame EDL timecodes with colons, `docs/markers/resolve-reference-2997DF.edl`). Nil for anything that is not
    /// a label: a field out of range (FF ≥ nfr, SS or MM ≥ 60, HH ≥ 24), or a drop-frame label that does not exist
    /// (MM:00;00 and ;01 at a minute that is not a multiple of ten).
    public static func frameCount(label: String, nfr: Int, fps: Double, dropFrame: Bool) -> Int? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." })
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let hh = Int(parts[0]), let mm = Int(parts[1]), let ss = Int(parts[2]), let ff = Int(parts[3]),
              nfr > 0, hh < 24, mm < 60, ss < 60, ff < nfr else { return nil }
        var count = (hh * 3600 + mm * 60 + ss) * nfr + ff
        if dropFrame {
            let drop = droppedFramesPerMinute(fps: fps)
            if ss == 0, mm % 10 != 0, ff < drop { return nil }
            let totalMinutes = 60 * hh + mm
            count -= drop * (totalMinutes - totalMinutes / 10)
        }
        return count
    }

    /// A duration as a timecode-shaped count of frames ("00:00:01:00" is `nfr` frames), never drop-frame: a duration is
    /// not a position on a clock. Resolve's marker dialog shows durations this way (`docs/markers/frameio_formating.png`).
    public static func durationLabel(frames: Int, nfr: Int) -> String {
        guard nfr > 0 else { return "—" }
        let f = max(frames, 0)
        return String(format: "%02d:%02d:%02d:%02d", f / (3600 * nfr), (f / (60 * nfr)) % 60, (f / nfr) % 60, f % nfr)
    }
}

// MARK: - Typed timecode: the transport's timecode entry rules (docs/MARKERS_PLAN.md §3.3, 2026-11-15)

/// What someone typed into a timecode field, read by the transport's timecode-entry rules (App/TimecodeEntry.swift):
/// digits fill from the right ("100" is 00:00:01:00, "1" is one frame), at most eight; a leading "+" (or "=") or "−"/"-"
/// makes the entry relative; fields are normalised, never rejected ("75" at 24 fps is 3 seconds 3 frames). A typed or
/// pasted label with separators ("1:00:01:19", "01:00:01;19") is read group by group, each group two digits.
public struct TypedTimecode: Equatable, Sendable {
    public enum Sign: Equatable, Sendable { case absolute, plus, minus }

    public static let maxDigits = 8

    public var sign: Sign
    /// Most significant first.
    public var digits: [Int]

    public init(sign: Sign = .absolute, digits: [Int]) {
        self.sign = sign
        self.digits = digits
    }

    /// Nil for anything that is not a typed timecode: no digits, a letter, more than eight digits, a group of three.
    public init?(_ text: String) {
        var t = Substring(text.trimmingCharacters(in: .whitespaces))
        var sign = Sign.absolute
        if let c = t.first, "+=".contains(c) { sign = .plus; t = t.dropFirst() }
        else if let c = t.first, "-−_".contains(c) { sign = .minus; t = t.dropFirst() }
        t = Substring(t.trimmingCharacters(in: .whitespaces))
        let separators: Set<Character> = [":", ";", ".", ","]
        var digits: [Int] = []
        if t.contains(where: { separators.contains($0) }) {
            let groups = t.split(omittingEmptySubsequences: false, whereSeparator: { separators.contains($0) })
            guard groups.count <= 4, groups.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy { $0.isASCII && $0.isNumber } })
            else { return nil }
            for g in groups { digits += (g.count == 1 ? "0" + g : String(g)).compactMap(\.wholeNumberValue) }
        } else {
            guard !t.isEmpty, t.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            digits = t.compactMap(\.wholeNumberValue)
            while digits.count > Self.maxDigits, digits.first == 0 { digits.removeFirst() }
        }
        guard !digits.isEmpty, digits.count <= Self.maxDigits else { return nil }
        self.sign = sign
        self.digits = digits
    }

    public var isRelative: Bool { sign != .absolute }

    /// HH, MM, SS, FF filled from the right and normalised at `nfr` — TimecodeEntry's `fields`, moved here so the
    /// transport and the marker editor share one copy.
    public func fields(nfr: Int) -> (h: Int, m: Int, s: Int, f: Int) {
        SMPTETimecode.fillFromRight(digits: digits, nfr: nfr)
    }

    /// The entry as a plain frame count (a duration or an offset): no drop-frame, no origin.
    public func plainFrameCount(nfr: Int) -> Int {
        let (h, m, s, f) = fields(nfr: nfr)
        return ((h * 60 + m) * 60 + s) * nfr + f
    }

    /// The entry as an absolute LABEL's frame count. Drop-frame: a label drop-frame does not have (MM:00;00 and ;01 at a
    /// minute not a multiple of ten) moves forward to that minute's first frame, as timecode entry does. Nil at or past
    /// 24 hours.
    public func labelFrameCount(nfr: Int, fps: Double, dropFrame: Bool) -> Int? {
        var (h, m, s, f) = fields(nfr: nfr)
        guard h < 24 else { return nil }
        if dropFrame, s == 0, m % 10 != 0 {
            let dropped = SMPTETimecode.droppedFramesPerMinute(fps: fps)
            if f < dropped { f = dropped }
        }
        return SMPTETimecode.frameCount(label: String(format: "%02d:%02d:%02d:%02d", h, m, s, f), nfr: nfr, fps: fps,
                                        dropFrame: dropFrame)
    }
}

extension SMPTETimecode {
    /// Digits (most significant first) as HH:MM:SS:FF, filled from the right two at a time and normalised: frames over
    /// `nfr` carry into seconds, seconds over 59 into minutes, minutes into hours.
    public static func fillFromRight(digits: [Int], nfr: Int) -> (h: Int, m: Int, s: Int, f: Int) {
        var value = 0
        for d in digits { value = value * 10 + d }
        var f = value % 100; value /= 100
        var s = value % 100; value /= 100
        var m = value % 100; value /= 100
        var h = value
        guard nfr > 0 else { return (h, m, s, f) }
        s += f / nfr;  f %= nfr
        m += s / 60;   s %= 60
        h += m / 60;   m %= 60
        return (h, m, s, f)
    }
}
