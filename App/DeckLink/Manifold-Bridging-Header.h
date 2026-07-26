// Objective-C bridging header — exposes the pure Obj-C DeckLink bridge to Swift. Keep this
// limited to Swift-visible Obj-C headers (no C++ — DeckLinkBridge.h is C++-free by design).
#import "DeckLinkBridge.h"

// Same rule for NDI: NDIBridge.h is pure Obj-C and pulls in NO NDI SDK headers, so the SDK's C
// API never reaches Swift (or the repo). The Obj-C++ side owns all of it.
#import "NDIBridge.h"

// Same rule again for libdatachannel (WHEP transport): DataChannelBridge.h is pure Obj-C and
// pulls in NO <rtc/*> headers, so libdatachannel's C API never reaches Swift. The .m side owns
// it — and because that seam is pure C, the app target's C++ standard (gnu++14) never has to
// meet libdatachannel's C++17.
#import "DataChannelBridge.h"

// SRT transport (stage 3d — the shipping path; the stage-2 spike this replaced is deleted). Same
// pure-C rule as the three above: SRTSession.h pulls in NEITHER <srt/*> NOR <libav*/*>, so neither
// library's API reaches Swift. It does include SRTAccessUnitReader.h, which is pure C too and
// which Swift genuinely needs — ManifoldSRTAccessUnit is the callback payload SRTFrameRouter
// reads. Imported by RELATIVE PATH for the same reason BuildInfoC.h is (below) — App/SRT is not
// on HEADER_SEARCH_PATHS and adding it to reach one file would widen the search scope for all of
// them.
//
// NO LONGER `#ifdef DEBUG`-GATED, and that is the point of the stage: unlike the spike, this is
// compiled and reachable in Release.
#import "../SRT/SRTSession.h"

// The C/ObjC optimization probe for the [BUILD] banner. Imported by RELATIVE PATH deliberately:
// every other header here resolves through HEADER_SEARCH_PATHS, and adding $(SRCROOT)/App to that
// list to reach one file would widen the search scope for all of them. In a change whose whole
// subject is build-configuration fragility, the import that needs no build-setting edit is the
// right one. See App/BuildInfoC.h for why this cannot be answered from Swift.
#import "../BuildInfoC.h"
