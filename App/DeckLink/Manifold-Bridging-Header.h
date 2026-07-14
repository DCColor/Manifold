// Objective-C bridging header — exposes the pure Obj-C DeckLink bridge to Swift. Keep this
// limited to Swift-visible Obj-C headers (no C++ — DeckLinkBridge.h is C++-free by design).
#import "DeckLinkBridge.h"

// Same rule for NDI: NDIBridge.h is pure Obj-C and pulls in NO NDI SDK headers, so the SDK's C
// API never reaches Swift (or the repo). The Obj-C++ side owns all of it.
#import "NDIBridge.h"
