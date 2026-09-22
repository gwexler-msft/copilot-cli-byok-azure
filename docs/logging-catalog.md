# APIM and Foundry logging catalog and developer identity correlation

## Customer summary

Azure API Management (APIM) can report who used the AI gateway, which API and model
they used, latency, failures, throttling, and token consumption where the backend
and gateway support usage reporting. These are separate telemetry categories, not
one complete request audit record.

This catalog distinguishes **configured in this repository**, **optional platform
capability**, and **proposed customization**. It describes checked-in configuration;
it is not an inspection or certification of a customer's deployed environment.

The current solution attaches developer identity to custom metrics. The recommended
extension is a structured, authenticated identity trace correlated with request,
dependency, and exception telemetry. That extension is **not implemented here**.

Microsoft Foundry adds model-service resource logs, platform metrics, and optional
application/agent tracing. These are separate collection paths, not automatically
part of APIM's Application Insights integration. Section 6 covers their categories,
configuration status, and how to correlate them with the developer identity at APIM.

For representative record formats, see [section 7](#7-representative-entry-formats).
For the JWT preflight work, see [section 8](#8-authentication-logging-entra-id-and-okta).

## 1. Application Insights categories

These are workspace table names. Run queries against the linked Log Analytics
workspace, scoped to the intended Application Insights resource. Application Insights
query contexts can expose different names, such as `requests` and `customMetrics`.

| Category | Table | Data available | Status and qualifications |
|---|---|---|---|
| Incoming requests and responses | `AppRequests` | Timestamp, request name/URL, response status, success, duration, request span ID, operation/parent IDs, and APIM context in `Properties` | Configured for successful 2xx responses as well as failures, subject to effective diagnostics and sampling. One request record describes the frontend transaction, not separate rows for its request and response. Includes rejected calls that reach the gateway's logging pipeline. |
| Backend and other external calls | `AppDependencies` | Target, dependency type/name, result code, success, duration, operation/parent IDs | Configured. Includes backend forwarding and supported policy dependencies. Retry attempts, classifier calls, identity-token acquisition, and OIDC metadata retrieval can appear when executed and supported by the gateway version. Not every request makes every dependency call. |
| Failures and exceptions | `AppExceptions`, plus failed `AppRequests` and `AppDependencies` | Exception type/message/details, policy/gateway failures, HTTP errors, timeouts, and client-disconnect failures where emitted | Automatic APIM exception telemetry is supported. A failed HTTP result is not proof of a backend application exception; backend stack traces require backend instrumentation. Do not add exception counts to failed-request counts as if they were distinct calls. |
| Authentication, authorization and throttling | `AppRequests`, `AppExceptions`, selected `AppMetrics` | Successful 2xx requests as well as 401/403/429 outcomes; available policy error context and dedicated throttle counters where implemented | Request outcomes follow effective diagnostics and sampling. A 2xx request is not a separate authentication-success event; structured authentication decisions require the proposed instrumentation. Not every rejection has a known developer or custom counter, and status alone does not distinguish gateway versus backend causes. |
| Content filtering and safety | Request/dependency failures; additional fields only when deliberately instrumented | Backend rejection status and any emitted error context | Not a structured safety-category audit feed. Body capture is disabled in the repository's default Application Insights configuration, and detailed filter classifications or successful-response annotations are not automatically extracted into custom properties. |
| Custom policy traces | `AppTraces` | Trace message, severity, source, custom metadata in `Properties`, operation/parent IDs | Optional through the `trace` policy. The BYOK inference policies do not currently emit a structured developer-identity trace. Diagnostic verbosity permits `information` and `error`, not `verbose`. |
| AI usage and governance metrics | `AppMetrics` | Request counters, token usage, routing decisions, classifier usage, and selected throttle counters, with custom dimensions | Configured through policy emissions; see section 3. These are aggregated measurements, not a guaranteed per-request ledger. |
| Request/response headers and bodies | Properties on the corresponding request/dependency telemetry when enabled | Selected frontend/backend headers and a bounded number of payload bytes | **Disabled in this repository's default Application Insights configuration**: all four header lists are empty and all four body limits are zero. APIM supports selected header logging and bounded body capture at service or API level; API-level diagnostics can override the defaults. Header logging does not require enabling body capture. |
| Availability tests | `AppAvailabilityResults` | Probe location, success, duration, and failure details | Requires a separately configured test; not created by this APIM diagnostic. An internal gateway needs an appropriately network-connected test runner. |
| Custom events and client experience | `AppEvents`, `AppPageViews`, browser/client telemetry | Business events, user sessions, UI timings | Not automatically generated by the APIM integration. Requires separate application/client instrumentation. APIM cannot observe IDE activity or model calls that bypass this gateway. |

Fields vary by telemetry type, gateway version, and diagnostic scope. Inspect actual
`Properties` before promising a particular APIM API, operation, product, or subscription
field to a customer. A table's existence does not mean this deployment produces rows in it.

## 2. Related logs that are not Application Insights telemetry

| Category | Destination | Current configuration / distinction |
|---|---|---|
| Gateway resource logs | `ApiManagementGatewayLogs` in Log Analytics | `GatewayLogs` is explicitly enabled with the `Dedicated` destination. Provides gateway status, timing, backend, subscription and error context; it does not automatically contain the caller's Entra object ID. |
| APIM platform metrics | Azure Monitor metrics; exported supported metrics in `AzureMetrics` | `AllMetrics` export is enabled. Covers service-level health, traffic and capacity metrics where supported, not per-developer identity. |
| LLM, MCP, WebSocket and developer-portal resource logs | Category-specific Azure Monitor resource logs | Separate, optional categories where supported by cloud/tier. Not enabled by the shared template; do not assume Commercial categories exist in Government. |
| Management-plane changes | Azure Activity Log | Records management operations such as changing a policy or resource configuration. Not a log of developer inference calls and not automatically exported by this APIM diagnostic. |
| Identity-provider sign-ins and audit | Entra sign-in/audit logs or the applicable identity provider | Separate diagnostic/export configuration and permissions. A token can serve many gateway calls; sign-ins are not one-to-one with APIM requests. |
| Model service and application logs | Backend diagnostics / application instrumentation | Separate from APIM logging. The backend normally sees APIM's managed identity or configured backend principal, not the individual developer. |

## 3. Customization already present

### Identity attribution

| Authentication mode | `developer_oid` metric dimension | `developer_upn` metric dimension | Meaning |
|---|---|---|---|
| Entra JWT | `oid` from the validated token | Validated `preferred_username`, falling back to `upn`, then `unknown` | Authenticated token subject. Current extraction can fall back to `unknown` for missing claims; an immutable identity claim must be present for reliable attribution. |
| APIM subscription key | APIM subscription ID | APIM subscription display name, falling back to ID | Credential/subscription attribution, **not** an Entra object ID or independently verified human identity. This is an APIM subscription, not an Azure subscription. |

A unique subscription per developer supports owner-based reporting through a maintained
subscription-to-developer mapping. Shared or copied keys cannot establish which person
actually made a call. APIM's built-in user/subscription identifiers must not be assumed
to be Entra identifiers. Display names and UPNs can change and should not be join keys.

### Metric inventory

Custom metrics use the `copilot.byok` namespace. The inference policies are not the
only API operations: model discovery and Responses item operations need separate
coverage verification.

| Metric / policy | Category | Existing dimensions and coverage |
|---|---|---|
| `copilot_byok_request` | Usage | Developer ID/label, deployment, routing decision; Foundry and Anthropic also include backend. Emitted only when execution reaches this policy, after some validation/routing checks, not for every gateway request. |
| `llm-emit-token-metric` | AI consumption | Developer ID/label, deployment, and backend where configured. Native token metrics depend on backend usage and protocol support; validate streaming separately for each model/API/cloud. Missing usage is not zero consumption. |
| `copilot_byok_auto_route` | Model selection | Developer label, selected deployment, decision, reason, and length band. Foundry/AOAI auto-routing only; this metric does not include `developer_oid`. |
| `copilot_byok_classifier_tokens` | Routing overhead | Developer ID/label, classifier deployment, backend. Only when the optional classifier runs and returns usable usage. Keep classifier overhead separate from the main inference. |
| `copilot_byok_prompt_tokens`, `copilot_byok_completion_tokens` | Compatibility token counters | Present in Anthropic outbound policies for JSON responses. Do not sum these and native token metrics for the same usage without proving they are mutually exclusive. |
| `copilot_byok_throttled` | Limit enforcement | Developer ID/label, deployment, backend, throttle type (`burst`, `tokens`, `quota`, `other`). Foundry/AOAI JWT `on-error` paths with established identity and a 429 response; not a universal counter for every backend or product-level rejection. |

For subscription-key throttles, gateway resource logs provide subscription-based
reporting. Rejections before an identity or metric policy is reached will not have
that policy's identity dimensions. Use request telemetry for overall gateway outcomes.

Token counts support usage reporting and rate-card-based cost estimates; they are not
an invoice. Model/version, pricing date, caching, reasoning tokens and other billable
features can affect actual cost.

## 4. Proposed developer-correlation customization

**Status: design recommendation, not an enabled policy.** Emit a small `information`
trace, for example `byok.identity`, immediately after successful credential validation
and identity resolution, before later routing checks and limits where policy order
permits. Use a fixed message and structured metadata, never a credential or raw token.
Attach additional route metadata only after the gateway has resolved it.

### Core identity and request fields (proposed)

| Proposed field | Trusted source / purpose |
|---|---|
| `auth_method` | Gateway-selected authentication branch, such as `entra_jwt` or `subscription_key`. |
| `principal_key` | Stable, namespaced key: Entra tenant plus immutable object ID; for key mode, gateway plus APIM subscription ID. Keep these identity types distinct. A governed pseudonymous mapping is an alternative. |
| `tenant_id`, `subject_id` | Allowlisted claims from a successfully validated Entra token; absent for a key-only caller. Any separately sourced subscription-owner attributes must be labelled as ownership enrichment, not token-subject claims. |
| `apim_subscription_id` | Validated `context.Subscription.Id` when available; never the subscription key itself. |
| `gateway_request_id` | Gateway-generated `context.RequestId`, for support correlation. Record in logs, not as a metric dimension. |
| `api_id`, `api_operation_id`, `deployment_name`, `backend`, `auto_route` | Gateway context and resolved routing values, where known. Requested versus resolved model should be distinct when auto-routing is used. |
| `schema_version` | Version of the enrichment contract so dashboards can handle changes explicitly. |

Future identity providers need an exact trusted issuer plus stable subject namespace;
same-endpoint multi-provider admission is not implied by this design. Follow the
[authentication contract](authentication.md) before adding another issuer.

### Optional display label

`developer_display_name` is an optional, **display-only proposal**, not an implemented
field. Populate it only from an approved claim in a successfully validated token
(for example `name`, if present) or an approved directory mapping keyed by stable
identity. If no approved source exists, omit it; never substitute a caller-supplied
label. This does not change the existing `developer_upn` metric dimension.

Token validation establishes the issuer of a claim, not the label's uniqueness,
current accuracy or business ownership. Entra `name` and `preferred_username` are
mutable display values. Do not use the label as a join, authorization or chargeback
key. Storing it under `Properties` provides **storage, not verification**; it does
not establish a developer-to-application ownership relationship.

### Customer-specific enrichment (not implemented)

`team`, `cost_center` and `project` are **unavailable in the baseline solution** and
excluded from the core correlation fields and examples. No ownership-data integration
currently supplies these attributes to gateway telemetry. The registration app's
Graph group-membership lookup supports tier selection, not this enrichment pipeline.

Before adding any such field, a customer-specific design must:

- Identify an authoritative source and data owner, with a mapping from the trusted
  issuer plus stable subject or a governed subscription-owner record. Display names
  and caller-supplied labels are not authoritative mappings.
- Control updates and define provenance, effective dates, freshness and missing/stale
  value handling. Do not invent missing values or silently apply today's ownership
  mapping to historical usage.
- Approve the permitted reporting uses, reader access and retention. A reporting
  attribute does not by itself become an authorization or chargeback entitlement.
- Establish how a particular request is assigned to a project or workload. Developer
  project membership alone does not establish which project should pay for that request.

Until that design is approved and implemented, omit these fields. If later added to
trace `Properties` or joined in a reporting layer, the storage location still does
not verify their business meaning.

### Correlation rules

1. Use Application Insights `OperationId` for W3C trace correlation across
   `AppRequests`, `AppDependencies`, `AppExceptions`, and the new `AppTraces` records.
   Scope to the intended Application Insights resource and time window.
2. For developer attribution to an individual request, also match the request span:
   trace `ParentId` to request `Id` where emitted. Validate this relationship with
   test traffic. A single distributed trace can contain multiple requests, so joining
   on `OperationId` alone can multiply rows or assign the wrong identity.
3. Preserve the parent/child chain for nested dependencies. Request status and duration
   should come from completed request telemetry, not from the early identity trace.
   For streaming, a policy returning headers is not proof that the full stream completed.
4. `context.Operation.Id` is the APIM API operation identifier, not the Application
   Insights trace ID. Likewise, do not assume `context.RequestId`, gateway resource-log
   correlation IDs and Application Insights span IDs are interchangeable.
5. Trace metadata appears on the trace's `Properties`; it does **not** automatically
   stamp `developer_oid` or `UserAuthenticatedId` onto every other telemetry row.
   Build a joined query/workbook view. Do not use aggregated `AppMetrics` as the
   per-request identity join source.
6. Invalid/expired credentials remain unattributed or explicitly unauthenticated.
   Never decode an unvalidated JWT and report its claimed user as authenticated.
   Native subscription validation and product limits can run before this trace;
   use available validated subscription context and document the remaining gap.

The proposed identity trace supports views such as **developer -> requests ->
latency/errors -> backend/model**. Team or project summaries additionally require
the customer-specific enrichment above, which is not implemented. Per-request token
attribution requires supported request-level usage records; aggregate token metrics
alone cannot provide it.

### Capacity and privacy controls

- APIM permits at most **five custom metric dimensions**, **100 unique values per
  dimension**, and **1,000 active time series per metric namespace**, according to
  Microsoft's current documentation. New values/series beyond the limits can be
  silently discarded. A fleet exceeding 100 developer identities can outgrow the
  existing per-developer metrics even before model/backend combinations are counted.
- Keep high-cardinality identities and request IDs in structured logs. Use metrics for
  bounded aggregates; log-derived reporting still requires volume/cost planning.
- The `trace` policy is not affected by Application Insights sampling. Reducing request
  sampling does not reduce these trace emissions, and a retained trace may have no
  retained request row. Monitor ingestion health and join coverage.
- Never log `Authorization`, `api-key`, `x-api-key`, cookies, access/refresh tokens,
  subscription keys, prompts or completions for identity correlation. Do not forward
  new developer-identity headers to the model backend just to make them loggable.
- Zero body/header capture is not a complete privacy guarantee: URLs/query strings,
  error messages, IP settings and existing developer labels can still contain sensitive
  data. Prevent secrets in URLs and review masking, access controls and retention.
- Treat object IDs, UPNs, team membership and stable pseudonyms as sensitive linkable
  data. Approve the identity schema, directory access, retention and reader roles.
- Application Insights is operational telemetry, not a guaranteed exhaustive or
  immutable audit system. Regulatory audit or financial chargeback needs a separately
  specified completeness, integrity and retention design.

## 5. Configuration and acceptance checklist

The [APIM module](../infra/modules/apim.bicep) configures a service-level Application
Insights diagnostic with 100% fixed sampling, `alwaysLog: allErrors`, `metrics: true`,
W3C correlation, `information` verbosity, and `logClientIp: true`. API-level diagnostics
can override this. Client-IP logging is subject to ingestion masking and proxies/NAT;
an IP address is not a developer identity.

The 100% sampling setting includes successful requests as well as failures.
`alwaysLog: allErrors` exempts errors from sampling; it does **not** mean "log errors
only." Effective API overrides and ingestion conditions still need verification.

The [observability module](../infra/modules/observability.bicep) links Application
Insights to Log Analytics and sets a 30-day workspace retention default. Confirm
effective table-specific retention and deployed networking settings separately.
Government query access must be tested from an approved network/identity; see the
[operational guidance](operations-lessons.md#8-observability).

Before enabling the proposed enrichment:

- Confirm effective diagnostics and actual field shapes with representative traffic.
- Exercise two distinct users and two distinct subscriptions, including shared-key
  limitations, and verify no cross-user join fan-out within a distributed trace.
- Cover success, routing rejection, invalid/expired credentials, each throttle path,
  backend failure/retry, and client cancellation; leave pre-auth failures unattributed.
- Cover every API/operation and both authentication variants, including discovery and
  Responses subresources, not just the primary inference policy.
- Verify JSON and streaming token coverage per cloud/model/API, absence of duplicate
  token accounting, and metric-cardinality limits at expected fleet size.
- Check emitted records for credentials, payload content and unapproved personal data.
- Validate request/span correlation, ingestion delay, sampling gaps, query access and
  the estimated ingestion/retention cost. Do not claim live verification from static code.

## 6. Foundry logging and observability capabilities

### Current deployment boundary

The [Foundry module](../infra/modules/foundry.bicep) creates an `AIServices` account,
model deployments, content-filter policies and private connectivity. The checked-in
Bicep does **not** define a Foundry account diagnostic setting. APIM's diagnostic
setting does not collect the backend account's resource logs or export its metrics.

Foundry platform metrics and Azure Activity Log events are collected automatically
at their respective Azure scopes. Collecting account resource logs, exporting metrics
to Log Analytics, and enabling application/project tracing require separate setup.
No Foundry logging configuration is enabled by adding this catalog.

The account categories below come from the `Microsoft.CognitiveServices/accounts`
reference. Verify availability on the actual account, model, deployment type, region
and cloud. Azure OpenAI-specific telemetry is not a promise of equivalent coverage
for every partner model or Foundry Agent Service feature.

### Account resource-log categories

| Category | What it can provide | Destination and qualification |
|---|---|---|
| `Audit` | Service audit events for supported account operations | Optional diagnostic category, documented in `AzureDiagnostics`. Distinct from subscription-level Azure Activity Log; not a record of all developer activity. |
| `RequestResponse` | Service request/response operational metadata, such as operation, result and duration where emitted | Optional diagnostic category in `AzureDiagnostics`. The category name alone does not guarantee full prompt/completion bodies or a uniform schema across APIs. |
| `Trace` | Service-side diagnostic/troubleshooting records | Optional diagnostic category in `AzureDiagnostics`. Not the same as Application Insights `AppTraces` or an instrumented agent's execution graph. |
| `AzureOpenAIRequestUsage` | Azure OpenAI request-usage records where supported | Optional diagnostic category in `AzureDiagnostics`, not a table of the same name. Verify the emitted fields, API/model coverage and content-capture behavior before using it for per-request accounting. |
| `ManagedNetworkEvent` | Managed-network events for applicable Foundry networking features | Optional diagnostic category in `AzureDiagnostics`. A private endpoint alone does not imply this category records all DNS, firewall or packet activity. |

These are account-provider categories, not five guaranteed feeds for every model.
In particular, the [Foundry Tools logging guide](https://learn.microsoft.com/en-us/azure/ai-services/diagnostic-logging)
limits its `Trace` category to Custom question answering. Do not interpret that
category as access to model reasoning, token-by-token execution or agent traces.

Documented sample fields include `TimeGenerated`, `_ResourceId`, `Category`,
`OperationName`, `DurationMs`, `ResultSignature` and `properties_s`; availability and
service-specific properties depend on the category. Inspect representative records
before defining joins or dashboards. APIM's `Dedicated` table destination does not
change the Foundry categories' documented `AzureDiagnostics` destination.

Diagnostic settings can route supported logs to Log Analytics, Storage or Event Hubs.
Account logs sent to the same workspace as Application Insights remain resource logs;
they do not become `AppRequests` or `AppTraces`. Export and ingestion charges need
separate review, especially for detailed request-usage records.

### Model metrics by category

These are **Azure Monitor platform metrics**, not APIM's `copilot.byok` custom
metrics. Metric names below are examples from Microsoft's reference; select the
family supported by the deployed model rather than summing overlapping families.

| Category | Examples | What the customer can learn |
|---|---|---|
| Traffic, errors and throttling | `AzureOpenAIRequests`; `ModelRequests` for supported model endpoints | Backend request volume and status distribution, including backend 429s, split by supported dimensions such as deployment, model/version, region and streaming mode. APIM-rejected calls that never reach Foundry are absent. |
| Token usage and caching | `ProcessedPromptTokens`, `GeneratedTokens`, `TokenTransaction`; model-family equivalents `InputTokens`, `OutputTokens`, `TotalTokens`; supported cache metrics | Input/output usage and caching behavior by model/deployment. These are aggregate service measurements, not developer-attributed billing records. |
| Latency and generation speed | `AzureOpenAITimeToResponse`, `AzureOpenAITTLTInMS`, `AzureOpenAINormalizedTBTInMS`, `AzureOpenAINormalizedTTFTInMS`, `AzureOpenAITokenPerSecond` | First-response responsiveness, completion latency and generation speed where supported. Service timing is not client end-to-end latency; coverage varies by deployment type and streaming mode. |
| Provisioned capacity | `AzureOpenAIProvisionedManagedUtilizationV2`; `ProvisionedUtilization` for supported model endpoints | Provisioned-throughput utilization and capacity pressure. Applicable to provisioned deployments, not a utilization measure for every pay-as-you-go deployment. |
| Content safety | `RAITotalRequests`, `RAIHarmfulRequests`, `RAIRejectedRequests`, `RAISystemEvent` | Safety checks, detections, blocked volume and system events, with category/severity dimensions where supported. Annotate-only detections can occur on successful calls; these are not automatically per-developer safety events. |
| Managed model routing | `ModelRouterRequests`, `ModelRouterFallbackCount`, `ModelRouterLatency` | Managed Foundry Model Router traffic, fallbacks and routing overhead when that feature is used. Separate from the free APIM heuristic's `copilot_byok_auto_route` metric. |
| Fine-tuning and modality-specific usage | `FineTunedTrainingHours` and supported audio, image or real-time usage metrics | Additional feature-specific consumption when those features are used; not necessarily relevant to a text-only BYOK deployment. |

Use Azure OpenAI/model-specific metrics for model performance analysis, not the
legacy generic Cognitive Services `Latency`, `TotalCalls` or `BlockedCalls` metrics.
Check each metric's **DS Export** support before promising it in `AzureMetrics`:
for example, the reference marks provisioned utilization and prompt cache match rate
as not exportable through diagnostic settings. Metric dimensions may also be lost
or aggregated during diagnostic export; use Metrics Explorer/API for supported
dimensional analysis. Missing log-export rows do not mean the metric is unavailable
at its source.

### Application, agent and evaluation telemetry

Foundry can display OpenTelemetry traces stored in a linked Application Insights
resource. This requires the applicable project/resource connection and SDK or
application instrumentation; simply calling a model through APIM does not instrument
the developer's IDE or produce an agent/tool execution trace.

| Category | Additional visibility | Prerequisite / status in this solution |
|---|---|---|
| Application and model spans | Trace/span IDs, parent-child calls, timing, errors, requested/returned model and usage attributes where emitted | Optional OpenTelemetry/Azure Monitor instrumentation. Telemetry maps to Application Insights tables such as `AppRequests`, `AppDependencies` and `AppTraces` according to signal type/exporter. Not enabled by the Foundry account module. |
| Agent and tool execution | Instrumented agent steps, tool calls, dependencies and failures | Requires a supported agent/runtime tracing integration. Client-side Copilot tool activity does not become visible just because its inference uses Foundry. |
| Evaluation and quality | Configured quality/safety scores associated with responses or traces, such as groundedness or relevance | Requires a separate evaluation/monitoring workflow and supported instrumentation. Not automatically inferred from HTTP success, token metrics or content-filter counters; storage/export depends on the evaluation workflow. |
| Message content | Prompt/completion or tool input/output content when explicitly captured | Separate, sensitive opt-in. The documented OpenAI SDK instrumentation has an optional `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT` setting; leave content capture off for identity-only correlation. |

APIM's zero-byte body logging does not disable independent Foundry or SDK content
capture. Review each collection path independently for secrets, source code, personal
data, retention and access. Do not enable broad payload logging merely to correlate
requests. Service abuse-monitoring controls are also separate from customer-managed
Azure Monitor diagnostic exports.

### Correlating Foundry with the developer

**Proposed extension, not implemented:** retain the trusted identity anchor described
in section 4 at APIM, then connect it to individual backend attempts. Foundry normally
authenticates APIM's managed identity or the configured cross-cloud backend principal;
that principal is not the human developer.

1. Associate the APIM request span and validated `principal_key` with the resolved
   backend account/deployment and each backend attempt. Distinguish inference,
   classifier calls and retries; one developer request can create multiple backend calls.
2. Where the endpoint exposes a service request/correlation ID, capture that allowlisted
   identifier in a structured gateway record and verify its correspondence to the
   backend log schema. Proposed fields include `backend_request_id`,
   `backend_resource_id` and `backend_attempt`. Header names and ID relationships must
   be tested per API/provider; they are not collected by the current empty header lists.
3. Join backend resource logs using the verified service identifier and backend resource
   scope. Do not assume a Foundry resource-log correlation ID equals Application Insights
   `OperationId`. APIM's Application Insights `_ResourceId` and the Foundry account's
   `_ResourceId` describe different resources and are not equal join keys.
4. For instrumented applications/agents, preserve W3C trace context across supported
   boundaries and validate parent/child spans. A shared Application Insights resource
   or workspace alone does not create trace propagation or developer attribution.
5. Compare APIM and Foundry token totals as independent views of usage; never add them
   together for the same inference. Reconcile retries, classifier overhead, cancellations,
   model names, time windows and ingestion delay. Platform metrics cannot provide an
   exact per-request identity join, and unmatched records must remain unattributed.

The intended view is **developer -> APIM request -> backend attempt -> Foundry
operation/usage**, with optional application/agent spans. Where no supported shared
identifier exists, limit reporting to explicit aggregate comparisons rather than
matching users by approximate timestamps, model name or IP address.

### Foundry acceptance checks

- Enumerate supported categories and metric definitions for every backend account,
  including secondary regions and any cross-cloud route, before configuring exports.
- Validate Government availability separately; keep telemetry in the approved cloud
  and data-residency boundary. Cross-cloud inference does not imply cross-cloud log
  export is configured, supported or permitted.
- Verify diagnostic destinations, actual schemas, payload-capture behavior, reader
  permissions, retention and export/ingestion cost using approved test data.
- Test request-ID/span correlation for success, backend failures/retries, streaming
  completion/cancellation and multiple developers. Expect no Foundry record for a call
  APIM rejects before forwarding.
- Verify model-specific token and safety coverage; do not interpret missing metrics
  as zero spend or absence of safety detections. Keep evaluation results separate from
  service safety counters and HTTP error statistics.

## 7. Representative entry formats

**All examples below are synthetic, sanitized illustrations, not captured customer
records or proof of live ingestion.** They show selected columns from a Log Analytics
row serialized as JSON, unless explicitly labelled otherwise. They are not the raw
Application Insights ingestion envelope or the Logs REST API `tables/columns/rows`
response. Omitted columns and empty property bags mean "not illustrated," not that
Azure always emits an empty value.

- Dates are UTC strings in these JSON examples; Log Analytics stores them as `datetime`.
- JSON numbers and booleans remain numbers and booleans. Application Insights
  `ResultCode` is a **string**; some resource-log status fields are integers.
- `Properties` and `Measurements` are `dynamic` columns represented as JSON objects.
  Foundry's `properties_s`, when present, is a **string containing JSON**, not the
  same column/type as `Properties`.
- `<...>` values are placeholders, including IDs and hostnames. They must not be
  treated as real IDs or copied into a parser as valid W3C trace/span identifiers.
- In the Application Insights workspace tables, `TenantId` identifies the **Log
  Analytics workspace**, not the developer's Entra tenant. Proposed `tenant_id`
  metadata is a separate field.

#### Format index

| Catalog item | Example / format notes |
|---|---|
| Incoming requests, backend dependencies, errors | [7.1](#71-requests-dependencies-failures-and-security-outcomes) |
| Authentication, authorization, throttling, content-filter outcomes | [7.1](#71-requests-dependencies-failures-and-security-outcomes); these reuse request/error schemas. |
| Custom traces and developer identity | [7.2](#72-custom-traces-and-proposed-identity-enrichment) |
| Every custom request/token/routing/throttle metric in section 3 | [7.3](#73-custom-usage-and-governance-metrics) |
| Gateway resource logs; request/response headers and bodies | [7.4](#74-gateway-resource-logs-and-optional-payload-capture) |
| Availability, custom events, page/client experience | [7.5](#75-availability-custom-events-and-client-experience) |
| APIM platform metrics and all seven Foundry metric categories | [7.6](#76-platform-metrics-exported-to-logs) and [7.10](#710-native-azure-monitor-metric-response) |
| Management changes, identity sign-ins and directory audit | [7.7](#77-management-activity-and-identity-provider-records) |
| APIM LLM, MCP, WebSocket and developer-portal logs | [7.8](#78-optional-apim-llm-mcp-websocket-and-portal-logs) |
| All five Foundry account resource-log categories | [7.9](#79-foundry-account-resource-logs), including the remaining inner-schema evidence gap. |
| Foundry application/model spans, agent/tool execution, evaluations, message content | [7.11](#711-application-agent-evaluation-and-message-formats) |
| Proposed developer-to-backend correlation | [7.12](#712-proposed-backend-correlation-record) |
| Entra/Okta authentication, JWT failures and credential lifecycle | [8](#8-authentication-logging-entra-id-and-okta) |

### 7.1 Requests, dependencies, failures and security outcomes

**Incoming request/response: `AppRequests`.** Documented
[column schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/apprequests).

```json
{
  "TimeGenerated": "2026-09-21T12:00:00Z",
  "Id": "<APIM_REQUEST_SPAN_ID>",
  "OperationId": "<TRACE_ID>",
  "ParentId": "<CLIENT_SPAN_ID>",
  "Name": "POST /openai/v1/chat/completions",
  "Url": "https://<APIM_HOST>/openai/v1/chat/completions",
  "ResultCode": "200",
  "Success": true,
  "DurationMs": 1250.5,
  "ItemCount": 1,
  "Properties": {},
  "_ResourceId": "<APPLICATION_INSIGHTS_RESOURCE_ID>"
}
```

**Backend/external call: `AppDependencies`.** One backend attempt is illustrated;
additional attempts or supported policy calls can produce additional rows. The
`ParentId` below references the request span, not the trace ID. Documented
[column schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/appdependencies).

```json
{
  "TimeGenerated": "2026-09-21T12:00:00.050Z",
  "Id": "<BACKEND_ATTEMPT_SPAN_ID>",
  "OperationId": "<TRACE_ID>",
  "ParentId": "<APIM_REQUEST_SPAN_ID>",
  "Name": "POST /openai/deployments/<MODEL_DEPLOYMENT>/chat/completions",
  "Target": "<FOUNDRY_HOST>",
  "DependencyType": "HTTP",
  "ResultCode": "200",
  "Success": true,
  "DurationMs": 1180.0,
  "Properties": {},
  "_ResourceId": "<APPLICATION_INSIGHTS_RESOURCE_ID>"
}
```

**Exception: `AppExceptions`.** Exact exception types/messages are service-dependent;
they are intentionally placeholders. Backend stack traces are not implied. Documented
[column schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/appexceptions).

```json
{
  "TimeGenerated": "2026-09-21T12:01:00Z",
  "OperationId": "<FAILED_TRACE_ID>",
  "ParentId": "<FAILED_REQUEST_SPAN_ID>",
  "ExceptionType": "<EMITTED_EXCEPTION_TYPE>",
  "OuterMessage": "<SANITIZED_ERROR_SUMMARY>",
  "SeverityLevel": 3,
  "Properties": {},
  "_ResourceId": "<APPLICATION_INSIGHTS_RESOURCE_ID>"
}
```

**Authentication, authorization, throttling and content-filter outcomes** reuse these
schemas; they are not four additional log tables. Example `AppRequests` projections:

```json
[
  {"Id":"<SUCCESSFUL_REQUEST_SPAN_ID>","OperationId":"<SUCCESSFUL_TRACE_ID>","ResultCode":"200","Success":true,"Properties":{}},
  {"Id":"<REJECTED_REQUEST_SPAN_ID>","OperationId":"<REJECTED_TRACE_ID>","ResultCode":"401","Success":false,"Properties":{}},
  {"Id":"<FORBIDDEN_REQUEST_SPAN_ID>","OperationId":"<FORBIDDEN_TRACE_ID>","ResultCode":"403","Success":false,"Properties":{}},
  {"Id":"<THROTTLED_REQUEST_SPAN_ID>","OperationId":"<THROTTLED_TRACE_ID>","ResultCode":"429","Success":false,"Properties":{}},
  {"Id":"<FILTERED_REQUEST_SPAN_ID>","OperationId":"<FILTERED_TRACE_ID>","ResultCode":"400","Success":false,"Properties":{}}
]
```

The first row illustrates a successful 2xx request outcome, not a dedicated
authentication-success event or proof of which identity was validated.

The last row is an illustrative blocked-prompt outcome, **not** evidence that every
400 is a content-filter block. A filtered completion or annotate-only detection can
also occur with HTTP 200. Use explicit supported error/safety evidence to classify
it. A pre-authentication rejection has no trusted developer identity; a gateway
rejection may have no backend dependency row at all.

### 7.2 Custom traces and proposed identity enrichment

`AppTraces` has documented top-level columns, but the metadata keys below are our
**proposed contract**, not built-in APIM fields and not currently emitted. Documented
[column schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/apptraces).

```json
{
  "TimeGenerated": "2026-09-21T12:00:00.010Z",
  "Message": "byok.identity",
  "SeverityLevel": 1,
  "OperationId": "<TRACE_ID>",
  "ParentId": "<APIM_REQUEST_SPAN_ID>",
  "Properties": {
    "schema_version": "1",
    "auth_method": "entra_jwt",
    "principal_key": "entra:<TENANT_ID>:<OBJECT_ID>",
    "tenant_id": "<TENANT_ID>",
    "subject_id": "<OBJECT_ID>",
    "gateway_request_id": "<GATEWAY_REQUEST_ID>"
  },
  "_ResourceId": "<APPLICATION_INSIGHTS_RESOURCE_ID>"
}
```

For key mode, use `auth_method: subscription_key`, a gateway-qualified subscription
`principal_key`, and `apim_subscription_id`; omit token-subject fields. The example
intentionally excludes display labels and business ownership attributes. See the
[optional display label](#optional-display-label) and
[unimplemented customer-specific enrichment](#customer-specific-enrichment-not-implemented)
requirements before adding any. `Properties` is a storage container, not a source
of verified identity or ownership. A trace for routing or backend results would use
the same envelope with different metadata. Severity 1 is Information and 3 is Error
in Application Insights; neither implies a specific HTTP status.

### 7.3 Custom usage and governance metrics

All section 3 metrics use the `AppMetrics` format. This is an example aggregate for
three unit-valued Foundry request-counter emissions with the same dimensions.
Documented [column schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/appmetrics).

```json
{
  "TimeGenerated": "2026-09-21T12:00:00Z",
  "Name": "copilot_byok_request",
  "Sum": 3.0,
  "Min": 1.0,
  "Max": 1.0,
  "ItemCount": 3,
  "Properties": {
    "developer_oid": "<OBJECT_ID_OR_APIM_SUBSCRIPTION_ID>",
    "developer_upn": "<DEVELOPER_LABEL_OR_SUBSCRIPTION_NAME>",
    "deployment_name": "<MODEL_DEPLOYMENT>",
    "backend": "foundry",
    "auto_route": "none"
  },
  "_ResourceId": "<APPLICATION_INSIGHTS_RESOURCE_ID>"
}
```

The same envelope applies to each item below. These property lists describe the
custom dimensions; platform-added dimensions are omitted. AOAI/Anthropic variants
have the differences noted in section 3.

| `Name` / family | Illustrative measurement | Custom `Properties` |
|---|---|---|
| `copilot_byok_request` | `Sum: 3`, `ItemCount: 3` | `developer_oid`, `developer_upn`, `deployment_name`, `backend`, `auto_route` for Foundry. |
| Native `Prompt Tokens`, `Completion Tokens`, `Total Tokens` from `llm-emit-token-metric` | A single prompt-usage observation: `Sum: 120`, `Min: 120`, `Max: 120`, `ItemCount: 1` | `developer_oid`, `developer_upn`, `deployment_name`, `backend` where configured. Cached/reasoning/audio token breakdowns, when emitted, use the same row shape with their own names. |
| `copilot_byok_auto_route` | One decision: `Sum: 1`, `ItemCount: 1` | `developer_upn`, `deployment_name`, `auto_route`, `auto_route_reason`, `auto_length_band`; e.g. `mini`, `short`, `short` for the last three values. |
| `copilot_byok_classifier_tokens` | One usage observation: `Sum: 20`, `ItemCount: 1` | `developer_oid`, `developer_upn`, `deployment_name` for the classifier, `backend`. |
| `copilot_byok_prompt_tokens` | One JSON-response input observation: `Sum: 120`, `ItemCount: 1` | `developer_oid`, `developer_upn`, `deployment_name`, `backend` in the Anthropic compatibility path. |
| `copilot_byok_completion_tokens` | One JSON-response output observation: `Sum: 35`, `ItemCount: 1` | Same Anthropic compatibility dimensions as the prompt counter. |
| `copilot_byok_throttled` | One observed throttle: `Sum: 1`, `ItemCount: 1` | `developer_oid`, `developer_upn`, `deployment_name`, `backend`, `throttle`; e.g. `burst`. |

`ItemCount` counts the aggregated **measurements**, not tokens. Do not assume each
metric row represents one request or retains a usable `OperationId`. For workspace
queries use `Sum`/`ItemCount`/`Properties`; Application Insights' alternative query
schema uses `value`/`valueCount`/`customDimensions`. The policy namespace is
`copilot.byok`; no top-level `Namespace` column is assumed in these examples.

### 7.4 Gateway resource logs and optional payload capture

**`ApiManagementGatewayLogs`**, produced by the configured `GatewayLogs` category.
Documented [column schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/apimanagementgatewaylogs).
This row illustrates subscription-key mode; a JWT-only request need not have an
APIM subscription. `OperationId` here names the **API operation**, not the W3C trace.

```json
{
  "TimeGenerated": "2026-09-21T12:00:00Z",
  "Category": "GatewayLogs",
  "CorrelationId": "<GATEWAY_CORRELATION_ID>",
  "ApiId": "<API_ID>",
  "OperationId": "<API_OPERATION_ID>",
  "ApimSubscriptionId": "<APIM_SUBSCRIPTION_ID>",
  "Method": "POST",
  "Url": "https://<APIM_HOST>/openai/v1/chat/completions",
  "ResponseCode": 200,
  "BackendResponseCode": 200,
  "IsRequestSuccess": true,
  "TotalTime": 1251,
  "BackendTime": 1180,
  "_ResourceId": "<APIM_RESOURCE_ID>"
}
```

Gateway failures can additionally populate `LastErrorSource`, `LastErrorReason`,
`LastErrorSection`, `LastErrorMessage` and `Errors`; values depend on the failing
policy/path. Native key/product rejections do not imply an authenticated Entra user.

**Headers and bodies: configurable, not an APIM limitation.** The repository's default
Application Insights diagnostic has empty header lists and zero body limits. APIM
supports selecting headers independently of body capture, including at API level.
The following is only a projection of documented gateway-resource-log columns when
the corresponding capture is separately configured. Header objects are `dynamic`;
their internal representation depends on the emitter. The empty objects below omit
header values. Body strings are redaction markers, not logged customer content or
automatic redaction.

```json
{
  "RequestHeaders": {},
  "RequestBody": "<REDACTED_REQUEST_CONTENT>",
  "ResponseHeaders": {},
  "ResponseBody": "<REDACTED_RESPONSE_CONTENT>",
  "BackendRequestHeaders": {},
  "BackendRequestBody": "<REDACTED_BACKEND_REQUEST_CONTENT>",
  "BackendResponseHeaders": {},
  "BackendResponseBody": "<REDACTED_BACKEND_RESPONSE_CONTENT>"
}
```

These are **gateway-resource-log columns**, not extra top-level `AppRequests`
columns. Application Insights diagnostic header/body capture, if enabled, is
represented in telemetry properties; inspect its emitted property names instead
of assuming the gateway table's names transfer. No content capture is needed for
the proposed identity trace.

### 7.5 Availability, custom events and client experience

These examples require separate tests or instrumentation; they are **not automatically
emitted by the gateway**.

**Availability test: `AppAvailabilityResults`.** Documented
[column schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/appavailabilityresults).

```json
{
  "TimeGenerated": "2026-09-21T12:00:00Z",
  "Id": "<TEST_EXECUTION_ID>",
  "Name": "<AVAILABILITY_TEST_NAME>",
  "Location": "<APPROVED_PROBE_LOCATION>",
  "DurationMs": 250.0,
  "Success": true,
  "Message": "Expected response received",
  "Properties": {},
  "_ResourceId": "<APPLICATION_INSIGHTS_RESOURCE_ID>"
}
```

**Application-defined event: `AppEvents`.** Event names and custom fields are chosen
by the application, not reserved APIM events. Documented
[column schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/appevents).

```json
{
  "TimeGenerated": "2026-09-21T12:00:00Z",
  "Name": "<APPLICATION_EVENT_NAME>",
  "OperationId": "<APP_TRACE_ID>",
  "ParentId": "<APP_SPAN_ID>",
  "Properties": {"<CUSTOM_PROPERTY_NAME>": "<SANITIZED_VALUE>"},
  "Measurements": {"<CUSTOM_MEASUREMENT_NAME>": 1.0},
  "_ResourceId": "<APPLICATION_INSIGHTS_RESOURCE_ID>"
}
```

**Page/client experience: `AppPageViews`.** Documented
[column schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/apppageviews).
This applies to an instrumented page, not automatic visibility into Copilot UI actions.

```json
{
  "TimeGenerated": "2026-09-21T12:00:00Z",
  "Id": "<PAGE_VIEW_ID>",
  "Name": "<PAGE_NAME>",
  "Url": "https://<APPLICATION_HOST>/<PAGE_PATH>",
  "DurationMs": 400.0,
  "SessionId": "<APPLICATION_SESSION_ID>",
  "Properties": {},
  "_ResourceId": "<APPLICATION_INSIGHTS_RESOURCE_ID>"
}
```

### 7.6 Platform metrics exported to logs

**`AzureMetrics`** is the exported format for supported APIM and Foundry platform
metrics, distinct from `AppMetrics`. Documented
[column schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/azuremetrics).
The following Foundry request-count row is illustrative **after a diagnostic export
is enabled**; the repo does not currently configure that export.

```json
{
  "TimeGenerated": "2026-09-21T12:00:00Z",
  "MetricName": "AzureOpenAIRequests",
  "TimeGrain": "PT1M",
  "UnitName": "Count",
  "Total": 8.0,
  "_ResourceId": "<FOUNDRY_RESOURCE_ID>"
}
```

The same row shape applies to exported APIM metrics, with the appropriate APIM
`MetricName` and resource ID. `Total` is the summed metric value; `Count`, if present,
is the number of metric samples, not necessarily the number of requests. Latency
and utilization use their supported `Average`, `Minimum` and `Maximum` aggregations.
Do not add invented `Properties` or per-developer fields to this table.

| Section 6 metric category | Example metric names | Representative value fields / units |
|---|---|---|
| Traffic, errors and throttling | `AzureOpenAIRequests`, `ModelRequests` | `Total: 8`, `UnitName: Count`; status/deployment splits belong to the source metric's supported dimensions. |
| Token usage and caching | `ProcessedPromptTokens`, `GeneratedTokens`, `TokenTransaction`, `InputTokens`, `OutputTokens`, `TotalTokens` | `Total: 120`, `UnitName: Count`; cache percentages use percent/average, not a token sum. |
| Latency and generation speed | `AzureOpenAITimeToResponse`, `AzureOpenAITTLTInMS`, `AzureOpenAINormalizedTBTInMS`, `AzureOpenAINormalizedTTFTInMS` | `Average: 125.5`, `UnitName: MilliSeconds` when exportable; generation-speed metrics use their own declared unit. |
| Provisioned capacity | `AzureOpenAIProvisionedManagedUtilizationV2`, `ProvisionedUtilization` | Source metric `average: 65.0`, unit `Percent`; **not** an `AzureMetrics` export example because diagnostic export is unsupported in the cited reference. |
| Content safety | `RAITotalRequests`, `RAIHarmfulRequests`, `RAIRejectedRequests`, `RAISystemEvent` | Volumes use `Total`/`Count` units; system-event metrics use their documented aggregation. No automatic developer dimension. |
| Managed model routing | `ModelRouterRequests`, `ModelRouterFallbackCount`, `ModelRouterLatency` | Count metrics use `Total`; routing latency uses `Average`/`MilliSeconds`. |
| Fine-tuning and modality usage | `FineTunedTrainingHours`, supported audio/image/real-time metrics | Use each definition's unit and aggregation; do not infer units from a display name or treat every value as tokens. |

All numbers in this table are illustrative, not measured results. Native metric
query responses use a different JSON envelope from a Log Analytics row, and can
preserve dimensions that diagnostic exports do not.

### 7.7 Management activity and identity-provider records

**Management-plane change: `AzureActivity` after export.** Documented
[column schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/azureactivity).
The caller is the principal performing the management operation, not necessarily
an inference developer. Foundry deployment changes use the same table with their
own operation name/resource ID.

```json
{
  "TimeGenerated": "2026-09-21T11:30:00Z",
  "CategoryValue": "Administrative",
  "OperationNameValue": "Microsoft.ApiManagement/service/apis/policies/write",
  "ActivityStatusValue": "Succeeded",
  "Caller": "<MANAGEMENT_PRINCIPAL_ID>",
  "CorrelationId": "<MANAGEMENT_OPERATION_CORRELATION_ID>",
  "Properties_d": {},
  "_ResourceId": "<APIM_POLICY_RESOURCE_ID>"
}
```

**Entra user sign-in: `SigninLogs` after separate tenant export.** Documented
[column schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/signinlogs).
`ResultType` is a string, with `"0"` indicating success. Its correlation ID belongs
to the sign-in flow, not automatically to an APIM inference trace.

```json
{
  "TimeGenerated": "2026-09-21T11:45:00Z",
  "Id": "<SIGNIN_EVENT_ID>",
  "AADTenantId": "<TENANT_ID>",
  "UserId": "<OBJECT_ID>",
  "AppId": "<CLIENT_ID>",
  "ResultType": "0",
  "IsInteractive": true,
  "CorrelationId": "<SIGNIN_CORRELATION_ID>"
}
```

**Entra directory audit: `AuditLogs` after separate tenant export.** Documented
[column schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/auditlogs).
Actor and target data are `dynamic`; the example omits their sensitive details.

```json
{
  "TimeGenerated": "2026-09-21T11:40:00Z",
  "Id": "<DIRECTORY_AUDIT_EVENT_ID>",
  "AADTenantId": "<TENANT_ID>",
  "OperationName": "<DIRECTORY_OPERATION_NAME>",
  "Result": "success",
  "InitiatedBy": {},
  "TargetResources": [],
  "CorrelationId": "<DIRECTORY_OPERATION_CORRELATION_ID>"
}
```

Managed-identity, service-principal and non-interactive sign-ins can use distinct
Entra log tables/categories. Other identity providers use their own schemas; the
examples above are not an Okta or universal identity-log contract. These records
do not establish a one-to-one sign-in-to-inference mapping.

### 7.8 Optional APIM LLM, MCP, WebSocket and portal logs

None of these four categories is enabled by the shared template. These are partial
examples of the [documented resource-specific tables](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/supported-logs/microsoft-apimanagement-service-logs),
subject to cloud/tier and feature support.

**`GatewayLlmLogs` -> `ApiManagementGatewayLlmLog`.** Documented
[column schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/apimanagementgatewayllmlog).
Notice the singular `Log` in the table name. Usage fields are integers. One request
can have multiple entries identified by `SequenceNumber`; do not blindly sum repeated
usage across message records. Validate when the gateway emits usage for your protocol.

```json
{
  "TimeGenerated": "2026-09-21T12:00:00Z",
  "CorrelationId": "<GATEWAY_CORRELATION_ID>",
  "RequestId": "<MODEL_SERVICE_REQUEST_ID>",
  "DeploymentName": "<MODEL_DEPLOYMENT>",
  "ModelName": "<MODEL_NAME>",
  "PromptTokens": 120,
  "CompletionTokens": 35,
  "TotalTokens": 155,
  "SequenceNumber": 0,
  "_ResourceId": "<APIM_RESOURCE_ID>"
}
```

`RequestMessages` and `ResponseMessages` are optional `dynamic` content fields in
this schema and are deliberately omitted from the example. Review content logging
before enabling the category; do not assume the existing zero-byte diagnostic
settings govern every LLM-specific content option.

**`GatewayMCPLogs` -> `ApiManagementGatewayMCPLog`.** Documented
[column schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/apimanagementgatewaymcplog).
This applies only to MCP traffic actually handled by the gateway.

```json
{
  "TimeGenerated": "2026-09-21T12:02:00Z",
  "CorrelationId": "<MCP_GATEWAY_CORRELATION_ID>",
  "Method": "tools/call",
  "ToolName": "<TOOL_NAME>",
  "ServerName": "<MCP_SERVER_NAME>",
  "SessionId": "<MCP_SESSION_ID>",
  "McpServerEndpoint": "https://<MCP_HOST>/<MCP_PATH>",
  "_ResourceId": "<APIM_RESOURCE_ID>"
}
```

For LLM and MCP logs, Microsoft documents `CorrelationId` as corresponding to
`ApiManagementGatewayLogs.CorrelationId`. Scope the join to the APIM resource and
validate cardinality. This still does not make it an Application Insights trace ID.

**`WebSocketConnectionLogs` -> `ApiManagementWebSocketConnectionLogs`.** Documented
[column schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/apimanagementwebsocketconnectionlogs).
The event name and source/destination labels below must be taken from emitted records.
SSE streaming is not a WebSocket connection.

```json
{
  "TimeGenerated": "2026-09-21T12:03:00Z",
  "CorrelationId": "<WEBSOCKET_CORRELATION_ID>",
  "EventName": "<EMITTED_CONNECTION_EVENT>",
  "Source": "<EMITTED_SOURCE>",
  "Destination": "<EMITTED_DESTINATION>",
  "_ResourceId": "<APIM_RESOURCE_ID>"
}
```

**`DeveloperPortalAuditLogs` -> `APIMDevPortalAuditDiagnosticLog`.** Documented
[column schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/apimdevportalauditdiagnosticlog).
This is the APIM developer portal, not the repo's separate Register application.

```json
{
  "TimeGenerated": "2026-09-21T12:04:00Z",
  "Category": "DeveloperPortalAuditLogs",
  "ActivityId": "<PORTAL_ACTIVITY_ID>",
  "OperationName": "<PORTAL_OPERATION>",
  "RequestMethod": "GET",
  "RequestPath": "/<PORTAL_PATH>",
  "ResponseCode": 200,
  "ResultType": "Succeeded",
  "HashedUserId": "<PORTAL_USER_HASH>",
  "_ResourceId": "<APIM_RESOURCE_ID>"
}
```

The portal's `HashedUserId` is not an Entra object ID or a subscription owner lookup.
These optional formats do not change the identity trust rules in section 4.

### 7.9 Foundry account resource logs

**`AzureDiagnostics`: shared envelope, service-specific details.** The
[table reference](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/azurediagnostics)
and [Foundry monitoring examples](https://learn.microsoft.com/en-us/azure/foundry-classic/openai/how-to/monitor-openai#kusto-queries)
document the common fields, but do not establish a complete, versioned JSON payload
contract for every category/model/API. The entries below intentionally omit the
unverified inner fields. They illustrate each category's row envelope, not five
captured records. Diagnostic export must first be configured on the Foundry account.

```json
[
  {
    "TimeGenerated": "2026-09-21T12:00:00Z",
    "_ResourceId": "<FOUNDRY_RESOURCE_ID>",
    "Category": "Audit",
    "OperationName": "<SERVICE_AUDIT_OPERATION>",
    "properties_s": "{}"
  },
  {
    "TimeGenerated": "2026-09-21T12:00:00Z",
    "_ResourceId": "<FOUNDRY_RESOURCE_ID>",
    "Category": "RequestResponse",
    "OperationName": "<MODEL_API_OPERATION>",
    "DurationMs": 1180,
    "ResultSignature": "<EMITTED_RESULT_SIGNATURE>",
    "properties_s": "{}"
  },
  {
    "TimeGenerated": "2026-09-21T12:00:00Z",
    "_ResourceId": "<FOUNDRY_RESOURCE_ID>",
    "Category": "Trace",
    "OperationName": "<SUPPORTED_SERVICE_TRACE_OPERATION>",
    "properties_s": "{}"
  },
  {
    "TimeGenerated": "2026-09-21T12:00:00Z",
    "_ResourceId": "<FOUNDRY_RESOURCE_ID>",
    "Category": "AzureOpenAIRequestUsage",
    "OperationName": "<USAGE_OPERATION>",
    "properties_s": "{}"
  },
  {
    "TimeGenerated": "2026-09-21T12:00:00Z",
    "_ResourceId": "<FOUNDRY_RESOURCE_ID>",
    "Category": "ManagedNetworkEvent",
    "OperationName": "<MANAGED_NETWORK_OPERATION>",
    "properties_s": "{}"
  }
]
```

The empty `properties_s` strings above mean **details omitted**, not "no usage or
content was recorded." When populated with JSON, its object is string-escaped in a
JSON row export. This schematic demonstrates the encoding only; the angle-bracket
property name is not a real Azure field:

```json
{
  "properties_s": "{\"<SERVICE_SPECIFIC_FIELD>\":\"<SANITIZED_VALUE>\"}"
}
```

| Category | Details to confirm from an approved sample before promising a field |
|---|---|
| `Audit` | Which operations generate events, the actor's identity namespace, action/result fields, and whether the actor is APIM's backend principal. |
| `RequestResponse` | Result/status encoding, service request/correlation ID, deployment/API fields, duration meaning and content inclusion. |
| `Trace` | Whether the specific service supports it at all, and that service's message/trace schema. Not a model-reasoning feed. |
| `AzureOpenAIRequestUsage` | Exact input/output/cached/reasoning usage fields, request identifiers, streaming behavior and any input/output content settings. Do not borrow `PromptTokens` column names from APIM's LLM table. |
| `ManagedNetworkEvent` | Event kind, network rule/connection fields and actual coverage for the configured managed-network feature. |

`AzureDiagnostics` can add service-specific suffixed columns and put overflow fields
in `AdditionalFields`; a single universal `properties_s` parser is not guaranteed.
**Remaining evidence requirement:** actual inner payloads and optional field presence
for these five categories must be confirmed in the target cloud/resource. Do not use
these deliberately partial examples as a production parser schema or proof that all
five categories emit for an OpenAI deployment.

### 7.10 Native Azure Monitor metric response

This is a **partial Metrics REST API response**, not a log row. It illustrates the
[documented response format](https://learn.microsoft.com/en-us/rest/api/monitor/metrics/list?view=rest-monitor-2023-10-01)
for a provisioned-capacity metric queried at the Foundry account. This format is also
used for other APIM/Foundry metric families, including metrics without log export.

```json
{
  "timespan": "2026-09-21T12:00:00Z/2026-09-21T12:01:00Z",
  "interval": "PT1M",
  "namespace": "microsoft.cognitiveservices/accounts",
  "value": [
    {
      "name": {
        "value": "AzureOpenAIProvisionedManagedUtilizationV2",
        "localizedValue": "Provisioned-managed Utilization V2"
      },
      "unit": "Percent",
      "timeseries": [
        {
          "metadatavalues": [
            {
              "name": {"value": "ModelDeploymentName"},
              "value": "<MODEL_DEPLOYMENT>"
            }
          ],
          "data": [
            {"timeStamp": "2026-09-21T12:00:00Z", "average": 65.0}
          ]
        }
      ]
    }
  ]
}
```

Notice `timeStamp`, `average` and `metadatavalues` versus the Log Analytics columns
`TimeGenerated`, `Average` and the separate metric table schema. Requested dimensions
are returned per series where supported; no developer identity is inferred from a
deployment-level time series. An absent/null datapoint is not the same as zero.

### 7.11 Application, agent, evaluation and message formats

**Application/model span: partial OpenTelemetry console format.** This follows the
shape in Microsoft's [OpenAI SDK tracing example](https://learn.microsoft.com/en-us/azure/foundry-classic/how-to/develop/trace-application#trace-to-console),
not a Log Analytics row or OTLP wire payload. Attribute conventions and exporter
mapping depend on the SDK version. None of this instrumentation is enabled here.

```json
{
  "name": "chat <MODEL_DEPLOYMENT>",
  "context": {"trace_id": "<APP_TRACE_ID>", "span_id": "<MODEL_SPAN_ID>"},
  "parent_id": "<APP_PARENT_SPAN_ID>",
  "kind": "SpanKind.CLIENT",
  "start_time": "2026-09-21T12:00:00Z",
  "end_time": "2026-09-21T12:00:01.250Z",
  "status": {"status_code": "UNSET"},
  "attributes": {
    "gen_ai.operation.name": "chat",
    "gen_ai.request.model": "<MODEL_DEPLOYMENT>",
    "gen_ai.response.model": "<RETURNED_MODEL>",
    "gen_ai.response.id": "<MODEL_RESPONSE_OBJECT_ID>",
    "gen_ai.usage.input_tokens": 120,
    "gen_ai.usage.output_tokens": 35
  },
  "events": []
}
```

`UNSET` is an OpenTelemetry status, not an HTTP result code. The response object's
ID is not automatically the service's HTTP request ID. Under Azure Monitor export,
the span can map to a request/dependency row with attributes in `Properties`;
inspect the exporter's actual mapping and serialization before writing joins.

**Agent and tool spans: illustrative console projections.** Microsoft's
[agent tracing guide](https://learn.microsoft.com/en-us/azure/foundry-classic/how-to/develop/trace-agents-sdk)
describes agent/tool spans and parent-child relationships. Exact attributes, kinds
and names vary with instrumentation. This shows an agent span with a child tool
span and deliberately omits arguments, results and message content.

```json
[
  {
    "name": "invoke_agent <AGENT_NAME>",
    "context": {"trace_id": "<APP_TRACE_ID>", "span_id": "<AGENT_SPAN_ID>"},
    "parent_id": "<APP_PARENT_SPAN_ID>",
    "start_time": "2026-09-21T12:00:00Z",
    "end_time": "2026-09-21T12:00:02Z",
    "attributes": {"gen_ai.operation.name": "invoke_agent"}
  },
  {
    "name": "execute_tool <TOOL_NAME>",
    "context": {"trace_id": "<APP_TRACE_ID>", "span_id": "<TOOL_SPAN_ID>"},
    "parent_id": "<AGENT_SPAN_ID>",
    "start_time": "2026-09-21T12:00:00.200Z",
    "end_time": "2026-09-21T12:00:00.400Z",
    "attributes": {"gen_ai.operation.name": "execute_tool"}
  }
]
```

**Evaluation/quality: proposed application-owned normalization, not a native Foundry
result schema.** There is no single evaluator/exporter selected by this repo. The
following `AppEvents` example illustrates how a customer could explicitly record a
normalized result; its event name and custom keys are **not built-in Foundry fields**.
The score/scale is hypothetical, not a quality assessment of this solution.

```json
{
  "TimeGenerated": "2026-09-21T12:05:00Z",
  "Name": "byok.evaluation",
  "OperationId": "<APP_TRACE_ID>",
  "ParentId": "<MODEL_SPAN_ID>",
  "Properties": {
    "schema_version": "1",
    "evaluation_run_id": "<EVALUATION_RUN_ID>",
    "evaluated_response_id": "<MODEL_RESPONSE_OBJECT_ID>",
    "evaluator": "<EVALUATOR_NAME>",
    "evaluator_version": "<EVALUATOR_VERSION>",
    "result": "pass"
  },
  "Measurements": {"score": 4.0, "score_min": 1.0, "score_max": 5.0},
  "_ResourceId": "<APPLICATION_INSIGHTS_RESOURCE_ID>"
}
```

Use a verified evaluated-response/span mapping, including for asynchronous evaluation;
do not attach a score to an arbitrary inference with a similar timestamp. To specify
a native evaluation record, first select the evaluation workflow and inspect its
actual event/API/artifact schema. Quality scores are not service safety counters.

**Message content: SDK-specific, sensitive opt-in.** There is no universal Foundry
message-log row. Depending on instrumentation, content can be attached to span
attributes, events or exported log bodies. This is a **schematic event projection**
only; its placeholder keys are not a promised SDK schema:

```json
{
  "name": "<SDK_MESSAGE_EVENT_NAME>",
  "timestamp": "2026-09-21T12:00:00Z",
  "attributes": {
    "<SDK_MESSAGE_CONTENT_ATTRIBUTE>": "<REDACTED_MESSAGE_CONTENT>"
  }
}
```

The documented instrumentation uses different opt-in settings, including
`OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT` for the OpenAI example and
`AZURE_TRACING_GEN_AI_CONTENT_RECORDING_ENABLED` for the Azure agent example. Keep
content capture disabled for identity-only reporting. A redaction marker in this
document is not evidence of automatic SDK redaction. Confirm the selected SDK's
schema and content controls before enabling or parsing these records.

### 7.12 Proposed backend-correlation record

**Proposed `AppTraces` record, not currently emitted.** This complements the identity
trace in 7.2 after a backend attempt has a verified service request ID. It shows how
the correlation could work without forwarding the developer's identity to the model.

```json
{
  "TimeGenerated": "2026-09-21T12:00:01.230Z",
  "Message": "byok.backend_result",
  "SeverityLevel": 1,
  "OperationId": "<TRACE_ID>",
  "ParentId": "<APIM_REQUEST_SPAN_ID>",
  "Properties": {
    "schema_version": "1",
    "gateway_request_id": "<GATEWAY_REQUEST_ID>",
    "backend_request_id": "<VERIFIED_MODEL_SERVICE_REQUEST_ID>",
    "backend_resource_id": "<FOUNDRY_RESOURCE_ID>",
    "backend_attempt": "1",
    "deployment_name": "<MODEL_DEPLOYMENT>",
    "backend": "foundry"
  },
  "_ResourceId": "<APPLICATION_INSIGHTS_RESOURCE_ID>"
}
```

Join this record to the identity/request span using the validated trace/span
relationship, then to the Foundry log using the verified service request ID and
backend resource scope. Per-attempt emission requires explicit instrumentation;
reading only the final response does not recover IDs for earlier retries. Do not
mistake receipt of response headers for successful completion of a streamed response.

## 8. Authentication logging: Entra ID and Okta

### Public documentation baseline, not an implementation claim

**Status: preflight/design only.** The current Entra/Okta authentication work has not
updated our production policies. This section starts from public Microsoft and Okta
documentation; it does not claim that the proposed fields, events, same-endpoint
admission or direct Okta validation are implemented, deployed or tested here. See
the [authentication design](authentication.md) for the evolving preflight evidence
and acceptance gates. Existing single-mode behavior is unchanged.

**This is possible:** APIM can record JWT validation outcomes and, after validation,
correlate an authenticated principal with request and backend telemetry. Some data
is available from native diagnostic records; a normalized developer-level event
requires explicit policy instrumentation. Neither collecting logs nor successfully
validating one JWT proves the planned key OR Entra OR Okta admission contract.

| Information | Publicly documented source | What still needs implementation or verification |
|---|---|---|
| Request HTTP outcome | `AppRequests`, `ApiManagementGatewayLogs`, exceptions where emitted | A 401 alone does not establish the cause or the purported user's identity. |
| JWT failure classification | `context.LastError.Source`, `Reason`, `Section`, optional `PolicyId`; gateway error fields where emitted | Confirm error-path coverage and map only known reasons into sanitized custom events. |
| Validated caller identity | `validate-jwt` output-token variable, populated on successful validation | Select approved claims, require stable user identity and enforce the delegated authorization contract before logging it as trusted. |
| Normalized authentication decision | Proposed `AppTraces` event using trace metadata | **Not built in or emitted today**; examples below are the proposed schema. |
| Entra sign-in/MFA/directory activity | Separately exported Entra sign-in and audit logs; formats in 7.7 | Tenant permissions, export configuration and interpretation of the applicable sign-in type. |
| Okta sign-in/policy/token activity | Okta System Log | Separate customer-side collection; no automatic Application Insights table or shared APIM trace ID. |
| Acquisition/renewal and reauthentication | Client/helper instrumentation and supported IdP events | APIM cannot observe a failed refresh when no request reaches the gateway. |

### Identity mapping after validation

Use separate trust configurations for each exact issuer, audience and required scope.
The following mappings are a proposed normalized logging contract, not a request to
dump token claims. Only use claims from a **successfully validated access token**.
Sources: [Entra access-token claims](https://learn.microsoft.com/en-us/entra/identity-platform/access-token-claims-reference)
and [Okta access-token claims](https://developer.okta.com/docs/api/openapi/okta-oauth/guides/overview/#access-token-scopes-and-claims).

| Field | Entra delegated access token | Direct Okta delegated access token (planned) |
|---|---|---|
| `auth_method` | `entra_jwt` | `okta_jwt` |
| `issuer` | Validated `iss` from the approved cloud/tenant | Validated exact custom authorization-server `iss`, including its server path |
| `tenant_id` | Validated `tid` | Omit; an Okta authorization server is not an Entra tenant |
| `subject_id` | Immutable `oid` within the tenant | Stable `sub` under the customer's agreed claim configuration |
| `principal_key` | `entra:<TENANT_ID>:<OBJECT_ID>`, scoped by the trusted issuer | `okta:<ISSUER_ID>:<STABLE_SUBJECT>`; issuer ID is a controlled one-to-one alias for the exact issuer |
| `client_app_id` | `azp` in v2 tokens; `appid` only if v1 is explicitly supported | `cid` |
| `audience` | Matched gateway API audience; not the calling client or Foundry audience | Matched custom API audience |
| `required_scope` | Configured permission such as `cli.invoke`; test membership in space-delimited `scp` | Configured API permission; Okta commonly supplies an `scp` array |

For Okta, confirm that the configured `sub` is stable, not a mutable email/login
expression. If the customer needs immutable `uid` or another claim instead, explicitly
revise and test the shared identity/quota contract; do not silently change join keys.
Require user-bound delegated access, not just a subject that could identify a
client-credentials application. Okta **org authorization-server access tokens** are
for Okta APIs; the planned gateway uses a **custom authorization server**. ID tokens
are not API access tokens for either provider.

If Okta authenticates a user through federation but **Entra issues the access token**,
the gateway records `entra_jwt`. The upstream sign-in path belongs in IdP evidence;
it cannot be inferred from an Entra token's acceptance alone. Entra, direct Okta and
subscription-key principals remain distinct unless a governed mapping links them.
Do not merge by email or assume an Okta subject is an Entra object ID.

### Proposed gateway event

Use one structured admission decision, for example `Message: byok.auth`, in
`AppTraces`. It can extend/replace the proposed `byok.identity` anchor from section
7.2 rather than creating two successful-authentication counts. The envelope follows
the documented `AppTraces` schema; **all metadata keys below are our proposed
contract**, not native APIM columns.

| Metadata | Contract |
|---|---|
| `schema_version`, `event_category` | Version `1`, fixed category `authentication`. |
| `auth_outcome` | `allowed`, `denied` or `error` at admission, not the eventual inference result. |
| `auth_stage` | `credential_extraction`, `token_validation`, `identity_resolution` or `authorization`. |
| `identity_status` | `validated` only after the complete identity contract succeeds; otherwise `unattributed`. |
| `auth_method` | Validated method on success; generic `jwt` or `unknown` when the provider/identity is not established. |
| `validator_id` | Gateway-configured validator branch; on failure this is **not proof of the token issuer**. |
| `credential_source` | Effective source label such as `api-key`, `x-api-key` or `authorization`, never its value. |
| Trusted identity fields above | Omit when validation fails. A separately denied authorization can retain identity only if full identity validation already succeeded. |
| `failure_reason`, `apim_error_source`, `apim_error_reason` | Allowlisted classifications, not raw exception text or a complete `LastError.Message`. |
| `failure_response_code` | Optional actual authentication-failure status as a string; final request status stays in `AppRequests.ResultCode`. |
| `gateway_request_id` | Gateway-generated identifier; use top-level `OperationId`/`ParentId` for the validated trace/span relationship. |

An unverified issuer can at most select a **statically allowlisted** validator; it
must never supply a discovery URL or be reported as an authenticated issuer. The
issuer, client and user fields in success records below must not be populated from
failed-validation tokens. Log a missing stable identity as a rejection, not an
authenticated shared `unknown` principal.

### Example: Entra allowed

**Synthetic proposed record, not emitted by the current policies.** This assumes
signature, lifetime, exact issuer/audience, stable identity, required scope and
applicable user/client restrictions have passed. `api-key` is a transport label,
not an assertion that the JWT was an APIM subscription key.

```json
{
  "TimeGenerated": "2026-09-21T12:00:00.010Z",
  "Message": "byok.auth",
  "SeverityLevel": 1,
  "OperationId": "<TRACE_ID>",
  "ParentId": "<APIM_REQUEST_SPAN_ID>",
  "Properties": {
    "schema_version": "1",
    "event_category": "authentication",
    "auth_outcome": "allowed",
    "auth_stage": "authorization",
    "identity_status": "validated",
    "auth_method": "entra_jwt",
    "validator_id": "<ENTRA_VALIDATOR_ID>",
    "credential_source": "api-key",
    "issuer": "<VALIDATED_ENTRA_ISSUER>",
    "tenant_id": "<TENANT_ID>",
    "subject_id": "<OBJECT_ID>",
    "principal_key": "entra:<TENANT_ID>:<OBJECT_ID>",
    "client_app_id": "<CLIENT_ID>",
    "audience": "<GATEWAY_API_AUDIENCE>",
    "required_scope": "cli.invoke",
    "gateway_request_id": "<GATEWAY_REQUEST_ID>"
  },
  "_ResourceId": "<APPLICATION_INSIGHTS_RESOURCE_ID>"
}
```

### Example: direct Okta allowed

**Synthetic target format, not proof of Okta integration.** This assumes the custom
authorization server and stable delegated-user contract pass customer validation.
The absent `tenant_id` is deliberate.

```json
{
  "TimeGenerated": "2026-09-21T12:02:00.010Z",
  "Message": "byok.auth",
  "SeverityLevel": 1,
  "OperationId": "<OKTA_TRACE_ID>",
  "ParentId": "<OKTA_REQUEST_SPAN_ID>",
  "Properties": {
    "schema_version": "1",
    "event_category": "authentication",
    "auth_outcome": "allowed",
    "auth_stage": "authorization",
    "identity_status": "validated",
    "auth_method": "okta_jwt",
    "validator_id": "<OKTA_VALIDATOR_ID>",
    "credential_source": "authorization",
    "issuer": "https://<OKTA_DOMAIN>/oauth2/<AUTHORIZATION_SERVER_ID>",
    "subject_id": "<STABLE_OKTA_SUBJECT>",
    "principal_key": "okta:<ISSUER_ID>:<STABLE_OKTA_SUBJECT>",
    "client_app_id": "<OKTA_CLIENT_ID>",
    "audience": "<GATEWAY_API_AUDIENCE>",
    "required_scope": "<REQUIRED_API_SCOPE>",
    "gateway_request_id": "<OKTA_GATEWAY_REQUEST_ID>"
  },
  "_ResourceId": "<APPLICATION_INSIGHTS_RESOURCE_ID>"
}
```

### Example: rejected JWT, no trusted developer

**Synthetic proposed record** using the documented `TokenExpired` reason. The
configured validator is known, but the rejected token is not used to fill in an
authenticated issuer, subject, client or principal.

```json
{
  "TimeGenerated": "2026-09-21T12:03:00Z",
  "Message": "byok.auth",
  "SeverityLevel": 1,
  "OperationId": "<REJECTED_TRACE_ID>",
  "ParentId": "<REJECTED_REQUEST_SPAN_ID>",
  "Properties": {
    "schema_version": "1",
    "event_category": "authentication",
    "auth_outcome": "denied",
    "auth_stage": "token_validation",
    "identity_status": "unattributed",
    "auth_method": "jwt",
    "validator_id": "<CONFIGURED_VALIDATOR_ID>",
    "credential_source": "api-key",
    "failure_reason": "expired",
    "apim_error_source": "validate-jwt",
    "apim_error_reason": "TokenExpired",
    "failure_response_code": "401",
    "gateway_request_id": "<REJECTED_GATEWAY_REQUEST_ID>"
  },
  "_ResourceId": "<APPLICATION_INSIGHTS_RESOURCE_ID>"
}
```

An allowed auth event may be followed by a quota rejection, backend failure or
cancelled stream. Conversely, a backend 401 is not necessarily a caller-authentication
failure. Join auth decisions to the corresponding request span and then to verified
backend records from 7.12; do not use the auth event as a second inference count.

### Public failure reasons and preflight checks

Microsoft documents these `validate-jwt` reasons. The normalized names in the second
column are only proposed reporting labels:

| Documented evidence | Proposed `failure_reason` | Qualification |
|---|---|---|
| `TokenNotPresent` | `missing_credential` | An earlier explicit guard can also detect absence without reaching the validator. |
| `TokenSignatureInvalid` | `signature_invalid` | No trusted user or issuer. |
| `TokenAudienceNotAllowed`, `TokenIssuerNotAllowed` | `audience_rejected`, `issuer_rejected` | Record the configured validator, not the raw rejected claim. |
| `TokenExpired` | `expired` | Does not prove that a client refresh was attempted or failed. |
| `TokenSignatureKeyNotFound` | `signing_key_unresolved` | Does not alone prove an IdP outage or legitimate key rotation. |
| `TokenClaimNotFound`, `TokenClaimValueNotAllowed` | `required_claim_missing`, `required_claim_rejected` | Name a scope/identity/client failure more specifically only when the known check identifies it. |
| `JwtInvalid` | `jwt_invalid` | Preserve a generic classification rather than guessing from malformed claims. |

Credential-conflict and explicit authorization guards need their own bounded reasons;
confirmed discovery/JWKS failures should be distinguished from invalid credentials.
`validate-jwt` defaults to 401, and current JWT policy files use 401 for validation
failures, including required-scope checks. Do not promise 403 for those checks unless
a separate authorization contract implements it. Log the actual status observed.

The public error-handling documentation permits tracing in `on-error` and exposes
`context.LastError`. An explicit `return-response` rejection needs instrumentation
before returning; native admission or earlier-scope failures may not reach the
custom event. Verify this on every supported operation, including discovery and
Responses subresources that skip inherited inbound policy. Custom traces bypass
Application Insights sampling, but that is not a guarantee of complete ingestion.

The approved identical-Authorization normalization case is one effective request
and one identity, not two auth events or quota charges. The original multiplicity
may no longer be observable after normalization. Conflicting sources must still be
rejected; public logging capabilities do not resolve the remaining admission gates.

### Example: native Okta System Log event

**Documented native shape with synthetic values**, unlike the proposed `byok.auth`
records above. This is one partial event from the array returned by the
[Okta System Log API](https://developer.okta.com/docs/api/openapi/okta-management/management/tag/SystemLog/),
not an `AppTraces` row. The API is read-only and requires separately authorized
collection, such as the documented `okta.logs.read` scope. No collector is configured
by this documentation.

```json
{
  "uuid": "<OKTA_EVENT_ID>",
  "published": "2026-09-21T11:45:00Z",
  "eventType": "user.session.start",
  "severity": "INFO",
  "actor": {
    "id": "<OKTA_USER_ID>",
    "type": "User"
  },
  "outcome": {
    "result": "SUCCESS"
  },
  "authenticationContext": {
    "externalSessionId": "<OKTA_SESSION_ID>"
  },
  "transaction": {
    "id": "<OKTA_TRANSACTION_ID>",
    "type": "WEB"
  }
}
```

| Native field | Interpretation |
|---|---|
| `uuid`, `published`, `eventType` | Event identity, publication time and event kind; not a JWT ID or gateway request timestamp. |
| `actor.id`, `actor.type` | Entity acting in this IdP event. Do not assume `actor.id` equals the access-token `sub` without verifying the authorization-server mapping. |
| `outcome.result` | Outcome of this specific event. A successful `user.session.start` proves neither custom API token issuance nor gateway acceptance. |
| `authenticationContext.externalSessionId` | Okta session correlation where present, not an Application Insights `OperationId`. |
| `transaction.id` | Okta transaction grouping where present, not an APIM request/span ID. |

Other event types provide policy, MFA and OAuth activity as documented by Okta;
their actors, targets and optional fields vary. The API warns that
`debugContext.debugData` is **not a stable data contract**. Do not export it wholesale
or depend on it for identity joins. Select target entities by their `type`, not array
position. A future SIEM/Log Analytics connector may transform field names and choose
its own table; that export schema must be verified separately.

Entra's native `SigninLogs` and `AuditLogs` examples remain in section 7.7. Both
providers' records can support a governed subject-level investigation, but neither
should be joined to an individual inference using only approximate timestamps.

### Token lifecycle, privacy and rollout boundaries

APIM validates the presented access token; it does not perform or observe every
client acquisition/refresh. A helper invocation may return a cached token, and a
failure before dispatch produces no gateway request span. Future helper telemetry
must use an approved sanitized sink while keeping credential-command stdout reserved
for the credential. No renewal logging or Okta helper is implemented by this section.

IdP sign-in, MFA, token issuance and local gateway validation are separate events.
Do not equate their correlation IDs or assume one sign-in per inference. Local
signature/lifetime validation can continue accepting a token until expiry without
learning of a recent account disablement/revocation. Do not report a fresh MFA or
revocation check merely because a JWT was accepted.

- Never record raw JWTs, refresh/ID tokens, authorization codes, secrets, complete
  claim sets, credential header values or unfiltered error messages. These examples
  also omit `jti`, token hashes and other token fingerprints.
- Treat stable subjects and client IDs as governed metadata. Use exact trusted issuer
  plus principal for identity joins; workspace `TenantId` is not token `tenant_id`.
- Keep metric dimensions bounded to configured categories such as validator/outcome/
  reason. Do not add high-cardinality users or client IDs to full metric schemas.
- Preflight must verify two users, multiple scopes, tampered/expired/wrong-issuer/
  audience tokens, missing stable identity, machine identities, conflicting sources,
  key-mode compatibility, error-path coverage, credential stripping and quota isolation.
- Keep Entra, synthetic Okta fixtures and customer Okta validation evidence distinct.
  Inspect approved samples to confirm actual fields before promising a production
  schema. No policy edits, IdP export configuration or deployment are authorized by
  this documentation addition.

## References

- [Microsoft: APIM integration and telemetry categories](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-app-insights)
- [Microsoft: trace policy and metadata](https://learn.microsoft.com/en-us/azure/api-management/trace-policy)
- [Microsoft: custom metric limits](https://learn.microsoft.com/en-us/azure/api-management/emit-metric-policy)
- [Microsoft: Foundry account resource-log categories and destinations](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/supported-logs/microsoft-cognitiveservices-accounts-logs)
- [Microsoft: Azure OpenAI and Foundry model monitoring reference](https://learn.microsoft.com/en-us/azure/foundry/openai/monitor-openai-reference)
- [Microsoft: model-service monitoring and diagnostic collection](https://learn.microsoft.com/en-us/azure/foundry-classic/openai/how-to/monitor-openai)
- [Microsoft: application tracing and optional message capture (classic portal)](https://learn.microsoft.com/en-us/azure/foundry-classic/how-to/develop/trace-application)
- [Microsoft: JWT validation policy and validated output variable](https://learn.microsoft.com/en-us/azure/api-management/validate-jwt-policy)
- [Microsoft: policy error handling and JWT failure reasons](https://learn.microsoft.com/en-us/azure/api-management/api-management-error-handling-policies)
- [Microsoft: Entra access-token claims](https://learn.microsoft.com/en-us/entra/identity-platform/access-token-claims-reference)
- [Okta: access-token validation and authorization-server boundary](https://developer.okta.com/docs/guides/validate-access-tokens/main/)
- [Okta: access-token scopes and claims](https://developer.okta.com/docs/api/openapi/okta-oauth/guides/overview/#access-token-scopes-and-claims)
- [Okta: native System Log API and event schema](https://developer.okta.com/docs/api/openapi/okta-management/management/tag/SystemLog/)
- [Foundry JWT policy](../policies/byok-foundry-policy.xml) and [subscription-key policy](../policies/byok-foundry-policy-subkey.xml)
- [Existing reporting queries](../monitoring/kql) and [delivery telemetry guidance](lessons-learned.md#5-telemetry--kql--what-you-actually-get-and-the-gov-caveats)