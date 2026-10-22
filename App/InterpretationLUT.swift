//
//  InterpretationLUT.swift — the window's Interpretation LUT (colour S6, L1;
//  docs/COLOR_MANAGEMENT_FINDINGS.md §6.11, *S6 — LUT: audit, decisions and plan*).
//
//  DECIDED (Robbie, 2026-10-12/13): one LUT slot per window, in Interpretation, so the window, scopes, SDI and
//  export all see it (decision 4); kept across source changes, cleared at quit (decision 5: it lives here, in
//  memory, and nothing saves it); trilinear and tetrahedral as an app-wide setting, default tetrahedral (D1).
//
//  L1 IS MINIMAL ON PURPOSE. Load LUT… and Remove LUT in the Interpretation menu, and the interpolation
//  setting. The output space is the source's (no tag moves until L2); Recent LUTs, Bypass, the readout line,
//  the title suffix, the amber face and the refusal banner are L3 (below; L1's alert sheet is gone).
//
//  L2 (D3, D4): the OUTPUT SPACE. Same as Source (the default, and where a load starts unless Recent LUTs
//  remember one for that file), a preset, or Custom. It is handed to the renderer with the LUT, through
//  `setInterpretationLUT`, which makes it the picture's codes: the layer, EDR, scopes, SDI tag, v210 matrix,
//  export ICC, Reference and CIE follow it, and the Source line does not.
//
//  L3 (D4, D6, D7): RECENT LUTS remember each file's path, bookmark and output space (`RecentLUTStore`, one
//  defaults key, never written over when unreadable); BYPASS LUT keeps the LUT loaded and hands the renderer no
//  LUT, so a bypassed window is the no-LUT path by construction, and un-bypassing hands back the same install
//  object; the READOUT LINE (`readoutLine`, the chain readout and the menu), the TITLE SUFFIX (`titleSuffix`) and
//  the face's "+ LUT" (`faceSuffix`); a REFUSAL is the window's banner (`engine.playbackNotice`, the slot the
//  Color control's other notices use), and the LUT already applied stays applied.
//
//  THE PARSE AND THE GPU BUILD RUN OFF THE MAIN THREAD, then one main-thread call hands the finished install
//  to the renderer, which parks it with the colour state for the render thread. A load that fails at any step
//  installs nothing, and the LUT already applied stays applied (`CubeLUT.parse` is whole-file-or-nothing).
//

import AppKit
import Combine
import UniformTypeIdentifiers
import LUTCube
import ColorimetryModel   // ColorimetryOverride, PictureCodes: the output space (L2)

/// D1: trilinear or tetrahedral, for every window. Stored only once the user chooses: until then the key is
/// absent and the default (tetrahedral) applies.
@MainActor
final class LUTInterpolationSetting: ObservableObject {
    static let shared = LUTInterpolationSetting()
    static let defaultsKey = "lutInterpolation"

    @Published var interpolation: CubeInterpolation {
        didSet {
            guard interpolation != oldValue else { return }
            UserDefaults.standard.set(interpolation.rawValue, forKey: Self.defaultsKey)
            NSLog("[LUT] interpolation → %@ (every window)", interpolation.rawValue)
        }
    }

    private init() {
        interpolation = UserDefaults.standard.string(forKey: Self.defaultsKey)
            .flatMap(CubeInterpolation.init(rawValue:)) ?? .default
    }
}

@MainActor
final class InterpretationLUTModel: ObservableObject {
    /// The loaded LUT's file name, or nil.
    @Published private(set) var name: String?
    /// `3D 33³`, `3D 33³ + 1D 4096 shaper`, … for the menu's section title.
    @Published private(set) var shape: String?
    /// L2 (D4): the LUT's stated output space; `.auto` = Same as Source. Reset to Same as Source by a new load
    /// and by Remove; kept by an interpolation change.
    @Published private(set) var outputSpace: ColorimetryOverride = .auto
    /// L3 (D6): loaded but not applied. The renderer holds no LUT while this is set; `install` keeps it.
    @Published private(set) var bypassed = false

    private var lut: CubeLUT?
    /// The built LUT, kept here so Bypass can take it off the renderer and put the SAME object back.
    private var install: InterpretationLUTInstall?
    /// The file it came from: Recent LUTs remember its output space by this path.
    private var url: URL?
    private weak var deck: WindowDeck?
    /// Each load or rebuild takes a number; a result that arrives after a newer request is dropped.
    private var generation = 0
    private var interpolationWatch: AnyCancellable?

    init(deck: WindowDeck) {
        self.deck = deck
        interpolationWatch = LUTInterpolationSetting.shared.$interpolation.dropFirst()
            .sink { [weak self] mode in self?.rebuild(mode) }
    }

    // MARK: Menu actions

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Load LUT"
        panel.prompt = "Load"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.load(url)
        }
        if let window = deck?.window { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    func remove() {
        generation += 1
        guard lut != nil else { return }
        (lut, install, url, name, shape, outputSpace, bypassed) = (nil, nil, nil, nil, nil, .auto, false)
        NSLog("[LUT] removed")
        push()
    }

    /// L3 (D6): Bypass LUT. The LUT stays loaded; the renderer is handed no LUT, so the picture, the tags and the
    /// exports are the no-LUT path's. Off again: the same install and output space go back.
    func setBypassed(_ on: Bool) {
        guard lut != nil, on != bypassed else { return }
        bypassed = on
        NSLog("[LUT] %@ %@", on ? "bypassed —" : "applied again —", name ?? "")
        push()
    }

    /// L2 (D4): state the LUT's output space. Only with a LUT loaded: without one there is no picture for it to
    /// describe (the menu greys it). A Custom outside the S3 table is never built by the menu, and refused here.
    func setOutputSpace(_ space: ColorimetryOverride) {
        guard lut != nil, space != outputSpace else { return }
        if let t = space.preset, space.isCustom, !CustomColorimetry.isSupported(t) { return }
        outputSpace = space
        if let url { RecentLUTStore.shared.setOutputSpace(space, for: url) }
        push()
    }

    /// Hand the renderer what is in force — the install and its output space, or nothing while bypassed — then
    /// everything that describes it: SDI's tag for the deck the card follows (as the file override does), the
    /// title, and one colour announcement so the chain readout's LUT line and the scope headers re-read even
    /// when no picture code moved (a Bypass at Same as Source moves none).
    private func push() {
        guard let deck else { return }
        if let renderer = deck.renderer {
            renderer.setInterpretationLUT(bypassed ? nil : install, outputSpace: bypassed ? .auto : outputSpace)
            renderer.sourceColorStateChanged()
        }
        if deck.gate.drivesDevices { DeckLinkService.shared.sourceColorChanged() }
        deck.applyWindowTitle()
    }

    // MARK: Words (L3)

    /// The readout line (D7), for the chain readout's LUT row, the menu and the `[CHAIN] LUT` log. nil with no LUT.
    var readoutLine: String? {
        guard let lut, let name else { return nil }
        return LUTReadout.line(name: name, lut: lut, interpolation: install?.interpolation ?? LUTInterpolationSetting.shared.interpolation,
                               outputLabel: outputSpace == .auto ? nil : outputSpace.label,
                               bypassed: bypassed, sourcePresent: deck?.hasSource ?? false)
    }

    /// The window title's words: "LUT name.cube", "LUT name.cube (bypassed)". nil with no LUT.
    var titleSuffix: String? { name.map { "LUT " + $0 + (bypassed ? " (bypassed)" : "") } }

    /// The Color control's face: " + LUT" while applied (amber). Empty while bypassed and with no LUT; a bypassed
    /// LUT's words are `faceBypassedWords`, drawn in their own style.
    var faceSuffix: String { isApplied ? " + LUT" : "" }

    /// "LUT bypassed" while bypassed, else nil. Drawn struck through and dimmed, so the face tells bypassed apart from
    /// applied (amber) and from none (no words) — LG session, 2026-10-22: " + LUT off" read as "bypass of what?".
    var faceBypassedWords: String? { name != nil && bypassed ? "LUT bypassed" : nil }

    /// A LUT is changing the picture: the face turns amber, as an override does.
    var isApplied: Bool { lut != nil && !bypassed }

    // MARK: Loading

    /// Load `url`. Its output space is the one Recent LUTs remember for that file (D4), else Same as Source.
    func load(_ url: URL) {
        SessionPaths.note(url)   // for the diagnostics redactor (privacy P1)
        generation += 1
        let gen = generation
        guard let renderer = deck?.renderer else { return }
        let mode = LUTInterpolationSetting.shared.interpolation
        let fileName = url.lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = CFAbsoluteTimeGetCurrent()
            let offMain = !Thread.isMainThread
            let result = Result { try CubeLUT.load(contentsOf: url) }
            let parsed = CFAbsoluteTimeGetCurrent() - t0
            var install: InterpretationLUTInstall?
            if case .success(let l) = result { install = renderer.makeLUTInstall(l, name: fileName, interpolation: mode) }
            let built = CFAbsoluteTimeGetCurrent() - t0 - parsed
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else {
                    NSLog("[LUT] %@ — superseded by a newer request, dropped", fileName); return
                }
                let timing = String(format: "parsed %@ in %.3f s, GPU tables %.3f s",
                                    offMain ? "off the main thread" : "ON THE MAIN THREAD", parsed, built)
                switch result {
                case .success(let l):
                    guard let install else { self.refuse(fileName, because: "Metal could not build it (the log has the reason)."); return }
                    // The output space Recent LUTs remember for this file (D4), else Same as Source. A new load is
                    // applied, whatever the previous LUT's Bypass was.
                    let space = RecentLUTStore.shared.outputSpace(for: url)
                    (self.lut, self.install, self.url, self.name, self.shape, self.outputSpace, self.bypassed)
                        = (l, install, url, fileName, l.shapeDescription, space, false)
                    NSLog("[LUT] loaded %@ — %@ · %@ (%@)", fileName, l.shapeDescription, mode.rawValue, timing)
                    if space != .auto { NSLog("[LUT] %@: output space %@, remembered by Recent LUTs", fileName, space.label) }
                    for line in l.ignored {
                        NSLog("[LUT] %@: line %d, keyword “%@” not recognised — ignored", fileName, line.line, line.keyword)
                    }
                    RecentLUTStore.shared.record(url, outputSpace: space)
                    self.push()
                case .failure(let error):
                    let message = (error as? CubeLUTError)?.message ?? "\(error)"
                    NSLog("[LUT] refused %@: %@ (%@)", fileName, message, timing)
                    self.refuse(fileName, because: message)
                }
            }
        }
    }

    /// Interpolation changed (D1, app-wide): the same table, a new pipeline.
    private func rebuild(_ mode: CubeInterpolation) {
        guard let lut, let fileName = name, let renderer = deck?.renderer else { return }
        generation += 1
        let gen = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let install = renderer.makeLUTInstall(lut, name: fileName, interpolation: mode)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation, let install else { return }
                self.install = install
                self.push()
            }
        }
    }

    /// Nothing was loaded; say so, and what is still applied, in the window's banner (L3; the slot the Color
    /// control's other notices use, `engine.playbackNotice`). Non-blocking, auto-dismissed, never a sheet.
    private func refuse(_ fileName: String, because reason: String) {
        let still = name.map { "“\($0)” is still " + (bypassed ? "loaded (bypassed)." : "applied.") } ?? "No LUT is applied."
        let text = "Couldn’t load “\(fileName)”: " + reason + " Nothing was loaded. " + still
        NSLog("[LUT] banner: %@", text)
        guard let engine = deck?.engine else { NSLog("[LUT] ⚠️ no engine on this window — the refusal is in the log only"); return }
        engine.playbackNotice = text
    }
}

// MARK: - Recent LUTs (L3, D4)

/// The Recent LUTs list, for every window: one defaults key (`RecentLUTList.defaultsKey`), newest first, each with
/// its path, plain bookmark data and stated output space.
///
/// ⚠️ READ BEFORE EVERY WRITE, AND NEVER WRITE OVER WHAT WAS NOT READ (CLAUDE.md's defaults rule). Each change
/// re-reads the stored value; when it does not decode (`RecentLUTList.decode` → nil) nothing is written, the log
/// says so, and the menu lists nothing. A missing file is listed, greyed, and never crashes a load.
@MainActor
final class RecentLUTStore: ObservableObject {
    static let shared = RecentLUTStore()

    struct Row: Identifiable, Equatable {
        let entry: RecentLUTEntry
        /// The file as its bookmark resolves now, else its path if that exists; nil = missing.
        let url: URL?
        var id: String { entry.path }
        var title: String {
            let shown = url?.lastPathComponent ?? entry.fileName
            let folder = ((url?.path ?? entry.path) as NSString).deletingLastPathComponent
            return "\(shown) — " + (url == nil ? "missing" : (folder as NSString).lastPathComponent)
                + (entry.outputSpace.map { " · out " + ColorimetryOverride(storageID: $0).shortLabel } ?? "")
        }
    }

    @Published private(set) var rows: [Row] = []
    private var activation: NSObjectProtocol?

    private init() {
        reload()
        // A file can come back (a volume mounted) or go while the app is in the background.
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// The stored list, or nil when it is not one this version reads (logged).
    private func read() -> [RecentLUTEntry]? {
        let stored = UserDefaults.standard.object(forKey: RecentLUTList.defaultsKey)
        guard let entries = RecentLUTList.decode(stored) else {
            NSLog("[LUT] ⚠️ the stored Recent LUTs (%@) is not a list this version reads — left as it is, nothing written",
                  RecentLUTList.defaultsKey)
            return nil
        }
        return entries
    }

    private func write(_ entries: [RecentLUTEntry]) {
        if entries.isEmpty {
            UserDefaults.standard.removeObject(forKey: RecentLUTList.defaultsKey)
        } else {
            UserDefaults.standard.set(RecentLUTList.encode(entries), forKey: RecentLUTList.defaultsKey)
        }
        reload()
    }

    func reload() {
        let next = (read() ?? []).map { Row(entry: $0, url: Self.resolve($0)) }
        if next != rows { rows = next }
    }

    /// A successful load: to the front, with its bookmark and output space.
    func record(_ url: URL, outputSpace: ColorimetryOverride) {
        guard let entries = read() else { return }
        let bookmark: Data?
        do { bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
        catch { bookmark = nil; NSLog("[LUT] Recent LUTs: no bookmark for %@ (%@) — the path alone is kept", url.lastPathComponent, "\(error)") }
        write(RecentLUTList.inserting(RecentLUTEntry(path: url.path, bookmark: bookmark, outputSpace: outputSpace.storageID),
                                      into: entries))
    }

    func setOutputSpace(_ space: ColorimetryOverride, for url: URL) {
        guard let entries = read(), RecentLUTList.entry(forPath: url.path, in: entries) != nil else { return }
        write(RecentLUTList.settingOutputSpace(space.storageID, forPath: url.path, in: entries))
    }

    /// The output space remembered for `url`, else Same as Source.
    func outputSpace(for url: URL) -> ColorimetryOverride {
        guard let entries = read(), let e = RecentLUTList.entry(forPath: url.path, in: entries) else { return .auto }
        return ColorimetryOverride(storageID: e.outputSpace)
    }

    /// Clear Menu.
    func clear() {
        guard let entries = read(), !entries.isEmpty else { return }
        NSLog("[LUT] Recent LUTs cleared (%d)", entries.count)
        write([])
    }

    /// The bookmark first (it follows a moved file), else the path; nil when neither names a file that exists.
    /// `.withoutMounting`: a menu must never mount a volume.
    private static func resolve(_ e: RecentLUTEntry) -> URL? {
        if let data = e.bookmark {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return FileManager.default.fileExists(atPath: e.path) ? URL(fileURLWithPath: e.path) : nil
    }
}
