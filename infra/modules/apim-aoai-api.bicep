// Legacy AOAI API. Path 'aoai' (the default route now goes to Foundry on path 'openai').
// Named values are created once by apim-named-values.bicep; this module only declares the
// API surface + operations + policy. Callers reach AOAI by pointing
// COPILOT_PROVIDER_BASE_URL at https://<apim-gateway>/aoai.

param apimName string
param aoaiPrivateBaseUrl string

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
  name: 'copilot-byok-aoai'
  properties: {
    displayName: 'Copilot BYOK -> Azure OpenAI (legacy)'
    path: 'aoai'
    protocols: ['https']
    // In subscriptionKey mode the per-developer APIM subscription key rides in the
    // 'api-key' header; APIM validates it natively. In jwt mode no subscription is
    // required and the policy's validate-jwt is the sole credential check.
    subscriptionRequired: authMode == 'subscriptionKey'
    subscriptionKeyParameterNames: authMode == 'subscriptionKey' ? {
      header: 'api-key'
      query: 'api-key'
    } : null
    serviceUrl: aoaiPrivateBaseUrl
    apiType: 'http'
  }
}

// GitHub Copilot CLI BYOK ('azure' mode) and VS Code 1.122+ Custom Endpoint speak the
// OpenAI-style /v1/* surface: they POST to /v1/chat/completions (or /v1/responses for the
// VS Code apiType 'responses' provider) with the model/deployment in the request BODY,
// NOT in the URL. The policy rewrites chat/completions/embeddings to the AOAI
// deployment-scoped data-plane path (/openai/deployments/{model}/...) and rewrites
// /v1/responses to the account-root /openai/v1/responses (model stays in the body).
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
// apiType: 'responses' is selected. Same /v1 prefix so the same API policy file applies;
// the policy detects '/responses' and rewrites to the account-root /openai/v1/responses.
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
    // Both policy files are embedded at compile time; the ternary selects which one is
    // applied at deploy time based on authMode.
    value: authMode == 'jwt' ? loadTextContent('../../policies/byok-aoai-policy.xml') : loadTextContent('../../policies/byok-aoai-policy-subkey.xml')
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
