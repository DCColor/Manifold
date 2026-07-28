import AppKit
import Foundation

/// Update NOTIFIER — emphatically not an updater.
///
/// It asks the release server what the current version is, and if that is newer than the running
/// binary it says so and offers to open the download page in the user's browser. It never
/// downloads, never writes to disk, never touches the app bundle. The whole surface is one HTTP
/// GET and, at most, one `NSWorkspace.open`.
///
/// THE DESIGN RULE IS SILENCE ON FAILURE. A tester on a plane, on hotel wifi, or behind a captive
/// portal must never see a complaint from this. Offline, DNS failure, 404, timeout, malformed
/// JSON, a manifest for the wrong product — every one of them takes the same path: log a line and
/// return. There is exactly one exception, and it is the menu item, because a user who clicked
/// "Check for Updates…" is owed an answer.
///
/// DELIBERATELY ABSENT: a preference to disable checking, a "skip this version" affordance, and
/// any notion of a check interval. Launch, plus the menu item, is the entire trigger surface.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()
    private init() {}

    // MARK: - Endpoints

    /// The release manifest. Verified live; see `Manifest` for the shape.
    private static let manifestURL = URL(string: "https://releases.graviton.tools/manifold/manifest")!
    /// The download page/redirect for this platform's asset. Opened in the DEFAULT BROWSER — we
    /// hand the user off, we do not fetch it ourselves.
    private static let downloadURL = URL(string: "https://releases.graviton.tools/manifold/mac-arm64")!

    /// Short by design. A launch check that hasn't answered in this long is a check that failed, and
    /// failing fast keeps a dead network from holding a URLSession task open behind the user's back.
    private static let timeout: TimeInterval = 5

    /// Cap on release notes shown in the dialog. The current manifest carries 6 and all 6 fit; the
    /// cap exists so a future 30-note release can't produce an alert taller than the screen. When it
    /// bites, the dialog says so rather than silently truncating.
    private static let maxNotesShown = 6

    // MARK: - State

    /// One launch check per process, however many windows the WindowGroup opens.
    private var launchCheckDone = false
    /// Guards against a double-click on the menu item stacking two dialogs.
    private var checkInFlight = false

    // MARK: - Entry points

    /// Launch check. Silent unless there is genuinely something newer.
    ///
    /// Called from a `.task` on the window's content, so it runs AFTER the window is up and never
    /// delays startup: everything below is either async or a few string comparisons.
    func checkAtLaunch() async {
        guard !launchCheckDone else { return }
        launchCheckDone = true
        await check(userInitiated: false)
    }

    /// Manifold ▸ Check for Updates… — the same check, but it reports "up to date" too, because the
    /// user asked and silence would read as a broken menu item.
    func checkFromMenu() {
        Task { await check(userInitiated: true) }
    }

    // MARK: - The check

    private func check(userInitiated: Bool) async {
        guard !checkInFlight else { return }
        checkInFlight = true
        defer { checkInFlight = false }

        let local = Self.runningVersion()
        NSLog("[UPDATE] checking — running %@ (build %@)", local.version, local.build)

        guard let manifest = await Self.fetchManifest() else {
            // Every failure mode lands here. Silent on launch; on the menu path the user gets a
            // plain "couldn't check" rather than a menu item that appears to do nothing.
            if userInitiated { Self.presentCheckFailed() }
            return
        }

        let comparison = Self.compare(localVersion: local.version, localBuild: local.build,
                                      remoteVersion: manifest.version, remoteBuild: manifest.build)
        switch comparison {
        case .orderedAscending:
            NSLog("[UPDATE] update available — %@ (build %@)", manifest.version, manifest.build)
            Self.presentUpdateAvailable(manifest: manifest, local: local)
        case .orderedSame, .orderedDescending:
            NSLog("[UPDATE] up to date — server has %@ (build %@)", manifest.version, manifest.build)
            if userInitiated { Self.presentUpToDate(local: local) }
        }
    }

    // MARK: - Running version (from the bundle, never a constant)

    /// The running binary's own identity. Read from Info.plist so it can never disagree with what
    /// the release script stamped: `MARKETING_VERSION` → CFBundleShortVersionString and
    /// `CURRENT_PROJECT_VERSION` → CFBundleVersion.
    static func runningVersion() -> (version: String, build: String) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return (version, build)
    }

    // MARK: - Comparison

    /// Compare a dotted numeric version string COMPONENT-WISE, never lexically. "0.10.0" > "0.9.0"
    /// is the case that string comparison gets wrong, and it is the reason this exists.
    ///
    /// Missing components are zero, so "0.5" and "0.5.0" compare equal. Any non-numeric tail on a
    /// component (a "-beta" suffix) is dropped rather than failing the whole comparison — we don't
    /// publish pre-release tags, and a malformed component should not be able to suppress a real
    /// update.
    ///
    /// Returns `.orderedAscending` when `lhs` is OLDER than `rhs`.
    static func compareNumericVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func components(_ s: String) -> [Int] {
            s.split(separator: ".").map { part in
                Int(part.prefix { $0.isNumber }) ?? 0
            }
        }
        let a = components(lhs), b = components(rhs)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Full ordering: marketing version first, BUILD NUMBER as the tie-break.
    ///
    /// THE BUILD TIE-BREAK IS LOAD-BEARING, NOT A REFINEMENT. Tester builds iterate the build number
    /// under a fixed marketing version — 0.5.0 build 4 today, 0.5.0 build 5 tomorrow — so a
    /// version-only comparison would report "up to date" for every tester build we ever ship. The
    /// build is compared with the same component-wise routine, which handles both a plain "5" and a
    /// dotted "1.2.3"-style build string.
    static func compare(localVersion: String, localBuild: String,
                        remoteVersion: String, remoteBuild: String) -> ComparisonResult {
        let byVersion = compareNumericVersions(localVersion, remoteVersion)
        guard byVersion == .orderedSame else { return byVersion }
        return compareNumericVersions(localBuild, remoteBuild)
    }

    // MARK: - Manifest

    /// The subset of the release manifest this notifier needs. Unknown keys (`product` aside,
    /// `updated`, `assets`) are ignored rather than required, so the server can grow fields without
    /// breaking older clients into silence.
    struct Manifest {
        let version: String
        let build: String
        let notes: [String]
    }

    /// GET the manifest. Returns nil on ANY failure — that is the contract, and every `return nil`
    /// below is one of the failure modes the spec enumerates.
    private static func fetchManifest() async -> Manifest? {
        var request = URLRequest(url: manifestURL)
        request.timeoutInterval = timeout
        // Never serve this from cache. A cached manifest is precisely the thing that would hide a
        // release from the tester who most needs to see it.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Offline, DNS failure, TLS failure, timeout, cancellation.
            NSLog("[UPDATE] check failed (network): %@", error.localizedDescription)
            return nil
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // 404, 500, a captive portal's redirect to a login page.
            NSLog("[UPDATE] check failed (HTTP %d)", http.statusCode)
            return nil
        }

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // Malformed JSON, an HTML error page, a captive portal's interstitial.
            NSLog("[UPDATE] check failed (response was not JSON)")
            return nil
        }

        // Wrong product entirely — don't offer a Manifold user someone else's release.
        if let product = root["product"] as? String, product.caseInsensitiveCompare("manifold") != .orderedSame {
            NSLog("[UPDATE] check failed (manifest is for '%@', not manifold)", product)
            return nil
        }

        guard let version = root["version"] as? String, !version.isEmpty else {
            NSLog("[UPDATE] check failed (manifest has no usable version)")
            return nil
        }

        // `build` IS A STRING IN THE LIVE MANIFEST ("4") though the spec writes it as a number (4).
        // Accept either rather than let a producer-side type change silence the notifier — this is
        // the field the tester-build tie-break depends on.
        let build: String
        if let s = root["build"] as? String { build = s }
        else if let n = root["build"] as? NSNumber { build = n.stringValue }
        else { build = "0" }

        let notes = (root["notes"] as? [String]) ?? []
        return Manifest(version: version, build: build, notes: notes)
    }

    // MARK: - Dialogs

    private static func presentUpdateAvailable(manifest: Manifest, local: (version: String, build: String)) {
        let alert = NSAlert()
        // A build-only bump is the COMMON tester case (0.5.0 build 4 → 0.5.0 build 5). Titling that
        // "Manifold 0.5.0 is available" to someone already running 0.5.0 reads as a bug, so the
        // build is promoted into the headline exactly when the marketing version can't distinguish.
        let sameVersion = compareNumericVersions(local.version, manifest.version) == .orderedSame
        alert.messageText = sameVersion
            ? "Manifold \(manifest.version) (build \(manifest.build)) is available"
            : "Manifold \(manifest.version) is available"

        var body = "You have \(local.version) (build \(local.build))."
        if !manifest.notes.isEmpty {
            let shown = manifest.notes.prefix(maxNotesShown)
            body += "\n\n" + shown.map { "•  \($0)" }.joined(separator: "\n")
            let hidden = manifest.notes.count - shown.count
            if hidden > 0 { body += "\n\n…and \(hidden) more." }
        }
        alert.informativeText = body
        alert.alertStyle = .informational

        alert.addButton(withTitle: "Download")   // default — first button
        alert.addButton(withTitle: "Not now")

        if alert.runModal() == .alertFirstButtonReturn {
            NSLog("[UPDATE] opening download page")
            NSWorkspace.shared.open(downloadURL)
        } else {
            NSLog("[UPDATE] user chose Not now")
        }
    }

    /// Menu path only — never shown at launch.
    private static func presentUpToDate(local: (version: String, build: String)) {
        let alert = NSAlert()
        alert.messageText = "Manifold is up to date"
        alert.informativeText = "You have \(local.version) (build \(local.build)), the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Menu path only. The launch path stays silent on failure, which is the whole point of it.
    private static func presentCheckFailed() {
        let alert = NSAlert()
        alert.messageText = "Couldn’t check for updates"
        alert.informativeText = "Manifold couldn’t reach the update server. Check your internet connection and try again."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
