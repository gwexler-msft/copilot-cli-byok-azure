import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import * as oauth from 'openid-client';
import { generateKeyPair, jwtVerify, SignJWT } from 'jose';
import { acquireToken, configKey, createLoginRequest, parseConfig, persistTokens, validateAccessClaims, validateCallbackRequest, withStoredSession } from './token.mjs';

const config = parseConfig({ issuer: 'https://identity.example.test/oauth2/fixture', clientId: 'fixture-client',
  audience: 'api://fixture-gateway', requiredScope: 'cli.invoke', subject: 'fixture-user', redirectUri: 'http://127.0.0.1:8765/callback' });
const { privateKey, publicKey } = await generateKeyPair('RS256');
const now = () => Math.floor(Date.now() / 1000);
const claims = changes => ({ iss: config.issuer, aud: config.audience, cid: config.clientId, sub: config.subject,
  uid: config.subject, scp: ['cli.invoke'], exp: now() + 3600, ...changes });
const sign = (changes = {}) => new SignJWT(claims(changes)).setProtectedHeader({ alg: 'RS256' }).sign(privateKey);
const verify = token => jwtVerify(token, publicKey, { algorithms: ['RS256'], issuer: config.issuer, audience: config.audience });

test('Okta trust settings reject implicit servers, credentials and unsafe callbacks', () => {
  for (const changes of [{ issuer: 'http://identity.example.test/oauth2/fixture' }, { issuer: 'https://identity.example.test' },
    { issuer: 'https://user:password@identity.example.test/oauth2/fixture' }, { issuer: 'https://127.0.0.1/oauth2/fixture' },
    { issuer: config.issuer + '/' }, { clientSecret: 'forbidden' }, { subject: 'mutable@example.test' },
    { redirectUri: 'http://0.0.0.0:8765/callback' }, { redirectUri: 'http://localhost:8765/callback' },
    { redirectUri: 'http://127.0.0.1:80/callback' }, { requiredScope: 'offline_access' }]) {
    assert.throws(() => parseConfig({ ...config, ...changes }));
  }
  assert.notEqual(configKey(config), configKey({ ...config, subject: 'other-user' }));
});

test('signed access tokens retain an immutable user, exact client and API scope', async () => {
  const token = await sign();
  const verified = await verify(token);
  assert.ok(validateAccessClaims(verified.payload, verified.protectedHeader, config) > now());
  for (const changes of [{ cid: 'other-client' }, { uid: 'other-user' }, { sub: 'other-user' },
    { scp: 'cli.invoke' }, { scp: ['other'] }, { scp: ['cli.invoke', 'cli.invoke'] }, { exp: 'invalid' }]) {
    assert.throws(() => validateAccessClaims(claims(changes), { alg: 'RS256' }, config));
  }
  await assert.rejects(verify(await sign({ iss: 'https://other.example.test/oauth2/fixture' })));
  await assert.rejects(verify(await sign({ aud: 'other-audience' })));
  await assert.rejects(verify(await sign({ exp: now() - 30 })));
  const other = await generateKeyPair('RS256');
  await assert.rejects(verify(await new SignJWT(claims()).setProtectedHeader({ alg: 'RS256' }).sign(other.privateKey)));
});

test('valid cached tokens do not refresh; expiry rotates the refresh grant exactly once', async () => {
  const first = await sign();
  let cached = { accessToken: first, refreshToken: 'refresh-first' };
  let calls = 0;
  const session = { load: async () => cached, save: async value => { cached = value; }, clear: async () => { cached = null; } };
  const renewed = await sign({ jti: 'renewed' });
  const authorization = { verify, refresh: async token => {
    assert.equal(token, 'refresh-first'); calls++;
    return { access_token: renewed, refresh_token: 'refresh-second', token_type: 'Bearer' };
  } };
  assert.equal(await acquireToken(config, session, authorization), first);
  assert.equal(calls, 0);
  cached.accessToken = await sign({ exp: now() - 1 });
  assert.equal(await acquireToken(config, session, authorization), renewed);
  assert.equal(cached.refreshToken, 'refresh-second');
  assert.equal(calls, 1);
  assert.equal(await acquireToken(config, session, authorization), renewed);
  assert.equal(calls, 1);
});

test('renewal and vault failures never release a token or switch the pinned user', async () => {
  let cached = { refreshToken: 'refresh-first' };
  const session = { load: async () => cached, save: async value => { cached = value; }, clear: async () => { cached = null; } };
  await assert.rejects(acquireToken(config, session, { verify, refresh: async () => { throw { error: 'invalid_grant' }; } }));
  assert.equal(cached, null);
  await assert.rejects(acquireToken(config, session, { verify, refresh: async () => assert.fail('Must not start a grant') }));
  const tokens = { access_token: await sign({ sub: 'other-user', uid: 'other-user' }), refresh_token: 'refresh-other', token_type: 'Bearer' };
  await assert.rejects(persistTokens(tokens, null, config, session, { verify }));
  assert.equal(cached, null);
  tokens.access_token = await sign();
  await assert.rejects(persistTokens(tokens, null, config, { save: async () => { throw new Error('Vault unavailable'); } }, { verify }));
  await assert.rejects(persistTokens({ id_token: tokens.access_token }, null, config, session, { verify }));
});

test('PKCE, state and nonce are fresh, and no confidential-client secret is used', async () => {
  const server = new oauth.Configuration({ issuer: config.issuer, authorization_endpoint: config.issuer + '/v1/authorize' },
    config.clientId, { token_endpoint_auth_method: 'none' }, oauth.None());
  const first = await createLoginRequest(config, server);
  const second = await createLoginRequest(config, server);
  assert.notEqual(first.verifier, second.verifier);
  assert.notEqual(first.state, second.state);
  assert.notEqual(first.nonce, second.nonce);
  assert.equal(first.url.searchParams.get('code_challenge_method'), 'S256');
  assert.equal(first.url.searchParams.get('code_challenge'), createHash('sha256').update(first.verifier).digest('base64url'));
  assert.equal(first.url.searchParams.get('redirect_uri'), config.redirectUri);
  assert.equal(first.url.searchParams.get('scope'), 'openid offline_access cli.invoke');
  assert.ok(!first.url.href.includes(first.verifier));
});

test('loopback callback rejects wrong hosts, state, duplicate results and invalid request targets', () => {
  const valid = { method: 'GET', headers: { host: '127.0.0.1:8765' }, url: '/callback?state=fixture-state&code=fixture-code' };
  assert.equal(validateCallbackRequest(valid, config, 'fixture-state').searchParams.get('code'), 'fixture-code');
  assert.equal(validateCallbackRequest({ ...valid, url: '/callback?state=fixture-state&error=access_denied' }, config, 'fixture-state')
    .searchParams.get('error'), 'access_denied');
  for (const changed of [{ method: 'POST' }, { headers: { host: 'localhost:8765' } }, { headers: { host: 'attacker.example.test:8765' } },
    { url: 'https://attacker.example.test/callback?state=fixture-state&code=fixture-code' },
    { url: '//attacker.example.test/callback?state=fixture-state&code=fixture-code' },
    { url: '/other?state=fixture-state&code=fixture-code' }, { url: '/callback?state=wrong&code=fixture-code' },
    { url: '/callback?code=fixture-code' }, { url: '/callback?state=fixture-state&state=fixture-state&code=fixture-code' },
    { url: '/callback?state=fixture-state&code=one&code=two' }, { url: '/callback?state=fixture-state&code=one&error=access_denied' },
    { url: '/callback?state=fixture-state&code=' }, { url: '/callback?state=fixture-state&code=fixture-code#fragment' },
    { url: '/callback?state=fixture-state&code=' + 'a'.repeat(8192) }]) {
    assert.equal(validateCallbackRequest({ ...valid, ...changed }, config, 'fixture-state'), null);
  }
});

test('cache is encrypted, bound to the trust configuration and serialized during refresh', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'byok-okta-test-'));
  let secret = null;
  const entry = { getPassword: () => secret, setPassword: value => { secret = value; }, deleteCredential: () => { secret = null; } };
  const options = { directory, entry };
  try {
    const initial = { refreshToken: 'fixture-secret-refresh', accessToken: await sign({ exp: now() - 1 }) };
    await withStoredSession(config, session => session.save(initial), options);
    const cachePath = join(directory, configKey(config), 'session.enc');
    const ciphertext = await readFile(cachePath, 'utf8');
    assert.ok(!ciphertext.includes(initial.refreshToken) && !ciphertext.includes(initial.accessToken) && !ciphertext.includes(secret));
    assert.deepEqual(await withStoredSession(config, session => session.load(), options), initial);
    let calls = 0;
    const token = await sign({ jti: 'concurrent-renewal' });
    const authorization = { verify, refresh: async () => { calls++; return { access_token: token, refresh_token: 'fixture-rotated', token_type: 'Bearer' }; } };
    const results = await Promise.all([1, 2, 3].map(() => withStoredSession(config, session => acquireToken(config, session, authorization), options)));
    assert.deepEqual(results, [token, token, token]);
    assert.equal(calls, 1);
    const otherConfig = { ...config, subject: 'other-user' };
    await withStoredSession(otherConfig, session => session.save({ accessToken: 'fixture', refreshToken: 'fixture' }), options);
    await writeFile(join(directory, configKey(otherConfig), 'session.enc'), ciphertext);
    await assert.rejects(withStoredSession(otherConfig, session => session.load(), options));
    const changed = JSON.parse(await readFile(cachePath, 'utf8'));
    changed.tag = Buffer.alloc(16).toString('base64');
    await writeFile(cachePath, JSON.stringify(changed));
    await assert.rejects(withStoredSession(config, session => session.load(), options));
    await withStoredSession(config, session => session.clear(), options);
    assert.equal(secret, null);
    await assert.rejects(readFile(cachePath));
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('OS keystore entry round-trip and exact cleanup', { skip: process.env.BYOK_TEST_OS_KEYRING !== '1' }, async () => {
  const { Entry } = await import('@napi-rs/keyring');
  const entry = new Entry('copilot-byok-okta-test', randomUUID(), { linux: { store: 'secret-service' } });
  assert.equal(entry.getPassword(), null, 'Only a new, uniquely owned test entry may be changed');
  try {
    entry.setPassword('synthetic-keystore-fixture');
    assert.equal(entry.getPassword(), 'synthetic-keystore-fixture');
  } finally {
    entry.deleteCredential();
    assert.equal(entry.getPassword(), null, 'The exact temporary test credential must be absent');
  }
});