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

    /// SRTO_STREAMID, or NULL/"" to leave it unset.
    ///
    /// HOW MOST HOSTED INGESTS ROUTE A PUBLISHER — it is the resource path, the channel key, or the
    /// account token, depending on the service. Not setting one where the server expects it is not
    /// a degraded connection: the server rejects the handshake, and the rejection says nothing
    /// about the missing id. NOT A SECRET IN THE PASSPHRASE SENSE (it is an address, and it is
    /// logged), but it is not shown in the UI either — see the note on the host in SRTClient.
    ///
    /// SRT's own ceiling is 512 bytes; a longer one is refused at Start rather than truncated,
    /// because a truncated stream id addresses something other than what the user asked for.
    const char *streamId;

    /// ── WHICH SESSION THIS IS, FOR THE CONSUMER'S BENEFIT ──────────────────────────────────
    ///
    /// An opaque token, chosen by the caller, echoed back to every callback that HOPS TO ANOTHER
    /// THREAD. This layer never interprets it; it only carries it.
    ///
    /// It exists because a session's last callback can outlive the session's usefulness. `onEnded`
    /// fires on the session thread just before the join completes, and a consumer that hops it to
    /// its own thread will receive it LATER — potentially after it has already started a
    /// replacement session. Without a token, "did this callback come from the session I am
    /// currently running?" is unanswerable, and the pointer cannot answer it either: Destroy frees
    /// the struct and the next Create can be handed the same address.
    ///
    /// See SRTClient.sessionGeneration, which is the counter this carries.
    uint64_t generation;

    /// SRTO_RCVLATENCY in milliseconds, or 0 to leave libsrt's live default (120 ms) alone.
    ///
    /// THE RECEIVE side specifically. This is the de-jitter/retransmit window the TSBPD scheduler
    /// works with, and it is the number `SRTClient.logLatencyBudget` weighs the render cushion
    /// against. What is REQUESTED here is not what the link ends up using: the handshake takes the
    /// MAXIMUM of the two sides' wishes, so a sender asking for more wins. Both numbers are
    /// reported back — see `requestedLatencyMs` on ManifoldSRTConnectionInfo.
    int32_t latencyMs;
} ManifoldSRTSessionConfig;

#pragma mark - What the handshake negotiated

/// Read back AFTER connect — as distinct from what we asked for. Latency in
/// particular is a NEGOTIATED maximum of the two sides' wishes, so the requested
/// value tells you nothing.
typedef struct {
    int32_t negotiatedLatencyMs;   ///< SRTO_RCVLATENCY. The transport-level de-jitter buffer.

    /// What we ASKED for, echoed back: the config's `latencyMs`, or 0 when the URL named no
    /// latency and libsrt's default stands. Reported alongside the negotiated value because the
    /// two differing is normal and informative — the peer raising it is the handshake working, not
    /// a fault, and a user who typed `?latency=80` and got 400 needs to see both numbers to
    /// understand that the sender is the one holding the buffer open.
    int32_t requestedLatencyMs;
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

/// The chosen AUDIO stream's format, RAW — same discipline as ManifoldSRTVideoFormat: no
/// defaulting, no interpretation, the demuxer's values travel intact and the Swift side decides.
///
/// ⚠️ EVERY FIELD HERE IS FREE AT DISCOVERY. `avformat_find_stream_info` has already run, so
/// AVCodecParameters is fully populated — nothing in this struct required new parsing, only
/// plumbing. That is worth knowing before anyone proposes reading the ADTS/LATM headers to get
/// facts the demuxer already has.
///
/// ⚠️ NO CHANNEL COUNT IS ASSUMED ANYWHERE DOWNSTREAM OF THIS STRUCT, AND THAT IS DELIBERATE.
/// MPEG-TS carries multichannel AAC routinely (a 5.1 contribution feed is ordinary) and the
/// layout is DECLARED in the mux. Stage 1 does not build the role bridge, but it carries the
/// declaration this far rather than collapsing it to a number — see `channelOrder`/`channelMask`.
typedef struct {
    int32_t streamIndex;
    int32_t pid;                 ///< AVStream.id, which libavformat sets to the TS PID. 0 if unset.
    int32_t codecID;             ///< Raw AVCodecID. THE FRAMING DISCRIMINATOR: AV_CODEC_ID_AAC is
                                 ///  ADTS-framed (TS stream type 0x0F), AV_CODEC_ID_AAC_LATM is
                                 ///  LATM/LOAS (0x11). They need different handling and the
                                 ///  demuxer already knows which it is.
    int32_t profile;             ///< AVCodecParameters.profile — LC vs HE vs HEv2. Governs frames
                                 ///  per packet (1024 vs 2048), so it is not cosmetic.
    int32_t sampleRate;
    int32_t channelCount;

    /// ── THE LAYOUT, CARRIED AS FAR AS STAGE 1 GOES ────────────────────────────────────────
    /// `channelOrder` is AVChannelOrder; `channelMask` is `AVChannelLayout.u.mask`, valid when the
    /// order is AV_CHANNEL_ORDER_NATIVE and 0 otherwise. Together they are the mux's DECLARATION —
    /// not a guess from the count. Stage 1 logs them and stops; see SRTFrameRouter for exactly
    /// where they stop and what stage 3 has to add.
    int32_t  channelOrder;
    uint64_t channelMask;

    int32_t timeBaseNum;         ///< 1/90000 for MPEG-TS, natively and always — as for video.
    int32_t timeBaseDen;

    /// AudioSpecificConfig, when the demuxer has one. Borrowed — VALID ONLY FOR THE DURATION OF
    /// THE CALL, like every other pointer in these callbacks. The decoder copies what it needs.
    /// May be NULL/0 on a TS where the ASC has not been seen yet; the decoder then synthesises a
    /// cookie from the ADTS header, which carries the same three facts.
    const uint8_t *extradata;
    int32_t extradataSize;

    char codecName[32];          ///< "aac", "aac_latm", "mp2", …
    char profileName[48];        ///< "LC", "HE-AAC", … or "unknown".
    char layoutName[64];         ///< av_channel_layout_describe: "stereo", "5.1(side)", …
} ManifoldSRTAudioFormat;

/// One audio packet from the chosen stream, forwarded raw. Deliberately NOT routed through
/// ManifoldSRTAccessUnitReader: that reader exists to reassemble H.264 ACCESS UNITS from PES
/// payloads across packet boundaries, and AAC has no such problem — libavformat's mpegts demuxer
/// already hands back one complete audio frame per AVPacket. Reusing it would be borrowing a
/// solution to a problem this stream does not have.
typedef struct {
    const uint8_t *data;         ///< Borrowed; valid only for the call.
    size_t         size;
    int64_t        pts;          ///< Stream time base (1/90000). MANIFOLD_SRT_NO_TIMESTAMP if absent.
    int64_t        dts;
} ManifoldSRTAudioPacket;

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
///
/// ── WHY THREE OF THE FOUR CARRY `generation` AND ONE DOES NOT ──────────────────
///
/// The three that a consumer typically HOPS to another thread carry the config's
/// `generation` back, so the far side can ask "is this mine?" before acting on it.
/// A hopped callback can arrive after its session is gone and a replacement has
/// started; acting on it then configures or tears down the WRONG session.
///
/// `onAccessUnit` does NOT carry one, because it is consumed INLINE on this thread
/// and cannot outlive it: Stop joins, so by the time a caller can start a
/// replacement, this thread is already dead and no access unit is in flight. That
/// is a property of the JOIN, not of the callback — see the note on
/// ManifoldSRTSessionStop.
typedef struct {
    void *context;

    /// The handshake completed. Fires at most once, before any other callback.
    void (*onConnected)(void *context, uint64_t generation, const ManifoldSRTConnectionInfo *info);

    /// avformat_find_stream_info succeeded and a video stream was chosen. Fires at
    /// most once, after onConnected and before the first access unit.
    void (*onVideoFormat)(void *context, uint64_t generation, const ManifoldSRTVideoFormat *format);

    /// One access unit from the chosen video stream. Pointers inside are valid ONLY
    /// for the duration of the call. NO generation — see above.
    void (*onAccessUnit)(void *context, const ManifoldSRTAccessUnit *accessUnit);

    /// An audio stream was chosen. Fires at most once, in the same place onVideoFormat does.
    /// NOT fired when the program carries no audio — see `onAudioAbsent`.
    void (*onAudioFormat)(void *context, uint64_t generation, const ManifoldSRTAudioFormat *format);

    /// Stream discovery finished and there is NO audio stream in this program. Fires at most once.
    /// ⚠️ A POSITIVE STATEMENT, NOT AN ABSENCE OF ONE. "No audio" and "audio not established yet"
    /// are different states with different UI, and the engine already models them separately
    /// (`audioPresence`). Inferring the first from silence is how a stream that simply had not
    /// started its audio PID yet gets reported as having none.
    void (*onAudioAbsent)(void *context, uint64_t generation);

    /// One audio packet from the chosen audio stream. Same inline/no-generation contract as
    /// onAccessUnit, for the same reason.
    void (*onAudioPacket)(void *context, const ManifoldSRTAudioPacket *packet);

    /// The last callback, always. `message` is a human-readable line safe to show a
    /// user — it never contains the passphrase and never the full URL.
    void (*onEnded)(void *context, uint64_t generation,
                    ManifoldSRTEndReason reason, const char *message);
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
/// BOUND: one SRTO_RCVTIMEO period plus one demux iteration, ONCE THE SESSION IS
/// RECEIVING. The receive already in flight returns within the timeout; every
/// callback entry after that sees the cleared flag and returns AVERROR_EXIT without
/// blocking, and the interrupt callback closes off libavformat's own retry loops.
/// `onEnded` has fired by the time this returns. A no-op if nothing is running.
///
/// ⚠️ A SESSION STILL IN `srt_connect` IS BOUND BY SRTO_CONNTIMEO INSTEAD — 3 s, not
/// 200 ms. srt_connect does not consult the run flag, so stopping a session that has
/// not finished its handshake blocks the caller for the remainder of the connect
/// timeout. Swapping streams mid-connect therefore costs the caller up to 3 s.
///
/// ⚠️ THE JOIN IS LOAD-BEARING FOR MORE THAN RESOURCE SAFETY. It is also the entire
/// reason `onAccessUnit` needs no generation token: because this blocks until the
/// session thread has exited, a caller cannot possibly have started a replacement
/// session while a frame from this one is still in flight. IF THIS IS EVER MADE
/// ASYNCHRONOUS — the obvious fix for the 3 s stall above is to break `srt_connect`
/// by closing the socket and stop waiting — that guarantee disappears SILENTLY, with
/// no compiler error and no crash, and the frame path would start delivering a dead
/// stream's pictures into a live session's renderer. Generation-check the frame path
/// in the same change, or do not make this async.
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
