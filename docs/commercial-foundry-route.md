# Commercial Foundry backend (selected by the `commercial-models` sentinel)

An **opt-in** extra **backend** that lets the **Gov** gateway reach a **Commercial Microsoft
Foundry** endpoint over the public internet — **without a second base URL**. Clients keep the one
default `/openai` route (API `copilot-byok-foundry`); the policy compares the requested `model`
against the `commercial-models` sentinel and, on a match, points that single request at the
commercial backend instead of the private Foundry. Everything else — caller credential, product
tier, quotas, telemetry — is identical either way.

> **The parallel `/openai-commercial` route is retired.** It is superseded by the sentinel
> (#118), which is what
> makes commercial-only models usable from the Copilot CLI at all: the CLI's `azure` provider
> discards any path on `COPILOT_PROVIDER_BASE_URL`, so it can only ever reach `/openai`. See
> [Retired](#retired) at the end for what existed and why it went.

**Backend auth is cross-tenant by service principal.** The caller authenticates to Gov APIM as
today, but APIM does **not** forward the caller token to the commercial backend. Instead APIM
mints a **separate** bearer token in the **Commercial tenant**
(supplied via the `COMMERCIAL_TENANT_ID` repo Variable / `foundryCommercialTenantId` param — never committed) using a **Commercial-tenant service principal** (OAuth2
client-credentials) and calls the commercial endpoint over HTTPS with
`Authorization: Bearer <commercial-token>`. A Gov managed-identity token is rejected by the
commercial tenant (`TenantAccessDenied`), which is why a commercial SP is required.

Everything ships **off by default** (`deployFoundryCommercial=false`). Nothing commercial is
created until you opt in and supply the placeholders below — and even then the backend stays
**inert** until `commercialModels` names at least one model.

> **Status (cross-cloud path validated 2026-07-01, gov-dev → commercial pilot Foundry).** A
> Gov-internal APIM gateway call returned **HTTP 200** from a Commercial Foundry for both
> `/v1/chat/completions` (gpt-5.1) and `/v1/responses` (gpt-4.1-mini), with the caller subscription
> key and the RAI content-filter applied. The same backend, token-mint and egress path are what the
> sentinel now uses — only the front door changed.
>
> **KEY FINDING — the secretless mode does NOT work across sovereign clouds.**
> `servicePrincipalFederated` (workload identity federation) is **rejected by Commercial Entra**
> with **`AADSTS700238`** ("Tokens issued by issuer `https://login.microsoftonline.us/<gov-tenant>/v2.0`
> may not be used for federated identity credential flows for applications … registered in this
> tenant"). A Gov Entra-tenant-issued managed-identity token cannot be a FIC assertion for a
> Commercial-tenant app. **For Gov → Commercial you must use `foundryCommercialAuthMode=servicePrincipal`
> (client secret)** or `apikey`. See [Backend auth](#backend-auth--caller-token-is-not-forwarded) and
> [servicePrincipal (secret) mode — validated step by step](#serviceprincipal-secret-mode--validated-step-by-step).
> (`servicePrincipalFederated` remains valid for *same-cloud* cross-tenant, e.g. commercial → commercial.)

---

## How the backend is chosen

| | Private Foundry (default) | Commercial Foundry (opt-in) |
|---|---|---|
| Front door | `/openai` (and `/anthropic`) | **the same** `/openai` (and `/anthropic`) |
| Chosen when | the requested model is **not** in `commercial-models` | the requested model **matches** `commercial-models` (name or prefix, case-insensitive) |
| APIM backend | `foundry` Url/Pool backend (private endpoint) | `foundry-commercial` Url backend (`<COMMERCIAL_BACKEND_ID>`) |
| Reaches | private Foundry in-VNet (private endpoint) | **Commercial Foundry over the public internet** |
| Egress | intra-VNet to the private endpoint | leaves the Gov VNet via the **NAT gateway public IP `<GOV_NAT_EGRESS_IP>`** |
| Backend auth | managed identity (in-cloud) | **`servicePrincipal`** (client secret — the only mode that works Gov→Commercial); `apikey` / `managedIdentity` also available (`<COMMERCIAL_BACKEND_AUTH_MODE>`) |
| Caller token to backend | n/a (MI) | **never forwarded** — stripped; a separate commercial token is attached |
| Caller auth | `subscriptionKey` / `jwt` | **same** credential, same key |
| Operations | `/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, `/v1/responses` | **same** — one API surface |
| Telemetry | `copilot_byok_request` + built-in token metrics | **same metric names**, `backend` dimension = `foundry-commercial` |
| Throttling | product tiers (subscriptionKey) / per-oid (jwt) | **same** — one API, one product linkage |

Because there is only one API, there is only one policy: the commercial branch is a
`set-backend-service` + token-mint step **inside** `byok-foundry-policy*.xml`, not a parallel copy.
Request parsing, the 400 model-not-specified guard, request metrics, reasoning-model normalization
(`gpt-5`/`o*` sampling-param strip + `max_tokens`→`max_completion_tokens`), the `/responses`
account-root rewrite and the surface-validation map are shared by definition — they cannot drift
between backends.

---

## Request flow

```mermaid
flowchart LR
    CLI["Copilot CLI / VS Code<br/>COPILOT_PROVIDER_BASE_URL=.../openai<br/>model = a name listed in commercial-models"] --> APIM
    subgraph GOV["Gov VNet"]
      APIM["APIM gateway — API copilot-byok-foundry (/openai)<br/>validate caller, metrics, normalize body,<br/>MATCH model against commercial-models → pick foundry-commercial,<br/>STRIP caller token, mint+cache commercial SP token,<br/>attach Authorization: Bearer, rewrite /v1/* path"]
      NAT["NAT gateway<br/>public IP (per-env NAT VIP)"]
      APIM --> NAT
    end
    NAT -->|"1. HTTPS client-credentials (NSG pri 260)"| AAD["Commercial AAD<br/>login.microsoftonline.com/&lt;COMMERCIAL_TENANT_ID&gt;"]
    AAD -->|"access_token (aud cognitiveservices.azure.com)"| NAT
    NAT -->|"2. HTTPS Bearer &lt;commercial-token&gt; (NSG pri 260)"| COMM["Commercial Microsoft Foundry<br/>&lt;COMMERCIAL_FOUNDRY_BASE_URL&gt;"]
```

A request whose model is **not** in `commercial-models` never reaches any of this — it routes
intra-VNet to the private Foundry endpoint exactly as before.

---

## Parameters (all `infra/main.bicep`)

| Parameter | Placeholder | Default | Notes |
|---|---|---|---|
| `deployFoundryCommercial` | — | `false` | Master opt-in. Off = nothing commercial is created. |
| `commercialModels` | `<COMMERCIAL_MODELS>` | `''` | **The sentinel.** Comma-separated model names/prefixes (case-insensitive) that `/openai` and `/anthropic` route to the commercial backend. Empty = INERT: the backend exists but nothing selects it. |
| `foundryCommercialBaseUrl` | `<COMMERCIAL_FOUNDRY_BASE_URL>` | `''` | Public base URL of the commercial Foundry account, e.g. `https://<acct>.openai.azure.com`. **Required** when enabled. |
| `foundryCommercialApiVersion` | `<COMMERCIAL_API_VERSION>` | `2025-04-01-preview` | Injected on deployment-scoped paths (not `/responses`). |
| `foundryCommercialAuthMode` | `<COMMERCIAL_BACKEND_AUTH_MODE>` | `servicePrincipal` | `servicePrincipal` (default) / `apikey` / `managedIdentity`. See **Backend auth** below. |
| `foundryCommercialTenantId` | `<COMMERCIAL_TENANT_ID>` | `''` | Commercial tenant whose authority mints the backend token (SP mode). In CI supplied via the `COMMERCIAL_TENANT_ID` repo Variable (no tenant ID committed). |
| `foundryCommercialClientId` | `<COMMERCIAL_CLIENT_ID>` | `''` | Commercial-tenant SP app (client) ID (SP mode). **Required** when enabled in SP mode. |
| `foundryCommercialClientSecret` (secret) | `<COMMERCIAL_CLIENT_SECRET_SECRET_REF>` | `''` | Commercial-tenant SP secret (SP mode). Supply via secure variable / Key Vault — never commit. |
| `foundryCommercialTokenResource` | `<COMMERCIAL_TOKEN_RESOURCE>` | `https://cognitiveservices.azure.com` | Token resource; policy appends `/.default` for the scope. |
| `foundryCommercialAuthorityHost` | — | `login.microsoftonline.com` | Commercial AAD authority host (token endpoint). |
| `foundryCommercialAudience` | `<COMMERCIAL_FOUNDRY_AUDIENCE>` | `''` | MI token audience; **only** used in `managedIdentity` mode. |
| `foundryCommercialApiKey` (secret) | — | `''` | Commercial Foundry key; **only** used in `apikey` mode. Supply via secure variable — never commit. |
| `foundryCommercialEgressDestinations` | `<COMMERCIAL_DESTINATION_CIDRS_OR_SERVICE_TAGS>` | `[]` | Public-IP CIDRs the APIM subnet may reach on 443. **Required** when `restrictApimEgress=true`. |
| `foundryCommercialModelTypes` | `<COMMERCIAL_MODEL_TYPES>` | `''` (→ inert `{}`) | Discovered model→API-surface map for commercial models; read by the `/anthropic` route policy. |

> `<COMMERCIAL_DEPLOYMENT_NAMES>` is not a Bicep parameter — it is the set of deployment names
> that exist **on the commercial Foundry account**. Callers put one of these in the request body
> `"model"`, and each one you want routed commercially must also appear in `commercialModels`.
> The shared auto-route (`model: auto`) resolves to the **private** Foundry's deployment names, so
> use **explicit** model names for commercial models.

---

## Backend auth — caller token is NOT forwarded

Caller auth and backend auth are **separate**. The caller authenticates to **Gov APIM** with the
existing `authMode` (subscription key, or a Gov-tenant JWT validated against
`api://copilot-byok-gateway-…` / audience `<API_AUDIENCE>`). APIM establishes caller identity for
telemetry/throttling and then **strips the caller credential** (`api-key` and `Authorization` are
deleted) before calling the backend. The caller token is **never** sent to the commercial backend.

Why a separate token is mandatory: the commercial Foundry resource lives in a **different
Commercial tenant** (`<COMMERCIAL_TENANT_ID>`). A token minted in the **Gov** tenant
(including the Gov APIM managed identity) is rejected by the commercial tenant with
`TenantAccessDenied` — even though the network path (DNS, TCP 443, TLS) succeeds. APIM must
therefore present a token issued **by the commercial tenant**.

Pick the backend credential via `foundryCommercialAuthMode`:

- **`servicePrincipalFederated` (default, SECRETLESS).** Workload identity federation — no secret
  anywhere. APIM mints **its own** Gov managed-identity token with audience
  `api://AzureADTokenExchange` and presents it to the **commercial** authority as an OAuth2
  **`client_assertion`** (instead of a `client_secret`):
  1. `authentication-managed-identity resource="api://AzureADTokenExchange"` → APIM MI token.
  2. `POST https://login.microsoftonline.com/<COMMERCIAL_TENANT_ID>/oauth2/v2.0/token` with
     `grant_type=client_credentials`, `client_id=<COMMERCIAL_CLIENT_ID>`,
     `client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer`,
     `client_assertion=<APIM MI token>`, `scope=<COMMERCIAL_TOKEN_RESOURCE>/.default`.
  3. The commercial SP carries a **federated identity credential** trusting that APIM MI
     (issuer = Gov MI issuer, subject = APIM MI object ID, audience = `api://AzureADTokenExchange`).
  4. The resulting `access_token` is **cached** per tenant+client until ~5 min before expiry; any
     failure returns **502** (`CommercialTokenFederationFailed`) and never calls the backend.

  See **Service principal + federated credential (peer setup)** below for the exact commands.

  > ⛔ **Cross-sovereign-cloud (Gov → Commercial): CONFIRMED NOT SUPPORTED.** Commercial Entra
  > rejects the Gov APIM MI token as a FIC assertion with **`AADSTS700238`**. Everything else in the
  > federation path works (the token signature is validated cross-cloud and matching reaches the
  > subject/audience checks), but the platform forbids an Entra-tenant issuer from *another sovereign
  > cloud* for FIC. Use `servicePrincipal` (secret) below. `servicePrincipalFederated` is still the
  > right choice for **same-cloud** cross-tenant (e.g. commercial → commercial).

- **`servicePrincipal` (secret — REQUIRED for Gov → Commercial; VALIDATED).** Same client-credentials
  flow but authenticated with `client_secret=<foundry-commercial-client-secret>` (secret named value,
  masked in traces). This is the **validated** cross-sovereign-cloud path — a Gov-internal call
  returned 200 from the commercial Foundry. A Gov managed-identity token is still rejected by the
  commercial tenant (`TenantAccessDenied`), so a **Commercial-tenant SP** (with a secret) is required.
  See [servicePrincipal (secret) mode — validated step by step](#serviceprincipal-secret-mode--validated-step-by-step).
- **`apikey`.** APIM sends `foundry-commercial-api-key` in the `api-key` header (only if the
  commercial account permits key auth).
- **`managedIdentity`.** APIM mints an MI token for `foundryCommercialAudience`. **Not** valid
  cross-tenant (kept for same-tenant edge cases).

Either way the SP must be granted a data-plane role (e.g. `Cognitive Services OpenAI User`) on the
**commercial** Foundry account.

> **APIM design note.** APIM policy has no native "acquire SP/federated token" action
> (`authentication-managed-identity` only mints APIM's own MI token). Both SP modes are therefore
> implemented with `send-request` + `cache-store-value`/`cache-lookup-value`. In federated mode the
> `client_assertion` is exactly APIM's MI token (audience `api://AzureADTokenExchange`), so no
> secret exists anywhere — the trust is the federated identity credential on the commercial SP.

> The Level 2 auto-route classifier is **safe to run alongside the commercial route**, and both
> pilots do. Its `send-request` mints an MI token for the **local** Foundry
> (`foundry-private-base-url`), which is unaffected by commercial models being routed elsewhere
> via SP/federated auth — the classifier never touches the commercial backend, and `auto` resolves
> only to the local mini/full deployments. The one configuration that would genuinely break is
> pointing `autoRouteClassifierDeployment` at a **commercial** model, since MI is not valid
> cross-tenant. (An earlier version of this note advised disabling the classifier whenever
> commercial models were in play; that was over-broad — gov-pilot has run both together since.)

---

## Service principal + federated credential (peer setup)

Hand this to whoever owns the **commercial** tenant. **No secret is created or shared.**

**You (Gov side) provide two values from the running Gov APIM:**
```bash
# FIC subject = the APIM system-assigned managed-identity object (principal) ID
az apim show -g <gov-rg> -n <gov-apim-name> --query identity.principalId -o tsv
# FIC issuer — the Gov APIM MI mints a **v2** token (CONFIRMED by decoding a live token):
#   https://login.microsoftonline.us/<gov-tenant>/v2.0   (ver=2.0; NOT the v1 sts.windows.net form)
# NOTE: this peer setup only applies to SAME-CLOUD cross-tenant federation. For Gov → Commercial the
# federated path is blocked (AADSTS700238) — skip to servicePrincipal (secret) mode instead.
```

**Scripted (recommended).** All four steps below are codified in
[`scripts/setup-commercial-backend.ps1`](../scripts/setup-commercial-backend.ps1) (and the bash
twin [`scripts/setup-commercial-backend.sh`](../scripts/setup-commercial-backend.sh)). They are
idempotent and cannot be an azd hook on the Gov deployment because they are directory + RBAC writes
in a **different tenant and cloud**. Run them once, signed in to the **commercial** tenant.

First read the two Gov inputs (signed in to `AzureUSGovernment`, in the Gov subscription):
```bash
# FIC subject = the Gov APIM system-assigned MI object id (changes on every APIM recreate)
az apim show -g <gov-rg> -n <gov-apim> --query identity.principalId -o tsv
# Gov gateway NAT egress IP to allowlist on the commercial Foundry firewall
az network public-ip show -g <gov-rg> -n pip-natgw-copilot-byok-<env>-<suffix> --query ipAddress -o tsv
```
Then, signed in to the **commercial** tenant (`az cloud set --name AzureCloud; az login`):
```pwsh
./scripts/setup-commercial-backend.ps1 `
  -FoundryAccountName <commercial-foundry-account> -FoundryResourceGroup <commercial-rg> `
  -GovTenantId <gov-tenant-guid> -GovApimMiObjectId <gov-apim-mi-object-id> `
  -GovEgressIp <gov-nat-egress-ip> -AllowGovEgressIp
```
```bash
./scripts/setup-commercial-backend.sh \
  --foundry-account-name <commercial-foundry-account> --foundry-resource-group <commercial-rg> \
  --gov-tenant-id <gov-tenant-guid> --gov-apim-mi-object-id <gov-apim-mi-object-id> \
  --gov-egress-ip <gov-nat-egress-ip> --allow-gov-egress-ip
```
The script creates the app + SP (no secret), adds **both** a v1 (`sts.windows.net`) and v2
(`login.microsoftonline.us`) federated credential to hedge the Gov MI token format, grants
`Cognitive Services OpenAI User`, optionally allowlists the Gov egress IP, and prints
`COMMERCIAL_CLIENT_ID` / `COMMERCIAL_TENANT_ID` (also pushed to the azd env / `$GITHUB_ENV`). Set
`COMMERCIAL_CLIENT_ID` as `foundryCommercialClientId` on the Gov side. Omit `-AllowGovEgressIp` /
`--allow-gov-egress-ip` to leave the Foundry firewall untouched.

**Worked example (gov-dev → comm-pilot Foundry, validated):**
```pwsh
./scripts/setup-commercial-backend.ps1 `
  -FoundryAccountName <commercial-foundry-account> -FoundryResourceGroup <commercial-rg> `
  -GovTenantId <GOV_TENANT_ID> `
  -GovApimMiObjectId <GOV_APIM_MI_OBJECT_ID> `
  -GovEgressIp <GOV_NAT_EGRESS_IP> -AllowGovEgressIp
```

**By hand (equivalent steps), if you prefer the raw CLI:**
```bash
# 1. App registration + service principal — NO secret, NO certificate
az ad app create --display-name copilot-byok-commercial-backend
APPID=$(az ad app list --display-name copilot-byok-commercial-backend --query "[0].appId" -o tsv)
az ad sp create --id "$APPID"

# 2. Federated identity credential trusting the Gov APIM managed identity
az ad app federated-credential create --id "$APPID" --parameters '{
  "name": "gov-apim-fed",
  "issuer": "https://sts.windows.net/<GOV_TENANT_ID>/",
  "subject": "<GOV_APIM_MI_OBJECT_ID>",
  "audiences": ["api://AzureADTokenExchange"]
}'

# 3. Data-plane role on the commercial Foundry account so the token can call it
az role assignment create --assignee "$APPID" \
  --role "Cognitive Services OpenAI User" \
  --scope "<commercial Foundry account resource ID>"

# 4. Allow the Gov egress IP on the Foundry resource firewall (per-env NAT IP), then enable PNA
az cognitiveservices account network-rule add \
  -g <commercial-rg> -n <commercial-foundry-name> --ip-address <gov-nat-egress-ip>
az resource update --ids <commercial Foundry account resource ID> \
  --set properties.publicNetworkAccess=Enabled
```

They return the **app (client) ID** → set it as `foundryCommercialClientId`.

> **The NAT egress IP is per-environment.** Each environment's NAT gateway has its **own** public
> IP. Always read it live (`az network public-ip show … pip-natgw-…`) for the environment you are
> wiring — never reuse another environment's value.

**Cross-cloud caveat — RESOLVED (2026-07-01): federation is BLOCKED Gov → Commercial.** The Gov APIM
MI mints a **v2** token (issuer `https://login.microsoftonline.us/<gov-tenant>/v2.0`). Commercial
Entra validates its signature cross-cloud and matches FICs by subject/audience, but then **rejects it
with `AADSTS700238`** — an Entra-tenant issuer from *another sovereign cloud* may not be used for a
FIC. No FIC configuration fixes this (it is a platform restriction). **Use `servicePrincipal` (secret)
below for Gov → Commercial.** (The federated peer setup above is still correct for **same-cloud**
cross-tenant scenarios.)

> Diagnostic breadcrumbs, in case you re-verify: FIC audience must be the literal
> `api://AzureADTokenExchange` (a custom value → `AADSTS700214` at runtime); only **one** FIC is
> allowed per subject (a v1+v2 hedge → `AADSTS700263`); and the final wall is `AADSTS700238`.

---

## servicePrincipal (secret) mode — validated step by step

This is the **working, validated** path for **Gov → Commercial**. It reuses the same SP as the
federated setup (data-plane role + firewall allow are identical); the only difference is a **client
secret** instead of a federated credential.

**1. Commercial tenant** — create the SP (if not already) and a client secret. The
[`scripts/setup-commercial-backend.*`](../scripts/setup-commercial-backend.ps1) script does the app +
SP + role + firewall; add the secret with `-CreateSecret` (or by hand):
```bash
# signed in to the COMMERCIAL tenant (az cloud set --name AzureCloud; az login)
APPID=$(az ad app list --display-name copilot-byok-commercial-backend --query "[0].appId" -o tsv)
az ad app credential reset --id "$APPID" --display-name gov-backend --years 1 --append --query password -o tsv
# grant the SP a data-plane role + allow the Gov NAT IP on the Foundry firewall (as in peer setup):
az role assignment create --assignee "$APPID" --role "Cognitive Services OpenAI User" \
  --scope "<commercial Foundry account resource ID>"
az cognitiveservices account network-rule add -g <commercial-rg> -n <commercial-foundry> \
  --ip-address <gov-nat-egress-ip>
az resource update --ids "<commercial Foundry account resource ID>" \
  --set properties.publicNetworkAccess=Enabled            # keep networkAcls.defaultAction=Deny
```

**2. Gov deployment** — set the auth mode + supply the secret out-of-band, then provision:
```jsonc
"deployFoundryCommercial":       { "value": true },
"foundryCommercialBaseUrl":      { "value": "https://<acct>.cognitiveservices.azure.com" },
"foundryCommercialAuthMode":     { "value": "servicePrincipal" },
"foundryCommercialTenantId":     { "value": "${COMMERCIAL_TENANT_ID}" },
"foundryCommercialClientId":     { "value": "${COMMERCIAL_CLIENT_ID}" },
"foundryCommercialClientSecret": { "value": "${COMMERCIAL_FOUNDRY_CLIENT_SECRET}" },  // secure var / KV
"foundryCommercialEgressDestinations": { "value": [ "<FOUNDRY_DATA_CIDR>", "<AAD_LOGIN_CIDR>" ] }
```
APIM then does OAuth2 client-credentials at `https://login.microsoftonline.com/<COMMERCIAL_TENANT_ID>/oauth2/v2.0/token`
with `client_id` + `client_secret` + `scope=https://cognitiveservices.azure.com/.default`, caches the
token per tenant+client, and calls the commercial Foundry with `Authorization: Bearer <token>`.

**Validated result (gov-dev → commercial pilot Foundry, 2026-07-01):** both surfaces returned **200**
from inside the Gov VNet (internal APIM, source = the gateway's private IP):
```
POST /openai/v1/chat/completions {"model":"<commercial-model>",...}  → 200  content:"pong"  (content-filter applied)
POST /openai/v1/responses        {"model":"<commercial-model>",...}  → 200  (usage.total_tokens 15)
```

> **Secret lifecycle.** Rotate with `az ad app credential reset --append` in the commercial tenant and
> update `foundry-commercial-client-secret` (prefer a Key Vault-backed named value so rotation is a
> single secret-set, no redeploy; the token cache re-mints on the next request). `apikey` mode is the
> alternative when the commercial account permits key auth.

---

## Why not VNet peering / private cross-cloud connectivity?

The route deliberately goes over the **public internet** (pinned to the Gov NAT egress IP, TLS 1.2+,
IP-allowlisted on the Foundry) because **there is no private network path between Azure Government and
Azure Commercial**:

- **VNet peering / Global VNet peering — unsupported across clouds.** Peering only works within a
  single cloud and a single Entra environment. The peering API cannot reference a VNet resource ID in
  the other cloud (Gov `usgov*` ↔ Commercial `AzureCloud` are separate sovereign backbones + separate
  Resource Manager + Entra environments).
- **Private Endpoint / Private Link — also cannot cross clouds.** A Gov private endpoint cannot target
  a Commercial `cognitiveservices` account (and vice-versa); private DNS zones don't span clouds. This
  is why the commercial Foundry's `privatelink.cognitiveservices.azure.com` CNAME is *not* intercepted
  by the Gov VNet (which links the Gov `…azure.us` zones) and resolves publicly instead.
- **ExpressRoute — no cross-cloud circuit** between Gov and Commercial for this.
- **Site-to-Site IPsec VPN — technically possible but not worth it here.** You would stand up a VPN
  gateway in each cloud and tunnel over the public internet; it keeps private addressing but still
  traverses the public internet, and the Commercial Foundry would need a private endpoint inside the
  Commercial VNet for the tunnel to terminate against. For a single APIM → Foundry HTTPS path that is
  far more moving parts than the TLS + IP-allowlist + SP-token design here.

So the supported topology is: **public egress via the Gov NAT gateway IP → allowlisted on the commercial
Foundry firewall → TLS to the commercial data + AAD endpoints**, with the SP secret providing the
cross-tenant identity. The `Network / egress` section below is what enforces that path.

---

## Network / egress

When `restrictApimEgress=true` (the Gov default), the APIM subnet is private and denies all
internet egress except the Azure-internal service tags APIM needs. The commercial endpoint is on
the public internet, so it must be **explicitly allowlisted**:

- Setting `foundryCommercialEgressDestinations` adds NSG rule **`Allow-Out-FoundryCommercial`**
  (priority **260**, TCP 443) to the APIM subnet, evaluated **before** the priority-4000
  `Deny-Out-Internet` rule.
- In **`servicePrincipalFederated`** / **`servicePrincipal`** mode the allowlist must cover **two** commercial destinations: the
  Foundry **data** endpoint (`<COMMERCIAL_FOUNDRY_BASE_URL>`) **and** the commercial **AAD token**
  endpoint (`login.microsoftonline.com`). The Gov `AzureActiveDirectory` service tag resolves to
  **Gov** AAD only, so commercial AAD must be added by CIDR. Coordinate source-IP allowlisting of
  `<GOV_NAT_EGRESS_IP>` on **both** the commercial Foundry resource firewall and any conditional-access /
  named-location policy on the SP.
- Allowed traffic leaves via the shared **NAT gateway**, whose static public IP is
  **`<GOV_NAT_EGRESS_IP>`** — this is the source IP the commercial endpoint sees.
- **NSGs cannot match FQDNs.** Supply the commercial endpoint's **public-IP CIDRs**. Resolve the
  host (`nslookup <COMMERCIAL_FOUNDRY_BASE_URL host>`) or use the published AzureCloud/region
  ranges, and refresh them if they drift. The cleaner long-term option for FQDN-based egress is
  Azure Firewall application rules (consistent with `infra/modules/firewall.bicep`); the NSG CIDR
  allowlist is the minimal change that works today.

> If `restrictApimEgress=false`, no deny rule exists and the commercial endpoint is reachable
> without this allowlist — but then egress is **not** guaranteed to leave via `<GOV_NAT_EGRESS_IP>`.

---

## Environments & CI wiring

The commercial Foundry is a **Gov-side** feature: the `gov-*` environments hold the backend
configuration and authenticate to it; the `comm-*` environments only **provide the Foundry** it
calls. So the consumer config lives on the Gov environments and the backend-firewall config lives on
the Commercial ones. Each environment's CI values come from **GitHub environment-scoped**
Variables/Secrets (so no real tenant/client IDs are committed — the param files use `${...}`
substitution).

| Environment | Role | Param file | Deployed by | Commercial-backend settings |
|---|---|---|---|---|
| **gov-dev** | Backend **consumer** (dev) | `main.parameters.ci.gov-dev.json` | [deploy-dev.yml](../.github/workflows/deploy-dev.yml) (push/dispatch) | Vars `COMMERCIAL_TENANT_ID`, `COMMERCIAL_CLIENT_ID`, `COMMERCIAL_FOUNDRY_BASE_URL` + Secret `COMMERCIAL_FOUNDRY_CLIENT_SECRET` |
| **gov-pilot** | Backend **consumer** (pilot) | `main.parameters.ci.gov.json` | [deploy.yml](../.github/workflows/deploy.yml) (manual dispatch) | same three Vars + the Secret |
| **comm-pilot** | Backend **Foundry** (stable) | `main.parameters.ci.commercial.json` | deploy.yml (manual dispatch) | Var `FOUNDRY_PUBLIC_INGRESS_IPS` = the gov NAT egress IP(s) to allowlist |
| **comm-dev** | Backend **Foundry** (ephemeral) | `main.parameters.ci.commercial-dev.json` | deploy-dev.yml (push/dispatch, nightly teardown) | Var `FOUNDRY_PUBLIC_INGRESS_IPS` **optional** — set only to exercise the ingress hook in CI |

**Both gov environments target the `comm-pilot` Foundry** (long-lived, stable name) as the shared
backend — `comm-pilot`'s firewall therefore allowlists **both** gov NAT egress IPs (dev + pilot).
`comm-dev` is not on the data path; its `FOUNDRY_PUBLIC_INGRESS_IPS` is set purely so each
ephemeral `comm-dev` deploy runs the ingress hook and catches script regressions before they reach
`comm-pilot`.

### CI Variables / Secret (per environment)

| Name | Kind | Set on | Feeds param | Purpose |
|---|---|---|---|---|
| `COMMERCIAL_TENANT_ID` | Variable | gov-dev, gov-pilot | `foundryCommercialTenantId` | Commercial tenant that mints the backend token |
| `COMMERCIAL_CLIENT_ID` | Variable | gov-dev, gov-pilot | `foundryCommercialClientId` | Commercial-tenant SP app (client) id |
| `COMMERCIAL_FOUNDRY_BASE_URL` | Variable | gov-dev, gov-pilot | `foundryCommercialBaseUrl` | Commercial Foundry account URL (no account name committed) |
| `COMMERCIAL_FOUNDRY_CLIENT_SECRET` | **Secret** | gov-dev, gov-pilot | `foundryCommercialClientSecret` | SP client secret (servicePrincipal mode) |
| `FOUNDRY_PUBLIC_INGRESS_IPS` | Variable | comm-pilot (+ comm-dev opt-in) | — (consumed by the hook) | Space/comma-separated gov NAT egress IPs to allowlist on this deploy's Foundry firewall |

The workflows export these into the `azd provision` steps (`deploy.yml`, `deploy-dev.yml`); an unset
value substitutes empty, so the route stays off / the hook no-ops on environments that don't opt in.

### Backend firewall hook

The commercial Foundry pins `publicNetworkAccess: 'Disabled'` in Bicep (private-endpoint-only default).
The post-provision hook [`scripts/allow-foundry-ingress-ips.*`](../scripts/allow-foundry-ingress-ips.ps1)
(wired in [azure.yaml](../azure.yaml)) runs on the **Commercial** deploy, reads `FOUNDRY_PUBLIC_INGRESS_IPS`,
and — only when non-empty — sets `publicNetworkAccess=Enabled` (defaultAction stays `Deny`) with those
IPs in `ipRules`. The comm-pilot's own private-endpoint path is unaffected (PE bypasses `networkAcls`);
Bicep clears `ipRules` each provision and the hook re-adds the current list, so removed IPs converge out.
It **no-ops** (and touches nothing) when the variable is empty — so Gov deploys and non-participating
Commercial deploys are never affected.

> **Per-environment NAT IP.** Each Gov environment's NAT gateway has its **own** egress IP; the commercial
> Foundry firewall must list **each** one that routes to it. Read them live
> (`az network public-ip show … pip-natgw-copilot-byok-<env>-<suffix>`).

---

## Deploy

1. In your gov parameters file (`infra/main.parameters.json`, copied from
   `infra/main.parameters.gov.example.json`) set:
   ```jsonc
   "deployFoundryCommercial":             { "value": true },
   "commercialModels":                    { "value": "<COMMERCIAL_MODELS>" },  // e.g. "gpt-5.6-luna,claude-"
   "foundryCommercialBaseUrl":            { "value": "https://<acct>.services.ai.azure.com" },
   "foundryCommercialAuthMode":           { "value": "servicePrincipal" },
   "foundryCommercialTenantId":           { "value": "${COMMERCIAL_TENANT_ID}" },
   "foundryCommercialClientId":           { "value": "${COMMERCIAL_CLIENT_ID}" },
   "foundryCommercialClientSecret":       { "value": "${COMMERCIAL_FOUNDRY_CLIENT_SECRET}" },  // secure var / KV
   "foundryCommercialEgressDestinations": { "value": [ "<FOUNDRY_DATA_CIDR>", "<AAD_LOGIN_CIDR>" ] }
   ```
   First complete the commercial-tenant peer setup above — running
   [`scripts/setup-commercial-backend.*`](../scripts/setup-commercial-backend.ps1) with
   `-SkipFederatedCredential -CreateSecret` is the recommended way (it also handles the source-IP
   allowlist on the commercial Foundry firewall with `-AllowGovEgressIp`).
2. `azd provision` (or your `az deployment sub create` flow). Models **not** named in
   `commercialModels` keep going to the private Foundry, unchanged.

> **Forgetting `commercialModels` is the common miss.** With `deployFoundryCommercial=true` but an
> empty sentinel the backend, named values and NSG rule all exist and nothing ever uses them — every
> request still lands on the private Foundry (and a commercial-only model 404s there).

---

## Configure clients

**Nothing to configure.** That is the point of the sentinel: there is one base URL, and the gateway
picks the backend under the wire. A client already pointed at `/openai` reaches commercial models by
asking for them **by name**.

**Copilot CLI:**
```bash
APIM_SUBSCRIPTION_KEY=<dev-key> source ./scripts/copilot-cli-byok.sh \
  https://<apim-gateway>/openai <commercial-model>
```
Or set the env directly:
```bash
export COPILOT_PROVIDER_BASE_URL="https://<apim-gateway>/openai"
export COPILOT_PROVIDER_API_KEY="<dev subscription key or Entra JWT>"
export COPILOT_MODEL="<COMMERCIAL_DEPLOYMENT_NAMES>"   # a name listed in commercialModels
```

> This is *why* the sentinel exists. The CLI's `azure` provider **discards any path** on
> `COPILOT_PROVIDER_BASE_URL` and always calls `/openai`, so a parallel commercial path was
> unreachable from the CLI no matter how it was configured.

**VS Code (Custom Endpoint provider, 1.122+):** keep the base URL at
`https://<apim-gateway>/openai` and add the commercial model ids to the existing provider block;
`apiType: responses` is supported on the same route.

---

## Anthropic / Claude models

Claude models in Microsoft Foundry speak the **Anthropic Messages API** (`POST /v1/messages`),
**not** OpenAI chat/completions. They are commercial-hosted, so they are selected by the same
`commercial-models` sentinel — but they need a front door that speaks their wire format and accepts
their credential header:

| Client | Route | Credential header | Behaviour |
|---|---|---|---|
| Anthropic-speaking (`COPILOT_PROVIDER_TYPE=anthropic`, VS Code `apiType: "messages"`, Anthropic SDKs) | `/anthropic/v1/messages` (opt-in, `deployAnthropicRoute=true`) | `x-api-key` | Native passthrough (param-safety only). **Streaming supported** — APIM relays SSE unbuffered. |
| OpenAI-speaking (Copilot CLI `azure` provider, VS Code `chat-completions`) | `/openai/v1/chat/completions` | `api-key` | An Anthropic model here is **refused** with a typed `400 WireFormatMismatch` naming the fix. |

**Why `/anthropic` is a separate API and not a policy branch.** APIM validates the subscription key
from the header **declared on the API**, *before* any policy executes, and an API can declare only
one such header. A `type=anthropic` client always sends `x-api-key`, so it cannot authenticate
against `/openai` (which declares `api-key`) no matter what the policy does. It is **not** a second
backend and **not** a second credential — same subscription key, same product tier, same quotas and
telemetry, which is what makes those clients meterable per developer key.

**Why `/openai` refuses instead of translating.** The gateway **validates and explains; it never
silently reshapes a request.** A reshaped request is a different request — different token
accounting, different content-filter surface, and a class of bugs that only appears in production.
So an Anthropic model on the OpenAI wire returns a typed error that names the fix:

```json
{"error":{"code":"WireFormatMismatch","message":"Model '<model>' is an Anthropic model and speaks the native Anthropic Messages API. Set COPILOT_PROVIDER_TYPE=anthropic and point the base URL at the /anthropic route."}}
```

### Enable it

```jsonc
"deployFoundryCommercial": { "value": true },
"deployAnthropicRoute":    { "value": true },
"commercialModels":        { "value": "claude-,anthropic-" }   // comma-sep names/prefixes
```

### Smoke

```bash
# Native Anthropic Messages — note the x-api-key header:
curl -sS https://<apim-gateway>/anthropic/v1/messages \
  -H "x-api-key: <key>" -H "content-type: application/json" \
  -d '{"model":"<claude-model>","messages":[{"role":"user","content":"ping"}],"max_tokens":16}'
# → 200, native Anthropic message shape (content[0].text).

# Same model on the OpenAI wire — expected to be REFUSED, not reshaped:
curl -sS https://<apim-gateway>/openai/v1/chat/completions \
  -H "api-key: <key>" -H "content-type: application/json" \
  -d '{"model":"<claude-model>","messages":[{"role":"user","content":"ping"}]}'
# → 400 WireFormatMismatch.
```

---

## Validation checklist

1. **Template compiles:** `az bicep build --file infra/main.bicep --stdout >/dev/null`.
2. **Sentinel set:** `az apim nv show -g <rg> --service-name <apim> --named-value-id commercial-models`
   → the model names/prefixes you expect (not empty / `__none__`).
3. **No second API:** `az apim api list -g <rg> --service-name <apim> --query "[].path"` → `openai`
   (+ optional `aoai`, `anthropic`). There is deliberately **no** commercial path.
4. **Policy attached:** `az apim api policy show --api-id copilot-byok-foundry ...`
   → references `{{commercial-models}}`, `{{foundry-commercial-backend-id}}` and the commercial
   auth block.
5. **Backend exists:** `az apim backend show --backend-id foundry-commercial ...` → commercial URL.
6. **Named values set:** `foundry-commercial-base-url`, `-backend-id`, `-api-version`,
   `-auth-mode` (=`servicePrincipal`), `-tenant-id`, `-client-id`, `-token-resource`,
   `-authority-host`, plus secrets `-client-secret` and `-api-key`.
7. **Product association:** unchanged — there is one inference API per wire format, already linked
   to `byok-standard` / `byok-power`, so existing keys reach commercial models with no extra link.
8. **NAT egress IP:**
   `az network public-ip show -g <rg> --name pip-natgw-copilot-byok-<env>-<suffix> --query ipAddress`
   → `<GOV_NAT_EGRESS_IP>`.
9. **Egress allow rule:** the APIM NSG has `Allow-Out-FoundryCommercial` (priority 260) with your
   CIDRs; confirm the commercial endpoint's access logs / NSG flow logs show source `<GOV_NAT_EGRESS_IP>`.
10. **Routing — chat:**
    ```bash
    curl -sS https://<apim-gateway>/openai/v1/chat/completions \
      -H "api-key: <key>" -H "content-type: application/json" \
      -d '{"model":"<commercial-deployment>","messages":[{"role":"user","content":"ping"}]}'
    ```
    → 200 from the commercial backend (the smoke suite's `commercial-via-default` assertion).
11. **Routing — responses:**
    ```bash
    curl -sS https://<apim-gateway>/openai/v1/responses \
      -H "api-key: <key>" -H "content-type: application/json" \
      -d '{"model":"<commercial-deployment>","input":"ping"}'
    ```
    → 200 (rewritten to `/openai/v1/responses`, no dated api-version).
12. **Metrics:** `copilot_byok_request` (and token metrics) emit with dimension
    `backend = foundry-commercial` (Application Insights / `copilot.byok` namespace).
13. **Private backend untouched:** a model **not** in `commercialModels` still lands on the private
    Foundry and the `/openai` smoke test passes unchanged.
14. **Token acquisition (SP mode):** trigger one commercial request and confirm a 200 (not 502
    `CommercialTokenAcquisitionFailed`). A 502 means the SP credentials are wrong or the commercial
    AAD token endpoint is not in the egress allowlist. In an APIM **trace** (Ocp-Apim-Trace), the
    `send-request` to `login.microsoftonline.com/<tenant>/oauth2/v2.0/token` returns 200 and the
    `client_secret` is masked.
15. **Bearer backend call:** the outbound request to the commercial backend carries
    `Authorization: Bearer …` (the commercial SP token) and **no** `api-key`; the caller credential
    is absent (stripped).
16. **TLS-only:** both the token endpoint and the backend URLs are `https://`; the backend
    succeeds with certificate validation on (no `validateCertificate*: false`).
17. **Caller token NOT forwarded:** with a caller JWT that passes Gov validation, confirm via trace
    that the backend never receives it (the `api-key` / `Authorization` caller headers are deleted
    before the backend call).
18. **Caller JWT still works to Gov APIM:** `az account get-access-token --resource
    api://copilot-byok-gateway-<GOV_TENANT_SHORT>` → use as the `api-key`; Gov `validate-jwt` accepts it and
    the request reaches the backend with the **commercial** token instead.

---

## Risks & follow-ups

- **SP secret lifecycle.** The client secret expires; rotate it (`az ad sp credential reset` in the
  commercial tenant) and update `foundry-commercial-client-secret`. Prefer a Key Vault-backed named
  value so rotation is a single secret-set with no redeploy. The token cache re-mints automatically
  on the next request after a rotation (cache key includes tenant+client).
- **Secret in the token-request body.** The client-credentials body is built in a policy expression
  with the secret named value URL-encoded; APIM masks secret named values in traces. If a future SP
  secret value contains a `"`, use the Key Vault-backed named value path.
- **NSG CIDR drift.** Commercial Foundry **and** commercial AAD IPs can change; NSG can't match
  FQDNs. Track the ranges or migrate APIM egress to Azure Firewall application rules.
- **Auto-route deployment names** resolve against the **private** Foundry. Use explicit model names
  for commercial models (`<COMMERCIAL_DEPLOYMENT_NAMES>`); `model: auto` will not pick one.
- **Data residency / compliance.** Sending Gov-originated traffic to a Commercial Foundry endpoint
  crosses a cloud boundary — confirm this is permitted for your data classification before enabling.

---

## Retired

Historical record. **Neither of these exists any more**; nothing below is deployable.

### The parallel `/openai-commercial` route

A second APIM API (`copilot-byok-foundry-commercial`, path `openai-commercial`) that carried a
near-duplicate copy of the Foundry policy and pointed at the commercial backend. Clients selected it
by **base URL**.

**Why it went.** The Copilot CLI's `azure` provider **discards any path** on
`COPILOT_PROVIDER_BASE_URL` and always calls `/openai`, so the route was unreachable from the primary
client it was built for. The `commercial-models` sentinel
(#118) selects the same
backend per-request on the route the CLI *can* reach, which made the parallel API redundant — and
deleting it removed a duplicated policy that had to be kept in lockstep with the original (six route
policies became four). Removed with it: `infra/modules/apim-foundry-commercial-api.bicep`,
`infra/overlay-commercial-route.bicep`, the four `policies/byok-foundry-commercial-*.xml` files, and
the params `foundryCommercialApiName`, `foundryCommercialApiPath`, `addCommercialToProductTiers`.

**Migration:** drop the path suffix — `https://<apim-gateway>/openai` — and make sure every model
you were reaching commercially is listed in `commercialModels`.

### The Claude streaming sidecar

An in-VNet `anthropic-stream-proxy` Azure Container Instance at `claude-proxy.byok.internal:8080`
(#117) that transcoded
OpenAI ⇄ Anthropic **while streaming**, to work around the fact that the in-policy translation shim
(#116) had to buffer the
whole response in order to reshape it.

**Why it went.** It only existed to reshape a stream, and reshaping is exactly what the gateway no
longer does: the native `/anthropic` route passes the Anthropic body through untouched, and **APIM
relays SSE unbuffered**, so token-by-token Claude works with no extra hop. The sidecar was a
compute-and-DNS dependency, an extra image to bake and pull, and a second place for wire-format bugs
to hide — in exchange for a translation the design had already rejected. Removed with it:
`infra/anthropic-stream-proxy-image/`, `infra/modules/anthropic-stream-proxy-aci.bicep`, and the
param `anthropicStreamProxyImageTag`.

**Migration:** point Anthropic-speaking clients at `https://<apim-gateway>/anthropic` with the key
in `x-api-key`. OpenAI-speaking clients get a typed `400 WireFormatMismatch` naming that fix instead
of a silently reshaped request.
