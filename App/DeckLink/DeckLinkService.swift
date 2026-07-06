import Foundation

/// App-side service for Blackmagic DeckLink OUTPUT. Hardware I/O lives in the App layer, decoupled
/// from ManifoldCore's engine logic. D1: enumerate output-capable devices via the Obj-C++ bridge
/// and report them — no frame output yet (that's D2). First stage of the BMD output arc
/// (D1 enumerate → D2 first frame → D3 scheduled playback → D4 A/V sync → D5 709 correctness).
final class DeckLinkService {

    /// A Swift-native snapshot of an output-capable device (mirrors DeckLinkDeviceInfo from the bridge).
    struct Device {
        let index: Int
        let modelName: String
        let displayName: String
    }

    static let shared = DeckLinkService()

    /// One bridge instance holds the output state across start/stop calls. Serial queue so
    /// start/stop can't race and never block the UI thread.
    private let bridge = DeckLinkBridge()
    private let queue = DispatchQueue(label: "com.graviton.manifold.decklink")

    /// The renderer that produces the real video frames (set by the App at startup). Weak — the
    /// renderer owns its lifecycle; the fill block sources 2vuy frames from it.
    weak var renderer: MetalVideoRenderer?

    /// D-real output frame size (matches the D3 fixed output mode, 2160p23.98). Real device/mode
    /// selection is a later stage; hardcoded here to match the bridge's fixed 3840x2160 output.
    private static let outputWidth = 3840
    private static let outputHeight = 2160

    /// Enumerate output-capable DeckLink devices. Synchronous SDK walk; returns [] if the driver
    /// isn't reachable or no card is present.
    func outputDevices() -> [Device] {
        DeckLinkBridge.enumerateOutputDevices().map {
            Device(index: $0.index, modelName: $0.modelName, displayName: $0.displayName)
        }
    }

    /// D-real: start CONTINUOUS scheduled playback of REAL video — each output frame is filled from
    /// the renderer's latest converted 2vuy staging buffer (push-on-render / pull-latest). Requires
    /// a file loaded + rendering (offscreen populated); until the first frame is ready, the fill
    /// falls back to neutral legal black. Logs each setup step + the callback completion summaries.
    func startScheduledOutput() {
        queue.async {
            // Arm the renderer's push convert (allocate 2vuy staging sized to the output frame).
            self.renderer?.beginDeckLinkOutput(width: Self.outputWidth, height: Self.outputHeight)

            // The fill block runs on the SDK callback thread → cheap: a memcpy from the renderer's
            // front staging buffer, or a neutral fallback if no converted frame is ready yet.
            let fill: DeckLinkFillBlock = { [weak self] _, buffer, rowBytes, width, height in
                if let r = self?.renderer,
                   r.copyLatestDeckLinkFrame(into: UnsafeMutableRawPointer(buffer),
                                             rowBytes: Int(rowBytes), width: Int(width), height: Int(height)) {
                    return true
                }
                Self.fillNeutral2vuy(buffer, rowBytes: Int(rowBytes), width: Int(width), height: Int(height))
                return false
            }

            let result = self.bridge.startScheduledPlaybackOnDevice0(fill: fill)
            for line in result.log { print("DeckLink D-real: \(line)") }
            print("DeckLink D-real: \(result.success ? "SUCCESS — real-video scheduled playback on device 0" : "FAILED")")
        }
    }

    /// Stop scheduled playback cleanly + disarm the renderer's push convert.
    func stopScheduledOutput() {
        queue.async {
            self.bridge.stopScheduledPlayback()
            self.renderer?.stopDeckLinkOutput()
            print("DeckLink D-real: output stopped")
        }
    }

    /// Neutral legal-black 2vuy fill ([Cb=128, Y=16, Cr=128, Y=16] per pair) — shown until the first
    /// real converted frame is ready, so the card never gets garbage.
    private static func fillNeutral2vuy(_ buffer: UnsafeMutablePointer<UInt8>, rowBytes: Int, width: Int, height: Int) {
        for y in 0..<height {
            let row = buffer.advanced(by: y * rowBytes)
            var x = 0
            while x < width {
                let o = (x / 2) * 4
                row[o + 0] = 128; row[o + 1] = 16; row[o + 2] = 128; row[o + 3] = 16
                x += 2
            }
        }
    }

    /// D1 probe: log the connected output devices once at startup. Runs off the main thread so a
    /// slow driver query never delays launch.
    func logDevicesAtStartup() {
        DispatchQueue.global(qos: .utility).async {
            let devices = self.outputDevices()
            if devices.isEmpty {
                print("DeckLink: found 0 output device(s) (no card / driver not reachable)")
            } else {
                let list = devices
                    .map { "\($0.modelName) (\($0.displayName))" }
                    .joined(separator: ", ")
                print("DeckLink: found \(devices.count) output device(s): \(list)")
            }
        }
    }
}
