// OVERLAY: enable the parallel Commercial Foundry route (/openai-commercial) on an ALREADY
// DEPLOYED APIM, WITHOUT re-running the full subscription-scoped main.bicep. It creates only the
// commercial-route resources (foundry-commercial backend + foundry-commercial-* named values +
// the commercial API/policy via the shared module + product links + the APIM-subnet NSG egress
// rule). Everything else on the APIM is left untouched.
//
// Why this exists: the target env (gov-dev) was provisioned by CI with secrets this operator does
// not hold; a full `azd provision` would risk reconfiguring the runner/register apps. This overlay
// is additive, idempotent, and reversible (delete the 4 resource kinds it creates). It deploys at
// RESOURCE GROUP scope against the existing APIM + NSG.
//
//   az deployment group create -g <rg> --template-file infra/overlay-commercial-route.bicep \
//     --parameters apimName=<apim> nsgName=<apim-subnet-nsg> \
//       foundryCommercialBaseUrl=https://<acct>.cognitiveservices.azure.com \
//       commercialTenantId=<commercial-tenant> commercialClientId=<sp-app-id> \
//       egressDestinations="['<cidr>',...]"
//
// The faithful, permanent path remains main.bicep's deployFoundryCommercial flag; this overlay
// mirrors the same resource shapes (apim-named-values.bicep / apim-backends.bicep /
// apim-foundry-commercial-api.bicep / apim-products.bicep) so a later full provision converges.

@description('Existing APIM service name.')
param apimName string

@description('Existing NSG on the APIM subnet (the commercial egress allow rule is added here).')
param nsgName string

@description('COMMERCIAL Foundry public base URL (account root, NO trailing slash). The policy appends /openai/deployments/<model>/<op>.')
param foundryCommercialBaseUrl string

@description('Commercial tenant GUID whose authority mints the backend token.')
param commercialTenantId string

@description('Commercial-tenant service principal app (client) id the Gov APIM MI federates to.')
param commercialClientId string

@secure()
@description('SECRET. Commercial-tenant SP client secret, used when foundryCommercialAuthMode=servicePrincipal. Empty keeps the placeholder named value (federated/apikey modes do not need it).')
param foundryCommercialClientSecret string = ''

@allowed([
  'servicePrincipalFederated'
  'servicePrincipal'
  'apikey'
  'managedIdentity'
])
@description('Backend auth mode. Default servicePrincipalFederated (secretless workload identity federation).')
param foundryCommercialAuthMode string = 'servicePrincipalFederated'

@description('api-version injected on deployment-scoped backend paths.')
param foundryCommercialApiVersion string = '2025-04-01-preview'

@description('Token resource for the backend SP token (policy appends /.default).')
param foundryCommercialTokenResource string = 'https://cognitiveservices.azure.com'

@description('COMMERCIAL AAD authority host for the token endpoint (cross-tenant). NOT environment() (that returns the Gov host).')
param foundryCommercialAuthorityHost string = 'login.microsoftonline.com'

@description('Caller-facing credential the API requires. subscriptionKey = APIM key in api-key header.')
@allowed([
  'subscriptionKey'
  'jwt'
])
param authMode string = 'subscriptionKey'

@description('APIM API name for the commercial route.')
param foundryCommercialApiName string = 'copilot-byok-foundry-commercial'

@description('APIM path segment for the commercial route.')
param foundryCommercialApiPath string = 'openai-commercial'

@description('Public-IP CIDRs the APIM subnet may reach on 443 for the commercial route (commercial Foundry data endpoint + commercial AAD login). NSGs cannot match FQDNs.')
param egressDestinations array

@description('Priority of the commercial egress allow rule (must beat the priority-4000 Deny-Out-Internet).')
param egressRulePriority int = 260

@description('Existing product names to link the commercial API into (so existing keys work on both routes).')
param productNames array = [
  'byok-standard'
  'byok-power'
]

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

// ---- foundry-commercial-* named values (mirror apim-named-values.bicep) ---------------------
resource nvBase 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-base-url'
  properties: { displayName: 'foundry-commercial-base-url', value: foundryCommercialBaseUrl, secret: false }
}
resource nvMiAud 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-mi-audience'
  properties: { displayName: 'foundry-commercial-mi-audience', value: 'https://unset.invalid', secret: false }
}
resource nvBackendId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-backend-id'
  properties: { displayName: 'foundry-commercial-backend-id', value: 'foundry-commercial', secret: false }
}
resource nvApiVersion 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-api-version'
  properties: { displayName: 'foundry-commercial-api-version', value: foundryCommercialApiVersion, secret: false }
}
resource nvAuthMode 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-auth-mode'
  properties: { displayName: 'foundry-commercial-auth-mode', value: foundryCommercialAuthMode, secret: false }
}
resource nvApiKey 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-api-key'
  properties: { displayName: 'foundry-commercial-api-key', value: ' ', secret: true }
}
resource nvTenantId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-tenant-id'
  properties: { displayName: 'foundry-commercial-tenant-id', value: empty(commercialTenantId) ? 'organizations' : commercialTenantId, secret: false }
}
resource nvClientId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-client-id'
  properties: { displayName: 'foundry-commercial-client-id', value: empty(commercialClientId) ? 'unset' : commercialClientId, secret: false }
}
resource nvClientSecret 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-client-secret'
  properties: { displayName: 'foundry-commercial-client-secret', value: empty(foundryCommercialClientSecret) ? ' ' : foundryCommercialClientSecret, secret: true }
}
resource nvTokenResource 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-token-resource'
  properties: { displayName: 'foundry-commercial-token-resource', value: foundryCommercialTokenResource, secret: false }
}
resource nvAuthorityHost 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-authority-host'
  #disable-next-line no-hardcoded-env-urls // intentionally the COMMERCIAL login host (cross-tenant token).
  properties: { displayName: 'foundry-commercial-authority-host', value: foundryCommercialAuthorityHost, secret: false }
}

// ---- foundry-commercial Url backend (mirror apim-backends.bicep) ----------------------------
resource backend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: 'foundry-commercial'
  properties: {
    protocol: 'http'
    url: foundryCommercialBaseUrl
  }
}

// ---- Commercial API + operations + policy (shared module) -----------------------------------
module commercialApi 'modules/apim-foundry-commercial-api.bicep' = {
  name: 'overlay-apim-foundry-commercial-api'
  params: {
    apimName: apimName
    foundryCommercialBaseUrl: foundryCommercialBaseUrl
    apiName: foundryCommercialApiName
    apiPath: foundryCommercialApiPath
    authMode: authMode
    // Passing the named-value ids makes the module (and its policy, which references {{...}})
    // wait until every foundry-commercial-* named value exists.
    namedValueIds: [
      nvBase.id
      nvMiAud.id
      nvBackendId.id
      nvApiVersion.id
      nvAuthMode.id
      nvApiKey.id
      nvTenantId.id
      nvClientId.id
      nvClientSecret.id
      nvTokenResource.id
      nvAuthorityHost.id
    ]
  }
  dependsOn: [
    backend
  ]
}

// ---- Product links (mirror apim-products.bicep) ---------------------------------------------
resource productApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = [
  for p in productNames: {
    name: '${apimName}/${p}/${foundryCommercialApiName}'
    dependsOn: [
      commercialApi
    ]
  }
]

// ---- APIM-subnet NSG egress allow rule (additive child resource) ----------------------------
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' existing = {
  name: nsgName
}
resource egressRule 'Microsoft.Network/networkSecurityGroups/securityRules@2024-05-01' = {
  parent: nsg
  name: 'Allow-Out-FoundryCommercial'
  properties: {
    description: 'Allow APIM subnet egress to the commercial Foundry data endpoint + commercial AAD login (cross-cloud /openai-commercial route).'
    access: 'Allow'
    direction: 'Outbound'
    protocol: 'Tcp'
    priority: egressRulePriority
    sourceAddressPrefix: 'VirtualNetwork'
    sourcePortRange: '*'
    destinationAddressPrefixes: egressDestinations
    destinationPortRange: '443'
  }
}

output apiName string = foundryCommercialApiName
output backendId string = 'foundry-commercial'
