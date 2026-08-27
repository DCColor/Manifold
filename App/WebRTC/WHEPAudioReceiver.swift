//
//  WHEPAudioReceiver.swift
//  Manifold
//
//  Opus packets off the wire → decoded PCM → the shared audio renderer, on the live clock.
//
//  ── STAGE 1: THE TWO SSRCs ARE ASSUMED ALIGNED ─────────────────────────────────────────────
//
//  Video and audio arrive on different SSRCs with independent, randomly-offset RTP timestamp
//  bases — video at 90 kHz, Opus at 48 kHz. The two are related properly only through RTCP Sender
//  Reports, each mapping its own SSRC's RTP clock to a common NTP wall-clock.
//
//  This stage does NOT do that. It assumes the two streams start aligned: the first Opus packet is
//  taken to be coincident with wherever the live clock has reached, and every later packet is
//  placed by its RTP timestamp DELTA from that first one. So relative timing WITHIN the audio
//  stream is exact (RTP-derived, sample-accurate); the audio-to-video OFFSET is an assumption.
//
//  That assumption is the thing being measured, not hidden: if burned-in timecode photographed
//  against OBS lands within a frame or two, the RTCP work is unnecessary and stage 2 does not
//  happen. `[WHEP-AUDIO] sync` logs the numbers the measurement needs.
//
//  ⚠️ IF THE MEASUREMENT IS BAD, THE ERROR SHOULD BE A CONSTANT, NOT A DRIFT. A fixed offset means
//  the alignment assumption is simply wrong and stage 2 (real SR-derived offset) fixes it. An error
//  that GROWS means something else — most likely LiveClock's rate slew against the synchronizer's
//  fixed 1.0 — and stage 2 as scoped would not fix that. The drift line below distinguishes them,
//  which is why it is logged rather than left to be inferred from two photographs.
//

import Foundation
import AVFoundation
import QuartzCore      // CACurrentMediaTime — the heartbeat's clock
import ManifoldCore

/// Owns the Opus decode + presentation timing for one WHEP session.
///
/// THREADING: `receive` is called on libdatachannel's network thread (see the warning on
/// `onAudioPacket` — that thread also serves video, so nothing here may block). Decode and enqueue
/// therefore hop to a private serial queue. Everything mutable lives on that queue.
final class WHEPAudioReceiver {

    /// Where decoded PCM goes — the engine's shared renderer + tap. Nil until `start`.
    private var sink: FrameEngine.LiveAudioSink?
    private var decoder: WHEPOpusDecoder?

    /// The live clock the video is presented against. Audio is placed on the SAME timeline.
    private let clock: () -> Double

    private let queue = DispatchQueue(label: "com.graviton.manifold.whep.audio",
                                      qos: .userInitiated)

    /// RTP timestamps are 32-bit and wrap (~24.8 hours at 48 kHz — long, but a stream left up over
    /// a weekend crosses it, and a wrap would throw presentation times a day into the past).
    ///
    /// ⚠️ NOT `RTPTimestampUnwrapper`. That type hardcodes 90 kHz as a property of the H.264 RTP
    /// profile (RFC 6184 §8.2.1) and returns a CMTime already divided by it — feeding 48 kHz audio
    /// through it would produce silently wrong seconds, off by 1.875×, which would look like a
    /// plausible sync error rather than an obvious bug. The unwrap arithmetic is five lines; the
    /// clock rate is the part that must not be borrowed.
    private var previousTimestamp: UInt32?
    private var unwrappedTicks: Int64 = 0

    private func unwrap(_ timestamp: UInt32) -> Int64 {
        if let previousTimestamp {
            // Signed 32-bit difference handles the wrap in both directions.
            unwrappedTicks += Int64(Int32(bitPattern: timestamp &- previousTimestamp))
        }
        previousTimestamp = timestamp
        return unwrappedTicks
    }

    /// Sender-timeline seconds of the FIRST packet, and the live-clock reading at that moment.
    /// Together these are the alignment assumption in one place.
    private var audioEpoch: Double?
    private var clockEpoch: Double?

    private var channelCount = 2
    private var established = false
    private var packets = 0
    private var framesDecoded = 0
    private var lastLogFrames = 0
    /// STAGE 1→3 COUNTS. `received` is incremented before the decoder is consulted, `enqueued`
    /// after the sink accepts — so the three numbers localise the break by themselves.
    private var received = 0
    private var enqueued = 0
    private var sampleBufferFailures = 0
    private var lastHeartbeat: CFTimeInterval = 0
    private var driftProbe: ((Double) -> Double?)?
    /// Packets discarded while the live clock was still unanchored. Reported, never silent.
    private var heldBeforeClock = 0

    init(clock: @escaping () -> Double) { self.clock = clock }

    /// Begin a session. `sink` and `driftProbe` come from the engine.
    func start(sink: FrameEngine.LiveAudioSink,
               channels: Int,
               driftProbe: @escaping (Double) -> Double?) {
        queue.async {
            self.sink = sink
            self.channelCount = max(1, min(channels, 2))
            self.decoder = WHEPOpusDecoder(channelCount: self.channelCount)
            self.driftProbe = driftProbe
            self.heldBeforeClock = 0
            self.audioEpoch = nil; self.clockEpoch = nil
            self.previousTimestamp = nil; self.unwrappedTicks = 0
            self.established = false
            self.packets = 0; self.framesDecoded = 0; self.lastLogFrames = 0
            self.received = 0; self.enqueued = 0; self.sampleBufferFailures = 0
            self.lastHeartbeat = CACurrentMediaTime()
            if self.decoder == nil {
                NSLog("[WHEP-AUDIO] no Opus decoder — audio disabled for this session")
            }
        }
    }

    /// ⚠️ SYNCHRONOUS ON PURPOSE. The caller (`WHEPFrameRouter.stopAudio`) calls `endLiveAudio`
    /// immediately after this returns, and that flushes the renderer and resets the tap. If this
    /// were `async`, a `handle` already on the queue could run AFTER the flush and push one stale
    /// buffer into a tap that the next session is about to start metering — a phantom level at the
    /// head of an unrelated stream. Waiting here closes that window entirely.
    ///
    /// Safe against deadlock: the audio queue never blocks on main. Its only main-actor touch is
    /// `Task { @MainActor … }`, which enqueues and returns. The wait is bounded by one packet's
    /// decode (~20 ms of audio, far less in wall time).
    func stop() {
        queue.sync {
            if self.packets > 0 {
                NSLog("[WHEP-AUDIO] session end — %d packet(s), %.2f s decoded",
                      self.packets, Double(self.framesDecoded) / WHEPOpusDecoder.sampleRate)
            }
            self.sink = nil; self.decoder = nil; self.driftProbe = nil
            self.audioEpoch = nil; self.clockEpoch = nil
        }
    }

    /// One Opus packet, straight off the network thread. Copies and gets off immediately.
    func receive(_ opus: Data, rtpTimestamp: UInt32) {
        queue.async { self.handle(opus, rtpTimestamp: rtpTimestamp) }
    }

    // MARK: - On the audio queue

    private func handle(_ opus: Data, rtpTimestamp: UInt32) {
        received += 1
        guard let sink, let decoder else {
            heartbeat(note: sink == nil ? "NO SINK" : "NO DECODER")
            return
        }

        // Sender timeline, in seconds, unwrapped past the 32-bit rollover.
        let senderSeconds = Double(unwrap(rtpTimestamp)) / WHEPOpusDecoder.sampleRate

        // THE ALIGNMENT ASSUMPTION, in two lines and nowhere else. Stage 2 replaces exactly this.
        //
        // ⚠️ THE EPOCH MUST NOT BE LATCHED FROM AN UNANCHORED CLOCK. `LiveClock.now()` returns
        // `-.infinity` until the first VIDEO frame calls `registerFrame` — a deliberate "never due"
        // sentinel, not a fault — and audio neither anchors that clock nor can. Latching it anyway
        // made `clockEpoch = -.infinity`, so EVERY buffer got `presentation = -.infinity + finite
        // = -.infinity` and the synchronizer could never schedule one. It was latched ONCE, so the
        // stream never recovered: 1892 packets decoded and enqueued, all unschedulable, silent.
        //
        // Audio packets typically beat the first decoded video frame, so this window is real and
        // routinely non-empty. Holding is correct rather than merely safe: video is not presenting
        // yet either, so there is nothing for this audio to be in sync WITH.
        if audioEpoch == nil {
            let reading = clock()
            guard reading.isFinite else {
                heldBeforeClock += 1
                heartbeat(note: "HOLDING — live clock unanchored (no video frame yet), "
                                + "\(heldBeforeClock) packet(s) dropped")
                return
            }
            audioEpoch = senderSeconds
            clockEpoch = reading
            // NOTHING IS ANCHORED HERE ANY MORE. The timebase is driven by `LiveClock`'s mapping
            // callback (`FrameEngine.mirrorLiveAudio`), which tracks every re-anchor, snap and rate
            // change rather than copying one reading. This latch is now ONLY the sender→video
            // timeline alignment — the stage-1 "SSRCs start aligned" assumption — and nothing else.
            NSLog("[WHEP-AUDIO] first packet — anchoring audio at live-clock %.3fs "
                + "(held %d packet(s) waiting for the clock; SSRCs ASSUMED aligned; stage 1)",
                  reading, heldBeforeClock)
        }
        guard let audioEpoch, let clockEpoch else { return }
        let presentation = clockEpoch + (senderSeconds - audioEpoch)

        // The heartbeat MUST fire on this path too: "every decode returned nothing" is the single
        // failure this instrumentation exists to name, and returning early without logging is how
        // it would stay invisible.
        guard let pcm = opus.withUnsafeBytes({ decoder.decode($0) }) else {
            heartbeat(note: "DECODE PRODUCED NOTHING")
            return
        }
        packets += 1

        // The channel count is the DECODER's, established on the first successful decode — the same
        // rule the file path uses, so the meters size their bars from what actually decoded rather
        // than from what the SDP offered.
        if !established {
            established = true
            let ch = channelCount
            Task { @MainActor in WHEPFrameRouter.shared.liveAudioEstablished?(ch) }
        }

        let frames = pcm.count / channelCount
        framesDecoded += frames
        guard frames > 0,
              let sb = Self.makeSampleBuffer(pcm, frames: frames, channels: channelCount,
                                             pts: presentation) else {
            sampleBufferFailures += 1
            heartbeat()
            return
        }
        // ⚠️ THE FIRST COMPUTED PTS IS LOGGED IMMEDIATELY, not after a second of audio. A bad
        // timebase is a CONSTANT, visible on buffer one — waiting for the 1 Hz heartbeat is how
        // 1892 buffers were enqueued at −inf before anyone saw the number.
        if enqueued == 0 {
            NSLog("[WHEP-AUDIO] first pts = %.3fs (clockEpoch=%.3fs, senderΔ=%.3fs) — %@",
                  presentation, clockEpoch, senderSeconds - audioEpoch,
                  presentation.isFinite ? "OK" : "NOT FINITE — this will never schedule")
        }
        // A non-finite pts cannot be scheduled and poisons the tap's anchor arithmetic, so it is
        // refused at the seam rather than enqueued and lost downstream.
        guard presentation.isFinite else {
            sampleBufferFailures += 1
            heartbeat(note: "NON-FINITE PTS — refusing to enqueue")
            return
        }
        sink.enqueue(sb)
        enqueued += 1

        lastLogFrames = framesDecoded
        heartbeat(presentation: presentation)
    }

    /// ⚠️ ONE SECOND OF WALL CLOCK, NOT ONE SECOND OF DECODED AUDIO. The previous cadence was
    /// `framesDecoded - lastLogFrames >= 48000`, which is a progress meter used as a heartbeat:
    /// it reports only while the thing it is meant to be diagnosing is already working. When decode
    /// stalls, `framesDecoded` stops advancing and the line goes silent — so the one failure this
    /// log exists to catch is the exact case it cannot report. Keyed to the host clock instead, it
    /// keeps talking through a total decode failure, which is when it is worth reading.
    private func heartbeat(presentation: Double? = nil, note: String? = nil) {
        let now = CACurrentMediaTime()
        guard now - lastHeartbeat >= 1.0 else { return }
        lastHeartbeat = now
        let drift = driftProbe?(clock())
        NSLog("[WHEP-AUDIO] chain — rx=%d decoded=%d failed=%d sbFail=%d enqueued=%d · "
            + "%.1f s audio · status=%d · pts=%@ · timebase−clock=%@%@",
              received, decoder?.decodeSuccesses ?? 0, decoder?.decodeFailures ?? 0,
              sampleBufferFailures, enqueued,
              Double(framesDecoded) / WHEPOpusDecoder.sampleRate,
              Int(decoder?.lastStatus ?? 0),
              presentation.map { String(format: "%.3fs", $0) } ?? "n/a",
              drift.map { String(format: "%+.1f ms", $0 * 1000) } ?? "n/a",
              note.map { " · \($0)" } ?? "")
    }

    /// Interleaved Int32 → a CMSampleBuffer the shared renderer accepts, stamped on the live
    /// timeline. Timescale 90 kHz to match the video clock's grid exactly; 48 kHz audio frames land
    /// on integer 90 kHz ticks only every 15 samples, so a coarser scale would quantise the offset
    /// being measured.
    private static func makeSampleBuffer(_ pcm: UnsafeBufferPointer<Int32>,
                                         frames: Int, channels: Int,
                                         pts: Double) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: WHEPOpusDecoder.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)

        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                             asbd: &asbd, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &format) == noErr,
              let format else { return nil }

        let byteCount = frames * channels * MemoryLayout<Int32>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: byteCount,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block,
              CMBlockBufferReplaceDataBytes(with: pcm.baseAddress!, blockBuffer: block,
                                            offsetIntoDestination: 0,
                                            dataLength: byteCount) == noErr else { return nil }

        var sb: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(WHEPOpusDecoder.sampleRate)),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 90_000),
            decodeTimeStamp: .invalid)
        // sampleSize is BYTES PER SAMPLE (one interleaved frame), not the frame count. Passing the
        // count here builds a buffer claiming frames×frames bytes and the renderer reads past the
        // block — a crash that only shows up once real audio flows.
        var sampleSize = channels * MemoryLayout<Int32>.size
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                        formatDescription: format, sampleCount: frames,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}
