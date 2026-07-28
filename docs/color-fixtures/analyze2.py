#!/usr/bin/env python3
"""EXPERIMENT 3 analysis — recover the LAYER's decode curve, WITHOUT using ColorSync.

Usage:
    python3 analyze2.py [sweep-out-dir] [--display-gamma G]

The capture is the composited framebuffer, tagged with the display profile. Turning a
framebuffer code back into light therefore means applying that profile's TRC:

    L = displayEOTF( framebuffer_code / 255 )    and    L = layerDecode( our_code )

Doing this arithmetically rather than via CGColorSpace matters: Experiment 1 established that the
CoreGraphics conversion path introduces a 1/16 linear toe for pure-power TRCs, so decoding the
capture through that same path would manufacture the very artifact under test.

── ⚠️ THE DISPLAY TRC IS READ FROM THE CAPTURE, NOT HARDCODED ────────────────────────────────

This script used to carry `DISPLAY_GAMMA = 1.960999` as a constant — the Studio's LG TV SSCR2
profile, measured once with parse_icc.py. That is a property of ONE MONITOR. Run unchanged on
any other machine it silently inverts with the wrong exponent and produces a plausible,
self-consistent, wrong answer: every candidate fit shifts together, so nothing looks broken.

That matters most on exactly the machine this test exists for. The MacBook Air ships a P3
factory profile, nothing like γ1.961, and the whole point of taking the test there is that the
display profile is different. So the TRC now comes out of `raw_0.icc` — the profile the capture
was actually tagged with — and the script prints what it found before using it.

`--display-gamma` forces a pure power law if you need to override.
"""
import json, math, os, struct, sys

W, H = 1920, 1080


# ── Display TRC, parsed out of the captured profile ──────────────────────────────────────────
# A compact reader for the two tag types Apple emits. parse_icc.py is the full characterisation
# tool and prints far more; this is deliberately the minimum needed to turn a framebuffer code
# into light, so the analysis has no dependency on that script's output being pasted in by hand.
def _sig(b, o):
    return b[o:o + 4].decode("latin-1")


def _s15(b, o):
    return struct.unpack_from(">i", b, o)[0] / 65536.0


def display_eotf(icc_path):
    """Return (eotf, description). eotf maps device value [0,1] -> linear light [0,1]."""
    b = open(icc_path, "rb").read()
    count = struct.unpack_from(">I", b, 128)[0]
    tags = {}
    for i in range(count):
        o = 132 + 12 * i
        tags[_sig(b, o)] = (struct.unpack_from(">I", b, o + 4)[0],
                            struct.unpack_from(">I", b, o + 8)[0])
    if "rTRC" not in tags:
        raise SystemExit(f"{icc_path}: no rTRC tag — cannot characterise the display.\n"
                         f"Run: python3 parse_icc.py {icc_path}")
    off, _size = tags["rTRC"]
    kind = _sig(b, off)

    if kind == "para":
        ft = struct.unpack_from(">H", b, off + 8)[0]
        n = {0: 1, 1: 3, 2: 4, 3: 5, 4: 7}.get(ft, 0)
        p = [_s15(b, off + 12 + 4 * i) for i in range(n)]
        if ft == 0:
            g = p[0]
            return (lambda x: x ** g), f"para type 0 — PURE POWER LAW, gamma {g:.6f}"
        if ft == 3 and len(p) == 5:
            g, a, c, d, e = p[0], p[1], p[2], p[3], p[4]
            # ICC type 3: Y = (aX+b)^g for X >= d, else cX.  (b is p[2] in ICC ordering;
            # Apple's type-3 profiles are the BT.709/sRGB shape.)
            gg, aa, bb, cc, dd = p[0], p[1], p[2], p[3], p[4]
            return (lambda x: (aa * x + bb) ** gg if x >= dd else cc * x), \
                   f"para type 3 — PIECEWISE (BT.709/sRGB shape), g={gg:.4f} d={dd:.4f}"
        raise SystemExit(
            f"{icc_path}: rTRC is 'para' functionType {ft}, which this script does not model.\n"
            f"Characterise it first:  python3 parse_icc.py {icc_path}\n"
            f"then re-run with --display-gamma if a power law is a fair approximation.")

    if kind == "curv":
        n = struct.unpack_from(">I", b, off + 8)[0]
        if n == 0:
            return (lambda x: x), "curv count=0 — IDENTITY (linear)"
        if n == 1:
            g = struct.unpack_from(">H", b, off + 12)[0] / 256.0
            return (lambda x: x ** g), f"curv count=1 — PURE POWER LAW, gamma {g:.6f}"
        v = [struct.unpack_from(">H", b, off + 12 + 2 * i)[0] / 65535.0 for i in range(n)]

        def table(x):
            pos = min(max(x, 0.0), 1.0) * (n - 1)
            i = min(int(pos), n - 2)
            f = pos - i
            return v[i] * (1 - f) + v[i + 1] * f

        return table, f"curv count={n} — SAMPLED TABLE (interpolated)"

    raise SystemExit(f"{icc_path}: rTRC is type '{kind}', unhandled.\n"
                     f"Run: python3 parse_icc.py {icc_path}")


def bt709(x):
    return x / 4.5 if x < 0.081 else ((x + 0.099) / 1.099) ** (1 / 0.45)


CANDIDATES = [
    ("x^1.9609 (macOS SDR default)", lambda x: x ** 1.9609375),
    ("x^2.4    (BT.1886 target)",    lambda x: x ** 2.4),
    ("piecewise BT.709",             bt709),
    ("code/16  (the CG-path toe)",   lambda x: x / 16),
]


def load(stem):
    d = open(stem + ".raw", "rb").read()
    assert len(d) == W * H * 4, (
        f"{stem}.raw is {len(d)} bytes, expected {W*H*4} for {W}x{H} RGBA.\n"
        f"The capture was probably not 1:1 — the Manifold window must be exactly 1920x1080.")
    return d


def patch_codes(d, p):
    """Median 8-bit framebuffer code over the patch's centre window, per channel."""
    rs, gs, bs = [], [], []
    for y in range(p["y0"], p["y1"], 3):
        base = y * W * 4
        for x in range(p["x0"], p["x1"], 3):
            o = base + x * 4
            rs.append(d[o]); gs.append(d[o + 1]); bs.append(d[o + 2])
    rs.sort(); gs.sort(); bs.sort()
    return rs[len(rs) // 2], gs[len(gs) // 2], bs[len(bs) // 2], rs[len(rs) // 20], rs[len(rs) * 19 // 20]


def analyse(stem, label, patches, eotf):
    d = load(stem)
    print("=" * 104)
    print(f"> {label}")
    print("   code        fb8   L=eotf(fb/255)     x^1.9609     x^2.4       bt709      code/16    impliedγ")
    rows = []
    for p in patches:
        r, g, b, lo, hi = patch_codes(d, p)
        L = eotf(r / 255.0)
        c = p["actual"]
        rows.append((c, L, r, lo, hi, (r, g, b)))
        gam = math.log(L) / math.log(c) if L > 0 and 0 < c < 1 else float("nan")
        if p["index"] % 3 == 0 or c < 0.06:
            print(f"  {c:.6f}  {r:5d}   {L:.7f}      {c**1.9609375:.7f}  {c**2.4:.7f}  "
                  f"{bt709(c):.7f}  {c/16:.7f}   {gam:6.3f}")
    print("  fit (max |measured - candidate|), split at the toe crossover:")
    for lo_c, hi_c, tag in [(0.0, 0.14, "codes < 0.14 "), (0.15, 1.01, "codes 0.15-1.0")]:
        sel = [(c, L) for (c, L, *_) in rows if lo_c <= c <= hi_c]
        parts = []
        for name, f in CANDIDATES:
            err = max(abs(L - f(c)) for c, L in sel)
            parts.append(f"{name} = {err:.3e}")
        print(f"    {tag}: " + "   ".join(parts))
    nonneutral = sum(1 for *_x, (r, g, b) in rows if abs(r - g) > 1 or abs(g - b) > 1)
    noisy = sum(1 for _c, _L, _r, lo, hi, _ in rows if hi - lo > 2)
    print(f"  patches with |R-G|>1 or |G-B|>1 (non-neutral): {nonneutral}/{len(rows)}"
          f"   patches with p5..p95 code spread >2 (overlay/noise contamination): {noisy}/{len(rows)}")
    return rows


def main():
    args = [a for a in sys.argv[1:]]
    forced_gamma = None
    if "--display-gamma" in args:
        i = args.index("--display-gamma")
        forced_gamma = float(args[i + 1])
        del args[i:i + 2]
    out_dir = args[0] if args else "."
    os.chdir(out_dir)

    here = os.path.dirname(os.path.abspath(__file__))
    patches_path = next((p for p in ("wedge.mov.patches.json",
                                     os.path.join(here, "wedge.mov.patches.json"))
                         if os.path.isfile(p)), None)
    if not patches_path:
        raise SystemExit("wedge.mov.patches.json not found (looked in the output dir and "
                         "beside this script). Regenerate with make_wedge.py.")
    patches = json.load(open(patches_path))["patches"]

    if forced_gamma is not None:
        eotf = lambda x: x ** forced_gamma
        desc = f"FORCED via --display-gamma {forced_gamma}"
    else:
        icc = "raw_0.icc"
        if not os.path.isfile(icc):
            raise SystemExit(
                "raw_0.icc not found — the display profile is needed to decode the capture.\n"
                "It is written by extract.swift during sweep.sh. Re-run the sweep, or pass\n"
                "--display-gamma G if you have characterised the display another way.")
        eotf, desc = display_eotf(icc)

    print("=" * 104)
    print("> DISPLAY PROFILE THE CAPTURE WAS TAGGED WITH  (read from raw_0.icc, not assumed)")
    print(f"    {desc}")
    print(f"    patches: {patches_path}")
    print("  If that is not a pure power law near 1.96, this is NOT the Studio's display and the")
    print("  Studio's numbers are not directly comparable — which is the point of running here.")

    r0 = analyse("raw_0", "DESTINATION 0 - SOURCE (CoreMedia709) = TODAY'S BEHAVIOUR", patches, eotf)
    r1 = analyse("raw_1", "DESTINATION 1 - kCGColorSpaceITUR_709", patches, eotf)
    r2 = analyse("raw_2", "DESTINATION 2 - synthesised para type-0 g2.4, 709 primaries", patches, eotf)

    print("=" * 104)
    print("> PAIRWISE: did the layer destination change the presented pixels at all?")
    for (a, b, an, bn) in [(r0, r1, "dest0", "dest1"), (r0, r2, "dest0", "dest2"),
                           (r1, r2, "dest1", "dest2")]:
        diff = [abs(x[2] - y[2]) for x, y in zip(a, b)]
        print(f"  {an} vs {bn}: patches differing in fb code = {sum(1 for d in diff if d > 0)}"
              f"/{len(diff)}, max |Δcode8| = {max(diff)}")
    print("")
    print("  If all three are identical, check that the build is Debug/Profile — a Release build")
    print("  compiles Experiment 3 out and the destination never changes. sweep.sh checks this.")


if __name__ == "__main__":
    main()
