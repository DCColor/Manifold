import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import CFFmpeg

/// Whether Apple's Avid DNxHR plug-in decoder is present in THIS process.
///
/// ⚠️ **PUSHED IN FROM THE APP LAYER, BECAUSE CORE CANNOT SEE IT.** `ProVideoWorkflow` lives in
/// `App/` (it owns the launch registration and the plug-in-directory probe) and ManifoldCore cannot
/// import the app. So the app sets this once, when its launch probe lands. It is `false` until then,
/// which is the safe direction: an MXF opened in that window takes the libav path it takes today.
public enum ProVideoDecoderAvailability {
    private static let lock = NSLock()
    private static var value = false
    /// Read from the decode pump; written once from the main actor.
    public static var isAvailable: Bool {
        lock.lock(); defer { lock.unlock() }; return value
    }
    public static func set(_ available: Bool) {
        lock.lock(); value = available; lock.unlock()
    }
}

/// Decodes ONE DNxHR profile — 4:4:4, libav `profile == 5`, compression ID 1270 — through Apple's
/// Avid plug-in decoder, from compressed packets libav demuxed.
///
/// ⚠️ **THE SCOPE IS ONE PROFILE AND WIDENING IT IS NOT A SMALL CHANGE.** 4:4:4 is the only profile
/// libav decodes *incorrectly* (`Unsupported: variable ACT flag.` → green and magenta). HQX and
/// everything else decode correctly on libav today and were measured agreeing with AVFoundation
/// bit-for-bit, so routing them here would move the primary format onto a path whose failure mode
/// **wedges teardown** (see `shutdown()`) in exchange for nothing.
///
/// ⚠️ **ROUTED ON THE PROFILE, NEVER ON libav's WARNING TEXT.** `Unsupported: variable ACT flag.` is
/// decoder log output, not an API — it has no stability guarantee and is not reachable as a value.
///
/// Full design record, including the measurements every constant here comes from:
/// `docs/BUGS.md` → *"the narrow MXF plan is VIABLE"*.
final class DNxHRVideoToolboxDecoder {

    /// libav's `FF_PROFILE_DNXHD_444`. Not exported to Swift by the shim, so it is named here.
    static let libavProfile444: Int32 = 5

    /// Is this the one profile libav decodes INCORRECTLY? A property of the FILE alone — it says
    /// nothing about whether we can do anything about it.
    ///
    /// ⚠️ **THIS IS THE SINGLE CONDITION BOTH HALVES HANG OFF, AND THAT IS WHAT MAKES THEM
    /// MUTUALLY EXCLUSIVE.** When it is true, either the plug-in decoder takes the file (piece 3)
    /// or the user is told the colour cannot be trusted (piece 4) — never both, never neither,
    /// because the two branches are `vtDecoder != nil` and `vtDecoder == nil` on one variable.
    static func isProfile444(codecID: AVCodecID, profile: Int32) -> Bool {
        codecID == AV_CODEC_ID_DNXHD && profile == libavProfile444
    }

    /// Whether this decoder should take the file. All three must hold.
    static func shouldRoute(codecID: AVCodecID, profile: Int32) -> Bool {
        isProfile444(codecID: codecID, profile: profile) && ProVideoDecoderAvailability.isAvailable
    }

    // MARK: - What the user is told when we CANNOT decode this correctly

    /// ⚠️ **THE HONEST HALF, AND IT HELPS MORE PEOPLE THAN THE ROUTING DOES.** The routing only
    /// works on machines that have Pro Video Formats. This fires on the ones that do not — where
    /// the file decodes through libav, comes back with the ACT failure, and renders green and
    /// magenta.
    ///
    /// ⚠️ **THE FAILURE MODE THIS PREVENTS IS A WRONG CONCLUSION, NOT A MISSING FEATURE.** On a QC
    /// tool, a picture that is silently wrong is worse than one that is absent: the reasonable
    /// reading of green-and-magenta is *this file is broken*, and someone may reject a delivery
    /// over it. Both strings therefore say the same three things — the picture is wrong, OUR
    /// decoder is why, and what is still trustworthy.
    ///
    /// ⚠️ **WORDED AS CAPABILITY, NEVER AS ERROR.** Nothing here is the user's doing and nothing is
    /// wrong with their file, so no string says "failed", "invalid" or "unsupported file".
    enum PictureCaveat {
        /// The inspector's standing row — true for as long as the file is open.
        static let short = "Colour unreliable — needs Pro Video Formats"
        /// The banner, shown once at load. Longer because it has to name the fix and, just as
        /// importantly, say what IS still good: a colourist may want the timecode, the audio or
        /// the captions from a file whose picture is unusable, and we do not refuse the file.
        static let banner = "This file is DNxHR 4:4:4, which Manifold’s built-in decoder renders "
            + "with the wrong colour. Apple’s Pro Video Formats package decodes it correctly — "
            + "install it and relaunch. Timecode, audio and captions are unaffected."
    }

    // MARK: - The synthesised format description

    /// ⚠️ **BOTH OF libav's GAPS ARE CODED AROUND HERE, AND BOTH ARE MEASURED.**
    ///
    /// 1. **`extradata` is 0 bytes** on every MXF fixture — there is no `ADHR` in the container to
    ///    lift. Apple's MXF reader *synthesises* the atom; so do we.
    /// 2. **`codec_tag` is `0x00000000`** — libav reports no fourCC for this stream, so `'AVdh'`
    ///    is supplied as a constant rather than passed through.
    ///
    /// The atom is 28 bytes: ASCII `"0002"` then six big-endian `UInt32`. For CID 1270 the values
    /// are `[1270, 2, 3, 0x00010000, 0, 2]`, established by bisection — **CID, f2, f3 and f6 each
    /// fail session-create when zeroed (−12907 / −12910), and f4 opens the session and then fails
    /// the DECODE with −12909.** f5 is 0 in every sample and could not be tested.
    ///
    /// ⚠️ **THIS ROW CAME FROM ONE 4:4:4 FIXTURE.** f2/f3/f4/f6 have no known semantics, so another
    /// 4:4:4 file could in principle need different values. That is exactly what the runtime
    /// fallback in `LibavFrameSource` is for: a wrong atom fails loudly at create or at decode, and
    /// the file goes back to libav — green, but playing.
    private static func makeFormatDescription(width: Int32, height: Int32)
        -> CMVideoFormatDescription? {
        var adhr = Data("0002".utf8)
        for field: UInt32 in [1270, 2, 3, 0x0001_0000, 0, 2] {
            withUnsafeBytes(of: field.bigEndian) { adhr.append(contentsOf: $0) }
        }
        let extensions: [CFString: Any] = [
            // ⚠️ ADHR ALONE. Measured necessary AND sufficient: ACLR, mtdt, FormatName, Depth,
            // CVFieldCount and the three colour keys are all decoration to this decoder, and a
            // dictionary carrying them WITHOUT ADHR fails create with −12902.
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms:
                ["ADHR": adhr] as CFDictionary
        ]
        var fd: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: 0x41566468,          // 'AVdh' — libav's codec_tag is 0, see above
            width: width, height: height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &fd)
        return status == noErr ? fd : nil
    }

    // MARK: - Lifecycle

    private var session: VTDecompressionSession?
    private let formatDescription: CMVideoFormatDescription
    /// Set by the output callback, read immediately after the synchronous wait.
    private var lastImage: CVPixelBuffer?
    private var lastStatus: OSStatus = noErr

    /// `nil` when no session could be opened — the caller must fall back to libav.
    init?(width: Int32, height: Int32) {
        guard let fd = Self.makeFormatDescription(width: width, height: height) else {
            print("[DNX-VT] could not build the format description — staying on libav")
            return nil
        }
        formatDescription = fd

        // The decode contract, unchanged: 10-bit 4:2:0 video range. Requested explicitly rather
        // than accepting the decoder's native `b64a`, so nothing downstream has to change.
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey:
                Int(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, image, _, _ in
                guard let refcon else { return }
                let me = Unmanaged<DNxHRVideoToolboxDecoder>
                    .fromOpaque(refcon).takeUnretainedValue()
                me.lastStatus = status
                me.lastImage = (status == noErr) ? image : nil
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())

        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fd,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &created)
        guard status == noErr, let created else {
            print("[DNX-VT] VTDecompressionSessionCreate = \(status) — staying on libav")
            return nil
        }
        session = created
        print("[DNX-VT] session opened for DNxHR 4:4:4 (CID 1270), requesting x420")
    }

    // MARK: - Decode

    /// Decode one compressed packet. Returns `nil` on ANY failure, which the caller treats as
    /// "fall back to libav" — this never throws and never retries.
    ///
    /// Synchronous by construction: `WaitForAsynchronousFrames` returns before we read the result,
    /// so there is never a frame in flight. That is also why seeking needs no session flush —
    /// DNxHR is all-intra and nothing is buffered.
    func decode(packet: UnsafeMutablePointer<AVPacket>, pts: CMTime, duration: CMTime)
        -> CVPixelBuffer? {
        guard let session, let data = packet.pointee.data, packet.pointee.size > 0 else { return nil }
        let size = Int(packet.pointee.size)

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: size, flags: 0,
                blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
              let blockBuffer,
              CMBlockBufferReplaceDataBytes(with: data, blockBuffer: blockBuffer,
                                            offsetIntoDestination: 0,
                                            dataLength: size) == kCMBlockBufferNoErr
        else { return nil }

        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sampleSize = size
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
                formatDescription: formatDescription, sampleCount: 1,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer
        else { return nil }

        lastImage = nil
        lastStatus = noErr
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: [], frameRefcon: nil, infoFlagsOut: nil)
        guard status == noErr else {
            print("[DNX-VT] DecodeFrame = \(status)")
            return nil
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard lastStatus == noErr, let image = lastImage else {
            // ⚠️ −17696 kVTVideoDecoderUnknownErr HERE MEANS THE DECODER PROCESS DIED, not "an
            // unknown soft error". It is what a format description the plug-in dislikes produces.
            // The caller falls back; `shutdown()`'s watchdog is what keeps the death from wedging
            // this thread when the session is later torn down.
            print("[DNX-VT] decode callback status = \(lastStatus)"
                + (lastStatus == -17696 ? "  (decoder process died)" : ""))
            return nil
        }
        lastImage = nil
        return image
    }

    // MARK: - Teardown

    /// ⚠️ **WATCHDOG, AND IT CANNOT UNWEDGE THE CALL — IT ONLY STOPS US WAITING ON IT.**
    ///
    /// When the plug-in has segfaulted its XPC service, `VTDecompressionSessionInvalidate` blocks
    /// in `xpc_connection_send_message_with_reply_sync` → `mach_msg` waiting for a reply from a
    /// process that is already dead. Measured at **seven minutes at 0 % CPU** before the probe that
    /// found it was killed; there is no evidence it would ever return, and there is no cancellation
    /// API for a blocked `mach_msg`.
    ///
    /// So Invalidate runs on a **detached thread** and this one waits a bounded 3 s. **When the
    /// watchdog fires it logs once and returns, abandoning the session** — the detached thread stays
    /// blocked for the life of the process and the session is never released. That is a deliberate
    /// leak of one thread and one session, taken because the alternative is stalling file close (and
    /// with it the deck, and any window teardown behind it) indefinitely.
    func shutdown() {
        guard let session else { return }
        self.session = nil
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            VTDecompressionSessionInvalidate(session)
            finished.signal()
        }
        if finished.wait(timeout: .now() + 3) == .timedOut {
            print("[DNX-VT] ⚠️ WATCHDOG: VTDecompressionSessionInvalidate did not return in 3 s — "
                + "the decoder process has almost certainly died. Abandoning the session (one "
                + "leaked session and one permanently blocked thread) rather than stalling close.")
        }
    }

    deinit { shutdown() }
}
