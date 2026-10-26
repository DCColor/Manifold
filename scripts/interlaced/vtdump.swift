// Interlaced I3 (docs/INTERLACED_FINDINGS.md §12). Not in the app: the reference i3cmp builds from VideoToolbox's own x420
// delivery. Usage: swiftc -O vtdump.swift -o vtdump && ./vtdump <file> <out.raw>  (then i3cmp <out.raw> yuv420p10le …)
// Read-only: frame 0 of a file decoded by AVAssetReader at x420 (Manifold's request), written as yuv420p10le planes.
import AVFoundation
let url = URL(fileURLWithPath: CommandLine.arguments[1]), out = CommandLine.arguments[2]
let sem = DispatchSemaphore(value: 0)
Task {
    let asset = AVURLAsset(url: url)
    let track = try! await asset.loadTracks(withMediaType: .video).first!
    let r = try! AVAssetReader(asset: asset)
    let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
    r.add(o); r.startReading()
    let pb = CMSampleBufferGetImageBuffer(o.copyNextSampleBuffer()!)!
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    var y = [UInt16](), cb = [UInt16](), cr = [UInt16]()
    let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!, yr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    for row in 0..<h { for x in 0..<w { y.append(yb.load(fromByteOffset: row * yr + 2 * x, as: UInt16.self) >> 6) } }
    let cbase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!, crb = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
    for row in 0..<(h / 2) { for k in 0..<(w / 2) {
        cb.append(cbase.load(fromByteOffset: row * crb + 4 * k, as: UInt16.self) >> 6)
        cr.append(cbase.load(fromByteOffset: row * crb + 4 * k + 2, as: UInt16.self) >> 6)
    } }
    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    var data = Data(); for p in [y, cb, cr] { p.withUnsafeBufferPointer { data.append(Data(buffer: $0)) } }
    try! data.write(to: URL(fileURLWithPath: out))
    print("wrote \(w)x\(h) x420 → yuv420p10le, \(data.count) bytes")
    sem.signal()
}
sem.wait()
