// hrprobe — can a PQ CGImage's content headroom be cleared? NO, AND THAT IS THE FINDING.
//
// Written for the HDR scrub investigation, to test "option B": strip the image's contentHeadroom
// so Core Animation excludes it from tone mapping, per CGImage.h — "The headroom value of 0.0f
// means 'headroom unknown'. The image with unknown content headroom will be excluded from tone
// mapping." The result refutes the premise of that option. See ../BUGS.md →
// "⚠️ A PQ image's content headroom cannot be cleared — it is DERIVED FROM the colorspace".
//
// Moved here out of a session scratchpad, which does not survive — the same reason scrubmeas.swift
// and ../color-fixtures/ are here. NOT part of the app target: project.yml's `sources:` is `App`
// plus one explicit DeckLink .cpp, so nothing under docs/ is compiled in.
//
// ── BUILD AND RUN ───────────────────────────────────────────────────────────────────────────────
//
//   cd docs/scrub-fixtures
//   xcrun swiftc -O -target arm64-apple-macos15.0 -o hrprobe hrprobe.swift
//   ./hrprobe ../color-fixtures/wedge-pq-24track.mov
//
// Do NOT pass -parse-as-library: single-file script, top-level code.
//
// ── WHAT IT MEASURED, 2026-08-28 ────────────────────────────────────────────────────────────────
//
//   source        : headroom=4.9261084 cs=kCGColorSpaceITUR_2100_PQ
//   headroom 0.0  : headroom=4.9261084   ← IGNORED. Not NULL, a new object, tag unchanged.
//   headroom 1.0  : headroom=1.0
//   headroom 2.0  : headroom=2.0
//   headroom 8.0  : headroom=8.0
//   plain CGImageCreate : headroom=4.9261084   ← an API with NO headroom parameter AT ALL
//
// The last line is the one that matters. An image built by an API that cannot express headroom
// still reports 4.9261084 (= kCGDefaultHDRImageContentHeadroom). The headroom is not metadata we
// attach; it is DERIVED FROM the PQ colorspace. 0.0 does not mean "clear the tag", it means "no
// explicit override" — and the fallback is the colorspace's implied default. Only values >= 1.0
// take. There is therefore NO WAY to obtain a PQ-tagged CGImage with unknown headroom, and the
// header's documented 0.0 case is unreachable through this API.
//
// ⚠️ THE GENERATOR CONFIG BELOW IS COPIED FROM FrameEngine.makeScrubPreviewGenerator. If that
// changes, change it here, or this probes a generator the app does not use.
import AVFoundation
import CoreGraphics
import Foundation

func describe(_ label: String, _ img: CGImage?) {
    guard let img else { print("  \(label): nil (function returned NULL)"); return }
    let cs = img.colorSpace
    let csName: String = (cs?.name as String?) ?? "nil"
    let is2100: Bool = cs.map { CGColorSpaceUsesITUR_2100TF($0) } ?? false
    let hr: Float = img.contentHeadroom
    let bpc: Int = img.bitsPerComponent
    var line = "  " + label + ": headroom=" + String(hr)
    line += " cs=" + csName
    line += " 2100TF=" + String(is2100)
    line += " bpc=" + String(bpc)
    print(line)
}

let path = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "docs/color-fixtures/wedge-pq-24track.mov"
let asset = AVURLAsset(url: URL(fileURLWithPath: path))
let g = AVAssetImageGenerator(asset: asset)
g.appliesPreferredTrackTransform = true
g.apertureMode = .encodedPixels
g.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
g.requestedTimeToleranceAfter  = CMTime(seconds: 0.5, preferredTimescale: 600)
g.maximumSize = CGSize(width: 960, height: 540)
g.dynamicRangePolicy = .matchSource

let sem = DispatchSemaphore(value: 0)
var source: CGImage?
g.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: 1.0, preferredTimescale: 600))]) { _, img, _, _, _ in
    source = img; sem.signal()
}
sem.wait()

guard let src = source else { print("FAILED to generate an image from \(path)"); exit(1) }
print("SOURCE (.matchSource, as shipping):")
describe("source        ", src)

print("\nCGImageCreateCopyWithContentHeadroom — every documented-legal value:")
describe("headroom 0.0  ", CGImageCreateCopyWithContentHeadroom(0.0, src))
describe("headroom 1.0  ", CGImageCreateCopyWithContentHeadroom(1.0, src))
describe("headroom 2.0  ", CGImageCreateCopyWithContentHeadroom(2.0, src))
describe("headroom 8.0  ", CGImageCreateCopyWithContentHeadroom(8.0, src))

print("\nIdentity checks — is the returned object even a new one?")
let c0 = CGImageCreateCopyWithContentHeadroom(0.0, src)
let c2 = CGImageCreateCopyWithContentHeadroom(2.0, src)
print("  copy(0.0) === source : \(c0.map { $0 === src } ?? false)")
print("  copy(2.0) === source : \(c2.map { $0 === src } ?? false)")

print("\nAlternate route — CGImageCreateCopyWithColorSpace(same PQ space):")
if let cs = src.colorSpace {
    describe("copyWithCS(PQ)", src.copy(colorSpace: cs))
}

print("\n── RECONSTRUCTION ROUTES (share the data provider, no re-render) ──")
if let dp = src.dataProvider {
    print("  source HAS a data provider (size=\(dp.data.map { CFDataGetLength($0) } ?? -1) bytes)")
    describe("create(hr 0.0)",
             CGImage(headroom: 0.0, width: src.width, height: src.height,
                 bitsPerComponent: src.bitsPerComponent, bitsPerPixel: src.bitsPerPixel,
                 bytesPerRow: src.bytesPerRow, space: src.colorSpace!,
                 bitmapInfo: src.bitmapInfo, provider: dp, decode: nil,
                 shouldInterpolate: src.shouldInterpolate, intent: src.renderingIntent))
    describe("plain CGImageCreate",
             CGImage(width: src.width, height: src.height,
                 bitsPerComponent: src.bitsPerComponent, bitsPerPixel: src.bitsPerPixel,
                 bytesPerRow: src.bytesPerRow, space: src.colorSpace!,
                 bitmapInfo: src.bitmapInfo, provider: dp, decode: nil,
                 shouldInterpolate: src.shouldInterpolate, intent: src.renderingIntent))
} else {
    print("  ⚠️ source has NO data provider — reconstruction would need a real copy")
}
