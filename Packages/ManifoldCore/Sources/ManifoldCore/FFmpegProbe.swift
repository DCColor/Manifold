import CFFmpeg

/// Stage 2a proof-of-link: a trivial, harmless call into the vendored static
/// libav to prove the link + C bridge work end-to-end in the real Manifold build.
/// No decoding, no demuxing — just version strings. TEMPORARY; remove once the
/// real DNxHR decode source (Stage 2b) lands.
public enum FFmpegProbe {

    /// libav build version, e.g. "8.1.1" (from `av_version_info()`).
    public static func versionInfo() -> String {
        String(cString: av_version_info())
    }

    /// One-line summary across the linked libraries, proving each archive resolves:
    /// avformat / avcodec / avutil / swscale all answer their version macros.
    public static func summary() -> String {
        func v(_ packed: UInt32) -> String {
            "\((packed >> 16) & 0xff).\((packed >> 8) & 0xff).\(packed & 0xff)"
        }
        return "libav \(versionInfo()) — "
            + "avformat \(v(avformat_version())), "
            + "avcodec \(v(avcodec_version())), "
            + "avutil \(v(avutil_version())), "
            + "swscale \(v(swscale_version()))"
    }
}
