#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Deploy the IntelliJ BYOK bolt-on (Option A) — dedicated /intellij API + policy on the customer's
  existing Internal APIM, plus the static-IP nginx proxy VM.

.DESCRIPTION
  Runs preflight checks against the customer environment, then a subscription-scoped Bicep
  deployment (main.bicep). Everything the deployment needs comes from the parameters file
  (copy main.parameters.example.json -> main.parameters.json and fill it in).

.EXAMPLE
  ./deploy.ps1 -ParametersFile ./main.parameters.json
  ./deploy.ps1 -ParametersFile ./main.parameters.json -FoundryApiKey $env:FOUNDRY_KEY
  ./deploy.ps1 -WhatIf
#>
[CmdletBinding()]
param(
  [string]$ParametersFile = "$PSScriptRoot/main.parameters.json",
  [string]$Location,
  [string]$FoundryApiKey,
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host $m -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; exit 1 }

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Fail "Azure CLI (az) not found on PATH." }
if (-not (Test-Path $ParametersFile)) { Fail "Parameters file not found: $ParametersFile`n         Copy main.parameters.example.json to main.parameters.json and fill it in." }

$params = (Get-Content $ParametersFile -Raw | ConvertFrom-Json).parameters
function Get-ParameterValue {
  param([string]$Name)
  if ($params.PSObject.Properties.Name -contains $Name) { return $params.$Name.value }
  return $null
}

$loc = if ($Location) { $Location } else { Get-ParameterValue -Name 'location' }
if (-not $loc) { Fail "location not provided (set it in the params file or pass -Location)." }

# ---------------------------------------------------------------- Preflight
Info "== Preflight =="
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { Fail "Not signed in. Run: az login" }
Ok "Signed in: $($acct.name)  (sub $($acct.id))"
$sub = $acct.id
$armBase = (az cloud show --query endpoints.resourceManager -o tsv).TrimEnd('/')

$apimRg = Get-ParameterValue -Name 'apimResourceGroup'
$apim = Get-ParameterValue -Name 'apimName'
az apim show -g $apimRg -n $apim -o none 2>$null
if ($LASTEXITCODE -ne 0) { Fail "APIM '$apim' not found in resource group '$apimRg'." }
Ok "APIM found: $apim"

$be = Get-ParameterValue -Name 'existingBackendName'
$beUrl = "$armBase/subscriptions/$sub/resourceGroups/$apimRg/providers/Microsoft.ApiManagement/service/$apim/backends/$be?api-version=2024-05-01"
az rest --method get --url $beUrl -o none 2>$null
if ($LASTEXITCODE -eq 0) { Ok "Foundry backend found: $be" } else { Warn "Backend '$be' not found on APIM — double-check existingBackendName." }

$products = @()
$prod = Get-ParameterValue -Name 'existingProductName'
if ($prod) { $products += [string]$prod }
$additionalProducts = Get-ParameterValue -Name 'additionalProductNames'
if ($additionalProducts) { $products += @($additionalProducts) }
$products = @(
  $products |
    ForEach-Object { [string]$_ } |
    Where-Object { $_.Trim().Length -gt 0 } |
    Select-Object -Unique
)
if ($products.Count -gt 0) {
  foreach ($product in $products) {
    az apim product show -g $apimRg --service-name $apim --product-id $product -o none 2>$null
    if ($LASTEXITCODE -eq 0) { Ok "Product found: $product" }
    else { Fail "Product '$product' not found on APIM (existingProductName/additionalProductNames)." }
  }
} else { Ok "No product association (subscription keys are all-APIs scope)." }

$ip = Get-ParameterValue -Name 'proxyStaticPrivateIp'
if (-not $ip) { Fail "proxyStaticPrivateIp not set in the params file." }
$vmRg = Get-ParameterValue -Name 'vmResourceGroup'
$vmName = Get-ParameterValue -Name 'vmName'
if (-not $vmName) { $vmName = 'vm-byok-intellij-proxy' }
$proxyNicId = Get-ParameterValue -Name 'proxyNicId'
if ($proxyNicId) {
  $nic = az network nic show --ids $proxyNicId -o json 2>$null | ConvertFrom-Json
  if (-not $nic) { Fail "proxyNicId not found or not readable: $proxyNicId" }
  if ($nic.id -notmatch '^/subscriptions/([^/]+)/') { Fail "proxyNicId is not a full NIC resource ID: $proxyNicId" }
  if ($Matches[1] -ne $sub) { Fail "The supplied proxy NIC must be in the active subscription '$sub'." }
  if ($nic.location -ne $loc) { Fail "The supplied proxy NIC is in '$($nic.location)' but the proxy VM location is '$loc'." }
  if (@($nic.ipConfigurations).Count -ne 1) { Fail "The supplied proxy NIC must have exactly one IP configuration." }
  $ipConfig = $nic.ipConfigurations[0]
  if ($ipConfig.privateIPAddress -ne $ip) { Fail "proxyStaticPrivateIp '$ip' does not match the supplied NIC private IP '$($ipConfig.privateIPAddress)'." }
  if ($ipConfig.privateIPAllocationMethod -ne 'Static') { Fail "The supplied proxy NIC must use static private IP allocation." }
  if ($ipConfig.publicIPAddress) { Fail "The supplied proxy NIC must not have a public IP address." }
  if (-not $ipConfig.subnet.id) { Fail "The supplied proxy NIC is not attached to a subnet." }
  $expectedVmId = "/subscriptions/$sub/resourceGroups/$vmRg/providers/Microsoft.Compute/virtualMachines/$vmName"
  $attachedVmId = $nic.virtualMachine.id
  if ($attachedVmId -and $attachedVmId -ne $expectedVmId) { Fail "The supplied proxy NIC is already attached to another VM: $attachedVmId" }
  if ($attachedVmId) { Ok "Customer NIC already attached to this proxy VM (idempotent re-run): $($nic.name) ($ip)" }
  else { Ok "Customer NIC validated: $($nic.name) ($ip); the deployment will attach it and create no NIC." }
} else {
  $subnetId = Get-ParameterValue -Name 'vmSubnetId'
  if (-not $subnetId) { Fail "vmSubnetId is required when proxyNicId is empty." }
  $subnet = az network vnet subnet show --ids $subnetId -o json 2>$null | ConvertFrom-Json
  if (-not $subnet) { Fail "Subnet not found: $subnetId" }
  Ok "Subnet found: $($subnet.name)"

  $ownIp = az network nic show -g $vmRg -n "nic-$vmName" --query "ipConfigurations[0].privateIPAddress" -o tsv 2>$null
  if ($ownIp -eq $ip) {
    Ok "Static IP $ip already held by this deployment's NIC (idempotent re-run)."
  } elseif ($subnetId -match '/resourceGroups/([^/]+)/providers/Microsoft.Network/virtualNetworks/([^/]+)/subnets/') {
    $vnetRg = $Matches[1]; $vnetName = $Matches[2]
    try {
      $chk = az network vnet check-ip-address -g $vnetRg -n $vnetName --ip-address $ip -o json 2>$null | ConvertFrom-Json
      if ($chk -and ($chk.available -eq $false)) { Fail "Static IP $ip is already in use in VNet '$vnetName'." }
      Ok "Static IP $ip is available in '$vnetName'."
    } catch { Warn "Could not verify IP availability for $ip (continuing)." }
  }
}

# App Insights: metrics are always on. The operator supplies the name + resource group of an
# EXISTING Application Insights (same subscription as APIM); the template reads its connection
# string itself, so no secret ever has to live in the params file or the CLI invocation.
$appInsightsName = Get-ParameterValue -Name 'appInsightsName'
$appInsightsRg = Get-ParameterValue -Name 'appInsightsResourceGroup'
if (-not $appInsightsName) { Fail "appInsightsName not set in the params file (metrics are required — point it at the customer's existing Application Insights)." }
if (-not $appInsightsRg) { Fail "appInsightsResourceGroup not set in the params file (the resource group of that Application Insights, same subscription as APIM)." }
az resource show -g $appInsightsRg -n $appInsightsName --resource-type microsoft.insights/components -o none 2>$null
if ($LASTEXITCODE -ne 0) { Fail "Application Insights '$appInsightsName' not found in resource group '$appInsightsRg'." }
Ok "Application Insights '$appInsightsName' found in '$appInsightsRg'."

# When not creating the VM RG, it must already exist.
$createVmRg = Get-ParameterValue -Name 'createVmResourceGroup'
$vmRgName = Get-ParameterValue -Name 'vmResourceGroup'
if ($createVmRg -eq $false) {
  az group show -n $vmRgName -o none 2>$null
  if ($LASTEXITCODE -ne 0) { Fail "createVmResourceGroup=false but VM resource group '$vmRgName' does not exist (create it, or set createVmResourceGroup=true)." }
  Ok "VM resource group '$vmRgName' exists (deploying into it; createVmResourceGroup=false)."
}

# ---------------------------------------------------------------- Deploy
Info "`n== Deploy =="
$template = "$PSScriptRoot/main.bicep"
$common = @('--location', $loc, '--template-file', $template, '--parameters', "@$ParametersFile")
if ($FoundryApiKey) { $common += @('--parameters', "foundryApiKey=$FoundryApiKey") }

if ($WhatIf) {
  az deployment sub what-if @common
  exit $LASTEXITCODE
}

$deployName = "intellij-byok-$((Get-Date).ToString('yyyyMMddHHmmss'))"
az deployment sub create --name $deployName @common
if ($LASTEXITCODE -ne 0) { Fail "Deployment failed." }

# ---------------------------------------------------------------- Done
$out = az deployment sub show --name $deployName --query properties.outputs -o json | ConvertFrom-Json
$baseUrl = $out.clientBaseUrl.value
Info "`n== Done =="
Write-Host "Client base URL : $baseUrl"
Write-Host ""
Write-Host "Configure JetBrains AI Assistant (Settings -> Tools -> AI Assistant -> Providers & API keys):"
Write-Host "  URL     : $baseUrl"
Write-Host "  API Key : <the developer's existing APIM subscription key>"
Write-Host ""
Write-Host "Validate from an IN-VNET host (the proxy + APIM are private):"
Write-Host "  curl -s $baseUrl/models -H 'Authorization: Bearer <APIM-SUB-KEY>'"
Write-Host "  # expect HTTP 200 and an OpenAI-shaped {""object"":""list"",""data"":[...]}"
