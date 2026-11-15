//
//  MarkersScopeView.swift — "Markers" in a scope slot (docs/MARKERS_PLAN.md §4.1 (a), §4.2).
//
//  Not render-coupled (like the meters): it reads the window's `MarkerModel` and samples nothing. Columns: timecode,
//  colour, name, duration; the note's first line under the name. Click selects, double-click (or Return) jumps, ⌫
//  deletes the selection (with undo), the context menu edits, recolours and deletes. The gear holds the colour filter
//  and, for a file without timecode, the start timecode markers use (D6).
//

import SwiftUI
import Markers
import ManifoldCore

struct MarkersScopeView: View {
    @ObservedObject var model: MarkerModel
    /// For the playhead row highlight.
    @ObservedObject var engine: FrameEngine
    var slotSelection: Binding<ScopeKind>? = nil

    @State private var selection: Set<UUID> = []

    var body: some View {
#if DEBUG
        let _ = ScopePerf.count("body.MarkersScopeView")
#endif
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ScopeSlotHeader(name: "MARKERS", suffix: headerSuffix, selection: slotSelection)
                ScopeGear(title: "Markers", help: "Filter by colour; start timecode") { gearContent }
                Spacer(minLength: 4)
                if let i = model.inPoint { markChip("IN \(label(i))") }
                if let o = model.outPoint { markChip("OUT \(label(o))") }
            }
            .padding(.horizontal, 6)
            .frame(height: scopeHeaderHeight)

            ZStack {
                Color.black
                content
            }
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
    private var content: some View {
        switch model.state {
        case .none:
            emptyText("Markers are for video files.")
        case .loading:
            emptyText("Reading markers…")
        case .unavailable(let why):
            emptyText(why)
        case .ready:
            if !model.isActive {
                emptyText("Markers are for video files.")
            } else if model.markers.isEmpty {
                emptyText(addHint)
            } else if model.visibleMarkers.isEmpty {
                emptyText("No markers in the colours chosen.")
            } else {
                list
            }
        }
    }

    private var addHint: String {
        let key = ShortcutCenter.shared.registry.label(for: .addMarker) ?? "Mark ▸ Add Marker"
        return "No markers. Press \(key) to mark the frame on screen."
    }

    private func emptyText(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
            .multilineTextAlignment(.center)
            .padding(12)
    }

    private var currentID: UUID? {
        let f = engine.currentFrame
        return model.visibleMarkers.last { $0.frame <= f }?.id
    }

    private var list: some View {
        let current = currentID
        return List(selection: $selection) {
            ForEach(model.visibleMarkers) { m in
                row(m, isCurrent: m.id == current)
                    .tag(m.id)
                    .listRowBackground(m.id == current ? Color.white.opacity(0.07) : Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 18)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let id = ids.first, let m = model.markers.first(where: { $0.id == id }) {
                Button("Edit…") { model.openEditor(m) }
                Button("Go to Marker") { model.go(to: m) }
            }
            if !ids.isEmpty {
                Menu("Color") {
                    ForEach(MarkerColor.allCases) { c in Button(c.name) { model.setColor(c, for: ids) } }
                }
                Divider()
                Button(ids.count == 1 ? "Delete Marker" : "Delete \(ids.count) Markers") { model.delete(ids) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let m = model.markers.first(where: { $0.id == id }) { model.go(to: m) }
        }
        .onDeleteCommand { model.delete(selection); selection = [] }
    }

    private func row(_ m: Marker, isCurrent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label(m.frame))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(isCurrent ? 0.95 : 0.75))
            Circle().fill(m.color.swatch).frame(width: 8, height: 8).help(m.color.name)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 1) {
                Text(m.name.isEmpty ? "—" : m.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(m.name.isEmpty ? 0.35 : 0.9))
                    .lineLimit(1)
                if let first = m.notes.split(whereSeparator: \.isNewline).first {
                    Text(first)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(m.duration == 1 ? "" : (model.basis?.durationLabel(m.duration) ?? ""))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
        .help(m.notes.isEmpty ? m.name : m.notes)
    }

    @ViewBuilder
    private var gearContent: some View {
        ScopeGearSectionHeader("Show colours", isFirst: true)
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
        if let b = model.basis, !b.hasTimecode {
            ScopeGearSectionHeader("Start timecode")
            StartOverrideField(model: model, current: b.label(0))
        }
    }
}

/// D6: the start timecode markers use for a file without one.
private struct StartOverrideField: View {
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
