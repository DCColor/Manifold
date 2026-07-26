//
//  SRTSession.h
//  Manifold
//
//  The SRT transport, promoted from SRTSpike.[hm] and now SHIPPING CODE.
//
//      libsrt caller socket → custom AVIOContext → mpegts demux → av_read_frame
//        → ManifoldSRTAccessUnitReader → callbacks → (Swift) decoder → screen
//
//  ── WHAT CHANGED FROM THE SPIKE, AND WHAT DELIBERATELY DID NOT ─────────────
//
//  UNCHANGED, because it was proven: the one-thread shape (the network thread and
//  the demux thread are the same thread by construction, because the read callback
//  is invoked SYNCHRONOUSLY from inside av_read_frame), the joinable NSThread +
//  lock-guarded run flag + semaphore join, SRTO_RCVTIMEO as the bound on shutdown
//  latency, the interrupt callback that closes off libavformat's internal retry
//  loops, `av_find_input_format("mpegts")` to skip probing, and the AVIOContext
//  unwind — `av_freep(&pb->buffer)` then `avio_context_free`, which
//  avformat_close_input does NOT do under AVFMT_FLAG_CUSTOM_IO.
//
//  CHANGED: the URL is parsed on the Swift side now (URLComponents already knows
//  how, and the passphrase has to be lifted out of the query there anyway), so
//  host/port/passphrase arrive as plain strings. The packets are no longer counted
//  and discarded — the video stream is chosen with av_find_best_stream and fed to
//  the access-unit reader. The B-frame PROBE is gone; the reorder delay it was
//  probing for is now measured continuously on the Swift side, where it has to be
//  compared against LiveClock's targetDepth (SRTFrameRouter.reorderDelay).
//
//  ── WHY THERE IS NO URL STRING PASSED TO LIBAVFORMAT ───────────────────────
//
//  ThirdParty/ffmpeg is built --disable-network: ff_file_protocol is the only
//  protocol compiled in and avformat_network_init() is a stub. There is no
//  "srt://…" door into libavformat, and that is the guardrail — every byte arrives
//  through the AVIOContext below rather than through a second, competing transport
//  implementation inside the same binary. See ThirdParty/ffmpeg/README.md.
//
//  ── HEADER DISCIPLINE ──────────────────────────────────────────────────────
//
//  PURE C. Pulls in NEITHER <srt/*> NOR <libav*/*>, exactly as DataChannelBridge.h,
//  NDIBridge.h and DeckLinkBridge.h do, so neither library's API reaches Swift or
//  the bridging header's module scan. The .m owns all of it.
//
//  NOT `#ifdef DEBUG`. The spike was; this is not. The whole SRT path ships.
//
//  ── THREADING CONTRACT ─────────────────────────────────────────────────────
//
//  Create/Start/Stop/Destroy: MAIN THREAD ONLY, asserted.
//  Every callback in ManifoldSRTSessionCallbacks: the SESSION THREAD
//  (`com.manifold.srt.session`), inline, and NEVER after Stop has returned — Stop
//  joins. `onEnded` is the LAST callback and is guaranteed to fire exactly once per
//  successful Start, whatever the outcome, so it is the correct place to release
//  anything the session thread owns (a VTDecompressionSession, a pixel-buffer pool).
//

#ifndef MANIFOLD_SRT_SESSION_H
#define MANIFOLD_SRT_SESSION_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "SRTAccessUnitReader.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - Configuration

/// What to dial. Every string is COPIED during Start and is not referenced after it
/// returns.
typedef struct {
    const char *host;            ///< Hostname or literal address. Required.
    const char *port;            ///< Decimal port, as text (getaddrinfo takes it that way). Required.

    /// SRTO_PASSPHRASE, or NULL/"" for an unencrypted stream.
    ///
    /// ⚠️ NEVER LOG THIS, NEVER PUT IT IN A `message` STRING. The implementation
    /// copies it into the socket option and then `memset`s its own copy; the only
    /// thing it ever reports is the resulting SRTO_KMSTATE, which says WHETHER the
    /// link is encrypted without saying what with. Same redaction posture the WHEP
    /// endpoint path already has.
    const char *passphrase;
} ManifoldSRTSessionConfig;

#pragma mark - What the handshake negotiated

/// Read back AFTER connect — as distinct from what we asked for. Latency in
/// particular is a NEGOTIATED maximum of the two sides' wishes, so the requested
/// value tells you nothing.
typedef struct {
    int32_t negotiatedLatencyMs;   ///< SRTO_RCVLATENCY. The transport-level de-jitter buffer.
    int32_t payloadSize;           ///< SRTO_PAYLOADSIZE, bytes.
    int32_t mss;                   ///< SRTO_MSS, bytes.
    int32_t kmState;               ///< SRTO_KMSTATE — see ManifoldSRTKeyMaterialStateName.
    int32_t peerVersion;           ///< SRTO_PEERVERSION, packed 0xMMmmpp.
    double  connectSeconds;
} ManifoldSRTConnectionInfo;

/// SRT key-material state as words. UNSECURED means "not encrypted", which for a
/// stream we supplied no passphrase for is correct and not a fault.
const char *ManifoldSRTKeyMaterialStateName(int32_t kmState);

#pragma mark - What the demuxer found

/// The chosen video stream's codecpar, verbatim.
///
/// ── COLORIMETRY IS REPORTED RAW, INCLUDING "UNSPECIFIED" ───────────────────
/// These are CICP codes straight out of `AVCodecParameters`. 2 is UNSPECIFIED for
/// primaries/transfer/matrix and 0 is UNSPECIFIED for range, and those values are
/// passed up UNTOUCHED rather than being defaulted to 709 here. Whoever displays
/// the picture has to state an assumption; that is a decision for the layer that
/// knows what the renderer does with it, and it must be able to tell "the sender
/// said 709" from "the sender said nothing". See SRTFrameRouter.Colorimetry.
typedef struct {
    int32_t streamIndex;
    int32_t width, height;

    int32_t colorPrimaries;      ///< CICP. 2 = unspecified.
    int32_t colorTransfer;       ///< CICP. 2 = unspecified.
    int32_t colorMatrix;         ///< CICP. 2 = unspecified.
    int32_t colorRange;          ///< 0 = unspecified, 1 = limited/MPEG, 2 = full/JPEG.

    int32_t timeBaseNum;         ///< AVStream.time_base. 1/90000 for MPEG-TS, natively and always.
    int32_t timeBaseDen;

    /// `codecpar->video_delay` — the number of reorder frames the SPS VUI CLAIMS.
    /// ⚠️ A HEADER CLAIM ONLY, and a great many encoders never emit the
    /// bitstream_restriction_flag that carries it, so 0 means "not stated", NOT
    /// "no B-frames". SRTFrameRouter measures the real answer from (pts − dts).
    int32_t videoDelay;

    double  guessedFrameRate;    ///< av_guess_frame_rate, or 0 when unknown.
    char    codecName[32];       ///< "h264", "hevc", …
    char    profileName[48];     ///< "High", "Constrained Baseline", … or "unknown".
} ManifoldSRTVideoFormat;

#pragma mark - How a session ended

/// A PLAIN int32_t WITH AN ANONYMOUS ENUM, NOT `typedef enum {...} Foo`. Deliberate: how Clang
/// imports a named C enum into Swift depends on attributes this pure-C header does not carry
/// (NS_ENUM needs Foundation, enum_extensibility changes the shape), and the two possible
/// spellings — a Swift `enum` with cases vs a `RawRepresentable` struct — are not
/// source-compatible with each other. An anonymous enum's constants import as plain `Int32`
/// globals under every rule, so the Swift side reads the same whatever the toolchain does.
typedef int32_t ManifoldSRTEndReason;
enum {
    ManifoldSRTEndReasonStopped = 0,     ///< ManifoldSRTSessionStop was called. Not a fault.
    ManifoldSRTEndReasonConnectFailed,   ///< srt_connect refused/timed out. `message` is libsrt's.
    ManifoldSRTEndReasonSetupFailed,     ///< Resolve, socket, AVIOContext, demuxer or stream discovery.
    ManifoldSRTEndReasonPeerClosed,      ///< The publisher closed the connection cleanly.
    ManifoldSRTEndReasonConnectionLost,  ///< SRT_ECONNLOST / peer idle timeout — the link died.
    ManifoldSRTEndReasonTransportError,  ///< Anything else, already logged.
};

#pragma mark - Callbacks

/// ALL of these fire on the session thread, inline. Do not block them for long: the
/// same thread is the one performing srt_recvmsg2, so time spent here is time the
/// receive buffer is not being drained.
typedef struct {
    void *context;

    /// The handshake completed. Fires at most once, before any other callback.
    void (*onConnected)(void *context, const ManifoldSRTConnectionInfo *info);

    /// avformat_find_stream_info succeeded and a video stream was chosen. Fires at
    /// most once, after onConnected and before the first access unit.
    void (*onVideoFormat)(void *context, const ManifoldSRTVideoFormat *format);

    /// One access unit from the chosen video stream. Pointers inside are valid ONLY
    /// for the duration of the call.
    void (*onAccessUnit)(void *context, const ManifoldSRTAccessUnit *accessUnit);

    /// The last callback, always. `message` is a human-readable line safe to show a
    /// user — it never contains the passphrase and never the full URL.
    void (*onEnded)(void *context, ManifoldSRTEndReason reason, const char *message);
} ManifoldSRTSessionCallbacks;

#pragma mark - Lifecycle (main thread only)

typedef struct ManifoldSRTSession ManifoldSRTSession;

/// Allocates a session. Does no networking. Returns NULL only on allocation failure.
ManifoldSRTSession *ManifoldSRTSessionCreate(const ManifoldSRTSessionCallbacks *callbacks);

/// Spins up the session thread, which connects and then demuxes until stopped.
/// Returns false only if the config is unusable or the thread could not be started —
/// a CONNECT failure is reported asynchronously through `onEnded`, because it takes
/// up to the connect timeout and must not block main.
///
/// Idempotent-hostile on purpose: calling Start twice without a Stop returns false
/// and logs, rather than silently leaking a thread.
bool ManifoldSRTSessionStart(ManifoldSRTSession *session, const ManifoldSRTSessionConfig *config);

/// Clears the run flag and BLOCKS until the session thread has exited.
///
/// BOUND: one SRTO_RCVTIMEO period plus one demux iteration. The receive already in
/// flight returns within the timeout; every callback entry after that sees the
/// cleared flag and returns AVERROR_EXIT without blocking, and the interrupt
/// callback closes off libavformat's own retry loops. `onEnded` has fired by the
/// time this returns. A no-op if nothing is running.
void ManifoldSRTSessionStop(ManifoldSRTSession *session);

/// Stops if needed, then frees. The session pointer is dead after this.
void ManifoldSRTSessionDestroy(ManifoldSRTSession *session);

#pragma mark - Diagnostics

/// The access-unit reader's counters, for the 1 Hz rollup on the Swift side. Safe to
/// call from main while the session runs: the counters are plain integers written by
/// one thread, and a torn read of a diagnostic count is not worth a lock on the
/// per-packet path. Zeroed when no stream has been discovered yet.
void ManifoldSRTSessionCopyReaderStats(const ManifoldSRTSession *session,
                                       ManifoldSRTAccessUnitReaderStats *outStats);

/// Transport counters: whole SRT messages received, bytes, and receive timeouts (a
/// timeout is silence, not a fault — it is what keeps a stalled stream legible).
void ManifoldSRTSessionCopyTransportStats(const ManifoldSRTSession *session,
                                          uint64_t *outMessages,
                                          uint64_t *outBytes,
                                          uint64_t *outRecvTimeouts);

/// The shared H.264 layer's counters — NAL types, oversize AUs — for the session-totals line.
/// Same threading caveat as the two above.
void ManifoldSRTSessionCopyReaderBuilderStats(const ManifoldSRTSession *session,
                                              ManifoldH264AccessUnitBuilderStats *outStats);

#ifdef __cplusplus
}
#endif

#endif /* MANIFOLD_SRT_SESSION_H */
