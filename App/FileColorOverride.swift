//
//  FileColorOverride.swift — the colour interpretation override for FILES, per window (colour S5,
//  docs/COLOR_MANAGEMENT_FINDINGS.md §6.11, decisions 6 and 7).
//
//  DECIDED (Robbie, 2026-10-13): per window, reset to Auto when a new file opens, not remembered per file.
//
//  WHERE IT SITS. Between the file's own tags and the one colour setter. Both places a file's tags reach
//  the renderer — the engine's load edge (`FrameEngine.onSourceColorTags`, wired in `DeckRegistry.configure`)
//  and `ContentView`'s metadata observer — hand them HERE, and this model makes the single
//  `setSourceColorSpace` call: the file's codes on Auto, the override's with `.overridden` otherwise. So the
//  picture (the renderer decodes an override's matrix itself), the layer, the scopes (`ScopeColorFeed`), the
//  SDI tag (re-tagged below) and the readout all move on one call, as CLAUDE.md's source-colour rule asks.
//
//  ⚠️ THE METADATA OBSERVER MUST COME THROUGH HERE TOO. It re-asserts the file's codes after inspection;
//  called straight on the renderer with `.fromCodes` it is not the no-op it used to be — the provenance
//  differs — and it would quietly undo an override made before inspection finished.
//

import AppKit
import ColorimetryModel

@MainActor
final class FileColorOverrideModel: ObservableObject {
    /// The override in force on this window's file. Auto = the file's own tags.
    @Published private(set) var override: ColorimetryOverride = .auto
    /// The file's own codes, as its container states them (nil = not stated), from the last tag edge.
    @Published private(set) var declared: (primaries: Int?, transfer: Int?, matrix: Int?) = (nil, nil, nil)

    private weak var deck: WindowDeck?

    init(deck: WindowDeck) { self.deck = deck }

    /// A file is on this deck and no live source owns it — the case this model speaks for.
    var isActive: Bool {
        guard let deck, deck.engine?.currentURL != nil else { return false }
        return DeckRegistry.shared.liveSource(for: deck) == nil
    }

    // MARK: Edges

    /// The engine committed a new file (`FrameEngine.onSourceCommitted`), before its tags arrive.
    func fileCommitted(_ url: URL) {
        guard override != .auto else { return }
        NSLog("[FILE-COLOR] override → Auto (new file: %@)", url.lastPathComponent)
        override = .auto
        deck?.applyWindowTitle()
    }

    /// The file's own tags, from either edge. Applied under the override in force.
    func fileTags(primaries: Int?, transfer: Int?, matrix: Int?) {
        declared = (primaries, transfer, matrix)
        // Unload (`stop()` clears `currentURL` before it publishes nils): nothing to interpret.
        if deck?.engine?.currentURL == nil, override != .auto {
            override = .auto
            deck?.applyWindowTitle()
        }
        apply()
    }

    // MARK: Changes

    /// Ask for `override` on this window's file. A Custom triple outside the S3 table never gets here
    /// (`ColorimetryOverride.customIfSupported`); a stray one is refused all the same.
    func set(_ new: ColorimetryOverride) {
        guard isActive, new != override else { return }
        if new.isCustom, let t = new.preset, !CustomColorimetry.isSupported(t) { return }
        override = new
        if let p = new.preset {
            NSLog("[FILE-COLOR] override → %@ (CICP %d-%d-%d)", new.label, p.primaries, p.transfer, p.matrix)
        } else {
            NSLog("[FILE-COLOR] override → Auto — the file’s own tags")
        }
        apply()
        deck?.applyWindowTitle()
    }

    /// The Reset item: back to the file's own tags, at once.
    func reset() { set(.auto) }

    /// ⌃⌥C on a file: the next preset, wrapping to Auto. From Custom it goes to the first preset after Auto.
    func cycle() {
        let all = ColorimetryOverride.allCases
        let i = all.firstIndex(of: override) ?? 0
        set(all[(i + 1) % all.count])
    }

    /// The codes on screen: the override's, or the file's own (nil → the renderer's 709 default).
    var effective: (primaries: Int, transfer: Int, matrix: Int) {
        override.preset ?? (declared.primaries ?? 1, declared.transfer ?? 1, declared.matrix ?? 1)
    }

    /// The window-title suffix's words while an override is in force on the file, or nil.
    var titleSuffix: String? {
        isActive && override != .auto ? "Color " + override.shortLabel : nil
    }

    // MARK: The one call

    private func apply() {
        guard let deck, let renderer = deck.renderer else { return }
        if let p = override.preset {
            renderer.setSourceColorSpace(primaries: p.primaries, transfer: p.transfer, matrix: p.matrix,
                                         provenance: .overridden)
        } else {
            let d = declared
            renderer.setSourceColorSpace(primaries: d.primaries, transfer: d.transfer, matrix: d.matrix,
                                         provenance: .fromCodes(primaries: d.primaries, transfer: d.transfer,
                                                                matrix: d.matrix))
        }
        // The readout's label can change with no code moving (Custom 9·14·9 is the Rec.2020 SDR preset's
        // triple), when `setSourceColorSpace` is a no-op; say so anyway. Cheap, main thread.
        renderer.sourceColorStateChanged()
        // The SDI tag, from the renderer's codes, as the metadata observer does for a load. Only for the
        // deck the card follows.
        if deck.gate.drivesDevices { DeckLinkService.shared.sourceColorChanged() }
    }
}
