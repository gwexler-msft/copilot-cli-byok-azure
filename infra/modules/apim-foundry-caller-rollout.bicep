targetScope = 'resourceGroup'

import { callerJwtTieringConfig } from './apim-caller-auth.bicep'

param apimName string
param foundryPrivateBaseUrl string
param entraTenantId string
param entraClientIds string[] = []

@allowed(['shared', 'coexistence'])
param callerAuthRollout string = 'shared'

param callerJwtTiering callerJwtTieringConfig = {
  entra: { enabled: false, mappings: [] }
  okta: { enabled: false, claimName: 'byok_tier', mappings: [] }
}
@description('Reviewed main deployment tier catalog. The caller-only transition does not update native product policies.')
param productTiers array = []

@minLength(1)
@maxLength(80)
param jwtProductId string = 'byok-jwt'

@secure()
@minLength(44)
@maxLength(44)
param responseOwnerKey string

@secure()
param responseOwnerPreviousKey string = ''

var loginHost = replace(replace(environment().authentication.loginEndpoint, 'https://', ''), '/', '')
var originWithSlash = uri(foundryPrivateBaseUrl, '/')
var foundryOrigin = take(originWithSlash, length(originWithSlash) - 1)
var authenticationNames = ['byok-authenticate', 'byok-strip-caller-credentials', 'byok-apply-caller-limits']
var ownershipNames = ['byok-response-owner-context', 'byok-prepare-responses-request', 'byok-read-response-owner', 'byok-verify-response-owner', 'byok-locate-response-owner']
var utilityNames = ['list-models', 'responses-get', 'responses-delete', 'responses-cancel', 'responses-input-items']

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' existing = {
  parent: apim
  name: 'copilot-byok-foundry'
}

var authenticationIds = [for fragmentName in authenticationNames: '${apim.id}/policyFragments/${fragmentName}']
var ownershipIds = [for fragmentName in ownershipNames: '${apim.id}/policyFragments/${fragmentName}']
var utilityPolicyIds = [for operationName in utilityNames: '${api.id}/operations/${operationName}/policies/policy']

module authentication 'apim-caller-auth.bicep' = {
  name: 'apim-caller-auth'
  params: {
    apimName: apimName
    keyEnabled: true
    entraLoginHost: loginHost
    entraTrust: {
      enabled: true
      tenantId: entraTenantId
      issuer: 'https://${loginHost}/${entraTenantId}/v2.0'
      clientIds: entraClientIds
    }
    jwtProductId: jwtProductId
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
  name: 'apim-response-ownership'
  params: {
    apimName: apimName
    responseOwnerKey: responseOwnerKey
    responseOwnerPreviousKey: responseOwnerPreviousKey
    backendOrigins: [foundryOrigin]
    responseStores: [{ origin: foundryOrigin, backendId: 'foundry', kind: 'foundry' }]
    callerAuthFragmentIds: authenticationIds
  }
  dependsOn: [authentication]
}

module consumer 'apim-foundry-api.bicep' = {
  name: 'apim-foundry-api'
  params: {
    apimName: apimName
    foundryPrivateBaseUrl: foundryPrivateBaseUrl
    authMode: 'subscriptionKey'
    sharedDiscoveryAuth: true
    sharedInferenceAuth: true
    callerAuthFragmentIds: authenticationIds
    responseOwnershipFragmentIds: ownershipIds
  }
  dependsOn: [ownership]
}

module admission 'apim-jwt-product.bicep' = {
  name: 'apim-jwt-product'
  params: {
    apimName: apimName
    productId: jwtProductId
    active: callerAuthRollout == 'coexistence'
    apiNames: [api.name]
    consumerPolicyIds: concat(['${api.id}/policies/policy'], utilityPolicyIds)
  }
  dependsOn: [consumer]
}