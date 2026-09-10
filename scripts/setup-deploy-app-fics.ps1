#requires -Version 7.0
<#
.SYNOPSIS
  Adds (or removes) GitHub Actions OIDC federated credentials on the Entra deploy app
  registration used by the CI/CD `deploy.yml` workflow. Idempotent.
.DESCRIPTION
  The runner UAMI's federated credentials are managed in Bicep (gh-runner.bicep) because
  the UAMI lives in the workload subscription and is part of the deployable surface. The
  *deploy* app, however, is an Entra App Registration in the workload tenant that exists
  OUTSIDE the workload sub (no infra dependency). Bicep cannot create FICs on App
  registrations, so this script wraps `az ad app federated-credential create` with
  idempotent add/remove semantics across both Azure clouds (AzureCloud + AzureUSGovernment).

  Subject convention (same for both clouds, just different tenants):
      repo:<Repository>:environment:<EnvName>

  Issuer (constant):      https://token.actions.githubusercontent.com
  Audience (constant):    api://AzureADTokenExchange
  FIC display name:       fic-env-<EnvName>

  The script does NOT create the app registration itself (use setup-entra.ps1 or the
  azd-managed deploy app for that); it only adds the federated credentials.

.PARAMETER AppDisplayName
  Display name of the existing Entra app registration that the deploy workflow logs in as.
  Either this OR -AppId must be provided.

.PARAMETER AppId
  AppId (client ID) of the existing Entra app registration. Either this OR -AppDisplayName.

.PARAMETER Repository
  GitHub repository in `<owner>/<repo>` form. Default: gwexler_microsoft/copilot-cli-byok-azure.

.PARAMETER EnvNames
  Array of GitHub Environment names to grant via OIDC. Defaults to the four planned envs
  (comm-pilot, comm-dev, gov-pilot, gov-dev). The script ONLY adds FICs whose subjects
  don't already exist on the app, so re-running is safe.

.PARAMETER Remove
  Removes any FICs on the app whose `name` matches `fic-env-<EnvNames[*]>`.

.EXAMPLE
  ./setup-deploy-app-fics.ps1 -AppDisplayName copilot-byok-cicd
.EXAMPLE
  ./setup-deploy-app-fics.ps1 -AppDisplayName copilot-byok-cicd -EnvNames comm-pilot,comm-dev
.EXAMPLE
  ./setup-deploy-app-fics.ps1 -AppId 00000000-0000-0000-0000-000000000000 -EnvNames comm-dev -Remove
#>
[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
  [Parameter(Mandatory, ParameterSetName = 'ByName')] [string] $AppDisplayName,
  [Parameter(Mandatory, ParameterSetName = 'ById')]   [string] $AppId,
  [string] $Repository = 'gwexler_microsoft/copilot-cli-byok-azure',
  [string[]] $EnvNames = @('comm-pilot', 'comm-dev', 'gov-pilot', 'gov-dev'),
  [switch] $Remove
)

$ErrorActionPreference = 'Stop'

# --- preflight ---------------------------------------------------------------------------
$ctx = az account show 2>$null | ConvertFrom-Json
if (-not $ctx) { throw 'Run `az login` first.' }
Write-Host "Cloud:       $($ctx.environmentName)"
Write-Host "Tenant:      $($ctx.tenantId)"
Write-Host "Repo:        $Repository"
Write-Host "Env subjects:" ($EnvNames -join ', ')

# Resolve app to its object ID (the only thing `az ad app federated-credential` accepts).
if ($PSCmdlet.ParameterSetName -eq 'ByName') {
  $AppId = az ad app list --display-name $AppDisplayName --query '[0].appId' -o tsv
  if (-not $AppId) { throw "No Entra app registration named '$AppDisplayName' found in tenant $($ctx.tenantId)." }
}
$appJson = az ad app show --id $AppId -o json | ConvertFrom-Json
if (-not $appJson) { throw "App $AppId not visible in current tenant ($($ctx.tenantId))." }
Write-Host "App:         $($appJson.displayName) ($AppId)"

# --- existing FICs (avoid duplicate creation; required for Remove) ------------------------
$existing = az ad app federated-credential list --id $AppId -o json | ConvertFrom-Json
$existingByName = @{}
foreach ($f in $existing) { $existingByName[$f.name] = $f }

$issuer   = 'https://token.actions.githubusercontent.com'
$audience = 'api://AzureADTokenExchange'

foreach ($env in $EnvNames) {
  $ficName = "fic-env-$env"
  $subject = "repo:${Repository}:environment:${env}"

  if ($Remove) {
    if ($existingByName.ContainsKey($ficName)) {
      Write-Host "Removing $ficName -> $subject"
      az ad app federated-credential delete --id $AppId --federated-credential-id $existingByName[$ficName].id | Out-Null
    } else {
      Write-Host "Skip remove $ficName (not present)"
    }
    continue
  }

  if ($existingByName.ContainsKey($ficName)) {
    $cur = $existingByName[$ficName]
    if ($cur.subject -ne $subject -or $cur.issuer -ne $issuer) {
      Write-Warning "FIC '$ficName' exists with different subject/issuer. Recreating to converge."
      az ad app federated-credential delete --id $AppId --federated-credential-id $cur.id | Out-Null
    } else {
      Write-Host "OK    $ficName -> $subject"
      continue
    }
  }

  $body = @{
    name      = $ficName
    issuer    = $issuer
    subject   = $subject
    audiences = @($audience)
  } | ConvertTo-Json -Compress
  $tmp = New-TemporaryFile
  try {
    Set-Content -Path $tmp -Value $body -Encoding utf8
    az ad app federated-credential create --id $AppId --parameters "@$tmp" | Out-Null
    Write-Host "ADD   $ficName -> $subject"
  } finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
  }
}

Write-Host ''
Write-Host 'Final FIC inventory:'
az ad app federated-credential list --id $AppId -o table --query "[].{name:name,subject:subject,issuer:issuer}"
