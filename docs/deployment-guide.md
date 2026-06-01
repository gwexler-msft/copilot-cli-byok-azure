# Deployment Guide

This guide assumes the plan has been reviewed and the Entra tenant + Azure
subscription are picked. **Nothing here destroys data.** Steps 0–2 are read-only prep and
validation; **Step 3 is the only step that creates or changes Azure resources**, and it runs
in ARM **incremental** mode — re-running it is idempotent and converges in place, it never
deletes resources that are absent from the template. The only intentionally destructive action
in this guide is **Teardown** (`az group delete`) at the very end. See *Idempotency, safe
re-runs & recovery* under Step 3 for what is (and isn't) safe to re-run.

## Which cloud are you deploying to?

The same template serves two distinct use cases. **Pick one now** — it determines the
parameters profile you copy in Step 1 and the cloud you sign into. There are **no code
changes** between them; everything is driven by the `cloudEnv` param (see
[Cloud parameterization](architecture.md#cloud-parameterization)).

| | **Government** (`AzureUSGovernment`) | **Commercial** (`AzureCloud`) |
|---|---|---|
| **Use case** | Sovereign / regulated workloads (DoD, federal, CJIS, ITAR) that must stay in Azure Government. The pilot's default. | Standard enterprise tenants, dev/test, or any workload without a sovereign-cloud mandate. |
| **Account** | `*.onmicrosoft.us` identity in a Gov tenant | `*.onmicrosoft.com` identity in a commercial tenant |
| **Sign-in** | `az cloud set --name AzureUSGovernment` then `az login --use-device-code` | `az cloud set --name AzureCloud` then `az login` |
| **Parameters profile** | `infra/main.parameters.example.json` | `infra/main.parameters.commercial.example.json` |
| **`cloudEnv`** | `AzureUSGovernment` | `AzureCloud` |
| **Typical region** | `usgovvirginia` | a commercial region (e.g. `eastus2`) that hosts your model |
| **Model SKU** | `DataZoneStandard` (`GlobalStandard` is N/A in usgovvirginia) | `GlobalStandard` |
| **`services.ai` DNS zone** | none (Gov has no `services.ai` zone — derived empty & skipped) | `privatelink.services.ai.azure.com` is created + linked |
| **`azd` cloud config** | `azd config set cloud.name AzureUSGovernment` (**required** — see azd section) | default (`AzureCloud`) — no extra config |

> Everything downstream follows the cloud you select here: the Entra/Graph scripts read
> it from `az cloud show`, the Bicep derives all endpoints from `cloudEnv`, and (for the
> `azd` path) `azd`'s `cloud.name` selects the AAD authority. The rest of this guide is
> written Gov-first; **Commercial callouts are inline** wherever the two differ.

## 0. Prereqs

### Required tools

`azd` (the Azure Developer CLI) is the **primary** way to deploy this repo. Install all
of these once per machine — the versions are the floors this repo is validated against.

| Tool | Min version | Why it's needed | Install / upgrade |
|---|---|---|---|
| **Azure Developer CLI (`azd`)** | **1.25.4** | Primary deploy driver. Reads [azure.yaml](../azure.yaml), provisions `infra/main` and manages the per-cloud environment. | `winget install Microsoft.Azd` / `winget upgrade Microsoft.Azd` (or `brew install azd`, `curl -fsSL https://aka.ms/install-azd.sh \| bash`) |
| **Azure CLI (`az`)** | 2.60+ | Used by the alternative `az deployment` path, the Entra setup script, RBAC/playground grants, and fetching dev keys. `azd` also shells out to it. | `winget upgrade Microsoft.AzureCLI` (or `brew upgrade azure-cli`) |
| **Bicep CLI** | 0.30+ | Compiles `infra/main.bicep`. `azd` and `az` both invoke it. | `az bicep upgrade` |
| **PowerShell 7+ (`pwsh`)** | 7.4+ | Runs `scripts/setup-entra.ps1` and the probe/wrapper scripts. (bash equivalents exist under `scripts/*.sh`.) | `winget upgrade Microsoft.PowerShell` |
| **GitHub Copilot CLI** | latest | The BYOK client you point at the gateway (Step 7). | `npm i -g @github/copilot` |

> Verify in one shot: `azd version; az version; az bicep version; pwsh -v`. If `azd version`
> prints an older build than 1.25.4, run the upgrade — a fresh terminal is needed after
> `winget upgrade` so `PATH` resolves the new binary.

### Required permissions

- Azure CLI logged in: `az login` (Commercial) or `az login --use-device-code` against Gov.
- **Contributor** on the subscription (to create the RG, VNet, APIM, AOAI/Foundry, etc.).
- **A role-assignment-capable role** — **User Access Administrator**, **Role Based Access
  Control Administrator**, or **Owner** at the subscription/RG scope — so the APIM managed
  identity can be granted `Cognitive Services OpenAI User` on AOAI **and** Foundry (the
  accounts have local auth disabled, so the gateway needs this or data-plane calls return
  `401 PermissionDenied`). **This is required regardless of how the grant happens.** In Gov
  least-privilege setups, **activate the role as an eligible (PIM) role for the deployment
  window only** and deactivate it after.
- **How the grant happens (both shipped example param files set `assignAoaiRbac=false`):**
  - **Default — `assignAoaiRbac=false` + `azd` postprovision hook (recommended).** The
    template skips the in-template RBAC module; the **postprovision hook** grants both
    accounts via the direct RBAC API. This is the only path that works for a **constrained
    (ABAC-conditioned) Owner**, where the in-template grant fails (see note in Step 3).
  - **Alternative — `assignAoaiRbac=true` (in-template).** Set it to `true` in your params
    only if you hold an **unconstrained** Owner/UAA; the template then creates both role
    assignments itself and there is **no follow-up step**. (The bicep *param* still defaults
    to `true`, but every committed `*.example.json` overrides it to `false`.)
- For the Gov pilot, sign in with an account in your Gov tenant (`*.onmicrosoft.us`).

> **Automated by `azd` hooks.** [azure.yaml](../azure.yaml) wires two hooks so you don't have
> to remember these steps:
> - **`preprovision`** → [`scripts/check-deploy-access`](../scripts/check-deploy-access.ps1)
>   inspects your effective subscription roles and reports whether you can (a) create
>   resources (Owner/Contributor) and (b) write role assignments (Owner / User Access
>   Administrator / RBAC Administrator). It **aborts** the deploy if you lack resource-creation
>   rights, and fails fast on missing RBAC rights when `assignAoaiRbac=true`
>   (set `azd env set assignAoaiRbac true|false` to match your params file; default behavior
>   when unset is warn-and-continue).
> - **`postprovision`** → [`scripts/grant-apim-mi-rbac`](../scripts/grant-apim-mi-rbac.ps1)
>   resolves the APIM MI principalId (it changes on every recreate) and idempotently grants
>   `Cognitive Services OpenAI User` on the AOAI **and** Foundry accounts. Safe in both modes:
>   with the default `assignAoaiRbac=false` it **is** the grant; when `true` it just
>   re-confirms the in-template grant (`az` returns the existing assignment). Both hooks use
>   `az`'s direct RBAC API, which **works for a constrained (ABAC-conditioned) Owner** even
>   though the in-template path does not (see note in Step 3).

```pwsh
# Commercial pilot
az cloud set --name AzureCloud
az login
az account set --subscription "<your sub id>"

# Government pilot
az cloud set --name AzureUSGovernment
az login --use-device-code
az account set --subscription "<your gov sub id>"
```

> **Pick your cloud once, here.** Everything downstream follows the active cloud:
> the Entra/Graph scripts read it from `az cloud show`, and the Bicep derives all
> endpoints from the `cloudEnv` parameter. The two clouds differ only in **which
> parameters profile** you start from (next step) — there are no code changes. See
> [Cloud parameterization](architecture.md#cloud-parameterization) for the full
> endpoint matrix and the `services.ai`-zone caveat that is Commercial-only.

## 1. Create the Entra app registration

This is **outside Bicep** because it lives in Microsoft Graph, not ARM.

```pwsh
./scripts/setup-entra.ps1 -DisplayName "copilot-byok-gateway" -ScopeName "cli.invoke"
```

It prints:

```
appIdUri: api://copilot-byok-gateway-<your-tenant-short>
clientId: <guid>
tenantId: <guid>
```

Create your local parameters file from the committed template that matches your cloud,
then fill in these values:

```pwsh
# Government (default pilot):
Copy-Item infra/main.parameters.example.json infra/main.parameters.json

# Commercial: start from the AzureCloud profile instead
#   (cloudEnv=AzureCloud, a commercial region, modelDeploymentSku=GlobalStandard already set):
# Copy-Item infra/main.parameters.commercial.example.json infra/main.parameters.json
```

Edit `infra/main.parameters.json` and replace the `<PLACEHOLDER>` values —
`entraTenantId` (tenantId), `apiAudience` (clientId), `apiAppIdUri` (appIdUri), and
`apimPublisherEmail`. This file is **gitignored** so your tenant-specific values are
never committed; the two `*.example.json` templates are the only parameters files in
source control. For Commercial, also confirm your `location` hosts the model + SKU
(`az cognitiveservices account list-skus`) before deploying.

## 2. Validate the Bicep

```pwsh
az bicep build --file infra/main.bicep
```

If it builds clean, preview the plan. With `azd` (primary path) this is `azd provision
--preview` (run it after the `azd` env is set up in Step 3); to preview without `azd`,
run a what-if at subscription scope:

```pwsh
az deployment sub what-if `
  --location usgovvirginia `
  --template-file infra/main.bicep `
  --parameters @infra/main.parameters.json
```

Read the preview/what-if output. **Stop here and inspect before going further.**

> **Commercial (`AzureCloud`) first run:** use your commercial region for `--location`
> and confirm the plan includes the **`privatelink.services.ai.azure.com`** private DNS
> zone plus its VNet link and the Foundry PE A-record in it. That zone exists only in
> Commercial (Gov derives it as empty and skips it), so a Commercial deployment is the
> only time this path is exercised — verify it here before deploying.

## 3. Deploy infrastructure

**`azd` is the primary path.** [azure.yaml](../azure.yaml) wires `azd` to the same
subscription-scope `infra/main` template and the `infra/main.parameters.json` you prepared
in Step 1, so `azd provision` runs the identical Bicep as a hand-rolled `az deployment`.
Because there is no `services:` block, `azd up` == `azd provision` (infra only). This single
flow creates the RG, VNet, APIM (~30–45 min), AOAI + Foundry + PEs + DNS, App Insights, the
APIM gateway Private DNS zone (`deployApimPrivateDns`, default true), and optionally the
P2S VPN gateway (`deployVpnGateway`, another ~30 min) and a Windows test VM + Azure Bastion
(`deployTestVm`). The APIM-MI → AOAI/Foundry role grant is handled by the **postprovision
hook** (shipped default `assignAoaiRbac=false`); set `assignAoaiRbac=true` to have the
template grant it in-line instead.

```pwsh
# 1. Point azd's AUTH + resource layer at the Gov cloud GLOBALLY, then sign in.
#    This MUST be the global cloud.name config — it governs which AAD authority the
#    token is minted against. Setting it only on the environment (AZURE_CLOUD_NAME)
#    steers provisioning endpoints but NOT the login authority, so the token is issued
#    by public AAD and Gov ARM rejects it: "AADSTS90051: Invalid national Cloud ID (2)".
azd config set cloud.name AzureUSGovernment
azd auth logout                                        # clear any stale public-cloud token
azd auth login --tenant-id <your-gov-tenant-guid>      # add --use-device-code if the browser redirect is blocked

# 2. Create the azd environment for this deployment.
azd env new gov-pilot --subscription <gov-sub-id> --location usgovvirginia
azd env set AZURE_CLOUD_NAME AzureUSGovernment         # belt-and-suspenders for provisioning endpoints

# 3. Preview the plan (what-if), then provision. No services: block => provision == up.
azd provision --preview
azd provision
```

> **Sovereign-cloud auth gotcha.** The global `azd config set cloud.name AzureUSGovernment`
> is what makes `azd auth login` use the Gov AAD authority (`login.microsoftonline.us`).
> The per-environment `AZURE_CLOUD_NAME` does **not** redirect the login authority — only
> the resource/management endpoints. If you skip the global config (or set only the env
> var), login mints a **public-cloud** token and provisioning fails with
> `AADSTS90051: Invalid national Cloud ID (2)`. To switch back to Commercial later:
> `azd config set cloud.name AzureCloud` (or `azd config unset cloud.name`).
>
> **`azd provision --preview` is benign-noisy on existing infra.** On an already-deployed
> environment the preview shows the core resources (RG, AI Services accounts, VNet, Log
> Analytics) as `Skip` (no change) and reports a handful of `Modify` lines for read-only /
> computed / API-default properties — e.g. APIM `natGatewayState`/`legacyPortalStatus`,
> model `currentCapacity`/`versionUpgradeOption`, App Insights `Flow_Type`/`Request_Source`,
> PE `isIPv6EnabledPrivateEndpoint`. These are ARM what-if artifacts, **not** real drift.
>
> **Literal parameters are intentional.** `infra/main.parameters.json` uses literal
> values (e.g. `"location": "usgovvirginia"`), **not** `azd`'s `${AZURE_LOCATION}`
> substitution tokens. That keeps the file usable by **both** `azd` and the alternative
> `az deployment sub create` — the az CLI passes `${...}` through verbatim, so tokenizing
> would break the direct path. With literals, `azd` simply honors the values in the file;
> the azd environment's location/name are not injected into resource names. If you want azd
> to own those, switch to a fully azd-only workflow and tokenize, but you then lose the
> direct `az deployment` path.
>
> **Outputs.** After `azd provision`, the Bicep outputs land in the azd environment —
> read them with `azd env get-values` (instead of querying `az deployment sub show`).
> The per-developer subscription keys are still retrieved with `az apim subscription`
> as in Step 6.

**Commercial (`AzureCloud`) with `azd`.** Commercial is `azd`'s default cloud, so the
sovereign-cloud dance is unnecessary — **do not** set `cloud.name` (or set it back with
`azd config set cloud.name AzureCloud` / `azd config unset cloud.name` if you previously
targeted Gov). The flow collapses to:

```pwsh
azd auth login                                        # default AzureCloud authority
azd env new comm-pilot --subscription <commercial-sub-id> --location <commercial-region>
azd provision --preview
azd provision
```

> Make sure `infra/main.parameters.json` was copied from
> `infra/main.parameters.commercial.example.json` (Step 1) so `cloudEnv=AzureCloud`,
> `modelDeploymentSku=GlobalStandard`, and a commercial `location` are in effect before
> you provision.

### Alternative: deploy with `az deployment sub create`

If you prefer raw ARM (or can't use `azd`), the same template deploys directly. This is the
path the project's CI/probe scripts use, and it sidesteps `azd`'s per-cloud `cloud.name`
config entirely — the active `az cloud set` already determines the authority.

```pwsh
az deployment sub create `
  --name "copilot-byok-$(Get-Date -Format yyyyMMdd-HHmm)" `
  --location usgovvirginia `
  --template-file infra/main.bicep `
  --parameters @infra/main.parameters.json
```

Read the outputs with `az deployment sub show --name <name> --query properties.outputs`.

> **Model/SKU (Gov):** `GlobalStandard` does not exist in usgovvirginia. The pilot uses
> **gpt-5.1 (2025-11-13) on DataZoneStandard**, capacity 50.
>
> **Mini tier (auto-routing):** `deployMiniModel=true` also deploys a cheap tier on each
> backend — **gpt-4.1-mini (2025-04-14) on DataZoneStandard**, capacity 50 — used when a
> caller sends the sentinel model `auto`. Confirm the exact mini name/version in your region
> with `az cognitiveservices model list --location <region>` first (`gpt-5.1-mini` is **not**
> available in usgovvirginia). Tune routing via the `autoRoute*` params (threshold 500, band
> 200, classifier off by default). Set `deployMiniModel=false` to skip the tier entirely.
>
> **RBAC:** the shipped params set `assignAoaiRbac=false`, so this raw `az deployment` path
> grants the APIM MI **no** data-plane role. Unlike `azd`, `az deployment` does **not** run the
> hooks, so you must grant it yourself afterwards — run
> [`scripts/grant-apim-mi-rbac`](../scripts/grant-apim-mi-rbac.ps1) (see below). Only set
> `assignAoaiRbac=true` if you hold an unconstrained Owner/UAA and want the template to grant it.
>
> **AOAI re-PUT race:** re-running the full `az deployment sub create` can fail with
> `AccountProvisioningStateInvalid` because the template re-PUTs the AOAI account while
> it is still settling. Once AOAI is `Succeeded`, deploy individual modules at RG scope
> (e.g. `infra/modules/apim-aoai-api.bicep`, `apim-private-dns.bicep`, `testvm.bicep`)
> instead of the whole subscription template.
>
> **`api-version` floor:** the gateway injects `api-version` from the
> `aoai-default-api-version` named value (param `defaultAoaiApiVersion`, default
> `2025-04-01-preview`). `gpt-4.1`/`gpt-5.1` need `2025-04-01-preview` or later; an older
> value makes a *live* deployment return `404 Resource not found`. If you patch the named
> value directly on a running APIM, also bump the Bicep default so it survives the next deploy.
>
> **`max_tokens` on gpt-5.x:** the `gpt-5.x` family rejects `max_tokens`
> (`400 ... use 'max_completion_tokens'`); `gpt-4.1-mini` accepts both. When probing the
> sentinel `auto` route (which can land on either tier), send `max_completion_tokens`.

### Out-of-band RBAC (only if `assignAoaiRbac=false`)

With `assignAoaiRbac=false` the template grants the APIM managed identity **no** data-plane
role, so an Owner/UAA must grant `Cognitive Services OpenAI User` on **each deployed account**
— AOAI **and** Foundry. Granting only AOAI makes the gateway return `200` on the `/aoai` path
but `401 PermissionDenied` ("Principal does not have access to API/Operation") on the Foundry
`/openai` path, because the MI cannot reach the Foundry backend.

**Easiest: run the script** (this is exactly what the `postprovision` hook runs, so an `azd`
deploy already does it for you — use this only for the raw `az deployment` path or to re-grant
manually). It resolves the MI principalId and both account scopes automatically and is
idempotent:

```pwsh
./scripts/grant-apim-mi-rbac.ps1 `
  -ResourceGroup rg-copilot-byok-<envName> `
  -ApimName <apimName> `
  -AoaiAccountName <aoaiName> `
  -FoundryAccountName <foundryName>
# bash: ./scripts/grant-apim-mi-rbac.sh <rg> <apimName> <aoaiName> <foundryName>
```

> **Constrained (ABAC) Owner caveat.** A *conditional* Owner can create these grants via the
> **direct** RBAC API (`az role assignment create`, which the script uses) but the **identical**
> assignment **fails inside the ARM nested template** — the ABAC `@Request` condition is not
> evaluated the same way in ARM role-assignment creation as in the direct API, so the template
> path defaults to deny. If you hold a constrained Owner, **set `assignAoaiRbac=false`** and let
> the script / `postprovision` hook do the grant. Re-running `azd auth login` does **not** help;
> this is an ARM-vs-RBAC-API evaluation difference, not token staleness.

Equivalent manual commands (what the script automates):

```pwsh
# $rg = your deployed RG: rg-copilot-byok-gov-pilot (Gov) or rg-copilot-byok-comm-pilot (Commercial).
$rg = "rg-copilot-byok-<envName>"
$apimMi  = az apim show -g $rg -n <apimName> --query identity.principalId -o tsv
$aoai    = az cognitiveservices account show -g $rg -n <aoaiName>    --query id -o tsv
$foundry = az cognitiveservices account show -g $rg -n <foundryName> --query id -o tsv
az role assignment create --assignee-object-id $apimMi --assignee-principal-type ServicePrincipal `
  --role "Cognitive Services OpenAI User" --scope $aoai
az role assignment create --assignee-object-id $apimMi --assignee-principal-type ServicePrincipal `
  --role "Cognitive Services OpenAI User" --scope $foundry
```

> **Do not mix manual grants with `assignAoaiRbac=true`.** A manual `az` grant gets a random
> GUID name while the Bicep module uses a deterministic `guid()` name; with both modes active
> on the same scope you can hit a `RoleAssignmentExists` collision that fails the module. Pick
> one path: in-template (`true`, unconstrained Owner/UAA) **or** out-of-band (`false` + script).

### Human playground / direct data-plane access

Both accounts run with **API keys disabled** (`disableLocalAuth=true`). Only APIM's managed
identity has a data-plane role, so the gateway path works but a person opening the Azure AI /
OpenAI **playground** (or calling the account with an SDK) hits an **expected** error:

> *Not authorized: Access to API keys is disabled and the account is missing Chat completion
> permissions. You will need the Cognitive Services OpenAI User role or higher.*

That is the keys-off design, not a fault. Grant humans access one of two ways — both end in the
`Cognitive Services OpenAI User` role on **each** account. The role grant itself is **identical
in both clouds**; only the portal you open and the example UPN/RG suffix differ:

| | **Government** (`AzureUSGovernment`) | **Commercial** (`AzureCloud`) |
|---|---|---|
| Playground portal | Azure AI Foundry / OpenAI portal at `*.azure.us` (e.g. `ai.azure.us`) | `ai.azure.com` / `oai.azure.com` |
| Example UPN suffix | `user@contoso.onmicrosoft.us` | `user@contoso.onmicrosoft.com` |
| Default RG name | `rg-copilot-byok-gov-pilot` (`envName=gov-pilot`) | `rg-copilot-byok-comm-pilot` (`envName=comm-pilot`) |
| `az login` cloud | `az cloud set --name AzureUSGovernment` first | `az cloud set --name AzureCloud` (default) |

> The RG name is `rg-copilot-byok-<envName>`, so it follows whichever parameters profile you
> deployed. Set `$rg` below to match your environment.

**Option A — IaC-managed (recommended, repeatable).** Add object IDs to the
`playgroundPrincipalIds` param and redeploy. Each principal gets the role on both the AOAI and
Foundry accounts automatically. Works even when `assignAoaiRbac=false`. Prefer a single Entra
**group** so membership changes need no redeploy:

```json
"playgroundPrincipalIds": { "value": [ "<user-or-group-objectId>" ] },
"playgroundPrincipalType": { "value": "Group" }
```

```pwsh
# Look up object IDs (use the UPN suffix for your cloud):
az ad user show --id user@contoso.onmicrosoft.us  --query id -o tsv     # Gov user (.us)
az ad user show --id user@contoso.onmicrosoft.com --query id -o tsv     # Commercial user (.com)
az ad group show --group "AI Playground Users" --query id -o tsv        # a group (cloud-agnostic)
```

**Option B — manual (one-off, no redeploy).**

```pwsh
# Set $rg to your deployed RG: rg-copilot-byok-gov-pilot (Gov) or rg-copilot-byok-comm-pilot (Commercial).
$rg = "rg-copilot-byok-<envName>"
$aoai    = az cognitiveservices account show -g $rg -n <aoaiName>    --query id -o tsv
$foundry = az cognitiveservices account show -g $rg -n <foundryName> --query id -o tsv
$who = "user@contoso.onmicrosoft.us"   # Gov: .us  |  Commercial: .com  — UPN or objectId
az role assignment create --assignee $who --role "Cognitive Services OpenAI User" --scope $aoai
az role assignment create --assignee $who --role "Cognitive Services OpenAI User" --scope $foundry
```

Use `Cognitive Services OpenAI Contributor` instead if they must also create/manage deployments.

> **VNet caveat (both clouds):** both accounts have `publicNetworkAccess=Disabled`, so the role
> is necessary but not sufficient — the playground only works from **inside the VNet** (P2S VPN
> or the test VM). A user on the public internet stays blocked even with the role.

### Idempotency, safe re-runs & recovery

Both `azd provision` and `az deployment sub create` run ARM in **incremental** mode. That means:

- **Re-running the deploy is safe and idempotent.** It updates resources in place to match the
  template and **never deletes** resources that aren't in the template. There is no "clean
  slate" wipe — converge by re-running, not by tearing down.
- **Always preview first.** `azd provision --preview` (or `az deployment sub what-if`) shows
  every change before it is applied. Treat a clean preview (core resources `Skip`, only benign
  computed-property `Modify` noise) as "nothing real will change."
- **Skip expensive or privileged pieces with the conditional flags** instead of editing the
  template. Each of these is a `bool`/list param you can flip off:
  
  | Param | Skips |
  |---|---|
  | `deployVpnGateway` | the P2S VPN gateway (slow, ~30–45 min) |
  | `deployTestVm` | the in-VNet diagnostics VM |
  | `deployMiniModel` | the cheap mini tier used by auto-routing |
  | `deployApimPrivateDns` | the APIM private DNS zone (when peering supplies it) |
  | `assignAoaiRbac` | the data-plane role grant (when an Owner grants it out-of-band) |
  | `playgroundPrincipalIds` | human playground access (empty list = none) |

**The few changes ARM cannot do in place** (these are platform/RP limits, not template faults):

| Change | Why it's not in-place | Safe way to make it |
|---|---|---|
| Model **SKU / version / name** on a Cognitive Services deployment | the deployment child resource is replaced, not patched | **Blue/green:** add the new model under a **new** deployment name, repoint the APIM exposed-model mapping to it, verify, then delete the old deployment. The account, PE, and network are untouched — no outage window. |
| Immutable account props (e.g. PE `privateDnsZoneId`) | RP rejects the update | delete just the affected child (e.g. the PE DNS zone-group) and re-run; the parent account stays put |
| `RoleAssignmentExists` collision | a hand-created assignment used a different name than Bicep's deterministic `guid()` | never hand-create assignments the template owns; if one exists, delete the manual one and let the template recreate it idempotently |
| `AccountProvisioningStateInvalid` on a full sub re-deploy | the template re-PUTs the AOAI/Foundry account while it is still settling | **transient — retry.** Once the account is `Succeeded`, deploy the affected **RG-scope module** alone (e.g. `apim-aoai-api.bicep`) rather than the whole subscription template |

Net: a customer **cannot** get into a "wonky state" from a normal re-run — incremental mode is
forgiving. The only hard-destructive operation is **Teardown** below, and the only changes that
require a replace are SKU/version/immutable edits, which the blue/green pattern stages without
downtime.

## 4. Configure the P2S VPN client

After deployment:

```pwsh
$rg = "rg-copilot-byok-<envName>"   # gov-pilot (Gov) or comm-pilot (Commercial)
$gw = az network vnet-gateway list -g $rg --query "[0].name" -o tsv
az network vnet-gateway vpn-client generate -g $rg -n $gw --processor-architecture Amd64 -o tsv
```

Download the returned URL, install the OpenVPN profile in `AzureVPN/`.

## 5. Install the Copilot CLI

The CLI is a developer-side client (laptop or the in-VNet test VM) — it is **not** part of
the Azure deployment. Install it wherever you will run `copilot`.

**Prerequisites (install in this order on the test VM):**

| Component | Version | Why | Install (Windows) |
|---|---|---|---|
| PowerShell | **7+** | the CLI wants PS **6+**, and `copilot` must run in the same shell the wrapper configures; stock Windows only ships PS 5.1 | `winget install Microsoft.PowerShell` |
| Node.js | **22+** | runtime for the `copilot` binary (required regardless of install method) | `winget install OpenJS.NodeJS.LTS` |
| Copilot CLI | **≥ 1.0.54** | the BYOK client | `winget install GitHub.Copilot` |

> **The wrapper runs on stock PowerShell 5.1.** `copilot-cli-byok.ps1` no longer hard-fails
> with `#requires -Version 7`. Under Windows PowerShell 5.1 it **warns** that PS7 is
> recommended and offers to install it (default **Yes**) — via WinGet, or, when WinGet is
> absent, via Microsoft's official MSI installer (`https://aka.ms/install-powershell.ps1`), so
> it works on stock Windows Server. It then **continues** in 5.1 — the wrapper's own steps
> (prompting, installing deps, setting the env vars, the `-Test` smoke test) all work there.
> Because env vars propagate **parent → child only**, the wrapper does everything in the
> current 5.1 process and then, if PS7 is available, **drops you into an interactive PS7 shell
> as its last step**. That child `pwsh` inherits the `COPILOT_PROVIDER_*` env vars (and the
> PATH entry for the npm-global `copilot`), so you land in a supported shell already configured
> — just type `copilot` to start, `exit` to return.

> **Interactive & remembered.** If you omit `-ApimBaseUrl` or `-Model`, the wrapper prompts
> for them and **persists the (non-secret) answers** to `%USERPROFILE%\.copilot-byok\config.json`,
> so next time just press Enter to accept the saved values. `-Model` defaults to **`auto`** (let
> the gateway route between the full and mini tiers). In subscription-key mode, if neither
> `-SubscriptionKey` nor `$env:APIM_SUBSCRIPTION_KEY` is set, the wrapper prompts for the key
> with **masked input** — the key (or JWT) is held only in the session and **never written to
> disk**.

> **Bake in your own defaults (optional).** Prefer a turn-key script? You can hardcode
> `$ApimBaseUrl` (and even `$SubscriptionKey`) directly in the `param()` block of
> `copilot-cli-byok.ps1` — a value set there wins over the saved config and the prompt. They
> default to empty so the normal prompt/remember flow is unaffected when you leave them alone.
> A baked-in key sits in the file as plaintext, so prefer `$env:APIM_SUBSCRIPTION_KEY` for
> secrets.

> **npm is optional.** `winget install GitHub.Copilot` pulls a self-contained build, so you
> do **not** need npm — just PowerShell 7 and Node 22. Use the npm path only if you prefer it
> (npm ships with Node 22+).

> **WinGet may be missing on Windows Server.** The App Installer (which provides `winget`) is
> not present on a stock Windows Server image. Install it first:
> - Microsoft Store → search **App Installer**, or
> - download the bundle from <https://aka.ms/getwinget> and run
>   `Add-AppxPackage -Path .\Microsoft.DesktopAppInstaller_*.msixbundle`
>
> On air-gapped hosts where the Store is blocked, use the msixbundle. Alternatively, skip
> WinGet entirely: install Node.js 22+ from the MSI (<https://nodejs.org>) and then
> `npm install -g @github/copilot@latest`.

```pwsh
# Windows (WinGet) — no npm required:
winget install Microsoft.PowerShell      # PowerShell 7+ (to run the wrapper)
winget install OpenJS.NodeJS.LTS         # Node.js 22+ (CLI runtime)
winget install GitHub.Copilot            # the Copilot CLI

# OR all platforms (npm — needs Node 22+ already installed), pin a recent build:
npm install -g @github/copilot@latest

# Verify (expect 1.0.54 or higher; latest is 1.0.56):
copilot --version
```

> **Shortcut.** The wrapper can install the CLI for you: run
> `./copilot-cli-byok.ps1 ... -InstallDeps` and it will install Node 22+ and the Copilot CLI if
> they are missing. With WinGet it uses `OpenJS.NodeJS.LTS` + `GitHub.Copilot`; **when WinGet is
> absent** (stock Windows Server) it falls back to the official **Node.js MSI** from nodejs.org
> and then `npm install -g @github/copilot@latest` — no Store, no WinGet required. Without
> `-InstallDeps` it prompts interactively (or just prints the commands and stops when
> non-interactive).

> **Version floor.** Any build **≥ 1.0.20** speaks the OpenAI-style versionless `/v1`
> route this gateway expects, but pin a recent release (**≥ 1.0.54**) to pick up BYOK and
> auto-routing fixes. On the in-VNet test VM, install Node 22+ first (e.g.
> `winget install OpenJS.NodeJS.LTS`) since it ships without it.

> **GitHub sign-in still required.** Even in BYOK mode the CLI runs `/login` once to verify
> your GitHub Copilot entitlement; only the **model traffic** is redirected to the private
> gateway via `COPILOT_PROVIDER_*`. In a fully air-gapped VNet, sign in before locking down
> egress, or use a `COPILOT_GITHUB_TOKEN` PAT with the *Copilot Requests* permission.

## 6. First developer test

`COPILOT_PROVIDER_BASE_URL` must point at the gateway's `/openai` route — the wrapper
**appends `/openai` automatically** if you leave it off, so `-ApimBaseUrl
'https://apim-...azure-api.us'` and `...azure-api.us/openai` are equivalent. The wrapper
defaults to
**`authMode=subscriptionKey`** — the developer presents their per-developer **APIM
subscription key** (set it once in `$env:APIM_SUBSCRIPTION_KEY` to avoid putting the
secret on the command line). Use `-AuthMode jwt -AppId <clientId-guid>` only if the
gateway was deployed with `authMode=jwt`; the `-AppId` is the app **client-ID GUID**
(v2-token audience), not the `api://` URI.

> Get a developer's subscription key from APIM → **Subscriptions** (or the portal
> "Show/Hide keys" action) for the subscription assigned to that developer.

> **The `auto` model and token limits.** The CLI sizes its context window from a built-in model
> catalog. A gateway-routed name like **`auto`** isn't in that catalog, so the CLI prints an
> informational *"Model 'auto' is not in the built-in catalog"* warning and would otherwise fall
> back to tiny token defaults. The wrapper handles this by exporting
> `COPILOT_PROVIDER_MAX_PROMPT_TOKENS` / `COPILOT_PROVIDER_MAX_OUTPUT_TOKENS` for any non-catalog
> model. The defaults are the **smaller** limit of each model the `auto` router can pick, so a
> request can't overflow whichever tier it lands on: **272000** prompt (gpt-5.1's input cap) and
> **32768** output (gpt-4.1-mini's output cap). Override either with `-MaxPromptTokens` /
> `-MaxOutputTokens`. A named catalog model (e.g. `gpt-5.1`) leaves these unset and uses the
> CLI's own values. The warning itself is harmless.

> **Ready-made test keys.** When `deployTestSubscriptions=true` (the default in
> subscription-key mode) the deployment provisions all-APIs APIM subscriptions named
> `dev1` and `dev2` so you can verify the gateway immediately. The deployment output
> `testSubscriptionIds` lists them. Fetch a key with:
>
> ```pwsh
> $rg   = 'rg-copilot-byok-<envName>'   # gov-pilot (Gov) or comm-pilot (Commercial)
> $apim = az deployment sub create ... # or: az apim list -g $rg --query "[0].name" -o tsv
> az apim subscription show -g $rg --service-name $apim --sid dev1 `
>   --query primaryKey -o tsv   # secondaryKey is the backup
> ```
>
> Each `dev1`/`dev2` key is valid for **both** `/openai` (Foundry) and `/aoai` (AOAI),
> and shows up as that name in telemetry (`developer_upn`). Treat them as shared pilot
> test credentials; provision per-person subscriptions for real developers.

### Option A — in-VNet test VM via Bastion (no VPN required)

When `deployTestVm=true`, connect to the VM through the portal (**Connect → Bastion**),
then on the VM:

> **APIM host suffix differs by cloud.** The examples below use a Gov host
> (`...azure-api.us`); on **Commercial** the gateway is `...azure-api.net`. Use whichever
> matches your deployment (the `deployment outputs` / `azd env get-values` report the real
> FQDN). The `/openai` suffix is appended automatically if you omit it.

```pwsh
# Default (subscription key) — no Azure CLI / az login needed for this mode:
$env:APIM_SUBSCRIPTION_KEY = '<your per-developer key>'
./scripts/copilot-cli-byok.ps1 -ApimBaseUrl 'https://apim-...azure-api.us/openai' `
                               -Model gpt-5.1 `
                               -Test

# Opt-in (jwt) — requires Azure CLI + login so a token can be minted:
#   Invoke-WebRequest https://aka.ms/installazurecliwindows -OutFile $env:TEMP\azcli.msi
#   Start-Process msiexec.exe -Wait -ArgumentList "/i `"$env:TEMP\azcli.msi`" /quiet"
#   az cloud set --name AzureUSGovernment; az login --use-device-code   # Gov (Commercial: az cloud set --name AzureCloud; az login)
#   ./scripts/copilot-cli-byok.ps1 -AuthMode jwt -AppId <clientId-guid> `
#                                  -ApimBaseUrl 'https://apim-...azure-api.us/openai' -Model gpt-5.1 -Test
```

Expect `http=200` with a completion. (Add `-ApimPrivateIp 10.60.1.4` as a fallback if
DNS hasn't propagated — it makes curl use `--resolve`.)

### Option B — developer laptop over P2S VPN

```pwsh
# On the laptop, after connecting P2S VPN (step 4) — default subscription-key mode:
$env:APIM_SUBSCRIPTION_KEY = '<your per-developer key>'
./scripts/copilot-cli-byok.ps1 -ApimBaseUrl 'https://apim-...azure-api.us/openai' `
                               -Model gpt-5.1
copilot "say hello in exactly five words"
```

Expected: a five-word response. The APIM log + App Insights show the request with the
developer dimension (`developer_oid`/`developer_upn` = the APIM subscription Id/Name in
subscription-key mode, or the Entra `oid`/`upn` in jwt mode).

> **Linux / macOS developers.** Use the bash twin `scripts/copilot-cli-byok.sh` — `source` it so
> the exported env vars stay in your shell. It mirrors the same provider contract: the `/openai`
> suffix is appended if omitted, `[model]` defaults to **`auto`**, and for a non-catalog model it
> exports the same token limits (`COPILOT_PROVIDER_MAX_PROMPT_TOKENS=272000` /
> `COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=32768`, overridable via the `MAX_PROMPT_TOKENS` /
> `MAX_OUTPUT_TOKENS` env vars). It does **not** auto-install prerequisites (install Node 22+ and
> `npm install -g @github/copilot@latest` yourself) — that bootstrap is Windows-only.
>
> ```bash
> # Configure the shell (default subscription-key mode), then run copilot:
> APIM_SUBSCRIPTION_KEY='<your per-developer key>' \
>   source ./scripts/copilot-cli-byok.sh 'https://apim-...azure-api.us/openai'   # model defaults to auto
> copilot "say hello in exactly five words"
>
> # One-shot smoke test (no shell change):
> TEST=1 APIM_SUBSCRIPTION_KEY='<key>' [APIM_PRIVATE_IP=10.60.1.4] \
>   ./scripts/copilot-cli-byok.sh 'https://apim-...azure-api.us/openai' gpt-5.1
> ```

## 7. Observability check

```pwsh
# Gov caveat: the App Insights query REST API is disabled in this tenant
# (az monitor app-insights query => AADSTS500014). Use the portal Logs blade / workbook.
# Portal -> App Insights -> Logs, then run:
#   customMetrics | where name == 'copilot_byok_request' | take 10
```

You should see rows with `developer_oid`, `developer_upn`, `deployment_name` (and
`backend` on the default Foundry API).

## 8. Tune rate limits & content filtering (optional)

**Rate-limit tiers (subscriptionKey mode).** Developers are grouped via APIM **products**. The
defaults ship two tiers — `byok-standard` and `byok-power` — and `dev1`/`dev2` are assigned to
them. To change a tier's numbers, edit `productTiers` in your parameters file and redeploy:

```jsonc
"productTiers": { "value": [
  { "name": "byok-standard", "displayName": "BYOK Standard", "description": "Standard tier.",
    "callsPerMinute": 60,  "tokensPerMinute": 20000, "monthlyCallQuota": 50000 },
  { "name": "byok-power",    "displayName": "BYOK Power",    "description": "Power tier.",
    "callsPerMinute": 120, "tokensPerMinute": 60000, "monthlyCallQuota": 200000 }
] }
```

Move a developer between tiers by changing the `product` on their entry in `testSubscriptions`
(e.g. `{ "name": "dev1", "product": "byok-power" }`) and redeploying. The `productTiers` numbers
apply **only in subscriptionKey mode** — that is where rate limiting lives (at product scope).
For **jwt mode** there are no products, so the single flat per-developer tier is set instead by
`jwtDefaultCallsPerMinute` / `jwtDefaultTokensPerMinute` / `jwtDefaultMonthlyCallQuota` (these
feed the `jwt-*` named values the jwt policies read). Only the set matching your `authMode` has
any effect; the other is inert. Responses carry `x-byok-calls-remaining`,
`x-byok-tokens-remaining`, and `x-byok-tokens-consumed` headers. See the architecture doc's
"Where rate limiting sits between the two auth modes" for the full comparison.

**Content filtering.** Both the AOAI and Foundry deployments **always** run a content filter —
there is no "off." Out of the box both use Microsoft's built-in default (`Microsoft.DefaultV2`),
so you already have responsible-AI filtering with nothing to configure. Customizing is opt-in via
the single shared `raiPolicyName` parameter. To view or customize:

```pwsh
# Show current filters and per-deployment assignments
./scripts/configure-content-filter.ps1 -ResourceGroup <rg> -AccountName <aoai-or-foundry-account> -Show

# Apply a tightened custom filter and attach it to a deployment
./scripts/configure-content-filter.ps1 -ResourceGroup <rg> -AccountName <account> `
  -Apply -PolicyName byok-strict -ConfigPath ./scripts/content-filter.sample.json `
  -AttachToDeployment gpt-5.1
```

```bash
./scripts/configure-content-filter.sh --resource-group <rg> --account-name <account> --show
```

To persist a custom filter in IaC, set `raiPolicyName` to the policy name in your parameters
file and redeploy — this repoints **both** the AOAI and Foundry deployments to that policy (it's
one shared knob), so the named policy must already exist on each account first (create it with
`-Apply`). **Tightening is always allowed; loosening below Microsoft defaults needs an approved
modified-content-filter application** (the platform rejects an unapproved loosened policy).

## Teardown

```pwsh
# RG is rg-copilot-byok-<envName>: gov-pilot (Gov) or comm-pilot (Commercial).
az group delete -n rg-copilot-byok-<envName> --yes --no-wait
./scripts/setup-entra.ps1 -DisplayName "copilot-byok-gateway" -Remove
```
