#!/usr/bin/env python3
"""Parse ICC profiles emitted by CGColorSpaceCopyICCData and characterise their TRC tags.

Reports, for each of rTRC/gTRC/bTRC, whether the tag is parametricCurveType ('para') or curveType
('curv'); for 'para' the function type and its parameters; for 'curv' the point count and samples.
Then fits the sampled curve against the candidate transfer functions so "pure power vs piecewise"
is answered by max deviation, not by eyeball.
"""
import struct
import sys


def s15f16(b, o):
    return struct.unpack_from(">i", b, o)[0] / 65536.0


def u16f16(b, o):
    return struct.unpack_from(">I", b, o)[0] / 65536.0


def sig(b, o):
    return b[o:o + 4].decode("latin-1")


# ── candidate transfer functions (device value → linear light) ──────────────────────────────────
def power(g):
    return lambda x: x ** g


def bt709_eotf(x):
    # Inverse of the BT.709 OETF: the piecewise curve with the linear toe below 0.081.
    return x / 4.5 if x < 0.081 else ((x + 0.099) / 1.099) ** (1 / 0.45)


def srgb_eotf(x):
    return x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4


def bt1886_eotf(x):
    # The display EOTF BT.1886 specifies: a pure 2.4 power law.
    return x ** 2.4


CANDIDATES = [
    ("x^1.961 (the forum claim)", power(1.961)),
    ("x^1.96", power(1.96)),
    ("x^2.0", power(2.0)),
    ("x^2.2", power(2.2)),
    ("x^2.4 (BT.1886)", bt1886_eotf),
    ("piecewise BT.709 EOTF", bt709_eotf),
    ("sRGB EOTF", srgb_eotf),
]


def parse_para(b, o, size):
    ftype = struct.unpack_from(">H", b, o + 8)[0]
    nparams = {0: 1, 1: 3, 2: 4, 3: 5, 4: 7}.get(ftype)
    if nparams is None:
        return {"kind": "para", "ftype": ftype, "error": "unknown function type"}
    p = [s15f16(b, o + 12 + 4 * i) for i in range(nparams)]
    names = {0: "g", 1: "g a b", 2: "g a b c", 3: "g a b c d", 4: "g a b c d e f"}[ftype].split()
    return {"kind": "para", "ftype": ftype, "params": dict(zip(names, p)), "raw": p}


def eval_para(info, x):
    t, p = info["ftype"], info["raw"]
    if t == 0:
        return x ** p[0]
    if t == 1:
        g, a, b = p
        return (a * x + b) ** g if x >= -b / a else 0.0
    if t == 2:
        g, a, b, c = p
        return (a * x + b) ** g + c if x >= -b / a else c
    if t == 3:
        g, a, b, c, d = p
        return (a * x + b) ** g if x >= d else c * x
    if t == 4:
        g, a, b, c, d, e, f = p
        return (a * x + b) ** g + e if x >= d else c * x + f
    raise ValueError


def parse_curv(b, o, size):
    n = struct.unpack_from(">I", b, o + 8)[0]
    if n == 0:
        return {"kind": "curv", "count": 0, "note": "identity"}
    if n == 1:
        g = struct.unpack_from(">H", b, o + 12)[0] / 256.0
        return {"kind": "curv", "count": 1, "gamma": g}
    vals = [struct.unpack_from(">H", b, o + 12 + 2 * i)[0] / 65535.0 for i in range(n)]
    return {"kind": "curv", "count": n, "values": vals}


def eval_curv(info, x):
    if info["count"] == 0:
        return x
    if info["count"] == 1:
        return x ** info["gamma"]
    v = info["values"]
    pos = x * (len(v) - 1)
    i = min(int(pos), len(v) - 2)
    frac = pos - i
    return v[i] * (1 - frac) + v[i + 1] * frac


def describe(path):
    b = open(path, "rb").read()
    print("=" * 78)
    print(f"{path}   ({len(b)} bytes)")
    size = struct.unpack_from(">I", b, 0)[0]
    print(f"  header size field : {size}")
    print(f"  version           : {b[8]}.{b[9] >> 4}.{b[9] & 15}")
    print(f"  device class      : {sig(b, 12)}   data space: {sig(b, 16)}   PCS: {sig(b, 20)}")
    print(f"  'acsp' signature  : {sig(b, 36)}")
    print(f"  rendering intent  : {struct.unpack_from('>I', b, 64)[0]}")

    ntags = struct.unpack_from(">I", b, 128)[0]
    tags = {}
    for i in range(ntags):
        o = 132 + 12 * i
        s = sig(b, o)
        off, sz = struct.unpack_from(">II", b, o + 4)
        tags[s] = (off, sz)
    print(f"  {ntags} tags: {', '.join(sorted(tags))}")

    # text tags
    for t in ("desc", "cprt"):
        if t in tags:
            off, sz = tags[t]
            ttype = sig(b, off)
            raw = b[off:off + sz]
            txt = "".join(ch for ch in raw[8:].decode("latin-1", "replace") if ch.isprintable())
            print(f"  {t} ({ttype}) : {txt.strip()[:90]!r}")

    # colorants / primaries / white point
    for t in ("rXYZ", "gXYZ", "bXYZ", "wtpt", "bkpt"):
        if t in tags:
            off, _ = tags[t]
            x, y, z = s15f16(b, off + 8), s15f16(b, off + 12), s15f16(b, off + 16)
            extra = ""
            if x + y + z:
                extra = f"   → xy=({x/(x+y+z):.4f}, {y/(x+y+z):.4f})"
            print(f"  {t} : X={x:.6f} Y={y:.6f} Z={z:.6f}{extra}")
    if "chad" in tags:
        off, _ = tags["chad"]
        m = [s15f16(b, off + 8 + 4 * i) for i in range(9)]
        print("  chad : " + " ".join(f"{v:+.5f}" for v in m))

    # TRC tags — the question
    for t in ("rTRC", "gTRC", "bTRC"):
        if t not in tags:
            print(f"  {t} : ABSENT")
            continue
        off, sz = tags[t]
        ttype = sig(b, off)
        if ttype == "para":
            info = parse_para(b, off, sz)
            fdesc = {
                0: "Y = X^g                                (pure power law)",
                1: "Y = (aX+b)^g for X>=-b/a, else 0",
                2: "Y = (aX+b)^g + c for X>=-b/a, else c",
                3: "Y = (aX+b)^g for X>=d, else cX        (PIECEWISE — the BT.709/sRGB shape)",
                4: "Y = (aX+b)^g + e for X>=d, else cX+f  (PIECEWISE)",
            }.get(info["ftype"], "?")
            print(f"  {t} : parametricCurveType 'para'  functionType={info['ftype']}")
            print(f"         {fdesc}")
            print("         " + "  ".join(f"{k}={v:.6f}" for k, v in info["params"].items()))
            ev = lambda x, i=info: eval_para(i, x)
        elif ttype == "curv":
            info = parse_curv(b, off, sz)
            if info["count"] == 0:
                print(f"  {t} : curveType 'curv'  count=0  → IDENTITY (linear)")
            elif info["count"] == 1:
                print(f"  {t} : curveType 'curv'  count=1  → PURE POWER LAW, gamma={info['gamma']:.6f}")
            else:
                v = info["values"]
                idx = [0, 1, 2, 4, 8, len(v) // 8, len(v) // 4, len(v) // 2, len(v) - 1]
                print(f"  {t} : curveType 'curv'  count={info['count']}  (sampled table)")
                print("         samples i/N → value: " + ", ".join(
                    f"{i}:{v[i]:.6f}" for i in sorted(set(idx))))
            ev = lambda x, i=info: eval_curv(i, x)
        else:
            print(f"  {t} : type '{ttype}' — not a TRC type this script parses")
            continue

        if t == "rTRC":
            xs = [i / 256.0 for i in range(257)]
            print("         fit against candidates (max |curve - candidate| over [0,1]):")
            rows = []
            for label, fn in CANDIDATES:
                err = max(abs(ev(x) - fn(x)) for x in xs)
                rows.append((err, label))
            for err, label in sorted(rows):
                mark = "  ← MATCH" if err < 1e-4 else ("  ← close" if err < 2e-3 else "")
                print(f"           {label:<28} max err = {err:.6e}{mark}")
            print("         curve at low end (where a piecewise toe would show):")
            for x in (0.0, 0.01, 0.02, 0.04, 0.081, 0.1, 0.2, 0.5, 1.0):
                print(f"           f({x:.3f}) = {ev(x):.6f}    x^1.961 = {x**1.961:.6f}"
                      f"    bt709 = {bt709_eotf(x):.6f}")


for p in sys.argv[1:]:
    describe(p)
