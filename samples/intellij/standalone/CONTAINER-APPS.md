# IntelliJ Managed Proxy

Tracking: GitHub issue #138 (follow-up to the VM implementation in #115).

Status: **Government pilot proxy deployed alongside the register app in its private-endpoint environment on 2026-09-17; basic runtime checks passed.** The final app uses the proxy name; the original runner-hosted and temporary relocation copies were removed after testing. Existing VM deployments
remain unchanged. This alternative removes the customer-managed proxy VM, not the need for
private networking. The client remains **JetBrains AI Assistant's OpenAI-compatible provider**,
not the GitHub Copilot plugin or a custom ACP agent.

```text
JetBrains AI Assistant -> private ACA HTTPS ingress -> nginx -> private APIM -> Foundry
```

The pilot passed private HTTPS model discovery and chat for two subscription tiers, missing/invalid
key rejection, incremental SSE with `[DONE]`, health checks, and unrelated-path rejection. The
existing in-VNet Windows demo VM reached both endpoints; the laptop could not reach ACA ingress.
An in-VNet workspace query confirmed distinct request and auto-route metrics for both test users.
This is not final production acceptance: actual IDE use, long-running/idle streams, large contexts,
concurrency, cancellation, and revision draining still need testing. Keep the VM available while
evaluating Container Apps. Concrete endpoint values belong in local deployment outputs, not Git.

## What This Deploys

- One Container App in an **existing private, VNet-integrated environment** and existing RG.
- nginx translates each developer's Bearer key to `api-key`. APIM still validates subscriptions.
- Only the configured `/intellij/` prefix is forwarded; `/healthz` is an unauthenticated local probe.
- Upstream APIM TLS certificate verification is enabled, with gateway hostname used for Host/SNI.
- Unbuffered request/response forwarding, one warm replica, HTTP concurrency scaling (20 requests
  per replica), and at most three replicas by default. Warm replicas reduce cold starts, not all
  platform restart delays. This is not an HA guarantee.
- Optional APIM configuration using the existing shared module, including telemetry and products.

No VM, NIC, environment, subnet, registry, identity, role assignment, Foundry resource,
or resource group is created. DNS is customer-managed by default; `configurePrivateDns=true`
explicitly adds the internal environment's private DNS zone, wildcard A record, and a
non-registering link to that environment's VNet in the proxy resource group. Do not enable it
over a zone managed by another deployment. Supply an approved nginx image through the required `proxyImage`
parameter; there is no implicit public image dependency. Configuration is mounted through an ACA
secret volume, but contains **no developer or backend keys**. Its hash is
part of the revision template so a configuration change rolls the app. Image/config maintenance
is still the customer's responsibility. Access logs omit query strings and authorization headers;
do not enable verbose logging or request-body capture for inference traffic.

## Mandatory Go/No-Go Gate

The network/platform owner must confirm all of the following before deployment:

| Requirement | PASS condition |
| --- | --- |
| Cloud and region | The target cloud supports the ACA environment, API version, container sizing, probes, and scaling configuration. Confirm Government support in the actual region, not by assuming Commercial parity. |
| Environment | An existing healthy VNet-integrated environment has a route to APIM. Default `environmentIngressMode=internal` requires internal ingress. Opt-in `privateEndpoint` requires an external environment, public access Disabled, and an approved/provisioned Private Endpoint. |
| Private client path | Developer workstations reach the environment's internal ingress IP on HTTPS via the VNet, peering, VPN, or ExpressRoute. Bastion management alone is not application connectivity. |
| DNS | The ACA app's default hostname resolves privately from developer networks. Use customer-managed DNS or the explicit `configurePrivateDns` option for the environment VNet; customers still own forwarding from other networks. No per-replica A-record reconciler is required. |
| APIM | Classic Internal APIM; the configured private IPv4 address is a current gateway VIP. Private-endpoint-only APIM is not implemented in this proof of concept. |
| TLS | The configured hostname matches a gateway hostname, and APIM presents a certificate trusted by the nginx system CA bundle. Private-CA custom domains require an approved image with that CA installed; do not disable verification. |
| Image delivery | The environment can pull the approved image anonymously. This version does not configure private-registry credentials or managed identity. Verify the tag exists and use an approved immutable digest for production; restricted networks need an approved image delivery solution before proceeding. |
| Access | Deployment identity can deploy into the proxy RG, read/join the environment, and read APIM. With APIM configuration enabled, it also needs APIM write permissions and read access to the existing App Insights. |
| Streaming budget | The ingress timeouts and request-size limits fit real IntelliJ requests, including delayed first tokens, silent reasoning intervals, large contexts, and SSE. A 600-second nginx read timeout does not override ACA or APIM limits. |

**Important:** app-level `external: true` means publish at the environment boundary. An internal
environment is VNet-only; the supported external-plus-PE mode blocks public access at the environment.
Setting
the app to internal ingress would restrict its default hostname to other apps in that environment.
This distinction must be tested when revisiting the earlier ACA 404 observations; those observations
do not prove that all internal-environment configurations are unusable.

The deployment helpers enforce the control-plane subset of this gate before running what-if or
create. They do not change cloud or sign in. Use an already authenticated, cloud-pinned terminal.
The top-level template also reads the environment's actual topology, subnet and PE settings and passes
the result to a nested parameter that accepts only `true`, rejecting a public environment before
the app is created. **Use the helpers rather than deploying the child module directly**: the
helpers additionally validate APIM topology, gateway inputs, and existing API authentication.
Environment changes after validation require repeating the gate.

## Prepare and Preview

Use `containerapp.parameters.example.json` as the shape for a local
`containerapp.parameters.json` (gitignored). Populate environment, existing RG, APIM gateway, and
location values locally. Do not commit identifying values or credentials.

Prefer the register application's environment for application workloads; keep CI runners separate.
For its external-plus-PE topology, explicitly set `environmentIngressMode=privateEndpoint` and
`configurePrivateDns=false`. Reuse its existing PE, DNS zone and VNet link; the internal-mode DNS
option must not be used here. Relocation requires a separately named app for overlap testing because
an existing app cannot move between environments. Keep the prior proxy until retirement is approved.

Set `proxyImage` to an approved, anonymously pullable nginx image, preferably pinned by digest.
It must include the standard `/etc/nginx/conf.d` layout and
`/etc/ssl/certs/ca-certificates.crt`. Do not assume MCR mirrors every upstream nginx release:
the proposed `1.28` mirror tag returned 404 during preparation. This package installs no packages
at container startup and does not build or publish an image.

The default `configureApim=false` requires an existing `intellij-byok` API with the same path,
`subscriptionRequired=true`, and subscription header `api-key`. This mode changes **only the proxy**
and is the migration path for an API already managed by Terraform or another Bicep deployment.

For a **new Bicep-managed API**, set `configureApim=true` and add wrapped parameter values for
`existingBackendName`, `appInsightsName`, and `appInsightsResourceGroup`. Supply all desired product
and routing settings from the existing VM entry point: `existingProductName`,
`additionalProductNames`, `apiVersion`, `autoRouteSentinel`, `autoRouteMiniDeployment`,
`autoRouteFullDeployment`, `autoRouteLengthThreshold`, and `autoRouteAmbiguousBand`. Omitting these
uses the same shared-module defaults, not the settings from a previous deployment.

For side-by-side VM and Container Apps hosting, deploy the shared API once with the VM entry
point and keep `configureApim=false` here. Both proxies still send each user's subscription key
to APIM. Bicep API deployments can opt into `foundryAuthMode=managedIdentity` for the
APIM-to-Foundry hop when backend key authentication is disabled. The existing APIM identity needs
appropriate Foundry data-plane RBAC; no proxy identity or direct proxy-to-Foundry route is added.
Key authentication remains the default. Container Apps is the intended final option after
runtime acceptance; retaining the VM is an independent opt-in choice.

Only one IaC deployment/state should own the APIM API. Do not enable `configureApim` over a
Terraform-owned API. Where the existing backend does not carry its own credential, set
`FOUNDRY_API_KEY` securely in the local environment before using `configureApim=true`. Helpers pass
it as a secure ARM parameter and never print it; do not use shell tracing/debug logs. The value is
still present in the child CLI process arguments, as with the existing deployment helpers.

From this directory, with PowerShell 7+ and Azure CLI:

```powershell
./deploy-containerapp.ps1 -ParametersFile ./containerapp.parameters.json -ValidateOnly
./deploy-containerapp.ps1 -ParametersFile ./containerapp.parameters.json
```

Or with bash, jq, and Azure CLI:

```bash
./deploy-containerapp.sh --parameters-file ./containerapp.parameters.json --validate-only
./deploy-containerapp.sh --parameters-file ./containerapp.parameters.json
```

The second invocation defaults to **what-if**, not deployment. Review its changes and obtain the
resource owner's approval. After the network gate passes and deployment is approved:

```powershell
./deploy-containerapp.ps1 -ParametersFile ./containerapp.parameters.json -Deploy -NetworkValidated
```

```bash
./deploy-containerapp.sh --parameters-file ./containerapp.parameters.json --deploy --network-validated
```

The deployment prints an HTTPS client base URL. Use it in JetBrains AI Assistant's
OpenAI-compatible provider, with the developer's existing **APIM subscription key**, not a Foundry
key. Keep the existing VM endpoint working until the managed endpoint passes the tests below.

## Local Regression Tests

From this directory, run the dependency-free guard suite with PowerShell 7+:

```powershell
pwsh -NoProfile -File ./tests/deployment-guards.Tests.ps1
```

The 40 cases mock every Azure CLI call and parameter-file read. They cover both private topologies,
APIM subscription authentication, unsafe inputs, failed reads, what-if as the default, explicit
deployment acknowledgement, and the active-cloud backend lookup. No Azure resources are accessed
or changed. This suite exercises the PowerShell helper; Bash runtime parity, nginx, image pulls,
and the live acceptance checks below remain separate validation requirements.

## Runtime Acceptance

Run from the actual developer network, with certificate verification enabled:

1. Resolve the ACA hostname to the approved private ingress IP; verify `/healthz` returns 200.
   Also test from outside the private network and confirm the endpoint is inaccessible.
2. With the APIM key in `Authorization: Bearer`, verify `GET /intellij/v1/models` returns the
   expected models and the IDE dropdown populates. No key and an invalid key must return 401.
3. Verify `/openai/v1/models` and unrelated paths return 404 through the proxy. Only the configured
   API prefix and the local health endpoint are exposed.
4. Verify a non-streaming chat and then `stream=true`, including incremental chunks and `[DONE]`,
   rather than one buffered response. Compare with the VM baseline.
5. Exercise delayed first tokens and silent intervals near/beyond four minutes, streams exceeding
   four minutes, representative maximum request bodies, concurrent IntelliJ workloads, and client
   cancellation. Check request failures and backend activity after cancellation.
6. Verify existing per-subscription request metrics, auto-routing decisions, and available token
   usage telemetry. Do not promise new streaming-token metrics from a hosting change.
7. Redeploy a configuration change and verify the new revision becomes ready. Test draining and
   interruption behavior; probes alone do not establish APIM/Foundry reachability.

ACA documentation lists a 240-second default HTTP timeout. Advanced **idle** timeout configuration
(4-30 minutes) requires premium ingress on dedicated workload-profile nodes, with at least two
nodes. Do not assume periodic SSE chunks or nginx's timeout resolve every platform limit; measure
both active streams and idle gaps. Premium ingress is deliberately not enabled by this package.

## Cost and Rollback

One warm Consumption replica has an ongoing cost; scaling and environment logging add usage.
Reuse of an existing environment reduces new infrastructure, but is subject to its capacity and
ownership rules. Premium ingress would introduce dedicated compute costs and needs a separate
decision. This package does not claim a priced saving versus the small VM.

For rollback, point IntelliJ back to the retained VM endpoint. With `configureApim=false`, no APIM
rollback is necessary. Do not destroy the Terraform VM stack to remove only its VM: that stack also
owns APIM resources. Any eventual VM retirement or Container App deletion needs explicit approval
and an ownership-aware change plan.

## Current Limits

- Local validation is not a successful deployment or an end-to-end IntelliJ test.
- New ACA environment/network/Private Endpoint provisioning is not included; existing private topologies are reused.
- Private registry authentication and private CA injection are not included.
- The Terraform route remains VM-only until the managed-hosting runtime proof passes.

References: [ACA ingress](https://learn.microsoft.com/azure/container-apps/ingress-overview),
[private DNS](https://learn.microsoft.com/azure/container-apps/private-endpoints-with-dns),
[advanced ingress settings](https://learn.microsoft.com/azure/container-apps/ingress-environment-configuration).