#!/usr/bin/env python3
"""Verify Manifold sync clips (AUDIO_RESAMPLER_DESIGN.md §19.3, §19.9). Read-only on the clips.

    python3 scripts/syncclips/verify.py [clip ...]        # default: every .mov in build/syncclips/
    FFPROBE=/path/to/ffprobe  (default: ffprobe on PATH)   # the read-back
    --json out.json                                        # per-clip results, and every event's times
    --loop N                                               # also the loop test: N passes, per seam

Two kinds of clip, told apart by name: `manifold-sync-<label>p.mov`, the ProRes master (60 × round(rate)
frames), and `manifold-sync-<label>p-h264.mov`, the bundled clip (`cycles` whole code cycles,
recipes.tsv). A legacy `.mp4` named explicitly is read as a 60 s clip (for comparison only).

Per clip:
  * READ-BACK (ffprobe): codecs, profile, pixel format, size, frame rate, frame count, duration, the
    four colour tags, audio rate and channels.
  * FLASHES: per-frame luma with each frame's exact pts (integer × time base). The set of white
    frames must be exactly the coded event frames, and each must present at exactly k / rate.
  * BEEPS, EXACTLY: the onset t0 of each tone, from the 1 kHz PHASE over the tone's flat middle
    (a least-squares sin/cos fit), resolved to < 1 µs; the coarse onset from the envelope only picks
    which 1 ms period. A/V per event = t0 − the flash frame's pts. Both channels.
  * THE CODED GATES (c12's, restated for an uneven pattern): one event per coded frame and no other;
    consecutive intervals follow the code; one burst per beep; the level between beeps (from 10 ms
    after a tone to 10 ms before the next) is the −60 dBFS floor.
  * c12.py, UNMODIFIED, with `--file` (a disk file has no sender grid). Its 1 Hz grid gate does not
    apply to a coded pattern; it is run and printed as is, and §19.9 says which gates fit.
  * EXACT LENGTH (§19.11): the DECODED audio — what a player gets, edit list honoured — is exactly
    frames × 48000 / rate samples, and the video's decoded frames are the recipe's. Then a loop adds
    nothing: audio and video restart together.
  * LOOP (--loop N): the clip decoded ONCE and appended N times, the way a looping player plays it
    (audio sample after sample; video frame after frame, each pass the decoded frames × 1 / rate
    later). Every event in every pass is measured with the same phase fit. Per seam (pass), the
    A/V median and worst; the drift is the last pass − the first. A clip whose decoded audio runs
    long or short drifts by exactly that difference per pass.
"""
import json, os, re, subprocess, sys, math
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
FFPROBE = os.environ.get('FFPROBE', 'ffprobe')
CODE = (0, 23, 52, 83)          # event offsets inside one cycle, in steps
CYCLE = 120                     # steps per cycle (23 + 29 + 31 + 37)
TONE_HZ, TONE_PEAK, RAMP = 1000.0, 0.1, 0.005
FS = 48000


def recipes():
    out = {}
    for line in open(os.path.join(HERE, 'recipes.tsv')):
        if not line.strip() or line.startswith('#'):
            continue
        label, rate, unit, cycles = line.rstrip('\n').split('\t')
        num, den = (int(v) for v in rate.split('/'))
        out[label] = dict(num=num, den=den, unit=int(unit), cycles=int(cycles))
    return out


def probe(path):
    r = subprocess.run([FFPROBE, '-v', 'error', '-count_frames', '-show_streams', '-show_format',
                        '-of', 'json', path], capture_output=True, text=True, check=True)
    j = json.loads(r.stdout)
    v = next(s for s in j['streams'] if s['codec_type'] == 'video')
    a = next(s for s in j['streams'] if s['codec_type'] == 'audio')
    return dict(vcodec=v['codec_name'], profile=v.get('profile'), pix_fmt=v['pix_fmt'],
                size=f"{v['width']}x{v['height']}", r_frame_rate=v['r_frame_rate'],
                avg_frame_rate=v['avg_frame_rate'], frames=int(v['nb_read_frames']),
                v_duration=float(v['duration']), time_base=v['time_base'],
                primaries=v.get('color_primaries'), transfer=v.get('color_transfer'),
                matrix=v.get('color_space'), range=v.get('color_range'),
                acodec=a['codec_name'], a_rate=int(a['sample_rate']), channels=a['channels'],
                a_duration=float(a['duration']), format_duration=float(j['format']['duration']))


def frames_luma(path):
    """(frame index, pts, YAVG) per decoded frame."""
    r = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', path, '-an', '-vf',
                        'scale=64:36,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-',
                        '-f', 'null', '-'], capture_output=True, text=True, check=True)
    rows = re.findall(r'frame:(\d+)\s+pts:(-?\d+)\s+pts_time:\S+\s+lavfi\.signalstats\.YAVG=([\d.]+)', r.stdout)
    return [(int(f), int(p), float(y)) for f, p, y in rows]


def audio(path):
    r = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', path, '-vn', '-ar', str(FS),
                        '-f', 'f32le', '-c:a', 'pcm_f32le', '-'], capture_output=True, check=True)
    x = np.frombuffer(r.stdout, '<f4').astype(np.float64)
    return x.reshape(-1, 2)


def tone_onset(x, t_nominal, period):
    """The tone's start t0 near t_nominal, from its 1 kHz phase over the flat middle."""
    w = 2 * math.pi * TONE_HZ
    # Coarse: the first sample above a quarter of the tone's peak, less where a 5 ms raised-cosine
    # tone first reaches it (≈ 1.7 ms) — only to choose the 1 ms period; ±0.5 ms is enough.
    a0 = int((t_nominal - 0.02) * FS)
    seg = np.abs(x[a0:a0 + int(0.04 * FS)])
    hit = np.argmax(seg > 0.25 * TONE_PEAK)
    coarse = (a0 + hit) / FS - 0.0017
    # Fine: fit a·sin(wt) + b·cos(wt) over the flat part, which is A·sin(w(t − t0)).
    i0 = int(math.ceil((coarse + RAMP + 0.0006) * FS))
    i1 = int(math.floor((coarse + period - RAMP - 0.0006) * FS))
    t = np.arange(i0, i1) / FS
    M = np.stack([np.sin(w * t), np.cos(w * t)], axis=1)
    (a, b), *_ = np.linalg.lstsq(M, x[i0:i1], rcond=None)
    amp = math.hypot(a, b)
    phase_t0 = (math.atan2(-b, a) / w) % (1 / TONE_HZ)          # t0 modulo one tone period
    k = round((coarse - phase_t0) * TONE_HZ)
    return phase_t0 + k / TONE_HZ, amp, (a0 + hit) / FS


def clip_kind(path):
    """(label, bundled?) from the file name."""
    m = re.search(r'manifold-sync-([\d.]+)p(-h264)?\.(mov|mp4)$', path)
    return m.group(1), m.group(2) is not None


def frame_count(r, bundled):
    nominal = (r['num'] + r['den'] // 2) // r['den']
    return r['cycles'] * CYCLE * r['unit'] if bundled else 60 * nominal


def loop_check(x, white, n_frames, num, den, passes):
    """The clip appended `passes` times (decode → append). Per pass: (median, worst) A/V in ms over
    every event, left channel; the flash of pass p is at its pts + p × the video's decoded length."""
    period = den / num
    xt = np.tile(x[:, 0], passes)
    vlen = n_frames * period
    out = []
    for p_ in range(passes):
        av = []
        for f, tf in white:
            t_flash = tf + p_ * vlen
            t0, _, _ = tone_onset(xt, t_flash, period)
            av.append((t0 - t_flash) * 1e3)
        out.append((float(np.median(av)), float(max(av, key=abs))))
    return out


def verify(path, rec, passes=0):
    label, bundled = clip_kind(path)
    r = rec[label]
    num, den, unit = r['num'], r['den'], r['unit']
    pr = probe(path)
    tb_num, tb_den = (int(v) for v in pr['time_base'].split('/'))
    nominal = (num + den // 2) // den
    n_frames = frame_count(r, bundled)
    F0 = nominal
    events = [F0 + unit * (CYCLE * c + o) for c in range(n_frames) for o in CODE
              if F0 + unit * (CYCLE * c + o) < n_frames]
    events = sorted(set(events))
    period = den / num
    # Flashes.
    fl = frames_luma(path)
    ys = np.array([y for _, _, y in fl])
    thr = 0.5 * (ys.min() + ys.max())
    white = [(f, p) for f, p, y in fl if y > thr]
    white_frames = [f for f, _ in white]
    flash_exact = []                 # pts − k/rate, seconds, exact rational arithmetic in float
    for f, p in white:
        flash_exact.append(p * tb_num / tb_den - f * den / num)
    # Beeps.
    x = audio(path)
    rows = []
    for f, p in white:
        tf = p * tb_num / tb_den
        t0L, ampL, crossL = tone_onset(x[:, 0], f * den / num, period)
        t0R, ampR, _ = tone_onset(x[:, 1], f * den / num, period)
        rows.append(dict(frame=f, flash=tf, beepL=t0L, beepR=t0R, av_ms=(t0L - tf) * 1e3,
                         avR_ms=(t0R - tf) * 1e3, boundary_err_us=(t0L - f * den / num) * 1e6,
                         amp=ampL, detector_ms=(crossL - tf) * 1e3))
    av = np.array([q['av_ms'] for q in rows] + [q['avR_ms'] for q in rows])
    # Exact length: the decoded audio against the recipe's frames, in samples (an integer: §19.11).
    samples_expected = n_frames * FS * den // num if (n_frames * FS * den) % num == 0 else None
    # Coded gates.
    intervals = np.diff(white_frames)
    code_steps = [23, 29, 31, 37]
    expect_iv = [unit * code_steps[i % 4] for i in range(len(intervals))]
    # Level between beeps, and one burst per beep: 10 ms after a tone → 10 ms before the next.
    gaps, extra = [], 0
    for a_, b_ in zip(rows, rows[1:]):
        s0, s1 = int((a_['flash'] + period + 0.010) * FS), int((b_['flash'] - 0.010) * FS)
        g = x[s0:s1, 0]
        gaps.append(g)
        if np.max(np.abs(g)) > 0.25 * TONE_PEAK:
            extra += 1
    g = np.concatenate(gaps)
    res = dict(
        clip=os.path.basename(path), label=label, probe=pr, expected_events=len(events),
        flashes=len(white_frames), flash_frames_exact=white_frames == events,
        flash_pts_err_us_max=max(abs(v) for v in flash_exact) * 1e6 if flash_exact else None,
        intervals_follow_code=list(intervals) == expect_iv,
        beeps=len(rows), av_ms_worst=float(np.max(np.abs(av))), av_ms_mean=float(np.mean(av)),
        boundary_err_us_max=float(max(abs(q['boundary_err_us']) for q in rows)),
        tone_amp_min=float(min(q['amp'] for q in rows)), tone_amp_max=float(max(q['amp'] for q in rows)),
        bursts_outside_tones=extra,
        floor_rms_dbfs=float(20 * np.log10(np.sqrt(np.mean(g ** 2)) + 1e-12)),
        floor_peak_dbfs=float(20 * np.log10(np.max(np.abs(g)) + 1e-12)),
        avsync_detector_ms_median=float(np.median([q['detector_ms'] for q in rows])),
        events=rows, cycle_s=unit * CYCLE * den / num, shortest_s=unit * 23 * den / num,
        bundled=bundled, frames_expected=n_frames, samples_decoded=int(len(x)),
        samples_expected=samples_expected,
        length_exact=(pr['frames'] == n_frames and samples_expected is not None and len(x) == samples_expected))
    if passes:
        lp = loop_check(x, [(q['frame'], q['flash']) for q in rows], pr['frames'], num, den, passes)
        res['loop'] = dict(passes=passes, per_pass=lp, drift_ms=lp[-1][0] - lp[0][0],
                           worst_ms=max((abs(w) for _, w in lp)))
    # c12.py, unmodified.
    c = subprocess.run([sys.executable, os.path.join(REPO, 'scripts/soak/analysis/c12.py'), path, '--file'],
                       capture_output=True, text=True)
    res['c12'] = {k: v.strip() for k, v in (l.split(None, 1) for l in c.stdout.splitlines() if l.strip())} \
        if c.returncode == 0 else {'error': c.stderr.strip()[-300:]}
    return res


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    jpath = sys.argv[sys.argv.index('--json') + 1] if '--json' in sys.argv else None
    if jpath in args:
        args.remove(jpath)
    passes = int(sys.argv[sys.argv.index('--loop') + 1]) if '--loop' in sys.argv else 0
    if passes and str(passes) in args:
        args.remove(str(passes))
    clips = args or sorted(os.path.join(REPO, 'build/syncclips', f)
                           for f in os.listdir(os.path.join(REPO, 'build/syncclips'))
                           if re.match(r'manifold-sync-.*\.mov$', f))
    rec = recipes()
    out, ok_all = [], True
    for p in clips:
        r = verify(p, rec, passes)
        out.append(r)
        pr = r['probe']
        ok = (r['flash_frames_exact'] and r['intervals_follow_code'] and r['beeps'] == r['expected_events']
              and r['av_ms_worst'] < 0.001 and r['bursts_outside_tones'] == 0 and r['flash_pts_err_us_max'] < 1
              and r['length_exact'] and (not passes or r['loop']['worst_ms'] < 0.001))
        ok_all &= ok
        print(f"{'PASS' if ok else 'FAIL'} {r['clip']}: {pr['vcodec']} {pr['profile']} {pr['pix_fmt']} {pr['size']} "
              f"{pr['r_frame_rate']} ({pr['frames']} fr, {pr['format_duration']:.3f} s) · "
              f"{pr['primaries']}/{pr['transfer']}/{pr['matrix']}/{pr['range']} · {pr['acodec']} {pr['a_rate']} Hz "
              f"{pr['channels']} ch")
        print(f"     events {r['beeps']}/{r['expected_events']} (flash frames exact: {r['flash_frames_exact']}, "
              f"intervals follow the code: {r['intervals_follow_code']}) · A/V worst {r['av_ms_worst']*1000:.3f} µs, "
              f"mean {r['av_ms_mean']*1000:+.3f} µs · beep vs exact boundary worst {r['boundary_err_us_max']:.3f} µs · "
              f"flash pts vs k/rate worst {r['flash_pts_err_us_max']:.3f} µs · tone peak {r['tone_amp_min']:.4f}–"
              f"{r['tone_amp_max']:.4f} · floor {r['floor_rms_dbfs']:.1f} dBFS rms / {r['floor_peak_dbfs']:.1f} peak · "
              f"bursts outside tones {r['bursts_outside_tones']} · avsync onset {r['avsync_detector_ms_median']:+.3f} ms")
        print(f"     length: {r['probe']['frames']}/{r['frames_expected']} frames, {r['samples_decoded']}/"
              f"{r['samples_expected']} samples decoded · exact: {r['length_exact']}"
              f" ({'bundled' if r['bundled'] else 'master / legacy'})")
        if passes:
            lp = r['loop']
            print(f"     loop ×{passes}: drift (last − first pass) {lp['drift_ms']*1000:+.3f} µs · worst event "
                  f"{lp['worst_ms']*1000:.3f} µs · per pass median (µs): "
                  + ' '.join(f"{m*1000:+.2f}" for m, _ in lp['per_pass']))
        c = r['c12']
        print("     c12: " + ' · '.join(f"{k} {c[k]}" for k in ('beeps', 'flashes', 'pairs', 'g_count', 'g_grid',
                                                                  'doubled', 'gap_rms_db', 'median', 'sd') if k in c)
              + (f" · ERROR {c['error']}" if 'error' in c else ''))
    if jpath:
        json.dump(out, open(jpath, 'w'), indent=1, default=float)
    sys.exit(0 if ok_all else 1)


if __name__ == '__main__':
    main()
