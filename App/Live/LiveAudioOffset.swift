//
//  LiveAudioOffset.swift — the per-source audio offset O, stage B (docs/AUDIO_RESAMPLER_DESIGN.md
//  §19.4, §19.8): the session value per window, its standing indicator, and the control.
//
//  O > 0 = the sound is heard LATER. The mechanism is stage A's (§19.1, §19.7): FrameEngine hands
//  the value to the steering, which moves its line and requests ONE splice, or refuses an advance
//  the queue cannot cover. This file is only the user's side of that:
//
//    * THE SESSION VALUE. Set at connect from the bookmark the stream was connected from (nil = 0),
//      or 0 for anything without one (NDI, a pasted URL, the DEBUG ⌃⌥D override). The nudge keys and
//      the control edit it. It lasts for the connect: every live-audio session the transport opens
//      inside it starts on it (`FrameEngine.liveAudioSessionOffset`).
//    * SAVE TO BOOKMARK persists it into that bookmark, and nothing else does. Editing the field in
//      the Stream Sources sheet changes the STORED value, which applies from the next connect.
//    * THE INDICATOR, whenever O ≠ 0: a control-bar badge and the window-title suffix
//      " — A/V +80 ms" (`WindowDeck.windowTitle`). Nothing is drawn over the picture — the same rule
//      the Bypass marker was placed under (COLOR_MANAGEMENT_FINDINGS.md §6.8). ⚠️ The badge lives in
//      the control bar and so hides with the OVERLAY HUD exactly as the Bypass badge does; the title
//      is the part that does not auto-hide. Full screen has no marker: accepted, as for Bypass.
//    * REFUSALS ARE SAID, never applied in part: an advance the queue cannot cover, a value outside
//      the range, pinned mode. In plain words, in the window's notice banner.
//    * HLS: no offset. Apple's player owns the audio; the control is disabled and says so.
//

import SwiftUI
import AppKit
import ManifoldCore
import StreamBookmarkModel

// MARK: - The session value, per window

@MainActor
final class LiveAudioOffsetModel: ObservableObject {
    /// O for the current connect, ms. 0 when nothing is connected or nothing was set.
    @Published private(set) var sessionMs = 0
    /// The bookmark this connect came from, and its stored value at connect or at the last save.
    @Published private(set) var bookmarkID: UUID?
    @Published private(set) var bookmarkName: String?
    @Published private(set) var savedMs: Int?
    @Published private(set) var source: LiveSource?

    private weak var deck: WindowDeck?

    init(deck: WindowDeck) { self.deck = deck }

    /// The one-line note the disabled HLS control carries.
    static let hlsNote = "No audio offset on HLS — Apple’s player owns the audio."

    /// An offset can be applied to this connect: a live source Manifold plays the audio of.
    var isAvailable: Bool { source != nil && source != .hls }

    /// The saved value differs from the session's: Save to Bookmark has something to do.
    var differsFromSaved: Bool { bookmarkID != nil && (savedMs ?? 0) != sessionMs }

    // MARK: Connect

    /// A connect is starting from this window (`DeckRegistry.connectLive`, the one funnel). The
    /// session value is the bookmark's, or 0; it is handed to the engine BEFORE the transport opens
    /// its audio session, so the first anchor places it with no splice.
    func prepare(source: LiveSource, bookmark: StreamBookmark?) {
        self.source = source
        bookmarkID = source == .hls ? nil : bookmark?.id
        bookmarkName = source == .hls ? nil : bookmark?.name
        savedMs = source == .hls ? nil : bookmark?.audioOffsetMs
        sessionMs = source == .hls ? 0 : (bookmark?.audioOffsetMs ?? 0)
        deck?.engine?.liveAudioSessionOffset = Double(sessionMs) / 1000
        NSLog("[AUDIO-OFFSET] connect (%@) — session value %@ (%@)",
              String(describing: source), Self.text(sessionMs),
              source == .hls ? "HLS: no offset, Apple’s player owns the audio"
                  : bookmark == nil ? "no saved stream: this connection only"
                  : "from the saved stream’s setting")
        deck?.applyWindowTitle()
    }

    // MARK: Changes

    /// ⌥] / ⌥[ (±1 ms), ⇧ for ±10, and the control's items.
    func nudge(byMs delta: Int) { set(sessionMs + delta) }

    /// Ask for O = `ms`. Applied whole or refused whole, with the refusal said in plain words.
    func set(_ ms: Int) {
        guard isAvailable else {
            if source == .hls { notice(Self.hlsNote) }
            return
        }
        let range = FrameEngine.liveAudioOffsetRangeMs
        guard range.contains(ms) else {
            notice("The audio offset can be set from \(Self.signed(range.lowerBound)) to "
                   + "\(Self.signed(range.upperBound)) ms. It stays at \(Self.text(sessionMs)).")
            return
        }
        guard ms != sessionMs, let engine = deck?.engine else { return }
        if let outcome = engine.setLiveAudioOffset(Double(ms) / 1000) {
            switch outcome {
            case let .applied(_, new, _), let .pending(_, new):
                sessionMs = Int((new * 1000).rounded())
            case let .refusedAdvance(_, _, available, _):
                notice(Self.refusalText(availableSeconds: available, current: sessionMs))
            case .outOfRange:
                notice("The audio offset can be set from \(Self.signed(range.lowerBound)) to "
                       + "\(Self.signed(range.upperBound)) ms.")
            case .disabledPinned:
                notice("The audio offset is off while the resampler ratio is pinned (a debug setting).")
            case .refusedByStage:
                notice("Couldn’t change the audio offset on this stream right now.")
            case .unchanged, .retired:
                break
            }
        } else {
            // Connecting: no audio session yet. The value is placed when it opens.
            engine.liveAudioSessionOffset = Double(ms) / 1000
            sessionMs = ms
        }
        deck?.applyWindowTitle()
    }

    /// Persist the session value into the bookmark this connect came from.
    func saveToBookmark() {
        guard let id = bookmarkID else { return }
        switch StreamBookmarkStore.shared.setAudioOffset(sessionMs, forBookmark: id) {
        case .success(let b):
            savedMs = b.audioOffsetMs
            NSLog("[AUDIO-OFFSET] saved %@ to the saved stream", Self.text(sessionMs))
        case .failure(let e):
            notice(e.message)
        }
    }

    /// Back to what the bookmark has stored (0 for none).
    func revertToSaved() { set(savedMs ?? 0) }

    private func notice(_ text: String) {
        NSLog("[AUDIO-OFFSET] notice: %@", text)
        deck?.engine?.playbackNotice = text
    }

    // MARK: Words

    /// "+80 ms", "−40 ms", "0 ms" — a typographic minus, as the badge prints it.
    static func text(_ ms: Int) -> String { ms == 0 ? "0 ms" : "\(signed(ms)) ms" }
    static func signed(_ ms: Int) -> String { ms > 0 ? "+\(ms)" : ms < 0 ? "−\(-ms)" : "0" }

    /// The badge and the title suffix's words.
    static func indicator(_ ms: Int) -> String { "A/V \(text(ms))" }

    /// Stage A's refusal, in plain words. The figure is what the queue allows NOW, floored to whole
    /// ms so the sentence never promises a fraction the next press could not deliver.
    static func refusalText(availableSeconds: Double, current: Int) -> String {
        let ms = Int((max(0, availableSeconds) * 1000).rounded(.down))
        return ms >= 1
            ? "Can move sound earlier by at most \(ms) ms on this stream right now. It stays at \(text(current))."
            : "Can’t move sound any earlier on this stream right now — it arrives too close to when it plays. It stays at \(text(current))."
    }
}

// MARK: - The control-bar item

/// The audio offset's control and its standing badge, for ONE window. Shown only while this window
/// has a live source. Same construction as `DisplayTransformControl`, for the reasons recorded
/// there: the badge is a SIBLING of the menu (a borderless menu label loses its colours), and this is
/// one element in `ContentView`'s control bar with no modifiers.
struct AudioOffsetControl: View {
    @ObservedObject var model: LiveAudioOffsetModel

    var body: some View {
        HStack(spacing: 5) {
            if model.isAvailable && model.sessionMs != 0 { badge }
            if model.isAvailable {
                Menu { menuContent } label: { label }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
            } else {
                // HLS: disabled, and the note is ON the control, not only in a tooltip.
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                    Text("A/V offset — not on HLS")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .fixedSize()
                }
                .opacity(0.45)
                .accessibilityLabel(LiveAudioOffsetModel.hlsNote)
            }
        }
        .help(model.isAvailable
              ? "Audio offset for this stream: \(LiveAudioOffsetModel.text(model.sessionMs)). "
                + "Positive = sound later. ⌥] / ⌥[ = ±1 ms, with ⇧ = ±10 ms."
              : LiveAudioOffsetModel.hlsNote)
    }

    /// ⚠️ THE STANDING INDICATOR, whenever O ≠ 0. A filled cyan capsule, so it reads as a SETTING
    /// that is on, distinct from Bypass's amber WARNING. Nothing is drawn when O = 0.
    private var badge: some View {
        HStack(spacing: 3) {
            Image(systemName: "waveform")
                .imageScale(.small)
            Text(LiveAudioOffsetModel.indicator(model.sessionMs))
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Self.badgeColour))
        .foregroundStyle(.black)
        .accessibilityLabel("Audio offset \(LiveAudioOffsetModel.text(model.sessionMs))")
        .accessibilityAddTraits(.isStaticText)
    }

    /// sRGB (0.35, 0.80, 1.00): the pixel check in §19.8 counts this colour.
    static let badgeColour = Color(.sRGB, red: 0.35, green: 0.80, blue: 1.00)

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform")
            Text("A/V")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .fixedSize()
        }
        .accessibilityLabel("Audio offset: \(LiveAudioOffsetModel.text(model.sessionMs))")
    }

    @ViewBuilder
    private var menuContent: some View {
        // The keys are named in the titles, NOT bound here: a key equivalent on a control-bar
        // menu's item would be a second claimant for the chord (TransportKeyMonitor handles it).
        Button("Sound later +1 ms      ⌥]") { model.nudge(byMs: 1) }
        Button("Sound earlier −1 ms    ⌥[") { model.nudge(byMs: -1) }
        Button("Sound later +10 ms     ⇧⌥]") { model.nudge(byMs: 10) }
        Button("Sound earlier −10 ms   ⇧⌥[") { model.nudge(byMs: -10) }
        Divider()
        Button("Reset to 0 ms") { model.set(0) }
            .disabled(model.sessionMs == 0)
        Divider()
        if let name = model.bookmarkName {
            Button("Save \(LiveAudioOffsetModel.text(model.sessionMs)) to “\(name)”") { model.saveToBookmark() }
                .disabled(!model.differsFromSaved)
            Button("Revert to Saved (\(LiveAudioOffsetModel.text(model.savedMs ?? 0)))") { model.revertToSaved() }
                .disabled(!model.differsFromSaved)
        } else {
            Text("Not a saved stream: this offset lasts for this connection only")
        }
    }
}
