# Roadmap

Forward-looking plan for the Copilot BYOK gateway. For **shipped** work see
[RELEASES.md](RELEASES.md); for the interactive board see the **BYOK Gateway Roadmap** Project
(filter `label:roadmap is:open`) and the umbrella issue
#17.

## How this maps to GitHub

- **Horizons** = the Project board `Status` field: `Now` (in progress), `Next` (near-term),
  `Later` (deferred/parking lot), `Blocked` (waiting on a dependency), `Done`. Horizons are set **per issue** and do **not** cascade
  from an epic to its sub-issues.
- **Themes** (`theme:*` labels) group related work: `cost`, `security`, `observability`,
  `reliability`, `dx`, `ai-manages-ai`, `compliance`, `multi-model`, `platform`.
- **Effort**: `effort:S` (~1–3 days), `effort:M` (~1–2 weeks), `effort:L` (multi-PR).
- **Priority**: `priority:p0` now … `p3` parking lot.

## Now

| Epic / issue | What | Theme |
|---|---|---|
| #139 | Same-endpoint key OR Entra JWT OR optional Okta JWT; active engineering, not released | security |
| #143 | Main/standalone/wizard compatibility and four Linux runtime tests pass; actual package installation and feature-path acceptance remain | security |
| #144 | Both clouds: 175 governance, 30 admission-rollback cases and matched throttle ingestion pass; deployed rollback and durable operations remain | security |
| #145 | Government real-expiry renewal and pinned-launcher HTTPS ACP tests pass; both VS Code experiences and IntelliJ custom ACP acceptance remain | security |
| #147 | Both pilot caller rollouts finalized and both dev provisioning/smoke runs passed; actual client/package/security/retained-object acceptance remains | security |
| #154 | Group-assigned per-user JWT tiers: shared catalog, Entra roles and optional Okta claim mapping; default-off local implementation started | security |

## Next

### Authentication Acceptance

[Same-endpoint key OR Entra JWT OR Okta JWT](authentication.md) preserves existing client
URLs and backend authentication while identifying JWT callers from validated claims.
Merged implementation and remaining release acceptance are tracked in
epic #139; pilot/dev rollout is
not production acceptance. The epic and children carry the `roadmap` label. The board and the
statuses below were synchronized on 2026-09-27; issue evidence comments distinguish passing
preflight checks from unfinished implementation and release acceptance.
Initial new-auth delivery covers Foundry/AOAI inference, discovery and stateful Responses;
standalone IntelliJ (Bicep/Terraform; VM/Container Apps) and manual packages remain tracked.
The owner explicitly deferred Anthropic new auth after classic-tier native-usage metering
failed; existing Anthropic authentication is unchanged and no call-only waiver was approved.
Government admission evidence supports
the approved local consolidation work. On 2026-09-21 the owner accepted documented
duplicate-Authorization differences under the
[single-credential contract](authentication.md#approved-compatibility-exception-2026-09-21).
Microsoft alignment is no longer a release dependency; no security or rollout waiver was approved.
Shared authentication, identity/quota isolation and all-surface negative tests precede rollout.

| Step | Tracking | Status |
|---|---|---|
| 1. Admission proof and design decision | #140 | Done: revised-contract admission/design proof |
| 2. Entra/Okta trust configuration | #141 | Done: component implementation/validation |
| 3. Shared validation and stable identity | #142 | Done: component implementation/validation |
| 4. All policies and deployment packages | #143 | Now |
| 5. Quotas, telemetry and response authorization | #144 | Now |
| 6. Client credential acquisition and renewal | #145 | Now |
| 7. Entra acceptance, key regression and rollout | #147 | Now |
| Deferred customer Okta acceptance gate | #146 | Later |

**Current checkpoint (2026-09-27 UTC):** PRs #149-#153, excluding optional private-access
PR #152, delivered the core caller implementation and guarded pilot transition path. Main
`95163d1` passed all six validation jobs and 337 development-preview regressions. Government
activation/finalization `36297048052`/`36297959291` and Commercial `36298287147`/`36299162295`
completed with all 49 resources verified, enabled/coexistence settings persisted, unchanged
ownership secrets and matching holds cleared. Native keys remain enabled and Okta disabled.
These are approved control-plane rollouts, not actual editor/client or customer acceptance.

The later scheduled dev run `36332302524` on that source completed both provisioning phases,
registration-app deployment and smoke in both clouds. This supersedes the earlier cancelled
dev run and teardown snapshot, but dev environments remain ephemeral. Probe-only cleanup
removed 614 reviewed test resources from the pilots while preserving live products, users,
backends, policies and product links. See [operations lessons](operations-lessons.md#retained-apim-probe-cleanup).

The reconciliation adds optional token-free renewal tracing and preserves the isolated
private-access tooling alongside the pilot safeguards. The PowerShell and Bash credential
tests, 206 private-access cases and 27 Checkov checks pass locally. No temporary network
apply or live manager rollback has run. Existing pilot VMs need no pilot-to-dev peering to
test their own gateways. Private-access execution still requires separate reviewed approval;
Packer #148 remains deferred. Source consolidation does not close #143-#147 or publish a
customer release. The public source snapshot requires a separate reviewed publication.

**JWT tiering in progress (2026-09-28):** #154 is Now. The review candidate carries the
shared catalog and Entra/Okta selectors through main, standalone VM/ACA Bicep, Terraform and
wizard packages. The focused Entra workflow binds tier mappings/ceilings into approval receipts;
CI staging accepts optional tier settings without enabling any environment. Tier admission and
throttle telemetry retains the existing per-caller metrics. Both issuers remain off by default.

Checks pass: 72 executable selector cases, four compiled limiter fixtures, 87 paired preparation
cases, 22 paired staging cases, 26 paired standalone cases, 54 mocked ACA installer cases,
20 Terraform mock plans and 371 workflow cases. Three compiled standalone/wizard entry points
preserve parameter bindings. The maximum namespaced policy is 32,575 bytes, within the project's
conservative fragment budget. Disabled rendering preserves the original flat limiter; neither
counter nor response-owner identity is renamed by tier selection.

This default-off implementation is a review candidate, not a live rollout. Exact-candidate CI/review, real APIM policy
acceptance, quota continuity, metric ingestion and retained-object rollback remain required. Role
assignments and activation require separate approval; real Okta remains customer-gated. No roles,
deployments or model test traffic changed. Existing release gates #143-#147 remain open.

**Historical checkpoint (2026-09-26 UTC):** PRs #149, #150 and #151 are merged. Main `a8fb212`
passes all six validation jobs; the corrected verifier passes 249 cases on the CI runner.
Commercial activation `36194268574` remains a historical failure after all four ARM modules
applied. No repeat activation occurred. Read-only CI reconciliation `36215131384` verified all
49 resources and the original source/target/trust/key receipt with zero diagnostics or omissions.
After the two existing settings were persisted and separately verified by `36215756105`, matching
finalize `36215998475` reverified all 49 resources and cleared only the hold without reapplying
the gateway. Direct readback at 03:55 UTC confirms enabled/coexistence and no hold. Native-key
admission remains required. This is completed control-plane reconciliation, not client acceptance.

Government's ordinary baseline deployment in `36214817446` succeeded, but its smoke was skipped
after the sibling Commercial job intentionally failed at the hold guard. Delayed scheduled
teardown `36215344300` then removed Government and completed at 04:15 UTC. The owner's single
unchanged-baseline restore/smoke `36217672911` succeeded: both provision phases and 16 smoke PASS,
zero FAIL, two SKIP. Direct private-baseline readback passed at 05:35 UTC. Read-only activation
preview `36221258203` evaluated all 49 resources with zero diagnostics/omissions and no apply.
All five provider checks and three scoped-role checks passed, and the owner approved the exact
main/receipt for one activation and conditional persistence/finalization. Fresh pre-dispatch checks
passed at 13:23 UTC. Government activation `36245015059` succeeded and verified all 49 resources.
The two existing settings were persisted to enabled/coexistence with other trust fields and both
owner secrets preserved. Read-only finalize preview `36245900349` passed, followed by matching
finalize `36246299802` at 13:50 UTC: all 49 resources reverified, hold cleared, no gateway reapply.
Direct checks confirm both dev holds absent and intended native/JWT admission at 13:53-13:58 UTC.
No retry, extra smoke or Commercial reapply was part of the Government action. Legacy preview
`36217315555` remains failed (41 entries,
12 diagnostics, seven omitted types) under the earlier unchanged-baseline-only exception; that
exception is not used for the complete JWT preview. Schedules were not changed or cancelled.

The verifier handles APIM's default/omitted/write-only fields and xml/rawxml representations
without dropping credential, admission, expression or literal checks. A newer verifier can use
an older held artifact only after ancestry, unchanged deployment inputs and original-receipt proof.
Filtered inventories are not evidence of deletion or complete coverage. Live JWT/client/package/
retained-object rollback acceptance remains open. Earlier both-cloud legacy smokes passed 17/16
assertions respectively, but do not substitute for the new integrated acceptance.
Read-only client readiness at 14:14 UTC found the existing Government Windows VM Running, in
a different non-overlapping VNet with no peering to dev. Its existing private DNS zone lacks the
dev gateway record. A scoped private-access plan and interactive-user/traffic approval are next;
no VM guest command, network write or model call was performed by that audit.
The initial validation-only private-access tooling passed 98 local cases and a live Government
provider preview (12 proposed creates, five preserving subnet updates, zero diagnostics, unchanged
snapshot). That receipt is historical, not approval for the later execution tooling.
The 2026-09-27 local safeguard checkpoint passes 206 private-access cases, 249 existing workflow
regressions and Checkov 3.3.19 (27 passed, zero findings/parsing errors). A guarded Plan/Apply/Rollback
manager, journal/ETag ownership checks, disconnect-first recovery and four-workflow hold protection
are ready for focused PR/CI review. No temporary network apply or live manager rollback has run.
This is optional test infrastructure, not a required customer topology. Exact-main review/CI,
single-operator maintenance exclusion, effective-policy/delegation review, fresh provider validation,
separate network approval and actual VM isolation/client acceptance remain gates. Holds do not expire
automatically. Tooling and these notes are not yet merged; live client/package gates remain open.
Earlier dated operational checkpoints below are historical, not the current merge/access status.

Fully validate Entra in controlled environments and implement the Okta equivalent with
local/fixture checks. Full Okta testing requires the customer environment: after engineering
completion it remains **implemented, pending customer validation**, disabled by default.
The customer gate does not block an accepted Entra release, but keeps the epic open unless
its scope is explicitly revised. Full end-to-end release acceptance is not claimed today.

Government CLI authentication, continuing-session real-expiry renewal and real Responses
inference with matching persisted token metrics passed in isolated fixtures. GPT-5.6 tools
plus reasoning uses Responses by owner decision; the failed Chat request is retained as a
documented model limitation. Main Foundry consumers are deployed in both pilots and dev environments;
full package/client acceptance remains open. Foundry/AOAI consumers, JWT accounting, owner
stamping/lookup and the guarded JWT product use explicit `legacy`/`shared`/`coexistence` stages,
default `legacy`.
All eight flat fragments completed isolated installation in both clouds; actual shared
authentication/stripping passed 7/7 signed controls per cloud without backend/model access.
Other fragments' installation is not their composed-policy runtime acceptance. The local suite
has 283 policy-expression/security cases, 60 paired guard and 13 paired staging cases. Committed
profiles retain legacy defaults; protected environment settings enable coexistence in both pilot
and dev environments. No old variant is removed. Full stateful Responses remains an explicit requirement.
On 2026-09-22 the corrected Commercial governance matrix passed 175/175 with a final receipt
audit: native-key/two-user JWT admission, independent counters, JSON/SSE TPM and mocked stateful
ownership. Two valid users' conflicting headers rejected in both orders. Cleanup and VM power
restoration passed. This is not real backend persistence/TLS, Government governance or rollout
acceptance; preceding failed harness attempts remain historical failures.
Government complete-policy compatibility subsequently passed 4/4, but governance was 159/175:
16 empty cancellation POSTs received 411. Framing is fixed and locally tested; corrected reruns
stopped on intermittent transport before the matrix. All diagnostic cleanup and original VM
power-state checks passed; no test is running at this checkpoint. See the
[Government evidence](authentication.md#government-governance-checkpoint-2026-09-22).
Later timing identified blocked TLS revocation retrieval. An approved VM-only TCP80 diagnostic
window enabled strict signed-auth/consumer checks, but local ARM HTTPS failed during governance
setup. The rule and all diagnostics were removed. Late credential refresh now matches the explicit
delegated scope and retains the freshness gate. A subsequent fresh Government run, using a
reusable ARM session, passed **175/175** with final receipt audit true, 7/7 auth and 4/4 compatibility
checks. Cleanup included the exact temporary revocation rule; the original running VM state was
preserved. Both clouds now have completed mock-governance evidence.
The subsequent bounded [real Foundry run](authentication.md#real-foundry-acceptance-2026-09-22)
passed persistence, cross-caller ownership, continuation, stream replay, current/previous-key
rotation and retirement in both clouds. Three actual objects per cloud were deleted with readback;
the fourth creation attempt was denied cross-owner continuation. Active-job cancellation timing
was inconclusive. No diagnostic or temporary network rule remains, and no production rollout ran.
All epic/child issues remain open; see the [client evidence](feature-request-byok-credential-refresh.md).

The 2026-09-23 package checkpoint includes 36 warning-free fresh Bicep builds, ten isolated
Terraform mock plans, 49 deployment guards, 13 paired standalone cases and 24 wizard compositions.
APIM accepted all sixteen actual policy consumers in both clouds behind diagnostic denials.
No-push image builds passed 33 selector cases and 88 wire cases per runtime across four proxy
configurations: the main and standalone nginx images, plus the pinned installer on Ubuntu 22.04
and the actual runner base. Earlier empty-header and njs syntax failures remain historical evidence.
No image was published and no existing proxy was upgraded.

Both clouds then passed 175 mock-governance cases, 30 detach-first admission-rollback cases and
matching legacy/new throttle ingestion: burst 2, tokens 16, quota 4; two identities and no invalid
identity rows per bucket. Owner keys and four utility policies were retained. Commercial telemetry
was recovered after a harness-only precondition fix without repeating traffic. Current-run cleanup
and VM power restoration passed. This is not package installation or retained-object CI rollback.

The pinned editor launcher passed strict-HTTPS renewal/failure tests with the actual CLI in one
ACP session; all fifteen wire tests pass. The owner requires both the VS Code CLI terminal and its
native Agent/Background experience, plus IntelliJ custom ACP, to be verified in the Government VM
user session. Native Custom Endpoint and IntelliJ AI Assistant stay on per-user keys; no new
native-provider refresh adapter is planned. Real customer Okta and macOS/Linux keystore acceptance
remain deferred. The owner subsequently approved full runner candidates, idle image-only adoption,
and a PR/CI/review/validation-gated merge with the normal key-only development smoke. The candidates
were published in both clouds under source tag `1a6ad46358b1` with verified digests; `latest` and
live runner references remain unchanged. Commercial access no longer resolves the tested pilot
resources, so adoption and deployment validation are paused. A fresh token did not restore that
inventory; other cached scopes returned authorization errors. Do not infer resource deletion or
recreate infrastructure. JWT settings/secrets remain unstaged and pilot activation unapproved.
The first PR checks passed JSON, YAML and policy parity but failed Bicep with live compiler 0.30.23
and the credential helper before Node setup. The ordering is corrected. GitHub also warned that
runner 2.335.1 loses eligibility on 2026-09-24; source now selects stable 2.337.0, whose official
Linux amd64 image exists. The earlier candidates remain published but must not be adopted.
Provisional image pins were removed pending newly approved builds. Access was subsequently restored,
and both supported 2.337.0 replacements from `c6aa05730fe4` built with verified digests. Both one-job
snapshots passed official deployment validation and strict image-only previews. Commercial's idle
runner update succeeded with unchanged identity/configuration/pull role and a protected rollback
snapshot. Government adoption and fresh 2.337.0 execution subsequently passed too. The approved
repository/two-pilot PAT rotation completed with fresh pings, unchanged private networking/RBAC and
encrypted-state cleanup. Dev runners were absent after scheduled teardown; the next normal rebuild
uses the updated repository secret. Five PR checks passed; the package job's assertions all passed
but leaked an expected-negative native exit code. The locally verified exit fix still needs CI proof.

## Remaining Delivery

| Workstream | Remaining acceptance or implementation |
|---|---|
| Two-cloud verification | Mock matrices complete (175/175 each); establish the durable strict certificate-revocation egress design for supported customer clients |
| Real backend and governance | Foundry persistence/TLS/rotation and both throttle metrics verified; finish deployment trust-boundary and remaining route coverage; active-cancel timing remains an accepted documented limitation |
| Operational rollout | Both pilots finalized with 49-resource verification; both dev environments provisioned and smoked; actual clients/packages and retained-object rollback remain |
| Clients and packaging | Linux/image gates pass; finish actual installer/feature paths, both VS Code experiences, IntelliJ custom ACP expiry/failure/recovery and native-key regressions |
| Review and release | Core implementation and pilot rollout merged with approved exact-head review exceptions; full client/package acceptance and customer source publication remain separate |

The two-cloud mock and bounded real Foundry acceptance do not close these workstreams.
Real customer Okta acceptance and Anthropic new authentication remain explicitly deferred.
Reducing the initial supported deployment/client surfaces requires an owner scope decision;
untested samples must not silently be called complete.

## Release Gates

The documented duplicate-header difference is accepted, not fixed. The Microsoft case is an
optional follow-up. Fresh integrated security/key-regression tests, two-valid-user conflict
rejection, native accounting, response ownership, customer client verification, rollback and
explicit CI deployment approval remain required. Historical parity failures are not relabeled
as successful new runs, and no authentication issue is closed solely by the exception.

## Later

| Issue | What | Theme |
|---|---|---|
| #146 | Real Okta acceptance after implementation and approved customer environment prerequisites; default-off until accepted | security |
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
