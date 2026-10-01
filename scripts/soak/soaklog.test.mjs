// node --test scripts/soak/soaklog.test.mjs   — soaklog.mjs on the real log lines of 2026-09-30's two WHEP runs.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sessionEnd, RELEASE } from './soaklog.mjs';

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
