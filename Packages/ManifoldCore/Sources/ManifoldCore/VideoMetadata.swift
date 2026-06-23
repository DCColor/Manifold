import Foundation
import CoreMedia

public struct ChapterMarker: Equatable, Sendable {
    public var time: Double
    public var title: String
}

/// Whether an audio track's layout name came from a real declaration, a marked
/// inference from channel count, or is an honest unknown.
public enum LayoutConfidence: Equatable, Sendable {
    case declared      // from real channel descriptions / known tag
    case inferred      // guessed from channel count, no declaration
    case undeclared    // no declaration and no confident guess
}

public struct AudioTrackInfo: Equatable, Sendable {
    public var codecName: String = "—"
    public var channelCount: Int = 0
    public var layoutName: String = "—"
    public var layoutConfidence: LayoutConfidence = .undeclared
    public var sampleRate: Double = 0      // Hz
    public var bitDepth: Int = 0
    public var dataRate: Double = 0         // bits/sec (estimated)

    public var sampleRateString: String {
        sampleRate > 0 ? String(format: "%.1f kHz", sampleRate / 1000) : "—"
    }
    public var bitDepthString: String {
        bitDepth > 0 ? "\(bitDepth)-bit" : "—"
    }
    public var dataRateString: String {
        dataRate > 0 ? String(format: "%.0f kb/s", dataRate / 1000) : "—"
    }
    /// Compact summary, e.g. "Stereo · 48.0 kHz · 24-bit"
    public var summary: String {
        var parts: [String] = []
        if layoutName != "—" { parts.append(layoutName) }
        else if channelCount > 0 { parts.append("\(channelCount) ch") }
        if sampleRate > 0 { parts.append(sampleRateString) }
        if bitDepth > 0 { parts.append(bitDepthString) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

public struct TextTrackInfo: Equatable, Sendable {
    public var kind: String = "—"        // "Closed Caption", "Subtitle", "Timed Text"
    public var format: String = "—"      // "CEA-608", "CEA-708", "WebVTT", "TTML", etc.
    public var language: String = "—"

    public var summary: String {
        var s = format
        if language != "—" && !language.isEmpty { s += " · \(language)" }
        return s
    }
}

public struct VideoMetadata: Equatable, Sendable {
    public var codecName: String = "—"
    public var width: Int = 0
    public var height: Int = 0
    public var frameRate: Double = 0
    public var fileName: String = "—"
    public var container: String = "—"
    public var videoDataRate: Double = 0    // bits/sec (estimated)

    public var creationDate: Date?       // embedded media creation date (from container)
    public var fileCreatedDate: Date?    // filesystem created (on this disk)
    public var fileModifiedDate: Date?   // filesystem modified (Finder's "modified")
    public var creator: String?          // author/creator tag, if present
    public var software: String?         // authoring tool / encoder, if present

    public var colorPrimaries: String = "—"
    public var transferFunction: String = "—"
    public var colorMatrix: String = "—"
    public var colorPrimariesCode: Int?
    public var transferFunctionCode: Int?
    public var colorMatrixCode: Int?

    public var startTimecode: String?
    public var chapters: [ChapterMarker] = []
    public var audioTracks: [AudioTrackInfo] = []
    public var textTracks: [TextTrackInfo] = []

    public var resolutionString: String {
        (width > 0 && height > 0) ? "\(width) × \(height)" : "—"
    }
    public var frameRateString: String {
        frameRate > 0 ? String(format: "%.3f fps", frameRate) : "—"
    }
    public var videoDataRateString: String {
        videoDataRate > 0 ? String(format: "%.1f Mb/s", videoDataRate / 1_000_000) : "—"
    }
    public var nclcTriple: String {
        func s(_ c: Int?) -> String { c.map(String.init) ?? "—" }
        return "\(s(colorPrimariesCode))-\(s(transferFunctionCode))-\(s(colorMatrixCode))"
    }
    public func labeled(_ name: String, _ code: Int?) -> String {
        guard let code else { return name }
        return "\(name) (\(code))"
    }

    public static func dateString(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
