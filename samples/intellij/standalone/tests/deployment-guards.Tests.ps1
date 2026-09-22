#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot '../deploy-containerapp.ps1'
$passed = 0
$mockState = @{}
$previousKey = $env:FOUNDRY_API_KEY
$previousExitCode = $global:LASTEXITCODE

function Get-Content {
  param([string]$LiteralPath, [switch]$Raw)
  if ($LiteralPath -ne 'mock-parameters.json') { throw 'Unexpected file read in deployment test.' }
  return ($mockState.fixture | ConvertTo-Json -Depth 20)
}

function az {
  $command = $args -join ' '
  $mockState.commands.Add($command)
  $global:LASTEXITCODE = 0
  if ($mockState.failCommand -and $command -like $mockState.failCommand) {
    $global:LASTEXITCODE = 1
    return '{}'
  }
  switch -Wildcard ($command) {
    'account show *' { return '{}' }
    'group show *' { return '{}' }
    'resource show *Microsoft.App/managedEnvironments*' { return ($mockState.environment | ConvertTo-Json -Depth 10) }
    'resource show *Microsoft.Insights/components*' { return '{}' }
    'apim api show *' { return ($mockState.api | ConvertTo-Json -Depth 10) }
    'apim product show *' { return '{}' }
    'apim show *' { return ($mockState.apim | ConvertTo-Json -Depth 10) }
    'cloud show *' { return '{"endpoints":{"resourceManager":"https://management.example.test/"}}' }
    'rest --method get *' { return '{}' }
    'deployment sub what-if *' { return '{}' }
    'deployment sub create *' { return 'https://proxy.example.test/intellij/v1' }
    default { throw "Unexpected Azure command in test: $command" }
  }
}

function Invoke-Case {
  param(
    [string]$Name,
    [scriptblock]$Arrange = {},
    [string[]]$Options = @('-ValidateOnly'),
    [string]$ExpectedError = '',
    [string]$ExpectedOperation = ''
  )
  $script:fixture = @{ parameters = @{} }
  foreach ($parameterName in @('location', 'proxyResourceGroup', 'environmentName', 'environmentResourceGroup', 'apimResourceGroup', 'apimName')) {
    $script:fixture.parameters[$parameterName] = @{ value = 'test' }
  }
  $script:fixture.parameters.proxyImage = @{ value = 'nginx:test' }
  $script:fixture.parameters.apimPrivateIp = @{ value = '192.0.2.1' }
  $script:fixture.parameters.apimGatewayHost = @{ value = 'gateway.example.test' }
  $script:fixture.parameters.configureApim = @{ value = $false }
  $script:environment = @{
    location = 'test'
    properties = @{
      provisioningState = 'Succeeded'
      vnetConfiguration = @{ internal = $true; infrastructureSubnetId = '/mock/subnet' }
    }
  }
  $script:apim = @{
    id = '/mock/apim'
    virtualNetworkType = 'Internal'
    privateIpAddresses = @('192.0.2.1')
    gatewayUrl = 'https://gateway.example.test'
    hostnameConfigurations = @()
  }
  $script:api = @{ path = 'intellij'; subscriptionRequired = $true; subscriptionKeyParameterNames = @{ header = 'api-key' } }
  $script:failCommand = ''
  $script:commands = [System.Collections.Generic.List[string]]::new()
  & $Arrange
  $mockState.fixture = $script:fixture
  $mockState.environment = $script:environment
  $mockState.apim = $script:apim
  $mockState.api = $script:api
  $mockState.failCommand = $script:failCommand
  $mockState.commands = $script:commands
  $caught = ''
  $switches = @{}
  foreach ($option in $Options) { $switches[$option.TrimStart('-')] = $true }
  try { & $helper -ParametersFile 'mock-parameters.json' @switches 6>$null | Out-Null }
  catch { $caught = $_.Exception.Message }
  if ($ExpectedError) {
    if ($caught -notlike "*$ExpectedError*") { throw "${Name}: expected '$ExpectedError', got '$caught'." }
  } elseif ($caught) { throw "${Name}: unexpected failure: $caught" }
  $deployments = @($script:commands | Where-Object { $_ -like 'deployment *' })
  if ($ExpectedOperation) {
    if ($deployments.Count -ne 1 -or $deployments[0] -notlike "deployment sub $ExpectedOperation *") {
      throw "${Name}: expected one $ExpectedOperation invocation."
    }
  } elseif ($deployments.Count) { throw "${Name}: validation/rejection reached a deployment command." }
  $script:passed++
  Write-Output "PASS: $Name"
}

function Set-PrivateEndpointFixture {
  $script:fixture.parameters.environmentIngressMode = @{ value = 'privateEndpoint' }
  $script:environment.properties.vnetConfiguration.internal = $false
  $script:environment.properties.publicNetworkAccess = 'Disabled'
  $script:environment.properties.privateEndpointConnections = @(@{
    properties = @{
      privateLinkServiceConnectionState = @{ status = 'Approved' }
      provisioningState = 'Succeeded'
    }
  })
}

try {
  $env:FOUNDRY_API_KEY = ''
  Invoke-Case 'valid private topology'
  Invoke-Case 'valid private endpoint topology' { Set-PrivateEndpointFixture }
  Invoke-Case 'private endpoint requires explicit mode' { Set-PrivateEndpointFixture; $script:fixture.parameters.Remove('environmentIngressMode') } -ExpectedError 'INTERNAL VNet-integrated'
  Invoke-Case 'private endpoint rejects public access' { Set-PrivateEndpointFixture; $script:environment.properties.publicNetworkAccess = 'Enabled' } -ExpectedError 'public access Disabled'
  Invoke-Case 'private endpoint rejects unspecified public access' { Set-PrivateEndpointFixture; $script:environment.properties.Remove('publicNetworkAccess') } -ExpectedError 'public access Disabled'
  Invoke-Case 'private endpoint rejects missing connection' { Set-PrivateEndpointFixture; $script:environment.properties.privateEndpointConnections = @() } -ExpectedError 'approved, provisioned'
  Invoke-Case 'private endpoint rejects pending connection' { Set-PrivateEndpointFixture; $script:environment.properties.privateEndpointConnections[0].properties.privateLinkServiceConnectionState.status = 'Pending' } -ExpectedError 'approved, provisioned'
  Invoke-Case 'private endpoint rejects failed connection' { Set-PrivateEndpointFixture; $script:environment.properties.privateEndpointConnections[0].properties.provisioningState = 'Failed' } -ExpectedError 'approved, provisioned'
  Invoke-Case 'private endpoint rejects missing subnet' { Set-PrivateEndpointFixture; $script:environment.properties.vnetConfiguration.infrastructureSubnetId = '' } -ExpectedError 'VNet-integrated'
  Invoke-Case 'private endpoint rejects internal topology' { Set-PrivateEndpointFixture; $script:environment.properties.vnetConfiguration.internal = $true } -ExpectedError 'external VNet-integrated'
  Invoke-Case 'private endpoint rejects internal DNS option' { Set-PrivateEndpointFixture; $script:fixture.parameters.configurePrivateDns = @{ value = $true } } -ExpectedError 'reuse existing PE DNS'
  Invoke-Case 'unknown ingress mode rejected' { $script:fixture.parameters.environmentIngressMode = @{ value = 'public' } } -ExpectedError 'environmentIngressMode'
  Invoke-Case 'DNS string boolean rejected' { $script:fixture.parameters.configurePrivateDns = @{ value = 'false' } } -ExpectedError 'JSON boolean'
  Invoke-Case 'what-if by default' -Options @() -ExpectedOperation 'what-if'
  Invoke-Case 'explicit approved deploy' -Options @('-Deploy', '-NetworkValidated') -ExpectedOperation 'create'
  Invoke-Case 'deploy requires network gate' -Options @('-Deploy') -ExpectedError 'requires -NetworkValidated'
  Invoke-Case 'mutually exclusive modes' -Options @('-Deploy', '-ValidateOnly') -ExpectedError 'not both'
  Invoke-Case 'public environment rejected' { $script:environment.properties.vnetConfiguration.internal = $false } -ExpectedError 'INTERNAL VNet-integrated'
  Invoke-Case 'missing subnet rejected' { $script:environment.properties.vnetConfiguration.infrastructureSubnetId = '' } -ExpectedError 'INTERNAL VNet-integrated'
  Invoke-Case 'missing VNet configuration rejected' { $script:environment.properties.Remove('vnetConfiguration') } -ExpectedError 'INTERNAL VNet-integrated'
  Invoke-Case 'unready environment rejected' { $script:environment.properties.provisioningState = 'Failed' } -ExpectedError 'not ready'
  Invoke-Case 'wrong region rejected' { $script:environment.location = 'other' } -ExpectedError 'location must match'
  Invoke-Case 'region display name accepted' {
    $script:fixture.parameters.location.value = 'usgovvirginia'
    $script:environment.location = 'USGov Virginia'
  }
  Invoke-Case 'public APIM rejected' { $script:apim.virtualNetworkType = 'External' } -ExpectedError 'requires Internal APIM'
  Invoke-Case 'wrong APIM IP rejected' { $script:apim.privateIpAddresses = @('192.0.2.2') } -ExpectedError 'current private VIPs'
  Invoke-Case 'wrong gateway hostname rejected' { $script:apim.gatewayUrl = 'https://other.example.test' } -ExpectedError 'does not match'
  Invoke-Case 'custom gateway hostname accepted' {
    $script:apim.gatewayUrl = 'https://other.example.test'
    $script:apim.hostnameConfigurations = @(@{ type = 'Proxy'; hostName = 'gateway.example.test' })
  }
  Invoke-Case 'wrong API path rejected' { $script:api.path = 'other' } -ExpectedError 'Existing intellij-byok API'
  Invoke-Case 'missing subscription auth rejected' { $script:api.subscriptionRequired = $false } -ExpectedError 'native api-key'
  Invoke-Case 'wrong subscription header rejected' { $script:api.subscriptionKeyParameterNames.header = 'other' } -ExpectedError 'native api-key'
  Invoke-Case 'image placeholder rejected' { $script:fixture.parameters.proxyImage.value = '<image>' } -ExpectedError 'non-placeholder'
  Invoke-Case 'string boolean rejected' { $script:fixture.parameters.configureApim.value = 'false' } -ExpectedError 'JSON boolean'
  Invoke-Case 'nginx path injection rejected' { $script:fixture.parameters.intellijApiPath = @{ value = 'intellij/;return 200;' } } -ExpectedError 'safe path segment'
  Invoke-Case 'nginx host injection rejected' { $script:fixture.parameters.apimGatewayHost.value = 'gateway.example.test;return 200;' } -ExpectedError 'must be a hostname'
  Invoke-Case 'noncanonical IP rejected' { $script:fixture.parameters.apimPrivateIp.value = '192.0.2.01' } -ExpectedError 'canonical IPv4'
  Invoke-Case 'parameter credential rejected' { $script:fixture.parameters.foundryApiKey = @{ value = 'not-a-real-key' } } -ExpectedError 'FOUNDRY_API_KEY'
  Invoke-Case 'failed environment read rejected' { $script:failCommand = 'resource show *Microsoft.App/managedEnvironments*' } -ExpectedError 'Azure preflight read failed'
  Invoke-Case 'failed API read rejected' { $script:failCommand = 'apim api show *' } -ExpectedError 'Azure preflight read failed'
  Invoke-Case 'new API requires backend settings' { $script:fixture.parameters.configureApim.value = $true } -ExpectedError 'requires existingBackendName'
  Invoke-Case 'new API uses active cloud ARM endpoint' {
    $script:fixture.parameters.configureApim.value = $true
    foreach ($name in @('existingBackendName', 'appInsightsName', 'appInsightsResourceGroup', 'existingProductName')) {
      $script:fixture.parameters[$name] = @{ value = 'test' }
    }
    $script:fixture.parameters.additionalProductNames = @{ value = @('test', 'other') }
  }
  if (@($script:commands | Where-Object { $_ -like 'rest --method get --url https://management.example.test/mock/apim/backends/test?api-version=2024-05-01 *' }).Count -ne 1) {
    throw 'Backend preflight did not use the active cloud ARM endpoint.'
  }
  if (@($script:commands | Where-Object { $_ -like 'apim product show *' }).Count -ne 2) { throw 'Product reads must be deduplicated.' }
  Write-Output "$passed deployment guard tests passed; Azure commands were mocked."
} finally {
  $env:FOUNDRY_API_KEY = $previousKey
  $global:LASTEXITCODE = $previousExitCode
}