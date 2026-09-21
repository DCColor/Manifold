//
//  SRTAudioDecoderLibav.swift
//  Manifold
//
//  AAC → Int32 interleaved LPCM, via libavcodec + libswresample. The sibling of
//  `SRTAudioDecoder`, which does the same job through AudioToolbox.
//
//  ── WHY THIS EXISTS: AUDIOTOOLBOX MIS-DECODES THE CLOUDFLARE FEED ──────────────────────────────
//
//  ESTABLISHED BY LISTENING, NOT INFERRED. The same Cloudflare SRT stream, the same bytes, the
//  same moment: ffmpeg's AAC decoder produces clean audio and AudioToolbox produces gravel. Two
//  things were ruled out first, and both are worth naming so nobody re-investigates them:
//
//    * FRAMING IS CORRECT. `[SRT-AUDIO-PROBE]` read the packets as received: 7-byte ADTS header,
//      `frame_length` matching the packet, `number_of_raw_data_blocks_in_frame` = 0, decoding to
//      1024 frames × 2 ch. The header was parsed right and the access unit handed over was right.
//    * TIMING IS CORRECT. `timebase−clock` holds within 4 ms for the session.
//
//  What is left is AudioConverter's decode of this particular bitstream. This file routes around
//  it. It does not diagnose it.
//
//  ── ⚠️ STEREO ONLY, AND THAT IS A DECISION RATHER THAN A LIMITATION OF THE APPROACH ────────────
//
//  `SRTFrameRouter` sends multichannel to `SRTAudioDecoder` instead. The reason is channel ORDER,
//  and it is a defect this codebase has already paid for once:
//
//      AudioToolbox's AAC decoder emits the AAC BITSTREAM order — for channel_configuration 6 that
//      is C L R Ls Rs LFE. libav's decoder emits LIBAV's native order — L R C LFE Ls Rs. They are
//      the same six channels in two different sequences, and attaching the wrong one puts dialogue
//      on Left and LFE on a surround, with six correctly-labelled meters and nothing looking
//      broken anywhere.
//
//  `SRTAudioDecoder`'s ask-then-verify sequence (request the layout, then READ IT BACK and label
//  from what came back) exists precisely because of that. Reproducing it here is real work, it is
//  not what a stereo bug needs, and doing it in a hurry is how the mislabelling arrives a second
//  time. Stereo needs none of it: one channel pair, both decoders agree on L R, and the layout is
//  a constant. The multichannel half is filed in `docs/BUGS.md`.
//
//  ⚠️ SO THE `<= 2` TEST AT THE CALL SITE IS LOAD-BEARING. Widening it without doing the
//  channel-order work re-introduces a defect that reads as correct in every log and every meter.
import AVFoundation
import CFFmpeg

final class SRTAudioDecoderLibav: SRTAudioDecoding {

    /// A ceiling on the interleaved output buffer, in FRAMES, across all AAC frames one packet
    /// yields. AAC-LC is 1024 per frame and SBR doubles it to 2048; an ADTS packet may carry up to
    /// four raw data blocks. 16384 is four times the worst legal case, so the guard below is a
    /// backstop rather than a limit anything should meet.
    private static let maxFramesPerPacket = 16384

    /// How many packets the probe describes at the head of a connection. Matches
    /// `SRTAudioDecoder.probePacketCount` so the two decoders' logs are read the same way.
    private static let probePacketCount = 5

    // ── The protocol surface ──────────────────────────────────────────────────────────────────
    //
    // ⚠️ THESE THREE ARE `private(set) var`, NOT `let`, AND THAT IS THE POINT OF THIS DECODER'S
    // CONTRACT. They are seeded from the mux at init and REPLACED by what the first decoded frame
    // actually reports. See `adoptFrameFormat`.
    private(set) var sampleRate: Double
    private(set) var channelCount: Int
    private(set) var channelLayoutData: Data?
    private(set) var channelRoles: [String] = []

    /// What the mux declared, kept for the disagreement report. Never used for decoding.
    private let declaredSampleRate: Double
    private let declaredChannelCount: Int

    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var swr: OpaquePointer?

    private let scratch: UnsafeMutablePointer<Int32>
    private let scratchCapacityFrames: Int
    /// The element count `scratch` was ALLOCATED with, kept separately from
    /// `scratchCapacityFrames * channelCount` because `channelCount` is mutable: a frame reporting
    /// fewer channels than the mux declared lowers it, and freeing against the lowered value would
    /// not match the allocation. The allocation is the thing `deinitialize` has to agree with.
    private let scratchElements: Int

    private var formatAdopted = false
    private var probePacketsLogged = 0
    private var loggedOverflow = false

    /// libav's own return codes, which Swift cannot spell as macros.
    private static let errEAGAIN: Int32 = -35        // AVERROR(EAGAIN) on Darwin
    private static let errEOF: Int32 = -541478725    // AVERROR_EOF

    /// `extradata` is the demuxer's AudioSpecificConfig when it has one. Unlike the AudioToolbox
    /// path there is no cookie, no ESDS wrapping and no ASC synthesis: libav takes the ASC as
    /// `AVCodecContext.extradata` if present, and reads everything it needs from the ADTS headers
    /// when it is not. `channelMask` / `channelOrder` are accepted for call-site symmetry with
    /// `SRTAudioDecoder` and are deliberately UNUSED — see the stereo-only note above; the moment
    /// they matter, this decoder is not the right one for that stream.
    init?(sampleRate: Double, channelCount: Int, extradata: [UInt8],
          channelMask: UInt64, channelOrder: Int32) {
        guard sampleRate > 0, channelCount > 0 else {
            NSLog("[SRT-AUDIO] libav: refusing to build a decoder with rate=%.0f channels=%d",
                  sampleRate, channelCount)
            return nil
        }
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.declaredSampleRate = sampleRate
        self.declaredChannelCount = channelCount
        self.scratchCapacityFrames = Self.maxFramesPerPacket
        self.scratchElements = Self.maxFramesPerPacket * channelCount
        self.scratch = .allocate(capacity: scratchElements)
        self.scratch.initialize(repeating: 0, count: scratchElements)

        guard let codec = avcodec_find_decoder(AV_CODEC_ID_AAC) else {
            // Not reachable on this build — `--verify-only` LAYER 3 enumerates `aac` from the
            // staged dylib — but asked rather than assumed, because that is the whole lesson of
            // ThirdParty/ffmpeg/README.md's `strings` false positive.
            NSLog("[SRT-AUDIO] libav: avcodec_find_decoder(AAC) returned NULL — the vendored "
                + "build has no AAC decoder. Nothing here can proceed.")
            cleanUp()
            return nil
        }
        guard let ctx = avcodec_alloc_context3(codec) else { cleanUp(); return nil }
        codecCtx = ctx
        ctx.pointee.sample_rate = Int32(sampleRate)
        av_channel_layout_default(&ctx.pointee.ch_layout, Int32(channelCount))

        // The ASC, when the demuxer supplied one. libav requires `AV_INPUT_BUFFER_PADDING_SIZE`
        // of zeroed slack past the end — its bitstream readers over-read by design.
        if !extradata.isEmpty {
            let padding = Int(AV_INPUT_BUFFER_PADDING_SIZE)
            guard let buf = av_mallocz(extradata.count + padding) else { cleanUp(); return nil }
            buf.copyMemory(from: extradata, byteCount: extradata.count)
            ctx.pointee.extradata = buf.assumingMemoryBound(to: UInt8.self)
            ctx.pointee.extradata_size = Int32(extradata.count)
        }

        guard avcodec_open2(ctx, codec, nil) == 0 else {
            NSLog("[SRT-AUDIO] libav: avcodec_open2 FAILED — no audio will reach the tap")
            cleanUp()
            return nil
        }
        guard let p = av_packet_alloc(), let f = av_frame_alloc() else { cleanUp(); return nil }
        packet = p
        frame = f

        // Stereo is the only shape this decoder accepts, so the layout is a constant rather than
        // something to derive — and being a constant is exactly why it is safe here and why
        // multichannel is not. L R, in that order, which is what both decoders produce for a pair.
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        channelLayoutData = withUnsafeBytes(of: &layout) { Data($0) }
        channelRoles = ["L", "R"]

        NSLog("[SRT-AUDIO] libav: AAC decoder open — mux declares %.0f Hz, %d ch. Rate and channel "
            + "count will be RE-READ from the first decoded frame (SBR changes the real rate and "
            + "only the frame reports it).", sampleRate, channelCount)
    }

    deinit { cleanUp() }

    /// ⚠️ IDEMPOTENT, AND IT HAS TO BE. A failable initializer that returns nil AFTER the stored
    /// properties are initialized still runs `deinit` — so every `cleanUp(); return nil` path in
    /// `init` is followed by a second `cleanUp()` from the deallocator. Without this latch that is
    /// a double `deallocate` of `scratch`, i.e. a heap corruption crash on the one path that only
    /// runs when something has already gone wrong.
    private var cleanedUp = false

    private func cleanUp() {
        guard !cleanedUp else { return }
        cleanedUp = true
        // Each of these takes a pointer to an OPTIONAL pointer and nils it — the frees cannot be
        // handed `&frame` directly, and the locals are what give them the right shape.
        if frame != nil {
            var f: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&f)
            frame = nil
        }
        if packet != nil {
            var p: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&p)
            packet = nil
        }
        if swr != nil {
            var s: OpaquePointer? = swr
            swr_free(&s)
            swr = nil
        }
        if codecCtx != nil {
            // `extradata` was allocated with av_mallocz; avcodec_free_context frees it.
            var c: UnsafeMutablePointer<AVCodecContext>? = codecCtx
            avcodec_free_context(&c)
            codecCtx = nil
        }
        scratch.deinitialize(count: scratchElements)
        scratch.deallocate()
    }

    // MARK: - Decode

    /// Decode one ADTS-framed AAC packet.
    ///
    /// ⚠️ THE RECEIVE IS A LOOP, NOT A SINGLE CALL, AND THAT IS NOT DEFENSIVENESS. One
    /// `avcodec_send_packet` can yield more than one frame — an ADTS frame may carry up to four
    /// raw data blocks — and `avcodec_receive_frame` hands them over one at a time. The
    /// AudioToolbox path decodes exactly one AAC frame per packet and silently drops the rest,
    /// which `[SRT-AUDIO-PROBE]`'s `adts.rdblocks` line flags for that reason. Here they are all
    /// drained and concatenated into one interleaved buffer, so the caller's single-buffer
    /// contract holds without losing audio.
    func decode(_ pkt: UnsafeRawBufferPointer) -> UnsafeBufferPointer<Int32>? {
        guard let codecCtx, let packet, let frame,
              let base = pkt.baseAddress, pkt.count > 0 else { return nil }

        #if DEBUG
        let probing = probePacketsLogged < Self.probePacketCount
        if probing {
            probePacketsLogged += 1
            let head = Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self),
                                                 count: min(16, pkt.count)))
            NSLog("[SRT-AUDIO-PROBE] pkt%d libav.recv    len=%d hex16=%@",
                  probePacketsLogged, pkt.count,
                  head.map { String(format: "%02X", $0) }.joined(separator: " "))
        }
        #endif

        // A packet with no `buf` is unowned by libav: `avcodec_send_packet` copies what it needs
        // and the caller's memory is not retained past the call. That is what lets this point
        // straight at the session thread's buffer with no copy of our own.
        av_packet_unref(packet)
        packet.pointee.data = UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: UInt8.self))
        packet.pointee.size = Int32(pkt.count)

        let sendRC = avcodec_send_packet(codecCtx, packet)
        if sendRC < 0 && sendRC != Self.errEAGAIN {
            #if DEBUG
            if probing { NSLog("[SRT-AUDIO-PROBE] pkt%d libav.outcome  send_packet failed (%d)",
                               probePacketsLogged, sendRC) }
            #endif
            return nil
        }

        var framesWritten = 0
        var blocks = 0
        while true {
            let rc = avcodec_receive_frame(codecCtx, frame)
            if rc == Self.errEAGAIN || rc == Self.errEOF { break }
            if rc < 0 {
                #if DEBUG
                if probing { NSLog("[SRT-AUDIO-PROBE] pkt%d libav.outcome  receive_frame failed (%d)",
                                   probePacketsLogged, rc) }
                #endif
                break
            }
            blocks += 1
            adoptFrameFormat(frame)
            framesWritten += convert(frame, writingAtFrameOffset: framesWritten)
            av_frame_unref(frame)
        }

        #if DEBUG
        if probing {
            NSLog("[SRT-AUDIO-PROBE] pkt%d libav.outcome  %d AAC frame(s) → %d sample frame(s) "
                + "× %d ch @ %.0f Hz", probePacketsLogged, blocks, framesWritten,
                  channelCount, sampleRate)
        }
        #endif

        guard framesWritten > 0 else { return nil }
        return UnsafeBufferPointer(start: scratch, count: framesWritten * channelCount)
    }

    /// ── WHAT THE FRAME SAYS WINS OVER WHAT THE MUX SAID ───────────────────────────────────────
    ///
    /// ⚠️ SBR IS THE REASON, AND IT IS NOT A CORNER CASE. For HE-AAC the access-unit headers
    /// describe the AAC-LC core at HALF the true output rate; the decoder reconstructs the top
    /// octave and emits at double. A decoder that trusted the mux would hand the tap 48 kHz
    /// samples labelled 24 kHz — every buffer the wrong duration, drifting steadily, with no
    /// counter anywhere reading wrong. The frame is the only thing that knows.
    ///
    /// Adopted ONCE, from the first frame, and any later disagreement is reported rather than
    /// silently followed: a mid-stream format change needs the scratch buffer resized and the
    /// resampler rebuilt, and pretending otherwise would write past the end of `scratch`.
    private func adoptFrameFormat(_ frame: UnsafeMutablePointer<AVFrame>) {
        let frameRate = Double(frame.pointee.sample_rate)
        let frameChannels = Int(frame.pointee.ch_layout.nb_channels)
        guard frameRate > 0, frameChannels > 0 else { return }

        if !formatAdopted {
            formatAdopted = true
            let rateDisagrees = frameRate != declaredSampleRate
            let chanDisagrees = frameChannels != declaredChannelCount
            sampleRate = frameRate
            // The scratch was allocated for the DECLARED channel count. A frame with more channels
            // than that would overrun it, so the count is adopted only when it cannot.
            if frameChannels <= declaredChannelCount { channelCount = frameChannels }
            NSLog("[SRT-AUDIO] libav: first frame reports %.0f Hz, %d ch — mux declared %.0f Hz, "
                + "%d ch.%@%@", frameRate, frameChannels, declaredSampleRate, declaredChannelCount,
                  rateDisagrees ? " ⚠️ RATE DISAGREES — the frame wins (SBR doubles the real rate "
                                + "and only the frame reports it)." : "",
                  chanDisagrees ? " ⚠️ CHANNEL COUNT DISAGREES — the frame wins unless it exceeds "
                                + "what the output buffer was sized for." : "")
            if rateDisagrees == false && chanDisagrees == false {
                NSLog("[SRT-AUDIO] libav: frame and mux agree.")
            }
            return
        }

        if frameRate != sampleRate || frameChannels != channelCount {
            NSLog("[SRT-AUDIO] ⚠️ libav: MID-STREAM FORMAT CHANGE — frame now reports %.0f Hz, "
                + "%d ch against %.0f Hz, %d ch in force. NOT adopted: the output buffer and the "
                + "resampler are sized for the original and changing them here would write past "
                + "the end of the scratch. Reconnect to pick up the new format.",
                  frameRate, frameChannels, sampleRate, channelCount)
        }
    }

    // MARK: - Planar float → interleaved Int32

    /// ── THE CONVERSION, AND WHY IT IS SWRESAMPLE AND NOT A LOOP ───────────────────────────────
    ///
    /// libav's AAC decoder emits `AV_SAMPLE_FMT_FLTP`: planar float, one buffer per channel,
    /// nominally in [-1, 1] but NOT clamped — AAC legitimately reconstructs beyond full scale.
    /// `AudioTapBuffer` stores Int32 interleaved. That is two conversions, planar→packed and
    /// float→fixed, and `swr_convert` does both in one pass with libav's own saturation and
    /// rounding. Writing the interleave by hand would mean reimplementing the clamp, and getting
    /// that wrong sounds exactly like the defect this decoder exists to fix.
    ///
    /// Same rate in and out, deliberately: this is a FORMAT conversion, not a resample. The rate
    /// the frame reports is the rate the tap is told about.
    ///
    /// Returns the number of sample frames written.
    private func convert(_ frame: UnsafeMutablePointer<AVFrame>,
                         writingAtFrameOffset offset: Int) -> Int {
        guard ensureSwr(frame) else { return 0 }
        let inSamples = Int(frame.pointee.nb_samples)
        guard inSamples > 0 else { return 0 }

        guard offset + inSamples <= scratchCapacityFrames else {
            if !loggedOverflow {
                loggedOverflow = true
                NSLog("[SRT-AUDIO] ⚠️ libav: one packet produced more than %d sample frames — the "
                    + "remainder of this packet is DROPPED. This is a backstop that nothing legal "
                    + "should reach (four raw data blocks of SBR is %d); if it fires, the packet "
                    + "shape is not what this decoder was built for.",
                      scratchCapacityFrames, 4 * 2048)
            }
            return 0
        }

        var inData: [UnsafePointer<UInt8>?] = [
            UnsafePointer(frame.pointee.data.0), UnsafePointer(frame.pointee.data.1),
            UnsafePointer(frame.pointee.data.2), UnsafePointer(frame.pointee.data.3),
            UnsafePointer(frame.pointee.data.4), UnsafePointer(frame.pointee.data.5),
            UnsafePointer(frame.pointee.data.6), UnsafePointer(frame.pointee.data.7)
        ]
        let writePoint = UnsafeMutableRawPointer(scratch + offset * channelCount)
        var outData: [UnsafeMutablePointer<UInt8>?] = [writePoint.assumingMemoryBound(to: UInt8.self)]

        let converted = inData.withUnsafeMutableBufferPointer { inPtr in
            outData.withUnsafeMutableBufferPointer { outPtr in
                swr_convert(swr, outPtr.baseAddress, Int32(inSamples),
                            inPtr.baseAddress, Int32(inSamples))
            }
        }
        return converted > 0 ? Int(converted) : 0
    }

    /// Build the resampler from the FIRST FRAME's actual format rather than from the codec
    /// context — the same reasoning `LibavAudioSource.ensureSwr` records: the context's idea of
    /// its own output is not settled until something has been decoded.
    private func ensureSwr(_ frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        if swr != nil { return true }
        var s: OpaquePointer?
        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, Int32(channelCount))
        let rc = swr_alloc_set_opts2(
            &s,
            &outLayout, AV_SAMPLE_FMT_S32, Int32(sampleRate),
            &frame.pointee.ch_layout, AVSampleFormat(frame.pointee.format),
            frame.pointee.sample_rate,
            0, nil)
        guard rc == 0, let s, swr_init(s) == 0 else {
            if s != nil { var t: OpaquePointer? = s; swr_free(&t) }
            NSLog("[SRT-AUDIO] ⚠️ libav: swr_alloc_set_opts2/swr_init FAILED — planar float cannot "
                + "be converted to interleaved Int32, so no audio will reach the tap.")
            return false
        }
        swr = s
        NSLog("[SRT-AUDIO] libav: swresample ready — %@ → S32 interleaved, %.0f Hz, %d ch",
              frame.pointee.format == AV_SAMPLE_FMT_FLTP.rawValue ? "FLTP" : "fmt \(frame.pointee.format)",
              sampleRate, channelCount)
        return true
    }
}
