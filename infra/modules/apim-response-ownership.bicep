param apimName string

@maxLength(32)
param resourcePrefix string = ''

param backendCredentialPolicy string = ''

@description('Stable 32-byte random key, canonical base64. Supply through the deployment secret path; never regenerate on redeploy while retained responses depend on it.')
@secure()
@minLength(44)
@maxLength(44)
param responseOwnerKey string

@description('Previous canonical base64 key during rotation. Retain until all responses stamped with it expire or are deleted. Empty means no previous key.')
@secure()
param responseOwnerPreviousKey string = ''

@description('Exact HTTPS backend origins eligible for ownership metadata lookup, including every configured pool member. Do not accept caller-supplied origins.')
@minLength(1)
@maxLength(8)
param backendOrigins string[]

type responseStore = {
  origin: string
  backendId: string
  kind: 'foundry' | 'aoai' | 'commercial'
}

@description('Concrete account backend IDs and credential kinds for locating an owned response. Origins must also be present in backendOrigins. Use concrete members, not pool IDs.')
@minLength(1)
@maxLength(8)
param responseStores responseStore[]

@description('Pass the authentication module fragmentIds output to order ownership resources after caller authentication.')
param callerAuthFragmentIds array

@export()
var lookupSources = {
  locate: loadTextContent('../../policies/fragments/byok-locate-response-owner.xml')
  credential: loadTextContent('../../policies/fragments/byok-response-backend-credential.xml')
  read: loadTextContent('../../policies/fragments/byok-read-response-owner.xml')
  verify: loadTextContent('../../policies/fragments/byok-verify-response-owner.xml')
}
var evaluationOnly = substring(lookupSources.verify, length('<fragment>'), indexOf(lookupSources.verify, '<choose>') - length('<fragment>'))
var selectedCredentialPolicy = empty(backendCredentialPolicy) ? lookupSources.credential : backendCredentialPolicy
var locateWithCredentials = replace(lookupSources.locate, '<include-fragment fragment-id="byok-response-backend-credential" />', replace(replace(selectedCredentialPolicy, '<fragment>', ''), '</fragment>', ''))
var locateWithRead = replace(locateWithCredentials, '<include-fragment fragment-id="byok-read-response-owner" />', replace(replace(lookupSources.read, '<fragment>', ''), '</fragment>', ''))
var locatePolicy = replace(locateWithRead, '<include-fragment fragment-id="byok-evaluate-response-owner" />', evaluationOnly)
var ownershipPolicies = [
  { name: 'byok-response-owner-context', value: loadTextContent('../../policies/fragments/byok-response-owner-context.xml') }
  { name: 'byok-prepare-responses-request', value: loadTextContent('../../policies/fragments/byok-prepare-responses-request.xml') }
  { name: 'byok-read-response-owner', value: loadTextContent('../../policies/fragments/byok-read-response-owner.xml') }
  { name: 'byok-verify-response-owner', value: loadTextContent('../../policies/fragments/byok-verify-response-owner.xml') }
  { name: 'byok-locate-response-owner', value: locatePolicy }
]

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource currentKey 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: '${resourcePrefix}caller-response-owner-key'
  properties: {
    displayName: '${resourcePrefix}caller-response-owner-key'
    secret: true
    value: responseOwnerKey
  }
}

resource previousKey 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: '${resourcePrefix}caller-response-owner-key-previous'
  properties: {
    displayName: '${resourcePrefix}caller-response-owner-key-previous'
    secret: true
    value: empty(responseOwnerPreviousKey) ? '__none__' : responseOwnerPreviousKey
  }
  dependsOn: [currentKey]
}

resource allowedOrigins 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: '${resourcePrefix}caller-response-backend-origins'
  properties: {
    displayName: '${resourcePrefix}caller-response-backend-origins'
    secret: false
    value: string(backendOrigins)
  }
  dependsOn: [previousKey]
}

resource stores 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: '${resourcePrefix}caller-response-stores'
  properties: {
    displayName: '${resourcePrefix}caller-response-stores'
    secret: false
    value: string(responseStores)
  }
  dependsOn: [allowedOrigins]
}

@batchSize(1)
resource fragments 'Microsoft.ApiManagement/service/policyFragments@2024-05-01' = [for policy in ownershipPolicies: {
  parent: apim
  name: '${resourcePrefix}${policy.name}'
  properties: {
    description: 'Caller-bound stored Responses ownership. Requires authenticated context and explicit backend routing.'
    format: 'xml'
    value: replace(policy.value, '{{', '{{${resourcePrefix}')
  }
  dependsOn: [stores]
}]

output fragmentIds array = [for (policy, policyIndex) in ownershipPolicies: fragments[policyIndex].id]
output callerAuthDependency array = callerAuthFragmentIds