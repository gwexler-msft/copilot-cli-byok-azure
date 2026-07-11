// RBAC for the self-hosted GitHub Actions runner UAMI. Grants the minimum data-plane and
// management-plane reads needed for CI/CD smoke tests + diagnostics. Wired from
// main.bicep alongside infra/modules/gh-runner.bicep (issue #57 phase 1).
//
// Roles assigned:
//   - Cognitive Services User on Foundry: lets the runner call /openai/* through the
//     APIM gateway with its Entra token (smoke gate sends a model request).
//   - API Management Service Reader on APIM: lets the runner read APIM configuration
//     (named values, products, subscriptions) during diagnostics — purely read-only.
//   - Log Analytics Reader on the LAW: lets the runner query App Insights / requests
//     telemetry to validate that smoke-test traffic was actually observed by APIM.

@description('Principal ID of the runner UAMI.')
param runnerPrincipalId string

@description('Foundry (kind=AIServices) account name. Empty when not deployed.')
param foundryAccountName string = ''

@description('Classic AOAI (kind=OpenAI) account name. Empty when not deployed.')
param aoaiAccountName string = ''

@description('APIM service name.')
param apimName string

@description('Log Analytics workspace name.')
param logAnalyticsName string

var roleCognitiveServicesUser   = 'a97b65f3-24c7-4388-baec-2e87135dc908' // Cognitive Services User (data-plane reader/invoker)
var roleApimServiceReader       = '71522526-b88f-4d52-b57f-d31fc3546d0d' // API Management Service Reader Role
var roleLogAnalyticsReader      = '73c42c96-874c-492b-b04d-ab87d138a893' // Log Analytics Reader

resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = if (!empty(foundryAccountName)) {
  name: empty(foundryAccountName) ? 'placeholder' : foundryAccountName
}

resource aoai 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = if (!empty(aoaiAccountName)) {
  name: empty(aoaiAccountName) ? 'placeholder' : aoaiAccountName
}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsName
}

resource runnerToFoundry 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(foundryAccountName)) {
  scope: foundry
  name: guid(foundry.id, runnerPrincipalId, roleCognitiveServicesUser)
  properties: {
    principalId: runnerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesUser)
  }
}

resource runnerToAoai 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(aoaiAccountName)) {
  scope: aoai
  name: guid(aoai.id, runnerPrincipalId, roleCognitiveServicesUser)
  properties: {
    principalId: runnerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesUser)
  }
}

resource runnerToApim 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: apim
  name: guid(apim.id, runnerPrincipalId, roleApimServiceReader)
  properties: {
    principalId: runnerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleApimServiceReader)
  }
}

resource runnerToLaw 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: law
  name: guid(law.id, runnerPrincipalId, roleLogAnalyticsReader)
  properties: {
    principalId: runnerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleLogAnalyticsReader)
  }
}
