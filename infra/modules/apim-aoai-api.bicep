// Legacy AOAI API. Path 'aoai' (the default route now goes to Foundry on path 'openai').
// Named values are created once by apim-named-values.bicep; this module only declares the
// API surface + operations + policy. Callers reach AOAI by pointing
// COPILOT_PROVIDER_BASE_URL at https://<apim-gateway>/aoai.

import { sharedModelsAuthentication, sharedResponsesPreparation, sharedResponseAffinity, sharedCallerThrottleTelemetry, responsesItemTemplate, guardNativePolicy } from './apim-foundry-api.bicep'

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

@description('Opt-in shared caller authentication, JWT accounting and owned Responses operations. Main must pass prepared auth/ownership outputs; legacy behavior remains the default.')
param sharedInferenceAuth bool = false

param callerAuthFragmentIds array = []
param responseOwnershipFragmentIds array = []

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

// Azure-OpenAI-NATIVE (legacy / wizard) data-plane paths on the /aoai route: the deployment is
// already IN the URL (/aoai/deployments/{deployment}/<op>?api-version=...). Client fleets
// provisioned by older wizard policies force the full deployment-scoped path; expose these ops so
// APIM matches (instead of 404-ing) those requests. The API policy extracts the in-URL deployment
// and the shared rewrite maps it to the AOAI backend data-plane path /openai/deployments/{model}/<op>
// (translating the /aoai prefix). Our own /v1/<op> short paths keep the body-model + auto-route rewrite.
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

var responseOperations = [
  { name: 'responses-get', method: 'GET', path: '/v1/responses/{response_id}' }
  { name: 'responses-delete', method: 'DELETE', path: '/v1/responses/{response_id}' }
  { name: 'responses-cancel', method: 'POST', path: '/v1/responses/{response_id}/cancel' }
  { name: 'responses-input-items', method: 'GET', path: '/v1/responses/{response_id}/input_items' }
]
var sharedEntry = replace(sharedModelsAuthentication, '__NATIVE_SUBSCRIPTION_REQUIRED__', toLower(string(authMode == 'subscriptionKey')))
var ownedResponsePolicy = replace(responsesItemTemplate, '__SHARED_AUTHENTICATION__', sharedEntry)

@batchSize(1)
resource responseItems 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = [for operation in responseOperations: if (sharedInferenceAuth) {
  parent: api
  name: operation.name
  properties: {
    displayName: operation.name
    method: operation.method
    urlTemplate: operation.path
    templateParameters: [{ name: 'response_id', type: 'string', required: true }]
  }
}]

@batchSize(1)
resource responseItemPolicies 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = [for (operation, operationIndex) in responseOperations: if (sharedInferenceAuth) {
  parent: responseItems[operationIndex]
  name: 'policy'
  properties: { format: 'xml', value: ownedResponsePolicy }
}]

var inferencePolicySources = {
  subscriptionKey: loadTextContent('../../policies/byok-aoai-policy-subkey.xml')
  jwt: loadTextContent('../../policies/byok-aoai-policy.xml')
}
var sharedInferenceAuthentication = replace(sharedModelsAuthentication, '<include-fragment fragment-id="byok-strip-caller-credentials" />', '')
var inferenceInboundEnd = indexOf(inferencePolicySources.subscriptionKey, '<inbound>') + length('<inbound>')
var sharedInferenceWithAuthentication = '${substring(inferencePolicySources.subscriptionKey, 0, inferenceInboundEnd)}${sharedInferenceAuthentication}${substring(inferencePolicySources.subscriptionKey, inferenceInboundEnd)}'
var sharedInferenceWithAccounting = replace(sharedInferenceWithAuthentication, '<set-variable name="developerOid" value="@(context.Subscription?.Id ?? "unknown")" />', '<include-fragment fragment-id="byok-apply-caller-limits" /><include-fragment fragment-id="byok-strip-caller-credentials" />${sharedResponsesPreparation}')
var sharedInferenceWithoutLegacyIdentity = replace(sharedInferenceWithAccounting, '<set-variable name="developerUpn" value="@(context.Subscription?.Name ?? context.Subscription?.Id ?? "unknown")" />', '')
var aoaiResponseAffinity = replace(sharedResponseAffinity, '((bool)context.Variables[&quot;isCommercialModel&quot;] ? &quot;commercial&quot; : ((bool)context.Variables[&quot;routeToAoai&quot;] ? &quot;aoai&quot; : &quot;foundry&quot;))', '&quot;aoai&quot;')
var sharedInferenceWithAffinity = replace(sharedInferenceWithoutLegacyIdentity, '<set-backend-service backend-id="{{aoai-backend-id}}" />', '<set-backend-service backend-id="{{aoai-backend-id}}" />${aoaiResponseAffinity}')
@export()
var sharedInferenceTemplate string = replace(sharedInferenceWithAffinity, '</on-error>', '${sharedCallerThrottleTelemetry}</on-error>')
var sharedInferencePolicy = replace(sharedInferenceTemplate, '__NATIVE_SUBSCRIPTION_REQUIRED__', toLower(string(authMode == 'subscriptionKey')))

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    // Both policy files are embedded at compile time; the ternary selects which one is
    // applied at deploy time based on authMode.
    value: sharedInferenceAuth ? sharedInferencePolicy : (authMode == 'jwt' ? inferencePolicySources.jwt : guardNativePolicy(inferencePolicySources.subscriptionKey))
  }
  dependsOn: [
    opChat
    opComp
    opEmbed
    opResponses
    opChatDep
    opCompDep
    opEmbedDep
  ]
}

output apiId string = api.id
output apiName string = api.name
output namedValueDependency array = namedValueIds
output callerAuthFragmentDependency array = callerAuthFragmentIds
output responseOwnershipDependency array = responseOwnershipFragmentIds
output callerPolicyIds array = [apiPolicy.id]
