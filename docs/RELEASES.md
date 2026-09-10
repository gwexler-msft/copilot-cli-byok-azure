# Releases

Version history for the Copilot BYOK → private Azure OpenAI/Foundry gateway. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

- **MAJOR** — breaking change to the deployed contract (param removed/renamed, route/policy
  behaviour change that requires client or IaC changes).
- **MINOR** — backward-compatible capability (new route/op, new opt-in param, new script).
- **PATCH** — backward-compatible fix (policy/CI/docs fix, no new surface).

> The project had no git tags before `1.0.0`; that entry is a **retroactive baseline** grouping
> the foundational work (285 commits from 2026-05-30). Per-commit detail lives in `git log`.
> From `1.1.0` onward, each change is recorded under its version as it lands.

## [Unreleased]

### Fixed
- Strip Copilot's top-level `snippy` service extension before forwarding Chat Completions or
  Responses requests to native Azure OpenAI / Foundry endpoints, which reject it as an
  unrecognized argument. The Responses auto-route smoke probe now exercises this client shape.

## [2.2.0] — 2026-08-12

**Sign-out that actually signs you out, and a register Key Vault that is private everywhere.** The
sign-out shipped in 2.1.0 was wrong in ways only a browser could reveal — it took three falsified
attempts to find the real causes. Alongside it, an audit found the register vaults in three
different states across four environments, including one pilot vault with a public data plane.

### Added
- **Sign-out no longer asks which account.** The app now drives the sign-out itself against Entra's
  end-session endpoint with `logout_hint`, sourced from the `login_hint` optional claim that
  `setup-register-entra` now requests. Entra only suppresses the account picker when given that
  claim's value; the docs are explicit that a UPN is not a valid substitute.

### Changed
- **`registerVnetIntegrated` is now set on all four environments**
  ([#137](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/137)) — the register
  Key Vault gets a private endpoint and the register Container Apps environment is VNet-integrated.
  It had never been set in any parameter file, so the pilots were **not reproducible from the
  committed template**: the working one had been built out-of-band with the flag on, and rebuilding
  it from `main` would silently have dropped both.
- **The dev register apps are private**, matching the pilots. They had run with a public edge since
  2026-06-22 while both pilots were in-VNet only. No VM or Bastion was added to dev — that stack is
  ~$210/mo per environment and stays a pilots-only, on-demand flip.
- **`prompt=login` removed.** Added in 2.1.0 on the theory that a live Entra SSO session would
  otherwise re-authenticate silently. A/B testing across two clouds showed sign-out already sticks
  without it, and on a device holding a Primary Refresh Token it is satisfied by the PRT — so it
  never covered the one case it was added for, while costing a credential prompt on every sign-in.
- **`deploy-dev` runs one scheduled provision a day instead of four.** The through-the-day smoke
  moved to `smoke-test.yml`, which has its own concurrency group and never touches the environment
  lifecycle.

### Fixed
- **Sign-out left the session alive.** `post_logout_redirect_uri` was built from `request.Scheme`,
  and the app has no forwarded-headers middleware — TLS terminates at the ingress, so it read
  `http`. Entra rejects a redirect URI that does not match the registered `https` one and stops on
  its own generic "you are signed out" page, so the browser never reached `/.auth/logout`, the Easy
  Auth cookie was never cleared, and the next visit found a live session. The page *said* signed
  out; the session was not.
- **Entra showed an empty "pick an account to sign out of" prompt.** Sign-out reached Entra twice:
  once with the hint, then again — hint-less — via Easy Auth's own logout after the redirect back.
  By then no session remained, so the picker had nothing to list. The two halves are now decoupled:
  the browser clears the cookie directly, then visits Entra exactly once. Cookie clearing no longer
  depends on a redirect returning to us, which is what the scheme bug had silently broken.
- **A pilot register Key Vault was reachable from the internet**, holding the Easy Auth client
  secret ([#137](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/137)). RBAC
  still gated it, but the network control its counterpart had was absent. One root cause produced
  three different symptoms: on Gov the template's request for a public vault was honoured; on
  Commercial a modify-effect policy rewrote it to `Disabled`, and with no private endpoint that left
  a vault **unreachable by anything** — including the app's own managed identity, which is why a dev
  environment could not provision.
- **`setup-register-entra` could not complete against a locked vault** and misreported why. It now
  writes the secret through an ARM deployment (a trusted service, so it lands while the vault stays
  locked), distinguishes a network block from an authorization failure instead of blaming "role not
  propagated" and burning 60s of retries, and no longer hangs on `azd env set` when no azd
  environment is selected — the exact path its own degrade message tells an admin to run by hand.

### Security
- The gov pilot register Key Vault's public data plane is closed; all four register vaults are now
  `publicNetworkAccess=Disabled` with `defaultAction=Deny` and exactly one private endpoint.
- The dev register apps — which mint APIM subscription keys — are no longer internet-facing.

### Operational notes
- **Recreating a register environment needs a specific order**, because `infrastructureSubnetId` is
  immutable on an existing managed environment and an incremental deployment does not roll back:
  delete the container app, delete the environment, **delete the environment's private endpoint**,
  deploy, then re-point the Easy Auth redirect URI. Skipping the third step blocks the redeploy; the
  environment private endpoint only exists where `registerPrivateNetworking` is true, so a procedure
  validated on dev does not exercise the pilots' shape.
- **Do not re-run `setup-register-entra` merely to refresh an app registration.** It cannot read a
  locked vault, concludes the secret is absent, mints a replacement, and the credential reset
  invalidates the one the running app is still using. Patch the registration directly instead.

### Known limitations
- On a device holding an Entra Primary Refresh Token, an explicit sign-in after sign-out completes
  without re-entering credentials. The app guarantees it ends the session and never silently resumes
  one; forcing re-credentialing is a Conditional Access sign-in-frequency decision.

## [2.1.0] — 2026-08-07

**Make `auto` actually save money, and make the gateway's own numbers trustworthy.** The default
tier could not sustain a single VS Code session, auto-routing never reached the cheap model, and the
classifier's spend was invisible. All three are fixed and proven on both pilots by their own smoke
runs. Nothing here is breaking; the pilots picked it up on the 2026-08-06 deploy.

### Added
- **Responses API stateful sub-resources** ([#110](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/110))
  — `GET`/`DELETE /v1/responses/{id}`, `POST .../cancel`, `GET .../input_items`, as four
  operation-scoped policy pairs that skip the API-level body-parse guard (they are body-less), so
  background and resumable Responses turns work.
- **`copilot_byok_classifier_tokens`** ([#128](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/128))
  — the auto-route classifier calls the model directly, so its tokens never traversed the pipeline
  and `llm-emit-token-metric` could not see them. They are now attributed per developer. Roughly
  ~300–1000 tokens per *ambiguous* request against a 13–15k main request.
- **Classifier failure diagnostics.** A failed classifier used to collapse every cause into one
  `classifier-fallback`. The reason is now encoded in the same dimension —
  `-noresp` / `-http401` / `-parse` / `-empty` — because `emit-metric` caps at five dimensions and
  that metric already used all five.
- **Register app**: the VS Code model list is rendered from deployment config rather than a static
  file, the installers preflight PowerShell/Node/Copilot CLI, and a test project covers the
  per-developer artifacts the app hands out.
- **Smoke**: asserts the classifier actually decides (a silent fallback still returns 200, so it was
  indistinguishable from success), and fails explicitly when a `429` came from the model deployment
  rather than the `llm-token-limit` policy.
- **`validate` runs on push to `main`**, not only on pull requests
  ([#135](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/135)) — with the admin
  bypass in use, every static gate had been silently skipped since 2026-07-23.
- **Sign-out and a session timeout on the register app**
  ([#136](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/136)). The page had
  neither, while displaying a live APIM subscription key in plaintext — shown once, then resident in
  the DOM for as long as the tab stayed open, so an unattended machine leaked the credential as well
  as the session. Two layers, doing different jobs:
  - **Enforcement:** authConfig `login.cookieExpiration` (`convention: FixedTime`,
    `easyAuthSessionLifetime`, default 60 min) — an absolute cap the browser cannot bypass.
  - **UX:** an in-page idle timer (`sessionIdleTimeoutMinutes`, default 15) that warns, then wipes
    the key from the DOM and redirects to `/.auth/logout`. It clears the key *before* navigating,
    because the redirect is not instant and the key element is the sensitive artifact.

  The two durations are deliberately **not** equal: matching them would sign out a developer who is
  actively working, mid-flow. Idle measures inactivity, the cap measures total session age.

### Changed
- **`byok-standard` 20,000 → 100,000 TPM** ([#130](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/130)).
  VS Code packs editor context into every request (13–15k tokens), so the old ceiling `429`d on the
  second turn within a minute and the default tier was unusable for interactive work. A tier TPM is
  bounded on both sides: it must also stay **under** the environment's `modelCapacity`, or APIM stops
  being the throttle and the model deployment becomes it. The dev environments therefore stay at
  20,000 against their deliberately tiny 25k backend.
- **Auto-route defaults `500/200` → `2000/1500`, classifier on in all four environments**
  ([#133](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/133)). Commercial ran
  length-only routing, so `auto` was effectively "always full model" there. The bands and the
  classifier are **one decision**: with the classifier off, a wider ambiguous band just sends traffic
  to the full model. `autoRouteClassifierEnabled` still defaults to `false` because it costs an extra
  call and needs a mini deployment; the pilots opt in explicitly.
- **The BYOK key step is now part of the main register flow**
  ([#129](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/129)). The key is still
  inlined into `chatLanguageModels.json`, but VS Code keeps a per-provider key in **secret storage**
  and sends **that** in preference to the file, so a key left from an earlier setup silently wins and
  APIM answers *"invalid subscription key"* against a config that looks perfectly correct. The
  register UI, both installers and the samples now say so up front rather than burying it in
  troubleshooting, and spell out the diagnostic: *invalid* means a key was sent and matched nothing;
  *missing* means none was sent at all.
  **Action for developers:** after installing, set the key via *Chat: Manage Language Models* →
  gear icon — especially if you have used the provider before.

  > VS Code's documented `"apiKey": "${input:...}"` form was shipped briefly and **reverted**: it does
  > not resolve in `chatLanguageModels.json`. Verified 2026-08-07 against gov-pilot — no prompt
  > appeared, VS Code sent the literal token, and the gateway rejected it. The docs recommend it and
  > show it in two Custom Endpoint examples, so this is a documentation/behaviour mismatch rather than
  > a configuration error on our side.
- **`/anthropic` enabled on both pilots** (the route shipped in 2.0.0; this turns it on).

### Fixed
- **`GatewayLogs` were never enabled.** The diagnostic setting used `categoryGroup: allLogs`, and
  `GatewayLogs` belongs to no category group, so naming it explicitly was the only way to get any.
- **The locked-down test VM could not reach Azure Monitor**, and the observability probe unrolled a
  single-row KQL result into characters.
- **Register app: JSON escaping silently shipped an unfilled template.** `JsonNode.ToJsonString`
  escapes `<`/`>` to `\u003C`, so the `<APIM_HOSTNAME>` substitution matched nothing.
- **The installer never set `COPILOT_MODEL`**, so the CLI refused to start against a BYOK provider.
- **PowerShell/bash helpers are pure ASCII.** A BOM alone was not enough — copying a script through
  the clipboard strips it, and the file then fails to parse on a stock Windows VM.

### Security
- Removed the last committed directory IDs, resource suffixes and real identifiers from samples and
  help text, and widened the scratch-script ignore rule so local helpers cannot be committed.
- The register app no longer leaves a session (and an on-screen subscription key) open indefinitely
  — see the sign-out / session-timeout entry above (#136).

### Operational notes
- **Never dispatch both pilot deploys at once — commercial first, then gov.** A commercial provision
  writes `publicNetworkAccess: Disabled` on the Commercial Foundry and the postprovision hook
  re-opens it moments later; inside that window every gov-pilot call to the commercial backend fails
  `403 "Public access is disabled"`. Dispatching both together therefore fails the gov smoke on a
  perfectly healthy system. It self-heals — re-run with
  `gh workflow run smoke-test.yml -f env=gov-pilot`. Recorded in
  [operations-lessons.md](operations-lessons.md) §5.

### Known limitations
- **Classifier tokens can be attributed but not enforced.** Making them count against a developer's
  tier TPM would require the gateway to call itself, which is impossible in internal VNet mode: APIM
  sits behind an internal load balancer and a backend cannot call the ILB frontend it sits behind
  (proven on gov-dev — the self-call returned no response at all while every other assertion passed).
  Recorded in [operations-lessons.md](operations-lessons.md) §6, since it rules out any re-entrant
  policy design, not just this one.

## [2.0.0] — 2026-08-01

**One standard path; the gateway picks the backend under the wire.** The parallel
`/openai-commercial` route and the Claude streaming sidecar are gone. Commercial models are reached
on the **default `/openai` route** via the `commercial-models` sentinel
([#118](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/118)), and
Anthropic-speaking clients get a **native `/anthropic` route** instead of a translation layer.

> ⚠️ **Breaking.** Any client whose `COPILOT_PROVIDER_BASE_URL` ends in `/openai-commercial` must
> drop that suffix and use `/openai`, and every model it was reaching must be listed in
> `commercialModels`. Four parameters are removed (below). The commercial Foundry **backend** is
> unchanged — same account, same cross-tenant SP token, same NAT egress and firewall allowlist.

### Added
- **Native Anthropic route `/anthropic`** (opt-in, `deployAnthropicRoute=true`): a separate APIM API
  exposing `POST /v1/messages` in the native Anthropic Messages wire format, credential in the
  **`x-api-key`** header. It exists *only* because APIM validates the subscription key from the
  header **declared on the API before any policy runs**, and an API can declare only one such header
  — so a `COPILOT_PROVIDER_TYPE=anthropic` client cannot authenticate against `/openai` no matter
  what the policy does. It is **not** a second backend and **not** a second credential: same
  subscription key, same product tier, same quotas and telemetry as `/openai`, and the backend is
  still chosen by the `commercial-models` sentinel. This is what makes `type=anthropic` clients
  meterable per developer key.
- **Typed `400 WireFormatMismatch` on `/openai`** when an Anthropic model is requested. Instead of
  translating, the gateway names the fix (set `COPILOT_PROVIDER_TYPE=anthropic` and use the
  `/anthropic` route). The symmetric guard on `/anthropic` refuses an OpenAI-shaped body the same
  way. The principle, now explicit: **the gateway validates and explains — it never silently
  reshapes a request.** This replaces the OpenAI→Anthropic translation shim
  ([#116](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/116)).

### Removed
- **(BREAKING) The `/openai-commercial` route.** Its API module
  (`infra/modules/apim-foundry-commercial-api.bicep`), its four policy files
  (`policies/byok-foundry-commercial-*.xml`) and `infra/overlay-commercial-route.bicep` are deleted.
  The route was unreachable from the client it was built for — the Copilot CLI's `azure` provider
  **discards any path** on `COPILOT_PROVIDER_BASE_URL` and always calls `/openai` — and the sentinel
  reaches the same backend on the route the CLI *can* use, which also collapses a duplicated policy
  that had to be kept in lockstep (six route policies became four).
  **Migration:** use `https://<gateway>/openai` and list the models in `commercialModels`.
- **The Claude streaming sidecar** ([#117](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/117))
  — the `anthropic-stream-proxy` ACI at `claude-proxy.byok.internal`, its ACI module and its image
  directory. It existed only to reshape a stream that the in-policy shim had to buffer; with the
  native `/anthropic` passthrough there is nothing to reshape, and **APIM relays SSE unbuffered**, so
  token-by-token Claude works with no extra hop, image bake or private-DNS dependency.
- **Cross-surface translation** ([#123](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/123))
  — the `byok-translate-inbound` / `byok-translate-outbound` policy fragments and the
  `translate-unsupported-surface` named value. Same reason: a reshaped request is a *different*
  request (different token accounting, different content-filter surface). Surface **validation**
  ([#120](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/120)) stays — the typed
  `400 UnsupportedApiTypeForModel` still names the surfaces a model does support.
- **Parameters removed:** `foundryCommercialApiName`, `foundryCommercialApiPath`,
  `addCommercialToProductTiers`, `anthropicStreamProxyImageTag` (plus
  `translateUnsupportedSurface`). Leaving any of them in a param file will fail the provision.

### Fixed
- **The follow-up provision no longer reverts the register app image to the .NET sample.** The
  two-phase bring-up runs `azd provision` → `azd deploy register` → `azd provision`; `registerAppImage`
  defaulted to the sample and CI never passed the real tag, so phase 2 silently undid the deploy
  (symptom: `register-auth` 404s, because the sample image has no `/api/register` route). The param
  now defaults to empty with a fallback, all four CI param files pass `${REGISTER_APP_IMAGE}`, and
  the deploy step hands the tag it just pushed back to phase 2.

### Notes
- **The commercial backend is unaffected.** `deployFoundryCommercial`, the `foundryCommercial*`
  settings, the cross-tenant service-principal token mint, the NAT egress path and the Foundry
  firewall allowlist all behave exactly as before — only the front door changed. See
  [commercial-foundry-route.md](commercial-foundry-route.md), whose *Retired* section records what
  went and why.
- `commercialModels` is the switch that matters: with `deployFoundryCommercial=true` but an empty
  sentinel, every request still lands on the private Foundry.

## [1.4.0] — 2026-07-25

Streamed requests are now **metered**. Token metrics move from a hand-rolled policy pair to APIM's
built-in `llm-emit-token-metric` ([#126](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/126)).

> ⚠️ **Dashboard-breaking.** The token metric **names change**. Anything querying
> `copilot_byok_prompt_tokens` / `copilot_byok_completion_tokens` must move to `Prompt Tokens` /
> `Completion Tokens` / `Total Tokens`. No client or IaC change is required, which is why this is a
> MINOR rather than MAJOR bump — but saved queries and custom workbooks **will go blank** until
> updated. The queries in `monitoring/kql/` are already migrated.

### Fixed
- **Streamed requests emitted no token metrics at all.** The outbound `emit-metric` pair read
  `context.Response.Body`, which only works for a JSON body — so it never fired for
  `text/event-stream`. Because Copilot CLI and VS Code stream by default, **most real traffic was
  unmetered** and token/cost dashboards materially undercounted usage. The built-in
  `llm-emit-token-metric` (inbound) captures usage at the platform level for streaming and
  non-streaming alike.

### Added
- **Richer token breakdown**, free with the built-in policy: alongside `Prompt Tokens` /
  `Completion Tokens` / `Total Tokens` it reports `Prompt Cached Tokens`,
  `Completion Reasoning Tokens`, and audio / prediction variants. `Completion Reasoning Tokens`
  matters for the gpt-5.x models; `Prompt Cached Tokens` improves cost attribution, since cached
  input bills at a lower rate.
- **Smoke assertion `streaming-token-metrics`** — sends a streaming call on **both**
  `chat/completions` and `/responses`, confirms each genuinely streamed, then asserts the built-in
  metrics counted them **and** the legacy pair counted zero. A two-sided regression guard, so either
  half breaking fails the build.

### Changed
- Custom dimensions are preserved (`developer_oid`, `developer_upn`, `deployment_name`, `backend`),
  so per-developer and per-model attribution is unchanged.
- `copilot_byok_request` / `_auto_route` / `_throttled` are untouched.

### Notes / limits
- **Anthropic carve-out.** `llm-emit-token-metric` supports the Anthropic Messages schema only on
  APIM **v2 tiers**, and v2 is unavailable in Azure Government. The hand-rolled pair is therefore
  retained for **Anthropic requests only**, so Claude traffic stays metered without double-counting
  OpenAI traffic. A *streaming* native `/v1/messages` call remains unmetered until that route can run
  on v2.
- `samples/intellij/standalone/` still uses the old pattern; it is a self-contained sample with its
  own gateway and was intentionally left alone.

### Validated
- Dev, both clouds: **10 PASS / 0 FAIL** each. `streaming-token-metrics` reports 6 token
  measurements (two streamed surfaces × three metrics) with the legacy pair at zero; the
  `emit-metric` assertion passes against the migrated KQL.
- The policy imports cleanly on **classic** tiers in Commercial *and* Government — the main risk,
  since Government has no v2 tiers and APIM validates policy at apply time.

## [1.3.0] — 2026-07-23

Non-streaming **cross-surface translation** — Phase 3 of the adaptive multi-type routing epic
([#119](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/119) /
[#123](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/123)). Opt-in, default off.

### Added
- **On-the-fly surface translation in all six route policies** (`foundry` / `aoai` / `commercial` ×
  subscription-key / JWT). When enabled, a request whose surface the resolved model does **not**
  support is transparently reshaped onto a supported surface instead of the Phase 2
  `UnsupportedApiTypeForModel` reject: `chat/completions` ⇄ `responses` (`messages`⇄`input`,
  `max_tokens`/`max_completion_tokens`⇄`max_output_tokens`, `reasoning_effort`⇄`reasoning.effort`,
  usage-token remap). The backend is called on the surface it supports and the response is reshaped
  back to the surface the client asked for.
- **Two shared APIM policy fragments** `byok-translate-inbound` / `byok-translate-outbound`
  (`policies/fragments/`), included by every route policy. The outbound reshape runs **after** the
  usage-metric emit, so token metrics read the model's native usage.
- **New opt-in named value** `translate-unsupported-surface` (default `false`) + Bicep param
  `translateUnsupportedSurface`. Translation is **strictly inert** unless the flag is `true`.
- **Smoke assertion** `translation` (`scripts/smoke-test.*`): data-driven — when the flag is on and a
  single-surface model exists it validates **both** directions (chat→responses and responses→chat)
  end to end; SKIPs (stays green) when the flag is off or every model supports both surfaces.

### Notes / limits
- **Streaming is not translated** — a streaming request to an unsupported surface still falls back to
  the Phase 2 typed 400; the streaming transcoder is Phase 4
  ([#121](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/121)).
- **`chat` ⇄ `messages`** (Anthropic) stays with the existing commercial-route shim
  ([#116](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/116)); this phase covers
  `chat/completions` ⇄ `responses`. _(Superseded in 2.0.0: the shim and this phase's translation were
  both removed in favour of the native `/anthropic` route and a typed `400 WireFormatMismatch`.)_

### Validated
- Live on both pilots via a temporary single-surface capability-map override (then restored): both
  directions reshaped end to end with real content returned — comm-pilot **13 PASS / 0 FAIL**,
  gov-pilot **17 PASS / 0 FAIL** (`translation-chat2responses` + `translation-responses2chat`).
  Default-off behaviour confirmed inert (translation SKIPs) on both.

## [1.2.0] — 2026-07-23

Model API-type **validation** — Phase 2 of the adaptive multi-type routing epic
([#119](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/119) /
[#120](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/120)), plus the automation
that closes Phase 1 ([#122](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/122)).

### Added
- **Surface validation in all six route policies** (`foundry` / `aoai` / `commercial` ×
  subscription-key / JWT). A request whose API surface (`aoaiOp`; Anthropic `messages` on the
  commercial route) the resolved model does **not** support — per the discovered `{{*-model-types}}`
  map — is rejected before backend token minting with a typed **HTTP 400 `UnsupportedApiTypeForModel`**
  that names the model, the requested surface, and the surfaces it does support. **Strictly inert**
  when the map is `{}` (default), the model is absent, or the map fails to parse — never blocks in
  those cases.
- **CI discovery workflow** `.github/workflows/discover-model-types.yml`. Manual, per-env, self-hosted
  (in-VNet) run that resolves a dev subscription key via ARM `listSecrets`, probes the gateway with
  `scripts/discover-model-types.*`, and opens a PR updating that env's CI param file with the probed
  `model → [types]` map (authoritative; a provision applies the named values). The key is read from a
  masked step output and never echoed.
- **Smoke assertion** `unsupported-surface` (`scripts/smoke-test.*`): once a map is populated, an
  embeddings call on a chat-only model must return `400 UnsupportedApiTypeForModel`; SKIPs (stays
  green) on envs without a map.
- **Capability maps populated** for both pilots (comm-pilot, gov-pilot) via the discovery workflow.

### Fixed
- **Probe false-negative**: the chat/completions probe sent `max_tokens`, which gpt-5.x rejects (it
  requires `max_completion_tokens`) → chat-capable models were mis-recorded as `responses`-only. The
  probe now sends `max_completion_tokens`.
- **Malformed error body**: the `UnsupportedApiTypeForModel` `message` embedded the raw supported-types
  JSON array with unescaped quotes, producing invalid JSON that clients (and tooling) could not parse.
  The human-readable message now uses a quote-free comma list; the raw array remains in the
  machine-readable `supported_types` field.

### Validated
- Live smoke on both pilots green with the new assertion: comm-pilot **11 PASS / 0 FAIL**, gov-pilot
  **15 PASS / 0 FAIL** — `unsupported-surface` returns the typed 400 with a valid JSON body.

### Notes
- On-the-fly cross-surface translation remains Phase 3
  ([#123](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/123)); the streaming
  transcoder is Phase 4 ([#121](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/121)).

## [1.1.0] — 2026-07-22

Model API-type discovery — Phase 1 of the adaptive multi-type routing epic
([#119](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/119) /
[#122](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/122)).

### Added
- **Per-route model→API-type capability map.** New APIM named values `foundry-model-types`
  (`/openai`), `aoai-model-types` (`/aoai`), and `foundry-commercial-model-types`
  (`/openai-commercial` — since 2.0.0 read by the `/anthropic` route), each holding a compact JSON
  map of every deployed model to the API surfaces it supports (`chat/completions`, `completions`,
  `embeddings`, `responses`, Anthropic `messages`). Inert `{}` default — no behaviour change until
  populated.
- **Discovery script** `scripts/discover-model-types.ps1` + `.sh` (parity). Hybrid discovery:
  enumerates `/v1/models` per route, then **probes** each candidate surface through the gateway
  (`/v1/models` exposes no `responses` capability flag, so surfaces must be probed). Writes the
  map into the committed CI param files (authoritative source; a provision applies the named
  value). The subscription key is read from an env var and never echoed or logged.
- **Bicep params** `foundryModelTypes`, `aoaiModelTypes`, `foundryCommercialModelTypes` threaded
  through `main.bicep` → `apim-named-values.bicep` (commercial gated on `deployFoundryCommercial`).

### Docs
- `docs/architecture.md` → new "Model API-type discovery (capability map)" subsection under
  *Wire format*.
- Added `docs/RELEASES.md` (this file) and `docs/ROADMAP.md`.

### Notes
- Storage + discovery only. Policy enforcement (validate the requested surface against the map and
  return a typed error on mismatch) lands in Phase 2
  ([#120](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/120)); on-the-fly
  translation in Phase 3 ([#123](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/123)).

## [1.0.0] — 2026-07-21 (retroactive baseline)

The foundational BYOK gateway: a customer-owned, private Azure OpenAI / Microsoft Foundry
account fronted by an **internal-VNet Azure API Management AI gateway**, parameterized for both
**Azure Commercial** and **Azure Government** from one Bicep/azd codebase.

### Gateway & routing
- Internal-VNet APIM (classic Developer SKU) with system-assigned managed identity; GenAI
  policies: per-developer credential validation (subscription key **or** Entra JWT), token-rate
  limiting, per-developer/per-model/backend token-metric emission, inbound credential stripping,
  MI reauth to the backend.
- Routes: default `/openai` (Foundry), `/aoai` (legacy AOAI), and `/openai-commercial`
  (cross-cloud commercial Foundry) — _`/openai-commercial` retired in 2.0.0; the commercial backend
  is now selected on `/openai` by the `commercial-models` sentinel._ OpenAI-compatible `/v1/*` short
  paths **and** Azure-native deployment-scoped paths; `GET /v1/models` for client discovery
  ([#97](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/97)).
- **Responses API** support (`/v1/responses` → account-root, versionless rewrite) alongside
  chat/completions/completions/embeddings.
- **Auto-routing**: sentinel model (`auto`/`byok-auto`) tiers requests to a mini/full deployment
  with an optional classifier.
- **Anthropic / Claude** on the commercial route
  ([#116](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/116)): OpenAI↔Anthropic
  shim + native `/v1/messages`, plus a streaming SSE transcoder sidecar
  ([#117](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/117)).
- **`commercialModels`** cross-cloud routing via the default `/openai` policy so the Copilot CLI
  can reach commercial-only models
  ([#118](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/118)).

### Infrastructure
- Subscription-scoped `main.bicep` creates the RG and full topology: VNet + subnets (child
  resources), Private Endpoints, P2S VPN gateway, APIM, Foundry/AOAI accounts
  (`publicNetworkAccess=Disabled`, `disableLocalAuth=true`), Log Analytics + Application Insights.
- Cloud parameterization (Commercial vs Government endpoints, DNS zones, audiences, authorities).
- Managed-identity backend auth + commercial cross-tenant token federation (secretless default).

### Delivery & clients
- CI/CD via GitHub Actions on **self-hosted ACA Job runners** (EMU enterprise; hosted runners
  disabled), `deploy.yml` (pilots) + `deploy-dev.yml` (dev), post-deploy smoke tests.
- Self-serve developer onboarding **register app** (`deployRegisterApp=true`).
- Client samples: VS Code 1.122 Custom Endpoint, IntelliJ/JetBrains (Continue + AI Assistant),
  standalone IntelliJ bolt-on.
- Observability: workspace-based KQL for tokens-per-dev, tokens-per-model, throttle-hits.
- Sanitized delivery playbooks: `docs/lessons-learned.md`, `docs/operations-lessons.md`,
  `docs/operations-runbook.md`.

[Unreleased]: https://github.com/gwexler_microsoft/copilot-cli-byok-azure/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/gwexler_microsoft/copilot-cli-byok-azure/releases/tag/v1.1.0
[1.0.0]: https://github.com/gwexler_microsoft/copilot-cli-byok-azure/releases/tag/v1.0.0
