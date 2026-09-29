// Soak orchestrator (resampler step 8 onward; README.md in this folder). Drives the sender OBS (4455) and the recorder OBS (4456) over
// obs-websocket, watches Manifold's log for the moments that need the operator, and writes a
// timeline for the analysis. Usage: node soak.mjs <label> <manifold-log>
import { connect } from './obsws.mjs';
import { execFileSync, spawnSync } from 'node:child_process';
import { readFileSync, existsSync, writeFileSync, statSync, readdirSync, openSync, readSync, closeSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';

const [label, logPath, transport] = process.argv.slice(2);
if (!label || !logPath || !['ndi', 'srt', 'srt-cf', 'whep', 'whep-cf', 'whep-cf-long', 'hls'].includes(transport)) { console.error('usage: node soak.mjs <label> <manifold-log> <ndi|srt|srt-cf|whep|whep-cf|whep-cf-long|hls>'); process.exit(2); }
if (existsSync(logPath) && process.env.SOAK_ATTACH !== '1') { console.error(`${logPath} already exists — use a fresh log name (or SOAK_ATTACH=1 for a Manifold launched just now)`); process.exit(2); }
// Timelines, probes and stdout captures go to SOAK_OUT, never into the repo.
const DIR = (process.env.SOAK_OUT ?? `${homedir()}/Desktop/manifold-soak`).replace(/\/?$/, '/');
mkdirSync(DIR, { recursive: true });
const timelinePath = `${DIR}soak-${label}-timeline.json`;
const timeline = { label, log: logPath, events: [] };

const SCENE = 'BLIPS_NOISE', BEEPS = 'BEEPS', NOISE = 'NOISE';
const APP_AUDIO = 'macOS Audio Capture', BUNDLE = 'com.graviton.manifold';
const CAPTURE_S = 130;
// File controls cover ≥ 5 loops of the 60 s fixture, so every display phase is sampled (§18.4).
const CONTROL_S = 300;
const T = { captureA: 180, noiseOn: 330, noiseOff: 1530, captureB: 1560, end: 1710 };

const sleep = s => new Promise(r => setTimeout(r, s * 1000));
const stamp = () => new Date().toISOString();
function mark(event, extra = {}) {
  const e = { t: stamp(), event, ...extra };
  timeline.events.push(e); writeFileSync(timelinePath, JSON.stringify(timeline, null, 1));
  console.log(`${e.t.slice(11, 19)}  ${event}${Object.keys(extra).length ? ' ' + JSON.stringify(extra) : ''}`);
}
function alert(msg, speak = true) {
  spawnSync('osascript', ['-e', `display notification "${msg.replace(/"/g, "'")}" with title "Manifold soak — ${label}" sound name "Glass"`]);
  if (speak) spawnSync('say', [msg]);
  mark('alert', { msg });
}
const logText = () => existsSync(logPath) ? readFileSync(logPath, 'utf8') : '';
// For a multi-hundred-MB log: read only what was appended after byte `from`.
const logSize = () => existsSync(logPath) ? statSync(logPath).size : 0;
function logTail(from) {
  const size = logSize(); if (size <= from) return '';
  const fd = openSync(logPath, 'r'); const buf = Buffer.alloc(size - from);
  readSync(fd, buf, 0, buf.length, from); closeSync(fd); return buf.toString('utf8');
}
async function waitForTail(re, from, timeoutS) {
  const deadline = Date.now() + timeoutS * 1000;
  for (;;) {
    const m = re.exec(logTail(from)); if (m) return m[0];
    if (Date.now() > deadline) return null;
    await sleep(2);
  }
}
async function waitForLog(re, what, after = 0, timeoutS = Infinity) {
  const deadline = Date.now() + timeoutS * 1000;
  for (;;) {
    if (Date.now() > deadline) { mark(`timed out waiting for ${what}`); return after; }
    const t = logText();
    const m = re.exec(t.slice(after));
    if (m) return after + m.index + m[0].length;
    await sleep(1);
  }
}
function newestMov() {
  const out = execFileSync('/bin/sh', ['-c', `ls -t "${homedir()}"/Movies/*.mov | head -1`]).toString().trim();
  return out;
}
function maxVolume(path) {
  const r = spawnSync('ffmpeg', ['-hide_banner', '-i', path, '-map', '0:a:0', '-af', 'volumedetect', '-f', 'null', '-']);
  const m = /max_volume: (-?[\d.]+|-inf) dB/.exec(r.stderr.toString());
  return m && m[1] !== '-inf' ? Number(m[1]) : -Infinity;
}
function manifoldPids() {
  const r = spawnSync('pgrep', ['-x', 'Manifold']); return r.stdout.toString().split(/\s+/).filter(Boolean);
}

let sender, recorder, beepsId, noiseId, recording = false;

async function restoreSender() {
  try {
    await sender.call('SetSceneItemEnabled', { sceneName: SCENE, sceneItemId: noiseId, sceneItemEnabled: false });
    await sender.call('SetInputMute', { inputName: BEEPS, inputMuted: false });
  } catch (e) { console.error('restore failed:', e.message); }
}
async function record(name, seconds) {
  await recorder.call('StartRecord'); recording = true;
  mark(`${name} start`);
  await sleep(seconds);
  // The recorder's Output Timer may already have stopped it at 2:10; that is not an error.
  let r = {};
  try { r = await recorder.call('StopRecord'); } catch (e) { mark(`${name} already stopped`, { why: e.message }); }
  recording = false;
  const path = r.outputPath ?? newestMov();
  await sleep(2);
  const vol = maxVolume(path);
  mark(`${name} stop`, { path, maxVolumeDb: vol });
  return { path, vol };
}
async function repickAudio() {
  const { inputSettings } = await recorder.call('GetInputSettings', { inputName: APP_AUDIO });
  await recorder.call('SetInputSettings', { inputName: APP_AUDIO, inputSettings: { ...inputSettings, application: '' } });
  await sleep(1);
  await recorder.call('SetInputSettings', { inputName: APP_AUDIO, inputSettings: { ...inputSettings, application: BUNDLE } });
  await sleep(2);
}

process.on('SIGINT', async () => {
  mark('interrupted');
  if (recording) await recorder.call('StopRecord').catch(() => {});
  await restoreSender(); process.exit(130);
});

// ── setup ────────────────────────────────────────────────────────────────────────────────────
sender = await connect(4455);
recorder = await connect(4456);
const items = (await sender.call('GetSceneItemList', { sceneName: SCENE })).sceneItems;
beepsId = items.find(i => i.sourceName === BEEPS)?.sceneItemId;
noiseId = items.find(i => i.sourceName === NOISE)?.sceneItemId;
if (!beepsId || !noiseId) throw new Error(`scene ${SCENE} must hold ${BEEPS} and ${NOISE}`);
const noiseSettings = (await sender.call('GetInputSettings', { inputName: NOISE })).inputSettings;
await sender.call('SetInputSettings', { inputName: NOISE, inputSettings: { looping: false, restart_on_activate: true } });
await sender.call('SetSceneItemEnabled', { sceneName: SCENE, sceneItemId: beepsId, sceneItemEnabled: true });
await restoreSender();

// ── transport specifics ────────────────────────────────────────────────────────────────────────
const TR = {
  ndi: { profile: null, connected: /\[NDI\] connected to/,
         connectMsg: 'Control done. Turn on DistroAV output, then connect Manifold to O B S P G M.',
         endMsg: 'Run complete. Disconnect N D I but keep Manifold open. Then play the beeps file for the second control.',
         endedLog: /\[NDI\] disconnected/,
         quitMsg: 'All done. Quit Manifold, stop Audio Hijack, and turn DistroAV off.' },
  whep: { profile: 'MediaMTX Local', stream: true, probe: 'rtsp://127.0.0.1:8554/live',
         connected: /\[WHEP\] connected — ICE/,
         connectMsg: 'Control done. O B S is streaming to Media M T X. Connect Manifold to the Media M T X WHEP bookmark.',
         endMsg: 'Run complete. Disconnect in Manifold but keep it open. Then play the beeps file for the second control.',
         endedLog: /\[WHEP\] DELETE resource/,
         quitMsg: 'All done. Quit Manifold and stop Audio Hijack. O B S has stopped streaming. Tell Claude MediaMTX is done.' },
  // The long run, self-contained: the soak's structure to the end of the noise segment, then
  // capture B at T0 + 4 h 30 with the stream still up, then OBS stops streaming and the script
  // waits for Manifold's media-stall watchdog to end the session. Manifold, both OBS and the
  // recorder stay up; control 2 is played in the morning (control2.mjs).
  'whep-cf-long': { profile: 'WHIP Cloudflare', stream: true, long: true, endAtS: 4.5 * 3600,
         connected: /\[WHEP\] connected — ICE/,
         connectMsg: 'Control done. O B S is streaming to Cloudflare. Connect Manifold to the Cloudflare WHEP bookmark.',
         endMsg: 'Wrap. Disconnect in Manifold but keep it open. Then play the beeps file for the second control.',
         endedLog: /\[WHEP\] DELETE resource/,
         quitMsg: 'All done. Quit Manifold. O B S has stopped streaming.' },
  'whep-cf': { profile: 'WHIP Cloudflare', stream: true,
         connected: /\[WHEP\] connected — ICE/,
         connectMsg: 'Control done. O B S is streaming to Cloudflare. Connect Manifold to the Cloudflare WHEP bookmark.',
         endMsg: 'Run complete. Disconnect in Manifold but keep it open. Then play the beeps file for the second control.',
         endedLog: /\[WHEP\] DELETE resource/,
         quitMsg: 'All done. Quit Manifold and stop Audio Hijack. O B S has stopped streaming.' },
  hls: { profile: 'MediaMTX Local', stream: true, logOnly: true, sessionS: 300,
         connected: /\[ARBITER\] claiming HLS/,
         connectMsg: 'Control done. Connect Manifold to the H L S address, one two seven dot zero dot zero dot one, port eight eight eight eight, live, index dot m three u eight.',
         endMsg: 'H L S check complete. Disconnect in Manifold but keep it open. Then play the beeps file for the second control.',
         endedLog: /\[HLS\] disconnected/,
         quitMsg: 'All done. Quit Manifold. O B S has stopped streaming.' },
  srt: { profile: 'SRT Local', stream: true, stopFirst: true, connected: /\[SRT\] transport up/,
         connectMsg: 'Control done. O B S is streaming. Connect Manifold to local S R T, and allow the passphrase prompt.',
         endMsg: 'Run complete. O B S has stopped streaming. Disconnect in Manifold but keep it open. Then play the beeps file for the second control.',
         endedLog: /\[SRT\] (session ended|══ stopped ══|connection lost)/,
         quitMsg: 'All done. Quit Manifold and stop Audio Hijack.' },
  // Cloudflare SRT: both OBS and Manifold are callers to Cloudflare, so the OBS-listener hang does
  // not apply and Manifold disconnects first, as on WHEP.
  'srt-cf': { profile: 'SRT Cloudflare', stream: true, connected: /\[SRT\] transport up/,
         connectMsg: 'Control done. O B S is streaming to Cloudflare over S R T. Connect Manifold to the Cloudflare S R T bookmark, and allow the passphrase prompt.',
         endMsg: 'Run complete. Disconnect in Manifold but keep it open. Then play the beeps file for the second control.',
         endedLog: /\[SRT\] (session ended|══ stopped ══|connection lost)/,
         quitMsg: 'All done. Quit Manifold and stop Audio Hijack. O B S has stopped streaming.' },
}[transport];

if (TR.profile) {
  const { currentProfileName } = await sender.call('GetProfileList');
  if (currentProfileName !== TR.profile) {
    const st = await sender.call('GetStreamStatus');
    if (st.outputActive) throw new Error('sender is streaming on another profile; stop it first');
    await sender.call('SetCurrentProfile', { profileName: TR.profile });
    await sleep(2);
  }
}
if (TR.profile) {
  const { parameterValue: mode } = await sender.call('GetProfileParameter', { parameterCategory: 'Output', parameterName: 'Mode' });
  const root = `${homedir()}/Library/Application Support/obs-studio/basic/profiles`;
  const dir = readdirSync(root).find(d => existsSync(`${root}/${d}/basic.ini`)
    && new RegExp(`^Name=${TR.profile}$`, 'm').test(readFileSync(`${root}/${d}/basic.ini`, 'utf8')));
  const enc = dir && existsSync(`${root}/${dir}/streamEncoder.json`)
    ? JSON.parse(readFileSync(`${root}/${dir}/streamEncoder.json`, 'utf8')) : {};
  mark('sender profile', { profile: TR.profile, outputMode: mode, keyintSec: enc.keyint_sec ?? null });
  if (mode !== 'Advanced') throw new Error(`${TR.profile} is in ${mode} output mode, not Advanced`);
  if (enc.keyint_sec !== 1) throw new Error(`${TR.profile} keyframe interval is ${enc.keyint_sec ?? 'unset'} s, not 1 s`);
}
const video = await sender.call('GetVideoSettings');
const recVideo = await recorder.call('GetVideoSettings');
mark('setup', { transport, profile: (await sender.call('GetProfileList')).currentProfileName,
  noiseLoopWas: noiseSettings.looping, noiseLoopNow: false,
  senderFps: video.fpsNumerator / video.fpsDenominator, recorderFps: recVideo.fpsNumerator / recVideo.fpsDenominator });
if (Math.abs(video.fpsNumerator / video.fpsDenominator - 23.976) > 0.01) throw new Error('sender is not 23.976');
if (recVideo.fpsNumerator / recVideo.fpsDenominator !== 60) throw new Error('recorder is not 60 fps');

// A 5 s preflight, repeated until the recorder hears Manifold. Re-picking the app source is manual:
// setting it over websocket does not re-attach to a new Manifold process (measured 2026-09-28).
async function preflightUntilHeard(tag) {
  alert(`Re-pick Manifold in the recorder's mac O S Audio Capture now.`);
  for (let attempt = 1; attempt <= 12; attempt++) {
    await sleep(attempt === 1 ? 12 : 10);
    const pre = await record(`${tag} preflight ${attempt}`, 5);
    if (pre.vol > -40) return true;
    if (attempt % 3 === 0) alert(`The recorder still hears nothing. Re-pick Manifold in its audio capture.`);
  }
  return false;
}
async function fileControl(tag, since) {
  let p = await waitForLog(/\[Play\] presented (2[0-9]|3[0-9])\.\d fps/, 'playing', since);
  mark(`${tag}: file playing`, { pids: manifoldPids() });
  const c = await record(tag, CONTROL_S);
  if (c.vol < -40) alert(`Warning: ${tag} is silent.`);
  return p;
}

let pos = 0;
if (process.env.SOAK_T0) {
  // Resume at a known connect time (the connect was missed); control 1 is already recorded.
  pos = logText().length;
} else {
// ── control 1 ────────────────────────────────────────────────────────────────────────────────
alert('Ready. Manifold is launching. Deny the licence prompt, start Audio Hijack, open the beeps file, turn looping ON, then press play.');
pos = await waitForLog(/\[BUILD\] configuration=/, 'launch');
mark('manifold launched', { pids: manifoldPids() });
pos = await waitForLog(/FrameEngine: loaded/, 'file loaded', pos);
pos = await waitForLog(/\[Play\] presented (2[0-9]|3[0-9])\.\d fps/, 'playing', pos);
if (!(await preflightUntilHeard('control 1'))) { alert('Stopping: the recorder cannot hear Manifold.'); process.exit(1); }
pos = await fileControl('control 1', pos);

// ── the live session ─────────────────────────────────────────────────────────────────────────
if (TR.stream) {
  const st = await sender.call('GetStreamStatus');
  if (!st.outputActive) { await sender.call('StartStream'); mark(`sender streaming (${transport})`); await sleep(5); }
  else mark('sender already streaming');
}
alert(TR.connectMsg);
pos = await waitForLog(TR.connected, 'connected', logText().length);
}
const t0 = process.env.SOAK_T0 ? Number(process.env.SOAK_T0) : Date.now();
if (process.env.SOAK_T0) mark('resumed', { t0: new Date(t0).toISOString() });

mark(`T0 ${transport} connected`, { pids: manifoldPids() });
alert('Connected. Nothing to do for about twenty eight minutes.');
const at = s => sleep(Math.max(0, (t0 + s * 1000 - Date.now()) / 1000));

if (TR.probe) {
  // The sender's own A/V, off the server, with no player in the path (AV_SYNC_FINDINGS §1.2b).
  setTimeout(() => {
    const out = `${DIR}soak-${label}-sender-probe.mkv`;
    const r = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-rtsp_transport', 'tcp',
      '-i', TR.probe, '-t', '40', '-c', 'copy', out]);
    mark('sender probe', { out, status: r.status, err: r.stderr.toString().slice(0, 200) });
  }, 60000);
}
if (TR.logOnly) {
  await at(TR.sessionS);
} else {
await at(T.captureA);
const a = await record('capture A', CAPTURE_S);
if (a.vol < -40) alert('Warning: capture A is silent.');
await at(T.noiseOn);
await sender.call('SetInputMute', { inputName: BEEPS, inputMuted: true });
await sender.call('SetSceneItemEnabled', { sceneName: SCENE, sceneItemId: noiseId, sceneItemEnabled: true });
mark('noise on, beeps muted');
await at(T.noiseOff);
await restoreSender();
mark('noise off, beeps unmuted');
if (TR.long) {
  await sleep(20);
  alert('Noise segment done. Stop Audio Hijack now. Nothing else tonight. The run ends by itself at four and a half hours.');
  mark('overnight: waiting for capture B', { at: new Date(t0 + TR.endAtS * 1000).toISOString() });
  await at(TR.endAtS);
  // Overnight: notifications only, no voice.
  const b = await record('capture B', CAPTURE_S);
  if (b.vol < -40) alert('Warning: capture B is silent.', false);
  // Stop the publisher. Cloudflare then holds the subscriber session open with no media, and
  // Manifold's media-stall watchdog (WHEPClient, 15 s without a decoded frame) tears it down through
  // disconnect() — the same path as the button, which writes the session END lines.
  const from = logSize();
  await sender.call('StopStream'); mark('sender stopped streaming (end of long run)');
  const stall = await waitForTail(/\[WHEP\] no media for \d+s on a healthy transport[^\n]*/, from, 120);
  const ended = await waitForTail(/\[WHEP-SRFIT\] session END[^\n]*/, from, 30);
  const steer = await waitForTail(/steering session END[^\n]*/, from, 10);
  const del = await waitForTail(/\[WHEP\] DELETE resource[^\n]*/, from, 10);
  mark('teardown', { watchdog: stall ?? 'NOT SEEN', fitEnd: !!ended, steeringEnd: !!steer, del: del ?? 'NOT SEEN' });
  if (!ended) alert('Manifold did not end the session after the stream stopped. Leave it: disconnect it by hand in the morning, before control 2.', false);
  alert('Long run complete. Stream stopped. In the morning: play the beeps file for control 2.', false);
  mark('done (control 2 in the morning: node control2.mjs)');
  sender.close(); recorder.close();
  process.exit(0);
} else {
await at(T.captureB);
const b = await record('capture B', CAPTURE_S);
if (b.vol < -40) alert('Warning: capture B is silent.');
await at(T.end);
}
}
mark('end', { pids: manifoldPids() });

// ── control 2, same launch ───────────────────────────────────────────────────────────────────
// SRT: the SENDER stops first. Manifold hanging up on OBS's listener hangs OBS (docs/BUGS.md).
// The log position is taken BEFORE the sender stops: on SRT the session ends within ~1 s of
// StopStream, and a position taken after it missed the marker (2026-09-28).
const endPos = logText().length;
if (TR.stopFirst) { await sender.call('StopStream'); mark('sender stopped streaming'); await sleep(2); }
alert(TR.endMsg);
// NO DEADLINE: a control recorded while the stream is still up is a live capture, not a control
// (2026-09-29: the operator was away, both waits timed out, and "control 2" recorded the stream).
// Repeat the prompt every 2 min instead.
let endedPos;
for (;;) {
  endedPos = await waitForLog(TR.endedLog, 'live session ended', endPos, 120);
  if (endedPos !== endPos) break;
  alert(`Still connected. ${TR.endMsg}`);
}
// Wait for the live source to release the deck, THEN for playback, so a live-session
// `[Play] presented` line cannot start the control early. The release line is common to every
// transport; NDI also reloads the file, SRT does not (2026-09-28).
let releasedPos;
for (;;) {
  releasedPos = await waitForLog(/\[ARBITER\] (exclusive device released|released )/, 'deck released', endedPos, 120);
  if (releasedPos !== endedPos) break;
  mark('deck not yet released; still waiting');
}
await fileControl('control 2', releasedPos);
if (TR.stream && !TR.stopFirst && !TR.keepStreaming) { await sender.call('StopStream'); mark('sender stopped streaming'); }
alert(TR.quitMsg);
mark('done');
sender.close(); recorder.close();
