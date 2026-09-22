# BYOK credential refresh: current status and original request

## Current status (2026-09-21)

The request was filed as [github/copilot-cli#3682](https://github.com/github/copilot-cli/issues/3682).
Its issue state was still open when checked on 2026-09-16, but CLI **1.0.85** provider help
documents `COPILOT_PROVIDER_API_KEY_COMMAND`, a command that prints a credential per request.
The paired wrappers now support opt-in per-request Azure CLI token acquisition. Local helper,
wrapper, and real CLI loopback tests passed. An interactive Government VM user also passed
both Responses and Chat Completions through private APIM using CLI 1.0.85 and the pinned token
helper against an isolated synthetic fixture. **Model inference and actual-expiry renewal
testing remain pending**.
The installed 1.0.75 help did not expose that command. Do not infer capabilities solely from
issue closure or the bundled CLI version.

| Client | Current evidence | Remaining work for this gateway |
|---|---|---|
| CLI 1.0.85 | Government VM Responses/Chat CLI calls passed private APIM with the token helper and synthetic response proofs; local retry and fail-closed tests pass | Real model inference, same-session renewal across actual expiry, utility/discovery requests, MFA and renewal failure |
| VS Code Custom Endpoint | Static secret-backed `apiKey`; `${apiKey}` interpolation in custom headers | No documented command-based renewal; see [#325811](https://github.com/microsoft/vscode/issues/325811), open when checked |
| VS Code built-in Azure provider | Microsoft authentication session obtained per request for Cognitive Services | This scope does not satisfy our custom gateway audience; not a drop-in renewal solution |
| IntelliJ AI Assistant / other providers | Header and renewal capabilities depend on the provider | Verify token renewal and the proxy's Bearer-to-`api-key` rewrite |

CLI custom headers also ship as `COPILOT_PROVIDER_HEADERS`, despite
[#3399](https://github.com/github/copilot-cli/issues/3399) still being open when checked.
`COPILOT_PROVIDER_BEARER_TOKEN` controls placement of a static token, not renewal.
VS Code's original header bug [#317810](https://github.com/microsoft/vscode/issues/317810)
was closed; [#320727](https://github.com/microsoft/vscode/issues/320727) remained reopened.
Current [VS Code documentation](https://code.visualstudio.com/docs/agent-customization/language-models)
supports `${apiKey}` in `requestHeaders`; the older plaintext-only guidance is superseded.

The gateway still selects key-only or Entra-JWT-only mode per deployment. **Same-endpoint
key OR Entra JWT OR Okta JWT is planned, not shipped.** Okta requires its own token helper
and issuer validation; changing IdP does not remove renewal requirements. See
[the authentication design](authentication.md) for the full contract, coverage and test gates.

## Opt-in CLI renewal

For an approved JWT-enabled endpoint, use the existing wrappers:

```powershell
./scripts/copilot-cli-byok.ps1 -AuthMode jwt -RefreshToken `
  -AppId '<CLIENT_ID>' -ApimBaseUrl 'https://<APIM_HOST>/openai' -Model '<MODEL>'
```

```bash
AUTH_MODE=jwt REFRESH_TOKEN=1 source ./scripts/copilot-cli-byok.sh \
  'https://<APIM_HOST>/openai' '<MODEL>' '<CLIENT_ID>'
```

Prerequisites: Azure CLI with `expires_on` token metadata, a delegated sign-in for the gateway
scope, and a Copilot CLI whose provider help advertises `COPILOT_PROVIDER_API_KEY_COMMAND`.
Bash additionally requires `jq`. Complete sign-in outside Copilot before configuring the wrapper.

The paired [PowerShell](../scripts/get-byok-token.ps1) and [Bash](../scripts/get-byok-token.sh)
helpers pin the cloud, tenant, account, and Azure CLI cache selected at setup. They never log in
or switch clouds. Each invocation asks Azure CLI for a gateway-scoped token; Azure CLI owns
caching and silent renewal, so a valid cached token can be reused. Missing, expired, near-expiry,
malformed, wrong-tenant, or failed token results stop the request with no credential output.
The helpers do not validate the JWT signature; that remains the gateway's responsibility.

Refresh mode clears static API-key and Bearer variables. Static-key mode clears a stale
credential command. Credential-bearing `COPILOT_PROVIDER_HEADERS` entries are rejected.
No access or refresh tokens are saved by these helpers, and no fallback to an old key is used.
The generated command contains nonsecret context; do not paste it into shared diagnostics.
`-RefreshToken` cannot be combined with `-Test`; it configures the CLI, not the curl smoke test.

**VM requirement:** the private APIM endpoint must be tested from the in-VNet VM. A local
Windows/Bastion account is sufficient for entering the VM; Azure CLI's delegated sign-in is
separate and can use a device code completed in a laptop browser. Run Command uses SYSTEM,
which does not inherit the interactive user's installed CLI or Azure login. Do not copy a
laptop token cache to work around that boundary. Configuring renewal does not convert a
key-only production API into a JWT-enabled or coexistence API.

## Validation evidence

On 2026-09-21, the interactive Government VM user completed the isolated no-backend gateway
check with strict TLS and certificate-revocation validation enabled. Missing and invalid
credentials each returned 401. Two invocations of the pinned token helper each returned 200
with the expected probe identity and credential-stripping marker. Tenant, VNet and auth-only
policy ownership checks passed. The explicitly approved VM-only outbound TCP-80 CRL window
was removed and its removal verified before the overall success result.

This proves user-session acquisition and private APIM acceptance, not two distinct token
issuances: Azure CLI may reuse a cached token. No Copilot inference, model backend, actual
expiry, cross-cloud parity, or production key/JWT coexistence was exercised by that check.

The subsequent interactive VM run also passed the real Copilot CLI gateway check. Both
Responses and Chat Completions reported CLI 1.0.85, exit code 0, one token-helper invocation,
and a matching unique synthetic response proof. Each disposable operation first rejected
missing and invalid credentials with 401; the missing-credential response carried its expected
route marker. The test API, local CLI files, and temporary CRL rule were removed successfully.
The TLS-revocation preflight remained enabled and no certificate-validation bypass was added.

This establishes the CLI/helper/private-gateway path for both wire formats in Government.
Each format used a separate short-lived CLI process and no model backend. It does not prove
renewal within one continuing CLI session, distinct token issuance, actual expiry, or automatic
401 recovery. Those gates, model inference, and cross-cloud coexistence acceptance remain open;
production authentication was not changed.

The no-Azure PowerShell and Bash regression suites cover context changes, token failures and
expiry, stdout hygiene, command quoting, unsupported CLI versions, and credential-source
transitions. They run in the existing validation workflow.

```powershell
./scripts/tests/copilot-credential.Tests.ps1
```

```bash
bash scripts/tests/copilot-credential.Tests.sh
node --test scripts/tests/copilot-credential-wire.test.mjs
```

The Node suite uses CLI 1.0.85, an isolated configuration directory, offline mode, a loopback
provider, synthetic rotating credentials, and no available tools. Both Responses and Chat
Completions acquired a new synthetic credential for each HTTP attempt after a 503, and a
credential-command failure produced zero provider requests. These are mechanism tests, not
real Entra expiry, automatic 401 recovery, or APIM acceptance. Discovery and every utility
request path are not yet proven.

The same loopback suite now verifies that the Azure provider preserves a configured
`/jwt-probe-fixture/openai` prefix, producing `/v1/responses` and `/v1/chat/completions` beneath
it. Older origin-only routing observations do not describe this tested client behavior.
This permits a separately scoped test API; it does not enable JWT on the key-only production API.

On this laptop, `--no-auto-update` selected bundled 1.0.75 instead of cached 1.0.85. The test
uses offline mode and a native executable/npm launcher to avoid that downgrade. The VS Code
outer PowerShell launcher did not preserve the CLI's failure exit status; invoke a native
launcher for automation and use `COPILOT_TEST_EXECUTABLE` when explicit selection is needed.

### Real-expiry gate prepared

The [persistent session driver](../scripts/copilot-credential-session.mjs) uses ACP to keep one
CLI 1.0.85 process and session alive for each wire format. The isolated-home, offline local test
now passes ACP session creation without supplied GitHub credentials, two prompts in one session,
and a later credential-helper failure with no provider request. The older ACP login-gate result
is not reproduced in this tested configuration. ACP can report a helper error in a session update
while returning `end_turn`; the gate requires a fresh gateway proof, not just a completed RPC.

The VM checker offers an explicit `-TestExpiry` opt-in together with `-TestCopilot` and the
approved temporary CRL allowance. The owner approved a disposable no-model API window of up
to two hours. The driver records only acquisition/expiry timestamps and SHA-256 token
fingerprints locally, never token text. It waits until both initial tokens have expired plus
10 seconds; fixture validation explicitly requires expiration with zero clock skew. The CRL
rule is removed during the idle period and reopened only for the final checks. No VM clock,
token lifetime, forced refresh, or sign-in is changed.

Acceptance requires a fresh timestamped gateway response before and after expiry in each
unchanged process/session, a later token expiry, a different fingerprint, and acquisition after
the original expiry. Normal fixture, local-file and CRL-rule cleanup remains mandatory. The
interactive VM window must remain open; do not run another sign-in or alter its cache during
the test. Waiting beyond the bounded budget, an expired/stale token, helper failure, process
exit, or cleanup failure cannot count as success.

All nine real-CLI loopback tests pass, including simulated-time expiry success, early resume,
stale metadata, renewal failure and cancellation. The timestamped policies also passed
Government create/readback/delete validation. These preparation checks are **not live expiry
acceptance**; the real VM run remains pending.

## Historical request and June findings

The remainder preserves the original proposal and June 2026 observations. Statements below
about missing CLI command support, absent upstream filing or all VS Code providers lacking
Entra renewal are historical, not current guidance. The proposed file-backed credential,
automatic 401 retry and caching semantics below are not claimed as shipped features.

## Title

Support refreshing the BYOK provider credential without restarting the CLI

## Describe the feature or problem you'd like to solve

When using a BYOK provider with a **short-lived bearer credential** (e.g. an Entra ID /
Azure AD OAuth access token, an AWS STS token, or any OIDC JWT), the Copilot CLI reads
`COPILOT_PROVIDER_API_KEY` (and any custom headers) **once at process startup** and reuses
that static value for the lifetime of the interactive session.

Entra access tokens live ~60–90 minutes. In a long interactive coding session the token
expires mid-conversation, the upstream gateway (e.g. Azure API Management running
`validate-jwt`) starts returning **HTTP 401**, and the CLI has **no way to obtain a fresh
credential** short of killing and relaunching the process — which loses the conversation
context.

This forces BYOK deployments that want true per-user identity (rather than a long-lived
static API key) to run an external **local reverse-proxy sidecar** purely to re-mint and
inject a fresh token on each request. That sidecar is the only reason JWT-based auth can't
be the simple default for enterprise/regulated (e.g. Azure Government) BYOK setups.

Note: this is **not** solved by custom-header support (#3399). Custom headers would still be
read once at startup and held static. The gap is specifically the *refresh* of a
short-lived credential during a live session.

## Proposed solution

Provide a way for the CLI to obtain a fresh credential per request (or on 401), e.g. one of:

1. **Credential command (preferred).** A new env var, e.g.
   `COPILOT_PROVIDER_API_KEY_COMMAND="az account get-access-token --scope <appId>/.default --query accessToken -o tsv"`.
   The CLI executes it to obtain the credential, caches the result, and **re-executes it**
   when the credential is near expiry or when the provider returns 401. Mirrors the
   well-established `credential_process` / `credHelpers` patterns in the AWS CLI, kubectl
   exec-credential, Git credential helpers, and Docker credential helpers.

2. **File-backed credential.** `COPILOT_PROVIDER_API_KEY_FILE=/path/to/token` where the CLI
   re-reads the file per request (an external `az`/cron/sidecar keeps it fresh). Simpler but
   weaker than option 1.

3. **Native OAuth client-credential / refresh-token flow** for `COPILOT_PROVIDER_TYPE=azure`
   that the CLI manages internally (mint + silent refresh).

Reactive trigger: on a `401` from the provider, the CLI should refresh the credential once
and retry the request transparently before surfacing the error.

## Example prompts or workflows

```bash
export COPILOT_PROVIDER_TYPE=azure
export COPILOT_PROVIDER_BASE_URL=https://my-apim.azure-api.us/openai
export COPILOT_MODEL=gpt-5.1
# CLI runs this to get a token, and re-runs it automatically before expiry / on 401:
export COPILOT_PROVIDER_API_KEY_COMMAND='az account get-access-token --scope <API_AUDIENCE>/.default --query accessToken -o tsv'
copilot   # stays authenticated across a multi-hour session, no restarts
```

## Additional context

- Validated working today (2026-06-03) against an Azure Government APIM gateway: an Entra JWT
  in the `api-key` header passes `validate-jwt` and returns a `gpt-5.1` completion (HTTP 200);
  a bad token returns HTTP 401. The **only** operational gap for interactive use is that the
  token cannot be refreshed in-session.
- Prior art for "run a command to get a credential": AWS CLI `credential_process`, kubernetes
  client-go exec credential plugins, Git/Docker credential helpers.
- Relationship to other issues:
  - #3399 (custom headers): complementary cleanup; would let the JWT ride in a real
    `Authorization` header, but does **not** address refresh.
  - #3448 (extra request params): unrelated (request body params, not auth).

## Editor support status (verified 2026-06-16)

Definitive answer to "does the editor refresh an expiring JWT, or will users have to
re-auth to APIM every ~hour?" — **No editor refreshes the credential in-session today.**
The credential is read from static config once and reused for the session's lifetime.

| Client | Where the credential lives | Refreshed in-session? | Source |
|---|---|---|---|
| **Copilot CLI** (BYOK `azure`) | `COPILOT_PROVIDER_API_KEY` env var, read once at process start | **No** — restart only | This doc (validated 2026-06-03) |
| **VS Code** (BYOK `azure` vendor) | `chatLanguageModels.json`: static `apiKey` + `url` | **No** | VS Code docs ¹ |
| **VS Code** (Custom Endpoint provider) | `chatLanguageModels.json`: static `apiKey` + `?_vscodeauth=openai.azure` url param | **No** | VS Code docs ¹ |

¹ [VS Code — AI language models / Bring your own language model key](https://code.visualstudio.com/docs/copilot/customization/language-models)
(page last edited 2026-06-10; fetched 2026-06-16). The BYOK "Model configuration reference"
defines `apiKey`, `url`, and `requestHeaders` as static config fields. There is **no**
documented credential-command, token-file, OAuth, or refresh-token mechanism for any vendor,
and the page's own Azure example is a static "Entra ID authentication" config (a fixed key/URL,
not a refreshing token).

### What HAS changed since this draft was written
- VS Code BYOK now exposes a per-model **`requestHeaders`** object (the custom-headers ask,
  cf. CLI #3399). This lets a JWT ride in a real header (e.g. `Authorization: Bearer …`)
  instead of `api-key` — **but it is still read once and held static**, so it does NOT solve
  refresh. (Reserved forbidden/forwarding/internal headers are stripped by VS Code.)
- The `azure` vendor and the **Custom Endpoint** provider both accept a full custom `url`,
  so pointing either editor at our APIM gateway (`https://<apim>.azure-api.us/…`) is supported.

### Implication for an unattended fleet rollout
- **JWT mode** (`byok-aoai-policy.xml`, `validate-jwt`): a per-user Entra access token
  (~60-90 min TTL) expires mid-session → APIM returns `401` → the user must relaunch / re-paste
  a fresh token. Across a few hundred unattended machines this is an hourly 401 wave. Only viable
  with an external local credential-refresh sidecar (the gap this feature request asks upstream
  to close).
- **Subscription-key mode** (`byok-aoai-policy-subkey.xml` + `apim-subscriptions.bicep`): a
  long-lived per-developer APIM subscription key, validated natively by APIM, with identity for
  telemetry/throttling taken from `context.Subscription`. **No hourly expiry → paste once.**
  This is the recommended fleet default; keep JWT mode for the few users who need true per-user
  Entra identity and can run the refresh sidecar.
