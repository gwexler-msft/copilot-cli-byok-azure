# BYOK credential refresh: current status and original request

## Current status (2026-09-23)

The request was filed as [github/copilot-cli#3682](https://github.com/github/copilot-cli/issues/3682).
Its issue state was still open when checked on 2026-09-16, but CLI **1.0.85** provider help
documents `COPILOT_PROVIDER_API_KEY_COMMAND`, a command that prints a credential per request.
The paired wrappers now support opt-in per-request Azure CLI token acquisition. Local helper,
wrapper, and real CLI loopback tests passed. An interactive Government VM user also passed
both Responses and Chat Completions through private APIM using CLI 1.0.85 and the pinned token
helper against an isolated synthetic fixture. A subsequent continuing-session test passed
renewal across actual token expiry for both wire formats. Real Responses inference also passed
with matching persisted token metrics. **Use Responses for GPT-5.6 coding with tools and
reasoning.** The captured Chat 400 matches Microsoft's documented restriction on that
combination; the owner selected Responses rather than disabling reasoning for Chat.
The installed 1.0.75 help did not expose that command. Do not infer capabilities solely from
issue closure or the bundled CLI version.

| Client | Current evidence | Remaining work for this gateway |
|---|---|---|
| CLI 1.0.85 | Government VM authentication and actual-expiry renewal passed for both formats; real Responses inference and matching persisted token metrics passed; GPT-5.6 tools plus reasoning uses Responses | Utility/discovery requests, MFA and live renewal-failure coverage, Commercial acceptance |
| CLI Okta credential equivalent | Opt-in PKCE helper, locally signed JWT/refresh/callback fixtures, encrypted cache, Windows keystore round-trip and paired launcher tests | Real Okta policy/MFA/rotation and customer end-to-end acceptance; no live Okta request was made |
| VS Code CLI-backed agent | Pinned launcher passed local real-CLI HTTPS ACP renewal and failed-helper rejection | Verify the actual editor launch path, private gateway routing, same-session expiry and failure/recovery; ordinary Agent mode and native background/Agent Host bridges are not proof of the configured CLI path |
| IntelliJ custom Copilot CLI ACP agent | CLI ACP actual-expiry evidence and pinned-launcher HTTPS fixture evidence exist independently of the IDE | Verify IntelliJ launches the intended CLI/version with the pinned credential helper and handles renewal failures |
| VS Code Custom Endpoint | Static secret-backed `apiKey`; `${apiKey}` interpolation in custom headers | Supported native experience remains per-user APIM subscription keys; native JWT renewal is outside the approved delivery boundary |
| VS Code built-in Azure provider | Microsoft authentication session obtained per request for Cognitive Services | This scope does not satisfy our custom gateway audience; not a drop-in renewal solution |
| IntelliJ native AI Assistant provider | Per-user APIM subscription key through the private Bearer-to-`api-key` proxy | Verify key/proxy regression; native JWT renewal is outside the approved delivery boundary |

### Approved Client Boundary (2026-09-23)

Renewable JWT access is delivered through the configured **GitHub Copilot CLI agent**, including
its editor integrations. VS Code Custom Endpoint and IntelliJ's native AI Assistant provider remain
optional **per-user APIM subscription-key** experiences. No new native-provider refresh extension
or token-injecting adapter is required for this delivery. The underlying model/credential path,
not the label Chat or Agent in the UI, determines which contract applies.

This is a support decision, not an IDE acceptance pass. Each editor must demonstrably run the
intended CLI/version and credential command against the private gateway, survive token expiry in
one continuing session, and fail closed with clear recovery when renewal or reauthentication fails.
The CLI's independent ACP/expiry results are reusable evidence but do not prove editor launch
configuration. Gateway package, telemetry, network, rollback and rollout gates remain unchanged.
The owner explicitly selected **both** VS Code's configured CLI terminal and native Agent/Background
experience for acceptance, plus IntelliJ custom ACP, using the existing Government VM interactive
user session. Passing only the terminal is not sufficient for the native UI gate.

The [pinned launcher](../scripts/start-copilot-agent.ps1) and Bash entry point use a nonsecret
profile with an absolute native executable, workspace, HTTPS gateway and fixed identity/cache.
They select Responses, clear static provider credentials, disable remote/export and CLI logging,
and keep ACP stdout protocol-only. On 2026-09-23 all fifteen native CLI wire tests passed,
including the launcher with strict HTTPS, a mocked Azure CLI and the real CLI 1.0.85: one ACP
session renewed its credential, then a failed helper produced no provider traffic. Ten profile
validation cases also passed. No IDE settings were changed and no editor UI acceptance was claimed.

The current [VS Code model documentation](https://code.visualstudio.com/docs/agent-customization/language-models#_bring-your-own-language-model-key)
enables Agent Host BYOK through `chat.agentHost.byokModels.enabled`, using editor-configured models.
The inspected [upstream session launcher](https://github.com/microsoft/vscode/blob/b448f61ee36701890853135d7343e98968c26dfd/src/vs/platform/agentHost/node/copilot/copilotSessionLauncher.ts)
constructs loopback Responses providers from the editor's model bridge, authenticated with a
session-scoped bridge token. That is not the gateway's Entra access token and does not establish
use of `COPILOT_PROVIDER_API_KEY_COMMAND`. This source evidence is not a test of the VM's installed
version. Native Agent/Background JWT renewal remains an explicit gate; no unsupported setting,
token injection or replacement provider adapter is assumed.

CLI custom headers also ship as `COPILOT_PROVIDER_HEADERS`, despite
[#3399](https://github.com/github/copilot-cli/issues/3399) still being open when checked.
`COPILOT_PROVIDER_BEARER_TOKEN` controls placement of a static token, not renewal.
VS Code's original header bug [#317810](https://github.com/microsoft/vscode/issues/317810)
was closed; [#320727](https://github.com/microsoft/vscode/issues/320727) remained reopened.
Current [VS Code documentation](https://code.visualstudio.com/docs/agent-customization/language-models)
supports `${apiKey}` in `requestHeaders`; the older plaintext-only guidance is superseded.

Current deployments still select key-only or Entra-JWT-only mode. **Same-endpoint key OR Entra
JWT OR Okta JWT is implemented locally, not shipped.** The opt-in
[Okta helper](../scripts/okta/README.md) now supplies its own PKCE/secure-refresh implementation;
it does not enable gateway trust or make static-only IDE providers renewable. See
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
Each format initially used a separate short-lived CLI process and no model backend. That first
check did not prove renewal within one continuing session, actual expiry, or automatic 401
recovery. The subsequent real-expiry gate below closes the continuing-session renewal check;
the real-model results are recorded separately below. Automatic 401 recovery and cross-cloud
coexistence acceptance remain open.
Production authentication was not changed.

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
provider, synthetic rotating credentials, and tool-denial flags. These flags do not prove that
the API request contains no tool schemas. Both Responses and Chat
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

### Real-expiry gate passed

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
Government create/readback/delete validation. These preparation checks alone were not live
expiry acceptance.

The user subsequently completed the real Government VM run on 2026-09-21. Both wire formats
passed before expiry, waited 3,579 seconds, and passed after expiry with unchanged processes
and sessions, one helper call each, renewed-token evidence, and fresh gateway response proofs.
The CRL allowance was closed while idle and reopened for the final checks. The final summary
reported `actualExpiryTested=true`, with successful API, local-file, and CRL-rule removal.
This is live same-session renewal evidence for Government; no model backend was called.

### Bounded inference results

The owner approved small billable model calls through a disposable JWT-only API. Read-only
Government inventory matched the existing native managed-identity backend and ready
`gpt-5.6-sol` deployment to both surfaces in the gateway's configured model map. No model
deployment, production API, backend identity, named value, or network baseline was changed.

The VM checker's separate `-TestInference` mode requires `-TestCopilot` and the approved CRL
window; it cannot be combined with `-TestExpiry`. It pins the validated caller and model,
expires after 20 minutes, limits each wire format to one admitted request, caps request bodies
at 65,536 characters and output at 512 tokens, and disables backend retries. It reuses the JWT
validator, production body normalization, native routing, and per-user accounting patterns,
with fixture-specific counters. Automatic model selection and cross-cloud routing are excluded.

Both CLI runs must return the expected short response and report one model request with
nonzero input/output token counts. Existing Application Insights logging is enabled only for
the disposable API, with header/body capture and client-IP logging disabled. Successful CLI
usage evidence is not proof of durable metric ingestion: `telemetryVerified` remains false
until a separate in-VNet query succeeds. The fixture, local files, and CRL rule are removed
on both success and failure.

The bounded policies and diagnostic settings passed Government create/readback/delete checks
without model calls. Real-CLI loopback tests verified the marker header and usage-file fields
for both wire formats. The interactive Government VM run then produced these results:

| Surface | CLI evidence | Persisted evidence |
|---|---|---|
| Responses | Exit 0, one helper invocation, expected response, one model request, 10,491 input and 9 output tokens | Model dependency and frontend 200; token metrics exactly match: 10,491 prompt, 9 completion, 10,500 total |
| Chat Completions | Exit 1, one helper invocation, no successful model usage reported | Model Chat dependency and frontend 400; request metric present, no token usage metric |

The API, local files, and temporary CRL rule were removed successfully. An in-VNet aggregate
query selected the most recent CLI fixture in the preceding four hours through the same
diagnostic-bound Application Insights logger. The operator's query token was CMS-encrypted
to a temporary VM certificate; the certificate and local transport file were removed. The
query returned no raw URLs, identities, credentials, request bodies, or response bodies.

The failed Chat row originally reported `backendCalled=false` because usage was absent. That
inference was wrong: the correlated model dependency proves a backend request returned 400.
The checker now reports unknown backend contact when no successful usage evidence exists and
exposes only allowlisted HTTP statuses, error codes, and parameter names. Persisted telemetry
did not retain the rejection body, so it did not identify the offending field. The later
response capture below supplied that evidence. No production normalization was changed.

The staged `-InferenceWireApi completions` mode limits a diagnostic retry to the failed wire
format; it does not repeat Responses. Forty-eight local checker checks pass, including selected
wire scope, unknown backend contact, diagnostic sanitization, and cleanup. Focused actual-CLI
loopback tests also prove that a synthetic backend 400 surfaces its parameter name without a
retry. Local request-shape inspection is mechanism evidence only, not the cause of the live 400.
**Responses inference and matching token ingestion passed; the failed Chat call is retained
as negative evidence, not relabeled as a pass.**

The next direct Chat-only attempt still exited 1 with one helper invocation and no classified
CLI error, while all cleanup passed. Its latest telemetry could not be retrieved through the
operator's intermittently unavailable management reads, so the earlier confirmed backend 400
must not be assumed to describe every later attempt. That run did capture a fresh-route
404 followed by the marked 401 readiness response.

The owner explicitly approved one additional Chat-only diagnostic using the temporary
[loopback response capture](../scripts/copilot-inference-diagnostic.mjs). The VM checker enables
it only with `-CaptureInferenceResponse -TestInference -InferenceWireApi completions` and the
existing explicit Copilot/CRL switches. The listener binds to loopback, forwards at most one
request to the verified HTTPS fixture without rewriting the body or credential, rejects
redirects, and emits only allowlisted status/error metadata. Captured bodies and credentials
are not written to disk or returned in diagnostics. Normal fixture/rule cleanup still applies.

This changes the local client transport for diagnosis only; it is not a production proxy,
duplicate-header normalization, or a change to production URLs or authentication. Results
are labeled `routeMode=loopback-diagnostic` and cannot count as direct CLI inference acceptance.
Fifty local checker checks and focused real-CLI tests for error capture, one-request forwarding,
redirect rejection and sanitization passed. The completed VM capture forwarded one request and
received HTTP 400 with `invalid_request_error`, parameter `reasoning_effort`, and an
unsupported-request classification. All fixture, local-file, and CRL-rule cleanup passed.

### Model limitation and decision

[Microsoft's reasoning-model guidance](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/reasoning#tool-calling-with-reasoning-models)
documents that GPT-5.6 Chat Completions cannot combine function tools with reasoning. Requests
with tools require `reasoning_effort=none`; omitting the parameter is not a fix because the
model defaults to `medium`. Responses supports tools with reasoning and is the recommended
surface for that workflow.

The local CLI request characterization showed tool schemas and `reasoning_effort=medium`,
matching the captured rejected parameter and the documented restriction. Tool-denial flags
control execution; they must not be treated as proof that the outgoing `tools` field is empty.
The live dated backend API version was `2025-04-01-preview`, not an older version predating
reasoning support. Switching to v1 alone would not remove the documented model restriction.

On 2026-09-21, the owner selected **use Responses and record the Chat limitation**, with no
further billable Chat attempts. Preserve reasoning and tools; do not silently strip
`reasoning_effort`, force `none`, remove tools, or deploy a wire-format conversion. No production
URL, policy, API-version setting, or authentication mode was changed. Chat without reasoning
was not tested or accepted. Its failed model request does not invalidate the separate successful
JWT acquisition/renewal checks for both wire formats.

Government Responses inference, matching token ingestion, and same-session renewal remain
passed within the documented fixture scope. Commercial coverage, utility/discovery paths,
live renewal-failure/MFA cases and integrated security acceptance remain separate. The owner
approved a [duplicate-header compatibility exception](authentication.md#approved-compatibility-exception-2026-09-21)
on 2026-09-21: Microsoft parity is no longer a delivery dependency, but customer clients must
send exactly one credential and must not rely on duplicate normalization or blindly retry a 401.

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
