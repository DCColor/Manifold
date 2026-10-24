#!/bin/zsh
# Checks every interlaced fixture three ways (docs/INTERLACED_FINDINGS.md §10, Q5 and Q11):
#   1. FFmpeg: the stream line's field label (`ffmpeg -i`; there is no ffprobe binary on the build Mac) and the
#      decoder's flags on the first three frames (`showinfo` i:T / i:B / i:P).
#   2. mediainfo: ScanType / ScanOrder.
#   3. The app's own readers (FileScan + SPSColor), fed by scanprobe.swift's route rather than the app's.
# ⚠️ FFmpeg prints "top coded first (swapped)" for a `fiel` 9 ProRes (§6). The picture and the decoder say TFF.
#
#   zsh scripts/interlaced/verify.sh [dir]      # default build/interlaced-fixtures
set -eu
HERE=${0:A:h}; REPO=${HERE:h:h}
DIR=${1:-$REPO/build/interlaced-fixtures}
SRC=$REPO/Packages/ManifoldCore/Sources
TOOLS=$DIR/.tools; mkdir -p $TOOLS
# Three modules, as the package builds them: SPSColor, then FileScan on it, then the probe.
swiftc -O -parse-as-library -emit-module -emit-library -static -module-name SPSColor \
       -emit-module-path $TOOLS/SPSColor.swiftmodule -o $TOOLS/libSPSColor.a $SRC/SPSColor/*.swift
swiftc -O -parse-as-library -emit-module -emit-library -static -module-name FileScan -I $TOOLS \
       -emit-module-path $TOOLS/FileScan.swiftmodule -o $TOOLS/libFileScan.a $SRC/FileScan/*.swift
swiftc -O -I $TOOLS -L $TOOLS -lFileScan -lSPSColor -o $TOOLS/scanprobe $HERE/scanprobe.swift

for f in $DIR/*.(mov|mxf|ts); do
  n=${f:t}
  print -- "── $n"
  print -- "   ffmpeg   : $(ffmpeg -hide_banner -i $f 2>&1 | grep -m1 'Video:' | sed -E 's/.*Video: //' | cut -c1-110)"
  print -- "   showinfo : $(ffmpeg -hide_banner -i $f -map 0:v -vf showinfo -frames:v 3 -f null - 2>&1 | grep -oE ' i:[A-Z?]' | tr -d ' \n')"
  print -- "   mediainfo: $(mediainfo --Inform='Video;%ScanType% %ScanOrder% %Height%' $f)"
  case $n in
    *.mov) print -- "   reader   : $($TOOLS/scanprobe mov $f)" ;;
    *.mxf) print -- "   reader   : $($TOOLS/scanprobe mxf $f)" ;;
    *.ts)
      codec=h264; [[ $n == hevc* ]] && codec=hevc
      ffmpeg -hide_banner -loglevel error -y -i $f -map 0:v -c copy -frames:v 1 -f $codec $TOOLS/au.bin
      print -- "   reader   : $($TOOLS/scanprobe annexb $codec $TOOLS/au.bin)" ;;
  esac
done
