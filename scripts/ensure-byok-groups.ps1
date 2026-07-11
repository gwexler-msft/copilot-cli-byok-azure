#requires -Version 7.0
<#
.SYNOPSIS
  Ensure the two BYOK security groups (tier mapping for the self-serve register app)
  exist, creating them when missing and the caller has rights. Idempotent.
  Cloud-agnostic (AzureCloud + AzureUSGovernment).

.DESCRIPTION
  GROUP BOOTSTRAP for the self-serve register app (issue #64). The register app maps a
  developer to an APIM product tier from their Entra security-group membership:
    - BYOK Admins      -> offboarding / admin actions  (registerAdminGroupId)
    - BYOK Power Users -> the byok-power product tier   (registerPowerGroupId)

  WHY IT EXISTS:
    Those group object-ids are consumed as Bicep PARAMS (registerAdminGroupId /
    registerPowerGroupId) at provision time to set the register container app's tier
    env vars. The ids must therefore be known BEFORE `azd provision` runs — so this is
    wired as a PREprovision hook (the grant-*-rbac / grant-register-graph-perms scripts
    are postprovision because they grant on already-created identities; group creation
    must come first).

  WHY IT IS A SCRIPT, NOT BICEP:
    Creating an Entra security group is a DIRECTORY write that requires the caller to
    hold Groups Administrator (or be a member who may create groups). The azd deploy
    principal deliberately may NOT hold that (separation of duties), and the
    Microsoft.Graph Bicep extension would hard-fail there. So we mirror the existing
    grant-* hook pattern: standalone, idempotent, and it DEGRADES GRACEFULLY (prints the
    manual command + required admin role and exits 0) when the caller lacks group-write
    rights — deployment never breaks. A tenant admin re-runs the identical script later.

  HOW THE IDS REACH BICEP:
    When resolved, the ids are written to the active azd environment via
    `azd env set registerAdminGroupId/registerPowerGroupId`. Param files that reference
    "${registerAdminGroupId}" / "${registerPowerGroupId}" then pick them up automatically
    (the right pattern for a FRESH tenant). The shipped commercial param files instead
    pin the known object-ids as literals — in that case this script is a verifying
    no-op (it confirms the groups exist) and the literal param value wins.

  OPT-IN: directory writes should not surprise an operator, so this only acts when
    MANAGE_BYOK_GROUPS is truthy (set per-env by the commercial CI jobs). Otherwise it
    prints a one-line skip notice and exits 0. Gov / non-register envs stay untouched.

  IDEMPOTENT: resolves each group by display name first and reuses it; only creates when
    absent. A duplicate-create race (reported as already-exists) is treated as success.

.PARAMETER AdminGroupName
  Display name of the admin group. Default 'BYOK Admins'.
.PARAMETER PowerGroupName
  Display name of the power-user group. Default 'BYOK Power Users'.
.PARAMETER Enable
  Master switch. Acts when -Enable is passed OR the MANAGE_BYOK_GROUPS env var is truthy.
  Otherwise the script skips with a notice and exits 0.
.EXAMPLE
  ./ensure-byok-groups.ps1 -Enable
.EXAMPLE
  # As a Groups Administrator, after a non-admin azd provision printed the skip notice:
  az login   # correct cloud (Commercial or Gov)
  ./ensure-byok-groups.ps1 -Enable
#>
[CmdletBinding()]
param(
  [string]$AdminGroupName = 'BYOK Admins',
  [string]$PowerGroupName = 'BYOK Power Users',
  [switch]$Enable
)

$ErrorActionPreference = 'Stop'

$enabled = $Enable.IsPresent -or ($env:MANAGE_BYOK_GROUPS -in @('1', 'true', 'True', 'yes', 'on'))
if (-not $enabled) {
  Write-Host 'MANAGE_BYOK_GROUPS not set — skipping BYOK group bootstrap (set it to true to enable).'
  return
}

az version *> $null 2>&1 || throw 'Azure CLI not found. Install it first.'
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' (matching the deployment cloud) first." }
Write-Host "Cloud:   $($ctx.environmentName)"
Write-Host "Account: $($ctx.user.name)`n"

# Resolve a group by display name, creating it when absent. Returns the object id, or
# $null when it does not exist and the caller cannot create it (graceful — never throws
# on a permission boundary).
function Resolve-OrCreate-Group {
  param([string]$DisplayName)

  $id = az ad group list --display-name $DisplayName --query '[0].id' -o tsv 2>$null
  if ($id) {
    Write-Host "Found '$DisplayName' -> $id"
    return $id
  }

  # mailNickname must be mail-safe (no spaces); derive from the display name.
  $nick = ($DisplayName -replace '[^A-Za-z0-9]', '')
  Write-Host "Creating '$DisplayName' (mailNickname '$nick')..."
  $out = az ad group create --display-name $DisplayName --mail-nickname $nick --query 'id' -o tsv 2>&1
  if ($LASTEXITCODE -eq 0 -and $out) {
    $newId = ("$out" -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim()
    Write-Host "Created '$DisplayName' -> $newId"
    return $newId
  }

  $text = "$out"
  # A create race: another run already made it. Re-resolve.
  if ($text -match 'already exist|exists with the same') {
    $id = az ad group list --display-name $DisplayName --query '[0].id' -o tsv 2>$null
    if ($id) { Write-Host "Found '$DisplayName' (created concurrently) -> $id"; return $id }
  }
  if ($text -match 'Authorization_RequestDenied|Insufficient privileges|Forbidden|\b403\b') {
    Write-Warning @"
Could not create '$DisplayName' — the signed-in account lacks group-creation rights.

This is EXPECTED when the azd deploy principal is not a tenant admin. Deployment continues
(tier mapping for this group is skipped until the group exists). Have a Groups Administrator
sign in to THIS cloud and run:

  az login                       # correct cloud (Commercial or Gov)
  ./scripts/ensure-byok-groups.ps1 -Enable
"@
    return $null
  }
  throw "Failed to create group '$DisplayName' (exit $LASTEXITCODE): $text"
}

$adminId = Resolve-OrCreate-Group -DisplayName $AdminGroupName
$powerId = Resolve-OrCreate-Group -DisplayName $PowerGroupName

# Publish resolved ids to the active azd environment so param files that use
# "${registerAdminGroupId}" / "${registerPowerGroupId}" substitution pick them up.
# Only set when resolved — never blank a working literal param fallback.
$azd = Get-Command azd -ErrorAction SilentlyContinue
if ($azd -and $env:AZURE_ENV_NAME) {
  if ($adminId) { azd env set registerAdminGroupId $adminId 2>$null | Out-Null }
  if ($powerId) { azd env set registerPowerGroupId $powerId 2>$null | Out-Null }
  Write-Host "`nPublished resolved group ids to azd env '$($env:AZURE_ENV_NAME)'."
} else {
  Write-Host "`nResolved group ids (azd env not detected — set params manually if needed):"
  Write-Host "  registerAdminGroupId = $adminId"
  Write-Host "  registerPowerGroupId = $powerId"
}

Write-Host "`nDone. BYOK group bootstrap complete."
