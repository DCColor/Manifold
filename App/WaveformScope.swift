import SwiftUI
import CoreGraphics

/// Native luma waveform scope. Pure consumer of MetalVideoRenderer.readbackRenderedFrame()
/// — it samples the PRE-DISPLAY offscreen texture (raw code values), never screen pixels,
/// so it agrees with a Resolve waveform on the same frame. Sampling is throttled here
/// (the renderer's readback stays per-call/full-res for ⌃⌥E export).
final class WaveformScopeModel: ObservableObject {

    /// The computed waveform trace image (green-on-black), published to the view.
    @Published var image: CGImage?

    /// Set by the owner when the scope is shown. Weak — the renderer outlives nothing here.
    weak var renderer: MetalVideoRenderer?

    // Scope intensity buffer dimensions. Width = column buckets, height = luma bins (8-bit).
    private let scopeWidth = 512
    private let lumaBins = 256

    private var timer: Timer?
    private let workQueue = DispatchQueue(label: "com.graviton.manifold.scope.waveform",
                                          qos: .userInitiated)
    private var sampling = false   // gate: skip a tick if the prior compute is still running
    private var readbackTexture: MTLTexture?   // this scope's own readback destination

    /// Perceptual-smoothness cap, NOT a framerate sync — independent of the source
    /// frame rate (a 24 fps and a 60 fps clip both update the scope at this rate).
    /// The overlap gate drops ticks if compute can't keep up; it never slows playback.
    private let updateHz = 24.0

    /// Process every Nth source row in the luma compute (columns stay full-res).
    /// 1 = every row (most accurate), 2 = default, 4 = cheapest. A waveform is a
    /// per-column luma distribution, so halving rows is visually equivalent at ~half cost.
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
        // Throttle gate + renderer presence. The gate is touched only on the main
        // thread (set here; cleared in the async completion's main hop below).
        guard !sampling, let renderer else { return }
        sampling = true

        // NON-BLOCKING readback: issue the GPU->CPU copy and return immediately.
        // The completion fires off the render thread once the GPU is done; we then
        // compute on workQueue and publish on main. This avoids the waitUntilCompleted
        // stall that landed the scope 2-3 presented frames late.
        let issued = renderer.readbackRenderedFrameAsync(into: &readbackTexture) { [weak self] bytes, w, h, bpr in
            // Called on Metal's completion thread (background). Hop to workQueue for
            // the heavy luma compute, then publish + clear the gate on main.
            guard let self else { return }
            self.workQueue.async {
                let img = self.computeWaveform(bytes: bytes, width: w, height: h, bytesPerRow: bpr)
                DispatchQueue.main.async {
                    if let img { self.image = img }
                    self.sampling = false   // gate held from issue until compute published
                }
            }
        }
        // If no readback was issued (no frame yet / setup failed), the completion
        // will never fire — release the gate so the next tick can try again.
        if !issued { sampling = false }
    }

    /// Build the luma waveform as a green-on-black RGBA CGImage.
    /// BGRA byte order (bytes B,G,R,A); row stride uses bytesPerRow, not width*4.
    private func computeWaveform(bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let scopeW = scopeWidth
        let bins = lumaBins

        // 2D histogram: [bin * scopeW + bucket] = pixel count.
        var accum = [UInt32](repeating: 0, count: scopeW * bins)

        bytes.withUnsafeBufferPointer { buf in
            // Row-subsampled (every rowStride-th row); columns stay full-res so
            // ramps/edges remain crisp.
            for y in stride(from: 0, to: height, by: rowStride) {
                let rowBase = y * bytesPerRow
                for x in 0..<width {
                    let p = rowBase + x * 4
                    let b = Float(buf[p + 0])
                    let g = Float(buf[p + 1])
                    let r = Float(buf[p + 2])
                    // Rec.709 luma on display-RGB 0-255 values.
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let lv = min(255, max(0, Int(luma + 0.5)))
                    let bucket = (x * scopeW) / width          // source column -> scope bucket
                    let row = (bins - 1) - lv                  // luma 255 at top
                    accum[row * scopeW + bucket] &+= 1
                }
            }
        }

        // Per-frame log normalization: faint traces stay visible, dense ones don't blow out.
        var maxCount: UInt32 = 1
        for c in accum where c > maxCount { maxCount = c }
        let denom = log(1.0 + Float(maxCount))

        var pixels = [UInt8](repeating: 0, count: scopeW * bins * 4)
        for i in 0..<(scopeW * bins) {
            let c = accum[i]
            let v: UInt8 = c == 0 ? 0
                : UInt8(min(255.0, 255.0 * log(1.0 + Float(c)) / denom))
            let o = i * 4
            pixels[o + 0] = 0      // R
            pixels[o + 1] = v      // G — green trace
            pixels[o + 2] = 0      // B
            pixels[o + 3] = 255    // A
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: scopeW, height: bins,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: scopeW * 4,
                       space: cs, bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Floating waveform panel. Fixed size for v1. Shows the trace image plus a subtle
/// 8-bit code-level graticule.
struct WaveformScopeView: View {
    @ObservedObject var model: WaveformScopeModel

    // 8-bit reference code levels (with IRE sense in the label where meaningful).
    private let levels: [(label: String, value: Double)] = [
        ("255",        255),
        ("235 (100)",  235),   // video white ≈ 100 IRE
        ("128",        128),
        ("16 (0)",      16),   // video black ≈ 0 IRE
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
                    Text("WAVEFORM · luma (8-bit)")
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
        }
    }
}
