// Measure how long the dashboard takes to show real numbers, and which RPCs it actually hits.
// Drives headless Edge over CDP. Usage: node loadtime.mjs [url]
const TARGET = process.argv[2] || "https://lodestarprotocol.xyz/";
const CDP = "http://127.0.0.1:9222";

const j = async (p) => (await fetch(CDP + p)).json();

const tabs = await j("/json/list");
let tab = tabs.find(t => t.type === "page");
if (!tab) { console.error("no page target; start Edge with --remote-debugging-port=9222"); process.exit(1); }

const ws = new WebSocket(tab.webSocketDebuggerUrl);
let id = 0;
const pending = new Map();
const send = (method, params = {}) => new Promise((res, rej) => {
  const i = ++id; pending.set(i, { res, rej });
  ws.send(JSON.stringify({ id: i, method, params }));
});
const events = [];
await new Promise(r => ws.addEventListener("open", r));
ws.addEventListener("message", (m) => {
  const d = JSON.parse(m.data);
  if (d.id && pending.has(d.id)) { pending.get(d.id).res(d.result); pending.delete(d.id); }
  else if (d.method === "Network.requestWillBeSent") events.push({ t: Date.now(), url: d.params.request.url });
});

await send("Network.enable");
await send("Page.enable");
await send("Network.clearBrowserCache");

const t0 = Date.now();
await send("Page.navigate", { url: TARGET });

// poll the dashboard TVL tile until it holds a real number
let firstNumber = null;
const deadline = Date.now() + 90000;
while (Date.now() < deadline) {
  const r = await send("Runtime.evaluate", {
    expression: `(()=>{const e=document.querySelector('#d-tvl');return e?e.textContent.trim():''})()`,
    returnByValue: true
  });
  const v = r?.result?.value || "";
  if (v && /[0-9]/.test(v) && v !== "$0.00" && !/^[-—]$/.test(v)) { firstNumber = { v, ms: Date.now() - t0 }; break; }
  await new Promise(r => setTimeout(r, 250));
}

const rpcHits = events.filter(e => /rpc|enosys|ankr|flare\.network/.test(e.url));
const byHost = {};
for (const h of rpcHits) { const host = new URL(h.url).host; byHost[host] = (byHost[host] || 0) + 1; }

console.log(`TARGET: ${TARGET}`);
console.log(`time to real TVL number: ${firstNumber ? firstNumber.ms + "ms  (" + firstNumber.v + ")" : "NEVER within 90s"}`);
console.log(`RPC requests by host:`, JSON.stringify(byHost, null, 2));
const firstRpc = rpcHits[0];
if (firstRpc) console.log(`first RPC hit at +${firstRpc.t - t0}ms -> ${new URL(firstRpc.url).host}`);
ws.close();
