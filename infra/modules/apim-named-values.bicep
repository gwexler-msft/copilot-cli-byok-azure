// All APIM named values created ONCE, service-scoped, so both the Foundry (default) API and
// the AOAI (legacy) API can reference them via {{...}} in their policies without collisions.

param apimName string

param entraOpenIdConfigUrl string
param apiAppIdUri string
param apiAudience string
param requiredScope string

@description('Default api-version APIM injects when caller omits it. Must be recent enough for the deployed models (gpt-4.1/gpt-5.1 require 2025-04-01-preview or later).')
param defaultAoaiApiVersion string = '2025-04-01-preview'

@description('Private base URL of the classic AOAI (kind=OpenAI) account. Empty when AOAI not deployed.')
param aoaiPrivateBaseUrl string = ''

@description('MI token audience for the AOAI backend (e.g. https://cognitiveservices.azure.us).')
param aoaiAudience string = ''

@description('Private base URL of the Foundry (kind=AIServices) account. Empty when Foundry not deployed.')
param foundryPrivateBaseUrl string = ''

@description('MI token audience for the Foundry OpenAI-compat backend (same as AOAI: cognitiveservices.azure.*).')
param foundryAudience string = ''

@description('Comma-separated model names that the DEFAULT (Foundry) route should pin to the AOAI backend instead. Empty = everything goes to Foundry.')
param aoaiPinnedModels string = ''

@description('jwt mode: per-developer burst limit (calls/min) keyed on Entra oid.')
param jwtCallsPerMinute int = 120

@description('jwt mode: per-developer token-per-minute limit (prompt+completion) keyed on Entra oid. The real AI-cost guard.')
param jwtTokensPerMinute int = 60000

@description('jwt mode: per-developer hard monthly call ceiling (calls per 30 days) keyed on Entra oid.')
param jwtMonthlyCallQuota int = 200000

@description('Auto-routing: sentinel model value that opts a request in to tiered routing.')
param autoRouteSentinel string = 'auto'

@description('Auto-routing: deployment name for the cheap (mini) tier.')
param autoRouteMiniDeployment string = ''

@description('Auto-routing: deployment name for the full (expensive) tier.')
param autoRouteFullDeployment string = ''

@description('Auto-routing Level 1: prompt-length threshold (chars).')
param autoRouteLengthThreshold int = 500

@description('Auto-routing Level 1: half-width of the ambiguous band around the threshold.')
param autoRouteAmbiguousBand int = 200

@description('Auto-routing Level 2: enable the classifier-model call for ambiguous prompts.')
param autoRouteClassifierEnabled bool = false

@description('Auto-routing Level 2: deployment name used as the classifier (max_tokens:1 simple/complex).')
param autoRouteClassifierDeployment string = ''

@description('APIM backend-id the Foundry API policy targets in set-backend-service (a Url backend name or a Pool backend name). Empty = use the legacy inline base-url fallback name "foundry".')
param foundryBackendId string = ''

@description('APIM backend-id the AOAI API policy targets in set-backend-service. Empty = fallback name "aoai".')
param aoaiBackendId string = ''

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource nvOpenId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'entra-openid-config-url'
  properties: {
    displayName: 'entra-openid-config-url'
    value: entraOpenIdConfigUrl
    secret: false
  }
}

resource nvAppIdUri 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'api-app-id-uri'
  properties: {
    displayName: 'api-app-id-uri'
    value: apiAppIdUri
    secret: false
  }
}

resource nvAudience 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'api-audience'
  properties: {
    displayName: 'api-audience'
    value: apiAudience
    secret: false
  }
}

resource nvScope 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'required-scope'
  properties: {
    displayName: 'required-scope'
    value: requiredScope
    secret: false
  }
}

resource nvApiVersion 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'aoai-default-api-version'
  properties: {
    displayName: 'aoai-default-api-version'
    value: defaultAoaiApiVersion
    secret: false
  }
}

resource nvAoaiBase 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'aoai-private-base-url'
  properties: {
    displayName: 'aoai-private-base-url'
    value: empty(aoaiPrivateBaseUrl) ? 'https://unset.invalid' : aoaiPrivateBaseUrl
    secret: false
  }
}

resource nvAoaiMiAud 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'aoai-mi-audience'
  properties: {
    displayName: 'aoai-mi-audience'
    value: empty(aoaiAudience) ? 'https://unset.invalid' : aoaiAudience
    secret: false
  }
}

resource nvFoundryBase 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-private-base-url'
  properties: {
    displayName: 'foundry-private-base-url'
    value: empty(foundryPrivateBaseUrl) ? 'https://unset.invalid' : foundryPrivateBaseUrl
    secret: false
  }
}

resource nvFoundryMiAud 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-mi-audience'
  properties: {
    displayName: 'foundry-mi-audience'
    value: empty(foundryAudience) ? 'https://unset.invalid' : foundryAudience
    secret: false
  }
}

resource nvPinnedModels 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'aoai-pinned-models'
  properties: {
    displayName: 'aoai-pinned-models'
    value: empty(aoaiPinnedModels) ? ' ' : aoaiPinnedModels
    secret: false
  }
}

resource nvJwtCalls 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'jwt-calls-per-minute'
  properties: {
    displayName: 'jwt-calls-per-minute'
    value: string(jwtCallsPerMinute)
    secret: false
  }
}

resource nvJwtTokens 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'jwt-tokens-per-minute'
  properties: {
    displayName: 'jwt-tokens-per-minute'
    value: string(jwtTokensPerMinute)
    secret: false
  }
}

resource nvJwtQuota 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'jwt-monthly-call-quota'
  properties: {
    displayName: 'jwt-monthly-call-quota'
    value: string(jwtMonthlyCallQuota)
    secret: false
  }
}

resource nvAutoSentinel 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'auto-route-sentinel'
  properties: {
    displayName: 'auto-route-sentinel'
    value: empty(autoRouteSentinel) ? 'auto' : autoRouteSentinel
    secret: false
  }
}

resource nvAutoMini 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'auto-route-mini-deployment'
  properties: {
    displayName: 'auto-route-mini-deployment'
    value: empty(autoRouteMiniDeployment) ? 'unset' : autoRouteMiniDeployment
    secret: false
  }
}

resource nvAutoFull 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'auto-route-full-deployment'
  properties: {
    displayName: 'auto-route-full-deployment'
    value: empty(autoRouteFullDeployment) ? 'unset' : autoRouteFullDeployment
    secret: false
  }
}

resource nvAutoThreshold 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'auto-route-length-threshold'
  properties: {
    displayName: 'auto-route-length-threshold'
    value: string(autoRouteLengthThreshold)
    secret: false
  }
}

resource nvAutoBand 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'auto-route-ambiguous-band'
  properties: {
    displayName: 'auto-route-ambiguous-band'
    value: string(autoRouteAmbiguousBand)
    secret: false
  }
}

resource nvAutoClassifierEnabled 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'auto-route-classifier-enabled'
  properties: {
    displayName: 'auto-route-classifier-enabled'
    value: autoRouteClassifierEnabled ? 'true' : 'false'
    secret: false
  }
}

resource nvAutoClassifierDeployment 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'auto-route-classifier-deployment'
  properties: {
    displayName: 'auto-route-classifier-deployment'
    value: empty(autoRouteClassifierDeployment) ? 'unset' : autoRouteClassifierDeployment
    secret: false
  }
}

// Backend-id the policies target in set-backend-service. With a single region this is just the
// Url backend name (transparent vs the old inline base-url); with a pool it is the Pool backend
// name. The base-url named values above are retained because the auto-route classifier's
// send-request uses them directly (it does not go through set-backend-service).
resource nvFoundryBackendId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-backend-id'
  properties: {
    displayName: 'foundry-backend-id'
    value: empty(foundryBackendId) ? 'foundry' : foundryBackendId
    secret: false
  }
}

resource nvAoaiBackendId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'aoai-backend-id'
  properties: {
    displayName: 'aoai-backend-id'
    value: empty(aoaiBackendId) ? 'aoai' : aoaiBackendId
    secret: false
  }
}

output namedValueIds array = [
  nvOpenId.id
  nvAppIdUri.id
  nvAudience.id
  nvScope.id
  nvApiVersion.id
  nvAoaiBase.id
  nvAoaiMiAud.id
  nvFoundryBase.id
  nvFoundryMiAud.id
  nvPinnedModels.id
  nvJwtCalls.id
  nvJwtTokens.id
  nvJwtQuota.id
  nvAutoSentinel.id
  nvAutoMini.id
  nvAutoFull.id
  nvAutoThreshold.id
  nvAutoBand.id
  nvAutoClassifierEnabled.id
  nvAutoClassifierDeployment.id
  nvFoundryBackendId.id
  nvAoaiBackendId.id
]
