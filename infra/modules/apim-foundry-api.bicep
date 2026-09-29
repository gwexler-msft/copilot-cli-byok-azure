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

@description('Opt-in shared model discovery authentication. Main enables this only during explicit shared rollout; requires prepared fragments and matching native key admission.')
param sharedDiscoveryAuth bool = false

@description('Opt-in shared inference authentication/accounting and owned Responses operations. Main enables this only during explicit shared rollout; requires prepared fragments, configured stores and matching native admission.')
param sharedInferenceAuth bool = false

@description('Pass the caller-auth module fragmentIds output to order an opted-in discovery consumer after its fragments.')
param callerAuthFragmentIds array = []

@description('Pass the ownership module fragmentIds output when shared inference is enabled; orders stored-response consumers after their ownership package.')
param responseOwnershipFragmentIds array = []

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

@export()
var nativeCallerGuard string = '''
<choose><when condition="@(context.Subscription == null || (context.Product != null &amp;&amp; !context.Product.SubscriptionRequired))">
<return-response><set-status code="401" reason="Native subscription required" /></return-response>
</when></choose>
'''

@export()
func guardNativePolicy(source string) string => '${substring(source, 0, indexOf(source, '<inbound>') + length('<inbound>'))}${nativeCallerGuard}${substring(source, indexOf(source, '<inbound>') + length('<inbound>'))}'

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

// Stateful Responses sub-resources (#110). Agentic clients using store:true, background tasks or
// resumable turns call these follow-ups after POST /v1/responses; without them background
// Responses and conversation resume fail. All four share ONE operation-scoped policy that skips
// the API inference policy (body-less requests would hit its ModelNotSpecified 400) and rebuilds
// the account-root /openai/v1/responses/... path - see byok-foundry-responses-item-policy*.xml.
resource opResponseGet 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'responses-get'
  properties: {
    displayName: 'Responses - get stored response'
    method: 'GET'
    urlTemplate: '/v1/responses/{response_id}'
    templateParameters: [
      { name: 'response_id', type: 'string', required: true }
    ]
  }
}

resource opResponseDelete 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'responses-delete'
  properties: {
    displayName: 'Responses - delete stored response'
    method: 'DELETE'
    urlTemplate: '/v1/responses/{response_id}'
    templateParameters: [
      { name: 'response_id', type: 'string', required: true }
    ]
  }
}

resource opResponseCancel 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'responses-cancel'
  properties: {
    displayName: 'Responses - cancel background response'
    method: 'POST'
    urlTemplate: '/v1/responses/{response_id}/cancel'
    templateParameters: [
      { name: 'response_id', type: 'string', required: true }
    ]
  }
}

resource opResponseInputItems 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'responses-input-items'
  properties: {
    displayName: 'Responses - list input items'
    method: 'GET'
    urlTemplate: '/v1/responses/{response_id}/input_items'
    templateParameters: [
      { name: 'response_id', type: 'string', required: true }
    ]
  }
}

// Same policy on all four: subkey relies on APIM's native api-key validation, jwt re-validates the
// Entra token because the API inbound is skipped.
var responsesItemPolicy = sharedInferenceAuth ? sharedResponsesItemPolicy : (authMode == 'jwt' ? loadTextContent('../../policies/byok-foundry-responses-item-policy.xml') : guardNativePolicy(loadTextContent('../../policies/byok-foundry-responses-item-policy-subkey.xml')))

resource opResponseGetPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opResponseGet
  name: 'policy'
  properties: { format: 'rawxml', value: responsesItemPolicy }
}

resource opResponseDeletePolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opResponseDelete
  name: 'policy'
  properties: { format: 'rawxml', value: responsesItemPolicy }
}

resource opResponseCancelPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opResponseCancel
  name: 'policy'
  properties: { format: 'rawxml', value: responsesItemPolicy }
}

resource opResponseInputItemsPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opResponseInputItems
  name: 'policy'
  properties: { format: 'rawxml', value: responsesItemPolicy }
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
var modelsPolicySources = {
  subscriptionKey: loadTextContent('../../policies/byok-foundry-models-policy-subkey.xml')
  jwt: loadTextContent('../../policies/byok-foundry-models-policy.xml')
}
@export()
var sharedModelsAuthentication string = '''
<set-variable name="byokCredentialHeader" value="api-key" />
<choose>
  <when condition="@(&quot;{{caller-key-enabled}}&quot; != &quot;__NATIVE_SUBSCRIPTION_REQUIRED__&quot; || &quot;{{caller-native-subscription-required}}&quot; != &quot;__NATIVE_SUBSCRIPTION_REQUIRED__&quot;)">
    <return-response>
      <set-status code="401" reason="Caller admission configuration mismatch" />
      <set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header>
      <set-body>{"error":{"code":"CallerAdmissionMismatch","message":"Caller authentication is not configured for this API."}}</set-body>
    </return-response>
  </when>
</choose>
<include-fragment fragment-id="byok-authenticate" />
<include-fragment fragment-id="byok-strip-caller-credentials" />
'''
@export()
var sharedModelsTemplate string = replace(replace(modelsPolicySources.subscriptionKey, '<set-header name="api-key" exists-action="delete" />', sharedModelsAuthentication), '<set-header name="Authorization" exists-action="delete" />', '')
var sharedModelsPolicy = replace(sharedModelsTemplate, '__NATIVE_SUBSCRIPTION_REQUIRED__', toLower(string(authMode == 'subscriptionKey')))

resource opModelsPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opModels
  name: 'policy'
  properties: {
    format: sharedDiscoveryAuth ? 'xml' : 'rawxml'
    value: sharedDiscoveryAuth ? sharedModelsPolicy : (authMode == 'jwt' ? modelsPolicySources.jwt : guardNativePolicy(modelsPolicySources.subscriptionKey))
  }
}

var inferencePolicySources = {
  subscriptionKey: loadTextContent('../../policies/byok-foundry-policy-subkey.xml')
  jwt: loadTextContent('../../policies/byok-foundry-policy.xml')
}
var sharedInferenceAuthentication = replace(sharedModelsAuthentication, '<include-fragment fragment-id="byok-strip-caller-credentials" />', '')
var inferenceInboundEnd = indexOf(inferencePolicySources.subscriptionKey, '<inbound>') + length('<inbound>')
var sharedInferenceWithAuthentication = '${substring(inferencePolicySources.subscriptionKey, 0, inferenceInboundEnd)}${sharedInferenceAuthentication}${substring(inferencePolicySources.subscriptionKey, inferenceInboundEnd)}'
@export()
var sharedResponsesPreparation string = '''
<choose>
  <when condition="@(context.Operation.Id == &quot;responses&quot;)">
    <include-fragment fragment-id="byok-response-owner-context" />
    <include-fragment fragment-id="byok-prepare-responses-request" />
    <choose>
      <when condition="@(!string.IsNullOrEmpty((string)context.Variables[&quot;byokResponseReference&quot;]))">
        <include-fragment fragment-id="byok-locate-response-owner" />
        <set-variable name="byokResponseBackendCredential" value="" />
      </when>
    </choose>
  </when>
</choose>
'''
@export()
var sharedResponseAffinity string = '''
<choose>
  <when condition="@(context.Operation.Id == &quot;responses&quot; &amp;&amp; !string.IsNullOrEmpty((string)context.Variables[&quot;byokResponseReference&quot;]))">
    <choose>
      <when condition="@(!(bool)context.Variables[&quot;byokResponseOwnerAuthorized&quot;] || (string)context.Variables[&quot;byokResponseBackendKind&quot;] != ((bool)context.Variables[&quot;isCommercialModel&quot;] ? &quot;commercial&quot; : ((bool)context.Variables[&quot;routeToAoai&quot;] ? &quot;aoai&quot; : &quot;foundry&quot;)))">
        <return-response>
          <set-status code="400" reason="Response continuation requires its original backend" />
          <set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header>
          <set-body>{"error":{"code":"ResponseBackendMismatch","message":"Continue the response with a model served by its original backend."}}</set-body>
        </return-response>
      </when>
    </choose>
    <set-backend-service backend-id="@((string)context.Variables[&quot;byokResponseBackendId&quot;])" />
  </when>
</choose>
'''
var sharedInferenceWithAccounting = replace(sharedInferenceWithAuthentication, '<set-variable name="developerOid" value="@(context.Subscription?.Id ?? "unknown")" />', '<include-fragment fragment-id="byok-apply-caller-limits" /><include-fragment fragment-id="byok-strip-caller-credentials" />${sharedResponsesPreparation}')
var sharedInferenceWithoutLegacyIdentity = replace(sharedInferenceWithAccounting, '<set-variable name="developerUpn" value="@(context.Subscription?.Name ?? context.Subscription?.Id ?? "unknown")" />', '')
var responseAffinityOffset = indexOf(sharedInferenceWithoutLegacyIdentity, '    <!-- 7. Rewrite the OpenAI-style /v1/<op> path')
@export()
var sharedCallerThrottleTelemetry string = '''
<choose>
  <when condition="@(context.Variables.ContainsKey(&quot;byokCallerAuthenticated&quot;) &amp;&amp; (bool)context.Variables[&quot;byokCallerAuthenticated&quot;] &amp;&amp; context.Variables.ContainsKey(&quot;byokJwtValidated&quot;) &amp;&amp; (bool)context.Variables[&quot;byokJwtValidated&quot;] &amp;&amp; context.Response != null &amp;&amp; (context.Response.StatusCode == 429 || (context.Response.StatusCode == 403 &amp;&amp; context.LastError.Source == &quot;quota-by-key&quot;)))">
    <set-variable name="byokThrottleKind" value="@{
      var source = context.LastError.Source;
      if (source == &quot;rate-limit-by-key&quot;) { return &quot;burst&quot;; }
      if (source == &quot;azure-openai-token-limit&quot;) { return &quot;tokens&quot;; }
      if (source == &quot;quota-by-key&quot;) { return &quot;quota&quot;; }
      return &quot;other&quot;;
    }" />
    <emit-metric name="copilot_byok_throttled" value="1" namespace="copilot.byok">
      <dimension name="developer_oid" value="@((string)context.Variables[&quot;developerOid&quot;])" />
      <dimension name="developer_upn" value="@((string)context.Variables[&quot;developerUpn&quot;])" />
      <dimension name="deployment_name" value="@(context.Variables.ContainsKey(&quot;deploymentName&quot;) ? (string)context.Variables[&quot;deploymentName&quot;] : &quot;unresolved&quot;)" />
      <dimension name="backend" value="@(context.Variables.ContainsKey(&quot;backendName&quot;) ? (string)context.Variables[&quot;backendName&quot;] : &quot;unresolved&quot;)" />
      <dimension name="throttle" value="@((string)context.Variables[&quot;byokThrottleKind&quot;])" />
    </emit-metric>
    <emit-metric name="copilot_byok_caller_throttled" value="1" namespace="copilot.byok">
      <dimension name="auth_method" value="@((string)context.Variables[&quot;callerAuthMethod&quot;])" />
      <dimension name="issuer" value="@((string)context.Variables[&quot;callerIssuer&quot;])" />
      <dimension name="principal" value="@((string)context.Variables[&quot;callerPrincipalKey&quot;])" />
      <dimension name="operation" value="@(context.Operation.Id)" />
      <dimension name="throttle" value="@((string)context.Variables[&quot;byokThrottleKind&quot;])" />
    </emit-metric>
    <choose>
      <when condition="@(context.Variables.ContainsKey(&quot;byokCallerTier&quot;) &amp;&amp; System.Text.RegularExpressions.Regex.IsMatch((string)context.Variables[&quot;byokCallerTier&quot;], @&quot;\A[a-z][a-z0-9-]{0,79}\z&quot;) &amp;&amp; new[] { &quot;burst&quot;, &quot;tokens&quot;, &quot;quota&quot; }.Contains((string)context.Variables[&quot;byokThrottleKind&quot;]))">
        <emit-metric name="copilot_byok_tier_throttled" value="1" namespace="copilot.byok">
          <dimension name="auth_method" value="@((string)context.Variables[&quot;callerAuthMethod&quot;])" />
          <dimension name="tier" value="@((string)context.Variables[&quot;byokCallerTier&quot;])" />
          <dimension name="operation" value="@(context.Operation.Id)" />
          <dimension name="throttle" value="@((string)context.Variables[&quot;byokThrottleKind&quot;])" />
        </emit-metric>
      </when>
    </choose>
  </when>
</choose>
'''
var sharedInferenceWithAffinity = '${substring(sharedInferenceWithoutLegacyIdentity, 0, responseAffinityOffset)}${sharedResponseAffinity}${substring(sharedInferenceWithoutLegacyIdentity, responseAffinityOffset)}'
@export()
var sharedInferenceTemplate string = replace(sharedInferenceWithAffinity, '</on-error>', '${sharedCallerThrottleTelemetry}</on-error>')
var sharedInferencePolicy = replace(sharedInferenceTemplate, '__NATIVE_SUBSCRIPTION_REQUIRED__', toLower(string(authMode == 'subscriptionKey')))

@export()
var responsesItemTemplate string = '''
<policies><inbound>
__SHARED_AUTHENTICATION__
<include-fragment fragment-id="byok-response-owner-context" />
<set-variable name="byokResponseReference" value="@(context.Request.MatchedParameters.GetValueOrDefault(&quot;response_id&quot;, &quot;&quot;))" />
<choose>
  <when condition="@(!System.Text.RegularExpressions.Regex.IsMatch((string)context.Variables[&quot;byokResponseReference&quot;], @&quot;\Aresp_[A-Za-z0-9_-]{1,128}\z&quot;))">
    <return-response><set-status code="404" reason="Response unavailable" /></return-response>
  </when>
</choose>
<include-fragment fragment-id="byok-locate-response-owner" />
<set-backend-service backend-id="@((string)context.Variables[&quot;byokResponseBackendId&quot;])" />
<set-header name="@((string)context.Variables[&quot;byokResponseBackendCredentialHeader&quot;])" exists-action="override"><value>@((string)context.Variables["byokResponseBackendCredential"])</value></set-header>
<set-variable name="byokResponseBackendCredential" value="" />
<rewrite-uri template="@(&quot;/openai/v1/responses/&quot; + Uri.EscapeDataString((string)context.Variables[&quot;byokResponseReference&quot;]) + (context.Operation.Id == &quot;responses-cancel&quot; ? &quot;/cancel&quot; : (context.Operation.Id == &quot;responses-input-items&quot; ? &quot;/input_items&quot; : &quot;&quot;)))" copy-unmatched-params="true" />
</inbound><backend>
<retry condition="@(context.Response != null &amp;&amp; (context.Response.StatusCode == 429 || context.Response.StatusCode &gt;= 500))" count="2" interval="0" first-fast-retry="true">
  <forward-request buffer-response="false" />
</retry>
</backend><outbound /><on-error>
<choose>
  <when condition="@(context.LastError.Source == &quot;validate-jwt&quot; &amp;&amp; context.Response != null &amp;&amp; context.Response.StatusCode == 401)">
    <return-response><set-status code="401" reason="Invalid caller access token" />
    <set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header>
    <set-body>{"error":{"code":"InvalidCallerToken","message":"A valid caller access token is required."}}</set-body>
    </return-response>
  </when>
</choose>
<return-response><set-status code="503" reason="Response operation unavailable" />
<set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header>
<set-body>{"error":{"code":"ResponseUnavailable","message":"The response operation is unavailable."}}</set-body>
</return-response>
</on-error></policies>
'''
var sharedResponsesItemPolicy = replace(responsesItemTemplate, '__SHARED_AUTHENTICATION__', replace(sharedModelsAuthentication, '__NATIVE_SUBSCRIPTION_REQUIRED__', toLower(string(authMode == 'subscriptionKey'))))

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
    opResponseGet
    opResponseDelete
    opResponseCancel
    opResponseInputItems
    opChatDep
    opCompDep
    opEmbedDep
    opModels
  ]
}

output apiId string = api.id
output apiName string = api.name
output namedValueDependency array = namedValueIds
output callerAuthFragmentDependency array = callerAuthFragmentIds
output responseOwnershipDependency array = responseOwnershipFragmentIds
output callerPolicyIds array = [apiPolicy.id, opModelsPolicy.id, opResponseGetPolicy.id, opResponseDeletePolicy.id, opResponseCancelPolicy.id, opResponseInputItemsPolicy.id]
