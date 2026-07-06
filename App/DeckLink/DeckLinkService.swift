import Foundation
import Combine

/// App-side service for Blackmagic DeckLink OUTPUT. Hardware I/O lives in the App layer, decoupled
/// from ManifoldCore's engine logic. Owns the output on/off state + selected device as observable
/// so the toolbar control and the ⌃⌥O/⌃⌥⇧O shortcuts share one source of truth.
/// BMD output arc: D1 enumerate → D2 first frame → D3 scheduled playback → D-real real video → D5 709.
final class DeckLinkService: ObservableObject {

    /// A Swift-native snapshot of an output-capable device (mirrors DeckLinkDeviceInfo from the bridge).
    struct Device {
        let index: Int
        let modelName: String
        let displayName: String
    }

    static let shared = DeckLinkService()

    /// @AppStorage key for the "Enable output on launch" preference (Settings → DeckLink Output).
    /// Explicit opt-in default behavior — NOT last-session persistence. Default false. Shared with
    /// SettingsView so the key can't drift.
    static let enableOnLaunchKey = "manifold.decklink.enableOnLaunch"

    /// Plain-speak output signal (format part). NO codec/"v210" jargon. The colorspace is appended
    /// separately via `signalLine` (it varies per source, unlike the fixed format).
    static let statusLine = "2160p23.98 · 10-bit 4:2:2"

    // Observable UI state (mutated on main).
    @Published private(set) var isOutputting = false     // reflects the ACTUAL scheduled-playback state
    @Published private(set) var selectedDeviceIndex = 0  // which enumerated device output targets
    @Published private(set) var devices: [Device] = []   // cached enumeration for the picker
    /// Plain-speak colorspace label for the current source (DISPLAY ONLY — the actual output tag is
    /// unchanged: D5 tags both 2020 and P3 as Rec.2020). Derived from the source colorPrimariesCode,
    /// so it can distinguish genuine 2020 from P3-in-2020 (which the collapsed tag cannot). nil → 709.
    @Published private(set) var colorspaceLabel = "Rec 709"

    /// The full Signal line for the output menu: fixed format + the current-source colorspace label.
    var signalLine: String { "\(Self.statusLine) · \(colorspaceLabel)" }

    /// Map a source CICP primaries code → plain-speak label. "(P3 limited)" flags P3 content sitting
    /// inside the Rec.2020 container (what's actually on the wire is Rec.2020, per D5's tag).
    static func colorspaceLabel(forPrimaries code: Int?) -> String {
        switch code {
        case 9:       return "Rec 2020"              // genuine Rec.2020
        case 11, 12:  return "Rec 2020 (P3 limited)" // DCI-P3 / P3-D65 → P3-in-2020
        default:      return "Rec 709"               // 1 / nil / 2 (unspecified) / unknown
        }
    }

    /// One bridge instance holds the output state across start/stop calls. Serial queue so
    /// start/stop can't race and never block the UI thread.
    private let bridge = DeckLinkBridge()
    private let queue = DispatchQueue(label: "com.graviton.manifold.decklink")

    /// The renderer that produces the real video frames (set by the App at startup). Weak — the
    /// renderer owns its lifecycle; the fill block sources v210 frames from it.
    weak var renderer: MetalVideoRenderer?

    /// D-real output frame size (matches the D3 fixed output mode, 2160p23.98). Real mode selection
    /// is a later stage; hardcoded to match the bridge's fixed 3840x2160 output.
    private static let outputWidth = 3840
    private static let outputHeight = 2160

    /// Enumerate output-capable DeckLink devices. Synchronous SDK walk; returns [] if the driver
    /// isn't reachable or no card is present.
    func outputDevices() -> [Device] {
        DeckLinkBridge.enumerateOutputDevices().map {
            Device(index: $0.index, modelName: $0.modelName, displayName: $0.displayName)
        }
    }

    /// Refresh the cached device list for the picker (call at startup / when the menu opens). Clamps
    /// the selection if the list shrank. Publishes on main.
    func refreshDevices() {
        let ds = outputDevices()
        DispatchQueue.main.async {
            self.devices = ds
            if self.selectedDeviceIndex >= ds.count { self.selectedDeviceIndex = 0 }
        }
    }

    private var hasAutoStarted = false   // one-shot guard so launch auto-start fires at most once

    /// Launch behavior for the "Enable output on launch" preference. Fires at most once per launch.
    /// Guard sequence: pref TRUE → a capable device is PRESENT (enumeration non-empty) → start via
    /// the normal path (device 0 by default, which does 2160p; a non-capable pick reverts on failure
    /// via the existing revert-on-failure). NEVER auto-starts when the pref is off, and never into
    /// absent hardware. No file required — if none is loaded yet, the neutral-black fallback shows
    /// until frames arrive (the same behavior as a manual start before loading).
    func autoStartOnLaunchIfEnabled() {
        guard !hasAutoStarted else { return }
        hasAutoStarted = true
        guard UserDefaults.standard.bool(forKey: Self.enableOnLaunchKey) else { return }   // pref off → nothing
        guard !outputDevices().isEmpty else {                                               // no hardware → skip
            print("DeckLink: enable-on-launch is on but no output device is present — skipping")
            return
        }
        print("DeckLink: enable-on-launch — starting output on device \(selectedDeviceIndex)")
        startScheduledOutput()   // revert-on-failure handles a present-but-incapable device gracefully
    }

    // MARK: - Shared action path (button, chevron device-switch, and ⌃⌥O/⌃⌥⇧O all route here)

    /// Toggle output on/off — the primary action shared by the toolbar button and ⌃⌥O.
    func toggleOutput() {
        if isOutputting { stopScheduledOutput() } else { startScheduledOutput() }
    }

    /// Pick the output device. If output is ON, cleanly stop and restart on the new device (the
    /// serial queue guarantees stop completes before the restart). No-op if unchanged.
    func selectDevice(_ index: Int) {
        guard index != selectedDeviceIndex else { return }
        let wasOn = isOutputting
        if wasOn { stopScheduledOutput() }
        selectedDeviceIndex = index
        if wasOn { startScheduledOutput() }
    }

    /// Start CONTINUOUS scheduled playback of REAL video on the selected device — each output frame
    /// is filled from the renderer's latest converted v210 staging buffer (push-on-render /
    /// pull-latest). Requires a file rendering; until the first frame is ready the fill shows neutral
    /// black. `isOutputting` flips true optimistically and reverts if the bridge start fails.
    func startScheduledOutput() {
        guard !isOutputting else { return }
        isOutputting = true
        let deviceIndex = selectedDeviceIndex
        // D5 output-signal TAG ← source PRIMARIES code ONLY (never the matrix; the kernel picks the
        // encoding matrix from the matrix code, independently). nil → 709.
        let primariesCode = renderer?.sourcePrimariesCode ?? 1
        queue.async {
            // Arm the renderer's push convert (allocate v210 staging sized to the output frame).
            self.renderer?.beginDeckLinkOutput(width: Self.outputWidth, height: Self.outputHeight)

            // The fill block runs on the SDK callback thread → cheap: a memcpy from the renderer's
            // front staging buffer, or a neutral fallback if no converted frame is ready yet.
            let fill: DeckLinkFillBlock = { [weak self] _, buffer, rowBytes, width, height in
                if let r = self?.renderer,
                   r.copyLatestDeckLinkFrame(into: UnsafeMutableRawPointer(buffer),
                                             rowBytes: Int(rowBytes), width: Int(width), height: Int(height)) {
                    return true
                }
                Self.fillNeutralV210(buffer, rowBytes: Int(rowBytes), width: Int(width), height: Int(height))
                return false
            }

            let result = self.bridge.startScheduledPlayback(withDeviceIndex: deviceIndex, fill: fill,
                                                            primariesCode: primariesCode)
            for line in result.log { print("DeckLink D-real: \(line)") }
            print("DeckLink D-real: \(result.success ? "SUCCESS — real-video scheduled playback on device \(deviceIndex)" : "FAILED")")
            if !result.success {
                self.renderer?.stopDeckLinkOutput()
                DispatchQueue.main.async { self.isOutputting = false }   // keep the button honest
            }
        }
    }

    /// Stop scheduled playback cleanly + disarm the renderer's push convert (D3 race-safe stop).
    func stopScheduledOutput() {
        guard isOutputting else { return }
        isOutputting = false
        queue.async {
            self.bridge.stopScheduledPlayback()
            self.renderer?.stopDeckLinkOutput()
            print("DeckLink D-real: output stopped")
        }
    }

    /// The source color tags changed (new file / re-inspect). Updates the DISPLAY label always
    /// (independent of output state), and — if output is running — re-applies the colorspace TAG
    /// from the new primaries. Both read colorPrimariesCode ONLY (the encoding matrix follows the
    /// matrix code, separately). Call after setSourceColorSpace.
    func sourceColorChanged() {
        let primariesCode = renderer?.sourcePrimariesCode
        // Display label tracks the current source whether or not output is on (it's the signal that
        // output produces / would produce). DISPLAY ONLY — does not touch the actual tag.
        let label = Self.colorspaceLabel(forPrimaries: primariesCode)
        DispatchQueue.main.async { self.colorspaceLabel = label }
        // Re-tag the live output signal only if currently playing.
        guard isOutputting else { return }
        queue.async { self.bridge.setOutputColorspaceForPrimaries(primariesCode ?? 1) }
    }

    /// Neutral legal-black v210 fill (10-bit Y=64, Cb=Cr=512) — shown until the first real converted
    /// frame is ready, so the card never gets garbage. For solid black the four v210 words are a
    /// fixed pattern: w0=w2=0x20010200 (Cb|Y|Cr = 512|64|512), w1=w3=0x04080040 (Y|Cb|Y = 64|512|64),
    /// repeated per 6-pixel group (16 bytes), across the 128-byte-aligned rowBytes.
    private static func fillNeutralV210(_ buffer: UnsafeMutablePointer<UInt8>, rowBytes: Int, width: Int, height: Int) {
        let w0: UInt32 = 0x2001_0200   // Cb0(512) | Y0(64)<<10 | Cr0(512)<<20
        let w1: UInt32 = 0x0408_0040   // Y1(64)  | Cb2(512)<<10 | Y2(64)<<20
        let groupsPerRow = rowBytes / 16
        buffer.withMemoryRebound(to: UInt32.self, capacity: (rowBytes / 4) * height) { words in
            for y in 0..<height {
                var p = y * (rowBytes / 4)
                for _ in 0..<groupsPerRow {
                    words[p + 0] = w0; words[p + 1] = w1; words[p + 2] = w0; words[p + 3] = w1
                    p += 4
                }
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
