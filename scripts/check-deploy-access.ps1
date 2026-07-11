#requires -Version 7.0
<#
.SYNOPSIS
  Pre-deployment access check for the BYOK gateway. Verifies the signed-in principal can
  (a) create resources and (b) grant the APIM managed identity its RBAC role. Wired as an
  azd `preprovision` hook. Cloud-agnostic (AzureCloud + AzureUSGovernment).
.DESCRIPTION
  The deployment needs two capabilities:
    1. Resource creation  -> Owner OR Contributor at subscription/RG scope.
    2. Role-assignment write (to grant the APIM MI "Cognitive Services OpenAI User")
       -> Owner, User Access Administrator, OR Role Based Access Control Administrator.

  This check inspects the principal's role assignments at subscription scope and reports
  which capabilities are present. Behaviour:
    - No resource-creation role (no Owner/Contributor)        -> HARD FAIL (exit 1).
    - Has resource creation but NO role-assignment capability -> WARN, and FAIL only if
      $env:assignAoaiRbac is "true" (the in-template RBAC module would fail). When
      assignAoaiRbac=false the grant is done out-of-band by grant-apim-mi-rbac, which
      still needs role-assignment rights, so we WARN loudly but allow the deploy.
    - Has both                                                -> PASS.

  NOTE on CONSTRAINED (ABAC) Owner: a conditional Owner shows up here as "Owner" and
  passes the role-assignment check, but the in-template RBAC module can still fail for it
  (the ABAC @Request condition is not evaluated the same way in ARM nested templates as in
  the direct RBAC API). For constrained Owners, set assignAoaiRbac=false and rely on the
  postprovision grant-apim-mi-rbac hook (direct `az role assignment create` works for them).

.PARAMETER Strict
  Treat the "missing role-assignment capability" warning as a hard failure regardless of
  assignAoaiRbac.
#>
[CmdletBinding()]
param(
  [switch]$Strict
)

$ErrorActionPreference = 'Stop'

az version *> $null 2>&1 || throw 'Azure CLI not found. Install it first.'
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' (matching the deployment cloud) first." }
$subId = $ctx.id
Write-Host "Cloud:        $($ctx.environmentName)"
Write-Host "Subscription: $($ctx.name) ($subId)"
Write-Host "Account:      $($ctx.user.name) [$($ctx.user.type)]"

# Resolve the signed-in principal's objectId (works for users; SPs use the SP objectId).
$assignee = $null
if ($ctx.user.type -eq 'user') {
  $assignee = az ad signed-in-user show --query id -o tsv 2>$null
}
if (-not $assignee) { $assignee = $ctx.user.name }  # SP/MI fallback (appId works as --assignee)

# All role assignments effective for this principal at/above subscription scope.
$scope = "/subscriptions/$subId"
$roles = az role assignment list --assignee $assignee --scope $scope --include-inherited `
  --query "[].roleDefinitionName" -o json 2>$null | ConvertFrom-Json
if (-not $roles) { $roles = @() }
$roleSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$roles)

$canCreate = $roleSet.Contains('Owner') -or $roleSet.Contains('Contributor')
$canAssign = $roleSet.Contains('Owner') -or $roleSet.Contains('User Access Administrator') `
  -or $roleSet.Contains('Role Based Access Control Administrator')

Write-Host "`nEffective roles at subscription scope:"
if ($roleSet.Count -eq 0) { Write-Host "  (none found — you may have only resource-scoped or PIM-eligible roles not yet activated)" }
else { $roleSet | Sort-Object | ForEach-Object { Write-Host "  - $_" } }

Write-Host "`nCapabilities:"
Write-Host ("  Resource creation (Owner/Contributor):                 {0}" -f ($(if ($canCreate) {'YES'} else {'NO'})))
Write-Host ("  Role assignment write (Owner/UAA/RBAC Admin):          {0}" -f ($(if ($canAssign) {'YES'} else {'NO'})))

$assignAoaiRbac = ($env:assignAoaiRbac -eq 'true')

if (-not $canCreate) {
  Write-Error "ACCESS CHECK FAILED: you need Owner or Contributor at subscription scope to provision resources. If you hold a PIM-eligible role, activate it and re-run."
  exit 1
}

if (-not $canAssign) {
  $msg = @"
WARNING: you do NOT appear to hold a role-assignment-capable role (Owner / User Access
Administrator / Role Based Access Control Administrator) at subscription scope.

The APIM managed identity must be granted 'Cognitive Services OpenAI User' on the AOAI and
Foundry accounts or data-plane calls will return 401 PermissionDenied. That grant is done
either:
  * in-template  (assignAoaiRbac=true)  -> requires this capability, OR
  * out-of-band  (assignAoaiRbac=false) -> via the postprovision grant-apim-mi-rbac hook,
                                            which ALSO requires this capability.

Either way you will need Owner/UAA. Ask an administrator to grant you User Access
Administrator on the resource group, or have them run scripts/grant-apim-mi-rbac after deploy.
"@
  Write-Warning $msg
  if ($Strict -or $assignAoaiRbac) {
    Write-Error "ACCESS CHECK FAILED: assignAoaiRbac=$($env:assignAoaiRbac) requires role-assignment capability. Set assignAoaiRbac=false to defer RBAC, or obtain Owner/UAA."
    exit 1
  }
  Write-Host "`nProceeding (assignAoaiRbac is not 'true'); remember to run scripts/grant-apim-mi-rbac after deployment."
  exit 0
}

Write-Host "`nACCESS CHECK PASSED: you can provision resources and grant the APIM MI role."
exit 0
