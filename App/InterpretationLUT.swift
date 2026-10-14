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
//  the title suffix, the amber face and the refusal banner are L3. A refusal here is an alert sheet.
//
//  THE PARSE AND THE GPU BUILD RUN OFF THE MAIN THREAD, then one main-thread call hands the finished install
//  to the renderer, which parks it with the colour state for the render thread. A load that fails at any step
//  installs nothing, and the LUT already applied stays applied (`CubeLUT.parse` is whole-file-or-nothing).
//

import AppKit
import Combine
import UniformTypeIdentifiers
import LUTCube

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

    private var lut: CubeLUT?
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
        (lut, name, shape) = (nil, nil, nil)
        deck?.renderer?.setInterpretationLUT(nil)
    }

    // MARK: Loading

    func load(_ url: URL) {
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
                    (self.lut, self.name, self.shape) = (l, fileName, l.shapeDescription)
                    NSLog("[LUT] loaded %@ — %@ · %@ (%@)", fileName, l.shapeDescription, mode.rawValue, timing)
                    for line in l.ignored {
                        NSLog("[LUT] %@: line %d, keyword “%@” not recognised — ignored", fileName, line.line, line.keyword)
                    }
                    renderer.setInterpretationLUT(install)
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
                renderer.setInterpretationLUT(install)
            }
        }
    }

    /// Nothing was loaded; say so, and what is still applied. L3 replaces this sheet with the banner.
    private func refuse(_ fileName: String, because reason: String) {
        let still = name.map { "“\($0)” is still applied." } ?? "No LUT is applied."
        NSLog("[LUT] nothing loaded from %@; %@", fileName, still)
        let alert = NSAlert()
        alert.messageText = "Couldn’t load “\(fileName)”"
        alert.informativeText = reason + " Nothing was loaded. " + still
        alert.alertStyle = .warning
        if let window = deck?.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
