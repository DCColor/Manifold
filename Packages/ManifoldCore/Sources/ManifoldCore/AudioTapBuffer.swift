import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

/// D4b-1: PCM audio TAP + PTS-keyed ring buffer.
///
/// Tees decoded audio at the two FrameEngine enqueue sites (AVFoundation reader + libav source),
/// normalizes BOTH producers to ONE card-ready format — **32-bit signed integer, interleaved,
/// source-native sample rate + channel count** — and holds a rolling ~2 s window keyed by source
/// PTS so D4b-2's DeckLink audio callback can later ask "give me N frames starting at source time T"
/// (T = synchronizer clock). NOTHING is sent to the card in this stage: this is capture + buffer +
/// format only.
///
/// Thread-safety: a single `NSLock` guards the ring + indices + format, matching the DeckLink
/// staging-buffer discipline. Writes come off the decode/enqueue thread(s); reads (D4b-2) come off
/// the card callback thread. `@unchecked Sendable` because all mutable state is lock-guarded (the
/// class is captured as a local in the enqueue closures, like the renderers, so it never crosses
/// the FrameEngine main-actor boundary).
public final class AudioTapBuffer: @unchecked Sendable {

    /// Which decode path produced a tapped buffer (for logging/validation only).
    public enum SourcePath: String { case avFoundation = "AVF", libav = "libav", ndi = "NDI" }

    /// The normalized capture format. `channelCount` is the SOURCE interleaved channel count (what the
    /// ring stores); `deckLinkChannelCount` is that count padded UP to the nearest SDK-legal value
    /// (2/8/16/32/64) that D4b-2 will schedule (padding with silent channels happens at schedule time,
    /// not in the ring).
    public struct Format: Equatable {
        public let sampleRate: Double
        public let channelCount: Int
        public let deckLinkChannelCount: Int
        public let path: SourcePath
    }

    /// Snapshot for the logging/validation hook + future preference UI.
    public struct Stats: Equatable {
        public var buffersIngested: Int
        public var framesHeld: Int      // frames currently retained (≤ capacity)
        public var lastPTS: Double      // source time of the newest sample held (s), NaN if none
        public var format: Format?
    }

    // MARK: - State (all guarded by `lock`)

    private let lock = NSLock()

    private var ring: [Int32] = []          // interleaved Int32, capacityFrames * channels
    private var capacityFrames = 0
    private var channels = 0
    private var sampleRate: Double = 0
    private var writeHead = 0               // next frame slot (mod capacityFrames)
    private var framesWritten = 0           // total frames written this session (monotonic)
    private var basePTS: Double = .nan      // source time (s) of session frame 0; NaN until first buffer
    private var currentFormat: Format?
    private var buffersIngested = 0
    private var lastLoggedFrames = 0

    /// Rolling window length. ~2 s gives the 50 Hz card callback (D4b-2) generous slack for
    /// host-clock vs card-clock drift.
    private let windowSeconds: Double = 2.0

    /// If an incoming buffer's PTS deviates from the expected running time by more than this, treat it
    /// as a discontinuity (a seek not routed through `reset()`, or a gap) and re-anchor rather than
    /// serve stale samples across the jump.
    private let discontinuityToleranceSeconds = 0.050

    /// D4b-2: fired when the capture format is first established, or changes (rate/channels) — i.e.
    /// exactly when the ring is (re)configured. NOT fired for a `reset()` (a seek keeps the format).
    ///
    /// This exists because the DeckLink audio stream is not like the system renderer: the card must be
    /// ENABLED with a fixed sample rate + channel count BEFORE scheduled playback starts, so "the file
    /// turned out to have 5.1 at 48k" is news the output has to act on — by re-establishing itself. The
    /// alternative (reading the format at output-start time) loses the race whenever output is enabled
    /// before a file is loaded, which is the common order.
    ///
    /// Called on the decode/enqueue thread, OUTSIDE the lock, so the handler may call back into the
    /// audio stack without deadlocking.
    public var onFormatChange: (@Sendable (Format) -> Void)?

    public init() {}

    // MARK: - Exposed format / presence

    /// True once PCM has actually started flowing (i.e. the file has a decodable audio track). A
    /// video-only file never sets a format, so this stays false.
    public var hasAudio: Bool { lock.lock(); defer { lock.unlock() }; return currentFormat != nil }

    /// The current normalized capture format, or nil before the first buffer / for a video-only file.
    public var format: Format? { lock.lock(); defer { lock.unlock() }; return currentFormat }

    /// A consistent snapshot of buffer state for the validation hook / future UI.
    public var stats: Stats {
        lock.lock(); defer { lock.unlock() }
        let last = basePTS.isNaN ? Double.nan : basePTS + Double(framesWritten) / max(sampleRate, 1)
        return Stats(buffersIngested: buffersIngested,
                     framesHeld: min(framesWritten, capacityFrames),
                     lastPTS: last, format: currentFormat)
    }

    /// SDK-legal channel-count mapping. DeckLink accepts ONLY 2/8/16/32/64 embedded audio channels,
    /// so pad UP to the nearest legal count: 1 (mono) → 2, 6 (5.1) → 8, etc.
    public static func deckLinkChannelCount(for channelCount: Int) -> Int {
        if channelCount <= 2 { return 2 }
        if channelCount <= 8 { return 8 }
        if channelCount <= 16 { return 16 }
        if channelCount <= 32 { return 32 }
        return 64
    }

    // MARK: - Reset (seek / scrub / stop discontinuity)

    /// Flush all buffered audio and forget the PTS anchor. Called from FrameEngine at every flush
    /// point (seek, libav re-read, stop) so a PTS jump never serves samples from before the seek. The
    /// format is retained (same file/track); the anchor re-establishes on the next ingested buffer.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        writeHead = 0
        framesWritten = 0
        lastLoggedFrames = 0
        basePTS = .nan
    }

    // MARK: - Ingest (decode/enqueue thread)

    /// Tee one decoded audio `CMSampleBuffer` just before it is enqueued to the renderer. Reads the
    /// ASBD generically (rate/channels/int-vs-float/bits — path-agnostic), converts the interleaved
    /// PCM to Int32, and appends to the ring keyed by PTS. Does NOT mutate `sampleBuffer` (the retained
    /// block buffer aliases the same data read-only), so the renderer path is unchanged. Cheap: one
    /// linear pass over the samples plus a copy into the ring.
    public func ingest(_ sampleBuffer: CMSampleBuffer, path: SourcePath) {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else { return }
        let asbd = asbdPtr.pointee
        let ch = Int(asbd.mChannelsPerFrame)
        let rate = asbd.mSampleRate
        guard ch > 0, rate > 0 else { return }
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bits = Int(asbd.mBitsPerChannel)
        let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        // Our two decode paths are always interleaved; a non-interleaved multi-channel layout would
        // need de-planarization we don't do here — skip defensively rather than mis-read.
        if nonInterleaved && ch > 1 { return }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard pts.isFinite else { return }

        // Pull the interleaved PCM block (retained block buffer stays alive for this scope).
        var abl = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == noErr, let data = abl.mBuffers.mData else { return }
        _ = blockBuffer   // keep alive until end of scope

        let sampleCount = frames * ch   // interleaved
        var scratch = [Int32](repeating: 0, count: sampleCount)

        if isFloat && bits == 32 {
            // float32 [-1,1] → int32: scale by 2^31, CLAMP to the int32 range (no wrap). A +1.0
            // sample maps to 2^31 which is one past Int32.max, so it clamps to Int32.max (1 LSB);
            // -1.0 maps exactly to Int32.min. Truncation toward zero for in-range values.
            let src = data.assumingMemoryBound(to: Float.self)
            for i in 0..<sampleCount {
                let v = Double(src[i]) * 2147483648.0
                scratch[i] = v >= 2147483647.0 ? Int32.max
                           : (v <= -2147483648.0 ? Int32.min : Int32(v))
            }
        } else if !isFloat && bits == 16 {
            // int16 → int32: lossless widen, sample in the high 16 bits (× 65536). Full-scale is
            // preserved so amplitude matches the float path (0 dBFS ≈ int32 full-scale).
            let src = data.assumingMemoryBound(to: Int16.self)
            for i in 0..<sampleCount { scratch[i] = Int32(src[i]) << 16 }
        } else if !isFloat && bits == 32 {
            // Already int32 interleaved — pass through unchanged.
            let src = data.assumingMemoryBound(to: Int32.self)
            for i in 0..<sampleCount { scratch[i] = src[i] }
        } else if !isFloat && bits == 24 {
            // Defensive (not produced by today's two paths; ready if the AVF reader is later raised to
            // 24-bit): packed 3-byte LE per sample, sign-extend 24→32, then × 256 into int32.
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            for i in 0..<sampleCount {
                let b0 = Int32(bytes[i * 3 + 0]); let b1 = Int32(bytes[i * 3 + 1]); let b2 = Int32(bytes[i * 3 + 2])
                var v = (b2 << 16) | (b1 << 8) | b0
                if (v & 0x0080_0000) != 0 { v |= Int32(bitPattern: 0xFF00_0000) }   // sign-extend
                scratch[i] = v << 8
            }
        } else {
            return   // unsupported sample type
        }

        // Hand the converted Int32 scratch to the shared ring-append — the SAME path the raw NDI
        // push funnels through, so the anchoring + windowing discipline has exactly one copy
        // regardless of which producer supplied the samples.
        scratch.withUnsafeBufferPointer { buf in
            append(buf, frames: frames, channels: ch, sampleRate: rate, pts: pts, path: path)
        }
    }

    /// Push raw interleaved Int32 PCM straight into the ring, keyed by source `pts` — the
    /// source-agnostic seam for a producer that already holds card-ready samples and never built a
    /// `CMSampleBuffer`. NDI is that producer: it converts its native float32-PLANAR frames to Int32
    /// interleaved and calls this. Identical ring, anchoring, windowing and `onFormatChange` contract
    /// as `ingest(_:path:)` — the two differ ONLY in how the Int32 samples are obtained. `samples`
    /// holds `frameCount * channelCount` interleaved Int32; nothing is retained past the call.
    ///
    /// Called off the producer's pull thread (the NDI display-tick pull), OUTSIDE any lock the caller
    /// holds, matching `ingest`'s threading contract.
    public func pushInterleavedInt32(_ samples: UnsafePointer<Int32>, frameCount: Int,
                                     channelCount ch: Int, sampleRate rate: Double,
                                     pts: Double, path: SourcePath) {
        guard frameCount > 0, ch > 0, rate > 0, pts.isFinite else { return }
        let buf = UnsafeBufferPointer(start: samples, count: frameCount * ch)
        append(buf, frames: frameCount, channels: ch, sampleRate: rate, pts: pts, path: path)
    }

    /// Shared ring-append (both `ingest` and `pushInterleavedInt32` funnel here): (re)configure the
    /// ring on a first/changed format, anchor or re-anchor the PTS clock, copy `frames` interleaved
    /// Int32 frames into the window, and fire `onFormatChange` after the lock is dropped. `src` holds
    /// `frames * channels` interleaved Int32.
    private func append(_ src: UnsafeBufferPointer<Int32>, frames: Int, channels ch: Int,
                        sampleRate rate: Double, pts: Double, path: SourcePath) {
        lock.lock()
        // (Re)configure on first buffer or a format change (rate/channels): size the ring to the window.
        var newFormat: Format?
        if currentFormat == nil || currentFormat?.sampleRate != rate || currentFormat?.channelCount != ch {
            channels = ch
            sampleRate = rate
            capacityFrames = max(1, Int((windowSeconds * rate).rounded()))
            ring = [Int32](repeating: 0, count: capacityFrames * ch)
            writeHead = 0; framesWritten = 0; basePTS = .nan
            let fmt = Format(sampleRate: rate, channelCount: ch,
                             deckLinkChannelCount: Self.deckLinkChannelCount(for: ch), path: path)
            currentFormat = fmt
            newFormat = fmt   // notified after the lock is dropped
        }
        // Anchor the session clock, or re-anchor on an unexpected PTS jump (seek/gap not routed
        // through reset()).
        if basePTS.isNaN {
            basePTS = pts
        } else {
            let expected = basePTS + Double(framesWritten) / sampleRate
            if abs(pts - expected) > discontinuityToleranceSeconds {
                writeHead = 0; framesWritten = 0; basePTS = pts
            }
        }
        let chan = channels
        let cap = capacityFrames
        ring.withUnsafeMutableBufferPointer { rp in
            for f in 0..<frames {
                let dstBase = ((writeHead + f) % cap) * chan
                let srcBase = f * chan
                for c in 0..<chan { rp[dstBase + c] = src[srcBase + c] }
            }
        }
        writeHead = (writeHead + frames) % cap
        framesWritten += frames
        buffersIngested += 1
        let framesNow = framesWritten
        let doLog = framesNow - lastLoggedFrames >= Int(sampleRate)   // ~ every 1 s of audio
        if doLog { lastLoggedFrames = framesNow }
        let logRate = Int(sampleRate); let logCh = chan; let held = min(framesNow, cap)
        lock.unlock()

        // Outside the lock: the handler re-establishes the DeckLink output (D4b-2), which must not
        // re-enter the ring while we hold it.
        if let newFormat {
            print("AudioTap[\(path.rawValue)]: format → \(Int(newFormat.sampleRate))Hz · "
                + "\(newFormat.channelCount)ch (→ \(newFormat.deckLinkChannelCount)ch on SDI)")
            onFormatChange?(newFormat)
        }

        if doLog {
            print("AudioTap[\(path.rawValue)]: int32 interleaved · \(logRate)Hz · \(logCh)ch · "
                + "pts=\(String(format: "%.3f", pts))s · held≈\(held)f · total=\(framesNow)f")
        }
    }

    // MARK: - Read (D4b-2: card callback thread) — designed here, wired in D4b-2

    /// Copy `frameCount` interleaved Int32 frames beginning at source time `startTime` (synchronizer
    /// seconds) into `dst` (capacity `frameCount * channelCount` Int32). Returns the number of frames
    /// actually available and copied from the requested start (0 if the requested time is outside the
    /// retained window — the caller pads silence / waits). Never blocks beyond the lock. This is the
    /// seam D4b-2 uses to feed ScheduleAudioSamples from the synchronizer clock.
    public func read(framesStartingAt startTime: Double, frameCount: Int,
                     into dst: UnsafeMutablePointer<Int32>) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard capacityFrames > 0, channels > 0, !basePTS.isNaN, framesWritten > 0, frameCount > 0 else { return 0 }
        let held = min(framesWritten, capacityFrames)
        let firstHeld = framesWritten - held    // absolute frame index of oldest retained frame
        let end = framesWritten                 // exclusive
        let startFrame = Int(((startTime - basePTS) * sampleRate).rounded())
        if startFrame < firstHeld || startFrame >= end { return 0 }
        var copied = 0
        for i in 0..<frameCount {
            let abs = startFrame + i
            if abs < firstHeld || abs >= end { break }
            let srcBase = (abs % capacityFrames) * channels
            let dstBase = i * channels
            for c in 0..<channels { dst[dstBase + c] = ring[srcBase + c] }
            copied += 1
        }
        return copied
    }
}
