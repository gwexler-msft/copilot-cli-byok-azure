import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { createServer as createTlsServer } from 'node:https';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { runCredentialSession } from '../copilot-credential-session.mjs';
import { classifyResponse, observeInference } from '../copilot-inference-diagnostic.mjs';

const scriptPath = fileURLToPath(import.meta.url);

if (process.argv[2] === '--azure-fixture') {
  const statePath = process.env.BYOK_AGENT_FIXTURE;
  const state = JSON.parse(readFileSync(statePath, 'utf8'));
  const command = process.argv.slice(3);
  if (process.env.AZURE_CONFIG_DIR !== state.cache) process.exit(2);
  if (command[0] === 'cloud' && command[1] === 'show') {
    process.stdout.write('AzureUSGovernment\n');
  } else if (command[0] === 'account' && command[1] === 'show') {
    process.stdout.write(JSON.stringify({ tenantId: state.tenantId, environmentName: 'AzureUSGovernment', user: { type: 'user', name: 'fixture-user' } }) + '\n');
  } else if (command[0] === 'account' && command[1] === 'get-access-token') {
    if (command[command.indexOf('--tenant') + 1] !== state.tenantId || command[command.indexOf('--scope') + 1] !== `${state.appId}/.default`) process.exit(2);
    appendFileSync(`${statePath}.calls`, 'called\n');
    if (state.fail) { process.stderr.write('Synthetic renewal failure.\n'); process.exit(1); }
    process.stdout.write(JSON.stringify({ tenant: state.tenantId, expires_on: Math.floor(Date.now() / 1000) + 3600,
      accessToken: `synthetic.${randomUUID().replaceAll('-', '')}.fixture` }) + '\n');
  } else process.exit(2);
  process.exit(0);
}

if (process.argv[2] === '--credential-fixture') {
  const statePath = process.argv[3];
  const state = JSON.parse(readFileSync(statePath, 'utf8'));
  appendFileSync(`${statePath}.calls`, 'called\n');
  if (state.fail) {
    process.stderr.write('Synthetic credential acquisition failed.\n');
    process.exit(1);
  }
  const credential = `synthetic.${randomUUID().replaceAll('-', '')}.fixture`;
  if (state.evidence) {
    appendFileSync(`${statePath}.receipts`, `${JSON.stringify({ acquiredAt: state.evidence.now, expiresOn: state.evidence.expires,
      fingerprint: createHash('sha256').update(credential).digest('hex') })}\n`);
  }
  process.stdout.write(`${credential}\n`);
  process.exit(0);
}

function quote(value) {
  return process.platform === 'win32'
    ? `"${value.replaceAll('"', '""')}"`
    : `'${value.replaceAll("'", "'\\''")}'`;
}

function resolveCli() {
  if (process.env.COPILOT_TEST_EXECUTABLE) return process.env.COPILOT_TEST_EXECUTABLE;
  if (process.platform !== 'win32') return 'copilot';
  const candidates = spawnSync('where.exe', ['copilot.exe', 'copilot.cmd'], { encoding: 'utf8', windowsHide: true });
  const executable = (candidates.stdout || '').split(/\r?\n/).find(candidate => /\.(exe|cmd)$/i.test(candidate.trim()));
  assert.ok(executable, 'Set COPILOT_TEST_EXECUTABLE to a native CLI launcher that preserves exit codes');
  return executable.trim();
}

function reply(response, wireApi, streaming, text = 'ready', model = 'gpt-4.1') {
  if (wireApi === 'completions') {
    const completion = {
      id: 'fixture-completion', object: 'chat.completion', created: 1, model,
      choices: [{ index: 0, message: { role: 'assistant', content: text }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
    };
    if (streaming) {
      response.writeHead(200, { 'Content-Type': 'text/event-stream' });
      response.write(`data: ${JSON.stringify({ ...completion, object: 'chat.completion.chunk', choices: [{ index: 0, delta: { role: 'assistant', content: text }, finish_reason: null }] })}\n\n`);
      response.end(`data: ${JSON.stringify({ ...completion, object: 'chat.completion.chunk', choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] })}\n\ndata: [DONE]\n\n`);
    } else {
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(JSON.stringify(completion));
    }
    return;
  }
  const content = { type: 'output_text', text, annotations: [] };
  const message = { id: 'fixture-message', type: 'message', role: 'assistant', status: 'completed', content: [content] };
  const result = {
    id: 'fixture-response', object: 'response', created_at: 1, status: 'completed', model,
    output: [message], error: null, incomplete_details: null, tools: [], parallel_tool_calls: false,
    usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } },
  };
  if (!streaming) {
    response.writeHead(200, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify(result));
    return;
  }
  response.writeHead(200, { 'Content-Type': 'text/event-stream' });
  const events = [
    { type: 'response.created', response: { ...result, status: 'in_progress', output: [] } },
    { type: 'response.output_item.added', output_index: 0, item: { ...message, status: 'in_progress', content: [] } },
    { type: 'response.content_part.added', item_id: message.id, output_index: 0, content_index: 0, part: { ...content, text: '' } },
    { type: 'response.output_text.delta', item_id: message.id, output_index: 0, content_index: 0, delta: text },
    { type: 'response.output_text.done', item_id: message.id, output_index: 0, content_index: 0, text },
    { type: 'response.content_part.done', item_id: message.id, output_index: 0, content_index: 0, part: content },
    { type: 'response.output_item.done', output_index: 0, item: message },
    { type: 'response.completed', response: result },
  ];
  events.forEach((event, sequenceNumber) => response.write(`event: ${event.type}\ndata: ${JSON.stringify({ ...event, sequence_number: sequenceNumber })}\n\n`));
  response.end();
}

async function exerciseCli(wireApi, failCredential, persistent = false, expiryScenario = '', requestModel = 'gpt-4.1', backendError = false, observeResponse = false, agentLauncher = false) {
  const directory = mkdtempSync(join(tmpdir(), 'byok-cli-wire-'));
  const providerPrefix = observeResponse ? `/jwt-probe-cli-${randomUUID().replaceAll('-', '')}/openai` : '/jwt-probe-fixture/openai';
  const statePath = join(directory, 'credential.json');
  const usagePath = join(directory, 'usage.json');
  const configHome = join(directory, 'copilot');
  mkdirSync(configHome);
  writeFileSync(statePath, JSON.stringify({ fail: failCredential }));
  const requests = [];
  let tlsOptions;
  let certificate;
  if (agentLauncher) {
    certificate = join(directory, 'fixture-ca.pem');
    const key = join(directory, 'fixture-key.pem');
    const openssl = process.env.OPENSSL_EXECUTABLE || (process.platform === 'win32' ? join(process.env.ProgramFiles, 'Git/usr/bin/openssl.exe') : 'openssl');
    const generated = spawnSync(openssl, ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost',
      '-addext', 'subjectAltName=IP:127.0.0.1,DNS:localhost', '-keyout', key, '-out', certificate], { encoding: 'utf8', windowsHide: true });
    assert.equal(generated.status, 0, 'Create only an ephemeral local HTTPS fixture certificate');
    tlsOptions = { key: readFileSync(key), cert: readFileSync(certificate) };
  }
  let clock = Math.floor(Date.now() / 1000);
  const proof = `cli-proof-${randomUUID().replaceAll('-', '')}`;
  if (expiryScenario) writeFileSync(statePath, JSON.stringify({ evidence: { now: clock, expires: clock + 120 } }));
  const handleRequest = (request, response) => {
    const credentials = request.headers['api-key'];
    requests.push({ key: credentials, bearer: request.headers.authorization, path: request.url, probeMarker: request.headers['x-byok-inference-probe'] });
    let body = '';
    request.setEncoding('utf8');
    request.on('data', chunk => {
      body += chunk;
      if (body.length > 4 * 1024 * 1024) request.destroy();
    });
    request.on('end', () => {
      if (backendError === 'redirect') {
        response.writeHead(307, { Location: 'https://redirect.invalid/blocked' });
        response.end();
        return;
      }
      if (backendError) {
        response.writeHead(400, { 'Content-Type': 'application/json' });
        response.end(JSON.stringify({ error: { message: "Unsupported parameter: 'prompt_cache_key'.", type: 'invalid_request_error', code: 'unsupported_parameter', param: 'prompt_cache_key' } }));
        return;
      }
      if (requests.length === 1) {
        response.writeHead(503, { 'Content-Type': 'application/json', 'Retry-After': '0' });
        response.end(JSON.stringify({ error: { message: 'Synthetic retry', type: 'server_error', code: 'server_error' } }));
        return;
      }
      try {
        const payload = body ? JSON.parse(body) : {};
        if (requestModel !== 'gpt-4.1') {
          assert.equal(payload.model, requestModel);
          assert.equal(payload.stream, true);
          assert.ok(Array.isArray(payload.messages));
          assert.equal(typeof payload.reasoning_effort, 'string');
        }
        reply(response, request.url.includes('/responses') ? 'responses' : 'completions', payload.stream, expiryScenario ? `${proof}:${clock}` : 'ready', requestModel);
      } catch {
        response.writeHead(400);
        response.end();
      }
    });
  };
  const server = agentLauncher ? createTlsServer(tlsOptions, handleRequest) : createServer(handleRequest);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const environment = { ...process.env };
  for (const name of Object.keys(environment)) {
    if (/^(COPILOT_|OTEL_|AZURE_|OPENAI_|ANTHROPIC_|NODE_TEST_|GH_TOKEN$|GITHUB_TOKEN$)/i.test(name)) delete environment[name];
  }
  Object.assign(environment, {
    COPILOT_HOME: configHome,
    COPILOT_OFFLINE: 'true',
    COPILOT_PROVIDER_BASE_URL: `${agentLauncher ? 'https' : 'http'}://127.0.0.1:${server.address().port}${providerPrefix}`,
    COPILOT_PROVIDER_TYPE: 'azure',
    COPILOT_PROVIDER_WIRE_API: wireApi,
    COPILOT_PROVIDER_API_KEY_COMMAND: `${quote(process.execPath)} ${quote(scriptPath)} --credential-fixture ${quote(statePath)}`,
    COPILOT_MODEL: requestModel,
    ...(!persistent && !expiryScenario ? { COPILOT_PROVIDER_HEADERS: 'X-Byok-Inference-Probe: fixture-marker' } : {}),
    USE_TGREP: 'false',
    NO_COLOR: '1',
  });
  const argumentsList = [
    ...(persistent ? ['--acp', '--stdio'] : ['--prompt=ready', '--silent', `--usage-output-file=${usagePath}`]), '--no-custom-instructions', '--disable-builtin-mcps',
    '--allow-all-tools', '--deny-tool=shell', '--deny-tool=write', '--deny-tool=url', '--available-tools=', '--no-ask-user', '--log-level=none',
    '--no-remote', '--no-remote-export',
  ];
  let child;
  let timeout;
  let timedOut = false;
  try {
    const executable = resolveCli();
    let launcherProfile;
    if (agentLauncher) {
      const cache = join(directory, 'azure-cache');
      const binaryDirectory = join(directory, 'bin');
      mkdirSync(cache);
      mkdirSync(binaryDirectory);
      const fixture = { appId: randomUUID(), tenantId: randomUUID(), cache, fail: false };
      writeFileSync(statePath, JSON.stringify(fixture));
      const azureCommand = process.platform === 'win32'
        ? `@echo off\r\n"${process.execPath}" "${scriptPath}" --azure-fixture %*\r\nexit /b %ERRORLEVEL%\r\n`
        : `#!/bin/sh\nexec ${quote(process.execPath)} ${quote(scriptPath)} --azure-fixture "$@"\n`;
      writeFileSync(join(binaryDirectory, process.platform === 'win32' ? 'az.cmd' : 'az'), azureCommand, { mode: 0o700 });
      const pathKey = Object.keys(environment).find(name => name.toUpperCase() === 'PATH') || 'PATH';
      environment[pathKey] = binaryDirectory + (process.platform === 'win32' ? ';' : ':') + environment[pathKey];
      environment.BYOK_AGENT_FIXTURE = statePath;
      environment.NODE_EXTRA_CA_CERTS = certificate;
      delete environment.NODE_TLS_REJECT_UNAUTHORIZED;
      const nativeCli = process.platform === 'win32' && !executable.endsWith('.exe')
        ? join(process.env.APPDATA, 'npm/node_modules/@github/copilot/node_modules/@github/copilot-win32-x64/copilot.exe') : executable;
      assert.ok(existsSync(nativeCli), 'The pinned editor launcher test requires an absolute native CLI executable');
      launcherProfile = join(directory, 'agent-profile.json');
      writeFileSync(launcherProfile, JSON.stringify({ cliExecutable: nativeCli, gatewayUrl: environment.COPILOT_PROVIDER_BASE_URL,
        model: requestModel, authMode: 'jwt', appId: fixture.appId, cloud: 'AzureUSGovernment', tenantId: fixture.tenantId,
        accountName: 'fixture-user', azureConfigDirectory: cache, workspace: directory }));
      delete environment.COPILOT_PROVIDER_API_KEY_COMMAND;
    }
    if (observeResponse) {
      environment.COPILOT_PROVIDER_HEADERS = `X-Byok-Inference-Probe: ${providerPrefix.split('/')[1]}`;
      const result = await observeInference({ executable, wireApi, directory, usagePath }, environment, { allowLoopbackHttp: true });
      assert.equal(result.providerResponseReceived, true);
      assert.equal(result.forwardedRequests, 1);
      assert.equal(requests.length, 1);
      assert.match(requests[0].key, /^synthetic\.[a-f0-9]{32}\.fixture$/);
      assert.equal(requests[0].bearer, undefined);
      assert.equal(requests[0].path, `${providerPrefix}/v1/chat/completions`);
      if (backendError === 'redirect') {
        assert.deepEqual(result.diagnostic.httpStatuses, [307]);
        assert.equal(result.diagnostic.hint, 'redirect-rejected');
      } else {
        assert.deepEqual(result.diagnostic.httpStatuses, [400]);
        assert.ok(result.diagnostic.errorCodes.includes('unsupported_parameter'));
        assert.ok(result.diagnostic.parameters.includes('prompt_cache_key'));
      }
      assert.notEqual(result.cliExit, 0);
      assert.doesNotMatch(JSON.stringify(result), /synthetic\.|private-message/);
      return;
    }
    if (expiryScenario) {
      const events = [];
      const controller = new AbortController();
      const sessionRun = runCredentialSession({ executable, environment, directory, receiptPath: `${statePath}.receipts`,
        proofs: { responses: proof, completions: proof } }, {
        now: () => clock,
        signal: controller.signal,
        report: row => events.push(row),
        pauseUntil: async resumeAt => {
          assert.equal(events.filter(row => row.test === 'vm-copilot-expiry-turn').length, 2);
          if (expiryScenario !== 'early') clock = resumeAt;
          if (expiryScenario === 'cancel') controller.abort();
          writeFileSync(statePath, JSON.stringify({ fail: expiryScenario === 'fail', evidence: { now: clock,
            expires: expiryScenario === 'stale' ? resumeAt - 10 : resumeAt + 3600 } }));
        },
      });
      if (expiryScenario === 'success') {
        const result = await sessionRun;
        assert.equal(result.sameSessions, true);
        assert.equal(result.actualExpiryTested, true);
        assert.equal(events.filter(row => row.phase === 'after-expiry' && row.passed).length, 2);
      } else {
        await assert.rejects(sessionRun);
        assert.equal(events.filter(row => row.phase === 'after-expiry' && row.passed).length, 0);
        if (['fail', 'early', 'cancel'].includes(expiryScenario)) assert.equal(requests.length, 3, 'A failed, early, or cancelled renewal must not call the provider');
      }
      return;
    }
    const windowsCommand = [executable, ...argumentsList].map(quote).join(' ');
    const launchCommand = agentLauncher ? 'pwsh' : (process.platform === 'win32' ? process.env.ComSpec : executable);
    const launchArguments = agentLauncher
      ? ['-NoLogo', '-NoProfile', '-NonInteractive', '-File', fileURLToPath(new URL('../start-copilot-agent.ps1', import.meta.url)), '-ConfigFile', launcherProfile, '-Mode', 'acp']
      : (process.platform === 'win32' ? ['/d', '/s', '/c', `"${windowsCommand}"`] : argumentsList);
    child = spawn(launchCommand, launchArguments, {
      cwd: directory, env: environment, windowsHide: true, windowsVerbatimArguments: process.platform === 'win32' && !agentLauncher,
      stdio: [persistent ? 'pipe' : 'ignore', 'pipe', 'pipe'],
    });
    let output = '';
    let errorOutput = '';
    child.stdout.on('data', chunk => { output += chunk.toString(); });
    child.stderr.on('data', chunk => { errorOutput += chunk.toString(); });
    timeout = setTimeout(() => {
      timedOut = true;
      if (process.platform === 'win32') spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
      else child.kill('SIGKILL');
    }, 90000);
    let exitCode;
    if (persistent) {
      const pending = new Map();
      const updates = [];
      let nextId = 1;
      const reader = createInterface({ input: child.stdout });
      reader.on('line', line => {
        let message;
        try { message = JSON.parse(line); } catch { if (agentLauncher) assert.fail('Agent launcher polluted ACP stdout'); return; }
        if (message.method === 'session/update') updates.push(message.params);
        if (message.method && message.id !== undefined) {
          child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'Client capabilities disabled for fixture' } })}\n`);
        } else if (pending.has(message.id)) {
          pending.get(message.id)(message);
          pending.delete(message.id);
        }
      });
      const rpc = (method, params) => new Promise((resolve, reject) => {
        const id = nextId++;
        const deadline = setTimeout(() => { pending.delete(id); reject(new Error(`ACP ${method} timed out`)); }, 30000);
        pending.set(id, message => { clearTimeout(deadline); resolve(message); });
        child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
      });
      try {
        const initialization = await rpc('initialize', { protocolVersion: 1, clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false } });
        assert.equal(initialization.error?.code, undefined, 'ACP initialization must work without GitHub credentials');
        const created = await rpc('session/new', { cwd: directory, mcpServers: [] });
        assert.equal(created.error?.code, undefined, `ACP session creation rejected with code ${created.error?.code}`);
        assert.ok(created.result?.sessionId, 'ACP must return a session identifier');
        const sessionId = created.result.sessionId;
        for (const turn of [1, 2]) {
          updates.length = 0;
          const previousRequests = requests.length;
          const response = await rpc('session/prompt', { sessionId, prompt: [{ type: 'text', text: `fixture turn ${turn}` }] });
          assert.equal(response.error?.code, undefined, `ACP turn ${turn} failed`);
          assert.equal(response.result?.stopReason, 'end_turn');
          assert.ok(requests.length > previousRequests, 'Each same-session turn must call the provider');
          assert.ok(updates.some(update => update.sessionId === sessionId && update.update?.sessionUpdate === 'agent_message_chunk' && update.update.content?.text?.includes('ready')), 'The same ACP session must return the fixture response');
          assert.equal(child.exitCode, null, 'CLI process must remain alive between prompts');
        }
        writeFileSync(statePath, JSON.stringify({ ...JSON.parse(readFileSync(statePath, 'utf8')), fail: true }));
        const previousRequests = requests.length;
        updates.length = 0;
        const failed = await rpc('session/prompt', { sessionId, prompt: [{ type: 'text', text: 'fixture credential failure' }] });
        assert.equal(requests.length, previousRequests, 'Failed renewal must not reuse a previous credential');
        const failureReported = updates.some(update => /error|failed|credential/i.test(update.update?.content?.text || ''));
        assert.ok(failed.error || failed.result?.stopReason !== 'end_turn' || failureReported,
          `Persistent session must report credential failure (updates=${JSON.stringify(updates.map(update => update.update))})`);
        exitCode = 0;
      } finally {
        reader.close();
        if (process.platform === 'win32') spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
        else child.kill('SIGKILL');
      }
    } else {
      [exitCode] = await once(child, 'exit');
    }
    assert.equal(timedOut, false, 'CLI exceeded the bounded local test duration');
    assert.ok(existsSync(`${statePath}.calls`), `CLI never invoked the credential fixture (exit=${exitCode}): ${errorOutput.slice(0, 1500)}`);
    const commandCalls = readFileSync(`${statePath}.calls`, 'utf8').trim().split('\n').length;
    if (backendError) {
      assert.notEqual(exitCode, 0, 'CLI must report a backend request rejection');
      assert.equal(requests.length, 1, 'A backend 400 must not trigger another provider request');
      assert.equal(commandCalls, 1);
      assert.match(output + errorOutput, /400/);
      assert.match(output + errorOutput, /prompt_cache_key/);
      return;
    }
    if (failCredential) {
      assert.notEqual(exitCode, 0, 'CLI must surface a credential-command failure');
      assert.equal(requests.length, 0, 'A credential failure must not send an unauthenticated provider request');
      assert.ok(commandCalls >= 1);
    } else {
      assert.equal(exitCode, 0, 'CLI failed against the synthetic provider');
      assert.match(output, /ready/);
      if (!persistent) {
        const usage = JSON.parse(readFileSync(usagePath, 'utf8'));
        assert.equal(usage.modelMetrics[requestModel].requests.count, 1);
        assert.equal(usage.modelMetrics[requestModel].usage.inputTokens, 1);
        assert.equal(usage.modelMetrics[requestModel].usage.outputTokens, 1);
      }
      assert.ok(requests.length >= 2, 'The transient response must exercise another HTTP request');
      assert.equal(new Set(requests.map(request => request.key)).size, requests.length, 'Each HTTP attempt must reacquire its credential');
      assert.ok(commandCalls >= requests.length);
      for (const request of requests) {
        assert.match(request.key || '', /^synthetic\.[a-f0-9]{32}\.fixture$/);
        assert.equal(request.bearer, undefined, 'Azure credential command must use api-key only');
        if (!persistent) assert.equal(request.probeMarker, 'fixture-marker', 'CLI must forward the nonsecret inference fixture marker');
        const pathname = new URL(request.path, 'http://127.0.0.1').pathname;
        const expectedPath = `${providerPrefix}/v1/${wireApi === 'responses' ? 'responses' : 'chat/completions'}`;
        assert.equal(pathname, expectedPath, 'Azure provider must preserve the disposable APIM API prefix');
      }
    }
  } finally {
    clearTimeout(timeout);
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    rmSync(directory, { recursive: true, force: true, maxRetries: 3 });
  }
}

for (const wireApi of ['responses', 'completions']) {
  test(`CLI Azure ${wireApi} preserves API prefixes and reacquires credentials for retries`, { timeout: 120000 }, async () => exerciseCli(wireApi, false));
}
test('CLI credential failure sends no provider request', { timeout: 120000 }, async () => exerciseCli('responses', true));
test('CLI inference model Chat request shape', { timeout: 120000 }, async () => exerciseCli('completions', false, false, '', 'gpt-5.6-sol'));
test('CLI exposes backend parameter rejection without retrying', { timeout: 120000 }, async () => exerciseCli('completions', false, false, '', 'gpt-4.1', true));
test('CLI response capture preserves a rejected request and sanitizes its error', { timeout: 120000 }, async () => exerciseCli('completions', false, false, '', 'gpt-4.1', true, true));
test('CLI response capture rejects redirects and forwards at most once', { timeout: 120000 }, async () => exerciseCli('completions', false, false, '', 'gpt-4.1', 'redirect', true));
test('Inference error classifier excludes unknown text and credentials', () => {
  const result = classifyResponse(400, Buffer.from(JSON.stringify({ error: { code: 'private-code', param: 'private-parameter',
    message: "Unsupported parameter: 'reasoning_effort'. private-message synthetic.secret.fixture https://private.example.test" } })));
  assert.deepEqual(result.errorCodes, []);
  assert.deepEqual(result.parameters, ['reasoning_effort']);
  assert.doesNotMatch(JSON.stringify(result), /private|synthetic/);
});
test('CLI ACP keeps one session and fails closed on later credential failure', { timeout: 120000 }, async () => exerciseCli('responses', false, true));
test('Pinned editor launcher keeps HTTPS ACP renewal and fails closed', { timeout: 120000 }, async () => exerciseCli('responses', false, true, '', 'gpt-4.1', false, false, true));
for (const scenario of ['success', 'early', 'stale', 'fail', 'cancel']) {
  test(`CLI expiry controller with simulated time: ${scenario}`, { timeout: 120000 }, async () => exerciseCli('responses', false, false, scenario));
}