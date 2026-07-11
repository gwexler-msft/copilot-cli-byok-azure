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

// Azure-OpenAI-NATIVE (legacy / wizard) data-plane paths: the deployment is already IN the URL
// (/openai/deployments/{deployment}/<op>?api-version=...), NOT the OpenAI-compatible /v1/<op>
// short path above. Some client fleets were provisioned by older wizard policies that force the
// full deployment-scoped path, and re-configuring every client is impractical. Expose these
// operations so APIM matches (instead of 404-ing) those requests; the API policy detects the
// in-URL deployment and forwards it verbatim, while our own /v1/<op> short paths keep the
// body-model + auto-route rewrite. Foundry accepts BOTH conventions on the same account.
resource opChatDep 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'chat-completions-deployment'
  properties: {
    displayName: 'Chat Completions (deployment-scoped, legacy)'
    method: 'POST'
    urlTemplate: '/deployments/{deployment}/chat/completions'
    templateParameters: [
      { name: 'deployment', type: 'string', required: true }
    ]
  }
}

resource opCompDep 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'completions-deployment'
  properties: {
    displayName: 'Completions (deployment-scoped, legacy)'
    method: 'POST'
    urlTemplate: '/deployments/{deployment}/completions'
    templateParameters: [
      { name: 'deployment', type: 'string', required: true }
    ]
  }
}

resource opEmbedDep 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'embeddings-deployment'
  properties: {
    displayName: 'Embeddings (deployment-scoped, legacy)'
    method: 'POST'
    urlTemplate: '/deployments/{deployment}/embeddings'
    templateParameters: [
      { name: 'deployment', type: 'string', required: true }
    ]
  }
}

// Model discovery (GET /v1/models). Exposed here so OpenAI-compatible clients (e.g.
// JetBrains AI Assistant's OpenAI-compatible provider) that probe <base>/models to validate
// the connection + populate the model dropdown work against the SAME base URL they use for
// chat (/openai/v1). This is served by an OPERATION-scoped policy that intentionally does NOT
// inherit the API inference policy (whose body-parse 400-guard would reject this body-less
// GET) — see policies/byok-foundry-models-policy*.xml. This is now the SINGLE model-listing
// surface: ANY valid inference key on this route can list models — acceptable because model
// names aren't sensitive and it's required for these clients to connect. The former dedicated
// 'copilot-byok-discovery' API + 'byok-discovery' product were consolidated away; the CI smoke
// runner asserts this op with a normal tier (dev1) key.
resource opModels 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'list-models'
  properties: {
    displayName: 'List Models'
    method: 'GET'
    urlTemplate: '/v1/models'
  }
}

// Operation-scoped policy: subkey variant relies on APIM's native api-key validation; jwt
// variant re-validates the Entra token (the API inbound is skipped, so it must). Both bypass
// the inference body-parse and rewrite to the account-root /openai/v1/models list surface.
resource opModelsPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opModels
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: authMode == 'jwt' ? loadTextContent('../../policies/byok-foundry-models-policy.xml') : loadTextContent('../../policies/byok-foundry-models-policy-subkey.xml')
  }
}

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
    opChatDep
    opCompDep
    opEmbedDep
    opModels
  ]
}

output apiId string = api.id
output apiName string = api.name
output namedValueDependency array = namedValueIds
