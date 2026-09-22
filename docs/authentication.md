# Caller authentication: subscription keys, Entra and Okta

## Status and scope (2026-09-21)

This document separates the implemented authentication modes from the planned migration.
It is a design record, not a deployment procedure or a claim that Okta is enabled.

| Capability | Current status |
|---|---|
| APIM subscription-key authentication | Implemented; all four CI environment configurations select `authMode=subscriptionKey` |
| Entra access-token authentication | Implemented as the alternative deployment mode `authMode=jwt` |
| Key OR JWT on the same client-facing endpoint | Identical Authorization normalization accepted as a known platform limitation by the owner; remaining acceptance gates in #140 stay open. Production unchanged. |
| Direct Okta access-token validation | Planned; not implemented |
| CLI dynamic credential command | Opt-in implemented; Government VM CLI 1.0.85 passed both wire formats through private APIM with synthetic responses. Model inference and actual-expiry renewal remain untested. |
| VS Code Custom Endpoint automatic JWT renewal | No documented credential-command mechanism in the checked configuration reference |

Deployment-mode entries reflect source/configuration findings, not a fresh production inventory.
The wrapper scripts support static Entra tokens or opt-in per-request token acquisition through
the CLI credential command. No Okta helper is implemented.

### Delivery and tracking

Epic #139 tracks the
seven implementation steps and their dependencies; see the [roadmap task list](ROADMAP.md#authentication-design-pending-implementation).
Implement and fully validate Entra end to end in controlled environments, while writing
the Okta equivalent with local/fixture tests. Full Okta validation must wait for the
customer environment and is tracked separately in
#146.

Okta remains planned today. After implementation, label it **implemented, pending customer
validation** and keep it disabled by default until the customer gate passes. Entra success
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

### Approved special case: identical Authorization normalization

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
HTTP/2. The probes now expect acceptance for the exact-same-token case while keeping conflict
rejections. Historical failing runs are not retroactively relabeled as passing. The strict
duplicate blocker is waived only for this special case; **#140 is still open, not signed off**.
Microsoft clarification can proceed as a nonblocking follow-up; no support ticket has been
submitted and no front proxy, hostname migration, or production coexistence rollout is approved.

**Owner parity decision (2026-09-19): require identical behavior in both clouds.** After
Commercial rejected duplicate Authorization lines that Government normalized or rejected with
a different status, the owner declined cloud-specific acceptance expectations. Keep the existing
same-token and conflicting-token expectations unchanged while investigating the rejecting layer.
The earlier Government exception does not authorize a divergent Commercial contract, custom
first-value selection, or a new ingress deployment.

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

## Policy coverage

| Surface | Current deployment relationship | Required coverage |
|---|---|---|
| Foundry inference | Default when Foundry is enabled | Authentication, identity and limits |
| Foundry model discovery | Same API; operation skips API inbound | Explicit authentication before backend call |
| Responses get/delete/cancel/input-items | Four operations sharing an operation policy; skip API inbound | Explicit authentication; verify cross-user stored-response authorization separately |
| Anthropic messages | Optional; enabled in Commercial CI configurations | Same trust rules, `x-api-key` compatibility |
| AOAI inference | Optional | Same trust rules when enabled |
| IntelliJ main gateway proxy | Forwards to Foundry APIs, not a separate inference policy | Preserve/normalize either credential without treating a JWT as an authenticated subscription |
| Standalone IntelliJ bolt-on | Separate inference and discovery policies | Both policies; Bicep and Terraform packaging parity; VM and Container Apps proxy paths |

The main gateway's JWT policy variants are [Foundry inference](../policies/byok-foundry-policy.xml),
[discovery](../policies/byok-foundry-models-policy.xml),
[Responses follow-ups](../policies/byok-foundry-responses-item-policy.xml),
[Anthropic](../policies/byok-anthropic-policy.xml) and [AOAI](../policies/byok-aoai-policy.xml).
Existing key variants must retain their validation and accounting behavior during migration.
Wizard/manual deployment samples must be documented as key-only until explicitly updated
and tested; changes to the main deployment do not retrofit customer-installed policies.

## Entra and Okta choices

**Entra today:** request an access token for the gateway app, not Azure Resource Manager
or Cognitive Services. Existing policies expect the gateway app client-ID audience and
delegated `cli.invoke` scope. App-only client-credentials tokens are a different identity
contract and are not supported by that delegated-scope check unchanged.

**Okta federated sign-in to Entra:** Okta authenticates the user, but Entra issues the API
access token. The gateway continues validating Entra; users still need their Entra identity
and gateway permissions. Federation, MFA and cloud support must be validated for the tenant.

**Direct Okta access tokens (planned):** configure an Okta custom authorization server for
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
| Copilot CLI | No change | Opt in with `-AuthMode jwt -RefreshToken` or `AUTH_MODE=jwt REFRESH_TOKEN=1`; live VM expiry acceptance is pending |
| VS Code Custom Endpoint | No change | Replace stored API key with access token; renewal needs a supported provider/helper integration |
| IntelliJ | No change | Replace credential and validate proxy/header path; renewal depends on client/provider/helper |

CLI 1.0.85 documents command output as `api-key` for `azure`, Bearer for `openai`, and
`x-api-key` for `anthropic`. Use the provider that preserves the required URL/wire format.
The command should print only the access token to stdout; caching, expiry handling and
interactive reauthentication belong to the helper. No Okta helper ships in this repository.
Test inference, utility requests, discovery and long-running sessions, not just provider help.

The paired token helpers now use the existing Azure CLI cache for each request, pinned to the
configured cloud, tenant and delegated account. Local helper/wrapper tests and three real CLI
loopback checks initially passed, including both wire APIs' retry acquisition and no provider request on
credential failure. On 2026-09-21, the interactive Government VM user also passed both Responses
and Chat Completions through a disposable private APIM fixture with CLI 1.0.85: each process
exited 0, invoked the pinned helper once, and received its unique synthetic response proof.
Missing/invalid credentials returned 401, and API, local-file and CRL-rule cleanup all passed.

This verifies the real CLI/helper/gateway path, not model inference or renewal across actual
expiry within one continuing CLI session. Perform those remaining checks in the in-VNet VM's
user session; Run Command's SYSTEM account cannot substitute for that user's sign-in.
See the [client validation evidence](feature-request-byok-credential-refresh.md#validation-evidence).
The suite now contains nine passing CLI loopback checks, including persistent ACP sessions and
simulated expiry/failure controls. The bounded real-expiry VM gate is prepared, not yet passed.
Production APIs and the duplicate-header parity release gate are unchanged.

Current Foundry/AOAI JWT policies (including discovery and Responses follow-ups) require
the token in `api-key`; Anthropic JWT accepts Bearer or `x-api-key`. A static bearer-token
setting does not by itself change these policies or refresh a token.

VS Code's current documentation permits `requestHeaders` values containing the literal
`${apiKey}` to use secret storage. This is header interpolation, not OAuth renewal. The
built-in Azure provider has Entra authentication for the Cognitive Services scope, which
does not satisfy this gateway's custom audience. Preserve the existing URL marker when
using today's JWT-in-`api-key` path; Bearer-only support on that path is still planned.

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

##### Current cross-cloud parity request draft (2026-09-19, not submitted)

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
| Two different Bearer values, either order | 400 with no probe context or backend receipt | Two policy-visible values, source guard 401, no backend receipt |

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
**No support request has been submitted and no mitigation has been approved.**

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