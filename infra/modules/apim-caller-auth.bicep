param apimName string

@maxLength(32)
param resourcePrefix string = ''

@description('Native subscription keys remain enabled by default. Consuming APIs must require subscriptions whenever this is true.')
param keyEnabled bool = true

@description('The same cloud-specific Entra login host used by the main deployment. No caller token controls this value.')
@minLength(1)
param entraLoginHost string

type entraTrustConfig = {
  enabled: bool
  tenantId: string
  issuer: string
  clientIds: string[]
}

type oktaTrustConfig = {
  enabled: bool
  issuer: string
  openIdConfigUrl: string
  audience: string
  requiredScope: string
  clientIds: string[]
}

@description('Exact Entra v2 trust. Existing Entra metadata, audience and scope named values must be deployed first. Empty clientIds retains the legacy delegated-client contract.')
param entraTrust entraTrustConfig = {
  enabled: false
  tenantId: ''
  issuer: ''
  clientIds: []
}

@description('Opt-in custom authorization server. Configure user-bound access tokens with immutable sub equal to uid and an explicit public-client allowlist. Disabled by default.')
param oktaTrust oktaTrustConfig = {
  enabled: false
  issuer: ''
  openIdConfigUrl: ''
  audience: ''
  requiredScope: ''
  clientIds: []
}

@minLength(1)
@maxLength(80)
param jwtProductId string = 'byok-jwt'

@description('Existing shared named-value dependencies. Passing their module output orders this module after legacy Entra/backend settings.')
param namedValueIds array = []

@sealed()
type callerTierMappingConfig = {
  @minLength(1)
  @maxLength(128)
  claimValue: string
  @minLength(1)
  @maxLength(80)
  tier: string
}

@export()
@sealed()
type callerJwtTieringConfig = {
  entra: {
    enabled: bool
    @maxLength(16)
    mappings: callerTierMappingConfig[]
  }
  okta: {
    enabled: bool
    @minLength(1)
    @maxLength(64)
    claimName: string
    @maxLength(16)
    mappings: callerTierMappingConfig[]
  }
}

@export()
@sealed()
type callerLimitTierConfig = {
  @minLength(1)
  @maxLength(80)
  name: string
  @minValue(1)
  @maxValue(2147483647)
  callsPerMinute: int
  @minValue(1)
  @maxValue(2147483647)
  tokensPerMinute: int
  @minValue(1)
  @maxValue(2147483647)
  monthlyCallQuota: int
}

@export()
var defaultCallerJwtTiering = {
  entra: { enabled: false, mappings: [] }
  okta: { enabled: false, claimName: 'byok_tier', mappings: [] }
}

@description('Explicit post-validation JWT tier mapping. Both issuers default off; enabled mappings require the matching caller trust and a reviewed tier catalog.')
param jwtTiering callerJwtTieringConfig = {
  entra: { enabled: false, mappings: [] }
  okta: { enabled: false, claimName: 'byok_tier', mappings: [] }
}

@description('Projection of the deployment-owned product tier catalog, not a second set of independently managed limits.')
@maxLength(8)
param tierCatalog callerLimitTierConfig[] = []

var entraComplete = !entraTrust.enabled || (!empty(entraTrust.tenantId) && startsWith(entraTrust.issuer, 'https://') && endsWith(entraTrust.issuer, '/${entraTrust.tenantId}/v2.0'))
var oktaComplete = !oktaTrust.enabled || (startsWith(oktaTrust.issuer, 'https://') && contains(oktaTrust.issuer, '/oauth2/') && startsWith(oktaTrust.openIdConfigUrl, '${oktaTrust.issuer}/.well-known/') && !empty(oktaTrust.audience) && !empty(oktaTrust.requiredScope) && !empty(oktaTrust.clientIds))
var tieringComplete = (!jwtTiering.entra.enabled || entraTrust.enabled) && (!jwtTiering.okta.enabled || oktaTrust.enabled) && (!(jwtTiering.entra.enabled || jwtTiering.okta.enabled) || !empty(tierCatalog))
var configurationValid = (keyEnabled || entraTrust.enabled || oktaTrust.enabled) && entraComplete && oktaComplete && !(entraTrust.enabled && oktaTrust.enabled && entraTrust.issuer == oktaTrust.issuer) && tieringComplete

var settings = [
  { name: 'caller-configuration-valid', value: toLower(string(configurationValid)) }
  { name: 'caller-key-enabled', value: toLower(string(keyEnabled)) }
  { name: 'caller-native-subscription-required', value: toLower(string(keyEnabled)) }
  { name: 'caller-entra-enabled', value: toLower(string(entraTrust.enabled)) }
  { name: 'caller-entra-login-host', value: entraLoginHost }
  { name: 'caller-okta-enabled', value: toLower(string(oktaTrust.enabled)) }
  { name: 'caller-jwt-product-id', value: jwtProductId }
  { name: 'caller-entra-tenant-id', value: empty(entraTrust.tenantId) ? '__none__' : entraTrust.tenantId }
  { name: 'caller-entra-issuer', value: empty(entraTrust.issuer) ? 'https://unset.invalid/entra' : entraTrust.issuer }
  { name: 'caller-entra-client-ids', value: empty(entraTrust.clientIds) ? '__any__' : join(entraTrust.clientIds, ',') }
  { name: 'caller-okta-issuer', value: empty(oktaTrust.issuer) ? 'https://unset.invalid/okta' : oktaTrust.issuer }
  { name: 'caller-okta-openid-config-url', value: empty(oktaTrust.openIdConfigUrl) ? 'https://unset.invalid/okta/.well-known/openid-configuration' : oktaTrust.openIdConfigUrl }
  { name: 'caller-okta-audience', value: empty(oktaTrust.audience) ? '__none__' : oktaTrust.audience }
  { name: 'caller-okta-required-scope', value: empty(oktaTrust.requiredScope) ? '__none__' : oktaTrust.requiredScope }
  { name: 'caller-okta-client-ids', value: empty(oktaTrust.clientIds) ? '__none__' : join(oktaTrust.clientIds, ',') }
]

@export()
var disabledValidator = '<fragment><return-response><set-status code="401" reason="Caller issuer disabled" /><set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header><set-body>{"error":{"code":"CallerIssuerDisabled","message":"This caller issuer is not enabled."}}</set-body></return-response></fragment>'
@export()
var sourcePolicies = {
  'byok-credential-source': loadTextContent('../../policies/fragments/byok-credential-source.xml')
  'byok-validate-entra': loadTextContent('../../policies/fragments/byok-validate-entra.xml')
  'byok-validate-okta': loadTextContent('../../policies/fragments/byok-validate-okta.xml')
  'byok-strip-caller-credentials': loadTextContent('../../policies/fragments/byok-strip-caller-credentials.xml')
  'byok-authenticate': loadTextContent('../../policies/fragments/byok-authenticate.xml')
  'byok-apply-caller-limits': loadTextContent('../../policies/fragments/byok-apply-caller-limits.xml')
}

@export()
var callerTierSelectionSource = loadTextContent('../../policies/fragments/byok-select-caller-tier.xml')
var flatLimitOffset = indexOf(sourcePolicies['byok-apply-caller-limits'], '<rate-limit-by-key')
@export()
var flatJwtLimitPolicies = substring(sourcePolicies['byok-apply-caller-limits'], flatLimitOffset, indexOf(substring(sourcePolicies['byok-apply-caller-limits'], flatLimitOffset), '    </when>'))

@export()
func renderCallerTierConfiguration(tiering callerJwtTieringConfig, catalog callerLimitTierConfig[]) string => base64(string({
  version: 1
  tiers: map(catalog, tier => tier.name)
  entra: union(tiering.entra, { claimName: 'roles' })
  okta: tiering.okta
}))

@export()
var callerTierBranchTemplate = '<when condition="@((string)context.Variables[&quot;byokCallerTier&quot;] == System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(&quot;__BYOK_TIER_NAME__&quot;)))">${flatJwtLimitPolicies}</when>'

var callerTierAdmissionTelemetry = '''
<choose>
  <when condition="@((string)context.Variables[&quot;byokCallerTier&quot;] != &quot;__flat__&quot;)">
    <emit-metric name="copilot_byok_tier_admitted" value="1" namespace="copilot.byok">
      <dimension name="auth_method" value="@((string)context.Variables[&quot;callerAuthMethod&quot;])" />
      <dimension name="tier" value="@((string)context.Variables[&quot;byokCallerTier&quot;])" />
      <dimension name="operation" value="@(context.Operation.Id)" />
    </emit-metric>
  </when>
</choose>
'''

@export()
var callerTierLimitsTemplate = replace(sourcePolicies['byok-apply-caller-limits'], flatJwtLimitPolicies, '${replace(replace(callerTierSelectionSource, '<fragment>', ''), '</fragment>', '')}<choose><when condition="@((string)context.Variables[&quot;byokCallerTier&quot;] == &quot;__flat__&quot;)">${flatJwtLimitPolicies}</when>__BYOK_JWT_TIER_BRANCHES__<otherwise><return-response><set-status code="403" reason="Caller tier unavailable" /><set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header><set-body>{"error":{"code":"CallerTierInvalid","message":"An unambiguous permitted caller tier is required."}}</set-body></return-response></otherwise></choose>${callerTierAdmissionTelemetry}')

func renderCallerTierBranch(tier callerLimitTierConfig) string => replace(replace(replace(replace(callerTierBranchTemplate, '__BYOK_TIER_NAME__', base64(tier.name)), '{{jwt-calls-per-minute}}', string(tier.callsPerMinute)), '{{jwt-tokens-per-minute}}', string(tier.tokensPerMinute)), '{{jwt-monthly-call-quota}}', string(tier.monthlyCallQuota))

@export()
func renderCallerLimits(tiering callerJwtTieringConfig, catalog callerLimitTierConfig[]) string => !(tiering.entra.enabled || tiering.okta.enabled) ? sourcePolicies['byok-apply-caller-limits'] : replace(replace(callerTierLimitsTemplate, '__BYOK_JWT_TIERING_CONFIG__', renderCallerTierConfiguration(tiering, catalog)), '__BYOK_JWT_TIER_BRANCHES__', join(map(catalog, tier => renderCallerTierBranch(tier)), ''))

var entraValidator = entraTrust.enabled && configurationValid ? sourcePolicies['byok-validate-entra'] : disabledValidator
var oktaValidator = oktaTrust.enabled && configurationValid ? sourcePolicies['byok-validate-okta'] : disabledValidator
var authenticationWithSource = replace(sourcePolicies['byok-authenticate'], '<include-fragment fragment-id="byok-credential-source" />', replace(replace(sourcePolicies['byok-credential-source'], '<fragment>', ''), '</fragment>', ''))
var authenticationWithEntra = replace(authenticationWithSource, '<include-fragment fragment-id="byok-validate-entra" />', replace(replace(entraValidator, '<fragment>', ''), '</fragment>', ''))
var authenticationPolicy = replace(authenticationWithEntra, '<include-fragment fragment-id="byok-validate-okta" />', replace(replace(oktaValidator, '<fragment>', ''), '</fragment>', ''))
var fragmentPolicies = [
  { name: 'byok-authenticate', value: authenticationPolicy }
  { name: 'byok-strip-caller-credentials', value: sourcePolicies['byok-strip-caller-credentials'] }
  { name: 'byok-apply-caller-limits', value: renderCallerLimits(jwtTiering, tierCatalog) }
]

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

@batchSize(1)
resource callerSettings 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = [for setting in settings: {
  parent: apim
  name: '${resourcePrefix}${setting.name}'
  properties: {
    displayName: '${resourcePrefix}${setting.name}'
    value: setting.value
    secret: false
  }
}]

@batchSize(1)
resource fragments 'Microsoft.ApiManagement/service/policyFragments@2024-05-01' = [for policy in fragmentPolicies: {
  parent: apim
  name: '${resourcePrefix}${policy.name}'
  properties: {
    description: 'Shared caller authentication contract. Requires the native admission configuration and explicit feature-policy inclusion.'
    format: 'xml'
    value: replace(policy.value, '{{', '{{${resourcePrefix}')
  }
  dependsOn: [callerSettings]
}]

output fragmentIds array = [for (policy, policyIndex) in fragmentPolicies: fragments[policyIndex].id]
output configurationValid bool = configurationValid
output requiredSubscriptionAdmission bool = keyEnabled
output needsJwtProduct bool = keyEnabled && (entraTrust.enabled || oktaTrust.enabled)
output jwtProductId string = jwtProductId
output namedValueDependency array = namedValueIds
