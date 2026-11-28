//
//  MarkersScopeView.swift — the marker list (docs/MARKERS_PLAN.md §4): "Markers" in a scope slot, and the shared list the
//  Markers window shows too (`MarkersWindow.swift`).
//
//  CLICKS (D7, changed by Robbie 2026-11-15), the same in the slot and the window:
//    · click: selects that marker alone and JUMPS the playhead to it;
//    · ⌘-click: adds or removes it from the selection, no jump; ⇧-click: selects the range, no jump;
//    · double-click: opens the editor;
//    · ⌫: deletes the selection (one undo step); the context menu edits, recolours, goes to, deletes.
//  CHAPTER ROWS (docs/CHAPTER_MARKERS_PLAN.md §4.1, Stage 2): the file's embedded chapters, interleaved by time, with a
//  book symbol for a swatch. Not editable: double-click jumps, ⌫ skips them, and the context menu converts them.
//  A plain `List(selection:)` cannot jump on a click of an already-selected row, so the rows read the click themselves
//  (`NSApp.currentEvent`'s modifiers and click count, at mouse-up, so a click jumps at once rather than after the
//  double-click interval).
//
//  Not render-coupled (like the meters): it samples nothing. Thumbnails come from `MarkerThumbnailer` (§4.4).
//

import SwiftUI
import Markers
import ManifoldCore

struct MarkersScopeView: View {
    @ObservedObject var model: MarkerModel
    /// For the playhead row highlight.
    @ObservedObject var engine: FrameEngine
    var slotSelection: Binding<ScopeKind>? = nil

    /// The slot's thumbnails (§4.4): on unless turned off in the gear.
    @AppStorage("manifold.markers.slotThumbnails") private var showThumbnails = true
    /// The slot's text size (gear, and Settings ▸ Scopes & Guides): one stored value, read live. Medium is the slot as it was.
    @AppStorage(MarkerTextSize.key) private var textSize: MarkerTextSize = MarkerTextSize.defaultSize
    @Environment(\.openWindow) private var openWindow

    var body: some View {
#if DEBUG
        let _ = ScopePerf.count("body.MarkersScopeView")
#endif
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ScopeSlotHeader(name: "MARKERS", suffix: headerSuffix, selection: slotSelection)
                ScopeGear(title: "Markers", help: "Thumbnails, text size, colors shown, start timecode") { gearContent }
                Spacer(minLength: 4)
                if let i = model.inPoint { markChip("IN \(label(i))") }
                if let o = model.outPoint { markChip("OUT \(label(o))") }
            }
            .padding(.horizontal, 6)
            .frame(height: scopeHeaderHeight)

            ZStack {
                Color.black
                MarkerListBody(model: model, engine: engine, style: .slot, showThumbnails: showThumbnails, metrics: textSize.metrics)
            }
            MarkerNotice(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15)))
    }

    private var headerSuffix: String {
        guard model.isActive else { return "" }
        let n = model.markers.count, shown = model.visibleMarkers.count
        var s = n == shown ? " · \(n)" : " · \(shown) of \(n)"
        if showChapters {
            let c = model.unconvertedChapters.count, cs = model.visibleChapters.count
            if c > 0 { s += c == cs ? " · \(c) from file" : " · \(cs) of \(c) from file" }
        }
        return s
    }

    @AppStorage(MarkerSettings.showChaptersKey) private var showChapters = true

    private func label(_ f: Int) -> String { model.basis?.label(f) ?? "—" }

    /// One line always: in a narrow slot, or at Large, the chip shrinks to 70 % and then truncates, never wraps out of the
    /// 22 pt header (which would clip it).
    private func markChip(_ text: String) -> some View {
        let m = textSize.metrics
        return Text(text)
            .font(.system(size: m.chip, weight: .semibold, design: .monospaced))
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, m.chipPaddingH).padding(.vertical, m.chipPaddingV)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 2))
    }

    /// Mark ▸ Show Marker List's own action (`ShowMarkerListMenuItem`): `openWindow` on the one Markers `Window` scene, which
    /// opens it, or brings it to the front when it is already open. The help names the menu item's current key, if any.
    private var openEditorHelp: String {
        let key = ShortcutCenter.shared.registry.label(for: .showMarkerList).map { " (\($0))" } ?? ""
        return "Open the Markers window, as Mark ▸ Show Markers Window does\(key)"
    }

    @ViewBuilder
    private var gearContent: some View {
        ScopeGearSectionHeader("Show", isFirst: true)
        Toggle("Thumbnails", isOn: $showThumbnails)
        Button("Regenerate Thumbnails") { model.regenerateThumbnails() }
            .disabled(!model.isActive || (model.markers.isEmpty && model.chapters.isEmpty))
            .help("Make this file's marker and chapter thumbnails again (not while playing)")
        MarkerColorFilter(model: model)
        ScopeGearSectionHeader("Text size")
        Picker("Text size", selection: $textSize) {
            ForEach(MarkerTextSize.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("The size of the marker list's text and rows in this scope. Also in Settings ▸ Scopes & Guides.")
        ScopeGearSectionHeader("Markers")
        Button("Show Markers Window") { openWindow(id: MarkersWindowScene.windowID) }
            .help(openEditorHelp)
        Button("Import Markers…") { model.presentImport() }.disabled(!model.isActive)
        Button("Export Markers…") { model.presentExport() }.disabled(!model.isActive || model.markers.isEmpty)
        // D-C17a: offered when the file has no tmcd and no container timecode — so also over a user-data or XMP start.
        if let b = model.basis, b.overrideAvailable {
            ScopeGearSectionHeader("Start timecode")
            StartOverrideField(model: model, current: b.label(0), fileLabel: b.fileLabel)
        }
    }
}

/// The export/import summary line under a list.
struct MarkerNotice: View {
    @ObservedObject var model: MarkerModel
    var body: some View {
        if let notice = model.notice {
            Text(notice)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(3)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.08))
        }
    }
}

/// The 16 colors and the From File chip as filter toggles; none chosen shows all. With any chosen, markers show only in
/// the colors chosen and file markers only with the chip (docs/CHAPTER_MARKERS_PLAN.md §4.1; renamed in Stage 3).
///
/// ⚠️ LAID OUT TO BE MEASURED WHOLE (Stage 2 attended check, 2026-11-17: the chip's border was clipped at the bottom in
/// the gear popover). A popover sizes itself from its content's ideal height, so: the swatches are a plain `Grid`, not a
/// `LazyVGrid` (a lazy grid's height is an estimate in a fitting-size pass); the chip is `fixedSize` so it is never
/// compressed, its border is inset (`strokeBorder`) inside its own padding, and it has room above and below; its text is
/// the `.caption` style, so it grows with the system text size instead of being clipped at a fixed point size.
struct MarkerColorFilter: View {
    @ObservedObject var model: MarkerModel
    private static let rows: [[MarkerColor]] = stride(from: 0, to: MarkerColor.allCases.count, by: 8).map {
        Array(MarkerColor.allCases[$0..<min($0 + 8, MarkerColor.allCases.count)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Colors").font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(Self.rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(Self.rows[r]) { c in swatch(c) }
                    }
                }
            }
            chaptersChip
                .padding(.vertical, 2)
            Button("Show All") { model.colorFilter = []; model.chapterFilter = false }.disabled(!model.filter.isActive)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func swatch(_ c: MarkerColor) -> some View {
        Button {
            if model.colorFilter.contains(c) { model.colorFilter.remove(c) } else { model.colorFilter.insert(c) }
        } label: {
            Circle().fill(c.swatch).frame(width: 14, height: 14)
                .opacity(model.colorFilter.isEmpty || model.colorFilter.contains(c) ? 1 : 0.25)
                .overlay(Circle().strokeBorder(Color.primary, lineWidth: model.colorFilter.contains(c) ? 1.5 : 0))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(c.name)
        .accessibilityLabel(c.name)
    }

    private var chaptersChip: some View {
        Button {
            model.chapterFilter.toggle()
        } label: {
            Label("From File", systemImage: "doc.text")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .imageScale(.small)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .opacity(!model.filter.isActive || model.chapterFilter ? 1 : 0.4)
                .background(Capsule().strokeBorder(Color.primary.opacity(model.chapterFilter ? 1 : 0.6),
                                                   lineWidth: model.chapterFilter ? 1.5 : 0.75))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .help("Markers embedded in the file: chapters and comments")
        .accessibilityLabel("From File")
        .accessibilityAddTraits(model.chapterFilter ? .isSelected : [])
    }
}

// MARK: - The list

/// The rows, in either style: `.slot` (timecode, colour, name with the note's first line, duration; optional thumbnail)
/// or `.window` (thumbnail, in, out, duration, colour, name, notes, keywords).
struct MarkerListBody: View {
    enum Style { case slot, window }

    @ObservedObject var model: MarkerModel
    @ObservedObject var engine: FrameEngine
    let style: Style
    let showThumbnails: Bool
    /// The slot style's sizes (`MarkerTextSize`); the window style keeps its own.
    var metrics: MarkerSlotMetrics = .medium

    @State private var selection: Set<MarkerListRow.ID> = []
    @State private var anchor: MarkerListRow.ID?
    /// View ▸ Show Markers: off, the list says so and shows nothing; nothing is deleted. It hides chapters too.
    @AppStorage(MarkerSettings.showKey) private var showMarkers = true
    /// View ▸ Show Chapters: read here so the rows follow it (`MarkerModel.visibleChapters` reads the same key).
    @AppStorage(MarkerSettings.showChaptersKey) private var showChapters = true
    @FocusState private var focused: Bool

    var body: some View {
        switch model.state {
        case .none: empty("Markers are for video files.")
        case .loading: empty("Reading markers…")
        case .unavailable(let why): empty(why)
        case .ready:
            if !model.isActive { empty("Markers are for video files.") }
            else if !showMarkers { empty(hiddenHint) }
            else if model.markers.isEmpty && (!showChapters || model.unconvertedChapters.isEmpty) { empty(addHint) }
            else if model.listRows.isEmpty { empty("Nothing in the filter chosen.") }
            else { list }
        }
    }

    private var addHint: String {
        let key = ShortcutCenter.shared.registry.label(for: .addMarker) ?? "Mark ▸ Add Marker"
        return "No markers. Press \(key) to mark the frame on screen."
    }

    private var hiddenHint: String {
        let key = ShortcutCenter.shared.registry.label(for: .showMarkers).map { " (\($0))" } ?? ""
        return "Markers are hidden. View ▸ Show Markers\(key) shows them again."
    }

    private func empty(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11))
            .foregroundStyle(style == .slot ? .white.opacity(0.45) : .secondary)
            .multilineTextAlignment(.center)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var thumbsOn: Bool { style == .window || showThumbnails }

    private var list: some View {
        let shown = model.listRows
        let current = shown.last { $0.frame <= engine.currentFrame }?.id
        return VStack(spacing: 0) {
            if style == .window { MarkerWindowHeader() }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { r in
                        row(r)
                            .padding(.horizontal, 6).padding(.vertical, style == .slot ? metrics.rowPadding : 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(r.id, isCurrent: r.id == current))
                            .contentShape(Rectangle())
                            .onTapGesture { click(r, in: shown) }
                            .contextMenu { contextItems(for: r, in: shown) }
                            .overlay { RowToolTip(text: rowHelp(r)) }
                    }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onDeleteCommand { deleteSelection() }
        // ⇧M on a selected chapter shows the read-only note (`MarkerModel.editMarkerAtPlayhead`).
        .onChange(of: selection) { _, sel in
            if sel.count == 1, case .chapter(let i)? = sel.first { model.selectedChapter = i } else { model.selectedChapter = nil }
        }
        .onAppear { if thumbsOn { model.thumbnails.want(true) } }
        .onDisappear { if thumbsOn { model.thumbnails.want(false) } }
        .onChange(of: thumbsOn) { _, on in model.thumbnails.want(on) }
    }

    private func background(_ id: MarkerListRow.ID, isCurrent: Bool) -> Color {
        if selection.contains(id) { return Color.accentColor.opacity(0.35) }
        if isCurrent { return (style == .slot ? Color.white : Color.primary).opacity(0.07) }
        return .clear
    }

    // MARK: Clicks (D7, see the header)

    private func click(_ r: MarkerListRow, in shown: [MarkerListRow]) {
        focused = true
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        if (event?.clickCount ?? 1) >= 2 {
            selection = [r.id]; anchor = r.id
            switch r {
            case .marker(let m): model.openEditor(m)
            case .chapter(let c):
                // Not editable: a double-click jumps first, then says so and offers Convert.
                model.go(to: c)
                model.showChapterNote(c)
            }
        } else if flags.contains(.command) {
            if selection.contains(r.id) { selection.remove(r.id) } else { selection.insert(r.id) }
            anchor = r.id
        } else if flags.contains(.shift), let a = anchor, let i = shown.firstIndex(where: { $0.id == a }),
                  let j = shown.firstIndex(where: { $0.id == r.id }) {
            selection = Set(shown[min(i, j)...max(i, j)].map(\.id))
        } else {
            selection = [r.id]; anchor = r.id
            model.go(toFrame: r.frame)
        }
    }

    /// The selected markers' ids. Chapter rows are skipped (⌫ never touches them).
    private func markerIDs(_ ids: Set<MarkerListRow.ID>) -> Set<UUID> {
        Set(ids.compactMap { if case .marker(let u) = $0 { return u } else { return nil } })
    }

    private func deleteSelection() {
        let ids = markerIDs(selection)
        model.delete(ids)
        selection = selection.filter { if case .marker = $0 { return false } else { return true } }
    }

    @ViewBuilder
    private func contextItems(for r: MarkerListRow, in shown: [MarkerListRow]) -> some View {
        let chosen = selection.contains(r.id) ? selection : [r.id]
        switch r {
        case .marker(let m):
            let ids = markerIDs(chosen)
            if ids.count == 1 {
                Button("Edit…") { model.openEditor(m) }
                Button("Go to Marker") { model.go(to: m) }
            }
            Menu("Color") {
                ForEach(MarkerColor.allCases) { c in Button(c.name) { model.setColor(c, for: ids) } }
            }
            Button(ids.count == 1 ? "Regenerate Thumbnail" : "Regenerate \(ids.count) Thumbnails") {
                model.regenerateThumbnails(ids)
            }
            Divider()
            Button(ids.count == 1 ? "Delete Marker" : "Delete \(ids.count) Markers") {
                model.delete(ids); selection.subtract(ids.map { .marker($0) })
            }
        case .chapter(let c):
            let picked: [MappedChapter] = shown.compactMap {
                if case .chapter(let x) = $0, chosen.contains($0.id) { return x } else { return nil }
            }
            if picked.count == 1 {
                Button("Edit…") { model.showChapterNote(c) }
                Button("Go to \(c.kind.label)") { model.go(to: c) }
            }
            Button(picked.count == 1 ? "Convert to Marker" : "Convert \(picked.count) File Markers to Markers") {
                model.convert(picked); selection.subtract(picked.map { .chapter($0.fileIndex) })
            }
            Button("Convert All File Markers to Markers") { model.convertAllChapters(); selection = [] }
                .disabled(model.unconvertedChapters.isEmpty)
            Divider()
            Button(picked.count == 1 ? "Regenerate Thumbnail" : "Regenerate \(picked.count) Thumbnails") {
                model.regenerateThumbnails(frames: Set(picked.map(\.frame)))
            }
        }
    }

    // MARK: Rows

    private func label(_ f: Int) -> String { model.basis?.label(f) ?? "—" }
    private func durationText(_ m: Marker) -> String { model.basis?.durationLabel(m.duration) ?? "" }

    @ViewBuilder
    private func row(_ r: MarkerListRow) -> some View {
        switch (r, style) {
        case (.marker(let m), .slot): slotRow(m)
        case (.marker(let m), .window): windowRow(m)
        case (.chapter(let c), .slot): chapterSlotRow(c)
        case (.chapter(let c), .window): chapterWindowRow(c)
        }
    }

    private func chapterDuration(_ c: MappedChapter) -> String { model.basis?.durationLabel(c.duration) ?? "" }

    /// Every row's tooltip (`ChapterLayer.rowToolTip`), shown by `RowToolTip`, not `.help` (see there).
    private func rowHelp(_ r: MarkerListRow) -> String {
        switch r {
        case .marker(let m): return ChapterLayer.rowToolTip(m, timecode: label(m.frame))
        case .chapter(let c): return ChapterLayer.rowToolTip(c, timecode: label(c.frame))
        }
    }

    /// The layer's color for the file marker (`MappedChapter.layerColor`: its own, Green for an XMP item without one),
    /// else the list's secondary.
    private func chapterTint(_ c: MappedChapter, slot: Bool) -> Color {
        if let k = c.layerColor { return Color(.sRGB, red: Double(k.red) / 255, green: Double(k.green) / 255, blue: Double(k.blue) / 255) }
        return slot ? .white.opacity(0.75) : .secondary
    }

    // The slot rows take every size from `metrics` (MarkerTextSize; Medium is the slot as it was). The timecode and the
    // duration are one line always: in a narrow slot they shrink to 70 % and then truncate instead of wrapping, and the
    // timecode is the last to give way. At Medium in a slot wide enough for the row, nothing changes.

    private func slotTimecode(_ s: String) -> some View {
        Text(s)
            .font(.system(size: metrics.timecode, design: .monospaced))
            .lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
            .foregroundStyle(.white.opacity(0.85))
    }

    private func slotDuration(_ s: String) -> some View {
        Text(s)
            .font(.system(size: metrics.duration, design: .monospaced))
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(.white.opacity(0.5))
    }

    private func chapterSlotRow(_ c: MappedChapter) -> some View {
        HStack(alignment: .center, spacing: metrics.rowSpacing) {
            if showThumbnails { MarkerThumb(thumbnails: model.thumbnails, frame: c.frame, height: metrics.thumbnail) }
            slotTimecode(label(c.frame))
            Image(systemName: c.kind.symbolName)
                .font(.system(size: metrics.swatch))
                .foregroundStyle(chapterTint(c, slot: true))
                .frame(width: metrics.swatch, height: metrics.swatch)
            Text(c.title.isEmpty ? "—" : c.title)
                .font(.system(size: metrics.name))
                .foregroundStyle(.white.opacity(c.title.isEmpty ? 0.35 : 0.75))
                .lineLimit(1)
            Spacer(minLength: 4)
            slotDuration(chapterDuration(c))
        }
    }

    private func chapterWindowRow(_ c: MappedChapter) -> some View {
        HStack(alignment: .top, spacing: MarkerWindowColumns.spacing) {
            MarkerThumb(thumbnails: model.thumbnails, frame: c.frame, height: 54)
                .frame(width: MarkerWindowColumns.thumb, alignment: .leading)
            mono(label(c.frame)).frame(width: MarkerWindowColumns.tc, alignment: .leading)
            mono(label(c.lastFrame)).frame(width: MarkerWindowColumns.tc, alignment: .leading)
            mono(chapterDuration(c)).frame(width: MarkerWindowColumns.tc, alignment: .leading)
            HStack(spacing: 5) {
                Image(systemName: c.kind.symbolName).foregroundStyle(chapterTint(c, slot: false)).frame(width: 10, height: 10)
                Text(c.kind.label).foregroundStyle(.secondary)
            }
            .frame(width: MarkerWindowColumns.color, alignment: .leading)
            Text(c.title.isEmpty ? "—" : c.title)
                .foregroundStyle(.secondary)
                .frame(width: MarkerWindowColumns.name, alignment: .leading)
            Text("").frame(maxWidth: .infinity, alignment: .leading)
            Text("").frame(width: MarkerWindowColumns.keywords, alignment: .leading)
        }
        .font(.system(size: 12))
        .padding(.vertical, 3)
    }

    private func slotRow(_ m: Marker) -> some View {
        HStack(alignment: .center, spacing: metrics.rowSpacing) {
            if showThumbnails { MarkerThumb(thumbnails: model.thumbnails, frame: m.frame, height: metrics.thumbnail) }
            slotTimecode(label(m.frame))
            Circle().fill(m.color.swatch).frame(width: metrics.swatch, height: metrics.swatch)
            VStack(alignment: .leading, spacing: 1) {
                Text(m.name.isEmpty ? "—" : m.name)
                    .font(.system(size: metrics.name))
                    .foregroundStyle(.white.opacity(m.name.isEmpty ? 0.35 : 0.9))
                    .lineLimit(1)
                if let first = m.notes.split(whereSeparator: \.isNewline).first {
                    Text(first).font(.system(size: metrics.notes)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            slotDuration(m.duration == 1 ? "" : durationText(m))
        }
    }

    private func windowRow(_ m: Marker) -> some View {
        HStack(alignment: .top, spacing: MarkerWindowColumns.spacing) {
            MarkerThumb(thumbnails: model.thumbnails, frame: m.frame, height: 54)
                .frame(width: MarkerWindowColumns.thumb, alignment: .leading)
            mono(label(m.frame)).frame(width: MarkerWindowColumns.tc, alignment: .leading)
            mono(label(m.lastFrame)).frame(width: MarkerWindowColumns.tc, alignment: .leading)
            mono(durationText(m)).frame(width: MarkerWindowColumns.tc, alignment: .leading)
            HStack(spacing: 5) {
                Circle().fill(m.color.swatch).frame(width: 10, height: 10)
                Text(m.color.name)
            }
            .frame(width: MarkerWindowColumns.color, alignment: .leading)
            Text(m.name.isEmpty ? "—" : m.name)
                .foregroundStyle(m.name.isEmpty ? .secondary : .primary)
                .frame(width: MarkerWindowColumns.name, alignment: .leading)
            Text(m.notes).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            Text(m.keywords.joined(separator: ", "))
                .foregroundStyle(.secondary)
                .frame(width: MarkerWindowColumns.keywords, alignment: .leading)
        }
        .font(.system(size: 12))
        .padding(.vertical, 3)
    }

    private func mono(_ s: String) -> some View { Text(s).font(.system(size: 12, design: .monospaced)) }
}

enum MarkerWindowColumns {
    static let spacing: CGFloat = 10
    static let thumb: CGFloat = 96
    static let tc: CGFloat = 92
    static let color: CGFloat = 86
    static let name: CGFloat = 150
    static let keywords: CGFloat = 130
}

struct MarkerWindowHeader: View {
    var body: some View {
        HStack(spacing: MarkerWindowColumns.spacing) {
            Text("").frame(width: MarkerWindowColumns.thumb, alignment: .leading)
            Text("In").frame(width: MarkerWindowColumns.tc, alignment: .leading)
            Text("Out").frame(width: MarkerWindowColumns.tc, alignment: .leading)
            Text("Duration").frame(width: MarkerWindowColumns.tc, alignment: .leading)
            Text("Color").frame(width: MarkerWindowColumns.color, alignment: .leading)
            Text("Name").frame(width: MarkerWindowColumns.name, alignment: .leading)
            Text("Notes").frame(maxWidth: .infinity, alignment: .leading)
            Text("Keywords").frame(width: MarkerWindowColumns.keywords, alignment: .leading)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(.bar)
    }
}

/// One marker's thumbnail, or a placeholder while it is made.
struct MarkerThumb: View {
    @ObservedObject var thumbnails: MarkerThumbnailer
    let frame: Int
    let height: CGFloat

    var body: some View {
        Group {
            if let image = thumbnails.images[frame] {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if thumbnails.noPreview.contains(frame) {
                Rectangle().fill(Color.gray.opacity(0.18)).aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(Text("no preview").font(.system(size: max(7, height / 6))).foregroundStyle(.secondary))
                    .help("This frame could not be decoded. Regenerate Thumbnail tries again.")
            } else {
                Rectangle().fill(Color.gray.opacity(0.18)).aspectRatio(16 / 9, contentMode: .fit)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

/// D6 / D-C17: the start timecode for a file with no timecode track and no container timecode. It replaces a start read
/// from the file's metadata, and the transport readout, timecode entry and Export Frame names use it as well as markers.
struct StartOverrideField: View {
    @ObservedObject var model: MarkerModel
    /// The file's own start from its metadata, nil when it has none.
    let fileLabel: String?
    @State private var text: String
    @State private var invalid = false

    init(model: MarkerModel, current: String, fileLabel: String?) {
        self.model = model
        self.fileLabel = fileLabel
        _text = State(initialValue: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(fileLabel.map { "From the file’s metadata: \($0). Start at:" } ?? "This file has no timecode. Start at:")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("00:00:00:00", text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 110)
                    .onSubmit { invalid = !model.setStartOverride(text) }
                Button("Set") { invalid = !model.setStartOverride(text) }
                Button("Reset") { text = fileLabel ?? "00:00:00:00"; invalid = !model.setStartOverride(nil) }
            }
            if invalid { Text("Not a timecode at this rate.").font(.caption).foregroundStyle(.red) }
            Text("Markers, the transport readout, timecode entry and Export Frame names all use it.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// An AppKit tooltip over a list row, marker or chapter (Stage 2 attended checks, 2026-11-17: neither kind of row in the
/// Markers slot showed its `.help` tooltip, while the timeline flag's, an AppKit tooltip, worked).
///
/// WHY NOT `.help`. The rows had `.help`, and it never showed. The cause is not measured. The likely ones are both in
/// this list: SwiftUI re-registers its tooltips when the list redraws, and the list observes the engine (the playhead
/// row) and the model, so the tooltip delay can keep restarting; and the row's `.onTapGesture` and `.contextMenu` wrap
/// it. This view sidesteps both: its `toolTip` is set only when the text changes, and AppKit owns the timing.
///
/// CLICKS PASS THROUGH. It answers hit-testing only outside mouse clicks, drags and scrolls (for the tooltip manager on
/// a mouse move), so a click, a double-click, a right-click or a scroll reaches the row exactly as before.
struct RowToolTip: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> ToolTipView {
        let v = ToolTipView()
        v.toolTip = text
        return v
    }

    func updateNSView(_ v: ToolTipView, context: Context) {
        if v.toolTip != text { v.toolTip = text }
    }

    final class ToolTipView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                 .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel, .pressure, .swipe, .magnify,
                 .smartMagnify, .rotate, .gesture, .beginGesture, .endGesture:
                return nil
            default:
                return super.hitTest(point)
            }
        }
    }
}
