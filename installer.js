'use strict';
// Builds the one-click Windows installer (.cmd) with the server URL and agent
// key baked in, and the agent script embedded.
const fs = require('fs');
const path = require('path');

function psQuote(s) { return String(s).replace(/'/g, "''"); }

function buildInstaller({ server, key, vncPassword = '', dir = __dirname }) {
  const template = fs.readFileSync(path.join(dir, 'installer-template.cmd'), 'utf8');
  const agent = fs.readFileSync(path.join(dir, 'public', 'sionyx-agent.ps1'));
  const out = template
    .replace('__SERVER__', () => psQuote(server))
    .replace('__KEY__', () => psQuote(key))
    .replace('__VNCPASS__', () => psQuote(vncPassword))
    .replace('__AGENT_B64__', () => agent.toString('base64'));
  return out.replace(/\r?\n/g, '\r\n'); // cmd is happiest with CRLF
}

module.exports = { buildInstaller };
