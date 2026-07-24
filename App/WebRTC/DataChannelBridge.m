//
//  DataChannelBridge.m
//  Manifold
//
//  Implementation of the libdatachannel seam.
//
//  NOTE THE EXTENSION: this is `.m` (Objective-C), NOT `.mm`. libdatachannel's
//  public C API (`rtc/rtc.h`) is `extern "C"` and includes only <stdbool.h> and
//  <stdint.h>, so no C++ is needed on our side at all. That is deliberate and is
//  the core linkage-hazard mitigation:
//
//    * This translation unit parses ZERO libdatachannel C++, so no template or
//      inline entity is instantiated across the boundary — regardless of what
//      either side's flags say.
//    * The C++ runtime the archive needs (libc++) is already linked into the app
//      by DeckLinkBridge.mm and DeckLinkAPIDispatch.cpp, and it is the SAME libc++.
//
//  Separately, the dialects are now pinned identical on both sides: project.yml
//  sets CLANG_CXX_LANGUAGE_STANDARD: c++17, and scripts/build_libdatachannel.sh builds
//  with CMAKE_CXX_STANDARD=17 + CMAKE_CXX_EXTENSIONS=OFF, which emits -std=c++17.
//  Keep the C seam anyway — it costs nothing and survives either side drifting.
//

#import "DataChannelBridge.h"
#import "H264Depacketizer.h"

#import <os/lock.h>
#include <stdatomic.h>

// RTC_STATIC makes rtc.h's RTC_C_EXPORT expand to nothing (no dllimport). It is a
// no-op on Darwin, but the static build also sets it as a PUBLIC compile
// definition, so we match it here rather than rely on the platform accident.
// It is also set in project.yml's GCC_PREPROCESSOR_DEFINITIONS; belt and braces.
#ifndef RTC_STATIC
#define RTC_STATIC
#endif

#include <rtc/rtc.h>

static void ManifoldRTCLog(rtcLogLevel level, const char *message) {
    NSLog(@"[WEBRTC] (%d) %s", (int)level, message ?: "");
}

/// One-time library init. The smoke test does this inline; the session path needs the same
/// thing, and both calls are idempotent, so it is hoisted into a dispatch_once.
static void ManifoldWebRTCEnsureInitialized(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rtcInitLogger(RTC_LOG_INFO, ManifoldRTCLog);
        rtcPreload();
    });
}

const char *ManifoldWebRTCVersion(void) {
    // Compile-time macro from rtc/version.h — proves the header search path.
    return RTC_VERSION;
}

BOOL ManifoldWebRTCLinkSmokeTest(NSString *_Nullable *_Nullable outMessage) {
    // 1. First real call into the archive. If the static lib did not link, the
    //    failure is at BUILD time (undefined symbol _rtcInitLogger), not here.
    rtcInitLogger(RTC_LOG_INFO, ManifoldRTCLog);

    // 2. Bring up the transport machinery.
    rtcPreload();

    // 3. Empty config: no ICE servers, no bind address, automatic everything.
    //    Zero-initializing is the documented way to take all defaults.
    rtcConfiguration config;
    memset(&config, 0, sizeof(config));

    int pc = rtcCreatePeerConnection(&config);
    if (pc <= 0) {
        // Negative values are rtcErr codes; 0 is never a valid handle.
        if (outMessage) {
            *outMessage = [NSString stringWithFormat:
                @"libdatachannel %s linked, but rtcCreatePeerConnection failed (%d)",
                RTC_VERSION, pc];
        }
        return NO;
    }

    int del = rtcDeletePeerConnection(pc);

    if (outMessage) {
        *outMessage = [NSString stringWithFormat:
            @"libdatachannel %s — linked, logger installed, PeerConnection "
            @"created (id %d) and deleted (rc %d). ICE/SRTP/SCTP/DTLS all resolved.",
            RTC_VERSION, pc, del];
    }
    return del >= 0;
}

#pragma mark - WHEP session

// ── Session lookup for the C callbacks ───────────────────────────────────────────────
//
// libdatachannel hands every callback a `void *` user pointer, and the obvious move is to
// stash an unretained `self` there. That is a use-after-free waiting to happen: callbacks
// are ENQUEUED on a Processor (see impl/peerconnection.cpp, `mProcessor.enqueue`) and can
// be dequeued after the Obj-C object is gone. A WEAK table keyed by PeerConnection id
// closes the hole — a callback that loses the race finds nil and returns.
//
// (The C API also skips any callback whose user-pointer entry has been erased, which
// `rtcDeletePeerConnection` does. That is a second layer, not the one relied on here.)

@interface ManifoldWHEPSession ()
@property (nonatomic, copy, nullable) void (^offerCompletion)(NSString *_Nullable, NSString *_Nullable);
- (void)handleGatheringComplete;

// Inbound video (step 3a). Declared here rather than left to same-@implementation lookup so
// that -snapshotStats in particular has a visible prototype: it returns a struct by value.
- (void)ingestRTP:(const uint8_t *)packet length:(size_t)length;
- (void)enqueueAccessUnit:(const ManifoldH264AccessUnit *)accessUnit;
- (void)configureDepacketizerFromNegotiatedDescription;
- (void)startRTPStatsTimer;
- (void)logRTPStatsTick;
- (ManifoldH264DepacketizerStats)snapshotStats;
@end

static NSMapTable *ManifoldWHEPMakeWeakTable(void) {
    return [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory |
                                              NSPointerFunctionsObjectPersonality
                                 valueOptions:NSPointerFunctionsWeakMemory |
                                              NSPointerFunctionsObjectPersonality];
}

static NSMapTable<NSNumber *, ManifoldWHEPSession *> *ManifoldWHEPSessions(void) {
    static NSMapTable *sessions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sessions = ManifoldWHEPMakeWeakTable(); });
    return sessions;
}

/// The same weak-table discipline, keyed by TRACK id rather than PeerConnection id:
/// track callbacks (in particular the per-RTP-packet message callback) are handed the
/// track's id, not the connection's.
static NSMapTable<NSNumber *, ManifoldWHEPSession *> *ManifoldWHEPTrackSessions(void) {
    static NSMapTable *sessions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sessions = ManifoldWHEPMakeWeakTable(); });
    return sessions;
}

static NSLock *ManifoldWHEPSessionsLock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });
    return lock;
}

/// Returns a STRONG reference (ARC retains the weak read), so the session cannot die
/// underneath a callback that is already running.
static ManifoldWHEPSession *ManifoldWHEPLookup(int pc) {
    NSLock *lock = ManifoldWHEPSessionsLock();
    [lock lock];
    ManifoldWHEPSession *session = [ManifoldWHEPSessions() objectForKey:@(pc)];
    [lock unlock];
    return session;
}

/// As above, for track callbacks. This one runs PER RTP PACKET — a few thousand times a
/// second at 1080p — so it is worth knowing what it costs: an uncontended NSLock plus a
/// weak read is tens of nanoseconds, against ~1200 bytes of memcpy in the depacketizer
/// behind it. Using `rtcSetUserPointer` instead would save that and reintroduce the
/// use-after-free this table exists to prevent. Not a trade worth making.
static ManifoldWHEPSession *ManifoldWHEPTrackLookup(int tr) {
    NSLock *lock = ManifoldWHEPSessionsLock();
    [lock lock];
    ManifoldWHEPSession *session = [ManifoldWHEPTrackSessions() objectForKey:@(tr)];
    [lock unlock];
    return session;
}

/// Pulls the negotiated H.264 payload type out of a media description.
///
/// It MUST come from the SDP rather than being hardcoded to the 96 we offered: the answer
/// picks, and a server is free to answer with a different number. Feeding the depacketizer
/// the wrong PT does not fail loudly — it silently discards every packet.
static int ManifoldWHEPH264PayloadTypeFromSDP(NSString *sdp) {
    for (NSString *rawLine in [sdp componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                          NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![line hasPrefix:@"a=rtpmap:"]) continue;

        NSString *rest = [line substringFromIndex:@"a=rtpmap:".length];   // "<pt> <name>/<clock>"
        NSRange space = [rest rangeOfString:@" "];
        if (space.location == NSNotFound) continue;

        NSString *encoding = [rest substringFromIndex:NSMaxRange(space)];
        // Prefix match on "H264/" so the RTX line (`rtx/90000`, whose apt points AT the
        // H.264 PT) cannot be mistaken for the codec itself.
        if ([encoding rangeOfString:@"H264/" options:NSCaseInsensitiveSearch].location != 0) continue;

        return [rest substringToIndex:space.location].intValue;
    }
    return -1;
}

static NSString *ManifoldWHEPStateName(rtcState state) {
    switch (state) {
        case RTC_NEW:          return @"new";
        case RTC_CONNECTING:   return @"connecting";
        case RTC_CONNECTED:    return @"connected";
        case RTC_DISCONNECTED: return @"disconnected";
        case RTC_FAILED:       return @"failed";
        case RTC_CLOSED:       return @"closed";
    }
    return @"unknown";
}

static NSString *ManifoldWHEPIceStateName(rtcIceState state) {
    switch (state) {
        case RTC_ICE_NEW:          return @"new";
        case RTC_ICE_CHECKING:     return @"checking";
        case RTC_ICE_CONNECTED:    return @"connected";
        case RTC_ICE_COMPLETED:    return @"completed";
        case RTC_ICE_FAILED:       return @"failed";
        case RTC_ICE_DISCONNECTED: return @"disconnected";
        case RTC_ICE_CLOSED:       return @"closed";
    }
    return @"unknown";
}

// ── The recvonly media the offer advertises ──────────────────────────────────────────
//
// Handed to `rtcAddTrack` as raw m-sections rather than built with `rtcAddTrackEx`,
// deliberately: rtcAddTrackEx ALWAYS calls Description::Media::addSSRC (capi.cpp), which
// stamps an `a=ssrc:` attribute onto the m-line — with a zeroed init, a literal `a=ssrc:0`.
// A receive-only section has no outgoing stream, so advertising an SSRC there is wrong,
// browsers do not do it, and a strict WHEP server may reject it. There is no C API to
// remove the attribute afterward. The raw-SDP path emits exactly these lines.
//
// Three things to know before editing these strings:
//   * The port MUST be non-zero. libdatachannel reads port 0 as "section removed"
//     (description.cpp) and silently drops the m-line from the BUNDLE group. 9 is the
//     conventional placeholder.
//   * `a=rtcp-mux` is deliberately ABSENT — libdatachannel appends it to every media
//     section itself, so listing it here would duplicate it.
//   * Line endings are "\n", not "\r\n". Only the first line is consumed without being
//     trimmed, so a CR there would leak into the parsed payload-type list. libdatachannel
//     regenerates the SDP with proper CRLF on output regardless.
//
// The codec set is a general receiver set, not tuned to any particular server. mids "0"
// and "1" produce `a=group:BUNDLE 0 1`, matching normal browser output.
static const char *const kManifoldWHEPVideoMSection =
    "m=video 9 UDP/TLS/RTP/SAVPF 96 97 98\n"
    "a=mid:0\n"
    "a=recvonly\n"
    "a=rtpmap:96 H264/90000\n"
    "a=fmtp:96 profile-level-id=42e01f;packetization-mode=1;level-asymmetry-allowed=1\n"
    "a=rtcp-fb:96 nack\n"
    "a=rtcp-fb:96 nack pli\n"
    "a=rtcp-fb:96 goog-remb\n"
    "a=rtpmap:97 VP8/90000\n"
    "a=rtcp-fb:97 nack\n"
    "a=rtcp-fb:97 nack pli\n"
    "a=rtcp-fb:97 goog-remb\n"
    "a=rtpmap:98 VP9/90000\n"
    "a=rtcp-fb:98 nack\n"
    "a=rtcp-fb:98 nack pli\n"
    "a=rtcp-fb:98 goog-remb\n";

static const char *const kManifoldWHEPAudioMSection =
    "m=audio 9 UDP/TLS/RTP/SAVPF 111\n"
    "a=mid:1\n"
    "a=recvonly\n"
    "a=rtpmap:111 opus/48000/2\n"
    "a=fmtp:111 minptime=10;useinbandfec=1\n";

// ── C callbacks. Called on libdatachannel's Processor threads. ───────────────────────
//
// Each one does the minimum — look the session up, copy anything borrowed — then hops to
// main. Nothing below touches Obj-C state on the calling thread, and nothing below calls
// back into libdatachannel: the Processor is serialized per PeerConnection, so blocking
// here would stall every subsequent callback for this connection.

static void ManifoldWHEPStateChanged(int pc, rtcState state, void *ptr) {
    (void)ptr;
    ManifoldWHEPSession *session = ManifoldWHEPLookup(pc);
    if (!session) return;
    NSString *name = ManifoldWHEPStateName(state);
    ManifoldWHEPConnectionState mapped = (ManifoldWHEPConnectionState)state;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (session.onConnectionState) session.onConnectionState(mapped, name);
    });
}

static void ManifoldWHEPIceStateChanged(int pc, rtcIceState state, void *ptr) {
    (void)ptr;
    ManifoldWHEPSession *session = ManifoldWHEPLookup(pc);
    if (!session) return;
    NSString *name = ManifoldWHEPIceStateName(state);
    ManifoldWHEPIceState mapped = (ManifoldWHEPIceState)state;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (session.onIceState) session.onIceState(mapped, name);
    });
}

static void ManifoldWHEPGatheringStateChanged(int pc, rtcGatheringState state, void *ptr) {
    (void)ptr;
    ManifoldWHEPSession *session = ManifoldWHEPLookup(pc);
    if (!session) return;
    if (state != RTC_GATHERING_COMPLETE) {
        NSLog(@"[WHEP-BRIDGE] gathering state %d", (int)state);
        return;
    }
    // Complete: the local description now carries every candidate. Read it on main —
    // rtcGetLocalDescription takes libdatachannel's own locks, and reading it from inside
    // the callback thread is needless risk when the hop costs nothing.
    dispatch_async(dispatch_get_main_queue(), ^{ [session handleGatheringComplete]; });
}

// ── Inbound media callbacks (step 3a) ────────────────────────────────────────────────
//
// THE HOT PATH. ManifoldWHEPTrackMessage runs once per RTP packet on libdatachannel's
// per-track thread, and unlike the state callbacks above it does NOT hop to main: a
// dispatch_async per packet would be more expensive than the depacketization itself, and
// would put frame reassembly behind the main run loop, which is where the UI lives.
//
// What runs here is bounded and allocation-free in the steady state: parse the 12-byte
// header, memcpy the payload into a reused buffer, bump counters. Everything that could
// block — logging, decode, the format description — happens elsewhere.

static void ManifoldWHEPTrackMessage(int tr, const char *message, int size, void *ptr) {
    (void)ptr;
    // libdatachannel's C API signals a STRING message with a negative size (the payload is
    // NUL-terminated). Media tracks only ever deliver binary, so a negative size here means
    // something we do not understand — not RTP.
    if (size <= 0 || !message) return;

    ManifoldWHEPSession *session = ManifoldWHEPTrackLookup(tr);
    if (!session) return;
    [session ingestRTP:(const uint8_t *)message length:(size_t)size];
}

/// Drains a track we negotiated but do not consume.
///
/// This is NOT optional housekeeping. A libdatachannel Channel with no message callback
/// QUEUES its incoming messages for a later `rtcReceiveMessage` that, for the audio track,
/// never comes — so leaving it unhandled grows a buffer for the whole session. Discarding
/// explicitly costs one function call per Opus packet (~50/s).
static void ManifoldWHEPDiscardMessage(int id, const char *message, int size, void *ptr) {
    (void)id; (void)message; (void)size; (void)ptr;
}

/// Fires INSIDE ManifoldH264DepacketizerSubmitRTP, on the network thread, with `_rtpLock`
/// held — so `context` is safe to use unretained: -ingestRTP already holds a strong
/// reference for the duration, and -close cannot free the depacketizer out from under it
/// without first taking the same lock.
static void ManifoldWHEPAccessUnitReady(const ManifoldH264AccessUnit *accessUnit, void *context) {
    ManifoldWHEPSession *session = (__bridge ManifoldWHEPSession *)context;
    [session enqueueAccessUnit:accessUnit];
}

static void ManifoldWHEPTrackOpen(int tr, void *ptr) {
    (void)ptr;
    NSLog(@"[WHEP-BRIDGE] video track %d open — RTP will start arriving", tr);
}

static void ManifoldWHEPTrackClosed(int tr, void *ptr) {
    (void)ptr;
    NSLog(@"[WHEP-BRIDGE] video track %d closed", tr);
}

@implementation ManifoldWHEPSession {
    int  _pc;
    BOOL _closed;

    // ── Inbound video (step 3a) ──────────────────────────────────────────────────────
    int _videoTrack;

    /// Owned by the session, mutated ONLY under `_rtpLock`. The depacketizer itself is
    /// single-threaded by contract; the lock exists because the 1 Hz logger on main reads
    /// its counters while the network thread is writing them, and because `close` frees it
    /// while a callback may be in flight.
    ManifoldH264Depacketizer *_depacketizer;
    os_unfair_lock _rtpLock;

    dispatch_queue_t _decodeQueue;

    /// Access units in flight between the network thread and the decode queue. Incremented
    /// on the network thread, decremented on the decode queue, so it must be atomic.
    _Atomic(int) _pendingAccessUnits;
    uint64_t _accessUnitsHandedOff;      // network thread, under _rtpLock
    uint64_t _accessUnitsDroppedBusy;    // network thread, under _rtpLock

    dispatch_source_t _statsTimer;
    ManifoldH264DepacketizerStats _previousStats;
    uint64_t _previousHandedOff;
    uint64_t _previousDroppedBusy;
    NSDate *_rtpStartedAt;
    int _quietTicks;
    int _pliRequests;                    // main thread only: log counter for PLIs actually sent
    NSTimeInterval _lastPliRequestedAt;  // main thread only: shared PLI throttle, 0 until first send
    BOOL _loggedOffMainPli;              // main thread only: one-shot guard for the off-main warning
    BOOL _loggedFirstPacket;
    BOOL _loggedParameterSets;
    BOOL _loggedFirstKeyframe;
    BOOL _loggedPayloadTypeMismatch;
}

@synthesize decodeQueue = _decodeQueue;

+ (nullable instancetype)sessionWithStunServer:(nullable NSString *)stunServer
                                         error:(NSString *_Nullable *_Nullable)outError {
    ManifoldWebRTCEnsureInitialized();

    rtcConfiguration config;
    memset(&config, 0, sizeof(config));

    // No STUN server is a valid configuration: a WHEP server supplies its own candidates in
    // the answer, and host candidates plus those often suffice. Only populate the array when
    // one was actually configured. rtcCreatePeerConnection copies the strings, so the
    // autoreleased UTF8String backing only has to outlive the call below.
    const char *iceServers[1] = { NULL };
    if (stunServer.length > 0) {
        iceServers[0] = stunServer.UTF8String;
        config.iceServers = iceServers;
        config.iceServersCount = 1;
    }

    // We drive negotiation by hand — add both m-sections, then one explicit offer. This
    // only suppresses libdatachannel's *automatic re-offer* on returning to a stable
    // signaling state; addTrack never negotiates on its own. Belt and braces.
    config.disableAutoNegotiation = true;

    // NOTE ON BUNDLE: there is no bundle-policy setting to configure, at either API level.
    // libdatachannel has no un-bundled mode — Description::generateSdp always emits a single
    // `a=group:BUNDLE` over every m-line, always emits `a=rtcp-mux` per section, and always
    // runs one ICE transport. That is max-bundle behaviour, which is what a modern WHEP
    // server expects; it just isn't expressed as a knob. Do not go looking for one.

    int pc = rtcCreatePeerConnection(&config);
    if (pc <= 0) {
        if (outError) *outError = [NSString stringWithFormat:@"rtcCreatePeerConnection failed (%d)", pc];
        return nil;
    }

    ManifoldWHEPSession *session = [[self alloc] init];
    session->_pc = pc;
    session->_rtpLock = OS_UNFAIR_LOCK_INIT;

    NSLock *lock = ManifoldWHEPSessionsLock();
    [lock lock];
    [ManifoldWHEPSessions() setObject:session forKey:@(pc)];
    [lock unlock];

    rtcSetStateChangeCallback(pc, ManifoldWHEPStateChanged);
    rtcSetIceStateChangeCallback(pc, ManifoldWHEPIceStateChanged);
    rtcSetGatheringStateChangeCallback(pc, ManifoldWHEPGatheringStateChanged);
    // Deliberately NO rtcSetLocalCandidateCallback: this is a non-trickle client, and
    // trickling candidates out one at a time is exactly what we are avoiding.

    // Recvonly media goes on NOW, before any offer can be generated. Doing it here rather
    // than in generateRecvOnlyOffer… makes the ordering structural: there is no code path
    // that produces an offer without media lines.
    int videoTrack = rtcAddTrack(pc, kManifoldWHEPVideoMSection);
    int audioTrack = rtcAddTrack(pc, kManifoldWHEPAudioMSection);
    if (videoTrack <= 0 || audioTrack <= 0) {
        if (outError) *outError = [NSString stringWithFormat:
            @"failed to add recvonly media (video %d, audio %d)", videoTrack, audioTrack];
        [session close];
        return nil;
    }

    // ── Inbound video plumbing (step 3a) ─────────────────────────────────────────────
    session->_videoTrack = videoTrack;

    // RtcpReceivingSession is libdatachannel's INBOUND media handler. It is not a
    // depacketizer — it does not touch the RTP payload at all — but it does two things we
    // need. It absorbs the RTCP that rtcp-mux delivers on this same track (SR, so the
    // sender's NTP↔RTP mapping is tracked for later A/V sync), and it is what
    // `rtcRequestKeyframe` pushes a PLI through. Without it, RTCP compound packets would
    // land in our RTP callback and every keyframe request would be a no-op.
    int chained = rtcChainRtcpReceivingSession(videoTrack);
    if (chained < 0) {
        NSLog(@"[WHEP-BRIDGE] WARNING: rtcChainRtcpReceivingSession failed (%d) — expect RTCP "
              @"in the RTP stream and no working keyframe requests", chained);
    }

    session->_depacketizer = ManifoldH264DepacketizerCreate();
    if (!session->_depacketizer) {
        if (outError) *outError = @"failed to allocate the H.264 depacketizer";
        [session close];
        return nil;
    }
    // ── The network-thread → decode-queue handoff (step 3b) ─────────────────────────
    //
    // SERIAL, and that is the whole design: H.264 without B-frames decodes strictly in
    // order, so one queue both preserves order and gives the decoder a single thread it
    // never has to lock against. WITH_AUTORELEASE_POOL because each frame creates a
    // CMBlockBuffer + CMSampleBuffer, and a queue without a pool would hold every one of
    // them until the thread happened to drain.
    //
    // USER_INITIATED, not USER_INTERACTIVE: decode must keep up with the stream but must
    // not outrank the render thread it will eventually feed.
    dispatch_queue_attr_t decodeAttr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL, QOS_CLASS_USER_INITIATED, 0);
    session->_decodeQueue = dispatch_queue_create("com.graviton.manifold.whep.decode", decodeAttr);

    ManifoldH264DepacketizerSetAccessUnitHandler(session->_depacketizer,
                                                 ManifoldWHEPAccessUnitReady,
                                                 (__bridge void *)session);

    [lock lock];
    [ManifoldWHEPTrackSessions() setObject:session forKey:@(videoTrack)];
    [lock unlock];

    rtcSetOpenCallback(videoTrack, ManifoldWHEPTrackOpen);
    rtcSetClosedCallback(videoTrack, ManifoldWHEPTrackClosed);
    rtcSetMessageCallback(videoTrack, ManifoldWHEPTrackMessage);

    // Audio is negotiated but not consumed yet. It still needs a callback — see
    // ManifoldWHEPDiscardMessage — or its packets accumulate in libdatachannel's receive
    // queue for the life of the session.
    rtcSetMessageCallback(audioTrack, ManifoldWHEPDiscardMessage);

    NSLog(@"[WHEP-BRIDGE] pc %d created — recvonly video (tr %d) + audio (tr %d), stun: %@",
          pc, videoTrack, audioTrack, stunServer.length > 0 ? stunServer : @"none");
    return session;
}

- (void)generateRecvOnlyOfferWithTimeout:(NSTimeInterval)timeout
                              completion:(void (^)(NSString *_Nullable, NSString *_Nullable))completion {
    NSAssert(NSThread.isMainThread, @"ManifoldWHEPSession must be driven from the main queue");
    if (_closed || _pc <= 0) { completion(nil, @"session is closed"); return; }
    if (self.offerCompletion) { completion(nil, @"an offer is already being generated"); return; }

    // Stored BEFORE setLocalDescription: gathering runs on another thread and can complete
    // before that call even returns.
    self.offerCompletion = completion;

    // This is the createOffer + setLocalDescription equivalent in one call, and it also
    // kicks off candidate gathering (auto-gathering is on by default).
    int rc = rtcSetLocalDescription(_pc, "offer");
    if (rc < 0) {
        self.offerCompletion = nil;
        completion(nil, [NSString stringWithFormat:@"rtcSetLocalDescription failed (%d)", rc]);
        return;
    }

    // Gathering can stall indefinitely — an unreachable STUN server being the usual cause.
    // Fail loudly instead of hanging with no output.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        void (^pending)(NSString *_Nullable, NSString *_Nullable) = strongSelf.offerCompletion;
        if (!pending) return;   // already delivered
        strongSelf.offerCompletion = nil;
        pending(nil, [NSString stringWithFormat:
            @"ICE gathering did not complete within %.0fs", timeout]);
    });
}

- (void)handleGatheringComplete {
    NSAssert(NSThread.isMainThread, @"gathering completion must be marshaled to main");
    if (_closed || _pc <= 0) return;

    void (^completion)(NSString *_Nullable, NSString *_Nullable) = self.offerCompletion;
    if (!completion) return;    // timed out, or no offer in flight
    self.offerCompletion = nil;

    // Two-pass read: a NULL buffer returns the size needed, including the terminator.
    int needed = rtcGetLocalDescription(_pc, NULL, 0);
    if (needed <= 0) {
        completion(nil, [NSString stringWithFormat:@"rtcGetLocalDescription size query failed (%d)", needed]);
        return;
    }
    char *buffer = malloc((size_t)needed);
    if (!buffer) { completion(nil, @"out of memory reading local description"); return; }

    int rc = rtcGetLocalDescription(_pc, buffer, needed);
    if (rc <= 0) {
        free(buffer);
        completion(nil, [NSString stringWithFormat:@"rtcGetLocalDescription failed (%d)", rc]);
        return;
    }
    NSString *sdp = [NSString stringWithUTF8String:buffer];
    free(buffer);

    if (sdp.length == 0) { completion(nil, @"local description was empty"); return; }
    completion(sdp, nil);
}

- (BOOL)setRemoteAnswer:(NSString *)answerSDP error:(NSString *_Nullable *_Nullable)outError {
    NSAssert(NSThread.isMainThread, @"ManifoldWHEPSession must be driven from the main queue");
    if (_closed || _pc <= 0) {
        if (outError) *outError = @"session is closed";
        return NO;
    }
    int rc = rtcSetRemoteDescription(_pc, answerSDP.UTF8String, "answer");
    if (rc < 0) {
        if (outError) *outError = [NSString stringWithFormat:@"rtcSetRemoteDescription failed (%d)", rc];
        return NO;
    }

    // The answer is applied, so the video track's description is now the NEGOTIATED one and
    // the payload type in it is the one that will actually be on the wire.
    [self configureDepacketizerFromNegotiatedDescription];
    [self startRTPStatsTimer];
    return YES;
}

#pragma mark - Inbound video (step 3a)

- (void)configureDepacketizerFromNegotiatedDescription {
    if (_videoTrack <= 0) return;

    int needed = rtcGetTrackDescription(_videoTrack, NULL, 0);
    NSString *description = nil;
    if (needed > 0) {
        char *buffer = malloc((size_t)needed);
        if (buffer) {
            if (rtcGetTrackDescription(_videoTrack, buffer, needed) > 0) {
                description = [NSString stringWithUTF8String:buffer];
            }
            free(buffer);
        }
    }

    int payloadType = description ? ManifoldWHEPH264PayloadTypeFromSDP(description) : -1;

    os_unfair_lock_lock(&_rtpLock);
    if (_depacketizer) ManifoldH264DepacketizerSetPayloadType(_depacketizer, payloadType);
    os_unfair_lock_unlock(&_rtpLock);

    if (payloadType >= 0) {
        NSLog(@"[WHEP-RTP] negotiated H.264 payload type %d on track %d", payloadType, _videoTrack);
    } else {
        // Not fatal: the depacketizer falls back to latching the first payload type it sees.
        // It IS worth shouting about, because that fallback will latch onto RTX if RTX
        // happens to arrive first, and the symptom is "no NALs, no errors".
        NSLog(@"[WHEP-RTP] WARNING: no H.264 rtpmap in the negotiated video description — "
              @"falling back to latching the first payload type seen. Answer may have "
              @"selected VP8/VP9, in which case nothing here will depacketize.");
    }
}

- (void)ingestRTP:(const uint8_t *)packet length:(size_t)length {
    // libdatachannel's track thread. See the callback comment above: no hop, no logging.
    os_unfair_lock_lock(&_rtpLock);
    if (_depacketizer) ManifoldH264DepacketizerSubmitRTP(_depacketizer, packet, length);
    os_unfair_lock_unlock(&_rtpLock);
}

/// Network thread, `_rtpLock` held, called from inside the depacketizer. Everything here is
/// a copy and a dispatch — no decode, no CoreMedia, no logging.
- (void)enqueueAccessUnit:(const ManifoldH264AccessUnit *)accessUnit {
    void (^handler)(NSData *, NSData *_Nullable, NSData *_Nullable, BOOL, BOOL, uint32_t) =
        self.onVideoAccessUnit;   // atomic property: safe to read from this thread
    if (!handler || accessUnit->size == 0) return;

    // BACKPRESSURE. dispatch_async has no bound, so a decoder that falls behind would grow
    // the queue until memory ran out. Shed non-keyframes instead — a dropped P-frame costs
    // one glitch, a dropped IDR costs everything until the next one, so keyframes always go
    // through however deep the backlog is.
    static const int kMaxPendingAccessUnits = 8;
    if (atomic_load_explicit(&_pendingAccessUnits, memory_order_relaxed) >= kMaxPendingAccessUnits &&
        !accessUnit->keyframe) {
        _accessUnitsDroppedBusy++;
        return;
    }

    NSData *avcc = [NSData dataWithBytes:accessUnit->data length:accessUnit->size];
    NSData *sps  = accessUnit->sps ? [NSData dataWithBytes:accessUnit->sps length:accessUnit->spsSize] : nil;
    NSData *pps  = accessUnit->pps ? [NSData dataWithBytes:accessUnit->pps length:accessUnit->ppsSize] : nil;
    const BOOL     changed   = accessUnit->parameterSetsChanged;
    const BOOL     keyframe  = accessUnit->keyframe;
    const uint32_t timestamp = accessUnit->rtpTimestamp;

    _accessUnitsHandedOff++;
    atomic_fetch_add_explicit(&_pendingAccessUnits, 1, memory_order_relaxed);

    // The block retains `handler`, so a decoder torn down mid-flight stays alive until the
    // last queued frame has run. That is deliberate: the alternative is a use-after-free.
    dispatch_async(_decodeQueue, ^{
        handler(avcc, sps, pps, changed, keyframe, timestamp);
        atomic_fetch_sub_explicit(&self->_pendingAccessUnits, 1, memory_order_relaxed);
    });
}

- (ManifoldH264DepacketizerStats)snapshotStats {
    ManifoldH264DepacketizerStats stats;
    os_unfair_lock_lock(&_rtpLock);
    ManifoldH264DepacketizerCopyStats(_depacketizer, &stats);
    os_unfair_lock_unlock(&_rtpLock);
    return stats;
}

- (void)startRTPStatsTimer {
    NSAssert(NSThread.isMainThread, @"stats timer must be created on main");
    if (_statsTimer || _closed) return;

    _rtpStartedAt = [NSDate date];
    _statsTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_statsTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC),
                              NSEC_PER_SEC, NSEC_PER_SEC / 10);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_statsTimer, ^{ [weakSelf logRTPStatsTick]; });
    dispatch_resume(_statsTimer);
}

/// The step-3a checkpoint, once a second on main. Counts are per-interval; the cumulative
/// totals go out at teardown via -rtpStatsSummary.
- (void)logRTPStatsTick {
    NSAssert(NSThread.isMainThread, @"stats logging must run on main");
    const ManifoldH264DepacketizerStats now = [self snapshotStats];
    const ManifoldH264DepacketizerStats was = _previousStats;
    _previousStats = now;

    os_unfair_lock_lock(&_rtpLock);
    const uint64_t handedOff = _accessUnitsHandedOff, droppedBusy = _accessUnitsDroppedBusy;
    os_unfair_lock_unlock(&_rtpLock);
    const uint64_t handedOffDelta = handedOff - _previousHandedOff;
    const uint64_t droppedBusyDelta = droppedBusy - _previousDroppedBusy;
    _previousHandedOff = handedOff;
    _previousDroppedBusy = droppedBusy;

#define MD_DELTA(field) (now.field - was.field)

    if (MD_DELTA(packetsReceived) == 0) {
        // Silence is a result too, but it does not need a line every second.
        if (++_quietTicks % 5 == 0) {
            NSLog(@"[WHEP-RTP] no RTP for %ds — transport is up but the server is not sending "
                  @"(or the video m-line was rejected)", _quietTicks);
        }
        return;
    }
    _quietTicks = 0;

    if (!_loggedFirstPacket) {
        _loggedFirstPacket = YES;
        NSLog(@"[WHEP-RTP] first RTP packet after %.2fs — ssrc 0x%08x, pt %d",
              [NSDate.date timeIntervalSinceDate:_rtpStartedAt], now.ssrc, now.payloadType);
    }
    if (!_loggedParameterSets && now.spsSize > 0 && now.ppsSize > 0) {
        _loggedParameterSets = YES;
        NSLog(@"[WHEP-RTP] parameter sets captured — SPS %zu bytes, PPS %zu bytes "
              @"(held out-of-band for the format description in step 3b)", now.spsSize, now.ppsSize);
    }
    if (!_loggedFirstKeyframe && now.keyframes > 0) {
        _loggedFirstKeyframe = YES;
        NSLog(@"[WHEP-RTP] first keyframe access unit assembled");
    }
    if (!_loggedPayloadTypeMismatch && MD_DELTA(packetsWrongPayloadType) > 0 && MD_DELTA(packetsAccepted) == 0) {
        _loggedPayloadTypeMismatch = YES;
        NSLog(@"[WHEP-RTP] WARNING: every packet this interval had an unexpected payload type. "
              @"Expected %d. The answer probably selected a codec we are not depacketizing.",
              now.payloadType);
    }

    NSLog(@"[WHEP-RTP] +%.0fs  frames=%llu (key=%llu)  NALs: SPS=%llu PPS=%llu IDR=%llu slice=%llu "
          @"SEI=%llu  |  pkts=%llu seqGaps=%llu lost=%llu reorder=%llu  |  "
          @"FU-A rx=%llu reassembled=%llu dropped=%llu  |  handoff=%llu shed=%llu",
          [NSDate.date timeIntervalSinceDate:_rtpStartedAt],
          MD_DELTA(accessUnits), MD_DELTA(keyframes),
          MD_DELTA(nalSPS), MD_DELTA(nalPPS), MD_DELTA(nalIDR), MD_DELTA(nalSlice), MD_DELTA(nalSEI),
          MD_DELTA(packetsReceived), MD_DELTA(seqGaps), MD_DELTA(packetsLost), MD_DELTA(packetsReordered),
          MD_DELTA(fuaPackets), MD_DELTA(fuaReassembled), MD_DELTA(fuaDropped),
          handedOffDelta, droppedBusyDelta);

    if (droppedBusyDelta > 0) {
        NSLog(@"[WHEP-RTP]   BACKPRESSURE: shed %llu access unit(s) — the decode queue is not "
              @"keeping up with the stream", droppedBusyDelta);
    }

    // Anything below is an anomaly, not a rate, so it only prints when it happens.
    if (MD_DELTA(packetsMalformed) || MD_DELTA(nalUnsupported) || MD_DELTA(packetsRTCP) ||
        MD_DELTA(packetsWrongSSRC) || MD_DELTA(accessUnitsByTimestamp) || MD_DELTA(accessUnitsOversize)) {
        NSLog(@"[WHEP-RTP]   anomalies: malformed=%llu unsupportedPacketType=%llu rtcpInRtp=%llu "
              @"otherSsrc=%llu auClosedByTimestamp=%llu auOversize=%llu",
              MD_DELTA(packetsMalformed), MD_DELTA(nalUnsupported), MD_DELTA(packetsRTCP),
              MD_DELTA(packetsWrongSSRC), MD_DELTA(accessUnitsByTimestamp), MD_DELTA(accessUnitsOversize));
    }

    // Joining mid-GOP is the normal case for a live stream: slices decode into nothing until
    // an IDR arrives. Ask for one. No lifetime cap now — the shared throttle in requestKeyframe
    // bounds the rate, and a cap here would go silent for the rest of the session after an early
    // burst. requestKeyframe owns the _pliRequests count and logs its own failures, so we only
    // announce an actual send (a throttled request returns NO and stays quiet).
    //
    // BEHAVIOR CHANGE, DELIBERATE: dropping the old `_pliRequests < 3` cap means that on a
    // connection where a keyframe NEVER arrives, this now retries indefinitely (once per 1 s
    // tick, while slices keep coming) instead of giving up after three attempts. That is
    // correct: a sender that starts its keyframe late, or an SFU slow to forward the PLI
    // upstream, should still be served rather than left frozen forever. The 250 ms throttle in
    // requestKeyframe bounds the worst case — combined with the client's ~0.5 Hz backstop the
    // steady-state ask is ~1.5 PLI/s, and the throttle caps it at 4 PLI/s no matter how the
    // triggers overlap.
    if (now.keyframes == 0 && now.nalSlice > 0) {
        if ([self requestKeyframe]) {
            NSLog(@"[WHEP-RTP] slices but no keyframe yet — PLI request %d sent", _pliRequests);
        }
    }

#undef MD_DELTA
}

- (BOOL)requestKeyframe {
    // INVARIANT: main thread only, and it is load-bearing. Every PLI trigger funnels here — the
    // two 1 Hz stats-timer triggers already run on main, and the new decode-error trigger
    // (WHEPVideoDecoder.onNeedsKeyframe, which fires on the decode queue) hops to main via
    // DispatchQueue.main.async before calling. That single-thread invariant is what lets the
    // throttle state below be a plain ivar with no lock, and lets the _closed / _videoTrack
    // reads observe the same teardown state -close writes on main.
    //
    // NOT enforced with NSAssert: Profile and Release do NOT define NS_BLOCK_ASSERTIONS (see
    // project.yml GCC_PREPROCESSOR_DEFINITIONS), so an assert would be live in both the build we
    // measure on and the build testers run. The thing being guarded — a PLI request off main —
    // is benign (at worst a torn read of the throttle timestamp or a redundant PLI), and
    // trapping to prevent it would crash a live review session. So the check is non-fatal:
    // warn once, then proceed.
    if (!NSThread.isMainThread && !_loggedOffMainPli) {
        _loggedOffMainPli = YES;
        NSLog(@"[WHEP] WARNING: requestKeyframe called off the main thread — proceeding, but the "
              @"PLI throttle expects main-only access (see the invariant in DataChannelBridge.m)");
    }
    if (_closed || _videoTrack <= 0) return NO;

    // ── ONE shared time-based throttle for ALL PLI paths ─────────────────────────────────
    // A minimum interval between PLIs, NOT a lifetime cap. The old policy (_pliRequests < 3
    // here, keyframeRequests < 5 in the client) reset only at connect, so after a couple of
    // mid-session freezes it was permanently exhausted and no PLI could ever be sent again.
    // Time-based instead: a burst of decode errors (23 were seen in one freeze) collapses to
    // ONE PLI, and a freeze ten minutes later still gets one. _pliRequests now only counts
    // sends for the log; it never gates.
    static const NSTimeInterval kMinPliInterval = 0.250;
    const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;   // monotonic
    if (_lastPliRequestedAt > 0 && (now - _lastPliRequestedAt) < kMinPliInterval) {
        return NO;   // a recent PLI is still outstanding — suppress this one
    }
    _lastPliRequestedAt = now;
    _pliRequests++;

    if (rtcRequestKeyframe(_videoTrack) >= 0) return YES;
    NSLog(@"[WHEP] PLI request %d FAILED — rtcRequestKeyframe rejected", _pliRequests);
    return NO;
}

- (nullable NSString *)rtpStatsSummary {
    const ManifoldH264DepacketizerStats stats = [self snapshotStats];
    if (stats.packetsReceived == 0) return nil;

    os_unfair_lock_lock(&_rtpLock);
    const uint64_t handedOff = _accessUnitsHandedOff, droppedBusy = _accessUnitsDroppedBusy;
    os_unfair_lock_unlock(&_rtpLock);

    return [NSString stringWithFormat:
            @"%llu pkts (%llu accepted) → %llu frames (%llu key) | "
            @"SPS=%llu PPS=%llu IDR=%llu slice=%llu SEI=%llu | "
            @"seqGaps=%llu lost=%llu reorder=%llu malformed=%llu | "
            @"FU-A rx=%llu reassembled=%llu dropped=%llu | "
            @"auClosedByTimestamp=%llu wrongPt=%llu wrongSsrc=%llu rtcpInRtp=%llu | "
            @"handedOffToDecoder=%llu shedForBackpressure=%llu",
            stats.packetsReceived, stats.packetsAccepted, stats.accessUnits, stats.keyframes,
            stats.nalSPS, stats.nalPPS, stats.nalIDR, stats.nalSlice, stats.nalSEI,
            stats.seqGaps, stats.packetsLost, stats.packetsReordered, stats.packetsMalformed,
            stats.fuaPackets, stats.fuaReassembled, stats.fuaDropped,
            stats.accessUnitsByTimestamp, stats.packetsWrongPayloadType, stats.packetsWrongSSRC,
            stats.packetsRTCP, handedOff, droppedBusy];
}

- (nullable NSString *)selectedCandidatePair {
    if (_closed || _pc <= 0) return nil;
    char local[512] = {0}, remote[512] = {0};
    int rc = rtcGetSelectedCandidatePair(_pc, local, (int)sizeof(local), remote, (int)sizeof(remote));
    if (rc < 0) return nil;
    return [NSString stringWithFormat:@"%s  ->  %s", local, remote];
}

- (void)close {
    // Main queue only. Destroying a PeerConnection from inside one of its own callbacks
    // deadlocks: the destructor waits for the Processor that the callback is running on.
    NSAssert(NSThread.isMainThread, @"ManifoldWHEPSession must be closed on the main queue");
    if (_closed) return;
    _closed = YES;
    self.offerCompletion = nil;
    self.onConnectionState = nil;
    self.onIceState = nil;

    if (_statsTimer) {
        dispatch_source_cancel(_statsTimer);
        _statsTimer = nil;
    }

    if (_videoTrack > 0) {
        // Unregister BEFORE freeing anything the callbacks touch.
        rtcSetMessageCallback(_videoTrack, NULL);
        rtcSetOpenCallback(_videoTrack, NULL);
        rtcSetClosedCallback(_videoTrack, NULL);

        NSLock *trackLock = ManifoldWHEPSessionsLock();
        [trackLock lock];
        [ManifoldWHEPTrackSessions() removeObjectForKey:@(_videoTrack)];
        [trackLock unlock];
        _videoTrack = 0;
    }

    // Stop new work reaching the decode queue. Frames ALREADY queued still run — their
    // blocks hold the handler, and by extension the decoder — which is why the Swift side
    // tears the decoder down with `decodeQueue.async`, behind them, rather than inline.
    self.onVideoAccessUnit = nil;

    // A message callback may be running RIGHT NOW on the track thread, already past the
    // unregister above. Detach the depacketizer under the lock so that callback either
    // completes first or finds NULL, then free it once no one can reach it.
    os_unfair_lock_lock(&_rtpLock);
    ManifoldH264Depacketizer *depacketizer = _depacketizer;
    _depacketizer = NULL;
    os_unfair_lock_unlock(&_rtpLock);
    if (depacketizer) {
        ManifoldH264DepacketizerFlush(depacketizer);
        ManifoldH264DepacketizerDestroy(depacketizer);
    }

    if (_pc > 0) {
        // Unregister callbacks first so nothing new is enqueued during teardown.
        rtcSetStateChangeCallback(_pc, NULL);
        rtcSetIceStateChangeCallback(_pc, NULL);
        rtcSetGatheringStateChangeCallback(_pc, NULL);
        rtcClosePeerConnection(_pc);
        rtcDeletePeerConnection(_pc);

        NSLock *lock = ManifoldWHEPSessionsLock();
        [lock lock];
        [ManifoldWHEPSessions() removeObjectForKey:@(_pc)];
        [lock unlock];

        NSLog(@"[WHEP-BRIDGE] pc %d closed and deleted", _pc);
        _pc = 0;
    }
}

- (void)dealloc {
    // Should not happen — callers close explicitly — but leaking a PeerConnection is worse
    // than a warning, and the weak table means callbacks are already safe by this point.
    if (!_closed && _pc > 0) {
        NSLog(@"[WHEP-BRIDGE] WARNING: pc %d deallocated without -close", _pc);
        if (_videoTrack > 0) rtcSetMessageCallback(_videoTrack, NULL);
        rtcSetStateChangeCallback(_pc, NULL);
        rtcSetIceStateChangeCallback(_pc, NULL);
        rtcSetGatheringStateChangeCallback(_pc, NULL);
        rtcDeletePeerConnection(_pc);
    }
    if (_statsTimer) dispatch_source_cancel(_statsTimer);
    if (_depacketizer) ManifoldH264DepacketizerDestroy(_depacketizer);
}

@end
