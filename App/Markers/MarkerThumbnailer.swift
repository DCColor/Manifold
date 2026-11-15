//
//  MarkerThumbnailer.swift — a small picture of each marker's frame (docs/MARKERS_PLAN.md §4.4, Robbie 2026-11-15).
//
//  WHERE THE PICTURE COMES FROM. The file, at the marker's frame, decoded by a decoder of its OWN
//  (`FrameEngine.makeFrameProducer`: the same route and pixel format as scrub, a separate instance, so its seeks never
//  disturb scrub or playback). The frame is drawn by Core Image from its own colour tags, HDR tone-mapped to SDR, into
//  sRGB: the picture, not the display transform. ⚠️ NOT BYTE-FOR-BYTE EXPORT FRAME: Export Frame reads the renderer's
//  offscreen picture, which carries a tag override or interpretation LUT; a thumbnail does not (no off-main path renders
//  an arbitrary frame through the renderer). Pixel aspect and clean aperture are not applied either. It is a thumbnail.
//
//  NEVER BLOCKS PLAYBACK. One frame at a time, at utility priority, and nothing new is started while the file plays:
//  the queue waits for a pause. The JPEG is made off the main thread.
//
//  CACHED in memory and in Caches (`MarkerThumbnailCache`, by fingerprint and frame), cleared with the markers.
//  ⚠️ Pictures from the user's media: never logged.
//

import AppKit
import Combine
import CoreImage
import ManifoldCore
import Markers

@MainActor
final class MarkerThumbnailer: ObservableObject {
    /// Frame → thumbnail.
    @Published private(set) var images: [Int: NSImage] = [:]

    /// Pixel height of a thumbnail (2× a 54 pt row).
    nonisolated static let pixelHeight: CGFloat = 108

    private weak var engine: FrameEngine?
    private var fingerprint: String?
    private var rate: Double = 0
    private var wanted: Set<Int> = []
    private var failed: Set<Int> = []
    private var inFlight: Int?
    private var producer: ScrubFrameProducer?
    private var demand = 0
    private var token = UUID()
    private var playing: AnyCancellable?
    private let cache = MarkerThumbnailCache.standard()
    private static let work = DispatchQueue(label: "manifold.markers.thumbnails", qos: .utility)
    nonisolated private static let context = CIContext(options: [.cacheIntermediates: false])

    /// A new file (or none): everything about the previous one is dropped and its decoder closed.
    func reset(engine: FrameEngine?, fingerprint: String?) {
        token = UUID()
        producer?.close()
        producer = nil
        inFlight = nil
        images = [:]
        wanted = []
        failed = []
        self.fingerprint = fingerprint
        self.engine = engine
        playing = engine?.$isPlaying.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in MainActor.assumeIsolated { if !isPlaying { self?.pump() } } }
    }

    /// The markers changed: keep thumbnails for their frames only (memory and disk), and make the missing ones.
    func sync(frames: Set<Int>, rate: Double) {
        self.rate = rate
        wanted = frames
        images = images.filter { frames.contains($0.key) }
        failed.formIntersection(frames)
        if let fp = fingerprint { let c = cache; Self.work.async { c.keepOnly(frames, fingerprint: fp) } }
        pump()
    }

    /// A view showing thumbnails appeared (true) or went (false). Nothing is made while nobody shows them.
    func want(_ on: Bool) {
        demand = max(0, demand + (on ? 1 : -1))
        pump()
    }

    private func pump() {
        guard demand > 0, inFlight == nil, let fp = fingerprint, rate > 0, let engine, !engine.isPlaying,
              let frame = wanted.subtracting(images.keys).subtracting(failed).min() else { return }
        inFlight = frame
        let t = token, c = cache
        Self.work.async { [weak self] in
            guard self != nil else { return }
            let data = c.read(fingerprint: fp, frame: frame)
            let image = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, t == self.token else { return }
                    if let image { self.finish(frame, image) } else { self.decode(frame) }
                }
            }
        }
    }

    private func decode(_ frame: Int) {
        guard let engine, !engine.isPlaying else { inFlight = nil; return }
        if producer == nil { producer = engine.makeFrameProducer() }
        guard let producer else { failed.insert(frame); inFlight = nil; return }
        guard producer.isReady else {
            // Opening: try again when it is ready.
            inFlight = nil
            producer.onReadyChanged = { [weak self] in MainActor.assumeIsolated { self?.pump() } }
            return
        }
        let t = token, fp = fingerprint, c = cache
        // The quarter-frame landing every typed seek uses (TransportKeyMonitor.commit).
        producer.decode(at: (Double(frame) + 0.25) / rate) { [weak self] scrub in
            MainActor.assumeIsolated {
                guard let self, t == self.token else { return }
                // The ScrubFrame (Sendable) crosses to the work queue, not its bare CVPixelBuffer.
                guard let scrub else { self.failed.insert(frame); self.inFlight = nil; self.pump(); return }
                Self.work.async { [weak self] in
                    guard self != nil else { return }
                    let jpeg = Self.jpeg(from: scrub.pixelBuffer)
                    if let jpeg, let fp { c.write(jpeg, fingerprint: fp, frame: frame) }
                    let image = jpeg.flatMap { NSImage(data: $0) }
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, t == self.token else { return }
                            if let image { self.finish(frame, image) } else { self.failed.insert(frame); self.inFlight = nil; self.pump() }
                        }
                    }
                }
            }
        }
    }

    private func finish(_ frame: Int, _ image: NSImage) {
        if wanted.contains(frame) { images[frame] = image }
        inFlight = nil
        pump()
    }

    /// The frame under its own tags, HDR tone-mapped to SDR, scaled to `pixelHeight`, as an sRGB JPEG. Off main.
    nonisolated static func jpeg(from pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer, options: [.toneMapHDRtoSDR: true])
        guard image.extent.height > 0 else { return nil }
        let scale = pixelHeight / image.extent.height
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.jpegRepresentation(of: scaled, colorSpace: srgb,
                                          options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8])
    }
}
