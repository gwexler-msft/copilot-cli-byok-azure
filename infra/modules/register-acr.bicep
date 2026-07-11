// Shared container registry (issue #64 register app + issue #94 pre-baked runner image).
//
// register: `azd deploy register` builds the Blazor image from app/register and pushes it
// here; the register Container App pulls via its UAMI (AcrPull granted below when its
// principal id is supplied).
//
// runner (#94): the pre-baked self-hosted runner image (infra/runner-image) is built into
// this same registry by `az acr build` and pulled by the runner Job's UAMI. To avoid a
// module dependency CYCLE (the ACR would otherwise need the runner UAMI principal, which is
// itself a gh-runner output that already depends on the ACR), the runner grants ITS OWN
// AcrPull inside gh-runner.bicep against this registry by name — this module only grants the
// register UAMI.
//
// The deployer authenticates with their own AAD token (`az acr login` / ACR Tasks);
// Contributor/Owner on the resource group — already required by the preprovision access gate —
// includes AcrPush, so no admin user / registry password is enabled.
//
// Created when deployRegisterApp OR (deployGhRunner && useAcrRunnerImage) (gated in main.bicep).
// The login server is surfaced as AZURE_CONTAINER_REGISTRY_ENDPOINT so azd knows where to push.

@description('Environment short name, e.g. gov-pilot, comm-pilot. Used in names.')
param envName string

@description('Stable 6-char suffix shared across the deployment for global uniqueness.')
param suffix string

@description('Azure region.')
param location string

@description('Principal ID of the register app UAMI (from apim-register-role.bicep). Granted AcrPull so the Container App can pull the image via managed identity. Empty when the registry is provisioned for the runner only (deployGhRunner without deployRegisterApp) — the runner grants its own AcrPull in gh-runner.bicep.')
param registerUamiPrincipalId string = ''

@description('Tags applied to every resource the module creates.')
param tags object = {}

// ACR names are globally unique, 5-50 chars, alphanumeric only (hyphens not allowed).
var acrName = toLower(take('acrreg${replace(envName, '-', '')}${suffix}', 50))

// Built-in AcrPull role.
var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: acrName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    adminUserEnabled: false
  }
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(registerUamiPrincipalId)) {
  scope: acr
  name: guid(acr.id, registerUamiPrincipalId, acrPullRoleId)
  properties: {
    principalId: registerUamiPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleId
  }
}

output loginServer string = acr.properties.loginServer
output name string = acr.name
output id string = acr.id
