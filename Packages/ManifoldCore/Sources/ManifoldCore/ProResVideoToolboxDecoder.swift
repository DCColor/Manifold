import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import CFFmpeg
import ColorimetryModel   // ChromaReadout.fourCC

/// ProRes packets read by libav, decoded by VideoToolbox — the route a `.mov` takes when AVFoundation
/// cannot see its video track (docs/BUGS.md, *A video `stsd` longer than its entries hides the video
/// track*; `ContainerSlackRoute`).
///
/// ── ⚠️ ONLY FOR FILES THE CONTAINER ROUTE SENDS HERE ────────────────────────────────────────────
///
/// `LibavFrameSource` and `LibavScrubProducer` build one of these only when the engine passes
/// `proResVideoToolbox: true`, which it does only for a file routed by `ContainerSlackRoute`. ProRes
/// in MXF still decodes through libav's software decoder, exactly as before: moving it here is a
/// separate decision (docs/BUGS.md, *ProRes MXF decodes in software*).
///
/// ── WHY VIDEOTOOLBOX AND NOT libav's PRORES DECODER ───────────────────────────────────────────────
///
/// MEASURED on both ARRI clips (2026-10-16): libav packets through this session, requested as `x444`,
/// are BYTE-IDENTICAL to AVFoundation's decode of a stream-copy remux of the same file (27/27, 26/26),
/// at 0.7–0.8 ms a frame. libav's software decoder costs 30–41 ms of CPU a frame at 2K 4444 and goes
/// through swscale, so its pixels are not the ones the same file shows once remuxed. It stays open
/// behind this route as the fallback, as libav does behind the DNxHR route.
///
/// Same shape as `DNxHRVideoToolboxDecoder` — one packet in, one image out, synchronous — and
/// deliberately a separate type, so the DNxHR route is not touched.
final class ProResVideoToolboxDecoder {

    /// The ProRes sample-entry types VideoToolbox decodes. libav's `codec_tag` is the `.mov` sample
    /// entry's fourCC; RAW (`aprn`, `aprh`) is not ProRes to libav's `prores` decoder and is excluded.
    static let codecTypes: Set<FourCharCode> = [
        0x6170636F,  // 'apco'  422 Proxy
        0x61706373,  // 'apcs'  422 LT
        0x6170636E,  // 'apcn'  422
        0x61706368,  // 'apch'  422 HQ
        0x61703468,  // 'ap4h'  4444
        0x61703478,  // 'ap4x'  4444 XQ
    ]

    /// The sample entry's type from libav's `codec_tag`, which libav stores little-endian
    /// (`MKTAG('a','p','4','h')`). nil for anything that is not one of the six.
    static func codecType(_ par: UnsafeMutablePointer<AVCodecParameters>) -> FourCharCode? {
        guard par.pointee.codec_id == AV_CODEC_ID_PRORES else { return nil }
        let t = FourCharCode(par.pointee.codec_tag).byteSwapped
        return codecTypes.contains(t) ? t : nil
    }

    private var session: VTDecompressionSession?
    private let formatDescription: CMVideoFormatDescription
    private var lastImage: CVPixelBuffer?
    private var lastStatus: OSStatus = noErr
    let pixelFormat: OSType

    /// nil when there is no description or no session — the caller stays on libav.
    ///
    /// The description is built from libav's codec parameters, because AVFoundation (which would
    /// normally supply it) is exactly what cannot read this file's sample description. It carries the
    /// codec type, the coded size and the field count; the container's colour goes on each buffer
    /// afterwards (`LibavPixelConversion.stampContainerColor`), as on every libav route.
    init?(_ par: UnsafeMutablePointer<AVCodecParameters>, pixelFormat: OSType) {
        self.pixelFormat = pixelFormat
        guard let type = Self.codecType(par) else { return nil }
        let interlaced: Bool = {
            switch par.pointee.field_order {
            case AV_FIELD_TT, AV_FIELD_BB, AV_FIELD_TB, AV_FIELD_BT: return true
            default: return false
            }
        }()
        var ext: [CFString: Any] = [kCMFormatDescriptionExtension_FieldCount: interlaced ? 2 : 1]
        if interlaced {
            let topFirst = par.pointee.field_order == AV_FIELD_TT || par.pointee.field_order == AV_FIELD_TB
            ext[kCMFormatDescriptionExtension_FieldDetail] = topFirst
                ? kCMFormatDescriptionFieldDetail_SpatialFirstLineEarly
                : kCMFormatDescriptionFieldDetail_SpatialFirstLineLate
        }
        var fd: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: type,
                                             width: par.pointee.width, height: par.pointee.height,
                                             extensions: ext as CFDictionary,
                                             formatDescriptionOut: &fd) == noErr, let fd else {
            print("[PRORES-VT] could not build the format description — staying on libav")
            return nil
        }
        formatDescription = fd

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(pixelFormat),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, image, _, _ in
                guard let refcon else { return }
                let me = Unmanaged<ProResVideoToolboxDecoder>.fromOpaque(refcon).takeUnretainedValue()
                me.lastStatus = status
                me.lastImage = (status == noErr) ? image : nil
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fd,
                                                  decoderSpecification: nil,
                                                  imageBufferAttributes: attrs as CFDictionary,
                                                  outputCallback: &callback,
                                                  decompressionSessionOut: &created)
        guard status == noErr, let created else {
            print("[PRORES-VT] VTDecompressionSessionCreate = \(status) — staying on libav")
            return nil
        }
        session = created
        print("[PRORES-VT] session opened for \(ChromaReadout.fourCC(type)) "
            + "\(par.pointee.width)×\(par.pointee.height), requesting \(ChromaReadout.fourCC(pixelFormat))")
    }

    /// One packet, one image; nil means "fall back to libav".
    func decode(packet: UnsafeMutablePointer<AVPacket>, pts: CMTime, duration: CMTime) -> CVPixelBuffer? {
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
                                            offsetIntoDestination: 0, dataLength: size) == kCMBlockBufferNoErr
        else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
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
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [],
                                                       frameRefcon: nil, infoFlagsOut: nil)
        guard status == noErr else {
            print("[PRORES-VT] DecodeFrame = \(status)")
            return nil
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard lastStatus == noErr, let image = lastImage else {
            print("[PRORES-VT] decode callback status = \(lastStatus)")
            return nil
        }
        lastImage = nil
        return image
    }

    /// Invalidate on a detached thread with a bounded wait, for the reason `DNxHRVideoToolboxDecoder.shutdown()`
    /// gives: an Invalidate against a dead decoder process blocks indefinitely, and closing a file must not.
    func shutdown() {
        guard let session else { return }
        self.session = nil
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            VTDecompressionSessionInvalidate(session)
            finished.signal()
        }
        if finished.wait(timeout: .now() + 3) == .timedOut {
            print("[PRORES-VT] ⚠️ WATCHDOG: VTDecompressionSessionInvalidate did not return in 3 s — "
                + "abandoning the session rather than stalling close.")
        }
    }

    deinit { shutdown() }
}
