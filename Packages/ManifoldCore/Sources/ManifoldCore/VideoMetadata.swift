import Foundation
import CoreMedia

public struct ChapterMarker: Equatable, Sendable {
    public var time: Double     // seconds
    public var title: String
}

/// Technical metadata about a loaded clip, for the inspector panel.
public struct VideoMetadata: Equatable, Sendable {
    public var codecName: String = "—"
    public var width: Int = 0
    public var height: Int = 0
    public var frameRate: Double = 0
    public var container: String = "—"

    public var colorPrimaries: String = "—"
    public var transferFunction: String = "—"
    public var colorMatrix: String = "—"
    public var colorPrimariesCode: Int?
    public var transferFunctionCode: Int?
    public var colorMatrixCode: Int?

    /// Start timecode like "01:00:00:00" (";" before frames if drop-frame). nil if none.
    public var startTimecode: String?
    public var chapters: [ChapterMarker] = []

    public var resolutionString: String {
        (width > 0 && height > 0) ? "\(width) × \(height)" : "—"
    }
    public var frameRateString: String {
        frameRate > 0 ? String(format: "%.3f fps", frameRate) : "—"
    }
    public var nclcTriple: String {
        func s(_ c: Int?) -> String { c.map(String.init) ?? "—" }
        return "\(s(colorPrimariesCode))-\(s(transferFunctionCode))-\(s(colorMatrixCode))"
    }
    public func labeled(_ name: String, _ code: Int?) -> String {
        guard let code else { return name }
        return "\(name) (\(code))"
    }
}
