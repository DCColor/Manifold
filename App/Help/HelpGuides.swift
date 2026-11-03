//
//  HelpGuides.swift — Help ▸ Sync and Color Guide: the guides bundled in the app, each in one reusable window.
//
//  Bundled, not hosted (Robbie, 2026-11-02): a guide opens offline and always describes the build it is in. The page is
//  the guide's Markdown (docs/guides/), turned into Contents/Resources/Guides/<slug>/index.html and one shared
//  Guides/guide.css by scripts/guide/build_guide.py, a build phase that runs on every build (project.yml), so the bundle
//  always matches the doc. What the doc cannot know, the app fills in: the version (CFBundleShortVersionString, the doc's
//  {{VERSION}} token) and the highlight colour (Settings ▸ General ▸ Highlight color, followed live). Light and dark
//  follow the window: the stylesheet's prefers-color-scheme, and an image's -dark version.
//
//  FIND is the window's own, in its toolbar: ⌘F to the field, Return or ⌘G for the next match, ⇧Return or ⇧⌘G for the
//  previous, the field's clear button to end it. WKWebView has no find of its own on macOS. ⌘F is full screen in a
//  player window and nothing here: `ShortcutCenter` acts only while a player window is key.
//
//  A NEW GUIDE (the "Manifold User Guide") is a case of `HelpGuide`, a `Window` scene in `ManifoldApp` and a line in the
//  "Bundle the guides" build phase. The Help menu lists every case, at its top.
//

import AppKit
import SwiftUI
import WebKit
import PlayheadSlider

/// The bundled guides, in Help-menu order.
enum HelpGuide: String, CaseIterable, Identifiable {
    case syncAndColor = "sync-and-color"

    var id: String { rawValue }

    /// The Help-menu item and the window's title.
    var title: String {
        switch self {
        case .syncAndColor: return "Sync and Color Guide"
        }
    }

    var windowID: String { "guide-" + rawValue }

    /// Contents/Resources/Guides: every guide's folder and the shared stylesheet. The page reads nothing outside it.
    static var directory: URL? { Bundle.main.resourceURL?.appendingPathComponent("Guides", isDirectory: true) }

    /// Its page in the bundle, or nil when this build has none.
    var pageURL: URL? {
        guard let u = Self.directory?.appendingPathComponent(rawValue, isDirectory: true)
                .appendingPathComponent("index.html"),
              FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }
}

// MARK: - The window

struct HelpGuideView: View {
    let guide: HelpGuide
    @StateObject private var page: GuidePage

    init(guide: HelpGuide) {
        self.guide = guide
        _page = StateObject(wrappedValue: GuidePage(guide: guide))
    }

    var body: some View {
        Group {
            if guide.pageURL != nil {
                GuideWebViewHost(webView: page.webView)
            } else {
                ContentUnavailableView("The guide isn’t included in this build.", systemImage: "book.closed")
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .toolbar {
            ToolbarItemGroup {
                Text(page.findStatus)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("guide.findStatus")
                GuideFindField(page: page)
                    .frame(width: 220)
                // Two plain toolbar buttons, NOT a ControlGroup: inside a toolbar ControlGroup a button's name never
                // reaches Accessibility, neither `.accessibilityLabel` nor a titled `Button(_:systemImage:)` with
                // `.labelStyle(.iconOnly)` (MEASURED twice, 2026-11-02: both read as "button", only the tooltip as help).
                Button { page.findAgain(backwards: true) } label: { Label("Previous Match", systemImage: "chevron.left") }
                    .help("Previous Match (⇧⌘G)")
                    .accessibilityIdentifier("guide.findPrevious")
                Button { page.findAgain(backwards: false) } label: { Label("Next Match", systemImage: "chevron.right") }
                    .help("Next Match (⌘G)")
                    .accessibilityIdentifier("guide.findNext")
            }
        }
        .onChange(of: AppHighlight.shared.hex) { _, _ in page.applyHighlight() }
    }
}

/// One guide’s page: its web view, and find. File-private, as `GuideWebView` is: an NSObject the app can see goes into
/// Manifold-Swift.h, which the Objective-C++ sources import without WebKit.
@MainActor
fileprivate final class GuidePage: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: GuideWebView
    /// "3 of 12", "Not found", or empty while there is nothing to find.
    @Published private(set) var findStatus = ""
    weak var findField: NSSearchField?

    init(guide: HelpGuide) {
        let config = WKWebViewConfiguration()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let accent = Self.accent()
        config.userContentController.addUserScript(WKUserScript(
            source: Self.pageScript + "guideFill(\(Self.js(version)), \(Self.js(accent.0)), \(Self.js(accent.1)));",
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = GuideWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .windowBackgroundColor
        webView.onFind = { [weak self] in self?.focusFind() }
        webView.onFindAgain = { [weak self] backwards in self?.findAgain(backwards: backwards) }
        if let url = guide.pageURL, let dir = HelpGuide.directory {
            webView.loadFileURL(url, allowingReadAccessTo: dir)
        }
    }

    // MARK: Find

    /// `step` 0 finds from the top as the query is typed; ±1 moves to the next or previous match (the first or last for a
    /// new query). An empty query ends find.
    func find(_ query: String, step: Int) {
        guard !query.isEmpty else {
            findStatus = ""
            webView.evaluateJavaScript("guideFindEnd()")
            return
        }
        webView.callAsyncJavaScript("return guideFind(q, step)", arguments: ["q": query, "step": step], in: nil,
                                    in: .page) { [weak self] result in
            guard let self, case .success(let value) = result, let at = value as? [Int], at.count == 2 else { return }
            self.findStatus = at[1] == 0 ? "Not found" : "\(at[0]) of \(at[1])"
        }
    }

    /// ⌘G, ⇧⌘G and the toolbar's arrows: the field's query, one match on.
    func findAgain(backwards: Bool) {
        let query = findField?.stringValue ?? ""
        if query.isEmpty {
            find("", step: 0)
            focusFind()
        } else {
            find(query, step: backwards ? -1 : 1)
        }
    }

    func focusFind() {
        guard let field = findField else { return }
        field.window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    // MARK: The page

    /// The highlight colour, followed live: its hex and its light-appearance text variant (`AppYellow.textOnLight`).
    func applyHighlight() {
        let accent = Self.accent()
        webView.callAsyncJavaScript("guideAccent(a, t)", arguments: ["a": accent.0, "t": accent.1], in: nil, in: .page)
    }

    private static func accent() -> (String, String) {
        let hex = AppHighlight.shared.hex
        return ("#" + hex, "#" + AppYellow.textOnLight(hex))
    }

    /// A Swift string as a JavaScript string literal.
    private static func js(_ s: String) -> String {
        (try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    /// The version and accent, and find: every match highlighted (the CSS Custom Highlight API), the current one in the
    /// highlight colour and scrolled into view. A match may cross elements ("**A/V** menu").
    private static let pageScript = """
    (function () {
      let ranges = [], current = -1, last = null;
      window.guideAccent = function (accent, textLight) {
        const s = document.documentElement.style;
        s.setProperty('--accent', accent);
        s.setProperty('--accent-text-light', textLight);
      };
      window.guideFill = function (version, accent, textLight) {
        document.querySelectorAll('.guide-version').forEach(function (e) { e.textContent = version; });
        guideAccent(accent, textLight);
      };
      function collect(query) {
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        const nodes = [], starts = [];
        let text = '';
        for (let n = walker.nextNode(); n; n = walker.nextNode()) { nodes.push(n); starts.push(text.length); text += n.data; }
        function at(i) {
          let lo = 0, hi = nodes.length - 1;
          while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (starts[mid] <= i) lo = mid; else hi = mid - 1; }
          return [nodes[lo], i - starts[lo]];
        }
        const hay = text.toLowerCase(), needle = query.toLowerCase(), found = [];
        for (let i = hay.indexOf(needle); i !== -1; i = hay.indexOf(needle, i + needle.length)) {
          const a = at(i), b = at(i + needle.length - 1), r = new Range();
          r.setStart(a[0], a[1]);
          r.setEnd(b[0], b[1] + 1);
          found.push(r);
        }
        return found;
      }
      window.guideFind = function (query, step) {
        if (query !== last) { ranges = collect(query); last = query; current = -1; }
        if (!ranges.length) { CSS.highlights.clear(); return [0, 0]; }
        if (current < 0) current = step < 0 ? ranges.length - 1 : 0;
        else current = (current + step + ranges.length) % ranges.length;
        CSS.highlights.set('guide-find', new Highlight(...ranges));
        CSS.highlights.set('guide-find-current', new Highlight(ranges[current]));
        const r = ranges[current].getBoundingClientRect();
        if (r.top < 40 || r.bottom > window.innerHeight - 40) window.scrollBy(0, r.top - window.innerHeight / 3);
        return [current + 1, ranges.length];
      };
      window.guideFindEnd = function () { ranges = []; last = null; current = -1; CSS.highlights.clear(); };
    })();

    """

    // MARK: WKNavigationDelegate

    /// The guide's own files open here; a link anywhere else opens in the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.isFileURL, let dir = HelpGuide.directory?.standardizedFileURL.path,
           url.standardizedFileURL.path.hasPrefix(dir + "/") {
            decisionHandler(.allow)
            return
        }
        if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}

/// The page's web view, taking the window's find keys. `performKeyEquivalent` reaches it wherever the focus is in the
/// window, the find field included, and before the menus do. No menu item holds ⌘F or ⌘G, and there is no Edit ▸ Find
/// (MEASURED, 2026-11-02: the only F items are View ▸ Enter Full Screen, fn-F, and Window ▸ Fill, fn-⌃F).
fileprivate final class GuideWebView: WKWebView {
    var onFind: (() -> Void)?
    var onFindAgain: ((_ backwards: Bool) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.window === window else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.charactersIgnoringModifiers?.lowercased(), mods) {
        case ("f", [.command]): onFind?(); return true
        case ("g", [.command]): onFindAgain?(false); return true
        case ("g", [.command, .shift]): onFindAgain?(true); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

private struct GuideWebViewHost: NSViewRepresentable {
    let webView: GuideWebView
    func makeNSView(context: Context) -> GuideWebView { webView }
    func updateNSView(_ nsView: GuideWebView, context: Context) {}
}

/// The toolbar's find field: typing finds from the top, Return the next match, ⇧Return the previous.
private struct GuideFindField: NSViewRepresentable {
    let page: GuidePage

    func makeCoordinator() -> Coordinator { Coordinator(page: page) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Find in Guide"
        field.sendsWholeSearchString = true          // the action is Return (and the clear button), never a typing pause
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submitted(_:))
        field.setAccessibilityIdentifier("guide.find")
        page.findField = field
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let page: GuidePage
        init(page: GuidePage) { self.page = page }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            page.find(field.stringValue, step: 0)
        }

        @objc func submitted(_ field: NSSearchField) {
            let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            page.find(field.stringValue, step: backwards ? -1 : 1)
        }
    }
}
