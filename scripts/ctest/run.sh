#!/bin/zsh
# C unit-test harnesses for the pure-C bitstream code in App/H264 and App/SRT, which the app target
# compiles directly and `swift test` cannot reach. Today: the HEVC access-unit builder and its
# random-access gate (docs/COLOR_MANAGEMENT_FINDINGS.md §6.10, Stage 3, decision 9).
#   zsh scripts/ctest/run.sh
# Builds into a temporary directory with the same sources the app compiles, under AddressSanitizer
# and UndefinedBehaviorSanitizer, warnings as errors. Exit status is the harness's.
set -eu
REPO=${0:A:h:h:h}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
clang -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined -fno-sanitize-recover=all \
  -I "$REPO/App/H264" -I "$REPO/App/SRT" \
  "$REPO/scripts/ctest/hevc_access_unit_builder_test.c" \
  "$REPO/App/H264/HEVCAccessUnitBuilder.c" \
  "$REPO/App/H264/H264AccessUnitBuilder.c" \
  "$REPO/App/H264/H264AnnexBScanner.c" \
  "$REPO/App/SRT/SRTAccessUnitReader.c" \
  -o "$OUT/hevc_access_unit_builder_test"
"$OUT/hevc_access_unit_builder_test"
