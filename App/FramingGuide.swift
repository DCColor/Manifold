import SwiftUI

/// Which framing guide is active. Persisted as String raw value. Distinguishes a
/// preset aspect (uses guideAspect) from Custom (uses customW/customH, a dynamic ratio).
enum GuideMode: String, CaseIterable, Identifiable {
    case off, aspect, custom
    var id: String { rawValue }
}

/// Aspect group (cinema / traditional). Decimal W/H, used directly. 1.77 = exact 16:9.
let cinemaGuides: [(label: String, ratio: Double)] = [
    ("1.33", 1.33), ("1.66", 1.66), ("1.77", 16.0 / 9.0), ("1.85", 1.85),
    ("2.0", 2.0), ("2.35", 2.35), ("2.39", 2.39), ("2.40", 2.40)
]

/// Social group. Exact fractions (these pillarbox on a 16:9 source). 16:9 lives in
/// the Aspect group already, so it isn't duplicated here.
let socialGuides: [(label: String, ratio: Double)] = [
    ("9:16", 9.0 / 16.0), ("1:1", 1.0), ("4:5", 4.0 / 5.0),
    ("2:3", 2.0 / 3.0), ("3:2", 3.0 / 2.0)
]

/// Platform safe-line presets (approximate keep-out zones, fractions of video height).
let safeLinePresets: [(label: String, top: Double, bottom: Double)] = [
    ("TikTok", 0.05, 0.80),
    ("Reels", 0.05, 0.82),
    ("Shorts", 0.05, 0.85)
]

/// Non-destructive framing overlay: an aspect crop box (darken outside + edge lines)
/// and/or two horizontal safe lines, drawn OVER the displayed video rect. Self-contained
/// and reactive — reads all guide state + styling from Preferences via @AppStorage, so
/// it updates live. Must be attached as an overlay on the aspect-fit video container so
/// its bounds equal the video's on-screen rect (tracks letterbox/pillarbox + scaling).
/// Never touches video pixels; draws on top.
struct GuideOverlay: View {
    // Framing decisions
    @AppStorage("guideMode") private var guideMode: GuideMode = .off
    @AppStorage("guideAspect") private var guideAspect = 2.39
    @AppStorage("customW") private var customW = 9.0
    @AppStorage("customH") private var customH = 16.0
    @AppStorage("safeLinesOn") private var safeLinesOn = false
    @AppStorage("safeTop") private var safeTop = 0.10
    @AppStorage("safeBottom") private var safeBottom = 0.90
    // Styling (set in Settings; defaults reproduce Pass 1's look)
    @AppStorage("guideDarkenOpacity") private var darkenOpacity = 0.85
    @AppStorage("guideDarkenColor") private var darkenHex = "000000"
    @AppStorage("guideLineColor") private var lineHex = "FFFFFF"
    @AppStorage("guideLineWidth") private var lineWidth = 2.0
    @AppStorage("safeLineColor") private var safeHex = "FFFF00"
    @AppStorage("safeLineWidth") private var safeWidth = 1.0
    @AppStorage("safeLineOpacity") private var safeOpacity = 0.75

    /// The active crop aspect (W/H), or nil if no crop guide is shown.
    private var cropAspect: Double? {
        switch guideMode {
        case .off:    return nil
        case .aspect: return guideAspect
        case .custom: return customH > 0 ? customW / customH : nil
        }
    }

    var body: some View {
        Canvas { ctx, size in
            guard size.width > 0, size.height > 0 else { return }
            let vr = CGRect(origin: .zero, size: size)   // this view's bounds = video rect

            // --- Aspect crop (Pass 1 math, now fed by styling prefs) ---
            if let aspect = cropAspect, aspect > 0 {
                let frameAR = size.width / size.height
                let cropW: CGFloat
                let cropH: CGFloat
                if aspect < frameAR {            // pillarbox — narrower than source
                    cropH = vr.height
                    cropW = vr.height * aspect
                } else {                          // letterbox — shorter than source
                    cropW = vr.width
                    cropH = vr.width / aspect
                }
                let crop = CGRect(x: vr.minX + (vr.width - cropW) * 0.5,
                                  y: vr.minY + (vr.height - cropH) * 0.5,
                                  width: cropW, height: cropH)

                let darken = ScopeColorCodec.color(fromHex: darkenHex)
                var outside = Path(vr)
                outside.addRect(crop)
                ctx.fill(outside, with: .color(darken.opacity(darkenOpacity)),
                         style: FillStyle(eoFill: true))

                let lc = ScopeColorCodec.color(fromHex: lineHex)
                let w = CGFloat(lineWidth)
                let shade = GraphicsContext.Shading.color(lc)
                ctx.fill(Path(CGRect(x: crop.minX - w, y: crop.minY - w, width: w, height: crop.height + 2 * w)), with: shade) // left
                ctx.fill(Path(CGRect(x: crop.maxX,     y: crop.minY - w, width: w, height: crop.height + 2 * w)), with: shade) // right
                ctx.fill(Path(CGRect(x: crop.minX - w, y: crop.minY - w, width: crop.width + 2 * w, height: w)), with: shade) // top
                ctx.fill(Path(CGRect(x: crop.minX - w, y: crop.maxY,     width: crop.width + 2 * w, height: w)), with: shade) // bottom
            }

            // --- Safe lines (full width across the video rect, independent of crop) ---
            if safeLinesOn {
                let sc = ScopeColorCodec.color(fromHex: safeHex).opacity(safeOpacity)
                let sw = CGFloat(safeWidth)
                let yTop = vr.minY + vr.height * CGFloat(safeTop)
                let yBot = vr.minY + vr.height * CGFloat(safeBottom)
                ctx.fill(Path(CGRect(x: vr.minX, y: yTop - sw / 2, width: vr.width, height: sw)), with: .color(sc))
                ctx.fill(Path(CGRect(x: vr.minX, y: yBot - sw / 2, width: vr.width, height: sw)), with: .color(sc))
            }
        }
        .allowsHitTesting(false)   // never blocks clicks on video/controls
    }
}

/// Panel off the guides button — FRAMING DECISIONS ONLY (styling lives in Settings).
/// Off / Aspect / Social / Custom for the crop; then a Safe Lines section.
struct GuidesPanel: View {
    @AppStorage("guideMode") private var guideMode: GuideMode = .off
    @AppStorage("guideAspect") private var guideAspect = 2.39
    @AppStorage("customW") private var customW = 9.0
    @AppStorage("customH") private var customH = 16.0
    @AppStorage("safeLinesOn") private var safeLinesOn = false
    @AppStorage("safeTop") private var safeTop = 0.10
    @AppStorage("safeBottom") private var safeBottom = 0.90

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Framing Guides").font(.headline).padding(.bottom, 2)

            row(label: "Off", selected: guideMode == .off) { guideMode = .off }

            Divider().padding(.vertical, 2)
            Text("Aspect").font(.caption).foregroundStyle(.secondary)
            ForEach(cinemaGuides, id: \.ratio) { g in
                row(label: g.label, selected: isAspectSelected(g.ratio)) {
                    guideAspect = g.ratio; guideMode = .aspect
                }
            }

            Divider().padding(.vertical, 2)
            Text("Social").font(.caption).foregroundStyle(.secondary)
            ForEach(socialGuides, id: \.ratio) { g in
                row(label: g.label, selected: isAspectSelected(g.ratio)) {
                    guideAspect = g.ratio; guideMode = .aspect
                }
            }

            Divider().padding(.vertical, 2)
            HStack(spacing: 8) {
                Button { guideMode = .custom } label: {
                    HStack(spacing: 8) {
                        Image(systemName: guideMode == .custom ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(guideMode == .custom ? Color.accentColor : .secondary)
                        Text("Custom")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text("W").font(.caption).foregroundStyle(.secondary)
                customField($customW)
                Text("H").font(.caption).foregroundStyle(.secondary)
                customField($customH)
            }

            Divider().padding(.vertical, 2)
            Toggle("Safe Lines", isOn: $safeLinesOn)
                .font(.caption)
            Menu("Platform preset") {
                ForEach(safeLinePresets, id: \.label) { p in
                    Button(p.label) { safeTop = p.top; safeBottom = p.bottom }
                }
                Button("Custom / Manual") { }   // leaves the user's hand-set values
            }
            .font(.caption)
            .disabled(!safeLinesOn)
            HStack {
                Text("Top").font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                Slider(value: $safeTop, in: 0.0...0.5)
            }.disabled(!safeLinesOn)
            HStack {
                Text("Bot").font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                Slider(value: $safeBottom, in: 0.5...1.0)
            }.disabled(!safeLinesOn)
        }
        .padding(12)
        .frame(width: 280)
    }

    private func isAspectSelected(_ ratio: Double) -> Bool {
        guideMode == .aspect && abs(guideAspect - ratio) < 0.0001
    }

    private func row(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(label)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Compact integer field (1–32). Editing implies the user wants the Custom guide.
    private func customField(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number.precision(.fractionLength(0)))
            .frame(width: 34)
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)
            .onChange(of: value.wrappedValue) { _, v in
                let clamped = min(32, max(1, v.rounded()))
                if clamped != value.wrappedValue { value.wrappedValue = clamped }
                guideMode = .custom
            }
    }
}
