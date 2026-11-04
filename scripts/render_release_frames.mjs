// Capture release-demo/player.html frame by frame through one headless Chrome (DevTools protocol).
// Each frame seeks every Web Animation to t, so the output is deterministic.
//   node scripts/render_release_frames.mjs <player.html> <outDir> <fps> <chromeBinary>
import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [player, outDir, fpsArg, chrome] = process.argv.slice(2);
const fps = Number(fpsArg);
const port = 9333 + Math.floor(Math.random() * 500);
const proc = spawn(chrome, [
  '--headless', '--disable-gpu', '--hide-scrollbars', `--remote-debugging-port=${port}`,
  `--user-data-dir=${mkdtempSync(join(tmpdir(), 'diduny-gif-'))}`, '--window-size=800,500', 'about:blank',
], { stdio: 'ignore' });

const sleep = ms => new Promise(r => setTimeout(r, ms));
let target;
for (let i = 0; i < 50 && !target; i++) {
  await sleep(200);
  try { target = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find(t => t.type === 'page'); } catch {}
}
if (!target) { proc.kill(); throw new Error('Chrome did not start'); }

const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r, { once: true }));
let id = 0; const pending = new Map();
ws.addEventListener('message', e => { const m = JSON.parse(e.data); pending.get(m.id)?.(m); pending.delete(m.id); });
const send = (method, params = {}) => new Promise((res, rej) => {
  const n = ++id; pending.set(n, m => m.error ? rej(new Error(m.error.message)) : res(m.result));
  ws.send(JSON.stringify({ id: n, method, params }));
});
const evaluate = async expr => (await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })).result.value;

await send('Emulation.setDeviceMetricsOverride', { width: 800, height: 500, deviceScaleFactor: 1, mobile: false });
await send('Page.enable');
await send('Page.navigate', { url: `${player}?t=0` });
await sleep(800);
await evaluate('document.fonts.ready.then(() => true)');
const total = await evaluate('window.TOTAL_MS');
const frames = Math.floor(total * fps / 1000);

for (let i = 0; i < frames; i++) {
  const t = i * 1000 / fps;
  await evaluate(`document.getAnimations().forEach(a => { a.pause(); a.currentTime = ${t}; }); new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))`);
  const { data } = await send('Page.captureScreenshot', { format: 'png' });
  writeFileSync(join(outDir, `f${String(i).padStart(5, '0')}.png`), Buffer.from(data, 'base64'));
}
console.log(`${frames} frames, ${total} ms`);
ws.close(); proc.kill();
