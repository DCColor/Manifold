#!/bin/bash
# Build vtdnxprobe. Objective-C, not Swift, and unlike mxfmeas that is not a style choice: the probe
# hands raw `AVPacket` bytes to `CMBlockBufferReplaceDataBytes` and builds `CMSampleBuffer`s by hand,
# which is C the whole way down. It links the vendored libav AND AVFoundation/VideoToolbox/
# MediaToolbox in one process on purpose — the comparison it performs is only meaningful if both
# decoders run against the same file in the same process.
#
# ⚠️ It #includes the APP'S OWN CFFmpeg shim (`Packages/ManifoldCore/Sources/CFFmpeg/include/shim.h`)
# rather than a private copy, for the reason build-mxfmeas.sh states: a harness measuring a different
# libav measures nothing.
#
# ⚠️ -framework MediaToolbox is REQUIRED and is easy to lose. `MTRegisterProfessionalVideoWorkflowFormatReaders`
# lives there, not in AVFoundation, and without it the `ref` phase reports "AVFoundation could not
# open it" — which looks like a finding and is an omission. See README.md's warning.
#
# ⚠️ The dylibs' install names are @rpath/… so the -rpath is REQUIRED — without it the binary
# compiles and then fails to launch with a dyld error that does not mention rpath. It is computed
# from the output location, not assumed.
#
# OUT=<dir> puts the binary somewhere other than this directory (the repo's .gitignore covers only
# `docs/mxf-fixtures/vtdnxprobe`).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
FF="$ROOT/ThirdParty/ffmpeg"
OUT="${OUT:-.}"
[ -d "$FF/lib" ] || { echo "no $FF/lib — run scripts/build_ffmpeg.sh first"; exit 1; }
[ -d "/Library/Video/Professional Video Workflow Plug-Ins" ] || \
  echo "⚠️  Pro Video Formats is NOT installed — every AVFoundation column will be empty. See README.md."
mkdir -p "$OUT"
xcrun clang -O2 -fobjc-arc -o "$OUT/vtdnxprobe" vtdnxprobe.m \
  -I "$ROOT/Packages/ManifoldCore/Sources/CFFmpeg/include" \
  -I "$FF/include" \
  -L "$FF/lib" -lavformat -lavcodec -lavutil \
  -Xlinker -rpath -Xlinker "$FF/lib" \
  -framework Foundation -framework AVFoundation -framework CoreMedia \
  -framework CoreVideo -framework VideoToolbox -framework MediaToolbox
echo "built $OUT/vtdnxprobe"
