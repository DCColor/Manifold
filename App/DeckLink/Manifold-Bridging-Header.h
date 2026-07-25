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

// SRT STAGE 2 TRANSPORT SPIKE — TEMPORARY, DELETE WITH App/SRT/. Same pure-C rule as the three
// above: SRTSpike.h pulls in NEITHER <srt/*> NOR <libav*/*>, so neither library's API reaches
// Swift. Imported by RELATIVE PATH for the same reason BuildInfoC.h is (below) — App/SRT is not
// on HEADER_SEARCH_PATHS and adding it to reach one file would widen the search scope for all of
// them. The import is unconditional and safe in Release: the header's declarations, and the whole
// of SRTSpike.m, are `#ifdef DEBUG`, so under Release this resolves to an empty header.
#import "../SRT/SRTSpike.h"

// The C/ObjC optimization probe for the [BUILD] banner. Imported by RELATIVE PATH deliberately:
// every other header here resolves through HEADER_SEARCH_PATHS, and adding $(SRCROOT)/App to that
// list to reach one file would widen the search scope for all of them. In a change whose whole
// subject is build-configuration fragility, the import that needs no build-setting edit is the
// right one. See App/BuildInfoC.h for why this cannot be answered from Swift.
#import "../BuildInfoC.h"
