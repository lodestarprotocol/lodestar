// Verify both borrow pre-checks (slot cap and per-collateral exposure cap), and that appending their
// reads to the stats multicall did not shift the price/tier offsets derived from base.length.
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
  if (d.method === "Runtime.exceptionThrown") errors.push(d.params.exceptionDetails?.exception?.description || "exception");
});
await send("Runtime.enable"); await send("Page.enable");
await send("Page.navigate", { url: TARGET });
await new Promise(r => setTimeout(r, 15000));

const ev = async (expr) => (await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true })).result?.value;

console.log("1. slot cap from chain   :", await ev("JSON.stringify({active:STATS.activeLoans,max:STATS.maxActiveLoans})"));
console.log("2. exposure from chain   :", await ev("JSON.stringify({expo:MK.FXRP.expo,cap:MK.FXRP.expoCap})"));
// If appending shifted the offsets, prices go 0 and the tier table silently falls back to the local copy.
console.log("3. offsets intact        :", await ev("JSON.stringify({price:MK.FXRP.price,hc:MK.FXRP.hc,tiers:MK.FXRP.tiers.length,tvl:(document.getElementById('d-tvl')||{}).textContent})"));

// doBorrow returns at `if(!account)` before reaching anything under test. `account` is a top-level
// `let`, a global lexical binding rather than a window property, so assign it bare.
const arm = `account='0x50073735Bd847299c16033295962ECb8DDB528b7';
             document.getElementById('amt').value='20';   // must clear minPrincipal, or that check fires first
             
             window.__t=[]; window.toast=(m)=>{window.__t.push(String(m));};`;

async function attempt(label, setup) {
  await ev(arm + setup);
  await ev("(async()=>{try{await window.doBorrow();}catch(e){}})()");
  await new Promise(r => setTimeout(r, 1200));
  const t = await ev("JSON.stringify(window.__t)");
  console.log("   " + label.padEnd(34), t);
  return t || "";
}

console.log("4. exposure-cap gate:");
// Slot cap must not fire in these, so give it room.
const roomy = "STATS.activeLoans=1; STATS.maxActiveLoans=400;";
const noRoom = await attempt("cap fully used ->", roomy + "MK.FXRP.expo=1000; MK.FXRP.expoCap=1000;");
const someRoom = await attempt("only $1 of room ->", roomy + "MK.FXRP.expo=999; MK.FXRP.expoCap=1000;");
const uncapped = await attempt("cap=0 (uncapped) ->", roomy + "MK.FXRP.expo=99999; MK.FXRP.expoCap=0;");
const unread = await attempt("cap unread (undefined) ->", roomy + "MK.FXRP.expo=undefined; MK.FXRP.expoCap=undefined;");
const plenty = await attempt("real chain values ->", roomy + "MK.FXRP.expo=1706; MK.FXRP.expoCap=1000000;");

const blocked = s => /capacity is left|at its cap/.test(s);
console.log("");
console.log("5. verdict:");
console.log("   at cap blocks              :", blocked(noRoom) ? "PASS" : "FAIL");
console.log("   partial room quotes it     :", blocked(someRoom) && /\$1\b/.test(someRoom) ? "PASS" : "FAIL");
console.log("   uncapped (0) does NOT block:", !blocked(uncapped) ? "PASS" : "FAIL - would bar valid borrows");
console.log("   unread cap does NOT block  :", !blocked(unread) ? "PASS" : "FAIL - a failed refresh would bar borrows");
console.log("   real values do NOT block   :", !blocked(plenty) ? "PASS" : "FAIL");
console.log("page exceptions:", errors.length ? errors : "none");
ws.close();
