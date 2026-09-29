import { spawn, spawnSync } from 'node:child_process';
import { createServer, request as requestHttp } from 'node:http';
import { request as requestHttps } from 'node:https';
import { once } from 'node:events';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const errorCodes = new Set(['unsupported_parameter', 'unsupported_value', 'invalid_parameter', 'invalid_value',
  'invalid_request_error', 'context_length_exceeded', 'content_filter', 'DeploymentNotFound', 'OperationNotSupported',
  'InvalidApiVersionParameter', 'BadRequest', 'BadArgument', 'RateLimitExceeded', 'QuotaExceeded', 'Unauthorized']);
const parameterNames = new Set(['snippy', 'max_tokens', 'max_completion_tokens', 'max_output_tokens', 'temperature',
  'top_p', 'stream_options', 'store', 'parallel_tool_calls', 'reasoning_effort', 'reasoning', 'safety_identifier',
  'prompt_cache_key', 'context_management', 'service_tier', 'tools', 'tool_choice', 'response_format', 'messages',
  'metadata', 'presence_penalty', 'frequency_penalty', 'api-version', 'model']);

export function classifyResponse(status, bytes) {
  let body;
  let bodyFormat = bytes.length ? 'text' : 'empty';
  try { body = JSON.parse(bytes.toString('utf8')); bodyFormat = 'json'; } catch { }
  const error = body?.error;
  const code = typeof error?.code === 'string' && errorCodes.has(error.code) ? error.code : '';
  const type = typeof error?.type === 'string' && errorCodes.has(error.type) ? error.type : '';
  const message = typeof error?.message === 'string' ? error.message : '';
  const parameter = typeof error?.param === 'string' && parameterNames.has(error.param) ? error.param : '';
  const mentioned = [...parameterNames].filter(name => new RegExp(`(?:parameter|param|argument)[:\\s'"=]+${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?![A-Za-z0-9_])`, 'i').test(message));
  const hint = /api[ -]?version/i.test(message) ? 'api-version-mentioned'
    : /not supported|unsupported/i.test(message) ? 'unsupported-request'
      : /content.filter|responsible.ai/i.test(message) ? 'content-filter-mentioned'
        : /token|context.length/i.test(message) ? 'token-limit-mentioned' : '';
  return { httpStatuses: [status], errorCodes: [...new Set([code, type].filter(Boolean))],
    parameters: [...new Set([parameter, ...mentioned].filter(Boolean))], bodyFormat, hint, classified: true };
}

function quote(value) {
  return `"${value.replaceAll('"', '""')}"`;
}

export async function observeInference(config, environment, options = {}) {
  const baseUrl = new URL(environment.COPILOT_PROVIDER_BASE_URL);
  const loopbackFixture = options.allowLoopbackHttp === true && baseUrl.protocol === 'http:' && baseUrl.hostname === '127.0.0.1';
  if ((!loopbackFixture && baseUrl.protocol !== 'https:') || baseUrl.username || baseUrl.password || baseUrl.search || baseUrl.hash ||
    !/^\/jwt-probe-cli-[a-f0-9]{32}\/openai\/?$/.test(baseUrl.pathname) || environment.NODE_TLS_REJECT_UNAUTHORIZED ||
    environment.COPILOT_PROVIDER_TYPE !== 'azure' || !['responses', 'completions'].includes(config.wireApi) ||
    environment.COPILOT_PROVIDER_API_KEY || environment.COPILOT_PROVIDER_BEARER_TOKEN || !environment.COPILOT_PROVIDER_API_KEY_COMMAND) {
    throw new Error('Unsafe diagnostic configuration');
  }
  const expectedMarker = `X-Byok-Inference-Probe: ${baseUrl.pathname.split('/')[1]}`;
  if (environment.COPILOT_PROVIDER_HEADERS !== expectedMarker) throw new Error('Fixture marker mismatch');
  const expectedPath = `${baseUrl.pathname.replace(/\/$/, '')}/v1/${config.wireApi === 'responses' ? 'responses' : 'chat/completions'}`;
  let forwardedRequests = 0;
  let providerResponseReceived = false;
  let diagnostic = { httpStatuses: [], errorCodes: [], parameters: [], classified: false };
  const upstreamRequests = new Set();
  const server = createServer((request, response) => {
    const credentialCount = request.rawHeaders.filter((header, index) => index % 2 === 0 && header.toLowerCase() === 'api-key').length;
    const requestUrl = new URL(request.url, 'http://127.0.0.1');
    if (forwardedRequests !== 0 || request.method !== 'POST' || requestUrl.pathname !== expectedPath || requestUrl.search ||
      credentialCount !== 1 || !request.headers['api-key'] || request.headers.authorization || request.headers['x-api-key'] ||
      request.headers['ocp-apim-subscription-key'] || request.headers['x-byok-inference-probe'] !== baseUrl.pathname.split('/')[1]) {
      response.writeHead(403, { 'Content-Type': 'application/json' });
      response.end('{"error":{"code":"diagnostic_request_rejected","message":"Outside the bounded diagnostic request."}}');
      return;
    }
    forwardedRequests++;
    const headers = { ...request.headers, host: baseUrl.host };
    delete headers.connection;
    delete headers['proxy-authorization'];
    const upstream = (loopbackFixture ? requestHttp : requestHttps)(new URL(expectedPath, baseUrl.origin), {
      method: 'POST', headers, timeout: 70000, rejectUnauthorized: true,
    }, backend => {
      providerResponseReceived = true;
      const status = backend.statusCode || 0;
      if (status >= 300 && status < 400) {
        diagnostic = { httpStatuses: [status], errorCodes: [], parameters: [], hint: 'redirect-rejected', classified: true };
        backend.resume();
        response.writeHead(502, { 'Content-Type': 'application/json' });
        response.end('{"error":{"code":"diagnostic_redirect_rejected","message":"Redirects are disabled for this fixture."}}');
        return;
      }
      const responseHeaders = { ...backend.headers };
      delete responseHeaders.connection;
      response.writeHead(status, responseHeaders);
      if (status >= 400) {
        const chunks = [];
        let capturedBytes = 0;
        backend.on('data', chunk => {
          if (capturedBytes + chunk.length <= 65536) { chunks.push(chunk); capturedBytes += chunk.length; }
        });
        backend.on('end', () => { diagnostic = classifyResponse(status, Buffer.concat(chunks)); });
      } else {
        diagnostic = { httpStatuses: [status], errorCodes: [], parameters: [], classified: true };
      }
      backend.on('error', () => response.destroy());
      backend.pipe(response);
    });
    upstreamRequests.add(upstream);
    upstream.once('close', () => upstreamRequests.delete(upstream));
    upstream.on('timeout', () => upstream.destroy());
    upstream.on('error', error => {
      const safeCode = ['ETIMEDOUT', 'ECONNRESET', 'ECONNREFUSED', 'ENOTFOUND', 'CERT_HAS_EXPIRED', 'UNABLE_TO_VERIFY_LEAF_SIGNATURE'].includes(error.code) ? error.code : 'transport-failed';
      diagnostic = { httpStatuses: [], errorCodes: [safeCode], parameters: [], classified: true };
      if (!response.headersSent) response.writeHead(502, { 'Content-Type': 'application/json' });
      response.end('{"error":{"code":"diagnostic_transport_failed","message":"The verified gateway request failed."}}');
    });
    request.on('aborted', () => upstream.destroy());
    request.pipe(upstream);
  });
  server.requestTimeout = 90000;
  server.headersTimeout = 10000;
  await new Promise((resolveListen, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolveListen); });
  let child;
  let deadline;
  let timedOut = false;
  try {
    const cliEnvironment = { ...environment,
      COPILOT_PROVIDER_BASE_URL: `http://127.0.0.1:${server.address().port}${baseUrl.pathname.replace(/\/$/, '')}`,
      COPILOT_PROVIDER_WIRE_API: config.wireApi };
    const argumentsList = ['--prompt=Reply with exactly BYOK_LIVE_OK and nothing else. Do not use tools.', '--silent',
      '--no-custom-instructions', '--disable-builtin-mcps', '--allow-all-tools', '--deny-tool=shell', '--deny-tool=write',
      '--deny-tool=url', '--available-tools=', '--no-ask-user', '--log-level=none', '--no-remote', '--no-remote-export',
      `--usage-output-file=${config.usagePath}`];
    const command = [config.executable, ...argumentsList].map(quote).join(' ');
    child = spawn(process.platform === 'win32' ? process.env.ComSpec : config.executable,
      process.platform === 'win32' ? ['/d', '/s', '/c', `"${command}"`] : argumentsList, {
        env: cliEnvironment, cwd: config.directory, stdio: ['ignore', 'pipe', 'pipe'],
        windowsHide: true, windowsVerbatimArguments: process.platform === 'win32',
      });
    let output = '';
    child.stdout.on('data', chunk => { if (output.length < 1048576) output += chunk.toString(); });
    child.stderr.resume();
    deadline = setTimeout(() => {
      timedOut = true;
      if (process.platform === 'win32') spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
      else child.kill('SIGKILL');
    }, 110000);
    const [exitCode] = await once(child, 'exit');
    return { test: 'inference-response-capture', cliExit: Number.isInteger(exitCode) ? exitCode : 1,
      responseMatches: /\bBYOK_LIVE_OK\b/.test(output), forwardedRequests, providerResponseReceived,
      gatewayTlsValidated: !loopbackFixture && providerResponseReceived, timedOut, diagnostic };
  } finally {
    clearTimeout(deadline);
    if (child && child.exitCode === null && child.signalCode === null) {
      if (process.platform === 'win32') spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
      else child.kill('SIGKILL');
    }
    for (const upstream of upstreamRequests) upstream.destroy();
    server.closeAllConnections();
    await new Promise(resolveClosed => server.close(resolveClosed));
  }
}

async function main() {
  let input = '';
  for await (const chunk of process.stdin) {
    input += chunk.toString();
    if (input.length > 16384) throw new Error('Diagnostic configuration too large');
  }
  const config = JSON.parse(input);
  const result = await observeInference(config, process.env);
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(() => {
    process.stdout.write('{"test":"inference-response-capture","failed":true}\n');
    process.exitCode = 1;
  });
}