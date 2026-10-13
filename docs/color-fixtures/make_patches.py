# S0 fixture source: 1920x1080 16-bit PPM, 6x3 patch grid, R'G'B' code values (no transfer applied —
# these are signal values, interpreted by whatever the file is tagged as).
# Row 0: greys 0, 10, 25, 50, 75, 100 %.  Row 1: 100 % R G B C M Y.  Row 2: 50 % R G B C M Y.
import sys, json
W, H, C, R = 1920, 1080, 6, 3
greys = [0.0, 0.10, 0.25, 0.50, 0.75, 1.0]
prim = [(1,0,0),(0,1,0),(0,0,1),(0,1,1),(1,0,1),(1,1,0)]
names = ["R","G","B","C","M","Y"]
rows = [[(g,g,g) for g in greys], [p for p in prim], [tuple(0.5*c for c in p) for p in prim]]
labels = [[f"grey {int(g*100)}%" for g in greys], [f"{n} 100%" for n in names], [f"{n} 50%" for n in names]]
out = sys.argv[1]
with open(out, "wb") as f:
    f.write(f"P6 {W} {H} 65535\n".encode())
    pw, ph = W // C, H // R
    for y in range(H):
        r = min(y // ph, R-1)
        line = bytearray()
        for x in range(W):
            c = min(x // pw, C-1)
            for v in rows[r][c]:
                q = round(v * 65535); line += bytes((q >> 8, q & 0xff))
        f.write(line)
json.dump({"grid": [C, R], "patch_px": [W//C, H//R], "patches": [[{"label": labels[r][c], "rgb": rows[r][c]} for c in range(C)] for r in range(R)]},
          open(out.replace(".ppm", ".json"), "w"), indent=1)
