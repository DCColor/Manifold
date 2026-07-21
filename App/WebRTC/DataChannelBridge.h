//
//  DataChannelBridge.h
//  Manifold
//
//  Swift-visible seam onto libdatachannel (the WebRTC transport for WHEP).
//
//  Same discipline as DeckLinkBridge.h and NDIBridge.h: this header is PURE
//  Objective-C/C and pulls in NO libdatachannel headers, so `rtc/rtc.h` never
//  reaches Swift or the bridging header's module scan. The .m file owns all of it.
//
//  STEP 1 OF 4 (WHEP): a LINK SMOKE TEST — prove the static library is present,
//  initialized, and callable, and that the app still launches with the DeckLink C++
//  in the same binary. (`ManifoldWebRTCLinkSmokeTest`, below.)
//
//  STEP 2 OF 4 (WHEP): the HANDSHAKE — `ManifoldWHEPSession`, below. A recvonly
//  PeerConnection, a non-trickle SDP offer, a remote answer, and ICE/DTLS coming up.
//  Still no RTP depacketization and no decode: step 2 succeeds when the transport
//  connects. Signalling (the HTTP POST) is NOT here — it lives in Swift/URLSession.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// libdatachannel's compile-time version string (e.g. "0.24.5"), read from the
/// `RTC_VERSION` macro in `rtc/version.h`.
///
/// This proves the HEADERS resolved. It does not prove linkage — the macro is
/// baked in at compile time — so treat it only as the first half of the check.
/// Returns a string literal; never NULL, never needs freeing.
const char *ManifoldWebRTCVersion(void);

/// Exercises real libdatachannel entry points to prove the STATIC ARCHIVE linked
/// and its whole transitive dependency graph resolved.
///
/// In order, it:
///   1. installs a log callback via `rtcInitLogger` — the first genuine call into
///      the archive, and it lights up the library's internal C++ logging (plog),
///   2. calls `rtcPreload`, which spins up the transport machinery,
///   3. creates and immediately deletes a `PeerConnection` with an empty config —
///      no ICE servers, no gathering, no network traffic. Constructing one forces
///      libjuice (ICE), libSRTP, usrsctp and Mbed TLS (certificate generation) to
///      actually be reachable, which a bare `rtcInitLogger` call would not.
///
/// Deliberately does NOT call `rtcCleanup()`: that blocks until every resource is
/// released, and a hang there would muddy the one signal this function exists to
/// give. Full teardown belongs with real WHEP session lifecycle later.
///
/// @param outMessage On return, a human-readable summary suitable for logging.
///                   Optional; pass NULL to ignore.
/// @return YES if every step succeeded.
BOOL ManifoldWebRTCLinkSmokeTest(NSString *_Nullable *_Nullable outMessage);

#pragma mark - WHEP session (step 2: the handshake)

/// PeerConnection state. Values mirror libdatachannel's `rtcState` one-for-one, so the
/// mapping is a cast — but Swift never sees an `rtc*` type.
typedef NS_ENUM(int32_t, ManifoldWHEPConnectionState) {
    ManifoldWHEPConnectionStateNew          = 0,
    ManifoldWHEPConnectionStateConnecting   = 1,
    ManifoldWHEPConnectionStateConnected    = 2,  ///< DTLS is up. Step 2's success condition.
    ManifoldWHEPConnectionStateDisconnected = 3,
    ManifoldWHEPConnectionStateFailed       = 4,
    ManifoldWHEPConnectionStateClosed       = 5,
};

/// ICE transport state. Values mirror libdatachannel's `rtcIceState` one-for-one.
typedef NS_ENUM(int32_t, ManifoldWHEPIceState) {
    ManifoldWHEPIceStateNew          = 0,
    ManifoldWHEPIceStateChecking     = 1,
    ManifoldWHEPIceStateConnected    = 2,
    ManifoldWHEPIceStateCompleted    = 3,
    ManifoldWHEPIceStateFailed       = 4,
    ManifoldWHEPIceStateDisconnected = 5,
    ManifoldWHEPIceStateClosed       = 6,
};

/// One WHEP playback session's WebRTC half: a receive-only PeerConnection that produces an
/// offer and consumes an answer. It does NO networking of its own beyond ICE/DTLS — the
/// SDP exchange is plain HTTP and belongs to the caller (see WHEPClient.swift).
///
/// This is a spec-compliant WHEP *receiver*, not a client for any particular server: the
/// offer it builds is standard recvonly SDP per draft-ietf-wish-whep.
///
/// THREADING. libdatachannel raises callbacks on its own internal Processor threads. This
/// class absorbs that: every block it vends is invoked on the MAIN queue, already marshaled.
/// In exchange, the caller must drive it from the main queue too — in particular `close`,
/// which must never run on a libdatachannel callback thread (tearing a PeerConnection down
/// from inside its own callback deadlocks against the Processor it is draining).
@interface ManifoldWHEPSession : NSObject

/// Creates the PeerConnection and immediately adds the recvonly video + audio m-sections,
/// so the "transceivers before the offer" ordering is structural rather than a convention
/// a future caller could get wrong.
///
/// @param stunServer A STUN URL (e.g. `stun:stun.example.org:19302`), or nil for none.
///                   nil is a legitimate configuration, not a degraded one: a WHEP server
///                   returns its own candidates in the answer, and on many networks host
///                   candidates plus those are sufficient. Try nil first; add a STUN server
///                   if ICE fails to find a working pair.
+ (nullable instancetype)sessionWithStunServer:(nullable NSString *)stunServer
                                         error:(NSString *_Nullable *_Nullable)outError;

/// Fires on the MAIN queue for every PeerConnection state transition.
@property (nonatomic, copy, nullable) void (^onConnectionState)(ManifoldWHEPConnectionState state,
                                                                NSString *name);

/// Fires on the MAIN queue for every ICE transport state transition.
@property (nonatomic, copy, nullable) void (^onIceState)(ManifoldWHEPIceState state, NSString *name);

/// Generates the offer and gathers ICE candidates NON-TRICKLE: `completion` is not called
/// until gathering reaches complete, so the SDP it hands back already carries every
/// `a=candidate` line and is ready to POST as-is. Reading the description any earlier
/// yields a candidate-less offer that negotiates and then never connects.
///
/// `completion` runs on the MAIN queue, exactly once — with an SDP, or with an error if
/// gathering fails or `timeout` elapses first. Call once per session.
- (void)generateRecvOnlyOfferWithTimeout:(NSTimeInterval)timeout
                              completion:(void (^)(NSString *_Nullable offerSDP,
                                                   NSString *_Nullable error))completion;

/// Applies the WHEP server's SDP answer, which starts ICE connectivity checks and then DTLS.
/// Progress arrives via `onIceState` / `onConnectionState`.
- (BOOL)setRemoteAnswer:(NSString *)answerSDP error:(NSString *_Nullable *_Nullable)outError;

/// The nominated ICE candidate pair, once connected — the "which path did it pick" line that
/// webrtc-internals shows. nil before connection.
- (nullable NSString *)selectedCandidatePair;

/// Closes and destroys the PeerConnection. Main queue only; safe to call twice.
- (void)close;

@end

NS_ASSUME_NONNULL_END
