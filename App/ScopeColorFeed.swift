//
//  ScopeColorFeed.swift — the scope headers' source colour, for ONE window.
//
//  The scope MATHS has always read the renderer's source codes (`computeWaveformGPU`,
//  `computeVectorscopeGPU`, `computeCIEGPU`). The scope HEADERS — the matrix labels, the waveform and
//  parade AUTO ruler (SDR code values vs PQ nits vs HLG), the vectorscope's source-primaries boxes and
//  the CIE header text — read six fields on the scope models, and until 2026-10-06 those were written
//  per transport: from the file's metadata, from NDI's colour info, from SRT's colorimetry. WHEP and
//  HLS never wrote them, nothing reset them when a source ended, and opening the tray during a live
//  stream reloaded them from the window's last FILE. So the headers routinely described a source
//  that had gone — an NDI PQ override left the waveform on a PQ (nits) ruler over a WHEP 709 picture.
//
//  This is now the ONLY writer of those six fields, and it reads only the renderer: the codes and the
//  provenance every source already states through `setSourceColorSpace`, announced by
//  `sourceColorStateDidChange`. A new transport, or a colorimetry override, reaches the headers by
//  reaching the renderer — there is nothing per transport to wire and therefore nothing to forget.
//  CLAUDE.md states the rule.
//
//  ⚠️ NO `.onChange` IN `ContentView` — that body is at the type-checker's limit (§6.7). This binds
//  from the `.onAppear` that already exists, and observes NotificationCenter, exactly as
//  `DisplayChainModel.bind` does.
//

import AppKit
import SwiftUI
import ManifoldCore

@MainActor
final class ScopeColorFeed: ObservableObject {

    private weak var deck: WindowDeck?
    private weak var waveform: WaveformScopeModel?
    private weak var parade: ParadeScopeModel?
    private weak var vectorscope: VectorscopeScopeModel?
    private weak var cie: CIEScopeModel?
    private var observers: [NSObjectProtocol] = []

    /// What was last written to the models. A post that changes none of it — a range-only
    /// announcement, a re-assert — writes and logs nothing.
    private struct Written: Equatable {
        let primaries: Int?
        let transfer: Int?
        let matrix: Int?
        let provenance: SourceColorProvenance
    }
    private var written: Written?

    // MARK: Binding

    /// Attach to a window's deck and its scope models. Idempotent: a second `.onAppear` must not
    /// stack observers.
    ///
    /// ⚠️ OBSERVES UNFILTERED AND COMPARES THE RENDERER IN THE HANDLER — `DisplayChainModel.bind`'s
    /// reasoning: `deck.renderer` is a plain stored property populated by `WindowDeckRegistrar`, not
    /// necessarily in place when `.onAppear` runs, so it is resolved at delivery time.
    func bind(deck: WindowDeck, waveform: WaveformScopeModel, parade: ParadeScopeModel,
              vectorscope: VectorscopeScopeModel, cie: CIEScopeModel) {
        self.deck = deck
        self.waveform = waveform
        self.parade = parade
        self.vectorscope = vectorscope
        self.cie = cie
        guard observers.isEmpty else { refresh(trigger: "bind"); return }

        observers.append(NotificationCenter.default.addObserver(
            forName: MetalVideoRenderer.sourceColorStateDidChange, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let r = note.object as? MetalVideoRenderer,
                      r === self.deck?.renderer else { return }
                self.refresh(trigger: "source")
            }
        })
        // The live source has gone: blank the traces. Its colour was cleared just before this, so
        // the headers already read the cleared state. The models stay active and resume when the
        // next source renders — `clear()`'s own contract.
        observers.append(NotificationCenter.default.addObserver(
            forName: MetalVideoRenderer.liveSourceDidRelease, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let r = note.object as? MetalVideoRenderer,
                      r === self.deck?.renderer else { return }
                self.waveform?.clear()
                self.parade?.clear()
                self.vectorscope?.clear()
                self.cie?.clear()
                NSLog("[SCOPE-COLOR] released: traces blanked")
            }
        })
        refresh(trigger: "bind")
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: Write

    /// Write the six scope fields from the renderer's source colour. Called on every colour
    /// announcement, on bind, and by `updateScopeSampling` when a scope (re)starts.
    func refresh(trigger: String = "reseed") {
        guard let renderer = deck?.renderer else { return }
        let now = Written(primaries: renderer.sourcePrimariesCode,
                          transfer: renderer.sourceTransferCode,
                          matrix: renderer.sourceMatrixCode,
                          provenance: renderer.sourceColorProvenance)
        guard now != written else { return }
        written = now

        waveform?.sourceMatrixCode = now.matrix
        waveform?.sourceTransferCode = now.transfer
        parade?.sourceTransferCode = now.transfer
        vectorscope?.sourceMatrixCode = now.matrix
        vectorscope?.sourcePrimariesCode = now.primaries
        let header = Self.cieHeader(primaries: now.primaries, transfer: now.transfer,
                                    provenance: now.provenance)
        cie?.spaceReadout = header

        func code(_ c: Int?) -> String { c.map(String.init) ?? "–" }
        NSLog("[SCOPE-COLOR] %@: %@  (CICP %@-%@-%@)", trigger, header,
              code(now.primaries), code(now.transfer), code(now.matrix))
    }

    /// The CIE header: the chain readout's names for the curve the renderer is USING (an absent
    /// axis prints its resolved 709, not a dash — §6.8's rule) plus the one tier word the chain
    /// readout prints. "Rec. 2020 · PQ (ST 2084) — overridden". Per-axis provenance is not carried:
    /// the renderer's tier is per source (accepted 2026-10-06).
    static func cieHeader(primaries: Int?, transfer: Int?,
                          provenance: SourceColorProvenance) -> String {
        "\(MediaInspector.primariesName(forCode: primaries ?? 1)) · "
            + "\(MediaInspector.transferName(forCode: transfer ?? 1)) — \(provenance.label)"
    }
}
