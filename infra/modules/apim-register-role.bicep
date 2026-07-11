// Least-privilege identity + RBAC for the self-serve "register" web app (issue #64 / #66).
//
// The register app provisions one APIM subscription per developer via the ARM management
// plane (Microsoft.ApiManagement/service/subscriptions) and reads the key back with
// listSecrets. It must NOT be able to touch policies, named values, APIs, or backends —
// so instead of the broad "API Management Service Contributor" it gets a purpose-built
// custom role scoped to subscription CRUD + key actions + product reads.
//
// Wired from main.bicep behind `deployRegisterApp` (issue #68). Creates:
//   - a user-assigned managed identity (UAMI) the Container App runs as,
//   - a custom role definition (subscription/product management only),
//   - a role assignment of that custom role to the UAMI, scoped to the APIM service.

@description('Short prefix used in all resource names. Lowercase, alpha-only.')
param namePrefix string

@description('Environment short name, e.g. gov-pilot, comm-pilot. Used in names.')
param envName string

@description('Stable 6-char suffix shared across the deployment for global uniqueness.')
param suffix string

@description('Azure region.')
param location string

@description('APIM service name the role assignment is scoped to.')
param apimName string

@description('Tags applied to every resource the module creates.')
param tags object = {}

var uamiName = take('id-${namePrefix}-register-${envName}-${suffix}', 64)

// Deterministic GUID name for the custom role definition (stable across redeploys).
var roleDefName = guid(resourceGroup().id, 'byok-register-subscription-manager')

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiName
  location: location
  tags: tags
}

// Custom role: exactly the management-plane operations the register app needs and no more.
// - service/read              : the ARM SDK GETs the parent APIM service before child ops.
// - products/read             : tier resolution maps a group -> an existing product.
// - subscriptions/{read,write,delete} : idempotent upsert + offboarding.
// - subscriptions/listSecrets, regenerate{Primary,Secondary}Key : key fetch + rotation.
// Notably ABSENT: policy/*, namedValues/*, apis/*, backends/* writes.
resource roleDef 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: roleDefName
  properties: {
    roleName: 'BYOK Register Subscription Manager (${envName})'
    description: 'Least-privilege role for the BYOK self-serve register app: manage APIM subscriptions (CRUD + key secrets) and read products. No policy/named-value/API/backend access.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.ApiManagement/service/read'
          'Microsoft.ApiManagement/service/products/read'
          'Microsoft.ApiManagement/service/subscriptions/read'
          'Microsoft.ApiManagement/service/subscriptions/write'
          'Microsoft.ApiManagement/service/subscriptions/delete'
          'Microsoft.ApiManagement/service/subscriptions/listSecrets/action'
          'Microsoft.ApiManagement/service/subscriptions/regeneratePrimaryKey/action'
          'Microsoft.ApiManagement/service/subscriptions/regenerateSecondaryKey/action'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
    assignableScopes: [
      resourceGroup().id
    ]
  }
}

resource registerToApim 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: apim
  name: guid(apim.id, uami.id, roleDefName)
  properties: {
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleDef.id
  }
}

output uamiId string = uami.id
output uamiName string = uami.name
output uamiClientId string = uami.properties.clientId
output uamiPrincipalId string = uami.properties.principalId
output roleDefinitionId string = roleDef.id
