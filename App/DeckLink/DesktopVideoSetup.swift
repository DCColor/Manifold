import AppKit

/// Blackmagic's Desktop Video Setup, opened from Settings ▸ DeckLink Output and the DeckLink menu (Robbie, 2026-11-15):
/// the app where the card's connector mapping is changed.
///
/// The bundle identifier was READ from the installed app's Info.plist (CFBundleIdentifier of
/// `/Applications/Blackmagic Desktop Video/Desktop Video Setup.app`, Desktop Video on the build Mac, 2026-11-15), not
/// guessed. The app is found by that identifier through Launch Services, so it is found wherever it is installed, and
/// the button exists only while it is.
enum DesktopVideoSetup {
    static let bundleIdentifier = "com.blackmagic-design.desktopvideo.utility"
    static let title = "Open Desktop Video Setup…"

    /// The installed app, or nil. A Launch Services lookup: cheap enough to ask when a menu or pane is drawn.
    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) }

    static var isInstalled: Bool { appURL != nil }

    static func open() {
        guard let url = appURL else { NSSound.beep(); return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { print("DeckLink: Desktop Video Setup did not open — \(error.localizedDescription)") }
        }
    }
}
