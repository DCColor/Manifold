// The app's scan readers (Packages/ManifoldCore/Sources/FileScan, SPSColor) fed by a DIFFERENT route from the
// app's, so a fixture is checked by the readers without trusting the app's plumbing (docs/INTERLACED_FINDINGS.md
// §10). Built and run by verify.sh.
//
//   scanprobe mov <file.mov>             fiel from CoreMedia; avcC / hvcC and the first sample from AVAssetReader
//   scanprobe mxf <file.mxf>             the header and the first picture essence element, by walking the KLV
//   scanprobe annexb <h264|hevc> <file>  an Annex B access unit (verify.sh extracts it from a .ts with ffmpeg)
//   scanprobe prores|dnx <file>          one raw frame
import AVFoundation
import VideoToolbox
import FileScan

func line(_ container: ScanReading?, _ bitstream: ScanReading?) {
    print(SourceScan.resolve(container: container, bitstream: bitstream).logLine)
}

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: see header"); exit(2) }
switch args[1] {
case "mov":
    VTRegisterProfessionalVideoWorkflowVideoDecoders()
    let asset = AVURLAsset(url: URL(fileURLWithPath: args[2]))
    let sem = DispatchSemaphore(value: 0)
    Task {
        defer { sem.signal() }
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let fmt = try? await track.load(.formatDescriptions).first else { print("no video track"); return }
        let container = ContainerScan.fiel(
            fieldCount: (CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_FieldCount) as? NSNumber)?.intValue,
            fieldDetail: CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_FieldDetail) as? String)
        var atoms: [String: [UInt8]] = [:]
        if let d = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any] {
            for (k, v) in d { if let v = v as? Data { atoms[k] = [UInt8](v) } }
        }
        let codec: BitstreamScan.Codec
        let configuration: [UInt8]
        switch CMFormatDescriptionGetMediaSubType(fmt) {
        case kCMVideoCodecType_H264: codec = .h264; configuration = atoms["avcC"] ?? []
        case kCMVideoCodecType_HEVC: codec = .hevc; configuration = atoms["hvcC"] ?? []
        case 0x41566468 /* AVdh */, 0x4156646E /* AVdn */: codec = .dnx; configuration = []
        default: codec = .prores; configuration = []
        }
        guard let reader = try? AVAssetReader(asset: asset) else { print("no reader"); return }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)   // passthrough: the coded sample
        reader.add(out)
        reader.startReading()
        // The first buffers out of a passthrough output can be markers with no data; take the first with bytes.
        var block: CMBlockBuffer? = nil
        for _ in 0..<8 {
            guard let sb = out.copyNextSampleBuffer() else { break }
            if let b = CMSampleBufferGetDataBuffer(sb), CMBlockBufferGetDataLength(b) > 0 { block = b; break }
        }
        guard let bb = block else {
            print("no sample (reader status \(reader.status.rawValue), \(reader.error.map { "\($0)" } ?? "no error"))"); return
        }
        var packet = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(bb))
        CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: packet.count, destination: &packet)
        line(container, BitstreamScan.read(codec: codec, configuration: configuration, packet: packet))
    }
    sem.wait()
case "mxf":
    let d = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: args[2]), options: .alwaysMapped))
    let header = Array(d.prefix(1 << 20))
    // The first picture essence element: key 06.0E.2B.34.01.02.01.01.0D.01.03.01.15.xx.xx.xx (GC picture item).
    let key: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x01, 0x02, 0x01, 0x01, 0x0D, 0x01, 0x03, 0x01, 0x15]
    var packet: [UInt8] = []
    var i = 0
    while i + 25 < d.count {
        if d[i] == 0x06, Array(d[i..<(i + 13)]) == key {
            let l0 = d[i + 16]
            var len = Int(l0), at = i + 17
            if l0 >= 0x80 { let n = Int(l0 & 0x7F); len = d[(i + 17)..<(i + 17 + n)].reduce(0) { ($0 << 8) | Int($1) }; at = i + 17 + n }
            packet = Array(d[at..<min(at + len, d.count)])
            break
        }
        i += 1
    }
    let codec: BitstreamScan.Codec = packet.starts(with: [0, 0, 2, 0x80]) ? .dnx : .prores
    line(ContainerScan.mxf(header: header), BitstreamScan.read(codec: codec, configuration: [], packet: packet))
case "annexb":
    let p = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: args[3])))
    line(nil, BitstreamScan.read(codec: args[2] == "hevc" ? .hevc : .h264, configuration: [], packet: p))
case "prores", "dnx":
    let p = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: args[2])))
    line(nil, BitstreamScan.read(codec: args[1] == "dnx" ? .dnx : .prores, configuration: [], packet: p))
default:
    print("unknown mode \(args[1])"); exit(2)
}
