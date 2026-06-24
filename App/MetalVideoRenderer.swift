import Foundation
import Metal
import CoreVideo
import CoreMedia
import QuartzCore

/// Renders decoded NV12 video frames to a CAMetalLayer, presentation-timed:
/// the tap enqueues frames (with PTS); a CVDisplayLink draws the frame matching
/// the current playback clock each display refresh. Engine-agnostic — it knows
/// nothing about FrameEngine, only a clock closure returning the current time.
final class MetalVideoRenderer {

    let metalLayer = CAMetalLayer()

    /// Returns the current playback time in seconds. Set by the owner before start().
    var clock: (() -> Double)?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache!

    // Frame queue: PTS (seconds) + pixel buffer, ordered by PTS. Guarded by lock.
    private struct QueuedFrame { let pts: Double; let pixelBuffer: CVPixelBuffer }
    private var frameQueue: [QueuedFrame] = []
    private let queueLock = NSLock()
    private let maxQueued = 12   // bounded buffer

    private var displayLink: CVDisplayLink?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("MetalVideoRenderer: no Metal device"); return nil
        }
        guard let queue = device.makeCommandQueue() else {
            print("MetalVideoRenderer: no command queue"); return nil
        }
        guard let library = device.makeDefaultLibrary() else {
            print("MetalVideoRenderer: no default library (shader not compiled in?)"); return nil
        }
        guard let vfn = library.makeFunction(name: "passthroughVertex"),
              let ffn = library.makeFunction(name: "passthroughFragment") else {
            print("MetalVideoRenderer: shader functions not found"); return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else {
            print("MetalVideoRenderer: pipeline creation failed"); return nil
        }

        self.device = device
        self.commandQueue = queue
        self.pipelineState = pipeline

        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true

        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard cacheStatus == kCVReturnSuccess else {
            print("MetalVideoRenderer: texture cache creation failed (\(cacheStatus))"); return nil
        }
    }

    deinit {
        stop()
    }

    // MARK: - Frame intake (called from the engine's tap, background queue)

    /// Enqueue a decoded frame for presentation-timed display.
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard pts.isFinite else { return }

        queueLock.lock()
        frameQueue.append(QueuedFrame(pts: pts, pixelBuffer: pixelBuffer))
        frameQueue.sort { $0.pts < $1.pts }
        // Bound the queue: drop the oldest if over capacity.
        if frameQueue.count > maxQueued {
            frameQueue.removeFirst(frameQueue.count - maxQueued)
        }
        queueLock.unlock()
    }

    /// Clear all queued frames (call on seek).
    func flush() {
        queueLock.lock()
        frameQueue.removeAll()
        queueLock.unlock()
    }

    // MARK: - Display link lifecycle

    func start() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { print("MetalVideoRenderer: CVDisplayLink create failed"); return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo in
            let renderer = Unmanaged<MetalVideoRenderer>.fromOpaque(userInfo!).takeUnretainedValue()
            renderer.displayTick()
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
        displayLink = link
    }

    func stop() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        flush()
    }

    // MARK: - Per-refresh presentation

    /// Called each display refresh (on the CVDisplayLink thread). Picks the
    /// newest frame whose PTS <= current playback time and renders it.
    private func displayTick() {
        guard let now = clock?() else { return }

        queueLock.lock()
        // Find the newest frame with pts <= now.
        var chosen: CVPixelBuffer?
        var dropCount = 0
        for (i, frame) in frameQueue.enumerated() {
            if frame.pts <= now {
                chosen = frame.pixelBuffer
                dropCount = i
            } else {
                break
            }
        }
        // Remove everything up to and including the chosen frame (consumed + stale).
        if chosen != nil, dropCount < frameQueue.count {
            frameQueue.removeFirst(dropCount + 1)
        }
        queueLock.unlock()

        if let pb = chosen {
            renderPixelBuffer(pb)
        }
    }

    // MARK: - Drawing

    private func renderPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard let lumaTexture = makeTexture(pixelBuffer, planeIndex: 0,
                                            pixelFormat: .r8Unorm,
                                            width: width, height: height),
              let chromaTexture = makeTexture(pixelBuffer, planeIndex: 1,
                                              pixelFormat: .rg8Unorm,
                                              width: width / 2, height: height / 2)
        else { return }

        if metalLayer.drawableSize != CGSize(width: width, height: height) {
            metalLayer.drawableSize = CGSize(width: width, height: height)
        }

        guard let drawable = metalLayer.nextDrawable() else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        passDesc.colorAttachments[0].storeAction = .store

        guard let cmdBuffer = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(lumaTexture, index: 0)
        encoder.setFragmentTexture(chromaTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }

    private func makeTexture(_ pixelBuffer: CVPixelBuffer, planeIndex: Int,
                             pixelFormat: MTLPixelFormat, width: Int, height: Int) -> MTLTexture? {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            pixelFormat, width, height, planeIndex, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return texture
    }
}
