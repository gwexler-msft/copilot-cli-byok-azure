# Operations lessons — Copilot BYOK gateway (Commercial + Government)

> **Audience:** engineers operating or extending this solution, and delivery teams reusing it.
> This is the sanitized, team-shareable consolidation of hard-won operational knowledge. It is the
> detail companion to [architecture.md](architecture.md) (design) and
> [lessons-learned.md](lessons-learned.md) (delivery playbook), and the source of truth referenced
> by [.github/copilot-instructions.md](../.github/copilot-instructions.md).
>
> **Sanitization policy:** no real tenant/subscription/client/object IDs, IPs/CIDRs, resource
> suffixes, account names, FQDNs, emails, or secrets appear here — only placeholders and patterns.
> Keep it that way when you edit. Environment role names (`comm-pilot`, `gov-pilot`, `comm-dev`,
> `gov-dev`) and the project prefix (`copilot-byok`) are generic and fine to use.

Resource-name patterns used below (`<env>` = role, `<suffix>` = deterministic azd token):
`apim-copilot-byok-<env>-<suffix>`, `aifcopilotbyok<env><suffix>` (Foundry/AOAI), `kvrun<env><suffix>`
(runner KV), `kvreg<env><suffix>` (register KV), `acrreg<env><suffix>` (ACR),
`caj-runner-<env>-<suffix>` (runner Job).

---

## Authentication admission warning (2026-09-18)

An isolated no-backend probe in both Government and Commercial found that setting
`subscriptionRequired=false` can populate `context.Subscription` for an active key
scoped to another API or an unlinked product. A policy accepting any non-null subscription
therefore authorizes out-of-scope callers. Valid product keys still retained product
context and enforced a test rate limit; those successes do not establish scope safety.
Mandatory admission rejected the out-of-scope keys but also rejected JWT-only callers.
Do not merge key/JWT policies using only a non-null subscription check. See
[authentication evidence](authentication.md#native-admission-experiment-blocked-2026-09-18).

APIM also requires unique API/product display names, not just resource IDs. Give disposable
probe resources unique names on each run. VM Run Command output is bounded; keep evidence
compact and assert the complete expected result set rather than accepting a partial log.

For API policy ownership reads on Windows, explicitly request JSON with
`az rest --headers 'Accept=application/json'`. The default request can return policy XML whose
BOM triggers `UnicodeEncodeError` in the CLI's text output; `-o json` alone does not negotiate
the HTTP response format. Verified on 2026-09-21: the same Government policy read failed with
default headers and succeeded with explicit JSON, exposing the policy in `properties.value`.
This rendering failure is not an RBAC denial. Preserve ownership checks and capture safe CLI
exit/error categories instead of requesting new permissions or printing raw policy errors.

Preserve the policy representation when writing it back. A JSON policy response with
`properties.format=xml` contains XML-escaped expressions; submitting it as `rawxml` can fail
compilation even when the authentication expressions were unchanged. APIM also reformats XML
on readback. For an `xml` envelope, compare securely parsed policy content rather than exact
formatting before deleting an owned fixture; still reject changed attributes or expression text.
This does not make the repository's `rawxml` policy sources suitable for a strict XML parser.
When generating a synthetic response, preserve early authentication rejections and replace only
the uniquely marked successful response. Both synthetic CLI wire policies passed Government
create/readback/delete validation on 2026-09-21; interactive CLI execution remains a separate gate.

ARM readback is not proof that a freshly created API is ready on the gateway. The first
interactive CLI fixture check returned 404 before the CLI started, while the retained auth-only
probe still passed. A subsequent token-free VM check reached both fixture routes and received
401 with their operation-specific markers. Treat propagation delay as the likely cause, not a
proven captured transition. Before sending CLI credentials, use bounded missing-credential
readiness checks and require the expected operation marker, not just the API's default 401.
Revalidate fixture ownership between attempts; unexpected acceptance, a wrong marker, transport
errors, or an exhausted readiness budget must stop the test and run normal cleanup.

An in-VNet Windows request can also time out before authentication when certificate-revocation
HTTP egress is blocked. Verified on 2026-09-21: an ordinary web request returned 401, while
strict-revocation TLS failed with `OfflineRevocation` / `RevocationStatusUnknown` and DigiCert
CRL retrieval timed out. Keep certificate validation enabled. For an explicitly approved test,
use a temporary VM-source `/32` outbound TCP-80 allowance, verify write/delete permission and
rule ownership, and remove only that rule in `finally` with readback. A cleanup failure must fail
the overall test. This diagnostic window is not a permanent certificate-revocation egress design.

The follow-up product-context guard blocked wrong-scope keys in both clouds but also rejected
legitimate API-scoped and all-APIs subscriptions. Product context is not a general replacement
for native scope authorization. Reject conflicting credential sources explicitly, but do not
mistake that fix for complete key/JWT coexistence.

Large CMS ciphertext passed as Windows Run Command parameters returned no structured test
results. Moving ciphertext into temporary script parameter defaults restored both Commercial
expiry replay and the admission matrix; a command-line size limit is suspected, not independently
confirmed. Keep only encrypted payloads in that script, delete the local temporary file, and
remove the VM's non-exportable certificate/private key after testing. Never expose remote error
bodies that might echo arguments. Expired signed tokens returned 401 with fresh-token 200 controls
in both clouds; this does not establish client token renewal.

The required-subscription API plus explicitly JWT-guarded open-product candidate subsequently
passed 78-case isolated probes in both clouds. Operations omitting inbound base must invoke
authentication explicitly; attaching an open product to current key-only operation policies
without doing that would create an authentication bypass. Keep production unchanged until
surface coverage and remaining acceptance gates pass; see the authentication evidence.

A subsequent Government mock-backend probe found that two separate identical Authorization
Bearer header lines become one policy-visible value and are accepted when the token is valid.
Different duplicate Bearer values returned 400 with no backend receipt; duplicate api-key lines
returned 401. Checking `Headers["Authorization"].Length` cannot reject multiplicity already
lost before policy evaluation. A source-verified validate-parameters test also accepted identical
duplicates. The owner subsequently approved an explicit known-issue exception: the exact same
Bearer token repeated in Authorization may normalize to one effective credential, which must
still validate. Different values, mixed credential sources, comma-combined values and duplicate
keys/query credentials remain rejected. This supersedes the strict-header blocker, not the
historical test results. #140 remains open for the remaining acceptance work; support is now
nonblocking. Do not infer Commercial/HTTP2 behavior or full sign-off from the Government tests.
Select Windows test VMs by OS, not list position: the environment also has a Linux VM, and
RunPowerShellScript against it reports an OS-type Conflict, not an execution-in-progress lock.

Commercial raw SslStream probes failed certificate revocation validation with
`RevocationStatusUnknown,OfflineRevocation` while ordinary WebRequest returned the expected 401.
Status 0 is not an authentication rejection. Keep revocation checks enabled and record only
sanitized certificate error enums. The separate 50-case Commercial association gate passed,
but does not prove raw-header, HTTP/2, backend or complete accounting behavior.

Long-running ARM probe sequences must refresh their management token before expiry, including
cleanup calls. Government association testing passed 40 cases before an expired token prevented
the final stage and automatic rollback. Fresh-token, ownership-checked recovery restored the
disposable association state. The harness now renews ARM tokens and each stage's user token;
never count successful manual cleanup as a passing interrupted acceptance matrix.
The later complete Government rerun passed all 50 association cases with rollback readback,
followed by 202/202 Foundry and 114/114 Anthropic admission cases with final receipt audits and
listener/firewall/certificate cleanup. Keep these distinct from the earlier partial results.

Government's later two-real-user runs on 2026-09-19 passed 242/242 Foundry and 154/154 Anthropic,
including 40/40 isolation checks in each variant. Test independent users against a counter shared
by operation aliases; including the operation ID would hide an alias-based quota reset. These
small isolated rate/quota controls do not prove the full production accounting pipeline.
Commercial's later diagnostic runs passed 240/246 Foundry and 152/158 Anthropic, including
40/40 two-user checks each, but failed full acceptance: duplicate Authorization lines returned
401 instead of the Government expectations. Single raw-header controls passed and rejected
duplicates had no backend receipt. A blank error/context header does not prove rejection before
the policy: a guard's `return-response` can omit the normal outbound and on-error diagnostics.
Instrument that branch with fixed markers and counts before assigning blame to the parser.
The marked Commercial run confirmed the guard executed with two policy-visible Authorization
values for both identical and different duplicates; it returned 401 with no backend receipt.
Government exposes one value for identical duplicates. `GetValueOrDefault` comma-joins an array,
so a combined-value flag alone does not prove the client sent one comma-combined wire header.
Both services report Developer/`stv2`/Internal; those resource properties are not runtime-build
identifiers. No policy-only normalization or platform migration was approved.
The owner requires identical behavior across clouds; do not silently change expected statuses.
Check both token lifetimes before fixture creation. A cached token can pass preflight and become
too short-lived during setup; a stopped freshness gate is not a failed authentication matrix.
Requesting an explicit scope alone did not force renewal. The installed CLI's MSAL credential
accepted `force_refresh=True`; direct use of its `Identity` constructor on Windows required
`encrypt=True` to read the existing encrypted cache. Keep users/clouds in separate caches and
never print the returned credentials. APIM still validates the tokens; local decoded claims
are only fixture preflight. Reuse the ownership-checked auth-only baseline rather than creating
another API with the same display name, while keeping admission/counter fixtures fresh.

Both services had HTTP/2 explicitly disabled. A capable client alone does not establish HTTP/2
coverage: assert the negotiated protocol and obtain approval for the service-wide setting change.
The Commercial test VM's outbound Internet deny also blocks HTTP certificate CRLs. An approved
temporary VM-source-only TCP 80 allowance restored strict TLS without disabling revocation.
Restore every temporary egress rule, HTTP/2 setting and original VM power state after the window.

Do not wrap a forty-minute `az apim wait` in a ten-minute process timeout. The first HTTP/2
window hit that local timeout before testing. Cleanup readback showed HTTP/2 `False`, no temporary
rules and the VM deallocated, but provisioning was still `Updating`; that is not completed
restoration. Wait for the service operation and verify `Succeeded` before another setting change.
In this window, completed readback reverted to HTTP/2 `True`; the activity log showed the first
rollback failed with `Conflict` during enablement. A fresh recovery write was accepted after
enablement settled and completed on 2026-09-19 with HTTP/2 `False` and provisioning `Succeeded`.
Final cleanup also confirmed zero temporary rules and the VM deallocated. Never interpret a
transient custom-property value as successful rollback; successful recovery does not turn the
aborted HTTP/2 matrix into an acceptance pass.

Validate portable-client capabilities locally before opening a service-wide test window.
The official curl 8.22.0_1 Windows package includes LibreSSL and HTTP2, but not Schannel.
`CURL_SSL_BACKEND` selects a compiled backend; it cannot add one. Keep the capability check
fail-closed instead of dropping revocation requirements. A client-directory cleanup failure must
be reported without skipping the mock listener, firewall and transport-certificate cleanup.

In a Government negative control, adding a wrong `<issuers>` entry alongside `openid-config`
did not exclude the metadata issuer: the real token still returned 200. An exact incompatible
`iss` requirement in `required-claims` returned 401. Do not assume issuer-list override semantics;
test exact issuer/audience pairing. APIM also requires `audiences` before `issuers` in validator
XML. This control does not establish real alternate-issuer or Okta acceptance.

---

## 1. Cloud & session discipline

- **One cloud per `az`/terminal session, forever.** Pin each shell to a cloud with its own
  `AZURE_CONFIG_DIR`. Never `az login --tenant <other>` inside a tab pinned to a different cloud —
  it corrupts that config dir. Open a fresh tab for the other cloud.
- **Cross-cloud work needs a real switch.** Commercial ↔ Government are different tenants,
  authorities, DNS zones, and data-plane endpoints. Switching is `az cloud set` + `az login`.
- **PIM elevation → force a real re-login.** After activating Owner (or any role) via PIM, a cached
  token that predates the activation keeps failing *writes* with `AuthorizationFailed` while *reads*
  succeed (ARM authorizes off the token's claims for the token's whole ~1h life). This is **not**
  propagation lag, a lock (`ScopeLocked`), or ABAC. Decisive test: decode the ARM token's `iat` and
  compare to the role's `createdOn`; if `iat < createdOn`, re-login (device-code) to refresh.

---

## 2. Deployment model (azd) & parameter files

- **`main.bicep` is `targetScope = subscription`** and creates the RG. Consequently `azd deploy
  <service>` cannot infer the target RG — set `AZURE_RESOURCE_GROUP` to the custom RG name
  (`rg-copilot-byok-<env>`), not azd's default `rg-<env>`.
- **Prefer CI over local `azd provision` for pilots.** CI (`deploy.yml`, manual dispatch) exports the
  full set of environment variables/secrets and re-substitutes the CI param file. A **local**
  `azd provision` typically runs with an incomplete env, so `${VAR}` substitutions collapse to empty
  and Bicep defaults take over — **silently resetting parameterized named values and secrets to
  placeholders**. This has caused live outages (see §5). If you must provision locally, set every
  required `azd env set …` value first. A **preprovision guard** (`scripts/check-provision-params.*`,
  wired in `azure.yaml`) now hard-fails the commercial-route case and warns on any other `${VAR}`
  param that would deploy blank (louder on `*-pilot`); bypass with `SKIP_PROVISION_PARAM_CHECK=true`.
- **Param-file rules:**
  - Every key under `"parameters"` must be `{ "value": ... }`. A bare-string `"_comment"` is allowed
    only at the file **root**; inside `parameters` it breaks azd's unmarshal
    (`cannot unmarshal string into … ArmParameter`). `ConvertFrom-Json` will *not* catch this (it's
    valid JSON, just not valid azd shape).
  - `main.json` (compiled ARM) and the local `*.<pilot>.json` param files are **.gitignored** — azd
    compiles `main.bicep` at provision time. Commit only `main.bicep` + `main.parameters.ci.*.json`.
- **azd pwsh hooks must `exit 0`** on success/degrade paths. azd runs hooks as `pwsh -File`; a bare
  `return` (or falling off the end) after a native `az` call that set a nonzero `$LASTEXITCODE`
  propagates that code and fails the provision. Add explicit `exit 0` on every graceful path and at
  script end (it still runs `finally`). The `.sh` twin usually already exits 0.
- **Script hygiene:** helpers are paired `.ps1` + `.sh`; keep them in parity. New `.sh` files need
  the executable bit set in git (`git update-index --chmod=+x scripts/foo.sh`), or CI can't run them.

---

## 3. Self-hosted CI runners (EMU)

**Hosted runners are disabled** at the EMU enterprise level, so every workflow uses self-hosted
**ACA Job** runners (KEDA-scaled, ephemeral, one job then exit; label = env name). Diagnosing a
`startup_failure` with empty `jobs`: the real reason is in the **check-run annotations API**, not
`gh run view` (which misleadingly blames the workflow file).

- **Auth = classic PAT (not GitHub App).** GitHub App mode is impossible on an EMU **user-owned**
  repo (can't install a user-owned app; an enterprise install lacks repo-level Administration). The
  App capability is retained in code for future org-hosted envs, but live config is PAT.
- **Weekly PAT rotation (EMU ~7–8 day cap).** The KEDA `github-runner` scaler polls GitHub with this
  PAT to scale runners; when it expires, **jobs sit `queued` with zero runners scaling**. Rotate on a
  fixed weekly cadence. GitHub has **no API to mint a PAT** — regenerate in the browser, then
  distribute. **Validate before distributing** (expect `HTTP 201` from the repo
  `…/actions/runners/registration-token` endpoint with `administration=write`); a bad/truncated PAT
  otherwise fails *late* (runner starts, then `401 → failed to obtain a runner registration token`).
- **Private runner Key Vaults → break-glass rotation.** Pilot runner KVs are
  `publicNetworkAccess=Disabled` + Private Endpoint, so `az keyvault secret set` from a workstation
  is blocked (`ForbiddenByConnection`). Use `scripts/rotate-runner-pat-breakglass.ps1`, which:
  1. momentarily opens the vault (`PNA=Enabled` + `defaultAction=Allow`, still RBAC-gated),
  2. writes the secret,
  3. **always re-locks in a `finally`** (even on Ctrl-C), and
  4. **re-resolves the ACA Job secret** — required, because the platform caches KV secret references
     at the Job level and a new execution otherwise reuses the stale value for hours.
  - Step 4 only works if the Job secret is genuinely a **Key Vault reference**. Against an *inline*
    secret it can only skip — so the script now exits non-zero with `PARTIAL:` rather than printing
    success, which previously masked a dead runner for hours.
  - **Governed-subscription fallback (ARM write):** on a managed subscription a `modify`-effect
    Azure Policy can force `PNA=Disabled` on every write, so the vault never opens (the update
    "succeeds" but re-reads as Disabled). The script detects this and **writes the secret via an ARM
    deployment** of a `Microsoft.KeyVault/vaults/secrets` resource instead: ARM is a trusted service
    and the vault keeps `bypass: AzureServices`, so the write succeeds **with the vault still
    locked** (this is how the original provision seeded it). Works from anywhere; no in-VNet host and
    no PNA toggle. This is *not* an IP problem — break-glass opens to all IPs during the window; the
    difference is purely governance between subscriptions.
  - A surgical `/32` IP allowlist does **not** work for the open window: the az CLI's egress to the
    vault is an Azure SNAT address (not your public IP) and can rotate — hence `defaultAction=Allow`.
- **A hand-fix that IaC doesn't know about is reverted by the next provision.** The runner Job's
  `gh-pat` was converted to a Key Vault reference by hand, and the next pilot deploy silently baked it
  back **inline** — because the CI param file still had `ghRunnerSecretFromKeyVault: false`. The same
  drift re-opened a runner vault to the public internet (`deployRunnerKvPrivateEndpoint` was simply
  absent from the CI params, so every provision rendered `PNA=Enabled`). Both looked "fixed" when
  checked right after the manual change and regressed within hours. Note the asymmetry that makes
  this dangerous: ARM incremental **never deletes**, so the vault and its Private Endpoint survived
  and the drift was invisible in a resource listing — only a *property* flipped back. **Any
  posture you care about belongs in the committed param file, and manual `az` fixes are a stopgap
  with an expiry date measured in one deploy.**
- **KV-backed Job secrets have to bootstrap in a single pass.** Container Apps **fetch-validates** a
  `keyVaultUrl` Job secret at create/update time, so the vault, the secret value, *and* the identity's
  Key Vault Secrets User role must all exist before the Job is written. Declaring the runner identity
  inside the runner module inverted that: the vault module needed the identity's principal id as an
  input, so it ran *after* the Job — the Job failed, the module produced no outputs, and the vault it
  was waiting on was never created. Permanent deadlock on a fresh env. The fix is ordering plus
  self-seeding: a standalone identity module → vault module (RBAC **and** the secret, seeded from the
  same credential CI already injects) → runner module. Seeding through ARM rather than the data plane
  is what makes it work while the vault is network-locked. Two guards matter: an **empty** credential
  must *skip* the write, never blank a live secret; and on a genuinely fresh env the Job write can
  still race **RBAC propagation**, so the provision step needs a retry (`dependsOn` orders resources,
  not role assignments).
- **Runner name collisions.** Use `RUNNER_NAME_PREFIX` (not `RUNNER_NAME`) so concurrently-scaled
  replicas register as distinct runners; a fixed name makes all-but-one loop forever on
  `Registration … was not found`. After changing a Job's env, **already-Running executions keep the
  old template** — stop them so KEDA respawns with the new one.
- **Runner egress cannot be NSG-allowlisted.** The GitHub Actions control plane (OIDC + runner
  broker, `*.actions.githubusercontent.com`) lives in vast, drifting Azure IP space that an NSG
  can't express. `restrictRunnerEgress=true` takes CI fully offline (federated-token fetch times
  out). Keep it **false**; the durable egress win is the pre-baked ACR runner image
  (`useAcrRunnerImage=true`). Real L7 lockdown = Azure Firewall **FQDN** rules (prototype ships
  dormant behind `deployRunnerFirewall`).
- **"0 runners" at idle is normal** (ephemeral runners deregister between jobs). The collision/expiry
  signature is workflows **stuck `queued`**, not an empty runner list. `completed/failure` with a
  `runner_name` set is a real workload failure, not a runner problem.
- **Smoke runs on the DEV runners**, so a rotation that only fixes the pilots leaves smoke blocked.
  The dev runner PAT is refreshed by a dev **reprovision**; a *scheduled* `deploy-dev` on an existing
  env **skips provision**, so force a `workflow_dispatch` (which always provisions) to push a fresh
  token without a manual paste.

---

## 4. Dev environment lifecycle (ephemeral comm-dev / gov-dev)

- **Resource-group existence is not deployment readiness.** A failed subscription deployment can
  create the dev RG and only part of APIM/register infrastructure. If later scheduled runs treat
  that RG as complete, smoke repeats misleading missing-key, missing-RBAC, 401, and 404 failures.
  The first daily `deploy-dev` schedule now always provisions. Phase 2 writes
  `deployDevStatus=complete` on the RG only after success; later schedules skip provisioning only
  when that marker exists. A partial deployment therefore repairs itself on the next schedule.

- **Nightly teardown → soft-delete tombstones block re-provision.** `az group delete` removes the RG,
  but **APIM**, **Cognitive Services** (Foundry/AOAI), and **Key Vault** soft-delete at
  *subscription* scope. azd's deterministic resource token regenerates the same names → collision
  (`ServiceAlreadyExistsInSoftDeletedState`, `FlagMustBeSetForRestore`, `vault … in deleted state`).
  Teardown captures names before delete and purges each tombstone; `deploy-dev` also **self-heals**
  by purging matching tombstones before provision.
- **A Failed-state *live* APIM also blocks** (not just tombstones). A `Failed` APIM (e.g. from an
  interrupted run or a transient VNet-injection `ActivationFailed`) can't be redeployed over —
  `az apim delete` it (a Failed APIM **hard**-deletes, no tombstone). `deploy-dev` self-heal deletes
  Failed-state APIMs before purging.
- **APIM VNet-injection `ActivationFailed` is region-side transient.** The same template provisions
  the other cloud green in the same run; the fix is a bounded provision **retry** (delete any
  Failed-state APIM between attempts). Persistent double-failures = a degraded region → wait for a
  later scheduled run.
- **Cold-start smoke flake:** the first gateway request after a from-scratch provision (discovery /
  `/models`) can time out (`HTTP 000`) while managed-identity→backend RBAC is still propagating and
  the backend is cold. Use a **patient retry** (many short attempts with backoff), not a single long
  timeout; later assertions pass because the retries absorbed the warm-up.

---

## 5. The Commercial Foundry backend (cross-cloud)

An opt-in **backend** that lets the **Government** gateway reach a **Commercial** Foundry endpoint
over the public internet. It is a **stable pilot→pilot** feature (Gov pilot consumes; Commercial
pilot provides the Foundry).

> **The parallel `/openai-commercial` route is retired** — the `commercial-models` sentinel now picks
> the commercial backend per-request on the default `/openai` route (and on `/anthropic`), so there
> is one base URL and one policy. Every lesson below is about the **backend and the cross-cloud path**
> and still applies unchanged; only the front door went away.

- **Cross-sovereign-cloud backend auth must use a client secret.** The "secretless"
  workload-identity-federation mode (`servicePrincipalFederated`) is **blocked** Gov→Commercial:
  Commercial Entra rejects a Government managed-identity token as a federated credential
  (`AADSTS700238` — an issuer from another sovereign cloud can't be a FIC issuer). Use
  `foundryCommercialAuthMode=servicePrincipal` (Commercial-tenant SP + client secret) or `apikey`.
  (Same-cloud cross-tenant federation *does* work.)
- **The caller token is never forwarded.** APIM validates the caller (subscription key or JWT),
  strips it, and mints a **separate** Commercial-tenant token via client-credentials, then calls the
  Commercial Foundry over HTTPS. A `502` on a commercial-backed request means the **backend token step
  or the backend itself** failed (`CommercialTokenAcquisitionFailed`/`…FederationFailed`) — not the
  caller key (that's `401`) and not the firewall (that's `403`).
- **Egress leaves the Gov VNet via the NAT gateway public IP**, which must be allowlisted on the
  Commercial Foundry's firewall. NSGs can't match FQDNs, so the APIM subnet NSG allows the Commercial
  Foundry **data endpoint + Commercial AAD login** CIDRs — refresh if they drift. Dev NAT IPs rotate
  on teardown, so a `403` on the commercial smoke assertion is a soft-fail on `-dev` (SKIP) and a real
  fail on pilots.
- **Recurring failure modes (all observed live):**
  - *Backend Foundry firewall reset to `PNA=Disabled`/empty allowlist* (e.g. after a backend
    redeploy) → every commercial call `502` (backend unreachable). Restore
    `PNA=Enabled` + `defaultAction=Deny` + allowlist the Gov NAT egress IP.
  - *Model deployed to the wrong Commercial account* → the backend points at one Foundry account; a
    model deployed to a *different* account (e.g. the commercial **dev** account) isn't reachable.
    Keep the pilot→pilot topology: deploy the model onto the account the Gov APIM
    `foundry-commercial-base-url` targets.
  - *Model missing from the sentinel* → with `commercialModels` empty (or the name not matching), the
    request silently goes to the **private** Foundry and 404s as an unknown deployment. Symptom looks
    like a missing model; cause is the sentinel. Check `commercial-models` before the backend.
  - *APIM commercial named values reset to placeholders* (`foundry-commercial-base-url =
    https://unset.invalid`, `auth-mode = servicePrincipalFederated`, tenant/client `unset`) → `502`.
    Root cause: a **local `azd provision` without the `COMMERCIAL_*` env vars** (empty `${…}` →
    Bicep defaults). Fix by re-running the **CI** gov-pilot deploy (re-substitutes from the env vars
    + secret; the CI param file already forces `authMode=servicePrincipal`). **Don't local-provision
    the gov pilot without the commercial vars set.** A preprovision guard
    (`scripts/check-provision-params.*`) now **hard-fails** a provision when
    `deployFoundryCommercial=true` but the `COMMERCIAL_*` values resolve empty/placeholder, so this
    wipe can't recur via the normal azd path (bypass: `SKIP_PROVISION_PARAM_CHECK=true`).
- **Never dispatch both pilot deploys at once — commercial first, then gov.** A commercial provision
  writes `publicNetworkAccess: Disabled` on the commercial Foundry and the **postprovision hook**
  (`allow-foundry-ingress-ips`, driven by the `FOUNDRY_PUBLIC_INGRESS_IPS` env variable) re-opens it
  moments later. Inside that window every gov-pilot call to the commercial backend fails with
  `403 "Public access is disabled. Please configure private endpoint."`, so a simultaneously
  dispatched gov smoke goes red on a perfectly healthy system. It self-heals — re-run the gov smoke
  alone with `gh workflow run smoke-test.yml -f env=gov-pilot`. Note also that the ingress IP is a
  repo *variable*, not a secret, so it appears in clear text in the Actions log.

- **APIM is internal VNet mode** — reachable only via its private IP from inside the VNet (P2S VPN or
  an in-VNet test VM / ephemeral ACI in `snet-aci`); its host does **not** resolve from a laptop.
  APIM **v2 tiers are not in Government** — use classic Developer/Premium (the GenAI policies work on
  classic).
- **Reachability triage:** APIM `provisioningState=Succeeded` + gateway timeout from *one* subnet ⇒
  suspect that subnet's NSG/DNS, not APIM. A **rule name can lie after a manual edit** — check the
  `access` field, not the name (an inverted `Allow-Out-VNet`→Deny blocks VM→APIM; an inverted
  `Deny-Out-Internet`→Allow silently leaves public egress open). Find recent changes via
  `az monitor activity-log list` ("Create or Update Security Rule").
- **Subnets are managed as child resources** in `network.bicep` (the VNet resource omits `subnets`),
  because an inline-subnets PUT is array-order-sensitive and reorders/recreates *in-use* subnets on
  redeploy (`InUseSubnetCannotBeDeleted`). Child subnets reconcile by name (`@batchSize(1)`). Some
  environments must set `pinSubnetPrivateOutbound=true` to pin the immutable
  `defaultOutboundAccess=false` and avoid a recreate.
- **Subkey proxy stable hostname:** VNet-injected ACI gets a dynamic private IP, so a private DNS
  zone (`byok.internal`) + an A record repointed at provision time gives Bearer-only clients a stable
  FQDN. The A record goes **stale if the platform recreates the ACI out-of-band** → manual repoint or
  a scheduled reconcile Job. Note: a **VNet-injected ACI cannot reach IMDS**, so an in-container
  `az login --identity` never works; run any token-needing reconciler as a **Container Apps** job
  (uses `IDENTITY_ENDPOINT`, not IMDS) — and note `az login --identity` doesn't work in ACA either
  (use the `IDENTITY_ENDPOINT` REST call directly).
- **The gateway cannot call itself (#128).** A policy `send-request` aimed at APIM's own gateway
  host gets **no response at all** — proven on gov-dev, where the instrumented classifier reported
  `classifier-fallback-noresp` while every other assertion in the same run passed, including chat
  calls to that same host from the in-VNet runner. Internal-mode APIM sits behind an internal load
  balancer, and a backend calling the ILB frontend it sits behind is the classic unsupported
  hairpin. Consequence: any design that re-enters the gateway to reuse its own pipeline (metering,
  throttling, transformation) is a dead end here — call the backend directly and account for it
  out of band. The failure is silent when `ignore-error="true"` is set, so instrument before
  concluding anything.

---

## 7. Identity & app auth

- **Backend auth is managed identity, not keys.** The APIM MI mints an Entra token per call
  (audience = the Cognitive Services endpoint) and reauthenticates to a PE-only backend
  (`disableLocalAuth=true`). The MI needs `Cognitive Services OpenAI User` on **every** backend
  account (each pool region) — a missing grant is a silent `401/403` from that member only. The
  wizard's "Web Service URL" field is cosmetic; routing is decided by the Backend entity the policy
  names.
- **Register app Easy Auth:** a CI deploy principal without Entra app-management rights (common in
  Government) can't create the app registration, so the setup step degrades (auth stays off).
  Durable fix: pre-create the app reg out-of-band as a tenant admin, store the **non-secret** client
  id + secret-KV-URI as GitHub env **Variables**, and let CI consume them. **Verify per-cloud azd env
  values resolve to the current cloud's resources** — azd env values are sticky across cloud
  switches and a commercial session can leave commercial IDs/URIs that pollute a later gov provision
  (a non-existent client id = broken login).
- **Egress-locked test VM can't render the Entra sign-in page:** the login *host* loads via the
  `AzureActiveDirectory` service tag, but the sign-in page's CDN assets are on Front Door / global
  convergence CDN ranges that a default-deny NSG blocks. Allow `AzureFrontDoor.Frontend` (tag) + the
  well-known convergence CDN CIDRs (same in both clouds). `AzureFrontDoor.FirstParty` is **not**
  usable in an NSG (only `.Frontend`/`.Backend` are).

---

## 8. Observability

- **Telemetry is workspace-based.** The App Insights components run in LogAnalytics ingestion mode,
  so data lands in workspace tables (`AppMetrics`, `AppRequests`, `AppDependencies`,
  `ApiManagementGatewayLogs`) — the classic `customMetrics`/`requests` tables are **empty**; don't
  query those. Custom metrics ingest ~1–2 min; platform metrics / gateway logs lag 5–15 min.
- **Empty Analytics on a pilot usually means an idle gateway, not a wiring bug.** Pilots get traffic
  only from real developer usage; smoke runs hit the *dev* APIMs. Confirm with classic ARM metrics
  (`TotalRequests`/`SuccessfulRequests`/…) before "fixing" the wiring, then send real traffic (a
  smoke run through the private gateway) to populate it.
- **Government: the laptop cannot query the LA/App Insights data plane** (the query service
  principals are disabled → `AADSTS500014` / silent empty + exit 1). ARM metrics
  (`az monitor metrics list`) **do** work. Verify Gov telemetry via the smoke run's own in-VNet
  assertion, not laptop KQL.
- **Gov Live Metrics needs the App Insights connection string** (not a bare instrumentation key): the
  QuickPulse client defaults to the Commercial live endpoint and can only learn the sovereign
  endpoint from the connection string. Classic ingestion is unaffected (why KQL/workbooks work while
  Live Metrics is dead).
- **APIM `emit-metric` allows at most 5 custom dimensions.** A 6th is accepted at deploy time but
  **silently never ingests**. Keep an existing metric's dimension schema stable and emit a *separate*
  metric (≤5 dims) for new dimensions rather than extending one past 5.
- **An API-scoped diagnostic needs `properties.metrics=true` to emit custom metrics.** Otherwise a
  gateway trace says *“No diagnostic settings have metric enabled. Metric emission skipped.”* Bicep
  sets this directly; the Terraform `azurerm_api_management_api_diagnostic` resource does **not**
  expose it — patch it via `azapi` (`azapi_update_resource` on the diagnostic's `properties.metrics`).
  Watch for this as a Bicep↔Terraform parity bug.

---

## 9. Azure Container Apps platform gotchas

- **Internal-only ACA ingress L7 routing** can be broken at the platform level (envoy returns a
  generic `404 "Azure Container App — Unavailable"` for *every* host, including fake ones). The
  validated workaround for "fully private" is **external env + `publicNetworkAccess=Disabled` +
  Private Endpoint**, with apps set `external: true` and the private DNS zone named exactly
  `privatelink.<region>.azurecontainerapps.io`.
- **External ACA ingress does not filter by client IP** — `ipSecurityRestrictions` sees the Azure
  regional proxy's source IP, not the client's. Use app-layer auth (Entra Easy Auth) or a
  Front Door/App Gateway in front; don't rely on ipSec for a client allowlist.
- **ACA Jobs validate the ACR image manifest at provision time** — `useAcrRunnerImage=true` fails
  the provision immediately if the tag is missing (`MANIFEST_UNKNOWN`). The image must exist in that
  env's ACR **before** the provision that creates the Job (hence two-phase bring-up for pilots; dev
  envs stay on the public image because their ACR is recreated empty nightly).
- **ACA caches KV secret references at the Job/App level** — after rotating a KV-backed secret,
  re-point the Job secret to the same `keyvaultref` (a control-plane call) to force immediate
  re-resolution; otherwise the stale value persists until the platform's periodic refresh.

---

## 10. Client integration

- **VS Code Chat (Custom Endpoint) and Copilot CLI BYOK** send the APIM subscription key in the
  `api-key` header and work without GitHub sign-in. A `502` surfaced in VS Code is a **gateway-side**
  failure (the "GitHub is experiencing a disruption" note is a generic red herring — BYOK traffic
  never touches GitHub). The request body model must exactly match a **deployment name** on the
  target backend account.
- **Credential refresh evidence (2026-09-17):** CLI 1.0.85 documents a per-request
  `COPILOT_PROVIDER_API_KEY_COMMAND`; the wrapper still mints on invocation and real expiry
  tests are pending. VS Code Custom Endpoint still needs a renewal integration. Direct
  Okta JWT and same-URL key OR JWT support are [planned](authentication.md), not deployed.
- **Header placement is not renewal or validation.** Foundry/AOAI JWT policies currently
  require `api-key`, including discovery and Responses follow-ups. The IntelliJ proxy
  rewrites Bearer to `api-key` but does not renew tokens. Never infer live auth mode from
  leftover products, or assume disabling subscription requirements preserves key validation.
- **IdP offboarding is not key revocation.** Revoke APIM subscriptions separately; locally
  validated JWTs may remain usable until expiry. Future Entra/Okta metrics must namespace
  stable user identities by issuer and must not collapse missing identity into `unknown`.
- **`GET /v1/models`** is served on the Foundry route for OpenAI-compatible clients (e.g. JetBrains
  AI Assistant) that probe it to connect. It's an operation-scoped policy that skips the inference
  body-parse. The AOAI and Commercial routes don't serve `/models` yet.
- **IntelliJ ACP (`--acp`) mode is gated on GitHub login even with BYOK** — an upstream limitation
  (the ACP server always advertises `copilot-login` and gates `session/new`), so fully-private
  BYOK-over-ACP is blocked. Login-free BYOK works via terminal `copilot -p` / interactive.
- **Header-less OpenAI-compatible providers** (URL + API-key only, sending `Authorization: Bearer`)
  can't use APIM subscription-key auth (that expects the key in `api-key`); use the subkey proxy
  (translates Bearer→`api-key`) or a client that sends the `api-key` header.
- **JetBrains AI Assistant (IntelliJ) BYOK ships as a standalone bolt-on** (`samples/intellij/standalone/`,
  Bicep **and** Terraform parity) that adds a dedicated `/intellij` API + policies to an *existing*
  customer APIM + Foundry plus a small static-IP nginx **proxy VM** (Bearer→`api-key`, forwards to the
  APIM private IP with the gateway Host/SNI so the VM needs no DNS). It **reuses** the customer's
  existing Foundry backend, product, and subscription keys — creating no managed identity, RBAC, or
  secret. An optional pre-baked Compute Gallery image covers air-gapped subnets where cloud-init
  can't `apt install`. JetBrains fans out several internal workloads (Core / instant helpers /
  completion / tool-calling); set Core to `auto` and pin the helpers to a small model so routing
  metrics reflect real prompts, not IDE chatter.
- **A downstream backend `401` can masquerade as an APIM key error.** If a route's policy injects a
  backend api-key named value that is empty/unset, the backend (Foundry/AOAI) returns its *own* `401`
  — body `"Access denied due to invalid subscription key or wrong API endpoint"` — which looks like an
  APIM subscription-key rejection but isn't. **Diagnose** by hitting a bogus path on the same API: a
  `404` means APIM validated your key fine (so the `401` on the real path is downstream backend
  auth), whereas a `401` on the bogus path would be the APIM key. Fix = populate the backend api-key
  named value (or wire MI). This bit the standalone bolt-on when the api-key param was left unset.

---

## 11. OpenAI `/v1` API surface

- **Implemented:** `POST /v1/{chat/completions,completions,embeddings,responses}`, `GET /v1/models`
  (dynamic deployment list + the `auto` sentinel — the only model-discovery surface), and the legacy
  `POST /openai/deployments/{deployment}/{chat/completions,completions,embeddings}` shape.
- **Adding an op is provision-only and proxy-agnostic:** a new APIM operation + a policy pair
  (`-subkey` validates the `api-key` natively; the `jwt` variant re-validates because the operation
  policy omits `<base/>`). **Body-less ops** (e.g. `GET`) must skip the inference body-parse
  `400`-guard. Reference implementation: the Foundry `/v1/models` operation + its policy pair.
- **GPT-5.6 and later require Responses for VS Code agent tool calls.** Chat Completions and
  function tools cannot be combined while reasoning is active; omitting `reasoning_effort` still
  fails because GPT-5.6 defaults to `medium`. Put these models on the VS Code `responses` provider.
  The documented chat fallback is top-level `reasoning_effort: "none"`, which disables reasoning;
  the VS Code picker only emits it when `none` is advertised and `reasoningEffortFormat` is
  `chat-completions`.
- **`/v1/models` is served on the Foundry route only** so far; the AOAI and Commercial routes need the
  analogous op added (the Commercial one must reuse that route's cross-tenant token auth, not MI).
- **Out of scope (intentional `404`s):** `/v1/files`, `/v1/batches`, `/v1/fine_tuning/*`,
  `/v1/assistants`, `/v1/threads*`, `/v1/vector_stores`, `/v1/realtime`. There is no `/v2`.

---

## 12. Editing the APIM policies

The `policies/*.xml` files are the highest-risk thing in the repo to edit: they are applied at
provision time, and a bad expression fails the deploy or — worse — degrades silently.

- **They are `rawxml`, not well-formed XML.** Expressions contain bare `<` (e.g. `As<JObject>`),
  so `[xml]`/strict parsers reject these files *at HEAD too*. A parse error is not evidence you
  broke something. The only real validation is APIM accepting the policy on provision.
- **APIM rejects `--` inside an XML comment.** Easy to introduce with an em-dash-style aside.
- **`resp.Body.As<JObject>()` CONSUMES the body.** If more than one expression reads the same
  response variable, every read must pass `preserveContent`: `As<JObject>(true)`. Otherwise the
  second read silently gets nothing — which looks like a backend problem, not a policy bug.
- **`emit-metric` allows at most 5 dimensions.** `copilot_byok_request` and
  `copilot_byok_auto_route` already use all 5. To add signal, encode it into an *existing*
  dimension's value (e.g. `classifier-fallback-http401`) and keep the value set bounded — it is
  metric cardinality.
- **`ignore-error="true"` plus a catch-all `try/catch` makes failures undiagnosable.** It
  flattens no-response / non-200 / timeout / parse failure into one indistinguishable value.
  Capture `resp == null` separately from `resp.StatusCode` *before* you need to debug it.
- **Four variants must stay in sync:** `byok-{foundry,aoai}-policy{,-subkey}.xml`. `validate.yml`
  enforces two pairings (wizard-vs-BYOK foundry, and AOAI jwt-vs-subkey) but not all of them.
- **Do not write smoke assertions that match a policy-emitted string exactly.** Making a value
  more specific once zeroed both counters and misreported as "the classifier never ran". Prefer
  `startswith`.
- **The gateway cannot call itself** — see §6. Rules out any re-entrant policy design.

To test a risky policy change without touching `main`: `deploy-dev.yml` only auto-runs on pushes
to `main`, but `gh workflow run deploy-dev.yml --ref <branch> -f envs=gov-dev` checks out that
branch and **always provisions** (provision is skipped only for `schedule` events on an existing
env). Pilots are manual-dispatch-only, so a branch can never reach them.
