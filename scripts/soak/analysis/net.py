import sys, statistics as st
def theil(x, y):
    s = [(y[j]-y[i])/(x[j]-x[i]) for i in range(len(x)) for j in range(i+1, len(x)) if x[j]-x[i] >= 120]
    return st.median(s) if s else None
for n in sys.argv[1:]:
    W = [tuple(map(float, l.split())) for l in open(n+'.windows.tsv')]
    out = []
    for k, w in enumerate(W):
        if w[0] < 660: continue
        seg = [v for v in W if w[0]-600 <= v[0] <= w[0] and v[0] > 60]
        b = theil([v[0] for v in seg], [v[2]-v[1] for v in seg])
        out.append((w[0], b, w[3]))
    dis = [b-a for _, b, a in out]
    print(f'{n}: {len(out)} windows · implied {min(o[1] for o in out)*1e6:+.1f}…{max(o[1] for o in out)*1e6:+.1f} ppm · '
          f'implied−applied median {st.median(dis)*1e6:+.2f}, sd {st.pstdev(dis)*1e6:.2f}, range {min(dis)*1e6:+.1f}…{max(dis)*1e6:+.1f} ppm')
