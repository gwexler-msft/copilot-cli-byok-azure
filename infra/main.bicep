targetScope = 'subscription'

@description('Short prefix used in all resource names. Lowercase, alpha-only.')
param namePrefix string = 'copilot-byok'

@description('Environment short name, e.g. gov-pilot, dev, prod. Used in names.')
param envName string = 'gov-pilot'

@description('Azure region for all resources.')
param location string = 'usgovvirginia'

@description('Cloud environment. Drives DNS suffixes and Entra endpoints.')
@allowed([
  'AzureCloud'
  'AzureUSGovernment'
])
param cloudEnv string = 'AzureUSGovernment'

@description('CIDR for the BYOK VNet.')
param vnetCidr string = '10.60.0.0/16'

@description('APIM SKU. Developer for pilot, Premium for production.')
@allowed([
  'Developer'
  'Premium'
])
param apimSku string = 'Developer'

@description('APIM publisher email shown on the dev portal and notifications.')
param apimPublisherEmail string

@description('APIM publisher display name.')
param apimPublisherName string = 'Copilot BYOK Gateway'

@description('AOAI model name to deploy.')
param modelName string = 'gpt-4.1'

@description('AOAI model version.')
param modelVersion string = '2025-04-14'

@description('AOAI deployment SKU (capacity unit type).')
@allowed([
  'Standard'
  'GlobalStandard'
  'DataZoneStandard'
])
param modelDeploymentSku string = 'Standard'

@description('AOAI deployment capacity (TPM units of 1000). 1 unit = 1,000 TPM. Bump if you raise the APIM product tier TPM (e.g. byok-power=60k TPM/dev × N concurrent devs). Default 250 covers ~4 power devs in parallel; check regional model quota before raising further.')
param modelCapacity int = 250

@description('Name of the Copilot deployment exposed via APIM (matches what devs put in COPILOT_MODEL).')
param apimExposedModelName string = 'gpt-4.1'

@description('Deploy the classic Azure OpenAI (kind=OpenAI) backend. Exposed via the APIM legacy path /aoai. Default false — Microsoft Foundry (kind=AIServices) is the recommended/standard backend; only enable this for a legacy /aoai path.')
param deployAoai bool = false

@description('Deploy the Microsoft Foundry (kind=AIServices) backend. The default APIM path /openai routes here.')
param deployFoundry bool = true

@description('Foundry model name. Defaults to the AOAI model so both backends host the same model.')
param foundryModelName string = modelName

@description('Foundry model version.')
param foundryModelVersion string = modelVersion

@description('Foundry deployment SKU (capacity unit type).')
param foundryModelDeploymentSku string = modelDeploymentSku

@description('Foundry deployment capacity (TPM units of 1000).')
param foundryModelCapacity int = modelCapacity

@description('Foundry exposed/deployment name (request body "model"). Defaults to apimExposedModelName.')
param foundryExposedModelName string = apimExposedModelName

@description('Comma-separated model names the default (Foundry) route should pin to the legacy AOAI backend instead. Empty = all traffic to Foundry.')
param aoaiPinnedModels string = ''

// ---------------------------------------------------------------------------------------------
// Auto model-routing (tiered): when a caller sends the sentinel model (default "auto"), APIM
// picks a cheaper "mini" deployment for short/non-coding prompts and the full model otherwise.
// Level 1 is an in-policy heuristic (length + coding signals); Level 2 is an optional classifier
// model call (off by default) for the ambiguous band. Requires a second "mini" deployment on
// each backend it applies to.
// ---------------------------------------------------------------------------------------------

@description('Deploy a secondary smaller "mini" model on each backend, used as the cheap tier by auto model-routing.')
param deployMiniModel bool = true

@description('Mini model name to deploy (the cheap auto-routing tier).')
param miniModelName string = 'gpt-4.1-mini'

@description('Mini model version. Confirm the exact version available in your region before deploying.')
param miniModelVersion string = '2025-04-14'

@description('Mini deployment SKU (capacity unit type).')
@allowed([
  'Standard'
  'GlobalStandard'
  'DataZoneStandard'
])
param miniModelDeploymentSku string = 'DataZoneStandard'

@description('Mini deployment capacity (TPM units of 1000). 1 unit = 1,000 TPM. Same sizing logic as modelCapacity — the mini takes auto-routed low-tier traffic, so size it similarly.')
param miniModelCapacity int = 250

@description('Mini exposed/deployment name (the value auto-routing rewrites the body "model" to for the cheap tier).')
param miniExposedModelName string = 'gpt-4.1-mini'

@description('Sentinel value callers put in the request body "model" to opt in to auto-routing. Explicit model names bypass routing.')
param autoRouteSentinel string = 'auto'

@description('Auto-routing Level 1: prompt-length threshold (characters across all messages). Shorter non-coding prompts lean to mini, longer to the full model.')
param autoRouteLengthThreshold int = 500

@description('Auto-routing Level 1: half-width (chars) of the ambiguous band around the threshold. Prompts within [threshold-band, threshold+band) are ambiguous and fall through to Level 2 (or the full model if the classifier is off). Set 0 for a hard threshold with no ambiguous band.')
param autoRouteAmbiguousBand int = 200

@description('Auto-routing Level 2: enable the classifier-model call for ambiguous prompts. Off = ambiguous prompts go to the full model (zero added latency). On = a max_tokens:1 call to the mini deployment decides simple/complex (adds one round-trip on the ambiguous band only).')
param autoRouteClassifierEnabled bool = false

@description('Caller credential the APIM gateway requires. subscriptionKey = per-developer APIM subscription key (default, what the customer was sold); jwt = short-lived Entra access token validated by validate-jwt. Switchable per deployment without changing backends.')
@allowed([
  'subscriptionKey'
  'jwt'
])
param authMode string = 'subscriptionKey'

@description('Entra tenant ID that issues developer JWTs.')
param entraTenantId string

@description('Entra app ID URI of the BYOK gateway app (created by scripts/setup-entra). Used in the dev-facing error message; this is what callers pass to --resource.')
param apiAppIdUri string

@description('JWT audience the gateway validates. With v2 access tokens this is the app (client) ID GUID, NOT the api:// URI. From scripts/setup-entra output (appId).')
param apiAudience string

@description('Required scope claim value the JWT must contain.')
param requiredScope string = 'cli.invoke'

@description('In subscriptionKey mode, create ready-to-use APIM subscriptions so the gateway can be verified immediately. Ignored when authMode=jwt.')
param deployTestSubscriptions bool = true

@description('Test developer APIM subscriptions to create (subscriptionKey mode). Each { name, product } scopes a key to a rate-limit product tier and is stamped onto telemetry as the developer. product must match a productTiers name OR "byok-discovery" (the restricted product that contains only the GET /v1/models discovery API).')
param testSubscriptions array = [
  {
    name: 'dev1'
    product: 'byok-standard'
  }
  {
    name: 'dev2'
    product: 'byok-power'
  }
  {
    // 'smoke' is the only key the CI smoke runner needs for the discovery assertion.
    // It is scoped to the byok-discovery product (created by apim-products.bicep) which
    // contains ONLY the copilot-byok-discovery API -- so this key can list models but
    // cannot run chat/completions/responses (those require a tier-scoped key).
    name: 'smoke'
    product: 'byok-discovery'
  }
]

@description('Rate-limit product tiers (subscriptionKey mode). Each becomes a published APIM product with a product-scope throttle policy: callsPerMinute (burst), tokensPerMinute (the AI-cost guard), monthlyCallQuota (hard 30-day call ceiling). Group developers by assigning their subscription to a tier.')
param productTiers array = [
  {
    name: 'byok-standard'
    displayName: 'BYOK Standard'
    description: 'Standard developer tier: modest burst + TPM, suitable for typical interactive coding use.'
    callsPerMinute: 60
    tokensPerMinute: 20000
    monthlyCallQuota: 50000
  }
  {
    name: 'byok-power'
    displayName: 'BYOK Power'
    description: 'Power developer tier: higher burst + TPM for heavy agentic / batch use (e.g. VS Code Copilot Chat with full codebase context, which routinely sends 30-80k-token requests).'
    callsPerMinute: 120
    tokensPerMinute: 200000
    monthlyCallQuota: 200000
  }
]

@description('jwt mode: the SINGLE flat per-developer burst limit (calls/min), keyed on Entra oid. Applies only when authMode=jwt; subscriptionKey mode uses productTiers instead.')
param jwtDefaultCallsPerMinute int = 120

@description('jwt mode: the SINGLE flat per-developer token-per-minute limit (prompt+completion), keyed on Entra oid. The real AI-cost guard. Applies only when authMode=jwt. Sized to match byok-power so a single VS Code Copilot Chat request with full codebase context (typically 30-80k tokens) fits inside one minute.')
param jwtDefaultTokensPerMinute int = 200000

@description('jwt mode: the SINGLE flat per-developer hard monthly call ceiling (calls per 30 days), keyed on Entra oid. Applies only when authMode=jwt.')
param jwtDefaultMonthlyCallQuota int = 200000

@description('Content-filter (responsible-AI) policy name applied to model deployments. byok-coding = the shipped default (severityThreshold=Low on all four harm categories + Jailbreak in annotate-only mode + Protected Material Text; authored automatically from scripts/content-filter.byok-coding.json). byok-strict swaps Jailbreak to blocking and is the right choice for stricter clients whose prompts do not trip Prompt Shields (authored from scripts/content-filter.byok-strict.json). Set to a built-in Microsoft.* name (e.g. Microsoft.DefaultV2) to use the platform default with no custom policy — note that Microsoft.DefaultV2 has blocking Jailbreak and will reject VS Code Copilot system prompts with 400 content_filter.')
param raiPolicyName string = 'byok-coding'

@description('Deploy a P2S VPN gateway. Adds ~30 min and ~$140/mo.')
param deployVpnGateway bool = true

@description('VPN root cert public data (base64, single line, no PEM headers). Required if deployVpnGateway=true.')
@secure()
param vpnRootCertPublicData string = ''

@description('Optional: resource ID of an existing VNet to peer with. Empty = no peering.')
param peerVnetResourceId string = ''

@description('Principal ID (object ID) to grant deployer-level RBAC on AOAI. Leave empty to skip.')
param deployerPrincipalId string = ''

@description('Assign the "Cognitive Services OpenAI User" role to APIM MI on the AOAI account. Requires the deployer to have Microsoft.Authorization/roleAssignments/write. Set false to assign out-of-band.')
param assignAoaiRbac bool = true

@description('Object IDs (users or groups) to grant "Cognitive Services OpenAI User" on BOTH the AOAI and Foundry accounts, enabling direct portal/playground + SDK access. Accounts have local auth disabled, so this is the ONLY way humans reach the data plane. Empty = none (add users out-of-band).')
param playgroundPrincipalIds array = []

@description('Principal type for playgroundPrincipalIds: "User" for individuals, "Group" for an Entra security group.')
@allowed([ 'User', 'Group' ])
param playgroundPrincipalType string = 'User'

@description('Umbrella switch for the on-demand validation/test stack: Windows test VM + Azure Bastion (~$210/mo combined) + the VM-subnet NSG egress allowlist + the VM-subnet NAT Gateway attachment. Default false = production gateway only (~$135/mo idle: APIM Developer + NAT for APIM-egress lockdown + PE + LA + Foundry). Flip to true when you need to validate networking, egress allowlists, or run the BYOK probe from inside the VNet; flip back to false to tear it all down via azd provision. The four granular sub-params below (deployTestVm, deployNatGateway, restrictVmEgress, testVmAdmin*) are only honored when this umbrella is true; otherwise they are forced off regardless of their values. restrictApimEgress is intentionally NOT gated by this switch (its snet-apim defaultOutboundAccess is immutable post-create, and the APIM-egress NSG is the real production security posture).')
param deployTestStack bool = false

@description('Deploy a Windows test VM + Azure Bastion for manual in-VNet validation of the Internal APIM. Tear down when done. Only takes effect when deployTestStack=true.')
param deployTestVm bool = false
@description('Admin username for the test VM. Required if deployTestStack=true && deployTestVm=true.')
param testVmAdminUsername string = 'byokadmin'

@description('Admin password for the test VM. Required if deployTestStack=true && deployTestVm=true. Passed at deploy time, never stored.')
@secure()
param testVmAdminPassword string = ''

@description('Deploy a NAT Gateway attachment on the test-VM subnet for deterministic, controlled egress (replaces the deprecated Azure default-outbound). Only takes effect when deployTestStack=true && deployTestVm=true. ~$32/mo + data. Default true so the egress-restricted VM subnet has a working outbound path; set false only for quick dev/test where the NAT cost is unwanted. NOTE: the NAT Gateway resource ITSELF is still deployed when restrictApimEgress=true (independent of this flag) because APIM Internal-mode subnet uses it for its allowed egress path.')
param deployNatGateway bool = true

@description('Apply an egress-allowlist NSG to the test-VM subnet (GitHub/npm/nodejs/Azure-management only; deny the rest). A discovery tool to observe exactly what the Copilot CLI install/runtime needs. Only takes effect when deployTestStack=true && deployTestVm=true. Default true (default-deny posture, matching restrictApimEgress). Pair with deployNatGateway so allowed traffic has an egress path.')
param restrictVmEgress bool = true

@description('Add a default-deny outbound allowlist to the APIM subnet NSG: permit only the Azure-internal service-tag dependencies APIM (Internal VNet mode) MUST reach (Entra/Storage/SQL/Key Vault/Azure Monitor) plus intra-VNet, then deny the rest of the internet. Default true (recommended default-deny posture); the APIM subnet becomes private and gets a NAT gateway for the allowed egress path. Independent of deployTestStack — the snet-apim defaultOutboundAccess flag this sets is IMMUTABLE post-create, so flipping false on an existing deployment requires recreating snet-apim (and therefore APIM). Set false only on a fresh deploy where the NAT cost or the private-subnet choice is unwanted.')
param restrictApimEgress bool = true

// Derived effective values: the four test-stack sub-params are ONLY honored when the
// deployTestStack umbrella is true. This lets a single flip in the params file tear down
// VM + Bastion + VM NSG + VM-subnet NAT attachment together, without losing the granular
// knobs for advanced "test stack on but skip NAT" scenarios.
var effectiveDeployTestVm     = deployTestStack && deployTestVm
var effectiveDeployNatGateway = deployTestStack && deployNatGateway
var effectiveRestrictVmEgress = deployTestStack && restrictVmEgress

@description('Deploy a VNet-linked Private DNS zone (azure-api.us/.net) with an A record for the APIM gateway so in-VNet clients resolve it without a hosts entry. Prerequisite for the VPN/DNS-resolver phase too.')
param deployApimPrivateDns bool = true

// ---------------------------------------------------------------------------------------------
// Self-hosted GitHub Actions runner (issue #57 / parent #52). Deploys an ACA Job + UAMI inside
// the BYOK VNet so CI/CD smoke tests can reach the private APIM gateway and Foundry data plane
// without leaving the VNet. Default false — the production gateway never needs the runner; flip
// to true in CI/CD environments (or `--parameters deployGhRunner=true`).
// ---------------------------------------------------------------------------------------------

@description('Deploy the VNet-injected self-hosted GitHub Actions runner stack (ACA env + Job + UAMI + RBAC + snet-runner). Default false. When false the runner subnet is NOT created and no runner resources exist. Set true to add the runner stack idempotently.')
param deployGhRunner bool = false

@description('CIDR for snet-runner. Must be /27 or larger (ACA Workload Profiles requirement). Empty default lets the network module derive `<vnetBase>.4.0/27` from `vnetCidr` so dev envs (e.g. 10.61.0.0/16) auto-fit. Override only to customize within a single VNet. Only used when deployGhRunner=true.')
param runnerSubnetCidr string = ''

@description('Container image the runner job runs. Phase 1 default is a placeholder so deploys succeed without GitHub credentials. Phase 3 (#58) will swap to the real actions-runner image.')
param ghRunnerImage string = 'mcr.microsoft.com/azure-cli:latest'

@description('GitHub repository (`<owner>/<repo>`) used to build OIDC federated-credential subjects for the runner UAMI. Both clouds share the same issuer URL; only the repo + env subject changes.')
param ghRepository string = 'gwexler_microsoft/copilot-cli-byok-azure'

@description('GitHub Environment names whose OIDC tokens may federate to THIS runner UAMI (subject `repo:<ghRepository>:environment:<name>`). Defaults to this env only; add sibling envs to share a runner pool. Empty array disables federation.')
param ghRunnerFicEnvSubjects array = [envName]

@description('GitHub PAT (#58 phase 3). When provided, the runner Job flips from Phase 1 manual placeholder to KEDA-scaled, event-driven self-hosted runner (myoung34/github-runner image). Stored ONLY as an ACA Job secret named `gh-pat`. Leave empty to keep the Phase 1 placeholder behavior. PAT scopes: classic `repo` OR fine-grained with `Actions: read+write` and `Administration: read+write`.')
@secure()
param ghRunnerPat string = ''

@description('Container image for the KEDA-driven runner (when ghRunnerPat is set). Pin to a SHA digest in production; `:latest` is fine for the experimental pilots.')
param ghRunnerEventImage string = 'myoung34/github-runner:latest'

@description('Comma-separated runner labels applied at registration. Workflows must `runs-on:` this exact value (or a subset). Default = envName so e.g. `runs-on: comm-pilot` reaches this env\'s runner pool.')
param ghRunnerLabels string = envName

@description('Max concurrent KEDA-driven runner replicas. Each replica = one workflow job, then the container exits (ephemeral). Higher = more burst parallelism, more Azure billing during bursts.')
param ghMaxRunners int = 5

// ---------------------------------------------------------------------------------------------
// Multi-region backend pools (opt-in). When off (default) each AI account is fronted by a single
// transparent APIM Url backend, identical to the prior inline base-url behavior. When on, extra
// regional accounts are deployed and APIM load-balances/fails-over across them via a Pool backend
// with circuit breakers — WITHOUT changing the managed-identity auth route (one Entra token,
// audience = the shared Cognitive Services audience, is valid against every regional account).
// ---------------------------------------------------------------------------------------------

@description('Deploy multi-region APIM backend pools (load-balanced + circuit-broken) across the AI accounts, keeping the managed-identity auth route. Default false = a single transparent Url backend per account. Opt in AND populate foundryRegions / aoaiRegions to add regions.')
param deployBackendPool bool = false

@description('Additional Foundry regions for the backend pool, BEYOND the primary `location`. Each item: { location: string, modelCapacity: int, miniModelCapacity: int }. Only used when deployBackendPool=true. The same model + mini deployment (names/versions) is created in every region so auto-routing works pool-wide.')
param foundryRegions array = []

@description('Additional AOAI regions for the backend pool, BEYOND the primary `location`. Each item: { location: string, modelCapacity: int, miniModelCapacity: int }. Only used when deployBackendPool=true AND deployAoai=true.')
param aoaiRegions array = []

@description('Attach a circuit breaker to each pooled Url backend (trips on 429 + 5xx and honors Retry-After so PTU 429s spill promptly to the next region). Only applies when deployBackendPool=true.')
param enableBackendCircuitBreaker bool = true

@description('Circuit breaker: number of failures within breakerInterval that trip a backend out of rotation.')
param breakerFailureCount int = 5

@description('Circuit breaker: rolling window the failures are counted over (ISO-8601 duration).')
param breakerInterval string = 'PT1M'

@description('Circuit breaker: how long a tripped backend stays out of rotation before being retried (ISO-8601 duration).')
param breakerTripDuration string = 'PT1M'

@description('Backend-pool distribution strategy. priority = active/passive failover (primary region serves all traffic; other regions take over only on trip/outage). weighted = active/active, load-balanced equally across all regions. Only applies when deployBackendPool=true with >1 region.')
@allowed([
  'priority'
  'weighted'
])
param backendPoolStrategy string = 'priority'

var suffix = substring(uniqueString(subscription().id, envName, location), 0, 6)
var rgName = 'rg-${namePrefix}-${envName}'

var cloudVars = {
  AzureCloud: {
    aoaiDnsZone: 'privatelink.openai.azure.com'
    cognitiveDnsZone: 'privatelink.cognitiveservices.azure.com'
    aiDnsZone: 'privatelink.services.ai.azure.com'
    aoaiAudience: 'https://cognitiveservices.azure.com'
    foundryAudience: 'https://cognitiveservices.azure.com'
    aoaiPublicSuffix: 'openai.azure.com'
    #disable-next-line no-hardcoded-env-urls // intentional per-cloud constant, not the active env
    entraLoginHost: 'login.microsoftonline.com'
    apimDnsZone: 'azure-api.net'
  }
  AzureUSGovernment: {
    aoaiDnsZone: 'privatelink.openai.azure.us'
    cognitiveDnsZone: 'privatelink.cognitiveservices.azure.us'
    aiDnsZone: '' // services.ai privatelink zone is Commercial-only today
    aoaiAudience: 'https://cognitiveservices.azure.us'
    foundryAudience: 'https://cognitiveservices.azure.us'
    aoaiPublicSuffix: 'openai.azure.us'
    entraLoginHost: 'login.microsoftonline.us'
    apimDnsZone: 'azure-api.us'
  }
}

var v = cloudVars[cloudEnv]
var entraOpenIdConfigUrl = 'https://${v.entraLoginHost}/${entraTenantId}/v2.0/.well-known/openid-configuration'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgName
  location: location
}

module observability 'modules/observability.bicep' = {
  name: 'observability'
  scope: rg
  params: {
    namePrefix: namePrefix
    envName: envName
    suffix: suffix
    location: location
  }
}

module network 'modules/network.bicep' = {
  name: 'network'
  scope: rg
  params: {
    namePrefix: namePrefix
    envName: envName
    suffix: suffix
    location: location
    vnetCidr: vnetCidr
    deployVpnGateway: deployVpnGateway
    vpnRootCertPublicData: vpnRootCertPublicData
    peerVnetResourceId: peerVnetResourceId
    deployTestVm: effectiveDeployTestVm
    deployNatGateway: effectiveDeployNatGateway
    restrictVmEgress: effectiveRestrictVmEgress
    restrictApimEgress: restrictApimEgress
    deployGhRunner: deployGhRunner
    runnerSubnetCidr: runnerSubnetCidr
  }
}

module privatedns 'modules/privatedns-cognitive.bicep' = {
  name: 'privatedns-cognitive'
  scope: rg
  params: {
    openaiDnsZoneName: v.aoaiDnsZone
    cognitiveDnsZoneName: v.cognitiveDnsZone
    aiDnsZoneName: v.aiDnsZone
    vnetId: network.outputs.vnetId
    peerVnetResourceId: peerVnetResourceId
  }
}

module aoai 'modules/aoai.bicep' = if (deployAoai) {
  name: 'aoai'
  scope: rg
  params: {
    namePrefix: namePrefix
    envName: envName
    suffix: suffix
    location: location
    openaiPublicSuffix: v.aoaiPublicSuffix
    openaiZoneId: privatedns.outputs.openaiZoneId
    peSubnetId: network.outputs.peSubnetId
    modelName: modelName
    modelVersion: modelVersion
    modelDeploymentSku: modelDeploymentSku
    modelCapacity: modelCapacity
    apimExposedModelName: apimExposedModelName
    raiPolicyName: raiPolicyName
    deployMiniModel: deployMiniModel
    miniModelName: miniModelName
    miniModelVersion: miniModelVersion
    miniModelDeploymentSku: miniModelDeploymentSku
    miniModelCapacity: miniModelCapacity
    miniExposedModelName: miniExposedModelName
    miniRaiPolicyName: raiPolicyName
  }
}

module foundry 'modules/foundry.bicep' = if (deployFoundry) {
  name: 'foundry'
  scope: rg
  params: {
    namePrefix: namePrefix
    envName: envName
    suffix: suffix
    location: location
    openaiPublicSuffix: v.aoaiPublicSuffix
    openaiZoneId: privatedns.outputs.openaiZoneId
    cognitiveZoneId: privatedns.outputs.cognitiveZoneId
    aiZoneId: privatedns.outputs.aiZoneId
    peSubnetId: network.outputs.peSubnetId
    modelName: foundryModelName
    modelVersion: foundryModelVersion
    modelDeploymentSku: foundryModelDeploymentSku
    modelCapacity: foundryModelCapacity
    exposedModelName: foundryExposedModelName
    raiPolicyName: raiPolicyName
    deployMiniModel: deployMiniModel
    miniModelName: miniModelName
    miniModelVersion: miniModelVersion
    miniModelDeploymentSku: miniModelDeploymentSku
    miniModelCapacity: miniModelCapacity
    miniExposedModelName: miniExposedModelName
    miniRaiPolicyName: raiPolicyName
  }
}

// Secondary Foundry accounts (one per extra region) for the backend pool. Same model + mini
// deployment names/versions as the primary so auto-routing and explicit model calls work against
// any pool member. PEs land in the primary VNet's PE subnet (cross-region PE is supported); the
// shared private DNS zones get one A record per account (customSubDomainName is unique per name).
module foundryRegional 'modules/foundry.bicep' = [for (region, i) in foundryRegions: if (deployFoundry && deployBackendPool) {
  name: 'foundry-r${i + 1}'
  scope: rg
  params: {
    namePrefix: namePrefix
    envName: envName
    suffix: suffix
    regionTag: 'r${i + 1}'
    location: region.location
    peLocation: location
    openaiPublicSuffix: v.aoaiPublicSuffix
    openaiZoneId: privatedns.outputs.openaiZoneId
    cognitiveZoneId: privatedns.outputs.cognitiveZoneId
    aiZoneId: privatedns.outputs.aiZoneId
    peSubnetId: network.outputs.peSubnetId
    modelName: foundryModelName
    modelVersion: foundryModelVersion
    modelDeploymentSku: foundryModelDeploymentSku
    modelCapacity: region.modelCapacity
    exposedModelName: foundryExposedModelName
    raiPolicyName: raiPolicyName
    deployMiniModel: deployMiniModel
    miniModelName: miniModelName
    miniModelVersion: miniModelVersion
    miniModelDeploymentSku: miniModelDeploymentSku
    miniModelCapacity: region.miniModelCapacity
    miniExposedModelName: miniExposedModelName
    miniRaiPolicyName: raiPolicyName
  }
}]

// Secondary AOAI accounts (one per extra region) for the legacy /aoai backend pool.
module aoaiRegional 'modules/aoai.bicep' = [for (region, i) in aoaiRegions: if (deployAoai && deployBackendPool) {
  name: 'aoai-r${i + 1}'
  scope: rg
  params: {
    namePrefix: namePrefix
    envName: envName
    suffix: suffix
    regionTag: 'r${i + 1}'
    location: region.location
    peLocation: location
    openaiPublicSuffix: v.aoaiPublicSuffix
    openaiZoneId: privatedns.outputs.openaiZoneId
    peSubnetId: network.outputs.peSubnetId
    modelName: modelName
    modelVersion: modelVersion
    modelDeploymentSku: modelDeploymentSku
    modelCapacity: region.modelCapacity
    apimExposedModelName: apimExposedModelName
    raiPolicyName: raiPolicyName
    deployMiniModel: deployMiniModel
    miniModelName: miniModelName
    miniModelVersion: miniModelVersion
    miniModelDeploymentSku: miniModelDeploymentSku
    miniModelCapacity: region.miniModelCapacity
    miniExposedModelName: miniExposedModelName
    miniRaiPolicyName: raiPolicyName
  }
}]

module apim 'modules/apim.bicep' = {
  name: 'apim'
  scope: rg
  params: {
    namePrefix: namePrefix
    envName: envName
    suffix: suffix
    location: location
    apimSku: apimSku
    apimPublisherEmail: apimPublisherEmail
    apimPublisherName: apimPublisherName
    apimSubnetId: network.outputs.apimSubnetId
    appInsightsId: observability.outputs.appInsightsId
    appInsightsInstrumentationKey: observability.outputs.appInsightsInstrumentationKey
    logAnalyticsId: observability.outputs.logAnalyticsId
  }
}

// The backend-id the policies target: the single Url backend by default, the Pool when >1 region.
// Unlike the old inline base-url, set-backend-service backend-id is validated to EXIST when the
// policy is applied. The Foundry policy statically references {{aoai-backend-id}} (and vice-versa)
// in its never-taken cross-route branch, so when one family is not deployed its backend-id must
// fall back to the OTHER family's existing backend to pass validation. The branch is never taken
// at runtime (it is gated on aoai-pinned-models, which is empty when AOAI is not deployed).
var foundryBackendReal = (deployBackendPool && length(foundryRegions) > 0) ? 'foundry-pool' : 'foundry'
var aoaiBackendReal = (deployBackendPool && length(aoaiRegions) > 0) ? 'aoai-pool' : 'aoai'
var foundryBackendId = deployFoundry ? foundryBackendReal : (deployAoai ? aoaiBackendReal : 'foundry')
var aoaiBackendId = deployAoai ? aoaiBackendReal : (deployFoundry ? foundryBackendReal : 'aoai')

module apimBackends 'modules/apim-backends.bicep' = {
  name: 'apim-backends'
  scope: rg
  params: {
    apimName: apim.outputs.apimName
    #disable-next-line BCP318 // guarded by deployFoundry
    foundryPrimaryUrl: deployFoundry ? foundry.outputs.foundryPrivateBaseUrl : ''
    // Direct for-expression (no ternary): empty when foundryRegions is unset. Pair foundryRegions
    // with deployFoundry + deployBackendPool, since it references the regional accounts' outputs.
    #disable-next-line BCP318 // regional outputs only present when the loop deployed
    foundryRegionalUrls: [for (region, i) in foundryRegions: foundryRegional[i].outputs.foundryPrivateBaseUrl]
    #disable-next-line BCP318 // guarded by deployAoai
    aoaiPrimaryUrl: deployAoai ? aoai.outputs.aoaiPrivateBaseUrl : ''
    #disable-next-line BCP318 // regional outputs only present when the loop deployed
    aoaiRegionalUrls: [for (region, i) in aoaiRegions: aoaiRegional[i].outputs.aoaiPrivateBaseUrl]
    enableCircuitBreaker: deployBackendPool && enableBackendCircuitBreaker
    breakerFailureCount: breakerFailureCount
    breakerInterval: breakerInterval
    breakerTripDuration: breakerTripDuration
    poolStrategy: backendPoolStrategy
  }
}

module apimNamedValues 'modules/apim-named-values.bicep' = {
  name: 'apim-named-values'
  scope: rg
  params: {
    apimName: apim.outputs.apimName
    entraOpenIdConfigUrl: entraOpenIdConfigUrl
    apiAppIdUri: apiAppIdUri
    apiAudience: apiAudience
    requiredScope: requiredScope
    #disable-next-line BCP318 // guarded by deployAoai; '' when the module is not deployed
    aoaiPrivateBaseUrl: deployAoai ? aoai.outputs.aoaiPrivateBaseUrl : ''
    aoaiAudience: v.aoaiAudience
    #disable-next-line BCP318 // guarded by deployFoundry; '' when the module is not deployed
    foundryPrivateBaseUrl: deployFoundry ? foundry.outputs.foundryPrivateBaseUrl : ''
    foundryAudience: v.foundryAudience
    aoaiPinnedModels: aoaiPinnedModels
    jwtCallsPerMinute: jwtDefaultCallsPerMinute
    jwtTokensPerMinute: jwtDefaultTokensPerMinute
    jwtMonthlyCallQuota: jwtDefaultMonthlyCallQuota
    autoRouteSentinel: autoRouteSentinel
    autoRouteMiniDeployment: miniExposedModelName
    autoRouteFullDeployment: foundryExposedModelName
    autoRouteLengthThreshold: autoRouteLengthThreshold
    autoRouteAmbiguousBand: autoRouteAmbiguousBand
    autoRouteClassifierEnabled: autoRouteClassifierEnabled
    autoRouteClassifierDeployment: miniExposedModelName
    foundryBackendId: foundryBackendId
    aoaiBackendId: aoaiBackendId
  }
}

module apimFoundryApi 'modules/apim-foundry-api.bicep' = if (deployFoundry) {
  name: 'apim-foundry-api'
  scope: rg
  params: {
    apimName: apim.outputs.apimName
    #disable-next-line BCP318 // guarded by the module's own if (deployFoundry)
    foundryPrivateBaseUrl: deployFoundry ? foundry.outputs.foundryPrivateBaseUrl : ''
    authMode: authMode
    namedValueIds: apimNamedValues.outputs.namedValueIds
  }
  // The Foundry API uses path 'openai'. On environments upgraded from an earlier layout the
  // AOAI API may still occupy 'openai' before it is re-pathed to 'aoai'; deploy AOAI first so
  // 'openai' is free, avoiding "Cannot create API ... with the same Path" collisions.
  dependsOn: [
    apimAoaiApi
    apimBackends
  ]
}

module apimAoaiApi 'modules/apim-aoai-api.bicep' = if (deployAoai) {
  name: 'apim-aoai-api'
  scope: rg
  params: {
    apimName: apim.outputs.apimName
    #disable-next-line BCP318 // guarded by the module's own if (deployAoai)
    aoaiPrivateBaseUrl: deployAoai ? aoai.outputs.aoaiPrivateBaseUrl : ''
    authMode: authMode
    namedValueIds: apimNamedValues.outputs.namedValueIds
  }
  dependsOn: [
    apimBackends
  ]
}

// Dedicated discovery API (#61): GET /discovery/v1/models on its own API +
// 'byok-discovery' product. Standard tier subscriptions (byok-standard / byok-power)
// are NOT scoped to this API, so dev1/dev2 keys cannot list models. The CI smoke
// runner uses a 'smoke' subscription scoped to byok-discovery. Skipped in jwt mode
// (no APIM subscriptions exist to gate it).
module apimDiscoveryApi 'modules/apim-discovery-api.bicep' = if (authMode == 'subscriptionKey' && deployFoundry) {
  name: 'apim-discovery-api'
  scope: rg
  params: {
    apimName: apim.outputs.apimName
    namedValueIds: apimNamedValues.outputs.namedValueIds
  }
  dependsOn: [
    apimBackends
  ]
}

module apimProducts 'modules/apim-products.bicep' = if (authMode == 'subscriptionKey' && deployTestSubscriptions) {
  name: 'apim-products'
  scope: rg
  params: {
    apimName: apim.outputs.apimName
    productTiers: productTiers
    apiNames: concat(
      deployFoundry ? [ 'copilot-byok-foundry' ] : [],
      deployAoai ? [ 'copilot-byok-aoai' ] : []
    )
    // Only declare the byok-discovery product when its API is actually deployed.
    discoveryApiName: (authMode == 'subscriptionKey' && deployFoundry) ? 'copilot-byok-discovery' : ''
  }
  // Products link the APIs, so order after the API modules exist.
  dependsOn: [
    apimFoundryApi
    apimAoaiApi
    apimDiscoveryApi
  ]
}

module apimSubscriptions 'modules/apim-subscriptions.bicep' = if (authMode == 'subscriptionKey' && deployTestSubscriptions) {
  name: 'apim-subscriptions'
  scope: rg
  params: {
    apimName: apim.outputs.apimName
    subscriptions: testSubscriptions
  }
  // Order after the products so each subscription's product scope binds to an existing product.
  dependsOn: [
    apimProducts
  ]
}

// The APIM managed identity needs the OpenAI User role on EVERY backend account it calls.
// Enabling the multi-region pool therefore forces MI RBAC on (primary + all regional members),
// otherwise a regional member silently returns 401/403 and poisons the pool.
module rbac 'modules/rbac.bicep' = if (assignAoaiRbac || deployBackendPool || !empty(playgroundPrincipalIds)) {
  name: 'rbac'
  scope: rg
  params: {
    #disable-next-line BCP318 // guarded by deployAoai; '' when the module is not deployed
    aoaiAccountName: deployAoai ? aoai.outputs.aoaiAccountName : ''
    #disable-next-line BCP318 // guarded by deployFoundry; '' when the module is not deployed
    foundryAccountName: deployFoundry ? foundry.outputs.foundryAccountName : ''
    assignAoai: deployAoai
    assignFoundry: deployFoundry
    assignApimMi: assignAoaiRbac || deployBackendPool
    #disable-next-line BCP318 // regional outputs only present when those loops deployed
    additionalFoundryAccountNames: [for (region, i) in foundryRegions: foundryRegional[i].outputs.foundryAccountName]
    #disable-next-line BCP318
    additionalAoaiAccountNames: [for (region, i) in aoaiRegions: aoaiRegional[i].outputs.aoaiAccountName]
    playgroundPrincipalIds: playgroundPrincipalIds
    playgroundPrincipalType: playgroundPrincipalType
    apimPrincipalId: apim.outputs.apimPrincipalId
    deployerPrincipalId: deployerPrincipalId
  }
}

module testvm 'modules/testvm.bicep' = if (effectiveDeployTestVm) {
  name: 'testvm'
  scope: rg
  params: {
    namePrefix: namePrefix
    envName: envName
    suffix: suffix
    location: location
    vmSubnetId: network.outputs.vmSubnetId
    adminUsername: testVmAdminUsername
    adminPassword: testVmAdminPassword
  }
}

module apimPrivateDns 'modules/apim-private-dns.bicep' = if (deployApimPrivateDns) {
  name: 'apim-private-dns'
  scope: rg
  params: {
    apimDnsZone: v.apimDnsZone
    apimGatewayHost: apim.outputs.apimGatewayHost
    apimPrivateIp: apim.outputs.apimPrivateIp
    vnetId: network.outputs.vnetId
    suffix: suffix
  }
}

// --------------------------------------------------------------------------------------------
// Self-hosted GitHub Actions runner (issue #57 phase 1). Only deployed when deployGhRunner=true;
// otherwise the runner subnet, env, job, UAMI and RBAC are all absent and a re-deploy with the
// flag off removes them idempotently. The ACA env reads its LAW customer ID + shared key
// directly inside the gh-runner module so the secret never crosses a module boundary.
// --------------------------------------------------------------------------------------------

module ghRunner 'modules/gh-runner.bicep' = if (deployGhRunner) {
  name: 'gh-runner'
  scope: rg
  params: {
    namePrefix: namePrefix
    envName: envName
    suffix: suffix
    location: location
    runnerSubnetId: network.outputs.runnerSubnetId
    logAnalyticsName: observability.outputs.logAnalyticsName
    runnerImage: ghRunnerImage
    ghRepository: ghRepository
    ghFicEnvSubjects: ghRunnerFicEnvSubjects
    ghRunnerPat: ghRunnerPat
    ghRunnerEventImage: ghRunnerEventImage
    ghRunnerLabels: ghRunnerLabels
    ghMaxRunners: ghMaxRunners
  }
}

module ghRunnerRbac 'modules/runner-rbac.bicep' = if (deployGhRunner) {
  name: 'gh-runner-rbac'
  scope: rg
  params: {
    #disable-next-line BCP318 // guarded by the module's own if (deployGhRunner)
    runnerPrincipalId: deployGhRunner ? ghRunner.outputs.uamiPrincipalId : ''
    #disable-next-line BCP318 // guarded by deployFoundry
    foundryAccountName: deployFoundry ? foundry.outputs.foundryAccountName : ''
    #disable-next-line BCP318 // guarded by deployAoai
    aoaiAccountName: deployAoai ? aoai.outputs.aoaiAccountName : ''
    apimName: apim.outputs.apimName
    logAnalyticsName: observability.outputs.logAnalyticsName
  }
}

output resourceGroup string = rg.name
output apimName string = apim.outputs.apimName
output apimGatewayUrl string = apim.outputs.apimGatewayUrl
#disable-next-line BCP318 // guarded by deployAoai
output aoaiAccountName string = deployAoai ? aoai.outputs.aoaiAccountName : ''
#disable-next-line BCP318 // guarded by deployAoai
output aoaiPrivateFqdn string = deployAoai ? aoai.outputs.aoaiPrivateFqdn : ''
#disable-next-line BCP318 // guarded by deployFoundry
output foundryAccountName string = deployFoundry ? foundry.outputs.foundryAccountName : ''
#disable-next-line BCP318 // guarded by deployFoundry
output foundryPrivateFqdn string = deployFoundry ? foundry.outputs.foundryPrivateFqdn : ''
output vnetName string = network.outputs.vnetName
output appInsightsName string = observability.outputs.appInsightsName
output entraOpenIdConfigUrl string = entraOpenIdConfigUrl

@description('Test APIM subscription IDs created in subscriptionKey mode. Fetch each key: az apim subscription show -g <rg> --service-name <apim> --sid <id> --query primaryKey -o tsv')
#disable-next-line BCP318 // guarded by the same condition as the module's if()
output testSubscriptionIds array = (authMode == 'subscriptionKey' && deployTestSubscriptions) ? apimSubscriptions.outputs.subscriptionIds : []

@description('Self-hosted GitHub Actions runner UAMI name (empty when deployGhRunner=false). Used by phase 2 (#53) to attach federated credentials.')
#disable-next-line BCP318 // guarded by deployGhRunner
output ghRunnerUamiName string = deployGhRunner ? ghRunner.outputs.uamiName : ''

@description('Self-hosted GitHub Actions runner UAMI client ID (empty when deployGhRunner=false). Used by GitHub Actions OIDC login.')
#disable-next-line BCP318 // guarded by deployGhRunner
output ghRunnerUamiClientId string = deployGhRunner ? ghRunner.outputs.uamiClientId : ''

@description('Self-hosted GitHub Actions runner UAMI principal ID (empty when deployGhRunner=false).')
#disable-next-line BCP318 // guarded by deployGhRunner
output ghRunnerUamiPrincipalId string = deployGhRunner ? ghRunner.outputs.uamiPrincipalId : ''

@description('ACA Job name hosting the self-hosted runner (empty when deployGhRunner=false). Phase 3 (#58) bootstrap registers replicas via this job.')
#disable-next-line BCP318 // guarded by deployGhRunner
output ghRunnerJobName string = deployGhRunner ? ghRunner.outputs.jobName : ''

@description('Federated credential subjects bound to the runner UAMI (issue #53). Each entry has the form `repo:<owner>/<repo>:environment:<env>` and is the value GitHub Actions OIDC tokens must carry to log in as the runner UAMI. Empty when deployGhRunner=false or ghRunnerFicEnvSubjects=[].')
#disable-next-line BCP318 // guarded by deployGhRunner
output ghRunnerFicSubjects array = deployGhRunner ? ghRunner.outputs.ghFicSubjects : []

@description('Trigger type the runner Job is currently configured for. `Event` when ghRunnerPat is set (KEDA-driven ephemeral runner, #58 phase 3 active). `Manual` when empty (#57 placeholder). Empty string when deployGhRunner=false.')
#disable-next-line BCP318 // guarded by deployGhRunner
output ghRunnerTriggerType string = deployGhRunner ? ghRunner.outputs.ghRunnerTriggerType : ''

@description('Runner label string applied at registration. Workflows must `runs-on:` this exact value (or a subset). Empty when deployGhRunner=false.')
#disable-next-line BCP318 // guarded by deployGhRunner
output ghRunnerLabels string = deployGhRunner ? ghRunner.outputs.ghRunnerLabels : ''
