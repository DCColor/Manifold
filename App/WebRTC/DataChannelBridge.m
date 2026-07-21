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
