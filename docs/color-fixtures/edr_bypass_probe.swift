// What does a CAMetalLayer do with `colorspace = nil` when EDR is opted IN?
//
// ── THE QUESTION, AND WHY PHASE 1 COULD NOT ANSWER IT ────────────────────────────────────────
//
// §6.6 closed Phase 1 with "`colorspace = nil` performs no conversion", measured on nine patches
// across two displays — but its own "Still open" list says SDR ONLY: "EDR was inert on the LG for
// this run; PQ and HLG sources untested, and the EDR opt-in changes layer configuration."
//
// Phase 2a needs that gap closed before it can say what Bypass does on an HDR source. §6.2 wants
// Bypass on HDR to show raw PQ code values uninterpreted — "PQ code values with no transform look
// spectacularly wrong, which is precisely what they look like in a player that ignores the tag".
// Three outcomes were possible a priori and they are not distinguishable by reading headers:
//
//   1. The layer REJECTS the nil — `colorspace` reads back non-nil, or the EDR opt-in silently
//      turns itself off, and Bypass-on-HDR is not a thing the platform will do.
//   2. It ACCEPTS it and clamps to SDR — the extended range collapses and the picture is the
//      SDR-clamped one, which is a different wrongness from the one §6.2 asked for.
//   3. It ACCEPTS it and passes values through — §6.2's raw uninterpreted code values.
//
// ── METHOD, COPIED FROM §6.6 DELIBERATELY ────────────────────────────────────────────────────
//
// Patches blitted DIRECTLY to the drawable — no shader, no sampling, so nothing between the value
// written and the value presented — then read back from the COMPOSITED framebuffer via
// `screencapture`. Same shape as Phase 1, so the numbers are comparable with the ones already in
// the document. Everything here is 8-bit: the capture path is 32BGRA.
//
// ⚠️ THE CAPTURE IS NOT DECODED THROUGH CoreGraphics. Samples come straight from the PNG's data
// provider, for the reason `extract.swift` states: Experiment 1 showed the CG conversion path
// introduces a 1/16 linear toe for pure-power TRCs, so decoding through it manufactures the very
// artefact a colour probe is looking for.
//
// ⚠️ A CAPTURE IS NOT LIGHT. This reads what the framebuffer HOLDS. On an EDR path the whole point
// is values ABOVE SDR white, which a 32BGRA capture cannot represent — so "clipped at 255" here
// means clipped IN THE CAPTURE and is evidence about the composite, not about the panel. Stated
// because it is exactly the inference someone will make from a column of 255s.
//
// USAGE:
//   swiftc -target arm64-apple-macos15.0 -O edr_bypass_probe.swift -o /tmp/edrprobe
//   /tmp/edrprobe [screenIndex]        # 0 = main; run once per display
//
import AppKit
import Metal
import QuartzCore
import ImageIO

// ── The patch set. PQ code values, chosen at the points that discriminate ────────────────────
//
// 0.0 / 0.5 / 1.0 are the structural ones. 0.58 is PQ DIFFUSE WHITE — the value that shows as
// white when the PQ EOTF is applied and as 58% grey when it is not, which is the single most
// diagnostic patch in the set and the one §6.2's claim turns on. 0.15 and 0.75 bracket it.
let patchValues: [Float] = [0.0, 0.15, 0.30, 0.50, 0.58, 0.75, 1.0]

let patchW = 120, patchH = 200
let width = patchW * patchValues.count, height = patchH

struct Condition {
    let name: String
    let declarePQ: Bool
    let wantsEDR: Bool
}

// The four cells of the 2×2. Conditions 1 and 4 are the controls that make 2 readable: 1 is
// today's HDR path, 4 is Phase 1's measured SDR bypass. 2 is the question.
let conditions = [
    Condition(name: "1. PQ declared, EDR ON   (today's HDR path)", declarePQ: true,  wantsEDR: true),
    Condition(name: "2. nil,         EDR ON   (← THE QUESTION)",   declarePQ: false, wantsEDR: true),
    Condition(name: "3. PQ declared, EDR OFF  (control)",          declarePQ: true,  wantsEDR: false),
    Condition(name: "4. nil,         EDR OFF  (Phase 1's case)",   declarePQ: false, wantsEDR: false),
]

let screenIndex = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 0 : 0
guard screenIndex < NSScreen.screens.count else {
    fatalError("screen \(screenIndex) does not exist — \(NSScreen.screens.count) attached")
}
let screen = NSScreen.screens[screenIndex]

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    fatalError("no Metal device")
}

// ── The window: opaque, screenSaver level, borderless ────────────────────────────────────────
//
// Matches Phase 1's configuration exactly ("a fullscreen `.screenSaver`-level opaque window"), so
// the one variable that document lists as untested — ordinary windowed compositing — stays
// untested here rather than being changed silently in the middle of a different question.
let origin = NSPoint(x: screen.frame.minX + 60, y: screen.frame.minY + 60)
let window = NSWindow(contentRect: NSRect(origin: origin, size: CGSize(width: width, height: height)),
                      styleMask: .borderless, backing: .buffered, defer: false)
window.level = .screenSaver
window.isOpaque = true
window.backgroundColor = .black
window.setFrameOrigin(origin)

let layer = CAMetalLayer()
layer.device = device
layer.pixelFormat = .rgba16Float      // E1's format — half floats, so >1.0 survives the layer
layer.framebufferOnly = false
layer.isOpaque = true
layer.drawableSize = CGSize(width: width, height: height)
layer.contentsScale = 1.0

let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
host.wantsLayer = true
host.layer = layer
window.contentView = host
window.orderFrontRegardless()

let pqSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!

// ── The patch texture, built once ────────────────────────────────────────────────────────────
let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                       width: width, height: height, mipmapped: false)
texDesc.usage = [.shaderRead]
texDesc.storageMode = .shared
guard let patchTex = device.makeTexture(descriptor: texDesc) else { fatalError("no texture") }

var pixels = [Float16](repeating: 0, count: width * height * 4)
for y in 0..<height {
    for x in 0..<width {
        let v = Float16(patchValues[min(x / patchW, patchValues.count - 1)])
        let i = (y * width + x) * 4
        pixels[i] = v; pixels[i+1] = v; pixels[i+2] = v; pixels[i+3] = Float16(1.0)
    }
}
pixels.withUnsafeBytes { raw in
    patchTex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                     withBytes: raw.baseAddress!, bytesPerRow: width * 8)
}

/// Present the patches. A straight blit — no shader, nothing sampled, nothing scaled.
func present() {
    guard let drawable = layer.nextDrawable(),
          let cmd = queue.makeCommandBuffer(),
          let blit = cmd.makeBlitCommandEncoder() else { return }
    blit.copy(from: patchTex, sourceSlice: 0, sourceLevel: 0,
              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: width, height: height, depth: 1),
              to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    blit.endEncoding()
    cmd.present(drawable)
    cmd.commit()
    cmd.waitUntilCompleted()
}

/// Capture THIS WINDOW BY ID and pull 8-bit samples with NO ColorSync conversion.
///
/// ⚠️ `-l <windowID>`, NOT `-R <rect>`, AND THE DIFFERENCE IS NOT COSMETIC. A region grab captures
/// whatever is on top of that rect, so any window the operator happens to leave over the probe is
/// silently measured instead of the probe. Window-id capture returns the window's own composited
/// contents: MEASURED — with an opaque window verifiably covering this rect (a region grab of it
/// returned the occluder's colour), the `-l` capture came back bit-identical to the unoccluded one,
/// 0 codes and 0 leaked pixels. This is also the method `sweep.sh` uses.
func capture(_ tag: String) -> [(Float, Int, Int, Int)] {
    let path = "/tmp/edrprobe_\(tag).png"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", "-t", "png", path]
    try? p.run(); p.waitUntilExit()

    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
          let data = img.dataProvider?.data as Data? else { return [] }
    let bpr = img.bytesPerRow, bpp = img.bitsPerPixel / 8
    var out: [(Float, Int, Int, Int)] = []
    let sy = img.height / 2
    for (i, v) in patchValues.enumerated() {
        let sx = min(i * patchW + patchW / 2, img.width - 1)
        let o = sy * bpr + sx * bpp
        guard o + 2 < data.count else { continue }
        // 32BGRA on this path — B,G,R,A. Reported as R,G,B.
        out.append((v, Int(data[o+2]), Int(data[o+1]), Int(data[o])))
    }
    return out
}

// ⚠️ READ FROM THE WINDOW'S OWN SCREEN, NOT `NSScreen.main` OR THE INDEXED ONE.
// docs/BUGS.md's EDR measurement hazard, rule 3: this machine has two displays, and "a probe that
// opens its own window may sample a different screen than the app does". `MetalVideoRenderer`
// resolves through `NSApp.mainWindow?.screen`, so the probe resolves the same way — otherwise the
// number reported here is not the number the app is acting on.
func edrLine(_ label: String) -> String {
    guard let s = window.screen else { return "  \(label): window is on NO screen" }
    // ⚠️ POTENTIAL BEFORE CURRENT — hazard rule 1. `potential == 1.0` means the display grants no
    // headroom AT THAT MOMENT and nothing about any layer can be inferred from `current`.
    return "  \(label) — window's screen: \"\(s.localizedName)\"\n"
        + "    maxPotentialEDR = \(s.maximumPotentialExtendedDynamicRangeColorComponentValue)"
        + "   maxEDR(now) = \(s.maximumExtendedDynamicRangeColorComponentValue)"
        + "   maxRef = \(s.maximumReferenceExtendedDynamicRangeColorComponentValue)"
}

print("╔══════════════════════════════════════════════════════════════════════════════════════╗")
print("  [EDRPROBE]  requested screen \(screenIndex): \"\(screen.localizedName)\"")
print(edrLine("AT START"))
print("╚══════════════════════════════════════════════════════════════════════════════════════╝")

// One warm-up present so the first condition is not measuring window creation.
layer.colorspace = pqSpace
layer.wantsExtendedDynamicRangeContent = true
present()
usleep(400_000)

var results: [String: [(Float, Int, Int, Int)]] = [:]

for (i, c) in conditions.enumerated() {
    layer.colorspace = c.declarePQ ? pqSpace : nil
    layer.wantsExtendedDynamicRangeContent = c.wantsEDR
    present()
    usleep(500_000)

    // ── READ THE PROPERTIES BACK. This is outcome 1 above, and it is the cheapest to test:
    // if the layer refuses a nil under EDR, or drops the opt-in, it shows here and no amount of
    // pixel arithmetic is needed.
    let csBack = layer.colorspace
    let csName = csBack.flatMap { $0.name.map { String($0) } } ?? (csBack == nil ? "nil" : "<unnamed>")
    let edrBack = layer.wantsExtendedDynamicRangeContent

    print("\n── \(c.name)")
    print("   REQUESTED : colorspace=\(c.declarePQ ? "ITUR_2100_PQ" : "nil")  wantsEDR=\(c.wantsEDR)")
    print("   READ BACK : colorspace=\(csName)  wantsEDR=\(edrBack)"
        + ((csBack == nil) == !c.declarePQ && edrBack == c.wantsEDR ? "   ✅ both stuck" : "   ⚠️ CHANGED"))
    // Per-condition, because `current` is the headroom this layer WON, and whether a nil-colorspace
    // layer can still win a grant is the question the HDR-on run exists to answer.
    print(edrLine("   now"))

    let s = capture("\(i)")
    results[c.name] = s
    print("   patch →  captured RGB (8-bit, 32BGRA capture path)")
    for (v, r, g, b) in s {
        print(String(format: "     %.2f  →  %3d %3d %3d", v, r, g, b))
    }
}

// ── The comparison the probe exists for ──────────────────────────────────────────────────────
print("\n══════════════════════════════════════════════════════════════════════════════════════")
func maxDelta(_ a: [(Float, Int, Int, Int)], _ b: [(Float, Int, Int, Int)]) -> Int {
    guard a.count == b.count, !a.isEmpty else { return -1 }
    return zip(a, b).map { max(abs($0.1 - $1.1), abs($0.2 - $1.2), abs($0.3 - $1.3)) }.max() ?? -1
}
let n = conditions.map { $0.name }
print("max |Δ| across patches, 8-bit:")
print("  (2) nil+EDR  vs (1) PQ+EDR   : \(maxDelta(results[n[1]] ?? [], results[n[0]] ?? []))"
    + "   ← 0 would mean the nil was ignored under EDR")
print("  (2) nil+EDR  vs (4) nil-noEDR: \(maxDelta(results[n[1]] ?? [], results[n[3]] ?? []))"
    + "   ← 0 would mean the EDR opt-in is inert once colorspace is nil")
print("  (1) PQ+EDR   vs (3) PQ-noEDR : \(maxDelta(results[n[0]] ?? [], results[n[2]] ?? []))"
    + "   ← the EDR opt-in's own effect, as a reference magnitude")
print("══════════════════════════════════════════════════════════════════════════════════════")

window.orderOut(nil)
