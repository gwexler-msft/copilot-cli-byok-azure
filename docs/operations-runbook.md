# Operations runbook — Gov/Commercial BYOK Copilot gateway

> **Audience:** the infra / operations / on-call team running a **deployed** BYOK gateway in
> production. This is task- and symptom-indexed for use *during* an incident or a routine
> change — not a design doc. For *why* the system is built this way, see
> [architecture.md](architecture.md); for *reusing* it on a new engagement, see
> [lessons-learned.md](lessons-learned.md); for the *first* deploy, see
> [deployment-guide.md](deployment-guide.md).

## Conventions used below

Set these once per shell; every recipe assumes them.

```pwsh
# Pick the env you operate. RG name is rg-copilot-byok-<envName>.
$env  = "gov-pilot"                       # or comm-pilot / gov / commercial
$rg   = "rg-copilot-byok-$env"
$apim = az apim list -g $rg --query "[0].name" -o tsv
$appi = az resource list -g $rg --resource-type microsoft.insights/components --query "[0].name" -o tsv
```

> **Gov cloud first.** Run `az cloud set --name AzureUSGovernment; az login` before anything
> for a Gov env. Commercial uses `AzureCloud` (the default).

---

## 1. Incident playbook — index by symptom

Start here when "it's broken." Each row: most-likely cause → first diagnostic → fix section.

| Symptom (what the developer sees) | Most likely cause | First check | Fix |
|---|---|---|---|
| **401** `Access token is missing, invalid…` | Wrong auth mode, expired JWT, or revoked key | Is the env `jwt` or `subscriptionKey`? Is the key/token current? | §2 (onboard/keys), §6 (auth-mode) |
| **`missing subscription key`** from a Bearer-only IDE (JetBrains AI Assistant) | Client sends the key as `Authorization: Bearer`; Internal APIM only reads `api-key` | Is the subkey proxy deployed + reachable in-VNet? | §10 (subkey proxy) |
| **403** `RBAC: access denied` / from backend | APIM MI missing role on a backend account | §5 MI-RBAC check | §5 |
| **404** `model … not found` / `Resource not found` | `api-version` too old, missing `COPILOT_PROVIDER_AZURE_API_VERSION`, or wrong model name | §4 api-version | §4 |
| **429** on first/normal request | TPM tier too low for Copilot-sized requests | §3 throttle check | §3 (raise tier) |
| **429** sustained | Developer over burst/quota — or a runaway agent | [throttle-hits KQL](../monitoring/kql/throttle-hits-per-developer.kql) | §3 |
| **400** `unsupported_value` / `max_tokens` | Reasoning-model param not stripped (policy drift) | Confirm policy matches repo | redeploy policy (§7) |
| **5xx / timeouts**, intermittent | Backend capacity (PTU 429→5xx), breaker open | [requests-per-backend-region KQL](../monitoring/kql/requests-per-backend-region.kql) | §5 backend/pool |
| **All devs down**, DNS fails | Private DNS / PE / VPN | §5 connectivity | §5 |
| **Dashboards empty**, calls succeed | Diagnostic lost `metrics:true` or destination not `Dedicated` | §8 telemetry health | §8 |
| **Streaming token metrics missing** (newer models, Gov) | Known platform limit — not an incident | — | §9 (no action) |

---

## 2. Routine task — onboard / offboard a developer

> **Self-serve alternative.** If this env was deployed with the register app
> (`deployRegisterApp=true`), developers onboard themselves — see the
> [register app runbook](register-app-runbook.md). The manual control-plane recipes below are
> the operator/break-glass path and apply to every env regardless.

**Auth mode decides the mechanism.** Check it first:

```pwsh
# subscriptionKey mode has products/subscriptions; jwt mode has neither.
az apim product list -g $rg --service-name $apim --query "[].name" -o tsv
```

### `subscriptionKey` mode (recommended for fleets)

A developer = an **APIM subscription** scoped to a **product tier** (`byok-standard` /
`byok-power`). The subscription Name is what shows up in telemetry as the developer.

```pwsh
# Onboard: create a subscription on a tier (idempotent name = the developer id).
az apim subscription create -g $rg --service-name $apim `
  --sid jdoe --display-name "jdoe (BYOK byok-standard)" `
  --scope "/products/byok-standard" --state active

# Hand them their key (primary; add secondaryKey for the backup):
az apim subscription show -g $rg --service-name $apim --sid jdoe --query primaryKey -o tsv

# Move tiers (e.g. standard -> power): re-scope, no key change.
az apim subscription update -g $rg --service-name $apim --sid jdoe `
  --scope "/products/byok-power"

# Offboard / revoke instantly:
az apim subscription update -g $rg --service-name $apim --sid jdoe --state suspended
# or hard-delete:
az apim subscription delete  -g $rg --service-name $apim --sid jdoe --yes
```

> The seeded `dev1`/`dev2` subscriptions come from
> [infra/modules/apim-subscriptions.bicep](../infra/modules/apim-subscriptions.bicep). For a
> durable fleet, add real entries there and redeploy so onboarding is in IaC, not ad-hoc.

> **Workstation hardening (fully-private fleets):** when handing a developer their key, also
> have them turn off VS Code editor telemetry / call-home chatter (`telemetry.telemetryLevel:
> "off"`, `update.mode: "none"`, autoUpdate off, Settings Sync off, no Copilot sign-in). The
> canonical `settings.json` block and rationale live in
> [deployment-guide.md → Lock down VS Code editor "chatter"](deployment-guide.md#lock-down-vs-code-editor-chatter-fully-private--no-call-home-posture);
> enforce it at the network layer per [github-egress-allowlist.md](github-egress-allowlist.md).

### `jwt` mode (per-user Entra identity)

There is **no key to issue**. Access = membership/app-role on the Entra app
`copilot-byok-gateway` + the `cli.invoke` scope.

```pwsh
# Onboard: ensure the user can get a token for the API (app-role / pre-authorized).
#   Managed centrally in Entra; see scripts/setup-entra.ps1 for the registration.
# Offboard: remove the user's app-role assignment (instant revoke):
#   Entra portal -> Enterprise apps -> copilot-byok-gateway -> Users and groups -> remove.
```

> Remember the **~1h token expiry**: jwt-mode users need the wrapper script to re-mint
> ([feature-request-byok-credential-refresh.md](feature-request-byok-credential-refresh.md)).

---

## 3. Rotate a key / revoke a compromised credential

```pwsh
# subscriptionKey: rotate ONE developer's key (regenerates primary; secondary unaffected).
az apim subscription regenerate-key -g $rg --service-name $apim --sid jdoe --key-kind primary
# Tell the dev to switch to the new key; once confirmed, rotate secondary too.

# Suspect a key is leaked but unsure which: suspend, rotate, re-hand-out.
az apim subscription update -g $rg --service-name $apim --sid jdoe --state suspended
```

> **No backend key to rotate.** The backend uses **managed identity**, not keys
> (`disableLocalAuth=true`) — there is intentionally nothing to rotate there. If a previous
> operator re-enabled local auth + a key, that is config drift; close it (§5 / lessons §2).
>
> **CI/runner secrets:** the GitHub runner credential (a **GitHub App key** in the primary path, or
> a **PAT** in the opt-in fallback) rotates via the Key-Vault-backed flow in
> [§3a](#github-runner-pat-rotation-key-vault-backed) below; other CI tokens (e.g.
> `PROJECT_TOKEN`) rotate via [cicd.md](cicd.md#L304).

<a id="github-runner-pat-rotation-key-vault-backed"></a>
### GitHub runner credential rotation (Key Vault-backed)

The self-hosted runner pool (opt-in `deployGhRunner=true`) authenticates to GitHub one of two ways,
selected by **`ghRunnerAuthMode`**:

- **`app` (GitHub App — PRIMARY / recommended).** A GitHub App authenticates with a private key and
  mints **short-lived installation tokens** on the fly, so there is **no long-lived credential to
  rotate** — you only ever roll the key if it leaks. Higher API budget too (15k/hr vs 5k). Stored as
  the runner Job secret **`gh-app-key`** (the PEM private key); the App ID + Installation ID are
  NON-secret ids passed as plain params.
- **`pat` (Personal Access Token — supported opt-in fallback).** For customers who can't or won't
  install a GitHub App. PATs **expire and must be rotated** on a schedule. Stored as the Job secret
  **`gh-pat`**.

Either way, with `ghRunnerSecretFromKeyVault=true` the secret is a **managed-identity Key Vault
reference** (resolved by the runner UAMI), so a roll/rotation is a **single Key Vault write** — no
Job re-create, no re-provision, identical in both Azure clouds (the vault URI is cloud-correct).
Both consumers — KEDA queue polling and the runner container's registration — read the same Job
secret.

> **Scope: pilots only.** `ghRunnerSecretFromKeyVault=true` is set on the **pilot** param files
> (`comm-pilot`/`gov-pilot`, both manual + CI). The **dev** envs (`comm-dev`/`gov-dev`) keep the
> inline secret (KV off) on purpose: their RGs are torn down nightly by
> [teardown-dev.yml](../.github/workflows/teardown-dev.yml), so a per-env vault would be destroyed
> every night (re-bootstrap + Key Vault soft-delete name collisions). The inline secret is
> auto-reinjected on each unattended dev reprovision, so dev needs no manual step.

> **Module default is `app`; this repo's live param files use `pat` (EMU constraint).** `app` is the
> module default and the recommended path for **org-hosted** deployments. However, this repo is
> **user-owned under an Enterprise Managed Users (EMU) account**, where a user-owned GitHub App can
> only be installed on **"This Enterprise"** — an enterprise-scoped install does **not** grant the
> repo-level **Administration** permission KEDA needs to register runners — so **app mode is not
> viable here** and all pilot + dev param files set `"ghRunnerAuthMode": { "value": "pat" }`. To
> re-enable `app` on a future org-hosted env, set it back to `app` and satisfy the **one-time
> prerequisite**: the GitHub App must exist and its credentials must be in place (repo
> Variables/Secret for dev; runner Key Vaults for pilots) **before** the next `azd provision`, or the
> runner falls back to the Phase-1 placeholder. Run the one-time setup below.

#### GitHub App setup (one-time) + cutover from PAT

> **Fast path:** [setup-gh-app.ps1](../scripts/setup-gh-app.ps1) automates steps 1–3 (and, with
> `-SetRepoVars`, the dev repo Variables/Secret) via GitHub's App-manifest flow:
> `./scripts/setup-gh-app.ps1 -SetRepoVars`. It opens a browser to create + install the App,
> downloads the PEM, auto-discovers the Installation ID, and prints the pilot Key Vault commands.
> (The App is a **GitHub** identity — **not** an Entra ID app registration; the only Entra identity
> in the runner stack is the runner UAMI, which Bicep already manages.) Manual steps if you prefer:

1. **Create the App** (org owner): GitHub → Settings → Developer settings → **GitHub Apps** → New.
   - Repository permissions: **Actions: Read**, **Administration: Read & write**,
     **Metadata: Read**. (Org-level runners instead: **Self-hosted runners: Read & write** +
     Actions Read + Metadata Read.)
   - **Uncheck Webhook → Active** (the runner doesn't use webhooks).
2. **Install** it on `gwexler_microsoft/copilot-cli-byok-azure`. Capture the **App ID** (App
   settings page) and **Installation ID** (`gh api /repos/<owner>/<repo>/installation --jq .id`, or
   the `.../installations/<id>` settings URL).
3. **Generate a private key** (App settings → Private keys → Generate private key) → downloads a
   `.pem`. Treat it like any secret; never commit it.
4. **Place the credentials:**
   - **Pilots (KV path)** — write the PEM to each pilot runner vault (per cloud session):
     ```pwsh
     az cloud set --name AzureCloud; az login   # AzureUSGovernment for gov-pilot
     ./scripts/setup-gh-runner.ps1 -Action SetSecret -Secret AppKey -AppKeyPath .\gh-app.pem -EnvNames comm-pilot
     # raw-az equivalent:
     az keyvault secret set --vault-name <ghRunnerKeyVaultName> --name gh-app-key --value "$(Get-Content -Raw .\gh-app.pem)" -o none
     ```
   - **Dev (inline path)** — add repo **Variables** `GH_APP_ID` + `GH_APP_INSTALLATION_ID` and a
     repo **Secret** `GH_APP_PRIVATE_KEY`, and have the dev workflows export them so azd
     substitutes `ghAppId` / `ghAppInstallationId` / `ghAppPrivateKey` (mirrors today's
     `GH_RUNNER_PAT` wiring).
5. **Param files are already `"ghRunnerAuthMode": { "value": "app" }`.** Confirm `ghAppId` +
   `ghAppInstallationId` resolve (pilots: literals, or `${GH_APP_ID}` / `${GH_APP_INSTALLATION_ID}`
   from CI vars), then `azd provision`. Bicep re-renders the Job with the KEDA `appKey` auth +
   `APP_ID` / `APP_PRIVATE_KEY` / `APP_LOGIN` container env.
6. Verify the pool scales on a queued job, then **revoke the old PAT**.

> **Rolling the App key** (only if it leaks): generate a new private key on the App, run the same
> `setup-gh-runner.ps1 -Action SetSecret -Secret AppKey ...`, then delete the old key in GitHub. No
> re-provision — KEDA picks up the new PEM on the next poll.

#### PAT rotation (opt-in fallback, `ghRunnerAuthMode='pat'`)

> **One-command weekly rotation.** Under EMU the PAT lifetime is capped (commonly **7 days**), so
> this is a recurring chore across **three** targets from one fresh PAT: the GitHub Actions repo
> secret `GH_RUNNER_PAT` (the durable source the **dev** envs inject on each reprovision) plus the
> **comm-pilot** and **gov-pilot** runner Key Vaults. [rotate-runner-pat.ps1](../scripts/rotate-runner-pat.ps1)
> does all of it: it sets the repo secret, then delegates the per-env Key Vault writes to
> `setup-gh-runner.ps1`, processing whichever envs match the active `az` cloud and printing a
> copy-paste second pass for the other cloud. Regenerate the PAT in the browser first (GitHub has no
> API to mint one), then:
>
> ```pwsh
> # Commercial-cloud session (prompts securely for the PAT):
> ./scripts/rotate-runner-pat.ps1
> # Then the gov pass it prints:
> az cloud set --name AzureUSGovernment; az login
> ./scripts/rotate-runner-pat.ps1 -Envs gov-pilot -SkipRepoSecret
> ```
>
> The manual per-target commands below remain valid for one-off or single-env rotations.

> **Network-locked runner Key Vaults (the pilots) — use the break-glass script.** Both pilot runner
> vaults run `publicNetworkAccess=Disabled` + a Private Endpoint, so the `az keyvault secret set` /
> `setup-gh-runner.ps1` / `rotate-runner-pat.ps1` paths below **403 (`ForbiddenByConnection`)** from a
> workstation. [rotate-runner-pat-breakglass.ps1](../scripts/rotate-runner-pat-breakglass.ps1) is the
> tool for these: it briefly OPENS the vault (`publicNetworkAccess=Enabled` + `defaultAction=Allow`,
> still RBAC-gated), WRITES `gh-pat`, **RE-LOCKS** it in a `finally` (always, even on Ctrl-C), then
> **forces the runner Container Apps Job to RE-RESOLVE** the secret. That last step is essential:
> Azure Container Apps caches KV secret references at the **Job** level, so a rotated PAT otherwise
> does not reach the runner until ACA's periodic refresh (observed **up to hours**) — the runner keeps
> failing registration with **HTTP 401** on the stale token in the meantime. Regenerate the PAT in the
> browser first, then run once per cloud:
>
> ```pwsh
> $env:GH_RUNNER_PAT = '<new-pat>'   # or omit and let the script prompt (hidden input)
> ./scripts/rotate-runner-pat-breakglass.ps1 -Env gov-pilot
> # Commercial pass (separate cloud + login):
> az cloud set --name AzureCloud; az login
> ./scripts/rotate-runner-pat-breakglass.ps1 -Env comm-pilot
> ```
>
> Also refresh the **repo secret** (the source the dev envs inject on reprovision), via stdin so the
> token never lands on a command line:
> `$env:GH_RUNNER_PAT | gh secret set GH_RUNNER_PAT --repo <owner/repo>`.

```pwsh
# 0. Be in the env's cloud (comm-* = Commercial, gov-* = Government — different logins).
az cloud set --name AzureCloud   # or AzureUSGovernment for gov-* envs
az login                         # if you just PIM-activated a role, re-login to refresh the token

# 1. Mint a NEW PAT on this repo (fine-grained: Administration RW + Actions Read + Metadata Read,
#    or classic `repo`). Rotate — the helper auto-discovers the subscription, detects the KV
#    reference, and writes to the vault (prompts for the PAT with hidden input):
./scripts/setup-gh-runner.ps1 -Action SetSecret -EnvNames comm-pilot

# Raw-az equivalent (vault name = the deployment output ghRunnerKeyVaultName):
az keyvault secret set --vault-name <ghRunnerKeyVaultName> --name gh-pat --value <new-pat> -o none
```

The next queued workflow job makes KEDA spin a fresh runner that reads the new credential — nothing
else to touch.

**First-time bring-up is two-phase** (a Container Apps Job can't reference a KV secret that does
not exist yet):

1. `azd provision` with `deployGhRunner=true` **and `ghRunnerSecretFromKeyVault=false`** → creates the
   empty runner Key Vault + a Phase-1 placeholder Job (Manual trigger, no secret).
2. Write the credential once (`-Secret AppKey` for app mode, or the PAT command above). RBAC: the
   deploying principal is granted **Key Vault Secrets Officer** by
   [runner-kv.bicep](../infra/modules/runner-kv.bicep); in CI the workflow self-grants.
3. `azd provision` again with **`ghRunnerSecretFromKeyVault=true`** → flips the Job to the KEDA Event
   trigger with the KV reference.
4. Every later rotation/roll = step 2 only.

> **Wrong cloud / subscription is the #1 gotcha.** comm-* and gov-* are different clouds (separate
> `az login`s). `setup-gh-runner.ps1` guards against a cloud mismatch and auto-discovers the
> subscription within the current cloud, but it cannot cross clouds. A freshly PIM-activated role
> needs a real re-login (`az login`) or writes 403 on the stale cached token.

---

## 4. Adjust rate / token / quota limits (no full redeploy)

**Where the limits live depends on auth mode** — this trips people up.

- **`subscriptionKey` mode:** limits are baked into each **product policy**
  ([apim-products.bicep](../infra/modules/apim-products.bicep)). Defaults: `byok-standard`
  60 calls/min · 20k TPM · 50k/mo; `byok-power` 120 · 60k · 200k. Change a tier by editing
  `productTiers` and redeploying (the values are inlined into the product policy XML).
- **`jwt` mode:** limits are **named values** the policy reads, so you can bump them live:

```pwsh
# Raise the jwt-mode TPM cost guard from 60k to 120k without a redeploy.
az apim nv update -g $rg --service-name $apim --named-value-id jwt-tokens-per-minute --value 120000
# Other tunables: jwt-calls-per-minute, jwt-monthly-call-quota.
```

> **"First request 429s"** is almost always the TPM guard set too low for Copilot-sized
> requests (5–15k tokens each). Raise the tier/named-value TPM, not the call limit. See
> lessons §4.

### Fix `api-version` 404s (newer models)

```pwsh
# gpt-4.1 / gpt-5.1 need 2025-04-01-preview or later. Bump the named value live:
az apim nv update -g $rg --service-name $apim --named-value-id aoai-default-api-version `
  --value 2025-04-01-preview
```

Also confirm clients still set `COPILOT_PROVIDER_AZURE_API_VERSION` (dropping it removes the
query param → 404). For the Gov Responses/`api-version` interplay, see
[architecture.md → Responses route](architecture.md#responses-route-openaiv1responses).

---

## 5. Backend, identity & connectivity health

### MI-RBAC (cause of backend 403s)

```pwsh
$apimMi = az apim show -g $rg -n $apim --query identity.principalId -o tsv
# Every backend account must grant the MI 'Cognitive Services OpenAI User'.
foreach ($acct in (az cognitiveservices account list -g $rg --query "[].name" -o tsv)) {
  $scope = az cognitiveservices account show -g $rg -n $acct --query id -o tsv
  az role assignment list --assignee $apimMi --scope $scope `
    --query "[?roleDefinitionName=='Cognitive Services OpenAI User'].roleDefinitionName" -o tsv
}
# Missing on any account = silent 401/403 from that member. Grant with:
#   ./scripts/grant-apim-mi-rbac.ps1 -ResourceGroup $rg -ApimName $apim ...
```

### Pool / breaker / region distribution

```pwsh
# Which backend/region is serving (and whether a breaker tripped):
az apim api list -g $rg --service-name $apim --query "[].name" -o tsv
# Run requests-per-backend-region.kql in the portal Logs blade to see live distribution.
```

### Connectivity (all-devs-down, DNS fails)

```pwsh
# From an on-VNet host: APIM private FQDN must resolve to 10.60.x.x.
Resolve-DnsName "$apim.azure-api.us"     # .azure-api.net for Commercial
# Off-VNet failure => VPN not connected or the private-link DNS zone not pushed.
# Backend PE: privatelink.openai.azure.us (Gov) / .com (Commercial) must resolve to the PE IP.
```

---

## 6. Switch / verify auth mode

```pwsh
# What mode is live? (products exist => subscriptionKey; absent => jwt)
az apim product list -g $rg --service-name $apim --query "[].name" -o tsv
```

Switching modes is a **redeploy** (`authMode=subscriptionKey|jwt` param), not a live toggle —
the API policies differ. Do it in a maintenance window; existing keys/tokens stop working at
the cutover. See [deployment-guide.md](deployment-guide.md) Option A/B/C.

---

## 7. Redeploy / roll back a policy or the stack

```pwsh
# Policy-only or full: deploy at RESOURCE-GROUP scope (sub-scope re-run is flaky — lessons §7).
az deployment group create -g $rg --template-file infra/main.bicep `
  --parameters infra/main.parameters.$env.json

# Patch just the diagnostic to Dedicated without a full deploy:
./scripts/apply-diag-dedicated.ps1 -ResourceGroup $rg -ApimName $apim
```

> **Roll back** = redeploy the previous git revision of `infra/` + `policies/`. The policy is
> authored from the repo, so `git checkout <good-sha> -- policies/ infra/ && az deployment
> group create …` reverts it. There is no in-portal "undo" you should rely on — the repo is the
> source of truth.

---

## 8. Telemetry health — "dashboards empty but calls succeed"

```pwsh
# 1. Smoke a request, then check custom metrics flowed (portal Logs blade — Gov query API is
#    disabled, AADSTS500014, so DON'T use `az monitor app-insights query`):
#      customMetrics | where name startswith 'copilot_byok_' | where timestamp > ago(15m)
# 2. If AppRequests populate but customMetrics is empty => the apim diagnostic lost metrics:true
#    (issue #16). Verify:
az rest --method get --url "$(az cloud show --query endpoints.resourceManager -o tsv)subscriptions/$(az account show --query id -o tsv)/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$apim/diagnostics/applicationinsights?api-version=2024-05-01" --query "properties.metrics"
#    Expect: true. If false/empty, redeploy (apim.bicep sets it).
# 3. If KQL returns 0 rows everywhere => diagnostic destination not 'Dedicated':
az monitor diagnostic-settings show --resource $(az apim show -g $rg -n $apim --query id -o tsv) `
  --name to-log-analytics --query logAnalyticsDestinationType -o tsv   # expect: Dedicated
#    Fix: ./scripts/apply-diag-dedicated.ps1 -ResourceGroup $rg -ApimName $apim
```

Run the bundled [smoke-test.ps1](../scripts/smoke-test.ps1) for an end-to-end PASS/FAIL across
discovery, chat (both tiers), the emit-metric net, and the token-limit path.

---

## 9. Known platform limits — do NOT chase these as incidents

These look like bugs but are Microsoft Gov-platform parity gaps. Document, don't debug.

- **Per-call token metrics absent for *streaming* traffic on newer models (Gov).** Depends on
  two independent Microsoft timelines (Gov backend api-version parity **and** APIM parsing the
  Responses streaming usage event). Request counts + throttles are unaffected. See
  [architecture.md → two-clocks note](architecture.md#responses-route-openaiv1responses).
- **App Insights query REST API disabled in Gov** (`AADSTS500014`). Use the portal Logs blade.
- **Live Metrics blade always empty; APIM Analytics blade sparse.** Working as designed — use
  the Logs blade / `ApiManagementGatewayLogs` table.

Escalate to Microsoft only with a repro that isolates the platform (e.g. a vanilla call), and
reference the specific behavior above so it isn't mistaken for a config error.

---

## 10. Subkey proxy for Bearer-only IDE clients

> **What it is.** An opt-in, in-VNet **nginx Azure Container Instance** (in `snet-aci`) that
> accepts `Authorization: Bearer <APIM subscription key>`, re-injects it as the `api-key`
> header, and forwards to the private Internal APIM `/openai` route. It exists because some
> OpenAI-compatible IDE clients (most notably **JetBrains AI Assistant**) expose only a URL +
> API-Key field and can ONLY send the key as a Bearer token, which Internal-mode APIM ignores.
> Design rationale + ruled-out alternatives: [architecture.md → Subkey proxy](architecture.md).
> Module: [apim-subkey-proxy-aci.bicep](../infra/modules/apim-subkey-proxy-aci.bicep). Tracked in
> [`#108`](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/108).

**Client base URL** (developer-facing, stable, never changes across reprovisions):

```
http://proxy.byok.internal:8080/openai/v1
```

Put the developer's APIM subscription key in the client's API-Key/Bearer field. Reachable
**only in-VNet** (P2S VPN or an in-VNet host) — no public exposure.

### Enable / disable

Set in the env's parameter file (`deployFoundrySubkeyProxy`), then `azd provision`. Enabling it
auto-adds `snet-aci` (`<vnetBase>.9.0/27`); no other flag is needed.

```pwsh
# tracked CI params: infra/main.parameters.ci.<commercial|commercial-dev|gov|gov-dev>.json
# local pilot params (gitignored): infra/main.parameters.<comm-pilot|gov-pilot>.json
#   "deployFoundrySubkeyProxy": { "value": true }
```

Currently deployed on **both pilots** (gov-pilot + comm-pilot) and enabled in all four CI envs.

### The nginx config (inline IaC — how to change/inspect proxy behavior)

There is **no Dockerfile and no custom image**: the container runs the **stock MCR-mirrored
`nginx`** image, and its entire configuration is authored **inline** as the `nginxConf` variable
in [apim-subkey-proxy-aci.bicep](../infra/modules/apim-subkey-proxy-aci.bicep) and mounted
**read-only as a secret volume** at `/etc/nginx/conf.d/default.conf`. The behavior is therefore
version-controlled as IaC, not baked into an artifact you build/push. What the config actually
does (all it does):

- `map $http_authorization $byok_key { ... "~*^Bearer (.+)$" $1; }` — extract the token from
  `Authorization: Bearer <key>`.
- `proxy_set_header api-key $byok_key;` + `proxy_set_header Authorization "";` — re-inject as
  `api-key`, drop the Bearer header.
- `proxy_pass https://<apimGatewayHost>;` with `proxy_ssl_server_name on;` — forward to the
  private APIM gateway over TLS (SNI required for APIM).
- `proxy_buffering off;` — stream SSE (`stream:true`) end to end.
- `proxy_read_timeout 600s;` + `client_max_body_size 50m;` — tolerate slow completions and large
  (full-codebase-context) prompts.

It is a **dumb pass-through** — it has **no per-endpoint logic** and forwards every path to APIM
unchanged. Adding OpenAI-compatible paths (e.g. `GET /v1/models/{model}`, `/v1/responses/{id}…`)
is **APIM-only work**; this module never changes for that.

**To change proxy behavior** (a timeout, body size, an extra header): edit the `nginxConf`
variable in the module and `azd provision`. Do **not** `exec` in and edit the file — the mount is
read-only and the container is stateless, so any in-place edit is reverted on the next
restart/reprovision.

**To inspect the live config** (debugging, from anywhere with ARM access — this uses the control
plane, not the data plane):

```pwsh
$cg = az container list -g $rg --query "[?contains(name,'subkeyproxy')].name | [0]" -o tsv
az container exec -g $rg -n $cg --exec-command "cat /etc/nginx/conf.d/default.conf"
```

### Where it is / current IP (you normally never need the IP)

The stable FQDN is a **VNet-linked private DNS** A record (`proxy.byok.internal`, zone
`byok.internal`) that Bicep **repoints at the ACI's current IP on every provision** — so a
reprovision that moves the (dynamic, unpinnable) ACI IP never changes the client URL. Between
provisions, a scheduled **reconciler job repoints it automatically on drift** (see below).

```pwsh
# The running container + its current private IP
az container list -g $rg --query "[?contains(name,'subkeyproxy')].{name:name, ip:ipAddress.ip, state:instanceView.state}" -o table
# What the FQDN currently resolves to (should equal the IP above)
az network private-dns record-set a show -g $rg -z byok.internal -n proxy --query "aRecords[].ipv4Address" -o tsv
# VNet link must be Completed for in-VNet resolution
az network private-dns link vnet list -g $rg -z byok.internal --query "[].{name:name, state:virtualNetworkLinkState}" -o table
```

### Self-healing DNS reconciler (`caj-proxydns` job)

A VNet-injected ACI's private IP is only written into the A record at **provision** time, so if
the platform **recreates** the container group out-of-band (host maintenance) the IP moves and
`proxy.byok.internal` goes stale. A scheduled **Container Apps Job** closes that gap: every ~15 min
it reads the proxy ACI's current IP and repoints the A record if it drifted (TTL 60s → clients
converge within ~a minute).

- **Why a job, not an in-ACI sidecar:** a VNet-injected ACI **cannot obtain a managed-identity
  token in-container** (IMDS `169.254.169.254` is unreachable in a VNet ACI). Container Apps supply
  the identity via `IDENTITY_ENDPOINT`, so the job authenticates there. It only calls ARM
  control-plane APIs, so it needs no in-VNet access. It runs in the **runner env** (`cae-runner`).
- **Why not `az login --identity`:** that CLI path only understands IMDS and fails in Container
  Apps. The job image ([infra/proxy-dns-reconciler-image](../infra/proxy-dns-reconciler-image),
  `reconcile.py`) uses **Python stdlib**: token from `IDENTITY_ENDPOINT`, then ARM REST.
- **Identity/RBAC (dedicated UAMI):** AcrPull on the shared ACR (pull the image), Reader on the
  proxy ACI (read its IP), Private DNS Zone Contributor on the zone (repoint the record).
- **Module:** [proxy-dns-reconcile-job.bicep](../infra/modules/proxy-dns-reconcile-job.bicep). Job
  name `caj-proxydns-<env>-<suffix>`. Image pre-baked by `az acr build` (built alongside the runner
  image in `build-runner-image.yml`).

```pwsh
$job = "caj-proxydns-$env-$suffix"   # e.g. caj-proxydns-gov-pilot-svmdsm
# Recent runs (Succeeded = it logged in via the ACA identity endpoint and reconciled)
az containerapp job execution list -g $rg -n $job --query "sort_by([].{name:name, status:properties.status, start:properties.startTime}, &start)[-5:]" -o table
# Force a run now (don't wait for the cron)
az containerapp job start -g $rg -n $job
```

> **Reading job logs:** these tenants **disable the Log Analytics data-plane SP**, so
> `az monitor log-analytics query` fails (bare `ERROR:` / 401). Validate via **execution status**
> (`Succeeded`/`Failed`) plus the **observable effect** — the A record value changing — instead of
> console logs. Drift test: point the record at a bogus IP
> (`az network private-dns record-set a add-record ... --ipv4-address 10.60.9.99` + remove the real
> one), `az containerapp job start`, then confirm the record returns to the ACI IP.

### Validate end to end

From an **in-VNet host with a test VM** (`deployTestStack=true`, e.g. gov-pilot):

```pwsh
$key = az apim subscription show -g $rg --service-name $apim --sid dev1 --query primaryKey -o tsv
az vm run-command invoke -g $rg -n vm-copilot-byok --command-id RunPowerShellScript --query "value[0].message" -o tsv `
  --scripts "Resolve-DnsName proxy.byok.internal -Type A | % IPAddress; (Invoke-WebRequest 'http://proxy.byok.internal:8080/openai/v1/models' -Headers @{Authorization='Bearer $key'} -UseBasicParsing).StatusCode"
# Expect: the ACI IP, then 200
```

From an env **without a test VM** (`deployTestStack=false`, e.g. comm-pilot) — spin up an
ephemeral ACI in `snet-aci` (delete it after). Use a YAML spec + `secureValue` env var to avoid
Windows/az quoting issues and to keep the key out of the command line:

```pwsh
$subnet = az network vnet subnet show -g $rg --vnet-name (az network vnet list -g $rg --query "[0].name" -o tsv) -n snet-aci --query id -o tsv
$key    = az apim subscription show -g $rg --service-name $apim --sid dev1 --query primaryKey -o tsv
@"
apiVersion: '2021-10-01'
location: $(az group show -n $rg --query location -o tsv)
name: aci-proxy-validate
properties:
  osType: Linux
  restartPolicy: Never
  subnetIds: [ { id: $subnet } ]
  containers:
    - name: probe
      properties:
        image: mcr.microsoft.com/azure-cli:latest
        resources: { requests: { cpu: 1, memoryInGB: 1.0 } }
        command: [ /bin/sh, -c, 'getent hosts proxy.byok.internal; curl -s -m 25 -w "\nSTATUS:%{http_code}\n" -H "Authorization: Bearer `$APIM_KEY" http://proxy.byok.internal:8080/openai/v1/models' ]
        environmentVariables: [ { name: APIM_KEY, secureValue: $key } ]
"@ | Set-Content .azure/aci-proxy-validate.yaml -Encoding ascii
az container create -g $rg -f .azure/aci-proxy-validate.yaml -o none
az container logs   -g $rg -n aci-proxy-validate        # expect the IP + models JSON + STATUS:200
az container delete -g $rg -n aci-proxy-validate --yes -o none
Remove-Item .azure/aci-proxy-validate.yaml               # the file holds the key
```

### Troubleshoot

| Symptom | Cause | Fix |
|---|---|---|
| `401` from the proxy | Request reached APIM but the key is missing/invalid/revoked | It's working — fix the key (§2/§3). A 401 proves DNS + proxy + APIM are all healthy. |
| Connection refused / timeout | Caller isn't in-VNet, or the ACI is stopped | Confirm you're on the VPN / an in-VNet host; check container `state` and `az container restart -g $rg -n <cg>` |
| `proxy.byok.internal` won't resolve | VNet link missing / wrong zone name | Re-check the `link vnet list` output above; the zone must be exactly `byok.internal` and the link `Completed` |
| URL worked, then broke after a client cached a raw IP | Someone configured the ACI IP directly instead of the FQDN | Switch the client base URL to `http://proxy.byok.internal:8080/openai/v1` |

Restart (picks up nothing new by itself — it's stateless; use only to clear a wedged container):
`az container restart -g $rg -n <container-group-name>`.

---

## Quick reference card

| I need to… | Command / section |
|---|---|
| Issue a developer key | §2 `az apim subscription create` + `show --query primaryKey` |
| Give a Bearer-only IDE (JetBrains) access | §10 subkey proxy (`http://proxy.byok.internal:8080/openai/v1`) |
| Revoke access now | §2/§3 `subscription update --state suspended` (key) or remove app-role (jwt) |
| Rotate a leaked key | §3 `subscription regenerate-key` |
| Stop "first request 429s" | §4 raise tier/`jwt-tokens-per-minute` TPM |
| Fix 404 on a new model | §4 bump `aoai-default-api-version`; keep `COPILOT_PROVIDER_AZURE_API_VERSION` |
| Diagnose backend 403 | §5 MI-RBAC loop |
| Empty dashboards | §8 metrics:true + Dedicated checks |
| Roll back a bad policy | §7 `git checkout <sha> -- policies/ infra/` + RG-scope deploy |
| Run a full health check | [smoke-test.ps1](../scripts/smoke-test.ps1) |
