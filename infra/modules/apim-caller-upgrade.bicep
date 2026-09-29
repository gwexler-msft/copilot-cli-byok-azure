import { callerAuthPreparationConfig } from '../main.bicep'
import { callerJwtTieringConfig } from './apim-caller-auth.bicep'

param apimName string
param apiId string
param modelsOperationId string
param callerAuthPreparation callerAuthPreparationConfig
@allowed(['shared', 'coexistence'])
param callerAuthRollout string = 'shared'
param callerJwtTiering callerJwtTieringConfig = {
  entra: { enabled: false, mappings: [] }
  okta: { enabled: false, claimName: 'byok_tier', mappings: [] }
}
@description('Reviewed catalog from the existing gateway deployment. Native product policies are not modified by this policy-only upgrade.')
param productTiers array = []
param entraTenantId string = ''
param apiAudience string = ''
param requiredScope string = 'cli.invoke'
param resourcePrefix string
param existingBackendName string
param existingBackendOrigin string
@allowed(['foundry', 'aoai'])
param backendKind string = 'foundry'
@allowed(['apiKey', 'managedIdentity'])
param foundryAuthMode string = 'managedIdentity'
@secure()
param foundryApiKey string = ''
@secure()
param responseOwnerKey string
@secure()
param responseOwnerPreviousKey string = ''
param jwtDefaultCallsPerMinute int = 120
param jwtDefaultTokensPerMinute int = 200000
param jwtDefaultMonthlyCallQuota int = 200000
param inferencePolicy string
param modelsPolicy string
param responsePolicy string
param ownershipCredentialPolicy string
type responseOperation = {
  name: string
  method: string
  path: string
}
@minLength(4)
@maxLength(4)
param responseOperations responseOperation[]

var loginHost = replace(replace(environment().authentication.loginEndpoint, 'https://', ''), '/', '')
var issuer = 'https://${loginHost}/${entraTenantId}/v2.0'
var audience = environment().name == 'AzureUSGovernment' ? 'https://cognitiveservices.azure.us' : 'https://cognitiveservices.azure.com'
var settings = [
  { name: 'entra-openid-config-url', value: '${issuer}/.well-known/openid-configuration', secret: false }
  { name: 'api-audience', value: empty(apiAudience) ? '__none__' : apiAudience, secret: false }
  { name: 'required-scope', value: requiredScope, secret: false }
  { name: 'jwt-calls-per-minute', value: string(jwtDefaultCallsPerMinute), secret: false }
  { name: 'jwt-tokens-per-minute', value: string(jwtDefaultTokensPerMinute), secret: false }
  { name: 'jwt-monthly-call-quota', value: string(jwtDefaultMonthlyCallQuota), secret: false }
  { name: 'foundry-mi-audience', value: audience, secret: false }
  { name: 'foundry-api-key', value: foundryAuthMode == 'apiKey' && !empty(foundryApiKey) ? foundryApiKey : ' ', secret: true }
]

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = { name: apimName }
resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' existing = { parent: apim, name: apiId }

@batchSize(1)
resource namedValues 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = [for setting in settings: {
  parent: apim
  name: '${resourcePrefix}${setting.name}'
  properties: { displayName: '${resourcePrefix}${setting.name}', value: setting.value, secret: setting.secret }
}]

module authentication 'apim-caller-auth.bicep' = {
  name: '${resourcePrefix}authentication'
  params: {
    apimName: apimName
    resourcePrefix: resourcePrefix
    keyEnabled: callerAuthPreparation.keyEnabled
    entraLoginHost: loginHost
    entraTrust: { enabled: callerAuthPreparation.entraEnabled, tenantId: entraTenantId, issuer: issuer, clientIds: callerAuthPreparation.entraClientIds }
    oktaTrust: callerAuthPreparation.oktaTrust
    jwtProductId: callerAuthPreparation.jwtProductId
    namedValueIds: [for (setting, index) in settings: namedValues[index].id]
    jwtTiering: callerJwtTiering
    tierCatalog: callerJwtTiering.entra.enabled || callerJwtTiering.okta.enabled ? map(productTiers, tier => {
      name: tier.name
      callsPerMinute: tier.callsPerMinute
      tokensPerMinute: tier.tokensPerMinute
      monthlyCallQuota: tier.monthlyCallQuota
    }) : []
  }
}

module ownership 'apim-response-ownership.bicep' = {
  name: '${resourcePrefix}ownership'
  params: {
    apimName: apimName
    resourcePrefix: resourcePrefix
    responseOwnerKey: responseOwnerKey
    responseOwnerPreviousKey: responseOwnerPreviousKey
    backendOrigins: [existingBackendOrigin]
    responseStores: [{ origin: existingBackendOrigin, backendId: existingBackendName, kind: backendKind }]
    backendCredentialPolicy: ownershipCredentialPolicy
    callerAuthFragmentIds: authentication.outputs.fragmentIds
  }
}

resource models 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' existing = { parent: api, name: modelsOperationId }
@batchSize(1)
resource responseItems 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = [for operation in responseOperations: {
  parent: api
  name: operation.name
  properties: { displayName: operation.name, method: operation.method, urlTemplate: operation.path, templateParameters: [{ name: 'response_id', type: 'string', required: true }] }
}]
resource inference 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: { format: 'rawxml', value: inferencePolicy }
  dependsOn: [ownership, utilities, discovery]
}
resource discovery 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: models
  name: 'policy'
  properties: { format: 'rawxml', value: modelsPolicy }
  dependsOn: [authentication]
}
@batchSize(1)
resource utilities 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = [for (operation, index) in responseOperations: {
  parent: responseItems[index]
  name: 'policy'
  properties: { format: 'xml', value: responsePolicy }
  dependsOn: [ownership]
}]
var utilityIds = [for (operation, index) in responseOperations: utilities[index].id]
module product 'apim-jwt-product.bicep' = {
  name: '${resourcePrefix}jwt-product'
  params: {
    apimName: apimName
    productId: callerAuthPreparation.jwtProductId
    active: callerAuthRollout == 'coexistence' && callerAuthPreparation.keyEnabled && (callerAuthPreparation.entraEnabled || callerAuthPreparation.oktaTrust.enabled)
    apiNames: [apiId]
    consumerPolicyIds: concat([inference.id, discovery.id], utilityIds)
  }
}