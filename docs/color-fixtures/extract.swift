// Extract RAW samples + the embedded ICC from a capture, with NO ColorSync conversion.
//
// Why: the analysis decode must not go through the very CoreGraphics conversion path whose
// low-end behaviour is under test. Experiment 1 showed that path introduces a 1/16 linear toe
// for pure-power TRCs, so using it to decode the capture would manufacture the artifact it is
// supposed to be detecting. Here the samples come straight from the PNG's data provider and the
// display profile is dumped for INDEPENDENT numeric evaluation (parse_icc.py).
import Foundation
import CoreGraphics
import ImageIO

let path = CommandLine.arguments[1]
let stem = CommandLine.arguments[2]
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("load failed") }

print("\(path): \(img.width)x\(img.height)  bpc=\(img.bitsPerComponent) bpp=\(img.bitsPerPixel)"
    + "  bytesPerRow=\(img.bytesPerRow)  alpha=\(img.alphaInfo.rawValue)"
    + "  bitmapInfo=0x\(String(img.bitmapInfo.rawValue, radix: 16))")
if let cs = img.colorSpace {
    let nm = cs.name.map { String($0) } ?? "<unnamed>"
    print("  colorspace: \(nm)  model=\(cs.model.rawValue) components=\(cs.numberOfComponents)")
    if let icc = cs.copyICCData() as Data? {
        try! icc.write(to: URL(fileURLWithPath: stem + ".icc"))
        print("  ICC: \(icc.count) bytes → \(stem).icc")
    } else { print("  ICC: none") }
} else { print("  colorspace: NONE") }

guard let data = img.dataProvider?.data as Data? else { fatalError("no provider data") }
try! data.write(to: URL(fileURLWithPath: stem + ".raw"))
print("  raw samples: \(data.count) bytes → \(stem).raw")
