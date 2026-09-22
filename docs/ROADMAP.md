# Roadmap

Forward-looking plan for the Copilot BYOK gateway. For **shipped** work see
[RELEASES.md](RELEASES.md); for the interactive board see the **BYOK Gateway Roadmap** Project
(filter `label:roadmap is:open`) and the umbrella issue
#17.

## How this maps to GitHub

- **Horizons** = the Project board `Status` field: `Now` (in progress), `Next` (near-term),
  `Later` (deferred/parking lot), `Done`. Horizons are set **per issue** and do **not** cascade
  from an epic to its sub-issues.
- **Themes** (`theme:*` labels) group related work: `cost`, `security`, `observability`,
  `reliability`, `dx`, `ai-manages-ai`, `compliance`, `multi-model`, `platform`.
- **Effort**: `effort:S` (~1–3 days), `effort:M` (~1–2 weeks), `effort:L` (multi-PR).
- **Priority**: `priority:p0` now … `p3` parking lot.

## Now

| Epic / issue | What | Theme |
|---|---|---|
| _Nothing in flight_ | Recently shipped: the multi-type routing epic (#119, Phases 1–3 in 1.1.0 / 1.2.0 / 1.3.0) and streamed-request token metering (#126, 1.4.0) — all validated live on both pilots. Pick the next theme from the umbrella below. | — |

## Next

### Authentication design pending implementation

[Same-endpoint key OR Entra JWT OR Okta JWT](authentication.md) preserves existing client
URLs and backend authentication while identifying JWT callers from validated claims.
Implementation is tracked in epic #139,
not shipped functionality. The epic and children carry the `roadmap` label; board horizons
are managed separately.
It covers inference, discovery, Responses follow-ups, optional AOAI/Anthropic routes and
standalone IntelliJ (Bicep/Terraform; VM/Container Apps). First gate: prove native key
validation/product quotas and JWT admission can coexist without anonymous access. Client
renewal, identity/quota isolation and all-surface negative tests precede pilot rollout.

| Issue | What | Theme |
|---|---|---|
| #139 | [Same-endpoint key OR Entra JWT OR Okta JWT](authentication.md); implementation pending | Authentication |

| Step | Tracking |
|---|---|
| 1. Admission proof and design decision | #140 |
| 2. Entra/Okta trust configuration | #141 |
| 3. Shared validation and stable identity | #142 |
| 4. All policies and deployment packages | #143 |
| 5. Quotas, telemetry and response authorization | #144 |
| 6. Client credential acquisition and renewal | #145 |
| 7. Entra acceptance, key regression and rollout | #147 |
| Deferred customer Okta acceptance gate | #146 |

Fully validate Entra in controlled environments and implement the Okta equivalent with
local/fixture checks. Full Okta testing requires the customer environment: after engineering
completion it remains **implemented, pending customer validation**, disabled by default.
The customer gate does not block an accepted Entra release, but keeps the epic open unless
its scope is explicitly revised. No runtime implementation is claimed complete today.

## Later

| Issue | What | Theme |
|---|---|---|
| #121 | Streaming chat⇄responses sidecar transcoder. **Demand-gated** — build only when a path-hardcoded client (e.g. Copilot CLI) must *stream* against a genuinely single-surface model. Any repointable client can use APIM's `/responses` route directly, which already streams natively. | multi-model |

## Themes on the horizon (umbrella #17)

The broader roadmap turns the gateway from proven plumbing into a self-managing platform. Vote
with 👍 reactions on the issues you want prioritized.

- **`theme:cost`** — semantic prompt cache, model-downshift routing, budget-triggered auto-suspend.
- **`theme:security`** — Prompt Shield + DLP regex inline, key auto-rotation, Defender for AI.
- **`theme:observability`** — SLO workbook, cost-per-request panels, synthetic probes, NL-KQL.
- **`theme:ai-manages-ai`** — a Foundry agent that watches the gateway's own telemetry and opens
  policy PRs.
- **`theme:reliability`** — multi-region Foundry pool, health probes, circuit breakers.
- **`theme:dx`** — Developer Portal self-service, VS Code pre-flight cost estimate, `config doctor`.
- **`theme:multi-model`** — beyond AOAI/Foundry; per-team default-model policy; the #119 epic above.
- **`theme:compliance`** — residency-proof immutable log, control-mapping docs, signed releases.
- **`theme:platform`** — migrate hand-rolled policy bits to APIM's built-in `llm-*` policies.

## Contributing to the roadmap

1. Open (or find) an issue; add the `roadmap` label so it lands on the board.
2. Tag it with a `theme:*`, an `effort:*`, and a `priority:*`.
3. Set its horizon (`Status`) on the board. Link phases of a larger effort as sub-issues of an epic.
4. When it ships, move the card to `Done` and add an entry to [RELEASES.md](RELEASES.md) under the
   version it lands in.
