// node --test scripts/soak/soaklog.test.mjs   — soaklog.mjs on the real log lines of 2026-09-30's two WHEP runs.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sessionEnd, RELEASE, beepWallMs } from './soaklog.mjs';

const WHEP_END = /\[WHEP\] DELETE resource/;   // soak.mjs TR.whep.endedLog
const LIVE_PLAY = '[Play] presented 24.0 fps\n';  // a live-session line, before the end
const DELETE = '2026-09-30 19:42:16.949 Manifold[9614:2148251] [WHEP] DELETE resource → HTTP 200\n';
const RELEASED = '2026-09-30 19:42:16.990 Manifold[9614:2098379] [ARBITER] exclusive device released — every deck paused; nothing auto-resumes\n'
  + '2026-09-30 19:42:16.990 Manifold[9614:2098379] [ARBITER] released WHEP stream — decks=1 active=criterion12-flash-beep-25p-60s.mov owner=none\n';
const PREFIX = 'earlier lines of the session\n';

test('DELETE before the release (observe-abs-whep-mediamtx, 19:42:16)', () => {
  const text = PREFIX + LIVE_PLAY + DELETE + RELEASED;
  const r = sessionEnd(text, PREFIX.length, WHEP_END);
  assert.ok(r.ended !== null && r.released !== null);
  assert.ok(r.released > r.ended);
  assert.equal(r.since, r.released);
});

test('release before the DELETE (observe-decklink-whep-cloudflare, 20:48:46): the case that lost control 2', () => {
  const text = PREFIX + LIVE_PLAY + RELEASED + DELETE;
  const r = sessionEnd(text, PREFIX.length, WHEP_END);
  assert.ok(r.ended !== null && r.released !== null, 'both found, whatever their order');
  assert.ok(r.released < r.ended);
  assert.equal(r.since, r.ended);
  // The old code searched for the release only AFTER the end line, and found nothing.
  assert.equal(RELEASE.exec(text.slice(r.ended)), null);
});

test('since is after both, so a live-session Play line cannot start the control', () => {
  for (const text of [PREFIX + LIVE_PLAY + DELETE + RELEASED, PREFIX + LIVE_PLAY + RELEASED + DELETE]) {
    const r = sessionEnd(text, PREFIX.length, WHEP_END);
    assert.equal(text.slice(r.since).indexOf('[Play] presented'), -1);
  }
});

test('nothing yet, or only one of the two: no start position', () => {
  assert.equal(sessionEnd(PREFIX + LIVE_PLAY, PREFIX.length, WHEP_END).since, null);
  assert.equal(sessionEnd(PREFIX + DELETE, PREFIX.length, WHEP_END).since, null);
  assert.equal(sessionEnd(PREFIX + RELEASED, PREFIX.length, WHEP_END).since, null);
});

test('lines before `from` are not counted', () => {
  const text = RELEASED + DELETE + PREFIX;
  assert.equal(sessionEnd(text, text.length - PREFIX.length, WHEP_END).since, null);
});

// observe-abs-decklink-whep-mediamtx, 21:17:29: the line that set the anchor. The noise check put the
// file's real start ~5 s before the moment the orchestrator noticed it.
const BEEP = '[AV-CONTENT] beep in pts=6.593604 host=103596.1398';

test('anchor from the beep line\'s own host time, not from when it was noticed', () => {
  const wallNow = Date.UTC(2026, 8, 30, 1, 17, 29);          // 21:17:29 EDT, when it was noticed
  const a = beepWallMs(BEEP, 103596.1398 + 5.0, wallNow);
  assert.ok(a.fromHost);
  assert.equal(a.ageS.toFixed(3), '5.000');
  assert.equal(wallNow - a.wallMs, 5000);
});

test('a host time from another clock (negative or stale age) falls back to now, flagged', () => {
  const wallNow = 1_000_000;
  for (const hostNow of [103596.1398 - 1, 103596.1398 + 3600]) {
    const a = beepWallMs(BEEP, hostNow, wallNow);
    assert.equal(a.fromHost, false);
    assert.equal(a.wallMs, wallNow);
  }
});

test('not a beep-in line: null', () => {
  assert.equal(beepWallMs('[AV-CONTENT] beep out pts=6.59 host=103596.1', 103600, 0), null);
  assert.equal(beepWallMs('[AV-CONTENT] flash pts=1.04 tick=87422.0118 now=1.04 audio−now=-0.6 ms', 103600, 0), null);
});
