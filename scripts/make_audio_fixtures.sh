#!/bin/zsh
#
#  make_audio_fixtures.sh — the audio-only test files (docs/STILLS_AND_AUDIO_ONLY_PLAN.md §6).
#
#  USAGE
#      scripts/make_audio_fixtures.sh            writes into $CODE_ROOT/Manifold/fixtures/audio (CODE_ROOT defaults to ~/Code)
#      FIXTURES_DIR=/some/dir scripts/make_audio_fixtures.sh
#
#  Each file is DURATION seconds of steady tone, one frequency per channel, so a channel on the wrong meter or the wrong
#  speaker can be told by ear. Generated, never copied from client media. Needs ffmpeg with libmp3lame, and python3 for
#  the iXML chunk, which ffmpeg cannot write.
#
#  BWF values, stated here because `afinfo` does not show `bext` (measured), so these are the cross-check:
#      bwf-bext-only.wav    TimeReference 172824000 at 48 kHz, no rate    → Time Reference 01:00:00.500
#      bwf-bext-ixml.wav    TimeReference 172974802 at 48 kHz, 24000/1001 → Timecode 01:00:00:01 @ 23.976
#      both: Origination Date 2026-11-04 12:30:15

set -eu

CODE_ROOT="${CODE_ROOT:-$HOME/Code}"
OUT="${FIXTURES_DIR:-$CODE_ROOT/Manifold/fixtures/audio}"
DURATION=6
FF=(ffmpeg -hide_banner -loglevel error -y)
TONES=(440 660 880 110 1100 1320 1540 1760)

mkdir -p "$OUT"

# The filter for `channels` tones at `rate`, joined into one stream of that layout.
tones() {
    local rate=$1 channels=$2 layout=$3 i inputs="" labels=""
    if (( channels == 1 )); then
        print -r -- "sine=frequency=${TONES[1]}:sample_rate=${rate}:duration=${DURATION},volume=0.25"
        return
    fi
    for (( i = 1; i <= channels; i++ )); do
        inputs+="sine=frequency=${TONES[$i]}:sample_rate=${rate}:duration=${DURATION},volume=0.25[c${i}];"
        labels+="[c${i}]"
    done
    print -r -- "${inputs}${labels}join=inputs=${channels}:channel_layout=${layout}"
}

make_wav() {
    local rate=$1 channels=$2 layout=$3 name=$4
    "${FF[@]}" -filter_complex "$(tones "$rate" "$channels" "$layout")" -c:a pcm_s24le "$OUT/$name"
}

for rate in 44100 48000 96000; do
    make_wav $rate 1 mono   "wav-${rate}-mono-24.wav"
    make_wav $rate 2 stereo "wav-${rate}-stereo-24.wav"
    make_wav $rate 6 5.1    "wav-${rate}-5.1-24.wav"
done

make_wav 48000 8 7.1 "wav-48000-7.1-24.wav"

STEREO48="$(tones 48000 2 stereo)"
STEREO44="$(tones 44100 2 stereo)"
"${FF[@]}" -filter_complex "$STEREO48" -c:a pcm_s24be "$OUT/aiff-48000-stereo-24.aif"
"${FF[@]}" -filter_complex "$STEREO44" -c:a libmp3lame -b:a 192k "$OUT/mp3-44100-stereo.mp3"
"${FF[@]}" -filter_complex "$STEREO48" -c:a aac -b:a 192k "$OUT/aac-48000-stereo.m4a"
"${FF[@]}" -filter_complex "$STEREO48" -c:a aac -b:a 192k -f adts "$OUT/aac-48000-stereo.aac"
"${FF[@]}" -filter_complex "$STEREO48" -c:a pcm_s24le -f mov "$OUT/audio-only.mov"

BWF_META=(-metadata origination_date=2026-11-04 -metadata origination_time=12:30:15)
"${FF[@]}" -filter_complex "$STEREO48" -c:a pcm_s24le -write_bext 1 "${BWF_META[@]}" \
    -metadata time_reference=172824000 "$OUT/bwf-bext-only.wav"
"${FF[@]}" -filter_complex "$STEREO48" -c:a pcm_s24le -write_bext 1 "${BWF_META[@]}" \
    -metadata time_reference=172974802 "$OUT/bwf-bext-ixml.wav"

# The iXML chunk, appended after `data`, with the RIFF size brought up to date.
python3 - "$OUT/bwf-bext-ixml.wav" <<'PY'
import struct, sys
path = sys.argv[1]
xml = (b'<?xml version="1.0" encoding="UTF-8"?><BWFXML><IXML_VERSION>1.5</IXML_VERSION><SPEED>'
       b'<TIMECODE_RATE>24000/1001</TIMECODE_RATE><TIMECODE_FLAG>NDF</TIMECODE_FLAG></SPEED></BWFXML>')
with open(path, 'r+b') as f:
    data = bytearray(f.read())
    assert data[:4] == b'RIFF' and data[8:12] == b'WAVE'
    if len(data) % 2:
        data += b'\0'
    data += b'iXML' + struct.pack('<I', len(xml)) + xml + (b'\0' if len(xml) % 2 else b'')
    data[4:8] = struct.pack('<I', len(data) - 8)
    f.seek(0)
    f.write(data)
PY

print "Wrote $(ls "$OUT" | wc -l | tr -d ' ') files to $OUT"
