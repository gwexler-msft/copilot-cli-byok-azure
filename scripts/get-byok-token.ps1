#requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidatePattern('^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')] [string] $AppId,
  [Parameter(Mandatory)] [ValidateSet('AzureCloud', 'AzureUSGovernment')] [string] $Cloud,
  [Parameter(Mandatory)] [ValidatePattern('^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')] [string] $TenantId,
  [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $AccountName,
  [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $AzureConfigDirectory
)

$ErrorActionPreference = 'Stop'
$previousConfig = $env:AZURE_CONFIG_DIR
$credential = $null
$raw = $null
function Write-ByokTokenTrace {
  param([string] $Event, [long] $Expires = 0)
  if ([string]::IsNullOrWhiteSpace($env:BYOK_TOKEN_TRACE_FILE)) { return }
  try {
    $entry = [ordered]@{
      event = $Event
      observedUtc = [DateTimeOffset]::UtcNow.ToString('o')
      expiresUtc = $(if ($Expires -gt 0) { [DateTimeOffset]::FromUnixTimeSeconds($Expires).ToString('o') } else { $null })
    }
    $path = [IO.Path]::GetFullPath($env:BYOK_TOKEN_TRACE_FILE)
    [IO.File]::AppendAllText($path, (($entry | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
  } catch {
    [Console]::Error.WriteLine('BYOK token trace could not be written; credential handling is unchanged.')
  }
}

try {
  $env:AZURE_CONFIG_DIR = [IO.Path]::GetFullPath($AzureConfigDirectory)
  $actualCloud = & az cloud show --query name -o tsv --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0 -or ([string]$actualCloud).Trim() -ne $Cloud) { throw 'Cloud context changed.' }
  $raw = & az account show -o json --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0) { throw 'Account lookup failed.' }
  $account = $raw | ConvertFrom-Json
  if ($account.tenantId -ne $TenantId -or $account.environmentName -ne $Cloud -or $account.user.type -ne 'user' -or $account.user.name -ne $AccountName) {
    throw 'Account context changed.'
  }
  $raw = & az account get-access-token --tenant $TenantId --scope "$AppId/.default" -o json --only-show-errors 2>$null
  if ($LASTEXITCODE -ne 0) { throw 'Token acquisition failed.' }
  $credential = $raw | ConvertFrom-Json
  $expires = 0L
  if (@($credential).Count -ne 1 -or $credential.tenant -ne $TenantId -or
      -not [long]::TryParse([string]$credential.expires_on, [ref]$expires) -or
      $expires -le [DateTimeOffset]::UtcNow.AddMinutes(1).ToUnixTimeSeconds() -or
      [string]$credential.accessToken -cnotmatch '\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z') {
    throw 'Unusable delegated token.'
  }
  Write-ByokTokenTrace -Event 'token-acquired' -Expires $expires
  Write-Output $credential.accessToken
} catch {
  Write-ByokTokenTrace -Event 'acquisition-failed'
  Write-Error 'Gateway credential unavailable. Check the pinned Azure cloud, account, cache and Entra connectivity. To sign in again, exit Copilot and rerun the BYOK launcher with -AuthMode jwt -RefreshToken -Login (add -UseDeviceCode on a VM). No credential was returned.' -ErrorAction Continue
  exit 1
} finally {
  $raw = $null
  $credential = $null
  $env:AZURE_CONFIG_DIR = $previousConfig
}
exit 0