//
//  MarkerEditorSheet.swift — the marker editor (docs/MARKERS_PLAN.md §3.3), laid out as Resolve's marker dialog:
//  Time and Duration, Name, Notes, Keyword, Color (`docs/markers/frameio_formating.png`), plus End and Set from In/Out.
//
//  Timecodes are typed as the transport shows them; drop-frame labels that do not exist are refused, as timecode entry
//  refuses them. Duration is typed as a timecode-shaped length (00:00:01:00 = one second of frames) or a frame count.
//

import SwiftUI
import Markers
import PlayheadSlider

struct MarkerEditorSheet: View {
    @ObservedObject var model: MarkerModel
    @State private var draft: Marker
    /// The committed values. The fields' text is what is being typed; it becomes these on commit (Tab, Return, leaving
    /// the field) and is reformatted to full SMPTE.
    @State private var start: Int
    @State private var duration: Int
    @State private var startText: String
    @State private var durationText: String
    @State private var keywordsText: String
    @State private var refusal: String?
    private let basis: TimecodeBasis
    private let isNew: Bool
    @FocusState private var focus: Field?

    private enum Field: Hashable { case name, start, duration }

    init(model: MarkerModel, marker: Marker, basis: TimecodeBasis, isNew: Bool) {
        self.model = model
        self.basis = basis
        self.isNew = isNew
        _draft = State(initialValue: marker)
        _start = State(initialValue: marker.frame)
        _duration = State(initialValue: marker.duration)
        _startText = State(initialValue: basis.label(marker.frame))
        _durationText = State(initialValue: basis.durationLabel(marker.duration))
        _keywordsText = State(initialValue: marker.keywords.joined(separator: ", "))
    }

    // The typed text read by the transport's timecode-entry rules (`TimecodeBasis.typedFrame` / `typedDuration`):
    // "100" is one second, "1" one frame, "+10" ten frames on. Relative entries count from the committed value.
    private var typedStart: Int? {
        guard let f = basis.typedFrame(startText, current: start), f >= 0, f <= model.lastFrame else { return nil }
        return f
    }
    private var typedDuration: Int? {
        guard let d = basis.typedDuration(durationText, current: duration), d >= 1 else { return nil }
        return d
    }
    private var endPastFile: Bool {
        guard let s = typedStart, let d = typedDuration else { return false }
        return s + d - 1 > model.lastFrame
    }
    private var endLabel: String {
        guard let s = typedStart, let d = typedDuration else { return "—" }
        return basis.label(s + d - 1)
    }
    private var canSave: Bool { typedStart != nil && typedDuration != nil && !endPastFile }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Marker" : "Marker").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Time").gridColumnAlignment(.trailing)
                    HStack(spacing: 14) {
                        tcField($startText, field: .start, invalid: typedStart == nil,
                                help: "As timecode entry: digits fill from the right (100 is 00:00:01:00); + or − for relative")
                        Text("Duration")
                        tcField($durationText, field: .duration, invalid: typedDuration == nil || endPastFile,
                                help: "As timecode entry: 100 is one second, 1 is one frame; + or − to lengthen or shorten")
                        Text("End").foregroundStyle(.secondary)
                        Text(endLabel).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Name")
                    TextField("", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .name)
                }
                GridRow(alignment: .top) {
                    Text("Notes").padding(.top, 4)
                    TextEditor(text: $draft.notes)
                        .font(.body)
                        .frame(minHeight: 90, maxHeight: 180)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                }
                GridRow {
                    Text("Keyword")
                    TextField("Separate keywords with commas", text: $keywordsText)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Color")
                    MarkerColorPicker(selection: $draft.color)
                }
            }
            if let i = model.inPoint, let o = model.outPoint, o >= i {
                Button("Set Time and Duration from In and Out") {
                    start = i; duration = o - i + 1
                    startText = basis.label(i); durationText = basis.durationLabel(o - i + 1)
                }
                .help("In \(basis.label(i)), Out \(basis.label(o))")
            }
            if endPastFile { Text("The marker would end after the file’s last frame.").font(.caption).foregroundStyle(.red) }
            if let refusal { Text(refusal).font(.caption).foregroundStyle(.red) }
            HStack {
                if !isNew {
                    Button("Remove Marker", role: .destructive) {
                        model.delete([draft.id])
                        model.cancelEditor()
                    }
                }
                Spacer()
                Button("Cancel") { model.cancelEditor() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Done") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(18)
        .frame(width: 560)
        .onAppear { focus = .name }
        // Leaving a timecode field commits it (Tab, a click elsewhere).
        .onChange(of: focus) { old, _ in
            if old == .start { commitStart() }
            if old == .duration { commitDuration() }
        }
        .onChange(of: startText) { refusal = nil }
    }

    private func tcField(_ text: Binding<String>, field: Field, invalid: Bool, help: String) -> some View {
        TextField("", text: text)
            .font(.system(.body, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .frame(width: 112)
            .foregroundStyle(invalid ? Color.red : Color.primary)
            .focused($focus, equals: field)
            .onSubmit { field == .start ? commitStart() : commitDuration() }
            .help(help)
    }

    /// The typed Time becomes the value and full SMPTE. Not a timecode: left as typed, in red.
    private func commitStart() {
        guard let f = typedStart else { return }
        start = f
        startText = basis.label(f)
    }

    private func commitDuration() {
        guard let d = typedDuration else { return }
        duration = d
        durationText = basis.durationLabel(d)
    }

    private func save() {
        // What is in the fields now, typed or committed: Return in a field reaches here too.
        guard let s = typedStart, let d = typedDuration, !endPastFile else { return }
        commitStart(); commitDuration()
        var m = draft
        m.frame = s
        m.duration = d
        m.name = Marker.singleLine(m.name)
        m.keywords = Marker.cleanKeywords(keywordsText.components(separatedBy: ","))
        refusal = model.commitEditor(m)
    }
}

/// Resolve's 16 swatches in its order; the name is the tooltip and the accessibility label.
struct MarkerColorPicker: View {
    @Binding var selection: MarkerColor

    var body: some View {
        HStack(spacing: 5) {
            ForEach(MarkerColor.allCases) { c in
                Button { selection = c } label: {
                    Circle()
                        .fill(c.swatch)
                        .frame(width: 15, height: 15)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: selection == c ? 2 : 0))
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help(c.name)
                .accessibilityLabel(c.name)
                .accessibilityAddTraits(selection == c ? .isSelected : [])
            }
        }
    }
}

extension MarkerColor {
    /// The swatch, sRGB.
    var swatch: Color { Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue) }
    var nsColor: NSColor { NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1) }
}

/// Presents the editor for a window's markers. A background host with its own sheet, as `CalibrationSheetHost` is,
/// because ContentView's body is at the type-checker's limit.
struct MarkerEditorHost: View {
    @ObservedObject var model: MarkerModel

    var body: some View {
        Color.clear
            .sheet(item: Binding(get: { model.editorMarker }, set: { if $0 == nil { model.cancelEditor() } })) { marker in
                if let basis = model.basis {
                    MarkerEditorSheet(model: model, marker: marker, basis: basis, isNew: model.editorIsNew)
                } else {
                    Text("This file has no frame rate to place a marker on.").padding(20)
                        .onTapGesture { model.cancelEditor() }
                }
            }
    }
}

/// The transport scrubber with this window's markers on it (docs/MARKERS_PLAN.md §4.3). Observes the markers so the
/// flags follow every change; everything else is `TransportScrubber`'s, unchanged.
struct MarkedTransportScrubber: View {
    @ObservedObject var markers: MarkerModel
    /// View ▸ Show Markers: off hides the flags, deletes nothing.
    @AppStorage(MarkerSettings.showKey) private var showMarkers = true
    var value: Double
    var range: ClosedRange<Double>
    var onChange: (Double) -> Void
    var onEditingChanged: (Bool) -> Void

    var body: some View {
        TransportScrubber(value: value, range: range, onChange: onChange, onEditingChanged: onEditingChanged,
                          markers: trackMarkers, onMarkerClicked: { i in
                              let shown = showMarkers && markers.isActive ? markers.markers : []
                              if shown.indices.contains(i) { markers.go(to: shown[i]) }
                          })
    }

    private var trackMarkers: [TrackMarker] {
        guard showMarkers, markers.isActive, let b = markers.basis, b.rate > 0 else { return [] }
        return markers.markers.map { m in
            TrackMarker(start: Double(m.frame) / b.rate, end: Double(m.lastFrame + 1) / b.rate, color: m.color.nsColor,
                        label: m.name.isEmpty ? b.label(m.frame) : "\(b.label(m.frame))  \(m.name)")
        }
    }
}
