// Minimal obs-websocket v5 client on Node's built-in WebSocket. No dependencies.
// Password is read from OBS's own config and never printed.
import { readFileSync } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { homedir } from 'node:os';

const cfg = JSON.parse(readFileSync(
  `${homedir()}/Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json`, 'utf8'));

export async function connect(port) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  const pending = new Map();
  let identified;
  const ready = new Promise((res, rej) => { identified = res; ws.onerror = e => rej(new Error(`ws ${port}: ${e.message ?? 'error'}`)); });
  ws.onmessage = ev => {
    const m = JSON.parse(ev.data);
    if (m.op === 0) {
      const ident = { rpcVersion: 1, eventSubscriptions: 0 };
      if (m.d.authentication) {
        const { challenge, salt } = m.d.authentication;
        const secret = createHash('sha256').update(cfg.server_password + salt).digest('base64');
        ident.authentication = createHash('sha256').update(secret + challenge).digest('base64');
      }
      ws.send(JSON.stringify({ op: 1, d: ident }));
    } else if (m.op === 2) identified();
    else if (m.op === 7) {
      const p = pending.get(m.d.requestId); if (!p) return; pending.delete(m.d.requestId);
      m.d.requestStatus.result ? p.res(m.d.responseData ?? {}) : p.rej(new Error(`${m.d.requestType}: ${m.d.requestStatus.code} ${m.d.requestStatus.comment ?? ''}`));
    }
  };
  await ready;
  return {
    call(requestType, requestData = {}) {
      const requestId = randomUUID();
      return new Promise((res, rej) => { pending.set(requestId, { res, rej }); ws.send(JSON.stringify({ op: 6, d: { requestType, requestId, requestData } })); });
    },
    close() { ws.close(); },
  };
}

// CLI: node obsws.mjs <port> <RequestType> [json]
if (process.argv[1].endsWith('obsws.mjs') && process.argv[2]) {
  const c = await connect(Number(process.argv[2]));
  try { console.log(JSON.stringify(await c.call(process.argv[3], process.argv[4] ? JSON.parse(process.argv[4]) : {}), null, 1)); }
  catch (e) { console.error(e.message); process.exitCode = 1; }
  c.close();
}
