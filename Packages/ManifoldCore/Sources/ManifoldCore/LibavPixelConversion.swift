import AVFoundation
import CFFmpeg
import ColorimetryModel   // ChromaSubsampling, SourceChroma (Stage 3b S2)
import FileChroma

/// The libav→CoreVideo mapping, in ONE place because there are now two clients of it.
///
/// It used to be four `private static` helpers inside `LibavFrameSource`. `LibavScrubProducer`
/// needs exactly the same answers — that is the point of it existing at all, since the whole
/// argument for the scrub producer is that the scrub frame and the playback frame are the same
/// pixels through the same pipeline. Two copies of a colour table is how that stops being true
/// silently: a file with an unusual transfer would render one way while playing and another way
/// while scrubbing, and nothing would say so.
enum LibavPixelConversion {

    /// swscale destination format matching a CoreVideo format: P010 ↔ `x420`, P210 ↔ `x422`, P410 ↔
    /// `x444` (each 10-bit, MSB-aligned, biplanar: the same layout on both sides).
    ///
    /// ⚠️ THIS IS WHAT REPLACES THE 8-BIT RGBA PATH, AND IT IS THE WHOLE HDR FIX FOR MXF.
    /// `LibavThumbnailSource` swscaled to `AV_PIX_FMT_RGBA` and wrapped the result in a `CGImage`:
    /// 8 bits per component, range already expanded, no transfer tag that survived. A PQ or HLG
    /// DNxHR file could not come out of that as anything but SDR — not because of a layer property
    /// but because the pixels had already been flattened. Going to P010 instead keeps the source's
    /// 10 bits and its stored range, and hands the transfer function on as an attachment for the
    /// shader and the layer to act on. That is the deliberately-deferred Part 3 of the HDR scrub
    /// entry, closed by deleting the 8-bit path rather than by giving it a float variant.
    ///
    /// ⚠️ NO DEFAULT BRANCH (Stage 3b S2). It used to fall through to NV12, so a 4:2:2 or 4:4:4 buffer
    /// handed to it would have been written as 8-bit 4:2:0 into a 10-bit buffer of another shape.
    /// A format this does not know is now a failed fill, said once, never a silent wrong picture.
    static func swsDestFormat(for cvFormat: OSType) -> AVPixelFormat? {
        switch ChromaSubsampling(pixelFormat: cvFormat) {
        case .c420?: return AV_PIX_FMT_P010LE
        case .c422?: return AV_PIX_FMT_P210LE
        case .c444?: return AV_PIX_FMT_P410LE
        case nil:    return nil
        }
    }

    /// The chroma a libav pixel format carries, read from its descriptor: THE function both libav
    /// clients' format comes from (via `FileChromaProbe`), so a file's frames and the buffer they
    /// fill are chosen from the same `pix_fmt` by the same rule.
    static func declaredChroma(pixFmt: AVPixelFormat) -> (source: SourceChroma, basis: String) {
        guard let desc = av_pix_fmt_desc_get(pixFmt) else { return (.unknown, "libav pix_fmt \(pixFmt.rawValue)") }
        let name = av_get_pix_fmt_name(pixFmt).map { String(cString: $0) } ?? "?"
        return FileChromaResolver.declared(
            pixFmtName: name,
            log2ChromaW: Int(desc.pointee.log2_chroma_w), log2ChromaH: Int(desc.pointee.log2_chroma_h),
            isRGB: desc.pointee.flags & UInt64(AV_PIX_FMT_FLAG_RGB) != 0,
            components: Int(desc.pointee.nb_components))
    }

    /// The colour the CONTAINER states for the video stream (its `codecpar`, read at open): the side that drives
    /// the picture (`ContainerColorPolicy`; decided 2026-10-12). Raw CICP codes, as libav's enums are.
    struct ContainerColor: Equatable, Sendable {
        let primaries: Int
        let transfer: Int
        let matrix: Int

        init(_ par: UnsafeMutablePointer<AVCodecParameters>) {
            primaries = Int(par.pointee.color_primaries.rawValue)
            transfer = Int(par.pointee.color_trc.rawValue)
            matrix = Int(par.pointee.color_space.rawValue)
        }

        /// What one frame's buffer is tagged with: per axis, the container's statement, else the frame's own.
        func resolved(frame: UnsafeMutablePointer<AVFrame>)
            -> (primaries: AVColorPrimaries, transfer: AVColorTransferCharacteristic, matrix: AVColorSpace) {
            let f = Self.decoder(frame)
            return (AVColorPrimaries(rawValue: UInt32(ContainerColorPolicy.resolve(container: primaries, decoder: f.primaries, .primaries))),
                    AVColorTransferCharacteristic(rawValue: UInt32(ContainerColorPolicy.resolve(container: transfer, decoder: f.transfer, .transfer))),
                    AVColorSpace(rawValue: UInt32(ContainerColorPolicy.resolve(container: matrix, decoder: f.matrix, .matrix))))
        }

        /// The frame's own statement, as the decoder made it.
        static func decoder(_ frame: UnsafeMutablePointer<AVFrame>) -> (primaries: Int, transfer: Int, matrix: Int) {
            (Int(frame.pointee.color_primaries.rawValue), Int(frame.pointee.color_trc.rawValue),
             Int(frame.pointee.colorspace.rawValue))
        }

        /// Where the decoder's frame states something different from the container (empty when they agree).
        func disagreements(frame: UnsafeMutablePointer<AVFrame>) -> [ColorAxisDisagreement] {
            ContainerColorPolicy.disagreements(container: (primaries, transfer, matrix), decoder: Self.decoder(frame))
        }

        var triple: String { "\(primaries)-\(transfer)-\(matrix)" }
    }

    /// Stamp the container's statements onto a buffer that did NOT come through `fillPixelBuffer` (the DNxHR 4:4:4
    /// VideoToolbox route), axis by axis; an axis the container does not state keeps whatever the decoder put there.
    static func stampContainerColor(_ pb: CVPixelBuffer, _ c: ContainerColor) {
        if ContainerColorPolicy.isStated(c.matrix, .matrix) {
            attach(pb, key: kCVImageBufferYCbCrMatrixKey, value: cvMatrix(AVColorSpace(rawValue: UInt32(c.matrix))))
        }
        if ContainerColorPolicy.isStated(c.primaries, .primaries) {
            attach(pb, key: kCVImageBufferColorPrimariesKey, value: cvPrimaries(AVColorPrimaries(rawValue: UInt32(c.primaries))))
        }
        if ContainerColorPolicy.isStated(c.transfer, .transfer) {
            attach(pb, key: kCVImageBufferTransferFunctionKey,
                   value: cvTransfer(AVColorTransferCharacteristic(rawValue: UInt32(c.transfer))))
        }
    }

    /// Tag a buffer the ProRes VideoToolbox route decoded exactly as `fillPixelBuffer` tags libav's frame of the same
    /// packet: per axis the container's statement, else the decoder's, and all three keys written. For ProRes the
    /// decoder's statement is the frame header's three codes (`ProResFrameHeader`), which is all libav's `prores`
    /// decoder reports. A key `fillPixelBuffer` would leave unset (a code CoreVideo has no name for) is removed, so
    /// nothing VideoToolbox attached on its own survives where libav's buffer would carry nothing.
    static func stampResolvedColor(_ pb: CVPixelBuffer, _ c: ContainerColor?,
                                   decoder d: (primaries: Int, transfer: Int, matrix: Int)) {
        let p = c.map { ContainerColorPolicy.resolve(container: $0.primaries, decoder: d.primaries, .primaries) } ?? d.primaries
        let t = c.map { ContainerColorPolicy.resolve(container: $0.transfer, decoder: d.transfer, .transfer) } ?? d.transfer
        let m = c.map { ContainerColorPolicy.resolve(container: $0.matrix, decoder: d.matrix, .matrix) } ?? d.matrix
        attach(pb, key: kCVImageBufferYCbCrMatrixKey, value: cvMatrix(AVColorSpace(rawValue: UInt32(m))))
        replace(pb, key: kCVImageBufferColorPrimariesKey, value: cvPrimaries(AVColorPrimaries(rawValue: UInt32(p))))
        replace(pb, key: kCVImageBufferTransferFunctionKey,
                value: cvTransfer(AVColorTransferCharacteristic(rawValue: UInt32(t))))
    }

    private static func replace(_ pb: CVPixelBuffer, key: CFString, value: CFString?) {
        if let value { CVBufferSetAttachment(pb, key, value, .shouldPropagate) } else { CVBufferRemoveAttachment(pb, key) }
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
    ///
    /// The colour tags are the CONTAINER's where it states them (`container`), else the frame's (2026-10-12). nil
    /// `container` keeps the frame's on every axis.
    static func fillPixelBuffer(_ pixelBuffer: CVPixelBuffer,
                                from frame: UnsafeMutablePointer<AVFrame>,
                                cvFormat: OSType,
                                container: ContainerColor?) -> Bool {
        let W = Int(frame.pointee.width), H = Int(frame.pointee.height)
        let srcFmt = AVPixelFormat(frame.pointee.format)
        guard let dstFmt = swsDestFormat(for: cvFormat) else {
            reportUnknownDestination(cvFormat)
            return false
        }
        // The frame's own chroma against the buffer's. Equal on every file the resolver read (it read
        // the same pix_fmt). Lower in the buffer only under the DEBUG force switch, or a stream whose
        // pix_fmt changed mid-file: a reduction sws makes, said once rather than per frame.
        noteChromaPair(frame: srcFmt, buffer: cvFormat)
        guard let sws = sws_getContext(Int32(W), Int32(H), srcFmt,
                                       Int32(W), Int32(H), dstFmt,
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

        // ⚠️ THE CONTAINER'S COLOUR, NOT THE DECODER'S, WHERE THE CONTAINER STATES IT. ffmpeg's DNxHR decoder stamps
        // every frame `bt709`; tagged from the frame, a DNx MXF whose descriptor says 601 or 2020 was decoded with the
        // 709 matrix while the scopes, SDI and readout used the descriptor's (COLOR_MANAGEMENT_FINDINGS.md §6.11).
        let tags = container?.resolved(frame: frame)
            ?? (primaries: frame.pointee.color_primaries, transfer: frame.pointee.color_trc, matrix: frame.pointee.colorspace)
        attach(pixelBuffer, key: kCVImageBufferYCbCrMatrixKey, value: cvMatrix(tags.matrix))
        attach(pixelBuffer, key: kCVImageBufferColorPrimariesKey, value: cvPrimaries(tags.primaries))
        attach(pixelBuffer, key: kCVImageBufferTransferFunctionKey, value: cvTransfer(tags.transfer))
        return true
    }

    // MARK: - Said once (any thread)

    private static let saidLock = NSLock()
    nonisolated(unsafe) private static var said = Set<String>()

    private static func sayOnce(_ key: String, _ line: @autoclosure () -> String) {
        saidLock.lock(); let first = said.insert(key).inserted; saidLock.unlock()
        if first { print(line()) }
    }

    private static func reportUnknownDestination(_ cvFormat: OSType) {
        sayOnce("dst-\(cvFormat)", "[CHROMA] ⚠️ libav conversion has no destination for "
            + "\(ChromaReadout.fourCC(cvFormat)) — frame not filled (no NV12 fallback)")
    }

    private static func noteChromaPair(frame pixFmt: AVPixelFormat, buffer cvFormat: OSType) {
        guard case .declared(let src) = declaredChroma(pixFmt: pixFmt).source,
              let dst = ChromaSubsampling(pixelFormat: cvFormat), src != dst else { return }
        let name = av_get_pix_fmt_name(pixFmt).map { String(cString: $0) } ?? "?"
        sayOnce("pair-\(pixFmt.rawValue)-\(cvFormat)",
                "[CHROMA] libav \(name) (\(src.label)) converted into \(ChromaReadout.fourCC(cvFormat)) "
                + "(\(dst.label)) by swscale")
    }
}
