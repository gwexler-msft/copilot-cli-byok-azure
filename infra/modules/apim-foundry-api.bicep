// Default API. Path 'openai' — this is what Copilot CLI hits when COPILOT_PROVIDER_BASE_URL
// points at https://<apim-gateway>/openai. Routes to the Foundry (AIServices) backend by
// default, with a per-model override (aoai-pinned-models named value) that can pin specific
// models to the legacy AOAI backend. Named values are created by apim-named-values.bicep.

param apimName string
param foundryPrivateBaseUrl string

@description('Credential the gateway requires from callers. subscriptionKey = per-developer APIM subscription key (default); jwt = Entra access token validated by validate-jwt.')
@allowed([
  'subscriptionKey'
  'jwt'
])
param authMode string = 'subscriptionKey'

@description('Resource IDs of the shared named values; used to order the policy after they exist.')
param namedValueIds array = []

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'copilot-byok-foundry'
  properties: {
    displayName: 'Copilot BYOK -> Microsoft Foundry (default)'
    path: 'openai'
    protocols: ['https']
    // In subscriptionKey mode the per-developer APIM subscription key rides in the
    // 'api-key' header (the same slot Copilot CLI uses for COPILOT_PROVIDER_API_KEY),
    // so APIM validates it natively. In jwt mode no subscription is required and the
    // policy's validate-jwt is the sole credential check.
    subscriptionRequired: authMode == 'subscriptionKey'
    subscriptionKeyParameterNames: authMode == 'subscriptionKey' ? {
      header: 'api-key'
      query: 'api-key'
    } : null
    serviceUrl: foundryPrivateBaseUrl
    apiType: 'http'
  }
}

// OpenAI-style surface: model/deployment is in the request BODY, not the URL.
// Chat/Completions/Embeddings hit the deployment-scoped data plane
// (/openai/deployments/{model}/<op>); Responses hits the account-root v1 surface
// (/openai/v1/responses) — the model still rides in the body, but the path is
// versionless and NOT deployment-scoped. The policy handles the rewrite split.
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

// Responses API — used by VS Code 1.122+ Custom Endpoint provider when
// apiType: 'responses' is selected. Same /v1 prefix as the other ops so the same
// API policy file applies; the policy detects '/responses' and rewrites to the
// account-root path /openai/v1/responses (no /deployments/{model}/).
resource opResponses 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'responses'
  properties: {
    displayName: 'Responses'
    method: 'POST'
    urlTemplate: responsesPath
  }
}

// Note: model discovery (GET /v1/models) lives on the dedicated
// 'copilot-byok-discovery' API (see modules/apim-discovery-api.bicep). It was moved off
// this API in #61 so the body-parsing 400-guard for the chat/completions/responses ops
// doesn't reject body-less GETs, AND so "who can list models?" becomes a product
// membership question (the byok-discovery product is the only one that includes that
// API). Keeping discovery here would require either skipping <base /> in an op policy
// (drift-prone) or making every dev tier capable of listing models (over-exposure).

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    // Both policy files are embedded at compile time; the ternary selects which one is
    // applied at deploy time based on authMode.
    value: authMode == 'jwt' ? loadTextContent('../../policies/byok-foundry-policy.xml') : loadTextContent('../../policies/byok-foundry-policy-subkey.xml')
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
