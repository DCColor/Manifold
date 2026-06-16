import Foundation
import CoreMedia

public struct ChapterMarker: Equatable, Sendable {
    public var time: Double
    public var title: String
}

public struct AudioTrackInfo: Equatable, Sendable {
    public var codecName: String = "—"
    public var channelCount: Int = 0
    public var layoutName: String = "—"
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

public struct VideoMetadata: Equatable, Sendable {
    public var codecName: String = "—"
    public var width: Int = 0
    public var height: Int = 0
    public var frameRate: Double = 0
    public var container: String = "—"
    public var videoDataRate: Double = 0    // bits/sec (estimated)

    public var colorPrimaries: String = "—"
    public var transferFunction: String = "—"
    public var colorMatrix: String = "—"
    public var colorPrimariesCode: Int?
    public var transferFunctionCode: Int?
    public var colorMatrixCode: Int?

    public var startTimecode: String?
    public var chapters: [ChapterMarker] = []
    public var audioTracks: [AudioTrackInfo] = []

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

    /// Map a channel count to a layout name (Flip's LAYOUTS table).
    public static func layoutName(forChannels n: Int) -> String {
        switch n {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 3: return "L R C"
        case 4: return "Quad"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return n > 0 ? "\(n) ch" : "—"
        }
    }
}
