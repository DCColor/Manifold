// Pure scans of Manifold's log for soak.mjs: no OBS, no clock, so they can be tested on real log text
// (soaklog.test.mjs: `node --test scripts/soak/soaklog.test.mjs`).

// The live source handing the deck back. Common to every transport (2026-09-28).
export const RELEASE = /\[ARBITER\] (exclusive device released|released )/;

// The end of a live session, as far as `text` shows it, searching from `from` (where the wait began):
//   ended     position just after the transport's own end line (`endedRe`), or null;
//   released  position just after the deck-release line, or null;
//   since     where to look for the control's `[Play] presented` line: after BOTH, so a live-session
//             line cannot start the control early. null until both are seen.
//
// ⚠️ BOTH ARE SEARCHED FROM `from`, NOT ONE AFTER THE OTHER. Manifold writes the release and the
// transport's end line from different threads, and their order varies: on 2026-09-30 WHEP's DELETE
// came 41 ms BEFORE the release at 19:42:16, and 645 ms AFTER it at 20:48:46. The old code searched
// for the release only after the DELETE, so on the second run it waited forever and control 2 was
// never recorded.
export function sessionEnd(text, from, endedRe) {
  const tail = text.slice(from);
  const e = endedRe.exec(tail), r = RELEASE.exec(tail);
  const ended = e ? from + e.index + e[0].length : null;
  const released = r ? from + r.index + r[0].length : null;
  return { ended, released, since: ended !== null && released !== null ? Math.max(ended, released) : null };
}

// The DeckLink file's first beep as Manifold received it: `[AV-CONTENT] beep in pts=… host=<s>`, where
// host is CACurrentMediaTime() — mach_absolute_time, the clock Node's process.hrtime also reads on
// macOS (checked 2026-09-30: the two interleave to the millisecond).
export const BEEP_IN = /\[AV-CONTENT\] beep in [^\n]*?host=([\d.]+)/;

// Wall time (ms since the epoch) of a beep line, from the line's OWN host time, not from when the
// orchestrator noticed it: on 2026-09-30 the anchor taken at noticing was 5 s late (the poll began
// only after the spoken prompt ended). `hostNowS` / `wallNowMs` are read together by the caller.
// An age outside [0, maxAgeS] means the clocks are not the same one: fall back to "now", flagged.
export function beepWallMs(line, hostNowS, wallNowMs, maxAgeS = 60) {
  const m = BEEP_IN.exec(line);
  if (!m) return null;
  const ageS = hostNowS - Number(m[1]);
  if (!(ageS >= 0 && ageS <= maxAgeS)) return { wallMs: wallNowMs, fromHost: false, ageS };
  return { wallMs: wallNowMs - ageS * 1000, fromHost: true, ageS };
}
