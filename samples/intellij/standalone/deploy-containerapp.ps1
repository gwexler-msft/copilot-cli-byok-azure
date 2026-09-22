#!/usr/bin/env pwsh
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$ParametersFile,
  [switch]$Deploy,
  [switch]$NetworkValidated,
  [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
if ($Deploy -and $ValidateOnly) { throw 'Choose Deploy or ValidateOnly, not both.' }
if ($Deploy -and -not $NetworkValidated) { throw 'Deployment requires -NetworkValidated after the runbook network gate passes.' }
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI is required.' }
$parameters = (Get-Content -LiteralPath $ParametersFile -Raw | ConvertFrom-Json -AsHashtable).parameters
if ($parameters -isnot [System.Collections.IDictionary]) { throw 'Expected an ARM parameters object.' }
if ($parameters.Contains('foundryApiKey')) { throw 'Supply backend credentials through FOUNDRY_API_KEY, never the parameters file.' }

function Get-Value([string]$Name, $Default = '') {
  if ($parameters.Contains($Name)) {
    if ($parameters[$Name] -isnot [System.Collections.IDictionary] -or -not $parameters[$Name].Contains('value')) {
      throw "Parameter $Name must contain a value property."
    }
    return $parameters[$Name].value
  }
  return $Default
}

function Read-Azure([string[]]$Arguments) {
  $result = & az @Arguments --only-show-errors -o json
  if ($LASTEXITCODE -ne 0) { throw 'Azure preflight read failed; no deployment was started.' }
  return ($result -join "`n" | ConvertFrom-Json)
}

foreach ($name in @('location', 'proxyResourceGroup', 'proxyImage', 'environmentName', 'environmentResourceGroup', 'apimResourceGroup', 'apimName', 'apimPrivateIp', 'apimGatewayHost')) {
  $value = Get-Value $name
  if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or $value -match '[<>\r\n]') {
    throw "Set a non-placeholder string value for $name."
  }
}
$apiPath = Get-Value 'intellijApiPath' 'intellij'
$hostName = Get-Value 'apimGatewayHost'
$privateIp = Get-Value 'apimPrivateIp'
$parsedIp = $null
if ($apiPath -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') { throw 'intellijApiPath must be a single safe path segment.' }
if ($hostName -notmatch '^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$') { throw 'apimGatewayHost must be a hostname without scheme, port, or path.' }
if (-not [System.Net.IPAddress]::TryParse($privateIp, [ref]$parsedIp) -or $parsedIp.AddressFamily -ne 'InterNetwork' -or $parsedIp.ToString() -ne $privateIp) {
  throw 'apimPrivateIp must be a canonical IPv4 address.'
}
$configureApim = Get-Value 'configureApim' $false
if ($configureApim -isnot [bool]) { throw 'configureApim must be a JSON boolean.' }
$ingressMode = Get-Value 'environmentIngressMode' 'internal'
if ($ingressMode -isnot [string] -or $ingressMode -cnotin @('internal', 'privateEndpoint')) { throw 'environmentIngressMode must be internal or privateEndpoint.' }
$configurePrivateDns = Get-Value 'configurePrivateDns' $false
if ($configurePrivateDns -isnot [bool]) { throw 'configurePrivateDns must be a JSON boolean.' }

$null = Read-Azure @('account', 'show')
$null = Read-Azure @('group', 'show', '--name', (Get-Value 'proxyResourceGroup'))
$environment = Read-Azure @('resource', 'show', '--resource-group', (Get-Value 'environmentResourceGroup'), '--name', (Get-Value 'environmentName'), '--resource-type', 'Microsoft.App/managedEnvironments', '--api-version', '2024-10-02-preview')
if ($ingressMode -eq 'internal') {
  if ($environment.properties.vnetConfiguration.internal -ne $true -or -not $environment.properties.vnetConfiguration.infrastructureSubnetId) {
    throw 'Internal mode requires an existing INTERNAL VNet-integrated ACA environment.'
  }
} else {
  $approvedEndpoints = @($environment.properties.privateEndpointConnections | Where-Object {
    $_.properties.privateLinkServiceConnectionState.status -ceq 'Approved' -and $_.properties.provisioningState -ceq 'Succeeded'
  })
  if ($environment.properties.vnetConfiguration.internal -ne $false -or -not $environment.properties.vnetConfiguration.infrastructureSubnetId -or $environment.properties.publicNetworkAccess -cne 'Disabled' -or $approvedEndpoints.Count -eq 0) {
    throw 'Private Endpoint mode requires an external VNet-integrated environment with public access Disabled and an approved, provisioned Private Endpoint.'
  }
  if ($configurePrivateDns) { throw 'Private Endpoint mode must reuse existing PE DNS with configurePrivateDns=false.' }
}
if ($environment.properties.provisioningState -ne 'Succeeded') { throw 'The ACA environment is not ready.' }
if (($environment.location -replace ' ', '') -ne ((Get-Value 'location') -replace ' ', '')) { throw 'location must match the ACA environment location.' }
$apim = Read-Azure @('apim', 'show', '--resource-group', (Get-Value 'apimResourceGroup'), '--name', (Get-Value 'apimName'))
if ($apim.virtualNetworkType -ne 'Internal' -or $privateIp -notin @($apim.privateIpAddresses)) {
  throw 'This proof of concept requires Internal APIM and one of its current private VIPs.'
}
$gatewayHosts = @(([uri]$apim.gatewayUrl).Host) + @($apim.hostnameConfigurations | Where-Object type -eq 'Proxy' | ForEach-Object hostName)
if ($hostName -notin $gatewayHosts) { throw 'apimGatewayHost does not match an APIM gateway hostname.' }

if ($configureApim) {
  foreach ($name in @('existingBackendName', 'appInsightsName', 'appInsightsResourceGroup')) {
    if ([string]::IsNullOrWhiteSpace((Get-Value $name)) -or (Get-Value $name) -match '[<>\r\n]') { throw "configureApim=true requires $name." }
  }
  $cloud = Read-Azure @('cloud', 'show')
  $backendUrl = "$($cloud.endpoints.resourceManager.TrimEnd('/'))$($apim.id)/backends/$(Get-Value 'existingBackendName')?api-version=2024-05-01"
  $null = Read-Azure @('rest', '--method', 'get', '--url', $backendUrl)
  $null = Read-Azure @('resource', 'show', '--resource-group', (Get-Value 'appInsightsResourceGroup'), '--name', (Get-Value 'appInsightsName'), '--resource-type', 'Microsoft.Insights/components', '--api-version', '2020-02-02')
  $products = @((Get-Value 'existingProductName')) + @(Get-Value 'additionalProductNames' @())
  foreach ($product in ($products | Where-Object { $_ } | Select-Object -Unique)) {
    $null = Read-Azure @('apim', 'product', 'show', '--resource-group', (Get-Value 'apimResourceGroup'), '--service-name', (Get-Value 'apimName'), '--product-id', $product)
  }
} else {
  $api = Read-Azure @('apim', 'api', 'show', '--resource-group', (Get-Value 'apimResourceGroup'), '--service-name', (Get-Value 'apimName'), '--api-id', 'intellij-byok')
  if ($api.path -ne $apiPath -or $api.subscriptionRequired -ne $true -or $api.subscriptionKeyParameterNames.header -ne 'api-key') {
    throw 'Existing intellij-byok API must match the path and require native api-key subscription authentication.'
  }
}

Write-Host 'Control-plane preflight passed. Private DNS, routes, image pulls, TLS and SSE still require in-network validation.'
if ($ValidateOnly) { exit 0 }
$operation = if ($Deploy) { 'create' } else { 'what-if' }
$arguments = @('deployment', 'sub', $operation, '--name', 'intellij-containerapp', '--location', (Get-Value 'location'), '--template-file', "$PSScriptRoot/containerapp.bicep", '--parameters', "@$ParametersFile", '--only-show-errors')
if ($configureApim -and $env:FOUNDRY_API_KEY) { $arguments += @('--parameters', "foundryApiKey=$env:FOUNDRY_API_KEY") }
if ($Deploy) { $arguments += @('--query', 'properties.outputs.clientBaseUrl.value', '-o', 'tsv') }
& az @arguments
if ($LASTEXITCODE -ne 0) { throw 'Deployment or what-if failed.' }
exit 0