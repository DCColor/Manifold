// wincap — capture the COMPOSITED Manifold window IN HDR, and diff two captures numerically.
//
// ── WHY THIS EXISTS, AND WHY `screencapture` CANNOT DO IT ───────────────────────────────────────
//
// The HDR scrub investigation reached a hypothesis that only the compositor's OUTPUT can answer:
// does the presence of a second EDR layer in the window change how either one is rendered? Every
// input has been eliminated (five layer properties individually, the image's headroom — which
// cannot be cleared because it IS the PQ colorspace — and the pixel values, which are identity at
// 1:1; see ../BUGS.md 2026-08-28). What is left is what Core Animation DID with them.
//
// ⚠️ `../color-fixtures/sweep.sh` CANNOT BE REUSED FOR THIS, AND REUSING IT WOULD PRODUCE A FOURTH
// DEAD INSTRUMENT. It captures with `screencapture -x -o -l <winID> cap.png`. `screencapture` has
// NO HDR option — checked, not assumed: its usage lists -t for format (png/pdf/jpg/tiff) and
// nothing for dynamic range. A PNG capture is 8-bit and SDR-tonemapped on the way out, so it
// DESTROYS exactly the difference being measured and would come back showing none. That is the
// same failure shape as the three dead instruments recorded in ../BUGS.md — a clean null from a
// measurement that could not have detected the effect.
//
// This uses ScreenCaptureKit instead: `SCScreenshotManager.captureImage` with
// `captureDynamicRange = .HDRLocalDisplay`, which the header says returns "a CGImage in RGhA
// format" — half-float RGBA, values above 1.0 preserved. macOS 15.0, and HDR capture is
// "only supported with Apple Silicon Mac", which this app is (arm64 only).
//
// ⚠️ NEEDS SCREEN RECORDING PERMISSION for whatever runs it (Terminal/iTerm). macOS will prompt on
// first run; if it returns a permission error the fix is System Settings ▸ Privacy & Security ▸
// Screen & System Audio Recording, then RESTART the terminal — the grant is not picked up live.
//
// ── BUILD AND RUN ───────────────────────────────────────────────────────────────────────────────
//
//   cd docs/scrub-fixtures
//   xcrun swiftc -O -target arm64-apple-macos15.0 -o wincap wincap.swift
//
//   ./wincap capture cond1        # writes cond1.f16 (raw half-float RGBA + a header)
//   ./wincap diff cond1.f16 cond2.f16
//   ./wincap diff cond1.f16 cond2.f16 --region right    # left | right | full (default full)
//
// Not part of the app target; nothing under docs/ is compiled in. Binary is built on demand and
// not committed, matching ../color-fixtures/.
import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreMedia

func die(_ m: String) -> Never { FileHandle.standardError.write((m+"\n").data(using: .utf8)!); exit(1) }

// ── CAPTURE ────────────────────────────────────────────────────────────────────────────────────

func capture(label: String) async {
    let content: SCShareableContent
    do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
    catch { die("SCShareableContent failed: \(error)\n\nThis is usually the Screen Recording permission. Grant it to your terminal in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, then RESTART the terminal.") }

    // Largest on-screen Manifold window — same selection rule as ../color-fixtures/getwin.swift,
    // so the two tools cannot disagree about which window is under test.
    let windows = content.windows.filter { $0.owningApplication?.applicationName == "Manifold" }
    guard let win = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    else { die("no on-screen Manifold window found (\(content.windows.count) windows visible)") }

    let cfg = SCStreamConfiguration()
    cfg.captureDynamicRange = .hdrLocalDisplay      // ← the whole point; SDR would erase the effect
    cfg.width = Int(win.frame.width * 2)            // 2x backing scale; exact raster is reported below
    cfg.height = Int(win.frame.height * 2)
    cfg.showsCursor = false
    let filter = SCContentFilter(desktopIndependentWindow: win)

    let image: CGImage = await withCheckedContinuation { c in
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { img, err in
            if let img { c.resume(returning: img) }
            else { die("captureImage failed: \(err.map(String.init(describing:)) ?? "nil")") }
        }
    }

    guard let dp = image.dataProvider, let data = dp.data, let ptr = CFDataGetBytePtr(data)
    else { die("capture produced no readable data provider") }
    let w = image.width, h = image.height, bpr = image.bytesPerRow, bpp = image.bitsPerPixel/8
    let isFloat = image.bitmapInfo.contains(.floatComponents)
    let csName: String = (image.colorSpace?.name as String?) ?? "nil"

    print("capture \(label): \(w)×\(h)  bpc=\(image.bitsPerComponent) bpp=\(image.bitsPerPixel) "
        + "float=\(isFloat) cs=\(csName)")
    if !isFloat || image.bitsPerComponent != 16 {
        print("  ⚠️ NOT half-float. HDR capture did not engage — this capture is SDR and CANNOT")
        print("     show the difference under test. Do not diff it. (Apple Silicon + macOS 15+ required.)")
    }

    // Header + raw bytes. Deliberately a dumb format: no encoder can silently tone-map it.
    var out = Data()
    var hdr = "WINCAP1 \(w) \(h) \(bpr) \(bpp) \(isFloat ? 1 : 0) \(csName)\n".data(using: .utf8)!
    out.append(hdr); hdr.removeAll()
    out.append(Data(bytes: ptr, count: bpr*h))
    let url = URL(fileURLWithPath: label.hasSuffix(".f16") ? label : label + ".f16")
    do { try out.write(to: url) } catch { die("write failed: \(error)") }
    print("  wrote \(url.lastPathComponent) (\(out.count) bytes)")
}

// ── DIFF ───────────────────────────────────────────────────────────────────────────────────────

struct Cap { var w = 0, h = 0, bpr = 0, bpp = 0, isFloat = false, cs = ""; var bytes = Data() }

func load(_ path: String) -> Cap {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { die("cannot read \(path)") }
    guard let nl = d.firstIndex(of: 0x0A),
          let head = String(data: d[d.startIndex..<nl], encoding: .utf8) else { die("\(path): no header") }
    let f = head.split(separator: " ")
    guard f.count >= 7, f[0] == "WINCAP1" else { die("\(path): not a wincap file") }
    var c = Cap()
    c.w = Int(f[1])!; c.h = Int(f[2])!; c.bpr = Int(f[3])!; c.bpp = Int(f[4])!
    c.isFloat = f[5] == "1"; c.cs = String(f[6])
    c.bytes = d[d.index(after: nl)...]
    return c
}

/// RGB at (x,y) as Doubles. RGhA = half-float RGBA.
func px(_ c: Cap, _ x: Int, _ y: Int) -> (Double, Double, Double) {
    let off = y*c.bpr + x*c.bpp
    return c.bytes.withUnsafeBytes { raw -> (Double, Double, Double) in
        let b = raw.baseAddress!.advanced(by: off)
        if c.isFloat && c.bpp >= 6 {
            let h = b.assumingMemoryBound(to: UInt16.self)
            return (Double(Float16(bitPattern: h[0])), Double(Float16(bitPattern: h[1])), Double(Float16(bitPattern: h[2])))
        }
        let u = b.assumingMemoryBound(to: UInt8.self)   // BGRA fallback (SDR capture)
        return (Double(u[2])/255, Double(u[1])/255, Double(u[0])/255)
    }
}

func stats(_ v: [Double]) -> String {
    guard !v.isEmpty else { return "n=0" }
    let m = v.reduce(0,+)/Double(v.count)
    let sd = (v.map { ($0-m)*($0-m) }.reduce(0,+)/Double(v.count)).squareRoot()
    return String(format: "mean %+.6f  sd %.6f  min %+.6f  max %+.6f", m, sd, v.min()!, v.max()!)
}

func diff(_ pa: String, _ pb: String, region: String) {
    let a = load(pa), b = load(pb)
    print("A \(pa): \(a.w)×\(a.h) float=\(a.isFloat) cs=\(a.cs)")
    print("B \(pb): \(b.w)×\(b.h) float=\(b.isFloat) cs=\(b.cs)")
    guard a.w == b.w, a.h == b.h else {
        die("\n⚠️ GEOMETRY MISMATCH — the window moved or resized between captures. The diff would be\n"
          + "   measuring a shift, not a colour difference. Recapture without touching the window.") }
    if !a.isFloat || !b.isFloat {
        print("\n⚠️ AT LEAST ONE CAPTURE IS NOT HALF-FLOAT — it is SDR and cannot show the effect.")
        print("   Any null result below is meaningless. Fix the capture before reading this.\n")
    }
    let x0 = region == "right" ? a.w/2 : 0
    let x1 = region == "left"  ? a.w/2 : a.w
    print("region: \(region)  x \(x0)..<\(x1)  of \(a.w)")

    var da: [Double] = [], av: [Double] = [], bv: [Double] = []
    let stepX = max(1, (x1-x0)/400), stepY = max(1, a.h/400)
    for y in stride(from: 0, to: a.h, by: stepY) {
        for x in stride(from: x0, to: x1, by: stepX) {
            let (ar,ag,ab) = px(a,x,y), (br,bg,bb) = px(b,x,y)
            for (u,v) in [(ar,br),(ag,bg),(ab,bb)] { da.append(u-v); av.append(u); bv.append(v) }
        }
    }
    guard !da.isEmpty else { die("no samples") }
    print("samples: \(da.count) channel-values")
    print("A - B:  \(stats(da))")
    print("A range [\(String(format:"%.6f",av.min()!)), \(String(format:"%.6f",av.max()!))]   "
        + "B range [\(String(format:"%.6f",bv.min()!)), \(String(format:"%.6f",bv.max()!))]")
    let maxAbs = da.map { abs($0) }.max()!
    print("max |A-B| = \(String(format:"%.6f",maxAbs))")

    // SHAPE, binned by B's value — an offset, a scale, a curve and a ceiling look different here.
    print("shape — mean(A-B) binned by B:")
    var bins = [[Double]](repeating: [], count: 10)
    let hi = max(bv.max()!, 1e-9)
    for i in 0..<bv.count { bins[min(9, max(0, Int(bv[i]/hi*10)))].append(da[i]) }
    for (k, bin) in bins.enumerated() where !bin.isEmpty {
        let mm = bin.reduce(0,+)/Double(bin.count)
        print(String(format: "   B %.3f–%.3f  n=%7d  mean %+.6f  %@",
                     Double(k)/10*hi, Double(k+1)/10*hi, bin.count, mm,
                     String(repeating: "█", count: min(40, Int(abs(mm)*400)))))
    }
    let thresh = 0.002
    print("")
    if maxAbs <= thresh {
        print("VERDICT: IDENTICAL to within \(thresh) (max |Δ| = \(String(format:"%.6f",maxAbs))).")
        print("  The compositor rendered this region the same in both conditions.")
    } else {
        print("VERDICT: DIFFERENT — max |Δ| = \(String(format:"%.6f",maxAbs)), well above the \(thresh) noise floor.")
        print("  The other layer's presence changed how this one was composited.")
    }
}

// ── MAIN ───────────────────────────────────────────────────────────────────────────────────────

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("""
    usage:
      wincap capture <label>                       capture the Manifold window in HDR → <label>.f16
      wincap diff <a.f16> <b.f16> [--region left|right|full]
    """)
    exit(2)
}
switch args[1] {
case "capture": await capture(label: args[2])
case "diff":
    var region = "full"
    if let i = args.firstIndex(of: "--region"), i+1 < args.count { region = args[i+1] }
    guard args.count >= 4 else { die("diff needs two files") }
    diff(args[2], args[3], region: region)
default: die("unknown command \(args[1])")
}
