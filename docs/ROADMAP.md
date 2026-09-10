# Roadmap

Forward-looking plan for the Copilot BYOK gateway. For **shipped** work see
[RELEASES.md](RELEASES.md); for the interactive board see the **BYOK Gateway Roadmap** Project
(filter `label:roadmap is:open`) and the umbrella issue
[#17](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/17).

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
| _Nothing in flight_ | Recently shipped: the multi-type routing epic ([#119](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/119), Phases 1–3 in 1.1.0 / 1.2.0 / 1.3.0) and streamed-request token metering ([#126](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/126), 1.4.0) — all validated live on both pilots. Pick the next theme from the umbrella below. | — |

## Next

| Issue | What | Theme |
|---|---|---|
| _Nothing queued_ | — | — |

## Later

| Issue | What | Theme |
|---|---|---|
| [#121](https://github.com/gwexler_microsoft/copilot-cli-byok-azure/issues/121) | Streaming chat⇄responses sidecar transcoder. **Demand-gated** — build only when a path-hardcoded client (e.g. Copilot CLI) must *stream* against a genuinely single-surface model. Any repointable client can use APIM's `/responses` route directly, which already streams natively. | multi-model |

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
