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

@description('Auto-routing: comma-separated allow-list of sentinel model values that opt a request in to tiered routing (case-insensitive). Default `auto,byok-auto` supports CLI (`auto`) and VS Code (`byok-auto`, since `auto` is reserved in the VS Code model picker).')
param autoRouteSentinel string = 'auto,byok-auto'

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

// ---- Commercial Foundry route named values -------------------------------------------------
// Always created (placeholder defaults) so the commercial policy validates whether or not the
// commercial route is deployed, matching how the foundry/aoai named values are always present.

@description('COMMERCIAL Foundry public base URL (used by the classifier send-request on the commercial route). Placeholder <COMMERCIAL_FOUNDRY_BASE_URL>. Empty => https://unset.invalid.')
param foundryCommercialBaseUrl string = ''

@description('MI token audience for the commercial backend when foundryCommercialAuthMode=managedIdentity (e.g. https://cognitiveservices.azure.com). Placeholder <COMMERCIAL_FOUNDRY_AUDIENCE>. Empty => https://unset.invalid.')
param foundryCommercialAudience string = ''

@description('APIM backend-id the commercial policy targets in set-backend-service. Placeholder <COMMERCIAL_BACKEND_ID>. Empty => fallback name "foundry-commercial".')
param foundryCommercialBackendId string = ''

@description('api-version the commercial route injects on deployment-scoped paths. Placeholder <COMMERCIAL_API_VERSION>. Defaults to the same recent preview the default route uses.')
param foundryCommercialApiVersion string = '2025-04-01-preview'

@description('How the commercial policy authenticates to the commercial backend. servicePrincipalFederated (SECRETLESS DEFAULT) = workload identity federation: APIM presents its own Gov MI token (audience api://AzureADTokenExchange) to the commercial tenant as a client_assertion (the commercial SP needs a federated identity credential; no secret); servicePrincipal = same flow with the secret {{foundry-commercial-client-secret}} (fallback); apikey = send {{foundry-commercial-api-key}} in the api-key header; managedIdentity = mint an MI token for {{foundry-commercial-mi-audience}} (same-tenant only). Placeholder <COMMERCIAL_BACKEND_AUTH_MODE>.')
@allowed([
  'servicePrincipalFederated'
  'servicePrincipal'
  'apikey'
  'managedIdentity'
])
param foundryCommercialAuthMode string = 'servicePrincipalFederated'

@description('SECRET. Commercial Foundry API key, used when foundryCommercialAuthMode=apikey. Supply out-of-band (do NOT commit). Empty => a space placeholder so the named value exists but is non-functional until set.')
@secure()
param foundryCommercialApiKey string = ''

// ---- Commercial service-principal (client-credentials) backend auth ------------------------
@description('<COMMERCIAL_TENANT_ID> Commercial tenant GUID whose authority mints the backend token (servicePrincipal mode). Supplied from the COMMERCIAL_TENANT_ID repo Variable in CI; empty => the named value falls back to "organizations".')
param foundryCommercialTenantId string = ''

@description('<COMMERCIAL_CLIENT_ID> App (client) ID of the COMMERCIAL-tenant service principal used for the client-credentials grant (servicePrincipal mode).')
param foundryCommercialClientId string = ''

@description('SECRET <COMMERCIAL_CLIENT_SECRET_SECRET_REF>. Client secret of the commercial-tenant service principal (servicePrincipal mode). Supply out-of-band / via a Key Vault-backed named value; do NOT commit. Empty => a space placeholder so the named value exists but is non-functional until set.')
@secure()
param foundryCommercialClientSecret string = ''

@description('<COMMERCIAL_TOKEN_RESOURCE> Resource the commercial backend token is minted for (servicePrincipal mode). The policy appends /.default to form the scope. Default https://cognitiveservices.azure.com.')
param foundryCommercialTokenResource string = 'https://cognitiveservices.azure.com'

@description('Commercial AAD authority host for the token endpoint (servicePrincipal mode). Default login.microsoftonline.com (Commercial). Token URL = https://<host>/<tenant-id>/oauth2/v2.0/token.')
#disable-next-line no-hardcoded-env-urls // intentionally the COMMERCIAL login host (cross-tenant token); environment() would return the Gov host.
param foundryCommercialAuthorityHost string = 'login.microsoftonline.com'

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

// ---- Commercial Foundry route named values -------------------------------------------------
resource nvFoundryCommercialBase 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-base-url'
  properties: {
    displayName: 'foundry-commercial-base-url'
    value: empty(foundryCommercialBaseUrl) ? 'https://unset.invalid' : foundryCommercialBaseUrl
    secret: false
  }
}

resource nvFoundryCommercialMiAud 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-mi-audience'
  properties: {
    displayName: 'foundry-commercial-mi-audience'
    value: empty(foundryCommercialAudience) ? 'https://unset.invalid' : foundryCommercialAudience
    secret: false
  }
}

resource nvFoundryCommercialBackendId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-backend-id'
  properties: {
    displayName: 'foundry-commercial-backend-id'
    value: empty(foundryCommercialBackendId) ? 'foundry-commercial' : foundryCommercialBackendId
    secret: false
  }
}

resource nvFoundryCommercialApiVersion 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-api-version'
  properties: {
    displayName: 'foundry-commercial-api-version'
    value: empty(foundryCommercialApiVersion) ? '2025-04-01-preview' : foundryCommercialApiVersion
    secret: false
  }
}

resource nvFoundryCommercialAuthMode 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-auth-mode'
  properties: {
    displayName: 'foundry-commercial-auth-mode'
    value: foundryCommercialAuthMode
    secret: false
  }
}

// SECRET. Holds the commercial Foundry API key (apikey auth mode). A space placeholder keeps the
// named value present (so the policy resolves {{foundry-commercial-api-key}}) but non-functional
// until the real key is set out-of-band.
resource nvFoundryCommercialApiKey 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-api-key'
  properties: {
    displayName: 'foundry-commercial-api-key'
    value: empty(foundryCommercialApiKey) ? ' ' : foundryCommercialApiKey
    secret: true
  }
}

// ---- Commercial service-principal (client-credentials) named values ------------------------
// The policy mints a backend token for the COMMERCIAL tenant via OAuth2 client-credentials when
// foundry-commercial-auth-mode=servicePrincipal. tenant-id/client-id/token-resource/authority-host
// are non-secret; client-secret is a SECRET named value (mask in traces, never logged).
resource nvFoundryCommercialTenantId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-tenant-id'
  properties: {
    displayName: 'foundry-commercial-tenant-id'
    value: empty(foundryCommercialTenantId) ? 'organizations' : foundryCommercialTenantId
    secret: false
  }
}

resource nvFoundryCommercialClientId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-client-id'
  properties: {
    displayName: 'foundry-commercial-client-id'
    value: empty(foundryCommercialClientId) ? 'unset' : foundryCommercialClientId
    secret: false
  }
}

// SECRET. A space placeholder keeps the named value present (so the policy resolves
// {{foundry-commercial-client-secret}}) but non-functional until the real secret is set
// out-of-band (prefer a Key Vault-backed named value in production).
resource nvFoundryCommercialClientSecret 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-client-secret'
  properties: {
    displayName: 'foundry-commercial-client-secret'
    value: empty(foundryCommercialClientSecret) ? ' ' : foundryCommercialClientSecret
    secret: true
  }
}

resource nvFoundryCommercialTokenResource 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-token-resource'
  properties: {
    displayName: 'foundry-commercial-token-resource'
    value: empty(foundryCommercialTokenResource) ? 'https://cognitiveservices.azure.com' : foundryCommercialTokenResource
    secret: false
  }
}

resource nvFoundryCommercialAuthorityHost 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-commercial-authority-host'
  properties: {
    displayName: 'foundry-commercial-authority-host'
    #disable-next-line no-hardcoded-env-urls // intentionally the COMMERCIAL login host (cross-tenant token); environment() would return the Gov host.
    value: empty(foundryCommercialAuthorityHost) ? 'login.microsoftonline.com' : foundryCommercialAuthorityHost
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
  nvFoundryCommercialBase.id
  nvFoundryCommercialMiAud.id
  nvFoundryCommercialBackendId.id
  nvFoundryCommercialApiVersion.id
  nvFoundryCommercialAuthMode.id
  nvFoundryCommercialApiKey.id
  nvFoundryCommercialTenantId.id
  nvFoundryCommercialClientId.id
  nvFoundryCommercialClientSecret.id
  nvFoundryCommercialTokenResource.id
  nvFoundryCommercialAuthorityHost.id
]
