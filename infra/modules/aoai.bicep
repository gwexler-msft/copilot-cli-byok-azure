param namePrefix string
param envName string
param suffix string
param location string

@description('Disambiguator appended to the account name for secondary backend-pool regions. Empty = primary account (name unchanged).')
param regionTag string = ''

@description('Region for the private endpoint. A PE must be co-located with its subnet/VNet, so for secondary-region pool accounts this is the PRIMARY VNet region, not the account region. Defaults to the account location for the primary account.')
param peLocation string = location

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

@description('Content-filter (responsible-AI) policy name applied to the deployment. byok-coding is the shipped default (authored below from scripts/content-filter.byok-coding.json; tightened harm filters + Jailbreak in annotate-only mode so VS Code Copilot system prompts do not trip Prompt Shields). byok-strict swaps Jailbreak to blocking (authored from scripts/content-filter.byok-strict.json) — use it for stricter clients whose prompts do not look jailbreak-like. A built-in Microsoft.* name (e.g. Microsoft.DefaultV2) uses the platform policy with no authoring. Any other custom name is authored from the byok-strict spec.')
param raiPolicyName string = 'byok-coding'

@description('Deploy a secondary smaller "mini" model on this account (the cheap tier used by APIM auto-routing).')
param deployMiniModel bool = false
param miniModelName string = ''
param miniModelVersion string = ''
param miniModelDeploymentSku string = ''
param miniModelCapacity int = 0
param miniExposedModelName string = ''
param miniRaiPolicyName string = 'byok-coding'

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

// Custom responsible-AI policy. A model deployment can only reference a raiPolicy that already
// exists on the account, so any custom (non-Microsoft.*) policy must be authored here first and
// the deployment made to depend on it. Built-in Microsoft.* policies need no authoring. Both
// shipped specs (byok-coding = annotate-only Jailbreak, byok-strict = blocking Jailbreak) are
// loaded from the same JSON files the configure-content-filter helper applies, keeping a single
// source of truth. Any unrecognised custom name falls back to byok-strict. Validated accepted
// on Azure US Government.
var isCustomRai = !startsWith(raiPolicyName, 'Microsoft.')
var miniNeedsOwnRai = deployMiniModel && !startsWith(miniRaiPolicyName, 'Microsoft.') && miniRaiPolicyName != raiPolicyName
var strictSpec = loadJsonContent('../../scripts/content-filter.byok-strict.json')
var codingSpec = loadJsonContent('../../scripts/content-filter.byok-coding.json')
var raiSpec = raiPolicyName == 'byok-coding' ? codingSpec : strictSpec
var miniRaiSpec = miniRaiPolicyName == 'byok-coding' ? codingSpec : strictSpec

resource raiPolicy 'Microsoft.CognitiveServices/accounts/raiPolicies@2024-10-01' = if (isCustomRai) {
  parent: aoai
  name: raiPolicyName
  properties: {
    basePolicyName: raiSpec.basePolicyName
    mode: raiSpec.mode
    contentFilters: raiSpec.contentFilters
  }
}

resource miniRaiPolicy 'Microsoft.CognitiveServices/accounts/raiPolicies@2024-10-01' = if (miniNeedsOwnRai) {
  parent: aoai
  name: miniRaiPolicyName
  properties: {
    basePolicyName: miniRaiSpec.basePolicyName
    mode: miniRaiSpec.mode
    contentFilters: miniRaiSpec.contentFilters
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
  dependsOn: isCustomRai ? [raiPolicy] : []
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
  dependsOn: miniNeedsOwnRai ? [modelDeployment, miniRaiPolicy] : [modelDeployment]
}

// The PE PUT calls the account control plane, which transiently flips to 'Accepted' while a
// model deployment is in flight. Serialize the PE after the deployments so the account is back
// in 'Succeeded' state, avoiding the AccountProvisioningStateInvalid race on idempotent re-runs.
resource pe 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: peName
  location: peLocation
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
