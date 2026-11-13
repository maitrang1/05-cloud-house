// Read-only Zalo personal sidecar (zca-js 2.2.0, vendored in node_modules).
//   node side.mjs login --qr FILE [--fixture F]      QR login; prints {"event":"session","session":{...}} once, then exits
//   node side.mjs serve --allow a,b [--gap-ms N] [--call-timeout-ms N] [--fixture F]
//       stdin line 1: {"session":{...}}; then one request per line {"rid":1,"method":"getAllFriends","args":[]}
//       stdout: {"rid":1,"ok":true,"data":...} | {"rid":1,"ok":false,"code":"refused|dead_session|rate_limited|timeout|error","msg":"..."}
// Safety: methods must be in read-only.json AND in --allow. Cookies are never printed. No listener, no send path exists in this file.
import { readFileSync } from "node:fs";
import { createInterface } from "node:readline";

const argv = process.argv.slice(2);
const mode = argv[0];
const opt = (k, d = "") => { const i = argv.indexOf("--" + k); return i >= 0 && i + 1 < argv.length ? argv[i + 1] : d; };
const out = (o) => process.stdout.write(JSON.stringify(o, (_k, v) => (typeof v === "bigint" ? v.toString() : v)) + "\n");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const READ = new Set(JSON.parse(readFileSync(new URL("./read-only.json", import.meta.url), "utf8")).read);
const fixturePath = opt("fixture");
const fixture = fixturePath ? JSON.parse(readFileSync(fixturePath, "utf8")) : null;

function classify(e) {
  const s = String((e && (e.message || e)) || "").toLowerCase();
  if (/enotfound|econn|etimedout|eai_again|fetch failed|network|socket|timed out/.test(s)) return "down";
  if (/login|cookie|session|unauthor|expired|logout|locked/.test(s)) return "dead_session";
  if (/rate|too many|limit|221/.test(s)) return "rate_limited";
  return "error";
}

// fixture api: deterministic, no network (tests). MOCK_MODE=dead|rate simulates a bad account.
function fakeApi() {
  let n = 0;
  return new Proxy({}, {
    get: (_t, name) => async (...args) => {
      n += 1;
      if (process.env.MOCK_MODE === "dead") throw new Error("session expired");
      if (process.env.MOCK_MODE === "rate" && n > 1) throw new Error("too many requests 221");
      const v = fixture && fixture[String(name)];
      if (v === undefined) throw new Error("no fixture for " + String(name));
      return typeof v === "function" ? v(...args) : (v && v.__byArg ? v.__byArg[String(args[0])] ?? null : v);
    },
  });
}

async function doLogin() {
  if (fixture) { out({ event: "session", session: { imei: "fixture", userAgent: "fixture", cookie: "FIXTURE-COOKIE" } }); return; }
  const qr = opt("qr");
  if (!qr) { out({ ok: false, code: "usage", msg: "--qr FILE needed" }); process.exit(2); }
  const { Zalo, LoginQRCallbackEventType } = await import("zca-js");
  const T = LoginQRCallbackEventType;
  const api = await new Zalo({ checkUpdate: false, logging: false }).loginQR({ qrPath: qr }, (ev) => {
    if (ev.type === T.QRCodeGenerated) ev.actions.saveToFile(qr).then(() => out({ event: "qr_saved", path: qr }));
    else if (ev.type === T.QRCodeScanned) out({ event: "scanned" });
    else if (ev.type === T.QRCodeExpired) ev.actions.retry();
    else if (ev.type === T.QRCodeDeclined) { out({ event: "declined" }); ev.actions.abort(); }
    else if (ev.type === T.GotLoginInfo) out({ event: "session", session: { imei: ev.data.imei, userAgent: ev.data.userAgent, cookie: ev.data.cookie } });
  });
  out({ ok: true, cmd: "login", uid: String(api.getOwnId()) });
  setTimeout(() => process.exit(0), 300);
}

async function doServe() {
  const allow = new Set(opt("allow").split(",").filter((n) => READ.has(n)));
  const gap = Number(opt("gap-ms", "1500"));
  const tmo = Number(opt("call-timeout-ms", "60000"));
  const rl = createInterface({ input: process.stdin });
  let api = null;
  let first = true;
  let last = 0;
  for await (const line of rl) {
    if (!line.trim()) continue;
    let req;
    try { req = JSON.parse(line); } catch { out({ ok: false, code: "error", msg: "bad json" }); continue; }
    if (first) {
      first = false;
      try {
        if (fixture) api = fakeApi();
        else {
          const { Zalo } = await import("zca-js");
          api = await new Zalo({ checkUpdate: false, logging: false }).login(req.session);
        }
        out({ ok: true, ready: true });
      } catch (e) { out({ ok: false, code: classify(e), msg: String((e && e.message) || e).slice(0, 200) }); process.exit(2); }
      continue;
    }
    const rid = req.rid;
    const m = String(req.method || "");
    if (!READ.has(m) || !allow.has(m) || typeof api[m] !== "function" && !fixture) { out({ rid, ok: false, code: "refused", msg: "method not allowed" }); continue; }
    const wait = last + gap - Date.now();
    if (wait > 0) await sleep(wait);
    last = Date.now();
    try {
      const data = await Promise.race([api[m](...(Array.isArray(req.args) ? req.args : [])), sleep(tmo).then(() => { throw new Error("timed out"); })]);
      out({ rid, ok: true, data });
    } catch (e) {
      const code = classify(e);
      out({ rid, ok: false, code, msg: String((e && e.message) || e).slice(0, 200) });
      if (code === "dead_session" || code === "rate_limited") process.exit(code === "dead_session" ? 2 : 3);
    }
  }
}

if (mode === "login") await doLogin();
else if (mode === "serve") await doServe();
else { out({ ok: false, code: "usage", msg: "login | serve" }); process.exit(2); }
