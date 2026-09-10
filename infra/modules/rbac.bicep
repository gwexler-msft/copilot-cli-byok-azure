@description('Classic AOAI (kind=OpenAI) account name. Empty when not deployed.')
param aoaiAccountName string = ''

@description('Foundry (kind=AIServices) account name. Empty when not deployed.')
param foundryAccountName string = ''

@description('Additional Foundry regional account names (backend-pool members) the APIM MI must also call.')
param additionalFoundryAccountNames array = []

@description('Additional AOAI regional account names (backend-pool members) the APIM MI must also call.')
param additionalAoaiAccountNames array = []

@description('Assign APIM MI the OpenAI User role on the AOAI account.')
param assignAoai bool = true

@description('Assign APIM MI the OpenAI User role on the Foundry account.')
param assignFoundry bool = true

@description('Assign the APIM managed identity the OpenAI User role. Set false when APIM MI RBAC is granted out-of-band (e.g. by a separate privileged operator).')
param assignApimMi bool = true

@description('Object IDs (users or groups) to grant "Cognitive Services OpenAI User" on BOTH accounts, for direct portal/playground + data-plane access. Empty = none.')
param playgroundPrincipalIds array = []

@description('Principal type for playgroundPrincipalIds. Use "User" for individuals, "Group" for an Entra security group.')
@allowed([ 'User', 'Group' ])
param playgroundPrincipalType string = 'User'

param apimPrincipalId string
param deployerPrincipalId string = ''

var roleCognitiveServicesOpenAIUser = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var roleCognitiveServicesOpenAIContributor = 'a001fd3d-188f-4b5d-821b-7da978bf7442'

resource aoai 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = if (assignAoai && !empty(aoaiAccountName)) {
  name: empty(aoaiAccountName) ? 'placeholder' : aoaiAccountName
}

resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = if (assignFoundry && !empty(foundryAccountName)) {
  name: empty(foundryAccountName) ? 'placeholder' : foundryAccountName
}

resource apimToAoai 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignApimMi && assignAoai && !empty(aoaiAccountName)) {
  scope: aoai
  name: guid(aoai.id, apimPrincipalId, roleCognitiveServicesOpenAIUser)
  properties: {
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAIUser)
  }
}

resource apimToFoundry 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignApimMi && assignFoundry && !empty(foundryAccountName)) {
  scope: foundry
  name: guid(foundry.id, apimPrincipalId, roleCognitiveServicesOpenAIUser)
  properties: {
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAIUser)
  }
}

// Playground / direct data-plane access for humans (or a group). Accounts have local auth
// disabled, so portal playground + SDK access require this Entra role on each account.
resource playgroundToAoai 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for pid in playgroundPrincipalIds: if (assignAoai && !empty(aoaiAccountName)) {
  scope: aoai
  name: guid(aoai.id, pid, roleCognitiveServicesOpenAIUser)
  properties: {
    principalId: pid
    principalType: playgroundPrincipalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAIUser)
  }
}]

resource playgroundToFoundry 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for pid in playgroundPrincipalIds: if (assignFoundry && !empty(foundryAccountName)) {
  scope: foundry
  name: guid(foundry.id, pid, roleCognitiveServicesOpenAIUser)
  properties: {
    principalId: pid
    principalType: playgroundPrincipalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAIUser)
  }
}]

resource deployerToAoai 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignAoai && !empty(aoaiAccountName) && !empty(deployerPrincipalId)) {
  scope: aoai
  name: guid(aoai.id, deployerPrincipalId, roleCognitiveServicesOpenAIContributor)
  properties: {
    principalId: deployerPrincipalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAIContributor)
  }
}

resource deployerToFoundry 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignFoundry && !empty(foundryAccountName) && !empty(deployerPrincipalId)) {
  scope: foundry
  name: guid(foundry.id, deployerPrincipalId, roleCognitiveServicesOpenAIContributor)
  properties: {
    principalId: deployerPrincipalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAIContributor)
  }
}

// Backend-pool members in other regions. The APIM MI mints ONE token (shared Cognitive Services
// audience) valid against every account, so it must hold the OpenAI User role on each member or
// that member silently returns 401/403 and poisons the pool. This is the must-not-forget step.
var additionalAiAccountNames = concat(additionalFoundryAccountNames, additionalAoaiAccountNames)

resource additionalAccounts 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = [for name in additionalAiAccountNames: {
  name: name
}]

resource apimToAdditional 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (name, i) in additionalAiAccountNames: if (assignApimMi) {
  scope: additionalAccounts[i]
  name: guid(additionalAccounts[i].id, apimPrincipalId, roleCognitiveServicesOpenAIUser)
  properties: {
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAIUser)
  }
}]
