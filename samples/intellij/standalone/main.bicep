// IntelliJ BYOK bolt-on — standalone deployment (Option A).
//
// Subscription-scoped so the APIM configuration and (Phase 2) the proxy VM can live in different
// resource groups. Phase 1 wires only the dedicated /intellij API + policy onto the customer's
// EXISTING Internal APIM (reusing the existing Foundry backend + product). The proxy VM module is added
// at Phase 2.

targetScope = 'subscription'

@description('Resource group holding the customer\'s existing APIM (where the /intellij API is added).')
param apimResourceGroup string

@description('Name of the customer\'s existing APIM service.')
param apimName string

@description('Name of the customer\'s EXISTING Foundry backend entity in APIM (reused via set-backend-service).')
param existingBackendName string

@description('Foundry api-key the bolt-on uses to reach the customer\'s EXISTING Foundry backend. REQUIRED unless that backend entity already carries its own credential — the bolt-on authenticates by api-key only and does NOT use managed identity (unlike the standard BYOK deployment, which uses APIM MI + Cognitive Services User). If omitted when required, Foundry returns 401 "Access denied due to invalid subscription key or wrong API endpoint". Passed inline by the deploy script; never stored in the params file.')
@secure()
param foundryApiKey string = ''

@description('api-version pinned on deployment-scoped Foundry calls.')
param apiVersion string = '2025-04-01-preview'

@description('Path segment for the dedicated API (client base = https://<apim>/<path>/v1).')
param intellijApiPath string = 'intellij'

@description('OPTIONAL primary existing APIM product whose subscription keys the IntelliJ users have. Empty with no additional products = all-APIs-scope keys.')
param existingProductName string = ''

@description('Additional existing APIM products whose subscription keys must also authorize the /intellij API (for example, standard + power tiers).')
param additionalProductNames array = []

@description('Auto-route sentinel value(s), comma-separated. Default "auto"; tiered routing activates only once autoRouteMiniDeployment + autoRouteFullDeployment are set (empty = disabled).')
param autoRouteSentinel string = 'auto'

@description('Deployment name for the cheap (mini) auto-route tier.')
param autoRouteMiniDeployment string = ''

@description('Deployment name for the full auto-route tier.')
param autoRouteFullDeployment string = ''

@description('Auto-route Level-1 prompt-length threshold (chars).')
param autoRouteLengthThreshold int = 500

@description('Auto-route Level-1 half-width of the ambiguous band.')
param autoRouteAmbiguousBand int = 200

@description('Name of the EXISTING Application Insights the /intellij API sends request + token metrics to. Reuse the customer\'s existing one — no App Insights is created.')
param appInsightsName string

@description('Resource group of that Application Insights (same subscription as APIM).')
param appInsightsResourceGroup string

// ---- Proxy VM (Option A) -----------------------------------------------------------------------
@description('Azure region for the proxy VM + its resource group.')
param location string

@description('Resource group for the proxy VM. Created when createVmResourceGroup=true; otherwise it must already exist (point it at any RG you have Contributor on — e.g. the same one as APIM to keep everything in one RG).')
param vmResourceGroup string

@description('Create vmResourceGroup (true, needs subscription-level RG-create rights) or deploy the VM into an EXISTING resource group (false). Set false + vmResourceGroup=<apimResourceGroup> to deploy everything into one RG.')
param createVmResourceGroup bool = true

@description('Resource id of the EXISTING subnet for a deployment-created NIC. Required when proxyNicId is empty; ignored when the customer supplies a NIC.')
param vmSubnetId string = ''

@description('OPTIONAL full resource id of a customer-created, unattached NIC. When set, the deployment attaches this NIC to the proxy VM and creates no NIC; it must be static, private-only, in the VM region, and use proxyStaticPrivateIp.')
param proxyNicId string = ''

@description('The STATIC private IP to assign the proxy (a free address reserved in that subnet). Permanent proxy address.')
param proxyStaticPrivateIp string

@description('Private IP of the customer Internal APIM (nginx connects here directly — no DNS).')
param apimPrivateIp string

@description('APIM gateway hostname (Host header + TLS SNI when forwarding by IP).')
param apimGatewayHost string

@description('Admin username for the proxy VM.')
param vmAdminUsername string = 'byokadmin'

@description('SSH public key for the proxy VM admin (password auth disabled).')
param vmAdminSshPublicKey string

@description('Proxy VM size.')
param vmSize string = 'Standard_B2s'

@description('Proxy VM name.')
param vmName string = 'vm-byok-intellij-proxy'

@description('OPTIONAL resource id of a pre-baked Azure Compute Gallery image version (nginx pre-installed) for air-gapped subnets with no package egress. Build it with scripts/build-proxy-image. Empty = install nginx at boot from the Ubuntu marketplace image.')
param proxyImageId string = ''

module intellijApim 'modules/intellij-apim.bicep' = {
  name: 'intellij-apim'
  scope: resourceGroup(apimResourceGroup)
  params: {
    apimName: apimName
    existingBackendName: existingBackendName
    foundryApiKey: foundryApiKey
    apiVersion: apiVersion
    intellijApiPath: intellijApiPath
    existingProductName: existingProductName
    additionalProductNames: additionalProductNames
    autoRouteSentinel: autoRouteSentinel
    autoRouteMiniDeployment: autoRouteMiniDeployment
    autoRouteFullDeployment: autoRouteFullDeployment
    autoRouteLengthThreshold: autoRouteLengthThreshold
    autoRouteAmbiguousBand: autoRouteAmbiguousBand
    appInsightsName: appInsightsName
    appInsightsResourceGroup: appInsightsResourceGroup
  }
}

@description('Path of the dedicated API (client base = https://<apim-host>/<this>/v1).')
output intellijApiPath string = intellijApim.outputs.apiPath

// Proxy VM resource group. Created only when createVmResourceGroup=true; otherwise the VM is
// deployed into an existing RG (set vmResourceGroup=<apimResourceGroup> to keep everything in one RG).
resource vmRg 'Microsoft.Resources/resourceGroups@2024-03-01' = if (createVmResourceGroup) {
  name: vmResourceGroup
  location: location
}

module proxyVm 'modules/proxy-vm.bicep' = {
  name: 'intellij-proxy-vm'
  scope: resourceGroup(vmResourceGroup)
  params: {
    location: location
    vmName: vmName
    vmSize: vmSize
    subnetId: vmSubnetId
    proxyNicId: proxyNicId
    staticPrivateIp: proxyStaticPrivateIp
    apimPrivateIp: apimPrivateIp
    apimGatewayHost: apimGatewayHost
    intellijApiPath: intellijApiPath
    adminUsername: vmAdminUsername
    adminSshPublicKey: vmAdminSshPublicKey
    proxyImageId: proxyImageId
  }
  dependsOn: createVmResourceGroup ? [ vmRg ] : []
}

@description('Point JetBrains AI Assistant here (URL field) with the APIM subscription key in the API Key field.')
output clientBaseUrl string = 'http://${proxyStaticPrivateIp}:8080/${intellijApim.outputs.apiPath}/v1'
output proxyPrivateIp string = proxyStaticPrivateIp
output proxyNicResourceId string = proxyVm.outputs.proxyNicId
