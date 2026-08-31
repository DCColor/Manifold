//
//  SRTAudioDecoder.swift
//  Manifold
//
//  AAC → Int32 interleaved LPCM, via AudioToolbox. Stage 1 of the SRT audio arc.
//
//  ── WHY AUDIOTOOLBOX AND NOT THE VENDORED LIBAV ────────────────────────────────────────────────
//
//  Both can decode AAC — measured, not assumed. `./scripts/build_ffmpeg.sh --verify-only` LAYER 3
//  loads the staged dylibs and enumerates them:
//
//      DECODER exactly: aac aac_latm dnxhd pcm_f32le pcm_s16be pcm_s16le pcm_s24be pcm_s24le
//                       pcm_s32le prores
//
//  So `aac` and `aac_latm` are both present. AudioToolbox was chosen anyway, for four reasons:
//
//    1. FORMAT. libav's AAC decoder emits PLANAR FLOAT, and `AudioTapBuffer.ingest` refuses that
//       shape outright — "a non-interleaved multi-channel layout would need de-planarization we
//       don't do here — skip defensively rather than mis-read". So the libav route requires a
//       swresample stage that this route does not; AudioToolbox produces Int32 interleaved, which
//       is exactly what the tap stores and what the DeckLink card wants.
//    2. PRECEDENT. WHEPAudioDecoder is the same three calls in the same order. One audio decode
//       shape in the app, not two.
//    3. MP2 FOR FREE. The vendored build has NO mp2 decoder (see the enumeration above); this
//       machine's AudioToolbox does — probed, 51 decoders, `.mp2` among them. An MPEG-TS feed
//       carrying MP2 is not exotic.
//    4. SURFACE. The vendored FFmpeg stays demux-only, which is where its LGPL and size discipline
//       already is.
//
//  ── ⚠️ NOTHING HERE ASSUMES A CHANNEL COUNT, AT ANY LAYER ──────────────────────────────────────
//
//  Rate, channel count and frames-per-packet all come from the stream's AVCodecParameters. There
//  is no `2` in this file. MPEG-TS carries multichannel AAC routinely and the layout is declared
//  in the mux; a decoder shaped around stereo is a thing stage 3 would have to unpick rather than
//  extend, which is the whole reason this is written this way in stage 1.
import AudioToolbox
import AVFoundation
import ManifoldCore   // AudioChannelLayoutBridge

final class SRTAudioDecoder {

    /// AAC frames per packet. LC is 1024; SBR (HE-AAC / HE-AACv2) doubles it to 2048.
    /// A CEILING for the output buffer, not an assumption about what arrives — the converter
    /// reports what it actually produced and short reads are normal.
    private static let maxFramesPerPacket = 2048

    /// Our own "no more input right now" sentinel. MUST NOT be `noErr` — see the long note in
    /// `WHEPAudioDecoder`, where returning `noErr` with zero packets retired the converter
    /// permanently and cost a session's audio for a measured 18 ms of sound.
    private static let noMoreInput: OSStatus = -1

    let sampleRate: Double
    let channelCount: Int
    let formatID: AudioFormatID

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // MARK: - STAGE 3: the channel layout
    // ══════════════════════════════════════════════════════════════════════════════════════════
    //
    // ⚠️ THE MUX SAYS WHAT THE CHANNELS *ARE*. THE CONVERTER SAYS WHAT ORDER THEY COME OUT IN.
    // THOSE ARE DIFFERENT QUESTIONS AND CONFLATING THEM IS THE ONE BUG THIS WHOLE SECTION EXISTS
    // TO AVOID.
    //
    // libavformat hands us `AVChannelLayout.u.mask` for the AAC stream. For 5.1 that is
    // `AV_CH_LAYOUT_5POINT1_BACK` = L R C LFE Ls Rs — but that ORDER is *libav's* native order,
    // the order libav's OWN decoder would emit. We do not use libav's decoder. AudioToolbox's AAC
    // decoder, asked for nothing in particular, emits the AAC bitstream's order, which for
    // channel_configuration 6 is `kAudioChannelLayoutTag_AAC_5_1` — **C L R Ls Rs LFE**. Measured:
    // CoreAudio expands that tag to exactly that sequence.
    //
    // So attaching the mux's mask to the decoder's output as if it described the interleave would
    // put dialogue on Left, Left on Right, and LFE on the surround pair — six bars, all labelled,
    // all wrong, and nothing anywhere would look broken. That is precisely the "reads as a real
    // observation and is not" failure this arc keeps finding.
    //
    // THE SEQUENCE HERE IS THEREFORE: ASK, THEN VERIFY.
    //   1. Translate the mux's mask to CoreAudio positions (`AudioChannelLayoutBridge`) — refusing
    //      any position outside the eighteen WAVE ones rather than approximating it.
    //   2. REQUEST that order from the converter via `kAudioConverterOutputChannelLayout`. This is
    //      the only way to make the mux's declaration true of the interleave rather than merely
    //      true of the bitstream.
    //   3. READ THE PROPERTY BACK once the magic cookie is settled, and label with WHAT CAME BACK.
    //      The converter is the authority on its own output; the read-back is what makes step 2 a
    //      verified fact instead of a hope. If the read-back disagrees with the request, the
    //      READ-BACK wins and the log says so.
    //   4. Any failure at any step → NO LAYOUT AT ALL. Not a fallback order, not the mask used
    //      anyway. The meters then show channel numbers, which is the honest answer and the one
    //      this codebase already gives everywhere else that a declaration is missing.

    /// The layout to attach to the decoded `CMSampleBuffer`, in CoreAudio's DESCRIPTIONS spelling,
    /// or nil when nothing about the channels could be established. Resolved after the first
    /// successful decode (see `resolveOutputLayout`), so it may be nil for the first packet or two.
    private(set) var channelLayoutData: Data?

    /// Per-channel role names for `channelLayoutData`, or empty. Logging + the meters' fallback.
    private(set) var channelRoles: [String] = []

    /// What the mask asked for, for the read-back comparison. Empty when the mask was refused.
    private var requestedLabels: [AudioChannelLabel] = []
    private var requestStatus: OSStatus = noErr
    private var requestMade = false
    private var maskRefusal: AudioChannelLayoutBridge.MaskRefusal?
    private var layoutResolved = false

    private var converter: AudioConverterRef?
    private let scratch: UnsafeMutablePointer<Int32>
    private let scratchCapacity: Int
    private let packetDescription: UnsafeMutablePointer<AudioStreamPacketDescription>

    private var pendingPacket: UnsafePointer<UInt8>?
    private var pendingSize: Int = 0
    private var pendingConsumed = false

    /// `extradata` is the AudioSpecificConfig when the demuxer has one; may be empty on a TS whose
    /// ASC has not been seen, in which case a cookie is synthesised from the first ADTS header.
    /// `channelMask` / `channelOrder` are the mux's declaration, straight off `AVCodecParameters`
    /// (`AVChannelLayout.u.mask` and `AVChannelOrder`). A zero mask, or a non-NATIVE order, means
    /// the mux declared nothing usable — which is a supported state, not an error.
    init?(sampleRate: Double, channelCount: Int, formatID: AudioFormatID, extradata: [UInt8],
          channelMask: UInt64, channelOrder: Int32) {
        guard sampleRate > 0, channelCount > 0 else {
            NSLog("[SRT-AUDIO] refusing to build a decoder with rate=%.0f channels=%d",
                  sampleRate, channelCount)
            return nil
        }
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.formatID = formatID
        self.scratchCapacity = Self.maxFramesPerPacket * channelCount
        self.scratch = .allocate(capacity: scratchCapacity)
        self.scratch.initialize(repeating: 0, count: scratchCapacity)
        self.packetDescription = .allocate(capacity: 1)
        self.packetDescription.initialize(to: AudioStreamPacketDescription())

        var input = AudioStreamBasicDescription()
        input.mFormatID = formatID
        input.mSampleRate = sampleRate
        input.mChannelsPerFrame = UInt32(channelCount)
        // A HINT, not a constraint — each packet carries its own frame count and the converter
        // reports what it produced. LC's 1024 is the common case; HE-AAC sends 2048.
        input.mFramesPerPacket = 1024

        var output = AudioStreamBasicDescription()
        output.mFormatID = kAudioFormatLinearPCM
        output.mSampleRate = sampleRate
        output.mChannelsPerFrame = UInt32(channelCount)
        // Int32 interleaved — what `AudioTapBuffer` stores and the card wants, so nothing
        // downstream converts again. Identical to the WHEP decoder's output and to the file
        // path's 32-bit reader settings.
        output.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        output.mBitsPerChannel = 32
        output.mFramesPerPacket = 1
        output.mBytesPerFrame = UInt32(4 * channelCount)
        output.mBytesPerPacket = output.mBytesPerFrame

        var conv: AudioConverterRef?
        let status = AudioConverterNew(&input, &output, &conv)
        guard status == noErr, let conv else {
            NSLog("[SRT-AUDIO] AudioConverterNew(%@ → LPCM) failed: %d",
                  Self.fourCC(formatID), Int(status))
            scratch.deinitialize(count: scratchCapacity); scratch.deallocate()
            packetDescription.deinitialize(count: 1); packetDescription.deallocate()
            return nil
        }
        converter = conv

        // STEP 1 + 2: translate the mux's mask and REQUEST it as the converter's output order.
        // Done before the cookie so the converter knows the shape we want before it is told what it
        // is decoding; verified afterwards, in `resolveOutputLayout`, which is the half that counts.
        switch AudioChannelLayoutBridge.labels(fromFFmpegMask: channelMask,
                                               channelOrder: channelOrder,
                                               channelCount: channelCount) {
        case .success(let labels):
            requestedLabels = labels
            let asked = AudioChannelLayoutBridge.roleNames(for: labels).joined(separator: " ")
            if var blob = AudioChannelLayoutBridge.bitmapLayoutData(for: labels) {
                requestStatus = blob.withUnsafeMutableBytes { raw in
                    AudioConverterSetProperty(conv, kAudioConverterOutputChannelLayout,
                                              UInt32(raw.count), raw.baseAddress!)
                }
                requestMade = true
                NSLog("[SRT-AUDIO] layout: mux declares %@ — requested as the converter's output "
                    + "order: %@", asked,
                      requestStatus == noErr ? "ACCEPTED"
                                             : "REFUSED (\(requestStatus)) — the read-back decides")
            } else {
                // Unreachable from the bridge's own output (every label it produces has a bitmap
                // position), but stated rather than silently skipped: a caller-supplied label set
                // could land here, and a request that was never made must not read as one that was.
                maskRefusal = nil
                NSLog("[SRT-AUDIO] layout: %@ has no WAVE bitmap spelling — no request made.", asked)
            }
        case .failure(let why):
            maskRefusal = why
            NSLog("[SRT-AUDIO] layout: no layout requested — %@. The converter's own output layout "
                + "is read back regardless; if that says nothing either, the meters show channel "
                + "NUMBERS rather than an order inferred from the count.", why.reason)
        }

        if !extradata.isEmpty {
            // libavformat hands AAC extradata as a RAW AudioSpecificConfig, so it needs the same
            // ESDS wrapping the ADTS-derived one does — `setCookie` applies it to whatever it is
            // given. objectType is the ASC's leading 5 bits.
            let objectType = UInt16((extradata[0] >> 3) & 0x1F)
            if setCookie(extradata, origin: "demuxer extradata", objectType: objectType) {
                // Accepted out of band: do not let the first ADTS header overwrite it.
                haveCookie = true
            }
        }
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        scratch.deinitialize(count: scratchCapacity); scratch.deallocate()
        packetDescription.deinitialize(count: 1); packetDescription.deallocate()
    }

    /// Whether the decoder is running with a cookie AudioToolbox actually accepted.
    ///
    /// ⚠️ A REJECTION USED TO BE A LOG LINE AND NOTHING ELSE — `setCookie` returned Void and the
    /// caller set `haveCookie = true` regardless, so the decoder carried on with no
    /// AudioSpecificConfig at all and nothing downstream could tell.
    ///
    /// IT WAS HARMLESS ON THE STREAM THAT EXPOSED IT, AND THAT IS PRECISELY WHY IT IS DANGEROUS.
    /// AudioConverter inferred AAC-LC 48 kHz stereo from the raw access units unaided: 2339 packets
    /// × 1024 frames = 2,395,136 = every frame accounted for, `undecodable=0`. The cookie was not
    /// needed there.
    ///
    /// It IS needed wherever inference cannot work:
    ///   * **HE-AAC / SBR** — the ASC carries the SBR extension, and the true output sample rate is
    ///     DOUBLE what the AU headers imply. Without the cookie the converter decodes the AAC-LC
    ///     core at half rate and every downstream duration is wrong.
    ///   * **Non-standard channel configurations** — anything the AU headers do not spell out.
    ///
    /// On those, silently proceeding yields wrong-rate or wrong-channel audio while `undecodable=0`
    /// still reads perfectly clean. The state is therefore recorded, reported, and — where
    /// inference is NOT known-safe — refused.
    enum CookieState {
        case notAttempted
        case accepted(origin: String)
        /// Rejected. `inferenceSafe` is true only for plain AAC-LC, where the converter is known
        /// to reach the right answer without help.
        case rejected(status: OSStatus, origin: String, inferenceSafe: Bool)
    }
    private(set) var cookieState: CookieState = .notAttempted

    /// True when the decoder must refuse to produce audio: the cookie was rejected AND the format
    /// is one the converter cannot be trusted to infer.
    var isUnusable: Bool {
        if case .rejected(_, _, let safe) = cookieState { return !safe }
        return false
    }

    /// The magic cookie: AudioToolbox needs the AudioSpecificConfig to know what it is decoding.
    ///
    /// ⚠️ AUDIOCONVERTER WANTS AN **ESDS**, NOT A BARE AudioSpecificConfig, AND THAT DISTINCTION IS
    /// THE WHOLE BUG. The ASC we synthesise from the ADTS header is correct — AAC-LC / 48 kHz /
    /// stereo packs to 0x1190, the canonical value, and the field widths (objectType 5, sampling
    /// index 4, channel config 4) are right. Handing those two bytes to
    /// `kAudioConverterDecompressionMagicCookie` is nevertheless rejected with `'!dat'` (bad data),
    /// because for AAC that property expects the MPEG-4 elementary-stream descriptor an `esds` box
    /// carries, with the ASC nested inside as a DecoderSpecificInfo. MEASURED, both ways, on this
    /// exact ASC: bare 2 bytes → REJECTED `'!dat'`; the same bytes ESDS-wrapped → ACCEPTED.
    @discardableResult
    private func setCookie(_ asc: [UInt8], origin: String, objectType: UInt16) -> Bool {
        guard let converter, !asc.isEmpty else { return false }
        var bytes = Self.esds(wrapping: asc)
        let status = AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie,
                                               UInt32(bytes.count), &bytes)
        if status == noErr {
            cookieState = .accepted(origin: origin)
            NSLog("[SRT-AUDIO] magic cookie set from %@ — ASC %@ in a %d-byte ESDS",
                  origin, asc.map { String(format: "%02X", $0) }.joined(separator: " "), bytes.count)
            return true
        }
        // AAC-LC (objectType 2) is the one case the converter demonstrably infers unaided.
        let inferenceSafe = (objectType == 2)
        cookieState = .rejected(status: status, origin: origin, inferenceSafe: inferenceSafe)
        NSLog("[SRT-AUDIO] ⚠️ magic cookie from %@ REJECTED: %d — ASC %@, %d-byte ESDS. %@",
              origin, Int(status),
              asc.map { String(format: "%02X", $0) }.joined(separator: " "), bytes.count,
              inferenceSafe
                ? "objectType 2 (AAC-LC): the converter can infer this, decoding anyway — but the "
                  + "output is UNVERIFIED by any config we supplied."
                : "objectType \(objectType) is NOT inferable (HE-AAC/SBR halves the rate, "
                  + "non-standard channel configs mis-map). REFUSING to decode rather than emit "
                  + "audio that would be wrong while every counter read clean.")
        return false
    }

    /// Wrap an AudioSpecificConfig in the ESDS blob AudioToolbox expects for AAC.
    /// Descriptor tags per ISO/IEC 14496-1: 0x03 ES_Descriptor, 0x04 DecoderConfigDescriptor,
    /// 0x05 DecoderSpecificInfo, 0x06 SLConfigDescriptor. Single-byte lengths are sufficient — an
    /// ASC is 2–5 bytes, so nothing here approaches the 127-byte short-form limit.
    static func esds(wrapping asc: [UInt8]) -> [UInt8] {
        let dsi: [UInt8] = [0x05, UInt8(asc.count)] + asc
        let dcd: [UInt8] = [0x04, UInt8(13 + dsi.count),
                            0x40,                        // objectTypeIndication: MPEG-4 Audio
                            0x15,                        // streamType audio, upStream 0
                            0x00, 0x00, 0x00,            // bufferSizeDB
                            0x00, 0x00, 0x00, 0x00,      // maxBitrate
                            0x00, 0x00, 0x00, 0x00]      // avgBitrate
                         + dsi
        let sl: [UInt8]  = [0x06, 0x01, 0x02]
        return [0x03, UInt8(3 + dcd.count + sl.count), 0x00, 0x00, 0x00] + dcd + sl
    }

    private var haveCookie = false

    /// Decode one packet. Returns interleaved Int32 frames — the decoder's own scratch, VALID ONLY
    /// UNTIL THE NEXT CALL, so the caller copies immediately.
    ///
    /// ⚠️ ADTS IS STRIPPED HERE, AND THE COOKIE MAY BE SYNTHESISED FROM IT. AudioToolbox wants RAW
    /// AAC access units plus a cookie; libavformat's mpegts demuxer hands back ADTS-framed packets
    /// for stream type 0x0F. The 7-byte header (9 with CRC) carries profile, sampling-frequency
    /// index and channel configuration — the same three facts an AudioSpecificConfig carries — so
    /// when the demuxer supplied no extradata, the first ADTS header is a sufficient source for the
    /// cookie. The channel configuration is READ from the header, never assumed.
    func decode(_ packet: UnsafeRawBufferPointer) -> UnsafeBufferPointer<Int32>? {
        guard let converter, let base = packet.baseAddress, packet.count > 0 else { return nil }
        var ptr = base.assumingMemoryBound(to: UInt8.self)
        var size = packet.count

        if let adts = Self.parseADTS(ptr, size) {
            if !haveCookie {
                // ADTS `profile` is objectType − 1, so LC (objectType 2) arrives here as 1.
                setCookie(Self.audioSpecificConfig(from: adts), origin: "ADTS header",
                          objectType: UInt16(adts.profileMinusOne) + 1)
                haveCookie = true
            }
            // A rejection on a format the converter cannot infer is fatal to correctness, not to
            // the session: refuse here so the packet is counted undecodable and the failure is
            // visible in the counters instead of arriving as quietly wrong audio.
            if isUnusable { return nil }
            ptr += adts.headerBytes
            size -= adts.headerBytes
            guard size > 0 else { return nil }
        } else {
            haveCookie = true   // raw AAC: whatever cookie we have (or none) is what we use
        }

        pendingPacket = ptr
        pendingSize = size
        pendingConsumed = false
        defer { pendingPacket = nil; pendingSize = 0 }

        var frames = UInt32(Self.maxFramesPerPacket)
        var abl = AudioBufferList()
        abl.mNumberBuffers = 1
        abl.mBuffers.mNumberChannels = UInt32(channelCount)
        abl.mBuffers.mDataByteSize = UInt32(scratchCapacity * MemoryLayout<Int32>.size)
        abl.mBuffers.mData = UnsafeMutableRawPointer(scratch)

        let status = AudioConverterFillComplexBuffer(
            converter,
            { _, ioNumberDataPackets, ioData, outDataPacketDescription, userData in
                let me = Unmanaged<SRTAudioDecoder>.fromOpaque(userData!).takeUnretainedValue()
                guard !me.pendingConsumed, let p = me.pendingPacket else {
                    ioNumberDataPackets.pointee = 0
                    return SRTAudioDecoder.noMoreInput
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

        // A short read is normal. `noMoreInput` is our own sentinel and is the EXPECTED status on
        // every successful decode — it must never be reported as a fault.
        guard frames > 0 else {
            if status != noErr && status != Self.noMoreInput { lastStatus = status }
            return nil
        }
        // STEP 3, and deliberately HERE rather than in `init`: the magic cookie may only have been
        // set moments ago, from this very packet's ADTS header, and the converter's idea of its own
        // output layout is not settled until it knows what it is decoding.
        resolveOutputLayout()
        return UnsafeBufferPointer(start: scratch, count: Int(frames) * channelCount)
    }

    /// Read `kAudioConverterOutputChannelLayout` back and label from WHAT CAME BACK. Runs once.
    ///
    /// ⚠️ THE READ-BACK IS THE AUTHORITY, NOT THE REQUEST — INCLUDING WHEN NO REQUEST WAS MADE.
    /// A converter that reports a layout is telling us the order it interleaves in; that is a
    /// decoder's declaration, not a guess, and it is worth having even for a stream whose mux said
    /// nothing. What is NOT allowed is to label from the request alone: `AudioConverterSetProperty`
    /// returning `noErr` says the property was accepted, not that the decoder reordered, and the
    /// difference between those two is the whole 5.1 failure mode.
    private func resolveOutputLayout() {
        guard !layoutResolved, let converter else { return }
        layoutResolved = true

        var size: UInt32 = 0
        var writable: DarwinBoolean = false
        let infoStatus = AudioConverterGetPropertyInfo(converter, kAudioConverterOutputChannelLayout,
                                                       &size, &writable)
        guard infoStatus == noErr, size >= UInt32(AudioChannelLayoutBridge.headerSize) else {
            reportNoLayout("the converter reports no output channel layout "
                         + "(GetPropertyInfo \(infoStatus), \(size) bytes)")
            return
        }
        var bytes = [UInt8](repeating: 0, count: Int(size))
        var got = size
        let status = bytes.withUnsafeMutableBytes { raw in
            AudioConverterGetProperty(converter, kAudioConverterOutputChannelLayout, &got, raw.baseAddress!)
        }
        guard status == noErr,
              let labels = bytes.withUnsafeBytes({ raw in
                  AudioChannelLayoutBridge.labels(fromLayout: raw.baseAddress!, size: Int(got))
              }) else {
            reportNoLayout("the converter's output channel layout could not be read (\(status))")
            return
        }
        guard labels.count == channelCount else {
            // A layout that does not account for every channel cannot be positional. Refuse it
            // whole rather than label the channels it does cover and number the rest — a partly
            // labelled 5.1 bar row invites reading the labelled ones as authoritative.
            reportNoLayout("the converter reports \(labels.count) layout position(s) for "
                         + "\(channelCount) decoded channel(s)")
            return
        }
        // Set-aware, like every site holding a full ordered label set — see `roleNames(for:)`.
        // ⚠️ AND IT MUST MATCH THE `asked` STRING BELOW, which is why both were converted in one
        // change: naming one side of that comparison set-aware and the other set-blind would make
        // an identical layout compare unequal and log a spurious mux/decoder disagreement.
        let roles = AudioChannelLayoutBridge.roleNames(for: labels)
        guard AudioChannelLayoutBridge.isUsable(roles) else {
            reportNoLayout("the converter's layout names no position this app has a role for "
                         + "(\(roles.joined(separator: " ")))")
            return
        }

        channelLayoutData = AudioChannelLayoutBridge.descriptionsLayoutData(for: labels)
        channelRoles = roles

        let asked = AudioChannelLayoutBridge.roleNames(for: requestedLabels).joined(separator: " ")
        let gotRoles = roles.joined(separator: " ")
        if requestMade && requestStatus == noErr && asked != gotRoles {
            // Loud, because this is the case where the mux and the decoder disagree about the
            // interleave and the labels now follow the DECODER. Nothing downstream is wrong — the
            // labels describe the samples — but the mux's own words are not what is on the wire,
            // and that is worth a line rather than a silent divergence.
            NSLog("[SRT-AUDIO] ⚠️ layout: requested %@ and the converter reports %@ — the READ-BACK "
                + "wins. The bars are labelled with what the decoder actually interleaves.",
                  asked, gotRoles)
        } else if requestMade && requestStatus != noErr {
            NSLog("[SRT-AUDIO] layout: the request was refused; the converter's own output layout "
                + "is %@ and the bars are labelled from that.", gotRoles)
        } else if !requestMade {
            NSLog("[SRT-AUDIO] layout: the mux declared nothing usable, but the CONVERTER declares "
                + "%@ — a decoder's statement about its own interleave, not an inference from the "
                + "channel count. Labelling from it.", gotRoles)
        } else {
            NSLog("[SRT-AUDIO] ✅ layout CONFIRMED: %@ — requested from the mux's declaration and "
                + "read back from the converter, which is what makes it a fact about the samples "
                + "rather than about the header.", gotRoles)
        }
    }

    /// One place to say "no layout", so every route to numbers reads the same in the log and none
    /// of them can quietly leave a stale `channelLayoutData` behind.
    private func reportNoLayout(_ why: String) {
        channelLayoutData = nil
        channelRoles = []
        NSLog("[SRT-AUDIO] layout: NONE — %@%@. The meters will show channel NUMBERS. This is the "
            + "designed outcome, not a gap: a per-channel role inferred from a channel count is "
            + "indistinguishable from a declared one on screen, and this app does not print one.",
              why,
              // Both halves in one line: what the MUX said (or failed to say) and what the
              // CONVERTER said. Reading only one of them is how "no layout" turns into a mystery.
              maskRefusal.map { "; the mux side: \($0.reason)" } ?? "")
    }

    private(set) var lastStatus: OSStatus = noErr

    // MARK: - ADTS

    struct ADTS {
        let headerBytes: Int
        let profileMinusOne: UInt8    // ADTS `profile` field: AAC-LC == 1
        let samplingIndex: UInt8
        let channelConfig: UInt8
    }

    /// Recognise an ADTS header. Returns nil for raw AAC / LATM, which is the signal to leave the
    /// packet alone.
    static func parseADTS(_ p: UnsafePointer<UInt8>, _ size: Int) -> ADTS? {
        guard size >= 7, p[0] == 0xFF, (p[1] & 0xF0) == 0xF0 else { return nil }
        let protectionAbsent = (p[1] & 0x01) != 0
        return ADTS(headerBytes: protectionAbsent ? 7 : 9,
                    profileMinusOne: (p[2] >> 6) & 0x03,
                    samplingIndex: (p[2] >> 2) & 0x0F,
                    channelConfig: ((p[2] & 0x01) << 2) | ((p[3] >> 6) & 0x03))
    }

    /// The 2-byte AudioSpecificConfig the ADTS header implies:
    /// 5 bits object type, 4 bits sampling index, 4 bits channel configuration, 3 bits zero.
    /// ADTS `profile` is objectType − 1, so LC (objectType 2) appears as 1.
    static func audioSpecificConfig(from a: ADTS) -> [UInt8] {
        let objectType = UInt16(a.profileMinusOne) + 1
        let bits = (objectType << 11) | (UInt16(a.samplingIndex) << 7) | (UInt16(a.channelConfig) << 3)
        return [UInt8(bits >> 8), UInt8(bits & 0xFF)]
    }

    static func fourCC(_ v: AudioFormatID) -> String {
        let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                 UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: b, encoding: .ascii) ?? "?"
    }
}
