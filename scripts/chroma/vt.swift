// VideoToolbox 4:2:2 / 4:4:4 decode probe (COLOR_MANAGEMENT_FINDINGS.md §6.10, Stage 3b). Links no app code.
//
//   swiftc -O -o /tmp/vt scripts/chroma/vt.swift
//   /tmp/vt build/chroma-fixtures/lines-422-hevc.mov build/chroma-fixtures/checker-444-hevc.mov ...
//
// For each file, decodes every frame through a raw VTDecompressionSession three ways — no format asked
// (the decoder's NATIVE output), x422, x420 — once HARDWARE-ONLY
// (kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder) and once SOFTWARE-ONLY, and
// prints whether the session used hardware, the pixel format delivered, frames decoded and ms/frame.
//
// READ IT THIS WAY:
//   * `HW-only: usingHW=true decoded 50/50 → x422`  this Mac decodes the format in hardware.
//   * `HW-only: create=-12906` (or decoded 0/50)     no hardware decoder for this profile.
//   * `SW-only: … err=-8969`                         no software decoder either (H.264 4:2:2 / 4:4:4 on
//                                                    the M4 Max, 2026-10-10): the stream cannot be shown
//                                                    at all, and there is nothing to convert to 4:2:0.
//   * The native format on hardware is PACKED ('p422' / 'p444'), which Metal cannot sample as r16/rg16:
//     always request x422 / x444 explicitly. Asking a 4:2:2 source for x420 costs MORE than x422.
//
// Do NOT use VTIsHardwareDecodeSupported for this: it answers per codec, not per chroma format.
//
// Measured on an M4 Max, macOS 26.5.1 (2026-10-10): HEVC Main 4:2:2 10, Main 4:4:4 10, H.264 High
// 4:2:2 10 and High 4:4:4 10 all decode in hardware; HEVC also in software; H.264 4:2:2/4:4:4 not.

import AVFoundation
import VideoToolbox
func fcc(_ c: OSType) -> String { String(bytes: [24,16,8,0].map{UInt8((c >> $0) & 0xff)}, encoding: .ascii) ?? "?" }
final class Box { var fmt = "none"; var n = 0; var err: OSStatus = 0 }
let cb: VTDecompressionOutputCallback = { refcon, _, status, _, img, _, _ in
    let b = Unmanaged<Box>.fromOpaque(refcon!).takeUnretainedValue()
    if status != noErr { b.err = status }
    if let img { b.n += 1; b.fmt = "\(fcc(CVPixelBufferGetPixelFormatType(img))) \(CVPixelBufferGetWidth(img))x\(CVPixelBufferGetHeight(img)) chromaH=\(CVPixelBufferGetHeightOfPlane(img, 1))" }
}
for path in CommandLine.arguments.dropFirst() {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let track = asset.tracks(withMediaType: .video)[0]
    let fd = track.formatDescriptions[0] as! CMFormatDescription
    print("== \(path)")
    for (label, req) in [("native (no format asked)", nil as OSType?), ("ask x422", kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange), ("ask x420", kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)] {
        for hwOnly in [true, false] {
            let box = Box()
            var rec = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: cb, decompressionOutputRefCon: Unmanaged.passUnretained(box).toOpaque())
            let spec: [CFString: Any] = hwOnly ? [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
                                               : [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false]
            let attrs: CFDictionary? = req.map { [kCVPixelBufferPixelFormatTypeKey: $0] as CFDictionary }
            var s: VTDecompressionSession?
            let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: spec as CFDictionary, imageBufferAttributes: attrs, outputCallback: &rec, decompressionSessionOut: &s)
            guard st == noErr, let s else { print("  \(label) \(hwOnly ? "HW-only" : "SW-only"): create=\(st)"); continue }
            var hw: CFBoolean?; VTSessionCopyProperty(s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &hw)
            let r = try! AVAssetReader(asset: asset); let o = AVAssetReaderTrackOutput(track: track, outputSettings: nil); r.add(o); r.startReading()
            let t0 = CFAbsoluteTimeGetCurrent(); var sent = 0
            while let sb = o.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(sb) > 0 { _ = VTDecompressionSessionDecodeFrame(s, sampleBuffer: sb, flags: [], frameRefcon: nil, infoFlagsOut: nil); sent += 1 } }
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(max(sent, 1))
            print("  \(label) \(hwOnly ? "HW-only" : "SW-only"): usingHW=\(hw.map { CFBooleanGetValue($0) } ?? false) decoded \(box.n)/\(sent) → \(box.fmt) err=\(box.err) \(String(format: "%.2f", ms)) ms/frame")
            VTDecompressionSessionInvalidate(s)
        }
    }
}
