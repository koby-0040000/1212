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

const ONLINE_MS = 25000;            // no heartbeat for this long => offline
const COOKIE = 'sx_dash';
const COOKIE_TTL_MS = 12 * 3600 * 1000;
const PENDING_TTL_MS = 2 * 60 * 1000; // a connect request the agent must pick up within this time
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const DATA_FILE = path.join(DATA_DIR, 'computers.json');
const COMMANDS = new Set(['cad', 'lock', 'logoff', 'restart', 'shutdown', 'uninstall', 'sysinfo', 'nettest']);

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
const view = (c) => ({
  number: c.number, name: c.name || '', hostname: c.hostname || '',
  online: isOnline(c), busy: isOnline(c) && !!c.busy,
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
router.use(express.json({ limit: '10kb' }));

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
  c.commands = (c.commands || []).slice(-4);
  c.commands.push({ action, at: Date.now() });
  if (action === 'uninstall') {
    // agents older than v3 do not know this command and would ignore it forever
    if (!c.stats || Number(c.stats.agent) < 3) return res.status(409).json({ error: 'agent_outdated' });
    c.uninstallAt = Date.now();
  }
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

// End one process on a computer (from the "פרטי מחשב" window). The agent re-checks
// that PID still belongs to that process name and refuses protected system processes.
router.post('/computers/:number/kill', requireAuth, (req, res) => {
  const c = computers.get(req.params.number);
  if (!c) return res.status(404).json({ error: 'unknown computer' });
  if (!isOnline(c)) return res.status(409).json({ error: 'offline' });
  if (!c.stats || Number(c.stats.agent) < 4) return res.status(409).json({ error: 'agent_outdated' });
  const pid = Number(req.body && req.body.pid);
  const name = String((req.body && req.body.name) || '');
  if (!Number.isInteger(pid) || pid <= 4 || pid > 4194304) return res.status(400).json({ error: 'bad pid' });
  if (!/^[\w .()\-]{1,60}$/.test(name)) return res.status(400).json({ error: 'bad name' });
  c.kills = (c.kills || []).slice(-4);
  c.kills.push({ pid, name, at: Date.now() });
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
  scheduleSave();
  res.json({ session, commands, kills });
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

module.exports = function mount(app) {
  if (!DASHBOARD_PASSWORD) console.warn('[dash] WARNING: DASHBOARD_PASSWORD is not set - dashboard login is disabled');
  if (!AGENT_KEY) console.warn('[dash] WARNING: AGENT_KEY is not set - agents cannot register');
  app.use('/api', router);
  app.get('/dashboard', (_req, res) => res.sendFile(path.join(__dirname, 'public', 'dashboard.html')));
  app.get('/sionyx-agent.ps1', (_req, res) => {
    res.type('text/plain; charset=utf-8').sendFile(path.join(__dirname, 'public', 'sionyx-agent.ps1'));
  });
};
