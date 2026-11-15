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

    /// The inverse of `durationLabel`. Also accepts a bare frame count ("48").
    public static func durationFrames(label: String, nfr: Int) -> Int? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if let n = Int(trimmed), n >= 0 { return n }
        let parts = trimmed.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." })
        guard parts.count == 4, let hh = Int(parts[0]), let mm = Int(parts[1]), let ss = Int(parts[2]),
              let ff = Int(parts[3]), nfr > 0, hh >= 0, mm >= 0, mm < 60, ss >= 0, ss < 60, ff >= 0, ff < nfr else { return nil }
        return (hh * 3600 + mm * 60 + ss) * nfr + ff
    }
}
