import sys, statistics as st
def ols(x, y):
    mx, my = sum(x)/len(x), sum(y)/len(y)
    sxx = sum((a-mx)**2 for a in x); b = sum((a-mx)*(c-my) for a, c in zip(x, y))/sxx
    r = [c-(my+b*(a-mx)) for a, c in zip(x, y)]
    return b, (sum(v*v for v in r)/(len(x)-2))**.5
def theil(x, y, step=1):
    s = [(y[j]-y[i])/(x[j]-x[i]) for i in range(0, len(x), step) for j in range(i+1, len(x), step) if x[j]-x[i] > 60]
    return st.median(s)
for n in sys.argv[1:]:
    P = [tuple(map(float, l.split())) for l in open(n+'.pairs.tsv')]
    x = [p[0] for p in P]; d = [p[1] for p in P]
    b, s = ols(x, d)
    diffs = [d[i+1]-d[i] for i in range(len(d)-1)]
    big = [v for v in diffs if abs(v) > 0.2e-3]
    jit = st.median(abs(v) for v in diffs)
    print(f'{n}: N {len(x)} over {x[-1]:.0f}s · OLS {b*1e6:+.2f} ppm · resid sd {s*1e3:.3f} ms · median |Δd| {jit*1e3:.4f} ms · '
          f'jumps >0.2ms: {len(big)} (+{sum(v>0 for v in big)}/-{sum(v<0 for v in big)}), sum {sum(big)*1e3:+.1f} ms, range {min(big, default=0)*1e3:+.2f}…{max(big, default=0)*1e3:+.2f}')
    try:
        W = [tuple(map(float, l.split())) for l in open(n+'.windows.tsv')]
    except FileNotFoundError: W = []
    W = [w for w in W if w[0] > 60]
    if W:
        t = [w[0] for w in W]; dep = [w[1] for w in W]; off = [w[2] for w in W]; sl = [w[3] for w in W]
        print(f'   depth: Theil-Sen {theil(t, dep)*1e6:+.2f} ppm, OLS {ols(t, dep)[0]*1e6:+.2f}; offset−depth (implied b) Theil-Sen {theil(t, [o-e for o, e in zip(off, dep)])*1e6:+.2f} ppm; applied slope mean {st.mean(sl)*1e6:+.2f}')
