// Dedicated 'discovery' API: exposes ONLY GET /v1/models, on its own path so the
// caller's product membership decides who can list models.
//
// Topology:
//   API   : copilot-byok-discovery   path: discovery
//   Op    : GET /v1/models
//   Policy: byok-discovery-policy.xml -> rewrites to /openai/v1/models on the foundry
//           backend with MI auth
//   Product: byok-discovery (declared in apim-products.bicep) -- the ONLY product that
//           includes this API. Standard tiers (byok-standard / byok-power) do NOT, so
//           their per-developer keys get 401 here.
//
// Why this is split out of copilot-byok-foundry (the main inference API):
//   - The foundry API-level policy parses the request body for a `model` field and 400s
//     on any request without one (every GET /v1/models call).
//   - "Who can list models?" becomes a product-membership question (auditable in the
//     APIM portal) instead of a per-key allowlist in policy XML.
//   - Telemetry / billing counters stay off the discovery path: emit-metric isn't
//     applied here so model-listing calls don't skew per-developer rate-limit-by-key or
//     copilot_byok_request aggregates.

param apimName string

@description('Resource IDs of the shared named values; used to order the API/policy after they exist (foundry-backend-id, foundry-mi-audience).')
param namedValueIds array = []

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'copilot-byok-discovery'
  properties: {
    displayName: 'Copilot BYOK -> Discovery (list models)'
    path: 'discovery'
    protocols: ['https']
    // Always subscription-key gated even in jwt mode for the rest of the deployment --
    // discovery is product-restricted, and the product-scope key is the gating mechanism.
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'api-key'
    }
    apiType: 'http'
  }
}

resource opModels 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'list-models'
  properties: {
    displayName: 'List Models'
    method: 'GET'
    urlTemplate: '/v1/models'
  }
}

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../../policies/byok-discovery-policy.xml')
  }
  dependsOn: [
    opModels
  ]
}

output apiId string = api.id
output apiName string = api.name
output namedValueDependency array = namedValueIds
