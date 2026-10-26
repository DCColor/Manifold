// 8-bit H.264 chroma (docs/BUGS.md, *8-bit H.264 files lose vertical chroma detail in the decode*). Not in the app.
// Usage: swiftc -O vtplanes.swift -o vtplanes && ./vtplanes <file> <ffmpeg-frame0.yuv420p.raw>
// Read-only. Frame 0 of an 8-bit 4:2:0 file through the three routes Manifold decodes with, each at x420 (10-bit, what
// every route asks for today) and 420v (8-bit):
//   reader  AVAssetReaderTrackOutput, FileFrameSource's settings (playback)
//   scrub   AVPlayerItemVideoOutput, AVPlayerScrubProducer's attributes (scrub)
//   vt      VTDecompressionSession, LiveVideoDecoder's attributes (the SRT / WHEP decoder), fed the file's samples
// Each plane is compared with FFmpeg's decode widened ×4 (BT.709's 10-bit rule). x420 is shown raw (the top ten bits) and
// as the shader takes a flagged 8-bit buffer (low two bits cleared); 420v ×4.
import AVFoundation
import VideoToolbox

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let ref = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
let x420 = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, v420 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

struct Planes { var w = 0, h = 0, y: [Int] = [], cb: [Int] = [], cr: [Int] = [] }

func planes(_ pb: CVPixelBuffer, clear: Bool) -> Planes {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let ten = CVPixelBufferGetPixelFormatType(pb) == x420
    var p = Planes(); p.w = CVPixelBufferGetWidth(pb); p.h = CVPixelBufferGetHeight(pb)
    func code(_ base: UnsafeMutableRawPointer, _ off: Int) -> Int {
        if ten { let c = Int(base.load(fromByteOffset: 2 * off, as: UInt16.self) >> 6); return clear ? c & ~3 : c }
        return Int(base.load(fromByteOffset: off, as: UInt8.self)) * 4
    }
    let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!, yr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0) / (ten ? 2 : 1)
    for r in 0..<p.h { for x in 0..<p.w { p.y.append(code(yb, r * yr + x)) } }
    let cbase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!, cr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1) / (ten ? 2 : 1)
    for r in 0..<(p.h / 2) { for k in 0..<(p.w / 2) {
        p.cb.append(code(cbase, r * cr + 2 * k)); p.cr.append(code(cbase, r * cr + 2 * k + 1))
    } }
    return p
}

func report(_ route: String, _ pb: CVPixelBuffer?) {
    guard let pb else { print("\(route): NO FRAME"); return }
    let fmt = CVPixelBufferGetPixelFormatType(pb)
    for clear in (fmt == x420 ? [false, true] : [false]) {
        let p = planes(pb, clear: clear)
        let n = p.w * p.h, c = n / 4
        guard ref.count >= n + 2 * c else { print("reference too small"); exit(2) }
        var line = String(format: "%-6@ %@%@", route as NSString, ChromaName(fmt) as NSString, clear ? " &~3" : "    ")
        for (name, got, off) in [("Y", p.y, 0), ("Cb", p.cb, n), ("Cr", p.cr, n + c)] {
            var mx = 0, sum = 0, exact = 0
            for i in 0..<got.count {
                let d = abs(got[i] - Int(ref[off + i]) * 4); mx = max(mx, d); sum += d; if d == 0 { exact += 1 }
            }
            line += String(format: "  %@ max %3d mean %6.3f exact %6.2f%%", name, mx, Double(sum) / Double(got.count),
                           100 * Double(exact) / Double(got.count))
        }
        // The chroma column at x = 100 (chroma k = 50), rows 0–5: the I3 sharp fixture's field alternation shows here.
        line += "  Cb[0..5]@k50 " + (0..<6).map { String(p.cb[$0 * p.w / 2 + 50]) }.joined(separator: ",")
        print(line)
    }
}
func ChromaName(_ f: OSType) -> String { f == x420 ? "x420" : f == v420 ? "420v" : String(format: "%08x", f) }

func viaReader(_ track: AVAssetTrack, _ asset: AVAsset, _ pf: OSType) -> CVPixelBuffer? {
    let r = try! AVAssetReader(asset: asset)
    let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pf])
    o.alwaysCopiesSampleData = false
    r.add(o); r.startReading()
    return o.copyNextSampleBuffer().flatMap(CMSampleBufferGetImageBuffer)
}

func viaScrub(_ pf: OSType) -> CVPixelBuffer? {
    let item = AVPlayerItem(asset: AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]))
    let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: pf,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ])
    item.add(out)
    let player = AVPlayer(playerItem: item); player.rate = 0; player.isMuted = true
    player.automaticallyWaitsToMinimizeStalling = false
    let deadline = Date().addingTimeInterval(10)
    while item.status != .readyToPlay && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    var sought = false
    player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in sought = true }
    while !sought && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    while Date() < deadline {
        if out.hasNewPixelBuffer(forItemTime: .zero), let pb = out.copyPixelBuffer(forItemTime: .zero, itemTimeForDisplay: nil) {
            return pb
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return nil
}

func viaVT(_ track: AVAssetTrack, _ asset: AVAsset, _ pf: OSType) -> CVPixelBuffer? {
    let r = try! AVAssetReader(asset: asset)
    let o = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    r.add(o); r.startReading()
    var samples: [CMSampleBuffer] = []
    while samples.count < 16, let sb = o.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(sb) > 0 { samples.append(sb) } }
    guard let fmt = samples.first.flatMap(CMSampleBufferGetFormatDescription) else { return nil }
    let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: pf,
                                  kCVPixelBufferIOSurfacePropertiesKey: [String: Any]() as CFDictionary,
                                  kCVPixelBufferMetalCompatibilityKey: true]
    let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
    var session: VTDecompressionSession?
    guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: spec as CFDictionary,
                                       imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                       decompressionSessionOut: &session) == noErr, let session else { return nil }
    VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    var frames: [(Double, CVPixelBuffer)] = []
    for sb in samples {
        _ = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, image, pts, _ in
            if status == noErr, let image { frames.append((pts.seconds, image)) }
        }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(session)
    VTDecompressionSessionInvalidate(session)
    return frames.min { $0.0 < $1.0 }?.1
}

let asset = AVURLAsset(url: url)
var track: AVAssetTrack?
let sem = DispatchSemaphore(value: 0)
Task { track = try? await asset.loadTracks(withMediaType: .video).first; sem.signal() }
sem.wait()
guard let track else { print("no video track"); exit(2) }
print(url.lastPathComponent)
for pf in [x420, v420] { report("reader", viaReader(track, asset, pf)) }
for pf in [x420, v420] { report("scrub", viaScrub(pf)) }
for pf in [x420, v420] { report("vt", viaVT(track, asset, pf)) }
