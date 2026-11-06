//
//  StillImageSurface.swift
//  Manifold
//
//  A still, drawn by macOS and never by Manifold's renderer: no Metal, no shader, no LUT, no display mode
//  (docs/STILLS_AND_AUDIO_ONLY_PLAN.md §2).
//
//  ⚠️ ITS OWN FILE AND ITS OWN Views, for the reason DisplayTransformControl.swift gives: ContentView's body is at the
//  type-checker's limit.
//

import AppKit
import SwiftUI
import ManifoldCore
import StillImageInfo

struct StillImageSurface: NSViewRepresentable {
    /// What the chain readout and the greyed controls say. Exactly what happens to the picture.
    static let colorLine = "Still image: shown as macOS shows it"

    @ObservedObject var engine: FrameEngine

    /// The picture rect sizes this view, never the image: a plain `NSImageView` reports the image's pixels as its intrinsic
    /// size, which would hold SwiftUI's layout at 5712 points.
    final class View: NSImageView {
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    }

    func makeNSView(context: Context) -> View {
        let view = View()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = false
        view.isEditable = false
        // A drop on the window belongs to the window: `NSImageView` registers for image drags of its own.
        view.unregisterDraggedTypes()
        // ⚠️ `.constrainedHigh`, STATED, AND NOT `.high`. Route C of B0: `.high` was brighter than Preview on the LG, and
        // this matches it side by side (docs/STILLS_AND_AUDIO_ONLY_PLAN.md, B0 result).
        view.preferredImageDynamicRange = .constrainedHigh
        view.setAccessibilityIdentifier("stillImageSurface")
        return view
    }

    func updateNSView(_ view: View, context: Context) {
        guard let picture = engine.stillPicture else {
            view.image = nil
            return
        }
        // Compared because SwiftUI updates this for any published change, and an `NSImage` is a new object each time.
        if context.coordinator.shown !== picture {
            context.coordinator.shown = picture
            view.image = NSImage(cgImage: picture, size: NSSize(width: picture.width, height: picture.height))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown: CGImage?
    }
}

/// What sits where the scrubber does while a still is open.
struct StillTransportLine: View {
    @ObservedObject var engine: FrameEngine

    var body: some View {
        Text(engine.stillInfo?.transportLine ?? "")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
            // One line, always, for the reason `scrubberRow` gives: the docked bar's height feeds the window's.
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("stillTransportLine")
    }
}
