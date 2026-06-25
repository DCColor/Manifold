import SwiftUI

// Framing-guide visual constants — defaults for this pass; full style controls
// (line color/width, darken amount, safe lines) come in a later pass.
let guideDarkenOpacity: Double = 0.85   // black over video area outside the crop
let guideLineWidth: CGFloat = 2         // crop-edge guide line thickness (pt)
let guideLineOpacity: Double = 1.0      // crop-edge guide line opacity

/// Cinema / traditional aspect ratios (decimal W/H, used directly by the crop math).
/// 1.77 ≈ 16:9 (effectively a no-op on a 16:9 source).
let cinemaGuides: [(label: String, ratio: Double)] = [
    ("1.33", 1.33), ("1.66", 1.66), ("1.77", 16.0 / 9.0), ("1.85", 1.85),
    ("2.0", 2.0), ("2.35", 2.35), ("2.39", 2.39), ("2.40", 2.40)
]

/// Non-destructive aspect-ratio framing guide drawn OVER the displayed video rect.
/// This view must be attached so its bounds equal the video's on-screen rect (attach
/// it as an overlay on the aspect-fit video container) — then the crop tracks the
/// video through letterbox/pillarbox fit and window scaling automatically. Draws on
/// top of the video; never touches video pixels.
struct GuideOverlay: View {
    let aspect: Double   // target crop aspect (W/H)

    var body: some View {
        Canvas { ctx, size in
            guard size.width > 0, size.height > 0, aspect > 0 else { return }

            // This view's bounds ARE the displayed video rect.
            let vr = CGRect(origin: .zero, size: size)
            let frameAR = size.width / size.height
            let cropW: CGFloat
            let cropH: CGFloat
            if aspect < frameAR {            // pillarbox — crop narrower (bars on sides)
                cropH = vr.height
                cropW = vr.height * aspect
            } else {                          // letterbox — crop shorter (bars top/bottom)
                cropW = vr.width
                cropH = vr.width / aspect
            }
            let cropLeft = vr.minX + (vr.width - cropW) * 0.5
            let cropTop  = vr.minY + (vr.height - cropH) * 0.5
            let crop = CGRect(x: cropLeft, y: cropTop, width: cropW, height: cropH)

            // Darken inside the video rect but OUTSIDE the crop (even-odd ring fill).
            // Only over the video area (vr) — the window's letterbox bars are outside
            // this view and stay untouched.
            var outside = Path(vr)
            outside.addRect(crop)
            ctx.fill(outside, with: .color(.black.opacity(guideDarkenOpacity)),
                     style: FillStyle(eoFill: true))

            // Guide lines just OUTSIDE each crop edge, growing outward into the dark.
            let w = guideLineWidth
            let c = GraphicsContext.Shading.color(.white.opacity(guideLineOpacity))
            ctx.fill(Path(CGRect(x: crop.minX - w, y: crop.minY - w, width: w, height: crop.height + 2 * w)), with: c) // left
            ctx.fill(Path(CGRect(x: crop.maxX,     y: crop.minY - w, width: w, height: crop.height + 2 * w)), with: c) // right
            ctx.fill(Path(CGRect(x: crop.minX - w, y: crop.minY - w, width: crop.width + 2 * w, height: w)), with: c) // top
            ctx.fill(Path(CGRect(x: crop.minX - w, y: crop.maxY,     width: crop.width + 2 * w, height: w)), with: c) // bottom
        }
        .allowsHitTesting(false)   // overlay never blocks clicks on video/controls
    }
}

/// Panel opened from the guides button. This pass: an "Off" option + a "Cinema"
/// section (one selected at a time). Future "Social" / "Custom" groups slot in as
/// additional sections below, using the same guideActive/guideAspect selection model.
struct GuidesPanel: View {
    @AppStorage("guideActive") private var guideActive = false
    @AppStorage("guideAspect") private var guideAspect = 2.39

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Framing Guides")
                .font(.headline)
                .padding(.bottom, 2)

            row(label: "Off", selected: !guideActive) { guideActive = false }

            Divider().padding(.vertical, 2)

            Text("Aspect")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(cinemaGuides, id: \.ratio) { g in
                row(label: g.label,
                    selected: guideActive && abs(guideAspect - g.ratio) < 0.0001) {
                    guideAspect = g.ratio
                    guideActive = true
                }
            }
        }
        .padding(12)
        .frame(width: 180)
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
}
