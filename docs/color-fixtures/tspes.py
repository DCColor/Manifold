"""Per-stream PES report for an MPEG-TS: PES count, first/last PTS, span (last PTS + one packet − first), the PES
spacing values seen, the largest step between consecutive PTS against the nominal one (a loop seam shows here as a
gap or an overlap), and for AAC the ADTS frames per PES. Read-only. Used by make_stream_fixtures.sh."""
import sys, collections
def pes(path):
    d = open(path, 'rb').read(); st = collections.defaultdict(list); cur = {}
    for i in range(0, len(d) - 187, 188):
        p = d[i:i + 188]
        if p[0] != 0x47: continue
        pid = ((p[1] & 0x1f) << 8) | p[2]; pusi = p[1] & 0x40; afc = (p[3] >> 4) & 3; o = 4
        if afc & 2: o += 1 + p[4]
        if not afc & 1 or o >= 188: continue
        pl = p[o:]
        if pusi:
            if pid in cur: st[pid].append(cur[pid])
            if pl[:3] != b'\x00\x00\x01' or pid < 0x20: cur.pop(pid, None); continue
            hl = pl[8]; pts = None
            if pl[7] & 0x80:
                b = pl[9:14]; pts = (((b[0] >> 1) & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1) / 90000
            cur[pid] = {'sid': pl[3], 'pts': pts, 'data': bytearray(pl[9 + hl:])}
        elif pid in cur: cur[pid]['data'] += pl
    for pid, v in cur.items(): st[pid].append(v)
    return st
def adts_frames(b):
    n = i = 0
    while i + 7 <= len(b) and b[i] == 0xFF and b[i + 1] & 0xF6 == 0xF0:
        n += 1; i += ((b[i + 3] & 3) << 11) | (b[i + 4] << 3) | (b[i + 5] >> 5)
    return n
for f in sys.argv[1:]:
    print("==", f)
    for pid, lst in sorted(pes(f).items()):
        sid = lst[0]['sid']; ptss = [x['pts'] for x in lst if x['pts'] is not None]
        steps = [round((b - a) * 1000, 3) for a, b in zip(ptss, ptss[1:])]
        nominal = collections.Counter(steps).most_common(1)[0][0]
        kind = 'video' if 0xE0 <= sid <= 0xEF else ('aac' if sid in (0xC0, 0xC1) else 'audio')
        extra = ''
        if kind == 'aac':
            fr = collections.Counter(adts_frames(x['data']) for x in lst)
            extra = f" · ADTS frames per PES {dict(fr)}"
        span = ptss[-1] + nominal / 1000 - ptss[0]
        print(f"  {kind:5} {len(lst)} PES · PTS {ptss[0]:.5f} → {ptss[-1]:.5f} · span {span:.5f} s · step {nominal} ms"
              f" (min {min(steps)}, max {max(steps)}){extra}")
