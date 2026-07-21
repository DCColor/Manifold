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
//  STEP 1 OF 4 (WHEP): this is a LINK SMOKE TEST only — prove the static library
//  is present, initialized, and callable, and that the app still launches with the
//  DeckLink C++ in the same binary. There is no WHEP handshake, no RTP, no decode.
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

NS_ASSUME_NONNULL_END
