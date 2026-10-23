#!/bin/zsh
# Builds the loopback tools into build/decklink-loopback/ (gitignored). Not part of the app.
set -eu
HERE=${0:A:h}; REPO=${HERE:h:h}; INC=$REPO/docs/BlackmagicDeckLinkSDK16.0/Mac/include; OUT=$REPO/build/decklink-loopback
mkdir -p $OUT
for t in ${@:-probe}; do
  clang++ -std=c++17 -O2 -Wall -Wno-unused-variable -I$INC $HERE/$t.cpp $INC/DeckLinkAPIDispatch.cpp \
    -framework CoreFoundation -o $OUT/$t
  echo "built $OUT/$t"
done
