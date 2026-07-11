// PARALLEL Commercial Foundry API. Path '<COMMERCIAL_API_PATH>' (default 'openai-commercial')
// — a SEPARATE API from the default '/openai' Gov/private route (apim-foundry-api.bicep), which
// is left untouched. Copilot CLI / VS Code hit this route when COPILOT_PROVIDER_BASE_URL points
// at https://<apim-gateway>/<COMMERCIAL_API_PATH>. It mirrors the Foundry API shape (chat /
// completions / embeddings / responses) and routes to a COMMERCIAL Microsoft Foundry endpoint
// over the public internet (egress leaves the Gov VNet via the NAT gateway public IP).
//
// Named values are created ONCE in apim-named-values.bicep (the foundry-commercial-* set); the
// commercial policy references them via {{...}}. Backend 'foundry-commercial' is created in
// apim-backends.bicep. This module only creates the API surface + operations + policy.

param apimName string

@description('COMMERCIAL Foundry public base URL (serviceUrl fallback; the policy overrides via set-backend-service backend-id). Placeholder <COMMERCIAL_FOUNDRY_BASE_URL> until supplied.')
param foundryCommercialBaseUrl string

@description('API name. Default copilot-byok-foundry-commercial (placeholder <COMMERCIAL_API_NAME>). Must be unique within the APIM instance and distinct from copilot-byok-foundry.')
param apiName string = 'copilot-byok-foundry-commercial'

@description('API path segment appended to the gateway URL. Default openai-commercial (placeholder <COMMERCIAL_API_PATH>). Must NOT collide with the default route path "openai".')
param apiPath string = 'openai-commercial'

@description('Credential the gateway requires from CALLERS (same semantics as the default route). subscriptionKey = per-developer APIM subscription key; jwt = Entra access token validated by validate-jwt. This is independent of the BACKEND auth used to reach the commercial endpoint (foundry-commercial-auth-mode named value).')
@allowed([
  'subscriptionKey'
  'jwt'
])
param authMode string = 'subscriptionKey'

@description('Resource IDs of the shared named values; used to order the policy after they exist (foundry-commercial-* set).')
param namedValueIds array = []

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: apiName
  properties: {
    displayName: 'Copilot BYOK -> Microsoft Foundry (commercial)'
    path: apiPath
    protocols: ['https']
    subscriptionRequired: authMode == 'subscriptionKey'
    subscriptionKeyParameterNames: authMode == 'subscriptionKey' ? {
      header: 'api-key'
      query: 'api-key'
    } : null
    // serviceUrl is a fallback only; the policy's set-backend-service backend-id wins. Guarded so
    // the API is still valid if the base URL has not been supplied yet (deployFoundryCommercial
    // gates the module, so this is normally set).
    serviceUrl: empty(foundryCommercialBaseUrl) ? 'https://unset.invalid' : foundryCommercialBaseUrl
    apiType: 'http'
  }
}

// Same OpenAI-style surface as the default route so one policy file applies to all ops.
var chatPath      = '/v1/chat/completions'
var compPath      = '/v1/completions'
var embedPath     = '/v1/embeddings'
var responsesPath = '/v1/responses'

resource opChat 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'chat-completions'
  properties: {
    displayName: 'Chat Completions'
    method: 'POST'
    urlTemplate: chatPath
  }
}

resource opComp 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'completions'
  properties: {
    displayName: 'Completions'
    method: 'POST'
    urlTemplate: compPath
  }
}

resource opEmbed 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'embeddings'
  properties: {
    displayName: 'Embeddings'
    method: 'POST'
    urlTemplate: embedPath
  }
}

resource opResponses 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'responses'
  properties: {
    displayName: 'Responses'
    method: 'POST'
    urlTemplate: responsesPath
  }
}

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    // Commercial policy variants (mirror the default route's two files). The ternary selects
    // jwt vs subscriptionKey at deploy time, identical to apim-foundry-api.bicep.
    value: authMode == 'jwt' ? loadTextContent('../../policies/byok-foundry-commercial-policy.xml') : loadTextContent('../../policies/byok-foundry-commercial-policy-subkey.xml')
  }
  dependsOn: [
    opChat
    opComp
    opEmbed
    opResponses
  ]
}

output apiId string = api.id
output apiName string = api.name
output namedValueDependency array = namedValueIds
