# Copilot instructions — Copilot BYOK → private Azure OpenAI/Foundry gateway

This repo delivers **Bring-Your-Own-Key (BYOK)** for GitHub Copilot CLI / VS Code Chat routed to a
**private Azure OpenAI / Microsoft Foundry** backend through an **internal (VNet) Azure API
Management** AI gateway. It targets **both Azure Commercial and Azure Government** from one
parameterized Bicep/azd codebase. Treat it as reusable IP: a new engagement should be
*configure-and-deploy*, not a rebuild.

Read [docs/architecture.md](../docs/architecture.md) for the system design,
[docs/lessons-learned.md](../docs/lessons-learned.md) for delivery guidance, and
[docs/operations-lessons.md](../docs/operations-lessons.md) for the hard-won operational gotchas
(this file is the quick-reference; that doc is the detail).

## Golden rules

- **Never commit identifiable or secret values.** No tenant/subscription/client/object IDs, no
  public/NAT IPs or internal CIDRs, no resource suffixes/account names/FQDNs, no emails, no PATs or
  keys. Use placeholders: `<TENANT_ID>`, `<SUBSCRIPTION_ID>`, `<CLIENT_ID>`, `<NAT_EGRESS_IP>`,
  `<CIDR>`, `<suffix>`, `<PUBLISHER_EMAIL>`, `<OWNER>/<REPO>`. This applies to code, docs, commit
  messages, and any file you create.
- **Secrets never route through chat.** When a script needs a PAT/secret, let it read from a secure
  prompt or an environment variable the user sets — do not ask for or echo the value.
- **Prefer CI over local provisioning for the pilots.** A local `azd provision` runs with an
  incomplete environment and silently resets parameterized named values / secrets to placeholders.
  Pilots are provisioned via GitHub Actions (`deploy.yml`, manual dispatch); dev envs via
  `deploy-dev.yml`. See operations-lessons "Deployment model".
- **Hard-to-reverse or shared-infra actions need confirmation** (deletes, purges, firewall/network
  changes, pushing, triggering deploys). Local/reversible actions (edits, builds, read-only `az`)
  are fine to do directly.

## Repo layout

- `infra/` — `main.bicep` (targetScope **subscription**), `modules/`, and `main.parameters.*.json`.
  `main.json` and the `*.comm-pilot.json` / `*.gov-pilot.json` param files are **.gitignored**;
  commit only `main.bicep` and the `main.parameters.ci.*.json` CI files.
- `policies/` — APIM GenAI policy XML (subkey + jwt variants per route).
- `scripts/` — paired **`.ps1` + `.sh`** helpers (keep them in parity). New `.sh` files need the
  executable bit (`git update-index --chmod=+x`).
- `docs/`, `monitoring/kql/`, `app/register/` (self-serve onboarding Blazor app), `samples/`.

## Cloud & terminal discipline

- Two clouds, **one cloud per terminal/`az` session, forever.** Use a pinned tab per cloud with its
  own `AZURE_CONFIG_DIR`; never `az login --tenant <other>` inside a tab pinned to a different cloud.
- Cross-cloud work (Commercial ↔ Government) requires a cloud switch + fresh login; the
  Commercial-tenant and Government-tenant contexts are distinct.
- After a **PIM elevation**, force a *real* re-login — a cached token predating the elevation keeps
  failing writes with `AuthorizationFailed` while reads succeed.

## IaC & deployment conventions

- azd param files: every key under `"parameters"` must be `{ "value": ... }`. A bare-string
  `"_comment"` is allowed only at the file **root**, never inside `parameters` (breaks azd unmarshal).
- azd **pwsh hooks must `exit 0`** on success/degrade paths — a bare `return` after a failed native
  `az` call leaks `$LASTEXITCODE` and fails the provision.
- `main.bicep` is subscription-scoped and creates the RG; `azd deploy <service>` can't infer the
  target, so set `AZURE_RESOURCE_GROUP` (custom RG name, not azd's default `rg-<env>`).

## Self-hosted CI runners (EMU)

- Hosted runners are **disabled** (EMU enterprise); every workflow targets self-hosted ACA Job
  runners (KEDA-scaled, ephemeral, label = env name).
- Runner auth is **classic PAT** (GitHub App mode is impossible on an EMU user-owned repo). EMU caps
  classic PAT lifetime (~7–8 days) → **rotate weekly**. Symptom of expiry: jobs stuck `queued`, zero
  runners scaling.
- Pilot runner Key Vaults are **private-endpoint-only**. Rotate with
  `scripts/rotate-runner-pat-breakglass.ps1`; on governed subscriptions where the vault can't be
  opened, it falls back to an **ARM-deployment write** (trusted-services bypass — writes with the
  vault still locked). Always **re-resolve the ACA Job secret** afterward (the platform caches KV
  secret refs at the Job level).

## Networking & platform gotchas

- The APIM gateway is **internal VNet mode** — reachable only via its private IP from inside the
  VNet (or P2S VPN / in-VNet test VM), never from a laptop. APIM v2 tiers are **not in Government**
  (use classic Developer/Premium).
- `network.bicep` manages subnets as **child resources** (not inline) to avoid reordering in-use
  subnets on redeploy; some environments need `pinSubnetPrivateOutbound=true`.
- Runner egress **NSG allowlisting cannot express the GitHub Actions control plane** (drifting Azure
  IP space) — keep `restrictRunnerEgress=false` unless an Azure Firewall FQDN policy is in place.
- Observability is **workspace-based** (query `AppMetrics`/`AppRequests`, not classic tables). In
  Government the Log Analytics / App Insights **query data plane is disabled from outside** — verify
  telemetry via the smoke run's in-VNet assertion or ARM metrics, not laptop KQL.

## When unsure

Search the codebase and `docs/`, gather context, then act. Diagnose failures (read the real error —
e.g. check-run annotations for `startup_failure`, activity log for network changes) rather than
retrying blindly. Record durable, **sanitized** lessons in `docs/operations-lessons.md`.
