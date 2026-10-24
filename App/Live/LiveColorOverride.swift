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
//      `DeckRegistry.connectLive` from the bookmark the stream was connected from (Stage D), or Auto
//      for anything without one. Applied through `SRTFrameRouter.setColorimetryOverride`, which tags the buffers
//      and tells the renderer from the same value (finding 10), through `setSourceColorSpace(…,
//      provenance: .overridden)` — so the chain readout and the scopes (`ScopeColorFeed`) follow it
//      with no work of their own.
//    * WHEP (Stage C): HERE too, the same way, through `WHEPFrameRouter.setColorimetryOverride`.
//    * HLS (Stage E): HERE too, through `HLSClient.setColorimetryOverride`. HLS re-reads the stream's
//      colour from every frame, so the override wins inside `publishColorTagsIfChanged`, over a
//      rendition change, and every vended frame is re-tagged. An HLS→HLS swap is a new connect: it
//      starts on the NEW bookmark's saved value, or Auto (decided 2026-10-12, §6.9 Stage E).
//
//  SAVE TO BOOKMARK (Stage D, decision 5): Save and Revert in the Color control's menu, as the audio
//  offset's are in the A/V menu. Nothing else writes it; the Stream Sources sheet has no field. Stored as
//  `StreamBookmark.colorOverride` (`ColorimetryOverride.storageID`), Auto as absent. NDI has no bookmark
//  and stays session-only.
//
//  THE TITLE SUFFIX (decision 4): " — Color 2020 PQ" while an override is in force, on any transport,
//  NDI included (`WindowDeck.windowTitle`). Nothing is drawn over the picture.
//
//  COLOUR S5 (§6.11, decision 7): Custom — `.custom(p, t, m)`, three pickers — on every transport, saved
//  per bookmark as `custom:p-t-m` in the same field; a Reset item at the top of the menu; and the same
//  control for files (`ColorInterpretationSlot`, `FileColorOverride.swift`).
//
//  American spelling in every user-facing word here (docs/BUGS.md, the American English entry).
//

import SwiftUI
import ShortcutRegistry
import ColorimetryModel
import StreamBookmarkModel
import LUTCube   // colour S6: CubeInterpolation, for the LUT section

// MARK: - The session value, per window

@MainActor
final class LiveColorOverrideModel: ObservableObject {
    /// The override for this window's current connect, on a transport that keeps it here (SRT).
    @Published private(set) var sessionOverride: ColorimetryOverride = .auto
    /// The transport this window last connected.
    @Published private(set) var source: LiveSource?
    /// The bookmark this connect came from, and its saved override at connect or at the last save
    /// (Auto when it has none, or one this transport does not offer).
    @Published private(set) var bookmarkID: UUID?
    @Published private(set) var bookmarkName: String?
    @Published private(set) var savedOverride: ColorimetryOverride = .auto

    private weak var deck: WindowDeck?

    init(deck: WindowDeck) { self.deck = deck }

    /// The transports with an override. NDI's lives on NDIService, SRT's, WHEP's and HLS's here.
    static func offersOverride(_ source: LiveSource) -> Bool {
        switch source {
        case .ndi, .srt, .web, .hls: return true
        }
    }

    /// The log tag for a transport whose override is held here.
    private static func logTag(_ source: LiveSource) -> String? {
        switch source {
        case .srt: return "SRT-COLOR"
        case .web: return "WHEP-COLOR"
        case .hls: return "HLS-COLOR"
        case .ndi: return nil
        }
    }

    /// Hand the override to the transport that applies it.
    private static func apply(_ override: ColorimetryOverride, on source: LiveSource) {
        switch source {
        case .srt: SRTFrameRouter.shared.setColorimetryOverride(override)
        case .web: WHEPFrameRouter.shared.setColorimetryOverride(override)
        case .hls: HLSClient.shared.setColorimetryOverride(override)
        case .ndi: break
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

    /// A connect is starting from this window (`DeckRegistry.connectLive`, the one funnel). The
    /// session starts on the bookmark's saved override (Stage D), or on Auto for anything without one
    /// (NDI, a pasted URL, the DEBUG ⌃⌥D/⌃⌥H overrides). Handed to the frame router BEFORE the transport
    /// opens, so the first decoded frame is already under it: on SRT it rides the activation, on WHEP
    /// it is the first announcement (§6.9 Stages B, C), on HLS it is stated at connect (Stage E).
    /// An HLS→HLS swap comes through here too, so it starts on the new bookmark's value.
    func prepare(source: LiveSource, bookmark: StreamBookmark?) {
        self.source = source
        bookmarkID = bookmark?.id
        bookmarkName = bookmark?.name
        savedOverride = ColorimetryOverride(storageID: bookmark?.colorOverride, on: Self.transport(source))
        guard let tag = Self.logTag(source) else {
            sessionOverride = .auto   // NDI's is on NDIService
            deck?.applyWindowTitle()
            return
        }
        sessionOverride = savedOverride
        Self.apply(sessionOverride, on: source)
        if let stored = bookmark?.colorOverride, savedOverride == .auto {
            // Kept verbatim in the bookmark; Auto here. Never applied past the picker's rule.
            NSLog("[%@] the saved stream’s color override “%@” is not offered on this transport — Auto",
                  tag, stored)
        }
        if let p = sessionOverride.preset {
            NSLog("[%@] override → %@ (CICP %d-%d-%d) — from the saved stream",
                  tag, sessionOverride.label, p.primaries, p.transfer, p.matrix)
        } else {
            NSLog("[%@] override → Auto (new connection)", tag)
        }
        deck?.applyWindowTitle()
    }

    // MARK: Changes

    /// The override in force on `source` in this window.
    func current(for source: LiveSource) -> ColorimetryOverride {
        switch source {
        case .ndi:             return NDIService.shared.colorimetryOverride
        case .srt, .web, .hls: return self.source == source ? sessionOverride : .auto
        }
    }

    /// Ask for `override` on `source`. A preset the transport does not offer is ignored; a supported Custom
    /// is offered on every transport (colour S5, decided 2026-10-13).
    func set(_ override: ColorimetryOverride, on source: LiveSource) {
        guard ColorimetryOverride.isOffered(override, on: Self.transport(source)) else { return }
        switch source {
        case .ndi:
            NDIService.shared.setColorimetryOverride(override)   // the title follows via arbitration
        case .srt, .web, .hls:
            guard self.source == source, override != sessionOverride, let tag = Self.logTag(source) else { return }
            sessionOverride = override
            Self.apply(override, on: source)
            if let p = override.preset {
                NSLog("[%@] override → %@ (CICP %d-%d-%d) — applied from the next decoded frame",
                      tag, override.label, p.primaries, p.transfer, p.matrix)
            } else {
                NSLog("[%@] override → Auto — the stream’s own color from the next decoded frame", tag)
            }
            deck?.applyWindowTitle()
        }
    }

    /// Color ▸ Next Tag Override: the next preset on this transport, wrapping to Auto.
    func cycle(on source: LiveSource?) {
        guard let source, Self.offersOverride(source) else { return }
        let all = ColorimetryOverride.available(on: Self.transport(source))
        let i = all.firstIndex(of: current(for: source)) ?? 0
        set(all[(i + 1) % all.count], on: source)
    }

    // MARK: Save to bookmark (Stage D)

    /// The transports whose override is saved per bookmark from this menu: SRT, WHEP and HLS. NDI is
    /// session-only (decision 1).
    static func savesOverride(_ source: LiveSource) -> Bool { logTag(source) != nil }

    /// The session's override differs from the bookmark's: Save and Revert have something to do.
    var differsFromSaved: Bool { bookmarkID != nil && sessionOverride != savedOverride }

    /// Persist the session's override into the bookmark this connect came from. Auto removes the key.
    func saveToBookmark() {
        guard let id = bookmarkID, let source, let tag = Self.logTag(source) else { return }
        let saving = sessionOverride
        switch StreamBookmarkStore.shared.setColorOverride(saving.storageID, forBookmark: id) {
        case .success(let b):
            savedOverride = ColorimetryOverride(storageID: b.colorOverride, on: Self.transport(source))
            NSLog("[%@] saved %@ to the saved stream", tag, saving.label)
        case .failure(let e):
            NSLog("[%@] notice: %@", tag, e.message)
            deck?.engine?.playbackNotice = e.message
        }
    }

    /// Back to the bookmark's saved override (Auto for none).
    func revertToSaved() {
        guard let source else { return }
        set(savedOverride, on: source)
    }

    /// The window-title suffix's words while an override is in force, or nil.
    func titleSuffix(for source: LiveSource) -> String? {
        let override = current(for: source)
        return override == .auto ? nil : "Color " + override.shortLabel
    }
}

// MARK: - The Color control

/// Which source the Interpretation control speaks for (colour S5): the window's live stream, or its file.
enum InterpretationSubject: Equatable {
    case live(LiveSource)
    case file
}

/// The control bar's ONE element for the Interpretation control (colour S5, decision 6). It picks the
/// subject here so `ContentView`'s body keeps a single element and no new branch (§6.7): the live stream
/// when this window shows one with an override, else the window's file, else nothing.
struct ColorInterpretationSlot: View {
    let deck: WindowDeck
    let live: LiveSource?
    let hasFile: Bool

    var body: some View {
        if let live, LiveColorOverrideModel.offersOverride(live) {
            ColorInterpretationControl(subject: .live(live), model: deck.colorOverride, fileModel: deck.fileColor, lut: deck.lut)
        } else if live == nil, hasFile {
            ColorInterpretationControl(subject: .file, model: deck.colorOverride, fileModel: deck.fileColor, lut: deck.lut)
        }
    }
}

struct ColorInterpretationControl: View {
    let subject: InterpretationSubject
    @ObservedObject var model: LiveColorOverrideModel
    @ObservedObject var fileModel: FileColorOverrideModel
    /// Colour S6: the window's LUT slot, and the app-wide interpolation (D1).
    @ObservedObject var lut: InterpretationLUTModel
    @ObservedObject private var lutSetting = LUTInterpolationSetting.shared
    @ObservedObject private var recentLUTs = RecentLUTStore.shared
    @ObservedObject private var ndi = NDIService.shared
    @ObservedObject private var srt = SRTClient.shared
    @ObservedObject private var whep = WHEPClient.shared
    @ObservedObject private var hls = HLSClient.shared

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
    ///
    /// Colour S5 (§6.11, decisions 6 and 7): files have it too, and both gain Custom — primaries, transfer
    /// and matrix chosen separately, from the S3 table's values — and a Reset item at the top.
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
                menuContent
            } label: {
                (Text(Image(systemName: "paintpalette")).font(.system(size: 13))
                 + Text("  ")
                 + Text(faceLabel + lut.faceSuffix).font(.system(.caption, design: .monospaced))
                 + bypassedLUTFace)
                    .foregroundColor(colorControlTint)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            // The interactive affordance — same size-8 chevron.down as the streaming / DeckLink
            // controls, so the control reads as a menu you open, not a passive readout.
            Menu {
                menuContent
            } label: {
                Text(Image(systemName: "chevron.down")).font(.system(size: 8))
                    .foregroundColor(colorControlTint)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        // The cycle's key is the registry's, with no default since 2026-10-23 (it was ⌃⌥C): named only when bound.
        .help((subject == .file
               ? "Color interpretation — Auto trusts the file’s tags; a preset or Override asserts them"
               : "Color interpretation — Auto trusts the stream; a preset or Override asserts it")
              + (ShortcutCenter.shared.registry.label(for: .cycleInterpretation).map { " (\($0) cycles the presets)" } ?? ""))
    }

    /// " + LUT bypassed" while the window's LUT is bypassed, struck through and dimmed: neither the amber of an applied
    /// LUT nor the plain face of none. A run of the face's one `Text`, so its own colour survives the borderless menu
    /// (see the note on `body`); the run's colour wins over the face's tint.
    private var bypassedLUTFace: Text {
        guard let words = lut.faceBypassedWords else { return Text("") }
        return Text(" + ").font(.system(.caption, design: .monospaced))
            + Text(words).font(.system(.caption, design: .monospaced))
                .strikethrough()
                .foregroundColor(.white.opacity(0.5))
    }

    // MARK: The subject

    /// The override in force for this control's subject.
    private var current: ColorimetryOverride {
        switch subject {
        case .live(let s): return model.current(for: s)
        case .file:        return fileModel.override
        }
    }

    private func choose(_ o: ColorimetryOverride) {
        switch subject {
        case .live(let s): model.set(o, on: s)
        case .file:        fileModel.set(o)
        }
    }

    /// The codes on screen now — Custom's pickers start from them. nil on a stream that has not stated
    /// its colour yet.
    private var effectiveCodes: (primaries: Int, transfer: Int, matrix: Int)? {
        switch subject {
        case .live:
            return reading.map { ($0.effective.primaries.code, $0.effective.transfer.code, $0.effective.matrix.code) }
        case .file:
            return fileModel.effective
        }
    }

    /// Amber when something on screen is a human assertion rather than a reading, the control
    /// bar's own white otherwise. Applied per leaf — see the note on `body`.
    private var colorControlTint: Color {
        let overridden: Bool
        switch subject {
        case .live: overridden = reading?.effective.isOverridden == true
        case .file: overridden = fileModel.override != .auto
        }
        // Colour S6, L3: an applied LUT is an assertion too (the face reads "+ LUT"); a bypassed one is not.
        return overridden || lut.isApplied ? Color.orange : .white.opacity(0.9)
    }

    // MARK: The menu

    /// Reset first (Robbie, 2026-10-13): undo an override without reopening, greyed on Auto. The final
    /// shortcut is the shortcut registry's. Then the presets, Custom, the source's own claim, and — for a
    /// saved stream — Save and Revert.
    @ViewBuilder private var menuContent: some View {
        Section {
            Button(subject == .file ? "Reset to File’s Tags" : "Reset to Stream’s Tags") { choose(.auto) }
                .disabled(current == .auto)
        }
        Section("Colorimetry") {
            Picker("Colorimetry", selection: presetBinding) {
                ForEach(presets) { option in
                    Text(option.label).tag(Optional(option))
                }
            }
            .pickerStyle(.inline)
        }
        customSection
        lutSection
        Section(subject == .file ? "File" : "Stream") {
            Button(statusLine) {}.disabled(true)
        }
        // Save and Revert, as the A/V menu has them for the audio offset (§6.9 Stage D, decision 5).
        // SRT, WHEP and HLS; NDI's override is for the session only, and a file's is per window.
        if case .live(let source) = subject, LiveColorOverrideModel.savesOverride(source) {
            Section {
                if let name = model.bookmarkName {
                    Button("Save \(model.current(for: source).label) to “\(name)”") { model.saveToBookmark() }
                        .disabled(!model.differsFromSaved)
                    Button("Revert to Saved (\(model.savedOverride.label))") { model.revertToSaved() }
                        .disabled(!model.differsFromSaved)
                } else {
                    Text("Not a saved stream: this override lasts for this connection only")
                }
            }
        }
    }

    private var presets: [ColorimetryOverride] {
        switch subject {
        case .live(let s): return ColorimetryOverride.available(on: LiveColorOverrideModel.transport(s))
        case .file:        return ColorimetryOverride.allCases
        }
    }

    /// nil while Custom is in force, so no preset row is checked.
    private var presetBinding: Binding<ColorimetryOverride?> {
        Binding(get: { current.isCustom ? nil : current },
                set: { if let o = $0 { choose(o) } })
    }

    // MARK: LUT (colour S6, L1; L3)

    /// Load, Recent LUTs, Bypass, remove, the output space (L2) and the app-wide interpolation, then the readout
    /// line. The LUT applies after the interpretation above, to whatever source this window shows, and stays
    /// across a change of source (decision 5).
    ///
    /// L3: rows that can be greyed are `Button`s and `Toggle`s, which honour `.disabled` in a menu (S5, L2); a
    /// missing recent file is a greyed row, never a load. The readout row is a disabled `Button`, as the File line
    /// is, so its words are readable by Accessibility.
    @ViewBuilder private var lutSection: some View {
        Section(lut.name.map { (lut.bypassed ? "LUT bypassed — " : "LUT — ") + "\($0) · \(lut.shape ?? "")"
                               + (lut.outputSpace == .auto ? "" : " → \(lut.outputSpace.lutSpaceLabel)") } ?? "LUT") {
            Button("Load LUT…") { lut.chooseFile() }
            Menu("Recent LUTs") {
                ForEach(recentLUTs.rows) { row in
                    Button(row.title) { if let url = row.url { lut.load(url) } }
                        .disabled(row.url == nil)
                }
                if !recentLUTs.rows.isEmpty { Divider() }
                Button("Clear Menu") { recentLUTs.clear() }
                    .disabled(recentLUTs.rows.isEmpty)
            }
            Toggle("Bypass LUT", isOn: Binding(get: { lut.bypassed }, set: { lut.setBypassed($0) }))
                .disabled(lut.name == nil)
            Button("Remove LUT") { lut.remove() }
                .disabled(lut.name == nil)
            outputSpaceMenu
            Menu("LUT Interpolation") {
                ForEach(CubeInterpolation.allCases, id: \.self) { mode in
                    // Any click chooses that mode (a checked row's toggle-off is ignored, as Custom's rows are).
                    Toggle(mode == .tetrahedral ? "Tetrahedral" : "Trilinear",
                           isOn: Binding(get: { lutSetting.interpolation == mode },
                                         set: { _ in lutSetting.interpolation = mode }))
                }
            }
            Button("LUT: " + (lut.readoutLine ?? "none")) {}.disabled(true)
        }
    }

    // MARK: LUT output space (colour S6, L2, D4)

    /// What the LUT's output IS: Same as Source (the default), a preset, or Custom. It becomes the picture's codes
    /// (D3) — layer, EDR, scopes, SDI tag, v210 matrix, export ICC, Reference, CIE — while the Source line and the
    /// interpretation above stay the source's. Greyed with no LUT. A fixed title, so an unattended run can press
    /// it by name; the checkmarks carry the choice, and the section title names a stated space.
    ///
    /// Rows are `Toggle`s, as Custom's are (a `Picker` row in a menu ignores `.disabled`, S5), and any click on a
    /// row chooses it (a checked row's toggle-off is ignored).
    ///
    /// ⚠️ GREYED PER ROW, NOT ON THE `Menu` — MEASURED. `.disabled` on the submenu itself left it and its rows
    /// reading enabled (Accessibility) with no LUT loaded, and a press would have done nothing, silently. Each row
    /// carries `.disabled` instead, which a `Toggle` row honours.
    ///
    /// "LUT Outputs" and "Same as Source (no change)" since 2026-10-24 (Robbie): the menu's words only; the stored
    /// value is still `ColorimetryOverride.storageID`, so saved LUT state loads as before. The closing rows say when
    /// to change it, as disabled `Button`s so Accessibility reads them (the readout row's construction).
    @ViewBuilder private var outputSpaceMenu: some View {
        Menu("LUT Outputs") {
            Toggle("Same as Source (no change)", isOn: outputBinding(.auto))
                .disabled(lut.name == nil)
            ForEach(ColorimetryOverride.allCases.filter { $0 != .auto }) { o in
                Toggle(o.label, isOn: outputBinding(o))
                    .disabled(lut.name == nil)
            }
            Section(lut.outputSpace.isCustom
                    ? "Custom — " + lut.outputSpace.lutSpaceLabel.replacingOccurrences(of: "Custom ", with: "") + " in use"
                    : "Custom") {
                outputAxisMenu("Primaries", 0, CustomColorimetry.primaries)
                outputAxisMenu("Transfer", 1, CustomColorimetry.transfers)
                outputAxisMenu("Matrix", 2, CustomColorimetry.matrices)
            }
            Divider()
            Button("Only change this for LUTs that convert to another color space (e.g. Rec.709 → PQ).") {}
                .disabled(true)
            Button("Display or calibration LUTs aren't supported here; use Bypass.") {}
                .disabled(true)
        }
    }

    private func outputBinding(_ o: ColorimetryOverride) -> Binding<Bool> {
        Binding(get: { lut.outputSpace == o }, set: { _ in lut.setOutputSpace(o) })
    }

    /// Where a Custom output space starts: the stated space's triple, else the source's codes on screen (any axis
    /// the table does not list taken as 709, as `customSeed` does).
    private var outputSeed: (primaries: Int, transfer: Int, matrix: Int) {
        if let t = lut.outputSpace.preset { return t }
        let e = effectiveCodes ?? (1, 1, 1)
        return (CustomColorimetry.primaries.contains(e.primaries) ? e.primaries : 1,
                CustomColorimetry.transfers.contains(e.transfer) ? e.transfer : 1,
                CustomColorimetry.matrices.contains(e.matrix) ? e.matrix : 1)
    }

    private func outputReplacing(_ axis: Int, _ value: Int) -> (primaries: Int, transfer: Int, matrix: Int) {
        var t = outputSeed
        switch axis {
        case 0: t.primaries = value
        case 1: t.transfer = value
        default: t.matrix = value
        }
        return t
    }

    private func outputAxisMenu(_ title: String, _ axis: Int, _ values: [Int]) -> some View {
        Menu(title) {
            ForEach(values, id: \.self) { c in
                let t = outputReplacing(axis, c)
                let allowed = CustomColorimetry.isSupported(t)
                Toggle(Self.axisName(axis, c) + (allowed ? "" : " — " + (CustomColorimetry.refusal(t) ?? "")),
                       isOn: Binding(get: {
                                         let s = outputSeed
                                         return lut.outputSpace.isCustom && (axis == 0 ? s.primaries : (axis == 1 ? s.transfer : s.matrix)) == c
                                     },
                                     set: { _ in
                                         if let o = ColorimetryOverride.customIfSupported(t) { lut.setOutputSpace(o) }
                                     }))
                    .disabled(!allowed || lut.name == nil)
            }
        }
    }

    // MARK: Custom (colour S5, decision 7)

    /// Three pickers, one per axis, each offering only the S3 table's values (`CustomColorimetry`). A value
    /// that would make a combination the table cannot draw as stated (PQ / HLG on non-HDR primaries) is
    /// greyed, and says why, so a Custom label never names a curve the picture is not drawn with.
    ///
    /// A SECTION OF THREE submenus rather than a "Custom ▸" menu of them: the three axes are visible in the
    /// menu itself, and the section header says when Custom is in force.
    ///
    /// ⚠️ EACH AXIS IS A MENU OF TOGGLES, NOT A `Picker` — MEASURED. The first build used three `Picker`s:
    /// in a menu their rows ignore `.disabled`, so PQ read enabled at primaries 709 (Accessibility
    /// `enabled` true on all six) and choosing it did nothing — refused by the model, silently. A `Toggle`
    /// row in a menu draws the checkmark and honours `.disabled`, as the Reset button does.
    ///
    /// ⚠️ FOR AN UNATTENDED RUN: synthetic mouse moves, clicks and arrow keys do not open these submenus,
    /// while the same clicks choose the preset rows. Accessibility does: the open menu hangs off the face's
    /// menu button, found by index, and a value is pressed with
    /// `click menu item "Rec. 2020 — 9" of menu 1 of menu item "Primaries" of …`.
    @ViewBuilder private var customSection: some View {
        Section(current.isCustom ? "Override — " + current.shortLabel.replacingOccurrences(of: "Override ", with: "") + " in use"
                                 : "Override") {
            axisMenu("Primaries", 0, CustomColorimetry.primaries)
            axisMenu("Transfer", 1, CustomColorimetry.transfers)
            axisMenu("Matrix", 2, CustomColorimetry.matrices)
        }
        .disabled(effectiveCodes == nil)
    }

    private func axisMenu(_ title: String, _ axis: Int, _ values: [Int]) -> some View {
        Menu(title) {
            ForEach(values, id: \.self) { c in
                let allowed = allows(axis, c)
                Toggle(Self.axisName(axis, c) + (allowed ? "" : " — " + (CustomColorimetry.refusal(replacing(axis, c)) ?? "")),
                       // ⚠️ THE NEW VALUE OF THE TOGGLE IS IGNORED — MEASURED. Off a preset, the checkmarks sit
                       // on the codes on screen, and clicking a checked row turns its toggle OFF: reading the
                       // bool made "Custom from 2020 PQ, keep primaries 2020" do nothing. Any click on an
                       // allowed row means "Custom, with this value on this axis".
                       isOn: Binding(get: { axisValue(axis) == c },
                                     set: { _ in
                                         if let o = ColorimetryOverride.customIfSupported(replacing(axis, c)), o != current {
                                             choose(o)
                                         }
                                     }))
                    .disabled(!allowed)
            }
        }
    }

    /// Where Custom starts: the Custom triple in force, else what is on screen, with any axis the table
    /// does not list taken as the value it is drawn with (709).
    private var customSeed: (primaries: Int, transfer: Int, matrix: Int) {
        if current.isCustom, let t = current.preset { return t }
        let e = effectiveCodes ?? (1, 1, 1)
        return (CustomColorimetry.primaries.contains(e.primaries) ? e.primaries : 1,
                CustomColorimetry.transfers.contains(e.transfer) ? e.transfer : 1,
                CustomColorimetry.matrices.contains(e.matrix) ? e.matrix : 1)
    }

    private func replacing(_ axis: Int, _ value: Int) -> (primaries: Int, transfer: Int, matrix: Int) {
        var t = customSeed
        switch axis {
        case 0: t.primaries = value
        case 1: t.transfer = value
        default: t.matrix = value
        }
        return t
    }

    private func allows(_ axis: Int, _ value: Int) -> Bool { CustomColorimetry.isSupported(replacing(axis, value)) }

    /// The value the axis's checkmark sits on: the Custom triple's, else what is on screen.
    private func axisValue(_ axis: Int) -> Int {
        let t = customSeed
        return axis == 0 ? t.primaries : (axis == 1 ? t.transfer : t.matrix)
    }

    /// The S3 table's own names, with the CICP code the label and the bookmark use.
    static func axisName(_ axis: Int, _ code: Int) -> String {
        let name: String
        switch axis {
        case 0: name = ColorimetryTable.primariesName(forCode: code)
        case 1: name = ColorimetryTable.transferName(forCode: code)
        default:
            switch code {
            case 1:  name = "Rec. 709"
            case 5:  name = "BT.470BG (601)"
            case 6:  name = "SMPTE 170M (601)"
            case 9:  name = "Rec. 2020 NCL"
            default: name = "—"
            }
        }
        return "\(name) — \(code)"
    }

    // MARK: Reading

    /// What the renderer has been told (`effective`) and what the stream said (`declared`). NDI's from
    /// NDIService; SRT's, WHEP's and HLS's from their clients, which publish the reading with the
    /// override applied. nil on SRT until the first SPS has been read, on HLS until the first frame,
    /// and for a file (which reads `fileModel`).
    private var reading: (effective: SourceColorimetry, declared: SourceColorimetry)? {
        guard case .live(let source) = subject else { return nil }
        switch source {
        case .ndi: return (ndi.colorInfo, ndi.declaredColorInfo)
        case .srt: return srt.colorimetry.map { ($0.bufferTags, $0.declaredTags) }
        case .web: return whep.colorimetry.map { ($0.bufferTags, $0.declaredTags) }
        case .hls: return hls.colorimetry
        }
    }

    /// Effective colorimetry + tier: "2020 PQ · Overridden", "709 · Assumed", "Override 9·1·6 · Overridden".
    private var faceLabel: String {
        let tier: String
        let p: Int, t: Int
        switch subject {
        case .live:
            guard let info = reading?.effective else { return "— · Waiting for the stream" }
            if case .live(let s) = subject, model.current(for: s).isCustom, info.isOverridden {
                return model.current(for: s).shortLabel + " · " + info.tier
            }
            (p, t, tier) = (info.primaries.code, info.transfer.code, info.tier)
        case .file:
            if fileModel.override.isCustom { return fileModel.override.shortLabel + " · Overridden" }
            let d = fileModel.declared
            let stated = [d.primaries, d.transfer, d.matrix].compactMap { $0 }.count
            tier = fileModel.override != .auto ? "Overridden" : (stated == 0 ? "Assumed" : "Declared")
            (p, t) = (fileModel.effective.primaries, fileModel.effective.transfer)
        }
        return "\(SourceColorimetry.primariesName(p).replacingOccurrences(of: "Rec.", with: "")) "
             + "\(SourceColorimetry.transferName(t).replacingOccurrences(of: "Rec.", with: "")) · \(tier)"
    }

    /// The source's own claim, independent of the override — an absence stated as an absence.
    private var statusLine: String {
        switch subject {
        case .live:
            guard let d = reading?.declared else { return "Has not stated its color yet" }
            guard d.isDeclared else { return "Declares no colorimetry" }
            return "Declares \(SourceColorimetry.primariesName(d.primaries.code)) · "
                 + "\(SourceColorimetry.transferName(d.transfer.code)) · "
                 + "\(SourceColorimetry.matrixName(d.matrix.code))"
        case .file:
            let d = fileModel.declared
            guard d.primaries != nil || d.transfer != nil || d.matrix != nil else { return "Tags no colorimetry" }
            func n(_ c: Int?, _ f: (Int) -> String) -> String { c.map(f) ?? "not stated" }
            return "Tagged \(n(d.primaries, SourceColorimetry.primariesName)) · "
                 + "\(n(d.transfer, SourceColorimetry.transferName)) · "
                 + "\(n(d.matrix, SourceColorimetry.matrixName))"
        }
    }
}
