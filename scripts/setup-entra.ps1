#requires -Version 7.0
<#
.SYNOPSIS
  Creates (or removes) the Entra app registration that fronts the Copilot BYOK APIM gateway.
.DESCRIPTION
  - Creates an app registration with the given display name.
  - Adds an Application ID URI of the form api://<displayName>-<tenant-short>.
  - Exposes a delegated OAuth2 scope (default: cli.invoke) so users get a JWT scoped to this API.
  - Pre-authorizes the Azure CLI client (04b07795-8ddb-461a-bbee-02f9e1bf7b46) for that scope, so
    `az account get-access-token --resource <appIdUri>` succeeds silently for any tenant user.
  - Prints the appId, tenantId, and appIdUri values needed by infra/main.parameters.json.
  Works in both AzureCloud and AzureUSGovernment. Reads the current cloud from `az account show`.
.PARAMETER DisplayName
  App registration display name.
.PARAMETER ScopeName
  OAuth2 delegated scope value the JWT must carry. APIM policy requires this in the `scp` claim.
.PARAMETER Remove
  If set, deletes the app registration instead of creating it.
.EXAMPLE
  ./setup-entra.ps1 -DisplayName copilot-byok-gateway -ScopeName cli.invoke
.EXAMPLE
  ./setup-entra.ps1 -DisplayName copilot-byok-gateway -Remove
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $DisplayName,
  [string] $ScopeName = 'cli.invoke',
  [switch] $Remove
)

$ErrorActionPreference = 'Stop'

function Require-AzCli {
  $v = az version 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
  if (-not $v) { throw 'Azure CLI not found. Install az and re-run.' }
  $ctx = az account show 2>$null | ConvertFrom-Json
  if (-not $ctx) { throw 'Run `az login` first.' }
  return $ctx
}

$ctx = Require-AzCli
$tenantId = $ctx.tenantId
Write-Host "Cloud:       $($ctx.environmentName)"
Write-Host "Tenant:      $tenantId"
Write-Host "Account:     $($ctx.user.name)"

if ($Remove) {
  $existing = az ad app list --display-name $DisplayName --query "[0].appId" -o tsv
  if (-not $existing) { Write-Host "No app named '$DisplayName' found. Nothing to do."; return }
  Write-Host "Deleting app registration '$DisplayName' ($existing)..."
  az ad app delete --id $existing | Out-Null
  Write-Host 'Done.'
  return
}

# Microsoft Graph endpoint differs per cloud (graph.microsoft.com vs graph.microsoft.us).
# Derive it from the active cloud so this works in both Commercial and Gov.
$graph = (az cloud show --query "endpoints.microsoftGraphResourceId" -o tsv).TrimEnd('/')

# Sends a Graph PATCH using the object-id URL form. The 'applications(appId=...)'
# form breaks under the Windows az.cmd wrapper, so we always address by object id.
function Invoke-GraphAppPatch {
  param([string] $ObjectId, [hashtable] $Patch)
  $json = $Patch | ConvertTo-Json -Depth 10
  $tmp = New-TemporaryFile
  Set-Content -Path $tmp.FullName -Value $json -Encoding utf8
  try {
    az rest --method PATCH `
            --uri "$graph/v1.0/applications/$ObjectId" `
            --resource $graph `
            --headers "Content-Type=application/json" `
            --body "@$($tmp.FullName)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Graph PATCH failed (exit $LASTEXITCODE)." }
  } finally {
    Remove-Item $tmp.FullName -Force
  }
}

$existing = az ad app list --display-name $DisplayName --query "[0].appId" -o tsv
if ($existing) {
  Write-Host "App '$DisplayName' already exists with appId=$existing. Reusing."
  $appId = $existing
} else {
  Write-Host "Creating app registration '$DisplayName'..."
  $appId = az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg --query appId -o tsv
}

$objectId = az ad app show --id $appId --query "id" -o tsv
$tenantShort = $tenantId.Substring(0, 8)
$appIdUri    = "api://$DisplayName-$tenantShort"

# Reuse the existing scope id on re-runs so the value stays stable; otherwise mint one.
$scopeId = az ad app show --id $appId --query "api.oauth2PermissionScopes[?value=='$ScopeName'].id | [0]" -o tsv
if (-not $scopeId) { $scopeId = [guid]::NewGuid().ToString() }

# Step 1: identifier URI + v2 access tokens + the exposed delegated scope.
# requestedAccessTokenVersion=2 must be set in the SAME request as the identifier URI,
# or tenant policy rejects the api:// URI. v2 tokens carry aud = the app's client-id GUID.
Write-Host "Setting Application ID URI ($appIdUri), v2 tokens, and scope '$ScopeName'..."
Invoke-GraphAppPatch -ObjectId $objectId -Patch @{
  identifierUris = @($appIdUri)
  api = @{
    requestedAccessTokenVersion = 2
    oauth2PermissionScopes = @(@{
        id                      = $scopeId
        adminConsentDescription = "Invoke the Copilot BYOK gateway on behalf of the signed-in user."
        adminConsentDisplayName = "Invoke $DisplayName"
        userConsentDescription  = "Allow $DisplayName to be invoked on your behalf."
        userConsentDisplayName  = "Invoke $DisplayName"
        isEnabled               = $true
        type                    = 'User'
        value                   = $ScopeName
      })
  }
}

# Step 2: pre-authorize the Azure CLI client for the now-existing scope. This must be a
# separate request -- a scope cannot be referenced in the same PATCH that defines it.
Write-Host "Pre-authorizing Azure CLI for scope '$ScopeName'..."
Invoke-GraphAppPatch -ObjectId $objectId -Patch @{
  api = @{
    preAuthorizedApplications = @(@{
        appId                  = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'  # Azure CLI (same GUID in Commercial and Gov)
        delegatedPermissionIds = @($scopeId)
      })
  }
}

$existingSp = az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv
if (-not $existingSp) {
  Write-Host "Creating service principal for the app..."
  az ad sp create --id $appId | Out-Null
}

Write-Host ''
Write-Host '----- Save these for infra/main.parameters.json -----'
Write-Host "tenantId   : $tenantId"
Write-Host "appId      : $appId"
Write-Host "appIdUri   : $appIdUri"
Write-Host "scopeName  : $ScopeName"
Write-Host ''
Write-Host "NOTE: with v2 tokens the JWT 'aud' claim is the appId GUID ($appId),"
Write-Host "      NOT the api:// URI. The APIM validate-jwt audience must be this GUID."
Write-Host "      Clients still fetch tokens with: az account get-access-token --resource $appIdUri"
Write-Host '-----------------------------------------------------'
