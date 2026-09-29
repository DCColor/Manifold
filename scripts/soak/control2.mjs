// Control 2 for a self-ending run (whep-cf-long), same Manifold launch, in the morning:
//   node control2.mjs <manifold-log> [label]   label defaults to the log's basename
// Waits for the beeps file to be playing (a NEW `[Play] presented` line), records 300 s on the
// recorder OBS (4456), reports its max volume. Appends to the long run's timeline.
import { connect } from './obsws.mjs';
import { statSync, openSync, readSync, closeSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { basename } from 'node:path';
import { spawnSync, execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
const logPath = process.argv[2];
if (!logPath || !existsSync(logPath)) { console.error('usage: node control2.mjs <manifold-log> [label]'); process.exit(2); }
const label = process.argv[3] ?? basename(logPath, '.log');
const DIR = (process.env.SOAK_OUT ?? `${homedir()}/Desktop/manifold-soak`).replace(/\/?$/, '/');
const tl = `${DIR}soak-${label}-timeline.json`;
const sleep = s => new Promise(r => setTimeout(r, s * 1000));
function mark(event, extra = {}) {
  const e = { t: new Date().toISOString(), event, ...extra }; console.log(e.t.slice(11, 19), event, JSON.stringify(extra));
  if (existsSync(tl)) { const j = JSON.parse(readFileSync(tl, 'utf8')); j.events.push(e); writeFileSync(tl, JSON.stringify(j, null, 1)); }
}
const from = statSync(logPath).size;
const tail = () => { const size = statSync(logPath).size; if (size <= from) return '';
  const fd = openSync(logPath, 'r'); const b = Buffer.alloc(size - from); readSync(fd, b, 0, b.length, from); closeSync(fd); return b.toString('utf8'); };
const recorder = await connect(4456);
spawnSync('say', ['Play the beeps file in Manifold, looping on.']);
mark('control 2: waiting for playback');
while (!/\[Play\] presented (2[0-9]|3[0-9])\.\d fps/.test(tail())) await sleep(1);
mark('control 2: file playing');
await recorder.call('StartRecord'); mark('control 2 start');
await sleep(300);
let r = {}; try { r = await recorder.call('StopRecord'); } catch (e) { mark('control 2 already stopped', { why: e.message }); }
const path = r.outputPath ?? execFileSync('/bin/sh', ['-c', `ls -t "${homedir()}"/Movies/*.mov | head -1`]).toString().trim();
await sleep(2);
const v = spawnSync('ffmpeg', ['-hide_banner', '-i', path, '-map', '0:a:0', '-af', 'volumedetect', '-f', 'null', '-']);
const m = /max_volume: (-?[\d.]+) dB/.exec(v.stderr.toString());
mark('control 2 stop', { path, maxVolumeDb: m ? Number(m[1]) : null });
spawnSync('say', ['Control two recorded. Tell Claude.']);
recorder.close();
