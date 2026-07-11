// acp-byok-repro.mjs
//
// Self-contained, IDE-independent reproduction for: BYOK (COPILOT_PROVIDER_*) is
// configured, but `copilot --acp --stdio` still gates `session/new` on a GitHub
// login (`-32000 Authentication required`) — even though `copilot -p` with the
// IDENTICAL env works login-free.
//
// It speaks newline-delimited JSON-RPC 2.0 to `copilot --acp --stdio`, exactly
// like an ACP client (Zed / IntelliJ) does, so it proves the behavior is in the
// CLI's ACP server and NOT in IntelliJ.
//
// Upstream tracking issue: https://github.com/github/copilot-cli/issues/4016
//
// USAGE (PowerShell on the gov-pilot VM), with the SAME env you use for BYOK:
//   $env:COPILOT_PROVIDER_BASE_URL = 'https://<APIM_HOST>/openai'
//   $env:COPILOT_PROVIDER_TYPE     = 'azure'
//   $env:COPILOT_PROVIDER_API_KEY  = '<APIM_SUBSCRIPTION_KEY>'
//   $env:COPILOT_MODEL             = 'gpt-5.1'
//   node .\scripts\acp-byok-repro.mjs
//
// Optionally point at a specific copilot binary (e.g. a pinned 1.0.61 install):
//   node .\scripts\acp-byok-repro.mjs "C:\path\to\copilot.exe"
//
// Nothing secret is printed: the API key is redacted in the env echo.

import { spawn } from 'node:child_process';
import { once } from 'node:events';

const copilotPath = process.argv[2] || 'copilot';
const TIMEOUT_MS = 30_000;

function redact(v) {
  if (!v) return '(unset)';
  if (v.length <= 8) return '***';
  return `${v.slice(0, 4)}…${v.slice(-2)} (len=${v.length})`;
}

console.log('=== ACP BYOK repro ===');
console.log('copilot binary :', copilotPath);
console.log('node version   :', process.version);
console.log('platform       :', `${process.platform} ${process.arch}`);
console.log('--- BYOK env (as seen by this process) ---');
console.log('COPILOT_PROVIDER_BASE_URL :', process.env.COPILOT_PROVIDER_BASE_URL || '(unset)');
console.log('COPILOT_PROVIDER_TYPE     :', process.env.COPILOT_PROVIDER_TYPE || '(unset)');
console.log('COPILOT_PROVIDER_API_KEY  :', redact(process.env.COPILOT_PROVIDER_API_KEY));
console.log('COPILOT_MODEL             :', process.env.COPILOT_MODEL || '(unset)');
console.log('COPILOT_OFFLINE           :', process.env.COPILOT_OFFLINE || '(unset)');
console.log('COPILOT_GITHUB_TOKEN      :', redact(process.env.COPILOT_GITHUB_TOKEN));
console.log('GH_TOKEN                  :', redact(process.env.GH_TOKEN));
console.log('GITHUB_TOKEN              :', redact(process.env.GITHUB_TOKEN));
console.log('==========================================\n');

const child = spawn(copilotPath, ['--acp', '--stdio'], {
  stdio: ['pipe', 'pipe', 'pipe'],
  env: process.env,
  shell: false,
});

child.on('error', (err) => {
  console.error('FAILED to spawn copilot:', err.message);
  console.error('If using a bare "copilot", ensure it is on PATH, or pass the full');
  console.error('path to copilot.exe as the first argument.');
  process.exit(1);
});

let stderrBuf = '';
child.stderr.on('data', (d) => { stderrBuf += d.toString(); });

// --- minimal newline-delimited JSON-RPC plumbing ---
let nextId = 0;
const pending = new Map();
let rxBuf = '';

child.stdout.on('data', (chunk) => {
  rxBuf += chunk.toString();
  let nl;
  while ((nl = rxBuf.indexOf('\n')) >= 0) {
    const line = rxBuf.slice(0, nl).trim();
    rxBuf = rxBuf.slice(nl + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { console.log('[non-JSON stdout]', line); continue; }
    if (msg.id !== undefined && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    } else if (msg.method) {
      // Agent -> client request/notification (e.g. session/update). Log it; if it
      // has an id, answer with an empty result so the agent isn't left hanging.
      console.log(`[agent->client] ${msg.method}`, JSON.stringify(msg.params ?? {}));
      if (msg.id !== undefined) send({ jsonrpc: '2.0', id: msg.id, result: {} });
    }
  }
});

function send(obj) {
  child.stdin.write(JSON.stringify(obj) + '\n');
}

function rpc(method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`timeout waiting for response to "${method}" (id=${id})`));
    }, TIMEOUT_MS);
    pending.set(id, (msg) => { clearTimeout(timer); resolve(msg); });
    console.log(`\n>>> ${method} (id=${id})`);
    send({ jsonrpc: '2.0', id, method, params });
  });
}

function summarize(tag, msg) {
  if (msg.error) {
    console.log(`<<< ${tag} ERROR: code=${msg.error.code} message=${JSON.stringify(msg.error.message)}`);
  } else {
    console.log(`<<< ${tag} OK`);
  }
  console.log(JSON.stringify(msg, null, 2));
}

async function main() {
  // 1) initialize — reveals agentInfo.version and the advertised authMethods.
  const init = await rpc('initialize', {
    protocolVersion: 1,
    clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } },
  });
  summarize('initialize', init);

  const authMethods = init?.result?.authMethods;
  const version = init?.result?.agentInfo?.version;
  console.log(`\n--- agent version: ${version ?? 'unknown'} ---`);
  console.log(`--- authMethods advertised: ${JSON.stringify(authMethods ?? null)} ---`);

  // 2) session/new — THIS is the operation that fails with
  //    -32000 "Authentication required" when BYOK is set but no GitHub login.
  const cwd = process.cwd();
  let sess;
  try {
    sess = await rpc('session/new', { cwd, mcpServers: [] });
  } catch (e) {
    console.log(`\n!!! session/new threw: ${e.message}`);
    console.log('If this timed out, the agent likely opened an interactive login');
    console.log('flow on a side channel instead of answering the RPC.');
    finish(2);
    return;
  }
  summarize('session/new', sess);

  console.log('\n=== VERDICT ===');
  if (sess.error && /auth/i.test(sess.error.message || '')) {
    console.log('REPRODUCED: session/new was rejected with an auth error while BYOK');
    console.log('(COPILOT_PROVIDER_*) is configured. The ACP server is gating the');
    console.log('session on a GitHub login independent of the custom provider.');
    finish(0);
  } else if (sess.error) {
    console.log(`session/new failed with a NON-auth error: code=${sess.error.code}`);
    finish(0);
  } else {
    console.log('session/new SUCCEEDED — ACP BYOK session created without a login gate.');
    console.log('(If you expected the bug, it is NOT reproduced on this build/env.)');
    finish(0);
  }
}

function finish(code) {
  if (stderrBuf.trim()) {
    console.log('\n--- copilot stderr ---');
    console.log(stderrBuf.trim());
  }
  try { child.stdin.end(); } catch {}
  child.kill();
  process.exit(code);
}

main().catch(async (e) => {
  console.error('\nUNEXPECTED ERROR:', e.message);
  finish(3);
});

// Guard: if copilot exits on its own, report it.
once(child, 'exit').then(([code, signal]) => {
  if (code !== null && code !== 0) {
    console.log(`\n[copilot exited early] code=${code} signal=${signal}`);
    if (stderrBuf.trim()) {
      console.log('--- copilot stderr ---');
      console.log(stderrBuf.trim());
    }
  }
});
