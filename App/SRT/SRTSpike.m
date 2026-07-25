//
//  SRTSpike.m
//  Manifold
//
//  SRT STAGE 2 — TRANSPORT SPIKE. TEMPORARY, DEBUG-ONLY. See SRTSpike.h for scope.
//
//  ── THE SHAPE, IN ONE PARAGRAPH ────────────────────────────────────────────────
//  One thread does everything. libsrt owns the socket; libavformat is handed a custom
//  AVIOContext whose read callback performs the blocking srt_recvmsg2. Because that
//  callback is invoked SYNCHRONOUSLY from inside av_read_frame, the network thread and
//  the demux thread are the same thread by construction — there is no queue, no
//  handoff, and no second thread to get the shutdown ordering wrong between. Nothing
//  here touches the render thread or the main thread after start().
//
//  ── WHY THERE IS NO URL STRING PASSED TO LIBAVFORMAT ───────────────────────────
//  ThirdParty/ffmpeg is built --disable-network: ff_file_protocol is the only protocol
//  compiled in and avformat_network_init() is a stub. avformat_open_input("srt://…")
//  cannot work, and that is the point — it is the guardrail that keeps every byte
//  arriving through the AVIOContext below rather than through a second, competing
//  transport implementation inside the same binary. See ThirdParty/ffmpeg/README.md.
//

#ifdef DEBUG

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>   // CACurrentMediaTime — the same clock NDIService's pump uses

#include <os/lock.h>
#include <netdb.h>
#include <string.h>

#include <srt/srt.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/pixdesc.h>

#pragma mark - Constants

/// The spike target. HARDCODED ON PURPOSE for this stage: the stream-bookmark UI
/// integration is a later stage, and a URL-entry path here would be a second, parallel
/// way to name a stream that then has to be kept in step with the shipping one.
static const char *const kSRTSpikeURL = "srt://127.0.0.1:9000";

/// Bound on the blocking receive, and therefore the bound on shutdown latency. This is
/// the single option that makes a clean stop possible: without it srt_recvmsg2 blocks
/// forever, the read callback never returns, av_read_frame never unwinds, and the join
/// in ManifoldSRTSpikeStop() would hang until the publisher happened to send something.
static const int kSRTSpikeRecvTimeoutMs = 200;

/// Connect timeout. libsrt's caller default is already 3000 ms; set explicitly so the
/// failure path's TIMING is a property of this file rather than of a library default
/// that could change under us.
static const int kSRTSpikeConnectTimeoutMs = 3000;

/// The AVIOContext's internal buffer. 64 KiB is the usual libavformat figure and is far
/// larger than one SRT message, so libavformat almost always reads out of its own buffer
/// and our callback is entered ~50 times per 64 KiB rather than per TS packet.
static const int kSRTSpikeIOBufferSize = 64 * 1024;

/// One SRT message. SRT live mode is MESSAGE-oriented: srt_recvmsg2 delivers whole
/// messages and FAILS with SRT_ELARGEMSG — DISCARDING the message — if the buffer it is
/// given is smaller than the pending one. The MPEG-TS default payload is 1316 bytes
/// (7 × 188) and the ceiling with a 1500-byte MTU is 1456, so this is sized to the
/// ceiling and never to what we expect to see.
#define SRT_SPIKE_MSG_MAX 1536

/// How many video packets the B-frame probe observes before it reports. See the probe
/// discussion at logBFrameProbe().
static const uint64_t kSRTSpikeBFrameProbePackets = 200;

/// Rollup cadence, matching [WHEP-RTP] and [LIVECLOCK].
static const double kSRTSpikeRollupInterval = 1.0;

/// After this much post-connect silence, say so. Connected-but-silent is a real and
/// common state (publisher not started, wrong stream id) and it must not look like a
/// hang. Mirrors the "[WHEP-RTP] no RTP for %ds" line.
static const double kSRTSpikeSilenceWarnAfter = 5.0;

#pragma mark - State

/// Per-stream demux counters. Written and read ONLY on the spike thread, so no locking:
/// the rollup is emitted from the same thread that fills these, whether it was woken by
/// a packet or by a receive timeout.
typedef struct {
    int index;
    enum AVMediaType type;
    const char *codecName;      // avcodec_get_name returns a static string; safe to hold
    double tbSec;               // stream time_base in seconds, for turning ticks into ms

    uint64_t pkts, bytes, keyframes;
    uint64_t noPTS, noDTS;

    // CONTINUITY IS MEASURED ON DTS, NOT PTS, AND THE DISTINCTION IS THE WHOLE POINT.
    // DTS is monotonic in decode order, so dtsBack is a genuine anomaly. PTS is NOT
    // monotonic in decode order when B-frames are present — ptsBack going up while
    // dtsBack stays at zero IS the B-frame signature, not a fault.
    int64_t lastPTS, lastDTS;
    bool havePTS, haveDTS;
    uint64_t ptsBack, dtsBack;
    double maxDtsGapMs;
} SRTSpikeStreamStats;

typedef struct {
    // ── transport (written by the read callback) ──
    SRTSOCKET sock;
    unsigned char msg[SRT_SPIKE_MSG_MAX];
    int msgLen, msgOff;             // the staged message and how much of it libavformat has taken
    uint64_t messagesIn, bytesIn, recvTimeouts;

    // ── run flag. The ONLY field touched by two threads. ──
    os_unfair_lock runLock;
    bool shouldRun;

    // ── demux (written by the read loop; allocated after find_stream_info) ──
    SRTSpikeStreamStats *streams;
    int streamCount;
    int videoIndex;

    // ── B-frame probe (video stream only) ──
    uint64_t probeCount, probePtsNeDts;
    int64_t probeMinDelta, probeMaxDelta;
    bool probeReported;

    // ── rollup bookkeeping ──
    double startedAt, lastRollupAt, connectedAt;
    uint64_t rollupMessages, rollupBytes, rollupTimeouts;
    bool warnedSilent, sawFirstPacket;
} SRTSpikeState;

/// Session globals. Touched ONLY from the main thread (start/stop), which is asserted.
static SRTSpikeState *gSpike;
static NSThread *gSpikeThread;
static dispatch_semaphore_t gSpikeFinished;

static bool spikeShouldRun(SRTSpikeState *s) {
    os_unfair_lock_lock(&s->runLock);
    const bool run = s->shouldRun;
    os_unfair_lock_unlock(&s->runLock);
    return run;
}

#pragma mark - Naming helpers

/// Every enum this spike reports is reported BY NAME. A CICP integer in a log is a
/// second lookup the reader has to perform, and this stage exists to be read.
static const char *spikeColorPrimariesName(enum AVColorPrimaries v) {
    const char *n = av_color_primaries_name(v);
    return n ? n : "?";
}
static const char *spikeColorTransferName(enum AVColorTransferCharacteristic v) {
    const char *n = av_color_transfer_name(v);
    return n ? n : "?";
}
static const char *spikeColorSpaceName(enum AVColorSpace v) {
    const char *n = av_color_space_name(v);
    return n ? n : "?";
}
static const char *spikeColorRangeName(enum AVColorRange v) {
    const char *n = av_color_range_name(v);
    return n ? n : "?";
}

/// "signalled" vs "UNSPECIFIED" stated in words, because the difference is the entire
/// point of question 5. CICP 2 is "unspecified" for primaries/transfer/matrix; range
/// uses 0. A value of 0 for primaries/transfer/matrix is "reserved" and would itself be
/// a finding, so it is not folded in with unspecified.
static const char *spikeSignalled(int cicp, int unspecifiedValue) {
    return cicp == unspecifiedValue ? "UNSPECIFIED (not signalled)" : "signalled";
}

/// SRT key-material state — i.e. whether the stream is actually encrypted right now.
static const char *spikeKMStateName(int km) {
    switch (km) {
        case SRT_KM_S_UNSECURED:  return "UNSECURED (no encryption)";
        case SRT_KM_S_SECURING:   return "SECURING (exchanging key material)";
        case SRT_KM_S_SECURED:    return "SECURED (encrypted, decrypting ok)";
        case SRT_KM_S_NOSECRET:   return "NOSECRET (encrypted, we have no passphrase)";
        case SRT_KM_S_BADSECRET:  return "BADSECRET (encrypted, wrong passphrase)";
        default:                  return "?";
    }
}

/// Annex-B start codes vs an avcC/hvcC configuration record. For MPEG-TS the expected
/// answer is Annex-B or no extradata at all (parameter sets arrive in-band), so an avcC
/// here would be a surprise worth knowing about before the decoder stage is designed.
static const char *spikeExtradataKind(const uint8_t *ed, int size) {
    if (!ed || size <= 0) return "none";
    if (size >= 4 && ed[0] == 0 && ed[1] == 0 && ed[2] == 0 && ed[3] == 1) return "Annex-B (4-byte start code)";
    if (size >= 3 && ed[0] == 0 && ed[1] == 0 && ed[2] == 1)               return "Annex-B (3-byte start code)";
    if (size >= 1 && ed[0] == 1)                                           return "avcC/hvcC (length-prefixed)";
    return "unrecognised";
}

static double spikeNow(void) { return CACurrentMediaTime(); }

#pragma mark - Rollup

static void logBFrameProbe(SRTSpikeState *s, AVCodecParameters *videoPar);

/// The per-second line. Called from BOTH the read loop (a packet arrived) and the read
/// callback's timeout path (nothing arrived) — the second is what keeps the log alive
/// through a silent stream instead of leaving the reader unsure whether we are stuck.
static void spikeRollup(SRTSpikeState *s) {
    const double now = spikeNow();
    const double since = now - s->lastRollupAt;
    if (since < kSRTSpikeRollupInterval) return;
    s->lastRollupAt = now;

    const uint64_t msgs = s->messagesIn - s->rollupMessages;
    const uint64_t bytes = s->bytesIn - s->rollupBytes;
    const uint64_t timeouts = s->recvTimeouts - s->rollupTimeouts;
    s->rollupMessages = s->messagesIn;
    s->rollupBytes = s->bytesIn;
    s->rollupTimeouts = s->recvTimeouts;

    const double elapsed = now - s->connectedAt;

    if (!s->sawFirstPacket && msgs == 0) {
        if (!s->warnedSilent && elapsed >= kSRTSpikeSilenceWarnAfter) {
            s->warnedSilent = true;
            NSLog(@"[SRT-SPIKE] connected for %.0fs but NOT ONE BYTE has arrived. The socket is up "
                  @"and the publisher is silent — check that something is actually sending to %s "
                  @"(and, on a real server, that the stream id matches).", elapsed, kSRTSpikeURL);
        }
        return;   // silence does not need a counters line every second
    }

    NSLog(@"[SRT-SPIKE] +%.0fs  transport: msgs=%llu bytes=%llu (%.2f Mb/s) recvTimeouts=%llu",
          elapsed, (unsigned long long)msgs, (unsigned long long)bytes,
          (double)bytes * 8.0 / (since * 1e6), (unsigned long long)timeouts);

    for (int i = 0; i < s->streamCount; i++) {
        SRTSpikeStreamStats *st = &s->streams[i];
        if (st->pkts == 0) continue;
        NSLog(@"[SRT-SPIKE]        stream %d %-5s %-6s pkts=%llu key=%llu bytes=%llu  "
              @"dtsBack=%llu ptsBack=%llu maxDtsGap=%.1fms  noPTS=%llu noDTS=%llu",
              st->index,
              st->type == AVMEDIA_TYPE_VIDEO ? "video" : (st->type == AVMEDIA_TYPE_AUDIO ? "audio" : "other"),
              st->codecName,
              (unsigned long long)st->pkts, (unsigned long long)st->keyframes,
              (unsigned long long)st->bytes,
              (unsigned long long)st->dtsBack, (unsigned long long)st->ptsBack,
              st->maxDtsGapMs,
              (unsigned long long)st->noPTS, (unsigned long long)st->noDTS);
    }
}

#pragma mark - AVIOContext callbacks

/// THE read callback. Invoked synchronously by libavformat from inside
/// avformat_open_input, avformat_find_stream_info and av_read_frame — so this function,
/// and the blocking srt_recvmsg2 inside it, run on the spike thread and nowhere else.
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
static int spikeReadPacket(void *opaque, uint8_t *buf, int bufSize) {
    SRTSpikeState *s = (SRTSpikeState *)opaque;
    if (bufSize <= 0) return AVERROR(EINVAL);

    if (s->msgOff >= s->msgLen) {
        s->msgOff = s->msgLen = 0;
        for (;;) {
            if (!spikeShouldRun(s)) return AVERROR_EXIT;

            SRT_MSGCTRL ctrl;
            srt_msgctrl_init(&ctrl);
            const int n = srt_recvmsg2(s->sock, (char *)s->msg, (int)sizeof(s->msg), &ctrl);

            if (n > 0) {
                s->msgLen = n;
                s->messagesIn++;
                s->bytesIn += (uint64_t)n;
                break;
            }
            if (n == 0) {
                NSLog(@"[SRT-SPIKE] peer closed the connection (zero-length message) — end of stream");
                return AVERROR_EOF;
            }

            int sysErr = 0;
            const int err = srt_getlasterror(&sysErr);
            srt_clearlasterror();

            if (err == SRT_ETIMEOUT || err == SRT_EASYNCRCV) {
                s->recvTimeouts++;
                spikeRollup(s);         // keep the log alive through silence
                continue;
            }
            if (err == SRT_ECONNLOST || err == SRT_ENOCONN || err == SRT_EINVSOCK) {
                NSLog(@"[SRT-SPIKE] connection lost: %s (srt errno %d, sys errno %d) — end of stream",
                      srt_strerror(err, sysErr), err, sysErr);
                return AVERROR_EOF;
            }
            NSLog(@"[SRT-SPIKE] srt_recvmsg2 failed: %s (srt errno %d, sys errno %d)",
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
/// is what makes ⌃⌥⇧D reliable during the open/analyse window, not just during the
/// steady-state av_read_frame loop.
static int spikeInterrupt(void *opaque) {
    return spikeShouldRun((SRTSpikeState *)opaque) ? 0 : 1;
}

#pragma mark - Stream discovery logging

/// Everything find_stream_info learned, for EVERY stream. This block and the B-frame
/// probe are the two outputs this whole stage exists to produce.
static void logStreamDiscovery(AVFormatContext *fmt, SRTSpikeState *s) {
    NSLog(@"[SRT-SPIKE] ── stream discovery ─────────────────────────────────────────");
    NSLog(@"[SRT-SPIKE] container: %s | streams=%u programs=%u | bit_rate=%lld | "
          @"probesize=%lld max_analyze_duration=%lldus",
          fmt->iformat ? fmt->iformat->name : "?",
          fmt->nb_streams, fmt->nb_programs, (long long)fmt->bit_rate,
          (long long)fmt->probesize, (long long)fmt->max_analyze_duration);

    for (unsigned p = 0; p < fmt->nb_programs; p++) {
        AVProgram *prog = fmt->programs[p];
        NSMutableString *members = [NSMutableString string];
        for (unsigned k = 0; k < prog->nb_stream_indexes; k++) {
            [members appendFormat:@"%s%u", k ? "," : "", prog->stream_index[k]];
        }
        NSLog(@"[SRT-SPIKE] program %d (pmt_pid %d): streams [%@]",
              prog->program_num, prog->pmt_pid, members);
    }

    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        AVStream *st = fmt->streams[i];
        AVCodecParameters *par = st->codecpar;
        const char *codec = avcodec_get_name(par->codec_id);
        const char *type = av_get_media_type_string(par->codec_type);

        NSLog(@"[SRT-SPIKE] stream %u: %s / %s (codec_id %d) | pid=0x%x | time_base=%d/%d",
              i, type ? type : "?", codec, (int)par->codec_id, (unsigned)st->id,
              st->time_base.num, st->time_base.den);

        if (par->codec_type != AVMEDIA_TYPE_VIDEO) {
            if (par->codec_type == AVMEDIA_TYPE_AUDIO) {
                NSLog(@"[SRT-SPIKE]     audio: %d Hz, %d ch, sample_fmt=%d, bit_rate=%lld",
                      par->sample_rate, par->ch_layout.nb_channels, par->format,
                      (long long)par->bit_rate);
            }
            continue;
        }

        const char *profile = avcodec_profile_name(par->codec_id, par->profile);
        const char *pixfmt = av_get_pix_fmt_name((enum AVPixelFormat)par->format);
        const AVRational guessed = av_guess_frame_rate(fmt, st, NULL);

        NSLog(@"[SRT-SPIKE]     video: %dx%d | profile=%s (%d) level=%d (%.1f) | pix_fmt=%s",
              par->width, par->height,
              profile ? profile : "UNKNOWN", par->profile,
              par->level, par->level / 10.0,
              pixfmt ? pixfmt : "UNKNOWN");
        NSLog(@"[SRT-SPIKE]     rate: guessed=%d/%d (%.3f fps) avg=%d/%d r=%d/%d | sar=%d/%d",
              guessed.num, guessed.den,
              guessed.den ? (double)guessed.num / guessed.den : 0.0,
              st->avg_frame_rate.num, st->avg_frame_rate.den,
              st->r_frame_rate.num, st->r_frame_rate.den,
              par->sample_aspect_ratio.num, par->sample_aspect_ratio.den);
        NSLog(@"[SRT-SPIKE]     extradata: %d bytes, %s",
              par->extradata_size, spikeExtradataKind(par->extradata, par->extradata_size));

        // ── COLORIMETRY. The thing SRT can do honestly that WHEP cannot. ──
        //
        // ⚠️ READ THE CAVEAT BEFORE DRAWING A CONCLUSION FROM THESE FOUR LINES. This
        // FFmpeg is built with the h264 PARSER but NO h264 DECODER (verified against the
        // archive: libavcodec has dnxhd, aac and pcm decoders only). find_stream_info
        // therefore fills these fields from the SPS VUI via the parser rather than from a
        // decoder pass. If they come back UNSPECIFIED, that is evidence about the SENDER
        // *only if* the parser propagates VUI colour — which is the first thing to
        // re-check before concluding "OBS does not signal colorimetry". The extradata
        // line above is logged partly so that question stays answerable.
        NSLog(@"[SRT-SPIKE]     color_primaries: %s — %s",
              spikeColorPrimariesName(par->color_primaries),
              spikeSignalled((int)par->color_primaries, (int)AVCOL_PRI_UNSPECIFIED));
        NSLog(@"[SRT-SPIKE]     color_trc:       %s — %s",
              spikeColorTransferName(par->color_trc),
              spikeSignalled((int)par->color_trc, (int)AVCOL_TRC_UNSPECIFIED));
        NSLog(@"[SRT-SPIKE]     color_space:     %s — %s",
              spikeColorSpaceName(par->color_space),
              spikeSignalled((int)par->color_space, (int)AVCOL_SPC_UNSPECIFIED));
        NSLog(@"[SRT-SPIKE]     color_range:     %s — %s",
              spikeColorRangeName(par->color_range),
              spikeSignalled((int)par->color_range, (int)AVCOL_RANGE_UNSPECIFIED));
        NSLog(@"[SRT-SPIKE]     chroma_location: %d | field_order: %d",
              (int)par->chroma_location, (int)par->field_order);

        // ── THE B-FRAME HEADER CLAIM. Recorded, NOT TRUSTED. ──
        //
        // video_delay is the number of frames of reorder the DECODER will need. Without a
        // decoder in this build it comes from the SPS VUI's bitstream_restriction_flag /
        // num_reorder_frames, and a great many real encoders never emit that. So a 0 here
        // means "not stated", NOT "no B-frames". The empirical probe is the answer.
        NSLog(@"[SRT-SPIKE]     ⚠️ video_delay (has_b_frames) = %d — HEADER CLAIM ONLY; "
              @"the packet probe below is the real answer", par->video_delay);
    }
    NSLog(@"[SRT-SPIKE] ─────────────────────────────────────────────────────────────");
}

/// The empirical B-frame answer, and the reason this stage exists.
///
/// Three places in the WHEP decode path assume decode order == display order. If a real
/// SRT feed carries B-frames, that assumption has to be paid for BEFORE the decode stage
/// is designed rather than debugged afterwards as a "stuttering" bug.
///
/// The instrument is deliberately not the header field: over the first N video packets,
/// count how many carry pts != dts and record the extremes of (pts - dts). A single
/// packet with pts > dts proves reorder. Zero over 200 packets, with both timestamps
/// present throughout, is decent evidence of a baseline/no-reorder stream — and the
/// "both present" qualifier matters, which is why noPTS/noDTS are reported alongside.
static void logBFrameProbe(SRTSpikeState *s, AVCodecParameters *videoPar) {
    if (s->probeReported || s->videoIndex < 0) return;
    s->probeReported = true;

    SRTSpikeStreamStats *v = NULL;
    for (int i = 0; i < s->streamCount; i++) {
        if (s->streams[i].index == s->videoIndex) { v = &s->streams[i]; break; }
    }
    if (!v) return;

    const double tbMs = v->tbSec * 1000.0;
    NSLog(@"[SRT-SPIKE] ⚠️ B-FRAME PROBE over the first %llu video packets:",
          (unsigned long long)s->probeCount);
    NSLog(@"[SRT-SPIKE]     pts != dts on %llu of %llu packets",
          (unsigned long long)s->probePtsNeDts, (unsigned long long)s->probeCount);
    if (s->probePtsNeDts > 0) {
        NSLog(@"[SRT-SPIKE]     (pts - dts): min=%lld max=%lld ticks  =  %.2f .. %.2f ms  "
              @"(time_base %.9fs)",
              (long long)s->probeMinDelta, (long long)s->probeMaxDelta,
              (double)s->probeMinDelta * tbMs, (double)s->probeMaxDelta * tbMs, v->tbSec);
        NSLog(@"[SRT-SPIKE]     VERDICT: THIS STREAM REORDERS. Decode order != display order. "
              @"The WHEP path's three decode-order assumptions do NOT carry over to SRT.");
    } else {
        NSLog(@"[SRT-SPIKE]     VERDICT: no reorder observed in this sample "
              @"(noPTS=%llu noDTS=%llu over the same window — a high count here means the "
              @"sample proves nothing).",
              (unsigned long long)v->noPTS, (unsigned long long)v->noDTS);
    }
    NSLog(@"[SRT-SPIKE]     header claimed video_delay=%d — %s",
          videoPar->video_delay,
          (videoPar->video_delay > 0) == (s->probePtsNeDts > 0) ? "agrees with the packets"
                                                                : "DISAGREES WITH THE PACKETS");
}

#pragma mark - The session

/// Parse `srt://host:port`. Strict by design: anything else fails loudly rather than
/// being half-understood. A general URL parser arrives with the bookmark stage.
static bool parseSpikeURL(const char *url, char *hostOut, size_t hostCap, char *portOut, size_t portCap) {
    static const char scheme[] = "srt://";
    const size_t schemeLen = sizeof(scheme) - 1;
    if (strncmp(url, scheme, schemeLen) != 0) return false;

    const char *authority = url + schemeLen;
    const char *colon = strrchr(authority, ':');
    if (!colon || colon == authority || colon[1] == '\0') return false;

    const size_t hostLen = (size_t)(colon - authority);
    if (hostLen >= hostCap || strlen(colon + 1) >= portCap) return false;

    memcpy(hostOut, authority, hostLen);
    hostOut[hostLen] = '\0';
    strlcpy(portOut, colon + 1, portCap);
    return true;
}

/// Read back and report what the handshake actually negotiated — as distinct from what
/// we asked for. Latency in particular is a NEGOTIATED maximum of the two sides' wishes,
/// so the requested value tells you nothing.
static void logNegotiatedOptions(SRTSOCKET sock, double connectSeconds) {
    int32_t rcvLatency = -1, latency = -1, mss = -1, payload = -1;
    int32_t kmState = -1, rcvKmState = -1, peerVersion = 0, localVersion = 0;
    int len;

    len = sizeof(rcvLatency);   srt_getsockflag(sock, SRTO_RCVLATENCY,  &rcvLatency,   &len);
    len = sizeof(latency);      srt_getsockflag(sock, SRTO_LATENCY,     &latency,      &len);
    len = sizeof(mss);          srt_getsockflag(sock, SRTO_MSS,         &mss,          &len);
    len = sizeof(payload);      srt_getsockflag(sock, SRTO_PAYLOADSIZE, &payload,      &len);
    len = sizeof(kmState);      srt_getsockflag(sock, SRTO_KMSTATE,     &kmState,      &len);
    len = sizeof(rcvKmState);   srt_getsockflag(sock, SRTO_RCVKMSTATE,  &rcvKmState,   &len);
    len = sizeof(peerVersion);  srt_getsockflag(sock, SRTO_PEERVERSION, &peerVersion,  &len);
    len = sizeof(localVersion); srt_getsockflag(sock, SRTO_VERSION,     &localVersion, &len);

    NSLog(@"[SRT-SPIKE] CONNECTED in %.3fs (srt_connection_time %lld us)",
          connectSeconds, (long long)srt_connection_time(sock));
    NSLog(@"[SRT-SPIKE]     latency: rcv=%d ms (SRTO_LATENCY reads %d ms) — NEGOTIATED, "
          @"not what we asked for", rcvLatency, latency);
    NSLog(@"[SRT-SPIKE]     mtu/mss=%d bytes | payload size=%d bytes (%d × 188 TS packets)",
          mss, payload, payload / 188);
    NSLog(@"[SRT-SPIKE]     encryption: %s (agent-side %s)",
          spikeKMStateName(kmState), spikeKMStateName(rcvKmState));
    NSLog(@"[SRT-SPIKE]     version: local %d.%d.%d, peer %d.%d.%d",
          (localVersion >> 16) & 0xff, (localVersion >> 8) & 0xff, localVersion & 0xff,
          (peerVersion >> 16) & 0xff, (peerVersion >> 8) & 0xff, peerVersion & 0xff);
}

/// The whole session, on the spike thread.
///
/// RESOURCE DISCIPLINE — the shape is LibavFrameSource.open()'s: every failure path
/// unwinds exactly what it allocated, in reverse. There is more to unwind here than on
/// any existing path, and two traps in particular:
///
///   1. A FAILED avformat_open_input FREES THE AVFormatContext AND NULLS YOUR POINTER.
///      So `avio` is held in a LOCAL and freed through that local — never through
///      `fmt->pb`, which after a failed open is unreachable.
///   2. WITH AVFMT_FLAG_CUSTOM_IO, avformat_close_input DOES NOT free the AVIOContext OR
///      its buffer. It NULLs `pb` internally precisely so it will not try. Both are ours
///      to free: av_freep(&avio->buffer) then avio_context_free(&avio). And the buffer
///      must be read back OUT OF the context — libavformat may replace it.
static void runSpike(SRTSpikeState *s, dispatch_semaphore_t finished) {
    // Declared up front, ahead of the first `goto cleanup`, so the unwind path can never
    // reference something the jump skipped over.
    SRTSOCKET sock = SRT_INVALID_SOCK;
    unsigned char *ioBuffer = NULL;
    AVIOContext *avio = NULL;
    AVFormatContext *fmt = NULL;
    AVPacket *pkt = NULL;
    struct addrinfo *res = NULL;
    const AVInputFormat *mpegts = NULL;
    AVCodecParameters *videoPar = NULL;
    char host[256] = {0}, port[16] = {0};
    bool srtStarted = false;
    const int previousLogLevel = av_log_get_level();

    s->startedAt = s->lastRollupAt = s->connectedAt = spikeNow();
    s->videoIndex = -1;
    s->probeMinDelta = INT64_MAX;
    s->probeMaxDelta = INT64_MIN;

    NSLog(@"[SRT-SPIKE] ══ start ══ target=%s | libsrt %s | libavformat %s",
          kSRTSpikeURL, SRT_VERSION_STRING, av_version_info());
    NSLog(@"[SRT-SPIKE] transport-only spike: packets are counted and DISCARDED. "
          @"No decode, no display, no UI.");

    // libav's own diagnostics at VERBOSE for the duration. The mpegts demuxer says useful
    // things about PAT/PMT and continuity that would otherwise be below the default INFO,
    // and a failing open is much more legible with them on. Restored at teardown.
    av_log_set_level(AV_LOG_VERBOSE);

    // ── 1. libsrt startup ──────────────────────────────────────────────────────
    // NOTE ON LOGGING: srt_setloghandler is deliberately NOT installed. See the report /
    // the note at the bottom of this file for what that costs and when to add it.
    if (srt_startup() == SRT_ERROR) {
        int sysErr = 0; const int err = srt_getlasterror(&sysErr);
        NSLog(@"[SRT-SPIKE] srt_startup failed: %s (srt errno %d)", srt_strerror(err, sysErr), err);
        goto cleanup;
    }
    srtStarted = true;

    // ── 2. resolve + socket + options ──────────────────────────────────────────
    if (!parseSpikeURL(kSRTSpikeURL, host, sizeof(host), port, sizeof(port))) {
        NSLog(@"[SRT-SPIKE] cannot parse '%s' — expected srt://host:port", kSRTSpikeURL);
        goto cleanup;
    }

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;      // srt_create_socket() defers its family until connect
    hints.ai_socktype = SOCK_DGRAM;   // SRT is UDP underneath
    const int gaiErr = getaddrinfo(host, port, &hints, &res);
    if (gaiErr != 0 || !res) {
        NSLog(@"[SRT-SPIKE] cannot resolve %s:%s — %s", host, port, gai_strerror(gaiErr));
        goto cleanup;
    }

    sock = srt_create_socket();
    if (sock == SRT_INVALID_SOCK) {
        int sysErr = 0; const int err = srt_getlasterror(&sysErr);
        NSLog(@"[SRT-SPIKE] srt_create_socket failed: %s (srt errno %d)", srt_strerror(err, sysErr), err);
        goto cleanup;
    }
    s->sock = sock;

    // SRTO_TRANSTYPE MUST BE SET FIRST. It is a macro option: setting it REWRITES a whole
    // group of others (latency, tsbpd, message API, congestion controller) to that
    // transmission type's defaults, so anything set before it is silently overwritten.
    const int transtype = SRTT_LIVE;
    srt_setsockflag(sock, SRTO_TRANSTYPE, &transtype, sizeof(transtype));

    const int rcvTimeout = kSRTSpikeRecvTimeoutMs;
    const int connTimeout = kSRTSpikeConnectTimeoutMs;
    srt_setsockflag(sock, SRTO_RCVTIMEO,  &rcvTimeout,  sizeof(rcvTimeout));
    srt_setsockflag(sock, SRTO_CONNTIMEO, &connTimeout, sizeof(connTimeout));
    // Latency, payload size and passphrase are LEFT AT THEIR DEFAULTS on purpose: this
    // stage is here to observe what a real publisher negotiates, and pinning our side
    // would be assuming the answer. Encryption arrives with the bookmark stage.

    // ── 3. connect (CALLER only — no listener, no rendezvous) ──────────────────
    const double connectStart = spikeNow();
    const int connectResult = srt_connect(sock, res->ai_addr, (int)res->ai_addrlen);
    const double connectSeconds = spikeNow() - connectStart;
    freeaddrinfo(res);
    res = NULL;

    if (connectResult == SRT_ERROR) {
        // ── WHAT A FAILED CONNECT LOOKS LIKE. Three independent facts, because any one
        //    of them alone is ambiguous: the SRT errno says WHICH STAGE failed, the
        //    system errno says whether the OS refused, and the reject reason is the only
        //    thing that distinguishes "the peer said no, and why" from "nobody answered".
        int sysErr = 0;
        const int err = srt_getlasterror(&sysErr);
        const int reject = srt_getrejectreason(sock);
        NSLog(@"[SRT-SPIKE] CONNECT FAILED after %.3fs to %s:%s", connectSeconds, host, port);
        NSLog(@"[SRT-SPIKE]     srt error:  %s (srt errno %d, sys errno %d: %s)",
              srt_strerror(err, sysErr), err, sysErr, sysErr ? strerror(sysErr) : "none");
        NSLog(@"[SRT-SPIKE]     reject reason: %s (%d)", srt_rejectreason_str(reject), reject);
        if (err == SRT_ENOSERVER) {
            NSLog(@"[SRT-SPIKE]     → nothing answered within %d ms. Nobody is listening on "
                  @"%s:%s, or a firewall is dropping UDP. Note SRT is UDP: a listener that "
                  @"is not running looks EXACTLY like a blocked port.",
                  kSRTSpikeConnectTimeoutMs, host, port);
        } else if (err == SRT_ECONNREJ) {
            NSLog(@"[SRT-SPIKE]     → the peer answered and refused. The reject reason above "
                  @"is the whole story (BADSECRET = passphrase, UNSECURE = one side has "
                  @"encryption and the other does not, VERSION = too old a peer).");
        }
        goto cleanup;
    }

    s->connectedAt = s->lastRollupAt = spikeNow();
    logNegotiatedOptions(sock, connectSeconds);

    // ── 4. the custom AVIOContext ──────────────────────────────────────────────
    ioBuffer = av_malloc(kSRTSpikeIOBufferSize);
    if (!ioBuffer) { NSLog(@"[SRT-SPIKE] av_malloc failed"); goto cleanup; }

    avio = avio_alloc_context(ioBuffer, kSRTSpikeIOBufferSize,
                              0,        // write_flag: read-only
                              s,        // opaque -> the read callback's state
                              spikeReadPacket,
                              NULL,     // no write
                              NULL);    // NO SEEK. Sets seekable = 0, which is the truth
                                        // about a live socket and stops the demuxer from
                                        // ever trying to rewind.
    if (!avio) {
        // avio_alloc_context did NOT take ownership — the buffer is still ours.
        NSLog(@"[SRT-SPIKE] avio_alloc_context failed");
        av_free(ioBuffer);
        ioBuffer = NULL;
        goto cleanup;
    }
    ioBuffer = NULL;   // ownership has moved into avio->buffer; free it from there only.

    // ── 5. the AVFormatContext ─────────────────────────────────────────────────
    // It must be allocated BY US and have ->pb assigned BEFORE avformat_open_input, or
    // libavformat allocates its own and goes looking for a protocol it does not have.
    mpegts = av_find_input_format("mpegts");
    if (!mpegts) {
        NSLog(@"[SRT-SPIKE] av_find_input_format(\"mpegts\") returned NULL — the mpegts "
              @"demuxer is not in this FFmpeg build. See ThirdParty/ffmpeg/README.md.");
        goto cleanup;
    }

    fmt = avformat_alloc_context();
    if (!fmt) { NSLog(@"[SRT-SPIKE] avformat_alloc_context failed"); goto cleanup; }

    fmt->pb = avio;
    // Explicit, although init_input would also set it. It is what tells
    // avformat_close_input to leave `pb` alone — without it, close would call
    // avio_close(pb) -> ffurl_close(pb->opaque) on a pointer that is our state struct
    // and not a URLContext. That is a crash, not a leak.
    fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
    fmt->interrupt_callback.callback = spikeInterrupt;
    fmt->interrupt_callback.opaque = s;
    // Stated rather than inherited: the discovery facts below are only as good as the
    // window they were derived from, and that window should be readable in the log.
    fmt->probesize = 2 * 1024 * 1024;
    fmt->max_analyze_duration = 5 * AV_TIME_BASE;

    // Passing the input format explicitly skips probing entirely — we know what this is,
    // and probing a live socket means buffering before the first packet.
    // The URL is "" and not NULL: nothing here opens a URL (there is no protocol to open
    // one with), and an empty string keeps libavformat's own logging from dereferencing
    // a null name.
    const int openResult = avformat_open_input(&fmt, "", mpegts, NULL);
    if (openResult < 0) {
        char errbuf[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(openResult, errbuf, sizeof(errbuf));
        NSLog(@"[SRT-SPIKE] avformat_open_input failed: %s (%d)", errbuf, openResult);
        // fmt has ALREADY been freed and NULLed by avformat_open_input. Do not touch it.
        // avio is still ours — the cleanup block frees it through the local.
        fmt = NULL;
        goto cleanup;
    }

    const int infoResult = avformat_find_stream_info(fmt, NULL);
    if (infoResult < 0) {
        char errbuf[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(infoResult, errbuf, sizeof(errbuf));
        NSLog(@"[SRT-SPIKE] avformat_find_stream_info failed: %s (%d)", errbuf, infoResult);
        goto cleanup;
    }

    logStreamDiscovery(fmt, s);

    // ── 6. per-stream counters ─────────────────────────────────────────────────
    s->streamCount = (int)fmt->nb_streams;
    s->streams = calloc(s->streamCount > 0 ? (size_t)s->streamCount : 1, sizeof(SRTSpikeStreamStats));
    if (!s->streams) { NSLog(@"[SRT-SPIKE] calloc failed"); goto cleanup; }
    for (int i = 0; i < s->streamCount; i++) {
        AVStream *st = fmt->streams[i];
        s->streams[i].index = i;
        s->streams[i].type = st->codecpar->codec_type;
        s->streams[i].codecName = avcodec_get_name(st->codecpar->codec_id);
        s->streams[i].tbSec = st->time_base.den ? (double)st->time_base.num / st->time_base.den : 0.0;
        if (s->videoIndex < 0 && st->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) s->videoIndex = i;
    }
    videoPar = s->videoIndex >= 0 ? fmt->streams[s->videoIndex]->codecpar : NULL;

    pkt = av_packet_alloc();
    if (!pkt) { NSLog(@"[SRT-SPIKE] av_packet_alloc failed"); goto cleanup; }

    // ── 7. the read loop ───────────────────────────────────────────────────────
    NSLog(@"[SRT-SPIKE] demuxing. ⌃⌥⇧D to stop.");
    while (spikeShouldRun(s)) {
        int readResult = 0;
        @autoreleasepool {
            readResult = av_read_frame(fmt, pkt);
            if (readResult >= 0) {
                s->sawFirstPacket = true;
                if (pkt->stream_index >= 0 && pkt->stream_index < s->streamCount) {
                    SRTSpikeStreamStats *st = &s->streams[pkt->stream_index];
                    st->pkts++;
                    st->bytes += (uint64_t)pkt->size;
                    if (pkt->flags & AV_PKT_FLAG_KEY) st->keyframes++;

                    const bool hasPTS = pkt->pts != AV_NOPTS_VALUE;
                    const bool hasDTS = pkt->dts != AV_NOPTS_VALUE;
                    if (!hasPTS) st->noPTS++;
                    if (!hasDTS) st->noDTS++;

                    if (hasDTS) {
                        if (st->haveDTS) {
                            const int64_t d = pkt->dts - st->lastDTS;
                            if (d < 0) st->dtsBack++;
                            else {
                                const double ms = (double)d * st->tbSec * 1000.0;
                                if (ms > st->maxDtsGapMs) st->maxDtsGapMs = ms;
                            }
                        }
                        st->lastDTS = pkt->dts;
                        st->haveDTS = true;
                    }
                    if (hasPTS) {
                        // A backward PTS in DECODE order is not an anomaly — it is what a
                        // reordered stream looks like. Counted separately from dtsBack for
                        // exactly that reason.
                        if (st->havePTS && pkt->pts < st->lastPTS) st->ptsBack++;
                        st->lastPTS = pkt->pts;
                        st->havePTS = true;
                    }

                    // The B-frame probe, video only, first N packets.
                    if (pkt->stream_index == s->videoIndex && !s->probeReported &&
                        hasPTS && hasDTS) {
                        s->probeCount++;
                        const int64_t delta = pkt->pts - pkt->dts;
                        if (delta != 0) s->probePtsNeDts++;
                        if (delta < s->probeMinDelta) s->probeMinDelta = delta;
                        if (delta > s->probeMaxDelta) s->probeMaxDelta = delta;
                    }
                }
                av_packet_unref(pkt);   // the packet is LOGGED AND DISCARDED. That is the scope.
            }
        }

        if (readResult < 0) {
            if (readResult == AVERROR_EXIT) {
                NSLog(@"[SRT-SPIKE] av_read_frame returned AVERROR_EXIT — stopping as asked");
            } else if (readResult == AVERROR_EOF) {
                NSLog(@"[SRT-SPIKE] end of stream");
            } else {
                char errbuf[AV_ERROR_MAX_STRING_SIZE] = {0};
                av_strerror(readResult, errbuf, sizeof(errbuf));
                NSLog(@"[SRT-SPIKE] av_read_frame failed: %s (%d)", errbuf, readResult);
            }
            break;
        }

        if (s->probeCount >= kSRTSpikeBFrameProbePackets && !s->probeReported && videoPar) {
            logBFrameProbe(s, videoPar);
        }
        spikeRollup(s);
    }

    // A short session may never reach the probe target; report what was gathered anyway,
    // clearly labelled with its (smaller) sample size.
    if (!s->probeReported && s->probeCount > 0 && videoPar) logBFrameProbe(s, videoPar);

    NSLog(@"[SRT-SPIKE] ══ session summary ══ %.1fs connected | msgs=%llu bytes=%llu "
          @"recvTimeouts=%llu",
          spikeNow() - s->connectedAt, (unsigned long long)s->messagesIn,
          (unsigned long long)s->bytesIn, (unsigned long long)s->recvTimeouts);
    for (int i = 0; i < s->streamCount; i++) {
        SRTSpikeStreamStats *st = &s->streams[i];
        NSLog(@"[SRT-SPIKE]     stream %d total: pkts=%llu key=%llu bytes=%llu dtsBack=%llu ptsBack=%llu",
              st->index, (unsigned long long)st->pkts, (unsigned long long)st->keyframes,
              (unsigned long long)st->bytes, (unsigned long long)st->dtsBack,
              (unsigned long long)st->ptsBack);
    }

cleanup:
    // Reverse order of acquisition. Every one of these is a no-op on a NULL/invalid
    // handle, so a failure at any step above lands here and unwinds exactly what it got.
    if (res) freeaddrinfo(res);
    if (pkt) av_packet_free(&pkt);
    if (s->streams) { free(s->streams); s->streams = NULL; s->streamCount = 0; }

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

    av_log_set_level(previousLogLevel);
    NSLog(@"[SRT-SPIKE] ══ stopped ══");
    dispatch_semaphore_signal(finished);   // releases the join in ManifoldSRTSpikeStop()
}

#pragma mark - Public entry points

void ManifoldSRTSpikeStart(void) {
    NSCAssert(NSThread.isMainThread, @"SRT spike start/stop is main-thread only");
    if (gSpikeThread) {
        NSLog(@"[SRT-SPIKE] already running — ⌃⌥⇧D to stop it first");
        return;
    }

    SRTSpikeState *s = calloc(1, sizeof(SRTSpikeState));
    if (!s) { NSLog(@"[SRT-SPIKE] calloc failed"); return; }
    s->runLock = OS_UNFAIR_LOCK_INIT;
    s->shouldRun = true;
    s->sock = SRT_INVALID_SOCK;
    s->videoIndex = -1;
    gSpike = s;

    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    gSpikeFinished = finished;

    // NDIService's audio pump, one for one: a joinable Thread, named, .userInteractive,
    // a lock-protected run flag, and a semaphore join at teardown.
    NSThread *thread = [[NSThread alloc] initWithBlock:^{ runSpike(s, finished); }];
    thread.name = @"com.manifold.srt.spike";
    thread.qualityOfService = NSQualityOfServiceUserInteractive;
    gSpikeThread = thread;
    [thread start];
}

void ManifoldSRTSpikeStop(void) {
    NSCAssert(NSThread.isMainThread, @"SRT spike start/stop is main-thread only");
    if (!gSpikeThread) {
        NSLog(@"[SRT-SPIKE] not running");
        return;
    }

    // Clear the flag, then BLOCK until the thread has actually exited. The join is what
    // guarantees no srt_recvmsg2 is in flight against a socket the cleanup path is about
    // to close, and no callback is in flight against the state struct freed below.
    //
    // BOUND: one SRTO_RCVTIMEO period (200 ms) plus one demux iteration. The receive
    // already in flight returns within the timeout; every callback entry after that sees
    // shouldRun == false and returns AVERROR_EXIT without blocking, and the
    // interrupt_callback closes off libavformat's own retry loops. Unbounded only if
    // SRTO_RCVTIMEO were ever removed — which is why it is set.
    os_unfair_lock_lock(&gSpike->runLock);
    gSpike->shouldRun = false;
    os_unfair_lock_unlock(&gSpike->runLock);

    dispatch_semaphore_wait(gSpikeFinished, DISPATCH_TIME_FOREVER);

    free(gSpike);
    gSpike = NULL;
    gSpikeThread = nil;
    gSpikeFinished = nil;
}

//  ── NOTE: libsrt's OWN LOGGING (srt_setloghandler) IS DELIBERATELY NOT INSTALLED ──
//
//  It is not needed for the failure modes this stage can actually hit — the three facts
//  logged at CONNECT FAILED above (srt errno, system errno, reject reason) name the
//  stage, the OS refusal and the peer's refusal respectively, which covers "nothing is
//  listening", "firewall", "wrong passphrase", "encryption mismatch" and "peer too old".
//
//  It becomes worth installing the moment a handshake fails for a reason those three do
//  NOT distinguish — the realistic one being an MTU/MSS mismatch across a real network
//  path, where the handshake induction succeeds and the conclusion silently does not.
//  libsrt's internal log at LOG_NOTICE names that; our errno set does not. When that
//  day comes it is ~10 lines: srt_setloglevel(LOG_NOTICE) plus an
//  SRT_LOG_HANDLER_FN forwarding area/message to NSLog under an [SRT-LIB] prefix. The
//  handler is called from libsrt's internal threads, so it must do nothing but format
//  and log.

#else

// Under Release everything above is compiled out and this file would be an empty
// translation unit, which ISO C does not permit. One typedef, no symbol, no cost — the
// same reason Sources/CFFmpeg/shim.c exists at all.
typedef int ManifoldSRTSpikeCompiledOutInRelease;

#endif  /* DEBUG */
