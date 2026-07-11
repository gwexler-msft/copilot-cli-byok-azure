#requires -Version 7.0
<#
.SYNOPSIS
  Grant the register-app managed identity a Microsoft Graph application permission
  (default GroupMember.Read.All) so it can resolve a developer's security groups via
  `getMemberGroups` when the Easy Auth token omits the inline `groups` claim (group
  overage, ~200 groups). Idempotent. Cloud-agnostic (AzureCloud + AzureUSGovernment).

.DESCRIPTION
  OUT-OF-BAND DIRECTORY GRANT for the self-serve register app (issue #64 / #67).

  WHY IT EXISTS:
    When a developer is a member of more than ~200 groups, Entra drops the `groups`
    claim from the token and emits an overage marker. The register app then calls
    Microsoft Graph `POST /users/{oid}/getMemberGroups` using its own managed identity
    to resolve the security-group ids that drive tier selection. That Graph call needs
    an APPLICATION permission (`GroupMember.Read.All`, or `Directory.Read.All`) granted
    to the managed identity's service principal, WITH tenant admin consent.

  WHY IT IS A SCRIPT, NOT BICEP:
    Granting a Graph application permission to a managed identity is a DIRECTORY write
    that requires the *caller* to be Global Administrator or Privileged Role
    Administrator. In Gov tenants (and most enterprise Commercial tenants) the azd
    deploy principal deliberately does NOT hold those roles (separation of duties), and
    the Microsoft.Graph Bicep extension would hard-fail there. So we mirror the existing
    `grant-apim-mi-rbac` pattern: wired as an azd `postprovision` hook, but standalone
    and idempotent, and it DEGRADES GRACEFULLY (prints the manual command + required
    admin role and exits 0) when the caller lacks consent rights — so deployment never
    breaks. A tenant admin re-runs the identical script later.

  CONSISTENCY ACROSS CLOUDS:
    The Graph endpoint is derived from the active cloud (`az cloud show`), so the same
    script works unchanged in Commercial (graph.microsoft.com) and Gov
    (graph.microsoft.us). Microsoft Graph's well-known appId is identical in every
    national cloud.

  ALTERNATIVE (no Graph permission needed):
    Configure the register app registration's groups optional claim to "Groups assigned
    to the application" (or assign only the tier groups to the app). Then overage never
    triggers and you do not need to run this script. Pass -SkipIfNotDeployed default
    behavior leaves such tenants untouched.

  IDEMPOTENT: checks for an existing appRoleAssignment first and no-ops if present; a
  duplicate POST (returned as 400 "already exists") is also treated as success.

.PARAMETER RegisterUamiClientId
  Client (app) ID of the register-app user-assigned managed identity. Falls back to the
  azd-injected output env var $env:registerUamiClientId. Empty => register app not
  deployed => script skips (exit 0).
.PARAMETER PermissionName
  Microsoft Graph application permission (appRole value) to grant. Default
  'GroupMember.Read.All'. Use 'Directory.Read.All' for the broader equivalent.
.EXAMPLE
  ./grant-register-graph-perms.ps1 -RegisterUamiClientId <guid>
.EXAMPLE
  # As a tenant admin, after a non-admin azd provision printed the skip notice:
  az login   # sign in as Global Admin / Privileged Role Administrator (correct cloud)
  ./grant-register-graph-perms.ps1 -RegisterUamiClientId <guid>
#>
[CmdletBinding()]
param(
  [string]$RegisterUamiClientId = $env:registerUamiClientId,
  [string]$PermissionName       = 'GroupMember.Read.All'
)

$ErrorActionPreference = 'Stop'

# Microsoft Graph's appId is the same well-known GUID in every national cloud.
$graphAppId = '00000003-0000-0000-c000-000000000000'

az version *> $null 2>&1 || throw 'Azure CLI not found. Install it first.'
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' (matching the deployment cloud) first." }
Write-Host "Cloud:   $($ctx.environmentName)"
Write-Host "Account: $($ctx.user.name)"

if (-not $RegisterUamiClientId) {
  Write-Host 'Register app not deployed (registerUamiClientId is empty) — skipping Graph grant.'
  return
}

# Cloud-aware Graph endpoint (graph.microsoft.com vs graph.microsoft.us).
$graph = (az cloud show --query 'endpoints.microsoftGraphResourceId' -o tsv).TrimEnd('/')
Write-Host "Graph:   $graph"

# Resolve the managed identity's service principal (the grant target/principal).
$miSpId = az ad sp show --id $RegisterUamiClientId --query 'id' -o tsv 2>$null
if (-not $miSpId) {
  Write-Host "Could not resolve a service principal for managed identity clientId '$RegisterUamiClientId'. Has the register app been provisioned? Skipping."
  exit 0
}

# Resolve Microsoft Graph's service principal in this tenant + the target appRole id.
$graphSpId = az ad sp show --id $graphAppId --query 'id' -o tsv
if (-not $graphSpId) { throw "Could not resolve the Microsoft Graph service principal in this tenant." }
$appRoleId = az ad sp show --id $graphAppId --query "appRoles[?value=='$PermissionName' && contains(allowedMemberTypes, 'Application')].id | [0]" -o tsv
if (-not $appRoleId) { throw "Microsoft Graph exposes no application appRole named '$PermissionName'." }

Write-Host "MI SP:   $miSpId"
Write-Host "Grant:   $PermissionName ($appRoleId) on Microsoft Graph`n"

# Idempotency: is the assignment already present?
$existing = az rest --method GET `
  --uri "$graph/v1.0/servicePrincipals/$miSpId/appRoleAssignments" `
  --resource $graph -o json 2>$null | ConvertFrom-Json
if ($existing -and $existing.value) {
  $already = $existing.value | Where-Object { $_.appRoleId -eq $appRoleId -and $_.resourceId -eq $graphSpId }
  if ($already) {
    Write-Host "Already granted '$PermissionName' to the register MI — nothing to do."
    exit 0
  }
}

# Create the assignment.
$bodyFile = New-TemporaryFile
@{ principalId = $miSpId; resourceId = $graphSpId; appRoleId = $appRoleId } |
  ConvertTo-Json | Set-Content -Path $bodyFile.FullName -Encoding utf8
try {
  $out = az rest --method POST `
    --uri "$graph/v1.0/servicePrincipals/$miSpId/appRoleAssignedTo" `
    --resource $graph `
    --headers 'Content-Type=application/json' `
    --body "@$($bodyFile.FullName)" 2>&1
  if ($LASTEXITCODE -ne 0) {
    $text = "$out"
    if ($text -match 'already exists|Permission being assigned already exists') {
      Write-Host "Grant already present (reported by Graph) — treating as success."
      exit 0
    }
    if ($text -match 'Authorization_RequestDenied|Insufficient privileges|Forbidden|\b403\b') {
      Write-Warning @"
Could not grant '$PermissionName' — the signed-in account lacks directory-consent rights.

This is EXPECTED when the azd deploy principal is not a tenant admin. The deployment
itself is fine; the group-overage fallback just won't work until an admin grants this.

Have a Global Administrator or Privileged Role Administrator sign in to THIS cloud and run:

  az login                       # correct cloud (Commercial or Gov)
  ./scripts/grant-register-graph-perms.ps1 -RegisterUamiClientId $RegisterUamiClientId

Or skip Graph entirely by setting the app registration groups claim to
'Groups assigned to the application'.
"@
      exit 0   # never fail azd on a permission boundary
    }
    throw "Graph appRole assignment failed (exit $LASTEXITCODE): $text"
  }
  Write-Host "Granted '$PermissionName' to the register managed identity."
} finally {
  Remove-Item $bodyFile.FullName -Force -ErrorAction SilentlyContinue
}

Write-Host "`nDone. Register-app Graph grant is in place."
exit 0
