# Delivery playbook & lessons learned — Gov BYOK Copilot engagements

> **Audience:** other account / delivery teams (DIB and similar regulated-cloud engagements)
> picking this repo up as a starting point. This is the "what we learned the hard way" companion
> to [architecture.md](architecture.md) — read this first to avoid re-discovering the same gaps,
> then use the architecture doc for the deep mechanics.

This solution (Copilot CLI / VS Code BYOK → private Azure OpenAI / Foundry through an internal
APIM AI gateway) is **reusable IP**. The infra (Bicep), policies, KQL, and wrapper scripts are
parameterized for both Commercial and Government, so a new engagement should be a
*configure-and-deploy*, not a *rebuild*. The notes below are the non-obvious lessons that aren't
visible from the code alone.

---

## 1. Reuse checklist (start here on a new engagement)

1. **Pick the cloud profile.** Copy `infra/main.parameters.gov.example.json` (Gov, the default)
   or `…commercial.example.json`, fill the `<PLACEHOLDER>` values. Cloud-specific endpoints
   (login authority, DNS zones, Cognitive Services audience) are already parameterized — don't
   hand-edit policies for the cloud.
2. **Choose the auth mode up front.** `subscriptionKey` (long-lived APIM key) vs `jwt` (Entra
   token). For an **unattended fleet** (e.g. 150–200 machines), prefer `subscriptionKey` — see
   §3. For true per-user identity, use `jwt` and accept the token-refresh constraint (§3).
3. **Confirm region/tier reality.** APIM **v2 tiers are not in Azure Government** — Gov uses the
   classic **Developer/Premium** tiers. The AI-gateway GenAI policies work on classic tiers, so
   this is fine; just don't design around a v2-only feature.
4. **Grant MI RBAC on every backend account** before first call (§2). A missing role surfaces as
   a silent 401/403 from one pool member, not an obvious config error.
5. **Use CI for pilots.** A local `azd provision` with incomplete environment values can reset
  named values or secrets to placeholders. Bootstrap once, then use `deploy.yml` and
  `deploy-dev.yml` so every deployment receives the complete environment contract.
6. **Validate all four environments.** Require pilot and dev smoke suites to pass, including
  Responses subresources and telemetry, before handing keys to developers.

---

## 2. Managed identity is the recommended APIM → Foundry/AOAI auth (not keys)

**Lesson:** the APIM "Import Azure AI Foundry/OpenAI" wizard wires the backend with an **API
key** by default. We deliberately use a **system-assigned managed identity + a Backend entity**
instead.

- The policy mints an Entra token (`authentication-managed-identity`, audience =
  `cognitiveservices.azure.<com|us>`) per call and reauthenticates to the backend with it. No
  key ever lives in APIM named values or on disk.
- The backend account runs `disableLocalAuth=true` + `publicNetworkAccess=Disabled` +
  Private-Endpoint-only. The wizard's key approach would force you to **re-enable local auth** on
  a PE-only account — a step backwards for a regulated threat model.
- **Gotcha:** MI auth only works if the APIM MI has `Cognitive Services OpenAI User` on **every**
  backend account (each region in a multi-region pool). Granted in `infra/modules/rbac.bicep`;
  if granted out-of-band, set `assignAoaiRbac=false`. A missing grant = silent 401/403 from that
  member only.
- **"Web Service URL" field is cosmetic.** The wizard populates the API's default backend URL,
  but the inbound policy's `set-backend-service backend-id="…"` **overrides it on every
  request**. Whether that field is blank or shows a fixed account URL is irrelevant — routing is
  decided by the **Backend entity** the policy names, which is what becomes a load-balanced
  **Pool** in multi-region. Don't let the field confuse a config review.

---

## 3. Credential lifetime — pick the auth mode to match the fleet

**Lesson:** neither the Copilot CLI nor VS Code BYOK refreshes a short-lived credential
in-session — the credential is read **once at process start** and reused for the session.

- **`jwt` mode:** Entra access tokens live ~60 min. In a long session the token expires
  mid-conversation and `validate-jwt` starts returning **401** hourly, with no in-CLI refresh.
  Workable for interactive single users (relaunch re-mints), painful for unattended fleets.
- **`subscriptionKey` mode (recommended for fleets):** a long-lived APIM subscription key,
  validated natively by APIM. No hourly 401. This is the pragmatic default for a
  150–200-machine rollout.
- The upstream gap is tracked in
  [docs/feature-request-byok-credential-refresh.md](feature-request-byok-credential-refresh.md)
  (a `credential_process`-style refresh hook). Until that ships, choose the mode deliberately —
  don't default to `jwt` for an unattended fleet.

---

## 4. Wizard-generated APIM policy gaps (and the fixes)

The raw wizard policy "works" but is quietly wrong for a streaming Copilot client. The minimal
fixes are shipped as [policies/wizard-foundry-policy-fixed.xml](../policies/wizard-foundry-policy-fixed.xml)
and its AOAI twin so a customer already on the wizard policy can adopt incrementally before
moving to the full split policy. The gaps:

| Gap | Symptom | Fix |
|---|---|---|
| **Token metric is silent on streaming** | App Insights dashboard empty even though calls succeed | `llm-emit-token-metric` only fires when the response carries `usage`; streamed replies omit it unless `stream_options.include_usage=true` is injected. We inject it for chat-completions. Better: emit a separate always-on inbound request counter so you're never fully blind. |
| **TPM limit too low** | First real request 429s | Wizard default `tokens-per-minute=10000`; a single Copilot request is routinely 5–15k tokens. Raise to ~200k as a ceiling. |
| **Reasoning models reject sampling params** | `400 unsupported_value` on `gpt-5`/`o1`/`o3`/`o4` | Strip `temperature`/`top_p`/`presence_penalty`/`frequency_penalty` for those model-name prefixes; remap `max_tokens` → `max_completion_tokens`. |
| **`/responses` not imported** | Newer VS Code (1.122+) Custom Endpoint clients fail | Add a `/responses` operation; route it to the account-root, versionless `/openai/v1/responses`. |
| **Copilot extension reaches native Responses** | `400 Unrecognized request argument supplied: snippy` | Strip the top-level `snippy` object at APIM; it is Copilot service metadata, not an OpenAI Responses parameter. Exercise this shape in smoke tests. |

**Gov-specific `api-version` trap (newer models):** the moment a client moves to a newer model
(e.g. `gpt-5.1`), two failures appear together and pull `api-version` in opposite directions:

- Drop `COPILOT_PROVIDER_AZURE_API_VERSION` and the CLI stops sending `api-version` → **404
  model not found**. Keep it set.
- The Responses API needs a *newer* dated preview than chat-completions, while Gov's
  chat-completions backend still needs the *older* `2024-09-01-preview` for the
  `stream_options.include_usage` inject to be recognized. Inject under the wrong version →
  `400 unknown parameter 'stream_options.include_usage'`.

This repo sidesteps both by rewriting Responses to the versionless `/openai/v1/responses` and
**stripping `api-version` entirely** there, so the dated version only ever applies to
chat-completions. If you keep Responses deployment-scoped instead, make the version
path-conditional — and **never mix the two shapes** (versionless rejects a dated version;
deployment-scoped requires one). Full detail:
[architecture.md → Responses route](architecture.md#responses-route-openaiv1responses).

---

## 5. Telemetry / KQL — what you actually get, and the Gov caveats

The gateway's value over "call Foundry directly" is **per-developer, per-model, attributable**
telemetry — the backend account only ever sees one caller (the APIM MI or one key) and cannot
break usage down by developer. Ready-made queries in [monitoring/kql](../monitoring/kql):

| Query | Answers |
|---|---|
| [tokens-per-developer.kql](../monitoring/kql/tokens-per-developer.kql) | token spend per developer (or per subscription key) |
| [tokens-per-model.kql](../monitoring/kql/tokens-per-model.kql) | token spend per model/deployment |
| [throttle-hits-per-developer.kql](../monitoring/kql/throttle-hits-per-developer.kql) | who is hitting which limit (burst / tokens / quota) |
| [requests-per-backend-region.kql](../monitoring/kql/requests-per-backend-region.kql) | pool member / region distribution |
| [error-rate.kql](../monitoring/kql/error-rate.kql) | gateway error rate over time |
| [custom-metrics-smoke.kql](../monitoring/kql/custom-metrics-smoke.kql) / [smoke-emit-metric.kql](../monitoring/kql/smoke-emit-metric.kql) | post-deploy "is telemetry flowing" check |

**`subscriptionKey`-mode reading:** the metric dimension *names* don't change between auth modes.
In `subscriptionKey` mode `developer_oid`/`developer_upn` carry the APIM **subscription
Id/Name** — read "developer" as "the subscription." Same dashboards, same queries.

**Gov caveats that look like bugs but aren't:**

- **App Insights query REST API is disabled in Gov** (`az monitor app-insights query` →
  `AADSTS500014`). Use the **portal Logs blade / workbook**, not the CLI query command.
- **Diagnostic setting must be `logAnalyticsDestinationType: 'Dedicated'`** or every KQL query
  returns 0 rows (the queries read the resource-specific `ApiManagementGatewayLogs` table, not
  the legacy `AzureDiagnostics`). `scripts/apply-diag-dedicated.ps1` patches an existing
  deployment.
- **Live Metrics blade is always empty** and **APIM Analytics blade is sparse** on low-traffic
  gateways — both are working as designed; use the Logs blade. See
  [architecture.md → What WON'T light up](architecture.md#what-wont-light-up--known-platform-limits).
- **Per-call token metrics for *streaming* traffic on newer models** are not available on Gov
  yet — it depends on two independent Microsoft timelines (Gov backend api-version parity **and**
  APIM learning to parse the Responses streaming usage event). Request counts and throttles are
  unaffected. See
  [architecture.md → two-clocks note](architecture.md#responses-route-openaiv1responses).

---

## 6. Content filter — don't ship the default policy to a Copilot env

**Lesson:** `Microsoft.DefaultV2` has **Prompt Shields jailbreak detection set to blocking**, and
VS Code Copilot's system prompts reliably trip it → `400 ResponsibleAIPolicyViolation`. This
happens **at the model account, not APIM** — auth is fine, the model rejected the prompt.

- Fix: a custom RAI policy with jailbreak **annotate-only** (`blocking:false, enabled:true`).
  Annotate-only is first-class and does **not** require the "modified content filter" approval
  (only *disabling* a shield or *loosening* a harm category does).
- Shipped as `scripts/content-filter.byok-coding.json`; the IaC default everywhere is
  `byok-coding`, not `Microsoft.DefaultV2`.

---

## 7. Known deployment friction (save the next team the debugging)

- **Keep one Azure cloud per terminal.** Use a separate `AZURE_CONFIG_DIR` and login for
  Commercial and Government. Never switch a pinned terminal across clouds. After PIM elevation,
  force a real logout/login; cached pre-elevation tokens can read resources but fail writes.
- **The first self-hosted runner is a bootstrap dependency.** Hosted runners are disabled in the
  EMU enterprise, so a target cloud cannot create its own pilot runner. Provision the first pilot
  locally or use the healthy pilot from the other cloud through `runnerLabel`.
- **Runner PAT expiry looks like an Azure scaling failure.** Jobs remain queued and KEDA creates
  no runners when the classic PAT expires. EMU caps its lifetime at roughly 7–8 days, so rotate
  weekly. Update the repo secret, both pilot Key Vault secrets, and the dev provisioning secret.
  A Key Vault write alone is insufficient for a running ACA Job: force the Job to re-resolve the
  secret reference.
- **Build the runner image before enabling it.** ACA Job provisioning validates the referenced
  ACR manifest immediately; flipping `useAcrRunnerImage=true` before the image exists fails the
  deployment.
- **Subscription-scope re-runs can hit settling races.** AOAI can return
  `AccountProvisioningStateInvalid`; APIM can return a transient bad-ETag `PreconditionFailed`.
  Wait for the live resource to reach `Succeeded`, then rerun the affected environment. Do not
  interrupt or overlap provision, teardown, and smoke.
- **Private-endpoint DNS zone naming is exact** — the auto-A-record registration only happens
  when the zone name matches Microsoft's recommended scheme. A wrong name creates the PE fine but
  registers no records.
- **Responses retrieval is eventually consistent.** A stored response can be created
  successfully and briefly return `404 Response ... not found` on retrieve. Use bounded retries;
  input-items and cancel succeeding confirms the APIM route is correct.
- **Stock Windows Server lacks client prerequisites.** Use Windows Server 2022 Datacenter Gen2,
  then install PowerShell 7, Node.js 22+, and Microsoft Visual C++ 2015–2022 Redistributable x64.
  Without the VC++ runtime, `copilot --version` works but interactive `copilot` exits; debug logs
  report that `cli-native.node` cannot be loaded.
- **Bastion local login is literal.** Use the bare local username (for example,
  `<LOCAL_ADMIN>`), not `.\<LOCAL_ADMIN>`. Prefer a keyboard-safe generated password because
  browser clipboard/keyboard-layout translation can corrupt special characters.
- **Developer SKU APIM has no SLA / zone redundancy** — fine for a pilot, switch to Premium for
  prod.
- **Test VM + Bastion are billable** — tear them down post-validation.

---

## TL;DR for a new account team

You are not starting from scratch. Copy a cloud parameter profile, pick `subscriptionKey` auth
for a fleet, grant MI RBAC on every backend, bootstrap the pilot runner, deploy through CI, set
the diagnostic destination to `Dedicated`, and run every smoke suite. The hard-won specifics —
runner credential lifecycle, cloud isolation, transient platform races, Responses consistency,
Windows prerequisites, wizard policy gaps, the Gov `api-version` interplay, telemetry limits,
and the content filter — are captured above so they don't have to be re-learned per engagement.

Once it's live, hand the infra/on-call team the
[Operations runbook](operations-runbook.md) — symptom-indexed incident triage, developer
onboarding/key rotation, limit tuning, and telemetry health checks for Day-2 operations.
