import Foundation
import CoreMedia

/// The file audio pumps' tap LOOK-AHEAD (docs/AUDIO_RESAMPLER_DESIGN.md §19.12).
///
/// ── WHY THE TAP CANNOT BE FILLED ONLY WHEN THE RENDERER ASKS ────────────────────────────────
///
/// Both file pumps (AVFoundation and libav) used to tee each decoded buffer into `AudioTapBuffer`
/// at the moment `audioRenderer` accepted it, so the tap could only ever be as far ahead of the
/// playhead as the renderer chose to be. MEASURED (§19.12): while SDI owns the audio the renderer
/// is MUTED, and a muted `AVSampleBufferAudioRenderer` refills on a 0.5 / 1.0 s timer and lets
/// its queue drain to −150…+60 ms of the playhead before asking again (unmuted it stays
/// +1.2…+1.6 s ahead). The DeckLink card reads the tap at playhead − ~54 ms, so every refill
/// cycle that drained past that put 20–100 ms of digital silence on SDI: 1–20 times a minute.
///
/// The fix keeps the renderer's pacing exactly as it was and decouples the TAP from it: after
/// the renderer has taken what it wants, the pump decodes on until it holds `seconds` of audio
/// the renderer has not taken, ingesting each buffer into the tap as it is decoded. The held
/// buffers go to the renderer, in order, at its next wake — before anything new is decoded — so
/// the renderer receives the identical sequence it always did, merely decoded earlier.
///
/// Muted or not: the look-ahead runs unconditionally. Unmuted, the renderer already runs far
/// ahead, and 250 ms more costs only memory (and is why the tap's window is 4 s, not 2).
///
/// ── STALE AUDIO: OWNED BY THE ARM, RESET WITH THE TAP ─────────────────────────────────────────
///
/// One pump object per ARM (per audio session token). Everything that moves the read position —
/// seek, frame step, loop, scrub release, track switch, file switch — retires the arm through
/// `FrameEngine.teardownAudioReading()` (bump the token, flush the renderer, `audioTap.reset()`)
/// and arms a new one. So held buffers never cross an arm: the tap copies of them are dropped by
/// that `reset()`, and the buffers themselves are dropped by `service` the first time it sees the
/// retired token. `isCurrent` is re-tested AFTER each decode and before the tap ingest, so a
/// decode that was in flight when the teardown ran does not reach the freshly reset tap.
///
/// Confined to the pump's serial queue; not thread-safe, and need not be.
public enum TapLookahead {
    /// How far past the renderer the tap is filled. MEASURED (§19.12): the muted renderer's head
    /// falls to −150 ms of the playhead and the card reads at −54 ms, a ~95 ms deficit; 250 ms
    /// gave a mid-file tap lead ≥ 232 ms over the card's cursor in 7 / 7 runs (AAC MP4, PCM MOV).
    public static let seconds: Double = 0.250

    /// Duration of a decoded PCM buffer, in seconds: its sample count over its rate. Falls back to
    /// the buffer's own duration when the format cannot be read.
    public static func duration(of sampleBuffer: CMSampleBuffer) -> Double {
        if let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
           asbd.mSampleRate > 0 {
            return Double(CMSampleBufferGetNumSamples(sampleBuffer)) / asbd.mSampleRate
        }
        let d = CMTimeGetSeconds(CMSampleBufferGetDuration(sampleBuffer))
        return d.isFinite && d > 0 ? d : 0
    }
}

/// One arm's look-ahead state and its pump loop. Generic over the buffer so the loop is testable
/// without a renderer; the pumps use `CMSampleBuffer`.
public final class TapLookaheadPump<Buffer>: @unchecked Sendable {

    public enum Outcome: Equatable {
        /// The renderer is full and the look-ahead is topped up: wait for the next wake.
        case waiting
        /// The source is exhausted and nothing is held: the caller stops requesting media.
        case ended
        /// `isCurrent` turned false: this arm is retired and its held buffers are dropped.
        case retired
    }

    private let lookahead: Double
    private let duration: (Buffer) -> Double
    private var held: [Buffer] = []
    private var heldHead = 0               // index of the oldest held buffer (amortised dequeue)
    public private(set) var heldSeconds: Double = 0
    private var exhausted = false

    public init(lookahead: Double = TapLookahead.seconds, duration: @escaping (Buffer) -> Double) {
        self.lookahead = lookahead
        self.duration = duration
    }

    public var heldCount: Int { held.count - heldHead }

    /// One renderer wake. Hand the renderer what it wants (held buffers first, then fresh
    /// decodes), then decode on until `lookahead` seconds are held. `ingest` tees a buffer into the
    /// tap and runs exactly once per buffer, at DECODE time; `enqueue` hands it to the renderer.
    public func service(isReady: () -> Bool,
                        isCurrent: () -> Bool,
                        next: () -> Buffer?,
                        ingest: (Buffer) -> Void,
                        enqueue: (Buffer) -> Void) -> Outcome {
        while isReady() {
            guard isCurrent() else { return retire() }
            if heldHead < held.count {
                let b = held[heldHead]
                heldHead += 1
                heldSeconds -= duration(b)
                if heldHead == held.count { held.removeAll(keepingCapacity: true); heldHead = 0; heldSeconds = 0 }
                enqueue(b)
                continue
            }
            guard !exhausted, let b = next() else { exhausted = true; return .ended }
            guard isCurrent() else { return retire() }
            ingest(b)
            enqueue(b)
        }
        while !exhausted && heldSeconds < lookahead {
            guard isCurrent() else { return retire() }
            guard let b = next() else { exhausted = true; break }
            guard isCurrent() else { return retire() }
            ingest(b)
            held.append(b)
            heldSeconds += duration(b)
        }
        return (exhausted && heldCount == 0) ? .ended : .waiting
    }

    private func retire() -> Outcome {
        held.removeAll()
        heldHead = 0
        heldSeconds = 0
        return .retired
    }
}
