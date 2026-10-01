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
