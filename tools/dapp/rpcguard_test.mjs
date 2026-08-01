// Behavioural test for the wallet-RPC guards: probe ordering, dead-wallet-RPC detection, and the
// gas-estimate fallback that keeps a healthy tx from being blocked by a wallet on a dead endpoint.
// Usage: node rpcguard_test.mjs http://127.0.0.1:8899/index.html   (needs headless Edge on :9222)
const TARGET = process.argv[2];
const CDP = "http://127.0.0.1:9222";
const j = async (p) => (await fetch(CDP + p)).json();
const tab = (await j("/json/list")).find(t => t.type === "page");
const ws = new WebSocket(tab.webSocketDebuggerUrl);
let id = 0; const pending = new Map();
const send = (m, params = {}) => new Promise(res => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method: m, params })); });
await new Promise(r => ws.addEventListener("open", r));
ws.addEventListener("message", (m) => { const d = JSON.parse(m.data); if (d.id && pending.has(d.id)) { pending.get(d.id)(d.result); pending.delete(d.id); } });
await send("Runtime.enable"); await send("Page.enable");
await send("Page.navigate", { url: TARGET });
await new Promise(r => setTimeout(r, 9000));

const run = async (label, expr) => {
  const r = await send("Runtime.evaluate", { expression: `(async()=>{${expr}})()`, awaitPromise: true, returnByValue: true });
  console.log(label, r.exceptionDetails ? "EXCEPTION " + (r.exceptionDetails.exception?.description || "") : JSON.stringify(r.result.value));
};

// 1. the wallet gets a live endpoint first, and the dead one is not first
await run("addChainRpcs:", `const u=await addChainRpcs(); return {first:u[0], all:u.length, deadFirst:u[0].includes("enosys")};`);

// 2. dead wallet RPC -> one sticky warning toast naming the live endpoint; healthy wallet RPC -> none
await run("deadWalletRpc:", `
  document.getElementById("toasts").innerHTML="";
  await checkWalletRpc({request:()=>new Promise(()=>{})});   // never answers, like a down endpoint
  const t=document.getElementById("toasts");
  return {toasts:t.children.length, text:(t.textContent||"").slice(0,140)};`);
await run("healthyWalletRpc:", `
  document.getElementById("toasts").innerHTML="";
  await checkWalletRpc({request:async()=>"0x1"});
  return {toasts:document.getElementById("toasts").children.length};`);

// 3. wallet cannot estimate -> sendTx still supplies a real padded gasLimit from the probed endpoint.
//    Stub only the wallet side; the fallback path hits the live chain for real.
await run("sendTxFallback:", `
  account="0xA63D649990878BA04892929b46674F64338e4909";
  const fake={ getAddress:async()=>POOL, interface:IPOOL,
    redeem:Object.assign((...a)=>a[a.length-1],{estimateGas:async()=>{throw new Error("missing revert data")}}) };
  const ov=await sendTx(fake,"redeem",9915423620911n,account,account);
  return {gasLimit:ov.gasLimit?ov.gasLimit.toString():null};`);
await run("sendTxBothDown:", `
  const fake={ getAddress:async()=>POOL, interface:IPOOL,
    redeem:Object.assign((...a)=>a[a.length-1],{estimateGas:async()=>{throw new Error("x")}}) };
  const saved=_rpUrl; _rpUrl="http://127.0.0.1:1/dead"; _rp=null;
  const ov=await sendTx(fake,"redeem",1n,account,account);
  _rpUrl=saved; _rp=null;
  return {gasLimit:ov.gasLimit?ov.gasLimit.toString():null, sentAnyway:true};`);
process.exit(0);
