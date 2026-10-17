import Foundation
import CFFmpeg
import ContainerRepair

/// What the engine does with a `.mov` / `.mp4` that AVFoundation opened but exposes no video track for.
/// docs/BUGS.md, *A video `stsd` longer than its entries hides the video track*.
///
/// ── ⚠️ ONLY EVER ASKED AFTER AVFOUNDATION HAS REPORTED NO VIDEO TRACK ───────────────────────────
///
/// `FrameEngine.loadAsset` calls `vet` from inside the branch where `loadTracks(withMediaType: .video)`
/// came back empty, and from nowhere else. A file AVFoundation can play never reaches the box scanner,
/// never logs a `[CONTAINER]` line and never takes this route. Detection is by box structure alone:
/// no codec, vendor, camera or encoder is consulted.
///
/// ── THE ROUTE ────────────────────────────────────────────────────────────────────────────────────
///
/// A video `stsd` with any bytes past its entries (`SampleDescriptionSlackPolicy`) goes to the libav path,
/// which reads past the slack, with ProRes decoded by VideoToolbox (`ProResVideoToolboxDecoder`). Nothing
/// is written to disk.
/// MEASURED on the two ARRI clips that prompted it: every frame byte-identical to a stream-copy remux
/// decoded by AVFoundation, at playback pace and slower; scrub 0.8–1.2 ms median.
enum ContainerSlackRoute {

    /// The containers the scanner understands. Anything else that AVFoundation shows no video for (an
    /// R3D, an AVI) keeps the engine's existing refusal and never reaches the scanner.
    static let extensions: Set<String> = ["mov", "mp4", "m4v", "qt"]

    /// The non-blocking notice raised when the route is taken.
    static let notice = "This file’s container has a sample-description size error; Manifold is reading around it."

    enum Decision {
        /// Read this file through libav. `sampleEntry` is the video sample entry's fourCC as libav read it
        /// (0 when it reports none), so the inspector can name the codec as it would for any `.mov`.
        case route(slacks: [VideoSampleDescriptionSlack], codec: String, sampleEntry: FourCharCode)
        /// Refuse, with this banner.
        case refuse(notice: String)
        /// Not a container this decides about: the engine's own refusal applies.
        case notApplicable
    }

    /// Box scan, policy and a libav open check, in that order. Reads only; runs off the main actor.
    static func vet(url: URL) -> Decision {
        guard extensions.contains(url.pathExtension.lowercased()) else { return .notApplicable }
        let name = url.lastPathComponent
        let finding = SampleDescriptionSlackScanner.scan(url: url)
        NSLog("[CONTAINER] %@: AVFoundation exposes no video track; box scan: %@", name, describe(finding))

        switch finding {
        case .slack(let slacks):
            let least = slacks.map(\.slackBytes).min() ?? 0
            // Every slack is routed today (minimum 1); the refusal stays so the floor can move without
            // leaving a slack file with no banner.
            guard SampleDescriptionSlackPolicy.routes(finding) else {
                NSLog("[CONTAINER] %@: %llu byte%@ of slack, under the %llu routed — refusing",
                      name, least, least == 1 ? "" : "s", SampleDescriptionSlackPolicy.minimumRoutedSlack)
                return .refuse(notice: "This file couldn’t be opened — its video sample-description table is "
                    + "\(least) byte\(least == 1 ? "" : "s") longer than its entries, a container error macOS "
                    + "won’t read past. Remuxing it (for example ffmpeg -c copy) fixes it.")
            }
            guard let (codec, sampleEntry) = libavDecodableVideo(url: url) else {
                NSLog("[CONTAINER] %@: libav cannot open and decode the video stream — refusing", name)
                return .refuse(notice: "This file couldn’t be opened — its video sample-description table is "
                    + "longer than its entries, a container error macOS won’t read past, and Manifold can’t "
                    + "read the video another way. Remuxing it (for example ffmpeg -c copy) fixes it.")
            }
            NSLog("[CONTAINER] %@: reading the video through libav (%@) — the file is not modified. This deviates "
                + "from the container standard: the stsd box is longer than its entries.", name, codec)
            return .route(slacks: slacks, codec: codec, sampleEntry: sampleEntry)
        case .malformed(let why):
            return .refuse(notice: "This file couldn’t be opened — its container is malformed (\(why)). "
                + "Remuxing it (for example ffmpeg -c copy) may fix it.")
        case .consistent:
            return .refuse(notice: "This file couldn’t be opened — macOS can’t read its video track, though "
                + "the container declares one. Remuxing it (for example ffmpeg -c copy) may fix it.")
        case .noVideoTrack:
            return .refuse(notice: "This file couldn’t be opened — it has no video track.")
        case .noMovieBox:
            return .refuse(notice: "This file couldn’t be opened — it has no movie header, so it may be "
                + "incomplete or still being written.")
        }
    }

    static func describe(_ f: SampleDescriptionFinding) -> String {
        switch f {
        case .noMovieBox: return "no movie box"
        case .noVideoTrack: return "no video track declared"
        case .consistent: return "video sample descriptions consistent"
        case .malformed(let why): return "malformed (\(why))"
        case .slack(let s):
            return s.map { "video stsd at \($0.stsdOffset) declares \($0.declaredSize) bytes, its entries "
                + "account for \($0.accountedSize) (\($0.slackBytes) byte\($0.slackBytes == 1 ? "" : "s") of slack)" }.joined(separator: "; ")
        }
    }

    /// The video stream's codec name and sample-entry fourCC when libav can open the file and has a decoder
    /// for it; nil otherwise. The same two calls `LibavFrameSource.open()` makes first, so a file that passes
    /// here opens there.
    private static func libavDecodableVideo(url: URL) -> (String, FourCharCode)? {
        var ctx: UnsafeMutablePointer<AVFormatContext>? = nil
        guard avformat_open_input(&ctx, url.path, nil, nil) == 0, let c = ctx else { return nil }
        defer { avformat_close_input(&ctx) }
        guard avformat_find_stream_info(c, nil) >= 0 else { return nil }
        for i in 0..<Int(c.pointee.nb_streams) {
            guard let par = c.pointee.streams[i]?.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_VIDEO else { continue }
            guard avcodec_find_decoder(par.pointee.codec_id) != nil else { return nil }
            // libav stores the `.mov` fourCC little-endian (MKTAG).
            return (String(cString: avcodec_get_name(par.pointee.codec_id)),
                    FourCharCode(par.pointee.codec_tag).byteSwapped)
        }
        return nil
    }
}
