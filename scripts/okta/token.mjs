import { createHash, createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { mkdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as oauth from 'openid-client';
import { createRemoteJWKSet, customFetch, jwtVerify } from 'jose';
import lockfile from 'proper-lockfile';

export function parseConfig(input) {
  const fields = ['issuer', 'clientId', 'audience', 'requiredScope', 'subject', 'redirectUri'];
  if (!input || Object.keys(input).sort().join(',') !== fields.sort().join(',') ||
      fields.some(name => typeof input[name] !== 'string' || input[name] !== input[name].trim() || /[<>\s\x00-\x1f]/.test(input[name]))) {
    throw new Error('Expected exactly the nonsecret Okta client settings.');
  }
  const issuer = new URL(input.issuer);
  if (issuer.protocol !== 'https:' || issuer.port || issuer.username || issuer.password || issuer.search || issuer.hash ||
      !/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$/i.test(issuer.hostname) || issuer.hostname.endsWith('.localhost') ||
      !/^\/oauth2\/[A-Za-z0-9_-]+$/.test(issuer.pathname) || issuer.href !== input.issuer ||
      !/^[A-Za-z0-9_-]{1,200}$/.test(input.clientId) || !/^[A-Za-z0-9._:-]{1,100}$/.test(input.requiredScope) ||
      ['openid', 'offline_access'].includes(input.requiredScope) || !/^[A-Za-z0-9_-]{3,200}$/.test(input.subject) || !input.audience) {
    throw new Error('A pinned custom Okta authorization server and user contract are required.');
  }
  const redirect = new URL(input.redirectUri);
  if (redirect.protocol !== 'http:' || redirect.hostname !== '127.0.0.1' || Number(redirect.port) < 1024 ||
      Number(redirect.port) > 65535 || redirect.pathname !== '/callback' || redirect.username || redirect.password || redirect.search || redirect.hash) {
    throw new Error('Register an explicit unprivileged 127.0.0.1 callback port.');
  }
  return Object.freeze({ ...input });
}

export function configKey(config) {
  return createHash('sha256').update(JSON.stringify([config.issuer, config.clientId, config.audience,
    config.requiredScope, config.subject, config.redirectUri])).digest('hex');
}

export function validateAccessClaims(payload, protectedHeader, config) {
  if (protectedHeader.alg !== 'RS256' || payload.iss !== config.issuer || payload.aud !== config.audience ||
      payload.cid !== config.clientId || payload.sub !== config.subject || payload.uid !== config.subject ||
      !Number.isSafeInteger(payload.exp) || !Array.isArray(payload.scp) || payload.scp.some(scope => typeof scope !== 'string') ||
      new Set(payload.scp).size !== payload.scp.length || !payload.scp.includes(config.requiredScope)) {
    throw new Error('The signed access token does not match the pinned gateway user contract.');
  }
  return payload.exp;
}

export async function createAuthorizationServer(config) {
  const allowedPaths = new Set(['/.well-known/openid-configuration', '/v1/authorize', '/v1/token', '/v1/keys', '/v1/revoke']
    .map(suffix => new URL(config.issuer + suffix).href));
  const guardedFetch = async (input, options = {}) => {
    const target = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
    if (!allowedPaths.has(target.href)) throw new Error('Unexpected identity endpoint.');
    return fetch(input, { ...options, redirect: 'error', signal: AbortSignal.timeout(15000) });
  };
  const server = await oauth.discovery(new URL(config.issuer), config.clientId,
    { token_endpoint_auth_method: 'none' }, oauth.None(), { [oauth.customFetch]: guardedFetch, timeout: 15 });
  const metadata = server.serverMetadata();
  for (const [name, suffix] of Object.entries({ issuer: '', authorization_endpoint: '/v1/authorize', token_endpoint: '/v1/token', jwks_uri: '/v1/keys', revocation_endpoint: '/v1/revoke' })) {
    if (metadata[name] !== config.issuer + suffix) throw new Error('Discovery does not match the pinned Okta server.');
  }
  if (!metadata.code_challenge_methods_supported?.includes('S256')) throw new Error('The authorization server must support PKCE S256.');
  const keys = createRemoteJWKSet(new URL(metadata.jwks_uri), { [customFetch]: guardedFetch, timeoutDuration: 15000 });
  return {
    server,
    verify: token => jwtVerify(token, keys, { algorithms: ['RS256'], issuer: config.issuer, audience: config.audience, clockTolerance: 0 }),
    refresh: token => oauth.refreshTokenGrant(server, token),
    revoke: token => oauth.tokenRevocation(server, token, { token_type_hint: 'refresh_token' }),
  };
}

export async function acquireToken(config, session, authorization, now = () => Math.floor(Date.now() / 1000)) {
  const cached = await session.load();
  if (!cached || typeof cached.refreshToken !== 'string' || !cached.refreshToken || /[\s\x00-\x1f]/.test(cached.refreshToken)) {
    throw new Error('Sign in explicitly before using the credential helper.');
  }
  if (cached.accessToken) {
    try {
      const verified = await authorization.verify(cached.accessToken);
      if (validateAccessClaims(verified.payload, verified.protectedHeader, config) > now() + 60) return cached.accessToken;
    } catch (error) {
      if (error.code !== 'ERR_JWT_EXPIRED') throw error;
    }
  }
  let tokens;
  try {
    tokens = await authorization.refresh(cached.refreshToken);
  } catch (error) {
    if (error.error === 'invalid_grant' || error.cause?.error === 'invalid_grant') await session.clear();
    throw error;
  }
  return persistTokens(tokens, cached.refreshToken, config, session, authorization, now());
}

export async function persistTokens(tokens, previousRefreshToken, config, session, authorization, now = Math.floor(Date.now() / 1000)) {
  if (typeof tokens.access_token !== 'string' || tokens.token_type?.toLowerCase() !== 'bearer' ||
      !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(tokens.access_token)) throw new Error('An access JWT is required.');
  const verified = await authorization.verify(tokens.access_token);
  if (validateAccessClaims(verified.payload, verified.protectedHeader, config) <= now + 60) throw new Error('Token validity is too short.');
  const refreshToken = tokens.refresh_token ?? previousRefreshToken;
  if (typeof refreshToken !== 'string' || !refreshToken || /[\s\x00-\x1f]/.test(refreshToken)) throw new Error('A renewable user grant is required.');
  await session.save({ accessToken: tokens.access_token, refreshToken });
  return tokens.access_token;
}

export async function withStoredSession(config, action, options = {}) {
  const binding = configKey(config);
  const directory = join(options.directory || join(homedir(), '.copilot', 'byok-okta'), binding);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const entry = options.entry || new (await import('@napi-rs/keyring')).Entry('copilot-byok-okta', binding,
    { linux: { store: 'secret-service' } });
  const cachePath = join(directory, 'session.enc');
  let compromised = false;
  const release = await lockfile.lock(join(directory, 'session'), { realpath: false, stale: 30000, update: 5000,
    retries: { retries: 12, factor: 1, minTimeout: 250, maxTimeout: 250 }, onCompromised: () => { compromised = true; } });
  let encryptionKey;
  function assertLock() {
    if (compromised) throw new Error('Credential refresh ownership changed.');
  }
  try {
    const stored = entry.getPassword();
    if (stored) {
      encryptionKey = Buffer.from(stored, 'base64');
      if (encryptionKey.length !== 32 || encryptionKey.toString('base64') !== stored) throw new Error('Invalid keystore entry.');
    }
    const prepare = async () => {
      assertLock();
      if (!encryptionKey) {
        encryptionKey = randomBytes(32);
        entry.setPassword(encryptionKey.toString('base64'));
        if (entry.getPassword() !== encryptionKey.toString('base64')) throw new Error('Keystore write was not persistent.');
      }
    };
    const session = {
      prepare,
      load: async () => {
        assertLock();
        let info;
        try { info = await stat(cachePath); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
        if (!info.isFile() || info.size > 65536 || !encryptionKey) throw new Error('Invalid encrypted credential cache.');
        const blob = JSON.parse(await readFile(cachePath, 'utf8'));
        if (blob.version !== 1 || typeof blob.iv !== 'string' || typeof blob.tag !== 'string' || typeof blob.data !== 'string') throw new Error('Invalid encrypted cache format.');
        const nonce = Buffer.from(blob.iv, 'base64');
        const tag = Buffer.from(blob.tag, 'base64');
        if (nonce.length !== 12 || tag.length !== 16) throw new Error('Invalid encrypted cache envelope.');
        const decipher = createDecipheriv('aes-256-gcm', encryptionKey, nonce);
        decipher.setAAD(Buffer.from(binding));
        decipher.setAuthTag(tag);
        return JSON.parse(Buffer.concat([decipher.update(Buffer.from(blob.data, 'base64')), decipher.final()]).toString('utf8'));
      },
      save: async value => {
        await prepare();
        const plaintext = Buffer.from(JSON.stringify(value));
        if (plaintext.length > 32768) throw new Error('Credential cache exceeds its bound.');
        const nonce = randomBytes(12);
        const cipher = createCipheriv('aes-256-gcm', encryptionKey, nonce);
        cipher.setAAD(Buffer.from(binding));
        let data;
        try { data = Buffer.concat([cipher.update(plaintext), cipher.final()]); } finally { plaintext.fill(0); }
        const blob = JSON.stringify({ version: 1, iv: nonce.toString('base64'), tag: cipher.getAuthTag().toString('base64'), data: data.toString('base64') });
        const temporary = join(directory, randomBytes(16).toString('hex') + '.tmp');
        try {
          await writeFile(temporary, blob, { flag: 'wx', mode: 0o600 });
          assertLock();
          await rename(temporary, cachePath);
        } finally { await rm(temporary, { force: true }); }
      },
      clear: async () => {
        assertLock();
        entry.deleteCredential();
        encryptionKey?.fill(0);
        encryptionKey = undefined;
        await rm(cachePath, { force: true });
      },
    };
    const result = await action(session);
    assertLock();
    return result;
  } finally {
    encryptionKey?.fill(0);
    await release();
  }
}

export async function createLoginRequest(config, server) {
  const verifier = oauth.randomPKCECodeVerifier();
  const state = oauth.randomState();
  const nonce = oauth.randomNonce();
  const url = oauth.buildAuthorizationUrl(server, { redirect_uri: config.redirectUri,
    scope: `openid offline_access ${config.requiredScope}`, code_challenge: await oauth.calculatePKCECodeChallenge(verifier),
    code_challenge_method: 'S256', state, nonce });
  return { verifier, state, nonce, url };
}

export function validateCallbackRequest(request, config, expectedState) {
  const redirect = new URL(config.redirectUri);
  if (request.method !== 'GET' || request.headers?.host !== redirect.host ||
      typeof request.url !== 'string' || request.url.length > 8192 || !request.url.startsWith('/callback?')) return null;
  try {
    const current = new URL(request.url, config.redirectUri);
    if (current.pathname !== redirect.pathname || current.origin !== redirect.origin || current.hash ||
        current.searchParams.getAll('state').length !== 1 || current.searchParams.get('state') !== expectedState ||
        current.searchParams.getAll('code').length + current.searchParams.getAll('error').length !== 1 ||
        !(current.searchParams.get('code') || current.searchParams.get('error'))) return null;
    return current;
  } catch {
    return null;
  }
}

export async function interactiveLogin(config, session, authorization) {
  await session.prepare();
  const login = await createLoginRequest(config, authorization.server);
  const redirect = new URL(config.redirectUri);
  let complete;
  let failed;
  let received;
  const callback = new Promise((resolveCallback, rejectCallback) => { complete = resolveCallback; failed = rejectCallback; });
  callback.catch(() => {});
  const server = createServer((request, response) => {
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('Content-Type', 'text/plain; charset=utf-8');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    const current = validateCallbackRequest(request, config, login.state);
    if (!current || received) {
      response.writeHead(400).end('Invalid sign-in state.'); return;
    }
    received = response;
    complete(current);
  });
  server.headersTimeout = 10000;
  server.requestTimeout = 15000;
  const timeout = setTimeout(() => failed(new Error('Sign-in timed out.')), 180000);
  try {
    await new Promise((resolveListen, rejectListen) => {
      server.once('error', rejectListen);
      server.listen(Number(redirect.port), '127.0.0.1', resolveListen);
    });
    const openBrowser = (await import('open')).default;
    await openBrowser(login.url.href, { wait: false });
    const current = await callback;
    const tokens = await oauth.authorizationCodeGrant(authorization.server, current,
      { pkceCodeVerifier: login.verifier, expectedState: login.state, expectedNonce: login.nonce, idTokenExpected: true });
    await persistTokens(tokens, null, config, session, authorization);
    received.writeHead(200).end('Sign-in complete. You can close this window.');
  } catch (error) {
    if (received && !received.writableEnded) received.writeHead(400).end('Sign-in failed. Return to your terminal.');
    throw error;
  } finally {
    clearTimeout(timeout);
    server.closeAllConnections();
    await new Promise(resolveClose => server.close(resolveClose));
  }
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length < 2 || args.length > 3 || args[0] !== '--config' ||
      (args[2] && !['--login', '--logout', '--validate-config'].includes(args[2]))) throw new Error('Unsupported command.');
  const path = resolve(args[1]);
  if ((await stat(path)).size > 16384) throw new Error('Client settings exceed their size limit.');
  const config = parseConfig(JSON.parse(await readFile(path, 'utf8')));
  if (args[2] === '--validate-config') { process.stdout.write('Okta client configuration is valid.\n'); return; }
  const result = await withStoredSession(config, async session => {
    if (args[2] === '--logout') {
      try {
        const cached = await session.load();
        if (cached?.refreshToken) {
          const authorization = await createAuthorizationServer(config);
          await authorization.revoke(cached.refreshToken);
        }
      } finally { await session.clear(); }
      process.stderr.write('Okta refresh grant revoked and local credential cache removed.\n');
      return null;
    }
    const authorization = await createAuthorizationServer(config);
    if (args[2] === '--login') {
      await interactiveLogin(config, session, authorization);
      process.stderr.write('Okta sign-in stored in the OS-protected credential cache.\n');
      return null;
    }
    return acquireToken(config, session, authorization);
  });
  if (result) process.stdout.write(result + '\n');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(() => {
    process.stderr.write('BYOK Okta credential failed. Check the pinned settings and OS keystore, then sign in explicitly outside Copilot. No credential was returned.\n');
    process.exitCode = 1;
  });
}