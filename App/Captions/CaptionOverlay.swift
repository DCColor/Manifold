import SwiftUI
import ManifoldCore

/// Where the caption's bottom edge sits in the video rect. A framing decision, so it's chosen
/// from the Aa menu (alongside the guides popover's safe-line presets), not from Settings —
/// same rule the broadcast action/title percentages follow.
enum CaptionPosition: String, CaseIterable, Identifiable {
    case titleSafe, bottom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .titleSafe: return "Title-safe"
        case .bottom:    return "Bottom edge"
        }
    }
}

/// Synced subtitle text drawn OVER the displayed video rect. Like GuideOverlay, this must be
/// attached as an overlay on the aspect-fit video container so its bounds equal the video's
/// on-screen rect — that's what makes the caption track letterbox/pillarbox and scaling for
/// free, and what lets it land on the SAME line the broadcast title-safe box draws.
///
/// A dedicated subview on purpose: it reads `engine.currentTime`, which republishes at the
/// engine's 10 Hz observer rate, so the cue lookup and text layout stay a leaf rather than
/// dragging the video stack's re-evaluation along. The caller gates it out of the tree
/// entirely when captions are off.
struct CaptionOverlay: View {
    @ObservedObject var engine: FrameEngine
    @ObservedObject var captions: CaptionController

    /// The SAME key the broadcast safe zones use, read independently of `broadcastSafeOn`:
    /// the caption tracks the title-safe VALUE whether or not the boxes are being drawn.
    @AppStorage("broadcastTitlePct") private var broadcastTitlePct = Preferences.defaultBroadcastTitlePct
    @AppStorage("manifold.caption.positionPreset") private var position: CaptionPosition = .titleSafe

    /// Caption height as a fraction of the video rect, so text scales with the frame instead of
    /// with the window — the guides derive their tick length from the video rect the same way.
    /// Clamped so a tiny window stays legible and a 4K-tall rect doesn't shout.
    private static let fontFraction: CGFloat = 0.045
    private static let fontRange: ClosedRange<CGFloat> = 12...64
    /// Bottom-edge preset: a 5% margin, i.e. exactly the action-safe line at its 0.90 default.
    private static let bottomEdgeY: CGFloat = 0.95

    var body: some View {
        GeometryReader { geo in
            // geo.size == the video rect (letterboxed), inherited from .aspectRatio(.fit).
            if let text = captions.cue(at: engine.currentTime), !text.isEmpty {
                let fontSize = min(max(geo.size.height * Self.fontFraction, Self.fontRange.lowerBound),
                                   Self.fontRange.upperBound)
                caption(text, fontSize: fontSize)
                    .frame(maxWidth: geo.size.width * 0.8)
                    // Height-limited frame anchored at the rect's top, content bottom-aligned →
                    // the caption's BOTTOM edge lands exactly on baselineY, centred horizontally.
                    .frame(width: geo.size.width, height: baselineY(in: geo.size), alignment: .bottom)
            }
        }
        .allowsHitTesting(false)   // never blocks clicks on video/controls
    }

    private func caption(_ text: String, fontSize: CGFloat) -> some View {
        Text(text)   // cue text keeps its "\n"s, so a two-line cue stays two lines
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)   // wrap, don't truncate
            .padding(.horizontal, fontSize * 0.5)
            .padding(.vertical, fontSize * 0.25)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: fontSize * 0.25))
    }

    /// Y of the caption's bottom edge, in the video rect's coordinates (top-left origin).
    ///
    /// `broadcastTitlePct` is a SIZE fraction (0.80 = the middle 80%, i.e. 10% inset per side),
    /// NOT an absolute Y — so the bottom title-safe line is at height * (1 + pct)/2 (0.90h at
    /// the 0.80 default), which is what FramingGuide's insetBy(dy: height * (1 - pct)/2) draws.
    /// Using height * pct here would put the caption 10% of the frame too high. (The social
    /// safeBottom key is the opposite convention — an absolute Y fraction. Don't cross them.)
    private func baselineY(in size: CGSize) -> CGFloat {
        switch position {
        case .bottom:
            return size.height * Self.bottomEdgeY
        case .titleSafe:
            // Storage doesn't clamp, so the consumer does — same guard the overlay's draw path uses.
            let pct = min(max(broadcastTitlePct, Preferences.broadcastPctRange.lowerBound),
                          Preferences.broadcastPctRange.upperBound)
            return size.height * CGFloat(1 + pct) / 2
        }
    }
}
