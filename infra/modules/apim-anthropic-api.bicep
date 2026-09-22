// NATIVE ANTHROPIC MESSAGES API. Path '<ANTHROPIC_API_PATH>' (default 'anthropic') — a SEPARATE
// API from the default '/openai' route (apim-foundry-api.bicep), which is left untouched.
//
// WHY IT EXISTS. A client configured with COPILOT_PROVIDER_TYPE=anthropic (Copilot CLI, or any
// Anthropic SDK) speaks the native Anthropic Messages wire format and sends its credential in the
// 'x-api-key' header. APIM validates the subscription key from the header declared in
// subscriptionKeyParameterNames BEFORE any policy executes, and an API can declare only ONE such
// header — so the same per-developer key cannot be accepted as 'api-key' (the /openai route) and
// as 'x-api-key' on a single API, and no inbound policy can paper over it. Hence a second API,
// differing from /openai ONLY in the credential header and the wire format it accepts.
//
// It is NOT a second backend: the backend is still chosen by the {{commercial-models}} sentinel
// (#118), exactly as on /openai. It is NOT a second credential either — the same subscription key,
// product and tier work on both routes, so quotas, rate limits and per-developer telemetry are
// shared. That is the point: it makes type=anthropic clients meterable per subscription key.
//
// Named values are created ONCE in apim-named-values.bicep; the policy references them via {{...}}.
// Backends are created in apim-backends.bicep. This module only creates the API + operation + policy.

param apimName string

@description('Fallback serviceUrl only; the set-backend-service backend-id in the policy always wins. Normally the commercial Foundry base URL, since Anthropic models are commercial-hosted.')
param fallbackBaseUrl string = ''

@description('API name. Must be unique within the APIM instance.')
param apiName string = 'copilot-byok-anthropic'

@description('API path segment appended to the gateway URL. Must NOT collide with "openai" or the commercial route path.')
param apiPath string = 'anthropic'

@description('Credential the gateway requires from CALLERS. subscriptionKey = per-developer APIM subscription key in the x-api-key header (what COPILOT_PROVIDER_API_KEY sends for type=anthropic); jwt = Entra access token validated by validate-jwt (COPILOT_PROVIDER_BEARER_TOKEN).')
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
  name: apiName
  properties: {
    displayName: 'Copilot BYOK -> Anthropic Messages (native)'
    path: apiPath
    protocols: ['https']
    subscriptionRequired: authMode == 'subscriptionKey'
    // THE WHOLE REASON THIS API EXISTS: type=anthropic clients send the key as 'x-api-key'.
    // APIM validates it natively from this header before the policy runs.
    subscriptionKeyParameterNames: authMode == 'subscriptionKey' ? {
      header: 'x-api-key'
      query: 'api-key'
    } : null
    serviceUrl: empty(fallbackBaseUrl) ? 'https://unset.invalid' : fallbackBaseUrl
    apiType: 'http'
  }
}

// Single surface. The Anthropic Messages API is versioned by the 'anthropic-version' HEADER, not
// by a path segment or api-version query parameter, so one operation covers every version.
// COPILOT_PROVIDER_TYPE=anthropic PRESERVES the configured base path and appends '/v1/messages',
// so a base URL of https://<gateway>/<apiPath> lands exactly here.
resource opMessages 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'messages'
  properties: {
    displayName: 'Anthropic Messages'
    method: 'POST'
    urlTemplate: '/v1/messages'
  }
}

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: authMode == 'jwt' ? loadTextContent('../../policies/byok-anthropic-policy.xml') : loadTextContent('../../policies/byok-anthropic-policy-subkey.xml')
  }
  dependsOn: [
    opMessages
  ]
}

output apiId string = api.id
output apiName string = api.name
output apiPath string = api.properties.path
// Mirrors the other API modules: surfaces the named-value dependency so the caller can order on it.
output namedValueDependency array = namedValueIds
