#requires -Version 7.0
<#
.SYNOPSIS
  Grant the APIM managed identity the "Cognitive Services OpenAI User" role on the AOAI
  and Foundry accounts. Idempotent. Cloud-agnostic (AzureCloud + AzureUSGovernment).
.DESCRIPTION
  This is the OUT-OF-BAND RBAC step for the BYOK gateway. It is wired as an azd
  `postprovision` hook, but can also be run standalone after a raw
  `az deployment sub create`.

  WHY IT EXISTS:
    The APIM gateway authenticates to Azure OpenAI / Foundry with its managed identity
    (local auth is disabled on the accounts), so the MI needs "Cognitive Services
    OpenAI User" on each account or data-plane calls return 401 PermissionDenied.

    The Bicep `rbac` module can create these grants in-template, but ONLY when the
    deployer holds an UNCONSTRAINED Owner / User Access Administrator role. A
    *constrained* (ABAC-conditioned) Owner can create the assignment via the direct
    RBAC API (`az role assignment create`) yet the IDENTICAL assignment FAILS inside an
    ARM nested template. For that case set `assignAoaiRbac=false` in the parameters and
    let this script grant the roles via the direct API instead.

  IDEMPOTENT: `az role assignment create` returns the existing assignment (exit 0) when
  one already exists, so re-running this (or re-running `azd provision`) is harmless,
  regardless of whether the in-template RBAC module also ran.

.PARAMETER ResourceGroup
  Resource group holding APIM + the Cognitive Services accounts.
  Falls back to the azd-injected output env var $env:resourceGroup.
.PARAMETER ApimName
  APIM service name. Falls back to $env:apimName.
.PARAMETER AoaiAccountName
  Classic AOAI (kind=OpenAI) account name. Falls back to $env:aoaiAccountName. Skipped if empty.
.PARAMETER FoundryAccountName
  Foundry (kind=AIServices) account name. Falls back to $env:foundryAccountName. Skipped if empty.
.EXAMPLE
  ./grant-apim-mi-rbac.ps1 -ResourceGroup rg-copilot-byok-<env> `
    -ApimName apim-copilot-byok-<env>-<suffix> `
    -AoaiAccountName aoaicopilotbyok<env><suffix> `
    -FoundryAccountName aifcopilotbyok<env><suffix>
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup      = $env:resourceGroup,
  [string]$ApimName           = $env:apimName,
  [string]$AoaiAccountName    = $env:aoaiAccountName,
  [string]$FoundryAccountName = $env:foundryAccountName
)

$ErrorActionPreference = 'Stop'
$roleName = 'Cognitive Services OpenAI User'   # 5e0bd9bd-7b93-4f28-af87-19fc36ad61bd

az version *> $null 2>&1 || throw 'Azure CLI not found. Install it first.'
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' (matching the deployment cloud) first." }
Write-Host "Cloud:   $($ctx.environmentName)"
Write-Host "Account: $($ctx.user.name)"

if (-not $ResourceGroup) { throw 'ResourceGroup not provided and $env:resourceGroup is empty.' }
if (-not $ApimName)      { throw 'ApimName not provided and $env:apimName is empty.' }

# Resolve the APIM managed identity principalId fresh — it changes on every recreate.
$apimMi = az apim show -g $ResourceGroup -n $ApimName --query 'identity.principalId' -o tsv
if (-not $apimMi) { throw "Could not read identity.principalId from APIM '$ApimName'. Is system-assigned MI enabled?" }
Write-Host "APIM MI principalId: $apimMi`n"

function Grant-Account([string]$accountName, [string]$label) {
  if (-not $accountName) { Write-Host "$label account not deployed — skipping."; return }
  $id = az cognitiveservices account show -g $ResourceGroup -n $accountName --query id -o tsv
  if (-not $id) { throw "Could not resolve $label account '$accountName'." }
  az role assignment create `
    --assignee-object-id $apimMi `
    --assignee-principal-type ServicePrincipal `
    --role $roleName `
    --scope $id 1>$null
  if ($LASTEXITCODE -ne 0) { throw "Failed to grant '$roleName' on $label account '$accountName' (exit $LASTEXITCODE)." }
  Write-Host "Granted '$roleName' to APIM MI on $label account: $accountName"
}

Grant-Account $AoaiAccountName    'AOAI'
Grant-Account $FoundryAccountName 'Foundry'

Write-Host "`nDone. APIM MI RBAC grants are in place."
