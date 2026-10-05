sionyx-vnc-relay
A tiny WebSocket relay (same job as `websockify`) plus a static
noVNC viewer page, used to remote-control
SIONYX kiosks over VNC even though:
the kiosks have no public IP / inbound port (they're behind normal NAT), and
the site's NetFree content filter does full TLS interception and blocks
every commercial remote-control tool that pins its own certificate
(RustDesk, AnyDesk, TeamViewer, the MeshCentral agent, ...).
Both sides of this relay talk plain `wss://` using the OS/browser trust
store (no pinning), the same way the kiosk's existing Firebase and
Understood-bridge traffic already does - which is why it gets through
NetFree where the others didn't.
`vnc.html` imports noVNC's `core/rfb.js` directly - it's vendored into
`public/novnc/core/` (copied as-is from `@novnc/novnc@1.7.0`, MPL-2.0,
https://github.com/novnc/noVNC) rather than pulled from a third-party CDN,
so there's no external dependency at serve time.
How it works
```
 Kiosk (SionyxKiosk.VncRelayService)          Admin's browser (vnc.html)
   TightVNC on 127.0.0.1:5900                        noVNC (RFB.js)
            │  raw VNC bytes                                │  RFB protocol
            ▼                                               ▼
     wss://.../agent/<token>   ───── this relay ─────  wss://.../viewer/<token>
```
`server.js` does not speak VNC at all - it just pairs the `agent` and
`viewer` WebSocket connections that share the same `<token>` and pipes
whatever bytes arrive on one straight to the other.
`<token>` is a one-time random string the dashboard generates per remote
session (see `sionyx-web`'s `requestVncSession`) and delivers to the kiosk
via Firebase and to the browser via the `vnc.html?token=...` link. It's a
shared room key, not a real auth system - treat each token as single-use
and short-lived.
Deploy (Render)
New Web Service on Render, connect this repo, Free plan.
Build command: `npm install` · Start command: `npm start`.
No environment variables required.
Once deployed, note the service URL (`https://<name>.onrender.com`) and
put it in `sionyx-web`'s VNC relay config and the kiosk's
`VncRelayUrl` setting.
Free-tier services on Render spin down after 15 minutes idle and take
about a minute to wake on the next connection - the same cold-start delay
SIONYX already handles for the Understood payment bridge.
Local dev
```
npm install
npm start   # listens on :3000
```

Transport fallback (NetFree)
Behind NetFree, `wss://` upgrades to this relay often get `418 Blocked by NetFree`
(or open and then carry no data), while plain HTTPS requests work. Both the kiosk
and `vnc.html` therefore try WebSocket first and fall back to HTTP long-polling
(`/rt/<role>/<token>/send|recv|close`) automatically - same rooms, same tokens,
and one side may be on WebSocket while the other is on HTTP.
Probe: a WebSocket is only trusted after `__relay_probe__` -> `__relay_probe_ack__`
round-trips. Clients opt in with `?probe=1`; until the probe succeeds the relay
routes/flushes nothing to that socket and lets a newcomer replace it (a "ghost"
connection NetFree ate can neither swallow data nor block the retry).
Clients without `?probe=1` (old builds, local relay) behave exactly as before.
Kiosk: `HttpRelayWebSocket.cs` implements `WebSocket` over HTTP so the existing
pump code is unchanged. Registry `VncRelayTransport` = `auto` (default) | `ws` | `http`.
Viewer: `public/relay-transport.js`. Append `?transport=http` (or `ws`) to
`vnc.html?token=...` to force one; the status line says "(HTTP - slower)" when on HTTP.


## Dashboard and computer registry (added in this repo)

Two addresses once deployed on Render:

- `https://<name>.onrender.com/health` returns `ok` when the server is up
  (`/` also says "SIONYX VNC Relay is up").
- `https://<name>.onrender.com/dashboard` is the admin dashboard: every computer
  that has the agent installed, active / off / in-control, and a **Connect** button
  that opens the noVNC viewer on that computer.

### Render environment variables

| Name | Required | Meaning |
|---|---|---|
| `DASHBOARD_PASSWORD` | yes | Password for `/dashboard` |
| `AGENT_KEY` | yes | Shared secret the agents send (`render.yaml` generates one) |
| `VNC_PASSWORD` | no | TightVNC password, added to the viewer link automatically |
| `DATA_DIR` | no | Where `computers.json` is kept (use a Render disk to survive restarts) |

### Installing the agent on a computer

1. Open `/dashboard`, press **Download installer** (`sionyx-install.cmd`; the server URL and
   agent key are already inside it).
2. Copy it to the computer and double-click. Accept the Windows admin prompt, type the
   computer number, press **Install**, done. A small graphical window (no black console) shows
   the progress step by step and the result. It installs a startup task and the computer shows up
   in the dashboard. On a computer that already has the agent, the number is pre-filled.

Re-running the installer updates the agent. TightVNC must be running on `127.0.0.1:5900`
for remote control (the dashboard shows "VNC: ready / not available" per computer).

Each card shows a status report: logged-in user, CPU, RAM, disk C:, uptime, IP, VNC.
A computer with no heartbeat for ~25 seconds shows as off. Agent log:
`C:\ProgramData\SionyxAgent\agent.log`.

**Remove from a computer:** in the dashboard pick "הסר תוכנה מהמחשב" in the command dropdown
(computer must be online, requires agent v3+ - re-run the installer once on older computers).
The agent notifies the server (the computer disappears from the list), then a one-time SYSTEM
task deletes the `SionyxAgent` scheduled task and `C:\ProgramData\SionyxAgent`. TightVNC and the
Ctrl+Alt+Del policy are left as-is. Manual removal:
`Unregister-ScheduledTask -TaskName SionyxAgent -Confirm:$false`.

How Connect works: the dashboard creates a one-time token, the agent receives it in its
next heartbeat response (within ~5s), bridges TightVNC to `/rt/agent/<token>`, and the
viewer page joins the same room. Nothing else in the relay changed.

### Commands and background operation

- The agent runs as a SYSTEM scheduled task at startup, so it works with nobody logged in and
  survives logout. The installer also sets TightVNC's service (`tvnserver`) to start automatically.
- Dashboard dropdown per computer: Ctrl+Alt+Del, lock, log off user, restart, shutdown, uninstall agent. Only this
  fixed list is accepted - the agent never runs arbitrary commands. A queued command expires after 60s.
- The viewer's existing **Ctrl+Alt+Del** button also works with this agent (control channel).
  The viewer's "elevated click" and "type text" buttons are not implemented by this agent.
- Ctrl+Alt+Del uses Windows `SendSAS`; the installer enables the required policy
  (`SoftwareSASGeneration=1`).

### Installer troubleshooting (lab computers)

The installer writes `C:\ProgramData\SionyxAgent\install.log` (PowerShell version, language mode, every step and
the exact error). If installation fails, open that file first.

The agent is started through `C:\ProgramData\SionyxAgent\run-agent.cmd`, which runs the agent with
`powershell -Command` instead of `powershell -File`. Reason: Group Policy / AppLocker execution policy on lab
computers blocks `.ps1` *files* (child process exit code 1) even with `-ExecutionPolicy Bypass`.
If `Register-ScheduledTask` fails, the installer falls back to `schtasks.exe`.
