// Verify the capacity pre-check, and that appending maxActiveLoans to the stats multicall did not
// shift the price/tier offsets that are derived from base.length.
//
// Usage: node captest.mjs http://127.0.0.1:8899/index.html   (needs headless Edge on :9222)
const TARGET = process.argv[2];
const CDP = "http://127.0.0.1:9222";
const j = async (p) => (await fetch(CDP + p)).json();
const tabs = await j("/json/list");
const tab = tabs.find(t => t.type === "page");
const ws = new WebSocket(tab.webSocketDebuggerUrl);
let id = 0; const pending = new Map(); const errors = [];
const send = (m, params = {}) => new Promise((res) => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method: m, params })); });
await new Promise(r => ws.addEventListener("open", r));
ws.addEventListener("message", (m) => {
  const d = JSON.parse(m.data);
  if (d.id && pending.has(d.id)) { pending.get(d.id)(d.result); pending.delete(d.id); }
  if (d.method === "Runtime.consoleAPICalled" && d.params.type === "error") errors.push(JSON.stringify(d.params.args?.map(a => a.value ?? a.description)));
  if (d.method === "Runtime.exceptionThrown") errors.push(d.params.exceptionDetails?.exception?.description || "exception");
});
await send("Runtime.enable"); await send("Page.enable");
await send("Page.navigate", { url: TARGET });
await new Promise(r => setTimeout(r, 14000));

const ev = async (expr) => (await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true })).result?.value;

// 1. the new values arrived from chain
const cap = await ev("JSON.stringify({active:STATS.activeLoans,max:STATS.maxActiveLoans,paused:STATS.paused})");
console.log("1. capacity read from chain :", cap);

// 2. offsets that derive from base.length still line up: prices and tiers must be populated.
//    If appending shifted them, prices go 0 and the tier table falls back to the local copy.
const px = await ev("JSON.stringify(Object.fromEntries(Object.keys(MK).filter(k=>MK[k].addr).map(k=>[k,MK[k].price])))");
console.log("2. oracle prices (0 = offsets broke):", px);

// 3. tiles still render real numbers
const tiles = await ev(`JSON.stringify(Object.fromEntries(["d-tvl","d-borrowed","d-util","d-apy","d-loans"].map(i=>[i,(document.getElementById(i)||{}).textContent])))`);
console.log("3. tiles                    :", tiles);

// 4. NEGATIVE CONTROL: the gate must actually fire. Force a full book and confirm doBorrow refuses
//    before touching the wallet, then restore.
// `account` is a top-level `let`, so it is a global lexical binding rather than a window property.
// Without setting it, doBorrow returns at its wallet check and never reaches the gate under test.
await ev("account='0x50073735Bd847299c16033295962ECb8DDB528b7'; window.__savedMax=STATS.maxActiveLoans; STATS.maxActiveLoans=1; STATS.activeLoans=99999; window.__toasts=[]; window.toast=(m,t)=>{window.__toasts.push(String(m));};");
await ev("(async()=>{ try{ await window.doBorrow(); }catch(e){} })()");
await new Promise(r => setTimeout(r, 1500));
const fired = await ev("JSON.stringify(window.__toasts)");
console.log("4. forced-full doBorrow says:", fired);

// 5. restore and confirm it does NOT block at real capacity
await ev("STATS.maxActiveLoans=window.__savedMax; STATS.activeLoans=1; window.__toasts=[];");
await ev("(async()=>{ try{ await window.doBorrow(); }catch(e){} })()");
await new Promise(r => setTimeout(r, 1500));
const notFired = await ev("JSON.stringify(window.__toasts)");
console.log("5. with room, capacity msg  :", /book is full/.test(notFired || "") ? "WRONGLY BLOCKED" : "not blocked (correct)");
console.log("   (message shown instead)  :", notFired);

console.log("console errors:", errors.length ? errors : "none");
ws.close();
