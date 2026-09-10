# IntelliJ / JetBrains BYOK samples (OpenAI-compatible, chat-completions)

> **TL;DR** — IntelliJ-family AI tools speak the **OpenAI Chat Completions API**, which the
> BYOK APIM gateway exposes on every route (`/v1/chat/completions`). That is all IntelliJ
> needs — the **Responses** API is optional and not required. Point any OpenAI-compatible
> IntelliJ client at the gateway, deliver the APIM subscription key as the **`api-key`
> header** (see the auth note below), and you are done.

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

If you deployed the gateway with `authMode=jwt`, there is no subscription key — put a fresh
Entra access token in the client's API-key field so it rides as `Authorization: Bearer`
(good for ~1 hour; these clients do not auto-refresh).

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

## Option 1 — GitHub Copilot CLI as a custom ACP agent (BYOK) — ⚠️ BLOCKED UPSTREAM (waiting on a Copilot CLI fix)

> **Status (2026-07-03).** Adding the Copilot CLI as a custom ACP agent in IntelliJ AI Assistant is
> **fully supported by JetBrains** via `acp.json`, and the agent launches correctly. It is currently
> **blocked by an upstream Copilot CLI bug**: in BYOK + `--acp` mode the CLI still requires a GitHub
> login, so `session/new` fails before any prompt runs. We filed the bug and are **waiting on a fix**:
> [github/copilot-cli#4016](https://github.com/github/copilot-cli/issues/4016) — *BYOK
> (`COPILOT_PROVIDER_*`) still rejected in `--acp` mode: `session/new` → `-32000 Authentication
> required` (regressed on 1.0.61–1.0.68)*. Until it lands, **use Option 3 (terminal)** for login-free
> BYOK. Repo tracking: [#107](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/107).

> **The critical distinction.** JetBrains AI Assistant's built-in **"GitHub Copilot"** agent is
> **not** the BYOK-capable `@github/copilot` CLI — it's the **`@github/copilot-language-server`**
> (GitHub's IDE completions/chat client), which authenticates to GitHub's Copilot service and **does
> not honor `COPILOT_PROVIDER_*`**. BYOK is a feature of the separate **`@github/copilot` CLI**. The
> custom-agent route below points IntelliJ at that real CLI instead of the language server.

IntelliJ AI Assistant drives agents over **ACP** (Agent Client Protocol) — a local agent is just a
subprocess it launches over stdio. JetBrains supports registering a **custom ACP agent** in an
`acp.json` file, so you can run the *real* BYOK-capable Copilot CLI. The steps (per
[JetBrains' ACP docs → Add a custom agent](https://www.jetbrains.com/help/ai-assistant/acp.html#add-custom-agent)):

1. **Install the standalone Copilot CLI.**
   ```powershell
   npm install -g @github/copilot@latest    # or:  winget install GitHub.Copilot
   copilot --version
   ```
   npm installs a native `copilot.exe` at
   `%APPDATA%\npm\node_modules\@github\copilot\node_modules\@github\copilot-win32-x64\copilot.exe`
   (a direct exe is the most reliable ACP `command` — a `.cmd`/`.ps1` shim is flaky under ACP).
2. **Create the `acp.json`.** In the **AI Chat** tool window, click the **⋯** button (upper-right)
   and choose **Add Custom Agent**. IntelliJ creates `~/.jetbrains/acp.json` and opens it for editing.
   Add a `agent_servers` entry that runs the CLI in ACP mode (`--acp`) with the BYOK env:
   ```json
   {
     "default_mcp_settings": {},
     "agent_servers": {
       "BYOK Copilot (gateway)": {
         "command": "C:\\Users\\<you>\\AppData\\Roaming\\npm\\node_modules\\@github\\copilot\\node_modules\\@github\\copilot-win32-x64\\copilot.exe",
         "args": ["--acp"],
         "env": {
           "COPILOT_PROVIDER_BASE_URL": "https://<APIM_HOSTNAME>/openai",
           "COPILOT_PROVIDER_TYPE": "azure",
           "COPILOT_PROVIDER_API_KEY": "<APIM_SUBSCRIPTION_KEY>",
           "COPILOT_MODEL": "gpt-5.1"
         }
       }
     }
   }
   ```
   The key inside `agent_servers` is the display name shown in AI Chat. Note the flag is **`--acp`**
   (not an `acp` subcommand — that errors with *"Invalid command format"*). Base URL ends in `/openai`
   (the CLI appends `/v1`).
3. Save `acp.json`; the agent appears in the AI Chat agent picker. Select it and send a prompt.

**⚠️ Current blocker (upstream) — why this doesn't work yet.** The Copilot CLI's `--acp` server
**hard-gates every session on a GitHub login, independent of BYOK**. `initialize` succeeds and
advertises `authMethods:[copilot-login]`, but `session/new` returns
`JSON-RPC error -32000: Authentication required` — even with `COPILOT_PROVIDER_*` set and
`COPILOT_OFFLINE=true`. The *identical* env runs **login-free** under `copilot -p` / interactive, so
this is purely an ACP-path defect. Confirmed failing on **1.0.61 and 1.0.68** (the 1.0.61
custom-provider-in-ACP fix, [#3048](https://github.com/github/copilot-cli/issues/3048), routed *model*
traffic only — it did not remove the auth gate). Reproduce it IDE-independently with
[`../../scripts/acp-byok-repro.mjs`](../../scripts/acp-byok-repro.mjs) (zero-dep Node stdio JSON-RPC
client — drives `initialize` → `session/new` and prints the verdict). This means a **fully-private /
egress-off** agent cannot proceed: the only ways to satisfy the gate today are a GitHub token
(`COPILOT_GITHUB_TOKEN` / `GH_TOKEN` / `GITHUB_TOKEN`, fine-grained PAT with the "Copilot Requests"
permission) or `copilot login` — **both need `github.com` reachable to validate**, defeating the
air-gapped design.

- **Tracking:** repo [#107](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/107);
  upstream [#4016](https://github.com/github/copilot-cli/issues/4016) (primary) /
  [#3048](https://github.com/github/copilot-cli/issues/3048) /
  [#3161](https://github.com/github/copilot-cli/issues/3161) /
  [#3902](https://github.com/github/copilot-cli/issues/3902).
- **Until the fix lands:** use **Option 3** (terminal) — the validated login-free BYOK path.

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
[#108](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/108).

### Alternative: the dedicated `/openai-bearer` route (Entra JWT)

Use this instead when you specifically want per-developer **Entra JWT identity** on the request
rather than a shared subscription key — at the cost of an **hourly token you must paste manually**.
Deploy the parallel **bearer route** (`deployFoundryBearer=true`, default path **`openai-bearer`** —
see [`infra/modules/apim-foundry-bearer-api.bicep`](../../infra/modules/apim-foundry-bearer-api.bicep)).
It sets `subscriptionRequired=false` so the request is **not** rejected pre-policy, then its inbound
policy **validates the Bearer value as an Entra JWT** (`validate-jwt`) — preserving per-developer
identity for metering plus all the shared value-adds (model rewrite, auto-route, token metrics). It
routes to the **same Foundry backend** as `/openai`, and coexists with the subscriptionKey `/openai`
route (existing CLI / VS Code users are untouched).

1. **URL / base**: `https://<APIM_HOSTNAME>/openai-bearer/v1`
2. **API Key**: a fresh **Entra access token** for the gateway's API scope:
   ```pwsh
   az account get-access-token --resource <API_APP_ID_URI> --query accessToken -o tsv
   ```
   AI Assistant sends it as `Authorization: Bearer <token>`, which the bearer route's `validate-jwt`
   accepts. The token is good for ~1 hour and these clients **do not auto-refresh** — paste a fresh
   one when it expires. (The subkey proxy above avoids this churn entirely.)
3. **Model**: pick `gpt-5.1` (or `gpt-4.1-mini`) — it rides in the request body.

The `/models` probe is served at `GET /openai-bearer/v1/models` (same base URL), so the connection
validates and the model dropdown populates.

> **Subscription-key gateways too.** The bearer route is independent of the gateway's global
> `authMode`, so you can add it to an existing **subscriptionKey** deployment without converting the
> whole gateway to `jwt` — `/openai` keeps using per-developer `api-key` subscriptions while
> `/openai-bearer` accepts Entra JWTs for AI Assistant. Tracked in
> [#102](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/102).

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

### Bearer route (`/openai-bearer`) — exactly what AI Assistant (Option 2) sends

This reproduces AI Assistant's `Authorization: Bearer` requests against the dedicated bearer route.
The credential is an **Entra access token**, not a subscription key:

```pwsh
$apim  = 'https://<APIM_HOSTNAME>'
$token = az account get-access-token --resource <API_APP_ID_URI> --query accessToken -o tsv
# Connection probe (what AI Assistant calls first):
irm "$apim/openai-bearer/v1/models" -Headers @{ Authorization = "Bearer $token" }
# Chat call:
irm "$apim/openai-bearer/v1/chat/completions" -Method Post `
  -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
  -Body (@{ model = 'gpt-5.1'; messages = @(@{ role = 'user'; content = 'say hello in exactly five words' }) } | ConvertTo-Json)
```

```bash
TOKEN=$(az account get-access-token --resource <API_APP_ID_URI> --query accessToken -o tsv)
curl -sk "https://<APIM_HOSTNAME>/openai-bearer/v1/models" -H "Authorization: Bearer $TOKEN"
curl -sk "https://<APIM_HOSTNAME>/openai-bearer/v1/chat/completions" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"model":"gpt-5.1","messages":[{"role":"user","content":"say hello in exactly five words"}]}'
```

A `200` confirms Option 2 will work. `401 — Unauthorized: invalid Entra token` means the token is
expired/for the wrong scope (re-mint with the gateway's `<API_APP_ID_URI>`); `404` means the bearer
route isn't deployed (set `deployFoundryBearer=true`).

## Troubleshooting

- **`Access denied due to missing subscription key`** — the client sent
  `Authorization: Bearer` instead of the `api-key` header. Add the `api-key` header, use
  the `?api-key=` query fallback, or point the client at the `/openai-bearer` route (Option 2).
- **`404 Not Found`** — wrong path. Confirm `/openai/v1/chat/completions` (Foundry),
  `/openai-bearer/v1/chat/completions` (bearer route), or `/aoai/v1/chat/completions` (legacy
  AOAI), and that the base URL ends at `/v1`. A `404` on `/openai-bearer` also means the route
  isn't deployed (`deployFoundryBearer=true`).
- **DNS fails off-VNet** — VPN isn't up or the private-link zone (`azure-api.us` /
  `azure-api.net`) wasn't pushed; `Resolve-DnsName apim-...` should return `10.x.x.x`.
- **`401` with a JWT-mode gateway** — put a fresh Entra access token in the API-key field
  (rides as `Authorization: Bearer`); do not use the `?api-key=` fallback in jwt mode.
