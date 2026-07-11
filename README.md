# GitHub Copilot CLI BYOK → Private Azure OpenAI (Commercial + Government)

Routes the developer's Copilot dev surfaces — **GitHub Copilot CLI** and **VS Code 1.122+
Copilot Chat** (Custom Endpoint provider) — to a **customer-owned, private Azure OpenAI /
Microsoft Foundry** account through an internal-VNet APIM gateway. Inference traffic
never leaves your tenant.

Based on the customer architecture whitepaper *"Architecture Reference - GitHub Copilot
BYOK with Azure"* (Parsons), reality-checked against shipping `gh copilot-cli` v1.0.x
and the VS Code 1.122 Custom Endpoint provider.

## What you get

| Layer | Component |
|---|---|
| Identity | Entra app registration `copilot-byok-gateway` exposing scope `cli.invoke`; Azure CLI is pre-authorized so devs get a silent token. |
| Network | VNet `10.60.0.0/16` with subnets for APIM, Private Endpoints, the VPN gateway, and a reserved DNS-inbound subnet. |
| Gateway | APIM Developer SKU in **internal VNet** mode, running as an **Azure API Management AI gateway** (GenAI policies) with a **system-assigned managed identity**. Policy validates the dev's credential, applies **token-rate limiting** + emits **per-developer token metrics**, strips inbound creds, **load-balances/routes** to the model backend, and reauthenticates to AOAI/Foundry with MI. |
| Inference | Azure OpenAI account, `publicNetworkAccess=Disabled`, `disableLocalAuth=true`, **Private Endpoint only**, gpt-4.1 deployment (GlobalStandard). |
| Access | Point-to-Site VPN gateway (OpenVPN protocol) so pilot devs can hit the private APIM from their laptops. |
| Observability | Log Analytics workspace, Application Insights, ready-made KQL queries for tokens-per-dev, tokens-per-model, and throttle-hits-per-dev (all fed by the AI gateway's `emit-metric` token telemetry). |

> **This gateway _is_ an Azure API Management AI gateway.** Azure API Management's *AI gateway*
> is **not a separate product or a v2-tier feature** — Microsoft documents it as applying to
> **all API Management tiers** ([genai-gateway-capabilities](https://learn.microsoft.com/en-us/azure/api-management/genai-gateway-capabilities)).
> It's the set of GenAI policies (token limits, token-metric emission, content safety,
> backend load balancing, semantic caching) layered on the normal API gateway, and this project
> is **built around them**: the policy applies the official `azure-openai-token-limit` AI-cost
> guard, emits per-developer token metrics, and load-balances/routes across model backends. The
> **classic Developer SKU** is deliberate — the APIM **v2 tiers (Basic/Standard/Premium v2) are
> not available in Azure Government** today
> ([v2 region availability](https://learn.microsoft.com/en-us/azure/api-management/api-management-region-availability)),
> so Gov uses the classic tiers, which support the same AI-gateway policies. The only v2-only
> AI extras (the Anthropic Messages schema, some portal import wizards, the Foundry-embedded
> gateway preview) aren't needed for an OpenAI-schema Copilot-CLI BYOK gateway. See
> [architecture.md → APIM as the AI gateway](docs/architecture.md#apim-as-the-ai-gateway-and-why-the-classic-developer-sku).

## Two clouds, one template

Cloud-specific values are parameterized:

| Param | Commercial default | Government default |
|---|---|---|
| `cloudEnv` | `AzureCloud` | `AzureUSGovernment` |
| `aoaiDnsZone` | `privatelink.openai.azure.com` | `privatelink.openai.azure.us` |
| `entraOpenIdConfig` | `https://login.microsoftonline.com/{tid}/v2.0/.well-known/openid-configuration` | `https://login.microsoftonline.us/{tid}/v2.0/.well-known/openid-configuration` |
| `aoaiAudience` | `https://cognitiveservices.azure.com` | `https://cognitiveservices.azure.us` |

First pilot targets **`usgovvirginia`** in your Azure Government tenant.

To deploy, copy the parameters profile that matches your cloud and fill in the
`<PLACEHOLDER>` values: `infra/main.parameters.gov.example.json` (Government, the default) or
`infra/main.parameters.commercial.example.json` (Commercial). See
[docs/architecture.md](docs/architecture.md#cloud-parameterization) for the full endpoint
matrix and the Commercial-only `services.ai` private-DNS-zone caveat.

> **Reusing this for another account / Gov BYOK engagement?** Read
> [docs/lessons-learned.md](docs/lessons-learned.md) first — a delivery playbook of the
> non-obvious gaps (wizard APIM policy fixes, managed-identity backend auth, the Gov
> `api-version`/Responses interplay, per-subscription-key telemetry KQL) so you can
> configure-and-deploy instead of rebuilding.

> **Running a deployed gateway?** [docs/operations-runbook.md](docs/operations-runbook.md) is
> the Day-2 ops guide — symptom-indexed incident playbook, onboarding/key rotation, limit
> tuning, and telemetry health checks for the infra/on-call team.

> **Self-serve developer onboarding?** [docs/register-app-runbook.md](docs/register-app-runbook.md)
> covers the opt-in register app (`deployRegisterApp=true`) — developers provision their own
> per-developer APIM key and config; admins deploy, configure Easy Auth + tiers, and offboard.

## Repo layout

```
.azure/infrastructure-plan.json   Reviewable plan (subscription-scope topology)
docs/                             Architecture, deployment guide, CI/CD, GitHub egress allowlist
infra/main.bicep                  Subscription-scope entry point
infra/modules/*.bicep             Network / APIM / AOAI / observability / RBAC / API+policy
policies/byok-aoai-policy.xml     The APIM policy (the heart of the design)
samples/vscode/                   VS Code 1.122 Custom Endpoint registration JSON
samples/intellij/                 IntelliJ / JetBrains OpenAI-compatible config (Continue + AI Assistant/ProxyAI)
scripts/                          One-time setup-entra + per-developer wrapper
monitoring/kql/*.kql              Workbook queries
```

## Status

**Pre-deployment.** Files are scaffolded for review. No `azd up`, no `az deployment`.
See [docs/deployment-guide.md](docs/deployment-guide.md) for the run order once approved.
For the automated / OIDC-federated path (both clouds) + planned self-hosted runner + post-deploy
smoke tests, see [docs/cicd.md](docs/cicd.md).

**`azd` is the primary deploy path** — `azure.yaml` wires `azd` to the
subscription-scope `infra/main` template (`azd provision`; no `services:` block, so
`azd up` == `azd provision`). Requires `azd` >= 1.25.4, Azure CLI >= 2.60, Bicep >= 0.30,
PowerShell 7+ (see *Required tools* in the deployment guide). **Commercial** is `azd`'s
default cloud; **Gov** tenants must first run `azd config set cloud.name AzureUSGovernment`
(global — it selects the AAD login authority) **then** `azd auth login`, otherwise
provisioning fails with `AADSTS90051: Invalid national Cloud ID (2)`. Raw
`az deployment sub create` against the same template remains available as an alternative.

## Client surfaces

The gateway is OpenAI-schema, so any client that can target an OpenAI-compatible endpoint
plus a bearer credential works. Two are first-class:

| Client | Path it hits | Credential it sends | Notes |
|---|---|---|---|
| **GitHub Copilot CLI** (BYOK `azure` provider) | `POST /openai/v1/chat/completions` on the Foundry or AOAI API | Entra JWT via `Authorization: Bearer` (laptop) or APIM subscription key via `api-key` (CI / no-Entra) | The wrapper script in [`scripts/`](scripts/) handles JWT minting. See [docs/deployment-guide.md](docs/deployment-guide.md). |
| **VS Code 1.122+** "Custom Endpoint" provider | `POST /openai/v1/chat/completions` and/or `POST /openai/v1/responses` on either API | APIM subscription key via the provider `apiKey` + a `?_vscodeauth=openai.azure` url param (makes VS Code send it as `api-key`; see [issue #96](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/96)); BYOK doesn't require GitHub sign-in | Set `apiType: chat-completions` or `apiType: responses` per model; `reasoningEffortFormat` follows the apiType. Ready-made model registration JSON in [`samples/vscode/`](samples/vscode/). See [docs/deployment-guide.md → Option C: VS Code Custom Endpoint](docs/deployment-guide.md#option-c--vs-code-via-custom-endpoint-byok-provider). |

Both APIs expose both routes (the policy rewrites `/openai/v1/responses` to the
account-root, versionless `/openai/v1/responses` data-plane path; chat-completions stays
deployment-scoped). Token metrics (`copilot_byok_prompt_tokens` / `_completion_tokens`)
emit for both — the policy falls back from `usage.prompt_tokens` to `usage.input_tokens`
(and `completion_tokens` to `output_tokens`) automatically.

> **Model discovery** (`#61`). `GET /v1/models` is an operation on the foundry inference API
> at `https://<apim>/openai/v1/models`, reachable by any valid inference key (model names
> aren't sensitive, and OpenAI-compatible IDE clients must list models to connect). It returns
> the live Foundry deployments reshaped to the OpenAI shape with the `auto` sentinel first. The
> former dedicated `copilot-byok-discovery` API + `byok-discovery` product were consolidated
> away. See
> [docs/architecture.md → Model discovery](docs/architecture.md#model-discovery--the-v1models-operation-on-the-foundry-api-61).

> **Self-serve onboarding at fleet scale is planned** (`#64`). A developer signs in once with
> Entra ID and gets their own APIM subscription **plus** a ready-to-use VS Code config written
> to disk — no admin ticket, no JSON hand-editing. See
> [docs/architecture.md → Self-serve developer onboarding](docs/architecture.md#self-serve-developer-onboarding-planned--64).

> **Auto model-selection comes in two flavors** (`#73`). Send **`model: auto`** to use the
> **free, in-policy APIM router** (coding-signal + length heuristic, optional classifier — already
> built), or opt in to Microsoft's **managed Foundry Model Router** (`deployModelRouter=true`,
> `#76`) and send **`model: model-router`** for a single `model-router` deployment that picks the
> underlying model itself (slight token markup). Both are chosen purely by the `model` value the
> client sends — no client code change. See
> [docs/architecture.md → Foundry Model Router vs the free APIM router](docs/architecture.md#foundry-model-router-vs-the-free-apim-router-opt-in-76).

> **AI tooling (MCP servers) is a separate plane** (`#74`). Model Context Protocol tool traffic
> does **not** flow through the model gateway by default. The repo ships GitHub's remote MCP in
> [`.vscode/mcp.json`](.vscode/mcp.json) (an egress decision); private/Gov deployments can also
> route tools through APIM as an **MCP broker** (same Entra/subkey auth, rate-limit, and App
> Insights telemetry — on the classic Developer SKU) or host MCP servers in-VNet behind a Private
> Endpoint. See [docs/architecture.md → AI tooling (MCP servers)](docs/architecture.md#ai-tooling-mcp-servers-in-the-byok-landscape).

## Known shipping limitations of Copilot CLI BYOK

- `COPILOT_PROVIDER_TYPE=azure` may hardcode an `api-version` ([copilot-cli#3208](https://github.com/github/copilot-cli/issues/3208)). The APIM policy *injects* `api-version` if missing and tolerates whatever the CLI sends.
- CLI cannot send custom headers ([#3399](https://github.com/github/copilot-cli/issues/3399)) or extra params ([#3448](https://github.com/github/copilot-cli/issues/3448)). All policy enforcement lives in APIM.
- Entra JWTs are ~1 hour. The wrapper script re-mints on each invocation; long sessions need a re-run. A future refresher daemon is out of scope for v1.
