#requires -Version 7.0
<#
.SYNOPSIS
  View or configure Azure OpenAI / Foundry content filters (responsible-AI / "raiPolicies")
  for the BYOK model deployments. Cloud-agnostic (AzureCloud + AzureUSGovernment).
.DESCRIPTION
  Microsoft applies a default content filter (Microsoft.DefaultV2) to every deployment. This
  script lets a customer:
    -Show   : list the raiPolicies on the account and which policy each deployment uses.
    -Apply  : create/update a CUSTOM raiPolicy from a JSON spec, and optionally attach it to a
              deployment (so the Bicep `raiPolicyName` param can then pin it for IaC).

  Reads the ARM endpoint from the active cloud (`az cloud show`), so it works in Gov.

  IMPORTANT (Gov + approvals):
    - Custom content-filter categories (jailbreak, protected material) and the ability to
      LOOSEN below Microsoft defaults are gated by Microsoft and differ by cloud/region.
      LOWERING filtering (raising severityThreshold or disabling a category) generally requires
      an approved Azure OpenAI Limited Access / modified-content-filter application. TIGHTENING
      (more blocking, lower thresholds) is always allowed.
    - This script never weakens filtering on its own; it just applies the spec you give it. The
      platform will reject a loosened policy if your subscription is not approved.
.PARAMETER ResourceGroup
  Resource group holding the Cognitive Services account.
.PARAMETER AccountName
  The AOAI (aif.../aoai...) Cognitive Services account name.
.PARAMETER Show
  List raiPolicies and per-deployment policy assignments. Default action if nothing else given.
.PARAMETER Apply
  Create/update a raiPolicy named -PolicyName from -ConfigPath.
.PARAMETER PolicyName
  Name of the custom raiPolicy to create/update (e.g. byok-strict).
.PARAMETER ConfigPath
  Path to a JSON file with { basePolicyName, mode, contentFilters: [...] }. See
  content-filter.sample.json.
.PARAMETER AttachToDeployment
  If set, repoints this deployment's raiPolicyName to -PolicyName after the policy is applied.
.EXAMPLE
  ./configure-content-filter.ps1 -ResourceGroup <resource-group> -AccountName <foundry-account-name> -Show
.EXAMPLE
  ./configure-content-filter.ps1 -ResourceGroup rg-... -AccountName aif... -Apply -PolicyName byok-strict -ConfigPath ./scripts/content-filter.sample.json -AttachToDeployment gpt-5.1
#>
[CmdletBinding(DefaultParameterSetName = 'Show')]
param(
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [Parameter(Mandatory)] [string] $AccountName,
  [Parameter(ParameterSetName = 'Show')] [switch] $Show,
  [Parameter(ParameterSetName = 'Apply', Mandatory)] [switch] $Apply,
  [Parameter(ParameterSetName = 'Apply', Mandatory)] [string] $PolicyName,
  [Parameter(ParameterSetName = 'Apply', Mandatory)] [string] $ConfigPath,
  [Parameter(ParameterSetName = 'Apply')] [string] $AttachToDeployment
)

$ErrorActionPreference = 'Stop'
$apiVersion = '2024-10-01'

function Get-Context {
  $ctx = az account show 2>$null | ConvertFrom-Json
  if (-not $ctx) { throw 'Run `az login` first.' }
  $arm = (az cloud show --query 'endpoints.resourceManager' -o tsv).TrimEnd('/')
  if (-not $arm) { throw 'Could not resolve ARM endpoint from active cloud.' }
  return [pscustomobject]@{ SubId = $ctx.id; Arm = $arm }
}

function Invoke-Arm {
  param([string]$Method, [string]$Url, [string]$Body)
  $args = @('rest', '--method', $Method, '--url', $Url)
  $bodyFile = $null
  if ($Body) {
    # Pass the body via a temp BOM-free UTF-8 file. Inline `--body "<json>"` is mangled by
    # PowerShell/cmd quoting on Windows (ARM then rejects it as InvalidRequestContent).
    $bodyFile = New-TemporaryFile
    [System.IO.File]::WriteAllText($bodyFile.FullName, $Body, (New-Object System.Text.UTF8Encoding($false)))
    $args += @('--headers', 'Content-Type=application/json', '--body', "@$($bodyFile.FullName)")
  }
  try {
    $out = az @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ARM call failed ($Method $Url):`n$out" }
  }
  finally {
    if ($bodyFile) { Remove-Item $bodyFile.FullName -ErrorAction SilentlyContinue }
  }
  if ($out) { return ($out | ConvertFrom-Json) }
  return $null
}

$c = Get-Context
$base = "$($c.Arm)/subscriptions/$($c.SubId)/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$AccountName"

if ($PSCmdlet.ParameterSetName -eq 'Show') {
  Write-Host "== raiPolicies on $AccountName ==" -ForegroundColor Cyan
  $policies = Invoke-Arm -Method GET -Url "$base/raiPolicies?api-version=$apiVersion"
  foreach ($p in $policies.value) {
    Write-Host ("  {0}  (base={1}, mode={2})" -f $p.name, $p.properties.basePolicyName, $p.properties.mode)
  }
  Write-Host "`n== deployments and their content filter ==" -ForegroundColor Cyan
  $deps = Invoke-Arm -Method GET -Url "$base/deployments?api-version=$apiVersion"
  foreach ($d in $deps.value) {
    Write-Host ("  {0}  ->  raiPolicyName = {1}" -f $d.name, ($d.properties.raiPolicyName ?? '(none)'))
  }
  return
}

# Apply
if (-not (Test-Path $ConfigPath)) { throw "ConfigPath not found: $ConfigPath" }
$spec = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$bodyObj = @{ properties = @{
    basePolicyName = ($spec.basePolicyName ?? 'Microsoft.DefaultV2')
    mode           = ($spec.mode ?? 'Default')
    contentFilters = $spec.contentFilters
} }
$body = $bodyObj | ConvertTo-Json -Depth 10

Write-Host "Applying raiPolicy '$PolicyName' to $AccountName ..." -ForegroundColor Cyan
Write-Warning 'Loosening filtering below Microsoft defaults requires an approved modified-content-filter application; the platform will reject an unapproved loosened policy.'
Invoke-Arm -Method PUT -Url "$base/raiPolicies/$PolicyName`?api-version=$apiVersion" -Body $body | Out-Null
Write-Host "  raiPolicy '$PolicyName' applied." -ForegroundColor Green

if ($AttachToDeployment) {
  Write-Host "Repointing deployment '$AttachToDeployment' to raiPolicy '$PolicyName' ..." -ForegroundColor Cyan
  $dep = Invoke-Arm -Method GET -Url "$base/deployments/$AttachToDeployment`?api-version=$apiVersion"
  $depBody = @{
    sku        = $dep.sku
    properties = @{
      model         = $dep.properties.model
      raiPolicyName = $PolicyName
    }
  } | ConvertTo-Json -Depth 10
  Invoke-Arm -Method PUT -Url "$base/deployments/$AttachToDeployment`?api-version=$apiVersion" -Body $depBody | Out-Null
  Write-Host "  Deployment '$AttachToDeployment' now uses '$PolicyName'." -ForegroundColor Green
  Write-Host "  To persist in IaC, set the model module's raiPolicyName param to '$PolicyName'." -ForegroundColor Yellow
}
