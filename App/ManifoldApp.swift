import SwiftUI
import ManifoldCore
import AVFoundation
import CoreVideo

@main
struct ManifoldApp: App {
    @StateObject private var engine = FrameEngine()

    // Stage 2a proof-of-link: prove the vendored static libav links + bridges in
    // the real build. TEMPORARY — remove once the DNxHR decode source lands.
    // Written to stderr (unbuffered) so it's visible immediately on launch.
    init() {
        FileHandle.standardError.write(Data("[FFmpegProbe] \(FFmpegProbe.summary())\n".utf8))
        // Stage 2b first-light headless check — decode+convert one DNxHR frame and
        // report the center RGB. TEMPORARY, remove with FFmpegProbe.
        let probePath = "/Volumes/DCCOLOR/TEST FLIP/CS Validation Manifold/RED75_709_HQ_Full_111_DNX_HXQ.mov"
        if FileManager.default.fileExists(atPath: probePath) {
            FileHandle.standardError.write(Data("[LibavFirstLight] \(LibavFrameSource.firstLightProbe(path: probePath))\n".utf8))
            FileHandle.standardError.write(Data("[LibavPerf] \(LibavFrameSource.perfProbe(path: probePath))\n".utf8))
        }
        // M3b: verify the AVFoundation path accepts x420 (10-bit) decode for 10-bit
        // ProRes AND 8-bit sources (8-bit must not regress). TEMPORARY. Fire-and-
        // forget — prints to stderr when each finishes (don't block init).
        for p in ["/Volumes/DCCOLOR/TEST FLIP/CS Validation Manifold/RED75_709_HQ_Full_111.mov",
                  "/Volumes/DCCOLOR/TEST FLIP/H264.mp4"] where FileManager.default.fileExists(atPath: p) {
            Task.detached {
                let r = await Self.avfX420Probe(path: p)
                FileHandle.standardError.write(Data("[AVFx420Probe] \(r)\n".utf8))
            }
        }
    }

    /// TEMPORARY M3b check: decode one frame via AVAssetReader requesting x420
    /// (10-bit) — exactly what FileFrameSource now does — and report the output
    /// buffer's format + center luma. Proves 10-bit ProRes and 8-bit sources both
    /// decode into the 10-bit contract without the reader failing.
    private static func avfX420Probe(path: String) async -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return "\(name): reader fail" }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
        guard reader.canAdd(out) else { return "\(name): x420 REJECTED by reader" }
        reader.add(out)
        guard reader.startReading() else { return "\(name): startReading fail \(String(describing: reader.error))" }
        guard let sb = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else {
            return "\(name): no sample (status \(reader.status.rawValue))"
        }
        let pf = CVPixelBufferGetPixelFormatType(pb)
        let fourCC = String(format: "%c%c%c%c", (pf >> 24) & 0xff, (pf >> 16) & 0xff, (pf >> 8) & 0xff, pf & 0xff)
        let is10 = (pf == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || pf == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        let W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var centerY = 0.0
        if is10 {
            let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt16.self)
            let s = CVPixelBufferGetBytesPerRowOfPlane(pb, 0) / 2
            centerY = Double(y[(H/2) * s + W/2]) / 64   // 10-bit code (high-aligned >>6)
        } else {
            let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
            let s = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            centerY = Double(y[(H/2) * s + W/2])
        }
        return "\(name): \(W)x\(H) outFmt='\(fourCC)' 10bit=\(is10) centerY=\(Int(centerY))"
    }

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine)
                .frame(minWidth: 720, minHeight: 460)
                .onOpenURL { url in
                    engine.load(url: url, autoplay: Preferences.shared.autoplayOnLoad)
                }
        }
        .windowStyle(.hiddenTitleBar)

        // The standard macOS Settings window (⌘,).
        Settings {
            SettingsView()
        }
    }
}
