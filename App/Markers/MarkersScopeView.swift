//
//  MarkersScopeView.swift — the marker list (docs/MARKERS_PLAN.md §4): "Markers" in a scope slot, and the shared list the
//  Markers window shows too (`MarkersWindow.swift`).
//
//  CLICKS (D7, changed by Robbie 2026-11-15), the same in the slot and the window:
//    · click: selects that marker alone and JUMPS the playhead to it;
//    · ⌘-click: adds or removes it from the selection, no jump; ⇧-click: selects the range, no jump;
//    · double-click: opens the editor;
//    · ⌫: deletes the selection (one undo step); the context menu edits, recolours, goes to, deletes.
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

    var body: some View {
#if DEBUG
        let _ = ScopePerf.count("body.MarkersScopeView")
#endif
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ScopeSlotHeader(name: "MARKERS", suffix: headerSuffix, selection: slotSelection)
                ScopeGear(title: "Markers", help: "Thumbnails, colours shown, start timecode") { gearContent }
                Spacer(minLength: 4)
                if let i = model.inPoint { markChip("IN \(label(i))") }
                if let o = model.outPoint { markChip("OUT \(label(o))") }
            }
            .padding(.horizontal, 6)
            .frame(height: scopeHeaderHeight)

            ZStack {
                Color.black
                MarkerListBody(model: model, engine: engine, style: .slot, showThumbnails: showThumbnails)
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
        return n == shown ? " · \(n)" : " · \(shown) of \(n)"
    }

    private func label(_ f: Int) -> String { model.basis?.label(f) ?? "—" }

    private func markChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 2))
    }

    @ViewBuilder
    private var gearContent: some View {
        ScopeGearSectionHeader("Show", isFirst: true)
        Toggle("Thumbnails", isOn: $showThumbnails)
        Button("Regenerate Thumbnails") { model.regenerateThumbnails() }
            .disabled(!model.isActive || model.markers.isEmpty)
            .help("Make this file's marker thumbnails again (not while playing)")
        MarkerColorFilter(model: model)
        ScopeGearSectionHeader("Markers")
        Button("Import Markers…") { model.presentImport() }.disabled(!model.isActive)
        Button("Export Markers…") { model.presentExport() }.disabled(!model.isActive || model.markers.isEmpty)
        if let b = model.basis, !b.hasTimecode {
            ScopeGearSectionHeader("Start timecode")
            StartOverrideField(model: model, current: b.label(0))
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

/// The 16 colours as filter toggles; none chosen shows all.
struct MarkerColorFilter: View {
    @ObservedObject var model: MarkerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Colours").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 4), count: 8), spacing: 4) {
                ForEach(MarkerColor.allCases) { c in
                    Button {
                        if model.colorFilter.contains(c) { model.colorFilter.remove(c) } else { model.colorFilter.insert(c) }
                    } label: {
                        Circle().fill(c.swatch).frame(width: 14, height: 14)
                            .opacity(model.colorFilter.isEmpty || model.colorFilter.contains(c) ? 1 : 0.25)
                            .overlay(Circle().strokeBorder(Color.primary, lineWidth: model.colorFilter.contains(c) ? 1.5 : 0))
                    }
                    .buttonStyle(.plain)
                    .help(c.name)
                    .accessibilityLabel(c.name)
                }
            }
            Button("Show All Colours") { model.colorFilter = [] }.disabled(model.colorFilter.isEmpty)
        }
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

    @State private var selection: Set<UUID> = []
    @State private var anchor: UUID?
    /// View ▸ Show Markers: off, the list says so and shows nothing; nothing is deleted.
    @AppStorage(MarkerSettings.showKey) private var showMarkers = true
    @FocusState private var focused: Bool

    var body: some View {
        switch model.state {
        case .none: empty("Markers are for video files.")
        case .loading: empty("Reading markers…")
        case .unavailable(let why): empty(why)
        case .ready:
            if !model.isActive { empty("Markers are for video files.") }
            else if !showMarkers { empty(hiddenHint) }
            else if model.markers.isEmpty { empty(addHint) }
            else if model.visibleMarkers.isEmpty { empty("No markers in the colours chosen.") }
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
        let shown = model.visibleMarkers
        let current = shown.last { $0.frame <= engine.currentFrame }?.id
        return VStack(spacing: 0) {
            if style == .window { MarkerWindowHeader() }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { m in
                        row(m)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(m, isCurrent: m.id == current))
                            .contentShape(Rectangle())
                            .onTapGesture { click(m, in: shown) }
                            .contextMenu { contextItems(for: m) }
                    }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onDeleteCommand { deleteSelection() }
        .onAppear { if thumbsOn { model.thumbnails.want(true) } }
        .onDisappear { if thumbsOn { model.thumbnails.want(false) } }
        .onChange(of: thumbsOn) { _, on in model.thumbnails.want(on) }
    }

    private func background(_ m: Marker, isCurrent: Bool) -> Color {
        if selection.contains(m.id) { return Color.accentColor.opacity(0.35) }
        if isCurrent { return (style == .slot ? Color.white : Color.primary).opacity(0.07) }
        return .clear
    }

    // MARK: Clicks (D7, see the header)

    private func click(_ m: Marker, in shown: [Marker]) {
        focused = true
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        if (event?.clickCount ?? 1) >= 2 {
            selection = [m.id]; anchor = m.id
            model.openEditor(m)
        } else if flags.contains(.command) {
            if selection.contains(m.id) { selection.remove(m.id) } else { selection.insert(m.id) }
            anchor = m.id
        } else if flags.contains(.shift), let a = anchor, let i = shown.firstIndex(where: { $0.id == a }),
                  let j = shown.firstIndex(where: { $0.id == m.id }) {
            selection = Set(shown[min(i, j)...max(i, j)].map(\.id))
        } else {
            selection = [m.id]; anchor = m.id
            model.go(to: m)
        }
    }

    private func deleteSelection() {
        model.delete(selection)
        selection = []
    }

    @ViewBuilder
    private func contextItems(for m: Marker) -> some View {
        let ids = selection.contains(m.id) ? selection : [m.id]
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
            model.delete(ids); selection.subtract(ids)
        }
    }

    // MARK: Rows

    private func label(_ f: Int) -> String { model.basis?.label(f) ?? "—" }
    private func durationText(_ m: Marker) -> String { model.basis?.durationLabel(m.duration) ?? "" }

    @ViewBuilder
    private func row(_ m: Marker) -> some View {
        switch style {
        case .slot: slotRow(m)
        case .window: windowRow(m)
        }
    }

    private func slotRow(_ m: Marker) -> some View {
        HStack(alignment: .center, spacing: 6) {
            if showThumbnails { MarkerThumb(thumbnails: model.thumbnails, frame: m.frame, height: 32) }
            Text(label(m.frame))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            Circle().fill(m.color.swatch).frame(width: 8, height: 8).help(m.color.name)
            VStack(alignment: .leading, spacing: 1) {
                Text(m.name.isEmpty ? "—" : m.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(m.name.isEmpty ? 0.35 : 0.9))
                    .lineLimit(1)
                if let first = m.notes.split(whereSeparator: \.isNewline).first {
                    Text(first).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(m.duration == 1 ? "" : durationText(m))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
        .help(m.notes.isEmpty ? m.name : m.notes)
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

/// D6: the start timecode markers use for a file without one.
struct StartOverrideField: View {
    @ObservedObject var model: MarkerModel
    @State private var text: String
    @State private var invalid = false

    init(model: MarkerModel, current: String) {
        self.model = model
        _text = State(initialValue: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("This file has no timecode. Markers count from:").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("00:00:00:00", text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 110)
                    .onSubmit { invalid = !model.setStartOverride(text) }
                Button("Set") { invalid = !model.setStartOverride(text) }
                Button("Reset") { text = "00:00:00:00"; invalid = !model.setStartOverride(nil) }
            }
            if invalid { Text("Not a timecode at this rate.").font(.caption).foregroundStyle(.red) }
            Text("The transport readout is unchanged.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
