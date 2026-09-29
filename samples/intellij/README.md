# IntelliJ / JetBrains BYOK samples

> **Client choice:** the configured native Copilot CLI custom ACP agent uses renewable JWTs
> and **Responses** for GPT-5.6 tools plus reasoning. Actual IntelliJ agent acceptance remains
> open. The native AI Assistant/OpenAI-compatible provider uses per-user APIM subscription keys
> and its supported model/wire format, with the existing Bearer-to-`api-key` proxy where needed.
> Chat Completions examples below describe that native-provider path, not the CLI agent.

These samples are the IntelliJ counterpart to [`../vscode/`](../vscode/README.md). Unlike VS
Code (which pastes a `chatLanguageModels.json`), IntelliJ tools are configured through the IDE
**Settings** UI (or each plugin's own config file), so this folder is a set of UI walkthroughs —
in priority order: the **Copilot CLI** (custom ACP agent, and integrated terminal), the built-in
**AI Assistant**, and the **Continue** / **ProxyAI** plugins.

## The one thing that trips everyone up: auth header

APIM validates the subscription key from the **`api-key` header** (or an **`?api-key=`**
query parameter) — see [`infra/modules/apim-foundry-api.bicep`](../../infra/modules/apim-foundry-api.bicep).
Most OpenAI-compatible clients (including Continue and IntelliJ AI Assistant) default to
sending the key as **`Authorization: Bearer <key>`**, which APIM **ignores** — you get
`Access denied due to missing subscription key`.

Three ways to satisfy APIM:

1. **Custom `api-key` header (recommended when the client supports it).** If the client lets
   you add request headers, set `api-key: <APIM_SUBSCRIPTION_KEY>`. This is what the Continue
   config does via `requestOptions.headers` (Option 4 below).
2. **Subkey proxy (recommended for Bearer-only clients like AI Assistant).** If the client can
   ONLY send a base URL + API-Key (no custom-header option) and sends the key as
   `Authorization: Bearer` — point its base URL at the in-VNet **subkey proxy** instead of APIM
   directly:
   ```
   http://proxy.byok.internal:8080/openai/v1
   ```
   The proxy accepts the `Bearer <APIM_SUBSCRIPTION_KEY>` the client sends, rewrites it to the
   `api-key` header APIM expects, and forwards to the private gateway. Put your APIM
   subscription key in the client's API-Key field and you're done — no custom header, no query
   hack. It's reachable only in-VNet (same P2S VPN / in-VNet reachability as APIM). Opt-in
   (`deployFoundrySubkeyProxy=true`); enabled on both pilots. See
   [operations-runbook.md §10](../../docs/operations-runbook.md#10-subkey-proxy-for-bearer-only-ide-clients)
   and [architecture.md](../../docs/architecture.md).
3. **`?api-key=` query fallback.** If the client only lets you set a base URL (no custom
   headers) and the subkey proxy isn't deployed, append `?api-key=<APIM_SUBSCRIPTION_KEY>` to
   the endpoint URL. Use this only when the client sends the request to the URL verbatim (it
   breaks if the client appends `/chat/completions` after the query string).

Legacy `authMode=jwt` replaces subscription-key authentication; it does not enable coexistence.
Those Foundry policies expect a gateway-audience token in `api-key`. A proxy can rewrite the
header but cannot validate or renew that token. Do not use pasted short-lived JWTs as the native
AI Assistant support path. Use the configured CLI agent for renewal and retain per-user keys for
the native provider, with shared admission activated only after deployment approval.

## What you need before configuring

1. **The APIM hostname** — Gov ends in `.azure-api.us`, Commercial in `.azure-api.net`.
   ```pwsh
   az deployment sub show -n <deployment-name> --query 'properties.outputs.apimGatewayUrl.value' -o tsv
   ```
2. **An APIM subscription key** — the `dev1` / `dev2` test keys work for smoke tests; give
   real developers their own per-user APIM subscription.
   ```pwsh
   az apim subscription show -g <rg> --service-name <apim> --sid dev1 --query primaryKey -o tsv
   ```
3. **Network reachability** — the APIM hostname must resolve to its **private** IP
   (in-VNet via the private DNS zone, or off-VNet over the P2S VPN). Confirm with
   `Resolve-DnsName apim-...` returning `10.x.x.x`.

The **base URL** is `https://<APIM_HOSTNAME>/openai/v1` for the Foundry route (or
`/aoai/v1` for the legacy AOAI route). The chat-completions endpoint is
`https://<APIM_HOSTNAME>/openai/v1/chat/completions`.

## Option 1 - Copilot CLI As A Custom ACP Agent

**Status (2026-09-23):** native CLI 1.0.85 passed login-free ACP sessions and actual JWT expiry
renewal in the Government test environment. The earlier 1.0.61/1.0.68 GitHub-login gate is historical,
not a blanket current blocker. Actual IntelliJ launch, tools and reauthentication recovery still
need acceptance. See [the precise evidence](../../docs/feature-request-byok-credential-refresh.md#real-expiry-gate-passed).
The new pinned launcher also passed a local strict-HTTPS test using the actual CLI in one ACP
session, including credential renewal and zero provider requests after helper failure. That is
launcher/protocol evidence, not an IntelliJ UI pass.

The approved support boundary is renewable JWT through the configured CLI agent, with the native
AI Assistant model-provider experience remaining on per-user APIM subscription keys. Selecting an
agent named Copilot is not evidence that this CLI or credential helper is being used.

> **The critical distinction.** JetBrains AI Assistant's built-in **"GitHub Copilot"** agent is
> **not** the BYOK-capable `@github/copilot` CLI — it's the **`@github/copilot-language-server`**
> (GitHub's IDE completions/chat client), which authenticates to GitHub's Copilot service and **does
> not honor `COPILOT_PROVIDER_*`**. BYOK is a feature of the separate **`@github/copilot` CLI**. The
> custom-agent route below points IntelliJ at that real CLI instead of the language server.

IntelliJ AI Assistant drives agents over **ACP** (Agent Client Protocol) — a local agent is just a
subprocess it launches over stdio. JetBrains supports registering a **custom ACP agent** in an
`acp.json` file, so you can run the *real* BYOK-capable Copilot CLI. The steps (per
[JetBrains' ACP docs → Add a custom agent](https://www.jetbrains.com/help/ai-assistant/acp.html#add-custom-agent)):

1. **Install the standalone Copilot CLI and PowerShell 7.4+.**
   ```powershell
   npm install -g @github/copilot@latest    # or:  winget install GitHub.Copilot
   copilot --version
   ```
   npm installs a native `copilot.exe` at
   `%APPDATA%\npm\node_modules\@github\copilot\node_modules\@github\copilot-win32-x64\copilot.exe`
   (a direct exe is the most reliable ACP `command` — a `.cmd`/`.ps1` shim is flaky under ACP).
2. **Prepare a local nonsecret agent profile.** Use [cli-agent.example.json](cli-agent.example.json)
   as the shape for the ignored `cli-agent.local.json`. Specify the absolute native CLI executable,
   gateway base ending in `/openai`, model, workspace and existing Azure CLI cache. Pin the expected
   cloud, tenant and signed-in account. Complete delegated sign-in in that cache outside IntelliJ.
   Do not put a token or subscription key in the profile. The launcher uses Responses and one
   `COPILOT_PROVIDER_API_KEY_COMMAND`, and never signs in or silently switches users.

   Validate without launching the CLI or making an Azure call:
   ```powershell
   ./scripts/start-copilot-agent.ps1 -ConfigFile ./samples/intellij/cli-agent.local.json -ValidateOnly
   ```
3. **Create the `acp.json`.** In the **AI Chat** tool window, click the **⋯** button (upper-right)
   and choose **Add Custom Agent**. IntelliJ creates `~/.jetbrains/acp.json` and opens it for editing.
   Add an `agent_servers` entry invoking the launcher. Keep absolute paths; only nonsecret
   configuration belongs here:
   ```json
   {
     "default_mcp_settings": {},
     "agent_servers": {
       "BYOK Copilot (gateway)": {
             "command": "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
             "args": [
                "-NoLogo", "-NoProfile", "-NonInteractive", "-File",
                "C:\\<REPOSITORY>\\scripts\\start-copilot-agent.ps1",
                "-ConfigFile", "C:\\<LOCAL_CONFIG>\\cli-agent.local.json", "-Mode", "acp"
             ],
             "env": {}
       }
     }
   }
   ```
   The entry name is the display name shown in AI Chat. The launcher invokes the configured native
   CLI with `--acp --stdio`; setup emits no banners on ACP stdout. Use the equivalent absolute
   `pwsh` and file paths on Linux/macOS. The paired Bash launcher accepts the same parameters.
4. Select the custom agent, after the target gateway's JWT configuration and test request budget
   are approved. Verify its executable/version and helper invocation, then test expiry without
   restarting the session and helper failure without backend traffic. Startup success alone does
   not complete this gate. Native editor subscription/license policies remain separate.

**Historical ACP failure (1.0.61/1.0.68).** Those CLI versions gated the `--acp` server on a
GitHub login despite BYOK. `initialize` succeeded and
advertises `authMethods:[copilot-login]`, but `session/new` returns
`JSON-RPC error -32000: Authentication required` — even with `COPILOT_PROVIDER_*` set and
`COPILOT_OFFLINE=true`. The *identical* env runs **login-free** under `copilot -p` / interactive, so
this is purely an ACP-path defect. Confirmed failing on **1.0.61 and 1.0.68** (the 1.0.61
custom-provider-in-ACP fix, [#3048](https://github.com/github/copilot-cli/issues/3048), routed *model*
traffic only — it did not remove the auth gate). Reproduce it IDE-independently with
[`../../scripts/acp-byok-repro.mjs`](../../scripts/acp-byok-repro.mjs) (zero-dep Node stdio JSON-RPC
client — drives `initialize` → `session/new` and prints the verdict). In those versions a
**fully-private / egress-off** agent could not proceed: the available workarounds were a GitHub token
(`COPILOT_GITHUB_TOKEN` / `GH_TOKEN` / `GITHUB_TOKEN`, fine-grained PAT with the "Copilot Requests"
permission) or `copilot login` — **both needed `github.com` reachable to validate**, defeating the
air-gapped design.

- **Tracking:** repo #107;
  upstream [#4016](https://github.com/github/copilot-cli/issues/4016) (primary) /
  [#3048](https://github.com/github/copilot-cli/issues/3048) /
  [#3161](https://github.com/github/copilot-cli/issues/3161) /
  [#3902](https://github.com/github/copilot-cli/issues/3902).
- This older failure is retained for diagnosis; it does not override the newer 1.0.85 ACP/expiry
   evidence. Do not install an older CLI or claim the editor integration passed from protocol tests alone.

## Option 2 — JetBrains AI Assistant (built-in)

JetBrains **AI Assistant** (2024.3+) has an **OpenAI-compatible** provider
(**Settings → Tools → AI Assistant → Providers & API keys**). Its provider exposes only a
**URL** and an **API Key** field — there is **no custom-header option** — and it sends the key as
**`Authorization: Bearer <key>`**. It also **probes `GET <base>/models`** to validate the
connection (part of the OpenAI REST spec; it won't connect without it).

### Why the default `/openai` route rejects it

APIM's subscription-key validation only reads the `api-key` header/query, and it runs **before any
policy**, so a request carrying only `Authorization: Bearer <key>` is rejected with:

```
401 — Access denied due to missing subscription key when making requests to an API.
```

APIM cannot remap a Bearer token into subscription-key validation, so an APIM **subscription key
cannot** be used with AI Assistant on the default `/openai` route directly.

### Recommended: the subkey proxy (durable subscription key — no hourly token)

Point AI Assistant's base URL at the in-VNet **subkey proxy**. It accepts the
`Authorization: Bearer <APIM subscription key>` the client sends, rewrites it to the `api-key`
header APIM expects, and forwards to the private gateway — so you use a normal, **non-expiring APIM
subscription key** (no Entra token, no hourly refresh, no custom header).

1. **URL / base**: `http://proxy.byok.internal:8080/openai/v1`
2. **API Key**: your **APIM subscription key** (`dev1`/`dev2` for smoke; a per-developer subscription
   for real users — metering is preserved via the key's subscription id).
3. **Model**: pick `gpt-5.1` (or `gpt-4.1-mini`) — it rides in the request body.

The `/models` probe works too — the proxy forwards `GET /v1/models` to APIM's dynamic model list, so
the connection validates and the dropdown populates. Reachable **only in-VNet** (same P2S VPN /
in-VNet reachability as APIM). Opt-in (`deployFoundrySubkeyProxy=true`; enabled on both pilots). See
[operations-runbook.md §10](../../docs/operations-runbook.md#10-subkey-proxy-for-bearer-only-ide-clients),
[architecture.md](../../docs/architecture.md), and
#108.

### Opt-in shared callers: acceptance pending

The target is **subscription key OR Entra JWT OR Okta JWT**, one credential per request,
with the same client-facing inference and discovery URLs. The main and standalone policy packages
are implemented locally, but this IDE/proxy workflow is not accepted for renewable JWT use. The
previously documented `deployFoundryBearer` switch and `/openai-bearer` module are not
present in the current infrastructure; do not use those old deployment instructions.

Existing key clients keep their configuration. JWT clients would put the access token in
the API-key field, but the proxy/admission path must first support the agreed header
contract. The current proxy translates Bearer to `api-key` and removes Authorization;
it does not obtain, validate or refresh an Entra/Okta token. The new raw-header njs guard requires
an approved compatible image and still needs Linux runtime acceptance. Test both inference and
`GET /v1/models`, and provide a supported renewal mechanism before fleet rollout.

Okta sign-in federated through Entra still produces an Entra API token. Direct Okta tokens
require custom-authorization-server validation and issuer-qualified identity in the gateway.
Neither option changes APIM-to-Foundry authentication. The standalone bolt-on's shared policies
and ownership operations are packaged for Bicep and Terraform, with default-legacy settings.
The [Okta CLI helper](../../scripts/okta/README.md) does not make AI Assistant invoke a credential
command. Existing native-key settings remain the supported choice until an IDE renewal design
and failure/recovery workflow are approved and tested.
See [the full authentication design](../../docs/authentication.md).

Because these clients use **chat-completions**, no Responses configuration is needed.

## Option 3 — `copilot` CLI in the IntelliJ integrated terminal (always works)

No plugin, no agent registration, no allowlist needed. Open IntelliJ's built-in terminal (which
inherits your User-scope env vars) and run the BYOK CLI directly:
```powershell
copilot -p "say hi in exactly five words"      # one-shot
copilot                                        # interactive session
```
This is the repo's **validated** BYOK path (`COPILOT_PROVIDER_*` → the gateway, no github.com login
required). It's the most reliable option on a locked-down/managed machine.

## Option 4 — Continue plugin (config file, most portable)

[Continue](https://plugins.jetbrains.com/plugin/22707-continue) is a cross-IDE plugin with
a JSON config, so it's the closest analog to the VS Code sample.

1. Install **Continue** from the JetBrains Marketplace and open its config (Continue panel →
   gear icon → **Open config**; file lives at `~/.continue/config.json`).
2. Add a BYOK model to the `models` array. Each model uses the `openai` provider, the
   `/openai/v1` Foundry base URL, and the `api-key` header (Continue's `openai` provider
   otherwise sends the key only as `Authorization: Bearer`, which APIM ignores):
   ```json
   {
     "title": "BYOK gpt-5.1",
     "provider": "openai",
     "model": "gpt-5.1",
     "apiBase": "https://<APIM_HOSTNAME>/openai/v1",
     "apiKey": "<APIM_SUBSCRIPTION_KEY>",
     "requestOptions": { "headers": { "api-key": "<APIM_SUBSCRIPTION_KEY>" } }
   }
   ```
   Add a second entry with `"model": "gpt-4.1-mini"` if you want the smaller model too.
3. Substitute `<APIM_HOSTNAME>` and `<APIM_SUBSCRIPTION_KEY>` in both the `apiKey`
   field and the `requestOptions.headers.api-key` value.
4. Save; pick a **BYOK …** model in the Continue chat and ask *"say hello in exactly five
   words."* A 200 means the chain is wired (IDE → DNS → APIM → policy → MI → backend).

> Newer Continue versions also support a `config.yaml`; the `config.json` form above still
> works. In YAML, set each model's `apiBase`, `apiKey`, and
> `requestOptions: { headers: { api-key: <key> } }` equivalently.

## Option 5 — ProxyAI (formerly CodeGPT) plugin

[ProxyAI](https://plugins.jetbrains.com/plugin/21056-proxy-ai) has an explicit **Custom
OpenAI** service that supports custom headers — ideal for the `api-key` requirement.

1. **Settings → Tools → ProxyAI → Providers → Custom OpenAI** (or *Custom Service*).
2. **Base host / URL**: `https://<APIM_HOSTNAME>` and set the completions path to
   `/openai/v1/chat/completions` (ProxyAI lets you edit the request path/body template).
3. **Headers**: add `api-key` = `<APIM_SUBSCRIPTION_KEY>`.
4. **Model / body**: set `model` to `gpt-5.1` (or `gpt-4.1-mini`) in the request body.
5. Test the connection, then chat.

## Smoke test from the same machine (no IDE required)

Proves the route works before touching the IDE — the exact requests the IDE will send (the
`/models` probe, then a chat call):

```pwsh
$apim = 'https://<APIM_HOSTNAME>'
$key  = '<APIM_SUBSCRIPTION_KEY>'
# Connection probe (what AI Assistant calls first):
irm "$apim/openai/v1/models" -Headers @{ 'api-key' = $key }
# Chat call:
irm "$apim/openai/v1/chat/completions" -Method Post `
  -Headers @{ 'api-key' = $key; 'Content-Type' = 'application/json' } `
  -Body (@{ model = 'gpt-5.1'; messages = @(@{ role = 'user'; content = 'say hello in exactly five words' }) } | ConvertTo-Json)
```

```bash
curl -sk "https://<APIM_HOSTNAME>/openai/v1/models" -H "api-key: <APIM_SUBSCRIPTION_KEY>"
curl -sk "https://<APIM_HOSTNAME>/openai/v1/chat/completions" \
  -H "api-key: <APIM_SUBSCRIPTION_KEY>" -H "Content-Type: application/json" \
  -d '{"model":"gpt-5.1","messages":[{"role":"user","content":"say hello in exactly five words"}]}'
```

A `200` with a chat completion confirms IntelliJ will work. `Access denied due to missing
subscription key` means the key isn't reaching APIM as `api-key` (fix the header/query per
the auth note above).

### JWT validation scope

Current JWT-mode tests target `/openai/v1/models` and `/openai/v1/chat/completions`, with a
gateway-scoped Entra token in `api-key`. A Bearer-only client must use a verified adapter.
These tests do not establish coexistence with keys, direct Okta support or automatic renewal.
Use the [authentication acceptance gates](../../docs/authentication.md#rollout-and-acceptance-gates)
for the planned migration; there is no separate bearer-route deployment switch today.

## Troubleshooting

- **`Access denied due to missing subscription key`** — the client sent
  `Authorization: Bearer` instead of the `api-key` header. Add the `api-key` header, use
   the documented subkey proxy for Bearer-only clients, or the existing key-only query fallback.
- **`404 Not Found`** — wrong path. Confirm `/openai/v1/chat/completions` (Foundry),
   or `/aoai/v1/chat/completions` (legacy AOAI), and that the base URL ends at `/v1`.
   The previously documented `/openai-bearer` route is not part of current infrastructure.
- **DNS fails off-VNet** — VPN isn't up or the private-link zone (`azure-api.us` /
  `azure-api.net`) wasn't pushed; `Resolve-DnsName apim-...` should return `10.x.x.x`.
- **`401` with a JWT-mode gateway** — verify token audience, expiry and scope, and ensure
   the current Foundry policy receives the token in `api-key` through a compatible provider
   or verified adapter. Bearer alone is insufficient today. Never put JWTs in URL queries.
