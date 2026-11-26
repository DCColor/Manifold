# Avid Media Composer marker reference (reduced)

Reduced copies of a Media Composer 25.12.2 marker export (4 one-frame markers on TC1, V1, V2, A1), made 2026-11-25
for docs/MARKER_EXPORT_PLAN.md §10 (decision P1, §14). The originals stay outside the repo in
`~/Code/Manifold/fixtures/markers/avid/` and are never committed, nor are the AAF and screenshot beside them (§13).

| File | From | Changed |
|---|---|---|
| `avid-mc25.12.txt` | `AVID MARKERS TEXT.txt` | The Avid login → `editor` (same length). Otherwise byte for byte: tabs, trailing spaces, LF |
| `avid-mc25.12.xml` | `AVID MARKERS XML.xml` | The login → `editor`; each `_ATN_CRM_ID` → the same shape, its machine-specific part replaced by a counter and zeros. Otherwise byte for byte: `//`, `/13`, attribute order, envelope, LF |

Both files keep their original sizes (173 and 15 412 bytes). Comments are the track names Joey typed; timestamps are
kept.

## How they were made

Run from the repo root, on the originals read-only:

```sh
set -e
SRC="$HOME/Code/Manifold/fixtures/markers/avid"
OUT="docs/markers/avid-reference"
LOGIN="<the login in the originals>"   # not recorded here
sed "s/$LOGIN/editor/g" "$SRC/AVID MARKERS TEXT.txt" > "$OUT/avid-mc25.12.txt"
sed "s/$LOGIN/editor/g" "$SRC/AVID MARKERS XML.xml" \
  | awk '{ if (match($0, /060a2b340101010501010f1013-000000-[0-9a-f]+-[0-9a-f]+-[0-9a-f]+/)) { n++;
      id=sprintf("060a2b340101010501010f1013-000000-%016x-000000000000-0000", n);
      $0=substr($0,1,RSTART-1) id substr($0,RSTART+RLENGTH) } print }' > "$OUT/avid-mc25.12.xml"
```

Check: neither output contains the login or any original id tail; `diff` against the originals shows only those 8
lines in the XML.

Later exports (J1, and B0's FCPXML) get the same treatment before entering the repo; an FCPXML also has its
`media-rep` paths replaced with `file:///fixtures/…`.
