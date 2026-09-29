# Caller authentication: subscription keys, Entra and Okta

## Status and scope (2026-09-27)

This document separates the implemented authentication modes from the planned migration.
It is a design record, not a deployment procedure or a claim that Okta is enabled.

| Capability | Current status |
|---|---|
| APIM subscription-key authentication | Implemented; all four CI environment configurations select `authMode=subscriptionKey` |
| Entra access-token authentication | Implemented as the alternative deployment mode `authMode=jwt` |
| Key OR JWT on the same client-facing endpoint | Implemented and merged, default `legacy`. Both pilots completed approved native-key plus Entra JWT activation and control-plane readback on 2026-09-27; both dev environments subsequently passed provisioning and smoke. Shared auth passed 7/7, mock governance 175/175, and bounded real Foundry Responses ownership/rotation checks in each cloud. Actual client/package and release acceptance remain open. |
| Direct Okta access-token validation | Shared validator/configuration and client equivalent are committed, default off; real APIM/Okta customer acceptance is pending |
| Stateful Responses | Real Foundry persistence, owner/cross-caller access, continuation, streaming replay and diagnostic key rotation passed in both clouds. Active-job cancellation timing was inconclusive; broader integration/rollout gates remain. |
| Anthropic new shared authentication | Deferred by owner decision after classic-tier native-usage metering failed. Existing Anthropic routes/authentication remain unchanged; no call-only quota waiver. |
| CLI dynamic credential command | Government VM CLI 1.0.85 passed both formats' authentication and actual-expiry renewal. Real Responses inference and matching token ingestion passed. Use Responses for GPT-5.6 tools plus reasoning; Chat has a documented model limitation. |
| Editor-hosted native Copilot CLI | Pinned launcher passed local HTTPS ACP same-session renewal and failed-helper rejection with the real CLI. Actual VS Code/IntelliJ launch, expiry and recovery acceptance remains open. |
| Native VS Code Custom Endpoint / IntelliJ AI Assistant | Approved support boundary uses per-user APIM subscription keys, not static JWTs or a new renewal adapter. Ordinary Agent mode using those providers has the same boundary. |

Deployment-mode entries reflect source/configuration findings, not a fresh production inventory.
The wrapper scripts support static Entra tokens or opt-in per-request token acquisition through
the CLI credential command. The opt-in [Okta public-client helper](../scripts/okta/README.md)
adds PKCE, pinned user claims, encrypted refresh storage and command-mode renewal; its fixture
tests and Windows keystore test passed, not real customer Okta acceptance.

### Delivery and tracking

Epic #139 tracks the
seven implementation steps and their dependencies; see the [roadmap task list](ROADMAP.md#authentication-design-pending-implementation).
Implement and fully validate Entra end to end in controlled environments, while writing
the Okta equivalent with local/fixture tests. Full Okta validation must wait for the
customer environment and is tracked separately in
#146.

The complete Okta feature remains unfinished. After consumer/client implementation, label it
**implemented, pending customer validation** and keep it disabled by default until the customer gate passes. Entra success
or synthetic Okta tokens do not prove real Okta compatibility. This deferred gate does not
block an accepted Entra release, but the overall epic remains open unless explicitly rescoped.

## Intended contract: one effective credential, not two

Keep existing client-facing inference and discovery URLs. A request presents ONE of:

| Credential | Validation | Identity after successful validation |
|---|---|---|
| APIM subscription key | Active subscription, correct API/product scope | APIM subscription ID |
| Entra access token | Trusted issuer/signature, gateway audience, expiry and required delegated scope | Tenant plus immutable `oid` |
| Okta access token | Trusted custom authorization server/signature, gateway audience, expiry and required scope | Issuer plus stable `sub` |

This is **key OR Entra JWT OR Okta JWT**, not key AND JWT. Key-only clients must keep
working. Supporting a new issuer does not make an arbitrary token valid.

### Approved compatibility exception (2026-09-21)

**Decision: accept the documented duplicate-Authorization differences and continue customer
delivery without waiting for Microsoft.** The owner explicitly approved this change. It
supersedes the 2026-09-19 requirement for identical duplicate-header outcomes across clouds,
not the requirement for identical supported single-credential behavior or secure rejection.
The acceptance contract is `single-credential-v1`.

> Clients must send exactly one credential in one supported header (or the existing native
> key-query form where supported). Repeated Authorization fields are outside the supported
> portable client contract. Identical repeated Bearer values may be rejected with HTTP 400/401,
> or normalized by the platform to one effective credential, which must fully validate before
> one request is authorized. Different credentials must be rejected before any backend access;
> HTTP 400 versus 401 and the rejecting platform/policy layer may differ.

| Request class | Required acceptance behavior in both clouds |
|---|---|
| One supported valid credential | Same authentication, identity, authorization and accounting semantics; no compatibility waiver |
| One invalid/missing/expired/tampered credential | Existing negative controls stay strict; no backend request |
| Separate Authorization lines with the exact same valid token | 400/401 with no backend access, or one fully validated identity and exactly one credential-stripped backend request |
| Separate Authorization lines with different values, including two valid users | 400/401, no chosen identity and no backend request, in either order |
| Repeated invalid/expired/tampered Bearer value | 400/401 and no backend request; repetition never makes a token valid |
| Mixed credential sources, comma-combined credential values, duplicate keys/query keys or duplicate JWT claims | Remain unsupported and rejected; not covered by a success exception |

**Unchanged security requirements:** exact issuer and gateway audience, signature and lifetime,
required scope, permitted user/client, immutable caller identity, native key scope/state,
quota isolation and credential stripping. No anonymous fallback, first-value selection,
custom deduplication, new ingress or URL migration is authorized. A transport error, 5xx,
missing validation evidence or unexpected backend receipt is not an acceptable rejection.
Accepted normalized duplicates represent one request and one accounting event, never two.

**Known residual limitation:** a client/intermediary emitting identical lines can work in
Government and fail in Commercial. Original multiplicity is not observable after Government
normalization, so exact wire-line auditing is not promised. Clients must not depend on either
cloud's recovery behavior. Fix duplicate emission in the SDK/proxy configuration; do not
automatically retry a duplicate-header failure unchanged or treat every 401 as token expiry.

**Customer handover:** JWT-capable client/edge applications remain supported when their route
is enabled and they send one gateway-audience access token. Prefer one
`Authorization: Bearer <ACCESS_TOKEN>` field; use one `api-key` or `x-api-key` field instead
only where the configured JWT route supports that client contract. Never send both. Renew
the token before expiry, retain private-gateway network access, and verify the actual customer
SDK/intermediary chain emits one credential. The implemented token profile is delegated-user
authentication; this decision does not add app-only/client-credentials or direct Okta readiness.

**Release effect:** Microsoft alignment is no longer a prerequisite for #140 or #147. Keep the
support case as an optional platform follow-up, not a delivery dependency. Existing historical
failure totals remain unchanged: they were measured against the earlier contract. Revised
tests must record `single-credential-v1`, actual status/context and a final backend-receipt audit;
old results are not silently relabeled as fresh passes.

The probe's revised evaluator has 35 local acceptance checks. The future live matrix includes
independent raw single-token controls for both users, conflicting valid-user tokens in both
orders, mixed-case identical lines and HTTP/2 counterparts where enabled. Rejected duplicates
must have zero backend receipts; accepted normalized duplicates still require validated context,
stripping and exactly one receipt. The final audit now follows the permitted rejection/success
outcome instead of assuming all identical duplicates must reach the backend. The isolated
shared-validator run passed seven signed-token controls per cloud, including identical
duplicates, but the revised native-admission/backend-receipt matrix has not been run yet.

Remaining gates are integrated policies and native accounting, JWKS rollover/outage behavior,
the two-distinct-valid-user duplicate case, stored-response authorization, supported client
acquisition/renewal and transport coverage, key regressions and rollback. Current pilots stay
key-only; shared-auth preparation does not activate JWT coexistence. This exception is neither
a claim that integration is finished nor authorization to commit, push or deploy.

### Historical identical-Authorization decision (2026-09-18)

The following chronology records earlier expectations. The approved compatibility exception
above controls current acceptance; historical failures and probe observations remain evidence.

**Owner decision (2026-09-18): accept this known platform limitation and continue acceptance
work.** This supersedes the earlier strict wire-level rejection decision recorded below.
APIM may normalize separate Authorization header lines containing the exact same Bearer token
into one effective credential, including case variants of the header name. Accept that request
only if the effective token passes all required JWT and stable-identity validation. This is
not an exception for duplicate JWT claims, two different valid tokens, or multiple identities.

Continue rejecting different Authorization values, comma-combined credential values, duplicate
key/query credentials, and multiple credential sources such as key plus Bearer or JWT in both
api-key and Authorization, even when those sources contain the same token. Do not add custom
first-value selection or deduplication to make conflicting credentials pass. Invalid, tampered,
expired, wrong-issuer/audience/scope tokens remain invalid when repeated.

Accepted duplicates represent one request and one validated identity, not two authentication
events or quota charges. The authenticated mock must observe exactly one request with caller
credentials stripped; full identity/accounting and multi-user tests remain required. Policy
cannot reliably log original duplicate multiplicity once APIM has removed it.

Known behavior is established on the Government HTTP/1.1 path, not assumed for Commercial or
HTTP/2. The probes at that checkpoint expected acceptance for the exact-same-token case while keeping conflict
rejections. Historical failing runs are not retroactively relabeled as passing. The strict
duplicate blocker is waived only for this special case; **#140 is still open, not signed off**.
At that initial Government-only checkpoint, Microsoft clarification was nonblocking and no
ticket existed. The subsequent cross-cloud decision below supersedes that status: a parity
support ticket was later verified created and Open. No front proxy, hostname migration, or
production coexistence rollout is approved.

**Historical owner parity decision (2026-09-19), superseded on 2026-09-21:** require identical
behavior in both clouds. After
Commercial rejected duplicate Authorization lines that Government normalized or rejected with
a different status, the owner initially declined cloud-specific acceptance expectations. That
decision kept the same-token and conflicting-token expectations unchanged during investigation.
The earlier Government exception does not authorize a divergent Commercial contract, custom
first-value selection, or a new ingress deployment.

### Current parity assessment (2026-09-21)

This combines the earlier signed-token evidence below with a fresh, approved inert-header
probe in both clouds. Issue #140
remains open for acceptance work, but no longer waits on Microsoft under the exception above.
The Microsoft ticket was previously verified created/Open on 2026-09-21;
its status was not re-polled for this probe. A specific platform root-cause explanation or
supported alignment has not been established.

| HTTP/1.1 input | Government observation | Commercial observation |
|---|---|---|
| One valid Bearer line | Validated 200 | Validated 200, including raw-client controls |
| Two separate lines containing the same valid JWT | One effective value, JWT validation, 200 and one stripped mock-backend receipt | Two effective values; our source guard returns 401; no backend receipt |
| A valid JWT and `not-a-jwt` on separate lines, either order | 400 with no recorded probe marker/context or backend receipt | Two effective values; marked source-guard 401; no backend receipt |
| Two distinct valid users' JWTs on separate lines | Not separately established by the recorded conflict fixtures | Not separately established by the recorded conflict fixtures |

There were two failures of the earlier contract: **acceptance parity** for the identical-valid
case and **rejection-status parity** for the conflicting case. Both observed conflicting paths
fail closed. The evidence does not show invalid credentials being accepted, and it does not
make the historical runs passes under that earlier requirement. The 2026-09-21 decision
explicitly accepts these differences; the unwaived security gates still apply.

The Commercial cause at policy level is established by a fixed rejection marker and effective
header count. The [probe policy](../scripts/probe-jwt-auth.ps1) rejects a visible
`Authorization` array whose length is not one; the new shared source guard does the same.
Government's identical-line path presents one effective value, so validation can proceed.
The new inert test below rules out JWT validation, subscription admission and our header
accessors as necessary causes of Government's conflicting-line 400. The exact platform
component that collapses identical lines or produces that 400 remains unproven. Absence of
our marker is not sufficient to name a particular parser. Matching Developer/`stv2`/Internal
ARM properties do not prove matching runtime builds.

[APIM's documented header API](https://learn.microsoft.com/en-us/azure/api-management/api-management-policy-expressions#context-variable)
exposes a string array; `GetValueOrDefault` returns a comma-joined view. Its comma flag cannot
tell separate wire lines from one comma-combined line. The
[raw probe serializer](../scripts/probe-jwt-auth-vm.ps1) preserves supplied lines, case and
order. Eight offline checks now execute that exact function without importing the VM probe's
side effects, opening a socket or using real credentials. They protect the harness, separately
from the live observations below. The two-real-user rate/quota controls do not substitute for
the untested two-valid-token duplicate case.

#### Fresh inert-header isolation result (2026-09-21)

The approved `-HeaderParityGate` ran from each existing in-VNet Windows VM over raw HTTP/1.1
with strict certificate and revocation checking. No live caller credentials, JWT validator,
model requests, backend, product associations or policy inheritance were used. Each temporary
API had `subscriptionRequired=false` only for this diagnostic; it could return fixed responses
but could not reach a backend. This is not evidence that optional admission is safe for a
production key/JWT API.

Each cloud recorded **24 observations**: eight inputs on three operations. `blind` never
accessed request headers; `array` read the Authorization array count/equality; `joined` invoked
`GetValueOrDefault` first and then measured the array. A marked **401 was the intentional
diagnostic response**, not a failed JWT check or an authentication acceptance result.

| Inert input | Government | Commercial |
|---|---|---|
| Missing header | Marked 401 at all stages; count 0 | Same |
| Single value, including final control | Marked 401 at all stages; count 1 | Same |
| Identical values on separate lines | Marked 401 at all stages; count 1; joined comma false | Marked 401 at all stages; count 2, equal true; joined comma true |
| Identical values with mixed-case header names | Same normalization as identical lines | Same preservation as identical lines |
| Different values on separate lines, both orders | Unmarked 400 at all stages, including `blind`; no expression-error marker | Marked 401 at all stages; count 2, equal false; joined comma true |
| One comma-combined line | Marked 401 at all stages; count 1; joined comma true | Same |

The differing-line rejection occurs without even invoking our header accessor, and the
normalization difference persists without any token parsing or native key admission. Merely
changing `GetValueOrDefault` to array access would not align the clouds. In Commercial, the
joined helper does not collapse the array: the subsequent count remains 2. These observations
narrow the issue to platform request handling before the diagnostic response, not a specific
identified Microsoft runtime component. All single/missing controls completed, and no
expression-error marker was returned.

Both temporary APIs were removed. Government's running VM state was preserved. Commercial's
VM was temporarily started and restored to deallocated. The first immediate Commercial GET
still saw the API after DELETE, so that run reported cleanup unverified; a subsequent paginated
read-only inventory found **zero diagnostic APIs**, with the gateway `Succeeded`, still Internal,
HTTP/2 `False`, and the VM deallocated. No second DELETE was necessary. Government's immediate
deletion/settings readback passed. No networking or HTTP/2 setting was changed in either cloud,
and no production API/policy or shared-auth fragment was deployed.

The reusable gate also has local checks for the three isolated policy variants, eight exact
wire-serialization cases and six mocked lifecycle cases covering preflight failure, partial
creation, matrix failure and changed ownership. The live result is completed evidence, not a
parity acceptance pass. Two distinct valid user JWTs in one request and Government HTTP/2
remain separate unverified gates.

The later Commercial HTTP/2 window did run: **258/270 Foundry**, **170/182 Anthropic**, with
**18/24 HTTP/2 cases per variant**. Each full matrix retained six HTTP/1.1 and six HTTP/2
duplicate-header parity failures; neither passed acceptance. HTTP/2 was restored to `False`,
the temporary CRL-egress rule was removed, and the VM was restored to deallocated. Government
HTTP/2 acceptance remains unverified. Earlier entries saying the client was unavailable
describe an earlier checkpoint, not the final Commercial transport evidence.

HTTP does not promise portable acceptance of repeated Bearer credentials:
[RFC 9110 section 5.3](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.3) restricts repeated
field lines to list-compatible fields, while
[Authorization](https://www.rfc-editor.org/rfc/rfc9110.html#section-11.6.2) carries one
credentials value, not a list of Bearer credentials. The identical-line exception is therefore
an implementation recovery behavior, not a standards guarantee that Commercial must accept
it. Clients must use the single-credential contract even where normalization is observed.

An optional support follow-up can identify the managed parser/runtime versions and
request-processing stages, state the supported normalization/rejection contract for both
clouds and transports, and give a supported alignment or tracking reference. No undocumented
setting, custom deduplication or first-value fallback is approved; only the documented
duplicate-header acceptance difference is waived.

The inert comparison above is now complete and is the smallest reproduction to discuss with
support. Ask why the `blind` operation is reached in Commercial but not Government for
conflicting lines, and which supported platform contract or mitigation can align the result.
Any further correlated replay or guarded real-token matrix, including two distinct valid users
in both orders, needs its own approved scope. Report only status, negotiated protocol, fixed
stage markers, value counts/equality and backend-receipt booleans. Keep resource IDs and request
correlations in the private support channel; never return header/token values. HTTP/2 toggles
or CRL/network windows still require separate approval and verified cleanup.

The caller credential is stripped before backend forwarding. APIM-to-Foundry/AOAI
networking, backend selection and authentication remain unchanged: managed identity or
the route's separately configured backend credential. An Okta caller token is never
forwarded to Foundry, and Foundry does not need to trust Okta.

## Gateway work and the admission gate

The current [API definition](../infra/modules/apim-foundry-api.bicep) sets
`subscriptionRequired` and selects either key or JWT policies from `authMode`.
Mandatory subscription validation can reject JWT-only callers before inbound policy runs.
Adding `validate-jwt` to a subkey policy therefore does not implement the intended OR contract.

**Same-URL admission is an unresolved implementation gate.** Prove how APIM handles valid,
invalid, suspended and wrong-scope keys, missing keys, and JWTs in each supported header,
including the resulting subscription/product context. Do not simply disable subscription
requirements and assume native key validation or product quotas still apply. If native
behavior cannot preserve the contract, design and approve an authentication-aware ingress
that preserves client URLs and isolates the key and JWT validation paths. No per-request
ARM key lookup, copied key allowlist, anonymous fallback or synthetic shared subscription
should be introduced as a shortcut.

The local shared-auth implementation includes credential selection, fixed issuer dispatch,
Entra/Okta validation, stable identity, credential stripping, JWT accounting and stateful
Responses ownership. [The main template](../infra/main.bicep) has explicit
`legacy`/`shared`/`coexistence` rollout stages, defaulting to `legacy`; no CI configuration
enables the new path. Foundry/AOAI consumers and the guarded JWT product are wired locally.
The actual shared Entra validator passed isolated checks in both clouds, but this is not an
integrated deployment or security acceptance. No old variant has been removed, and standalone
packages remain separate work. Legacy key policies also gain a deny guard against missing
native subscriptions or stale open-product admission; valid key behavior still needs regression
coverage. No production policy was changed by the diagnostic runs.

After admission is resolved, use a shared authentication fragment with explicit inclusion
in operations that omit `<base />`. The validation sequence must:

1. Extract exactly one effective credential using the header contract and approved identical
  Authorization exception above. Prefer Bearer for
   JWTs; preserve existing `api-key`/`x-api-key` client compatibility. Reject conflicting
   credential sources; never put access tokens in URL query strings.
2. Select a validation path without trusting an unverified token. An unverified `iss`
   can select only a statically allowlisted issuer branch, never a discovery URL supplied
   by the caller. Each branch revalidates its exact issuer, audience, signature and claims.
3. Keep Entra and Okta trust settings separate, avoiding a cross-product of allowed issuers
   and audiences. Reject unknown issuers, malformed/expired tokens, missing scopes and
   missing stable identities. Never fall back to key authentication after failed JWT validation.
4. Normalize validated identity for telemetry and limits, then strip every accepted caller
   credential header/query parameter before forwarding.

Entra `scp` is space-delimited; Okta commonly supplies an array. Test required-scope
membership for each issuer, including multiple scopes. ID tokens are not API credentials:
require the API audience, access permissions and appropriate client/user claims.

### Shared fragment contract (local implementation)

| Source | Responsibility |
|---|---|
| [Credential source](../policies/fragments/byok-credential-source.xml) | Check enabled-method/trust configuration, then select one key or JWT source; reject conflicts and JWT query credentials |
| [Authentication composition](../policies/fragments/byok-authenticate.xml) | Reject ambiguous raw JWTs, select a fixed issuer validator, retain native key identity, and produce validated principal outputs |
| [Entra validation](../policies/fragments/byok-validate-entra.xml) | Signed, expiring v2 token; exact cloud/tenant issuer and API audience; delegated scope, user identity and client contract |
| [Okta validation](../policies/fragments/byok-validate-okta.xml) | Signed custom-server access token; separate issuer/audience/scope; explicit client allowlist and user-bound immutable subject |
| [Credential stripping](../policies/fragments/byok-strip-caller-credentials.xml) | Require authenticated context, remove caller headers/query credentials and clear the raw-token variable before backend access |
| [Caller limits](../policies/fragments/byok-apply-caller-limits.xml) | Preserve native product accounting; apply JWT call/token/monthly limits exactly once using the validated principal |

Source components are not one-to-one runtime includes. APIM does not support
[nested policy fragments](https://learn.microsoft.com/en-us/azure/api-management/policy-fragments).
Bicep expands the first four sources into one flat `byok-authenticate` fragment and deploys
`byok-strip-caller-credentials` and `byok-apply-caller-limits` separately. Disabled issuer
branches render rejecting stubs, not placeholder discovery calls. The three fragments wait for
their named values; consumers must also order the existing Entra/backend settings first.
The module's configuration output is a completeness check, with stricter executable trust
checks in the gate and paired pre-provision validation for the preparation inputs. The module
alone is not a complete validated deployment contract: direct ARM deployments can bypass the
local hook, and integrated admission/ownership/standalone acceptance remains incomplete.

The consuming policy supplies `byokCredentialHeader` as `api-key` or `x-api-key`, invokes
authentication before inherited quota policies, and invokes stripping before any classifier
or model call. A key-enabled deployment must retain actual native required-subscription
admission; a named-value flag does not itself prove API scope validation. The guarded open
product is linked only in explicit coexistence; rollback must detach it first. Operations that
omit inbound base invoke authentication explicitly and must not run the inference body parser.

| Output | Contract |
|---|---|
| `callerAuthMethod` | `subscriptionKey`, `entraJwt`, or `oktaJwt`, set only on the selected authenticated path |
| `callerIssuer` | `apim` for a native subscription, otherwise the exact validated token issuer |
| `callerSubject` | Subscription ID; normalized Entra tenant plus `oid`; or validated Okta `sub` |
| `callerPrincipalKey` | Method plus length-prefixed issuer plus subject; intended for new JWT counters, not automatic rewriting of native key budgets |
| `byokCallerAuthenticated` / `byokJwtValidated` | Completion guards; initialized false, never established by unverified token parsing |
| `developerOid` / `developerUpn` | Compatibility telemetry values; display names are never authorization or quota keys |

The current JWT profile is RS256 with required expiration and zero clock skew. Raw duplicate
JSON members (including escaped names), ambiguous scalar identities and wrong issuer-specific
scope types are rejected before signature validation. Unverified issuer parsing chooses only
a statically configured branch; `validate-jwt` still verifies the signature, issuer, audience,
lifetime and required claims. The post-validation gate requires immutable identity and rejects
app-only/client-as-audience contracts; parsing tests do not prove those cryptographic checks.

Entra retains the legacy permitted-delegated-client behavior when no explicit client allowlist
is configured. Okta requires an explicit allowlist and, for this initial default-off profile,
`sub` equal to the user-bound `uid`. A customer authorization server that puts a mutable login
in `sub` must use an approved immutable-subject configuration; do not silently switch identity
keys. Customer compatibility, token issuance and JWKS/renewal behavior remain #146 gates.

[Shared-auth tests](../scripts/tests/caller-auth.Tests.ps1) execute 283 policy-expression and
security cases, including credential/claim checks, accounting, ownership, request stamping,
configured origins/stores and the guarded JWT product. The Bash entry point runs the same suite. CI also
compares a fresh standalone Bicep build's embedded XML with source, verifies disabled-issuer
stubs, flat composition and ordering, and enforces a conservative fragment-size budget.
The actual Entra validator now has signed-token runtime evidence in both clouds, described
below. These local checks do not prove native admission, live ownership, quota enforcement,
JWKS rollover or Okta compatibility.

### Preparation and staged rollout

`callerAuthPreparation` is a sealed, typed object. Omitting it creates no new resources; the
default candidate key/Entra flags follow legacy `authMode`, and Okta defaults off. Supplying
the object requires all its fields, as shown in the disabled
[Commercial example](../infra/main.parameters.commercial.example.json) and
[Government example](../infra/main.parameters.gov.example.json).

| Field | Preparation contract |
|---|---|
| `enabled` | Opt in to named values, flat auth fragments and an inactive guarded JWT product; alone does not change API authentication or add product links |
| `keyEnabled`, `entraEnabled` | Methods used by explicit shared rollout; legacy `authMode` still controls APIs while rollout is `legacy`, and always controls the deferred Anthropic route |
| `entraClientIds` | Optional explicit delegated-client GUID allowlist; an empty array retains the legacy permitted-client contract |
| `oktaTrust` | Independent `enabled`, exact custom-server `issuer`, matching `openIdConfigUrl`, API `audience`, `requiredScope`, and explicit `clientIds` |
| `jwtProductId` | Unpublished guarded JWT-product identifier; must not collide with a native tier; associations are added only in `coexistence` |

Entra trust derives from `cloudEnv` and the existing `entraTenantId`, `apiAudience` and
`requiredScope`; no caller token or new arbitrary metadata input selects the authority.
Enabled preparation requires at least one method. Enabled Entra requires canonical lowercase,
nonzero GUIDs; enabled Okta requires HTTPS custom-server metadata, a distinct API audience and
explicit clients. Duplicate clients, placeholders, malformed scopes, unsafe audience syntax,
unresolved required substitutions and contradictory types are rejected before provisioning.
Nested `${VAR}` strings are resolved without printing their values. Flags remain JSON booleans.

The existing [PowerShell guard](../scripts/check-provision-params.ps1) and
[Bash guard](../scripts/check-provision-params.sh) validate this contract. Their optional explicit
parameter-file input permits isolated checks without replacing the staged deployment file.
`SKIP_PROVISION_PARAM_CHECK=true` bypasses only the legacy backend/advisory checks, never supplied
shared-auth trust. Bash requires `jq`; neither guard calls Azure. Direct ARM callers must run
the applicable guard themselves; Bicep compilation does not replace runtime or trust validation.

The local suite covers 60 paired guard cases (120 helper executions, including both published
examples), plus 13 paired staging cases and the 283 policy-expression/security cases. Active rollout requires
valid preparation, at least one Foundry/AOAI route, a stable canonical 32-byte ownership key,
and at most eight configured response stores. `coexistence` additionally requires native keys
and at least one JWT issuer. These are local checks, not a deployment or rollout.

#### CI inputs and durable keys

The existing pilot and dev workflows now invoke the paired guard's explicit staging mode after
copying the selected CI profile. With no caller-auth environment settings, the profile remains
byte-for-byte unchanged and the rollout stays `legacy`. Both pilots and dev environments have
approved enabled/coexistence settings and durable ownership secrets outside Git. The pilot
transitions were finalized, and both dev environments passed full provisioning and smoke on
the same source. These environment-specific settings are not copied by a fresh clone.

| Environment setting | Kind | Contract |
|---|---|---|
| `BYOK_CALLER_AUTH_PREPARATION` | Variable | Complete JSON object matching the typed preparation contract; absent leaves the selected profile unchanged |
| `BYOK_CALLER_AUTH_ROLLOUT` | Variable | Explicit `legacy`, `shared` or `coexistence`; absent preserves the selected profile |
| `BYOK_RESPONSE_OWNER_KEY` | Secret | Stable random 32-byte key encoded as canonical base64; required for active shared rollout |
| `BYOK_RESPONSE_OWNER_PREVIOUS_KEY` | Secret | Previous canonical key during rotation, or explicit `__none__` for no previous key; omission rejects active staging |

The existing tenant/audience environment variables still supply Entra settings. Ownership keys
are injected only into staging and provision/preview steps, never echoed or written to
`GITHUB_ENV`. The staged parameter document stores environment references, not secret values;
explicit `__none__` becomes an empty previous-key parameter. The helper validates before replacing
the target and leaves its original contents intact on failure. PowerShell and Bash reject zero,
noncanonical and repeated current/previous keys consistently. Ordinary pre-provision validation
remains read-only; staging is opt-in via `-StageCallerAuth` or `--stage-caller-auth`.

Generate an ownership key once in a secure operator environment and store it in the target
GitHub environment's secret manager. Never generate it per deployment or paste it into chat.
For approved rotation, retain the old current key as the previous key before supplying the new
current key; validate old and new stored objects before removing the old key. Choosing `__none__`
after rotation deliberately revokes access to objects signed only by the removed key. Key
creation/rotation, environment activation and a live persistence/rollback rehearsal remain
explicit operational gates. Missing CI secrets must not be treated as permission to erase state.

| `callerAuthRollout` | Behavior |
|---|---|
| `legacy` (default) | Retain legacy mode selection. Preparation may install inactive resources; no JWT-product links are added. |
| `shared` | Bind shared Foundry/AOAI consumers and response ownership. Add no new open-product links; with native keys enabled, JWT admission is not yet activated. |
| `coexistence` | Require native subscription admission and attach the explicitly JWT-guarded product to Foundry/AOAI after their policies are installed. |

**Rollback is detach-first.** Remove and verify the exact JWT-product/API links before
restoring legacy policies. Incremental ARM does not delete omitted links or the new conditional
AOAI Responses operations. Changing the rollout parameter to `legacy` alone is not a verified
rollback. Retain ownership keys while stored responses may still be used; do not rotate or
erase them as an incidental redeployment step. An approved CI rollout/rollback rehearsal and
secure owner-key provisioning are still required before customer activation.

#### Manual development transition

The development workflow has isolated `caller_action` values `activate`, `rollback` and
`finalize`. These actions target exactly one of `comm-dev`, `gov-dev`, `comm-pilot` or `gov-pilot`, require `smoke=false`,
and cannot be combined with recovery or the older JWT-preview flags. They never run full-stack
provisioning, self-heal, app builds, app registration, or smoke. Pilot targets require explicit
manual caller actions; push/schedule deployment stays dev-only. Code and fixture validation do
not prove a live transition or authorize one.

The focused template defaults to protected `shared` mode. `activate` explicitly previews
`coexistence`: all 49 expected APIM resources must be evaluated with no diagnostics or writes
outside the allowlist. `rollback` previews 48 resources and separately declares removal of the
JWT-product/Foundry association. Native subscription admission stays required in both modes.

1. Merge reviewed lifecycle guards before any apply, then ensure no older lifecycle job is
  active or queued for the target. A draft-branch preview is useful evidence, but its receipt
  cannot authorize a main-branch apply. Keep the existing owner keys and staged trust settings.
2. Dispatch the selected action with `preview_only=true`. Review the sanitized resource summary
  and `callerPreviewDigest`. It binds the exact commit, compiled template, APIM target, caller
  audience/scope/budgets, resolved inputs and ownership keys without disclosing those values.
3. After explicit operational approval and deployment validation, dispatch the same action on
  the same main commit with `preview_only=false` and the reviewed digest. A fresh preview must
  still pass. Rerunning an applying GitHub job is refused; a retry needs fresh review.
4. The action sets the non-secret `byokCallerTransition` resource-group tag before gateway
  writes. Dev provisioning/teardown, pilot preview/provision and smoke fail closed while a hold
  exists. Pilot previews and provision share the existing `dev-env-<environment>` lock with caller
  transitions and smoke; the prefix is retained for compatibility. Jobs are never cancelled by
  this path. A failed or successful apply
  leaves this hold in place; no automatic rollback or hold expiry is assumed.
5. For activation, review the readback, then an authorized operator sets the existing GitHub
  environment preparation JSON to `enabled=true` and rollout to `coexistence`, preserving every
  other trust field and both secrets. This workflow does not obtain a broader GitHub credential
  or modify environment variables. For rollback, persist `enabled=true` and rollout `shared`.
6. Preview `finalize` and review its digest and readback. The preview compares all expected
  resource properties, association state and exact owner-key values without changing gateway
  resources, settings or the hold. After settings are persisted, explicitly apply `finalize`.
  It repeats the readback and checks persisted settings before removing only its matching hold
  tag. A mismatch keeps the hold.

If deployment succeeded but its verifier failed, do not repeat activation. A newer verifier may
reconcile the original hold only when its artifact commit is an ancestor, the infrastructure,
policy and parameter-validation sources are unchanged, and the original receipt is reproduced
using the same compiled template, target, resolved trust settings and owner keys. The summary
reports `callerArtifactSource` separately from `callerVerifierSource`. A successful read-only
finalize preview is reconciliation evidence, not a retroactive success for the failed run or
permission to apply finalization. Review the new verifier and explicitly approve finalization.

Rollback first replaces the recognized JWT product guard with its denying form using the current
ETag, deletes only its Foundry association, and verifies absence with APIM's bodyless `HEAD`
contract plus the API product inventory. Only then does it apply protected `shared` consumers.
It does not restore legacy Responses utilities, delete auth/ownership resources, regenerate keys,
or remove native products/subscriptions. Retained responses remain caller-bound; JWT callers
lose admission until coexistence is separately restored. Live retained-object acceptance remains
required before claiming rollback is proven.

A partial transition can intentionally keep dev infrastructure alive past nightly teardown.
Reconcile it promptly and review the extra runtime cost; do not manually clear the hold to force
a legacy deployment through. Unknown holds, changed keys, changed product guards, another API
sharing the JWT product, or a changed source receipt require operator review. The hold is not an
Azure resource lock and does not prevent an out-of-band administrator from changing resources.

#### Pilot Test Rollout

Both existing pilots completed the approved focused rollout on 2026-09-27, Government first,
using main `95163d1`. Each activation and finalization verified all 49 caller resources; enabled
coexistence settings were persisted, ownership secrets preserved and matching holds cleared.
Native keys remain enabled and Okta disabled. This is deployed/control-plane-verified pilot
testing, not a completed customer release. The separate Packer-image request remains deferred.
The existing pilot VM can reach its own VNet; temporary pilot-to-dev peering is not a prerequisite.

For a future explicitly approved transition, compare the target's issuer metadata, gateway audience,
delegated scope, limits, native products and operation inventory against its own CI profile.
Use its cloud-pinned sign-in and durable ownership secrets; never replace existing keys or copy
another environment's trust. New targets stage disabled preparation first. These settings alone
do not activate JWT, and the prior pilot approval does not authorize another apply.

Resolve the APIM target from its exact successful `apim` deployment output, not a filtered resource
list. Dev transitions require their completed-baseline marker; pilots require healthy existing
groups and gateways. Read all collection pages using bounded same-service, same-path pagination,
rejecting unknown versions, duplicate entries and cycles. A missing first-page setting is not
permission to alter the live contract.

Obtain a fresh main-source preview receipt and separate apply approval. Follow the activation,
preserving-settings and matching-finalization sequence above. A retained caller hold blocks
ordinary pilot lifecycle jobs; drain older jobs and exclude out-of-band provisioning. No network,
backend, product-tier, native-key or model change is implied by this caller-only procedure.

Protected Responses follow-ups reject legacy objects without ownership markers. Use fresh test
conversations; do not disable ownership or exempt old objects to make a test pass. Retain the
original owner key through rollback and test retained-object recovery separately. Failed actions
do not authorize an automatic retry, key regeneration or rollback.

Actual client tests use the VM's signed-in interactive user session. Explicit native Copilot CLI
and IntelliJ custom CLI ACP use renewable JWT; native VS Code Custom Endpoint/ordinary Agent and
IntelliJ AI Assistant remain per-user subscription-key clients. Agent/Background/Agent Host needs
its own measured check. SYSTEM Run Command, copied caches and mock ACP fixtures do not establish
editor acceptance. Connectivity and model/expiry test windows require their own bounded approval.
All remaining package/security/accounting and retained-response gates stay open in #143-#147.

#### Isolated Client-Access Validation

The temporary VM-to-dev private-access design is test infrastructure for this engagement, not a
required customer release topology. Release acceptance still needs a working private client path;
customers may supply their own VPN, peering, ExpressRoute or in-VNet workstation. This helper is
not referenced by normal main, standalone or wizard deployment entry points.

`scripts/preview-private-client-access.ps1` and its Bash wrapper validate the existing VM, private
gateway, NSGs, complete dev subnet coverage and DNS before proposing 12 new resources and five
preserving subnet updates. They have no apply, cleanup, login or feature-registration operation.
Only the PE subnet gains NSG endpoint-policy enforcement; other policy settings, subnet prefixes,
delegations, NAT references and immutable outbound settings are preserved. Unsupported fields,
existing peerings, conflicting DNS/rules, stale snapshots and intervening changes stop validation.

From the repository root, with PowerShell 7.4+, standalone Bicep and an already authenticated cache:

```powershell
./scripts/preview-private-client-access.ps1 `
  -VmResourceId '<VM_RESOURCE_ID>' -GatewayResourceId '<APIM_RESOURCE_ID>' `
  -AzureConfigDirectory "$HOME/.azure-gov" -Cloud AzureUSGovernment
```

The default live path performs management-plane reads and local validation only. Add
`-ProviderPreview` for ARM validate/what-if; temporary resolved parameters have restricted access
and are removed afterward. Output contains counts, a bound digest and sanitized failure codes,
not resource IDs, addresses or raw policy/configuration. `-SnapshotFile` supports offline fixtures;
`scripts/tests/private-client-access.Tests.ps1` exercises that contract without Azure calls.

Even a passing preview reports `canApply=false`. Merged lifecycle protection, delegated-service
and effective-policy review, live isolation tests, a separate network-apply approval and subsequent
request/token budgets remain gates. Do not deploy the preview templates directly or treat a passed
snapshot as proof of client connectivity, renewal, production security or release acceptance.

#### Guarded Private-Access Session

[The session manager](../scripts/manage-private-client-access.ps1) and
[Bash wrapper](../scripts/manage-private-client-access.sh) add explicit `Plan`, `Apply` and
`Rollback` actions for the same-cloud pilot-VM to dev-gateway pair. They are isolated validation
tooling, not part of customer provisioning. No live apply or rollback has been accepted yet.
Local validation on 2026-09-27 passed 206 private-access cases, the existing 249 development-preview
cases, and Checkov 3.3.19 with 27 passed checks, zero findings and zero parsing errors. The scanner
checks a materialized 17-resource fixture; it does not establish effective network policy or
runtime compatibility of the delegated services.

Before applying, merge the reviewed guards in all four lifecycle workflows, require successful
validation and the **Private access security scan** job on the exact current main commit, and
drain older active or queued lifecycle jobs. Review effective NSG rules, routes and delegated-service
compatibility. Use one designated operator, one private journal and an attended maintenance window:
no parallel access sessions, old-branch dispatches, local azd provisioning, teardown, manual network
changes or other out-of-band writers may run during the window. Tag PATCH is not an atomic lease;
neither the local journal lock nor the tag prevents a second workstation or administrator writing.
Do not apply unless this operational exclusion can be maintained.

Create a fresh plan using the same checked-out source and pinned cache that will execute it:

```powershell
$stateFile = Join-Path $HOME 'byok-private-access/session.json'
$reviewedCommit = '<FULL_REVIEWED_MAIN_COMMIT>'
./scripts/manage-private-client-access.ps1 -Action Plan -StateFile $stateFile `
  -VmResourceId '<VM_RESOURCE_ID>' -GatewayResourceId '<APIM_RESOURCE_ID>' `
  -Cloud AzureUSGovernment -AzureConfigDirectory "$HOME/.azure-gov" `
  -ReviewedCommit $reviewedCommit
```

`Plan` performs reads only and writes an owner-restricted recovery journal outside the repository.
The digest binds the baseline, parameters, exact resource-write allowlist and execution sources.
The journal contains private topology and ETags: never attach it to an issue, paste it into chat,
include it in a VM bundle or edit it to bypass a mismatch. Keep it until rollback is verified.
A changed snapshot or source requires a new plan and approval, not a repeated apply.

After separate approval of that exact digest and the isolation review, the operator may run:

```powershell
$reviewedDigest = '<REVIEWED_PLAN_DIGEST>'
./scripts/manage-private-client-access.ps1 -Action Apply -StateFile $stateFile `
  -ReviewedDigest $reviewedDigest -ReviewedCommit $reviewedCommit `
  -Repository '<OWNER>/<REPO>' -AzureConfigDirectory "$HOME/.azure-gov" `
  -IsolationReviewConfirmed -ApproveNetworkChanges
```

Apply requires a fresh complete provider preview and a matching snapshot. It journals before
writes, reserves `byokPrivateClientAccess` on both resource groups, checks lifecycle inactivity,
installs and verifies isolation before either peering, then creates the exact DNS record. Existing
caller-transition holds also block reservation. Each resource write uses an absence/ETag condition;
an uncertain outcome stops without retries or automatic rollback. Runtime conditional-header and
asynchronous behavior still require the first approved live acceptance window.

Every guarded workflow blocks on any presence of the access tag, including an empty or malformed
value; it never treats age as permission to continue. The hold can retain dev resources past
scheduled teardown and incur additional runtime cost. **There is no automatic expiry or watchdog.**
The 30-minute check only refuses delayed completion of peering creation. The operator must time
the separately approved test window and explicitly close access afterward.

Run rollback from the original reviewed checkout, using the same protected journal and receipt:

```powershell
./scripts/manage-private-client-access.ps1 -Action Rollback -StateFile $stateFile `
  -ReviewedDigest $reviewedDigest -ReviewedCommit $reviewedCommit `
  -Repository '<OWNER>/<REPO>' -AzureConfigDirectory "$HOME/.azure-gov" `
  -ApproveNetworkChanges
```

Rollback disconnects verified owned peerings before removing DNS or restoring subnet settings;
it releases only matching holds after all 17 resources are restored or absent. It does not require
main to remain frozen, but does require the original execution files. Pending or externally changed
resources are not adopted, overwritten or deleted. For example, pending DNS stops cleanup only
after owned peerings are disconnected, retaining isolation and holds for review. If an uncertain
peering or changed ownership blocks disconnection, stop all tests and obtain an explicitly reviewed
network recovery action. Use exact ARM GETs and operation evidence to reconcile; do not relabel
the journal, clear holds, blindly rerun apply or treat a matching-looking resource as ownership proof.

#### VM Test Handoff

Use the existing Government Windows VM's signed-in interactive user session in VS Code and
IntelliJ. Run Command/SYSTEM, copied laptop token caches and fixture passes do not establish editor
acceptance. A source-only archive is for local tests and client helpers; the network manager must
run from the reviewed Git checkout with its original private journal. Do not package credentials,
local azd state, resolved parameters or recovery journals.

From the reviewed checkout or source archive, the offline preparation check is:

```powershell
pwsh -NoProfile -File ./scripts/tests/private-client-access.Tests.ps1
```

After the separately approved private path is applied, first verify normal DNS resolution and
TLS to the exact dev gateway plus bounded negative connectivity checks to non-target addresses.
No inference belongs in this transport-only stage. Stop on an unexpected allowed connection,
certificate failure or delegated-service regression, and close the temporary path.

Only after transport/isolation acceptance and a new request/token budget may actual client tests
start. Record the source commit, VM interactive-session context, client/extension versions, bounded
requests, expiry/renewal results and matching gateway accounting without recording tokens:

- Explicit native Copilot CLI, including the VS Code terminal: renewable JWT and actual expiry.
- IntelliJ custom native CLI ACP agent: actual IDE launch, continued-session renewal and recovery.
- Native VS Code Custom Endpoint/ordinary Agent and IntelliJ AI Assistant: per-user subscription
  keys, including regressions; they do not inherit CLI credential-command support.
- Native VS Code Agent/Background/Agent Host: inspect the actual UI/runtime separately; do not
  assume it invokes the configured CLI/helper.

Main/standalone Bicep/Terraform, VM/ACI/ACA and wizard/manual package acceptance, native accounting,
security negatives and retained-response rollback remain release gates. Customer Okta acceptance
stays separate and disabled by default. Neither this handoff nor dev control-plane success approves
pilot activation or claims a completed customer release.

### Foundry/AOAI consumers (implemented, default off)

[Foundry](../infra/modules/apim-foundry-api.bicep) and
[AOAI](../infra/modules/apim-aoai-api.bicep) compose shared authentication ahead of native
inherited accounting, then JWT-only limits and credential stripping before classifier/model
access. The shared principal selects JWT counters; native key callers retain their product
budgets. Model routing, backend credentials and native wire formats remain separate from
caller authentication. Classifier token attribution is not automatic limiter enforcement.

**Approved budget migration:** native subscription keys, Entra identities and Okta identities
have independent budgets for the initial release. A person holding more than one credential
can consume each applicable budget. There is no automatic cross-method or email-based linking;
native product tiers are not inferred from JWT claims. Keep this explicit during onboarding
and offboarding, and do not merge existing counters as an incidental deployment change.

Foundry discovery invokes authentication/stripping explicitly without inference body parsing,
limits or inbound base. All four Responses utilities also authenticate explicitly, verify
ownership and pin the owning backend before retrieval, deletion, cancellation or input-items
access. They preserve streaming and query parameters without inherited inference counters.
The main rollout binds both module hooks; direct module callers must supply matching auth and
ownership dependencies. Fresh compilation/structural tests are not full gateway acceptance.

### Group-Assigned JWT Tiers (In Progress)

#154 adds an explicit
`callerJwtTiering` contract. Both issuers default off. The main-template implementation
projects its limits from `productTiers`, so native product policies and JWT tiers have one catalog.
This does not assign a JWT user an APIM subscription or combine key/Entra/Okta budgets.

Entra uses a validated gateway-access-token `roles` claim populated by administrator-assigned
app roles. Okta uses an administrator-controlled claim, `byok_tier` by default, in an access
token from the configured custom authorization server. Okta accepts a string or string array;
Entra roles must be an array. Neither path reads a caller-supplied header or performs Graph/ARM
membership lookups. Signature, issuer/audience, scope, delegated-user and allowed-client checks
still precede tier selection. Real Okta setup and acceptance remain customer-gated in #146.

The configuration shape below is intentionally disabled and contains no customer assignments:

```json
{
  "entra": {
    "enabled": false,
    "mappings": [
      { "claimValue": "BYOK.Standard", "tier": "byok-standard" },
      { "claimValue": "BYOK.Power", "tier": "byok-power" }
    ]
  },
  "okta": {
    "enabled": false,
    "claimName": "byok_tier",
    "mappings": []
  }
}
```

When an issuer is enabled, exactly one distinct mapped tier must resolve. Missing, malformed,
duplicate or conflicting tier claims reject with 403; unrelated roles do not select a tier.
Multiple distinct configured role values may select the same tier, but cannot stack allowances.
Role values are case-sensitive; the Entra app role and `claimValue` must match exactly.
Enabled main tiering requires an explicit reviewed catalog of one to eight tiers, enabled matching
issuer trust and `shared`/`coexistence` rollout. The paired guards validate configuration before
writing staged parameters and do not allow the legacy skip switch to bypass tier checks.
Explicit staging accepts `BYOK_CALLER_JWT_TIERING`. The pilot and dev workflows bind this optional
environment variable. Source defaults and committed CI profiles remain disabled; the two pilot
environments were explicitly enabled for the approved single-account test on 2026-09-28. An absent
value preserves the existing parameter file and flat JWT behavior.

The renderer inlines selection into the existing caller-limits fragment and generates mutually
exclusive literal limit branches. This is necessary because `quota-by-key` does not permit runtime
expressions for its call ceiling. All branches preserve `callerPrincipalKey`, successful-call
increment semantics, token estimation and the fixed 30-day quota window. A disabled issuer retains
the flat JWT branch; with both disabled, the original caller-limits policy is byte-for-byte unchanged.

These checks preserve counter identity in generated code; they do not prove live APIM usage survives
tier changes or redeployment. That requires the separately approved two-cloud quota-continuity and
rollback tests. Old tokens may retain old role claims until expiry. Do not use tiering as immediate
revocation, a shared department pool, a global gateway counter or a financial spending guarantee.

For an approved manual group-switching test, use the gateway API's assigned security groups,
not the registration portal's native-key onboarding groups. Remove the account from its previous
tier group and add it directly to the other; do not leave it in both. After membership propagation,
acquire a newly issued gateway access token and verify the expected `roles` value locally without
printing or sharing the token. A cached token keeps its old tier until replaced or expired. Restarting
a client alone might reuse its token cache; verify the new role rather than assuming renewal occurred.

The gateway chooses caps for the validated caller at request time. Group switching does not create
an APIM subscription, alter native-key caps or require a policy redeployment. No tier or two distinct
mapped tiers produce 403 when Entra tiering is enabled. The `x-byok-calls-remaining`,
`x-byok-tokens-remaining` and `x-byok-tokens-consumed` headers can help observe applied inference
limits, but are not a fresh allowance or proof of quota reset. Use a JWT-capable CLI surface for
this test; ordinary native-key editor requests do not exercise the Entra role selector.

Standalone VM/Container Apps Bicep and wizard upgrades accept the same `callerJwtTiering` and
`productTiers` inputs. Terraform uses `caller_jwt_tiering` and `product_tiers` with the same nested
mapping/catalog field names. Supply the existing gateway deployment's reviewed catalog; these
bolt-ons do not overwrite native product policies. Regenerate the caller policy package from the
same source before Terraform planning. Its versioned `tiering` capability exports the exact Bicep
selector and branch templates; enabled tiering rejects an older package without that capability.

Installer preflight and Terraform require classic Developer/Premium APIM for enabled tiering.
Container Apps requires `configureApim=true` to change tier configuration; when reusing another
deployment's API, omit tier settings and manage them through that API's owner. No v2 behavior is
inferred from the classic counter contract.

The focused caller workflow now validates and carries Entra tier mappings and the full reviewed
catalog into its approval fingerprint. Role, tier, flag or ceiling changes invalidate the receipt.
It retains the existing 49-resource coexistence / 48-resource protected-shared scope, exact policy
readback, matching persisted-settings finalization and unchanged ownership keys. This workflow
still permits only its existing Entra/native-key trust profile; it does not activate Okta.

Numeric catalog changes that must also change native product policies need the owning full-stack
deployment; a caller-only transition does not edit products. Disable or change JWT tiering only
through a freshly reviewed receipt and persisted configuration. Removing a parameter is not proof
of rollback or retained quota continuity. Publishing code is not approval to activate it.

Two optional metrics expose tier-level behavior without raw group, role or identity claims:

| Metric | Meaning | Dimensions |
|---|---|---|
| `copilot_byok_tier_admitted` | Request passed the selected tier's limit policies; not proof of backend success or a token-usage total | `auth_method`, `tier`, `operation` |
| `copilot_byok_tier_throttled` | Selected-tier rejection from the gateway burst, token or call-quota policy; not a backend 429 | `auth_method`, `tier`, `operation`, `throttle` |

Flat/disabled issuers emit neither tier metric. Existing per-caller metrics and their dimensions
remain unchanged. The [throttle query](../monitoring/kql/throttle-hits-per-developer.kql) includes
a separate workspace-based tier view. No tier metric ingestion or live KQL validation has run yet.

**Pilot deployment verified (2026-09-28):** Entra tiering is installed and finalized in Government
and Commercial on source `5b23eb3c45e3f9cd002c81fdd8765a81eefdc485`, with explicit exact-receipt
approval. Government activation/finalization were 36469270763 / 36475108603; Commercial were
36476074046 / 36478222484. Each activation, finalization preview and finalization passed the exact
49-resource CI readback with zero diagnostics/omissions. Both transition holds are cleared.

| Entra Role | Calls/Minute | Tokens/Minute | Calls/Fixed 30 Days |
|---|---:|---:|---:|
| `BYOK.Standard` | 60 | 100000 | 50000 |
| `BYOK.Power` | 120 | 200000 | 200000 |

The dedicated BYOK JWT Test Standard/Power security groups are assigned to these roles; the primary
test account starts in Standard and Power is empty in each tenant. Government's primary account is
licensed for Entra premium. Fresh gateway tokens were checked for the expected immutable identity,
audience, scope and single Standard role without printing credentials. The second account was only
removed from the dedicated Power group; its directory user was retained. Dev and pilot share the
gateway API app registration within each cloud, but only pilot tier settings were enabled.

Native-key product policies and backend resources were outside the apply scope, and CI verified
native admission and existing ownership-key values. The additional independent local before/after
hash comparison was unavailable after the observer terminal closed and local Government APIM read
access failed; the owner explicitly approved finishing with the exact CI verification path. No
assistant model traffic or live group-switching/limit test was run. Quota continuity, multi-user
isolation, JSON/SSE limits, telemetry ingestion, retained-object rollback and actual client renewal
remain acceptance gates. Okta remains disabled and customer-gated; #154's runtime acceptance is
not complete.

### Stateful Responses ownership

The owner explicitly retained full stateful Responses rather than a stateless-only release.
[The ownership module](../infra/modules/apim-response-ownership.bicep) deploys five flat
fragments for owner context, request preparation, metadata lookup, verification and bounded
store location. The implementation preserves `store`, background mode, streaming/resume,
`previous_response_id`, and get/delete/cancel/input-items operations.

- A stable secret `responseOwnerKey` signs the validated caller principal with HMAC-SHA256.
  It is an APIM secret named value, never an output. `responseOwnerPreviousKey` permits a
  controlled two-key rotation window; removing an old key makes its older objects inaccessible.
- Creation overwrites reserved `metadata.byok_owner_v1`; clients may use up to **15 other
  metadata entries**. Existing objects without a valid marker are not automatically adopted.
- A follow-up or continuation searches at most eight configured concrete backend stores using
  separate backend credentials. It verifies the exact response ID and owner marker, then pins
  the operation to that backend. Model-family mismatch rejects instead of cross-account fallback.
- Denied ownership prevents the requested operation or continuation, but verification itself
  can read backend metadata using trusted credentials. Do not describe that as zero backend contact.
- Non-null `conversation` references and `input` item-reference objects are rejected because
  their separate ownership contracts are not implemented. They are not silently made stateless.
- Gateway-only stamping is a deployment trust prerequisite: direct backend access and legacy
  routes that can create or alter metadata must not bypass it. The HMAC marker is not a substitute
  for that boundary. Live persistence, cross-user/key isolation, rotation and all stateful
  operation tests remain release gates.

### Fresh shared runtime evidence (2026-09-21)

Approved isolated `SharedRuntimeGate` runs completed installation of all eight actual flattened
auth/accounting/ownership fragments on classic internal APIM in **both clouds**. Fragment writes
used completed ARM operations plus readback, not initial 200/201 acceptance. Only auth and
credential stripping were executed by the signed-token API; creating other fragments does not
prove their composed policy placement, quotas or ownership behavior.

| Signed-token control | Government | Commercial |
|---|---|---|
| Missing / malformed / tampered / mixed-source credential | 401 for each | 401 for each |
| One valid JWT in `api-key` / Bearer | 200, validated and stripped | 200, validated and stripped |
| Exact-identical repeated Bearer | 200, validated and stripped | 401 |

Each cloud passed **7/7** under `single-credential-v1`; no model/backend was called. Temporary
APIs, fragments and token-transport certificates were removed with readback. Government's
running VM was preserved; Commercial's VM was restored to deallocated. Earlier failed attempts
remain failures: they exposed unfinished ARM writes, unsupported `System.UriKind`, and a
diagnostic `on-error` block masking JWT 401 as 500. All were repaired before these fresh passes.

The subsequent complete-policy compatibility gates imported the same Bicep templates
used by deployment through [the local renderer](../scripts/tests/caller-policy-render.bicepparam).
Foundry inference, AOAI inference, discovery and the shared Responses utility all installed and
returned their mandatory first-statement diagnostic 403 (**4/4 in each cloud**). This proves
composition acceptance, not feature execution. Government's earlier TCP-preflight failure
remains failed history; the later completed compatibility run is separate fresh evidence.
No NSG, HTTP/2 or production policy was changed.

An owner-approved, no-model governance matrix now uses temporary native keys/products, two
real delegated users, isolated counters and an APIM-subnet-only VM mock. Its lookup credential
and destination are substituted solely for the diagnostic; production ownership logic is
retained. This cannot prove real backend persistence or backend TLS. Early setup/transport
failures and a duplicate-inheritance error in the explicit test operation were recorded, not
counted as acceptance. Receipt audits distinguish metadata verification reads from requested
operations. The completed Commercial result is recorded below; this does not replace full
production integration or Government acceptance.

### Commercial governance evidence (2026-09-22)

The corrected `SharedGovernanceGate` passed **175/175 checks**, with zero failures and a
passing final backend-receipt audit under `single-credential-v1`. This used actual shared
authentication, accounting and ownership fragments on classic internal APIM, two real Entra
delegated users, and temporary native subscriptions/products. All backend responses and stored
objects were synthetic; no model was called.

- Native key controls covered two subscriptions, secondary/API/all-API/rotated keys, rejected
  old/suspended/wrong-scope/unlinked keys, and supported query-key admission.
- Independent single-token positives passed for both users. Conflicting valid JWTs rejected
  in both header orders without backend calls. Identical duplicates rejected with 401 in
  Commercial, as the approved contract permits.
- Native and JWT call/monthly budgets remained independent. Alias requests shared their
  caller's counters; mixed credentials did not consume an allowance. JWT rate limits retain
  APIM's deferred-increment behavior, not a promise of exact distributed request accounting.
- Chat and Responses JSON/SSE TPM fixtures passed for each user: an initial 200 followed by
  two 429s without backend execution. JSON reported 270 consumed tokens. Streaming response
  headers reported early estimates (8 for Chat, 1 for Responses), not final usage totals;
  these headers are not proof of complete streaming telemetry.
- Four caller identities (two JWT users and two native subscriptions) created stamped
  background responses with preserved tools/reasoning. Cross-owner get/delete/cancel/input-items
  and continuation attempts rejected; owners could retrieve, resume, cancel, continue and delete.
  Unstamped/deleted responses and a tampered utility token rejected. Lookup reads and actual
  operations were audited separately, with caller credentials stripped.

The preceding 23-case admission run had ten failures because the PowerShell harness collapsed
a single credential-header array into a string and concatenated its correlation header onto the
credential. That run remains failed evidence. The transport now preserves typed header arrays;
15 local request-evaluator checks cover zero/single/multiple headers and receipt semantics.
Fresh main/module builds, exact consumer rendering and compiled-package checks pass.

The successful run removed all owned APIs/products/subscriptions/backends/fragments, listener,
firewall rule and transport certificates with readback; the Commercial VM returned to deallocated.
No production policy, NSG, HTTP/2 setting or CI deployment changed. Remaining gates include
Government governance, real backend TLS/persistence and gateway-only stamping, owner-key
rotation/lifecycle, full feature-policy execution, telemetry, remaining packages/clients and
approved CI rollout/rollback. No issue or release is complete solely from this mock result.

### Government governance checkpoint (2026-09-22)

**Fresh corrected run: 175/175 PASS**, zero failures, final receipt audit true under
`single-credential-v1`. All signed-auth controls (7/7) and deny-prefixed consumer compatibility
checks (4/4) passed again. This is the same mock-backed native-key, two-user JWT, isolated quota,
JSON/SSE TPM and four-caller stateful ownership matrix described for Commercial. Cancellation
requests now carry explicit zero content length. No real model was called; real backend
persistence, TLS and full feature-workflow acceptance are still separate gates.

The owner-approved VM-only TCP80 revocation window kept strict TLS and certificate revocation
enabled. All owned APIs, products, subscriptions, backend, fragments, listener, firewall rule
and transport certificates were removed with readback. The exact temporary NSG rule was also
removed and Government's original running VM state preserved. No window or test remains active.
The successful run used a reusable per-run ARM web session and refreshed both users for the
same explicit delegated scope after setup; the fifteen-minute token margin was not reduced.

The failures below are historical attempts, not the result of this fresh run.

Government completed the 175-case matrix with **159 passing checks and 16 cancellation failures**.
The failed owner/cross-owner cancellation POSTs returned 411 before ownership lookup because
the raw diagnostic client omitted `Content-Length: 0`. That is not an accepted authentication
rejection. The serializer now explicitly frames empty POSTs, with a passing local regression;
the historical matrix and failed final receipt audit are not relabeled as a pass.

Two corrected reruns then stopped before the governance matrix: one consumer check returned no
structured result; the next failed strict transport preflight before creating resources.
Consumer failures now report a fixed transport-stage label instead of losing all observations.
Interleaved read-only checks passed strict TLS/HTTP, showed DNS resolving to the expected private
gateway address, and succeeded on direct private TCP. The observed connectivity interruption is
intermittent; its cause is not established. The VM's VNet allow/Internet deny rules were only read,
never changed. Do not infer durable reachability or final governance acceptance from a spot check.

All created diagnostics from those attempts were removed and Government's original running
VM state was preserved. The completed fresh run above now closes this mock-matrix rerun gate.

Subsequent stage timing identified a concrete transport failure: DNS/TCP completed in milliseconds,
while TLS took about 51 seconds and failed with `RevocationStatusUnknown, OfflineRevocation`.
An explicitly owner-approved diagnostic window allowed outbound TCP 80 from only the Government
VM `/32`, with strict TLS/revocation still enabled. The signed-auth/consumer checks passed inside
that window, but a separate local ARM HTTPS connection failed during governance setup; no full
matrix pass is claimed. All diagnostic resources and the exact temporary NSG rule were removed
with readback, and the VM remained running. No window or test remains active. Durable client
certificate-revocation egress is still a customer network-design requirement, not a permanent
allow rule created by these tests.

Fixture setup also outlived captured-token freshness and briefly lost existing PIM access.
The owner refreshed existing access; a paginated inventory then confirmed zero leftovers.
The harness now obtains a second-user `SecureString` after resource/certificate setup and requests
the first-user token for the same explicit delegated scope used by the refresher, avoiding a
different cached `/.default` token. The fifteen-minute minimum remains unchanged. Synthetic limiter
variants inline the actual accounting fragment to avoid six redundant diagnostic resources;
production packaging is unchanged. These corrections preceded the fresh 175/175 run above;
earlier failed attempts retain their original outcomes.

### Real Foundry acceptance (2026-09-22)

The owner approved at most four Responses creation attempts per cloud, at most 256 output
tokens each, using synthetic prompts and isolated policies. Both clouds completed the same
four phases: initial checks (31 observations), key rotation (3), old-key retirement (3) and
cleanup (3). All phases passed. One observation per cloud records cancellation timing as
**inconclusive**, not proof of cancellation of an active job.

The fixture consumed all four POST-attempt slots per cloud: three actual stored responses and
one cross-owner continuation rejected with 404. No automatic inference retries or Chat calls
were made. A session-local allowance prevents an unreviewed repeat, and the VM persists the
response IDs/attempt state encrypted to its temporary certificate before sending creations.

Verified with the existing Foundry backend and its managed-identity authentication:

- Both real delegated users and a native subscription listed the selected Responses model;
  missing/malformed credentials and missing diagnostic access were denied.
- Background streaming and native-key responses persisted gateway-stamped metadata instead
  of the client-supplied marker. Requests retained tools and nonzero reasoning effort.
- Other users and the other authentication method could not get, delete, cancel, enumerate
  input items or continue the owned object. Owners could read metadata/input items and replay
  the stored background stream.
- A diagnostic-only key rotation kept old objects readable using the previous key; an owner
  continuation created under the new key received a new marker. Removing the previous key
  denied old objects while the new object remained readable. Restoring the diagnostic previous
  key allowed verified deletion of all three objects.
- Backend HTTPS name/chain validation was not disabled. The Government VM used its approved,
  temporary VM-only revocation window; strict client certificate checks remained enabled.

The actual Bicep-rendered Foundry consumer was used with diagnostic admission/body limits,
isolated counter/metric names and automatic inference retry removed to enforce the approved
budget. Only Responses/discovery operations were registered. This does not prove AOAI-specific,
regional-pool, cross-cloud backend, auto-classifier, manual/proxy package or all client behavior.
No telemetry-ingestion assertion was performed by this run. The background job finished before
cancellation, so its documented 400 was accepted only as an explicit timing limitation; mock
owner/cross-owner cancellation policy checks passed separately.

All six real stored responses across both clouds were deleted and subsequent reads returned
404. Encrypted VM state, transport certificates and owned APIs/products/subscriptions/fragments
were removed. Government's exact temporary NSG rule was deleted; Commercial returned to its
original deallocated state and Government remained running. Production APIs, ownership keys,
backend resources and CI environment settings were not changed. No live test remains running.

### Anthropic new-auth deferral (2026-09-21)

The owner approved deferral after a bounded Commercial mock-only test of classic APIM's
`llm-token-limit`: OpenAI JSON/SSE controls enforced the limit, while native Anthropic JSON
and SSE each allowed all three requests. The JSON counter reported zero; the streaming header
reported eight despite declared native usage of 270. The older `azure-openai-token-limit`
also failed the native JSON case. Earlier transport-incomplete attempts are not passing evidence.
No real model was called; diagnostic APIs, mock listener and scoped Windows firewall rule were
removed, and VM power was restored.

Initial shared-auth delivery is **Foundry/AOAI**. Existing Anthropic route/authentication is
unchanged and is not linked to the new JWT product. There is no call-only quota waiver or claim
that native Anthropic TPM is enforced by these policies on classic tiers. Anthropic new auth
requires a separately accepted native-usage accounting solution.

## Policy coverage

| Surface | Current deployment relationship | Required coverage |
|---|---|---|
| Foundry inference | Default when Foundry is enabled | Authentication, identity and limits |
| Foundry model discovery | Same API; operation skips API inbound | Explicit authentication before backend call |
| Responses get/delete/cancel/input-items | Shared owner-checked policies are opt-in; skip API inbound | Live cross-user ownership and stateful operation acceptance |
| Anthropic messages | Existing route unchanged; new auth explicitly deferred | Separate accepted native-usage accounting before new-auth activation |
| AOAI inference | Optional | Same trust rules when enabled |
| IntelliJ main gateway proxy | Forwards to Foundry APIs, not a separate inference policy | Preserve/normalize either credential without treating a JWT as an authenticated subscription |
| Standalone IntelliJ bolt-on | Separate inference and discovery policies | Both policies; Bicep and Terraform packaging parity; VM and Container Apps proxy paths |

The main gateway's JWT policy variants are [Foundry inference](../policies/byok-foundry-policy.xml),
[discovery](../policies/byok-foundry-models-policy.xml),
[Responses follow-ups](../policies/byok-foundry-responses-item-policy.xml),
[Anthropic](../policies/byok-anthropic-policy.xml) and [AOAI](../policies/byok-aoai-policy.xml).
Existing key variants must retain their validation and accounting behavior during migration.
The standalone Bicep/Terraform and wizard/manual shared packages are now implemented locally.
They have not been live-upgraded or accepted. Changes to the main deployment do not retrofit
customer-installed policies. Keep legacy defaults until the relevant package gate passes.

### Package Engineering Checkpoint (2026-09-23)

- Fresh main, module and standalone Bicep builds pass: 36 templates, no warnings. Terraform
  validation and ten isolated mock plans pass with the shared nginx installer; paired
  standalone parameter validation has thirteen cases. The private topology/deployment helper
  has 49 mocked cases. Namespaced auth/ownership policies share the canonical sources.
- The wizard/manual overlay compiles and has 24 composition cases, eight operation-inventory
  gates, a private temporary-parameter-directory test and full mocked preflight. The old BASIC
  installer rejects shared-policy/open-product overwrite before mutations. The upgrade selects
  a repository baseline, not an arbitrary customer policy merge; review customer feature changes
  and operation overrides before adoption. All sixteen actual main/standalone/wizard policy
  consumers were accepted by APIM in both clouds and returned their mandatory first-statement
  diagnostic denial. This proves policy compatibility, not execution of those full feature paths
  or a successful customer installer deployment.
- A real stock-nginx matrix initially passed 52 cases. Expanded coverage then exposed empty
  credential-header loss; that earlier pass is not acceptance. The new njs raw-header gate has
  33 selector cases and 88 forwarding/TLS/conflict checks across four configurations per runtime.
  No-push image tests passed for the actual main nginx 1.25.5 and standalone nginx 1.28.0 images,
  plus the pinned nginx 1.30.5/njs 1.0.1 installer on Ubuntu 22.04 and the actual runner base.
  The final installer tests include fail-closed VM bootstrap ordering. No image was published
  or deployed; complete proxy-to-APIM, long-stream and customer installation gates remain.
- Both clouds passed 175 mock-governance cases and 30 admission-rollback cases. Detaching the
  JWT product rejected both JWT users while valid native key variants remained usable; restoring
  the native-only guard retained the owner keys and four protected utility policies. Both legacy
  and issuer-qualified throttle metrics ingested matching totals: burst 2, tokens 16, quota 4,
  with two subjects and zero invalid identity rows in each bucket. Commercial's initial telemetry
  harness failure was repaired and the already-emitted data queried without replaying traffic.
  All resources owned by these operational runs were removed and VM power restored. This is not
  a CI deployment rollback or a post-deployment retained-object recovery test.
- The Okta helper uses maintained OAuth/OIDC and JOSE libraries, exact user/client/API binding,
  browser PKCE, OS-keystore-protected encryption and serialized refresh rotation. Eight local
  tests including a disposable Windows keystore entry passed; both CLI launcher suites passed.
  No real Okta request was made. All fifteen native CLI wire tests passed, including the pinned
  editor launcher over strict HTTPS; actual editor UI acceptance is not implied by ACP tests.
- CI gates are wired, but the runner image needs its newer Bicep compiler and nginx njs module.
  The first PR checks exposed Bicep 0.30.23, Node setup after its first consumer, and runner
  2.335.1's service cutoff on 2026-09-24. The initial published candidates are retired from adoption.
  Commercial access was restored without infrastructure recreation. Supported runner 2.337.0
  replacements from source `c6aa05730fe4` built in both clouds with verified digests; `latest`
  was unchanged. Node setup now precedes credential tests. Both exact job snapshots passed the
  required deployment validation and image-only previews with existing AcrPull and no new roles.
  Commercial adoption succeeded while idle, with full raw configuration equality except the image
  and an encrypted rollback snapshot. Government then passed the same adoption checks. Fresh
  executions in both clouds verified runner 2.337.0. The approved PAT rotation also completed for
  the repository and both private pilot vault/job copies, with fresh pings and no network/RBAC
  changes. The remaining package CI failure was a leaked expected-negative exit code; its explicit
  success-exit fix passed local success/failure checks and awaits the required CI rerun.
  Source is published on an isolated branch. PR merge is approved only after required CI, scoped
  review and baseline deployment validation pass; pilot API activation remains unapproved.

## Entra and Okta choices

**Entra today:** request an access token for the gateway app, not Azure Resource Manager
or Cognitive Services. Existing policies expect the gateway app client-ID audience and
delegated `cli.invoke` scope. App-only client-credentials tokens are a different identity
contract and are not supported by that delegated-scope check unchanged.

**Okta federated sign-in to Entra:** Okta authenticates the user, but Entra issues the API
access token. The gateway continues validating Entra; users still need their Entra identity
and gateway permissions. Federation, MFA and cloud support must be validated for the tenant.

**Direct Okta access tokens (opt-in, pending customer validation):** configure an Okta custom authorization server for
this API, an API audience, scopes, authorized client applications and user access policies.
Okta org authorization-server access tokens are for Okta APIs, not this gateway. Confirm
production API Access Management licensing. Add opt-in deployment settings for the exact
issuer/discovery endpoint, audience, scope and any client restrictions; keep Okta disabled
by default and keep tenant-specific values outside committed files.

Prefer a user authorization-code flow with PKCE and secure refresh-token storage for
developer clients. Do not distribute a shared confidential-client secret to desktops or
claim service-account tokens identify individual developers. API scopes, client restrictions
and authorization-server policies must prevent unwanted machine-to-machine access.

Clients need access to their IdP sign-in/token endpoints. APIM needs approved discovery/JWKS
access and working signing-key rotation. Verify Commercial/Government cloud boundaries,
egress controls and the customer's Okta service/compliance requirements explicitly.

## Identity, quotas and operations

- Preserve key callers' subscription identity and product-tier limits. For JWT callers,
  use issuer-qualified stable identities and explicit limits; a JWT does not automatically
  select an APIM subscription or inherit a product tier.
- Record authentication method/issuer separately from subject; retain existing dashboard
  compatibility deliberately. Never log access tokens, subscription keys or refresh tokens.
- Missing identity must fail authorization rather than collapse users into an `unknown`
  quota bucket. Do not use mutable email addresses as stable authorization keys.
- The same person using a key, Entra and Okta is three identities unless a trusted mapping
  links them. Define cross-method quotas before allowing migration to multiply a user's budget.
- Disabling an IdP account does not revoke its APIM key. Locally validated access tokens
  may remain usable until expiry unless an explicit revocation mechanism is added.
- The registration app is currently Entra-based. Direct Okta gateway support does not add
  Okta portal sign-in, group synchronization or automatic subscription offboarding.

## Client changes

| Client | Existing key users | JWT migration |
|---|---|---|
| Copilot CLI | No change | Opt in with `-AuthMode jwt -RefreshToken` or `AUTH_MODE=jwt REFRESH_TOKEN=1`; Government expiry renewal and real Responses inference passed; use Responses for GPT-5.6 tools plus reasoning; Commercial coverage remains open |
| VS Code running the configured native Copilot CLI | No change to other providers | Use the pinned CLI launcher and renewable credential command; actual editor launch/session acceptance is required, and native background/Agent Host bridges are not assumed equivalent |
| IntelliJ custom Copilot CLI ACP agent | No change to other providers | Use the pinned CLI launcher in ACP mode; actual IDE launch/session acceptance is required, not the built-in language-server-backed Copilot entry |
| VS Code Custom Endpoint, including Agent mode using it | Keep per-user APIM subscription key | JWT renewal is outside the approved native-provider support boundary |
| IntelliJ AI Assistant model provider | Keep per-user APIM subscription key and existing proxy path where required | JWT renewal is outside the approved native-provider support boundary |

CLI 1.0.85 documents command output as `api-key` for `azure`, Bearer for `openai`, and
`x-api-key` for `anthropic`. Use the provider that preserves the required URL/wire format.
The command should print only the access token to stdout; caching, expiry handling and
interactive reauthentication belong to the helper. The opt-in Okta helper remains disabled until
customer validation. The [pinned editor launcher](../scripts/start-copilot-agent.ps1) binds the
native executable, workspace, endpoint and user/cloud/cache without putting tokens in editor
configuration. Its local real-CLI test verifies one ACP session, renewed credentials and no provider
request after helper failure, but does not certify either editor's integration.
The owner requires both VS Code's CLI terminal and native Agent/Background experience, plus
IntelliJ's custom ACP agent, to pass separately in the Government VM's interactive user session.
Test inference, utility requests, discovery and long-running sessions, not just provider help.

The paired token helpers now use the existing Azure CLI cache for each request, pinned to the
configured cloud, tenant and delegated account. Local helper/wrapper tests and three real CLI
loopback checks initially passed, including both wire APIs' retry acquisition and no provider request on
credential failure. On 2026-09-21, the interactive Government VM user also passed both Responses
and Chat Completions through a disposable private APIM fixture with CLI 1.0.85: each process
exited 0, invoked the pinned helper once, and received its unique synthetic response proof.
Missing/invalid credentials returned 401, and API, local-file and CRL-rule cleanup all passed.

The subsequent long-running Government test also passed both wire formats after actual token
expiry in unchanged CLI processes/sessions, with renewed-token and fresh-response evidence.
The CRL allowance was closed while idle; all final cleanup passed. This verifies the real
CLI/helper/gateway path and same-session renewal. Model-inference evidence comes from the
separate user-session run below; Run Command's SYSTEM account cannot substitute for that
user's sign-in.
See the [client validation evidence](feature-request-byok-credential-refresh.md#validation-evidence).
The loopback suite covers persistent ACP sessions, simulated expiry/failure controls, and
backend-error reporting. In the separate bounded real-model VM gate, Responses passed with
10,491 input and 9 output tokens; persisted model/frontend 200 records and token metrics match.
Chat failed with CLI exit 1 and a correlated model-backend 400. Missing usage does not prove
the backend was not called. The approved one-request diagnostic then captured HTTP 400 with
`invalid_request_error` naming `reasoning_effort`; all cleanup passed. This matches
[Microsoft's documented GPT-5.6 restriction](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/reasoning#tool-calling-with-reasoning-models):
Chat requests with function tools require `reasoning_effort=none`, whereas Responses supports
tools with reasoning. The CLI's local wire characterization contained tools and `medium` effort.
The owner chose Responses and stopped further Chat attempts, rather than silently disabling
reasoning. Chat without reasoning has not been tested. The model limitation is separate from
the passed authentication and renewal checks, and the failed Chat model call remains negative
evidence. No API-version change or production normalization was made; the loopback capture was
temporary diagnostic equipment, not a production proxy.
Production APIs were unchanged by that client test. The later owner-approved compatibility
exception supersedes the duplicate-header parity release gate, not the remaining security gates.

#### Start JWT Mode In A Clean Shell

**Windows JWT CLI handoff: two scripts, one entry point.** Your operator supplies matching copies
of these files in the **same folder**; a full repository clone is not required:

- [copilot-cli-byok.ps1](../scripts/copilot-cli-byok.ps1): the launcher. This is the only script
  the developer runs directly.
- [get-byok-token.ps1](../scripts/get-byok-token.ps1): the credential helper. The launcher invokes
  it for preflight and configures Copilot to invoke it for subsequent requests. Do not run it
  manually; its stdout contains the access token.

The launcher sets `COPILOT_PROVIDER_*` and `COPILOT_MODEL` in the current shell from the supplied
settings. Neither the portal's [Use-Byok.ps1](../app/register/src/Installers/Use-Byok.ps1) nor
[Use-Cloud.ps1](../scripts/Use-Cloud.ps1) is required for this JWT CLI path. If also using the portal
installer for VS Code's subscription-key setup, use its `-SkipCliEnv` switch so it does not write
persistent key-based CLI settings. The two-script handoff does not include the Azure CLI and
Copilot CLI executables; their prerequisite setup is described below.

JWT mode requires Azure CLI and a delegated-user sign-in; the launcher now guides first-run
authentication instead of requiring manual cloud and login commands. The
[PowerShell launcher](../scripts/copilot-cli-byok.ps1) first looks for `az` on PATH and in the
standard Windows MSI and launcher-managed per-user installation locations. It verifies version
2.54.0 or newer, which provides the token-expiration field used by the credential helper. Existing
installations are reused, not silently upgraded or overwritten.

On 64-bit Windows, add `-InstallDeps` to the existing JWT launcher command to install Azure CLI
when missing, or approve the interactive `[y/N]` prompt. Noninteractive execution requires the
switch. The installer uses Microsoft's version-pinned x64 ZIP distribution (currently **preview**),
extracts it under `%LOCALAPPDATA%/Microsoft/AzureCLI-BYOK/<version>`, and adds its `bin` directory to
the current process PATH. It does not require WinGet or elevation and does not change the persistent
user/machine PATH. Later launcher runs rediscover that installation. Temporary download/extraction
files are cleaned up; existing installation directories are never overwritten. Broken or outdated
installations require explicit repair/upgrade.

This download needs approved HTTPS access to `azcliprod.blob.core.windows.net`; the launcher does
not change firewall/proxy rules. Managed or offline machines can have Azure CLI preinstalled using
an approved method instead. See [Microsoft's Windows installation options](https://learn.microsoft.com/cli/azure/install-azure-cli-windows).
The [Bash counterpart](../scripts/copilot-cli-byok.sh) continues to require platform-specific
dependency installation outside the launcher, including Azure CLI and `jq` for JWT setup. Azure CLI
is not required by either launcher's native subscription-key or Okta mode.

**First sign-in:** obtain the gateway URL, application client ID, directory tenant ID and model
from your operator. For a tier-enabled gateway, the operator must also assign your account to
exactly one mapped tier through the gateway API's groups/roles, not the registration portal's
native-key onboarding groups. The pilot groups are `BYOK JWT Test Standard` and
`BYOK JWT Test Power` in the matching tenant.

Run this from the folder containing the two scripts in a new Government-only terminal on the client
machine. If using a repository clone, enter its `scripts` directory first. For Commercial,
use the operator's `.azure-api.net` URL and Commercial tenant/application IDs in a separate terminal.
The splatted settings avoid fragile trailing backticks and contain no credentials:

```powershell
$byok = @{
  AuthMode = 'jwt'
  RefreshToken = $true
  AppId = '<CLIENT_ID>'
  TenantId = '<TENANT_ID>'
  ApimBaseUrl = 'https://<apim-name>.azure-api.us/openai'
  Model = 'gpt-5.6-sol'
  WireApi = 'responses'
}
./copilot-cli-byok.ps1 @byok -Login -UseDeviceCode -InstallDeps
```

Complete the device-code sign-in as the intended Entra user. Only after the launcher succeeds,
run `copilot` in that configured terminal. If the launcher opens PowerShell 7, run Copilot there.
If setup fails or sign-in is cancelled, stop and resolve that error instead of starting Copilot
with an older configuration.

The setup sequence is:

1. Infer `AzureUSGovernment` from an exact `.azure-api.us` hostname or `AzureCloud` from
  `.azure-api.net`. Custom hostnames require `-Cloud` or an interactive choice. HTTPS is required;
  conflicting cloud overrides, URL credentials, query parameters and fragments are rejected.
2. Reuse an explicit `AZURE_CONFIG_DIR`, or select the current user's `.azure-byok-government` /
  `.azure-byok-commercial` directory. The default `.azure` cache is not selected implicitly.
  An existing cache must already match the inferred cloud; it is never switched to another cloud.
3. Reuse a matching delegated user, or ask permission to sign in and prompt for the gateway
  directory tenant GUID. Supply `-TenantId '<TENANT_ID>'` to avoid that prompt. The hostname and
  application client ID cannot identify the tenant. A conflicting cached tenant or application
  identity is rejected instead of silently replaced.
4. Install missing dependencies when approved, initialize the cloud only in a newly created
  cache, and run Azure CLI login for the exact tenant and gateway scope. `-UseDeviceCode` displays
  instructions for a browser on another machine; omit it for Azure CLI's browser/broker default.
5. Verify the resulting cloud, tenant and delegated user, preflight the gateway token helper,
  and configure Copilot in the same shell. Failed/cancelled setup does not replace existing
  provider credentials. New caches are prepared in temporary directories and published only after
  cloud initialization succeeds. Failed preparation cleans up only directories created by that
  attempt, so an installation/cloud-setup failure can be retried. Existing caches are not deleted
  or overwritten. A successfully initialized cache remains after cancelled sign-in for an explicit retry.

`-Login` explicitly starts sign-in without the launcher's confirmation prompt, even for an
already-cached account. It is recommended in the first-run command above, but is not a mandatory
one-time-only flag: an interactive first run can instead prompt for sign-in approval, and `-Login`
is also used for deliberate reauthentication. Without it, noninteractive runs never start login.
`-InstallDeps` is only installation consent, not sign-in consent. A requested sign-in still requires
the user to complete Entra authentication. Enter device codes/passwords directly in the browser,
never in chat. The gateway app registration, delegated permission/consent and intended tier
assignments must already exist; the launcher does not create or grant them.

For Bash, from the repository root use `AUTH_MODE=jwt REFRESH_TOKEN=1 source ./scripts/copilot-cli-byok.sh <APIM_URL> <MODEL>
<CLIENT_ID>` in an interactive terminal. Optional settings are `BYOK_AZURE_CLOUD`, `BYOK_TENANT_ID`,
`BYOK_LOGIN=1` and `BYOK_USE_DEVICE_CODE=1`, with the same inference, approval and cache boundaries.
Do not copy a laptop's cache to a VM or use another operating-system user's cache. A terminal/cache
remains pinned to one cloud; open a separate terminal for the other cloud.

Sign-in and renewal need approved outbound HTTPS to `login.microsoftonline.us` (Government) or
`login.microsoftonline.com` (Commercial), plus applicable sign-in dependencies; they do not flow
through private APIM. A setup failure before token preflight is not a tier-enforcement result.
A clean shell may have no `COPILOT_PROVIDER_BASE_URL` or `COPILOT_MODEL`, so use explicit inputs as
above. The per-request helper still never signs in or changes cloud/account/cache. It can return a
cached JWT: per-request acquisition is not forced reissuance, and group changes do not rewrite
an existing token's roles.

#### Routine JWT Launches

After successful setup, run `copilot` directly while still in the configured terminal. In a new
terminal, open the folder containing the two scripts, recreate the same `$byok` settings above,
and rerun the launcher **without `-Login`**:

```powershell
./copilot-cli-byok.ps1 @byok
```

Then run `copilot` after the launcher succeeds. Keep `RefreshToken = $true`: the credential command
reuses a usable access token and requests renewal when needed. Ordinary access-token expiry does
not require another interactive login while the refresh grant remains usable and Entra is reachable.
If sign-in/MFA is required again, exit Copilot and use the first-sign-in command without
`-InstallDeps` unless software is missing. Do not add `-Login` to every normal launch.

The matching cloud-specific cache persists across terminals, but `$byok` and the provider environment
variables do not necessarily do so. An explicit `AZURE_CONFIG_DIR` must still point to that same
cloud's cache. For Bash, leave `BYOK_LOGIN` unset or `0` on normal launches and keep `REFRESH_TOKEN=1`.

#### Understand JWT Access Messages

**403 after a group change:** Copilot's generic `Authentication failed ... HTTP 403` may indicate
missing/conflicting tier claims or a token cached before membership was assigned. It does not prove
the account is unassigned or that login expired. Follow these steps:

1. Exit Copilot. Have the administrator verify the intended Entra account has direct membership in
  exactly one group assigned to the gateway API's mapped tier role, in the correct tenant. Neither
  group or conflicting tier roles causes inference rejection when tiering is enabled; there is no
  default-tier fallback. Portal native-key groups are not JWT tier assignments.
2. After the administrator fixes or changes membership, allow Entra propagation. Reuse the same
  `$byok` settings and cloud-specific cache, and explicitly request sign-in again:

```powershell
./copilot-cli-byok.ps1 @byok -Login -UseDeviceCode
```

3. Complete the browser sign-in, wait for the launcher to succeed, then start `copilot` in that
  same configured terminal. This requests authentication for the gateway scope; it does not
  guarantee immediate directory propagation. No cache deletion, APIM redeployment or new
  subscription is needed. Restarting Copilot alone does not replace a cached JWT.
4. If 403 persists, inspect only safe token metadata (mapped tier roles, issuance and expiry times)
  and the actual gateway error code. `CallerTierInvalid` identifies tier selection failure. Missing
  roles require checking freshness/assignment; an expected single role with continued rejection
  requires gateway investigation. Do not repeatedly log in or share raw tokens to diagnose it.

**Waiting instead:** with `-RefreshToken` configured, the helper can pick up changed roles when it
next obtains a newly issued access token after propagation, normally when the cached token needs
renewal. Requests may continue to receive 403 until then. A valid old token can also retain access
after group removal until replaced or expired. There is no fixed propagation/expiry wait that
guarantees a role change, and automatic renewal cannot bypass a required interactive sign-in.
Use the explicit sign-in step above when you want to test changed membership sooner.

The launcher distinguishes **token acquired** from **gateway access granted**. Before configuring
Copilot, it inspects the token already acquired for preflight and warns if its app-role claim is
missing or empty. For a tier-enabled gateway, that token cannot select a tier: allow group changes
to propagate, then rerun the same launcher with `-Login` (and `-UseDeviceCode` on a remote VM).
For Bash, use `BYOK_LOGIN=1` and optionally `BYOK_USE_DEVICE_CODE=1`. If access remains denied,
ask the administrator to verify exactly one mapped gateway tier assignment.

This is an advisory metadata check, not signature validation or proof of current group membership.
It prints neither tokens nor raw claims, makes no additional token or gateway request, and does not
block role-less tokens for gateways where tiering is disabled. It cannot validate custom role-to-tier
mappings. Having app roles does not establish authorization; APIM remains authoritative.

If the credential helper cannot obtain a usable token, it emits no credential and gives the
re-login command plus cloud/account/cache/connectivity guidance. The helper never starts interactive
login itself. Copilot CLI owns the generic runtime `Authentication failed ... HTTP 403` banner;
the launcher cannot replace it. A 403 alone does not mean sign-in expired. Missing/conflicting tier
claims are one cause, reported by APIM as `CallerTierInvalid`; inspect the actual gateway error when
fresh sign-in does not restore access. Gateway denial status and policy enforcement are unchanged.

#### Observe Renewal In The VM Session

The Entra token helpers support an optional `BYOK_TOKEN_TRACE_FILE` path. It is disabled by default
and appends only `event`, `observedUtc` and `expiresUtc` JSON fields, never tokens, claims, account
names or identifiers. Credential stdout and authentication behavior are unchanged. Trace writes
are best-effort; a trace-file error is reported on stderr without turning a valid token into a failure.

Use the updated helper on the VM, in the same terminal already configured for renewable JWT.
Before starting one new CLI session, set a fresh trace path:

```powershell
$env:BYOK_TOKEN_TRACE_FILE = Join-Path $env:TEMP ('byok-renewal-' + [guid]::NewGuid().ToString('N') + '.log')
$env:BYOK_TOKEN_TRACE_FILE
copilot
```

In a second VM terminal, follow that printed path after the first helper invocation creates it:

```powershell
Get-Content -LiteralPath '<TRACE_FILE>' -Tail 10 -Wait
```

Repeated `token-acquired` records with the same `expiresUtc` mean the same expiry is being reused;
they do not mean a new token was issued on each request. A later expiry shows a newer credential
was returned. To prove the actual client renewal path, keep that CLI session running past the first
expiry and observe a successful normal request plus a new expiry, without manually calling the helper,
`az account get-access-token`, or signing in during the test. Launcher preflight can also create an
initial trace row; it is not itself a Copilot request. `acquisition-failed` has no expiry and does not
establish successful renewal. No rows alone do not prove failure; confirm the configured helper path
and stderr. A variable set in another terminal cannot enable tracing in an already-running process.

These diagnostics cannot reconstruct earlier renewals or observe a VM from a separate laptop cache.
Disable tracing before a subsequent session with `$env:BYOK_TOKEN_TRACE_FILE = $null`. For Bash,
export the same variable before launch and use `tail -f` to follow the selected file.

Legacy Foundry/AOAI JWT policies (including discovery and Responses follow-ups) require
the token in `api-key`; Anthropic JWT accepts Bearer or `x-api-key`. A static bearer-token
setting does not by itself change these policies or refresh a token.

VS Code's current documentation permits `requestHeaders` values containing the literal
`${apiKey}` to use secret storage. This is header interpolation, not OAuth renewal. The
built-in Azure provider has Entra authentication for the Cognitive Services scope, which
does not satisfy this gateway's custom audience. Preserve the existing URL marker when
using legacy JWT-in-`api-key` paths. Shared authentication adds validated Bearer admission on the
same URLs only after its explicit rollout gates. Native Custom Endpoint remains key-based under
the approved support boundary; its UI mode does not select the independently configured CLI.

The current IntelliJ nginx proxy extracts Bearer into `api-key` and clears Authorization.
This rewrite does not validate or renew a JWT. Test or adapt it as part of dual-auth admission;
do not silently replace user tokens with a shared service identity.

See the [client capability record](feature-request-byok-credential-refresh.md) and the
[VS Code](../samples/vscode/README.md) / [IntelliJ](../samples/intellij/README.md) guides.

## Rollout and acceptance gates

1. Prove same-URL key/JWT admission in an isolated dev test, including product scope,
   suspension, key rotation, missing credentials and anonymous-access rejection.
2. Test Entra and Okta success and failure: signature, expiry, issuer/audience pairing,
   required scope, user/client restrictions, malformed tokens and conflicting headers.
3. Exercise every policy surface above. Verify no validation bypass on body-less operations,
   cross-user response access, credential stripping, metrics and quota isolation.
4. Verify existing key clients unchanged and JWT clients through actual token expiry,
  MFA/renewal failure and signing-key rotation. Test standalone Bicep/Terraform equivalently.
  Record live Entra, fixture Okta and live customer Okta evidence separately; unrun tests
  remain explicit gaps rather than inferred passes.
5. Keep pilots key-only until Entra/key acceptance gates pass and deployment is approved.
  Entra may ship with Okta disabled while customer validation is pending. Enable Okta only
  after its customer acceptance and deployment approval. Deploy through CI with rollback
  configuration; no backend authentication changes are required by this feature.

### Government and Commercial JWT probes (2026-09-18)

With explicit approval, separate temporary APIs were created on Government and Commercial
pilot APIM and exercised from their private Windows test VMs. Existing APIs, named values,
products and backend configuration were not modified. The probe copies the authentication
block from [the Foundry JWT policy](../policies/byok-foundry-policy.xml), omits inherited
policies and replaces inference with a fixed post-validation response. It has no backend.
This is a live authentication-block test, not a full inference-policy test. Both clouds
returned the baseline results below; the separate admission experiment follows.

| Case | Observed result |
|---|---|
| Real gateway-scoped Entra delegated user token | 200; probe marker and caller-header stripping asserted |
| Missing credential | 401 |
| Malformed token in `api-key` | 401 |
| Malformed Bearer-only credential, without `api-key` | 401 |
| VM managed-identity ARM token, not a gateway user token | 401 |
| Tampered signature on the user token | 401 |
| Real user token against a deliberately wrong-audience validator | 401 |
| Real user token against a deliberately ungranted-scope validator | 401 |
| Genuinely expired signed user token | Both clouds: 401 with fresh-token 200 control |

The audience/scope controls alter only the isolated operation validators; they do not
mint new tokens or modify shared named values. No model backend was called. Credential
stripping is asserted inside the probe, not observed at a downstream mock server.
The real user token was CMS-encrypted to a temporary, non-exportable VM certificate;
only ciphertext crossed Run Command. Certificate/private-key removal passed after testing.

[probe-jwt-auth.ps1](../scripts/probe-jwt-auth.ps1) is the PowerShell 7 orchestrator;
[probe-jwt-auth.sh](../scripts/probe-jwt-auth.sh) delegates to it and also requires `pwsh`.
[probe-jwt-auth-vm.ps1](../scripts/probe-jwt-auth-vm.ps1) is the Windows PowerShell 5.1
Run Command payload. The orchestrator refuses cloud switches and existing API overwrites.
`-TestExisting` reruns an explicitly selected probe, `-IncludeUserToken` enables encrypted
user-token tests, and `-AddValidationControls` creates the two rejection controls once.
`-ValidateOnly` checks extraction without Azure calls; it is not APIM runtime validation.

### Native admission experiment: blocked (2026-09-18)

`-AdmissionProbe -IncludeUserToken` creates two additional no-backend APIs, disposable
products and subscriptions. One API requires subscriptions, the other does not. Both
inherit the probe product policy and validate JWTs only when `context.Subscription` is null.
This is deliberately an experimental candidate, not a production-ready policy.

The expanded 32-case matrix produced identical results in Government and Commercial:

| Case | Required subscription | Optional subscription |
|---|---|---|
| Active primary, secondary, replacement primary key | 200; subscription, product and inherited policy present | Same |
| Missing, invalid, suspended or replaced old key | 401 | 401 |
| Active key scoped to a different API | 401 | **200: authorization failure** |
| Active key scoped to an unlinked product | 401 | **200: authorization failure** |
| Entra JWT in `api-key` or Bearer | 401 before JWT policy | 200 after JWT validation; no subscription/product tier |
| Valid key plus Bearer JWT | **200: violates one-credential contract** | **200: violates one-credential contract** |
| Disposable product limit, requests 1 through 4 | 200, 200, 200, 429 | Same |

The optional API exposes subscription context even for keys outside its authorized scope.
Consequently, `context.Subscription != null` is not sufficient authorization. Merely
disabling subscription requirements and branching on that value is rejected. Preserved
product context and a working tiny product rate limit do not compensate for the scope gap.
Production tier/token/monthly quotas were not exercised. Conflicting credentials also
need explicit rejection before either authentication path is selected.

The next admission design must prove correct scope authorization without a copied key
allowlist, per-request ARM calls or a shared synthetic subscription. Any ingress redesign
requires approval. Existing inference policies and deployment mode selection remain unchanged.

### Product-context guard: incompatible with full key scope support

The follow-up `-AdmissionProbe -ProductContextGuard -IncludeUserToken` experiment produced
identical 40-case results in both clouds: 36 passed and four legitimate-key cases failed.
It rejects conflicting header sources before inherited policy, then requires both product
context and the inherited probe-product marker for a recognized subscription.

| Case | Required subscription | Optional subscription |
|---|---|---|
| Authorized product primary, secondary and replacement keys | 200 with subscription/product/policy context | Same |
| Wrong-API and unlinked-product keys | 401 | 401 |
| Legitimate API-scoped key | **401: compatibility regression** | **401: compatibility regression** |
| Legitimate all-APIs key | **401: compatibility regression** | **401: compatibility regression** |
| Key plus JWT, invalid key plus JWT, JWT in both headers | 401 | 401 |
| Entra JWT in `api-key` or Bearer | 401 | 200 |
| Disposable product limit, requests 1 through 4 | 200, 200, 200, 429 | Same |

Missing, invalid, suspended and replaced old keys also returned 401. This is a header-only
Foundry probe; rejecting query keys and alternate key headers does not prove coverage of
the other production surfaces. The documented `context.Subscription` members do not expose
subscription scope, and legitimate API/all-APIs subscriptions do not supply product context.
The guard closes the observed scope bypass but cannot preserve the full key contract.
Do not ship it as coexistence support or silently narrow support to product subscriptions.
Retaining the agreed scope compatibility requires another proven admission design; an ingress
redesign or an explicit product-only contract both require approval. No production policy changed.

### Alternative admission investigation (2026-09-18)

**Recommendation: continue acceptance testing of required subscriptions plus a JWT-protected
open product before adding an ingress layer.** The initial investigation was documentation-only;
the subsequently approved isolated probe passed its 16-case gate in both clouds. This is not
full production acceptance. Production policies and deployment settings remain unchanged.

Microsoft's [request-handling table](https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions#how-api-management-handles-requests-with-or-without-subscription-keys)
distinguishes two configurations that the earlier probes must not conflate:

| Configuration | Documented admission behavior | Evidence here |
|---|---|---|
| API subscription optional | Can admit keys outside the API/product scope | Unsafe candidate reproduced in both clouds |
| API subscription required, associated open product | Valid in-scope keys use native admission; no-key requests enter open-product context | Initial 16-case gate passed in both clouds; explicit JWT guard required |

The detailed documentation also describes invalid keys falling through to an open product,
while its summary table lists out-of-scope keys as denied. Therefore, measure the actual
subscription/product context for invalid and wrong-scope keys; do not infer that every
fallback is rejected before policy. The final response must reject them either way.

#### Candidate flow and invariants

1. Retain the existing API resource IDs, paths, required-subscription setting, key parameter
  names, protected products and subscription scopes. Add one dedicated open product per API
  association where needed; an API can belong to at most one open product. No synthetic
  subscription or copied keys are involved. "Open" means no subscription required, not
  anonymous model access: a JWT validator must guard every no-key execution path.
2. Explicitly invoke the shared credential/authentication gate before inherited quota policy,
  credential stripping, backend authentication, or any model/discovery forwarding. Include
  it directly in operation policies that omit inbound `<base />`. Product-only JWT policy
  is insufficient: the current discovery and four Responses follow-up operations skip it.
3. Reject multiple credential sources, repeated credential values and empty/malformed sources,
   except the owner-approved identical Authorization normalization described above.
  Preserve established single-key header/query contracts unless a change is approved;
  never accept JWTs in query strings. Test Bearer normalization through the IntelliJ proxy
  and the separate Anthropic header contract rather than treating the Foundry probe as coverage.
4. In the designated open-product context, require full Entra/opt-in Okta JWT validation and
  immutable identity, regardless of whether a subscription object unexpectedly exists.
  Never treat a product ID or a client-supplied marker as proof of JWT validation.
  Invalid JWTs terminate here; there is no key retry after JWT failure.
5. Only after the probe proves native scope enforcement for this configuration may a native
  subscription outside the open-product path authorize a key caller. Do not require product
  context for API/all-APIs keys. All other contexts fail closed. API-scoped/all-APIs keys do
  not inherit product policies today; preserve that behavior rather than inventing a tier.
6. Preserve product-key accounting once per request; apply explicit issuer/subject limits to
  JWT callers without borrowing an open-product or shared-subscription quota identity.
  Strip caller credentials and retain existing backend authentication after admission.

#### Smallest discriminating probe

The approved probe creates only an isolated no-backend API with required
subscriptions, one protected product and one JWT-protected open product. Install all guards
before linking the open product. Use a normal inherited operation and a second operation
that omits `<base />` but explicitly invokes the same authentication gate.

The first gate is eight requests per operation: legitimate product/API/all-APIs keys and
JWTs in `api-key`/Bearer must return 200; wrong-API key, unlinked-product key and no credential
must return 401. Record sanitized native subscription/product context as well as status.
Any wrong-scope success, anonymous success, valid-scope rejection, or JWT admission failure
disproves the candidate before expanding testing. Do not reuse the old matrix's expectation
that every required-subscription API must reject JWTs: the open product changes that premise.

If this gate passes, extend the existing matrix for secondary/rotated/suspended keys,
conflicting/repeated/empty headers, query-key compatibility, malformed/expired/wrong-issuer/
wrong-audience/wrong-scope JWTs and missing identity. Assert exact case names, context and
single quota charging, including deliberately changed/removal product associations. Repeat
in Government and Commercial. Production acceptance still requires every policy surface,
streaming/cancellation, real backend credential isolation, telemetry and client renewal.
Okta fixture and eventual customer evidence remain separate gates.

Enabling the open-product association is the security-sensitive transition: install and
verify authentication on every operation first, link last, then run rejection smoke tests.
Rollback unlinks the open product before removing guards. Merely unpublishing the product
does not block gateway access. CI must enforce the API's required-subscription setting and
explicit authentication coverage so configuration drift cannot revive the optional-key bypass.

#### Ingress alternatives if the candidate fails

| Alternative | Compatibility and tradeoffs | Disposition |
|---|---|---|
| APIM routing facade at existing paths | Keep original key API IDs/scopes but move their paths behind a new facade; route JWTs to separate mandatory JWT validation. Never copy keys into new APIs. Requires an actual second gateway request, not just a backend URL rewrite, to run native admission. | Reserve candidate; path migration, direct-route guards, SSE/cancellation, duplicate accounting and internal-VNet self-call behavior need proof. |
| Private reverse proxy in front of key and JWT paths | Route keys to the original required-subscription API and JWTs to an independently validated path; reject conflicting sources before routing. | Larger operational/network change. Preserving hostnames requires DNS control and a usable TLS certificate; do not assume the service-managed gateway hostname/certificate can move to a proxy. |
| Separate JWT URL | Leaves native key APIs intact with a small routing boundary. | Violates the same-URL requirement; only with explicit contract change. |
| Product-only guard | Already tested; rejects legitimate API/all-APIs keys. | Rejected under the current contract. |

For an APIM facade, unverified token shape may guide routing but never authorize it;
each destination must independently validate its credential, with no fallback after failure.
An authorization-only call to a separate API does not prove access to the original API or
transfer its native subscription context. Avoid that shortcut and per-request ARM lookups.
Microsoft documents a loopback/Host workaround for internal-VNet `send-request` self-calls;
that is not evidence that full streamed inference proxying works. Keep this as a fallback
research path, not a deployed or approved architecture.

### Open-product probe results (2026-09-18)

`-AdmissionProbe -OpenProductProbe -IncludeUserToken` passed all 16 named assertions in
Government first, then Commercial. Each cloud used one new required-subscription no-backend
API, a protected product, a guarded open product, an unlinked negative-control product and
disposable keys. Existing production APIs/products were not modified. The open product was
linked only after the API gate and explicit operation policy were installed.

| Case (each operation) | Inherited operation | Explicit auth, no inbound base |
|---|---|---|
| Valid product key | 200; subscription/product/product-policy present | 200; subscription/product present, no inherited product policy |
| Valid API-scoped or all-APIs key | 200; subscription only | Same |
| Entra JWT in `api-key` or Bearer | 200; product and validated-JWT marker, no subscription | Same |
| Key scoped to another API or unlinked product | 401; subscription and product flags still present, no validated-JWT marker | Same |
| Missing credential | 401 | 401 |

The four compact context flags are subscription present, product present, protected-product
policy executed, and JWT validated. These are booleans, not identities or credentials.
Wrong-scope responses demonstrate why a non-null subscription remains insufficient: the
candidate explicitly validates JWTs for its designated open-product context even when a
subscription exists. No product-only restriction was imposed on legitimate API/all-APIs keys.
The explicit operation deliberately does not inherit product policies, matching the existing
discovery/follow-up boundary; this is not evidence of quota enforcement on that operation.

Baseline Entra controls on the separate existing probe and temporary certificate/private-key
cleanup passed in both runs. Those baseline controls are not JWT-negative coverage of the
new open-product path. Exact case-name/count checks and expected successful context checks
passed. The Bash launcher forwards the new switch unchanged. PowerShell syntax, editor
diagnostics and auth-extraction checks passed locally.

The initial admission blocker is narrowed, not the whole acceptance gate closed. Next test
the expanded matrix under this exact configuration: key lifecycle, conflicts/repeated headers,
query-key compatibility, JWT negatives and stable identity, association changes, single quota
charging and credential stripping. Then cover all real operations, backend isolation, streaming,
telemetry and renewal. Okta remains unimplemented/unvalidated. No new ingress, shared auth
fragment, production rollout or cleanup was performed; disposable resources are retained.
The Commercial VM was restored to deallocated after its run.

### Expanded open-product gate (2026-09-18)

The approved next probe passed **78/78 exact named assertions in Government, then 78/78 in
Commercial** using `-AdmissionProbe -OpenProductProbe -ExpandedGate -IncludeUserToken`
and a captured `-ExpiredUserToken`. The initial 16-case mode remains available unchanged.
Only disposable no-backend APIs, products, subscriptions and validator controls were created.

The expanded probe adds source-count/multiple-value checks, single query-key compatibility,
query credential removal, space-delimited scope matching and nonempty validated `tid`/`oid`
checks to its experimental policy. No production policy was changed. Every successful matrix
request asserts expected native context and header/query credential stripping inside APIM.

| Coverage | Observed result in both clouds |
|---|---|
| Initial product/API/all-APIs and JWT admission cases | Preserved on inherited and explicit/no-base operations |
| Secondary and replacement primary key | 200 |
| Suspended, invalid and replaced old key | 401 |
| Empty credential, empty Bearer, key/JWT and JWT/JWT conflicts | 401 |
| Comma-combined repeated key/Bearer values | 401 |
| Single query key | 200 and query removed before fixed response |
| Repeated query key, query plus Bearer, JWT-shaped query value | 401 |
| Tampered signature and genuinely expired signed user token | 401 on both open-product operations |
| Deliberately wrong audience/scope/exact issuer claim validators | 401 |
| Deliberately missing identity claim lookup | 401 |
| Product test counter on inherited operation | 200, 200, 200, 429; a different subscription still 200 |
| Same product key on no-base operation | Four 200s; product policy intentionally not inherited |
| Explicit issuer/tenant/subject JWT test counter, per control operation | 200, 200, 200, 429 |

Conflicting requests using the throttle key preceded its three successful calls, demonstrating
that those conflicts did not consume this product counter. JWT and key counters use different
identities; no shared subscription was substituted. These tiny call counters are not proof of
production token/monthly quotas or multi-user isolation. JWT limiter and validator-control
operations explicitly omit inbound base to avoid executing the API gate/response twice;
their names group test surfaces, not inherited-policy coverage.

An initial Government run passed 76/78: adding a deliberately wrong `<issuers>` entry alongside
the existing `openid-config` still accepted the real token in both controls. Do not assume
that an explicit issuer list replaces the metadata issuer. Requiring the incompatible `iss`
value in `required-claims` produced the expected 401 in the corrected run. This is an exact
claim rejection control, not live acceptance/rejection of tokens from a second issuer.
The missing-identity control similarly checks an intentionally absent claim after validating
the real signed token, not an IdP-issued token lacking `oid`. Neither implies Okta coverage.

Remaining gaps include separate repeated HTTP header lines (only combined values tested),
real alternate-issuer/missing-identity and multi-scope fixtures, multi-user JWT quota isolation,
live product-association changes and propagation, all production operation/header contracts,
downstream credential observation, full accounting, streaming/cancellation and client renewal.
The query-JWT case uses an inert JWT-shaped string to avoid putting a real access token in a
URL; real tokens remained header-only and CMS-encrypted across Run Command.

PowerShell parsing, compressed-result roundtrip, editor diagnostics and baseline controls
passed. Exact matrix names/counts prevent partial logs from becoming success; compressed
transport contains only sanitized status/context results. Temporary VM certificates/private
keys were removed. Commercial returned to deallocated; production remains key-only. Probe
resources, including partial/failed setup attempts, are retained pending approved cleanup.
This is a probe gate pass, not closure of the production acceptance work in #140.

### Mock-backend gate: strict duplicate-header blocker (2026-09-18)

Historical results under the original strict contract follow. The approved identical
Authorization special case above supersedes the blocker, not the recorded observations.

The owner approved isolated mock listeners and APIM-subnet-only Windows firewall rules
on the existing test VMs, with cleanup. `-BackendGate` extends `-ExpandedGate` with a
temporary private mock backend, raw HTTP/1.1 requests over certificate-validated TLS,
native call-quota controls, and operation shapes copied from the deployed Foundry API.
The mock records only random per-request test IDs, receipt counts and credential-presence
booleans in memory. It does not echo or persist credentials or request bodies.

Government completed a 194-case run with 192 passes and two strict duplicate-Bearer
failures. A 198-case diagnostic rerun reproduced those failures and added four differing
duplicate-Bearer requests. Those four returned 400, not the initial expected 401, with
no backend receipt. The harness now expects 400 for those specific parser-rejection cases;
at that point this expectation-only adjustment had not been rerun. Identical duplicates
still expected rejection under the original contract and failed that historical gate.

| Separate wire header lines | Government result | Backend receipt |
|---|---|---|
| Duplicate `api-key` | 401 | None |
| Mixed-case duplicate key name | 401 | None |
| Two identical valid `Authorization: Bearer` values | 200; APIM policy sees one Authorization value | One, credentials stripped |
| Valid Bearer then invalid Bearer | 400 | None |
| Invalid Bearer then valid Bearer | 400 | None |

This is not evidence of invalid-token acceptance: the accepted token was valid. It does
disprove strict rejection of every duplicate wire header by the current APIM-only gate.
The owner initially retained that strict requirement rather than accepting identical-value
normalization, blocking #140 at that time. The later approved exception supersedes that decision;
no final design sign-off or coexistence rollout is approved.
The policy expression API exposes a header dictionary, not raw incoming header lines:
[APIM context reference](https://learn.microsoft.com/azure/api-management/api-management-policy-expressions#context-variable).
The observation is specific to this tested Government path; Commercial and HTTP/2 behavior
are not inferred from it.

Other Government assertions passed: missing/invalid/expired/wrong-scope/conflicting requests
had no mock receipt; accepted requests had one receipt without caller credential headers or
query parameters; product call quota allowed three calls then returned 403; another subscription
was unaffected; rejected conflicts did not consume that quota. Explicit no-base operations
continued to bypass inherited product quotas, matching the baseline rather than repairing it.
All 12 copied Foundry operation method/path shapes passed eight cases each, including discovery
and all four Responses follow-ups. These use the experimental authentication policy with the
matching inheritance pattern, **not the complete production inference/backend policies**.
They do not prove production token quotas, telemetry, or full integration.

The temporary listener, firewall rule and transport certificate/private key were removed,
with passing cleanup assertions. The Government Windows VM was already running and was left
running. No Commercial test VM was started for this gate. No production API, model backend,
Azure NSG or DNS setting changed. Disposable APIM resources from these attempts are retained.

#### Platform investigation and support handoff (2026-09-18)

The support draft and strict-gate results in this section predate the approved special case.
They are retained as evidence; support escalation and stricter ingress are no longer prerequisites
for continuing the remaining acceptance tests under the revised contract.

**Finding: no documented managed-gateway fix identified; Microsoft confirmation pending.**
Documentation research and the isolated schema test below do not prove that no internal
platform mitigation exists. No production policy, DNS, or client URL was changed.

| Supported surface reviewed | Finding and implication |
|---|---|
| [Policy expression context](https://learn.microsoft.com/azure/api-management/api-management-policy-expressions#context-variable) | `context.Request.Headers` is a dictionary of string arrays. No raw-header-line collection or original header count is documented. The live probe already sees one value before its own credential normalization. Repeating that count check cannot recover lost multiplicity. |
| [Validate parameters](https://learn.microsoft.com/azure/api-management/validate-parameters-policy) | Documents multiple-value rejection and an Authorization example. The Government HTTP/1.1 schema test below proves validation executes but accepts identical separate Authorization lines, including mixed-case names. The tested configuration does not satisfy strict wire-level rejection. |
| [Validate headers](https://learn.microsoft.com/azure/api-management/validate-headers-policy) | Validates response headers, not incoming credential headers; not a solution to this request-admission requirement. |
| [Service custom properties](https://learn.microsoft.com/dotnet/api/azure.resourcemanager.apimanagement.apimanagementservicedata.customproperties) | The reviewed reference documents TLS/cipher and HTTP/2 controls, not a duplicate-Authorization rejection switch. Do not invent or trial undocumented properties on shared gateways. Changing HTTP versions would not repair the already-observed HTTP/1.1 case. |

Targeted GitHub searches for duplicate Authorization behavior in `Azure/api-management` and
API Management issue reports did not identify a matching public fix. Search coverage is not
exhaustive and does not establish Microsoft acknowledgement. The exact internal component
performing normalization is unknown; do not attribute it to IIS, HTTP.sys or a particular
gateway build without platform evidence.

The discriminating policy experiment uses an isolated operation with a declared single-string
Authorization parameter and `validate-parameters` in prevention mode. The persisted parameter
definition and a deliberately nonconforming single-value control prove validation executes;
an import dropping the definition or a schema-resolution error would be inconclusive.
The original acceptance criterion was a conforming single header passing while identical separate
lines were rejected. Under the revised contract the test instead characterizes identical-line
normalization as one accepted value. It also includes differing values and case variants, emitting only sanitized
status/count/error-source fields, never raw validation details or credentials.

The isolated experiment is implemented as `-TestExisting -ParameterGate` in
`scripts/probe-jwt-auth.ps1`, with a `ParameterTest` phase in the paired VM helper. It creates
one randomly named operation under the ownership-checked probe API, verifies the persisted
single-string Authorization definition and permitted value, and uses inert Bearer strings.
Eight raw TLS HTTP/1.1 requests cover valid/invalid/missing singles, identical duplicates,
mixed-case identical duplicates, differing duplicates in both orders and a final valid single.
Invalid/missing controls must identify `validate-parameters` as their error source. The policy
always returns locally with no inherited backend pipeline; no mock backend receipt measurement
is claimed for this schema-only test. The operation is deleted and absence checked in `finally`.

**Execution status: FAILED strict duplicate gate (2026-09-18); six of eight cases passed.**
The initial attempt was blocked before writes by `403 AuthorizationFailed`. After the owner
restored access, an exact probe read returned 200 and the ownership guard passed unchanged.
The Authorization schema persisted exactly and the following live results were observed:

| Case | HTTP | Policy-visible Authorization values | Validation error source | Gate result |
|---|---|---|---|---|
| Valid single | 200 | 1 | None | Pass |
| Invalid single | 400 | 1 | `validate-parameters` | Pass |
| Missing header | 400 | 0 | `validate-parameters` | Pass |
| Identical duplicate lines | 200 | 1 | None | **Fail** |
| Identical duplicates, mixed-case names | 200 | 1 | None | **Fail** |
| Differing duplicates, valid first | 400 | No probe header | No probe header | Pass |
| Differing duplicates, valid last | 400 | No probe header | No probe header | Pass |
| Valid single after duplicate cases | 200 | 1 | None | Pass |

The positive controls and source-checked rejections rule out an inactive schema as the cause.
The tested validation policy does not recover the lost wire multiplicity. This schema-only
experiment uses inert strings, not signed JWTs, and makes no backend calls; it complements
rather than replaces the preceding authenticated mock-backend evidence. No inference is made
about Commercial, HTTP/2, or an undocumented Microsoft service mitigation.

The temporary operation was deleted and its absence verified (`schema-operation-removed`).
No firewall, certificate, VM power state, production API policy or URL changed. PowerShell
parsing, raw serialization, local simulated-normalization checks and editor diagnostics also
passed. This was the strict-contract blocker; the subsequent owner decision makes support
confirmation a nonblocking follow-up rather than a prerequisite.

##### Historical Microsoft support request draft (not submitted)

This draft captures the superseded strict requirement. Revise its impact and requirement
before any future submission; the identical-token exception is now accepted.

**Subject:** API Management Government: reject identical duplicate Authorization header lines
before normalization without changing gateway URLs

**Impact:** Blocks acceptance of a new same-URL key-or-JWT authentication design. Existing
production key-only APIs are unchanged; this is not a reported production outage or a
demonstrated invalid-token/signature bypass.

**Observed:** In an isolated required-subscription API with a JWT-guarded open product, a
certificate-validating raw HTTP/1.1 TLS client sends two separate identical Authorization
Bearer lines. Both inherited and explicit/no-base operations expose one Authorization value
at the start of the experimental policy, validate the real token, and return 200. A private
mock backend confirms one request with caller credentials stripped. Different duplicate
Bearer values in either order return 400 with no observed mock receipt. Duplicate api-key
lines return 401. See the preceding evidence table and the repository's probe scripts.

**Supported-policy follow-up:** A separate schema-only operation declares a required string
Authorization parameter with one permitted inert value and runs `validate-parameters` in
prevention mode. ARM readback confirms the definition persisted. Valid single values return
200; invalid and missing singles return 400 with `context.LastError.Source` equal to
`validate-parameters`. Nevertheless, identical duplicate lines and mixed-case identical
duplicates both return 200 with one policy-visible value. Differing duplicates return 400.
The eight-case test completed and the temporary operation was removed. This rules out the
tested schema configuration as a strict duplicate guard, not all possible platform mitigations.

**Required:** Reject duplicate credential header lines even when values are identical, while
preserving existing Microsoft-owned gateway URLs, native subscription scope/state validation,
JWT validation and backend authentication. No new proxy or hostname migration is approved.

**Questions for APIM engineering:**

1. Is identical Authorization deduplication expected on the Government classic managed gateway,
  and which processing stage performs it? Does behavior differ by gateway build or protocol?
2. Is there a supported parser setting, service mitigation or planned fix that rejects duplicate
  Authorization lines before normalization, with availability in Government and Commercial?
3. Given the source-verified schema test above, is there another supported configuration that
  can enforce original header-line multiplicity? Please provide its example and limits.
4. If unsupported, please confirm the limitation and the supported alternatives under the
  unchanged-hostname requirement. Please supply a tracking reference and rollout guidance.

Provide resource ID, region/SKU, reproduction UTC window and correlation IDs only through the
approved private support channel; they are intentionally absent from this document. Request
a supported way to identify the managed gateway build if needed. Do not attach live tokens,
keys, raw credential-bearing traces or CMS payloads. Coordinate a fresh isolated reproduction
if Microsoft requires trace correlation. The observed test was Government HTTP/1.1; Commercial
and HTTP/2 have not reproduced this gate. **This draft has not been submitted to Microsoft.**

##### Cross-cloud parity support handoff (submitted; verified 2026-09-21)

**Subject:** Align policy-visible duplicate Authorization handling across Commercial and
Government classic managed gateways without changing client URLs.

**Impact:** Blocks acceptance of a new key-or-JWT design, not an existing production outage.
The owner requires identical cross-cloud behavior and has not authorized custom credential
deduplication, a new ingress, or cloud-specific expectations. Production authentication is unchanged.

**Observed:** Both services report Developer tier, `stv2`, internal VNet mode, HTTP/2 `False`,
and provisioning `Succeeded`. These values do not identify the actual gateway runtime build.
The same certificate-validating raw HTTP/1.1 probe and isolated admission policy are used:

| Request | Government | Commercial |
|---|---|---|
| Single valid Bearer | 200 after validation | 200 after validation, including raw-client control |
| Two identical valid Bearer lines | One policy-visible value, validated 200, one stripped backend receipt | Two policy-visible values, source guard 401, no backend receipt |
| Valid JWT plus `not-a-jwt`, either order | 400 with no probe context or backend receipt | Two policy-visible values, source guard 401, no backend receipt |

The Commercial rejecting branch explicitly returned a fixed `credential-source-guard` marker
and count `2` for all six inherited/explicit parity failures. Its comma flag describes the
`GetValueOrDefault` joined view, not evidence that the client sent a comma-combined header.
No credential values were returned. The marked Anthropic run remained 152/158, with 40/40
two-user controls passing and all listener/firewall/certificate, NSG rule, and VM-power cleanup
passing. Its final receipt audit failed because repeated-valid acceptance was required.

**Questions for APIM engineering:**

1. Which runtime/parser stage accounts for this difference, and how can its build be identified
  through a supported interface in both clouds?
2. Is there a supported configuration or platform mitigation that aligns identical-line
  normalization and conflicting-line rejection while preserving native subscription validation?
3. What is the supported cross-cloud and HTTP/2 contract, rollout status, and tracking reference?

Provide identifiers, UTC reproduction windows, and correlations only through an approved private
support channel; do not attach live credentials or credential-bearing traces. Do not set
undocumented service properties or migrate gateway platforms based on this draft.
**The cross-cloud support ticket was verified created and Open on 2026-09-21.** No duplicate
submission or approved mitigation followed. The earlier strict-rejection draft above remains
historical; ticket identifiers/contact details are intentionally excluded from the repository.

#### Strict ingress candidate and remaining gates

The proxy candidate and its prerequisites below are deferred unless strict rejection of
identical Authorization lines becomes a requirement again. No new ingress is planned for
the accepted special case. The active acceptance work is listed after this historical candidate.

A private header-validation proxy **before** APIM could reject duplicates before normalization,
then forward the single unchanged credential to the original APIM API IDs and paths. Keep
native subscription validation and JWT validation in APIM; do not translate JWTs into keys,
duplicate authentication with ARM lookups, or create a shared subscription identity.
NGINX njs documents that `rawHeadersIn` preserves duplicate names and values without merging:
[njs raw header reference](https://nginx.org/en/docs/njs/reference.html#r_raw_headers_in).
This is research, not a tested ingress implementation. The existing subkey proxy translates
Bearer values to keys and is not this component.

Before approving or deploying that candidate:

1. Prove raw-line rejection using the pinned proxy/parser version, including HTTP/1.1 and
  HTTP/2, same/different values and case variants; retain streaming and cancellation.
2. Resolve the unchanged-URL constraint: the first TLS endpoint needs a certificate for the
  existing client hostname. DNS redirection alone cannot transfer a Microsoft-owned APIM
  hostname/certificate to a customer proxy. A customer-owned hostname needs its own approved
  certificate/DNS plan; changing client URLs is not silently permitted.
3. Prevent direct APIM access from bypassing the proxy, using an approved network or authenticated
  proxy-to-APIM boundary. A caller-supplied marker header is insufficient.
4. Repeat backend/header gates in both clouds and the route-specific `x-api-key` gate if ingress
  changes. Complete product association
  removal/restoration and propagation tests, production-policy integration, full accounting
  and rollback checks. The tiny call-quota test does not replace token-quota coverage.
5. Review the complete sanitized matrix and explicitly approve the final topology/header
  contract. Keep #140 and dependent implementation decisions open until then.

#### Revised-contract acceptance results (2026-09-18)

Fresh Government runs after the exception was approved passed **198/198 Foundry** cases and
**110/110 Anthropic-header** cases. These include identical valid Bearer duplicates on inherited
and explicit/no-base paths: one policy-visible value, validated JWT context, and exactly one
credential-stripped mock receipt. Differing Bearer duplicates returned 400 with no observed
receipt; duplicate keys and mixed credential sources remained rejected. The Foundry run covers
12 copied operation shapes; the Anthropic run covers its single copied operation shape.

Both runs passed listener, firewall-rule and certificate cleanup. The Government VM was left
running as originally found. Production policies, backend credentials, URLs, NSGs and DNS were
unchanged. Disposable APIM test resources remain retained. The schema expectation change has
passed local characterization checks; its historical live strict failure above is not relabeled.

Remaining gates include Commercial mock-backend runs, HTTP/2 and additional raw-header negative
controls, product association removal/restoration and propagation, complete production-policy
integration, full identity/accounting and multi-user quotas, and rollback. The tiny call-quota
fixture does not prove production token quotas or telemetry. Review the complete evidence before
closing #140 or approving coexistence rollout; Okta customer validation remains separate.

#### Association, transport and design review follow-up (2026-09-18)

Commercial mock-backend execution finished with **187/198 cases passing**, not a full pass.
All ten raw-header cases returned no HTTP response; one ordinary chat-completions all-API-key
case also returned no response and remains unresolved. The Anthropic run was not reached.
Listener, firewall and certificate cleanup passed; the VM was restored to deallocated.

An inert `TransportTest` isolated the raw-header failure to TLS certificate validation:
`RemoteCertificateChainErrors` with `RevocationStatusUnknown,OfflineRevocation`. Ordinary
WebRequest HTTPS returned the expected 401. Raw requests failed before sending headers, so
they establish no Commercial duplicate-header behavior. Revocation validation remains enabled;
no network rules or trust stores changed. The test VM's curl lacks HTTP/2 support and PowerShell
7 is absent. HTTP/2 remains untested, not silently downgraded to HTTP/1.1.

The new `-AssociationGate` uses fresh disposable resources and encrypted credentials, without
a backend or firewall rule. Commercial passed the **16-case baseline and 50/50 association
cases**, covering both inherited and explicit/no-base paths:

| Stage | Product key | API/all-API keys | JWT | Missing |
|---|---|---|---|---|
| Native product unlinked | 401 | 200 | 200 | 401 |
| Native product restored | 200 | 200 | 200 | 401 |
| Open product unlinked | 200 | 200 | 401 | 401 |
| Open product restored | 200 | 200 | 200 | 401 |
| Rollback: open product unlinked | 200 | 200 | 401 | 401 |

Each case required three consecutive matching responses and expected context on successes.
All Commercial cases matched on their first three requests after ARM readback and VM invocation.
This demonstrates convergence when observed, not instantaneous revocation or zero-second
propagation. All stage certificates were removed. Final ARM readback confirmed the open product
unlinked and native product linked; the VM was restored to deallocated.

Government passed its baseline and the first **40 association cases**, then the cached ARM
token expired before rollback and also prevented automatic cleanup. Targeted recovery used
recent successful ARM association activity, exact disposable API/product ownership markers,
and the expected two-operation shape. Fresh-token recovery unlinked that open product and
restored its native product; both states were verified. No production association changed.
This is recovery evidence, not a passing final ten-case Government rollback stage.

The harness now refreshes ARM credentials before expiry (including cleanup) and user tokens
before association stages. Local fault injection verified that an expired ARM credential is
renewed before normal and cleanup requests. The initial retry was interrupted; a later complete
Government rerun passed **50/50 association cases**, with three matching responses per case,
all stage certificates removed and final open-unlinked/native-linked readback verified.

Fresh Government mock-backend reruns passed **202/202 Foundry** and **114/114 Anthropic**.
Repeated expired and tampered Bearer lines returned 401 with no receipt. Identical valid Bearer
lines returned 200 as one effective value, with one stripped backend receipt. Different values
in either order returned 400 with no receipt. Both final receipt audits passed after stopping
and joining the listener worker; listener, firewall and certificate removal passed. These are
HTTP/1.1 admission results, not HTTP/2 or full production accounting acceptance.

Readback found HTTP/2 explicitly disabled on both services. The owner approved temporary
service-wide HTTP/2 testing with restoration, a temporary Commercial VM-source-only TCP 80
Internet rule for CRL retrieval, and VM-source-only TCP 443 rules to the resolved portable-client
download addresses. These are bounded test windows, not permanent deployment changes. During
the Commercial window strict SslStream TLS reached HTTP 401 with revocation checks still enabled;
before the window it failed with offline revocation. Complete window/matrix results and cleanup
must be recorded separately; approval or a successful transport check is not a passing matrix.

The first Commercial HTTP/2 window did not reach the matrix: a local ten-minute process timeout
terminated `az apim wait` despite its forty-minute service timeout. Restoration readback showed
HTTP/2 `False`, zero temporary rules and the VM deallocated, but APIM still `Updating`.
The completed operation subsequently read `Succeeded` with HTTP/2 `True`: the earlier `False`
was not durable restoration. Activity logs confirmed the first rollback failed with `Conflict`
while enablement was running. A recovery write was accepted after the enable operation settled;
the recovery completed on 2026-09-19 with HTTP/2 `False`, provisioning `Succeeded`, and a passing
final readback. A separate final check confirmed zero temporary egress rules and the VM
deallocated. This verifies restoration, not admission: no HTTP/2 case passed in that window.

Opt-in `-Http2Gate` defines HTTP/2 credential cases with stdin-only credential transport,
strict protocol checking and client-directory cleanup, but is currently blocked by client
capability. The checksum-pinned curl 8.22.0_1 package was verified locally and provides
LibreSSL/HTTP2, not Schannel. `CURL_SSL_BACKEND=schannel` cannot add an absent backend.
The harness rejects that package before credential requests; a compatible verified client is
required. Native CA roots alone do not establish equivalent Windows revocation checking.
Opt-in `-SecondUserToken` adds distinct-user rate/quota controls sharing a counter across paired
operations. Their counters include validated issuer, tenant and subject. Fresh Government runs
on 2026-09-19 passed **242/242 Foundry** and **154/154 Anthropic**, including **40/40 two-user
cases per variant** with two distinct, same-tenant delegated users. Each user received three
successful calls before its own rate/quota rejection; an operation alias shared the exhausted
counter. The second user retained a separate allowance, and its requests did not reset the first
user's exhausted counter. Conflicting credentials were rejected before consuming the allowance.
Final backend receipt audits, listener/firewall/certificate cleanup, and preservation of the
Government VM's running state all passed. These are isolated HTTP/1.1 controls, not complete
production RPM/TPM/monthly accounting, telemetry, or streaming integration.

An earlier Anthropic setup stopped at the token-freshness guard before VM execution; it is not
counted as a matrix pass. Both credentials were silently renewed from their separate encrypted
Windows CLI caches before the successful retry. The initial attempt to create another auth-only
baseline also stopped before admission setup because APIM requires a unique API display name;
the successful runs reused the ownership-checked baseline and created fresh admission fixtures.

A Commercial two-real-user Foundry run on 2026-09-19 passed **235/242 cases**, including
**40/40 isolated two-user cases**, but failed the overall gate and final backend receipt audit.
The approved VM-only TCP 80 window restored strict TLS with revocation enabled. Repeated valid
Bearer headers returned 401 on both inherited and explicit paths instead of the expected 200;
different Bearer values in either order also returned 401 instead of the expected 400.
One API-scoped chat-completions request returned 500. These are observations requiring diagnosis,
not a reason to weaken expectations or infer the Government normalization behavior in Commercial.
Listener/firewall/certificate cleanup, temporary NSG rule removal, and original VM deallocation
all passed. A focused follow-up adds raw single-header positive controls and preserves sanitized
policy-error and backend-receipt details. With those controls, fresh Commercial runs passed
**240/246 Foundry** and **152/158 Anthropic**, with **40/40 two-user cases per variant** and all
single-header raw controls passing. The six failures in each variant were the repeated-valid
Bearer case and both orderings of different Bearer values on inherited and explicit paths.
All returned 401 with no backend receipt. Both final receipt audits failed because acceptance
was required for repeated-valid Bearer requests; neither full matrix passed. The earlier 500
did not recur, but its cause was not established. All local/backend and temporary network/power
cleanup passed. A further disposable-policy marker will distinguish source-guard rejections
from gateway parser rejection without returning credential values. That marked Anthropic run
also returned **152/158**, with the six failures showing `sourceGuard=true`, two policy-visible
Authorization values, and no backend receipt. Commercial preserves the multiplicity presented
to our guard; the guard then rejects as designed. Government's earlier normalization exposes
one value for identical lines. The marker's comma flag is the joined header view, not evidence
of a different wire request. Both services report Developer/`stv2`/Internal and HTTP/2 disabled;
runtime-build parity is unverified. All cleanup passed. Cross-cloud parity remains a required
gate, per the owner's decision above; no expectations were relaxed.

**Design review: retain the candidate; final approval remains pending.** The required-subscription
API with explicitly JWT-guarded open product preserves the demonstrated admission behavior.
Attach the open product last and unlink it first during rollback. The owner-approved identical
Authorization exception remains narrow; it does not excuse conflicting or invalid credentials.

Full accounting/integration is not proven. The current production JWT policy extracts `oid`
with an `unknown` fallback and keys RPM/TPM/monthly counters on `oid` alone, not the proposed
validated tenant-plus-user identity. A shared coexistence implementation and complete production
pipeline fixture remain required. Isolated real-user controls passed in both clouds, but the
Commercial full admission matrices still fail duplicate-header parity. These results do not
establish production accounting or cross-cloud parity. Forged
identity claims or operation-specific counters do not substitute for that evidence.
Keep #140 open. No production rollout, TLS-validation bypass, or permanent network change is
approved. Network changes are limited to the explicitly approved temporary test windows above.

### Expiry replay and remaining work

Token lifetime policy assessment (2026-09-18): read-only Microsoft Graph checks found
single-tenant v2 gateway resource applications in both clouds, no tenant token lifetime
policies, and no assignments on either resource application or service principal.
Microsoft documents policy creation/assignment in Commercial and Government L4/L5.
`AccessTokenLifetime` supports 10 minutes through `23:59:59` for newly issued tokens;
it does not rewrite an existing signed token, configure refresh-token lifetime, or apply
to APIM's backend managed identity. No token lifetime policy was created or assigned.

Use renewable credentials as the production approach. An app-specific 4-8 hour policy
could be an approved interim convenience for static-token clients, but extends the
replay window for a stolen token and still requires renewal. A dedicated test resource
application with a 10-minute policy could accelerate repeated expiry tests. Either change
requires approval, fresh issuance rather than a cached token, and inspection of the issued
lifetime before claiming success. Never use an organization-default policy for this test.
The current validator omits `clock-skew` (APIM default: zero); the harness's five-minute
delay is a conservative test buffer, not a configured gateway acceptance extension.

Government and Commercial genuine signed-token expiry passed on 2026-09-18: each unchanged
captured token returned 401, a fresh delegated token returned 200 with caller-header stripping asserted,
and temporary certificate/private-key cleanup passed. The baseline rejection controls also
passed in the same run. No issuer lifetime policy, signed claim, system clock or gateway
expiration setting was changed. This verifies expiry rejection, not automatic client renewal.

Unmodified samples are stored outside the
repository using Windows DPAPI, decryptable only by the capturing user on that machine.
Pass a recovered `SecureString` to `-ExpiredUserToken` together with `-TestExisting` and
`-IncludeUserToken`. The orchestrator refuses replay until five minutes after the sample's
`exp`, uses a fresh positive control, and CMS-encrypts both tokens to the temporary VM
certificate. Never modify `exp`, paste tokens into commands, or commit captured samples.

Probe APIs/products/subscriptions are retained for investigation, including partial setup
runs, and require explicit cleanup. The Commercial test VM is returned to its original
deallocated state after testing. Other policy surfaces, client
lifecycle, backend isolation, full accounting and Okta remain unverified. These results
do not close #140.

## References

- [APIM subscriptions and request handling](https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions)
- [Open products and API access](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-add-products#access-to-product-apis)
- [Policy scopes and inheritance](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-policies#scopes)
- [Internal-VNet self-call limitation](https://learn.microsoft.com/en-us/azure/api-management/send-request-policy#usage-notes)
- [Backend URL routing, not native admission](https://learn.microsoft.com/en-us/azure/api-management/set-backend-service-policy)
- [APIM validate-jwt](https://learn.microsoft.com/en-us/azure/api-management/validate-jwt-policy)
- [Entra configurable token lifetimes](https://learn.microsoft.com/en-us/entra/identity-platform/configurable-token-lifetimes)
- [Assign token lifetime policy and cloud availability](https://learn.microsoft.com/en-us/graph/api/application-post-tokenlifetimepolicies?view=graph-rest-1.0)
- [Okta authorization servers](https://developer.okta.com/docs/concepts/auth-servers/)
- [VS Code model configuration](https://code.visualstudio.com/docs/agent-customization/language-models)