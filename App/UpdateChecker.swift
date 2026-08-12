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

    /// How many release notes the dialog shows BEFORE the user asks for the rest.
    ///
    /// ⚠️ THIS IS NOW A FOLD, NOT A TRUNCATION, and the difference is the whole point. It used to be
    /// a hard cap: the dialog printed six bullets and "…and 4 more." — text that told the user
    /// something existed and gave them no way to reach it, which is worse than showing nothing at
    /// all. The remainder is now behind a button that expands the alert in place.
    ///
    /// The number still exists for the reason the cap did: a thirty-note release must not open a
    /// dialog taller than the screen. Six is what the 0.5.x releases carried and it is a
    /// comfortable opening height — see `ReleaseNotesAccessory` for the measured geometry.
    private static let maxNotesShown = 6

    /// Above this many notes the expanded list scrolls instead of growing the alert. Derived, not
    /// guessed: see the height table in `ReleaseNotesAccessory`.
    private static let scrollThreshold = 14

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

        alert.informativeText = "You have \(local.version) (build \(local.build))."
        alert.alertStyle = .informational

        // THE NOTES MOVED OUT OF `informativeText` AND INTO AN ACCESSORY VIEW. `informativeText` is
        // a flat string on a label — nothing in it can be clicked, which is exactly why the old
        // "…and 4 more." was dead. An accessory view is real AppKit and can hold a button.
        var accessory: ReleaseNotesAccessory?
        if !manifest.notes.isEmpty {
            let view = ReleaseNotesAccessory(notes: manifest.notes,
                                             collapsedCount: maxNotesShown,
                                             scrollThreshold: scrollThreshold)
            // Re-laying out the alert is the host's job, not the view's: `layout()` lives on NSAlert
            // and the view has no business knowing what it is embedded in.
            view.onToggle = { [weak alert] in alert?.layout() }
            alert.accessoryView = view
            accessory = view
        }

        alert.addButton(withTitle: "Download")   // default — first button
        alert.addButton(withTitle: "Not now")
        // Keyboard focus must not land on the disclosure button — ⏎ has to mean Download. Asked for
        // after the buttons exist, because that is when the alert has a window to ask about.
        accessory?.declineFirstResponder(in: alert)

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

// MARK: - The expandable release-notes list

/// The release-notes list inside the update alert: a few bullets, and a button that reveals the
/// rest by growing the dialog in place.
///
/// ── WHY THIS IS A VIEW AND NOT MORE `informativeText` ─────────────────────────────────────
///
/// `NSAlert.informativeText` is a plain `String` rendered into a label the alert owns. Nothing in
/// it is addressable, so "…and 4 more." could never have been made clickable — it was a sentence
/// describing an absence. `NSAlert.accessoryView` is the supported seam for putting real controls
/// into an alert, and `NSAlert.layout()` is the supported way to tell the alert its accessory
/// changed size. Together they give expand-in-place without leaving the NSAlert idiom, which
/// matters here: this dialog is raised at LAUNCH from a static context, and NSAlert is the only
/// presentation in the app that needs no window to attach to.
///
/// ── MEASURED GEOMETRY — system font, 380 pt column, the real 0.6.0 notes ──────────────────
///
/// Measured by building this exact view inside a real `NSAlert` and reading `alert.window.frame`
/// after `layout()`. Re-measure if the font, the column width or the threshold changes:
///
///     case                                  accessory   alert window
///     ───────────────────────────────────   ─────────   ────────────
///     6-note release (nothing folded)          176 pt        394 pt
///     0.6.0 as it opens — 10 notes, 6 shown    200 pt        418 pt
///     0.6.0 expanded — all 10                  296 pt        514 pt
///     14 notes expanded (last size that grows) 424 pt        642 pt
///     15+ notes expanded (scrolls, capped)     448 pt        666 pt
///     30 notes as it opens (still 6 shown)     200 pt        418 pt
///
/// (The 24 pt step at the threshold is the scroller appearing, not a jump in the text.)
///
/// **Expanding the current release costs 96 pt** — 418 → 514. The bullets are long enough that most
/// wrap to two lines, so a note costs ~24 pt rather than the ~18 pt a single line would.
///
/// ⚠️ ABOVE `scrollThreshold` NOTES THE EXPANDED LIST SCROLLS instead of growing the window, and the
/// cap is set so crossing the threshold does not change the dialog's size (see `maxScrollHeight`).
/// The ceiling is 642 pt against ~870 pt of usable height on the shortest display this app supports
/// (1440×900, less menu bar and Dock). Without the cap a thirty-note release would open an alert
/// roughly 1,100 pt tall with its buttons off the bottom of the screen — unclickable, and
/// unreachable by keyboard for anyone who does not already know that ⏎ is Download.
///
/// Note the folded height is CONSTANT at 418 pt whatever the release carries, because the fold is
/// what the dialog opens at. Only someone who asks for the rest pays for it.
final class ReleaseNotesAccessory: NSView {

    /// Called after the fold state changes, so the host can re-lay-out the alert. The view resizes
    /// ITSELF; making the alert catch up is the host's job (`NSAlert.layout()`).
    var onToggle: (() -> Void)?

    /// The text column. 380 pt is a touch wider than NSAlert's natural text width, so the alert
    /// grows to fit the accessory rather than the accessory being squeezed — which keeps the bullets
    /// on the same measure as the message above them instead of wrapping earlier.
    private static let width: CGFloat = 380
    /// Gap between the last bullet and the disclosure button.
    private static let buttonGap: CGFloat = 8

    private let notes: [String]
    private let collapsedCount: Int
    private let scrolls: Bool
    private var expanded = false

    private let label = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let scrollView = NSScrollView()

    init(notes: [String], collapsedCount: Int, scrollThreshold: Int) {
        self.notes = notes
        self.collapsedCount = collapsedCount
        self.scrolls = notes.count > scrollThreshold
        super.init(frame: .zero)

        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = Self.width
        // Selectable so a tester can copy a line out of the dialog, editable false. Costs nothing
        // and is the difference between "I'll retype this" and ⌘C.
        label.isSelectable = true

        button.bezelStyle = .inline
        button.isBordered = false
        button.target = self
        button.action = #selector(toggle)
        button.contentTintColor = .controlAccentColor

        if scrolls {
            scrollView.hasVerticalScroller = true
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.documentView = label
            addSubview(scrollView)
        } else {
            addSubview(label)
        }
        addSubview(button)

        applyState()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// ⏎ MUST MEAN DOWNLOAD. An accessory view's controls join the alert's key loop, and a button
    /// that took first responder would swallow Return — turning the primary action into "expand the
    /// list", which is the opposite of what someone pressing Return in an update dialog wants.
    func declineFirstResponder(in alert: NSAlert) {
        alert.window.initialFirstResponder = alert.buttons.first
    }

    @objc private func toggle() {
        expanded.toggle()
        applyState()
        onToggle?()
    }

    /// Rebuild the text and resize self to fit. Called on construction and on every toggle.
    private func applyState() {
        let visible = expanded ? notes : Array(notes.prefix(collapsedCount))
        label.stringValue = visible.map { "•  \($0)" }.joined(separator: "\n")

        let hidden = notes.count - collapsedCount
        if hidden > 0 {
            // A disclosure triangle plus a sentence, rather than a bare "…and 4 more.": the triangle
            // is the part that says "this opens", which is precisely what the old text lacked.
            button.title = expanded ? "▾  Show fewer" : "▸  Show \(hidden) more"
            button.isHidden = false
        } else {
            button.isHidden = true
        }

        // Lay out bottom-up: the button sits under the text, and `self` is exactly as tall as both.
        let textHeight = label.sizeThatFits(NSSize(width: Self.width,
                                                  height: .greatestFiniteMagnitude)).height
        // The scrolling case is the only one that CAPS the height; the growing case is whatever the
        // text needs. `maxScrollHeight` is the same budget the threshold was derived from.
        let visibleTextHeight = scrolls && expanded ? min(textHeight, Self.maxScrollHeight) : textHeight
        button.sizeToFit()
        let buttonHeight = button.isHidden ? 0 : button.frame.height + Self.buttonGap

        let container = scrolls ? scrollView : label
        container.frame = NSRect(x: 0, y: buttonHeight,
                                 width: Self.width, height: visibleTextHeight)
        if scrolls { label.frame = NSRect(x: 0, y: 0, width: Self.width, height: textHeight) }
        button.frame = NSRect(x: 0, y: 0, width: button.frame.width, height: button.frame.height)
        frame = NSRect(x: 0, y: 0, width: Self.width, height: visibleTextHeight + buttonHeight)
    }

    /// The tallest the notes list is allowed to get once it scrolls.
    ///
    /// CHOSEN TO MATCH THE GROWING CASE AT THE THRESHOLD, not picked for roundness: 14 notes is the
    /// last count that grows, and it needs 424 pt of text. Setting the scroll cap to the same figure
    /// means crossing the threshold does not change the dialog's size — without it, a 15-note
    /// release opened a SHORTER dialog than a 14-note one (502 pt vs 642 pt), which is a visible
    /// discontinuity with no meaning behind it. Re-measure both if the threshold moves.
    private static let maxScrollHeight: CGFloat = 424
}
