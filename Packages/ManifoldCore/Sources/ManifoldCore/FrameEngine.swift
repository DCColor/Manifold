@preconcurrency import AVFoundation
import Combine
// UTType, for the still-image refusal in `loadAsset` — the engine has to answer "can I play this"
// for every entry point, so the type question is asked here rather than in a view.
import UniformTypeIdentifiers

/// Frame-level playback engine (Step 4c-3c, concurrency-hardened): video + audio
/// via AVSampleBufferRenderSynchronizer. The frame pumps run on background queues
/// and capture LOCAL reader/output/renderer references (never reach through self),
/// with a per-session token so a seek can retire a stale pump cleanly. Only
/// published UI state is mutated on the main actor.
/// User assertion of a clip's color range, overriding the file's tag. Transient
/// per-file (resets to `.auto` on each load) — never globally persisted, since
/// one file's correct override would be wrong for the next.
public enum RangeOverride: String, CaseIterable, Sendable {
    case auto    // trust the file's tag (full if tagged-full; else video/legal)
    case full    // force full-range decode regardless of tag
    case legal   // force video/legal-range decode regardless of tag

    public var label: String {
        switch self {
        case .auto:  return "Auto"
        case .full:  return "Full"
        case .legal: return "Legal"
        }
    }
}

/// How to interpret FULL-range chroma — a decode property, not a UI concept.
/// Two conventions exist in the wild (verified against real files):
///  - `.fullSwing`: chroma scale 255 (H.273 / full-swing spec). Renders a
///    spec-conformant full file (75% red Cr≈224) correctly.
///  - `.resolve`: chroma scaled by 219/224 (net ~260.8). Resolve expands
///    full-range chroma by the LUMA factor (255/219), storing Cr≈226 for 75%
///    red; this inverse renders Resolve full files correctly (~191).
/// Only affects the full-range path; legal is unchanged either way. The numeric
/// rawValue is passed to the shader.
public enum FullRangeChromaConvention: Int32, CaseIterable, Sendable {
    case fullSwing = 0
    case resolve   = 1

    /// The single shipping default — Resolve, the common case for this audience.
    public static let defaultConvention: FullRangeChromaConvention = .resolve

    public var label: String {
        switch self {
        case .fullSwing: return "Full-swing (spec)"
        case .resolve:   return "Resolve"
        }
    }
}

@MainActor
public final class FrameEngine: ObservableObject, PlaybackEngine {

    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var displaySize: CGSize?
    @Published public private(set) var hasMedia = false
    @Published public private(set) var metadata: VideoMetadata?
    @Published public private(set) var currentURL: URL?
    // Audio output gain/mute (passthrough to the persistent audioRenderer).
    @Published public private(set) var volume: Float = 1.0
    @Published public private(set) var isMuted: Bool = false

    /// Non-fatal playback notice for the UI's banner: playback is running, but in a degraded mode
    /// the user needs to be told about. Currently one producer — the audio track could not be
    /// added to the reader, so the file is playing VIDEO ONLY. A file that silently plays without
    /// sound and without explanation is its own confusing bug, which is why this is published to
    /// the UI and not merely logged. Cleared by the UI when dismissed, and on the next load.
    @Published public var playbackNotice: String?

    /// True once this file has fallen back to video-only, so the notice is raised ONCE per file
    /// rather than re-firing on every seek (beginReading runs per seek, and the fallback with it).
    private var audioFallbackAnnounced = false

    /// Monotonic load generation. `loadAsset` spawns detached inspection Tasks (metadata, display
    /// size) that outlive the function, so a load which BAILS — or which a newer load supersedes —
    /// must not have their results land on the engine afterwards. Each Task captures the generation
    /// it was started for and publishes only if it is still current.
    private var loadGeneration = 0

    /// The newest position a frame step has asked for, or nil when none is outstanding, plus
    /// whether the drain loop that services it is running. See `stepFrame` for why holding an arrow
    /// key needs these at all.
    private var pendingStepTarget: Double?
    private var stepDrainRunning = false
    // JKL shuttle transport rate (transient session state — not persisted).
    // Signed: > 0 forward, 0 paused, < 0 reverse. Forward rates drive the
    // synchronizer directly; reverse is a best-effort jog (see setShuttleRate).
    @Published public private(set) var shuttleRate: Float = 0
    /// Loop NORMAL FORWARD PLAYBACK back to the top at end-of-media. Deliberately narrow: it fires
    /// only from 1x play (shuttleRate == 1), never while JKL-shuttling (2/4/8x), and there is no
    /// loop-at-head for reverse. Transient session state — not persisted. See the end-of-media observer.
    @Published public private(set) var isLooping: Bool = false
    public private(set) var tcInfo: TimecodeReader.Result?

    /// Maximum shuttle multiplier in either direction (1 → 2 → 4 → 8).
    private let maxShuttleRate: Float = 8
    /// Reverse jog: the forward-only AVAssetReader pump cannot decode backward,
    /// so reverse "playback" is a timer that re-seeks toward the head. Best-effort.
    private var reverseTimer: Timer?
    private let reverseTickInterval: Double = 0.1

    /// Optional tap: called on the video pump queue with each decoded frame,
    /// in ADDITION to the normal display enqueue. Used by a parallel Metal
    /// renderer. Called on a background queue — consumers must hop threads as needed.
    public var onVideoFrame: ((CMSampleBuffer) -> Void)?

    /// Optional: called when the engine flushes for a seek/reload, so a parallel
    /// renderer can clear its frame queue. Called on the main actor.
    public var onFlush: (() -> Void)?

    /// THE SOURCE'S CICP COLOUR CODES, PUBLISHED BEFORE THE FIRST FRAME CAN BE ENQUEUED.
    ///
    /// ── WHY THIS IS A CALLBACK AND NOT A `@Published` PROPERTY ─────────────────────────────
    ///
    /// The layer colorspace used to be derived from `metadata`, through SwiftUI's
    /// `.onChange(of: engine.metadata)`. That is late twice over: `metadata` is produced by a
    /// detached inspection Task that the load path never awaits (it re-opens the file through
    /// libav for HDR10, and reads audio tracks, text tracks, timecode, chapters and common
    /// metadata), and even once it lands, `.onChange` runs a SwiftUI update pass later. Frames
    /// meanwhile flow from `beginReading`. MEASURED: on a 24-track master the first frame was
    /// presented with NO colorspace on the layer, 5 launches out of 5 — and because a
    /// CAMetalLayer applies its colorspace at PRESENT time, the wrong picture then persisted
    /// until the next present. Not a flash: a stuck frame that survived a 15 s wait and a window
    /// move, and corrected only on play.
    ///
    /// A `@Published` property would have kept the SwiftUI hop and therefore kept the race. This
    /// is a direct call, on the main actor, in the same turn as the load — the same shape as
    /// `onVideoFrame` and `onFlush`, and wired in the same place (`DeckRegistry.configure`).
    ///
    /// nil codes mean "no source, or nothing declared" — the renderer resolves that to its 709
    /// default. Publishing nils on unload is what stops a failed open, or an emptied deck, from
    /// leaving the PREVIOUS file's colour space on the layer.
    public var onSourceColorTags: ((Int?, Int?, Int?) -> Void)?

    nonisolated(unsafe) private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var videoRenderer: AVSampleBufferVideoRenderer?
    private let audioRenderer = AVSampleBufferAudioRenderer()

    /// D4b-1: PCM audio tap. Tees decoded audio at BOTH enqueue sites into a PTS-keyed, card-ready
    /// (int32 interleaved) ring buffer, WITHOUT altering what the renderer receives. Read by D4b-2's
    /// DeckLink audio callback; nothing is sent to the card yet. Captured as a local in the enqueue
    /// closures (like the renderers) so it never crosses the main-actor boundary.
    public let audioTap = AudioTapBuffer()

    /// What the DECODER — not AVFoundation's inspector — knows about this source's audio.
    ///
    /// ── WHY THIS EXISTS. ⚠️ THE CONDITION NAMED HERE IS NO LONGER TRUE — SEE BELOW ────────────
    ///
    /// This was added because `metadata.audioTracks` WAS blind on the libav path, and silently so.
    /// `MediaInspector` reads an AVURLAsset, and `loadMXF` never calls it at all (AVFoundation
    /// cannot open MXF), so `metadata.audioTracks` was EMPTY for every MXF — including the ones
    /// playing audio perfectly. Anything that read emptiness as "this file has no audio" was
    /// therefore wrong on a headline format for this app.
    ///
    /// ── WHAT CHANGED, AND WHEN ────────────────────────────────────────────────────────────────
    ///
    /// **2026-08-31, `8492039`** — `applyLibavMetadata` gained a companion, `applyLibavAudioTrack`,
    /// which fills ONE row on the libav path from `LibavAudioSource.AudioInfo`. An MXF stopped
    /// showing an empty Audio section.
    ///
    /// **2026-08-31, the multi-stream enumeration** — that companion now fills one row PER audio
    /// stream, so a four-track MXF has four. `metadata.audioTracks` is no longer blind on this
    /// path at all: it is complete, for description. (It is not a track LIST you can choose from —
    /// `audioTracks`/`audioTrackCount` are still empty here and that is a different question. See
    /// the note on `applyLibavAudioTrack`.)
    ///
    /// ── ⚠️ AND THE REASON SURVIVES ITS ORIGIN STORY, SO DO NOT DELETE THIS ────────────────────
    ///
    /// EMPTINESS STILL CANNOT ANSWER THE QUESTION. A file with no audio stream and a file whose
    /// metadata has not landed yet both present an empty `audioTracks`, and the rows arrive AFTER
    /// the decoder has sized the meters' bars, so the window is real rather than theoretical. A
    /// LIVE source never produces rows of its own — `MediaInspector` needs an `AVURLAsset` and a
    /// push source is not one — and worse, the rows sitting there may describe the last FILE this
    /// deck opened, since `metadata` is not cleared when a stream takes the picture over. So on a
    /// live source the row count is not merely uninformative, it is someone else's answer. That is
    /// why `audioTrackFaceLabel` reads this and why the meters' role closure asks
    /// `LiveSource.connected` before it looks at `audioTracks` at all.
    ///
    /// The distinction that matters to a reader is between "no audio" and "don't know yet", and
    /// only the decode path can tell them apart, because it is the thing that opened the stream.
    /// Both paths set this: libav from `LibavAudioSource.open()`, AVFoundation from whether an
    /// audio track output could be added. Meters key their empty state off it — showing silent
    /// bars for a file that has audio, or "NO AUDIO" for one whose audio simply has not started,
    /// are both lies a colourist would act on.
    @Published public private(set) var audioPresence: AudioPresence = .unknown

    private var asset: AVURLAsset?
    private var videoTrack: AVAssetTrack?
    /// The source's signaled range (from the format description), captured once
    /// per load. Combined with `rangeOverride` to derive the effective range.
    private var sourceRange: MediaInspector.SourceColorRange = .untagged
    /// User range assertion. Transient per-file: reset to `.auto` on each load.
    @Published public private(set) var rangeOverride: RangeOverride = .auto
    /// Effective full-range flag fed to the shader (override resolves source
    /// range). Decode is ALWAYS 420v (raw, unclipped); this flag — not the buffer
    /// format — decides whether the shader expands (legal/video) or passes through
    /// (full). Published for the UI.
    @Published public private(set) var effectiveIsFullRange: Bool = false
    /// Thread-safe mirror of `effectiveIsFullRange` for the render thread
    /// (CVDisplayLink), which cannot touch main-actor state.
    private nonisolated let rangeLock = NSLock()
    private nonisolated(unsafe) var effectiveRangeMirror = false
    /// Active full-range chroma convention (decode property). Default Resolve —
    /// the common case for this audience; full-swing/spec path retained. No
    /// runtime control yet — this is just the default + an inspector readout.
    @Published public private(set) var fullRangeChromaConvention: FullRangeChromaConvention = .defaultConvention
    /// Render-thread mirror of `fullRangeChromaConvention` (guarded by `rangeLock`).
    private nonisolated(unsafe) var chromaConventionMirror: Int32 = FullRangeChromaConvention.defaultConvention.rawValue
    /// Convention rawValue, readable from the render thread (CVDisplayLink).
    public nonisolated func currentChromaConventionRaw() -> Int32 {
        rangeLock.lock(); defer { rangeLock.unlock() }
        return chromaConventionMirror
    }
    /// EVERY audio track the asset carries, in the order AVFoundation returns them (file order).
    ///
    /// ⚠️ THIS USED TO BE A SINGLE `audioTrack` SET FROM `loadTracks(…).first`, AND THAT WAS A
    /// PLAYBACK GAP, NOT A DISPLAY ONE. A file with mono + stereo + 5.1 had two of its three tracks
    /// unreachable: not decoded, not rendered, not tapped, not sent to SDI. The inspector listed all
    /// three (it enumerates the asset directly — see `MediaInspector.audioTracks`), so the two were
    /// describing different things and only the inspector was complete.
    ///
    /// EMPTY ON THE libav PATH. AVFoundation cannot open MXF, so `loadMXF` leaves this empty while
    /// `LibavAudioSource` decodes the first audio stream it finds. Multi-track selection is therefore
    /// an AVFoundation-path capability today; `audioTrackCount` reports 0 there and the UI falls back
    /// to the single-track presentation, which is honest — we genuinely cannot offer a choice.
    private var audioTracks: [AVAssetTrack] = []

    /// Which of `audioTracks` is monitored — the one track that feeds the audio renderer AND the
    /// tap, and therefore the meters and DeckLink too. Always a valid index into `audioTracks`, or 0
    /// when there are none. Reset to 0 on every load: a track index carried across files is a claim
    /// about material no longer open.
    @Published public private(set) var selectedAudioTrackIndex: Int = 0

    /// How many audio tracks the user can choose between. 0 on the libav path and for video-only
    /// files. The UI shows a disabled control at 0 or 1 rather than hiding it — that a file has one
    /// audio track is worth knowing, and a control that appears and disappears is not.
    public var audioTrackCount: Int { audioTracks.count }

    /// The monitored track. Nil for video-only files and on the libav path.
    private var audioTrack: AVAssetTrack? {
        audioTracks.indices.contains(selectedAudioTrackIndex) ? audioTracks[selectedAudioTrackIndex] : nil
    }
    /// The VIDEO reader. Since audio was decoupled this carries exactly one output — the video
    /// track — so a `startReading` failure here is unambiguously the video's fault.
    private var reader: AVAssetReader?

    /// The AUDIO reader — a SECOND `AVAssetReader` over the same asset, carrying only the selected
    /// audio track's output.
    ///
    /// ── WHY AUDIO HAS ITS OWN READER ──────────────────────────────────────────────────────────
    ///
    /// `AVAssetReader` outputs are frozen at `startReading()` — MEASURED: `canAdd` returns true
    /// before the start and false after — so with both tracks on one reader, changing which audio
    /// track is read meant rebuilding the whole thing, which meant re-seeking the VIDEO for a
    /// purely audio-side decision. That is what made a track switch stutter the picture.
    ///
    /// Two readers make the switch free for video: the audio reader is rebuilt and the video reader
    /// is not touched at all. It also removes a hazard that predates the selector — the two outputs
    /// used to share one reader, and `startReading()` is all-or-nothing, so an audio track the
    /// reader refused took the PICTURE down with it (MEASURED in the wild: an ARRI ALEXA Mini
    /// ProRes 4444 XQ whose 5-channel LPCM track advertises channel layout tag 0xFFFF0000 —
    /// `kAudioChannelLayoutTag_Unknown` ORed with a channel count of ZERO while its own ASBD says
    /// 5 — failing -11800 / paramErr -50 seven times in one session, with the tester looking at a
    /// black screen). The retry-without-audio dance that worked around that is GONE: a malformed
    /// audio track can no longer reach the video reader to break it.
    ///
    /// ⚠️ THIS DOES NOT INTRODUCE DRIFT, AND THE REASON IS STRUCTURAL. Neither reader is a clock.
    /// Both renderers hang off the ONE `AVSampleBufferRenderSynchronizer`, and every buffer carries
    /// its SOURCE pts, which comes from the file and not from how far a reader happens to have got.
    /// The synchronizer presents each buffer when its pts is due against a single timebase, so a
    /// reader running ahead or behind changes only its own QUEUE DEPTH, never presentation time.
    /// The failure mode two readers can produce is starvation (a dropout, which self-heals on the
    /// next buffer), not accumulating skew. Contrast the DeckLink audio callback, where host and
    /// card clocks genuinely do diverge and an anchor loop is required — there are two clocks there;
    /// here there is one.
    ///
    /// This also mirrors what the libav path has always done: `LibavFrameSource` and
    /// `LibavAudioSource` are independent demuxers armed separately against the same synchronizer.
    /// The AVFoundation path now has the same shape.
    private var audioReader: AVAssetReader?
    /// The current file's video `FrameSource`. The file decode now flows through
    /// this (Stage 1 seam): it owns the video pump and emits frames via
    /// `onVideoFrame`, which we route to the display renderer + Metal tap below.
    /// Recreated per reading session (a seek retires the old one via `stop()`).
    private var currentSource: FileFrameSource?
    /// The libav-backed video source, used for formats VideoToolbox can't decode
    /// (DNxHR). Stage 2b first light: a single static frame. When set, the
    /// AVFoundation decode path is bypassed for this file.
    private var libavSource: LibavFrameSource?
    /// The libav audio sibling — decodes the DNx file's audio to PCM on the shared
    /// `audioRenderer` (same synchronizer → A/V sync). Nil if the file has no audio.
    private var libavAudioSource: LibavAudioSource?
    /// Set in `loadAsset` when the file's codec needs the libav path (DNxHR).
    private var useLibav = false
    /// Decoded video format requested at the decode-request site. A named property
    /// rather than a magic constant so the sources/decoders can vary it.
    /// M3b: 10-bit 420 biplanar (x420, raw video-range). 10-bit ProRes and DNxHR
    /// HQX now flow through at full bit depth; 8-bit sources decode cleanly into the
    /// 10-bit container. Range expansion stays in the shader (the VideoRange label
    /// is just the container — raw values are preserved, exactly as the 8-bit path).
    private let videoPixelFormat: OSType = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    private var timeObserver: Any?
    private let videoPumpQueue = DispatchQueue(label: "com.graviton.manifold.pump.video")
    private let audioPumpQueue = DispatchQueue(label: "com.graviton.manifold.pump.audio")

    /// Increments each new reading session; a pump checks its captured token
    /// against this and stops if it's been superseded (e.g. by a seek).
    private let sessionToken = SessionToken()

    /// Retirement authority for the AUDIO pump, SEPARATE from `sessionToken`.
    ///
    /// ⚠️ THE SEPARATION IS THE WHOLE POINT AND MUST NOT BE COLLAPSED. A track switch has to retire
    /// the audio pump WITHOUT retiring the video pump — bumping the shared token would stop the
    /// FrameSource mid-playback, which is precisely the stutter this change exists to remove.
    /// `beginReading` bumps BOTH (a seek moves both readers); `selectAudioTrack` bumps only this one.
    ///
    /// ⚠️ AND IT GOVERNS THE libav AUDIO PUMP TOO, WHICH IT DID NOT ALWAYS. `beginLibavReading`
    /// armed `LibavAudioSource` on `sessionToken`, so on the MXF/DNxHR path this token had no audio
    /// pump to retire and the VIDEO token had two — the exact collapse the paragraph above forbids,
    /// on the one path that never got the split. Both paths now establish audio currency here, and
    /// nothing arms an audio pump on `sessionToken`.
    private let audioSessionToken = SessionToken()

    /// ── THE THIRD TOKEN: retirement authority for the SCRUB PRODUCER ──────────────────────────
    ///
    /// Sits beside the two above because it is the same idiom for the same reason, and putting it
    /// here rather than inventing view-side counters is the actual simplification: deleting the
    /// scrub handoff removes three ad-hoc generation checks from `ContentView`, and this is the one
    /// thing that replaces them. ⚠️ **That is a RELOCATION, not a removal.** The asynchrony those
    /// checks existed for is a property of having an out-of-band frame producer, and the producer
    /// is not going away — it moved from a `CGImage` behind a `Task` to a `CVPixelBuffer` behind a
    /// seek completion.
    ///
    /// Bumped on producer teardown and on every load commit.
    private let scrubToken = SessionToken()

    /// The scrub seam. Nil when no producer exists for this source — which in Stage 1 is every
    /// file (the flag is off) and, once the flag is on, still every MXF: AVFoundation cannot open
    /// MXF at all, so that half waits for the libav producer in Stage 3 and keeps the overlay.
    private var scrubCoalescer: ScrubCoalescer?

    /// Called on MAIN with each scrub frame that survives the delivery-side token check. Wired to
    /// `MetalVideoRenderer.presentImmediate` in `DeckRegistry.configure`, alongside `onVideoFrame`
    /// and `onFlush` — the same shape, for the same reason: the renderer lives in the app target.
    public var onScrubFrame: ((CVPixelBuffer, Double) -> Void)?

    public init() {
        synchronizer.addRenderer(audioRenderer)
    }

    /// Adopt a display renderer as this engine's video output.
    ///
    /// THE REMOVE IS LOAD-BEARING, not tidiness. `addRenderer` accumulates: the synchronizer keeps
    /// every renderer ever added and drives them all, while `videoRenderer` — which the decode
    /// pumps enqueue into — only ever points at the LAST one. So a second attach left the previous
    /// renderer permanently on the synchronizer's clock, being timed but never fed, and nothing
    /// released it.
    ///
    /// This was invisible before per-window engines because one engine saw exactly one attach.
    /// It stops being invisible the moment a `SampleBufferNSView` is rebuilt (a re-hosted view, a
    /// surface recreated by SwiftUI) — each rebuild would add another orphan. Removing first makes
    /// attach IDEMPOTENT and the renderer set exactly one element, which is what every other line
    /// in this class already assumes.
    ///
    /// Re-attaching the SAME renderer is a no-op remove followed by a re-add, which is harmless.
    public func attach(renderer: AVSampleBufferVideoRenderer) {
        if let previous = videoRenderer {
            synchronizer.removeRenderer(previous, at: synchronizer.currentTime())
        }
        self.videoRenderer = renderer
        synchronizer.addRenderer(renderer)
    }

    /// The synchronizer's current playback time, readable from any thread
    /// (e.g. a CVDisplayLink render loop). The synchronizer handles its own
    /// thread-safety for this call, so it is nonisolated despite @MainActor.
    public nonisolated func currentSyncTime() -> CMTime {
        synchronizer.currentTime()
    }

    /// True when transport is paused (synchronizer rate 0). Readable from any thread
    /// (the CVDisplayLink render loop), same thread-safety rationale as currentSyncTime().
    public nonisolated func isPausedNow() -> Bool {
        synchronizer.rate == 0
    }

    /// PlaybackEngine conformance: bare load defaults to autoplay.
    public func load(url: URL) {
        load(url: url, autoplay: true)
    }

    public func load(url: URL, autoplay: Bool) {
        // ⚠️ `currentURL` IS NO LONGER SET HERE. It used to be assigned the moment `load` was
        // called, which meant a file that was then REFUSED had already overwritten the URL of the
        // file still on screen — the inspector's "Edit in Flip", the arbiter's window name and the
        // caption sidecar's `onChange(of: currentURL)` all followed a file that never loaded. It is
        // assigned in `loadAsset`'s commit phase now, with everything else the new source owns.
        Task { await loadAsset(url: url, autoplay: autoplay) }
    }

    /// Re-read the current file's metadata from disk (e.g. after editing it in
    /// Flip). Uses a FRESH asset to avoid AVFoundation serving cached metadata for
    /// a rewritten file. The inspector readout always refreshes (cheap, display-
    /// only). If the COLOR-relevant tags actually changed, the render path is
    /// re-derived to match exactly what a fresh open produces — otherwise playback
    /// is left completely undisturbed.
    ///
    /// Why the render path needs more than a metadata refresh: the shader reads the
    /// YCbCr→RGB matrix and transfer from the DECODED pixel buffer's attachments,
    /// and the range from `sourceRange` — both seeded from the DECODE asset, not the
    /// inspector. Re-reading metadata fixes the inspector (and, via the UI's
    /// metadata observer, the layer colorspace) but the decode keeps running on the
    /// stale asset, so the conversion matrix / transfer / range stay old until the
    /// file is reopened. Adopting the fresh asset for decode and rebuilding at the
    /// current position re-stamps buffers with the new attachments and re-reads the
    /// range — the same derivation a fresh open performs.
    public func reinspect() async {
        guard let url = currentURL else { return }
        let freshAsset = AVURLAsset(url: url)
        let newTc = MediaInspector.timecode(for: url)
        let newMeta = await MediaInspector.metadata(for: freshAsset, url: url)

        // Inspector always refreshes.
        let old = self.metadata
        self.tcInfo = newTc
        self.metadata = newMeta

        // Re-derive the render path ONLY when a color-relevant tag changed, so a
        // no-op refresh (or a non-color metadata edit) never disturbs playback.
        let colorChanged =
            old?.colorPrimariesCode   != newMeta.colorPrimariesCode ||
            old?.transferFunctionCode != newMeta.transferFunctionCode ||
            old?.colorMatrixCode      != newMeta.colorMatrixCode ||
            old?.colorRange           != newMeta.colorRange
        guard colorChanged else { return }

        // Adopt the fresh asset for DECODE too (the stale one may serve cached
        // format descriptions for the rewritten file).
        self.asset = freshAsset

        // Rebuild the scrub-preview generator on the fresh asset.
        // THE SCRUB PRODUCER, rebuilt on the fresh asset for the reason stated one line up and
        // not for a new one: a re-inspect follows a REWRITE OF THE SAME FILE, and a producer built
        // on the pre-rewrite asset holds that asset's cached format descriptions exactly as
        // `self.asset` did. (The `AVAssetImageGenerator` that used to be rebuilt here is deleted —
        // this is what replaced it.)
        //
        // ⚠️ ONLY REACHED WHEN A COLOUR TAG CHANGED — the `guard colorChanged` above returns
        // first on a no-op refresh, so this does not pay the 11.9–47.1 ms install on every press
        // of the reload button. `useLibav` is unchanged by a tag rewrite, so it is carried
        // forward rather than re-derived.
        installScrubProducer(for: url, useLibav: useLibav)

        guard let vTrack = try? await freshAsset.loadTracks(withMediaType: .video).first else { return }
        self.videoTrack = vTrack
        // A re-inspect follows a rewrite of the SAME file, so the track set is usually identical —
        // keep the monitored track if the new asset still has one at that index, rather than
        // yanking a colourist back to track 1 because the file was re-wrapped underneath them.
        self.audioTracks = (try? await freshAsset.loadTracks(withMediaType: .audio)) ?? []
        if !self.audioTracks.indices.contains(self.selectedAudioTrackIndex) {
            self.selectedAudioTrackIndex = 0
        }

        // Re-read the source range from the fresh format description and reset the
        // per-file override to Auto — a fresh open does the same; the new tags are
        // authoritative. updateEffectiveRange() pushes the thread-safe mirror the
        // render thread reads, so this can't race the CVDisplayLink.
        rangeOverride = .auto
        if let formats = try? await vTrack.load(.formatDescriptions), let fmt = formats.first {
            sourceRange = MediaInspector.sourceColorRange(for: fmt)
        } else {
            sourceRange = .untagged
        }
        updateEffectiveRange()

        // Rebuild the decode at the current position, preserving play state, so the
        // shader reads buffers stamped with the NEW color attachments. The layer
        // colorspace re-applies separately via the UI's metadata observer
        // (setSourceColorSpace, CATransaction-guarded).
        await beginReading(from: currentTime, resumePlaying: isPlaying)
    }

    /// Set output gain (0–1). Writes through to the persistent audio renderer.
    /// Adjusting volume unmutes (standard behavior). Does not touch audio decode.
    public func setVolume(_ v: Float) {
        let clamped = min(1, max(0, v))
        // ⚠️ THE GUARD IS ON THE PUBLISH ONLY, AND IT IS DELIBERATELY NOT AN EARLY RETURN.
        //
        // `@Published` sends on every assignment, equal or not, so seeding a fresh engine with the
        // persisted volume published a NO-OP CHANGE — and because the seed runs from
        // `DeckRegistry.configure` inside `viewDidMoveToWindow`, it invalidated a SwiftUI view
        // mid-update ("Publishing changes from within view updates is not allowed"). On a default
        // install both sides are 1.0, so the warning was paid for a write that changed nothing.
        //
        // Wrapping the whole body in `guard clamped != volume else { return }` would be a BUG, not
        // a tidier version of this: the three statements below are not conditional on the volume
        // having changed. Setting the same volume while muted must still UNMUTE (that is the
        // standard behaviour this method documents), and `audioRenderer` and the SDI gate must
        // still be brought into line — a renderer that drifted out of sync would never be
        // recovered by a later equal-valued call. So only the line that publishes is skipped, and
        // every audible effect still happens on every call.
        if clamped != volume { volume = clamped }
        audioRenderer.volume = clamped
        if isMuted { isMuted = false }
        applyAudioMute()
    }

    public func toggleMute() {
        isMuted.toggle()
        applyAudioMute()
    }

    /// D4b-3: TRUE while DeckLink output is enabled AND the audio destination is SDI — i.e. the card
    /// owns the program audio, so the system (computer) renderer must be silent. The two paths are
    /// mutually exclusive: the same program never plays twice.
    ///
    /// This is the ONLY authority the destination has over the system renderer, and it is gated on
    /// DeckLink being enabled, not on the destination alone. When DeckLink output is disabled the App
    /// sets this false and the term simply drops out of the mute rule below — desktop playback returns
    /// to being governed by `isMuted` alone, no matter what the destination enum still says.
    private var deckLinkOwnsAudio = false

    /// Called by the App whenever the DeckLink enable state OR the audio destination changes. Routing
    /// only: it re-evaluates the existing mute, and adds no second mechanism.
    public func setDeckLinkOwnsAudio(_ owns: Bool) {
        guard deckLinkOwnsAudio != owns else { return }
        deckLinkOwnsAudio = owns
        applyAudioMute()
    }

    /// Effective renderer mute = the user's mute OR an active non-1× shuttle OR the SDI destination
    /// owning the program (D4b-3).
    /// Fast-forward replays audio at >1× (pitch/garble), so we mute off-speed and
    /// restore the user's choice when returning to 1× — standard NLE behavior.
    private func applyAudioMute() {
        let offSpeed = shuttleRate != 0 && shuttleRate != 1
        audioRenderer.isMuted = isMuted || offSpeed || deckLinkOwnsAudio
        // D4b-2: mirror the same decision for the SDI audio stream, which pulls from a callback thread
        // and cannot touch main-actor state. One addition the PULL model forces: PAUSE is silence too.
        // The system renderer gets that for free (a stopped synchronizer clock simply stops pulling);
        // the card asks for samples at ~50 Hz regardless, and the source time it asks at is frozen while
        // paused — so serving PCM would re-send the same window forever (a drone). Silence is the honest
        // answer. Net: real PCM only at exactly 1× forward, unmuted.
        setCardAudioSilent(isMuted || shuttleRate != 1)
    }

    /// D4b-2: thread-safe mirror of the SDI audio gate, readable from the DeckLink audio-callback
    /// thread (same rationale as `effectiveRangeMirror` for the render thread). TRUE → the SDI stream
    /// must carry silence. Starts true: nothing is playing at init.
    private nonisolated let cardAudioLock = NSLock()
    private nonisolated(unsafe) var cardAudioSilentMirror = true

    private nonisolated func setCardAudioSilent(_ silent: Bool) {
        cardAudioLock.lock(); cardAudioSilentMirror = silent; cardAudioLock.unlock()
    }

    /// True when the SDI audio stream must carry SILENCE — the user muted, or the transport is not at
    /// exactly 1× forward (paused, or an off-speed JKL shuttle whose audio the 1×-only decode pump
    /// cannot supply). The card is still fed zeros, never starved. Real scrub audio is a separate DSP
    /// feature, deliberately deferred.
    public nonisolated func isCardAudioSilent() -> Bool {
        cardAudioLock.lock(); defer { cardAudioLock.unlock() }
        return cardAudioSilentMirror
    }

    public func play() { setShuttleRate(1) }

    public func pause() { setShuttleRate(0) }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Arm/disarm looping. Takes effect at the next end-of-media during normal forward play.
    public func toggleLoop() { isLooping.toggle() }

    // MARK: - JKL shuttle transport

    /// Core rate control. Positive rates are REAL forward playback driven by the
    /// synchronizer (the pump feeds frames as fast as the renderer requests).
    /// Zero pauses. Negative rates start a best-effort reverse jog (the
    /// forward-only reader can't decode backward — see startReverseJog).
    public func setShuttleRate(_ rate: Float) {
        let clamped = max(-maxShuttleRate, min(maxShuttleRate, rate))
        if clamped >= 0 { stopReverseJog() }
        shuttleRate = clamped
        applyAudioMute()
        if clamped > 0 {
            synchronizer.rate = clamped
            isPlaying = true
        } else if clamped == 0 {
            synchronizer.rate = 0
            isPlaying = false
        } else {
            synchronizer.rate = 0      // synchronizer can't drive the backward pump
            isPlaying = true
            startReverseJog()
        }
    }

    /// L — step forward (1 → 2 → 4 → 8). Tapping forward while reversed or paused
    /// snaps to 1× (direction switch interrupts).
    public func shuttleForward() {
        setShuttleRate(shuttleRate < 1 ? 1 : min(shuttleRate * 2, maxShuttleRate))
    }

    /// J — step reverse (-1 → -2 → -4 → -8). Tapping reverse while forward or
    /// paused snaps to -1× (direction switch interrupts).
    public func shuttleBackward() {
        setShuttleRate(shuttleRate > -1 ? -1 : max(shuttleRate * 2, -maxShuttleRate))
    }

    /// K — pause from any shuttle speed.
    public func shuttlePause() { setShuttleRate(0) }

    /// Step exactly one frame and pause (arrow-key jog). Re-seeks to the target
    /// frame via the reader and holds it at rate 0.
    /// Step by whole frames. Bound to ← / → (one frame) and ⇧← / ⇧→ (one second).
    ///
    /// ── THE SEEKS COALESCE. ⚠️ AND THE BACKLOG THIS GUARDS AGAINST WAS NOT OBSERVED ─────────
    ///
    /// This was `Task { await beginReading(...) }` — one unbounded Task per call, each doing a full
    /// reader teardown and rebuild (cancel the AVAssetReader, flush both renderers, construct a new
    /// reader and FrameSource). The worry was that key repeat (~30/s) would outrun the rebuild and
    /// leave a queue draining after the key came up, with the picture still travelling.
    ///
    /// ⚠️ MEASURED, AND IT DID NOT. Instrumented build, 60 programmatic steps at 200 Hz — six times
    /// real key repeat — on 1080p ProRes 422 HQ from local disk:
    ///
    ///     per-press Task : 60 steps → 60 rebuilds, 1 rebuild after the last step, 9 ms tail
    ///     coalesced      : 60 steps → 46 rebuilds, 1 rebuild after the last step, 8 ms tail
    ///
    /// A rebuild finishes in well under 5 ms on that file, so nothing accumulated either way. Do not
    /// read the coalescer as a fix for a bug anyone has seen.
    ///
    /// IT IS KEPT AS A BOUND, NOT A REPAIR. The measurement holds for ONE file on ONE machine, and
    /// the quantity it depends on — how long a reader rebuild takes — is exactly what grows with
    /// raster, codec and storage: 8K ProRes off a network volume is the case where a 33 ms budget
    /// stops being comfortable, and it is not a case that can be tested here. `pendingStepTarget`
    /// holds the newest destination; the first call starts a drain loop and every call while that
    /// loop runs merely overwrites the target. So the outstanding work is one rebuild in flight plus
    /// at most one queued behind it, WHATEVER the repeat rate and however slow the media, and the
    /// last rebuild always lands on the final position. Intermediate frames are skipped rather than
    /// decoded, which is the right reading of a held key: the user is asking to travel, not to see
    /// every frame on the way. On fast media it is a 23% reduction in rebuilds and nothing else.
    ///
    /// ⚠️ THE ACCUMULATOR READS `pendingStepTarget` FIRST, NOT `currentTime`. The pump writes
    /// `currentTime` from decoded PTS, so during a drain it lags behind the steps already accepted;
    /// accumulating from it would make a held key fight its own decoder and advance erratically.
    public func stepFrame(by frames: Int) {
        let fps = (metadata?.frameRate ?? 0) > 0 ? metadata!.frameRate : 24
        setShuttleRate(0)
        let base = pendingStepTarget ?? currentTime
        // ⚠️ THE CEILING IS THE LAST FRAME, NOT `duration`, and the two are not the same instant.
        // `duration` is the end of the last frame's interval — one frame TIME past the last frame's
        // presentation time — so clamping there parked the playhead on a frame index that does not
        // exist: stepping to the end of a 96-frame file read `01:00:04:00`, i.e. frame 96 of 0…95.
        // Harmless-looking until timecode entry arrived and clamped to `totalFrames` (95,
        // `01:00:03:23`), at which point ← / → and a typed timecode disagreed about where the end is
        // and one of them was quoting a frame you cannot see.
        let lastFrameTime = Double(totalFrames) / fps
        let target = max(0, min(base + Double(frames) / fps, lastFrameTime))
        currentTime = target
        pendingStepTarget = target
        guard !stepDrainRunning else { return }   // the running drain will pick this target up
        stepDrainRunning = true
        Task { await drainPendingSteps() }
    }

    /// Rebuild to the newest requested position until no newer one has arrived. See `stepFrame`.
    private func drainPendingSteps() async {
        defer { stepDrainRunning = false }
        let generation = loadGeneration
        while let target = pendingStepTarget {
            pendingStepTarget = nil
            // A load (or a stop) during the drain retires it: the targets belong to the file that
            // was open when they were typed, and seeking the NEW file to them would be nonsense.
            // Same generation authority the inspection Tasks use.
            guard loadGeneration == generation, hasMedia else { return }
            await beginReading(from: target, resumePlaying: false)
        }
    }

    private func startReverseJog() {
        reverseTimer?.invalidate()
        let speed = -shuttleRate                 // positive magnitude
        let tick = reverseTickInterval
        let timer = Timer(timeInterval: tick, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reverseStep(speed: speed, tick: tick) }
        }
        RunLoop.main.add(timer, forMode: .common)
        reverseTimer = timer
    }

    private func reverseStep(speed: Float, tick: Double) {
        let newTime = currentTime - Double(speed) * tick
        if newTime <= 0 {
            currentTime = 0
            setShuttleRate(0)                    // hit the head — stop at 0
            return
        }
        currentTime = newTime
        Task { await beginReading(from: newTime, resumePlaying: false) }
    }

    private func stopReverseJog() {
        reverseTimer?.invalidate()
        reverseTimer = nil
    }

    /// SOFT RETIREMENT — yield the transport, KEEP the media. The counterpart to `stop()` below,
    /// and the verb arbitration wants almost everywhere `stop()` used to be called.
    ///
    /// ── WHY THIS EXISTS ────────────────────────────────────────────────────────────────────
    ///
    /// `stop()` is a full UNLOAD: it zeroes `hasMedia`, `currentURL`, `duration` and `tcInfo` and
    /// cancels the reader. That is the right verb for the ONE deck a live stream is taking the
    /// display away from — its renderer is about to show something else, so its file has genuinely
    /// gone. It is the wrong verb for every OTHER deck, which under the multi-window model must
    /// keep its paused frame, scopes, inspector and frame export while merely giving up the right
    /// to play. Every "retire the other source" path in the app used to be built on `stop()`, so
    /// every one of them destroyed all four.
    ///
    /// ── WHY THIS IS RATE 0 AND NOT A MUTE ──────────────────────────────────────────────────
    ///
    /// A paused synchronizer is ALREADY silent — `synchronizer.rate = 0` stops the audio renderer
    /// pulling, and `applyAudioMute` (via `setShuttleRate`) also silences the SDI stream. Muting
    /// instead would leave the clock running and the decoder pumping, and would add a SECOND
    /// silence mechanism to keep in step with the first. There is exactly one mechanism, and this
    /// is it.
    ///
    /// Idempotent, and cheap when already parked: the guard keeps a repeated arbitration pass from
    /// republishing `shuttleRate` / `isPlaying` and re-rendering a window for no reason.
    public func yieldTransport() {
        guard isPlaying || shuttleRate != 0 else { return }
        setShuttleRate(0)
    }

    /// Fully stop playback and tear down the current reading session.
    ///
    /// ⚠️ THIS UNLOADS THE FILE. For "stop playing but keep the media", use `yieldTransport()`.
    public func stop() {
        _ = sessionToken.next()
        stopReverseJog()
        shuttleRate = 0
        applyAudioMute()
        synchronizer.rate = 0
        currentSource?.stop()           // retire the video pump (FrameSource seam)
        currentSource = nil
        libavSource?.stop()             // retire the libav sources (DNxHR path)
        libavSource = nil
        libavAudioSource?.stop()
        libavAudioSource = nil
        installScrubProducer(for: nil, useLibav: false)   // retire the scrub producer

        // Audio is its OWN reader + pump now, so it retires through its own teardown — which bumps
        // `audioSessionToken`, stops the pump, cancels that reader, flushes the renderer and drops
        // the tap's ring. Missing this would leave an audio pump running against an unloaded file.
        teardownAudioReading()

        let readerToCancel = reader
        reader = nil
        // Serialize cancellation behind both pump queues so it can't overlap an
        // in-flight copyNextSampleBuffer() on either queue.
        videoPumpQueue.async {
            self.audioPumpQueue.async {
                readerToCancel?.cancelReading()
            }
        }

        videoRenderer?.flush()
        // Back to "don't know", NOT to "no audio": nothing is loaded, so there is nothing to
        // assert. A meter must not report absence on the strength of a teardown.
        audioPresence = .unknown
        isPlaying = false
        currentTime = 0
        // An outstanding frame-step destination belongs to the file that just left. Left set, it
        // would become the accumulator's base for the first step of the NEXT source (see
        // `stepFrame`), so a step in a freshly loaded file would start from the old one's position.
        pendingStepTarget = nil
        // A full teardown must leave NO transport readout from the departed source: the same
        // incoherence we fixed for scopes (blank-on-disconnect). duration + tcInfo drive the
        // scrubber range and the source/end-timecode readouts; without this a file→stream takeover
        // (this runs via onWillActivateStream) or a disconnect leaves the old file's end timecode
        // (e.g. 01:00:37:17) and scrubber length on screen behind the live source. A stream is not
        // seekable, so zeroed readouts (00:00:00 / empty scrubber) are the correct resting state —
        // no live-transport model is implied here. metadata is intentionally left alone: it drives
        // the metadata-onChange scope wiring, which the connecting stream immediately repopulates.
        duration = 0
        tcInfo = nil
        hasMedia = false
        currentURL = nil
        // …AND THE SHAPE IS A TRANSPORT READOUT TOO, for exactly the reason the block above gives.
        // It was missed when that reasoning was applied to duration and tcInfo, and the omission
        // only became visible once live sources started publishing a size of their own: a stream
        // taking a deck over (this runs via onWillActivateStream) would otherwise inherit the
        // departed FILE's aspect and hold it until its own first frame arrived — a 4:3 file's lock
        // on a 16:9 stream, which is worse than the no-lock state because it looks deliberate.
        // `abandonLoad` used to clear it for the same reason; that function is gone (a refused load
        // no longer empties the deck — see `rejectLoad`), so `stop()` is now the only teardown that
        // has to state this rule. Note `load()` deliberately does NOT clear it — a file→file open
        // holds the previous shape for the few ms until inspection returns, rather than flashing
        // the 16:9 fallback.
        displaySize = nil
        // …AND THE COLOUR STATE WITH IT, same class of bug, one degree nastier. A deck emptied by
        // an unload — including the deck a live stream is taking the display from — must not hand
        // the next source the departed file's colorspace. Unlike `displaySize`, holding the old
        // value across the gap is not a harmless brief inaccuracy: the layer applies its
        // colorspace at PRESENT time, so the next source's FIRST frame would be drawn through the
        // dead file's space and would stay that way until something presented again.
        onSourceColorTags?(nil, nil, nil)
    }

    /// Publish the frame size of a LIVE (non-file) source into this deck.
    ///
    /// ── WHY LIVE SOURCES NEED A SETTER AT ALL ──────────────────────────────────────────────
    ///
    /// The file paths learn their shape by INSPECTING an asset — `MediaInspector.displaySize`, or
    /// libav's stream info on the MXF path — and publish it once, from inside this class. A stream
    /// has no asset to inspect: its shape is a property of the decoded pictures arriving on a
    /// transport thread, and the transports do not (and must not) know a `FrameEngine` exists. So
    /// the value arrives from outside, through `LiveDisplaySize` → `DeckRegistry` → here.
    ///
    /// ── WHAT IT IS AND IS NOT ──────────────────────────────────────────────────────────────
    ///
    /// The file value is `naturalSize × preferredTransform` — rotation-corrected, NOT PAR-corrected.
    /// The honest live equivalent is the DECODED BUFFER's dimensions, which is what the callers
    /// pass: no rotation exists to correct (no transport carries one), and no PAR is applied
    /// because none of the three currently gives us one to apply. That makes the two paths agree
    /// on the one thing that matters — both describe the geometry the renderer actually draws into
    /// the video rect — and it means a live value is a SQUARE-PIXEL assumption, stated here rather
    /// than implied.
    ///
    /// nil means "no live picture". Idempotent, and guarded so a per-frame publish that has not
    /// changed cannot republish `@Published` state and re-render the window. MAIN ACTOR.
    public func setLiveDisplaySize(_ size: CGSize?) {
        guard displaySize != size else { return }
        displaySize = size
    }

    public func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration))
        Task { await beginReading(from: clamped, resumePlaying: isPlaying) }
    }

    /// Monitor a different audio track. Governs PLAYBACK, not just metering: the selected track is
    /// the one that feeds the audio renderer, and — because the tap is teed off that same enqueue —
    /// the meters and the DeckLink audio stream follow it without any further wiring.
    ///
    /// ── THE PICTURE DOES NOT MOVE ─────────────────────────────────────────────────────────────
    ///
    /// This rebuilds the AUDIO reader ONLY. The video reader, the FrameSource, the video renderer
    /// and `synchronizer.rate` are all untouched, so there is no flush, no re-anchor and no
    /// re-preroll on the video side — the frame on screen is not disturbed and playback does not
    /// pause. It reads as a change of what you are hearing, not as a playback glitch.
    ///
    /// This used to rebuild BOTH readers (it called `beginReading`, i.e. the seek path) because a
    /// single `AVAssetReader` carried both tracks and its outputs are frozen at `startReading()` —
    /// MEASURED: `canAdd` is true before the start and false after. Decoupling audio onto its own
    /// reader is what removed that. See `audioReader` for why this cannot introduce drift.
    ///
    /// The audible cost is one renderer flush plus the new reader's spin-up — MEASURED at 3–4 ms
    /// warm for an audio-only reader, against 25–33 ms for the full rebuild this replaced. Under a
    /// frame either way, and this is a deliberate, occasional action.
    ///
    /// No-ops on an unchanged index, on an out-of-range index, and on the libav path (where
    /// `audioTracks` is empty and there is nothing to choose between).
    public func selectAudioTrack(_ index: Int) {
        guard audioTracks.indices.contains(index), index != selectedAudioTrackIndex else { return }
        selectedAudioTrackIndex = index
        // Positioned at the playhead, NOT at zero. `beginAudioReading` tears down the previous
        // audio session (which drops the old track's PCM from the ring) and starts the new one
        // against the clock that is still running.
        let at = CMTime(seconds: currentTime, preferredTimescale: 600)
        Task { await beginAudioReading(from: at) }
    }

    /// Current frame from the start of the file (0-based).
    public var currentFrame: Int {
        let fps = (metadata?.frameRate ?? 0) > 0 ? metadata!.frameRate : 24
        return Int((currentTime * fps).rounded())
    }

    public var totalFrames: Int {
        let fps = (metadata?.frameRate ?? 0) > 0 ? metadata!.frameRate : 24
        return max(Int((duration * fps).rounded()) - 1, 0)
    }

    /// During a scrub drag: just track the target and show it on the clock,
    /// WITHOUT rebuilding the reader every tick (that storms the decoder).
    ///
    /// AND — when a scrub producer exists — hand that position to the seam. This is the whole of
    /// the view's new job: `ContentView` already called this on every slider callback, so "here is
    /// the position" needed no new call site. Everything the view used to own about the request
    /// (the in-flight latch, the media-distance gate, the generation stamp) is gone from it; the
    /// coalescer owns the first, deleted the second, and the token below replaces the third.
    public func scrubSeek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration))
        currentTime = clamped
        scrubCoalescer?.submit(clamped)
    }

    /// On scrub release (or a discrete seek): do the real reader rebuild.
    public func exactSeek(to seconds: Double) {
        // Release is the natural edge for the drag's `[SCRUB]` summary: it is the one moment that
        // means "that gesture is over". No-op when no producer ran.
        scrubCoalescer?.flushStats(label: currentURL?.lastPathComponent ?? "—")
        seek(to: seconds)
    }

    /// Build the scrub producer for `url`, or tear the old one down and build nothing.
    ///
    /// ── ONE FUNCTION, BOTH COMMIT PATHS, AND THE TEARDOWN IN THE SAME PLACE ───────────────────
    ///
    /// The lifecycle is the one `libavThumbnailSource` used to have — created in `loadAsset`'s PHASE 2 and
    /// in `loadMXF`, released in `stop()` and at the top of the next commit. Only the object is
    /// different. Calling this at the top of a commit with `url: nil` is the teardown.
    ///
    /// ⚠️ THE TOKEN IS CHECKED AT DELIVERY, NOT AT REQUEST, and the difference is a real bug and
    /// not a formality. A scrub frame decoded from the OLD file can reach the renderer AFTER the
    /// new file's `setSourceColorSpace(...)` has been installed on the layer — old pixels drawn
    /// through the new file's colour state. The renderer already has a diagnostic for exactly that
    /// condition (`[EDR] … ⚠️ AFTER a frame was already on screen`). A check at request time is
    /// necessary and not sufficient: the window that matters is between the decode STARTING and
    /// the pixels LANDING, which is precisely the window a load can slip into. So the check lives
    /// in the delivery closure below, one line before the hand-off.
    private func installScrubProducer(for url: URL?, useLibav: Bool) {
        scrubCoalescer?.close()
        scrubCoalescer = nil
        // Bumped on teardown as well as on install, so a completion still in flight from the
        // producer just closed cannot deliver into the next file.
        let token = scrubToken.next()

        guard let url else { return }

        // ── TWO PRODUCERS, ONE DESTINATION. THIS BRANCH IS THE WHOLE SELECTION. ───────────────
        //
        // It sits exactly where the overlay branch used to be selected, and it is the ONLY place
        // the corpus is split. `useLibav` is the same flag playback already routes on
        // (`MediaInspector.requiresLibavDecode`, plus MXF unconditionally), so scrub and playback
        // can never disagree about which demuxer a file needs.
        //
        // Below this line nothing is producer-specific: the same coalescer, the same delivery-side
        // token, the same `onScrubFrame` → `presentImmediate`. There is no `CGImage` on either
        // path any more, and therefore no second display path, no second colour-management mode,
        // and no format a scope cannot sample.
        let producer: ScrubFrameProducer = useLibav
            ? LibavScrubProducer(url: url, pixelFormat: videoPixelFormat)
            : AVPlayerScrubProducer(url: url, pixelFormat: videoPixelFormat)
        scrubCoalescer = ScrubCoalescer(producer: producer) { [weak self] frame in
            guard let self else { return }
            guard self.scrubToken.isCurrent(token) else { return }   // ← the delivery-side check
            self.onScrubFrame?(frame.pixelBuffer, frame.pts)
        }
    }

    /// The source timecode at a time on the file's timeline: the file's start TC plus however many
    /// frames have elapsed.
    ///
    /// ── ⚠️ SECONDS→FRAMES USES THE EXACT RATE, NOT `nfr`, AND THAT IS A CORRECTION ───────────
    ///
    /// This line read `seconds * Double(tc.nfr)` — the INTEGER rate — and for every NTSC-family rate
    /// that is the wrong conversion by exactly the 1000/1001 pulldown factor:
    ///
    ///   * `nfr` is 24 for a 23.976 file, and it is CORRECT for splitting a frame count into
    ///     HH:MM:SS:FF — SMPTE labels count 24 frames per timecode second, which is the whole point
    ///     of the rate. `format(...)` below still takes it, unchanged.
    ///   * But the frame INDEX at time t is `round(t × 23.976)`, not `round(t × 24)`. Using 24
    ///     over-counted by 0.1% — one frame per ~1000, so the readout ran a frame ahead of the
    ///     picture after ~42 s and about fourteen frames ahead by the ten-minute mark.
    ///
    /// It was invisible while the readout was the only consumer: a display that drifts against
    /// itself consistently still looks like a timecode. It stopped being invisible when timecode
    /// ENTRY arrived, because entry closes the loop — type a timecode, seek to it, read it back —
    /// and the loop did not close. Every other frame-index site in this engine (`currentFrame`,
    /// `totalFrames`, `stepFrame`) already used the exact rate; this was the odd one out.
    ///
    /// Rate precedence matches `TimecodeContext` in the app layer, deliberately: the metadata rate is
    /// authoritative and the timecode track's own rate is the fallback, so the readout and the entry
    /// that has to land on it can never derive a frame from two different numbers.
    public func currentSourceTimecode(at seconds: Double) -> String? {
        guard let tc = tcInfo, tc.nfr > 0 else { return nil }
        let declared = metadata?.frameRate ?? 0
        let rate = declared > 0 ? declared : tc.fps
        guard rate > 0 else { return nil }
        let elapsedFrames = Int((seconds * rate).rounded())
        return TimecodeReader.format(frameCount: tc.startFrame + elapsedFrames,
                                     nfr: tc.nfr, fps: tc.fps, dropFrame: tc.dropFrame)
    }

    public func endSourceTimecode() -> String? {
        currentSourceTimecode(at: duration)
    }

    /// ── REFUSE A FILE WITHOUT TOUCHING WHAT IS ALREADY LOADED ───────────────────────────────
    ///
    /// Raise `notice` in the UI's banner and do NOTHING ELSE. The deck keeps its media, its
    /// position, and its playback: you dropped the wrong file, you do not lose the right one.
    ///
    /// ⚠️ THIS IS ONLY SAFE BECAUSE OF WHERE IT IS CALLED FROM, and that is the whole of the
    /// change it belongs to. Every caller is in `loadAsset`'s VETTING PHASE, which runs before the
    /// function has written a single field — see the phase comment there. A refusal reached after
    /// the commit point would leave a half-built deck, which is worse than either outcome.
    ///
    /// ── WHAT THIS REPLACED, AND THE DISTINCTION THAT WAS MISSING ─────────────────────────────
    ///
    /// This used to be `abandonLoad(notice:)`, which reset the engine to its NO-MEDIA state:
    /// `hasMedia = false`, asset/tracks/generator/metadata/displaySize/duration/tcInfo/currentURL
    /// all cleared, the colour tags nil'd. Reasonable-sounding, and wrong for every case that
    /// actually reached it, because it conflated two different events:
    ///
    ///   * **THIS LOAD FAILED BEFORE IT BEGAN.** Nothing was replaced; the media on screen is
    ///     untouched and still correct. Refuse and say so. ← every caller today
    ///   * **THE MEDIA THAT WAS LOADED IS GONE.** The deck is describing something that can no
    ///     longer draw, so leaving `hasMedia` true would show a transport over a dead file.
    ///
    /// Only the second warrants emptying the deck, and nothing in this engine detects it today —
    /// no path re-checks a file that is already playing. If one is ever added (a reader that dies
    /// mid-playback, a `reinspect` that finds the file gone), it needs the destructive counterpart,
    /// and the fields listed above are what it has to clear — `hasMedia` above all, since that is
    /// what the UI keys its empty state off (`hasSource = engine.hasMedia || activeLiveSource`),
    /// and the colour tags, since a stale source colourspace is invisible until the NEXT source is
    /// drawn through it. It is deliberately not written until something needs it.
    private func rejectLoad(notice: String) {
        playbackNotice = notice
    }

    /// ══════════════════════════════════════════════════════════════════════════════════════════
    ///  TWO PHASES, AND THE BOUNDARY BETWEEN THEM IS THE POINT OF NO RETURN.
    ///
    ///  **PHASE 1 — VET.** Decide whether this file can be played. Writes NOTHING: not one field,
    ///  not the generation counter, not the libav sources. Every refusal lives here, and because
    ///  nothing has been touched yet, refusing is free — the deck keeps playing whatever it had.
    ///
    ///  **PHASE 2 — COMMIT.** Only now is the previous source torn down and the new one installed.
    ///  Past this line the old media is gone and there is no way back, so nothing here may fail
    ///  soft.
    ///
    ///  ⚠️ THE ORDER USED TO BE THE OTHER WAY AROUND, AND IT COST THE USER THEIR FILE. Both
    ///  refusals sat AFTER the teardown, so dropping a still — or an R3D, or anything AVFoundation
    ///  could not open — stopped the libav sources, replaced the asset, the scrub generator, the
    ///  timecode and the duration, and THEN discovered the file was no good and emptied the deck to
    ///  a bare empty state. A mis-drop destroyed the clip that was on screen. The refusal was
    ///  correct; its position was not.
    ///
    ///  ⚠️ MXF IS NOT VETTED, and that is a stated gap rather than an oversight. AVFoundation
    ///  cannot open it at all, so the phase-1 check has nothing to ask; vetting it means opening it
    ///  through libav, which is most of the work of loading it. The MXF path therefore commits
    ///  immediately, exactly as it did before this split — it has never had a refusal to be
    ///  non-destructive about. When it grows one, it belongs in phase 1 with the others.
    /// ══════════════════════════════════════════════════════════════════════════════════════════
    private func loadAsset(url: URL, autoplay: Bool) async {

        // ══════════ PHASE 1 — VET. NOTHING BELOW THIS LINE MAY WRITE STATE. ══════════

        // ── A STILL IMAGE, REFUSED BY NAME ────────────────────────────────────────────────────
        //
        // Same refusal PATH as every other file this engine cannot play — `rejectLoad`, which
        // raises the one banner — and a different SENTENCE, because the reason is different and the
        // generic one would be a lie. "Its video track is unreadable" says the file is damaged or
        // its codec is beyond us; a PNG's lack of a video track is neither. It is a correct,
        // healthy file of a kind this app does not open.
        //
        // Caught HERE rather than at the drop or the open panel because this is the one place every
        // entry point passes through — a drop, ⌘O, a Finder double-click, a drag to the Dock icon.
        // The alternative was a second refusal mechanism sitting in the view layer, which is what
        // produced the bug this replaces: the drop's own type filter returned false for an image
        // and nothing happened at all, no message, no log, nothing to distinguish it from a dead
        // window.
        //
        // ── WHY STILLS ARE NOT SUPPORTED, AND WHAT WOULD HAVE TO HAPPEN FIRST ────────────────
        //
        // ⚠️ THIS IS BANKED AS POST-1.0 AND IT IS GATED ON THE COLOUR PIPELINE, NOT ON EFFORT.
        // Decoding a PNG is trivial; showing one HONESTLY is not, and this app's whole claim is
        // that what it puts on screen is what the file says.
        //
        // A still can carry an EMBEDDED ICC PROFILE. Video does not work that way: a video file
        // declares its colour through NCLC/CICP codes drawn from a small closed set of primaries,
        // transfer functions and matrices, and every path in this app — the shader's conversion,
        // the layer's colorspace, the scopes' math, the inspector's readout — is built on picking
        // from that set. An arbitrary ICC profile is a different problem: an arbitrary source
        // primaries triangle and an arbitrary tone curve, which have to be converted to the display
        // rather than looked up.
        //
        // Doing that correctly means the SHADER owns the display transform instead of handing the
        // layer a colorspace and letting ColorSync convert. That is exactly Reference mode, which
        // is currently open work blocked on the MacBook Air measurement — see
        // docs/AIR-COLOUR-TEST.md for the test and docs/COLOR_MANAGEMENT_FINDINGS.md for the state
        // of the question ("Reference mode needs a declared destination — open, the real work").
        //
        // So the order is: settle Reference mode, then stills. Adding stills first would mean
        // either drawing them through the video path with their profile ignored — a picture this
        // app cannot stand behind — or a second colour path beside the one being rebuilt.
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            NSLog("[PLAYBACK] refusing %@ — still image (%@). Manifold plays video; see the note at "
                + "this refusal for why stills are gated on the colour pipeline.",
                  url.lastPathComponent, type.identifier)
            rejectLoad(notice: "Manifold plays video — still images aren’t supported.")
            return
        }

        // Is this the libav path? Asked here because the answer decides whether phase 1 has
        // anything left to do — AVFoundation cannot open an MXF, so there is nothing to ask it.
        let isMXF = url.pathExtension.lowercased() == "mxf"

        // ── AVFOUNDATION OPENED THE CONTAINER BUT EXPOSES NO VIDEO TRACK ──────────────────────
        // Not "the codec is unsupported" — the track is absent from the asset entirely, so there
        // is nothing to decode and nothing we can configure our way out of. MEASURED cause on the
        // file that prompted this: a QuickTime whose video `stsd` carries 8 trailing zero bytes
        // that parse as a box with SIZE 0 ("extends to end of file"). AVFoundation rejects the
        // sample description and drops the track; libav ignores the padding and reads the file
        // fine, which is why other applications open it and Quick Look — also AVFoundation — does
        // not. Removing exactly those 8 bytes makes the track appear, and injecting them into a
        // working file makes it vanish, so the mechanism is established rather than inferred.
        //
        // This is ALSO where an R3D lands, and every other container AVFoundation declines: it is
        // the one question that separates "there is a picture in here" from "there is not", and it
        // is asked BEFORE anything is torn down. Asking it here is what makes the refusal cost the
        // user nothing.
        //
        // ⚠️ THE ASSET IS OPENED ONCE AND CARRIED INTO PHASE 2. Re-creating it after the commit
        // would ask the file system the same question twice and — worse — leave the possibility of
        // the two answers differing.
        var vettedAsset: AVURLAsset?
        var vettedTrack: AVAssetTrack?
        if !isMXF {
            let asset = AVURLAsset(url: url)
            guard let vTrack = try? await asset.loadTracks(withMediaType: .video).first else {
                NSLog("[PLAYBACK] no video track — AVFoundation exposes no readable video track for "
                    + "%@; the container may declare a malformed sample description. Not loading — "
                    + "the deck keeps what it had.", url.lastPathComponent)
                rejectLoad(notice: "This file couldn’t be opened — its video track is unreadable.")
                return
            }
            vettedAsset = asset
            vettedTrack = vTrack
        }

        // ══════════ PHASE 2 — COMMIT. THE PREVIOUS SOURCE ENDS HERE. ══════════

        currentURL = url
        // A new file gets a clean slate for the degraded-playback notice: the previous file's
        // "video only" banner must not persist onto one whose audio reads fine. NOT done in phase
        // 1: a refused load must leave the current file's notice alone, since that file is still
        // the one on screen.
        playbackNotice = nil
        audioFallbackAnnounced = false

        // Retire any inspection Tasks still in flight from a previous load before starting this one.
        loadGeneration &+= 1
        let generation = loadGeneration
        // …and any frame step the PREVIOUS file had outstanding, for the reason given in `stop()`.
        // The bump above is what makes a drain loop already running notice and retire itself.
        pendingStepTarget = nil

        // New file: retire any prior libav sources (bound to the old file). The
        // per-file libav video+audio sources are created lazily in beginLibavReading.
        libavSource?.stop(); libavSource = nil
        libavAudioSource?.stop(); libavAudioSource = nil
        // The scrub producer is retired HERE and rebuilt below once `useLibav` is known — the
        // second half of the same lifecycle, and the bump this performs is what makes an in-flight
        // frame from the outgoing file fail its delivery check instead of landing on the new one.
        installScrubProducer(for: nil, useLibav: false)

        // MXF: AVFoundation can't demux it — route straight to libav (container-based
        // detection; not a VT-failed fallback). Its metadata comes from libav.
        if isMXF {
            self.asset = nil
            self.videoTrack = nil
            await loadMXF(url: url, autoplay: autoplay)
            return
        }

        guard let asset = vettedAsset, let vTrack = vettedTrack else { return }   // unreachable
        self.asset = asset

        // Same inspection as AVPlayerEngine, via the shared inspector. Both publish only if this
        // load is still the current one (see `loadGeneration`).
        self.tcInfo = MediaInspector.timecode(for: url)
        Task { [weak self] in
            let meta = await MediaInspector.metadata(for: asset, url: url)
            await MainActor.run {
                guard let self, self.loadGeneration == generation else { return }
                self.metadata = meta
            }
        }
        Task { [weak self] in
            let size = await MediaInspector.displaySize(for: asset)
            await MainActor.run {
                guard let self, self.loadGeneration == generation else { return }
                self.displaySize = size
            }
        }

        if let dur = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(dur)
            if seconds.isFinite { self.duration = seconds }
        }

        self.videoTrack = vTrack
        // The track was found in phase 1, so by here the media is genuinely playable.
        self.hasMedia = true
        // ALL of them, not `.first` — see `audioTracks`. Selection resets to track 1 for a new file.
        self.audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        self.selectedAudioTrackIndex = 0

        // Range (8-bit): capture the SOURCE's signaled range (same format-
        // description determination the inspector uses) and reset the user
        // override to Auto for the new file (transient per-file). Decode is ALWAYS
        // 420v; the override drives the shader's expansion via effectiveIsFullRange.
        rangeOverride = .auto
        useLibav = false
        if let formats = try? await vTrack.load(.formatDescriptions), let fmt = formats.first {
            sourceRange = MediaInspector.sourceColorRange(for: fmt)
            // ── THE DISPLAY'S COLOUR STATE, ESTABLISHED HERE AND NOT FROM `metadata` ─────────
            //
            // THIS POINT, AND NOT ONE LINE LATER, IS THE WHOLE FIX. It is the same format
            // description the range determination above already has in hand, so the codes cost
            // nothing to read; it is on the main actor, in the same turn; and it is BEFORE
            // `beginReading` at the bottom of this function, which is the ONLY thing that
            // creates a reader and therefore the only thing that can enqueue a frame. Nothing
            // between here and there produces a picture, so no frame can reach the renderer
            // before the layer has been told what it is looking at.
            //
            // The `metadata` observer still calls the same renderer method later with the same
            // three codes; that call is now a no-op re-assert (the renderer compares before
            // acting). It stays because it is also where the DeckLink output and the scope
            // headers are re-derived, which genuinely do belong to the full inspection.
            let codes = MediaInspector.colorCodes(for: fmt)
            onSourceColorTags?(codes.primaries, codes.transfer, codes.matrix)
            // DNxHR can't decode through VideoToolbox; route it to libav. Its real
            // range (DNxHR/MXF ACLR) comes from libav's color_range, applied in
            // beginLibavReading — overriding the often-untagged AVFoundation read.
            useLibav = MediaInspector.requiresLibavDecode(fmt)
        } else {
            sourceRange = .untagged
            // NO FORMAT DESCRIPTION IS ALSO AN ANSWER, and it must be published rather than
            // skipped: leaving the previous file's codes standing is the stale-colour bug in its
            // purest form. nils resolve to the renderer's 709 default.
            onSourceColorTags?(nil, nil, nil)
        }
        updateEffectiveRange()

        // The scrub producer, at the same point in the same commit and for the same reason: the
        // decoder has to be warm before the first grab, not built by it. No-op unless the Stage 1
        // flag is on; skipped for libav files, which have no AVFoundation route.
        installScrubProducer(for: url, useLibav: useLibav)

        installTimeObserverIfNeeded()

        print("FrameEngine: loaded — duration \(self.duration)s, audio tracks: \(self.audioTracks.count) (monitoring \(self.audioTracks.isEmpty ? "none" : "#\(self.selectedAudioTrackIndex + 1)"))")
        await beginReading(from: 0, resumePlaying: autoplay)
    }

    /// The periodic clock observer that publishes `currentTime` and stops at the end.
    /// Shared by the AVFoundation and libav/MXF load paths (added once).
    private func installTimeObserverIfNeeded() {
        guard timeObserver == nil else { return }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = synchronizer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let t = CMTimeGetSeconds(time)
            guard t.isFinite else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.duration > 0 && t >= self.duration {
                    self.currentTime = self.duration
                    // LOOP fires only from NORMAL FORWARD PLAY, i.e. shuttleRate == 1 — the rate
                    // play() establishes. NOT 0: setShuttleRate treats 0 as PAUSED (isPlaying = false),
                    // so a `shuttleRate == 0` test here could never be true while playing. Hitting the
                    // end while JKL-shuttling (2/4/8x) keeps the existing stop-and-hold, so a fast
                    // shuttle never silently wraps. Loop-at-head (reverse) is out of scope: reverse has
                    // its own head-stop in reverseStep and never reaches this observer.
                    //
                    // The wrap is a full beginReading re-seek, and this observer only ticks at ~0.1s,
                    // so the wrap point is quantized and a small hitch is expected — accepted for v1.
                    // beginReading also flushes the renderers, so DeckLink output may show its neutral
                    // fallback for a beat at the wrap.
                    if self.isPlaying && self.isLooping && self.shuttleRate == 1 {
                        // resumePlaying: true re-establishes 1x play; beginReading resets currentTime.
                        Task { await self.beginReading(from: 0, resumePlaying: true) }
                    } else if self.isPlaying {
                        self.synchronizer.rate = 0
                        self.isPlaying = false
                        self.shuttleRate = 0
                        self.applyAudioMute()
                    }
                } else {
                    self.currentTime = t
                }
            }
        }
    }

    /// The MXF load path. AVFoundation has no MXF demuxer, so it can't open the file
    /// at all — MXF routes DIRECTLY to libav (not an AVFoundation-attempt-then-fall-
    /// back). All the facts AVFoundation normally supplies (duration, size, fps,
    /// color) are read from libav in `beginLibavReading` (gated on `videoTrack == nil`).
    private func loadMXF(url: URL, autoplay: Bool) async {
        self.hasMedia = true
        self.tcInfo = MediaInspector.timecode(for: url)   // nil for MXF; harmless
        self.videoTrack = nil                              // AVFoundation blind → libav supplies metadata
        self.audioTracks = []                              // libav picks the stream; no selection to offer
        self.selectedAudioTrackIndex = 0
        self.rangeOverride = .auto
        self.useLibav = true
        // Both commit paths call this, so neither can forget it. MXF resolves to the LIBAV
        // producer inside — AVFoundation is blind to MXF for scrub exactly as it is for playback.
        installScrubProducer(for: url, useLibav: true)
        installTimeObserverIfNeeded()
        await beginReading(from: 0, resumePlaying: autoplay)
    }

    /// Populate the UI-facing metadata/duration/size from libav's stream facts, for
    /// the MXF path where AVFoundation supplies nothing. Color codes drive the layer
    /// colorspace (via the metadata observer → setSourceColorSpace) exactly as the
    /// AVFoundation-read codes do; the shader's YCbCr matrix still comes from the
    /// pixel-buffer attachment the source sets. Called on the main actor.
    private func applyLibavMetadata(_ info: LibavFrameSource.StreamInfo, url: URL) {
        if info.durationSeconds.isFinite, info.durationSeconds > 0 { self.duration = info.durationSeconds }
        if info.width > 0, info.height > 0 { self.displaySize = CGSize(width: info.width, height: info.height) }

        var meta = VideoMetadata()
        meta.fileName = url.lastPathComponent
        meta.container = url.pathExtension.uppercased()
        meta.codecName = info.codecName
        meta.width = info.width
        meta.height = info.height
        meta.frameRate = info.frameRate
        meta.colorPrimariesCode = info.primariesCode
        meta.transferFunctionCode = info.transferCode
        meta.colorMatrixCode = info.matrixCode
        // Resolve the human-readable names the SAME way the .mov path does (the
        // inspector renders `labeled(name, code)`; without the name it shows "— (1)").
        meta.colorPrimaries = MediaInspector.primariesName(forCode: info.primariesCode)
        meta.transferFunction = MediaInspector.transferName(forCode: info.transferCode)
        meta.colorMatrix = MediaInspector.matrixName(forCode: info.matrixCode)
        meta.colorRange = (info.isFullRange
            ? MediaInspector.SourceColorRange.full
            : MediaInspector.SourceColorRange.videoLegal).displayName
        meta.startTimecode = info.startTimecode   // MXF Material Package TC (libav)
        // Same HDR10 reader the AVFoundation path uses, so the inspector's HDR10 section
        // reads identically whichever backend supplied the rest of the metadata.
        meta.hdr10 = HDR10MetadataReader.read(url: url)

        // Feed the SAME transport time-display path the .mov tmcd path uses: build a
        // TimecodeReader.Result from libav's TC string + frame rate so the scrubber/
        // controls show REAL timecode (start TC + elapsed), not a 00:00:00 counter.
        // Nil string → no source TC (transport falls back to the elapsed counter).
        if let tcString = info.startTimecode {
            self.tcInfo = TimecodeReader.parse(timecode: tcString, fps: info.frameRate)
        }

        // Data rate: estimate from file size / duration (libav reports no per-stream
        // bit_rate for MXF DNxHR; video dominates so audio/overhead is negligible) —
        // same "estimated" spirit as the .mov path's estimatedDataRate.
        var fileSize: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            meta.fileModifiedDate = attrs[.modificationDate] as? Date
            meta.fileCreatedDate = attrs[.creationDate] as? Date
            fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }
        if fileSize > 0, info.durationSeconds > 0 {
            meta.videoDataRate = Double(fileSize) * 8 / info.durationSeconds
        }
        self.metadata = meta
    }

    /// ONE audio row per audio stream in the container, so an MXF's Audio section lists what the
    /// file actually holds. Closes the gap documented on `audioPresence`: `MediaInspector` reads an
    /// `AVURLAsset`, `loadMXF` never calls it, and `metadata.audioTracks` therefore stayed EMPTY for
    /// every MXF — including ones playing audio perfectly — so the inspector showed no audio rows.
    ///
    /// ── ⚠️ DESCRIBING FOUR STREAMS IS NOT OFFERING FOUR STREAMS ───────────────────────────────
    ///
    /// `LibavAudioSource` still decodes exactly one stream — the first — and nothing here changes
    /// that. `audioTrackCount` counts `AVAssetTrack`s and is still 0 on this path, so the toolbar
    /// picker stays disabled and `InspectorPanel` still renders these rows as plain readouts:
    /// not clickable, and none marked as monitored. That is deliberate until the SWITCH exists —
    /// a control that lets you pick a stream nothing can bind is worse than an honest disabled one
    /// (see the note on `audioTrackControl`). What the rows do is REPORT, which the inspector could
    /// not do at all a moment ago.
    ///
    /// ⚠️ ROW 0 IS THE DECODED STREAM, AND SOMETHING DEPENDS ON THAT. `ContentView` feeds the
    /// meters `audioTracks[selectedAudioTrackIndex].roles`, and `selectedAudioTrackIndex` is 0 on
    /// this path (there is nothing to select). Rows are built in `AVStream` order and the decoded
    /// stream is the FIRST audio stream, so index 0 is it and the meters keep labelling the bars
    /// with the roles of the audio they are actually showing. A switch has to move both together.
    ///
    /// ── ⚠️ WHY THE GUARD, AND WHY IT IS THE SAME ONE `applyLibavMetadata` USES ────────────────
    ///
    /// A `.mov` carrying DNxHR reaches this branch too — libav decodes its video — but its
    /// `metadata` came from `MediaInspector`, which enumerated the asset and holds ALL of its audio
    /// tracks. Writing these rows over that complete list would be a downgrade wearing the shape of
    /// a fix. `videoTrack == nil` means "AVFoundation is blind to this container", which is exactly
    /// the condition under which this path is the only source of the fact.
    ///
    /// MAIN ACTOR, and NOT a second `metadata` assignment. `FrameEngine` is `@MainActor` and
    /// `beginLibavReading` is one of its methods, so this runs on the main actor. It is called from
    /// the same straight-line stretch that ran `applyLibavMetadata` about twenty lines earlier with
    /// no suspension between them, so it MUTATES the metadata that call published rather than
    /// replacing it — there is no window in which a second assignment could race or clobber the
    /// first, and SwiftUI coalesces the two `objectWillChange` emissions into one update.
    private func applyLibavAudioTrack(_ ainfo: LibavAudioSource.AudioInfo) {
        guard videoTrack == nil, !ainfo.streams.isEmpty else { return }
        // Optional-chained: `applyLibavMetadata` runs under the identical `videoTrack == nil`
        // condition and has already published a `metadata`, so this is a mutation of that value.
        // If it somehow has not, dropping the rows is better than publishing ones with no file facts.
        self.metadata?.audioTracks = ainfo.streams.map { Self.audioTrackRow(for: $0) }
    }

    /// One inspector row from one libav audio stream.
    ///
    /// ── THE NAMING GOES THROUGH THE AVFOUNDATION PATH'S OWN FUNCTIONS, ON PURPOSE ─────────────
    ///
    /// `MediaInspector.audioLayout(from:channelCount:)` for the name + confidence, and
    /// `AudioChannelLayoutBridge.roles(from:)` for the per-channel roles — the same two readers the
    /// AVFoundation path uses, fed the description `open()` built for THIS stream. ⚠️ **NOT
    /// `stream.layoutName`**: that is `av_channel_layout_describe` output ("5.1(side)"), a different
    /// vocabulary from the one `AudioTrackInfo.layoutName` holds. Two namers for one fact is how an
    /// MXF and a MOV of the same mix come to disagree in the same panel.
    ///
    /// ⚠️ AND THE THREE-TIER SHAPE IS USED AS-IS. `audioLayout` returns `.declared` only for a real
    /// declaration; a stream that declares nothing lands on `.inferred`/`.undeclared` and the row
    /// shows a channel count, italic and dimmed, rather than a layout name invented from the count.
    /// Nothing here adds a name the file did not give.
    ///
    /// STATIC AND PURE, so it cannot pick up a fact about the MONITORED stream while describing a
    /// different one — the mistake this whole change is one instance of avoiding.
    private static func audioTrackRow(for stream: LibavAudioSource.AudioInfo.StreamInfo) -> AudioTrackInfo {
        var row = AudioTrackInfo()
        // ⚠️ THE DISPLAY NAME, NOT FFmpeg's IDENTIFIER. `stream.codecName` is `avcodec_get_name`
        // output ("pcm_s24le") — an internal identifier that must not reach the inspector while the
        // AVFoundation path shows "PCM" for the same content. `audioFormatID` is the same codec
        // spelled as CoreAudio spells it, which lets both paths read ONE name list. Nil means no
        // CoreAudio equivalent, and then the FFmpeg identifier IS the honest answer — the same
        // fallback `audioCodecName` itself makes to a raw four-character code.
        row.codecName = stream.audioFormatID.map(MediaInspector.audioCodecName) ?? stream.codecName
        row.channelCount = stream.channels
        row.sampleRate = Double(stream.sampleRate)
        row.bitDepth = stream.bitsPerRawSample
        // The number a decoder is bound with — see `AudioTrackInfo.sourceStreamIndex`.
        row.sourceStreamIndex = Int(stream.streamIndex)
        if let fmt = stream.formatDescription {
            let layout = MediaInspector.audioLayout(from: fmt, channelCount: stream.channels)
            row.layoutName = layout.name
            row.layoutConfidence = layout.confidence
            row.roles = AudioChannelLayoutBridge.roles(from: fmt) ?? []
        } else {
            // No description means nothing could be built to READ a layout out of, which is not the
            // same as a file that declared nothing — but it reaches a viewer the same way, and the
            // channel count is still a fact. Same fallback `MediaInspector.audioTracks` makes for a
            // track with no format description; no layout is guessed from the count.
            row.layoutName = stream.channels > 0 ? "\(stream.channels) ch" : "—"
            row.layoutConfidence = .undeclared
        }
        return row
    }

    /// Resolve override + source range into the effective full-range flag the
    /// shader uses. Auto trusts the tag (full only if tagged-full); Full and Legal
    /// force their respective ranges. Decode stays 420v regardless — only this
    /// flag changes, so the shader expands (legal/video) or passes through (full).
    private func updateEffectiveRange() {
        let isFull: Bool
        switch rangeOverride {
        case .auto:  isFull = (sourceRange == .full)
        case .full:  isFull = true
        case .legal: isFull = false
        }
        effectiveIsFullRange = isFull
        rangeLock.lock(); effectiveRangeMirror = isFull; rangeLock.unlock()
    }

    /// Effective full-range flag, readable from the render thread (CVDisplayLink).
    public nonisolated func currentEffectiveIsFullRange() -> Bool {
        rangeLock.lock(); defer { rangeLock.unlock() }
        return effectiveRangeMirror
    }

    /// Apply a manual range override. Decode is always 420v, so the buffer never
    /// changes — only the shader's expansion flag does. No reader rebuild needed;
    /// the next rendered frame (or a forced refresh when paused) reflects it.
    public func setRangeOverride(_ override: RangeOverride) {
        guard override != rangeOverride else { return }
        rangeOverride = override
        updateEffectiveRange()
    }

    /// Stage 3a: the libav decode path (DNxHR), continuous clock-driven playback.
    /// The source is created+opened ONCE per file (then nil after a file change);
    /// each call seeks it to `time` and re-arms the decode pump with a fresh session
    /// token. The pump is paced by the SAME renderer backpressure the AVFoundation
    /// source uses, and the synchronizer is the master clock — so play/pause/seek
    /// all work through the existing transport.
    private func beginLibavReading(from time: Double, resumePlaying: Bool) async {
        guard let url = currentURL, let videoRenderer else { return }

        let token = sessionToken.next()
        synchronizer.rate = 0
        currentSource?.stop(); currentSource = nil      // retire any AVFoundation pump
        // ⚠️ AND THE AVFOUNDATION AUDIO READER, WHICH IS A SEPARATE SESSION SINCE THE DECOUPLING.
        // This branch RETURNS before `beginReading`'s own teardown, so without this an AVF audio
        // reader left over from a previously-loaded .mov would keep pumping into the shared
        // renderer underneath an MXF — the previous file's sound over the new file's picture.
        teardownAudioReading()
        videoRenderer.stopRequestingMediaData()          // stop the prior pump arm
        videoRenderer.flush(); onFlush?()

        // Create + open once per file. The libav-reported range is authoritative for
        // DNxHR (ACLR), where AVFoundation's FullRangeVideo extension is often absent.
        if libavSource == nil {
            let source = LibavFrameSource(url: url,
                                          pixelFormat: videoPixelFormat,
                                          pacingRenderer: videoRenderer,
                                          pumpQueue: videoPumpQueue)
            do {
                // open() enables auto-threaded decode so the 4K 10-bit source cost
                // doesn't contend with the render pipeline (locks 23.976fps).
                let info = try source.open()
                sourceRange = info.isFullRange ? .full : .videoLegal
                updateEffectiveRange()
                // Same rule as the AVFoundation path, at this path's equivalent point: libav has
                // just told us what the stream declares, and the decode pump is armed BELOW this
                // block, so this precedes the first frame. On the MXF path AVFoundation supplies
                // nothing at all, so without this the layer would keep the previous file's space
                // for the whole of the load — and `applyLibavMetadata` (which does carry these
                // codes) is both later and behind a SwiftUI update pass.
                onSourceColorTags?(info.primariesCode, info.transferCode, info.matrixCode)
                // MXF: AVFoundation is blind to the container, so the UI facts
                // (duration/size/fps/color/codec) come from libav. .mov-DNx already
                // has them from AVFoundation (videoTrack set) — leave those untouched.
                if videoTrack == nil { applyLibavMetadata(info, url: url) }
                print("FrameEngine: libav opened — \(info.width)x\(info.height), "
                    + "src \(info.sourcePixelFormat), range \(info.rangeName), "
                    + "matrix \(info.matrixName), audio=\(info.hasAudio)")
            } catch {
                print("FrameEngine: libav open failed for \(url.lastPathComponent): \(error)")
                return
            }
            // Same consumer wiring as the AVFoundation source: reference renderer +
            // Metal tap, both fed off the source's onVideoFrame.
            let vRenderer = videoRenderer
            let frameTap = onVideoFrame
            source.onVideoFrame = { sb in
                vRenderer.enqueue(sb)
                frameTap?(sb)
            }
            libavSource = source

            // Audio (if present): decode the audio stream to interleaved-float PCM
            // and feed the SHARED audioRenderer on the SAME synchronizer → A/V sync
            // is free. Absent audio → video-only (no source created).
            let audio = LibavAudioSource(url: url, pacingRenderer: audioRenderer, pumpQueue: audioPumpQueue)
            if let ainfo = try? audio.open() {
                let aRenderer = audioRenderer
                let tap = audioTap   // local capture (thread-safe class) — no main-actor hop on the pump
                audio.onAudioFrame = { sb in
                    tap.ingest(sb, path: .libav)   // D4b-1 tee — does not alter the enqueued buffer
                    aRenderer.enqueue(sb)
                }
                libavAudioSource = audio
                // The ONLY place an MXF's channel count is knowable — see `audioPresence`.
                let channels = ainfo.channels
                Task { @MainActor [weak self] in self?.audioPresence = .present(channels: channels) }
                print("FrameEngine: libav audio — \(ainfo.codecName) \(ainfo.sampleRate)Hz "
                    + "\(ainfo.channels)ch (\(ainfo.layoutName))")
                // The other streams, when there are any. Printed with FFmpeg's own identifiers and
                // stream NUMBERS, because a diagnostics reader is comparing this against ffprobe,
                // not against the inspector. Says plainly which one is being decoded — describing
                // four streams while decoding one is exactly the state that needs stating.
                if ainfo.streams.count > 1 {
                    for s in ainfo.streams {
                        let mark = s.streamIndex == ainfo.decoded.streamIndex ? " ← decoded" : ""
                        print("FrameEngine: libav audio stream #\(s.streamIndex) — \(s.codecName) "
                            + "\(s.sampleRate)Hz \(s.channels)ch (\(s.layoutName))\(mark)")
                    }
                }
                applyLibavAudioTrack(ainfo)
            } else {
                // POSITIVE evidence of absence, not merely a lack of evidence: the demuxer opened
                // the file and found no audio stream.
                Task { @MainActor [weak self] in self?.audioPresence = .absent }
                print("FrameEngine: libav — no audio stream (video-only)")
            }
        }

        // Anchor the clock at the seek target, then seek + arm both pumps.
        //
        // ── ⚠️ TWO TOKENS, AND THE COMMENT THAT USED TO SAY "THE SAME SESSION TOKEN" NAMED THE BUG
        //
        // Arming the AUDIO pump on `sessionToken` made the VIDEO token the audio pump's only
        // retirement authority on this path, which is exactly the coupling `audioSessionToken`
        // exists to prevent (see its declaration). Retiring libav audio alone meant bumping the
        // video token, which stops `LibavFrameSource` mid-playback — the stutter the two-token
        // split was built to remove, reintroduced on the one path that never got the split.
        //
        // It is also a live gap TODAY, independent of any track switch. `teardownAudioReading`
        // promises that an in-flight pump callback "bows out at its next check rather than racing
        // the cancel", and it delivers that by bumping `audioSessionToken`. Its
        // `stopRequestingMediaData()` prevents FURTHER callbacks, but a callback already inside
        // `arm`'s `while renderer.isReadyForMoreMediaData` loop re-tests `current()` — the VIDEO
        // token — finds it unchanged, and keeps enqueuing pre-flush frames into a renderer that
        // was just flushed. The AVFoundation audio pump has never had that window; this closes it
        // for libav by giving both pumps the same authority.
        let session = sessionToken
        // ⚠️ ORDERED, NOT ASSUMED. `teardownAudioReading()` near the top of this function already
        // bumped `audioSessionToken` and DISCARDED the result; the bump below supersedes that one
        // and keeps its value. Between the two there is no suspension point — this function is
        // `async`, but that whole stretch is straight-line main-actor code: it contains no `await`
        // at all, and its one early `return` is the libav-open failure, which never reaches here.
        // So no other `teardownAudioReading()` caller (`stop()`, `beginLiveAudio`,
        // `beginAudioReading`) can interleave between them and strand this token stale-on-arrival.
        //
        // This is the SAME two-step `beginAudioReading` performs on the AVFoundation path —
        // teardown bumps and discards, the new session bumps and keeps — so both paths now
        // establish audio currency identically rather than by two different rules.
        let audioSession = audioSessionToken
        let audioToken = audioSession.next()
        synchronizer.setRate(0, time: CMTime(seconds: time, preferredTimescale: 600))
        libavSource?.arm(fromSeconds: time, isCurrent: { session.isCurrent(token) })
        libavAudioSource?.arm(fromSeconds: time, isCurrent: { audioSession.isCurrent(audioToken) })
        if resumePlaying { play() }
    }

    // MARK: - Live (push-source) audio

    /// Where a live source hands decoded PCM. Holds the renderer and the tap directly so a network
    /// or decode thread can enqueue without hopping to the main actor — the same local-capture
    /// discipline the file and libav pumps use.
    public final class LiveAudioSink: @unchecked Sendable {
        private let renderer: AVSampleBufferAudioRenderer
        private let tap: AudioTapBuffer
        /// ⚠️ THE PATH IS A CONSTRUCTION PARAMETER, NOT A CONSTANT, AND THAT IS A CORRECTION.
        /// `enqueue` hardcoded `.whep`, which was true while WHEP was the only live source
        /// reaching this sink and silently wrong the moment a second one did: SRT audio would
        /// have been labelled WHEP in the tap's stats and in its format-change callback — a
        /// mislabel that reads as a real observation and would be believed.
        private let path: AudioTapBuffer.SourcePath
        fileprivate init(renderer: AVSampleBufferAudioRenderer, tap: AudioTapBuffer,
                         path: AudioTapBuffer.SourcePath) {
            self.renderer = renderer; self.tap = tap; self.path = path
        }
        /// Tee to the tap, then to the renderer — the SAME order and the same two consumers the
        /// file pump feeds, so metering, SDI embedding, routing and mute all apply unchanged.
        public func enqueue(_ sampleBuffer: CMSampleBuffer) {
            tap.ingest(sampleBuffer, path: path)
            renderer.enqueue(sampleBuffer)
        }
    }

    /// Open the shared audio renderer to a live push source, with the synchronizer's timebase
    /// anchored to `clockSeconds` — the live clock's current reading.
    ///
    /// ── WHY THE SYNCHRONIZER IS ANCHORED RATHER THAN LEFT ALONE ───────────────────────────────
    ///
    /// A live source presents VIDEO through `MetalVideoRenderer`, paced by `LiveClock.now()`; the
    /// synchronizer is not involved in that at all. But `AVSampleBufferAudioRenderer` presents by
    /// PTS against a timebase, so for audio to land with the picture the timebase has to read the
    /// SAME timeline LiveClock does. Anchoring it here and stamping every buffer with its live-clock
    /// presentation time is what makes "the audio is scheduled by the existing LiveClock" literally
    /// true rather than approximately true.
    ///
    /// ⚠️ RATE 1.0 IS AN ASSUMPTION WITH A KNOWN EXPIRY. LiveClock slews its own rate slightly off
    /// 1.0 to regulate the VIDEO buffer depth; the synchronizer here runs at exactly 1.0. The two
    /// therefore diverge at the slew rate, which is small but not zero. `liveAudioDrift` reports the
    /// gap so a lip-sync measurement can see it rather than inferring it, and so the decision about
    /// whether it matters is made from a number.
    /// ⚠️ DOES NOT ANCHOR THE TIMEBASE, AND MUST NOT — THE ANCHOR TIME IS NOT KNOWN YET.
    ///
    /// This used to take `startingAt clockSeconds` and hand it straight to `synchronizer.setRate`.
    /// That was wrong on the WHEP path in a way that made audio permanently unschedulable:
    ///
    ///   * `LiveClock.now()` returns `-.infinity` — a DELIBERATE sentinel — until the first VIDEO
    ///     frame calls `registerFrame`. Audio never calls it and cannot anchor the clock.
    ///   * This function runs when the ANSWER is applied, which is necessarily before any video
    ///     frame has arrived. So `clockSeconds` was `-.infinity` essentially every time.
    ///   * `CMTime(seconds: -.infinity, preferredTimescale:)` is an INVALID CMTime, so the
    ///     synchronizer was anchored to nothing and `currentTime()` read as NaN.
    ///
    /// The anchor is now taken by `anchorLiveAudio(at:)`, from the first audio packet that sees a
    /// FINITE clock — the first moment the value actually exists. Until then the renderer holds at
    /// rate 0 with nothing scheduled, which is the correct state: video is not presenting yet either.
    /// `path` names which live transport is feeding this sink. It reaches the tap's stats, the
    /// tap's format-change callback AND the mirror's log tag, so it is the one value that decides
    /// whether a line about this session names the transport that produced it.
    ///
    /// ⚠️ NO DEFAULT, AND THE MISSING DEFAULT IS THE FIX. This used to default to `.whep` "so the
    /// existing WHEP call site is unchanged", which made the parameter optional at exactly the
    /// moment a second transport arrived — `WindowDeck` wired SRT's seam by copying WHEP's line,
    /// the default silently applied, and an entire SRT session logged `AudioTap[WHEP]`. The
    /// LiveAudioSink note below already called that class of mislabel out ("reads as a real
    /// observation and would be believed") and then a defaulted parameter reintroduced it one
    /// layer up. A required argument is what makes a new transport unable to inherit WHEP's name.
    public func beginLiveAudio(cushion: Double,
                               path: AudioTapBuffer.SourcePath) -> LiveAudioSink {
        // A live source is not a file: retire any file audio session first so two producers can
        // never feed the renderer at once.
        teardownAudioReading()
        liveAudioActive = true
        liveAudioAnchor = nil
        mirror.lock.lock()
        mirror.active = true; mirror.cushion = cushion; mirror.mirrored = false
        mirror.path = path
        mirror.smoothedRate = 1.0; mirror.haveSmoothed = false
        mirror.lastHost = 0; mirror.firstHost = 0
        mirror.pushedRate = 1.0; mirror.pushedMedia = 0; mirror.pushedHost = 0
        mirror.changes = 0; mirror.pushes = 0; mirror.lastStatsHost = 0
        mirror.lock.unlock()
        audioRenderer.flush()
        synchronizer.rate = 0      // held until the first mirrored mapping arrives
        applyAudioMute()
        audioPresence = .unknown   // "don't know yet" until the first packet establishes channels
        return LiveAudioSink(renderer: audioRenderer, tap: audioTap, path: path)
    }

    /// Mirror state, reachable from the threads `mirrorLiveAudio` runs on (the WHEP source thread
    /// and the display tick). Separate from `liveAudioActive`/`liveAudioAnchor`, which are
    /// main-actor state read by the UI — the two describe the same session but are read from
    /// different isolation domains, and merging them would put a lock on the main-actor path.
    final class LiveAudioMirrorState: @unchecked Sendable {
        let lock = NSLock()
        var active = false
        var cushion: Double = 0
        var mirrored = false          // has at least one mapping landed?

        /// Which transport opened this session — the mirror's LOG TAG, and nothing else.
        ///
        /// ⚠️ THE MIRROR IS TRANSPORT-AGNOSTIC AND ITS LOG WAS NOT. `mirrorLiveAudio` is fed by
        /// whichever live source holds the clock; both of its lines were nevertheless hardcoded
        /// `[WHEP-AUDIO]`, so an SRT session reported its timebase mirroring under WHEP's tag —
        /// the same class of mislabel as `LiveAudioSink`'s hardcoded `.whep`, and just as
        /// believable, because the numbers in those lines are real.
        var path: AudioTapBuffer.SourcePath = .whep

        // ── RATE SMOOTHING STATE ───────────────────────────────────────────────────────────
        var smoothedRate: Double = 1.0
        var haveSmoothed = false
        var lastHost: Double = 0
        /// Host time of the first mapping, for the τ ramp. 0 until the first mapping lands.
        var firstHost: Double = 0
        // What the synchronizer was last actually told.
        var pushedRate: Double = 1.0
        var pushedMedia: Double = 0
        var pushedHost: Double = 0
        // Counters — `changes` is mappings received, `pushes` is setRate calls issued. The ratio is
        // the thing that was unmeasurable on the run that motivated this.
        var changes = 0
        var pushes = 0
        var lastStatsHost: Double = 0
    }

    /// EMA time constant for the mirrored rate, in seconds.
    ///
    /// ⚠️ CHOSEN FROM THE MEASURED SENDER CLOCK, NOT PICKED FOR FEEL. `[WHEP-DRIFT]` puts the real
    /// sender/receiver ratio at σ = 0.021%, |err| max 0.042% — a total spread of **1.1 cents**. The
    /// control loop meanwhile swings the full ±0.5% rail, **17.3 cents peak-to-peak**, at up to
    /// `controlHz` = 10 Hz. So ~94% of the rate signal is buffer-depth correction, not clock
    /// tracking, and for audio that correction IS varispeed — a 17-cent warble at 10 Hz.
    ///
    /// 30 s sits between the two timescales by a wide margin in both directions: it is 300× the
    /// P-loop's 0.1 s update interval and ~30× the ~1 s depth wobble, so depth transients are
    /// attenuated to nothing; while a genuine sender offset is very nearly a constant, so it is
    /// still tracked to within a few percent of its value inside a minute.
    private static let liveAudioRateTau = 30.0

    /// ── STARTUP CONVERGENCE: A SHORT TIME CONSTANT THAT RAMPS TO THE STEADY-STATE ONE ────────
    ///
    /// THE DEFECT THIS FIXES: the EMA starts with no history. It is seeded at 1.0 while the clock
    /// is typically already railed near 1.004 (44.6% of samples sit at a rail), so the mirrored
    /// rate lags reality by ~0.4% and position error accrues at ~4 ms/s until it trips the position
    /// tolerance. Measured over a 13-minute run: every excursion above 30 ms fell in the first 27
    /// seconds, as a monotonic ramp followed by a correction. Steady state was fine — middle and
    /// last thirds ran mean +3.5 ms, σ 3.2 ms, range −5.4…+11.3 ms.
    ///
    /// ⚠️ WHY NOT SEED FROM THE CLOCK'S RATE AT ANCHOR (the obvious one-liner): at anchor time the
    /// clock is most often AT A RAIL, so seeding from that single instantaneous sample seeds the
    /// filter with the very excursion it exists to reject — trading a 4 ms/s ramp for a τ-long
    /// unwind of a 0.5% bias. Averaging quickly beats copying one sample.
    ///
    /// τ is therefore ramped linearly from `liveAudioRateTauFast` to `liveAudioRateTau` over
    /// `liveAudioRateRamp` seconds of session time.
    ///
    /// ⚠️ THE STEADY STATE CANNOT REGRESS, AND THAT IS BY CONSTRUCTION RATHER THAN BY MEASUREMENT:
    /// once elapsed ≥ `liveAudioRateRamp`, τ is exactly `liveAudioRateTau` and the filter is
    /// bit-identical to the one that produced those numbers. The ramp is unreachable after 10 s,
    /// so it can only affect the window where the excursions actually were.

    /// 2 s ≈ 20 P-loop updates at `controlHz` — enough to average out per-tick noise, short enough
    /// that the EMA is within ~5% of the true rate by 3τ ≈ 6 s.
    private static let liveAudioRateTauFast = 2.0

    /// 10 s. All measured excursions >30 ms were inside the first 27 s, so full smoothing is in
    /// place well before the steady-state regime the constraint protects begins.
    private static let liveAudioRateRamp = 10.0

    /// Push the rate only once it has moved this far from what the synchronizer was last told.
    ///
    /// 0.02% ≈ the sender ratio's own σ (0.0206%): below this we would be chasing measurement noise
    /// rather than clock. As a STEP it is 0.35 cents, far under the ~5-cent pitch JND, so each push
    /// is individually inaudible. And it bounds the position error the rate alone can accumulate:
    /// at 0.02% residual, a full minute between pushes costs 12 ms — under a third of a frame.
    private static let liveAudioRateThreshold = 0.0002

    /// Push regardless of rate when the timebase would be this far from `LiveClock`'s position.
    /// This is what makes a snap, a freeze-guard correction or the first anchor land IMMEDIATELY
    /// and exactly — they arrive as a large position error, not as a rate change — and it is why
    /// smoothing the rate does not weaken the anchor mirroring that removed the 190 ms drift.
    private static let liveAudioPositionTolerance = 0.010
    private let mirror = LiveAudioMirrorState()

    /// Track `LiveClock`'s mapping so the audio timebase reads what `now()` reads, minus the
    /// cushion. THIS REPLACED A ONE-SHOT ANCHOR, and the difference is the whole fix:
    ///
    ///   * `LiveClock` rewrites its mapping from SEVEN places (first anchor, target retarget, the
    ///     unity-rate pin, the snap, the P-loop rate change, the freeze guard, the overflow
    ///     re-anchor) and slews `rate` within ±0.5% continuously.
    ///   * Video follows all of it for free because it reads `now()` per frame. A timebase pinned
    ///     once at rate 1.0 follows none of it. Measured on two saved runs, that divergence reached
    ///     **190 ms** within 3–4 minutes — about 4.5 frames at 24 fps.
    ///
    /// ⚠️ THE CUSHION GOES ON THE HOST ANCHOR, NOT THE MEDIA STAMPS. Video's anchor is pinned
    /// `startupDepth` into the future (`registerFrame`), and the loop then holds the buffer at
    /// `targetDepth`, so a video frame is presented `targetDepth` after it arrives. Audio stamps
    /// carry sender-timeline values with no such offset. Subtracting the cushion HERE gives audio
    /// the same lead without touching the timestamps, so the two paths' PTS values stay directly
    /// comparable when someone photographs them side by side.
    ///
    /// `nil` means un-anchored (`reset()`): hold the renderer rather than guess.
    ///
    /// NONISOLATED because it is called from `LiveClock`'s callback, which fires on whichever
    /// thread changed the mapping. `AVSampleBufferRenderSynchronizer` handles its own
    /// thread-safety for `setRate` — the same rationale as `currentSyncTime()` above.
    public nonisolated func mirrorLiveAudio(_ mapping: LiveClock.Mapping?) {
        mirror.lock.lock()
        let active = mirror.active
        let cushion = mirror.cushion
        let wasMirrored = mirror.mirrored
        // The transport's own tag — read under the same lock as everything else this session owns.
        let tag = "[\(mirror.path.rawValue)-AUDIO]"
        if active, mapping != nil { mirror.mirrored = true }
        if mapping == nil { mirror.mirrored = false }
        mirror.lock.unlock()
        guard active else { return }

        guard let m = mapping,
              m.senderPTS.isFinite, m.hostTime.isFinite, m.rate.isFinite, m.rate > 0 else {
            // Un-anchored, or a mapping we cannot represent. Holding is correct: video is not
            // presenting either, and a guessed timebase is what produced the -inf failure before.
            synchronizer.rate = 0
            return
        }
        // ── ANCHOR FAITHFULLY, RATE SLOWLY ────────────────────────────────────────────────
        //
        // Position is mirrored exactly; only the RATE the synchronizer sees is smoothed. The two
        // are separated by asking what our timebase would read right now given what we last pushed:
        // a pure P-loop rate change leaves position continuous (LiveClock sets the new anchor to
        // the old mapping evaluated at the same instant), so it shows up as ~zero position error
        // and is allowed to be throttled. A snap, freeze-guard correction or first anchor shows up
        // as a LARGE position error and is pushed immediately, unsmoothed.
        //
        // This is not a second mechanism beside the funnel — the funnel is still the only writer of
        // the mapping. This is the consumer deciding what to forward, which is the only place the
        // distinction between "the clock moved" and "the controller twitched" can be made.
        let target = m.senderPTS - cushion
        mirror.lock.lock()
        let dt = mirror.haveSmoothed ? max(0.0, min(1.0, m.hostTime - mirror.lastHost)) : 0.0
        if mirror.haveSmoothed {
            // dt-based EMA so the constant means seconds, not "per callback" — the callback rate
            // varies with what the control loop is doing and must not change the filter.
            let elapsed = m.hostTime - mirror.firstHost
            let ramp = min(1.0, max(0.0, elapsed / Self.liveAudioRateRamp))
            let tau = Self.liveAudioRateTauFast
                    + (Self.liveAudioRateTau - Self.liveAudioRateTauFast) * ramp
            let alpha = 1.0 - exp(-dt / tau)
            mirror.smoothedRate += alpha * (m.rate - mirror.smoothedRate)
        } else {
            mirror.smoothedRate = m.rate
            mirror.haveSmoothed = true
            mirror.firstHost = m.hostTime
        }
        mirror.lastHost = m.hostTime
        mirror.changes += 1

        let predicted = mirror.pushedMedia + (m.hostTime - mirror.pushedHost) * mirror.pushedRate
        let positionError = wasMirrored ? abs(target - predicted) : .infinity
        let rateMoved = abs(mirror.smoothedRate - mirror.pushedRate)
        let shouldPush = positionError > Self.liveAudioPositionTolerance
                      || rateMoved > Self.liveAudioRateThreshold
        let rateToPush = mirror.smoothedRate
        let smoothedNow = mirror.smoothedRate
        if shouldPush {
            mirror.pushedRate = rateToPush
            mirror.pushedMedia = target
            mirror.pushedHost = m.hostTime
            mirror.pushes += 1
        }
        let changes = mirror.changes, pushes = mirror.pushes
        let statsDue = m.hostTime - mirror.lastStatsHost >= 10.0
        if statsDue { mirror.lastStatsHost = m.hostTime }
        mirror.lock.unlock()

        // ⚠️ EMITTED BEFORE THE PUSH GUARD, AND THAT ORDERING IS THE WHOLE POINT OF THIS LINE.
        // It used to sit after `guard shouldPush`, while `lastStatsHost` was advanced before it —
        // so a 10 s window that came due without a push consumed the window and printed nothing.
        // The effect was to report only the windows that happened to end in a push, which made the
        // change→call ratio — the one number this line exists to produce — read far too low: two
        // lines in 67 s claiming 3 mapping changes, against 37 rate changes visible in the 1 Hz
        // [LIVECLOCK] series over the same run. A throttle that reports only when the throttled
        // thing fires cannot measure what it is throttling.
        if statsDue {
            NSLog("%@ mirror — %d mapping change(s) → %d setRate call(s) "
                + "· smoothedRate=%.5f · clockRate=%.5f · posErr=%.1f ms%@",
                  tag, changes, pushes, smoothedNow, m.rate,
                  positionError.isFinite ? positionError * 1000 : 0,
                  shouldPush ? "" : " · (no push this window)")
        }

        guard shouldPush else { return }
        synchronizer.setRate(Float(rateToPush),
                             time: CMTime(seconds: target, preferredTimescale: 90_000),
                             atHostTime: CMTime(seconds: m.hostTime, preferredTimescale: 90_000))
        if !wasMirrored {
            NSLog("%@ timebase MIRRORED — first mapping: senderPTS=%.3fs host=%.3fs "
                + "rate=%.5f (smoothed %.5f) cushion=%.3fs → timebase=%.3fs",
                  tag, m.senderPTS, m.hostTime, m.rate, rateToPush, cushion, target)
        }
    }

    /// The live source has established its channel count — publish it so the meters size their bars
    /// from the DECODER rather than growing into shape as audio arrives.
    public func liveAudioEstablished(channels: Int) {
        audioPresence = channels > 0 ? .present(channels: channels) : .unknown
    }

    /// The live source carries no audio at all, established positively (the server declined the
    /// m-section, or the stream has none). Distinct from `.unknown`, which is "not yet".
    public func liveAudioAbsent() {
        audioPresence = .absent
    }

    /// How far the synchronizer's timebase has drifted from the live clock, in seconds. Positive =
    /// audio timebase is AHEAD of the video clock. Nil when no live audio session is running.
    /// ⚠️ THIS GUARDED ON `liveAudioAnchor`, WHICH NOTHING SETS ANY MORE — so it returned nil for
    /// an entire 125 s verification run and printed `timebase−clock=n/a` throughout, which is
    /// precisely the number that was supposed to prove the mirror was holding. `liveAudioAnchor`
    /// was written by `anchorLiveAudio(at:)`; when the mirror replaced that, its only writer went
    /// with it and this guard was left keyed to a field frozen at nil. The mirror's own state is
    /// the correct predicate: it is set exactly when a mapping has actually reached the timebase.
    public func liveAudioDrift(against clockSeconds: Double) -> Double? {
        mirror.lock.lock()
        let ready = mirror.active && mirror.mirrored
        mirror.lock.unlock()
        guard ready, clockSeconds.isFinite else { return nil }
        let timebase = CMTimeGetSeconds(synchronizer.currentTime())
        guard timebase.isFinite else { return nil }
        // The timebase deliberately runs `cushion` behind the live clock (see `mirrorLiveAudio`),
        // so that offset is removed here. What remains is the MIRROR ERROR — how far the audio
        // timebase has slipped from the mapping it is tracking — which is what this is read for.
        // Reporting the raw difference would show a constant −0.400 s and bury the signal.
        return (timebase + liveAudioCushionValue) - clockSeconds
    }

    /// Cushion, readable on the main actor for `liveAudioDrift`.
    private var liveAudioCushionValue: Double {
        mirror.lock.lock(); defer { mirror.lock.unlock() }
        return mirror.cushion
    }

    public func endLiveAudio() {
        // Guarded on ACTIVE, not on the anchor: a session that never saw a finite clock still has a
        // renderer and a tap to retire. Keying this to the anchor would leak exactly the session
        // that failed to start.
        guard liveAudioActive else { return }
        liveAudioActive = false
        liveAudioAnchor = nil
        mirror.lock.lock()
        mirror.active = false; mirror.mirrored = false
        mirror.lock.unlock()
        synchronizer.rate = 0
        audioRenderer.flush()
        audioTap.reset()
        audioPresence = .unknown
    }

    private var liveAudioAnchor: Double?
    /// A live-audio session is open. DISTINCT from `liveAudioAnchor`, which is only set once the
    /// clock becomes finite — there is a real window where a session is running and unanchored.
    private var liveAudioActive = false

    // MARK: - The audio reading session (independent of the video reader)

    /// Retire the current audio reader and pump. Leaves the VIDEO side completely alone.
    ///
    /// Bumps `audioSessionToken` first so an in-flight pump callback bows out at its next check
    /// rather than racing the cancel, then serializes the cancellation behind the audio pump queue
    /// so it cannot overlap an `copyNextSampleBuffer()` already running there.
    private func teardownAudioReading() {
        _ = audioSessionToken.next()
        audioRenderer.stopRequestingMediaData()
        let toCancel = audioReader
        audioReader = nil
        audioPumpQueue.async { toCancel?.cancelReading() }
        audioRenderer.flush()
        audioTap.reset()   // the ring holds the previous track/position — never serve across a swap
    }

    /// Build and start the audio reader for the currently selected track, positioned at `start`,
    /// and wire the pump that feeds the shared `audioRenderer` and the tap.
    ///
    /// Called from `beginReading` (load / seek — both readers move together) and from
    /// `selectAudioTrack` (track switch — ONLY this side moves). It never touches `reader`,
    /// `currentSource`, `synchronizer.rate` or the video renderer, which is what makes a track
    /// switch invisible on the picture.
    ///
    /// ⚠️ `synchronizer.setRate` IS DELIBERATELY NOT CALLED HERE. The timebase is the one clock both
    /// renderers share; re-anchoring it for an audio-side rebuild would move the picture. Buffers
    /// carry their own source pts and the synchronizer places them against the clock that is already
    /// running — including discarding the few milliseconds that are already past by the time the
    /// reader spins up (MEASURED at 3–4 ms warm), which is why the splice is inaudible.
    private func beginAudioReading(from start: CMTime) async {
        teardownAudioReading()

        guard let asset, let aTrack = audioTrack,
              let settings = await Self.audioOutputSettings(for: aTrack) else {
            // No audio track at all, or no readable stream description. Both are POSITIVE evidence
            // of absence for a file we have successfully opened — the meters are entitled to say
            // "NO AUDIO TRACK" rather than sit at silence.
            audioPresence = .absent
            return
        }

        let token = audioSessionToken.next()

        guard let newReader = try? AVAssetReader(asset: asset) else {
            NSLog("[PLAYBACK] could not create the audio reader"); audioPresence = .unknown; return
        }
        newReader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        let out = AVAssetReaderTrackOutput(track: aTrack, outputSettings: settings)
        out.alwaysCopiesSampleData = false
        guard newReader.canAdd(out) else {
            NSLog("[PLAYBACK] audio reader refused the track output"); audioPresence = .absent; return
        }
        newReader.add(out)

        guard newReader.startReading() else {
            // ── THE FAILURE THAT USED TO BLACK OUT THE PICTURE ────────────────────────────────
            // On the old shared reader this took the video down with it and needed a
            // retry-without-audio rebuild. Now it is contained: the video reader is already
            // running and is not involved. We lose this file's audio and say so, once.
            NSLog("[PLAYBACK] audio reader startReading failed: %@", String(describing: newReader.error))
            audioPresence = .absent
            if !audioFallbackAnnounced {
                audioFallbackAnnounced = true
                playbackNotice = "This file’s audio track couldn’t be read — playing video only."
            }
            return
        }
        audioFallbackAnnounced = false
        self.audioReader = newReader

        let aRenderer = audioRenderer
        let tap = audioTap          // thread-safe class, captured locally — no main-actor hop
        let session = audioSessionToken
        aRenderer.requestMediaDataWhenReady(on: audioPumpQueue) { [weak self] in
            guard self != nil, session.isCurrent(token) else {
                aRenderer.stopRequestingMediaData(); return
            }
            while aRenderer.isReadyForMoreMediaData {
                guard session.isCurrent(token) else {
                    aRenderer.stopRequestingMediaData(); return
                }
                guard newReader.status == .reading, let next = out.copyNextSampleBuffer() else {
                    aRenderer.stopRequestingMediaData(); return
                }
                tap.ingest(next, path: .avFoundation)   // D4b-1 tee — does not alter the buffer
                aRenderer.enqueue(next)
            }
        }

        // The channel count the meters label, from the track's own ASBD. A count we cannot read is
        // NOT evidence of absence — audio is demonstrably there (the reader started).
        let descs = (try? await aTrack.load(.formatDescriptions)) ?? []
        let ch = descs.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0) }
                      .map { Int($0.pointee.mChannelsPerFrame) } ?? 0
        audioPresence = ch > 0 ? .present(channels: ch) : .unknown
    }

    /// LPCM output settings for an audio track, with the channel count taken from the track's OWN
    /// ASBD rather than left for AVFoundation to infer.
    ///
    /// 32-bit signed int (not 16): a reference tool must not downconvert. 24-bit sources reach the
    /// renderer + the D4b-1 audio tap at full precision; the tap reads the ASBD generically (int32
    /// pass-through), and AVSampleBufferAudioRenderer accepts int32 interleaved LPCM, so the
    /// system-audio path is unaffected. This also matches the libav/MXF path's fidelity. Nothing
    /// here downmixes — the channel COUNT is preserved exactly as the source carries it.
    ///
    /// WHY THE CHANNEL COUNT IS EXPLICIT. Omitting `AVNumberOfChannelsKey` makes AVFoundation
    /// derive the output channel count from the source's channel layout. MEASURED: on an ARRI
    /// ALEXA Mini ProRes whose 5-channel track advertises layout tag 0xFFFF0000 — Unknown ORed
    /// with a channel count of ZERO, contradicting its own 5-channel ASBD — that derivation
    /// produces an invalid output format and startReading fails with paramErr (-50). Supplying the
    /// count removes the derivation entirely. Bit depth is irrelevant to that failure: int16,
    /// int24, int32 and float32 all failed identically without the count, and all succeeded with it.
    ///
    /// Returns nil when the channel count cannot be established. Callers then add NO audio output
    /// and fall back to video-only — deliberately NOT "emit the settings without a channel count",
    /// which is precisely the configuration that fails. There is no code path left that can build
    /// LPCM settings with no channel count.
    private static func audioOutputSettings(for track: AVAssetTrack) async -> [String: Any]? {
        guard let formats = try? await track.load(.formatDescriptions),
              let fmt = formats.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else {
            NSLog("[PLAYBACK] audio track has no readable stream description — omitting audio output")
            return nil
        }
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0 else {
            NSLog("[PLAYBACK] audio track reports 0 channels — omitting audio output")
            return nil
        }

        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: channels
        ]

        // Above stereo, AVFoundation wants an explicit layout alongside the count. PREFER THE
        // SOURCE'S OWN — a well-formed 5.1 tag must survive, or a legitimate surround file would
        // lose its speaker assignment to a flat discrete mapping. Only when the source's layout is
        // the Unknown family (high 16 bits == 0xFFFF — the ARRI case) is one synthesised, and then
        // as DiscreteInOrder: it preserves count and channel ORDER while claiming nothing about
        // speaker roles, which is the honest answer when the file itself doesn't know.
        if channels > 2 {
            var sourceLayout: Data?
            var layoutSize = 0
            if let layoutPtr = CMAudioFormatDescriptionGetChannelLayout(fmt, sizeOut: &layoutSize),
               layoutSize > 0,
               (layoutPtr.pointee.mChannelLayoutTag >> 16) != 0xFFFF {
                sourceLayout = Data(bytes: layoutPtr, count: layoutSize)
            }
            if let sourceLayout {
                settings[AVChannelLayoutKey] = sourceLayout
            } else {
                var synthesized = AudioChannelLayout()
                synthesized.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
                settings[AVChannelLayoutKey] = Data(bytes: &synthesized,
                                                    count: MemoryLayout<AudioChannelLayout>.size)
                NSLog("[PLAYBACK] audio track advertises an unknown channel layout — "
                    + "using DiscreteInOrder for its %d channels", channels)
            }
        }
        return settings
    }

    private func beginReading(from time: Double, resumePlaying: Bool) async {
        if useLibav {
            await beginLibavReading(from: time, resumePlaying: resumePlaying)
            return
        }
        guard let asset, let vTrack = videoTrack, let videoRenderer else { return }

        // Retire any prior pump session.
        let token = sessionToken.next()

        synchronizer.rate = 0
        currentSource?.stop()           // retire the prior session's video pump
        currentSource = nil

        // BOTH readers move on a seek. The audio side retires through its own teardown (bumping
        // `audioSessionToken`, flushing the renderer and resetting the tap for the pts
        // discontinuity); `beginAudioReading` at the bottom re-establishes it at the new position.
        // A scrub therefore still moves picture and sound together — decoupling changed which
        // operations move ONE side, not whether a seek moves both.
        teardownAudioReading()

        let oldReader = reader
        reader = nil
        videoPumpQueue.async {
            self.audioPumpQueue.async {
                oldReader?.cancelReading()
            }
        }
        videoRenderer.flush()
        onFlush?()

        guard let newReader = try? AVAssetReader(asset: asset) else {
            print("FrameEngine: reader create failed"); return
        }
        let start = CMTime(seconds: time, preferredTimescale: 600)
        newReader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)

        // The file decode now flows through the FrameSource seam: FileFrameSource
        // owns the video output + pump and emits frames via onVideoFrame (wired to
        // the consumers below). Always decode videoPixelFormat (420v, raw video-
        // range): the file's stored values, unclipped — range handling happens in
        // the shader via effectiveIsFullRange, never by a full-range decode (which
        // would pre-expand and clip super-white / sub-black content).
        // Currency is gated by the session token — the SAME monotonic authority the
        // engine already uses (bumped to `token` above). A superseded source's pump
        // sees this go false and bows out without touching the shared renderer, so
        // rapid create→retire churn (J jog, aggressive scrub) can't let a dying
        // source cancel the live one.
        let session = sessionToken
        guard let source = FileFrameSource(reader: newReader,
                                           track: vTrack,
                                           pixelFormat: videoPixelFormat,
                                           pacingRenderer: videoRenderer,
                                           pumpQueue: videoPumpQueue,
                                           isCurrent: { session.isCurrent(token) }) else {
            print("FrameEngine: cannot add video output"); return
        }

        // ── THE VIDEO READER CARRIES VIDEO ONLY ───────────────────────────────────────────────
        // Audio lives on its own reader (see `audioReader`), so there is nothing here that could
        // fail on the audio track's behalf. The retry-without-audio rebuild this function used to
        // carry — written for the ARRI ALEXA Mini 0xFFFF0000 layout that failed -11800/paramErr -50
        // and left the tester looking at a black screen — is gone with the coupling that caused it.
        // A failure here is the VIDEO's, and there is no longer anything to drop and retry without.
        guard newReader.startReading() else {
            NSLog("[PLAYBACK] video reader startReading failed: %@", String(describing: newReader.error))
            return
        }
        let reader = newReader
        let activeSource = source

        self.reader = reader
        synchronizer.setRate(0, time: start)

        // Route the FrameSource's frames to the SAME two consumers as before:
        // the reference AVSampleBufferVideoRenderer (display + sync clock) and the
        // engine's Metal tap (onVideoFrame, set by the UI). Set unconditionally so
        // the display path enqueues even when no Metal tap is attached — exactly
        // the old pump's behavior, just routed through the protocol.
        let vRenderer = videoRenderer
        let frameTap = onVideoFrame
        activeSource.onVideoFrame = { sb in
            vRenderer.enqueue(sb)
            frameTap?(sb)
        }
        self.currentSource = activeSource
        try? activeSource.start()

        // AUDIO, on its own reader, positioned at the SAME source time. A seek moves both readers;
        // a track switch calls this one alone. Awaited rather than fired-and-forgotten so
        // `audioPresence` is settled before this function returns — the meters key their empty
        // states off it, and a load that returned with it still stale would flash "NO AUDIO TRACK"
        // over a file that has some.
        await beginAudioReading(from: start)

        if resumePlaying { play() }
        print("FrameEngine: reading from \(time)s (audio reader: \(audioReader != nil))")
    }
}

// AVAssetReader/AVAssetReaderTrackOutput predate Swift concurrency and have no
// Sendable annotation. Each session's instances are exclusively owned by one pump
// queue, so the unchecked conformance is safe.
extension AVAssetReader: @retroactive @unchecked Sendable {}
extension AVAssetReaderTrackOutput: @retroactive @unchecked Sendable {}

/// Thread-safe session counter so a background pump can tell if it's been
/// superseded by a newer reading session (seek/reload) without touching the
/// main actor.
private final class SessionToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
    func isCurrent(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == value
    }
}
