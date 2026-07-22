//
//  BuildInfoC.h
//  Manifold
//
//  The C/ObjC half of the [BUILD] banner (see App/BuildInfo.swift).
//
//  WHY A C FILE EXISTS JUST FOR THIS. Swift's optimization level is observable from Swift (assert's
//  autoclosure survives only under -Onone). The C/ObjC level is NOT: it is a different compiler
//  invocation with a different build setting (GCC_OPTIMIZATION_LEVEL), and nothing on the Swift side
//  can see it. That gap matters here more than it would in most projects, because the hottest code
//  in the WHEP path is C and ObjC — H264Depacketizer.c receives every RTP packet, and
//  DataChannelBridge.m produces the arrival timestamps the whole jitter/underrun measurement is
//  built on. A build with Swift at -O and C at -O0 would look valid to a Swift-only probe and
//  produce numbers that are not.
//
//  These two functions are compiled AS PART OF THE APP TARGET, so they see the real
//  GCC_OPTIMIZATION_LEVEL. clang defines __OPTIMIZE__ whenever optimizing and __OPTIMIZE_SIZE__
//  additionally under -Os/-Oz, so the answer is OBSERVED from the actual compilation rather than
//  copied from project.yml and left to drift.
//

#ifndef BuildInfoC_h
#define BuildInfoC_h

/// The C/ObjC optimization level this binary's C sources were built at: "-O0", "-O" or "-Os".
/// Returns a static string literal — never free it.
const char *ManifoldCOptimizationLevel(void);

/// 1 when the C sources were compiled with optimization of any kind, 0 at -O0.
/// This is the measurement-validity gate: 0 means C-side timings are not meaningful.
int ManifoldCIsOptimized(void);

#endif /* BuildInfoC_h */
