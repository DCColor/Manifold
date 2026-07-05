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

    /// One bridge instance holds the D2 output state (enabled output + displayed frame) across the
    /// start/stop calls. Serial queue so start/stop can't race and never block the UI thread.
    private let bridge = DeckLinkBridge()
    private let queue = DispatchQueue(label: "com.graviton.manifold.decklink")

    /// Enumerate output-capable DeckLink devices. Synchronous SDK walk; returns [] if the driver
    /// isn't reachable or no card is present.
    func outputDevices() -> [Device] {
        DeckLinkBridge.enumerateOutputDevices().map {
            Device(index: $0.index, modelName: $0.modelName, displayName: $0.displayName)
        }
    }

    /// D3 "scheduled playback": start CONTINUOUS free-running synthetic output on device 0 (a
    /// per-frame hue walk) driven by the card's clock via the completion callback. Logs each setup
    /// step; the callback thread then logs completion-result summaries until stopped.
    func startScheduledOutput() {
        queue.async {
            let result = self.bridge.startScheduledPlaybackOnDevice0()
            for line in result.log { print("DeckLink D3: \(line)") }
            print("DeckLink D3: \(result.success ? "SUCCESS — free-running scheduled playback on device 0" : "FAILED")")
        }
    }

    /// Stop D3 scheduled playback cleanly.
    func stopScheduledOutput() {
        queue.async {
            self.bridge.stopScheduledPlayback()
            print("DeckLink D3: output stopped")
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
