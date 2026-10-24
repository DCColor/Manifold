import Foundation
import CoreMedia
import CFFmpeg
import FileScan

/// A file's scan and field order (docs/INTERLACED_FINDINGS.md §10, I1), read once per file by whichever
/// metadata producer builds its `VideoMetadata`: `MediaInspector.metadata` for AVFoundation files,
/// `FrameEngine.applyLibavMetadata` for MXF and routed `.mov`. Detection only: nothing else reads the answer yet.
///
/// The container comes from the format description's `fiel` (FieldCount / FieldDetail) or the MXF picture
/// descriptor, never from libav's `field_order`, whose `.mov` mapping is the §6 trap. The bitstream comes from
/// the first video packet libav's demuxer returns, read by this app's own header readers: the same bits the
/// decoder turns into its frame flags, read before any decode and identically on both paths.
enum FileScanProbe {

    /// `formatDescription`: the video track's, when AVFoundation has one. `mxf`: read the MXF header instead.
    static func resolve(url: URL, formatDescription fmt: CMFormatDescription?, mxf: Bool) -> SourceScan {
        let t0 = CFAbsoluteTimeGetCurrent()
        let container: ScanReading?
        if let fmt {
            container = ContainerScan.fiel(
                fieldCount: (CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_FieldCount)
                             as? NSNumber)?.intValue,
                fieldDetail: CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_FieldDetail)
                             as? String)
        } else if mxf {
            container = mxfHeader(url: url).flatMap { ContainerScan.mxf(header: $0) }
        } else {
            container = nil
        }
        let bitstream = firstPacket(url: url).flatMap {
            BitstreamScan.read(codec: $0.codec, configuration: $0.configuration, packet: $0.packet)
        }
        let scan = SourceScan.resolve(container: container, bitstream: bitstream)
        print(scan.logLine + String(format: " (probe %.1f ms)", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        return scan
    }

    /// The header partition through the end of its header metadata. SMPTE 377-1 counts `HeaderByteCount` from the
    /// primer pack: after the partition pack AND any KLV fill that pads it to the KAG (FFmpeg pads to 512).
    /// ⚠️ Not `MXFDeclaredRange.headerBytes`, which counts from the pack's value and so stops short by the pack and
    /// its fill: on FFmpeg-made MXF the picture descriptor is the last set in the header and is cut (docs/BUGS.md,
    /// the MXF header read entry). Bounded at 16 MB.
    private static func mxfHeader(url: URL) -> [UInt8]? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 64 * 1024), head.count >= 64 else { return nil }
        let h = [UInt8](head)
        // 06.0E.2B.34.02.05.01.01.0D.01.02.01.01: a partition pack (any kind; the header comes first).
        guard Array(h[0..<13]) == [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01]
        else { return nil }
        func klv(_ at: Int) -> (valueOffset: Int, length: Int)? {
            guard at + 17 <= h.count else { return nil }
            let first = h[at + 16]
            if first < 0x80 { return (at + 17, Int(first)) }
            let n = Int(first & 0x7F)
            guard n > 0, n <= 8, at + 17 + n <= h.count else { return nil }
            return (at + 17 + n, h[(at + 17)..<(at + 17 + n)].reduce(0) { ($0 << 8) | Int($1) })
        }
        guard let pack = klv(0), pack.valueOffset + 40 <= h.count else { return nil }
        let headerByteCount = h[(pack.valueOffset + 32)..<(pack.valueOffset + 40)].reduce(0) { ($0 << 8) | Int($1) }
        var start = pack.valueOffset + pack.length
        // KLV fill: 06.0E.2B.34.01.01.01.vv.03.01.02.10.01.00.00.00 (vv, the registry version, varies).
        if start + 16 <= h.count, Array(h[start..<(start + 7)]) == [0x06, 0x0E, 0x2B, 0x34, 0x01, 0x01, 0x01],
           Array(h[(start + 8)..<(start + 16)]) == [0x03, 0x01, 0x02, 0x10, 0x01, 0x00, 0x00, 0x00],
           let fill = klv(start) {
            start = fill.valueOffset + fill.length
        }
        guard headerByteCount > 0 else { return nil }
        let total = min(start + headerByteCount, 16 * 1024 * 1024)
        try? fh.seek(toOffset: 0)
        guard let data = try? fh.read(upToCount: total) else { return nil }
        return [UInt8](data)
    }

    /// The first video stream's codec, its extradata (`avcC` / `hvcC` in a `.mov`), and its first packet.
    /// Demuxer only: no `avformat_find_stream_info`, no decoder. Gives up after a bounded number of packets so
    /// a file whose video starts late cannot turn a probe into a scan.
    private static func firstPacket(url: URL) -> (codec: BitstreamScan.Codec, configuration: [UInt8], packet: [UInt8])? {
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&ctx, url.path, nil, nil) == 0, let fmt = ctx else { return nil }
        defer { avformat_close_input(&ctx) }

        var videoIndex = -1
        for i in 0..<Int(fmt.pointee.nb_streams) {
            guard let stream = fmt.pointee.streams[i] else { continue }
            if videoIndex < 0, stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO { videoIndex = i }
            else { stream.pointee.discard = AVDISCARD_ALL }
        }
        guard videoIndex >= 0, let par = fmt.pointee.streams[videoIndex]?.pointee.codecpar else { return nil }
        let codec: BitstreamScan.Codec
        switch par.pointee.codec_id {
        case AV_CODEC_ID_PRORES: codec = .prores
        case AV_CODEC_ID_DNXHD: codec = .dnx
        case AV_CODEC_ID_H264: codec = .h264
        case AV_CODEC_ID_HEVC: codec = .hevc
        default: return nil
        }
        let configuration = par.pointee.extradata.map {
            Array(UnsafeBufferPointer(start: $0, count: Int(par.pointee.extradata_size)))
        } ?? []

        guard let packet = av_packet_alloc() else { return nil }
        defer { var p: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&p) }
        for _ in 0..<64 {
            guard av_read_frame(fmt, packet) >= 0 else { return nil }
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == Int32(videoIndex),
                  let data = packet.pointee.data, packet.pointee.size > 0 else { continue }
            return (codec, configuration, Array(UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))))
        }
        return nil
    }
}
