//
//  SRTSession.m
//  Manifold
//
//  See SRTSession.h for the contract and for what was promoted verbatim from the
//  stage-2 spike (SRTSpike.m, now deleted).
//
//  ── THE SHAPE, IN ONE PARAGRAPH ────────────────────────────────────────────────
//  One thread does everything. libsrt owns the socket; libavformat is handed a custom
//  AVIOContext whose read callback performs the blocking srt_recvmsg2. Because that
//  callback is invoked SYNCHRONOUSLY from inside av_read_frame, the network thread and
//  the demux thread are the same thread by construction — there is no queue, no
//  handoff, and no second thread to get the shutdown ordering wrong between. The
//  access-unit reader and (through the callbacks) the video decoder run on that same
//  thread, which is what makes the decoder's "one thread owns the session" rule hold
//  for free. Nothing here touches the render thread or the main thread after Start.
//

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>   // CACurrentMediaTime — the same clock NDIService's pump uses

#include <os/lock.h>
#include <netdb.h>
#include <string.h>
#include <syslog.h>   // LOG_NOTICE, for srt_setloglevel

#include <srt/srt.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>

#include "SRTSession.h"

#pragma mark - Constants

/// Bound on the blocking receive, and therefore the bound on shutdown latency. This is
/// the single option that makes a clean stop possible: without it srt_recvmsg2 blocks
/// forever, the read callback never returns, av_read_frame never unwinds, and the join
/// in ManifoldSRTSessionStop() would hang until the publisher happened to send something.
static const int kSRTRecvTimeoutMs = 200;

/// Connect timeout. libsrt's caller default is already 3000 ms; set explicitly so the
/// failure path's TIMING is a property of this file rather than of a library default
/// that could change under us.
static const int kSRTConnectTimeoutMs = 3000;

/// SRTO_PEERIDLETIMEO — how long a connected socket tolerates total silence from the
/// peer before declaring the connection broken. THIS IS SRT'S OWN EQUIVALENT OF WHEP'S
/// STUCK-`.disconnected` BACKSTOP, and it is why there is no app-level timer for the
/// same job: libsrt escalates a dead link to SRT_ECONNLOST on its own, which the read
/// callback below turns into AVERROR_EOF and an onEnded(ConnectionLost). Stated
/// explicitly, at libsrt's own default, for the same reason the connect timeout is —
/// so the teardown TIMING is ours and not a library default's.
static const int kSRTPeerIdleTimeoutMs = 5000;

/// The AVIOContext's internal buffer. 64 KiB is the usual libavformat figure and is far
/// larger than one SRT message, so libavformat almost always reads out of its own buffer
/// and our callback is entered ~50 times per 64 KiB rather than per TS packet.
static const int kSRTIOBufferSize = 64 * 1024;

/// One SRT message. SRT live mode is MESSAGE-oriented: srt_recvmsg2 delivers whole
/// messages and FAILS with SRT_ELARGEMSG — DISCARDING the message — if the buffer it is
/// given is smaller than the pending one. The MPEG-TS default payload is 1316 bytes
/// (7 × 188) and the ceiling with a 1500-byte MTU is 1456, so this is sized to the
/// ceiling and never to what we expect to see.
#define SRT_MSG_MAX 1536

/// After this much post-connect silence, say so. Connected-but-silent is a real and
/// common state (publisher not started, wrong stream id) and it must not look like a
/// hang. Mirrors the "[WHEP-RTP] no RTP for %ds" line.
static const double kSRTSilenceWarnAfter = 5.0;

#pragma mark - State

//  ── ARC NOTE ON THE TWO OBJ-C FIELDS AT THE BOTTOM ────────────────────────────
//  `thread` and `finished` are strong Obj-C references inside a calloc'd C struct.
//  Clang permits that (a "non-trivial C struct"), and calloc's zeroing gives them
//  valid nil values — but ARC does NOT run a destructor for heap memory released
//  with free(). So they must be nil'd BEFORE the free, which is exactly what Stop
//  does and why Destroy calls Stop unconditionally rather than only when running.
//  Every other field is a plain C type.
typedef struct ManifoldSRTSession {
    ManifoldSRTSessionCallbacks callbacks;

    // ── dialled target. Copied at Start; the passphrase is wiped after use. ──
    char host[256];
    char port[16];
    char passphrase[80];        // SRT's ceiling is 79 chars + NUL.
    char streamId[513];         // SRT's ceiling is 512 bytes + NUL.
    uint64_t generation;        // Opaque caller token, echoed to the hopping callbacks.
    int32_t latencyMs;          // 0 = leave libsrt's live default alone.

    // ── transport (written by the read callback, on the session thread) ──
    SRTSOCKET sock;
    unsigned char msg[SRT_MSG_MAX];
    int msgLen, msgOff;         // the staged message and how much of it libavformat has taken
    uint64_t messagesIn, bytesIn, recvTimeouts;

    // ── run flag. The ONLY field touched by two threads. ──
    os_unfair_lock runLock;
    bool shouldRun;

    // ── demux (session thread) ──
    ManifoldSRTAccessUnitReader *reader;
    int videoIndex;
    double connectedAt;
    bool sawFirstPacket, warnedSilent;

    /// WHICH KIND OF EOF the read callback produced. Both a graceful peer shutdown and
    /// a dead link reach av_read_frame as a bare AVERROR_EOF, and the two are worth
    /// telling apart in the UI ("the stream ended" vs "the connection was lost"). The
    /// distinction only exists at the srt_recvmsg2 return, so it is latched there
    /// rather than guessed from srt_getsockstate afterwards — by which time the socket
    /// looks the same either way.
    ManifoldSRTEndReason eofReason;

    // ── lifecycle (main thread) ──
    NSThread *thread;
    dispatch_semaphore_t finished;
} ManifoldSRTSession;

static bool srtShouldRun(ManifoldSRTSession *s) {
    os_unfair_lock_lock(&s->runLock);
    const bool run = s->shouldRun;
    os_unfair_lock_unlock(&s->runLock);
    return run;
}

static double srtNow(void) { return CACurrentMediaTime(); }

#pragma mark - libsrt's own logging

//  ── WHY srt_setloghandler IS INSTALLED HERE AND WAS NOT IN THE SPIKE ──────────
//
//  The spike dialled 127.0.0.1 and argued, correctly for that scope, that the three
//  facts it logged on a failed connect (srt errno, system errno, reject reason) name
//  the stage, the OS refusal and the peer's refusal, which covers "nothing is
//  listening", "firewall", "wrong passphrase", "encryption mismatch" and "peer too
//  old". It also named the case those three do NOT distinguish: an MTU/MSS mismatch
//  across a real network path, where the handshake INDUCTION succeeds and the
//  CONCLUSION silently does not. libsrt's internal log at LOG_NOTICE names that; our
//  errno set does not.
//
//  Stage 3d is the first SRT code that dials a real network, so that case stops being
//  hypothetical and the handler goes in. It is ~15 lines and it costs nothing while
//  the link is healthy — libsrt emits at NOTICE only around handshake and teardown.
//
//  TWO RULES THE HANDLER MUST OBEY, both structural:
//    1. It is called from LIBSRT'S OWN INTERNAL THREADS (the GC thread, the sender
//       and receiver worker threads). It must do nothing but format and log — no
//       locks of ours, no allocation beyond NSLog's own, no re-entry into libsrt.
//    2. It is PROCESS-GLOBAL, not per-socket, and outlives any one session. So it is
//       installed exactly once (dispatch_once) rather than on every connect, and it
//       captures nothing.
//  ── ⚠️ NOT INSTALLING A HANDLER DOES NOT MEAN SILENCE. THE FLOOR BELOW IS WHY. ──
//
//  An earlier version of this file gated the handler out of Release and claimed that
//  made libsrt "silent by construction" in a shipped build. THAT WAS WRONG, and it
//  was wrong in the direction that ships stderr noise to users. Measured against the
//  vendored v1.5.6 archive (ThirdParty/libsrt/lib/libsrt.a), the global
//  `srt_logger_config` is built by logger_defs.cpp's static initializer as:
//
//      enabled_fa  = the AllFaOn mask (0x7a0f83e129bf — most functional areas ON)
//      max_level   = 4                                        <- LOG_WARNING
//      log_stream  = &std::cerr                               <- THE DEFAULT SINK
//      loghandler_fn / loghandler_opaque = NULL / NULL
//
//  (Read straight out of __GLOBAL__sub_I_logger_defs.cpp: `mov w8,#0x4; str w8,[x19,#8]`
//  for the level, and the only external data reference in that initializer is
//  `__ZNSt3__14cerrE`. `strings` on the archive shows the message text is compiled in —
//  the build script does not pass -DENABLE_LOGGING=OFF, and libsrt's default is ON.)
//
//  libsrt's dispatcher is `if (loghandler_fn) call it; else if (log_stream) write it`,
//  so with NO handler every LOGC at fatal/error/warning goes STRAIGHT TO STDERR from
//  strings inside libsrt.a, with nothing of ours involved. Those fire in ordinary
//  operation — handshake rejections, key-material failures, connection breaks, the 83
//  "IPE:" internal-error strings. A shipped app would print them and there would be no
//  code in this repo to grep for when someone asked why.
//
//  ── THE FIX: AN UNGATED FLOOR, THEN A GATED OVERRIDE ──────────────────────────
//
//  BOTH mechanisms are applied, and they are independent on purpose:
//
//    1. A NO-OP HANDLER. Structural: a non-NULL `loghandler_fn` wins the dispatcher's
//       branch unconditionally, so nothing can reach std::cerr regardless of level.
//       It carries no format string, so nothing extra ships.
//    2. A LEVEL BELOW ANYTHING LIBSRT EMITS. `SRT_LOG_LEVEL_MIN` is LOG_CRIT, the
//       lowest level in libsrt's own LogLevel enum, so one below it can never satisfy
//       the dispatcher's `level <= max_level` test — libsrt does not even FORMAT the
//       line, which is the cheaper half.
//
//  Either alone would do. Both, because (1) assumes the branch order and (2) assumes
//  the comparison, and neither assumption is ours to make about a vendored library.
//
//  `strings`/`nm` also confirm the archive references no `fprintf`/`stderr`/`perror`
//  at all, so `log_stream` is the ONLY sink there is to close.
//
//  ── AND THE DIAGNOSTIC HANDLER, ON TOP, IN DEBUG/PROFILE ──────────────────────
//
//  THE GATE IS SPELLED `defined(DEBUG) || defined(MANIFOLD_TELEMETRY)` TO MATCH THE
//  SWIFT SIDE, but only DEBUG actually reaches the C compiler today: project.yml
//  carries MANIFOLD_TELEMETRY in SWIFT_ACTIVE_COMPILATION_CONDITIONS (Swift-only)
//  and never in GCC_PREPROCESSOR_DEFINITIONS. Debug and Profile both define DEBUG=1
//  there, Release defines neither — so the `[SRT-LIB]` string and the real handler
//  exist in exactly the two configurations that are for measuring. The second term is
//  there so that if MANIFOLD_TELEMETRY is ever added to the C definitions, this file
//  needs no edit.

/// One below `SRT_LOG_LEVEL_MIN` (LOG_CRIT), i.e. below every level in libsrt's
/// LogLevel enum — fatal(2), error(3), warning(4), note(5), debug(7). Expressed
/// against libsrt's own constant rather than as a bare 1, so it stays correct if
/// syslog's numbering ever moves under us.
static const int kSRTLogLevelSilent = SRT_LOG_LEVEL_MIN - 1;

/// The floor. Compiled into EVERY configuration and does nothing but exist: its
/// address is what diverts libsrt's dispatcher away from std::cerr.
static void srtSilentLogHandler(void *opaque, int level, const char *file, int line,
                                const char *area, const char *message) {
    (void)opaque; (void)level; (void)file; (void)line; (void)area; (void)message;
}

#if defined(DEBUG) || defined(MANIFOLD_TELEMETRY)
static void srtLogHandler(void *opaque, int level, const char *file, int line,
                          const char *area, const char *message) {
    (void)opaque; (void)level; (void)file; (void)line;
    NSLog(@"[SRT-LIB] %s: %s", area ? area : "srt", message ? message : "");
}
#endif

/// Install the log policy. Process-global (not per-socket), so `dispatch_once` rather
/// than once per connect.
///
/// CALLED BEFORE `srt_startup()`, deliberately: startup itself logs, and installing
/// afterwards would leave a window in which those lines reached stderr. It is safe to
/// call first — `srt_setloghandler` / `srt_setloglevel` touch nothing but
/// `srt_logger_config` under its own statically-initialised mutex.
static void installSRTLogPolicyOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // THE UNGATED FLOOR. Release ends here, silent, by two independent mechanisms.
        srt_setloghandler(NULL, srtSilentLogHandler);
        srt_setloglevel(kSRTLogLevelSilent);
#if defined(DEBUG) || defined(MANIFOLD_TELEMETRY)
        // The measuring configurations override BOTH halves of the floor. Order does
        // not matter — nothing logs between these two calls.
        srt_setloghandler(NULL, srtLogHandler);
        srt_setloglevel(LOG_NOTICE);
#endif
    });
}

#pragma mark - Naming helpers

const char *ManifoldSRTKeyMaterialStateName(int32_t km) {
    switch (km) {
        case SRT_KM_S_UNSECURED:  return "UNSECURED (no encryption)";
        case SRT_KM_S_SECURING:   return "SECURING (exchanging key material)";
        case SRT_KM_S_SECURED:    return "SECURED (encrypted, decrypting ok)";
        case SRT_KM_S_NOSECRET:   return "NOSECRET (encrypted, we have no passphrase)";
        case SRT_KM_S_BADSECRET:  return "BADSECRET (encrypted, wrong passphrase)";
        default:                  return "?";
    }
}

#pragma mark - AVIOContext callbacks

/// THE read callback. Invoked synchronously by libavformat from inside
/// avformat_open_input, avformat_find_stream_info and av_read_frame — so this function,
/// and the blocking srt_recvmsg2 inside it, run on the session thread and nowhere else.
///
/// ── THE RETURN CONTRACT, WHICH IS THE EASIEST THING HERE TO GET WRONG ──────────
/// avio.h is explicit: "For stream protocols, must never return 0 but rather a proper
/// AVERROR code." A 0 return is read as a zero-length read and libavformat will call
/// straight back in — a spin. So:
///   > 0            bytes delivered (a SHORT read is fine and is the normal case here)
///   AVERROR_EXIT   we are stopping. Unwinds av_read_frame immediately.
///   AVERROR_EOF    the peer closed, or the connection is gone. Ends the session cleanly.
///   AVERROR_EXTERNAL  a real SRT error, already logged.
///   (never 0)
/// A RECEIVE TIMEOUT IS NOT ANY OF THESE. It loops here and is invisible to
/// libavformat, deliberately: surfacing a 200 ms silence as an error would make
/// avformat_find_stream_info abandon a stream that is merely between GOPs.
///
/// ── WHY THE MESSAGE IS STAGED RATHER THAN READ STRAIGHT INTO buf ───────────────
/// srt_recvmsg2 is message-oriented and DISCARDS a message that does not fit the buffer
/// it is handed (SRT_ELARGEMSG). libavformat does not promise a large buf_size — when a
/// request exceeds its internal buffer it calls this function directly with the caller's
/// size, which can be small. Staging one whole message and serving min(buf_size,
/// remaining) out of it is therefore correct for ANY buf_size, at the cost of one memcpy.
static int srtReadPacket(void *opaque, uint8_t *buf, int bufSize) {
    ManifoldSRTSession *s = (ManifoldSRTSession *)opaque;
    if (bufSize <= 0) return AVERROR(EINVAL);

    if (s->msgOff >= s->msgLen) {
        s->msgOff = s->msgLen = 0;
        for (;;) {
            if (!srtShouldRun(s)) return AVERROR_EXIT;

            SRT_MSGCTRL ctrl;
            srt_msgctrl_init(&ctrl);
            const int n = srt_recvmsg2(s->sock, (char *)s->msg, (int)sizeof(s->msg), &ctrl);

            if (n > 0) {
                s->msgLen = n;
                s->messagesIn++;
                s->bytesIn += (uint64_t)n;
                s->sawFirstPacket = true;
                break;
            }
            if (n == 0) {
                NSLog(@"[SRT] peer closed the connection (zero-length message) — end of stream");
                s->eofReason = ManifoldSRTEndReasonPeerClosed;
                return AVERROR_EOF;
            }

            int sysErr = 0;
            const int err = srt_getlasterror(&sysErr);
            srt_clearlasterror();

            if (err == SRT_ETIMEOUT || err == SRT_EASYNCRCV) {
                s->recvTimeouts++;
                // CONNECTED BUT SILENT is a real state and must not read as a hang.
                if (!s->sawFirstPacket && !s->warnedSilent &&
                    srtNow() - s->connectedAt >= kSRTSilenceWarnAfter) {
                    s->warnedSilent = true;
                    NSLog(@"[SRT] connected for %.0fs but NOT ONE BYTE has arrived. The socket is up "
                          @"and the publisher is silent — check that something is actually sending "
                          @"to %s:%s.", kSRTSilenceWarnAfter, s->host, s->port);
                }
                continue;
            }
            if (err == SRT_ECONNLOST || err == SRT_ENOCONN || err == SRT_EINVSOCK) {
                // Includes the SRTO_PEERIDLETIMEO expiry — libsrt's own version of
                // WHEP's stuck-`.disconnected` backstop, which is why there is no
                // app-level timer for the same job.
                NSLog(@"[SRT] connection lost: %s (srt errno %d, sys errno %d) — end of stream",
                      srt_strerror(err, sysErr), err, sysErr);
                s->eofReason = ManifoldSRTEndReasonConnectionLost;
                return AVERROR_EOF;
            }
            NSLog(@"[SRT] srt_recvmsg2 failed: %s (srt errno %d, sys errno %d)",
                  srt_strerror(err, sysErr), err, sysErr);
            return AVERROR_EXTERNAL;
        }
    }

    int n = s->msgLen - s->msgOff;
    if (n > bufSize) n = bufSize;
    memcpy(buf, s->msg + s->msgOff, (size_t)n);
    s->msgOff += n;
    return n;
}

/// Belt-and-braces alongside the AVERROR_EXIT above. libavformat has internal retry
/// loops — find_stream_info's analysis loop most of all — that consult
/// ff_check_interrupt WITHOUT necessarily re-entering the read callback. Wiring this up
/// is what makes Stop reliable during the open/analyse window, not just during the
/// steady-state av_read_frame loop.
static int srtInterrupt(void *opaque) {
    return srtShouldRun((ManifoldSRTSession *)opaque) ? 0 : 1;
}

#pragma mark - Access-unit forwarding

/// The reader's handler. Runs inline on the session thread, inside
/// ManifoldSRTAccessUnitReaderSubmitPacket, inside the av_read_frame loop.
static void srtForwardAccessUnit(const ManifoldSRTAccessUnit *accessUnit, void *context) {
    ManifoldSRTSession *s = (ManifoldSRTSession *)context;
    if (s->callbacks.onAccessUnit) s->callbacks.onAccessUnit(s->callbacks.context, accessUnit);
}

#pragma mark - Stream discovery

/// Fill the video-format struct from the chosen stream, RAW — no defaulting, no
/// interpretation. The UNSPECIFIED codes travel intact; see the header.
static void fillVideoFormat(AVFormatContext *fmt, int index, ManifoldSRTVideoFormat *out) {
    AVStream *st = fmt->streams[index];
    AVCodecParameters *par = st->codecpar;

    memset(out, 0, sizeof(*out));
    out->streamIndex    = index;
    out->width          = par->width;
    out->height         = par->height;
    out->colorPrimaries = (int32_t)par->color_primaries;
    out->colorTransfer  = (int32_t)par->color_trc;
    out->colorMatrix    = (int32_t)par->color_space;
    out->colorRange     = (int32_t)par->color_range;
    out->timeBaseNum    = st->time_base.num;
    out->timeBaseDen    = st->time_base.den;
    out->videoDelay     = par->video_delay;

    const AVRational guessed = av_guess_frame_rate(fmt, st, NULL);
    out->guessedFrameRate = guessed.den ? (double)guessed.num / guessed.den : 0.0;

    const char *codec = avcodec_get_name(par->codec_id);
    strlcpy(out->codecName, codec ? codec : "?", sizeof(out->codecName));
    const char *profile = avcodec_profile_name(par->codec_id, par->profile);
    strlcpy(out->profileName, profile ? profile : "unknown", sizeof(out->profileName));
}

/// One line per stream, and one for the container. Shorter than the spike's block — the
/// colorimetry detail now travels up to SRTFrameRouter, which logs it with the
/// provenance it decides on rather than raw enum names.
static void logStreamDiscovery(AVFormatContext *fmt, int videoIndex) {
    NSLog(@"[SRT] container: %s | streams=%u programs=%u",
          fmt->iformat ? fmt->iformat->name : "?", fmt->nb_streams, fmt->nb_programs);
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        AVCodecParameters *par = fmt->streams[i]->codecpar;
        const char *type = av_get_media_type_string(par->codec_type);
        if (par->codec_type == AVMEDIA_TYPE_VIDEO) {
            NSLog(@"[SRT]   stream %u: %s / %s %dx%d%s", i, type ? type : "?",
                  avcodec_get_name(par->codec_id), par->width, par->height,
                  (int)i == videoIndex ? "  ← CHOSEN" : "");
        } else {
            // ── THE AAC STREAM, AND WHY IGNORING IT IS A CLEAN NO-OP ──────────────
            // av_read_frame demuxes every stream in the program whether we read from
            // it or not — the PES assembly is driven by the TS packets arriving, not
            // by our interest — so "ignoring audio" costs one branch per packet and
            // an av_packet_unref that would have happened anyway. There is no
            // buffering to grow and no PID filter to get wrong: libavformat does not
            // queue packets for a stream nobody reads, because av_read_frame RETURNS
            // each packet to us and we drop it. Audio is a later arc; this is the
            // whole of what it costs today.
            NSLog(@"[SRT]   stream %u: %s / %s (ignored — audio is a later arc)",
                  i, type ? type : "?", avcodec_get_name(par->codec_id));
        }
    }
}

#pragma mark - Negotiated options

static void readConnectionInfo(SRTSOCKET sock, double connectSeconds, int32_t requestedLatencyMs,
                               ManifoldSRTConnectionInfo *out) {
    int32_t rcvLatency = -1, mss = -1, payload = -1, kmState = -1, peerVersion = 0;
    int len;
    len = sizeof(rcvLatency);  srt_getsockflag(sock, SRTO_RCVLATENCY,  &rcvLatency,  &len);
    len = sizeof(mss);         srt_getsockflag(sock, SRTO_MSS,         &mss,         &len);
    len = sizeof(payload);     srt_getsockflag(sock, SRTO_PAYLOADSIZE, &payload,     &len);
    len = sizeof(kmState);     srt_getsockflag(sock, SRTO_KMSTATE,     &kmState,     &len);
    len = sizeof(peerVersion); srt_getsockflag(sock, SRTO_PEERVERSION, &peerVersion, &len);

    out->negotiatedLatencyMs = rcvLatency;
    out->requestedLatencyMs  = requestedLatencyMs;
    out->mss                 = mss;
    out->payloadSize         = payload;
    out->kmState             = kmState;
    out->peerVersion         = peerVersion;
    out->connectSeconds      = connectSeconds;
}

#pragma mark - The session

/// The whole session, on the session thread.
///
/// RESOURCE DISCIPLINE — the shape is LibavFrameSource.open()'s: every failure path
/// unwinds exactly what it allocated, in reverse. Two traps in particular:
///
///   1. A FAILED avformat_open_input FREES THE AVFormatContext AND NULLS YOUR POINTER.
///      So `avio` is held in a LOCAL and freed through that local — never through
///      `fmt->pb`, which after a failed open is unreachable.
///   2. WITH AVFMT_FLAG_CUSTOM_IO, avformat_close_input DOES NOT free the AVIOContext OR
///      its buffer. It NULLs `pb` internally precisely so it will not try. Both are ours
///      to free: av_freep(&avio->buffer) then avio_context_free(&avio). And the buffer
///      must be read back OUT OF the context — libavformat may replace it.
static void runSession(ManifoldSRTSession *s) {
    SRTSOCKET sock = SRT_INVALID_SOCK;
    unsigned char *ioBuffer = NULL;
    AVIOContext *avio = NULL;
    AVFormatContext *fmt = NULL;
    AVPacket *pkt = NULL;
    struct addrinfo *res = NULL;
    const AVInputFormat *mpegts = NULL;
    bool srtStarted = false;

    ManifoldSRTEndReason reason = ManifoldSRTEndReasonSetupFailed;
    char message[256] = {0};

    s->connectedAt = srtNow();
    s->videoIndex = -1;

    NSLog(@"[SRT] ══ session start ══ %s:%s | libsrt %s | libavformat %s",
          s->host, s->port, SRT_VERSION_STRING, av_version_info());

    // ── 1. libsrt startup ──────────────────────────────────────────────────────
    // THE LOG POLICY GOES IN FIRST. libsrt's default sink is std::cerr at LOG_WARNING
    // (measured — see the block at installSRTLogPolicyOnce), and srt_startup itself can
    // log, so installing afterwards would leave a window in which libsrt's own strings
    // reached a shipped app's stderr.
    installSRTLogPolicyOnce();
    if (srt_startup() == SRT_ERROR) {
        int sysErr = 0; const int err = srt_getlasterror(&sysErr);
        NSLog(@"[SRT] srt_startup failed: %s (srt errno %d)", srt_strerror(err, sysErr), err);
        strlcpy(message, "Couldn’t start the SRT transport.", sizeof(message));
        goto cleanup;
    }
    srtStarted = true;

    // ── 2. resolve + socket + options ──────────────────────────────────────────
    {
        struct addrinfo hints;
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_UNSPEC;      // srt_create_socket() defers its family until connect
        hints.ai_socktype = SOCK_DGRAM;   // SRT is UDP underneath
        const int gaiErr = getaddrinfo(s->host, s->port, &hints, &res);
        if (gaiErr != 0 || !res) {
            NSLog(@"[SRT] cannot resolve %s:%s — %s", s->host, s->port, gai_strerror(gaiErr));
            snprintf(message, sizeof(message), "Couldn’t find %s.", s->host);
            goto cleanup;
        }
    }

    sock = srt_create_socket();
    if (sock == SRT_INVALID_SOCK) {
        int sysErr = 0; const int err = srt_getlasterror(&sysErr);
        NSLog(@"[SRT] srt_create_socket failed: %s (srt errno %d)", srt_strerror(err, sysErr), err);
        strlcpy(message, "Couldn’t open an SRT socket.", sizeof(message));
        goto cleanup;
    }
    s->sock = sock;

    // SRTO_TRANSTYPE MUST BE SET FIRST. It is a macro option: setting it REWRITES a whole
    // group of others (latency, tsbpd, message API, congestion controller) to that
    // transmission type's defaults, so anything set before it is silently overwritten.
    {
        const int transtype = SRTT_LIVE;
        srt_setsockflag(sock, SRTO_TRANSTYPE, &transtype, sizeof(transtype));

        const int rcvTimeout = kSRTRecvTimeoutMs;
        const int connTimeout = kSRTConnectTimeoutMs;
        const int peerIdle = kSRTPeerIdleTimeoutMs;
        srt_setsockflag(sock, SRTO_RCVTIMEO,      &rcvTimeout,  sizeof(rcvTimeout));
        srt_setsockflag(sock, SRTO_CONNTIMEO,     &connTimeout, sizeof(connTimeout));
        srt_setsockflag(sock, SRTO_PEERIDLETIMEO, &peerIdle,    sizeof(peerIdle));

        // ── REQUESTED LATENCY ─────────────────────────────────────────────────
        // AFTER SRTO_TRANSTYPE, and it has to be: TRANSTYPE rewrites the latency
        // group wholesale, so setting this above would be silently undone. Only
        // when the URL named one — otherwise libsrt's live default (120 ms) stands,
        // which is also what OBS ships, and writing 120 explicitly would look like a
        // decision we had made rather than one we had inherited.
        if (s->latencyMs > 0) {
            const int latency = (int)s->latencyMs;
            if (srt_setsockflag(sock, SRTO_RCVLATENCY, &latency, sizeof(latency)) == SRT_ERROR) {
                int sysErr = 0; const int err = srt_getlasterror(&sysErr);
                NSLog(@"[SRT] SRTO_RCVLATENCY %d ms rejected: %s (srt errno %d)",
                      latency, srt_strerror(err, sysErr), err);
                strlcpy(message, "That stream latency isn’t a value SRT will accept.",
                        sizeof(message));
                goto cleanup;
            }
            NSLog(@"[SRT] requested receive latency %d ms (the peer may raise it)", latency);
        }

        // ── STREAM ID ─────────────────────────────────────────────────────────
        // ⚠️ THE VALUE IS NOT PRINTED HERE. A streamid can carry a credential — SRT's
        // `#!::…,s=…` access-control syntax defines `s` as a session token, and many
        // hosted ingests use the raw publish key as the whole id — so the one place it
        // reaches a log is SRTClient, which runs it through `redactedStreamId` first.
        // Duplicating that parser in C to print it twice would be two chances to get
        // the redaction wrong; this line proves the option was ACCEPTED, which is the
        // part the Swift-side log cannot know.
        //
        // Unlike the passphrase it is NOT wiped after use: libsrt keeps no copy we can
        // rely on for reconnection diagnostics, and the value is needed for the
        // lifetime of the config rather than just the setsockflag call.
        if (s->streamId[0] != '\0') {
            if (srt_setsockflag(sock, SRTO_STREAMID,
                                s->streamId, (int)strlen(s->streamId)) == SRT_ERROR) {
                int sysErr = 0; const int err = srt_getlasterror(&sysErr);
                NSLog(@"[SRT] SRTO_STREAMID rejected: %s (srt errno %d)",
                      srt_strerror(err, sysErr), err);
                strlcpy(message, "That stream ID isn’t a value SRT will accept.", sizeof(message));
                goto cleanup;
            }
            NSLog(@"[SRT] SRTO_STREAMID accepted (value logged, redacted, by SRTClient)");
        }

        // ── PASSPHRASE ────────────────────────────────────────────────────────
        // Set, then WIPED FROM OUR COPY immediately. libsrt has derived its key
        // material by the time setsockflag returns, so there is no reason for the
        // plaintext to outlive this block — and nothing below it can log a buffer
        // that is already zeroed. The only encryption fact that ever leaves this
        // file is SRTO_KMSTATE, which says WHETHER the link is encrypted without
        // saying what with.
        if (s->passphrase[0] != '\0') {
            const int result = srt_setsockflag(sock, SRTO_PASSPHRASE,
                                               s->passphrase, (int)strlen(s->passphrase));
            memset(s->passphrase, 0, sizeof(s->passphrase));
            if (result == SRT_ERROR) {
                int sysErr = 0; const int err = srt_getlasterror(&sysErr);
                // libsrt rejects a passphrase outside 10…79 characters. Say which rule
                // was broken, never what was supplied.
                NSLog(@"[SRT] SRTO_PASSPHRASE rejected: %s (srt errno %d)",
                      srt_strerror(err, sysErr), err);
                strlcpy(message, "That stream passphrase isn’t valid (SRT requires 10–79 characters).",
                        sizeof(message));
                goto cleanup;
            }
            NSLog(@"[SRT] passphrase set (value withheld) — the link will be encrypted");
        }
    }

    // ── 3. connect (CALLER only — no listener, no rendezvous) ──────────────────
    {
        const double connectStart = srtNow();
        const int connectResult = srt_connect(sock, res->ai_addr, (int)res->ai_addrlen);
        const double connectSeconds = srtNow() - connectStart;
        freeaddrinfo(res);
        res = NULL;

        if (connectResult == SRT_ERROR) {
            // ── WHAT A FAILED CONNECT LOOKS LIKE. Three independent facts, because any
            //    one of them alone is ambiguous: the SRT errno says WHICH STAGE failed,
            //    the system errno says whether the OS refused, and the reject reason is
            //    the only thing that distinguishes "the peer said no, and why" from
            //    "nobody answered".
            int sysErr = 0;
            const int err = srt_getlasterror(&sysErr);
            const int reject = srt_getrejectreason(sock);
            NSLog(@"[SRT] CONNECT FAILED after %.3fs to %s:%s", connectSeconds, s->host, s->port);
            NSLog(@"[SRT]   srt error: %s (srt errno %d, sys errno %d: %s)",
                  srt_strerror(err, sysErr), err, sysErr, sysErr ? strerror(sysErr) : "none");
            NSLog(@"[SRT]   reject reason: %s (%d)", srt_rejectreason_str(reject), reject);

            reason = ManifoldSRTEndReasonConnectFailed;
            // SURFACE LIBSRT'S OWN WORDS, the way WHEP surfaces the server's own 409
            // body: the library knows things our generic does not, and its strings are
            // short, English and free of anything secret. The two most common causes get
            // a plain-language lead-in first, because "Connection setup failure" is not
            // an instruction to anyone.
            if (err == SRT_ENOSERVER) {
                snprintf(message, sizeof(message),
                         "Nothing answered at %s:%s — SRT is UDP, so a listener that isn’t "
                         "running looks exactly like a blocked port. (%s)",
                         s->host, s->port, srt_strerror(err, sysErr));
            } else if (err == SRT_ECONNREJ) {
                snprintf(message, sizeof(message),
                         "The stream refused the connection: %s. (%s)",
                         srt_rejectreason_str(reject), srt_strerror(err, sysErr));
            } else {
                snprintf(message, sizeof(message), "%s", srt_strerror(err, sysErr));
            }
            goto cleanup;
        }

        s->connectedAt = srtNow();

        ManifoldSRTConnectionInfo info;
        readConnectionInfo(sock, connectSeconds, s->latencyMs, &info);
        NSLog(@"[SRT] CONNECTED in %.3fs — negotiated rcv latency %d ms | payload %d bytes | "
              @"mtu %d | %s | peer %d.%d.%d",
              info.connectSeconds, info.negotiatedLatencyMs, info.payloadSize, info.mss,
              ManifoldSRTKeyMaterialStateName(info.kmState),
              (info.peerVersion >> 16) & 0xff, (info.peerVersion >> 8) & 0xff, info.peerVersion & 0xff);
        if (s->callbacks.onConnected) {
            s->callbacks.onConnected(s->callbacks.context, s->generation, &info);
        }
    }

    // ── 4. the custom AVIOContext ──────────────────────────────────────────────
    ioBuffer = av_malloc(kSRTIOBufferSize);
    if (!ioBuffer) {
        NSLog(@"[SRT] av_malloc failed");
        strlcpy(message, "Out of memory starting the stream.", sizeof(message));
        goto cleanup;
    }

    avio = avio_alloc_context(ioBuffer, kSRTIOBufferSize,
                              0,        // write_flag: read-only
                              s,        // opaque -> the read callback's state
                              srtReadPacket,
                              NULL,     // no write
                              NULL);    // NO SEEK. Sets seekable = 0, which is the truth
                                        // about a live socket and stops the demuxer from
                                        // ever trying to rewind.
    if (!avio) {
        // avio_alloc_context did NOT take ownership — the buffer is still ours.
        NSLog(@"[SRT] avio_alloc_context failed");
        av_free(ioBuffer);
        ioBuffer = NULL;
        strlcpy(message, "Out of memory starting the stream.", sizeof(message));
        goto cleanup;
    }
    ioBuffer = NULL;   // ownership has moved into avio->buffer; free it from there only.

    // ── 5. the AVFormatContext ─────────────────────────────────────────────────
    // It must be allocated BY US and have ->pb assigned BEFORE avformat_open_input, or
    // libavformat allocates its own and goes looking for a protocol it does not have.
    mpegts = av_find_input_format("mpegts");
    if (!mpegts) {
        NSLog(@"[SRT] av_find_input_format(\"mpegts\") returned NULL — the mpegts demuxer "
              @"is not in this FFmpeg build. See ThirdParty/ffmpeg/README.md.");
        strlcpy(message, "This build can’t read MPEG-TS.", sizeof(message));
        goto cleanup;
    }

    fmt = avformat_alloc_context();
    if (!fmt) {
        NSLog(@"[SRT] avformat_alloc_context failed");
        strlcpy(message, "Out of memory starting the stream.", sizeof(message));
        goto cleanup;
    }

    fmt->pb = avio;
    // Explicit, although init_input would also set it. It is what tells
    // avformat_close_input to leave `pb` alone — without it, close would call
    // avio_close(pb) -> ffurl_close(pb->opaque) on a pointer that is our state struct
    // and not a URLContext. That is a crash, not a leak.
    fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
    fmt->interrupt_callback.callback = srtInterrupt;
    fmt->interrupt_callback.opaque = s;
    // Stated rather than inherited: the discovery facts below are only as good as the
    // window they were derived from, and that window should be readable in the log.
    fmt->probesize = 2 * 1024 * 1024;
    fmt->max_analyze_duration = 5 * AV_TIME_BASE;

    // Passing the input format explicitly skips probing entirely — we know what this is,
    // and probing a live socket means buffering before the first packet. The URL is ""
    // and not NULL: nothing here opens a URL (there is no protocol to open one with), and
    // an empty string keeps libavformat's own logging from dereferencing a null name.
    {
        const int openResult = avformat_open_input(&fmt, "", mpegts, NULL);
        if (openResult < 0) {
            char errbuf[AV_ERROR_MAX_STRING_SIZE] = {0};
            av_strerror(openResult, errbuf, sizeof(errbuf));
            NSLog(@"[SRT] avformat_open_input failed: %s (%d)", errbuf, openResult);
            // fmt has ALREADY been freed and NULLed by avformat_open_input. Do not touch
            // it. avio is still ours — the cleanup block frees it through the local.
            fmt = NULL;
            // AVERROR_EXIT here means our own interrupt callback fired: the user stopped
            // us mid-open, which is not a failure to report.
            reason = (openResult == AVERROR_EXIT) ? ManifoldSRTEndReasonStopped
                                                  : ManifoldSRTEndReasonSetupFailed;
            strlcpy(message, "Couldn’t read the stream.", sizeof(message));
            goto cleanup;
        }
    }

    {
        const int infoResult = avformat_find_stream_info(fmt, NULL);
        if (infoResult < 0) {
            char errbuf[AV_ERROR_MAX_STRING_SIZE] = {0};
            av_strerror(infoResult, errbuf, sizeof(errbuf));
            NSLog(@"[SRT] avformat_find_stream_info failed: %s (%d)", errbuf, infoResult);
            reason = (infoResult == AVERROR_EXIT) ? ManifoldSRTEndReasonStopped
                                                  : ManifoldSRTEndReasonSetupFailed;
            strlcpy(message, "Couldn’t identify the stream’s contents.", sizeof(message));
            goto cleanup;
        }
    }

    // ── 6. choose the video stream ─────────────────────────────────────────────
    // av_find_best_stream rather than "the first video stream": a contribution feed can
    // legitimately carry more than one (a program with a backup encode, or a still-image
    // PID), and libavformat's own ranking — by bitrate, then frame count, then index —
    // is the answer we would otherwise be reimplementing worse. NULL decoder-out: this
    // build has no H.264 DECODER (only the parser), and passing a decoder pointer would
    // make find_best_stream reject the stream for having none.
    s->videoIndex = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    logStreamDiscovery(fmt, s->videoIndex);
    if (s->videoIndex < 0) {
        NSLog(@"[SRT] no video stream in this program — nothing to display");
        strlcpy(message, "That stream carries no video.", sizeof(message));
        goto cleanup;
    }

    {
        ManifoldSRTVideoFormat format;
        fillVideoFormat(fmt, s->videoIndex, &format);
        if (s->callbacks.onVideoFormat) {
            s->callbacks.onVideoFormat(s->callbacks.context, s->generation, &format);
        }
    }

    s->reader = ManifoldSRTAccessUnitReaderCreate();
    if (!s->reader) {
        NSLog(@"[SRT] access-unit reader alloc failed");
        strlcpy(message, "Out of memory starting the stream.", sizeof(message));
        goto cleanup;
    }
    ManifoldSRTAccessUnitReaderSetHandler(s->reader, srtForwardAccessUnit, s);

    pkt = av_packet_alloc();
    if (!pkt) {
        NSLog(@"[SRT] av_packet_alloc failed");
        strlcpy(message, "Out of memory starting the stream.", sizeof(message));
        goto cleanup;
    }

    // ── 7. the read loop ───────────────────────────────────────────────────────
    reason = ManifoldSRTEndReasonStopped;
    while (srtShouldRun(s)) {
        int readResult = 0;
        @autoreleasepool {
            readResult = av_read_frame(fmt, pkt);
            if (readResult >= 0) {
                // Video only. Every other stream — the AAC track above all — is
                // unref'd and gone; see the note in logStreamDiscovery for why that
                // is a no-op rather than a leak waiting to happen.
                if (pkt->stream_index == s->videoIndex) {
                    ManifoldSRTAccessUnitReaderSubmitPacket(s->reader, pkt->data, (size_t)pkt->size,
                                                            pkt->pts, pkt->dts);
                }
                av_packet_unref(pkt);
            }
        }

        if (readResult < 0) {
            if (readResult == AVERROR_EXIT) {
                NSLog(@"[SRT] stopping as asked");
                reason = ManifoldSRTEndReasonStopped;
            } else if (readResult == AVERROR_EOF) {
                // The read callback latched WHICH kind of EOF this is; both arrive here
                // indistinguishably. A demuxer-originated EOF (no callback involved)
                // leaves eofReason at its zero value, which is Stopped — so fall back to
                // PeerClosed for that case rather than reporting a stop nobody asked for.
                NSLog(@"[SRT] end of stream");
                reason = s->eofReason != ManifoldSRTEndReasonStopped ? s->eofReason
                                                                    : ManifoldSRTEndReasonPeerClosed;
                strlcpy(message,
                        reason == ManifoldSRTEndReasonConnectionLost
                            ? "The connection to the stream was lost."
                            : "The stream ended.",
                        sizeof(message));
            } else {
                char errbuf[AV_ERROR_MAX_STRING_SIZE] = {0};
                av_strerror(readResult, errbuf, sizeof(errbuf));
                NSLog(@"[SRT] av_read_frame failed: %s (%d)", errbuf, readResult);
                reason = ManifoldSRTEndReasonTransportError;
                strlcpy(message, "The stream stopped unexpectedly.", sizeof(message));
            }
            break;
        }
    }

    NSLog(@"[SRT] ══ session summary ══ %.1fs connected | msgs=%llu bytes=%llu recvTimeouts=%llu",
          srtNow() - s->connectedAt, (unsigned long long)s->messagesIn,
          (unsigned long long)s->bytesIn, (unsigned long long)s->recvTimeouts);

cleanup:
    // Reverse order of acquisition. Every one of these is a no-op on a NULL/invalid
    // handle, so a failure at any step above lands here and unwinds exactly what it got.
    if (res) freeaddrinfo(res);
    if (pkt) av_packet_free(&pkt);

    // With AVFMT_FLAG_CUSTOM_IO set, this NULLs `pb` internally and frees NEITHER the
    // AVIOContext NOR its buffer. Both are freed below, through our own local.
    if (fmt) avformat_close_input(&fmt);

    if (avio) {
        // Read the buffer back OUT OF the context: libavformat is entitled to have
        // replaced it, and freeing the original pointer would free the wrong block.
        av_freep(&avio->buffer);
        avio_context_free(&avio);
    }
    // Only reachable if av_malloc succeeded and avio_alloc_context was never reached;
    // ioBuffer is NULLed the moment ownership moves into the context, so this can never
    // double-free the block freed just above.
    if (ioBuffer) av_free(ioBuffer);

    // The socket dies LAST, after the demuxer is finished with it, so the read callback
    // can never be entered against a closed socket.
    if (sock != SRT_INVALID_SOCK) srt_close(sock);
    s->sock = SRT_INVALID_SOCK;
    if (srtStarted) srt_cleanup();

    // ── onEnded IS THE LAST CALLBACK, AND IT FIRES BEFORE THE JOIN COMPLETES ───
    // Which is what makes it the right place for the consumer to release everything
    // this thread owns — the VTDecompressionSession, the promote session, the pixel
    // pool. All of them are single-thread-owned by contract, and this is the only
    // instant at which that thread is still alive and guaranteed idle.
    //
    // The reader is deliberately NOT destroyed here. It is torn down in Stop, on main,
    // AFTER the join — because ManifoldSRTSessionCopyReaderStats is callable from main
    // while the session runs, and freeing the reader on this thread would open a
    // use-after-free window against a 1 Hz diagnostic poll. A torn read of a counter is
    // acceptable; a dangling pointer is not.
    if (s->callbacks.onEnded) {
        s->callbacks.onEnded(s->callbacks.context, s->generation,
                             reason, message[0] ? message : NULL);
    }

    NSLog(@"[SRT] ══ stopped ══");
    dispatch_semaphore_signal(s->finished);   // releases the join in ManifoldSRTSessionStop()
}

#pragma mark - Public entry points

ManifoldSRTSession *ManifoldSRTSessionCreate(const ManifoldSRTSessionCallbacks *callbacks) {
    NSCAssert(NSThread.isMainThread, @"SRT session lifecycle is main-thread only");
    if (!callbacks) return NULL;
    ManifoldSRTSession *s = calloc(1, sizeof(ManifoldSRTSession));
    if (!s) return NULL;
    s->callbacks = *callbacks;
    s->runLock = OS_UNFAIR_LOCK_INIT;
    s->sock = SRT_INVALID_SOCK;
    s->videoIndex = -1;
    return s;
}

bool ManifoldSRTSessionStart(ManifoldSRTSession *s, const ManifoldSRTSessionConfig *config) {
    NSCAssert(NSThread.isMainThread, @"SRT session lifecycle is main-thread only");
    if (!s || !config || !config->host || !config->port) return false;
    if (s->thread) {
        NSLog(@"[SRT] a session is already running — stop it first");
        return false;
    }
    if (strlen(config->host) >= sizeof(s->host) || strlen(config->port) >= sizeof(s->port)) {
        NSLog(@"[SRT] host or port too long");
        return false;
    }
    if (config->passphrase && strlen(config->passphrase) >= sizeof(s->passphrase)) {
        // 79 chars is SRT's own ceiling; a longer one is a typo, not a stream we can dial.
        NSLog(@"[SRT] passphrase too long (SRT allows at most 79 characters)");
        return false;
    }
    if (config->streamId && strlen(config->streamId) >= sizeof(s->streamId)) {
        // REFUSED, NOT TRUNCATED. A shortened stream id is a valid string addressing something
        // other than what the user asked for, and the server's rejection would not say so.
        NSLog(@"[SRT] stream id too long (SRT allows at most 512 bytes)");
        return false;
    }

    strlcpy(s->host, config->host, sizeof(s->host));
    strlcpy(s->port, config->port, sizeof(s->port));
    memset(s->passphrase, 0, sizeof(s->passphrase));
    if (config->passphrase) strlcpy(s->passphrase, config->passphrase, sizeof(s->passphrase));
    memset(s->streamId, 0, sizeof(s->streamId));
    if (config->streamId) strlcpy(s->streamId, config->streamId, sizeof(s->streamId));
    s->latencyMs = config->latencyMs;
    s->generation = config->generation;

    s->msgLen = s->msgOff = 0;
    s->messagesIn = s->bytesIn = s->recvTimeouts = 0;
    s->sawFirstPacket = s->warnedSilent = false;
    s->eofReason = ManifoldSRTEndReasonStopped;
    s->videoIndex = -1;
    if (s->reader) { ManifoldSRTAccessUnitReaderDestroy(s->reader); s->reader = NULL; }
    s->shouldRun = true;
    s->finished = dispatch_semaphore_create(0);

    // NDIService's audio pump, one for one: a joinable Thread, named, .userInteractive,
    // a lock-protected run flag, and a semaphore join at teardown.
    NSThread *thread = [[NSThread alloc] initWithBlock:^{ runSession(s); }];
    thread.name = @"com.manifold.srt.session";
    thread.qualityOfService = NSQualityOfServiceUserInteractive;
    s->thread = thread;
    [thread start];
    return true;
}

void ManifoldSRTSessionStop(ManifoldSRTSession *s) {
    NSCAssert(NSThread.isMainThread, @"SRT session lifecycle is main-thread only");
    if (!s || !s->thread) return;

    // Clear the flag, then BLOCK until the thread has actually exited. The join is what
    // guarantees no srt_recvmsg2 is in flight against a socket the cleanup path is about
    // to close, no callback is in flight against the consumer, and no access unit can
    // reach a decoder the caller is about to release.
    os_unfair_lock_lock(&s->runLock);
    s->shouldRun = false;
    os_unfair_lock_unlock(&s->runLock);

    dispatch_semaphore_wait(s->finished, DISPATCH_TIME_FOREVER);

    // Safe only now: the join above proves the session thread is gone, so nothing can be
    // inside the reader. See the note at the end of runSession.
    if (s->reader) { ManifoldSRTAccessUnitReaderDestroy(s->reader); s->reader = NULL; }

    s->thread = nil;
    s->finished = nil;
}

void ManifoldSRTSessionDestroy(ManifoldSRTSession *s) {
    NSCAssert(NSThread.isMainThread, @"SRT session lifecycle is main-thread only");
    if (!s) return;
    ManifoldSRTSessionStop(s);
    memset(s->passphrase, 0, sizeof(s->passphrase));
    free(s);
}

void ManifoldSRTSessionCopyReaderStats(const ManifoldSRTSession *s,
                                       ManifoldSRTAccessUnitReaderStats *outStats) {
    if (!outStats) return;
    ManifoldSRTAccessUnitReaderCopyStats(s ? s->reader : NULL, outStats);
}

void ManifoldSRTSessionCopyReaderBuilderStats(const ManifoldSRTSession *s,
                                              ManifoldH264AccessUnitBuilderStats *outStats) {
    if (!outStats) return;
    ManifoldSRTAccessUnitReaderCopyBuilderStats(s ? s->reader : NULL, outStats);
}

void ManifoldSRTSessionCopyTransportStats(const ManifoldSRTSession *s,
                                          uint64_t *outMessages,
                                          uint64_t *outBytes,
                                          uint64_t *outRecvTimeouts) {
    if (outMessages)     *outMessages     = s ? s->messagesIn   : 0;
    if (outBytes)        *outBytes        = s ? s->bytesIn      : 0;
    if (outRecvTimeouts) *outRecvTimeouts = s ? s->recvTimeouts : 0;
}
