# Okta Credential Helper

Opt-in public-client credentials for the shared gateway contract. This helper is locally tested;
real customer Okta acceptance remains issue #146. It does not enable Okta on APIM or add Okta
sign-in to the registration app. Native APIM subscription keys remain the default.

## Requirements

- Node.js 22+, HTTPS access to the configured Okta custom authorization server and its JWKS.
- An Okta native/public application with authorization-code + PKCE and refresh-token grants,
  token endpoint authentication `none`, and the exact registered loopback callback URI.
- A custom API audience and `cli.invoke` scope. The signed access JWT must use RS256, contain
  the configured `cid`, and set both `sub` and `uid` to the same immutable Okta user ID.
- The matching issuer, audience, client and scope must be explicitly allowed by the gateway.
  Org-authorization-server tokens and confidential-client secrets are not supported.
- Windows Credential Manager, macOS Keychain, or Linux Secret Service. Linux has no plaintext
  or in-memory fallback; headless machines need an approved Secret Service session.

Check the customer's API Access Management licensing, compliance boundary, sign-in policies,
user assignment, refresh-token rotation and IdP egress before activation.

## Setup

Run `npm ci --ignore-scripts --no-fund` in this directory. Use [client.example.json](client.example.json)
as the shape for a local, nonsecret configuration. The ignored `client.local.json` is one option;
never commit live domain, client or user values. No password, access token or refresh token belongs
in this configuration.

From the repository root:

```powershell
./scripts/get-okta-token.ps1 -ConfigFile ./scripts/okta/client.local.json -ValidateOnly
./scripts/get-okta-token.ps1 -ConfigFile ./scripts/okta/client.local.json -Login
./scripts/copilot-cli-byok.ps1 -AuthMode okta -OktaConfigFile ./scripts/okta/client.local.json -ApimBaseUrl 'https://<GATEWAY_HOST>' -Model '<MODEL>'
```

```bash
bash scripts/get-okta-token.sh --config scripts/okta/client.local.json --validate-config
bash scripts/get-okta-token.sh --config scripts/okta/client.local.json --login
AUTH_MODE=okta OKTA_CONFIG_FILE="$PWD/scripts/okta/client.local.json" source scripts/copilot-cli-byok.sh 'https://<GATEWAY_HOST>' '<MODEL>'
```

Sign-in opens the system browser and binds only the registered `127.0.0.1` port for at most three
minutes. PKCE, state and nonce are fresh per attempt. A different signed-in user is rejected, not
silently adopted. Normal credential-command invocations never open a browser.

The CLI must advertise `COPILOT_PROVIDER_API_KEY_COMMAND`. The launcher clears static key and
Bearer-token settings, keeps Responses as the default wire API, and sends one access token in
`api-key`. Do not add an `Authorization` credential through custom headers. Do not run the token-only
helper in a terminal transcript or paste its output into chat: stdout is intentionally the access
token for its consuming client. Diagnostics are generic and go to stderr.

## Storage And Recovery

The OS keystore holds only a random 256-bit cache-encryption key. Access/refresh tokens are encrypted
with AES-256-GCM under the user's home directory at `.copilot/byok-okta/<configuration-hash>`.
Authenticated encryption binds the cache to issuer, client, audience, scope, user and callback.
An interprocess lock serializes refresh-token rotation. No refresh secret is placed in process
arguments, provider configuration or plaintext files. Cache corruption, unavailable keystore,
identity mismatch and renewal failure produce no access-token output.

`invalid_grant` clears local credentials. Correct settings or user assignment and explicitly sign
in again outside Copilot. Issuer/client/user changes create a different cache; log out of the old
configuration before retiring it. Do not delete ownership keys or APIM subscriptions as a substitute
for IdP revocation.

```powershell
./scripts/get-okta-token.ps1 -ConfigFile ./scripts/okta/client.local.json -Logout
```

```bash
bash scripts/get-okta-token.sh --config scripts/okta/client.local.json --logout
```

Logout attempts refresh-grant revocation and always removes the local cache, including when
discovery/revocation fails. A failed remote revocation still needs operator follow-up. Already
issued access tokens can remain valid until expiry; signing out does not revoke an APIM key.

The approved renewable editor route is the configured native Copilot CLI, including an IntelliJ
custom CLI ACP agent. Actual editor launch, expiry and failure/recovery still need acceptance;
the CLI fixture test alone does not prove either UI integration. Native VS Code Custom Endpoint
and IntelliJ AI Assistant keep per-user APIM subscription keys. Neither invokes this helper or
renews a pasted JWT automatically; no new native-provider adapter is part of this scope.

## Tests

`npm test` uses locally signed fixture JWTs and a mocked keystore. It covers issuer/client/user/scope
checks, PKCE, expired-token refresh, rotation, concurrent callers, revoked grants, vault failures,
encrypted-cache tampering and configuration binding. `BYOK_TEST_OS_KEYRING=1 npm test` additionally
creates and deletes one unique synthetic OS-keystore entry. The native Windows test passed; this
does not establish macOS/Linux keystore or real Okta acceptance. `npm audit --omit=dev` checks the
pinned dependency inventory.