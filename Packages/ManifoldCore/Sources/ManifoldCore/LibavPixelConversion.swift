import AVFoundation
import CFFmpeg

/// The libav→CoreVideo mapping, in ONE place because there are now two clients of it.
///
/// It used to be four `private static` helpers inside `LibavFrameSource`. `LibavScrubProducer`
/// needs exactly the same answers — that is the point of it existing at all, since the whole
/// argument for the scrub producer is that the scrub frame and the playback frame are the same
/// pixels through the same pipeline. Two copies of a colour table is how that stops being true
/// silently: a file with an unusual transfer would render one way while playing and another way
/// while scrubbing, and nothing would say so.
enum LibavPixelConversion {

    /// swscale destination format matching a CoreVideo format (P010 ↔ x420 10-bit, NV12 ↔ 420v).
    ///
    /// ⚠️ THIS IS WHAT REPLACES THE 8-BIT RGBA PATH, AND IT IS THE WHOLE HDR FIX FOR MXF.
    /// `LibavThumbnailSource` swscaled to `AV_PIX_FMT_RGBA` and wrapped the result in a `CGImage`:
    /// 8 bits per component, range already expanded, no transfer tag that survived. A PQ or HLG
    /// DNxHR file could not come out of that as anything but SDR — not because of a layer property
    /// but because the pixels had already been flattened. Going to P010 instead keeps the source's
    /// 10 bits and its stored range, and hands the transfer function on as an attachment for the
    /// shader and the layer to act on. That is the deliberately-deferred Part 3 of the HDR scrub
    /// entry, closed by deleting the 8-bit path rather than by giving it a float variant.
    static func swsDestFormat(for cvFormat: OSType) -> AVPixelFormat {
        switch cvFormat {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return AV_PIX_FMT_P010LE
        default:
            return AV_PIX_FMT_NV12
        }
    }

    static func cvMatrix(_ s: AVColorSpace) -> CFString {
        switch s {
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: return kCVImageBufferYCbCrMatrix_ITU_R_2020
        case AVCOL_SPC_SMPTE170M, AVCOL_SPC_BT470BG: return kCVImageBufferYCbCrMatrix_ITU_R_601_4
        default: return kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }
    }

    static func cvPrimaries(_ p: AVColorPrimaries) -> CFString? {
        switch p {
        case AVCOL_PRI_BT709: return kCVImageBufferColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_BT2020: return kCVImageBufferColorPrimaries_ITU_R_2020
        case AVCOL_PRI_SMPTE432: return kCVImageBufferColorPrimaries_P3_D65
        default: return nil
        }
    }

    static func cvTransfer(_ t: AVColorTransferCharacteristic) -> CFString? {
        switch t {
        case AVCOL_TRC_BT709: return kCVImageBufferTransferFunction_ITU_R_709_2
        case AVCOL_TRC_SMPTE2084: return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_ARIB_STD_B67: return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        default: return nil
        }
    }

    static func attach(_ pb: CVPixelBuffer, key: CFString, value: CFString?) {
        guard let value else { return }
        CVBufferSetAttachment(pb, key, value, .shouldPropagate)
    }

    /// A pixel-buffer pool for `width × height` in `cvFormat`, IOSurface-backed and Metal-capable.
    /// `minimumBufferCount` differs by client — playback pre-warms 20 for the frames it keeps in
    /// flight, a scrub producer needs a handful — so it is a parameter rather than a constant.
    static func makePool(width: Int, height: Int, cvFormat: OSType,
                         minimumBufferCount: Int) -> CVPixelBufferPool? {
        let pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: cvFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]() as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: minimumBufferCount
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary,
                                      pbAttrs as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
        return pool
    }

    /// swscale a decoded `AVFrame` straight into a pooled `CVPixelBuffer`'s planes — one pass,
    /// no intermediate copy — and carry the source's colour tags across as attachments.
    ///
    /// ⚠️ SRC AND DST RANGE ARE FORCED EQUAL, which looks like a no-op and is the load-bearing
    /// line. It tells swscale not to remap legal↔full, so the stored code values arrive unclipped
    /// and the SHADER does the expansion — the same contract the playback path has, and therefore
    /// the same picture. `LibavThumbnailSource` did the opposite (expanded to full on the way to
    /// RGBA) because a `CGImage` has no shader behind it; that is one of the two reasons its
    /// output could never match the played frame.
    static func fillPixelBuffer(_ pixelBuffer: CVPixelBuffer,
                                from frame: UnsafeMutablePointer<AVFrame>,
                                cvFormat: OSType) -> Bool {
        let W = Int(frame.pointee.width), H = Int(frame.pointee.height)
        let srcFmt = AVPixelFormat(frame.pointee.format)
        guard let sws = sws_getContext(Int32(W), Int32(H), srcFmt,
                                       Int32(W), Int32(H), swsDestFormat(for: cvFormat),
                                       Int32(SWS_BILINEAR.rawValue), nil, nil, nil) else { return false }
        defer { sws_freeContext(sws) }
        let coeff = sws_getCoefficients(SWS_CS_ITU709)
        let r: Int32 = (frame.pointee.color_range == AVCOL_RANGE_JPEG) ? 1 : 0
        _ = sws_setColorspaceDetails(sws, coeff, r, coeff, r, 0, 1 << 16, 1 << 16)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let srcData: [UnsafePointer<UInt8>?] = [
            UnsafePointer(frame.pointee.data.0), UnsafePointer(frame.pointee.data.1),
            UnsafePointer(frame.pointee.data.2), UnsafePointer(frame.pointee.data.3)
        ]
        var srcStride: [Int32] = [
            frame.pointee.linesize.0, frame.pointee.linesize.1,
            frame.pointee.linesize.2, frame.pointee.linesize.3
        ]
        var dst: [UnsafeMutablePointer<UInt8>?] = [
            CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
            CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self),
            nil, nil
        ]
        var dstStride: [Int32] = [
            Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)),
            Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)),
            0, 0
        ]
        let scaled = sws_scale(sws, srcData, &srcStride, 0, Int32(H), &dst, &dstStride)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        guard scaled > 0 else { return false }

        attach(pixelBuffer, key: kCVImageBufferYCbCrMatrixKey, value: cvMatrix(frame.pointee.colorspace))
        attach(pixelBuffer, key: kCVImageBufferColorPrimariesKey, value: cvPrimaries(frame.pointee.color_primaries))
        attach(pixelBuffer, key: kCVImageBufferTransferFunctionKey, value: cvTransfer(frame.pointee.color_trc))
        return true
    }
}
