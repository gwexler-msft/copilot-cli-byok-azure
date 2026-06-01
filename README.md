# GitHub Copilot CLI BYOK → Private Azure OpenAI (Commercial + Government)

Routes the GitHub Copilot CLI to a **customer-owned, private Azure OpenAI** account
through an internal-VNet APIM gateway. Inference traffic never leaves your tenant.

Based on the customer architecture whitepaper *"Architecture Reference - GitHub Copilot
BYOK with Azure"* (Parsons), reality-checked against shipping `gh copilot-cli` v1.0.x.

## What you get

| Layer | Component |
|---|---|
| Identity | Entra app registration `copilot-byok-gateway` exposing scope `cli.invoke`; Azure CLI is pre-authorized so devs get a silent token. |
| Network | VNet `10.60.0.0/16` with subnets for APIM, Private Endpoints, the VPN gateway, and a reserved DNS-inbound subnet. |
| Gateway | APIM Developer SKU in **internal VNet** mode with a **system-assigned managed identity**. Policy validates the dev's JWT, emits per-developer telemetry to App Insights, strips inbound creds, and reauthenticates to AOAI with MI. |
| Inference | Azure OpenAI account, `publicNetworkAccess=Disabled`, `disableLocalAuth=true`, **Private Endpoint only**, gpt-4.1 deployment (GlobalStandard). |
| Access | Point-to-Site VPN gateway (OpenVPN protocol) so pilot devs can hit the private APIM from their laptops. |
| Observability | Log Analytics workspace, Application Insights, ready-made KQL queries for tokens-per-dev and tokens-per-model. |

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
`<PLACEHOLDER>` values: `infra/main.parameters.example.json` (Government, the default) or
`infra/main.parameters.commercial.example.json` (Commercial). See
[docs/architecture.md](docs/architecture.md#cloud-parameterization) for the full endpoint
matrix and the Commercial-only `services.ai` private-DNS-zone caveat.

## Repo layout

```
.azure/infrastructure-plan.json   Reviewable plan (subscription-scope topology)
docs/                             Architecture, deployment guide, GitHub egress allowlist
infra/main.bicep                  Subscription-scope entry point
infra/modules/*.bicep             Network / APIM / AOAI / observability / RBAC / API+policy
policies/byok-aoai-policy.xml     The APIM policy (the heart of the design)
scripts/                          One-time setup-entra + per-developer wrapper
monitoring/kql/*.kql              Workbook queries
```

## Status

**Pre-deployment.** Files are scaffolded for review. No `azd up`, no `az deployment`.
See [docs/deployment-guide.md](docs/deployment-guide.md) for the run order once approved.

**`azd` is the primary deploy path** — `azure.yaml` wires `azd` to the
subscription-scope `infra/main` template (`azd provision`; no `services:` block, so
`azd up` == `azd provision`). Requires `azd` >= 1.25.4, Azure CLI >= 2.60, Bicep >= 0.30,
PowerShell 7+ (see *Required tools* in the deployment guide). **Commercial** is `azd`'s
default cloud; **Gov** tenants must first run `azd config set cloud.name AzureUSGovernment`
(global — it selects the AAD login authority) **then** `azd auth login`, otherwise
provisioning fails with `AADSTS90051: Invalid national Cloud ID (2)`. Raw
`az deployment sub create` against the same template remains available as an alternative.

## Known shipping limitations of Copilot CLI BYOK

- `COPILOT_PROVIDER_TYPE=azure` may hardcode an `api-version` ([copilot-cli#3208](https://github.com/github/copilot-cli/issues/3208)). The APIM policy *injects* `api-version` if missing and tolerates whatever the CLI sends.
- CLI cannot send custom headers ([#3399](https://github.com/github/copilot-cli/issues/3399)) or extra params ([#3448](https://github.com/github/copilot-cli/issues/3448)). All policy enforcement lives in APIM.
- Entra JWTs are ~1 hour. The wrapper script re-mints on each invocation; long sessions need a re-run. A future refresher daemon is out of scope for v1.
