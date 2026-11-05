//
//  AudioCardText.swift
//  AudioFileInfo
//
//  The card's and the Inspector's words for an audio-only file (docs/STILLS_AND_AUDIO_ONLY_PLAN.md §5.2). One place, so the
//  two cannot describe a file differently and B5's SDI card can reuse them.
//

import Foundation

public enum AudioCardText {

    /// "WAV · 24-bit PCM", "WAV · 32-bit float", "MP3", "M4A · AAC", "MOV · AAC". The container is dropped when it would
    /// repeat the codec.
    public static func format(container: String, codec: String, bitDepth: Int, isFloat: Bool) -> String {
        let coding: String
        if codec == "PCM", bitDepth > 0 {
            coding = "\(bitDepth)-bit " + (isFloat ? "float" : "PCM")
        } else {
            coding = codec
        }
        if container.isEmpty { return coding }
        if coding.isEmpty || coding == "—" || coding.caseInsensitiveCompare(container) == .orderedSame { return container }
        return "\(container) · \(coding)"
    }

    /// "1 channel", "2 channels · Stereo", "6 channels · 5.1". The layout is named only when the file declares one: a
    /// name inferred from the count alone would read as a statement about the file.
    public static func channels(count: Int, declaredLayout: String?) -> String {
        let base = count == 1 ? "1 channel" : "\(count) channels"
        guard let declaredLayout, !declaredLayout.isEmpty, declaredLayout != "—" else { return base }
        return "\(base) · \(declaredLayout)"
    }

    /// "44.1 kHz", "48 kHz", "96 kHz", "22.05 kHz".
    public static func sampleRate(_ hz: Double) -> String {
        guard hz > 0 else { return "—" }
        var text = String(format: "%.2f", hz / 1000)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + " kHz"
    }

    /// "0:03.250", "3:25.000", "1:02:03.456": a file's length to the millisecond.
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let ms = Int((seconds * 1000).rounded())
        let h = ms / 3_600_000, m = ms / 60_000 % 60, s = ms / 1000 % 60, f = ms % 1000
        return h > 0 ? String(format: "%d:%02d:%02d.%03d", h, m, s, f) : String(format: "%d:%02d.%03d", m, s, f)
    }
}
