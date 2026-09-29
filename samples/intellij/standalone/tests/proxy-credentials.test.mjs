import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, readFile, rm, mkdir, writeFile } from 'node:fs/promises';
import https from 'node:https';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import credentials from '../nginx-credentials.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const nginx = process.env.NGINX_EXECUTABLE || 'nginx';
const openssl = process.env.OPENSSL_EXECUTABLE || 'openssl';
const normalize = text => text.split(/\r?\n/).map(line => line.trim()).filter(Boolean).join('\n');

test('raw credential gate rejects absent, empty, mixed, repeated and encoded sources', () => {
  const cases = [
    { headers: [['Authorization', 'Bearer fixture-key']], result: 'header:fixture-key' },
    { headers: [['authorization', 'Bearer header.payload.signature']], result: 'header:header.payload.signature' },
    { headers: [['api-key', 'fixture-key']], result: 'header:fixture-key' },
    { headers: [], args: 'api-key=fixture-key&after=cursor', result: 'query' },
    { headers: [], args: '%61pi%2dkey=fixture-key', result: 'query' },
    { headers: [], result: 'invalid' },
    { headers: [['api-key', '']], result: 'invalid' },
    { headers: [['Authorization', '']], result: 'invalid' },
    { headers: [['Authorization', 'Bearer fixture-key'], ['api-key', '']], result: 'invalid' },
    { headers: [['api-key', 'fixture-key'], ['Authorization', '']], result: 'invalid' },
    { headers: [['Authorization', 'Bearer fixture-key'], ['x-api-key', '']], result: 'invalid' },
    { headers: [['api-key', 'fixture-key'], ['Ocp-Apim-Subscription-Key', '']], result: 'invalid' },
    { headers: [['api-key', 'fixture-key']], args: '%61pi%2dkey=other', result: 'invalid' },
    { headers: [['api-key', 'fixture-key']], args: '%61ccess_token=other', result: 'invalid' },
    { headers: [['Authorization', 'Bearer fixture-key'], ['authorization', 'Bearer fixture-key']], result: 'invalid' },
    { headers: [['Authorization', 'Bearer fixture-key'], ['authorization', 'Bearer other']], result: 'invalid' },
    { headers: [['api-key', 'fixture-key'], ['API-Key', 'fixture-key']], result: 'invalid' },
    { headers: [['api-key', 'fixture-key,other']], result: 'invalid' },
    { headers: [['Authorization', 'Basic fixture-key']], result: 'invalid' },
    { headers: [['Authorization', 'Bearer fixture-key other']], result: 'invalid' },
    { headers: [['x-api-key', 'fixture-key']], result: 'invalid' },
    { headers: [], args: 'api-key=one&api-key=two', result: 'invalid' },
    { headers: [], args: 'api-key=one&API-Key=two', result: 'invalid' },
    { headers: [], args: 'api-key=', result: 'invalid' },
    { headers: [], args: 'api-key=one%2ctwo', result: 'invalid' },
    { headers: [], args: 'api-key=one%0d%0atwo', result: 'invalid' },
    { headers: [], args: 'api-key=fixture-key%0a', result: 'invalid' },
    { headers: [['api-key', 'fixture-key\n']], result: 'invalid' },
    { headers: [['Authorization', 'Bearer fixture-key\n']], result: 'invalid' },
    { headers: [], args: 'Authorization=Bearer%20fixture-key', result: 'invalid' },
    { headers: [], args: 'subscription-key=fixture-key', result: 'invalid' },
    { headers: [['Authorization', 'Bearer fixture-key']], args: 'after=cursor&limit=10', result: 'header:fixture-key' },
  ];
  for (const [index, scenario] of cases.entries()) {
    assert.equal(credentials.credential({ rawHeadersIn: scenario.headers, variables: { args: scenario.args || '' } }), scenario.result, `raw credential case ${index + 1}`);
  }
  assert.equal(credentials.credential({}), 'invalid', 'Missing njs request state must fail closed');
});

async function proxyConfig(name) {
  const source = await readFile(path.join(root, name), 'utf8');
  if (name.endsWith('.conf')) return source;
  const match = source.replaceAll('\r\n', '\n').match(/    content: \|\n([\s\S]*?)\nruncmd:/);
  assert.ok(match, 'Cloud-init must contain exactly the proxy config');
  return match[1].replace(/^      /gm, '');
}

test('VM bootstrap stages configuration until njs is installed and stops on failure', async () => {
  const standard = await readFile(path.join(root, 'cloud-init.yaml'), 'utf8');
  const prebaked = await readFile(path.join(root, 'cloud-init.prebaked.yaml'), 'utf8');
  assert.ok(standard.includes('path: /var/lib/byok/byok-proxy.conf'));
  assert.ok(!standard.includes('path: /etc/nginx/conf.d/byok-proxy.conf'));
  for (const source of [standard, prebaked]) {
    const commands = source.slice(source.indexOf('runcmd:'));
    assert.match(commands, /runcmd:\r?\n  - \|\r?\n      set -eu/);
    assert.ok(commands.indexOf('nginx -t') < commands.indexOf('systemctl restart nginx'));
  }
  const commands = standard.slice(standard.indexOf('runcmd:'));
  assert.ok(commands.indexOf('bash /var/lib/byok/install-nginx-njs.sh') < commands.indexOf('install -m 644'));
  for (const name of ['cloud-init.yaml', 'cloud-init.prebaked.yaml']) {
    const config = await proxyConfig(name);
    assert.ok(config.includes('js_import credentials'));
    assert.ok(config.includes('proxy_ssl_verify on;'));
  }
});

async function unusedPort() {
  const server = net.createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}

async function request(port, headers, suffix = '/intellij/v1/models') {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host: '127.0.0.1', port });
    const chunks = [];
    socket.setTimeout(5000, () => socket.destroy(new Error('Loopback proxy timeout')));
    socket.on('error', reject);
    socket.on('data', chunk => chunks.push(chunk));
    socket.on('connect', () => socket.write(`GET ${suffix} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n${headers.join('\r\n')}\r\n\r\n`));
    socket.on('end', () => {
      const response = Buffer.concat(chunks).toString('utf8');
      resolve(Number(response.match(/^HTTP\/1\.[01] (\d{3}) /)?.[1] || 0));
      socket.destroy();
    });
  });
}

async function stopNginx(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, 'exit');
  const force = setTimeout(() => child.kill('SIGKILL'), 2000);
  force.unref();
  child.kill();
  try { await exited; } finally { clearTimeout(force); }
}

test('all proxy variants preserve a single credential and reject visible conflicts', { timeout: 60000 }, async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'byok-proxy-'));
  let upstream;
  let child;
  try {
    const certificate = path.join(directory, 'certificate.pem');
    const key = path.join(directory, 'key.pem');
    const generated = spawnSync(openssl, ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
      '-subj', '/CN=gateway.example.test', '-addext', 'subjectAltName=DNS:gateway.example.test',
      '-keyout', key, '-out', certificate], { encoding: 'utf8', windowsHide: true });
    assert.equal(generated.status, 0, 'OpenSSL must generate an ephemeral loopback TLS fixture');
    const receipts = [];
    upstream = https.createServer({ key: await readFile(key), cert: await readFile(certificate) }, (incoming, response) => {
      receipts.push({ headers: incoming.headers, rawHeaders: incoming.rawHeaders, url: incoming.url, sni: incoming.socket.servername });
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end('{"object":"list","data":[]}');
    });
    upstream.listen(0, '127.0.0.1');
    await once(upstream, 'listening');
    const backendPort = upstream.address().port;
    const canonical = await proxyConfig('nginx.containerapp.conf');
    const modulePath = process.env.NGINX_NJS_MODULE || '/usr/lib/nginx/modules/ngx_http_js_module.so';
    const credentialSource = await readFile(path.join(root, 'nginx-credentials.mjs'), 'utf8');
    const cases = [
      { name: 'bearer key', headers: ['Authorization: Bearer fixture-key'], key: 'fixture-key', status: 200 },
      { name: 'bearer JWT', headers: ['Authorization: Bearer header.payload.signature'], key: 'header.payload.signature', status: 200 },
      { name: 'API key', headers: ['api-key: fixture-key'], key: 'fixture-key', status: 200 },
      { name: 'query only', headers: [], suffix: '/intellij/v1/models?api-key=fixture-query', status: 200 },
      { name: 'encoded query only', headers: [], suffix: '/intellij/v1/models?%61pi%2dkey=fixture-query', status: 200 },
      { name: 'missing credential', headers: [], status: 401 },
      { name: 'empty key only', headers: ['api-key:'], status: 401 },
      { name: 'duplicate query', headers: [], suffix: '/intellij/v1/models?api-key=fixture-one&api-key=fixture-two', status: 401 },
      { name: 'mixed headers', headers: ['Authorization: Bearer fixture-one', 'api-key: fixture-two'], status: 401 },
      { name: 'bearer and empty key', headers: ['Authorization: Bearer fixture-one', 'api-key:'], status: 401 },
      { name: 'key and empty authorization', headers: ['api-key: fixture-one', 'Authorization:'], status: [400, 401] },
      { name: 'bearer and empty unsupported header', headers: ['Authorization: Bearer fixture-one', 'x-api-key:'], status: 401 },
      { name: 'key and empty native header', headers: ['api-key: fixture-one', 'Ocp-Apim-Subscription-Key:'], status: 401 },
      { name: 'wrong key header', headers: ['Authorization: Bearer fixture-one', 'x-api-key: fixture-two'], status: 401 },
      { name: 'native header conflict', headers: ['api-key: fixture-one', 'Ocp-Apim-Subscription-Key: fixture-two'], status: 401 },
      { name: 'header plus query', headers: ['Authorization: Bearer fixture-one'], suffix: '/intellij/v1/models?api-key=fixture-two', status: 401 },
      { name: 'header plus encoded query', headers: ['Authorization: Bearer fixture-one'], suffix: '/intellij/v1/models?%61pi%2dkey=fixture-two', status: 401 },
      { name: 'same repeated bearer', headers: ['Authorization: Bearer fixture-one', 'authorization: Bearer fixture-one'], status: [400, 401] },
      { name: 'different repeated bearer', headers: ['Authorization: Bearer fixture-one', 'Authorization: Bearer fixture-two'], status: [400, 401] },
      { name: 'repeated key', headers: ['api-key: fixture-one', 'api-key: fixture-two'], status: 401 },
      { name: 'comma bearer', headers: ['Authorization: Bearer fixture-one,Bearer fixture-two'], status: 401 },
      { name: 'unsupported authorization', headers: ['Authorization: Basic fixture'], status: 401 },
    ];
    for (const [index, name] of ['nginx.containerapp.conf', 'cloud-init.yaml', 'cloud-init.prebaked.yaml', 'main-proxy'].entries()) {
      let config = name === 'main-proxy' ? canonical : await proxyConfig(name);
      assert.equal(normalize(config.slice(0, config.indexOf('log_format'))), normalize(canonical.slice(0, canonical.indexOf('log_format'))));
      if (name === 'main-proxy') config = config.replace(/    location \/ \{\s*return 404;\s*\}/, '').replace('location ^~ /__INTELLIJ_API_PATH__/', 'location /');
      const port = await unusedPort();
      const instance = path.join(directory, `instance-${index}`);
      await mkdir(path.join(instance, 'logs'), { recursive: true });
      await mkdir(path.join(instance, 'temp'), { recursive: true });
      const prefix = `${instance.replaceAll('\\', '/')}/`;
      await writeFile(path.join(instance, 'nginx-credentials.mjs'), credentialSource);
      config = config.replaceAll('__APIM_PRIVATE_IP__', `127.0.0.1:${backendPort}`)
        .replaceAll('__APIM_GATEWAY_HOST__', 'gateway.example.test').replaceAll('__INTELLIJ_API_PATH__', 'intellij')
        .replace('listen 8080;', `listen 127.0.0.1:${port};`)
        .replace('/etc/ssl/certs/ca-certificates.crt', certificate.replaceAll('\\', '/'))
        .replace('/etc/nginx/conf.d/nginx-credentials.mjs', `${prefix}nginx-credentials.mjs`)
        .replace(/access_log [^;]+;/, `access_log ${prefix}access.log byok;`)
        .replace(/error_log [^;]+;/, `error_log ${prefix}error.log crit;`);
      await writeFile(path.join(instance, 'nginx.conf'), `load_module ${modulePath};\nworker_processes 1;\npid ${prefix}nginx.pid;\nerror_log ${prefix}startup.log crit;\nevents { worker_connections 32; }\nhttp { ${config} }\n`);
      const syntax = spawnSync(nginx, ['-p', prefix, '-c', 'nginx.conf', '-t'], { encoding: 'utf8', windowsHide: true });
      assert.equal(syntax.status, 0, `nginx syntax rejected ${name}: ${syntax.stderr}`);
      child = spawn(nginx, ['-p', prefix, '-c', 'nginx.conf', '-g', 'daemon off; master_process off;'], { stdio: 'ignore', windowsHide: true });
      const readyDeadline = Date.now() + 5000;
      while (true) {
        try { await request(port, [], '/healthz'); break; }
        catch { if (Date.now() > readyDeadline || child.exitCode !== null) throw new Error('Loopback nginx failed to start'); await new Promise(resolve => setTimeout(resolve, 20)); }
      }
      for (const scenario of cases) {
        const before = receipts.length;
        const status = await request(port, scenario.headers, scenario.suffix);
        assert.ok([].concat(scenario.status).includes(status), `${name}: ${scenario.name} returned ${status}`);
        assert.equal(receipts.length - before, status === 200 ? 1 : 0, `${name}: ${scenario.name} unexpected upstream receipt`);
        if (status === 200) {
          const receipt = receipts.at(-1);
          assert.equal(receipt.headers['api-key'], scenario.key);
          assert.equal(receipt.headers.authorization, undefined);
          assert.equal(receipt.sni, 'gateway.example.test');
          assert.equal(receipt.headers.host, 'gateway.example.test');
        }
      }
      await stopNginx(child);
      child = null;
      const log = await readFile(path.join(instance, 'access.log'), 'utf8');
      assert.ok(!/fixture-(key|query|one|two)|header\.payload\.signature/.test(log), 'Proxy access log must not contain credentials or query values');
    }
  } finally {
    await stopNginx(child);
    if (upstream) {
      upstream.closeAllConnections();
      await new Promise(resolve => upstream.close(resolve));
    }
    await rm(directory, { recursive: true, force: true });
  }
});