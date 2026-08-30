#!/bin/bash
# Build libavmeas. It exists because this harness, unlike the other three in this directory, has to
# LINK THE VENDORED LIBAV — a one-line `xcrun swiftc -O -o x x.swift` cannot express that.
#
# ⚠️ It #includes the APP'S OWN CFFmpeg shim (`Packages/ManifoldCore/Sources/CFFmpeg/include/shim.h`)
# rather than a private copy, so the libav surface this measures is by construction the one the app
# compiles against. Same reason the decode contract and the conversion are copied verbatim: a
# harness that measures a slightly different pipeline measures nothing.
#
# ⚠️ NOT -parse-as-library. Single-file script; top-level code is only legal without it, and the
# failure message ("statements are not allowed at the top level") does not name the flag. Same trap
# as scrubmeas.swift and avpvomeas.swift.
#
# ⚠️ The dylibs' install names are @rpath/… (checked with `otool -D`), so the -rpath is REQUIRED —
# without it the binary compiles and then fails to launch with a dyld error that does not mention
# rpath. It is relative to the binary, which lives here, so the built harness stays runnable from
# any working directory as long as the repo is intact.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
FF="$ROOT/ThirdParty/ffmpeg"
[ -d "$FF/lib" ] || { echo "no $FF/lib — run scripts/build_ffmpeg.sh first"; exit 1; }
xcrun swiftc -O -o libavmeas libavmeas.swift \
  -import-objc-header "$ROOT/Packages/ManifoldCore/Sources/CFFmpeg/include/shim.h" \
  -Xcc -I -Xcc "$FF/include" \
  -L "$FF/lib" -lavformat -lavcodec -lavutil -lswscale -lswresample \
  -Xlinker -rpath -Xlinker "@executable_path/../../ThirdParty/ffmpeg/lib"
echo "built ./libavmeas"
