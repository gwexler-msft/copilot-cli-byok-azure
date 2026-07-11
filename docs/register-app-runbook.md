# Register app runbook — self-serve BYOK developer onboarding

> **What this is.** The self-serve **register app** (issue [#64](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/64))
> is an Entra-authenticated web app that lets a developer provision their **own** per-developer
> APIM subscription (a BYOK key scoped to a product tier), download a ready-to-paste VS Code
> config, and run a one-shot installer — without an operator manually creating subscriptions.
> It replaces the manual `az apim subscription create` onboarding in
> [operations-runbook.md §2](operations-runbook.md) for fleets that want self-service.
>
> **Audience.** Two readers, two halves:
> - **Developers** — [§1 Developer quickstart](#1-developer-quickstart).
> - **Operators / platform admins** — [§2](#2-admin-prerequisites) onward (deploy, configure,
>   distribute, offboard).
>
> The app is **opt-in**: it only exists in an environment provisioned with
> `deployRegisterApp=true`. Environments without it keep using the manual onboarding flow.
> For *why* it is built this way (external ACA + Easy Auth, no VNet injection, least-priv UAMI),
> see [plan-register-app.md](plan-register-app.md) and [architecture.md](architecture.md).

---

## 1. Developer quickstart

> You need: a workstation that can resolve the **APIM gateway** host to its private IP
> (in-VNet, or off-VNet over the P2S VPN), a tenant account that is a member of the BYOK
> access group, and VS Code **1.122+**.

1. **Open the register app.** Your operator gives you the URL (looks like
   `https://ca-register-<env>-<suffix>.<region>.azurecontainerapps.io`). Sign in with your
   Entra (work) account when redirected — Easy Auth gates the whole app.
2. **Register.** Click **Register / Get my key**. The app creates your personal APIM
   subscription (idempotent — clicking again returns the same subscription) and shows your
   key **once**. Copy it now; it is not shown again. If you lose it, use **Regenerate**
   (which invalidates the old key).
3. **Get your config.** Click **Download config** to get a `chatLanguageModels.json` already
   filled in with the gateway host and your key, **or** **Download installer** and pick your
   OS (Windows / macOS / Linux).
4. **Run the installer once.** It merges the BYOK model config into your VS Code user folder
   (without clobbering existing settings), wires the utility/small model, and applies the
   privacy/telemetry lockdown. See [§6 What the installer writes](#6-what-the-installer-writes).
   - Windows (PowerShell): `./Use-Byok.ps1`
   - macOS / Linux (bash): `chmod +x use-byok.sh && ./use-byok.sh`
5. **Reload VS Code** (`Developer: Reload Window`) so the new language models register. Open
   Chat, pick a **BYOK** model, and start chatting.

> **Manual fallback.** If you prefer to paste config by hand (or the register app is not
> deployed in your environment), follow [samples/vscode/README.md](../samples/vscode/README.md).
> The self-serve flow is the recommended path; the manual paste is the fallback.

---

## 2. Admin prerequisites

Before the register app is usable, four things must be true. The first two are **org/tenant**
prerequisites; the last two are handled by the deploy (called out so you can verify them).

| Prerequisite | Who/where | Why |
|---|---|---|
| **Org BYOK policy enabled** | GitHub.com org policy — *"Bring Your Own Language Model Key in VS Code"* (Copilot Business/Enterprise) | If disabled org-wide, **no** `chatLanguageModels.json` works — pure-private fleets without Copilot sign-in are unaffected, but mixed fleets must enable it. Gate this **before** rollout. |
| **Entra app registration for Easy Auth** | Auto-created by [scripts/setup-register-entra.ps1](../scripts/setup-register-entra.ps1) (`.sh` for bash) — run by the CI deploy workflows, or once by an admin. See [§4](#4-configure-entra-app-registration--easy-auth). | Fronts the app so only tenant users reach it and supplies the `oid`/`groups` claims the backend uses for identity + tier. Degrades to a printed manual command when the deploy principal lacks directory-write rights (expected in Gov). |
| **Least-privilege UAMI + custom role** | Auto-created by [apim-register-role.bicep](../infra/modules/apim-register-role.bicep) when `deployRegisterApp=true`. | The app runs as this UAMI: APIM subscription CRUD + key actions + product/service read **only**. No data-plane, no broad Contributor. |
| **Graph `GroupMember.Read.All` grant on the UAMI** | Auto-attempted by the `grant-register-graph-perms` postprovision hook; needs a consent-capable deployer. See [§5](#5-tier-gating--groups). | Needed only for the **group-overage** fallback (users in ≳200 groups). Degrades safely to claim groups if the grant is skipped. |

---

## 3. Deploy the register app

The register app is an **opt-in** add-on to an already-deployed gateway env. Two steps:
**provision** (creates the ACR, UAMI+role, ACA env+app on a placeholder image) then a
**targeted deploy** (builds and pushes the real image).

Set the register params in your **`infra/main.parameters.json`** (the per-deployment,
gitignored param file — copy from `main.parameters.commercial.example.json` /
`main.parameters.gov.example.json`), then:

```jsonc
// infra/main.parameters.json — add/flip these:
"deployRegisterApp":                 { "value": true },
"registerEasyAuthClientId":          { "value": "<app-reg clientId from §4>" },        // empty ⇒ no auth
"registerEasyAuthSecretKeyVaultUri": { "value": "<KV secret URI from §4>" }            // preferred: managed-identity Key Vault reference
// (legacy inline fallback: "registerEasyAuthClientSecret": { "value": "<secret>" } — @secure, avoid committing)
```

```pwsh
# 0. Pick the env (same RG convention as everywhere: rg-copilot-byok-<envName>).
$env = "comm-pilot"            # or gov-pilot / commercial / gov

# 1. Provision (phase 1) with the register app on. The Easy Auth id/secret start empty —
#    hosting + Key Vault + UAMI come up on a placeholder image with no auth.
azd provision

# 2. Build + push the real image to the gated ACR and roll the Container App. TARGETED deploy
#    (never a blanket `azd up` — register is the only service with an image to build):
azd deploy register

# 3. Wire Easy Auth (creates the app reg, stores the secret in Key Vault) then re-provision
#    (phase 2) to attach the login flow. See §4 — CI runs these two steps automatically.
./scripts/setup-register-entra.ps1   # bash: ./scripts/setup-register-entra.sh
azd provision
```

> **Why two phases.** `deployRegisterApp=true` provisions a **gated** Standard ACR
> ([register-acr.bicep](../infra/modules/register-acr.bicep)) and outputs
> `AZURE_CONTAINER_REGISTRY_ENDPOINT`; `azd deploy register` resolves the Container App by its
> `azd-service-name: register` tag and builds the image **in ACR Tasks** (`remoteBuild: true`)
> so no local Docker daemon is required — this is what lets CI runners provision without Docker.

> **Bicep parameters** ([main.bicep](../infra/main.bicep)):
>
> | Param | Default | Notes |
> |---|---|---|
> | `deployRegisterApp` | `false` | Master switch. `false` ⇒ no ACR/UAMI/KV/app, env is register-less. |
> | `registerEasyAuthClientId` | `''` | Entra app-reg client id (§4). Empty ⇒ no auth (placeholder bring-up only). |
> | `registerEasyAuthSecretKeyVaultUri` | `''` | **Preferred.** Key Vault secret URI for the client secret ([register-kv.bicep](../infra/modules/register-kv.bicep)); the Container App reads it via its UAMI so the secret never flows through a param. Written by `setup-register-entra` (§4). |
> | `registerEasyAuthClientSecret` | `''` (`@secure`) | Legacy inline fallback when no KV URI is set; stored as a Container App secret. |
> | `registerAppImage` | `mcr.microsoft.com/dotnet/samples:aspnetapp` | Placeholder until `azd deploy register` swaps in the real image. |
>
> The app URL is the `registerAppUrl` deployment output (azd env value `REGISTER_APP_URL`);
> the FQDN, Key Vault name, and Easy Auth secret URI are outputs `registerAppFqdn`,
> `registerKeyVaultName`, and `registerEasyAuthSecretUri`.

---

## 4. Configure Entra app registration + Easy Auth

The register app uses **Container Apps Easy Auth** (`authConfig 'current'`,
`unauthenticatedClientAction: RedirectToLoginPage`). You need one Entra app registration per
cloud. This is **automated** by [scripts/setup-register-entra.ps1](../scripts/setup-register-entra.ps1)
(`.sh` for bash) and runs as part of the CI deploy workflows — you only do it by hand for a
local deploy or when the CI principal lacks directory-write rights (it degrades to a printed
manual command, never failing the deployment).

### Why two phases

The Easy Auth redirect URI is `https://<registerAppFqdn>/.auth/login/aad/callback`, and the
FQDN doesn't exist until the Container App is first provisioned. So the bring-up is:

1. **Provision (phase 1)** with `deployRegisterApp=true` and the Easy Auth params empty →
   hosting + the register **Key Vault** ([register-kv.bicep](../infra/modules/register-kv.bicep))
   + UAMI + ACR come up on a placeholder image, no auth.
2. **`azd deploy register`** → builds and pushes the real Blazor image.
3. **`setup-register-entra`** → creates/reuses the app registration
   `copilot-byok-register-<envName>`, sets the redirect URI, `api://<clientId>` identifier,
   v2 tokens, and the **SecurityGroup** groups claim; mints a client secret and **stores it in
   Key Vault** (secret `register-easyauth-secret`); then publishes `REGISTER_EASYAUTH_CLIENT_ID`
   and `REGISTER_EASYAUTH_SECRET_KV_URI` to the azd env.
4. **Provision (phase 2)** → the now-populated params attach the login flow; the Container App
   reads the secret from Key Vault via its UAMI (the plaintext never touches a Bicep param or
   azd state).

### Run it (local / manual)

```pwsh
# After phase-1 `azd provision` + `azd deploy register` (§3):
./scripts/setup-register-entra.ps1            # discovers FQDN + KV from azd outputs
# bash: ./scripts/setup-register-entra.sh
azd provision                                  # phase 2 — attaches Easy Auth
```

The script is idempotent (reuses the app reg + KV secret on re-run; pass `-Rotate` /
`ROTATE=1` to force a new secret) and cloud-aware (Graph endpoint resolved from
`az cloud show`). If it can't write to the directory it prints the exact admin command and
exits 0 — Easy Auth stays off (the app is reachable unauthenticated) until an admin runs it.

> **CI does this automatically.** [deploy-dev.yml](../.github/workflows/deploy-dev.yml)
> (dev envs) and [deploy.yml](../.github/workflows/deploy.yml) (pilots) run the full
> phase 1 → deploy → setup → phase 2 sequence on every applicable run. In Gov, where the
> deploy principal is intentionally **not** a directory admin, the setup step degrades and the
> run still goes green — wire Easy Auth there by running the script once as a tenant admin.

### What the script configures (for reference / manual parity)

- Redirect URI (Web): `https://<registerAppFqdn>/.auth/login/aad/callback`.
- Application ID URI: `api://<clientId>` (Easy Auth `allowedAudiences`), v2 access tokens.
- **Token configuration → groups claim → Security groups**: emits group **object IDs** in the
  `groups` claim. The backend's tier map compares against those GUIDs (see [§5](#5-tier-gating--groups)).
  For users in ≳200 groups the token carries an overage marker instead; the backend then calls
  Graph `getMemberGroups` (requires the §2 Graph grant) and degrades to claim groups if Graph
  is unavailable.
- A client secret, written to the register Key Vault as `register-easyauth-secret`. Both clouds
  use the same shape — only the login host (`login.microsoftonline.com` / `.us`) differs.


---

## 5. Tier gating + groups

Tiers map an Entra **group object ID** to an APIM **product** (`byok-standard` / `byok-power`).
Configured in the app's `Byok` settings (env vars `Byok__*` on the Container App, defaults in
[appsettings.json](../app/register/src/appsettings.json)):

| Setting | Meaning |
|---|---|
| `Byok:DefaultProductId` | Tier for everyone not matched by `TierMap`. Default `byok-standard` (least-priv). |
| `Byok:TierMap[].GroupId` / `.ProductId` | If the caller's `groups` claim contains `GroupId`, they get `ProductId` (e.g. the `byok-power` group → `byok-power`). |
| `Byok:AdminGroupId` | Members may run the **offboard/revoke** flow for *other* developers (§7). Everyone can always self-revoke. |

Fill these per environment with your tenant's group object IDs. They are **not yet
first-class Bicep params** — they bind from the Container App's environment via ASP.NET's
double-underscore convention (`Byok:AdminGroupId` ← `Byok__AdminGroupId`,
`Byok:TierMap[0].GroupId` ← `Byok__TierMap__0__GroupId`). Set them with `az containerapp
update` (or bake non-secret defaults into [appsettings.json](../app/register/src/appsettings.json)
before building the image):

```pwsh
$rg = "rg-copilot-byok-$env"
$app = az containerapp list -g $rg --query "[?tags.\"azd-service-name\"=='register'].name | [0]" -o tsv

# Look up a group's object id:
$power = az ad group show --group "BYOK Power Users" --query id -o tsv
$admin = az ad group show --group "BYOK Admins"      --query id -o tsv

# Push as Container App env vars (rolls a new revision):
az containerapp update -g $rg -n $app --set-env-vars `
  "Byok__AdminGroupId=$admin" `
  "Byok__TierMap__0__GroupId=$power" "Byok__TierMap__0__ProductId=byok-power"
```

> A targeted `azd deploy register` redeploys the image; env vars set with `az containerapp
> update` persist across image deploys (they're on the app, not the image). Re-apply them only
> if you recreate the Container App via `azd provision`.

> Least-privilege by default: an unmapped user gets `byok-standard`, and any Graph failure
> **degrades** to the inline claim groups — it never escalates a tier.

---

## 6. What the installer writes

The downloadable installer (`Use-Byok.ps1` / `use-byok.sh`) touches **three local surfaces**,
all **per-user**, never machine-wide, and **merges** rather than clobbers:

1. **VS Code `chatLanguageModels.json`** (user folder) — the BYOK model config (gateway host +
   the developer's key). Auto-discovered by VS Code; no `settings.json` pointer needed.
2. **VS Code `settings.json`** — the utility/small-model pair (`chat.utilityModel`,
   `chat.utilitySmallModel` → `BYOK gpt-4.1-mini`) **and** the telemetry/call-home lockdown
   block. Required for the no-sign-in posture.
3. **Copilot CLI env vars** (USER scope) — `COPILOT_PROVIDER_*` (type `azure`, base URL
   `.../openai`, the key, token limits), persisted (HKCU on Windows; shell-profile marker
   block on *nix) rather than current-shell-only.

Opt-out switches (use only on Copilot-signed fleets that want defaults): `-SkipUtilityModels`,
`-SkipPrivacyLockdown`, `-SkipCliEnv`.

> **Never set `COPILOT_OFFLINE`.** It breaks BYOK (process-wide HTTP kill — the request hits
> the gateway with no credential). Privacy is enforced at the **network layer** via the egress
> allowlist, not an app switch. The canonical telemetry-off `settings.json` block lives in
> [deployment-guide.md → Lock down VS Code editor "chatter"](deployment-guide.md#lock-down-vs-code-editor-chatter-fully-private--no-call-home-posture);
> network enforcement is [github-egress-allowlist.md](github-egress-allowlist.md).

---

## 7. Offboarding / revocation

A developer's access **is** their APIM subscription. Revoking it stops their key immediately.

- **Self-service:** any signed-in developer can **Regenerate** (rotate, invalidating the old
  key) or **Revoke** their own subscription from the app.
- **Admin offboard:** members of `Byok:AdminGroupId` can revoke a **departed** developer by UPN
  from the app (the backend matches the subscription's `DisplayName`, which is the UPN).
- **Break-glass (no app):** straight control-plane, same as
  [operations-runbook.md §2](operations-runbook.md):
  ```pwsh
  $rg = "rg-copilot-byok-$env"; $apim = az apim list -g $rg --query "[0].name" -o tsv
  # Subscriptions created by the app are named  byok-<oid>  (stable across UPN renames).
  az apim subscription list -g $rg --service-name $apim --query "[?contains(displayName,'<upn>')].name" -o tsv
  az apim subscription update -g $rg --service-name $apim --sid <sid> --state suspended   # instant
  az apim subscription delete -g $rg --service-name $apim --sid <sid> --yes               # permanent
  ```

> **Why `sid = byok-<oid>` not the UPN.** The subscription id derives from the immutable Entra
> object id, so a UPN rename never orphans a subscription; the `DisplayName` stays the UPN for
> telemetry (`developer_upn`) and portal readability.

---

## 8. Auth-mode + capacity notes

- **Auth mode.** The register app issues **subscription keys** (`subscriptionKey` mode — the
  fleet default). Keys are long-lived and validated natively by APIM. JWT mode is intentionally
  **not** used for fleets: ~60-min token expiry would mean hourly `401`s fleet-wide and VS Code
  does not refresh JWTs. Rationale:
  [feature-request-byok-credential-refresh.md](feature-request-byok-credential-refresh.md).
- **Capacity.** APIM supports **10,000 subscriptions/instance** and **1,000 per product** — a
  few hundred per-developer keys is comfortably within limits.

---

## 9. Per-cloud differences (Commercial / Government)

The app is cloud-agnostic; only endpoints change, driven by the single `Byok__CloudEnv`
(`AzureCloud` / `AzureUSGovernment`) env var — mirrors `cloudVars` in
[main.bicep](../infra/main.bicep):

| Constant | Commercial | Government |
|---|---|---|
| ARM management base | `management.azure.com` | `management.usgovcloudapi.net` |
| Entra login host | `login.microsoftonline.com` | `login.microsoftonline.us` |
| Microsoft Graph base | `graph.microsoft.com` | `graph.microsoft.us` |
| APIM gateway DNS zone | `azure-api.net` | `azure-api.us` |

### Government caveats (verify before a Gov rollout)

- **Foundry portal launch button.** The blue *"Go to Azure AI Foundry portal"* button on the
  AIServices Overview blade in `portal.azure.us` lags Commercial and may be missing. This is a
  **Gov portal parity gap, not a resource problem** — the IaC provisions the correct
  `kind: AIServices`. Use the Foundry portal directly at **https://ai.azure.us/** and pick the
  resource. File a Gov support ticket for a tracked ETA.
- **Features not available in Gov** (don't promise these in onboarding comms): the VS Code
  Azure AI Foundry extension, Foundry Agents, model fine-tuning, serverless endpoints, batch
  jobs, and Azure OpenAI Evaluation.

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| App URL redirects to login then errors | Easy Auth app-reg redirect URI / audience mismatch | Confirm `https://<fqdn>/.auth/login/aad/callback` redirect URI + `api://<clientId>` audience (§4). |
| Register succeeds but VS Code shows no BYOK model | Installer not run, or VS Code not reloaded | Run the installer (§6), then `Developer: Reload Window`. Confirm `chatLanguageModels.json` is in the user folder. |
| Everyone lands on `byok-standard` (no power tier) | `TierMap` GroupId unset, or groups claim not emitted | Set `Byok__TierMap__0__GroupId` on the Container App (§5) **and** enable the Security-groups claim on the app reg (§4). |
| Power users in many groups get standard | Group overage + Graph grant missing | Confirm the `grant-register-graph-perms` hook granted `GroupMember.Read.All` (§2); re-run it as a consent-capable admin if it was skipped. |
| `azd deploy register` wants a local Docker daemon | `remoteBuild` not in effect | `azure.yaml` `services.register.docker.remoteBuild: true` builds in ACR Tasks — confirm it's set; re-pull main. |
| Postprovision hook fails `exit 126 / Permission denied` | Shipped `.sh` lost its exec bit | `git update-index --chmod=+x scripts/grant-register-graph-perms.sh` and re-commit (the repo tracks these 100755). |
| Key works at gateway but app can't create subscription | UAMI role/scope drift | Verify the custom role assignment from [apim-register-role.bicep](../infra/modules/apim-register-role.bicep) is present on the APIM instance. |

---

## 11. Verification & smoke probes

### Automated (CI + local) — `scripts/smoke-test.ps1` / `.sh`

The smoke test ([smoke-test.ps1](../scripts/smoke-test.ps1), [smoke-test.sh](../scripts/smoke-test.sh))
runs after every deploy and includes four register-app assertions. All four **SKIP** (never
fail) on envs without the register app, so they're safe to run everywhere:

| Assertion | What it proves | Notes |
|---|---|---|
| `register-app` | App is up — `GET /healthz` returns 200/302/401/403 | Liveness only. |
| `register-auth` | **Login is enforced** — unauth `POST /api/register` is denied (302 login redirect, or 401 if Easy Auth isn't attached yet). **FAILs on 2xx** (endpoint anonymously reachable). | The security net for "no provisioning without a login". |
| `register-rbac` | The register UAMI holds the custom `BYOK Register Subscription Manager` role at the APIM scope — i.e. it *can* provision. | Control-plane check; needs `Reader` on the RG. |
| `provision-roundtrip` | **The provisioning path works end-to-end** — mirrors the app's `ApimProvisioner`: PUT an ephemeral APIM subscription scoped to a tier product → `listSecrets` → chat `200` with the fresh key → DELETE the subscription. | **MUTATES APIM** (throwaway sub, cleaned up). Auto-SKIPs where the smoke identity is read-only (pilots get 403). `-SkipProvisionProbe` / `--skip-provision-probe` opts out; `-ProvisionProduct` / `--provision-product` picks the tier (default `byok-standard`). |

```pwsh
# Run just the register-relevant checks locally (token-limit skipped for speed):
./scripts/smoke-test.ps1 -EnvName comm-dev -SkipTokenLimit
# Skip the mutating provision round-trip (control-plane checks only):
./scripts/smoke-test.ps1 -EnvName comm-dev -SkipProvisionProbe
```

> **Why the real `POST /api/register` isn't automated:** that path requires an *interactive*
> Entra login (the `/.auth/login/aad/callback` browser flow), which a CI runner can't complete.
> `provision-roundtrip` exercises the same ARM provisioning the app performs, just driven by the
> smoke identity instead of an end-user token — so the mechanism is covered even though the
> human login isn't.

### Manual interactive-login probe (do this once per env after first deploy)

The only thing the automated probes can't cover is a real human completing Easy Auth and
getting a working key. Verify it by hand once after wiring Easy Auth (§4):

1. **Login** — open `https://<registerAppFqdn>/` in a private browser window. You should be
   redirected to your tenant's Entra login. Sign in with a **work account**. ✅ Expect: you land
   on the register app UI (not an error). A 401/403 *after* login usually means the app reg
   audience (`api://<clientId>`) or redirect URI is wrong (§4).
2. **Provision a key** — trigger registration (UI button, or `POST /api/register` from the
   browser devtools/`Invoke-RestMethod` with your session cookie). ✅ Expect: a JSON body with
   `sid`, `productId`, `primaryKey`, `baseUrl`. The `productId` should match your **tier group**
   (admins → `byok-power`, others → `byok-standard`; §5).
3. **Verify the key works** — call the gateway with the returned key:
   ```pwsh
   $r = irm "$baseUrl/v1/chat/completions" -Method Post -Headers @{ 'api-key' = $primaryKey } `
     -ContentType 'application/json' `
     -Body (@{ model='gpt-5.1'; messages=@(@{role='user';content='Reply pong.'}); max_completion_tokens=16 } | ConvertTo-Json)
   $r.choices[0].message.content   # -> "pong"
   ```
   ✅ Expect: `200` + a reply. A `401` here means the subscription wasn't created/active; a `429`
   means it works but you hit the tier's TPM.
4. **Re-run = same key** — registering again returns the **same** `sid`/key (idempotent upsert
   keyed on your `oid`). ✅ Expect: identical `sid`.
5. **Tier move (optional)** — add/remove yourself from a `TierMap` group, re-register, and
   confirm `productId` changes accordingly.

---

## See also

- [plan-register-app.md](plan-register-app.md) — design + as-built for the whole register app.
- [operations-runbook.md](operations-runbook.md) — the deployed-gateway ops runbook (manual
  onboarding, key rotation, rate limits, backend health).
- [deployment-guide.md](deployment-guide.md) — first deploy of the gateway itself.
- [samples/vscode/README.md](../samples/vscode/README.md) — manual config paste (fallback).
- [github-egress-allowlist.md](github-egress-allowlist.md) — network-layer privacy enforcement.
