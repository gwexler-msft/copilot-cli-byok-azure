# Private Copilot, Customer-Controlled AI

Seven-slide briefing for a 10–15 minute presentation. The generated PowerPoint is
`gov-byok-briefing.pptx` in this directory.

## 1. Private Copilot, Customer-Controlled AI

**Subtitle:** A reusable BYOK gateway for Azure Government and Commercial

- GitHub Copilot CLI and VS Code keep the familiar developer experience.
- Customer-owned APIM and Microsoft Foundry become the governed inference path.
- Private networking, managed identity, policy, and telemetry stay under customer control.

**Speaker note:** This is not a replacement developer tool. It is a controlled model path behind
the tools developers already use. The work packages the architecture as reusable, parameterized
infrastructure rather than a one-off deployment.

## 2. The Customer Problem We Solved

- Regulated teams want AI-assisted development without sending inference to an unmanaged public
  model endpoint.
- Security teams need a clear trust boundary, private data plane, centralized policy, and an
  attributable audit trail.
- Platform teams need one repeatable implementation across Commercial and Government clouds.

**Answer:** Put an internal Azure API Management AI gateway between the developer and a
private-endpoint-only Foundry deployment.

**Speaker note:** The important distinction is customer control of the inference path. GitHub SaaS
is not the default model path. APIM validates the caller, enforces policy, removes the inbound
credential, and authenticates separately to the model backend.

## 3. How the Request Flows

1. Copilot CLI or VS Code sends an OpenAI-compatible request over the customer's private access
   path.
2. Internal-VNet APIM authenticates the developer, applies token limits, normalizes client quirks,
   chooses the model/backend, and emits usage metrics.
3. APIM uses managed identity to call Foundry through a private endpoint; backend keys and public
   model access are disabled.
4. Log Analytics and Application Insights provide per-developer, per-model, and throttle telemetry.

**Speaker note:** The inbound and backend identities are deliberately separate. A developer's APIM
key or JWT never reaches Foundry. The backend sees the APIM managed identity. Chat Completions,
Responses, model discovery, streaming, and optional Anthropic-wire clients are handled at the
gateway.

## 4. What Changes in Azure Government

**Same design and codebase**

- One Bicep/azd implementation with cloud-specific parameter profiles.
- Sovereign login authority, Cognitive Services audience, private DNS zones, regions, and endpoints
  are selected by configuration.
- No Government-specific fork to maintain.

**Government-specific engineering**

- Use classic APIM Developer for pilots and Premium for production; APIM v2 is not available in
  Azure Government.
- Run smoke tests from VNet-injected self-hosted runners because the gateway is private and hosted
  runners are unavailable in the target EMU environment.
- Use Government-compatible API routing and portal/workbook telemetry workflows where query data
  plane access differs.

**Speaker note:** Azure Government is not treated as “Commercial with a different URL.” The
template parameterizes authorities, audiences, DNS, and availability. The default Gov inference
path remains inside the Government tenant and private network. A cross-cloud Commercial model
backend exists only as an explicit opt-in and changes that boundary, so it must be disclosed and
approved separately.

## 5. What We Delivered and Proved

- A parameterized subscription-scope Bicep/azd platform for Commercial and Government.
- Private APIM-to-Foundry routing using managed identity, private endpoints, disabled public access,
  and disabled local backend auth.
- First-class Copilot CLI and VS Code support for Chat Completions and Responses, including streaming,
  stateful Responses operations, model discovery, and client-shape normalization.
- Per-developer tiers, token limits, model routing, throttling, and workspace-based telemetry.
- Private self-service onboarding and ephemeral, VNet-injected CI runners with automated smoke tests.
- Live validation on both Commercial and Government pilots, captured through release 2.2.0.

**Speaker note:** Say “pilot validated,” not “universally production certified.” The strongest proof
is the automated dual-cloud regression loop: the same source provisions both dev environments,
tests from inside each private VNet, and preserves long-lived pilots for demos and canary checks.

## 6. Hard Problems Already De-Risked

- **Credential lifetime:** subscription keys are the pragmatic fleet default until clients refresh
  Entra JWTs in-session.
- **Copilot protocol behavior:** APIM handles streaming usage, reasoning-model parameter differences,
  Responses routing, and unsupported client metadata.
- **Content filtering:** a coding-specific policy avoids false-positive jailbreak blocks while
  retaining annotation and harm controls.
- **Government observability:** use workspace tables and in-VNet assertions; do not depend on
  Commercial-only query behavior.
- **Private CI operations:** self-hosted runners, private Key Vault references, credential rotation,
  and deployment ordering are documented and automated.

**Speaker note:** This slide is the reusable-IP argument. Much of the value is not the resource
diagram; it is the set of tested policy fixes and operating procedures that prevent every customer
team from rediscovering the same platform constraints.

## 7. Customer Value and Adoption Path

**Customer outcomes**

- Stronger data-boundary story: private inference endpoint and customer-controlled network path.
- Reduced secret exposure: managed identity to the backend; no model key on developer machines.
- Governed consumption: per-developer limits, routing, usage attribution, and operational telemetry.
- Faster delivery: configure-and-deploy reusable IP instead of redesigning each engagement.
- Cloud portability: one operating model across Commercial and Government.

**Adoption path**

1. Select the cloud profile, regions, models, APIM tier, and customer network integration.
2. Choose subscription-key or JWT authentication based on fleet and identity requirements.
3. Deploy through the reviewed CI path, then run private smoke and telemetry assertions.
4. Onboard a limited cohort, tune tiers and policies, and promote from pilot to production APIM.

**Speaker note:** Close on the decision this enables: a customer can begin with a tightly scoped
pilot, prove the private trust boundary and developer workflow, then scale using the same artifacts
and operating model. Production should use an SLA-backed APIM tier and customer-specific security,
capacity, and compliance review.

## Source Material

- `docs/architecture.md`
- `docs/lessons-learned.md`
- `docs/operations-lessons.md`
- `docs/cicd.md`
- `docs/RELEASES.md`
