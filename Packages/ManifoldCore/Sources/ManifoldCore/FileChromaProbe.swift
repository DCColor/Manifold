import Foundation
import CoreMedia
import CFFmpeg
import ColorimetryModel
import FileChroma

/// The app's DEBUG chroma switch, pushed in at launch.
///
/// ⚠️ **PUSHED IN FROM THE APP LAYER, BECAUSE CORE CANNOT GATE IT.** `MANIFOLD_FORCE_CHROMA_420` is
/// DEBUG-only, and this package cannot see the app's DEBUG under Profile (the note on
/// `.define("MANIFOLD_TELEMETRY")` in Package.swift). So the app, which can, sets it once at launch
/// from `MetalVideoRenderer.forceChroma420`, always false in Release. Same shape as
/// `ProVideoDecoderAvailability`.
public enum FileChromaPolicy {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var force = false
    nonisolated(unsafe) private static var reason = ""

    public static func set(force420: Bool, reason: String) {
        lock.lock(); force = force420; self.reason = reason; lock.unlock()
    }
    static var current: (force420: Bool, reason: String) {
        lock.lock(); defer { lock.unlock() }; return (force, reason)
    }
}

/// THE one place a file's chroma is decided (docs/COLOR_MANAGEMENT_FINDINGS.md §6.10, Stage 3b S2).
/// `FrameEngine` calls it once per load, before either decoder exists, and hands the answer to the
/// scrub producer and the playback source alike, so they decode the same format by construction.
enum FileChromaProbe {

    /// AVFoundation files: the codec type, and for H.264 / HEVC the SPS in `avcC` / `hvcC`.
    static func resolve(formatDescription fmt: CMFormatDescription) -> ResolvedChroma {
        var atoms: [String: [UInt8]] = [:]
        if let dict = CMFormatDescriptionGetExtension(
                fmt, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
                as? [String: Any] {
            for (key, value) in dict {
                if let data = value as? Data { atoms[key] = [UInt8](data) }
            }
        }
        let declared = FileChromaResolver.declared(codecType: CMFormatDescriptionGetMediaSubType(fmt),
                                                   atoms: atoms)
        let policy = FileChromaPolicy.current
        return FileChromaResolver.resolve(declared.source, basis: declared.basis,
                                          force420: policy.force420, forceReason: policy.reason)
    }

    /// libav files (DNx in `.mov`, every MXF): the first video stream's `pix_fmt`, through
    /// `LibavPixelConversion.declaredChroma`, the same rule the conversion applies to each frame.
    ///
    /// Opens the container once, on the caller's thread, and closes it. `avformat_find_stream_info`
    /// is what fills `pix_fmt` for DNx (the demuxer alone does not know it); it is the cost the scrub
    /// producer and the playback source each already pay, paid once more here so that both are told
    /// the answer instead of each working it out.
    static func resolveLibav(url: URL) -> ResolvedChroma {
        // Timed, because it runs on the caller's (main) actor like `LibavFrameSource.open()` does:
        // the load cost S2 adds, stated per file rather than assumed small.
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { print(String(format: "[CHROMA-FILE] libav probe %.1f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)) }
        var ctx: UnsafeMutablePointer<AVFormatContext>? = nil
        guard avformat_open_input(&ctx, url.path, nil, nil) == 0, ctx != nil else {
            return failed("libav could not open the file")
        }
        defer { avformat_close_input(&ctx) }
        guard avformat_find_stream_info(ctx, nil) >= 0 else { return failed("libav found no stream info") }
        for i in 0..<Int(ctx!.pointee.nb_streams) {
            guard let par = ctx!.pointee.streams[i]?.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_VIDEO else { continue }
            let pixFmt = AVPixelFormat(par.pointee.format)
            guard pixFmt != AV_PIX_FMT_NONE else { return failed("libav stated no pix_fmt") }
            let declared = LibavPixelConversion.declaredChroma(pixFmt: pixFmt)
            let policy = FileChromaPolicy.current
            return FileChromaResolver.resolve(declared.source, basis: declared.basis,
                                              force420: policy.force420, forceReason: policy.reason)
        }
        return failed("libav found no video stream")
    }

    private static func failed(_ basis: String) -> ResolvedChroma {
        FileChromaResolver.resolve(.unknown, basis: basis, force420: false, forceReason: "")
    }
}
