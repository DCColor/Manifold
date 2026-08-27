//
//  WHEPAudioDecoder.swift
//  Manifold
//
//  Opus → interleaved Int32 LPCM, for the WHEP receive path.
//
//  ── NO NEW DEPENDENCY, AND THAT WAS NOT THE EXPECTED ANSWER ────────────────────────────────
//
//  This was scoped as "vendor libopus" — build script, licence entry, THIRD_PARTY_NOTICES line,
//  and the provenance question that libdatachannel's build already has. None of that happened,
//  because macOS decodes Opus natively and always has for our deployment target:
//
//      kAudioFormatOpus is in kAudioFormatProperty_DecodeFormatIDs (51 formats listed)
//      AudioConverterNew(Opus → LPCM int32) succeeds
//
//  MEASURED against a reference, because "it decodes" is not "it decodes correctly" and a meter
//  that is 21 dB out is worse than no meter. 101 raw Opus packets (2.02 s of a 1 kHz tone,
//  libopus-encoded at 96 kbps, Ogg pages stripped so the input matched what RTP delivers):
//
//      source tone before encoding    peak −21.1 dBFS
//      FFmpeg's own decode            peak −21.0 dBFS
//      THIS PATH (AudioToolbox)       peak −21.0 dBFS, 96840 frames = 2.018 s
//
//  ⚠️ THAT DURATION DID NOT DESCRIBE THE CODE BELOW IT (found 2026-08-27, now fixed). Re-measured
//  on a fresh 102-packet fixture, this class as written decoded 840 frames — 0.018 s — because the
//  input callback signalled END OF STREAM on its first exhaustion and the converter never accepted
//  another packet. The LEVEL above was reproduced exactly (peak bit-identical to FFmpeg's decode of
//  the same packets), which is why the fault survived a measurement: everything that arrived was
//  correct, there was just almost none of it. With the fix the same fixture yields 97800 frames
//  (2.038 s). See the EOS note in the input callback — it is the whole bug.
//
//  Level-accurate to 0.1 dB against FFmpeg, and the right duration. The alternative of adding
//  `--enable-decoder=opus` to the vendored FFmpeg was also viable (its Opus decoder is NATIVE,
//  not a libopus wrapper — `ffmpeg -decoders` lists `opus` and `libopus` separately), but it
//  costs a full rebuild of the vendored dylibs for a decoder the OS already has.
//
//  ── WHY AudioConverter AND NOT AVAudioConverter ────────────────────────────────────────────
//
//  AVAudioConverter wants AVAudioCompressedBuffer, which wants packet descriptions we would have
//  to synthesise anyway, and it adds an Obj-C object per packet on a path that runs 50×/second.
//  The C API takes the RTP payload as-is with one stack-allocated packet description.
//

import Foundation
import AudioToolbox
import AVFoundation

/// Decodes one Opus packet at a time into interleaved Int32 LPCM at the source rate.
///
/// NOT thread-safe, and deliberately not made so: it is driven from exactly one place — the
/// serial audio queue in `WHEPAudioReceiver` — and an internal lock would only hide a caller that
/// had started violating that.
final class WHEPOpusDecoder {

    /// Opus is always 48 kHz on the wire in WebRTC (RFC 7587 §4.1: the RTP clock rate is 48000
    /// regardless of what the encoder used internally), so this is fixed rather than negotiated.
    static let sampleRate: Double = 48_000

    private var converter: AudioConverterRef?
    private(set) var channelCount: Int

    /// The packet currently being fed to the converter. `supply` reads these; they are only valid
    /// for the duration of one `decode` call.
    private var pendingPacket: UnsafePointer<UInt8>?
    private var pendingSize: Int = 0
    private var pendingConsumed = false
    /// ⚠️ MANUALLY ALLOCATED, NOT A STORED STRUCT OR A SWIFT ARRAY, AND BOTH FOR THE SAME REASON.
    /// `AudioConverterFillComplexBuffer` keeps the packet description pointer we hand it beyond the
    /// input callback's return, and callers keep the decoded buffer beyond `decode`'s return.
    /// Producing either with `withUnsafe…Pointer { $0 }` escapes a pointer out of the scope that
    /// guarantees it — undefined behaviour that happens to work until an allocation moves. Owning
    /// the memory outright makes both lifetimes real.
    private let packetDescription: UnsafeMutablePointer<AudioStreamPacketDescription>

    /// Output scratch, allocated once and reused. 120 ms at 48 kHz is the largest frame size the
    /// Opus codec defines, so one packet can never produce more than this many frames.
    /// STAGE 2 DIAGNOSTICS. The last status `AudioConverterFillComplexBuffer` returned and how many
    /// calls produced nothing — surfaced because a decoder that silently yields zero frames is
    /// indistinguishable from a stream that never arrived unless the status is reported.
    private(set) var lastStatus: OSStatus = noErr
    private(set) var decodeFailures = 0
    private(set) var decodeSuccesses = 0

    private let scratch: UnsafeMutablePointer<Int32>
    private let scratchCapacity: Int
    private static let maxFramesPerPacket = 5_760      // 120 ms @ 48 kHz

    /// Returned by the input callback to mean "no more input right now" — deliberately NOT
    /// `noErr`, which would mean end-of-stream and permanently retire the converter. See the long
    /// note at the call site. The value is arbitrary and never escapes this type.
    private static let noMoreInput: OSStatus = 1

    init?(channelCount: Int) {
        self.channelCount = max(1, min(channelCount, 2))
        self.scratchCapacity = Self.maxFramesPerPacket * self.channelCount
        self.scratch = UnsafeMutablePointer<Int32>.allocate(capacity: self.scratchCapacity)
        self.scratch.initialize(repeating: 0, count: self.scratchCapacity)
        self.packetDescription = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        self.packetDescription.initialize(to: AudioStreamPacketDescription())

        var input = AudioStreamBasicDescription()
        input.mFormatID = kAudioFormatOpus
        input.mSampleRate = Self.sampleRate
        input.mChannelsPerFrame = UInt32(self.channelCount)
        // 960 frames = 20 ms, the WebRTC default and what our `a=fmtp:111 minptime=10` invites.
        // This is the converter's HINT, not a constraint: a stream sending 10 ms or 40 ms packets
        // still decodes, because each packet carries its own frame count and the converter reports
        // what it actually produced. Verified across the 101-packet fixture above.
        input.mFramesPerPacket = 960

        var output = AudioStreamBasicDescription()
        output.mFormatID = kAudioFormatLinearPCM
        output.mSampleRate = Self.sampleRate
        output.mChannelsPerFrame = UInt32(self.channelCount)
        // Int32 interleaved — the format `AudioTapBuffer` stores and the card wants, so nothing
        // downstream converts again. Matches the file path's 32-bit reader settings exactly.
        output.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        output.mBitsPerChannel = 32
        output.mFramesPerPacket = 1
        output.mBytesPerFrame = UInt32(4 * self.channelCount)
        output.mBytesPerPacket = output.mBytesPerFrame

        var conv: AudioConverterRef?
        let status = AudioConverterNew(&input, &output, &conv)
        guard status == noErr, let conv else {
            NSLog("[WHEP-AUDIO] AudioConverterNew(Opus → LPCM) failed: %d", Int(status))
            return nil
        }
        converter = conv
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        scratch.deinitialize(count: scratchCapacity); scratch.deallocate()
        packetDescription.deinitialize(count: 1); packetDescription.deallocate()
    }

    /// Decode one Opus packet. Returns interleaved Int32 frames, or nil if the packet produced
    /// nothing (a decoder reset, or a packet the converter rejected).
    ///
    /// The returned buffer is the decoder's own scratch — VALID ONLY UNTIL THE NEXT CALL. The
    /// caller copies it into the tap and the renderer buffer immediately, so nothing is retained.
    func decode(_ packet: UnsafeRawBufferPointer) -> UnsafeBufferPointer<Int32>? {
        guard let converter, let base = packet.baseAddress, packet.count > 0 else { return nil }

        pendingPacket = base.assumingMemoryBound(to: UInt8.self)
        pendingSize = packet.count
        pendingConsumed = false
        defer { pendingPacket = nil; pendingSize = 0 }

        var frames = UInt32(Self.maxFramesPerPacket)
        var produced: UInt32 = 0
        let channels = channelCount

        var abl = AudioBufferList()
        abl.mNumberBuffers = 1
        abl.mBuffers.mNumberChannels = UInt32(channels)
        abl.mBuffers.mDataByteSize = UInt32(scratchCapacity * MemoryLayout<Int32>.size)
        abl.mBuffers.mData = UnsafeMutableRawPointer(scratch)
        let status = AudioConverterFillComplexBuffer(
                converter,
                { _, ioNumberDataPackets, ioData, outDataPacketDescription, userData in
                    let me = Unmanaged<WHEPOpusDecoder>
                        .fromOpaque(userData!).takeUnretainedValue()
                    // ONE packet per call, then report exhaustion. Returning the same packet twice
                    // would decode it twice; claiming more than we have makes the converter block
                    // waiting for input that never comes.
                    //
                    // ⚠️ THE EXHAUSTION STATUS MUST NOT BE `noErr`, AND THIS IS NOT A STYLE CHOICE.
                    // `ioNumberDataPackets = 0` WITH `noErr` is how an input proc signals END OF
                    // STREAM. AudioConverter takes it literally and permanently retires the
                    // converter: the call that sees it still returns its frames, and EVERY LATER
                    // `FillComplexBuffer` RETURNS ZERO FRAMES FOREVER. Since this decoder feeds one
                    // packet per call by design, that fires on the very first packet — so the
                    // stream would decode ~17 ms and then be silent for the rest of the session,
                    // with no error anywhere and a decoder that still looks healthy.
                    //
                    // MEASURED, both ways, on a 102-packet fixture (1 kHz tone, libopus @ 96 kbps,
                    // Ogg pages stripped so the input matches what RTP delivers):
                    //     returning noErr : 840 frames total   (0.018 s) — packet 1 only, then 0
                    //     returning this  : 97800 frames total (2.038 s) — 960 per packet
                    // Peak was bit-identical to FFmpeg's own decode of the same packets in both
                    // cases, which is exactly why this is so easy to miss: what little arrives is
                    // perfectly correct.
                    //
                    // A non-zero status means "no more input RIGHT NOW". FillComplexBuffer returns
                    // it to the caller, having produced what it could, and the converter stays
                    // usable for the next packet. `decode` below treats it as success whenever
                    // frames came back.
                    guard !me.pendingConsumed, let p = me.pendingPacket else {
                        ioNumberDataPackets.pointee = 0
                        // Named explicitly, not `Self`: a C function pointer cannot be formed
                        // from a closure that captures dynamic Self.
                        return WHEPOpusDecoder.noMoreInput
                    }
                    me.pendingConsumed = true
                    ioData.pointee.mNumberBuffers = 1
                    ioData.pointee.mBuffers.mNumberChannels = UInt32(me.channelCount)
                    ioData.pointee.mBuffers.mDataByteSize = UInt32(me.pendingSize)
                    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: p)
                    me.packetDescription.pointee.mStartOffset = 0
                    me.packetDescription.pointee.mVariableFramesInPacket = 0
                    me.packetDescription.pointee.mDataByteSize = UInt32(me.pendingSize)
                    outDataPacketDescription?.pointee = me.packetDescription
                    ioNumberDataPackets.pointee = 1
                    return noErr
                },
                Unmanaged.passUnretained(self).toOpaque(),
                &frames, &abl, nil)
        produced = frames

        // A short read is normal (the packet simply held fewer frames than the ceiling); only a
        // hard error with nothing produced is a failure. `noMoreInput` is OUR OWN sentinel and is
        // the expected status on every successful decode, so it must never be logged as a fault.
        lastStatus = status
        guard produced > 0 else {
            decodeFailures += 1
            if status != noErr && status != Self.noMoreInput {
                NSLog("[WHEP-AUDIO] decode failed: %d", Int(status))
            }
            return nil
        }
        decodeSuccesses += 1
        return UnsafeBufferPointer(start: scratch, count: Int(produced) * channels)
    }
}
