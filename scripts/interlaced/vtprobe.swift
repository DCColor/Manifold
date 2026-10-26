// Interlaced I3 (docs/INTERLACED_FINDINGS.md §12). Not in the app. Usage: swiftc -O vtprobe.swift -o vtprobe && ./vtprobe <file>
// Read-only: decode frame 0 of a file with AVAssetReader at a requested pixel format; print chroma rows 0-7 at x=100 (Cb).
import AVFoundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let fmts: [(String, OSType)] = [("x420 (10-bit, as Manifold asks)", kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
                                ("420v (8-bit)", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)]
let asset = AVURLAsset(url: url)
let sem = DispatchSemaphore(value: 0)
Task {
    let track = try! await asset.loadTracks(withMediaType: .video).first!
    for (name, pf) in fmts {
        let r = try! AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pf])
        r.add(o); r.startReading()
        guard let sb = o.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { print(name, "no frame"); continue }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!, rb = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let ten = pf == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        var rows: [Int] = []
        for c in 0..<8 {
            let p = base + c * rb
            rows.append(ten ? Int(p.load(fromByteOffset: 50 * 4, as: UInt16.self) >> 6) : Int(p.load(fromByteOffset: 50 * 2, as: UInt8.self)))
        }
        print(name, "delivered", String(format: "%08x", CVPixelBufferGetPixelFormatType(pb)), "chroma rows 0-7 Cb:", rows)
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    }
    sem.signal()
}
sem.wait()
