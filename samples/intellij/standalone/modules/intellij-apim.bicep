// IntelliJ BYOK bolt-on — dedicated /intellij API + policy on the customer's EXISTING Internal APIM.
//
// Self-contained: creates only a new API, its operations, the two policies, the named values the
// policies read, and (optionally) links the API to the existing product so existing
// subscription keys work. It does NOT create a backend or Foundry credential — it reuses the
// customer's existing Foundry backend by name (set-backend-service), with an optional api-key named
// value for the case where the key is applied in policy rather than on the backend entity.

@description('Name of the customer\'s existing APIM service.')
param apimName string

@description('Name of the customer\'s EXISTING Foundry backend entity in APIM (the one the default API uses). The policy set-backend-service\'s to it.')
param existingBackendName string

@description('OPTIONAL Foundry api-key. Provide ONLY if the key is applied in policy rather than carried on the backend entity. Empty = the backend supplies its own credential.')
@secure()
param foundryApiKey string = ''

@description('api-version pinned on deployment-scoped Foundry calls.')
param apiVersion string = '2025-04-01-preview'

@description('Path segment for the dedicated API (client base becomes https://<apim>/<path>/v1). Also the proxy targetPath.')
param intellijApiPath string = 'intellij'

@description('OPTIONAL primary existing APIM product name whose subscription keys are the IntelliJ user keys. Empty with no additional products = keys are all-APIs scope (no link needed).')
param existingProductName string = ''

@description('Additional existing APIM product names whose subscription keys must also authorize the /intellij API.')
param additionalProductNames array = []

@description('Auto-route sentinel model value(s), comma-separated. Default "auto"; tiered routing activates only once autoRouteMiniDeployment + autoRouteFullDeployment are set (empty = disabled).')
param autoRouteSentinel string = 'auto'

@description('Deployment name for the cheap (mini) auto-route tier.')
param autoRouteMiniDeployment string = ''

@description('Deployment name for the full auto-route tier.')
param autoRouteFullDeployment string = ''

@description('Auto-route Level-1 prompt-length threshold (chars).')
param autoRouteLengthThreshold int = 500

@description('Auto-route Level-1 half-width of the ambiguous band around the threshold.')
param autoRouteAmbiguousBand int = 200

@description('Name of the EXISTING Application Insights the /intellij API emits request + token metrics to. Reuse the customer\'s existing one — this module creates none.')
param appInsightsName string

@description('Resource group of that Application Insights (same subscription as APIM).')
param appInsightsResourceGroup string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

// ---- Named values the policies read via {{...}} ------------------------------------------------
var namedValues = [
  { name: 'intellij-foundry-backend-id', value: existingBackendName, secret: false }
  { name: 'intellij-foundry-api-key', value: empty(foundryApiKey) ? ' ' : foundryApiKey, secret: true }
  { name: 'intellij-api-version', value: apiVersion, secret: false }
  // APIM rejects empty named values (1-4096 chars). When auto-route is disabled these are empty, so
  // substitute a single space — both policies treat the sentinel as disabled via IsNullOrWhiteSpace,
  // and the mini/full deployment names are only read inside the (then-inactive) auto-route branch.
  { name: 'intellij-auto-sentinel', value: empty(autoRouteSentinel) ? ' ' : autoRouteSentinel, secret: false }
  { name: 'intellij-auto-mini-deployment', value: empty(autoRouteMiniDeployment) ? ' ' : autoRouteMiniDeployment, secret: false }
  { name: 'intellij-auto-full-deployment', value: empty(autoRouteFullDeployment) ? ' ' : autoRouteFullDeployment, secret: false }
  { name: 'intellij-auto-length-threshold', value: string(autoRouteLengthThreshold), secret: false }
  { name: 'intellij-auto-ambiguous-band', value: string(autoRouteAmbiguousBand), secret: false }
  // Metrics are always on for the bolt-on. Kept as a named value so it can be flipped to 'false'
  // at runtime (edit the named value) as a kill-switch without a redeploy.
  { name: 'intellij-metrics-enabled', value: 'true', secret: false }
]

resource nvs 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = [for nv in namedValues: {
  parent: apim
  name: nv.name
  properties: {
    displayName: nv.name
    value: nv.value
    secret: nv.secret
  }
}]

// ---- The dedicated API -------------------------------------------------------------------------
resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'intellij-byok'
  properties: {
    displayName: 'IntelliJ BYOK -> Foundry'
    path: intellijApiPath
    protocols: ['https']
    // The APIM subscription key rides in the 'api-key' header (what the proxy re-injects), so
    // APIM validates it natively before the policy runs.
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'api-key'
    }
    apiType: 'http'
  }
}

// ---- Operations --------------------------------------------------------------------------------
resource opChat 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'chat-completions'
  properties: { displayName: 'Chat Completions', method: 'POST', urlTemplate: '/v1/chat/completions' }
}
resource opComp 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'completions'
  properties: { displayName: 'Completions', method: 'POST', urlTemplate: '/v1/completions' }
}
resource opEmbed 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'embeddings'
  properties: { displayName: 'Embeddings', method: 'POST', urlTemplate: '/v1/embeddings' }
}
resource opResponses 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'responses'
  properties: { displayName: 'Responses', method: 'POST', urlTemplate: '/v1/responses' }
}
resource opModels 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'list-models'
  properties: { displayName: 'List Models', method: 'GET', urlTemplate: '/v1/models' }
}

// ---- Policies ----------------------------------------------------------------------------------
// Operation-scoped models policy (omits <base />, so the API inference policy's body-parse guard
// does not run on the body-less GET).
resource opModelsPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opModels
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/intellij-models.xml')
  }
  dependsOn: [ nvs ]
}

// API-scoped inference policy (applies to chat/completions/embeddings/responses).
resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/intellij-inference.xml')
  }
  dependsOn: [ nvs, opChat, opComp, opEmbed, opResponses, opModels ]
}

// ---- Product association (reuse the customer's existing subscription keys) ----------------------
resource product 'Microsoft.ApiManagement/service/products@2024-05-01' existing = if (!empty(existingProductName)) {
  parent: apim
  name: existingProductName
}

resource productApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = if (!empty(existingProductName)) {
  parent: product
  name: api.name
}

var distinctAdditionalProductNames = filter(
  union(additionalProductNames, []),
  productName => !empty(productName) && productName != existingProductName
)

resource additionalProducts 'Microsoft.ApiManagement/service/products@2024-05-01' existing = [for productName in distinctAdditionalProductNames: {
  parent: apim
  name: productName
}]

resource additionalProductApis 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = [for (productName, index) in distinctAdditionalProductNames: {
  parent: additionalProducts[index]
  name: api.name
}]

// ---- Metrics: reuse an EXISTING App Insights (no component created here) ------------------------
// Read the existing App Insights (Reader is enough) so we can wire the logger with its connection
// string (not a bare ikey) — that carries the correct per-cloud ingestion + live endpoints.
resource appi 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
  scope: resourceGroup(appInsightsResourceGroup)
}

// Service-level logger named 'intellij-appinsights' so it never collides with a logger the customer
// may already have (e.g. 'appinsights').
resource logger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'intellij-appinsights'
  properties: {
    loggerType: 'applicationInsights'
    resourceId: appi.id
    credentials: { connectionString: appi.properties.ConnectionString }
    isBuffered: true
  }
}

// API-SCOPED diagnostic (not service-level) so we add telemetry ONLY for /intellij and leave the
// customer's global APIM diagnostics untouched. metrics:true is REQUIRED for the policy's
// emit-metric to reach App Insights customMetrics (otherwise APIM silently drops the emitted metrics).
resource apiDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  parent: api
  name: 'applicationinsights'
  properties: {
    loggerId: logger.id
    alwaysLog: 'allErrors'
    metrics: true
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    httpCorrelationProtocol: 'W3C'
    verbosity: 'information'
    logClientIp: true
  }
}

output apiId string = api.id
output apiName string = api.name
output apiPath string = intellijApiPath
output loggerName string = logger.name
