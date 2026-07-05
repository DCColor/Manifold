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

    /// D2 "first light": push one synthetic solid-color frame out device 0 and hold it on the
    /// monitor. Logs each step so a failure is diagnosable at the exact point.
    func startTestFrameOutput() {
        queue.async {
            let result = self.bridge.startTestFrameOutputOnDevice0()
            for line in result.log { print("DeckLink D2: \(line)") }
            print("DeckLink D2: \(result.success ? "SUCCESS — synthetic frame held on device 0 output" : "FAILED")")
        }
    }

    /// Turn the D2 test output off (disable output, release the held frame).
    func stopTestOutput() {
        queue.async {
            self.bridge.stopTestOutput()
            print("DeckLink D2: output stopped")
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
