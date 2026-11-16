//
//  FrameRequest.swift — asking a "first frame at or after this time" decoder for one exact frame
//  (docs/MARKERS_PLAN.md §4.4, §15; Robbie 2026-11-15).
//
//  `LibavScrubProducer` (MXF, the container route) seeks backward and decodes forward to the FIRST frame whose time is at
//  or after the requested time (`reaches`). Marker thumbnails first asked it for `(N + 0.25) / rate`, the quarter-frame
//  nudge the AVFoundation seek path needs (TimecodeEntry): frame N's own time is before that, so the producer skipped it
//  and returned frame N + 1, which the thumbnail's frame check then refused, twice: "no preview" on every MXF marker
//  (`mk-2997df-tc.mxf`, 01:00:12;00 and ;01). The request for that rule is a quarter frame BEFORE frame N: frame N − 1 is
//  three quarters of a frame earlier and does not reach it, frame N does.
//

public enum FrameRequest {
    /// The producer's acceptance rule: a frame at `seconds` satisfies a request for `target`. (Moved here from
    /// `LibavScrubProducer`, unchanged: `sec + 1e-6 < seconds` skipped a frame.)
    public static func reaches(_ seconds: Double, _ target: Double) -> Bool { seconds + 1e-6 >= target }

    /// The time to ask a first-at-or-after decoder for, to get frame `index` at `rate`.
    public static func firstAtOrAfter(index: Int, rate: Double) -> Double {
        max((Double(index) - 0.25) / rate, 0)
    }
}
