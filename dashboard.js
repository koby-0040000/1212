// Computer registry + dashboard API, mounted by server.js. Does not touch the relay logic.
//
//   Agent (on each computer):  POST /api/agent/heartbeat   header x-agent-key
//   Admin (dashboard page):    POST /api/login, GET /api/computers,
//                              POST /api/computers/:n/connect, ...
//
// Env vars (set in Render):
//   DASHBOARD_PASSWORD  admin password for /dashboard   (required)
//   AGENT_KEY           shared secret the agents send   (required)
//   VNC_PASSWORD        optional, appended to the viewer link
//   SESSION_SECRET      optional, signs the login cookie
//   DATA_DIR            optional, where computers.json is kept

'use strict';
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const express = require('express');
const { buildInstaller } = require('./installer');

const DASHBOARD_PASSWORD = process.env.DASHBOARD_PASSWORD || '';
const AGENT_KEY = process.env.AGENT_KEY || '';
const VNC_PASSWORD = process.env.VNC_PASSWORD || '';
const SECRET = process.env.SESSION_SECRET
  || crypto.createHash('sha256').update(`sionyx-dash|${DASHBOARD_PASSWORD}|${AGENT_KEY}`).digest('hex');

const DOWN_MS = 5 * 60 * 1000;     // no heartbeat this long => really down (alert); between ONLINE_MS and this = "reconnecting"
const ONLINE_MS = 45000;            // no heartbeat for this long => offline
const COOKIE = 'sx_dash';
const COOKIE_TTL_MS = 12 * 3600 * 1000;
const PENDING_TTL_MS = 2 * 60 * 1000; // a connect request the agent must pick up within this time
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const DATA_FILE = path.join(DATA_DIR, 'computers.json');
const COMMANDS = new Set(['cad', 'lock', 'logoff', 'restart', 'shutdown', 'uninstall', 'sysinfo', 'nettest', 'getlog', 'restartfilter', 'diagnose']);
const FIXES = new Set(['clean_temp', 'start_services', 'sync_time', 'flush_dns', 'repair_wmi', 'power_balanced', 'renew_ip', 'restart_adapter', 'enable_adapter', 'reset_network_stack']);

// Version fingerprint of the agent script this server is serving (normalised, ASCII). Agents report
// the fingerprint of the script they are running, so the dashboard can show who still needs the update.
function agentFingerprint() {
  try {
    const t = fs.readFileSync(path.join(__dirname, 'public', 'sionyx-agent.ps1'), 'utf8').replace(/^\uFEFF/, '').replace(/\r/g, '');
    return crypto.createHash('sha1').update(t, 'utf8').digest('hex').slice(0, 8);
  } catch (_) { return ''; }
}
const AGENT_VER = agentFingerprint();
const UNINSTALL_ALIVE_MS = 20 * 1000;
const UNINSTALL_WAIT_MS = 2 * 60 * 1000; // how long the dashboard shows "removing..." before giving up
const COMMAND_TTL_MS = 60 * 1000; // a queued command the agent does not pick up in time is dropped
const NUMBER_RE = /^[A-Za-z0-9_-]{1,32}$/;

const computers = new Map(); // number -> { number, name, hostname, firstSeen, lastSeen, busy, pending }

// ---- persistence (best effort; on Render free it lasts until the next deploy/restart) ----
try {
  const saved = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
  for (const c of saved) computers.set(c.number, { ...c, busy: false, pending: null });
  console.log(`[dash] loaded ${computers.size} computer(s) from disk`);
} catch { /* first run */ }

let saveTimer = null;
function scheduleSave() {
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    try {
      fs.mkdirSync(DATA_DIR, { recursive: true });
      const list = [...computers.values()].map(({ number, name, hostname, firstSeen, lastSeen }) => (
        { number, name, hostname, firstSeen, lastSeen }));
      fs.writeFileSync(DATA_FILE, JSON.stringify(list));
    } catch (e) { console.error('[dash] save failed:', e.message); }
  }, 15000);
  saveTimer.unref();
}

// ---- auth helpers ----
const sha = (s) => crypto.createHash('sha256').update(String(s)).digest();
const safeEq = (a, b) => crypto.timingSafeEqual(sha(a), sha(b));
const sign = (v) => crypto.createHmac('sha256', SECRET).update(v).digest('hex');

function parseCookies(header) {
  const out = {};
  for (const part of String(header || '').split(';')) {
    const i = part.indexOf('=');
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}

function isLoggedIn(req) {
  const v = parseCookies(req.headers.cookie)[COOKIE];
  if (!v) return false;
  const [exp, sig] = v.split('.');
  if (!exp || !sig || Number(exp) < Date.now()) return false;
  return safeEq(sig, sign(exp));
}

function requireAuth(req, res, next) {
  if (!DASHBOARD_PASSWORD) return res.status(503).json({ error: 'DASHBOARD_PASSWORD is not set on the server' });
  if (!isLoggedIn(req)) return res.status(401).json({ error: 'unauthorized' });
  next();
}

const attempts = new Map(); // ip -> { n, reset }
function loginAllowed(ip) {
  const now = Date.now();
  const a = attempts.get(ip);
  if (!a || a.reset < now) return true;
  return a.n < 10;
}
function loginFailed(ip) {
  const now = Date.now();
  const a = attempts.get(ip);
  if (!a || a.reset < now) attempts.set(ip, { n: 1, reset: now + 10 * 60 * 1000 });
  else a.n += 1;
}

// Sanitizes the on-demand "sysinfo" payload (CPU model + top processes by
// load) the agent sends back after a "sysinfo" command, same spirit as
// cleanStats: cap sizes/lengths, drop anything malformed, never trust the
// agent's numbers blindly.
function cleanSysInfo(si) {
  if (!si || typeof si !== 'object') return null;
  const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
  const str = (v, n) => (typeof v === 'string' ? v.slice(0, n) : '');
  const procs = Array.isArray(si.processes) ? si.processes.slice(0, 12).map((p) => ({
    name: str(p && p.name, 60), pid: num(p && p.pid), pct: num(p && p.pct), memMb: num(p && p.memMb),
    hint: str(p && p.hint, 80), protected: !!(p && p.protected),
  })).filter((p) => p.name) : [];
  return {
    cpuModel: str(si.cpuModel, 120), cores: num(si.cores), threads: num(si.threads), maxMhz: num(si.maxMhz),
    procCount: num(si.procCount), cpuPct: num(si.cpuPct), processes: procs,
  };
}

function cleanStats(s) {
  if (!s || typeof s !== 'object') return null;
  const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
  const str = (v, n) => (typeof v === 'string' ? v.slice(0, n) : '');
  return {
    os: str(s.os, 80), user: str(s.user, 80), ip: str(s.ip, 45), agent: str(s.agent, 10), ver: str(s.ver, 16),
    cpuPct: num(s.cpuPct), ramTotalGb: num(s.ramTotalGb), ramFreeGb: num(s.ramFreeGb),
    diskTotalGb: num(s.diskTotalGb), diskFreeGb: num(s.diskFreeGb), uptimeHours: num(s.uptimeHours),
    vnc: !!s.vnc,
  };
}

function cleanDiag(d) {
  if (!d || typeof d !== 'object' || !Array.isArray(d.findings)) return null;
  const SEV = new Set(['ok', 'warn', 'bad']);
  const findings = d.findings.slice(0, 20).map((f) => {
    if (!f || typeof f !== 'object') return null;
    const p = {};
    if (f.p && typeof f.p === 'object') {
      for (const k of Object.keys(f.p).slice(0, 8)) {
        const v = f.p[k];
        if (typeof v === 'number' && Number.isFinite(v)) p[String(k).slice(0, 20)] = v;
        else if (typeof v === 'string') p[String(k).slice(0, 20)] = v.slice(0, 120);
      }
    }
    const id = typeof f.id === 'string' && /^[a-z_]{2,30}$/.test(f.id) ? f.id : '';
    if (!id) return null;
    return { id, sev: SEV.has(f.sev) ? f.sev : 'warn', fix: FIXES.has(f.fix) ? f.fix : '', p };
  }).filter(Boolean);
  return { findings, checks: Number(d.checks) || 0, took: Number(d.took) || 0 };
}
function cleanFixResults(arr) {
  if (!Array.isArray(arr)) return [];
  return arr.slice(0, 6).map((r) => (r && FIXES.has(r.id) ? { id: r.id, ok: !!r.ok, msg: String(r.msg || '').slice(0, 180), freedMb: Number(r.freedMb) || 0 } : null)).filter(Boolean);
}

function cleanNetInfo(n) {
  if (!n || typeof n !== 'object') return null;
  const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? Math.round(v * 10) / 10 : null);
  const str = (v, k) => (typeof v === 'string' ? v.slice(0, k) : '');
  return {
    adapter: str(n.adapter, 80), linkMbps: num(n.linkMbps), wifi: !!n.wifi,
    gateway: str(n.gateway, 45), gatewayMs: num(n.gatewayMs),
    inet1Ms: num(n.inet1Ms), inet2Ms: num(n.inet2Ms), dnsMs: num(n.dnsMs),
    srvOk: !!n.srvOk, srvMin: num(n.srvMin), srvAvg: num(n.srvAvg), srvMax: num(n.srvMax),
    downMbps: num(n.downMbps), upMbps: num(n.upMbps), took: num(n.took),
  };
}

const isOnline = (c) => !!c.lastSeen && Date.now() - c.lastSeen < ONLINE_MS;
// online | unstable (missed heartbeats for under 5 minutes: usually a network blip) | offline
const connState = (c) => (isOnline(c) ? 'online' : c.lastSeen && Date.now() - c.lastSeen < DOWN_MS ? 'unstable' : 'offline');
const isCurrent = (c) => !!(AGENT_VER && c.stats && c.stats.ver === AGENT_VER);
const view = (c) => ({
  number: c.number, name: c.name || '', hostname: c.hostname || '',
  online: isOnline(c), connState: connState(c), busy: isOnline(c) && !!c.busy,
  logAt: c.logAt || null, lastOutage: c.lastOutage || null,
  diagAt: c.diagAt || null, diagCount: c.diag ? c.diag.findings.filter((f) => f.sev !== 'ok').length : null, fixAt: c.fixAt || null,
  // "removing..." only while the computer has not come back with a heartbeat after the command;
  // if it is still alive 20s later the removal did not happen -> report a failure instead of hanging.
  uninstalling: !!c.uninstallAt && Date.now() - c.uninstallAt < UNINSTALL_WAIT_MS && !(c.lastSeen > c.uninstallAt + UNINSTALL_ALIVE_MS),
  uninstallFailed: !!c.uninstallAt && !!c.lastSeen && c.lastSeen > c.uninstallAt + UNINSTALL_ALIVE_MS,
  lastSeen: c.lastSeen || null, firstSeen: c.firstSeen || null,
  stats: c.stats || null,
  sysinfo: c.sysinfo || null, sysinfoAt: c.sysinfoAt || null,
  killResult: c.killResult || null, killResultAt: c.killResultAt || null,
  rttMs: c.rttMs != null ? c.rttMs : null, netinfo: c.netinfo || null, netinfoAt: c.netinfoAt || null,
  upToDate: !!(AGENT_VER && c.stats && c.stats.ver === AGENT_VER),
});

// ---- routes ----
const router = express.Router();
router.use((_req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });
// Basic hardening headers for everything this router serves.
router.use((_req, res, next) => {
  res.set({ 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', 'X-Frame-Options': 'DENY' });
  next();
});
// 64kb: one heartbeat can carry stats + sysinfo + network test + diagnosis + a 40-line log together.
router.use(express.json({ limit: '64kb' }));

router.post('/login', (req, res) => {
  if (!DASHBOARD_PASSWORD) return res.status(503).json({ error: 'DASHBOARD_PASSWORD is not set on the server' });
  if (!loginAllowed(req.ip)) return res.status(429).json({ error: 'too many attempts, try again later' });
  const pw = String((req.body && req.body.password) || '');
  if (!safeEq(pw, DASHBOARD_PASSWORD)) {
    loginFailed(req.ip);
    return res.status(401).json({ error: 'wrong password' });
  }
  const exp = String(Date.now() + COOKIE_TTL_MS);
  res.set('Set-Cookie', `${COOKIE}=${exp}.${sign(exp)}; HttpOnly; SameSite=Strict; Path=/; Max-Age=${COOKIE_TTL_MS / 1000}${req.secure ? '; Secure' : ''}`);
  res.json({ ok: true });
});

router.post('/logout', (_req, res) => {
  res.set('Set-Cookie', `${COOKIE}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0`);
  res.json({ ok: true });
});

router.get('/computers', requireAuth, (_req, res) => {
  const list = [...computers.values()].map(view);
  res.json({
    serverTime: Date.now(),
    total: list.length,
    online: list.filter((c) => c.online).length,
    unstable: list.filter((c) => c.connState === 'unstable').length,
    computers: list,
  });
});

router.post('/computers/:number/connect', requireAuth, (req, res) => {
  const c = computers.get(req.params.number);
  if (!c) return res.status(404).json({ error: 'unknown computer' });
  if (!isOnline(c)) return res.status(409).json({ error: 'offline' });
  const token = crypto.randomBytes(16).toString('hex'); // one-time room key
  c.pending = { token, createdAt: Date.now() };
  const url = `/vnc.html?token=${token}` + (VNC_PASSWORD ? `&password=${encodeURIComponent(VNC_PASSWORD)}` : '');
  console.log(`[dash] connect requested for computer ${c.number}`);
  res.json({ url });
});

router.post('/computers/:number/command', requireAuth, (req, res) => {
  const c = computers.get(req.params.number);
  if (!c) return res.status(404).json({ error: 'unknown computer' });
  if (!isOnline(c)) return res.status(409).json({ error: 'offline' });
  const action = String((req.body && req.body.action) || '');
  if (!COMMANDS.has(action)) return res.status(400).json({ error: 'unknown action' });
  // These need the current agent script: older versions run heavy work inline and can freeze the whole agent
  // (computer then shows as not connected) on slow or broken-WMI computers, or do not know the command at all.
  if (['sysinfo', 'nettest', 'getlog', 'restartfilter', 'diagnose'].includes(action) && !isCurrent(c)) {
    return res.status(409).json({ error: 'agent_outdated' });
  }
  if (action === 'uninstall') {
    // agents older than v3 do not know this command and would ignore it forever
    if (!c.stats || Number(c.stats.agent) < 3) return res.status(409).json({ error: 'agent_outdated' });
    c.uninstallAt = Date.now();
  }
  c.commands = (c.commands || []).slice(-4);
  c.commands.push({ action, at: Date.now() });
  if (!['sysinfo', 'nettest', 'getlog', 'diagnose'].includes(action)) addEvent(c.number, 'cmd', 'פקודה: ' + action);
  console.log(`[dash] command ${action} queued for computer ${c.number}`);
  res.json({ ok: true });
});

// ---- network test endpoints (agent only; same key as the heartbeat) ----
const agentAuth = (req, res, next) => {
  if (!AGENT_KEY) return res.status(503).json({ error: 'AGENT_KEY is not set on the server' });
  if (!safeEq(req.get('x-agent-key') || '', AGENT_KEY)) return res.status(401).json({ error: 'bad agent key' });
  next();
};
router.get('/agent/ping', agentAuth, (_req, res) => { res.set('Cache-Control', 'no-store'); res.json({ t: Date.now() }); });
router.get('/agent/speedtest', agentAuth, (req, res) => {
  const kb = Math.max(16, Math.min(2048, parseInt(req.query.kb, 10) || 256));
  res.set({ 'Cache-Control': 'no-store', 'Content-Type': 'application/octet-stream', 'Content-Length': String(kb * 1024) });
  res.end(crypto.randomBytes(kb * 1024)); // incompressible, so proxies/compression cannot inflate the result
});
router.post('/agent/speedtest-up', agentAuth, express.raw({ type: '*/*', limit: '600kb' }), (req, res) => {
  res.set('Cache-Control', 'no-store'); res.json({ bytes: Buffer.isBuffer(req.body) ? req.body.length : 0 });
});

// Repairs: only ids from the FIXES whitelist; the agent re-checks the whitelist on its side too.
router.post('/computers/:number/fix', requireAuth, (req, res) => {
  const c = computers.get(req.params.number);
  if (!c) return res.status(404).json({ error: 'unknown computer' });
  if (!isOnline(c)) return res.status(409).json({ error: 'offline' });
  if (!isCurrent(c)) return res.status(409).json({ error: 'agent_outdated' });
  const ids = (Array.isArray(req.body && req.body.ids) ? req.body.ids : []).map(String).filter((x) => FIXES.has(x));
  if (!ids.length) return res.status(400).json({ error: 'no valid fix' });
  const uniq = [...new Set(ids)].slice(0, 6);
  c.fixes = (c.fixes || []).slice(-6);
  uniq.forEach((id) => c.fixes.push({ id, at: Date.now() }));
  c.fixResults = (c.fixResults || []);
  addEvent(c.number, 'cmd', 'תיקון מרחוק: ' + uniq.join(', '));
  res.json({ ok: true, ids: uniq });
});
router.get('/computers/:number/diag', requireAuth, (req, res) => {
  const c = computers.get(req.params.number);
  if (!c) return res.status(404).json({ error: 'unknown computer' });
  res.json({ diag: c.diag || null, diagAt: c.diagAt || null, fixResults: c.fixResults || [] });
});

// End one process on a computer (from the "פרטי מחשב" window). The agent re-checks
// that PID still belongs to that process name and refuses protected system processes.
router.post('/computers/:number/kill', requireAuth, (req, res) => {
  const c = computers.get(req.params.number);
  if (!c) return res.status(404).json({ error: 'unknown computer' });
  if (!isOnline(c)) return res.status(409).json({ error: 'offline' });
  if (!isCurrent(c)) return res.status(409).json({ error: 'agent_outdated' });
  const pid = Number(req.body && req.body.pid);
  const name = String((req.body && req.body.name) || '');
  if (!Number.isInteger(pid) || pid <= 4 || pid > 4194304) return res.status(400).json({ error: 'bad pid' });
  if (!/^[\w .()\-]{1,60}$/.test(name)) return res.status(400).json({ error: 'bad name' });
  c.kills = (c.kills || []).slice(-4);
  c.kills.push({ pid, name, at: Date.now() });
  addEvent(c.number, 'cmd', `סיום תהליך ${name} (${pid})`);
  console.log(`[dash] kill ${name} (${pid}) queued for computer ${c.number}`);
  res.json({ ok: true });
});

router.post('/computers/:number/name', requireAuth, (req, res) => {
  const c = computers.get(req.params.number);
  if (!c) return res.status(404).json({ error: 'unknown computer' });
  c.name = String((req.body && req.body.name) || '').slice(0, 60);
  scheduleSave();
  res.json({ ok: true });
});

router.delete('/computers/:number', requireAuth, (req, res) => {
  const c = computers.get(req.params.number);
  if (c && isOnline(c)) return res.status(409).json({ error: 'computer is online' });
  computers.delete(req.params.number);
  scheduleSave();
  res.json({ ok: true });
});

// One-click installer for Windows, with this server's URL and the agent key baked in.
router.get('/installer', requireAuth, (req, res) => {
  if (!AGENT_KEY) return res.status(503).json({ error: 'AGENT_KEY is not set on the server' });
  const server = process.env.PUBLIC_URL || `${req.protocol}://${req.get('host')}`;
  res.set('Content-Type', 'application/octet-stream');
  res.set('Content-Disposition', 'attachment; filename="sionyx-install.cmd"');
  res.send(buildInstaller({ server: server.replace(/\/$/, ''), key: AGENT_KEY, vncPassword: VNC_PASSWORD }));
});

// Agent heartbeat. Response carries a session token when the admin pressed "connect".
router.post('/agent/heartbeat', (req, res) => {
  if (!AGENT_KEY) return res.status(503).json({ error: 'AGENT_KEY is not set on the server' });
  if (!safeEq(req.get('x-agent-key') || '', AGENT_KEY)) return res.status(401).json({ error: 'bad agent key' });
  const body = req.body || {};
  const number = String(body.number || '').trim();
  if (!NUMBER_RE.test(number)) return res.status(400).json({ error: 'bad computer number' });

  const now = Date.now();
  let c = computers.get(number);
  if (!c) {
    c = { number, name: '', firstSeen: now, pending: null };
    computers.set(number, c);
    console.log(`[dash] new computer registered: ${number}`);
  }
  c.hostname = String(body.hostname || '').slice(0, 64);
  c.lastSeen = now;
  c.liveSinceBoot = true;   // seen alive since this server started (used so permanently-dead computers do not re-alert after every deploy)
  c.busy = !!body.busy;
  const st = cleanStats(body.stats);
  if (st) c.stats = st;
  // Only present when the agent just answered a "sysinfo" command (see
  // Get-SysInfo in sionyx-agent.ps1) - most heartbeats won't carry this.
  const si = cleanSysInfo(body.sysinfo);
  if (si) { c.sysinfo = si; c.sysinfoAt = now; }
  if (typeof body.rttMs === 'number' && body.rttMs >= 0 && body.rttMs < 60000) { c.rttMs = Math.round(body.rttMs); c.rttAt = now; }
  const ni = cleanNetInfo(body.netinfo);
  if (ni) { c.netinfo = ni; c.netinfoAt = now; }
  const og = body.outage;
  if (og && typeof og === 'object' && Number(og.secs) >= 20) {
    const CAUSE = { dns: 'שרת השמות (DNS) לא ענה', timeout: 'פסק זמן - אין תגובה מהשרת', no_route: 'אין נתיב לרשת או לשרת', tls: 'שגיאת הצפנה/תעודה (בדוק שעון המחשב וסינון)', proxy: 'בעיית פרוקסי', server: 'השרת עצמו לא היה זמין (עדכון/הפעלה מחדש)', auth: 'שגיאת הרשאה', other: 'סיבה לא ידועה' };
    const cause = CAUSE[og.cause] ? og.cause : 'other';
    const l = og.local && typeof og.local === 'object' ? og.local : null;
    c.lastOutage = {
      at: now, secs: Math.min(Math.round(Number(og.secs)), 7 * 86400), cause,
      msg: String(og.msg || '').slice(0, 120), heals: String(og.heals || '').slice(0, 400),
      local: l ? { adapter: !!l.adapter, ip: String(l.ip || '').slice(0, 45), gw: !!l.gw, inet: !!l.inet, dns: !!l.dns } : null,
    };
    const mins = Math.max(1, Math.round(c.lastOutage.secs / 60));
    const where = l ? (!l.adapter ? ' כרטיס הרשת לא פעיל.' : !l.gw ? ' הנתב לא ענה (בעיה ברשת המקומית).' : !l.inet ? ' הרשת המקומית תקינה אבל אין אינטרנט.' : '') : '';
    addEvent(c.number, 'info', `הייתה הפסקת תקשורת של ${mins} דקות. סיבה: ${CAUSE[cause]}.${where}${c.lastOutage.heals ? ' תיקון אוטומטי: ' + c.lastOutage.heals : ''}`);
  }
  const dg = cleanDiag(body.diag);
  if (dg) { c.diag = dg; c.diagAt = now; }
  const fr = cleanFixResults(body.fixResults);
  if (fr.length) {
    c.fixResults = (c.fixResults || []).concat(fr.map((r) => ({ ...r, at: now }))).slice(-12); c.fixAt = now;
    fr.forEach((r) => addEvent(c.number, 'info', `תיקון ${r.id}: ${r.ok ? 'הצליח' : 'נכשל'}${r.msg ? ' (' + r.msg + ')' : ''}`));
  }
  if (typeof body.logTail === 'string') { c.logTail = body.logTail.slice(-8000); c.logAt = now; }
  const kr = body.killResult;
  if (kr && typeof kr === 'object') {
    c.killResult = { pid: Number(kr.pid) || 0, name: String(kr.name || '').slice(0, 60), ok: !!kr.ok, msg: String(kr.msg || '').slice(0, 120) };
    c.killResultAt = now;
  }

  let session = null;
  if (c.pending) {
    if (now - c.pending.createdAt >= PENDING_TTL_MS) c.pending = null;
    else if (!c.busy) { session = c.pending.token; c.pending = null; }
  }
  const now2 = Date.now();
  const commands = (c.commands || []).filter((x) => now2 - x.at < COMMAND_TTL_MS).map((x) => x.action);
  c.commands = [];
  const kills = (c.kills || []).filter((x) => now2 - x.at < COMMAND_TTL_MS).map((x) => ({ pid: x.pid, name: x.name }));
  c.kills = [];
  const fixes = (c.fixes || []).filter((x) => now2 - x.at < COMMAND_TTL_MS).map((x) => x.id);
  c.fixes = [];
  scheduleSave();
  res.json({ session, commands, kills, fixes });
});

// The agent calls this right before it deletes itself from the computer: the computer is
// removed from the registry (so it does not stay in the dashboard as "off").
router.post('/agent/uninstalled', (req, res) => {
  if (!AGENT_KEY) return res.status(503).json({ error: 'AGENT_KEY is not set on the server' });
  if (!safeEq(req.get('x-agent-key') || '', AGENT_KEY)) return res.status(401).json({ error: 'bad agent key' });
  const number = String((req.body && req.body.number) || '').trim();
  if (!NUMBER_RE.test(number)) return res.status(400).json({ error: 'bad computer number' });
  computers.delete(number);
  scheduleSave();
  console.log(`[dash] computer ${number} uninstalled the agent and was removed`);
  res.json({ ok: true });
});

// =====================================================================================
// Events, 24h history, alerts, and durable state
// =====================================================================================
const HIST_STEP_MS = 2 * 60 * 1000;        // one history sample per computer every 2 minutes
const HIST_KEEP = 720;                      // = 24 hours
const EVENTS_KEEP = 300;
const events = [];                          // newest last: { t, number, type: down|up|cpu|cmd|info, msg }
const hist = new Map();                     // number -> [[t, cpu, ramPct, rttMs], ...]
const bootAt = Date.now();

function addEvent(number, type, msg) {
  events.push({ t: Date.now(), number: String(number || ''), type, msg: String(msg).slice(0, 200) });
  if (events.length > EVENTS_KEEP) events.splice(0, events.length - EVENTS_KEEP);
  scheduleHistSave();
}

// ---- optional alerts: Telegram bot and/or a generic webhook (set env vars on Render) ----
const TG_TOKEN = process.env.TELEGRAM_BOT_TOKEN || '';
const TG_CHAT = process.env.TELEGRAM_CHAT_ID || '';
const ALERT_WEBHOOK = process.env.ALERT_WEBHOOK_URL || '';
const alertsConfigured = () => !!((TG_TOKEN && TG_CHAT) || ALERT_WEBHOOK);
async function sendAlert(text) {
  const jobs = [];
  if (TG_TOKEN && TG_CHAT) {
    jobs.push(fetch(`https://api.telegram.org/bot${TG_TOKEN}/sendMessage`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: TG_CHAT, text }),
    }).then((r) => { if (!r.ok) throw new Error('telegram HTTP ' + r.status); }));
  }
  if (ALERT_WEBHOOK) {
    jobs.push(fetch(ALERT_WEBHOOK, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ text, content: text }),
    }).then((r) => { if (!r.ok) throw new Error('webhook HTTP ' + r.status); }));
  }
  const res = await Promise.allSettled(jobs);
  res.forEach((r) => { if (r.status === 'rejected') console.error('[dash] alert failed:', r.reason && r.reason.message); });
  return res.length > 0 && res.every((r) => r.status === 'fulfilled');
}

// ---- durable state: local file, plus Upstash Redis (free) when configured, so a Render deploy/restart
// no longer wipes the computer list, names, history and events ----
const KV_URL = (process.env.UPSTASH_REDIS_REST_URL || '').replace(/\/$/, '');
const KV_TOKEN = process.env.UPSTASH_REDIS_REST_TOKEN || '';
const kvOn = () => !!(KV_URL && KV_TOKEN);
async function kvGet(key) {
  const r = await fetch(`${KV_URL}/get/${key}`, { headers: { Authorization: `Bearer ${KV_TOKEN}` } });
  const j = await r.json(); return j && j.result ? JSON.parse(j.result) : null;
}
async function kvSet(key, val) {
  const r = await fetch(`${KV_URL}/set/${key}`, { method: 'POST', headers: { Authorization: `Bearer ${KV_TOKEN}` }, body: JSON.stringify(val) });
  if (!r.ok) throw new Error('kv HTTP ' + r.status);
}
const HIST_FILE = path.join(DATA_DIR, 'history.json');
let histTimer = null, kvCompAt = 0, kvHistAt = 0;
function saveHistNow() {
  const out = { events, hist: Object.fromEntries(hist) };
  try { fs.mkdirSync(DATA_DIR, { recursive: true }); fs.writeFileSync(HIST_FILE, JSON.stringify(out)); } catch (e) { console.error('[dash] history save failed:', e.message); }
  if (kvOn() && Date.now() - kvHistAt > 5 * 60 * 1000) { kvHistAt = Date.now(); kvSet('sionyx:history', out).catch((e) => console.error('[dash] kv history:', e.message)); }
}
function scheduleHistSave() { if (histTimer) return; histTimer = setTimeout(() => { histTimer = null; saveHistNow(); }, 60000); histTimer.unref(); }
function kvSaveComputers() {
  if (!kvOn() || Date.now() - kvCompAt < 2 * 60 * 1000) return;
  kvCompAt = Date.now();
  const list = [...computers.values()].map(({ number, name, hostname, firstSeen, lastSeen }) => ({ number, name, hostname, firstSeen, lastSeen }));
  kvSet('sionyx:computers', list).catch((e) => console.error('[dash] kv computers:', e.message));
}
function loadHistFile() {
  try {
    const o = JSON.parse(fs.readFileSync(HIST_FILE, 'utf8'));
    if (Array.isArray(o.events)) events.push(...o.events.slice(-EVENTS_KEEP));
    for (const [k, v] of Object.entries(o.hist || {})) if (Array.isArray(v)) hist.set(k, v.slice(-HIST_KEEP));
  } catch { /* first run */ }
}
loadHistFile();
if (kvOn()) {
  (async () => {
    try {
      const comps = await kvGet('sionyx:computers');
      let added = 0;
      for (const c of comps || []) if (c && c.number && !computers.has(c.number)) { computers.set(c.number, { ...c, busy: false, pending: null }); added++; }
      const h = await kvGet('sionyx:history');
      if (h && !events.length && !hist.size) {
        if (Array.isArray(h.events)) events.push(...h.events.slice(-EVENTS_KEEP));
        for (const [k, v] of Object.entries(h.hist || {})) if (Array.isArray(v)) hist.set(k, v.slice(-HIST_KEEP));
      }
      console.log(`[dash] restored ${added} computer(s) from Upstash`);
    } catch (e) { console.error('[dash] Upstash restore failed:', e.message); }
  })();
}

// ---- monitor: connection state changes -> events/alerts, and 24h history samples ----
let lastSample = 0;
async function monitorTick() {
  const now = Date.now();
  const downs = [], ups = [], hots = [];
  for (const c of computers.values()) {
    if (!c.lastSeen) continue;
    const age = now - c.lastSeen;
    if (age >= DOWN_MS && !c.downAlerted && c.liveSinceBoot && now - bootAt > DOWN_MS) {       // grace after a server restart: agents need time to come back
      c.downAlerted = true; c.downSince = c.lastSeen; c.hiSince = null;
      addEvent(c.number, 'down', 'המחשב לא מחובר כבר 5 דקות'); downs.push(c);
    } else if (age < ONLINE_MS && c.downAlerted) {
      c.downAlerted = false;
      const mins = Math.max(1, Math.round((now - (c.downSince || now)) / 60000));
      addEvent(c.number, 'up', `המחשב חזר לאחר כ-${mins} דקות`); ups.push({ c, mins });
    }
    const cpu = c.stats && c.stats.cpuPct;
    if (age < ONLINE_MS && cpu != null && cpu >= 90) {
      c.hiSince = c.hiSince || now;
      if (now - c.hiSince >= 10 * 60 * 1000 && !c.hiAlerted) { c.hiAlerted = true; addEvent(c.number, 'cpu', `עומס מעבד גבוה (${cpu}%) כבר 10 דקות`); hots.push(c); }
    } else if (cpu != null && cpu < 70) { c.hiSince = null; c.hiAlerted = false; }
  }
  if (now - lastSample >= HIST_STEP_MS) {
    lastSample = now;
    for (const c of computers.values()) {
      if (!isOnline(c) || !c.stats) continue;
      const st = c.stats;
      const ram = st.ramTotalGb && st.ramFreeGb != null ? Math.round((st.ramTotalGb - st.ramFreeGb) / st.ramTotalGb * 100) : null;
      const arr = hist.get(c.number) || []; arr.push([now, st.cpuPct, ram, c.rttMs != null ? c.rttMs : null]);
      if (arr.length > HIST_KEEP) arr.splice(0, arr.length - HIST_KEEP);
      hist.set(c.number, arr);
    }
    scheduleHistSave();
  }
  kvSaveComputers();
  // one batched message per tick; several computers down together usually means a network/power problem, not 5 separate faults
  const lines = [];
  if (downs.length >= 3) lines.push(`\u26A0\uFE0F ${downs.length} מחשבים לא מחוברים: ${downs.map((c) => c.number).join(', ')}\nייתכן שהבעיה ברשת, בחשמל או בשרת.`);
  else downs.forEach((c) => lines.push(`\u274C מחשב ${c.number}${c.name ? ' (' + c.name + ')' : ''} לא מחובר כבר 5 דקות`));
  ups.forEach(({ c, mins }) => lines.push(`\u2705 מחשב ${c.number}${c.name ? ' (' + c.name + ')' : ''} חזר אחרי כ-${mins} דקות`));
  hots.forEach((c) => lines.push(`\u{1F525} מחשב ${c.number}: מעבד ${c.stats.cpuPct}% כבר 10 דקות`));
  if (lines.length && alertsConfigured()) await sendAlert('SIONYX\n' + lines.join('\n'));
}
const monitorTimer = setInterval(() => { monitorTick().catch((e) => console.error('[dash] monitor:', e.message)); }, 15000);
monitorTimer.unref();

router.get('/events', requireAuth, (req, res) => {
  const n = Math.max(1, Math.min(300, parseInt(req.query.limit, 10) || 100));
  res.json({ events: events.slice(-n).reverse(), alerts: { configured: alertsConfigured(), telegram: !!(TG_TOKEN && TG_CHAT), webhook: !!ALERT_WEBHOOK, durable: kvOn() } });
});
router.get('/computers/:number/history', requireAuth, (req, res) => {
  res.json({ step: HIST_STEP_MS, samples: hist.get(req.params.number) || [] });
});
router.get('/computers/:number/log', requireAuth, (req, res) => {
  const c = computers.get(req.params.number);
  if (!c) return res.status(404).json({ error: 'unknown computer' });
  res.json({ text: c.logTail || '', at: c.logAt || null });
});
router.post('/alerts/test', requireAuth, async (_req, res) => {
  if (!alertsConfigured()) return res.status(409).json({ error: 'not_configured' });
  const ok = await sendAlert('SIONYX: הודעת בדיקה - ההתראות עובדות \u2705');
  res.status(ok ? 200 : 502).json({ ok });
});

module.exports = function mount(app) {
  if (!DASHBOARD_PASSWORD) console.warn('[dash] WARNING: DASHBOARD_PASSWORD is not set - dashboard login is disabled');
  if (!AGENT_KEY) console.warn('[dash] WARNING: AGENT_KEY is not set - agents cannot register');
  app.use('/api', router);
  app.get('/dashboard', (_req, res) => res.set({ 'X-Frame-Options': 'DENY', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer' }).sendFile(path.join(__dirname, 'public', 'dashboard.html')));
  app.get('/sionyx-agent.ps1', (_req, res) => {
    res.type('text/plain; charset=utf-8').sendFile(path.join(__dirname, 'public', 'sionyx-agent.ps1'));
  });
};
