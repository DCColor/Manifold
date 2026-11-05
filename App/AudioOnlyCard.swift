//
//  AudioOnlyCard.swift
//  Manifold
//
//  What the window shows for an audio-only file (docs/STILLS_AND_AUDIO_ONLY_PLAN.md §5.2): file name, format, channels,
//  sample rate, duration. The Metal and sample-buffer surfaces stay behind it, black.
//
//  ⚠️ ITS OWN FILE AND ITS OWN View, for the reason DisplayTransformControl.swift gives: ContentView's body is at the
//  type-checker's limit. ContentView adds one overlay and no modifiers.
//

import SwiftUI
import ManifoldCore
import AudioFileInfo

/// The words on the card, from the engine's facts. The Inspector reads the same lines, so the two cannot disagree.
struct AudioOnlyFacts: Equatable {
    var format: String
    var channels: String
    var sampleRate: String

    /// Nil until the file's metadata has been read. `metadata` can still be the previous file's for a moment after the
    /// commit, so it must name this file.
    @MainActor
    init?(engine: FrameEngine) {
        guard let m = engine.metadata, m.fileName == engine.currentURL?.lastPathComponent else { return nil }
        let index = m.audioTracks.indices.contains(engine.selectedAudioTrackIndex) ? engine.selectedAudioTrackIndex : 0
        guard m.audioTracks.indices.contains(index) else { return nil }
        let track = m.audioTracks[index]
        format = AudioCardText.format(container: m.container, codec: track.codecName, bitDepth: track.bitDepth,
                                      isFloat: track.isFloat)
        channels = AudioCardText.channels(count: track.channelCount,
                                          declaredLayout: track.layoutConfidence == .declared ? track.layoutName : nil)
        sampleRate = AudioCardText.sampleRate(track.sampleRate)
    }
}

struct AudioOnlyCard: View {
    @ObservedObject var engine: FrameEngine
    /// Height kept clear at the bottom, so the floating controls never cover the card.
    var bottomClearance: CGFloat

    private var name: String { engine.currentURL?.lastPathComponent ?? "" }

    var body: some View {
        ZStack {
            Color.black
            // The roomy form, or the one that still fits above the controls in a short window.
            ViewThatFits(in: .vertical) {
                content(spacing: 8, showsIcon: true)
                content(spacing: 2, showsIcon: false)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, bottomClearance)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("audioOnlyCard")
    }

    private func content(spacing: CGFloat, showsIcon: Bool) -> some View {
        VStack(spacing: spacing) {
            if showsIcon {
                Image(systemName: "waveform")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
            }
            Text(name)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
            if let facts = AudioOnlyFacts(engine: engine) {
                line(facts.format)
                line(facts.channels)
                line(facts.sampleRate)
            }
            line(AudioCardText.duration(engine.duration))
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(1)
    }
}
