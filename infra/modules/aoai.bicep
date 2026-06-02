param namePrefix string
param envName string
param suffix string
param location string

@description('Disambiguator appended to the account name for secondary backend-pool regions. Empty = primary account (name unchanged).')
param regionTag string = ''

@description('Public DNS suffix for the openai endpoint (e.g. openai.azure.com or openai.azure.us). Used to build the private base URL.')
param openaiPublicSuffix string

@description('Resource ID of the shared privatelink.openai.* DNS zone (created by privatedns-cognitive.bicep).')
param openaiZoneId string

param peSubnetId string

param modelName string
param modelVersion string
param modelDeploymentSku string
param modelCapacity int

@description('What devs put in COPILOT_MODEL. Becomes the AOAI deployment name.')
param apimExposedModelName string

@description('Content-filter (responsible-AI) policy name applied to the deployment. Microsoft.DefaultV2 is the built-in default; set to a custom raiPolicy name (see scripts/configure-content-filter) to tighten or loosen filtering.')
param raiPolicyName string = 'Microsoft.DefaultV2'

@description('Deploy a secondary smaller "mini" model on this account (the cheap tier used by APIM auto-routing).')
param deployMiniModel bool = false
param miniModelName string = ''
param miniModelVersion string = ''
param miniModelDeploymentSku string = ''
param miniModelCapacity int = 0
param miniExposedModelName string = ''
param miniRaiPolicyName string = 'Microsoft.DefaultV2'

var nameBody = take(replace(toLower('${namePrefix}${envName}${suffix}${regionTag}'), '-', ''), 56)
var aoaiName = 'aoai${nameBody}'
var peName   = take('pe-aoai-${envName}-${suffix}${empty(regionTag) ? '' : '-${regionTag}'}', 80)

resource aoai 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: aoaiName
  location: location
  kind: 'OpenAI'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: aoaiName
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: true
    networkAcls: {
      defaultAction: 'Deny'
      virtualNetworkRules: []
      ipRules: []
    }
  }
}

resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aoai
  name: apimExposedModelName
  sku: {
    name: modelDeploymentSku
    capacity: modelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
    raiPolicyName: raiPolicyName
  }
}

// Optional secondary "mini" deployment (cheap tier for APIM auto-routing). Serialized after the
// primary deployment via dependsOn so the two PUTs on the same account do not race.
resource miniDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = if (deployMiniModel) {
  parent: aoai
  name: miniExposedModelName
  sku: {
    name: miniModelDeploymentSku
    capacity: miniModelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: miniModelName
      version: miniModelVersion
    }
    raiPolicyName: miniRaiPolicyName
  }
  dependsOn: [
    modelDeployment
  ]
}

// The PE PUT calls the account control plane, which transiently flips to 'Accepted' while a
// model deployment is in flight. Serialize the PE after the deployments so the account is back
// in 'Succeeded' state, avoiding the AccountProvisioningStateInvalid race on idempotent re-runs.
resource pe 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: peName
  location: location
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'aoai-account'
        properties: {
          privateLinkServiceId: aoai.id
          groupIds: ['account']
        }
      }
    ]
  }
  dependsOn: [
    modelDeployment
    miniDeployment
  ]
}

resource peDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: pe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'aoai'
        properties: { privateDnsZoneId: openaiZoneId }
      }
    ]
  }
}

output aoaiAccountName string = aoai.name
output aoaiPrivateFqdn string = '${aoai.name}.privatelink.${openaiPublicSuffix}'
output aoaiPrivateBaseUrl string = 'https://${aoai.name}.${openaiPublicSuffix}'
