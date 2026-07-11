// Microsoft Foundry (AIServices) account hosting Azure OpenAI model deployments, fronted by
// APIM via the OpenAI-compatible data plane (/openai/deployments/{model}/...).
//
// Differs from aoai.bicep only in `kind: 'AIServices'` and the extra cognitiveservices zone.
// The MI audience for the OpenAI-compat surface is the SAME as classic AOAI
// (https://cognitiveservices.azure.us in Gov), so APIM RBAC and policy auth are unchanged.

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

@description('Resource ID of the shared privatelink.openai.* DNS zone.')
param openaiZoneId string

@description('Resource ID of the shared privatelink.cognitiveservices.* DNS zone.')
param cognitiveZoneId string

@description('Optional resource ID of the privatelink.services.ai.* zone (Commercial only). Empty = skip.')
param aiZoneId string = ''

param peSubnetId string

param modelName string
param modelVersion string
param modelDeploymentSku string
param modelCapacity int

@description('What devs put in the request body "model" field. Becomes the Foundry deployment name.')
param exposedModelName string

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

@description('Deploy an additional standalone model on this account, independent of the mini/auto-routing tier. Used to host a Commercial-only model (e.g. gpt-5-mini) exercised via the cross-cloud commercial route. Off by default; enable only where the region hosts the model + SKU.')
param deployExtraModel bool = false
param extraModelName string = ''
param extraModelVersion string = ''
param extraModelDeploymentSku string = ''
param extraModelCapacity int = 0
param extraExposedModelName string = ''
param extraRaiPolicyName string = 'byok-coding'

var nameBody = take(replace(toLower('${namePrefix}${envName}${suffix}${regionTag}'), '-', ''), 56)
var foundryName = 'aif${nameBody}'
var peName      = take('pe-foundry-${envName}-${suffix}${empty(regionTag) ? '' : '-${regionTag}'}', 80)

resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: foundryName
  location: location
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: foundryName
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
// The extra model authors its own RAI policy only when it uses a distinct custom policy not already
// authored by the primary or mini deployment. Default (byok-coding == primary) reuses raiPolicy.
var extraNeedsOwnRai = deployExtraModel && !startsWith(extraRaiPolicyName, 'Microsoft.') && extraRaiPolicyName != raiPolicyName && extraRaiPolicyName != miniRaiPolicyName
var strictSpec = loadJsonContent('../../scripts/content-filter.byok-strict.json')
var codingSpec = loadJsonContent('../../scripts/content-filter.byok-coding.json')
var raiSpec = raiPolicyName == 'byok-coding' ? codingSpec : strictSpec
var miniRaiSpec = miniRaiPolicyName == 'byok-coding' ? codingSpec : strictSpec
var extraRaiSpec = extraRaiPolicyName == 'byok-coding' ? codingSpec : strictSpec

resource raiPolicy 'Microsoft.CognitiveServices/accounts/raiPolicies@2024-10-01' = if (isCustomRai) {
  parent: foundry
  name: raiPolicyName
  properties: {
    basePolicyName: raiSpec.basePolicyName
    mode: raiSpec.mode
    contentFilters: raiSpec.contentFilters
  }
}

resource miniRaiPolicy 'Microsoft.CognitiveServices/accounts/raiPolicies@2024-10-01' = if (miniNeedsOwnRai) {
  parent: foundry
  name: miniRaiPolicyName
  properties: {
    basePolicyName: miniRaiSpec.basePolicyName
    mode: miniRaiSpec.mode
    contentFilters: miniRaiSpec.contentFilters
  }
}

resource extraRaiPolicy 'Microsoft.CognitiveServices/accounts/raiPolicies@2024-10-01' = if (extraNeedsOwnRai) {
  parent: foundry
  name: extraRaiPolicyName
  properties: {
    basePolicyName: extraRaiSpec.basePolicyName
    mode: extraRaiSpec.mode
    contentFilters: extraRaiSpec.contentFilters
  }
}

resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry
  name: exposedModelName
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
  parent: foundry
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

// Optional additional standalone deployment (e.g. a Commercial-only showcase model reached via the
// cross-cloud commercial route). Serialized after the primary + mini deployments (dependsOn) so the
// concurrent PUTs on the same account do not race.
resource extraDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = if (deployExtraModel) {
  parent: foundry
  name: extraExposedModelName
  sku: {
    name: extraModelDeploymentSku
    capacity: extraModelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: extraModelName
      version: extraModelVersion
    }
    raiPolicyName: extraRaiPolicyName
  }
  dependsOn: extraNeedsOwnRai ? [modelDeployment, miniDeployment, extraRaiPolicy] : [modelDeployment, miniDeployment]
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
        name: 'foundry-account'
        properties: {
          privateLinkServiceId: foundry.id
          groupIds: ['account']
        }
      }
    ]
  }
  dependsOn: [
    modelDeployment
    miniDeployment
    extraDeployment
  ]
}

// Bind the PE to all relevant shared zones so whichever FQDN the platform registers resolves.
var zoneConfigs = concat(
  [
    {
      name: 'openai'
      properties: { privateDnsZoneId: openaiZoneId }
    }
    {
      name: 'cognitiveservices'
      properties: { privateDnsZoneId: cognitiveZoneId }
    }
  ],
  empty(aiZoneId) ? [] : [
    {
      name: 'servicesai'
      properties: { privateDnsZoneId: aiZoneId }
    }
  ]
)

resource peDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: pe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: zoneConfigs
  }
}

output foundryAccountName string = foundry.name
output foundryPrivateFqdn string = '${foundry.name}.privatelink.${openaiPublicSuffix}'
output foundryPrivateBaseUrl string = 'https://${foundry.name}.${openaiPublicSuffix}'
