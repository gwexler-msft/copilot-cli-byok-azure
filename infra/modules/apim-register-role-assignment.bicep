@export()
@sealed()
type registerRoleAssignmentReference = {
  @maxLength(36)
  name: string
  @maxLength(36)
  principalId: string
  scope: string
  roleDefinitionId: string
}

@export()
func selectRegisterRoleAssignmentName(apimId string, principalId string, roleDefinitionId string, existing registerRoleAssignmentReference) string => !empty(existing.name) && toLower(existing.principalId) == toLower(principalId) && toLower(existing.scope) == toLower(apimId) && toLower(last(split(existing.roleDefinitionId, '/'))) == toLower(last(split(roleDefinitionId, '/'))) ? existing.name : guid(apimId, principalId, roleDefinitionId)

param apimName string
param principalId string
param roleDefinitionId string

param existingRoleAssignment registerRoleAssignmentReference = {
  name: ''
  principalId: ''
  scope: ''
  roleDefinitionId: ''
}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource registerToApim 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: apim
  name: selectRegisterRoleAssignmentName(apim.id, principalId, roleDefinitionId, existingRoleAssignment)
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleDefinitionId
  }
}