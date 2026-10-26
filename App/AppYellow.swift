import SwiftUI
import PlayheadSlider

/// The app's one yellow, for SwiftUI. Defined once, as `AppYellow` in Packages/ManifoldCore/Sources/PlayheadSlider,
/// which says what it marks and why green is kept for live. Not the user's playhead colour: a colour chosen in
/// Settings changes the playhead only.
extension Color {
    static var appYellow: Color { Color(nsColor: AppYellow.nsColor) }
    /// Text on a background that follows the appearance: the yellow in dark, its darker text variant in light.
    static var appYellowText: Color { Color(nsColor: AppYellow.textNSColor) }
}
