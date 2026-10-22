#!/usr/bin/env python3
"""Read every SDI scaling fixture back and check it (scripts/sdi-scaling/README.md).

    python3 scripts/sdi-scaling/verify.py [file.mov ...]     # default: build/sdi-scaling/sdi-*.mov

Stdlib only. Needs `ffmpeg` and `mediainfo` on PATH (the same tools the generator uses; ffprobe is NOT needed —
`ffmpeg -i` prints the same libavformat stream description).

Per file:
  tags     ffmpeg's stream line: prores (HQ), yuv422p10le, tv range, bt709 / bt709 / bt709, SAR 1:1, W×H, rate;
           pcm_s24le, 48000 Hz, stereo. mediainfo: sample entries `apch` and `in24`, little-endian, frame and
           sample counts, colour tags read from the container.
  picture  frame 0 decoded to 10-bit luma, measured against the recipe (ProRes is lossy, so with tolerances):
           border rows and columns ≈ 940, background ≈ 192, the centre 2×2 ≈ 940, the ring's radius measured
           left, right, up and down from the centre (equal within 1 px = round), the line-pair patches still
           alternating (contrast ≥ 60 % of white − black).
Exit status 1 if any check fails.
"""
import glob
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
WHITE, BLACK, GREY = 940, 64, 192          # 235 / 16 / 48 at 10 bits


def run(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout + subprocess.run(args, capture_output=True, text=True).stderr


def recipes():
    out = {}
    for line in open(os.path.join(HERE, "recipes.tsv")):
        if not line.strip() or line.startswith("#"):
            continue
        label, w, h, rate = line.rstrip("\n").split("\t")[:4]
        out[label] = (int(w), int(h), rate)
    return out


def luma(path, w, h):
    # The decoder's own yuv422p10le, Y plane only. NOT `-pix_fmt gray10le`: that conversion expands limited range
    # to full (white 940 → 1023, the background 192 → 149), which measures swscale rather than the file.
    raw = subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-i", path, "-frames:v", "1",
                          "-f", "rawvideo", "-pix_fmt", "yuv422p10le", "-"], capture_output=True).stdout
    assert len(raw) == w * h * 4, f"decoded {len(raw)} bytes, expected {w * h * 4}"
    raw = raw[:w * h * 2]
    vals = memoryview(raw).cast("H")
    return lambda x, y: vals[y * w + x]


def ring_radius(px, w, h, dx, dy):
    """Distance from the centre to the middle of the ring along one axis direction: the FIRST run of white met
    walking outward past the crosshair — anything further out (the label, the border) is not the ring."""
    cx, cy = (w - 1) / 2, (h - 1) / 2
    hits = []
    for r in range(int(min(w, h) * 0.2), int(max(w, h) * 0.5)):
        x, y = int(round(cx + dx * r - (0.5 if dx < 0 else 0))), int(round(cy + dy * r - (0.5 if dy < 0 else 0)))
        if not (0 <= x < w and 0 <= y < h):
            break
        if px(x, y) > (WHITE + GREY) // 2:
            hits.append(r)
        elif hits:
            break
    return sum(hits) / len(hits) if hits else None


def check(path, rec):
    w, h, rate = rec
    fails, rows = [], {}
    info = run("ffmpeg", "-hide_banner", "-i", path)
    v = re.search(r"Stream #0:\d+.*Video: (.*)", info)
    a = re.search(r"Stream #0:\d+.*Audio: (.*)", info)
    vline, aline = (v.group(1) if v else ""), (a.group(1) if a else "")
    rows["ffmpeg video"] = vline.strip()
    rows["ffmpeg audio"] = aline.strip()
    want_v = ["prores (HQ)", "apch", "yuv422p10le(tv, bt709, progressive)", f"{w}x{h}", "SAR 1:1"]
    for s in want_v:
        if s not in vline:
            fails.append(f"video stream lacks '{s}'")
    fps = {"24000/1001": "23.98 fps", "60000/1001": "59.94 fps"}.get(rate, "")
    if fps and fps not in vline:
        fails.append(f"video stream lacks '{fps}'")
    for s in ["pcm_s24le", "in24", "48000 Hz", "stereo", "s32"]:
        if s not in aline:
            fails.append(f"audio stream lacks '{s}'")

    mi = run("mediainfo", "--Output=Video;%CodecID%|%Width%|%Height%|%PixelAspectRatio%|%FrameRate_Num%/%FrameRate_Den%|%FrameCount%|%colour_primaries%|%transfer_characteristics%|%matrix_coefficients%|%colour_range%|%colour_primaries_Source%|%BitDepth%|%ChromaSubsampling%\\n", path).strip()
    ma = run("mediainfo", "--Output=Audio;%CodecID%|%Format_Settings_Endianness%|%BitDepth%|%Channel(s)%|%SamplingRate%|%SamplingCount%\\n", path).strip()
    rows["mediainfo video"] = mi
    rows["mediainfo audio"] = ma
    mv = mi.split("|")
    if len(mv) >= 13:
        # Not 9 (range) or 11 (bit depth): mediainfo reports neither for ProRes. A .mov's `colr` is QuickTime `nclc`,
        # which has no range field; ProRes is limited range by definition, and ffmpeg's `tv` above is the check.
        expect = {0: "apch", 1: str(w), 2: str(h), 3: "1.000", 6: "BT.709", 7: "BT.709", 8: "BT.709", 10: "Container / Stream", 12: "4:2:2"}
        for i, e in expect.items():
            if mv[i] != e:
                fails.append(f"mediainfo field {i} = '{mv[i]}', expected '{e}'")
    else:
        fails.append("mediainfo video line unreadable")
    mav = ma.split("|")
    if len(mav) >= 6:
        for i, e in {0: "in24", 1: "Little", 2: "24", 3: "2", 4: "48000"}.items():
            if mav[i] != e:
                fails.append(f"mediainfo audio field {i} = '{mav[i]}', expected '{e}'")
        frames, samples = int(mv[5]), int(mav[5])
        num, den = map(int, rate.split("/"))
        if frames * 48000 * den != samples * num:
            fails.append(f"{frames} frames and {samples} samples are not the same length")
        rows["length"] = f"{frames} frames = {samples} samples = {samples / 48000:.4f} s"

    px = luma(path, w, h)
    edge = [px(x, 0) for x in range(w)] + [px(x, h - 1) for x in range(w)] + [px(0, y) for y in range(h)] + [px(w - 1, y) for y in range(h)]
    bg = px(w // 2, int(h * 0.5 - min(w, h) * 0.2))           # inside the ring, off the crosshair
    centre = [px(w // 2 - 1 + i, h // 2 - 1 + j) for i in (0, 1) for j in (0, 1)]
    radii = [ring_radius(px, w, h, dx, dy) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))]
    want_r = 0.35 * min(w, h)
    y0 = h - 24 - 64
    lp = [px(24 + i, y0 + 32) for i in range(8, 40)]            # the 1-px vertical line pairs, bottom left
    contrast = (max(lp) - min(lp)) / (WHITE - BLACK)
    rows["border min / max"] = f"{min(edge)} / {max(edge)}"
    rows["background"] = str(bg)
    rows["centre 2x2"] = " ".join(map(str, centre))
    rows["ring radius R / L / D / U"] = " / ".join("—" if r is None else f"{r:.1f}" for r in radii) + f" (recipe {want_r:.1f})"
    rows["1-px line pairs"] = f"{min(lp)}–{max(lp)}, contrast {contrast:.0%}"
    if min(edge) < WHITE - 40:
        fails.append(f"border dips to {min(edge)}")
    if abs(bg - GREY) > 8:
        fails.append(f"background {bg}, expected ≈ {GREY}")
    if min(centre) < WHITE - 40:
        fails.append(f"centre {centre}")
    if any(r is None for r in radii) or max(radii) - min(radii) > 1.0 or abs(sum(radii) / 4 - want_r) > 1.5:
        fails.append(f"ring radii {radii}, recipe {want_r:.1f}")
    if contrast < 0.6:
        fails.append(f"1-px line pairs at {contrast:.0%} contrast")
    return rows, fails


def main():
    files = sys.argv[1:] or sorted(glob.glob(os.path.join(REPO, "build", "sdi-scaling", "sdi-*.mov")))
    if not files:
        print("no fixtures; run make_fixtures.sh first")
        return 1
    recs, bad = recipes(), 0
    for f in files:
        label = os.path.basename(f)[len("sdi-"):-len(".mov")]
        if label not in recs:
            print(f"{f}: not in recipes.tsv"); bad += 1; continue
        rows, fails = check(f, recs[label])
        print(f"== {os.path.basename(f)}: {'PASS' if not fails else 'FAIL'}")
        for k, v in rows.items():
            print(f"   {k:26} {v}")
        for x in fails:
            print(f"   ✗ {x}")
        bad += bool(fails)
    print(f"{len(files) - bad} / {len(files)} pass")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
