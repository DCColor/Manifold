//
//  SPSTiming.swift
//  SPSColor
//
//  What an HEVC stream's own parameter sets declare about its frame rate: the SPS VUI's
//  `vui_timing_info`, or the VPS's `vps_timing_info` (docs/COLOR_MANAGEMENT_FINDINGS.md §6.10, Stage 4).
//  H.264's equivalent already exists, in C, for WHEP: App/H264/H264SPSTiming.c. SRT uses that one for
//  H.264; this is the HEVC half, beside the HEVC colour walk it continues.
//
//  ── WHY ────────────────────────────────────────────────────────────────────────────────────
//
//  SRT's frame rate came only from libavformat's `av_guess_frame_rate`, which MEASURES it from the
//  timestamps it receives. A server that rewrites DTS changes that measurement: MediaMTX gives a
//  VideoToolbox HEVC stream at 25 fps DTS steps of 1800 and 5400 ticks, and the guess reads 50.
//  Decided (Robbie, 2026-10-09): the stream's own declaration wins when present; the measurement is
//  the fallback.
//
//  ── WHAT IT READS ──────────────────────────────────────────────────────────────────────────
//
//  `HEVCSPSColor.timing` continues the colour walk past `video_signal_type`; `vpsTiming` walks the VPS.
//  Everything before the timing fields is stepped over at the width the standard gives it. Nothing after
//  `time_scale` is read: HRD parameters follow, and are not ours.
//
//  Same fail-closed rules as the colour: never throws, never traps; a truncated or out-of-range parse
//  is "not declared", never a rate. A zero tick or zero time scale is forbidden and reads as not declared.
//

/// One HEVC declaration of timing, as coded. One tick is one PICTURE period.
public struct SPSTiming: Equatable, Sendable {

    /// Where the declaration was read.
    public enum Source: Equatable, Sendable {
        /// SPS VUI, H.265 §E.2.1.
        case sps
        /// VPS, H.265 §7.3.2.1.
        case vps
    }

    public let source: Source
    public let numUnitsInTick: UInt32
    public let timeScale: UInt32
    /// SPS `field_seq_flag`: each picture is a FIELD, so the tick rate is a field rate.
    public let fieldSequence: Bool

    public init(source: Source, numUnitsInTick: UInt32, timeScale: UInt32,
                fieldSequence: Bool = false) {
        self.source = source
        self.numUnitsInTick = numUnitsInTick
        self.timeScale = timeScale
        self.fieldSequence = fieldSequence
    }

    /// Frames per second, or nil when the declaration is not a frame rate: a zero field, or an HEVC
    /// field sequence (a field rate, which halving would only guess at).
    public var frameRate: Double? {
        guard numUnitsInTick > 0, timeScale > 0, !fieldSequence else { return nil }
        return Double(timeScale) / Double(numUnitsInTick)
    }

    /// For the log: the fields as coded, and where.
    public var described: String {
        var s = "\(source == .sps ? "SPS VUI" : "VPS") num_units_in_tick=\(numUnitsInTick) time_scale=\(timeScale)"
        if fieldSequence { s += " field_seq_flag=1" }
        return s
    }

    /// Both fields are u(32).
    static func read(_ r: inout BitReader, source: Source, fieldSequence: Bool = false) -> SPSTiming? {
        let tick = UInt32(truncatingIfNeeded: r.bits(32))
        let scale = UInt32(truncatingIfNeeded: r.bits(32))
        guard !r.overrun else { return nil }
        return SPSTiming(source: source, numUnitsInTick: tick, timeScale: scale, fieldSequence: fieldSequence)
    }
}
