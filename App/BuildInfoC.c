//
//  BuildInfoC.c
//  Manifold
//
//  See BuildInfoC.h. This TU is compiled with the app target's real C flags, which is the entire
//  point: the macros below are set by clang from the actual GCC_OPTIMIZATION_LEVEL in force, so the
//  [BUILD] banner reports what was really compiled rather than what project.yml claims.
//
//  DO NOT add -O flags to this file specifically, and do not move these functions into a header as
//  `static inline`. A header is parsed by Swift's clang importer with ITS flags, not the app
//  target's, so an inlined version could report a different level than the code being measured.
//  The measurement is only trustworthy while it lives in a normally-compiled .c file.
//

#include "BuildInfoC.h"

const char *ManifoldCOptimizationLevel(void) {
    // Order matters: clang defines BOTH __OPTIMIZE__ and __OPTIMIZE_SIZE__ under -Os, so the
    // size-optimized case has to be tested first or it would report as plain "-O".
#if defined(__OPTIMIZE_SIZE__)
    return "-Os";
#elif defined(__OPTIMIZE__)
    return "-O";
#else
    return "-O0";
#endif
}

int ManifoldCIsOptimized(void) {
#if defined(__OPTIMIZE__)
    return 1;
#else
    return 0;
#endif
}
