import SwiftUI
import PlayheadSlider

/// The app's highlight colour, for SwiftUI: #FFE600 unless Settings ▸ General ▸ Highlight color says otherwise
/// (Packages/ManifoldCore/Sources/PlayheadSlider, `AppYellow` and `AppHighlight`, which say what it marks and why green
/// is kept for live). Read through `AppHighlight.shared`, which is observed, so a view that uses either colour in its
/// body redraws when the choice changes. The playhead follows it unless Settings gives the playhead its own colour.
extension Color {
    static var appYellow: Color { Color(nsColor: AppHighlight.shared.nsColor) }
    /// Text on a background that follows the appearance: the highlight in dark, its darker text variant in light.
    static var appYellowText: Color { Color(nsColor: AppHighlight.shared.textNSColor) }
}
