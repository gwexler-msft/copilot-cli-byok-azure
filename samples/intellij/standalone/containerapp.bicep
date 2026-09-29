targetScope = 'subscription'

import { callerAuthPreparationConfig } from '../../../infra/main.bicep'
import { callerJwtTieringConfig } from '../../../infra/modules/apim-caller-auth.bicep'

param callerAuthPreparation callerAuthPreparationConfig = {
  enabled: false
  keyEnabled: true
  entraEnabled: false
  entraClientIds: []
  oktaTrust: { enabled: false, issuer: '', openIdConfigUrl: '', audience: '', requiredScope: '', clientIds: [] }
  jwtProductId: 'intellij-jwt'
}
@allowed(['legacy', 'shared', 'coexistence'])
param callerAuthRollout string = 'legacy'
param callerJwtTiering callerJwtTieringConfig = {
  entra: { enabled: false, mappings: [] }
  okta: { enabled: false, claimName: 'byok_tier', mappings: [] }
}
@description('Reviewed tier catalog from the existing gateway deployment. Tier activation requires configureApim=true and does not rewrite native product policies.')
param productTiers array = []
param entraTenantId string = ''
param apiAudience string = ''
param requiredScope string = 'cli.invoke'
param existingBackendOrigin string = ''
@secure()
param responseOwnerKey string = ''
@secure()
param responseOwnerPreviousKey string = ''
param jwtDefaultCallsPerMinute int = 120
param jwtDefaultTokensPerMinute int = 200000
param jwtDefaultMonthlyCallQuota int = 200000

@description('Deployment location, matching the existing Container Apps environment.')
param location string

@description('Existing resource group for the proxy. No resource group is created.')
param proxyResourceGroup string

param proxyAppName string = 'ca-byok-intellij-proxy'
param environmentName string
param environmentResourceGroup string
@description('Use privateEndpoint only for a VNet-integrated environment with public access Disabled and an approved, provisioned Private Endpoint. Reuse existing PE DNS; configurePrivateDns must be false.')
@allowed(['internal', 'privateEndpoint'])
param environmentIngressMode string = 'internal'

param apimResourceGroup string
param apimName string
param apimPrivateIp string
param apimGatewayHost string
param intellijApiPath string = 'intellij'
param proxyImage string

@minValue(1)
@maxValue(10)
param maxReplicas int = 3

@description('False reuses an existing /intellij API without changing its owner/state. True deploys the existing shared APIM module for a new Bicep-managed installation.')
param configureApim bool = false

@description('Opt in to a private DNS zone for the existing internal environment domain, a wildcard ingress record, and a non-registering link to the environment VNet. Leave false for customer-managed DNS.')
param configurePrivateDns bool = false

@description('Required with configureApim=true.')
param existingBackendName string = ''

@secure()
param foundryApiKey string = ''

@description('APIM-to-Foundry authentication only, used when configureApim=true. No identity or Foundry access is added to the proxy.')
@allowed(['apiKey', 'managedIdentity'])
param foundryAuthMode string = 'apiKey'

param apiVersion string = '2025-04-01-preview'
param existingProductName string = ''
param additionalProductNames array = []
param autoRouteSentinel string = 'auto'
param autoRouteMiniDeployment string = ''
param autoRouteFullDeployment string = ''
param autoRouteLengthThreshold int = 500
param autoRouteAmbiguousBand int = 200
param appInsightsName string = ''
param appInsightsResourceGroup string = ''

resource environment 'Microsoft.App/managedEnvironments@2024-10-02-preview' existing = {
  name: environmentName
  scope: resourceGroup(environmentResourceGroup)
}

var approvedPrivateEndpoints = filter(environment.properties.?privateEndpointConnections ?? [], connection => connection.properties.?privateLinkServiceConnectionState.?status == 'Approved' && connection.properties.?provisioningState == 'Succeeded')
var privateEnvironmentValidated = !empty(environment.properties.?vnetConfiguration.?infrastructureSubnetId) && (environmentIngressMode == 'internal'
  ? environment.properties.?vnetConfiguration.?internal == true
  : environment.properties.?vnetConfiguration.?internal == false && environment.properties.?publicNetworkAccess == 'Disabled' && !empty(approvedPrivateEndpoints) && !configurePrivateDns)

module privateDns 'modules/proxy-private-dns.bicep' = if (configurePrivateDns) {
  name: 'intellij-proxy-private-dns'
  scope: resourceGroup(proxyResourceGroup)
  params: {
    domainName: environment.properties.defaultDomain
    ingressIp: environment.properties.staticIp
    vnetId: split(environment.properties.vnetConfiguration.infrastructureSubnetId, '/subnets/')[0]
    linkName: '${proxyAppName}-vnet'
    privateEnvironmentValidated: any(environment.properties.?vnetConfiguration.?internal == true && !empty(environment.properties.?vnetConfiguration.?infrastructureSubnetId))
  }
}

module intellijApim 'modules/intellij-apim.bicep' = if (configureApim) {
  name: 'intellij-apim'
  scope: resourceGroup(apimResourceGroup)
  params: {
    apimName: apimName
    callerAuthPreparation: callerAuthPreparation
    callerAuthRollout: callerAuthRollout
    callerJwtTiering: callerJwtTiering
    productTiers: productTiers
    entraTenantId: entraTenantId
    apiAudience: apiAudience
    requiredScope: requiredScope
    existingBackendOrigin: existingBackendOrigin
    responseOwnerKey: responseOwnerKey
    responseOwnerPreviousKey: responseOwnerPreviousKey
    jwtDefaultCallsPerMinute: jwtDefaultCallsPerMinute
    jwtDefaultTokensPerMinute: jwtDefaultTokensPerMinute
    jwtDefaultMonthlyCallQuota: jwtDefaultMonthlyCallQuota
    existingBackendName: existingBackendName
    foundryApiKey: foundryApiKey
    foundryAuthMode: foundryAuthMode
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

module proxy 'modules/proxy-containerapp.bicep' = {
  name: 'intellij-proxy-containerapp'
  scope: resourceGroup(proxyResourceGroup)
  params: {
    location: location
    proxyAppName: proxyAppName
    environmentName: environmentName
    environmentResourceGroup: environmentResourceGroup
    privateEnvironmentValidated: any(privateEnvironmentValidated)
    proxyImage: proxyImage
    apimPrivateIp: apimPrivateIp
    apimGatewayHost: apimGatewayHost
    intellijApiPath: intellijApiPath
    maxReplicas: maxReplicas
  }
  dependsOn: [intellijApim]
}

output clientBaseUrl string = proxy.outputs.clientBaseUrl
