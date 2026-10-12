//
//  LiveColorOverride.swift — the colorimetry override on the live transports: the session value per
//  window, the window-title suffix's words, and the Color control (docs/COLOR_MANAGEMENT_FINDINGS.md
//  §6.9, Stage B).
//
//  WHERE THE VALUE LIVES, per transport (§6.9 decision 1):
//
//    * NDI: on `NDIService`, for the session, as before. This model only forwards to it, so NDI's
//      behaviour is unchanged.
//    * SRT: HERE, one per window (the `LiveAudioOffsetModel` pattern). Set up in
//      `DeckRegistry.connectLive`, reset to Auto on every connect, session-only until Stage D saves it
//      per bookmark. Applied through `SRTFrameRouter.setColorimetryOverride`, which tags the buffers
//      and tells the renderer from the same value (finding 10), through `setSourceColorSpace(…,
//      provenance: .overridden)` — so the chain readout and the scopes (`ScopeColorFeed`) follow it
//      with no work of their own.
//    * WHEP (Stage C) and HLS (Stage E): none yet. `offersOverride` says so, and the control is not
//      shown for them.
//
//  THE TITLE SUFFIX (decision 4): " — Color 2020 PQ" while an override is in force, on any transport,
//  NDI included (`WindowDeck.windowTitle`). Nothing is drawn over the picture.
//
//  American spelling in every user-facing word here (docs/BUGS.md, the American English entry).
//

import SwiftUI
import ColorimetryModel

// MARK: - The session value, per window

@MainActor
final class LiveColorOverrideModel: ObservableObject {
    /// The override for this window's current connect, on a transport that keeps it here (SRT).
    @Published private(set) var sessionOverride: ColorimetryOverride = .auto
    /// The transport this window last connected.
    @Published private(set) var source: LiveSource?

    private weak var deck: WindowDeck?

    init(deck: WindowDeck) { self.deck = deck }

    /// The transports with an override today. NDI's lives on NDIService, SRT's here.
    static func offersOverride(_ source: LiveSource) -> Bool {
        switch source {
        case .ndi, .srt:  return true
        case .web, .hls:  return false   // Stages C and E
        }
    }

    static func transport(_ source: LiveSource) -> ColorimetryTransport {
        switch source {
        case .ndi: return .ndi
        case .web: return .whep
        case .srt: return .srt
        case .hls: return .hls
        }
    }

    // MARK: Connect

    /// A connect is starting from this window (`DeckRegistry.connectLive`, the one funnel). Every
    /// connect starts on Auto: the override is for this connection only until Stage D.
    func prepare(source: LiveSource) {
        self.source = source
        sessionOverride = .auto
        if source == .srt {
            SRTFrameRouter.shared.setColorimetryOverride(.auto)
            NSLog("[SRT-COLOR] override → Auto (new connection)")
        }
        deck?.applyWindowTitle()
    }

    // MARK: Changes

    /// The override in force on `source` in this window.
    func current(for source: LiveSource) -> ColorimetryOverride {
        switch source {
        case .ndi:       return NDIService.shared.colorimetryOverride
        case .srt:       return self.source == .srt ? sessionOverride : .auto
        case .web, .hls: return .auto
        }
    }

    /// Ask for `override` on `source`. A preset the transport does not offer is ignored.
    func set(_ override: ColorimetryOverride, on source: LiveSource) {
        guard ColorimetryOverride.available(on: Self.transport(source)).contains(override) else { return }
        switch source {
        case .ndi:
            NDIService.shared.setColorimetryOverride(override)   // the title follows via arbitration
        case .srt:
            guard self.source == .srt, override != sessionOverride else { return }
            sessionOverride = override
            SRTFrameRouter.shared.setColorimetryOverride(override)
            if let p = override.preset {
                NSLog("[SRT-COLOR] override → %@ (CICP %d-%d-%d) — applied from the next decoded frame",
                      override.label, p.primaries, p.transfer, p.matrix)
            } else {
                NSLog("[SRT-COLOR] override → Auto — the stream’s own color from the next decoded frame")
            }
            deck?.applyWindowTitle()
        case .web, .hls:
            return
        }
    }

    /// ⌃⌥C: the next preset on this transport, wrapping to Auto.
    func cycle(on source: LiveSource?) {
        guard let source, Self.offersOverride(source) else { return }
        let all = ColorimetryOverride.available(on: Self.transport(source))
        let i = all.firstIndex(of: current(for: source)) ?? 0
        set(all[(i + 1) % all.count], on: source)
    }

    /// The window-title suffix's words while an override is in force, or nil.
    func titleSuffix(for source: LiveSource) -> String? {
        let override = current(for: source)
        return override == .auto ? nil : "Color " + override.shortLabel
    }
}

// MARK: - The Color control

struct ColorInterpretationControl: View {
    let source: LiveSource
    @ObservedObject var model: LiveColorOverrideModel
    @ObservedObject private var ndi = NDIService.shared
    @ObservedObject private var srt = SRTClient.shared

    /// Color — the color-interpretation control: how Manifold reads the incoming color, and the
    /// user's power to override that reading. This is a source-AGNOSTIC control by design. Today it
    /// hosts a single section — the live stream's colorimetry override — because stream content is
    /// all there is to interpret right now. When files gain color-management modes (Bypass /
    /// Embedded / Match-QuickTime) they become a SECOND section in this SAME menu, not a new control:
    /// file and stream are two answers to one question ("what color is this, really?"), so they
    /// belong under one "Color" roof. Build here, don't restructure later — the seam is marked below.
    ///
    /// The face states the EFFECTIVE interpretation and its tier, because the honest thing and the
    /// useful thing are the same sentence here — "709 · Assumed" tells the user both what the scopes
    /// are doing and that nobody actually verified it. The chevron (matching the streaming / DeckLink
    /// split-buttons) makes it read as a menu you OPEN, not a passive readout. An override turns the
    /// control amber: something on screen is a human assertion, not a reading, and that should never
    /// look like the neutral resting state.
    ///
    /// Most NDI senders declare nothing (OmniScope declares nothing at all), so for the common case
    /// the colorimetry section is not a corner-case escape hatch — it is how the stream's colorimetry
    /// gets set.
    ///
    /// Moved out of ContentView for Stage B (§6.9), when it gained SRT: one element there, no
    /// modifiers (§6.7). The body below is unchanged; only where it reads the colorimetry from moved
    /// (`reading`, per transport).
    var body: some View {
        // Two-part split face mirroring the streaming / DeckLink controls: a readout element + a
        // lone-chevron menu. The chevron MUST be its own borderlessButton Menu label, not the
        // trailing item of a multi-element label — `.menuStyle(.borderlessButton)` reserves and
        // clips a trailing region for its disclosure indicator, and `.menuIndicator(.hidden)` hides
        // the drawn arrow but not the clip, so a chevron sitting at a rich label's trailing edge is
        // swallowed (the 3b bug: palette + text showed, chevron didn't). A lone chevron sits at its
        // label's leading edge with only empty, harmlessly-clipped space after it — which is exactly
        // why the streaming / DeckLink chevrons render. Both halves open the SAME presets, so the
        // whole face stays clickable; the readout half also reads the effective colorimetry + tier.
        //
        // ⚠️ THE AMBER IS APPLIED TO THE LEAF `Text`s, AND `Image` IS WRAPPED IN ONE — MEASURED.
        //
        // `.foregroundStyle(…)` on this HStack is what the code used to do, and §6.8 measured the
        // result: **max(r − b) = 0 across the whole face** while the label read "Overridden".
        // `.menuStyle(.borderlessButton)` strips a LABEL's foreground, exactly as it strips a
        // label's background (§6.8's Bypass-badge defect), and the control bar's own white wins.
        //
        // Five alternatives were measured in an isolated harness before this one was written:
        // `.foregroundStyle` inside the label (STRIPPED — white), `.foregroundColor` on the
        // leaves (the `Text` colours, the `Image` does NOT — a half-orange control), `.tint` on
        // the Menu (colours both — but it also repaints the menu's own SELECTION HIGHLIGHT, which
        // is the system accent's job), `HStack { Text(Image); Text }` (colours both and then
        // **SWALLOWS THE TEXT ENTIRELY** — see below), and ONE CONCATENATED `Text`, which is what
        // is here: it colours, it keeps its sizes, and it leaves the menu's accent alone.
        //
        // ⚠️ THE SWALLOWED-TEXT TRAP IS THE ONE ALREADY DOCUMENTED ABOVE, FROM THE OTHER SIDE.
        // The note on the chevron says a borderless menu "reserves and clips a trailing region
        // for its disclosure indicator", so a chevron at a rich label's trailing edge disappears.
        // Wrapping the symbol in a `Text` turns this label into a MIXED one — a text-like element
        // beside a view — and the same clip then eats the READOUT instead. Measured: the face
        // dropped from 214 pt wide to 28, the glyph alone. A single `Text` is not a mixed label,
        // so it is not clipped; the per-run `.font` keeps the glyph at its old size and the
        // readout in the same monospaced caption.
        HStack(spacing: 2) {
            Menu {
                colorStreamColorimetrySection
            } label: {
                (Text(Image(systemName: "paintpalette")).font(.system(size: 13))
                 + Text("  ")
                 + Text(faceLabel).font(.system(.caption, design: .monospaced)))
                    .foregroundColor(colorControlTint)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            // The interactive affordance — same size-8 chevron.down as the streaming / DeckLink
            // controls, so the control reads as a menu you open, not a passive readout.
            Menu {
                colorStreamColorimetrySection
                // SEAM: a future file color-management section (Bypass / Embedded / Match-QuickTime)
                // drops into colorStreamColorimetrySection's peer set — same menu, same control —
                // when files gain those modes. Nothing is stubbed today (an inert row would read as
                // broken); the structure is simply ready.
            } label: {
                Text(Image(systemName: "chevron.down")).font(.system(size: 8))
                    .foregroundColor(colorControlTint)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .help("Color interpretation — Auto trusts the stream; a preset asserts it (⌃⌥C cycles)")
    }


    /// Amber when something on screen is a human assertion rather than a reading, the control
    /// bar's own white otherwise. Applied per leaf — see the note on `body`.
    private var colorControlTint: Color {
        reading?.effective.isOverridden == true ? Color.orange : .white.opacity(0.9)
    }

    /// The live stream's colorimetry override — the one color-interpretation section with content
    /// today. Presets assert a colorimetry; the "Stream" subsection keeps the sender's own claim
    /// visible so an override reads as CONTRADICTING a declaration rather than filling a silence.
    @ViewBuilder private var colorStreamColorimetrySection: some View {
        Section("Colorimetry") {
            Picker("Colorimetry", selection: overrideBinding) {
                ForEach(ColorimetryOverride.available(on: LiveColorOverrideModel.transport(source))) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)
        }
        Section("Stream") {
            Button(streamStatusLine) {}.disabled(true)
        }
    }

    /// What the renderer has been told (`effective`) and what the stream said (`declared`). NDI's from
    /// NDIService; SRT's from SRTClient, which publishes the reading with the override applied. nil on
    /// SRT until the first SPS has been read.
    private var reading: (effective: SourceColorimetry, declared: SourceColorimetry)? {
        switch source {
        case .ndi: return (ndi.colorInfo, ndi.declaredColorInfo)
        case .srt: return srt.colorimetry.map { ($0.bufferTags, $0.declaredTags) }
        case .web, .hls: return nil
        }
    }

    /// Effective colorimetry + tier: "2020 PQ · Overridden", "709 · Assumed", "709 · Declared".
    private var faceLabel: String {
        guard let info = reading?.effective else { return "— · Waiting for the stream" }
        return "\(SourceColorimetry.primariesName(info.primaries.code).replacingOccurrences(of: "Rec.", with: "")) "
             + "\(SourceColorimetry.transferName(info.transfer.code).replacingOccurrences(of: "Rec.", with: "")) · \(info.tier)"
    }

    /// The stream's own claim, independent of the override — an absence stated as an absence.
    private var streamStatusLine: String {
        guard let d = reading?.declared else { return "Has not stated its color yet" }
        guard d.isDeclared else { return "Declares no colorimetry" }
        return "Declares \(SourceColorimetry.primariesName(d.primaries.code)) · "
             + "\(SourceColorimetry.transferName(d.transfer.code)) · "
             + "\(SourceColorimetry.matrixName(d.matrix.code))"
    }

    private var overrideBinding: Binding<ColorimetryOverride> {
        Binding(get: { model.current(for: source) },
                set: { model.set($0, on: source) })
    }
}
