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
@end

static NSMapTable<NSNumber *, ManifoldWHEPSession *> *ManifoldWHEPSessions(void) {
    static NSMapTable *sessions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sessions = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory |
                                                      NSPointerFunctionsObjectPersonality
                                         valueOptions:NSPointerFunctionsWeakMemory |
                                                      NSPointerFunctionsObjectPersonality];
    });
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

@implementation ManifoldWHEPSession {
    int _pc;
    BOOL _closed;
}

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
    return YES;
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
        rtcSetStateChangeCallback(_pc, NULL);
        rtcSetIceStateChangeCallback(_pc, NULL);
        rtcSetGatheringStateChangeCallback(_pc, NULL);
        rtcDeletePeerConnection(_pc);
    }
}

@end
