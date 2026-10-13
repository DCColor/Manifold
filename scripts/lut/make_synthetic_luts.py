#!/usr/bin/env python3
"""Synthetic .cube LUTs with known outputs (colour S6, docs/COLOR_MANAGEMENT_FINDINGS.md §6.11, *S6 — LUT*).

Writes each LUT and one `expected.json` holding, per LUT, probe inputs and the output for both interpolations
(trilinear, tetrahedral), plus the analytic value where the LUT is affine (both interpolations are then exact).

The interpolation here is written independently of the Swift reference (LUTCube/CubeLUTEvaluator.swift) and must
agree with it (L0-P6). Every table value is the float32 that the written text parses to, which is what the Swift
parser stores, so the two compare like for like.

Two sets:
  default   small LUTs (≤ 17³), committed as test fixtures:
            Packages/ManifoldCore/Tests/LUTCubeTests/Fixtures/synthetic
  --l1      the L1 set (identity 33³ and 65³, the levels guard, the discriminator, …) for the renderer runs.
            Large, never committed: write it under build/.

Usage:
  python3 -I scripts/lut/make_synthetic_luts.py [--out DIR] [--l1]

Standard library only.
"""

import argparse
import json
import math
import os
import random
import struct


def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def fmt(x):
    return "%.10g" % x


def written(x):
    """The value the parser will hold: the float32 of the text this script writes."""
    return f32(float(fmt(x)))


# ---------------------------------------------------------------------------------------------------------------
# Tables

class LUT:
    def __init__(self, name, title, shaper=None, cube=None, affine=None, comment=None, style="adobe"):
        self.name, self.title, self.style = name, title, style
        self.shaper = shaper    # dict(size, dmin, dmax, rows)
        self.cube = cube        # dict(size, dmin, dmax, rows)  red fastest
        self.affine = affine    # f(rgb) -> rgb for every input in the domain, or None
        self.comment = comment


def table1d(size, fn, dmin=(0.0, 0.0, 0.0), dmax=(1.0, 1.0, 1.0)):
    dmin = tuple(written(v) for v in dmin)
    dmax = tuple(written(v) for v in dmax)
    rows = []
    for i in range(size):
        x = [dmin[c] + (dmax[c] - dmin[c]) * i / (size - 1) for c in range(3)]
        rows.append(tuple(written(v) for v in fn(x)))
    return dict(size=size, dmin=dmin, dmax=dmax, rows=rows)


def table3d(size, fn, dmin=(0.0, 0.0, 0.0), dmax=(1.0, 1.0, 1.0)):
    dmin = tuple(written(v) for v in dmin)
    dmax = tuple(written(v) for v in dmax)
    rows = []
    for b in range(size):
        for g in range(size):
            for r in range(size):
                idx = (r, g, b)
                x = [dmin[c] + (dmax[c] - dmin[c]) * idx[c] / (size - 1) for c in range(3)]
                rows.append(tuple(written(v) for v in fn(x)))
    return dict(size=size, dmin=dmin, dmax=dmax, rows=rows)


# ---------------------------------------------------------------------------------------------------------------
# Evaluation: independent of the Swift reference; the same contract (see the header of CubeLUTEvaluator.swift).

def pos(x, lo, hi, n):
    t = (x - lo) / (hi - lo)
    t = 0.0 if t != t else min(max(t, 0.0), 1.0)
    p = t * (n - 1)
    i = min(int(math.floor(p)), n - 2)
    return i, p - i


def eval1d(tab, rgb):
    out = []
    for c in range(3):
        i, f = pos(rgb[c], tab["dmin"][c], tab["dmax"][c], tab["size"])
        a, b = tab["rows"][i][c], tab["rows"][i + 1][c]
        out.append(a + (b - a) * f)
    return out


def eval3d(tab, rgb, mode):
    n = tab["size"]
    (r0, fr), (g0, fg), (b0, fb) = (pos(rgb[c], tab["dmin"][c], tab["dmax"][c], n) for c in range(3))

    def node(dr, dg, db):
        return tab["rows"][(r0 + dr) + n * ((g0 + dg) + n * (b0 + db))]

    def comb(*terms):
        return [sum(w * v[c] for w, v in terms) for c in range(3)]

    if mode == "trilinear":
        out = [0.0, 0.0, 0.0]
        for dr in (0, 1):
            for dg in (0, 1):
                for db in (0, 1):
                    w = (fr if dr else 1 - fr) * (fg if dg else 1 - fg) * (fb if db else 1 - fb)
                    v = node(dr, dg, db)
                    for c in range(3):
                        out[c] += w * v[c]
        return out
    c000, c111 = node(0, 0, 0), node(1, 1, 1)
    if fr > fg:
        if fg > fb:
            return comb((1 - fr, c000), (fr - fg, node(1, 0, 0)), (fg - fb, node(1, 1, 0)), (fb, c111))
        if fr > fb:
            return comb((1 - fr, c000), (fr - fb, node(1, 0, 0)), (fb - fg, node(1, 0, 1)), (fg, c111))
        return comb((1 - fb, c000), (fb - fr, node(0, 0, 1)), (fr - fg, node(1, 0, 1)), (fg, c111))
    if fb > fg:
        return comb((1 - fb, c000), (fb - fg, node(0, 0, 1)), (fg - fr, node(0, 1, 1)), (fr, c111))
    if fb > fr:
        return comb((1 - fg, c000), (fg - fb, node(0, 1, 0)), (fb - fr, node(0, 1, 1)), (fr, c111))
    return comb((1 - fg, c000), (fg - fr, node(0, 1, 0)), (fr - fb, node(1, 1, 0)), (fb, c111))


def evaluate(lut, rgb, mode):
    v = list(rgb)
    if lut.shaper:
        v = eval1d(lut.shaper, v)
    if lut.cube:
        v = eval3d(lut.cube, v, mode)
    return v


# ---------------------------------------------------------------------------------------------------------------
# Writing

def write_cube(lut, path):
    lines = []
    if lut.comment:
        lines += ["# " + c for c in lut.comment]
    lines.append('TITLE "%s"' % lut.title)
    s, c = lut.shaper, lut.cube
    if lut.style == "resolve":
        if s:
            lines.append("LUT_1D_SIZE %d" % s["size"])
            lines.append("LUT_1D_INPUT_RANGE %s %s" % (fmt(s["dmin"][0]), fmt(s["dmax"][0])))
        if c:
            lines.append("LUT_3D_SIZE %d" % c["size"])
            lines.append("LUT_3D_INPUT_RANGE %s %s" % (fmt(c["dmin"][0]), fmt(c["dmax"][0])))
    else:
        t = s or c
        lines.append(("LUT_1D_SIZE %d" if s else "LUT_3D_SIZE %d") % t["size"])
        if t["dmin"] != (0.0, 0.0, 0.0):
            lines.append("DOMAIN_MIN " + " ".join(fmt(v) for v in t["dmin"]))
        if t["dmax"] != (1.0, 1.0, 1.0):
            lines.append("DOMAIN_MAX " + " ".join(fmt(v) for v in t["dmax"]))
    lines.append("")
    for t in (s, c):
        if t:
            lines += [" ".join(fmt(v) for v in row) for row in t["rows"]]
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")


def probes(lut, rng, count):
    """Lattice points, random interior points, edges and out-of-domain points, in the LUT's own input domain."""
    first = lut.shaper or lut.cube
    lo, hi = first["dmin"], first["dmax"]
    pts = []
    # Lattice points of the first table (exact node inputs).
    n = first["size"]
    for _ in range(min(count // 4, n ** 3)):
        idx = [rng.randrange(n) for _ in range(3)]
        pts.append([lo[c] + (hi[c] - lo[c]) * idx[c] / (n - 1) for c in range(3)])
    for _ in range(count):
        pts.append([lo[c] + (hi[c] - lo[c]) * rng.random() for c in range(3)])
    span = [hi[c] - lo[c] for c in range(3)]
    pts += [list(lo), list(hi), [lo[0] - 0.1 * span[0], hi[1] + 0.1 * span[1], lo[2] + 0.5 * span[2]],
            [hi[0] + 0.25 * span[0], lo[1] - 0.25 * span[1], hi[2] + 1.0 * span[2]],
            [0.5 * (lo[c] + hi[c]) for c in range(3)]]
    return pts


def clamp_domain(lut, rgb):
    t = lut.shaper or lut.cube
    return [min(max(rgb[c], t["dmin"][c]), t["dmax"][c]) for c in range(3)]


# ---------------------------------------------------------------------------------------------------------------
# The sets

def affine(m, o):
    return lambda x: [sum(m[r][c] * x[c] for c in range(3)) + o[r] for r in range(3)]


def small_set():
    ident = lambda x: list(x)
    mat = ((0.8, 0.15, 0.05), (-0.1, 1.2, -0.1), (0.05, -0.2, 1.3))
    off = (0.02, -0.03, 0.01)
    sq = lambda x: [v * v for v in x]
    prod = lambda x: [x[0] * x[1] * x[2]] * 3
    cross = lambda x: [x[0] * x[1], x[1] * x[2], x[2] * x[0]]
    nonlin = lambda x: [math.sqrt(max(v, 0.0)) * (0.9 + 0.1 * x[(c + 1) % 3]) for c, v in enumerate(x)]
    log_shaper = lambda x: [(math.log2(max(v, 0.0) + 0.1) + 3.321928) / 3.459432 for v in x]  # [-0.1,1.2] → ~[0,1]
    step = lambda x: [0.0 if v < 0.03 else 1.0 for v in x]
    return [
        LUT("identity_3d_17", "Identity 17", cube=table3d(17, ident), affine=ident),
        LUT("gain_half_3d_9", "Gain 0.5", cube=table3d(9, lambda x: [0.5 * v for v in x]),
            affine=lambda x: [0.5 * v for v in x]),
        LUT("swap_rb_3d_9", "Swap R and B", cube=table3d(9, lambda x: [x[2], x[1], x[0]]),
            affine=lambda x: [x[2], x[1], x[0]]),
        LUT("invert_3d_9", "Invert", cube=table3d(9, lambda x: [1 - v for v in x]), affine=lambda x: [1 - v for v in x]),
        LUT("matrix_offset_3d_9", "Matrix and offset", cube=table3d(9, affine(mat, off)), affine=affine(mat, off)),
        LUT("square_3d_9", "Square per channel", cube=table3d(9, sq)),
        LUT("square_1d_64", "Square, 1D", shaper=table1d(64, sq)),
        LUT("product_3d_2", "r·g·b discriminator", cube=table3d(2, prod)),
        LUT("cross_3d_9", "Cross products", cube=table3d(9, cross)),
        LUT("nonlinear_3d_9", "Non-linear cross-channel", cube=table3d(9, nonlin)),
        LUT("domain_identity_3d_5", "Identity on -0.25..1.25",
            cube=table3d(5, ident, (-0.25, -0.25, -0.25), (1.25, 1.25, 1.25)), affine=ident),
        LUT("domain_perchannel_3d_5", "Identity on per-channel domains",
            cube=table3d(5, ident, (0.0, -0.5, 0.1), (1.0, 2.0, 0.9)), affine=ident),
        LUT("shaper_log_3d_9", "Log shaper then square", style="resolve",
            shaper=table1d(256, log_shaper, (-0.1, -0.1, -0.1), (1.2, 1.2, 1.2)), cube=table3d(9, sq)),
        LUT("shaper_identity", "Identity shaper and identity 3D", style="resolve",
            shaper=table1d(32, ident), cube=table3d(2, ident), affine=ident),
        LUT("levels_guard_1d_1024", "Levels guard: step at 0.03", shaper=table1d(1024, step)),
    ]


def l1_set():
    ident = lambda x: list(x)
    step = lambda x: [0.0 if v < 0.03 else 1.0 for v in x]
    prod = lambda x: [x[0] * x[1] * x[2]] * 3
    mat = ((0.8, 0.15, 0.05), (-0.1, 1.2, -0.1), (0.05, -0.2, 1.3))
    return [
        LUT("identity_3d_33", "Identity 33", cube=table3d(33, ident), affine=ident),
        LUT("identity_3d_65", "Identity 65", cube=table3d(65, ident), affine=ident),
        LUT("identity_1d_1024", "Identity 1D 1024", shaper=table1d(1024, ident), affine=ident),
        LUT("identity_shaper_3d_33", "Identity shaper + 33", style="resolve",
            shaper=table1d(4096, ident), cube=table3d(33, ident), affine=ident),
        LUT("swap_rb_3d_33", "Swap R and B", cube=table3d(33, lambda x: [x[2], x[1], x[0]]),
            affine=lambda x: [x[2], x[1], x[0]]),
        LUT("invert_3d_33", "Invert", cube=table3d(33, lambda x: [1 - v for v in x]),
            affine=lambda x: [1 - v for v in x]),
        LUT("gain_half_3d_33", "Gain 0.5", cube=table3d(33, lambda x: [0.5 * v for v in x]),
            affine=lambda x: [0.5 * v for v in x]),
        LUT("gamma2_1d_1024", "Gamma 2, 1D", shaper=table1d(1024, lambda x: [v * v for v in x])),
        LUT("matrix_3d_33", "Matrix", cube=table3d(33, affine(mat, (0, 0, 0))), affine=affine(mat, (0, 0, 0))),
        LUT("levels_guard_1d_1024", "Levels guard: step at 0.03", shaper=table1d(1024, step)),
        LUT("product_3d_2", "r·g·b discriminator", cube=table3d(2, prod)),
    ]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(os.path.dirname(here))
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(repo, "Packages/ManifoldCore/Tests/LUTCubeTests/Fixtures/synthetic"))
    ap.add_argument("--l1", action="store_true", help="the L1 renderer set (large; write it under build/)")
    ap.add_argument("--probes", type=int, default=64)
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    rng = random.Random(20261013)
    luts = l1_set() if args.l1 else small_set()
    expected = []
    for lut in luts:
        path = os.path.join(args.out, lut.name + ".cube")
        write_cube(lut, path)
        entries = []
        for p in probes(lut, rng, args.probes):
            e = {"in": p,
                 "trilinear": evaluate(lut, p, "trilinear"),
                 "tetrahedral": evaluate(lut, p, "tetrahedral")}
            if lut.affine:
                e["analytic"] = lut.affine(clamp_domain(lut, p))
            entries.append(e)
        expected.append({"name": lut.name, "file": lut.name + ".cube", "affine": lut.affine is not None,
                         "probes": entries})
        print("wrote %s (%d probes)" % (path, len(entries)))
    with open(os.path.join(args.out, "expected.json"), "w", encoding="utf-8") as fh:
        # One probe per line: compact, and still a readable diff when the generator changes.
        fh.write('{"generator": "scripts/lut/make_synthetic_luts.py", "luts": [\n')
        for k, lut in enumerate(expected):
            head = {key: lut[key] for key in ("name", "file", "affine")}
            fh.write(json.dumps(head)[:-1] + ', "probes": [\n')
            fh.write(",\n".join(json.dumps(e, separators=(",", ":")) for e in lut["probes"]))
            fh.write("\n]}" + ("," if k + 1 < len(expected) else "") + "\n")
        fh.write("]}")
        fh.write("\n")


if __name__ == "__main__":
    main()
