import SwiftUI
import CoreGraphics
import Metal

/// Native RGB parade scope: three side-by-side waveform columns (R | G | B), each
/// plotting one channel's per-column value distribution. Pure consumer of
/// MetalVideoRenderer.readbackRenderedFrameAsync (the same non-blocking readback the
/// luma waveform uses) — it samples the PRE-DISPLAY offscreen texture (raw code
/// values), never screen pixels. Independent of the luma waveform: own gate, own
/// readback texture, so both can run at once without colliding.
final class ParadeScopeModel: ObservableObject {

    /// The composited three-column parade image (R|G|B), published to the view.
    @Published var image: CGImage?

    weak var renderer: MetalVideoRenderer?

    // Each channel column is columnWidth px; the full image is 3 columns wide.
    private let columnWidth = 192
    private let bins = 256   // 8-bit channel value bins

    private var timer: Timer?
    private let workQueue = DispatchQueue(label: "com.graviton.manifold.scope.parade",
                                          qos: .userInitiated)
    private var sampling = false                 // per-scope overlap gate
    private var readbackTexture: MTLTexture?     // this scope's own readback destination

    /// Perceptual-smoothness cap — independent of source frame rate (same as waveform).
    private let updateHz = 24.0

    /// Process every Nth source row (columns stay full-res). Same default as waveform.
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
        // NON-BLOCKING readback into this scope's OWN texture (independent of the
        // waveform's). Compute on workQueue, publish on main, clear the gate on main.
        let issued = renderer.readbackRenderedFrameAsync(into: &readbackTexture) { [weak self] bytes, w, h, bpr in
            guard let self else { return }
            self.workQueue.async {
                let img = self.computeParade(bytes: bytes, width: w, height: h, bytesPerRow: bpr)
                DispatchQueue.main.async {
                    if let img { self.image = img }
                    self.sampling = false
                }
            }
        }
        if !issued { sampling = false }
    }

    /// Build the three-column RGB parade as one composited green/red/blue-tinted
    /// RGBA image. Per-channel histograms (NO luma weighting); BGRA byte order;
    /// row stride subsampling; log normalization with a SHARED max across channels
    /// so inter-channel trace density stays comparable.
    private func computeParade(bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let colW = columnWidth
        let bins = self.bins

        var accR = [UInt32](repeating: 0, count: colW * bins)
        var accG = [UInt32](repeating: 0, count: colW * bins)
        var accB = [UInt32](repeating: 0, count: colW * bins)

        bytes.withUnsafeBufferPointer { buf in
            for y in stride(from: 0, to: height, by: rowStride) {
                let rowBase = y * bytesPerRow
                for x in 0..<width {
                    let p = rowBase + x * 4
                    let b = Int(buf[p + 0])
                    let g = Int(buf[p + 1])
                    let r = Int(buf[p + 2])
                    let bucket = (x * colW) / width
                    accR[((bins - 1) - r) * colW + bucket] &+= 1
                    accG[((bins - 1) - g) * colW + bucket] &+= 1
                    accB[((bins - 1) - b) * colW + bucket] &+= 1
                }
            }
        }

        // Shared max across all three channels -> comparable brightness scaling.
        var maxCount: UInt32 = 1
        for c in accR where c > maxCount { maxCount = c }
        for c in accG where c > maxCount { maxCount = c }
        for c in accB where c > maxCount { maxCount = c }
        let denom = log(1.0 + Float(maxCount))
        func intensity(_ c: UInt32) -> UInt8 {
            c == 0 ? 0 : UInt8(min(255.0, 255.0 * log(1.0 + Float(c)) / denom))
        }

        // Composite: column 0 = R (red trace), 1 = G (green), 2 = B (blue).
        let totalW = colW * 3
        var pixels = [UInt8](repeating: 0, count: totalW * bins * 4)
        for row in 0..<bins {
            let rowOut = row * totalW
            for bx in 0..<colW {
                let vR = intensity(accR[row * colW + bx])
                let vG = intensity(accG[row * colW + bx])
                let vB = intensity(accB[row * colW + bx])

                var o = (rowOut + (0 * colW + bx)) * 4   // R column
                pixels[o + 0] = vR; pixels[o + 1] = 0; pixels[o + 2] = 0; pixels[o + 3] = 255

                o = (rowOut + (1 * colW + bx)) * 4       // G column
                pixels[o + 0] = 0; pixels[o + 1] = vG; pixels[o + 2] = 0; pixels[o + 3] = 255

                o = (rowOut + (2 * colW + bx)) * 4       // B column
                pixels[o + 0] = 0; pixels[o + 1] = 0; pixels[o + 2] = vB; pixels[o + 3] = 255
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: totalW, height: bins,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: totalW * 4,
                       space: cs, bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Floating RGB parade panel. Wider than tall to give three columns room. Shows the
/// composited trace plus a subtle 8-bit code-level graticule and R|G|B separators.
struct ParadeScopeView: View {
    @ObservedObject var model: ParadeScopeModel

    private let levels: [(label: String, value: Double)] = [
        ("255",        255),
        ("235 (100)",  235),
        ("128",        128),
        ("16 (0)",      16),
        ("0",            0)
    ]

    var body: some View {
        ZStack {
            Color.black
            if let img = model.image {
                Image(decorative: img, scale: 1.0)
                    .resizable()
                    .interpolation(.none)
            }
            graticule
            VStack {
                HStack {
                    Text("PARADE · RGB (8-bit)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                }
                Spacer()
            }
            .padding(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15)))
    }

    private var graticule: some View {
        Canvas { ctx, size in
            // Horizontal code-level reference lines spanning all three columns.
            for (label, value) in levels {
                let y = size.height * (1.0 - value / 255.0)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(path, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
                ctx.draw(
                    Text(label).font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4)),
                    at: CGPoint(x: size.width - 4, y: y), anchor: .trailing
                )
            }
            // Thin R|G|B column separators at 1/3 and 2/3.
            for frac in [1.0 / 3.0, 2.0 / 3.0] {
                let x = size.width * frac
                var sep = Path()
                sep.move(to: CGPoint(x: x, y: 0))
                sep.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(sep, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
            }
        }
    }
}
