import { spawn, spawnSync } from 'node:child_process';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

function requireCondition(condition, message) {
  if (!condition) throw new Error(message);
}

function quote(value) {
  return `"${value.replaceAll('"', '""')}"`;
}

function startSession(executable, environment, directory) {
  const argumentsList = ['--acp', '--stdio', '--no-custom-instructions', '--disable-builtin-mcps',
    '--allow-all-tools', '--deny-tool=shell', '--deny-tool=write', '--deny-tool=url', '--available-tools=',
    '--no-ask-user', '--log-level=none', '--no-remote', '--no-remote-export'];
  const windowsCommand = [executable, ...argumentsList].map(quote).join(' ');
  const child = spawn(process.platform === 'win32' ? process.env.ComSpec : executable,
    process.platform === 'win32' ? ['/d', '/s', '/c', `"${windowsCommand}"`] : argumentsList, {
      cwd: directory, env: environment, windowsHide: true, windowsVerbatimArguments: process.platform === 'win32',
      stdio: ['pipe', 'pipe', 'pipe'],
    });
  const pending = new Map();
  const updates = [];
  let nextId = 1;
  let failed = false;
  const reader = createInterface({ input: child.stdout });
  const rejectPending = () => {
    failed = true;
    for (const request of pending.values()) { clearTimeout(request.timer); request.reject(new Error('CLI session terminated')); }
    pending.clear();
  };
  child.on('error', rejectPending);
  child.on('exit', rejectPending);
  child.stdin.on('error', rejectPending);
  child.stderr.resume();
  reader.on('line', line => {
    if (line.length > 1048576) { rejectPending(); return; }
    let message;
    try { message = JSON.parse(line); } catch { return; }
    if (message.method === 'session/update' && message.params?.update?.sessionUpdate === 'agent_message_chunk') {
      if (updates.length >= 1000) { rejectPending(); return; }
      updates.push(message.params);
    }
    if (message.method && message.id !== undefined) {
      child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'Client capabilities disabled' } })}\n`);
    } else if (pending.has(message.id)) {
      const request = pending.get(message.id);
      clearTimeout(request.timer);
      pending.delete(message.id);
      request.resolve(message);
    }
  });
  return {
    child, updates,
    alive: () => !failed && child.exitCode === null && child.signalCode === null,
    rpc: (method, params) => new Promise((resolveRequest, reject) => {
      if (failed) { reject(new Error('CLI session is not running')); return; }
      const id = nextId++;
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`ACP ${method} timed out`)); }, 60000);
      pending.set(id, { resolve: resolveRequest, reject, timer });
      child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
    }),
    close: () => {
      reader.close();
      rejectPending();
      if (child.exitCode === null && child.signalCode === null) {
        if (process.platform === 'win32') spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
        else child.kill('SIGKILL');
      }
    },
  };
}

function readReceipts(path) {
  if (!existsSync(path)) return [];
  requireCondition(statSync(path).size <= 65536, 'Credential receipt limit exceeded');
  const rows = readFileSync(path, 'utf8').trim().split(/\r?\n/).filter(Boolean).map(line => JSON.parse(line));
  for (const row of rows) {
    requireCondition(Object.keys(row).sort().join(',') === 'acquiredAt,expiresOn,fingerprint' &&
      Number.isSafeInteger(row.acquiredAt) && Number.isSafeInteger(row.expiresOn) && /^[a-f0-9]{64}$/.test(row.fingerprint),
    'Invalid credential receipt');
  }
  return rows;
}

export async function runCredentialSession(config, hooks = {}) {
  const now = hooks.now || (() => Math.floor(Date.now() / 1000));
  const report = hooks.report || (() => {});
  const sessions = [];
  const wireApis = config.wireApis || ['responses', 'completions'];
  requireCondition(wireApis.length > 0 && wireApis.length <= 2 && new Set(wireApis).size === wireApis.length &&
    wireApis.every(wire => ['responses', 'completions'].includes(wire)), 'Unsupported wire formats');
  const environment = { ...config.environment };
  requireCondition(environment.COPILOT_PROVIDER_TYPE === 'azure' && environment.COPILOT_PROVIDER_API_KEY_COMMAND &&
    !environment.COPILOT_PROVIDER_API_KEY && !environment.COPILOT_PROVIDER_BEARER_TOKEN && !environment.COPILOT_PROVIDER_HEADERS &&
    environment.COPILOT_OFFLINE === 'true' && !environment.NODE_TLS_REJECT_UNAUTHORIZED, 'Unsafe provider environment');
  const baseline = new Map();
  let resumeAt = 0;
  const abortSessions = () => { for (const session of sessions) session.close(); };
  hooks.signal?.addEventListener('abort', abortSessions, { once: true });
  async function prompt(session, wire, afterExpiry) {
    requireCondition(session.alive(), 'CLI process did not survive the expiry window');
    const before = readReceipts(config.receiptPath).length;
    session.updates.length = 0;
    const sentAt = now();
    const response = await session.rpc('session/prompt', {
      sessionId: session.sessionId,
      prompt: [{ type: 'text', text: afterExpiry ? 'Return the next fixture response.' : 'Return the fixture response.' }],
    });
    requireCondition(!response.error && response.result?.stopReason === 'end_turn', 'ACP fixture prompt failed');
    const proof = config.proofs[wire];
    requireCondition(/^cli-proof-[a-f0-9]{32}$/.test(proof), 'Invalid fixture proof');
    const text = session.updates.filter(update => update.sessionId === session.sessionId)
      .map(update => update.update.content?.text || '').join('');
    const matched = text.match(new RegExp(`${proof}:([0-9]{10,})`));
    requireCondition(matched, 'Gateway response proof missing');
    const gatewayTime = Number(matched[1]);
    requireCondition(gatewayTime >= sentAt - 5 && gatewayTime <= now() + 5, 'Gateway proof is stale or clocks disagree');
    const receipts = readReceipts(config.receiptPath).slice(before);
    requireCondition(receipts.length > 0, 'CLI did not reacquire its credential');
    const receipt = receipts.at(-1);
    requireCondition(receipt.acquiredAt >= sentAt - 5 && receipt.expiresOn > now() + 60, 'Token receipt is stale or near expiry');
    if (afterExpiry) {
      const first = baseline.get(wire);
      requireCondition(now() >= resumeAt && gatewayTime > first.expiresOn && receipt.acquiredAt > first.expiresOn &&
        receipt.expiresOn > first.expiresOn && receipt.fingerprint !== first.fingerprint,
      'A newly acquired token after real expiry was not established');
    } else {
      baseline.set(wire, receipt);
    }
    report({ test: 'vm-copilot-expiry-turn', wireApi: wire, phase: afterExpiry ? 'after-expiry' : 'before-expiry',
      helperCalls: receipts.length, responseProofMatches: true, sameProcess: true, sameSession: true,
      initialTokenExpired: afterExpiry, renewedToken: afterExpiry, backendCalled: false, passed: true });
  }
  try {
    requireCondition(!hooks.signal?.aborted, 'Expiry test was cancelled');
    for (const wire of wireApis) {
      const session = startSession(config.executable, { ...environment, COPILOT_PROVIDER_WIRE_API: wire }, config.directory);
      sessions.push(session);
      const initialized = await session.rpc('initialize', { protocolVersion: 1,
        clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false } });
      requireCondition(!initialized.error && /^1\.0\.85(?:\.|$)/.test(initialized.result?.agentInfo?.version || ''), 'Unverified ACP client version');
      const created = await session.rpc('session/new', { cwd: config.directory, mcpServers: [] });
      requireCondition(!created.error && typeof created.result?.sessionId === 'string', 'ACP session creation failed');
      session.sessionId = created.result.sessionId;
      session.wireApi = wire;
      await prompt(session, wire, false);
    }
    resumeAt = Math.max(...[...baseline.values()].map(receipt => receipt.expiresOn)) + 10;
    const waitSeconds = resumeAt - now();
    requireCondition(waitSeconds > 0 && waitSeconds <= 6600, 'Token expiry exceeds the approved test window');
    report({ test: 'vm-copilot-expiry-wait', resumeAtUtc: new Date(resumeAt * 1000).toISOString(),
      remainingSeconds: waitSeconds, wireFormats: wireApis.length, sameProcessesRunning: sessions.every(session => session.alive()) });
    requireCondition(typeof hooks.pauseUntil === 'function', 'An explicit bounded expiry wait controller is required');
    await hooks.pauseUntil(resumeAt);
    requireCondition(now() >= resumeAt, 'Real token expiry has not elapsed');
    for (const session of sessions) await prompt(session, session.wireApi, true);
    const result = { test: 'vm-copilot-expiry-session', passed: true, wireFormats: wireApis.length,
      sameProcesses: true, sameSessions: true, actualExpiryTested: true, backendCalled: false };
    report(result);
    return result;
  } finally {
    hooks.signal?.removeEventListener('abort', abortSessions);
    for (const session of sessions) session.close();
  }
}

async function main() {
  const input = createInterface({ input: process.stdin });
  const iterator = input[Symbol.asyncIterator]();
  const first = await iterator.next();
  requireCondition(!first.done, 'Missing session configuration');
  const config = JSON.parse(first.value);
  config.environment = { ...process.env };
  requireCondition(new URL(config.environment.COPILOT_PROVIDER_BASE_URL).protocol === 'https:', 'Live expiry requires HTTPS');
  const send = row => process.stdout.write(`${JSON.stringify(row)}\n`);
  const abort = () => { throw new Error('Expiry controller disconnected'); };
  const controller = new AbortController();
  const deadline = setTimeout(() => controller.abort(), 6900000);
  controller.signal.addEventListener('abort', () => input.close(), { once: true });
  try {
    await runCredentialSession(config, {
      report: send,
      signal: controller.signal,
      pauseUntil: async resumeAt => {
        send({ test: 'expiry-window-control', action: 'close' });
        const closed = await iterator.next();
        if (closed.done || JSON.parse(closed.value).action !== 'closed') abort();
        await new Promise((resolveWait, reject) => {
          const cleanup = () => {
            clearTimeout(timer);
            process.stdin.off('end', disconnected);
            controller.signal.removeEventListener('abort', disconnected);
          };
          const timer = setTimeout(() => { cleanup(); resolveWait(); }, Math.max(0, resumeAt * 1000 - Date.now()));
          const disconnected = () => { cleanup(); reject(new Error('Expiry controller disconnected')); };
          process.stdin.once('end', disconnected);
          controller.signal.addEventListener('abort', disconnected, { once: true });
          if (controller.signal.aborted) disconnected();
        });
        send({ test: 'expiry-window-control', action: 'open' });
        const opened = await iterator.next();
        if (opened.done || JSON.parse(opened.value).action !== 'opened') abort();
      },
    });
  } finally { clearTimeout(deadline); input.close(); process.stdin.pause(); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(() => {
    process.stdout.write(`${JSON.stringify({ test: 'vm-copilot-expiry-session', passed: false, failure: 'session-or-renewal-check-failed' })}\n`);
    process.exitCode = 1;
  });
}