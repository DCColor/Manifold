// AVFoundation output-format probe (COLOR_MANAGEMENT_FINDINGS.md §6.10, Stage 3b). Links no app code.
//
//   swiftc -O -o /tmp/avf-formats scripts/chroma/avf-formats.swift
//   /tmp/avf-formats rows    build/chroma-fixtures/lines-422-*.mov
//   /tmp/avf-formats checker build/chroma-fixtures/checker-444-*.mov
//
// Reads every frame through AVAssetReader (what FileFrameSource does) asking for x420, x422, x444, sv22
// and sv44, and prints the format delivered, the chroma plane size, ms/frame, the first chroma samples
// and how many chroma samples sit on their own pattern (`rows` for lines-422, `checker` for checker-444).
// Registers the Pro Video Formats decoders first, as the app does.
//
// ⚠️ THE "own pattern" COUNT IS ONLY MEANINGFUL AT THE SOURCE'S OWN CHROMA RESOLUTION. A decimated plane
// is judged at its sample's luma position, so a point-sampled x420 can score 100 % on the checker while
// showing a solid colour. Read the printed sample values as well.
//
// Measured on an M4 Max, macOS 26.5.1 (2026-10-10): every format asked for is delivered for ProRes 422 HQ,
// 4444, 4444 XQ, H.264 and HEVC 4:2:2, and DNxHR 444 (plug-in). The native request is the cheapest
// (ProRes 422 HQ 1080: x420 1.53 ms, x422 0.48 ms; ProRes 4444: x420 1.65 ms, x444 0.58 ms).

import AVFoundation
import VideoToolbox
VTRegisterProfessionalVideoWorkflowVideoDecoders()
func fcc(_ c: OSType) -> String { String(bytes: [24,16,8,0].map{UInt8((c >> $0) & 0xff)}, encoding: .ascii) ?? "?" }
// pattern: "rows" (422 fixture: chroma alternates by row) or "checker" (444 fixture: by x+y)
let pattern = CommandLine.arguments[1]
let reqs: [OSType] = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                      kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange,
                      kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange]
for f in CommandLine.arguments.dropFirst(2) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: f)); let track = asset.tracks(withMediaType: .video)[0]
    print("== \(f) \(fcc(CMFormatDescriptionGetMediaSubType(track.formatDescriptions[0] as! CMFormatDescription)))")
    for req in reqs {
        let r = try! AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: req]); o.alwaysCopiesSampleData = false
        r.add(o); r.startReading()
        var n = 0; var first: CVPixelBuffer?; let t0 = CFAbsoluteTimeGetCurrent()
        while let sb = o.copyNextSampleBuffer() { if let pb = CMSampleBufferGetImageBuffer(sb) { first = first ?? pb; n += 1 } }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(max(n, 1))
        guard let pb = first else { print("  \(fcc(req)): FAILED \(r.error.map { ($0 as NSError).code } ?? 0)"); continue }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!; let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let cw = CVPixelBufferGetWidthOfPlane(pb, 1), ch = CVPixelBufferGetHeightOfPlane(pb, 1)
        let is16 = req == kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange || req == kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange
        var ok = 0, tot = 0, sample = ""
        for y in stride(from: 0, to: ch, by: 1) { let p = (base + y*bpr).assumingMemoryBound(to: UInt16.self)
            for x in [cw/2, cw/2 + 1] { let cb = Int(p[2*x]) >> 6
                let lumaX = x * (1920 / cw), lumaY = y * (1080 / ch)
                let odd = pattern == "rows" ? lumaY % 2 == 1 : (lumaX + lumaY) % 2 == 1
                if abs(cb - (odd ? 300 : 724)) <= 4 { ok += 1 }; tot += 1
                if y < 2 { sample += "\(cb) " } } }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        print("  \(fcc(req)) → \(fcc(CVPixelBufferGetPixelFormatType(pb))) chroma \(cw)x\(ch) \(String(format: "%.2f", ms)) ms/f  Cb(x=mid,mid+1;y=0,1)=\(sample)  samples on own pattern ±4: \(ok)/\(tot)\(is16 ? " (16-bit, >>6)" : "")")
    }
}
