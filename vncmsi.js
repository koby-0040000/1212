'use strict';
// Serves the TightVNC MSI installers to the kiosks, so the one-click installer
// never needs to reach tightvnc.com (blocked by NetFree). This server (on Render,
// no filter) downloads each MSI once from tightvnc.com and caches it in memory.
// If you drop tightvnc-setup-64bit.msi / -32bit.msi into public/, those win.
const https = require('https');
const fs = require('fs');
const path = require('path');

const VERSIONS = (process.env.TIGHTVNC_VERSIONS || '2.8.88,2.8.87,2.8.85').split(',');
const cache = {};      // arch -> Buffer
const pending = {};    // arch -> Promise

function get(url, redirects = 5) {
  return new Promise((resolve, reject) => {
    https.get(url, { headers: { 'User-Agent': 'sionyx-relay' } }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location && redirects > 0) {
        res.resume();
        return resolve(get(new URL(res.headers.location, url).toString(), redirects - 1));
      }
      if (res.statusCode !== 200) { res.resume(); return reject(new Error('HTTP ' + res.statusCode)); }
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve(Buffer.concat(chunks)));
    }).on('error', reject).setTimeout(60000, function () { this.destroy(new Error('timeout')); });
  });
}

async function load(arch) {
  if (cache[arch]) return cache[arch];
  if (pending[arch]) return pending[arch];
  pending[arch] = (async () => {
    for (const v of VERSIONS) {
      const url = `https://www.tightvnc.com/download/${v}/tightvnc-${v}-gpl-setup-${arch}.msi`;
      try {
        const buf = await get(url);
        // MSI files start with the OLE2 signature; also reject tiny error pages
        if (buf.length > 500000 && buf[0] === 0xD0 && buf[1] === 0xCF) {
          console.log(`[vncmsi] cached ${arch} v${v} (${buf.length} bytes)`);
          return (cache[arch] = buf);
        }
        console.warn(`[vncmsi] ${url}: not an MSI`);
      } catch (e) { console.warn(`[vncmsi] ${url}: ${e.message}`); }
    }
    throw new Error('could not download TightVNC ' + arch);
  })().finally(() => { delete pending[arch]; });
  return pending[arch];
}

module.exports = function register(app) {
  // warm the cache so the first kiosk install is fast
  load('64bit').catch(() => {});
  app.get('/tightvnc-setup-:arch.msi', async (req, res) => {
    const arch = req.params.arch;
    if (arch !== '64bit' && arch !== '32bit') return res.status(404).end();
    const local = path.join(__dirname, 'public', `tightvnc-setup-${arch}.msi`);
    if (fs.existsSync(local)) return res.sendFile(local);
    try {
      const buf = await load(arch);
      res.set('Content-Type', 'application/octet-stream');
      res.set('Content-Length', String(buf.length));
      res.send(buf);
    } catch (e) { res.status(502).send('TightVNC download unavailable: ' + e.message); }
  });
};
