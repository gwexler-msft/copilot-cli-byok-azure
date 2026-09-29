using none

import { selectRegisterRoleAssignmentName } from '../../infra/modules/apim-register-role-assignment.bicep'

var subscriptionId = guid('register-role-test-subscription')
var firstPrincipal = guid('register-role-test-first-principal')
var secondPrincipal = guid('register-role-test-second-principal')
var roleName = guid('register-role-test-definition')
var roleId = '/subscriptions/${subscriptionId}/resourceGroups/fixture/providers/Microsoft.Authorization/roleDefinitions/${roleName}'
var apimId = '/subscriptions/${subscriptionId}/resourceGroups/fixture/providers/Microsoft.ApiManagement/service/fixture'
var legacyName = guid('register-role-test-existing-name')
var emptyReference = { name: '', principalId: '', scope: '', roleDefinitionId: '' }
var existing = { name: legacyName, principalId: firstPrincipal, scope: apimId, roleDefinitionId: roleId }

param selections = {
  newIdentity: selectRegisterRoleAssignmentName(apimId, firstPrincipal, roleId, emptyReference)
  newIdentityAgain: selectRegisterRoleAssignmentName(apimId, firstPrincipal, roleId, emptyReference)
  recreatedIdentity: selectRegisterRoleAssignmentName(apimId, secondPrincipal, roleId, existing)
  recreatedIdentityDefault: selectRegisterRoleAssignmentName(apimId, secondPrincipal, roleId, emptyReference)
  preservedLegacy: selectRegisterRoleAssignmentName(apimId, firstPrincipal, roleId, existing)
  caseInsensitive: selectRegisterRoleAssignmentName(apimId, firstPrincipal, roleId, {
    name: legacyName
    principalId: toUpper(firstPrincipal)
    scope: toUpper(apimId)
    roleDefinitionId: toUpper('/subscriptions/${subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/${roleName}')
  })
  wrongScope: selectRegisterRoleAssignmentName(apimId, firstPrincipal, roleId, union(existing, { scope: '${apimId}-other' }))
  wrongRole: selectRegisterRoleAssignmentName(apimId, firstPrincipal, roleId, union(existing, { roleDefinitionId: '${roleId}-other' }))
  legacyName: legacyName
}