//
//  LiveDecodeFailure.swift
//  ColorimetryModel
//
//  What a VideoToolbox decode failure means for a live stream (docs/COLOR_MANAGEMENT_FINDINGS.md §6.10,
//  Stage 3b S3/S4 follow-up). In the package so `swift test` reaches the table; LiveVideoDecoder acts on it.
//
//  ── WHY THE CODE ALONE CANNOT DECIDE ───────────────────────────────────────────────────
//
//  VideoToolbox names "this Mac has no decoder for this format" with its own codes (−12906, −12910) and
//  their legacy twin (−8970). But MEASURED (§6.10, S3): H.264 4:2:2 in software fails with −8969, which
//  VTErrors.h pairs with −12909, kVTVideoDecoderBadDataErr — the same answer as a picture damaged in
//  transit. So a refusal on the code alone would leave that stream black; a refusal on any first failure
//  would also refuse a stream whose first keyframe was merely damaged. Hence two rules: refuse at once on
//  an unsupported-format code; on a data error, keep the stream and wait for the next random-access
//  picture, and refuse only when `dataFailuresBeforeRefusal` of them in a row have failed with nothing
//  ever decoded.
//

public enum LiveDecodeFailure: Equatable, Sendable {
    /// VideoToolbox has no decoder for this format: refuse now, there is nothing to wait for.
    case unsupportedFormat
    /// The data could not be decoded (damage, or a decoder that reports an unsupported format as bad
    /// data): drop to the next random-access picture and try again.
    case data

    public init(status: Int32) {
        switch status {
        case -12906,    // kVTCouldNotFindVideoDecoderErr
             -12910,    // kVTVideoDecoderUnsupportedDataFormatErr
             -8970:     // its legacy twin (VTErrors.h: "c.f. -8970")
            self = .unsupportedFormat
        default:
            self = .data
        }
    }

    /// Random-access pictures in a row that must fail, with no picture ever decoded since the session
    /// was built, before a stream with only data errors is refused. Each is a separate keyframe (a failure
    /// closes the keyframe gate), so a single damaged keyframe never refuses a stream: the next one plays.
    public static let dataFailuresBeforeRefusal = 3
}
