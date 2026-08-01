// Verify the dashboard tiles render real values and no console errors appear.
const TARGET = process.argv[2];
const CDP = "http://127.0.0.1:9222";
const j = async (p) => (await fetch(CDP + p)).json();
const tabs = await j("/json/list");
const tab = tabs.find(t => t.type === "page");
const ws = new WebSocket(tab.webSocketDebuggerUrl);
let id = 0; const pending = new Map(); const errors = [];
const send = (method, params = {}) => new Promise((res) => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
await new Promise(r => ws.addEventListener("open", r));
ws.addEventListener("message", (m) => {
  const d = JSON.parse(m.data);
  if (d.id && pending.has(d.id)) { pending.get(d.id)(d.result); pending.delete(d.id); }
  if (d.method === "Runtime.consoleAPICalled" && d.params.type === "error") errors.push(JSON.stringify(d.params.args?.map(a => a.value ?? a.description)));
  if (d.method === "Runtime.exceptionThrown") errors.push(d.params.exceptionDetails?.exception?.description || "exception");
});
await send("Runtime.enable"); await send("Page.enable");
await send("Page.navigate", { url: TARGET });
await new Promise(r => setTimeout(r, 12000));
const ids = ["d-tvl", "d-borrowed", "d-util", "d-apy", "d-apy-sub", "d-lenders", "d-borrowers", "netblock"];
const r = await send("Runtime.evaluate", {
  expression: `JSON.stringify(Object.fromEntries(${JSON.stringify(ids)}.map(i=>[i,(document.getElementById(i)||{}).textContent])))`,
  returnByValue: true
});
console.log("tiles:", JSON.stringify(JSON.parse(r.result.value), null, 2));
console.log("console errors:", errors.length ? errors : "none");
ws.close();
