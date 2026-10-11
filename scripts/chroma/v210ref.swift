// Re-run a revision's `rgbToV210` on a DEBUG v210 dump's readback, on the GPU, and compare with the dump
// (COLOR_MANAGEMENT_FINDINGS.md §6.10, Stage 3b S1, P1). Links no app code.
//
//   swiftc -O -o /tmp/v210ref scripts/chroma/v210ref.swift
//   git show 1bd07de:App/PassthroughShader.metal > /tmp/head.metal
//   /tmp/v210ref /tmp/head.metal <stem>      # <stem>.rgba16f, <stem>.v210.json, <stem>.v210 from ⌃⌥E
//
// Why the GPU and not a CPU copy of the kernel: a CPU copy cannot be byte-exact (fused multiply-adds
// round differently at .5 boundaries). The same kernel source, compiled by the same Metal compiler and
// run on the same GPU, can. A HEAD kernel that predates `chromaMode` simply never reads it: the
// uniform struct is passed in full and an older kernel reads its own prefix.
//
// Prints `IDENTICAL` or the number of differing 10-bit components, split into luma and chroma, with
// the largest difference. Exit status 0 when identical, 1 when not, 2 on bad input.

import Foundation
import Metal

struct Params {   // RGBToV210Params, Stage 3b S1 layout (a prefix of it is every earlier layout)
    var srcWidth: UInt32, srcHeight: UInt32, dstWidth: UInt32, dstHeight: UInt32, dstRowWords: UInt32
    var kr: Float, kb: Float
    var chromaMode: UInt32
}

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: v210ref <PassthroughShader.metal> <dump stem>"); exit(2) }
let kernelSource = try String(contentsOfFile: args[1], encoding: .utf8)
let stem = args[2]
let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: stem + ".v210.json"))) as! [String: Any]
let raw = try Data(contentsOf: URL(fileURLWithPath: stem + ".rgba16f"))
let dump = try Data(contentsOf: URL(fileURLWithPath: stem + ".v210"))
let w = meta["width"] as! Int, h = meta["height"] as! Int
let rowBytes = meta["rowBytes"] as! Int, rbpr = meta["readbackBytesPerRow"] as! Int
let mode = UInt32(meta["chromaMode"] as! Int)
let kr = Float(meta["kr"] as! Double), kb = Float(meta["kb"] as! Double)
guard raw.count == rbpr * h, dump.count == rowBytes * h else { print("size mismatch"); exit(2) }

let device = MTLCreateSystemDefaultDevice()!
let lib = try device.makeLibrary(source: kernelSource, options: nil)
let pipeline = try device.makeComputePipelineState(function: lib.makeFunction(name: "rgbToV210")!)
let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
desc.usage = [.shaderRead]; desc.storageMode = .shared
let tex = device.makeTexture(descriptor: desc)!
raw.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                                  withBytes: $0.baseAddress!, bytesPerRow: rbpr) }
let out = device.makeBuffer(length: rowBytes * h, options: .storageModeShared)!
var p = Params(srcWidth: UInt32(w), srcHeight: UInt32(h), dstWidth: UInt32(w), dstHeight: UInt32(h),
               dstRowWords: UInt32(rowBytes / 4), kr: kr, kb: kb, chromaMode: mode)
let q = device.makeCommandQueue()!, cmd = q.makeCommandBuffer()!, enc = cmd.makeComputeCommandEncoder()!
enc.setComputePipelineState(pipeline); enc.setTexture(tex, index: 0); enc.setBuffer(out, offset: 0, index: 0)
enc.setBytes(&p, length: MemoryLayout<Params>.stride, index: 1)
enc.dispatchThreadgroups(MTLSize(width: (((w + 5) / 6) + 15) / 16, height: (h + 15) / 16, depth: 1),
                         threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
enc.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()

// Compare component by component. v210 word k of a 4-word group holds 3 components; the pattern of
// which are luma: w0 Cb Y Cr, w1 Y Cb Y, w2 Cr Y Cb, w3 Y Cr Y.
let isLuma: [[Bool]] = [[false, true, false], [true, false, true], [false, true, false], [true, false, true]]
let ref = UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: UInt32.self), count: rowBytes * h / 4)
var lumaDiff = 0, chromaDiff = 0, maxDiff = 0
dump.withUnsafeBytes { d in
    let got = d.bindMemory(to: UInt32.self)
    let groupsPerRow = (w + 5) / 6
    for y in 0..<h {
        for g in 0..<groupsPerRow {
            for k in 0..<4 {
                let i = y * rowBytes / 4 + g * 4 + k
                for c in 0..<3 {
                    let a = Int((ref[i] >> (10 * UInt32(c))) & 0x3FF), b = Int((got[i] >> (10 * UInt32(c))) & 0x3FF)
                    if a != b {
                        if isLuma[k][c] { lumaDiff += 1 } else { chromaDiff += 1 }
                        maxDiff = max(maxDiff, abs(a - b))
                    }
                }
            }
        }
    }
}
print("\(w)x\(h) chromaMode=\(mode) kernel=\(args[1])")
if lumaDiff + chromaDiff == 0 { print("IDENTICAL"); exit(0) }
print("DIFFERENT: luma \(lumaDiff), chroma \(chromaDiff) components; max |Δ| \(maxDiff) codes")
exit(1)
