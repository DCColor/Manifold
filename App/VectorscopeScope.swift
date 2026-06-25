import SwiftUI
import CoreGraphics
import Metal

/// Native vectorscope: a 2D chroma-plane (Cb horizontal, Cr vertical) scatter on a
/// circular graticule with the six color-bar target boxes (R, G, B, Cy, Mg, Yl).
/// Pure consumer of MetalVideoRenderer.readbackRenderedFrameAsync — samples the
/// PRE-DISPLAY offscreen texture (raw code values), never screen pixels. Independent
/// of the waveform/parade: own gate, own readback texture, runs alongside them.
final class VectorscopeScopeModel: ObservableObject {

    @Published var image: CGImage?
    weak var renderer: MetalVideoRenderer?

    // Square chroma-plane buffer.
    static let plane = 300

    /// Chroma -> plot position, as a FRACTION of the plot dimension per chroma unit.
    /// Calibrated to 75% color bars (the broadcast/Resolve convention): at this scale
    /// the 75%-bar primaries/secondaries land ON the target boxes (boxes derived with
    /// the same transform below). The outermost 75% targets (green/magenta, chroma
    /// magnitude ≈ 114) sit at ~0.35 of the plot from center ≈ 77% of the graticule
    /// circle (radius 0.46), leaving headroom — 100% content reads further out,
    /// reaching ~the circle edge. 75% bars land in-box BY CONSTRUCTION.
    static let chromaScaleFrac: Float = 0.0031

    /// The six 75% reference colors (R, G, B, Cy, Mg, Yl) — classic SMPTE 75% bar
    /// levels: active channels at 0.75·255 ≈ 191, off channels 0. Used to DERIVE the
    /// target box centers from the SAME Cb/Cr transform as the plotted data
    /// (not hand-placed), so 75% bars must land in their boxes.
    static let targets: [(name: String, r: Float, g: Float, b: Float)] = [
        ("R",  191,   0,   0),
        ("Yl", 191, 191,   0),
        ("G",    0, 191,   0),
        ("Cy",   0, 191, 191),
        ("B",    0,   0, 191),
        ("Mg", 191,   0, 191)
    ]

    /// Rec.709 normalized chroma (matches Resolve's 709 vectorscope). Used by BOTH
    /// the per-pixel plot and the target-box derivation, so they are guaranteed
    /// consistent. Cb,Cr ≈ [-128,127] for 0–255 input.
    @inline(__always)
    static func chroma(r: Float, g: Float, b: Float) -> (cb: Float, cr: Float) {
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let cb = (b - y) / 1.8556
        let cr = (r - y) / 1.5748
        return (cb, cr)
    }

    private var timer: Timer?
    private let workQueue = DispatchQueue(label: "com.graviton.manifold.scope.vector",
                                          qos: .userInitiated)
    private var sampling = false
    private var readbackTexture: MTLTexture?

    private let updateHz = 24.0
    private let rowStride = 2

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / updateHz, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        image = nil
    }

    private func tick() {
        guard !sampling, let renderer else { return }
        sampling = true
        let issued = renderer.readbackRenderedFrameAsync(into: &readbackTexture) { [weak self] bytes, w, h, bpr in
            guard let self else { return }
            self.workQueue.async {
                let img = self.computeVectorscope(bytes: bytes, width: w, height: h, bytesPerRow: bpr)
                DispatchQueue.main.async {
                    if let img { self.image = img }
                    self.sampling = false
                }
            }
        }
        if !issued { sampling = false }
    }

    /// Plot each sampled pixel's chroma into the plane buffer; log-normalize; emit a
    /// white-on-black trace image. BGRA byte order; bytesPerRow; rowStride subsampling.
    private func computeVectorscope(bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let plane = Self.plane
        let center = Float(plane) * 0.5
        let s = Self.chromaScaleFrac * Float(plane)   // chroma units -> plane pixels

        var accum = [UInt32](repeating: 0, count: plane * plane)

        bytes.withUnsafeBufferPointer { buf in
            for y in stride(from: 0, to: height, by: rowStride) {
                let rowBase = y * bytesPerRow
                for x in 0..<width {
                    let p = rowBase + x * 4
                    let (cb, cr) = Self.chroma(r: Float(buf[p + 2]),
                                               g: Float(buf[p + 1]),
                                               b: Float(buf[p + 0]))
                    let px = Int(center + cb * s + 0.5)
                    let py = Int(center - cr * s + 0.5)   // Cr up (Y flip)
                    if px >= 0, px < plane, py >= 0, py < plane {
                        accum[py * plane + px] &+= 1
                    }
                }
            }
        }

        var maxCount: UInt32 = 1
        for c in accum where c > maxCount { maxCount = c }
        let denom = log(1.0 + Float(maxCount))

        var pixels = [UInt8](repeating: 0, count: plane * plane * 4)
        for i in 0..<(plane * plane) {
            let c = accum[i]
            let v: UInt8 = c == 0 ? 0 : UInt8(min(255.0, 255.0 * log(1.0 + Float(c)) / denom))
            let o = i * 4
            pixels[o + 0] = v; pixels[o + 1] = v; pixels[o + 2] = v; pixels[o + 3] = 255   // white trace
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: plane, height: plane,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: plane * 4,
                       space: cs, bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Floating square vectorscope panel: trace image + circular graticule with the six
/// derived target boxes. Header "VECTORSCOPE · 709".
struct VectorscopeScopeView: View {
    @ObservedObject var model: VectorscopeScopeModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("VECTORSCOPE · 709")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)

            ZStack {
                Color.black
                if let img = model.image {
                    Image(decorative: img, scale: 1.0)
                        .resizable()
                        .interpolation(.none)
                }
                graticule
            }
            .aspectRatio(1, contentMode: .fit)   // stay square, fit available space
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15)))
    }

    private var graticule: some View {
        Canvas { ctx, size in
            let cx = size.width * 0.5
            let cy = size.height * 0.5
            let frac = CGFloat(VectorscopeScopeModel.chromaScaleFrac)

            // Outer chroma boundary circle (subtle). Sized to enclose the 100% targets.
            let circleR = size.width * 0.46
            let circleRect = CGRect(x: cx - circleR, y: cy - circleR,
                                    width: circleR * 2, height: circleR * 2)
            ctx.stroke(Path(ellipseIn: circleRect), with: .color(.white.opacity(0.14)), lineWidth: 0.5)

            // Faint center crosshair.
            var cross = Path()
            cross.move(to: CGPoint(x: cx - 6, y: cy)); cross.addLine(to: CGPoint(x: cx + 6, y: cy))
            cross.move(to: CGPoint(x: cx, y: cy - 6)); cross.addLine(to: CGPoint(x: cx, y: cy + 6))
            ctx.stroke(cross, with: .color(.white.opacity(0.2)), lineWidth: 0.5)

            // Six target boxes — derived from the SAME chroma transform as the data.
            let box: CGFloat = 9
            for t in VectorscopeScopeModel.targets {
                let (cb, cr) = VectorscopeScopeModel.chroma(r: t.r, g: t.g, b: t.b)
                let bxCenterX = cx + CGFloat(cb) * frac * size.width
                let bxCenterY = cy - CGFloat(cr) * frac * size.height   // Cr up
                let rect = CGRect(x: bxCenterX - box / 2, y: bxCenterY - box / 2,
                                  width: box, height: box)
                ctx.stroke(Path(rect), with: .color(.white.opacity(0.5)), lineWidth: 0.75)
                ctx.draw(
                    Text(t.name).font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.white.opacity(0.55)),
                    at: CGPoint(x: bxCenterX, y: bxCenterY - box), anchor: .center
                )
            }
        }
    }
}
