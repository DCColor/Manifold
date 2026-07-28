#!/usr/bin/env python3
"""Generate a 10-bit step-wedge fixture with DENSE low-code sampling.

A linear 0-1 ramp cannot resolve the toe: the region of interest is 0.01-0.2 of the
post-range-expansion display code, and the toe crossover for gamma 2.4 sits near 0.138.
So the wedge is deliberately non-uniform - 32 of its 48 patches live below code 0.25.

Patches are FLAT and 240x180, so 4:2:0 chroma subsampling and any codec ringing at patch
edges cannot contaminate the patch interior (we sample the centre 60%).

Luma codes are chosen so that AFTER the shader's legal-range expansion the display value is
the target: y_norm = code/1023.984375, v = (y_norm - 64/1023.984375) * (1023.984375/876)
                                        = (code - 64) / 876
Chroma is neutral (512) everywhere, so R=G=B=v - the patch is a pure grey of known value.
"""
import subprocess, sys, json

W, H = 1920, 1080
COLS, ROWS = 8, 6
PW, PH = W // COLS, H // ROWS          # 240 x 180
FPS, SECONDS = 24, 4

TARGETS = [
    0.0025, 0.005, 0.0075, 0.010, 0.0125, 0.015, 0.0175, 0.020,
    0.0225, 0.025, 0.0275, 0.030, 0.035, 0.040, 0.045, 0.050,
    0.060,  0.070, 0.080,  0.090, 0.100,  0.110, 0.120,  0.130,
    0.140,  0.150, 0.160,  0.170, 0.180,  0.190, 0.200,  0.220,
    0.250,  0.280, 0.300,  0.350, 0.400,  0.450, 0.500,  0.550,
    0.600,  0.650, 0.700,  0.750, 0.800,  0.850, 0.900,  1.000,
]
assert len(TARGETS) == COLS * ROWS

patches = []
for i, t in enumerate(TARGETS):
    code = max(64, min(940, round(64 + 876 * t)))
    patches.append({
        "index": i, "row": i // COLS, "col": i % COLS,
        "target": t, "luma10": code,
        "actual": (code - 64) / 876.0,          # what the shader will emit
        # sample window: centre 60% of the patch, in FRAME pixel coords
        "x0": (i % COLS) * PW + int(PW * 0.2), "x1": (i % COLS) * PW + int(PW * 0.8),
        "y0": (i // COLS) * PH + int(PH * 0.2), "y1": (i // COLS) * PH + int(PH * 0.8),
    })

# ---- build one frame of yuv420p10le ----
y_plane = bytearray()
for y in range(H):
    row = bytearray()
    for x in range(W):
        p = patches[(y // PH) * COLS + (x // PW)]
        row += int(p["luma10"]).to_bytes(2, "little")
    y_plane += row
chroma_plane = bytearray()
for _ in range((W // 2) * (H // 2)):
    chroma_plane += (512).to_bytes(2, "little")
frame = bytes(y_plane) + bytes(chroma_plane) * 2

out = sys.argv[1] if len(sys.argv) > 1 else "wedge.mov"
raw = out + ".raw"
with open(raw, "wb") as f:
    for _ in range(FPS * SECONDS):
        f.write(frame)

# ProRes 422 HQ: intra-only, 10-bit, and flat patches survive it exactly (verified downstream by
# the app's own OFFSCREEN export, which reports the code values the layer is actually handed).
cmd = [
    "ffmpeg", "-y", "-f", "rawvideo", "-pix_fmt", "yuv420p10le", "-s", f"{W}x{H}",
    "-r", str(FPS), "-i", raw,
    "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le",
    "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
    "-color_range", "tv", out,
]
subprocess.run(cmd, check=True, capture_output=True)
with open(out + ".patches.json", "w") as f:
    json.dump({"width": W, "height": H, "cols": COLS, "rows": ROWS,
               "patchW": PW, "patchH": PH, "patches": patches}, f, indent=1)
print(f"wrote {out} ({FPS*SECONDS} frames) + {out}.patches.json")
print(f"{len(patches)} patches; {sum(1 for p in patches if p['actual'] < 0.25)} below code 0.25")
print("low end (target -> luma10 -> actual emitted code):")
for p in patches[:12]:
    print(f"   {p['target']:.4f} -> {p['luma10']:4d} -> {p['actual']:.6f}")
