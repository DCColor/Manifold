#!/bin/bash
# Build mxfmeas. Like libavmeas and unlike the other harnesses, it has to LINK THE VENDORED LIBAV —
# a one-line `xcrun swiftc -O -o x x.swift` cannot express that.
#
# ⚠️ It #includes the APP'S OWN CFFmpeg shim (`Packages/ManifoldCore/Sources/CFFmpeg/include/shim.h`)
# rather than a private copy, so the libav surface this measures is by construction the one the app
# compiles against. A harness measuring a different libav measures nothing — which is the whole
# premise of the comparison it performs.
#
# ⚠️ NOT -parse-as-library. Single-file script; top-level code is only legal without it, and the
# failure message ("statements are not allowed at the top level") does not name the flag. Same trap
# as scrubmeas.swift, avpvomeas.swift and libavmeas.swift.
#
# ⚠️ The dylibs' install names are @rpath/… so the -rpath is REQUIRED — without it the binary
# compiles and then fails to launch with a dyld error that does not mention rpath. It is relative to
# the binary, so the built harness stays runnable from any working directory as long as the repo is
# intact.
#
# OUT=<dir> puts the binary somewhere other than this directory (the repo's .gitignore covers only
# `docs/mxf-fixtures/mxfmeas`). The rpath is computed from the output location, not assumed.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
FF="$ROOT/ThirdParty/ffmpeg"
OUT="${OUT:-.}"
[ -d "$FF/lib" ] || { echo "no $FF/lib — run scripts/build_ffmpeg.sh first"; exit 1; }
mkdir -p "$OUT"
xcrun swiftc -O -o "$OUT/mxfmeas" mxfmeas.swift \
  -import-objc-header "$ROOT/Packages/ManifoldCore/Sources/CFFmpeg/include/shim.h" \
  -Xcc -I -Xcc "$FF/include" \
  -L "$FF/lib" -lavformat -lavcodec -lavutil -lswscale -lswresample \
  -Xlinker -rpath -Xlinker "$FF/lib"
echo "built $OUT/mxfmeas"
