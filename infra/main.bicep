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

@description('Deploy the in-VNet subkey proxy: an nginx Azure Container Instance (in snet-aci) that translates "Authorization: Bearer <apim-subscription-key>" into the api-key header and forwards to the private /openai route, so OpenAI-compatible IDE clients (e.g. JetBrains AI Assistant) that can ONLY send a Bearer token use their APIM subscription key (no expiring Entra token). Reachable only in-VNet. Adds snet-aci (/27). Default false.')
param deployFoundrySubkeyProxy bool = false

@description('Container image for the subkey proxy. The standard Docker Hub nginx mirrored on MCR (reachable under restricted egress). Override to pin a specific tag/digest.')
param subkeyProxyImage string = 'mcr.microsoft.com/mirror/docker/library/nginx:1.25'

// ---------------------------------------------------------------------------------------------
// Commercial Foundry route (opt-in; PARALLEL to the default /openai Gov/private route).
// Adds a SEPARATE APIM API (default path /openai-commercial) that reaches a COMMERCIAL Microsoft
// Foundry endpoint over the public internet (egress leaves the Gov VNet via the NAT gateway).
// The existing /openai route is left completely untouched. Everything below is a placeholder
// until the operator supplies the real commercial endpoint + auth + egress ranges.
// ---------------------------------------------------------------------------------------------

@description('Deploy the parallel Commercial Foundry route (new APIM API + foundry-commercial backend + foundry-commercial-* named values + APIM egress allow rule + product linkage). Default false = nothing commercial is created and /openai is the only Foundry path. Opt in AND supply foundryCommercialBaseUrl (+ auth + egress) to activate.')
param deployFoundryCommercial bool = false

@description('<COMMERCIAL_FOUNDRY_BASE_URL> Public base URL of the Commercial Foundry endpoint (e.g. https://<account>.openai.azure.com or https://<account>.cognitiveservices.azure.com). Required when deployFoundryCommercial=true.')
param foundryCommercialBaseUrl string = ''

@description('<COMMERCIAL_API_NAME> APIM API name for the commercial route. Must be unique and distinct from copilot-byok-foundry.')
param foundryCommercialApiName string = 'copilot-byok-foundry-commercial'

@description('<COMMERCIAL_API_PATH> APIM path segment for the commercial route. Must NOT collide with the default route path "openai". Clients set COPILOT_PROVIDER_BASE_URL=https://<gateway>/<this>.')
param foundryCommercialApiPath string = 'openai-commercial'

@description('<COMMERCIAL_API_VERSION> api-version the commercial route injects on deployment-scoped paths. Confirm it supports the commercial deployment(s) = <COMMERCIAL_DEPLOYMENT_NAMES>.')
param foundryCommercialApiVersion string = '2025-04-01-preview'

@description('<COMMERCIAL_BACKEND_AUTH_MODE> How APIM authenticates to the COMMERCIAL backend (independent of caller auth; the caller token is NEVER forwarded). servicePrincipalFederated (SECRETLESS DEFAULT) = workload identity federation: APIM presents its own Gov MI token (audience api://AzureADTokenExchange) to the commercial tenant as an OAuth2 client_assertion and exchanges it for a backend token (the commercial SP needs a federated identity credential; NO secret stored); servicePrincipal = same flow but authenticated with the secret foundryCommercialClientSecret (fallback if cross-cloud federation is unavailable); apikey = send foundryCommercialApiKey in the api-key header; managedIdentity = mint an MI token for foundryCommercialAudience (same-tenant only — a Gov MI token is rejected cross-tenant with TenantAccessDenied).')
@allowed([ 'servicePrincipalFederated', 'servicePrincipal', 'apikey', 'managedIdentity' ])
param foundryCommercialAuthMode string = 'servicePrincipalFederated'

@description('<COMMERCIAL_FOUNDRY_AUDIENCE> MI token audience for the commercial backend (managedIdentity mode only). Empty otherwise.')
param foundryCommercialAudience string = ''

@description('SECRET. Commercial Foundry API key (apikey mode only). Supply via a secure pipeline variable; do NOT commit. Stored as a secret APIM named value foundry-commercial-api-key.')
@secure()
param foundryCommercialApiKey string = ''

// Commercial-tenant service principal (client-credentials) backend auth (servicePrincipal mode).
// APIM mints a bearer token for foundryCommercialTokenResource from the COMMERCIAL tenant authority
// and attaches it to the backend call. The Gov APIM managed identity is NOT used (cross-tenant MI
// is rejected). The token endpoint (login.microsoftonline.com) is public-internet from Gov, so it
// must ALSO be in foundryCommercialEgressDestinations.
@description('<COMMERCIAL_TENANT_ID> Commercial tenant GUID whose authority mints the backend token (servicePrincipal mode). Empty by default; in CI it is supplied from the COMMERCIAL_TENANT_ID repo Variable via param-file substitution so no tenant ID is committed (same posture as entraTenantId).')
param foundryCommercialTenantId string = ''

@description('<COMMERCIAL_CLIENT_ID> App (client) ID of the COMMERCIAL-tenant service principal (servicePrincipal mode). Grant it a data-plane role (e.g. Cognitive Services OpenAI User) on the commercial Foundry account.')
param foundryCommercialClientId string = ''

@description('SECRET <COMMERCIAL_CLIENT_SECRET_SECRET_REF>. Client secret of the commercial-tenant service principal (servicePrincipal mode). Supply via a secure pipeline variable or a Key Vault-backed named value; do NOT commit. Stored as the secret named value foundry-commercial-client-secret.')
@secure()
param foundryCommercialClientSecret string = ''

@description('<COMMERCIAL_TOKEN_RESOURCE> Resource the commercial backend token is minted for (servicePrincipal mode); the policy appends /.default for the scope. Default https://cognitiveservices.azure.com.')
param foundryCommercialTokenResource string = 'https://cognitiveservices.azure.com'

@description('Commercial AAD authority host for the token endpoint (servicePrincipal mode). Default login.microsoftonline.com (Commercial cloud). Token URL = https://<host>/<tenantId>/oauth2/v2.0/token.')
#disable-next-line no-hardcoded-env-urls // intentionally the COMMERCIAL login host (Gov->Commercial cross-tenant token); environment() would wrongly return the Gov host.
param foundryCommercialAuthorityHost string = 'login.microsoftonline.com'

@description('<COMMERCIAL_DESTINATION_CIDRS_OR_SERVICE_TAGS> Destination IPv4 CIDRs (NSG cannot match FQDNs) the APIM subnet may reach outbound on 443 for the commercial route, added above the default-deny when restrictApimEgress=true. In servicePrincipal mode this MUST include BOTH (a) the commercial Foundry data endpoint ranges AND (b) the commercial AAD token endpoint ranges (login.microsoftonline.com — the Gov AzureActiveDirectory service tag does NOT cover commercial AAD). Resolve the hosts to their public ranges (or use the published AzureCloud AzureActiveDirectory + CognitiveServices ranges). Empty => the commercial route is unreachable while egress is locked down.')
param foundryCommercialEgressDestinations array = []

@description('Link the commercial API into the existing subscriptionKey product tiers (byok-standard / byok-power) so a tier-scoped developer key works on BOTH /openai and the commercial path. Default true. Only applies when deployFoundryCommercial=true && authMode=subscriptionKey.')
param addCommercialToProductTiers bool = true

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

@description('Deploy an additional standalone model on the primary Foundry account, independent of the mini/auto-routing tier. Used to host a Commercial-only model (e.g. gpt-5-mini) that the cross-cloud commercial route exercises. Off by default; enable only where the region hosts the model + SKU (e.g. the commercial pilot).')
param deployExtraModel bool = false

@description('Extra model name (e.g. gpt-5-mini). Required when deployExtraModel=true.')
param extraModelName string = ''

@description('Extra model version. Confirm the exact version available in your region before deploying.')
param extraModelVersion string = ''

@description('Extra deployment SKU (capacity unit type).')
@allowed([
  'Standard'
  'GlobalStandard'
  'DataZoneStandard'
])
param extraModelDeploymentSku string = 'GlobalStandard'

@description('Extra deployment capacity (TPM units of 1000).')
param extraModelCapacity int = 50

@description('Extra exposed/deployment name (the value callers put in the request body "model" to hit this deployment).')
param extraExposedModelName string = ''

@description('Comma-separated allow-list of sentinel model values that opt a request in to tiered auto-routing (case-insensitive, trimmed). Explicit model names bypass routing. Default supports both `auto` (CLI) and `byok-auto` (VS Code, where `auto` is a reserved model id in the model picker).')
param autoRouteSentinel string = 'auto,byok-auto'

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

@description('Test developer APIM subscriptions to create (subscriptionKey mode). Each { name, product } scopes a key to a rate-limit product tier and is stamped onto telemetry as the developer. product must match a productTiers name. Model listing (GET /v1/models) is served by the foundry inference API to any valid inference key, so no separate discovery subscription is needed.')
param testSubscriptions array = [
  {
    name: 'dev1'
    product: 'byok-standard'
  }
  {
    name: 'dev2'
    product: 'byok-power'
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

@description('Admin password for the test VM. Optional: with Entra ID login (default) leave empty and a random password is generated. Only set this for a break-glass local admin login. Passed at deploy time, never stored.')
@secure()
param testVmAdminPassword string = ''

@description('Principal (object) ID granted "Virtual Machine Administrator Login" on the test VM, enabling Entra ID sign-in (no local password). Empty => defaults to registerAdminGroupId (BYOK Admins).')
param testVmAadLoginPrincipalId string = ''

@description('Principal type for testVmAadLoginPrincipalId.')
@allowed([ 'User', 'Group', 'ServicePrincipal' ])
param testVmAadLoginPrincipalType string = 'Group'

@description('Deploy a NAT Gateway attachment on the test-VM subnet for deterministic, controlled egress (replaces the deprecated Azure default-outbound). Only takes effect when deployTestStack=true && deployTestVm=true. ~$32/mo + data. Default true so the egress-restricted VM subnet has a working outbound path; set false only for quick dev/test where the NAT cost is unwanted. NOTE: the NAT Gateway resource ITSELF is still deployed when restrictApimEgress=true (independent of this flag) because APIM Internal-mode subnet uses it for its allowed egress path.')
param deployNatGateway bool = true

@description('Apply an egress-allowlist NSG to the test-VM subnet (GitHub/npm/nodejs/Azure-management only; deny the rest). A discovery tool to observe exactly what the Copilot CLI install/runtime needs. Only takes effect when deployTestStack=true && deployTestVm=true. Default true (default-deny posture, matching restrictApimEgress). Pair with deployNatGateway so allowed traffic has an egress path.')
param restrictVmEgress bool = true

@description('Add a default-deny outbound allowlist to the APIM subnet NSG: permit only the Azure-internal service-tag dependencies APIM (Internal VNet mode) MUST reach (Entra/Storage/SQL/Key Vault/Azure Monitor) plus intra-VNet, then deny the rest of the internet. Default true (recommended default-deny posture); the APIM subnet becomes private and gets a NAT gateway for the allowed egress path. Independent of deployTestStack — the snet-apim defaultOutboundAccess flag this sets is IMMUTABLE post-create, so flipping false on an existing deployment requires recreating snet-apim (and therefore APIM). Set false only on a fresh deploy where the NAT cost or the private-subnet choice is unwanted.')
param restrictApimEgress bool = true

@description('Pin `defaultOutboundAccess: false` explicitly on the subnets that otherwise omit it (snet-pe, snet-dns-in, AzureBastionSubnet, GatewaySubnet, snet-cae-register). Set true for an EXISTING environment whose subnets were already created with defaultOutboundAccess=false (Azure secure-by-default) — otherwise the template omits the immutable property, Azure computes the default (true), and a re-PUT tries to recreate those in-use subnets (Bastion/PE/DNS), which fails. Leave false (default) for environments whose subnets are still on legacy implicit outbound (true) so the omission keeps matching.')
param pinSubnetPrivateOutbound bool = false

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

@description('Apply an egress-allowlist NSG to the runner subnet (snet-runner): permit only the ACA-platform service tags the runner Job needs (ARM/Entra/Monitor/Storage/Key Vault/MCR/ACR) plus GitHub/npm-node CIDRs and intra-VNet, then deny the rest. Only takes effect when deployGhRunner=true. Default FALSE (opt-in) — the runner is production CI and a too-tight allowlist silently breaks it (e.g. the Docker Hub image pull). Supply runnerImageRegistryCidrs (or pre-mirror the runner image to the ACR) before enabling; #94 pre-bakes the image to ACR to remove that need. The desired end-state for FQDN egress control is Azure Firewall.')
param restrictRunnerEgress bool = false

@description('IPv4 CIDRs for the runner image registry (default myoung34/github-runner on Docker Hub), allowed outbound when restrictRunnerEgress=true. Default empty `[]` (no rule) — supply the current Docker Hub / Cloudflare ranges OR pre-mirror the image into the deployment ACR (covered by the AzureContainerRegistry tag) and leave this empty. INTERIM knob: #94 pre-bakes the runner image to ACR, removing the need for this. NSG is IP-based and cannot match FQDNs, so these will drift; the end-state is Azure Firewall application rules.')
param runnerImageRegistryCidrs array = []

@description('PROTOTYPE (ships dormant). Route snet-runner egress through an Azure Firewall whose application rules allowlist GitHub/Azure FQDNs — the correct primitive for the GitHub Actions control plane that restrictRunnerEgress (NSG) cannot express (an NSG IP allowlist takes the runner offline; see docs/github-egress-allowlist.md). Only takes effect when deployGhRunner=true. Default FALSE: the firewall has a real fixed cost — Basic ~$288/mo (commercial) / ~$361/mo (gov) per pilot, Standard ~$913/$1,141; data-processed is a few $/mo for CI. Pricing pulled 2026-06-24 (see infra/modules/firewall.bicep). When true, adds AzureFirewallSubnet + AzureFirewallManagementSubnet (/26 each), routes snet-runner 0.0.0.0/0 to the firewall, and drops the runner NAT gateway.')
param deployRunnerFirewall bool = false

@allowed([ 'Basic', 'Standard' ])
@description('Azure Firewall SKU tier for the runner egress firewall (when deployRunnerFirewall=true). Basic is the cheapest tier that supports FQDN application rules and is sufficient for CI throughput (<250 Mbps); it MANDATES the management subnet + a second public IP (both auto-provisioned). Standard (~3x cost) adds throughput/threat-intel. See the cost table in infra/modules/firewall.bicep.')
param runnerFirewallTier string = 'Basic'

@description('Extra destination FQDNs to allow from snet-runner through the firewall, appended to the built-in GitHub/Azure allowlist in infra/modules/firewall.bicep. Use to add env-specific endpoints found during validation. Only used when deployRunnerFirewall=true.')
param runnerFirewallAdditionalFqdns array = []

@description('Container image the runner job runs. Phase 1 default is a placeholder so deploys succeed without GitHub credentials. Phase 3 (#58) will swap to the real actions-runner image.')
param ghRunnerImage string = 'mcr.microsoft.com/azure-cli:latest'

@description('GitHub repository (`<owner>/<repo>`) used to build OIDC federated-credential subjects for the runner UAMI. Both clouds share the same issuer URL; only the repo + env subject changes.')
param ghRepository string = 'gwexler_microsoft/copilot-cli-byok-azure'

@description('GitHub Environment names whose OIDC tokens may federate to THIS runner UAMI (subject `repo:<ghRepository>:environment:<name>`). Defaults to this env only; add sibling envs to share a runner pool. Empty array disables federation.')
param ghRunnerFicEnvSubjects array = [envName]

@description('GitHub PAT (#58 phase 3). When provided, the runner Job flips from Phase 1 manual placeholder to KEDA-scaled, event-driven self-hosted runner (myoung34/github-runner image). Stored ONLY as an ACA Job secret named `gh-pat`. Leave empty to keep the Phase 1 placeholder behavior. Prefer `ghRunnerSecretFromKeyVault` (Key Vault reference) over this inline param for production. PAT scopes: classic `repo` OR fine-grained with `Actions: read+write` and `Administration: read+write`.')
@secure()
param ghRunnerPat string = ''

@description('KV-backed runner-secret toggle (#58). When true (and deployGhRunner=true), the runner Job sources its auth secret from the dedicated runner Key Vault (runner-kv) via a Key Vault reference resolved by the runner UAMI: `gh-app-key` in app mode, `gh-pat` in pat mode. This keeps the secret out of azd state. BOOTSTRAP IS TWO-PHASE: (1) provision with this false to create the empty vault + placeholder Job; (2) write the secret once (`az keyvault secret set --vault-name <ghRunnerKeyVaultName> --name <gh-app-key|gh-pat> --value <...>` or scripts/setup-gh-runner.*); (3) provision again with this true so the Job picks up the KV reference. Rotations thereafter are a single `az keyvault secret set` — no re-provision, identical in both clouds.')
param ghRunnerSecretFromKeyVault bool = false

@description('Runner auth method (#58): `app` (GitHub App — PRIMARY/recommended; mints short-lived installation tokens, nothing to rotate, 15k/hr API limit) or `pat` (Personal Access Token — supported opt-in fallback). App mode needs ghAppId + ghAppInstallationId + a private key (Key Vault via ghRunnerSecretFromKeyVault, or inline ghAppPrivateKey). PAT mode needs ghRunnerPat. Either mode stays a Phase 1 Manual placeholder until its credentials are present.')
@allowed([ 'app', 'pat' ])
param ghRunnerAuthMode string = 'app'

@description('GitHub App ID (numeric string, NON-secret). Required for app mode. From the App settings page ("App ID").')
param ghAppId string = ''

@description('GitHub App installation ID (numeric string, NON-secret). Required for app mode. From the installation settings URL (.../installations/<id>) or `gh api /repos/<owner>/<repo>/installation --jq .id`.')
param ghAppInstallationId string = ''

@description('GitHub App private key PEM, inline @secure() (app mode, dev path — injected from a repo secret on each nightly rebuild). Prefer the Key Vault path (ghRunnerSecretFromKeyVault=true) for long-lived pilots. Ignored when ghRunnerAuthMode=pat.')
@secure()
param ghAppPrivateKey string = ''

@description('Container image for the KEDA-driven runner (when ghRunnerPat is set). Pin to a SHA digest in production; `:latest` is fine for the experimental pilots. IGNORED when useAcrRunnerImage=true (#94): the runner then pulls the pre-baked image from the shared ACR instead.')
param ghRunnerEventImage string = 'myoung34/github-runner:latest'

@description('Pull the runner image from the shared ACR (pre-baked by #94: infra/runner-image + build-runner-image.yml) instead of the public myoung34 image. Default FALSE (opt-in, ships dormant like restrictRunnerEgress) so live runners are untouched. TWO-PHASE: (1) build the image to ACR via the build-runner-image workflow; (2) flip this true. Provisioning the shared ACR is auto-enabled when this is true. Once on, the runner pulls only `<acr>/github-runner:<runnerImageTag>` — covered by the AzureContainerRegistry + Storage service tags — so restrictRunnerEgress=true works with no CIDR params.')
param useAcrRunnerImage bool = false

@description('Tag of the pre-baked runner image in the shared ACR (#94). Default `latest`; pin to an immutable tag/digest in production and bump to roll a new image. Only used when useAcrRunnerImage=true.')
param runnerImageTag string = 'latest'

@description('Comma-separated runner labels applied at registration. Workflows must `runs-on:` this exact value (or a subset). Default = envName so e.g. `runs-on: comm-pilot` reaches this env\'s runner pool.')
param ghRunnerLabels string = envName

@description('Max concurrent KEDA-driven runner replicas. Each replica = one workflow job, then the container exits (ephemeral). Higher = more burst parallelism, more Azure billing during bursts.')
param ghMaxRunners int = 5

// ---------------------------------------------------------------------------------------------
// Self-serve developer onboarding "register" app (issue #64 / #66 + #68). Deploys an EXTERNAL
// ACA env + Container App fronted by Entra Easy Auth, running as a least-privilege UAMI whose
// custom role can only manage APIM subscriptions (CRUD + key actions) and read products. Control
// -plane only (no VNet injection), so it sidesteps the internal-ingress L7 bug. Default false.
// ---------------------------------------------------------------------------------------------

@description('Deploy the self-serve register app stack (UAMI + custom APIM-subscription role + external ACA env + Container App + optional Easy Auth). Default false. Set true to add it idempotently.')
param deployRegisterApp bool = false

@description('Container image the register app runs. Default is the .NET ASP.NET sample (listens on 8080) so the first provision yields a healthy revision before the Blazor image is built; azd deploy swaps in the real image.')
param registerAppImage string = 'mcr.microsoft.com/dotnet/samples:aspnetapp'

@description('Entra app registration (client) ID for the register app Easy Auth. Leave empty to provision hosting WITHOUT auth (placeholder bring-up before the app reg exists); set it to turn on the login redirect.')
param registerEasyAuthClientId string = ''

@description('Entra app registration client secret for the register app Easy Auth. Required only when registerEasyAuthClientId is set. Stored as a Container App secret. Prefer registerEasyAuthSecretKeyVaultUri (Key Vault reference) over passing the secret inline; this param is the back-compat fallback.')
@secure()
param registerEasyAuthClientSecret string = ''

@description('Key Vault secret URI holding the register app Easy Auth client secret (e.g. https://<kv>.vault.azure.net/secrets/register-easyauth-secret). Written by scripts/setup-register-entra.*; the Container App references it via managed identity so the secret never flows through a Bicep param. Takes precedence over registerEasyAuthClientSecret when set.')
#disable-next-line secure-secrets-in-params // this is a Key Vault reference URI, not the secret value
param registerEasyAuthSecretKeyVaultUri string = ''

@description('Entra security group object ID whose members get the register app admin/offboard (revoke) surface. Empty disables the admin surface. Tenant-specific; set in the commercial/gov param files for the matching tenant.')
param registerAdminGroupId string = ''

@description('Entra security group object ID whose members get the byok-power tier instead of the default byok-standard. Empty => everyone defaults to byok-standard. Tenant-specific; set in the matching-tenant param file.')
param registerPowerGroupId string = ''

@description('Make the register app PRIVATE by default: set the ACA environment public network access to Disabled and reach it through a Private Endpoint in snet-pe with a privatelink.<region>.azurecontainerapps.* zone. The app stays external (so it registers on the env public envoy) but is only reachable in-VNet (P2S VPN / test VM). Set false to keep public ingress (e.g. a laptop demo not on the VNet).')
param registerPrivateNetworking bool = true

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
    acaDnsSuffix: 'azurecontainerapps.io'
    vaultDnsZone: 'privatelink.vaultcore.azure.net'
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
    acaDnsSuffix: 'azurecontainerapps.us'
    vaultDnsZone: 'privatelink.vaultcore.usgovcloudapi.net'
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
    apimCommercialEgressDestinations: deployFoundryCommercial ? foundryCommercialEgressDestinations : []
    deployGhRunner: deployGhRunner
    runnerSubnetCidr: runnerSubnetCidr
    restrictRunnerEgress: restrictRunnerEgress
    runnerImageRegistryCidrs: runnerImageRegistryCidrs
    deployRunnerFirewall: deployRunnerFirewall
    deployAciSubnet: deployFoundrySubkeyProxy
    deployRegisterEnvSubnet: deployRegisterApp && registerVnetIntegrated
    pinSubnetPrivateOutbound: pinSubnetPrivateOutbound
  }
}

// Runner egress firewall (PROTOTYPE, ships dormant — deployRunnerFirewall defaults false).
// FQDN application-rule allowlist for snet-runner; the correct egress control for the
// GitHub Actions control plane that the NSG (restrictRunnerEgress) cannot express. See
// infra/modules/firewall.bicep for the cost table and the allowlisted FQDNs.
module firewall 'modules/firewall.bicep' = if (deployGhRunner && deployRunnerFirewall) {
  name: 'runner-firewall'
  scope: rg
  params: {
    namePrefix: namePrefix
    envName: envName
    suffix: suffix
    location: location
    firewallSubnetId: network.outputs.firewallSubnetId
    managementSubnetId: network.outputs.firewallManagementSubnetId
    tier: runnerFirewallTier
    sourceAddresses: [ network.outputs.runnerSubnetCidr ]
    additionalFqdns: runnerFirewallAdditionalFqdns
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
    deployExtraModel: deployExtraModel
    extraModelName: extraModelName
    extraModelVersion: extraModelVersion
    extraModelDeploymentSku: extraModelDeploymentSku
    extraModelCapacity: extraModelCapacity
    extraExposedModelName: extraExposedModelName
    extraRaiPolicyName: raiPolicyName
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
    appInsightsConnectionString: observability.outputs.appInsightsConnectionString
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
    // Commercial route: single public Url backend 'foundry-commercial'. Empty when the route is off.
    foundryCommercialUrl: deployFoundryCommercial ? foundryCommercialBaseUrl : ''
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
    // Commercial route named values (always created with placeholder defaults; only meaningful
    // when deployFoundryCommercial=true). The secret api-key flows through here to a secret NV.
    // Backend-id is a literal (not apimBackends.outputs) to avoid coupling named-values to the
    // backends module, which would make the inference APIs' explicit apimBackends dependsOn
    // redundant. The foundry-commercial backend is created in apim-backends.bicep under the
    // same name when deployFoundryCommercial=true.
    foundryCommercialBaseUrl: deployFoundryCommercial ? foundryCommercialBaseUrl : ''
    foundryCommercialAudience: foundryCommercialAudience
    foundryCommercialBackendId: deployFoundryCommercial ? 'foundry-commercial' : ''
    foundryCommercialApiVersion: foundryCommercialApiVersion
    foundryCommercialAuthMode: foundryCommercialAuthMode
    foundryCommercialApiKey: foundryCommercialApiKey
    // Commercial-tenant service principal (client-credentials) backend auth. tenant-id flows
    // through always (non-secret, defaults to the confirmed commercial tenant); the secret flows to
    // a secret NV. client-id gated on deployFoundryCommercial so an off route keeps placeholders.
    foundryCommercialTenantId: foundryCommercialTenantId
    foundryCommercialClientId: deployFoundryCommercial ? foundryCommercialClientId : ''
    foundryCommercialClientSecret: foundryCommercialClientSecret
    foundryCommercialTokenResource: foundryCommercialTokenResource
    foundryCommercialAuthorityHost: foundryCommercialAuthorityHost
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

// Parallel Commercial Foundry API (path foundryCommercialApiPath, default 'openai-commercial').
// SEPARATE from the default /openai route above, which is untouched. Opt-in via
// deployFoundryCommercial. Uses the foundry-commercial backend + foundry-commercial-* named
// values + the commercial policy variants. Distinct path so there is no collision with 'openai'.
module apimFoundryCommercialApi 'modules/apim-foundry-commercial-api.bicep' = if (deployFoundryCommercial) {
  name: 'apim-foundry-commercial-api'
  scope: rg
  params: {
    apimName: apim.outputs.apimName
    foundryCommercialBaseUrl: foundryCommercialBaseUrl
    apiName: foundryCommercialApiName
    apiPath: foundryCommercialApiPath
    authMode: authMode
    namedValueIds: apimNamedValues.outputs.namedValueIds
  }
  dependsOn: [
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

// Model listing (GET /v1/models) is served by the foundry inference API's list-models
// operation to any valid inference key (model names aren't sensitive) — see
// apim-foundry-api.bicep + policies/byok-foundry-models-policy*.xml. The former dedicated
// 'copilot-byok-discovery' API + 'byok-discovery' product were consolidated away (they
// duplicated the same list); the CI smoke runner asserts /openai/v1/models with a tier key.
module apimProducts 'modules/apim-products.bicep' = if (authMode == 'subscriptionKey' && deployTestSubscriptions) {
  name: 'apim-products'
  scope: rg
  params: {
    apimName: apim.outputs.apimName
    productTiers: productTiers
    apiNames: concat(
      deployFoundry ? [ 'copilot-byok-foundry' ] : [],
      deployAoai ? [ 'copilot-byok-aoai' ] : [],
      (deployFoundryCommercial && addCommercialToProductTiers) ? [ foundryCommercialApiName ] : []
    )
  }
  // Products link the APIs, so order after the API modules exist.
  dependsOn: [
    apimFoundryApi
    apimFoundryCommercialApi
    apimAoaiApi
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
    aadLoginPrincipalId: empty(testVmAadLoginPrincipalId) ? registerAdminGroupId : testVmAadLoginPrincipalId
    aadLoginPrincipalType: testVmAadLoginPrincipalType
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

// Deterministic runner Key Vault name + PAT secret URI. Computed in the parent (single source
// of truth) so the runner Job can reference the KV secret by a string URI without depending on
// the runner-kv module (avoids a dependency cycle — see runner-kv.bicep header). The name rule
// mirrors register-kv: <=24 chars, starts with a letter, alphanumeric. `environment().suffixes.
// keyvaultDns` is cloud-correct (.vault.azure.net vs .vault.usgovcloudapi.net).
var runnerKvName = take('kvrun${replace(envName, '-', '')}${suffix}', 24)
var runnerPatSecretUri = 'https://${runnerKvName}${environment().suffixes.keyvaultDns}/secrets/gh-pat'
var runnerAppKeySecretUri = 'https://${runnerKvName}${environment().suffixes.keyvaultDns}/secrets/gh-app-key'

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
    ghRunnerAuthMode: ghRunnerAuthMode
    ghAppId: ghAppId
    ghAppInstallationId: ghAppInstallationId
    ghAppPrivateKey: ghRunnerAuthMode == 'app' ? ghAppPrivateKey : ''
    ghAppPrivateKeyKeyVaultSecretUri: (ghRunnerAuthMode == 'app' && ghRunnerSecretFromKeyVault) ? runnerAppKeySecretUri : ''
    ghRunnerPat: ghRunnerAuthMode == 'pat' ? ghRunnerPat : ''
    ghRunnerPatKeyVaultSecretUri: (ghRunnerAuthMode == 'pat' && ghRunnerSecretFromKeyVault) ? runnerPatSecretUri : ''
    ghRunnerEventImage: ghRunnerEventImage
    ghRunnerLabels: ghRunnerLabels
    ghMaxRunners: ghMaxRunners
    // #94: pull the pre-baked image from the shared ACR when opted in. Empty otherwise
    // (keeps the public myoung34 image). registerAcr is provisioned when useAcrRunnerImage
    // is true (see deploySharedAcr), so these references are safe under that guard.
    #disable-next-line BCP318 // guarded by (deployGhRunner && useAcrRunnerImage) => registerAcr deployed
    acrLoginServer: (deployGhRunner && useAcrRunnerImage) ? registerAcr.outputs.loginServer : ''
    #disable-next-line BCP318 // guarded by (deployGhRunner && useAcrRunnerImage) => registerAcr deployed
    acrName: (deployGhRunner && useAcrRunnerImage) ? registerAcr.outputs.name : ''
    runnerImageTag: runnerImageTag
  }
}

// Dedicated RBAC-mode Key Vault for the runner PAT (#58 — KV-backed rotation). Created whenever
// the runner is deployed (so the empty vault exists for the two-phase bootstrap) regardless of
// whether ghRunnerSecretFromKeyVault is on yet. The runner UAMI gets Secrets User (read) so the Job
// resolves the gh-pat reference; the deploying principal (when known) gets Secrets Officer (write)
// for the rotation helper. The vault NAME is owned here (runnerKvName) so the deterministic secret
// URI passed to the Job above stays in sync WITHOUT gh-runner depending on this module (which would
// cycle: runner-kv already depends on the runner UAMI principalId, a gh-runner output).
@description('Lock the runner Key Vault down: publicNetworkAccess=Disabled + a Private Endpoint in snet-pe (+ the privatelink.vaultcore zone). The VNet-integrated runner env resolves the gh-pat reference over the PE; secret ROTATION then must run from an in-VNet host (the test VM). Default false.')
param deployRunnerKvPrivateEndpoint bool = false

@description('VNet-integrate the register Container Apps environment (adds snet-cae-register + vnetConfiguration on the env) and lock its Key Vault to a Private Endpoint. Makes the register app internal-only with NO public vault. RECREATES the register env (immutable) -> the app FQDN changes -> update the Easy Auth redirect URI after. Default false.')
param registerVnetIntegrated bool = false

// The privatelink.vaultcore zone is shared by any locked-down vault (runner and/or register).
var vaultPrivateDnsEnabled = (deployGhRunner && deployRunnerKvPrivateEndpoint) || (deployRegisterApp && registerVnetIntegrated)

// Vault privatelink DNS zone for locked-down Key Vaults (runner and/or register).
module privatednsVault 'modules/privatedns-vault.bicep' = if (vaultPrivateDnsEnabled) {
  name: 'privatedns-vault'
  scope: rg
  params: {
    vaultDnsZoneName: v.vaultDnsZone
    vnetId: network.outputs.vnetId
    peerVnetResourceId: peerVnetResourceId
  }
}

module runnerKv 'modules/runner-kv.bicep' = if (deployGhRunner) {
  name: 'runner-kv'
  scope: rg
  params: {
    vaultName: runnerKvName
    location: location
    tenantId: entraTenantId
    #disable-next-line BCP318 // guarded by the module's own if (deployGhRunner)
    runnerUamiPrincipalId: deployGhRunner ? ghRunner.outputs.uamiPrincipalId : ''
    deployerPrincipalId: deployerPrincipalId
    privateNetworking: deployRunnerKvPrivateEndpoint
    peSubnetId: network.outputs.peSubnetId
    #disable-next-line BCP318 // privatednsVault exists whenever deployGhRunner && deployRunnerKvPrivateEndpoint (a subset of vaultPrivateDnsEnabled)
    vaultDnsZoneId: (deployGhRunner && deployRunnerKvPrivateEndpoint) ? privatednsVault.outputs.vaultZoneId : ''
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

// --------------------------------------------------------------------------------------------
// Self-serve register app (issue #64 phase M1). Only deployed when deployRegisterApp=true. The
// role module creates the UAMI + custom role + assignment scoped to APIM; the app module hosts
// the Blazor UI/API on an external ACA env behind Easy Auth, running as that UAMI. Both read
// their dependencies (APIM name, LAW name, cloud vars) from existing module outputs / cloudVars.
// --------------------------------------------------------------------------------------------

module registerRole 'modules/apim-register-role.bicep' = if (deployRegisterApp) {
  name: 'register-role'
  scope: rg
  params: {
    namePrefix: namePrefix
    envName: envName
    suffix: suffix
    location: location
    apimName: apim.outputs.apimName
  }
}

// Key Vault for the register app Easy Auth client secret. Gated on deployRegisterApp; the
// register UAMI gets Secrets User (read) so the Container App resolves the secret reference,
// and the deploying principal (when known) gets Secrets Officer (write) for the setup script.
module registerKv 'modules/register-kv.bicep' = if (deployRegisterApp) {
  name: 'register-kv'
  scope: rg
  params: {
    envName: envName
    suffix: suffix
    location: location
    tenantId: entraTenantId
    #disable-next-line BCP318 // guarded by deployRegisterApp
    registerUamiPrincipalId: deployRegisterApp ? registerRole.outputs.uamiPrincipalId : ''
    deployerPrincipalId: deployerPrincipalId
    privateNetworking: deployRegisterApp && registerVnetIntegrated
    peSubnetId: network.outputs.peSubnetId
    #disable-next-line BCP318 // privatednsVault exists whenever deployRegisterApp && registerVnetIntegrated (a subset of vaultPrivateDnsEnabled)
    vaultDnsZoneId: (deployRegisterApp && registerVnetIntegrated) ? privatednsVault.outputs.vaultZoneId : ''
  }
}

// Container registry the register image is pushed to by `azd deploy register`, and (when
// useAcrRunnerImage=true) the pre-baked runner image is built into by `az acr build` (#94).
// Gated on deployRegisterApp OR an opted-in runner; the register UAMI gets AcrPull here, the
// runner UAMI grants its own AcrPull in gh-runner.bicep (avoids a module dependency cycle).
var deploySharedAcr = deployRegisterApp || (deployGhRunner && useAcrRunnerImage)

module registerAcr 'modules/register-acr.bicep' = if (deploySharedAcr) {
  name: 'register-acr'
  scope: rg
  params: {
    envName: envName
    suffix: suffix
    location: location
    #disable-next-line BCP318 // guarded by deployRegisterApp
    registerUamiPrincipalId: deployRegisterApp ? registerRole.outputs.uamiPrincipalId : ''
  }
}

module registerApp 'modules/register-app.bicep' = if (deployRegisterApp) {
  name: 'register-app'
  scope: rg
  params: {
    envName: envName
    suffix: suffix
    location: location
    logAnalyticsName: observability.outputs.logAnalyticsName
    #disable-next-line BCP318 // guarded by the module's own if (deployRegisterApp)
    registerUamiId: deployRegisterApp ? registerRole.outputs.uamiId : ''
    #disable-next-line BCP318 // guarded by deployRegisterApp
    registerUamiClientId: deployRegisterApp ? registerRole.outputs.uamiClientId : ''
    apimName: apim.outputs.apimName
    apimGatewayUrl: apim.outputs.apimGatewayUrl
    cloudEnv: cloudEnv
    entraLoginHost: v.entraLoginHost
    entraTenantId: entraTenantId
    adminGroupId: registerAdminGroupId
    powerGroupId: registerPowerGroupId
    privateNetworking: registerPrivateNetworking
    peSubnetId: network.outputs.peSubnetId
    vnetId: network.outputs.vnetId
    acaDnsZoneName: 'privatelink.${location}.${v.acaDnsSuffix}'
    easyAuthClientId: registerEasyAuthClientId
    easyAuthClientSecret: registerEasyAuthClientSecret
    easyAuthSecretKeyVaultUri: registerEasyAuthSecretKeyVaultUri
    registerImage: registerAppImage
    #disable-next-line BCP318 // guarded by deployRegisterApp
    acrLoginServer: deployRegisterApp ? registerAcr.outputs.loginServer : ''
    infrastructureSubnetId: (deployRegisterApp && registerVnetIntegrated) ? network.outputs.registerEnvSubnetId : ''
  }
}

// In-VNet subkey proxy (nginx ACI in snet-aci): translates 'Authorization: Bearer <apim sub key>'
// -> the api-key header and forwards to the private /openai route, so Bearer-only OpenAI-compatible
// IDE clients (JetBrains AI Assistant) can use their APIM subscription key (no expiring token).
// Needed because APIM can't validate a subkey delivered as a Bearer token in-policy, and the
// self-loopback bridge fails on Internal-mode APIM (ILB has no backend->own-frontend hairpin).
module apimSubkeyProxy 'modules/apim-subkey-proxy-aci.bicep' = if (deployFoundry && deployFoundrySubkeyProxy) {
  name: 'apim-subkey-proxy'
  scope: rg
  params: {
    location: location
    namePrefix: namePrefix
    envName: envName
    suffix: suffix
    aciSubnetId: network.outputs.aciSubnetId
    apimGatewayHost: apim.outputs.apimGatewayHost
    image: subkeyProxyImage
    targetPath: 'openai'
    vnetId: network.outputs.vnetId
  }
  dependsOn: [
    apimFoundryApi
  ]
}

// Self-healing DNS reconciler: a scheduled Container Apps Job in the runner env (cae-runner) that
// repoints proxy.byok.internal at the proxy ACI's current IP when it drifts (the ACI IP changes on
// out-of-band recreation). Runs in Container Apps, not as an in-ACI sidecar, because a VNet-injected
// ACI can't get a managed-identity token in-container (IMDS unreachable). Requires the proxy, the
// runner env, and the shared ACR (holding the pre-baked reconciler image) to all be present.
module proxyDnsReconcileJob 'modules/proxy-dns-reconcile-job.bicep' = if (deployFoundry && deployFoundrySubkeyProxy && deployGhRunner && deploySharedAcr) {
  name: 'proxy-dns-reconcile-job'
  scope: rg
  params: {
    location: location
    namePrefix: namePrefix
    envName: envName
    suffix: suffix
    cloudName: cloudEnv
    #disable-next-line BCP318 // guarded by deployGhRunner
    managedEnvironmentId: ghRunner.outputs.envId
    #disable-next-line BCP318 // guarded by deploySharedAcr
    acrLoginServer: registerAcr.outputs.loginServer
    #disable-next-line BCP318 // guarded by deploySharedAcr
    acrName: registerAcr.outputs.name
    #disable-next-line BCP318 // guarded by deployFoundrySubkeyProxy
    proxyContainerGroupName: apimSubkeyProxy.outputs.containerGroupName
    #disable-next-line BCP318 // guarded by deployFoundrySubkeyProxy
    proxyDnsZoneName: apimSubkeyProxy.outputs.proxyDnsZoneName
    #disable-next-line BCP318 // guarded by deployFoundrySubkeyProxy
    proxyHostLabel: apimSubkeyProxy.outputs.proxyHostLabel
  }
}

output resourceGroup string = rg.name
output apimName string = apim.outputs.apimName
output apimGatewayUrl string = apim.outputs.apimGatewayUrl

@description('In-VNet base URL for the subkey proxy (nginx ACI). Point JetBrains AI Assistant here with your APIM subscription key in the API Key field. Empty when the proxy is not deployed.')
#disable-next-line BCP318 // guarded by deployFoundrySubkeyProxy
output subkeyProxyBaseUrl string = (deployFoundry && deployFoundrySubkeyProxy) ? apimSubkeyProxy.outputs.proxyBaseUrl : ''

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
#disable-next-line BCP318 // guarded by deployRegisterApp
output registerAppUrl string = deployRegisterApp ? registerApp.outputs.appUrl : ''
#disable-next-line BCP318 // guarded by deployRegisterApp
output registerAppFqdn string = deployRegisterApp ? registerApp.outputs.appFqdn : ''
#disable-next-line BCP318 // guarded by deployRegisterApp
output registerUamiClientId string = deployRegisterApp ? registerRole.outputs.uamiClientId : ''
#disable-next-line BCP318 // guarded by deployRegisterApp
output registerKeyVaultName string = deployRegisterApp ? registerKv.outputs.vaultName : ''
#disable-next-line BCP318 // guarded by deployRegisterApp
output registerEasyAuthSecretUri string = deployRegisterApp ? registerKv.outputs.easyAuthSecretUri : ''

@description('Name of the dedicated runner Key Vault (empty when deployGhRunner=false). Rotate the PAT with: az keyvault secret set --vault-name <this> --name gh-pat --value <pat>.')
output ghRunnerKeyVaultName string = deployGhRunner ? runnerKvName : ''

@description('Full Key Vault secret URI the runner Job reads its PAT from (empty when deployGhRunner=false). Set ghRunnerSecretFromKeyVault=true after writing this secret to flip the Job to the KV reference.')
output ghRunnerPatSecretUri string = deployGhRunner ? runnerPatSecretUri : ''

@description('Full Key Vault secret URI the runner Job reads its GitHub App private key from in app mode (empty when deployGhRunner=false). Write the PEM here then set ghRunnerSecretFromKeyVault=true.')
output ghRunnerAppKeySecretUri string = deployGhRunner ? runnerAppKeySecretUri : ''

@description('Active runner auth method: app (GitHub App) | pat (Personal Access Token). Empty when deployGhRunner=false.')
#disable-next-line BCP318 // guarded by the module's own if (deployGhRunner)
output ghRunnerAuthMode string = deployGhRunner ? ghRunner.outputs.ghRunnerAuthMode : ''

@description('How the runner Job currently sources its gh-pat secret: keyvault | inline | none (empty when deployGhRunner=false).')
#disable-next-line BCP318 // guarded by the module's own if (deployGhRunner)
output ghRunnerSecretSource string = deployGhRunner ? ghRunner.outputs.ghRunnerSecretSource : ''

@description('Container registry endpoint `azd deploy register` pushes the Blazor image to (empty when deployRegisterApp=false). azd reads AZURE_CONTAINER_REGISTRY_ENDPOINT to target the push; the register Container App pulls from it via its UAMI.')
#disable-next-line BCP318 // guarded by deployRegisterApp
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = deployRegisterApp ? registerAcr.outputs.loginServer : ''

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
