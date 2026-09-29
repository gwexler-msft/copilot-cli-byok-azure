#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot '../get-byok-token.ps1'
$previousConfig = $env:AZURE_CONFIG_DIR
$previousExitCode = $global:LASTEXITCODE
$previousProfile = $env:USERPROFILE
$previousTrace = $env:BYOK_TOKEN_TRACE_FILE
$previousPath = $env:PATH
$savedEnvironment = @{}
Get-ChildItem Env: | Where-Object { $_.Name -like 'COPILOT_*' } | ForEach-Object { $savedEnvironment[$_.Name] = $_.Value }
$temporaryProfile = Join-Path ([IO.Path]::GetTempPath()) ('byok-credential-tests-' + [guid]::NewGuid().ToString('N'))
$appId = [guid]::NewGuid().ToString()
$tenantId = [guid]::NewGuid().ToString()
$state = @{}
$passed = 0

function az {
  $global:LASTEXITCODE = 0
  $command = $args -join ' '
  if ($env:AZURE_CONFIG_DIR -ne $state.config) { throw 'CLI cache was not pinned.' }
  if ($command -like $state.failCommand) { $global:LASTEXITCODE = 1; return 'private-error-details' }
  switch -Wildcard ($command) {
    'version *' { return '{"azure-cli":"2.90.0"}' }
    'cloud show *' { return $state.cloud }
    'account show*' {
      switch ($state.accountFailure) {
        'empty' { return }
        'failed' { $global:LASTEXITCODE = 1; return }
        'failed-json' { $global:LASTEXITCODE = 1; return ($state.account | ConvertTo-Json -Depth 5 -Compress) }
        'malformed' { return 'private-error-details' }
        'terminating-error' { throw 'private-error-details' }
      }
      return ($state.account | ConvertTo-Json -Depth 5 -Compress)
    }
    'account get-access-token *' {
      $staticToken = $command -like '*--query accessToken -o tsv*'
      if ($args -contains 'login' -or $command -notlike "*--scope $appId/.default*" -or
          (-not $staticToken -and $command -notlike "*--tenant $tenantId*")) { throw 'Unexpected token scope.' }
      $state.requests++
      if ($staticToken) { return $state.token.accessToken }
      return ($state.token | ConvertTo-Json -Compress)
    }
    default { throw 'Unexpected Azure command.' }
  }
}

function copilot {
  $global:LASTEXITCODE = 0
  if (($args -join ' ') -ne 'help providers') { throw 'Unexpected Copilot request in unit tests.' }
  if ($state.legacyCli) { return 'Legacy provider help' }
  'COPILOT_PROVIDER_API_KEY_COMMAND'
}

function node {
  $global:LASTEXITCODE = 0
  if([IO.Path]::GetFileName($args[0]) -ne 'token.mjs' -or $args[1] -cne '--config' -or $args[2] -cne $state.oktaConfig){throw 'Unexpected Okta helper invocation.'}
  if($state.oktaFailed){$global:LASTEXITCODE=1;return}
  $state.oktaToken
}

function Read-Host { return 'n' }

function Invoke-TokenCase {
  param([string] $Name, [scriptblock] $Arrange = {}, [switch] $Reject, [string] $Cloud = 'AzureCloud')
  $state.Clear()
  $state.config = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'byok-mock-cache'))
  $state.cloud = $Cloud
  $state.account = @{ tenantId = $tenantId; environmentName = $Cloud; user = @{ name = 'fixture-user'; type = 'user' } }
  $state.token = @{ tenant = $tenantId; expires_on = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds(); accessToken = 'fixture.payload.signature' }
  $state.failCommand = 'no-match'
  $state.requests = 0
  & $Arrange
  $env:AZURE_CONFIG_DIR = 'original-cache'
  $output = @(& $helper -AppId $appId -Cloud $Cloud -TenantId $tenantId -AccountName fixture-user -AzureConfigDirectory $state.config 2>&1)
  if ($env:AZURE_CONFIG_DIR -ne 'original-cache') { throw "${Name}: parent cache changed." }
  $stdout = @($output | Where-Object { $_ -is [string] })
  if ($Reject) {
    if ($LASTEXITCODE -eq 0 -or $stdout.Count -ne 0 -or ($output | Out-String) -match 'private-error-details|fixture\.payload\.signature') { throw "${Name}: credential failure was not closed and sanitized." }
    if (($output | Out-String) -notlike '*Gateway credential unavailable*-Login*-UseDeviceCode*No credential was returned*') { throw "${Name}: credential failure lacks actionable sign-in guidance." }
  } else {
    if ($LASTEXITCODE -ne 0 -or $stdout.Count -ne 1 -or $stdout[0] -ne $state.token.accessToken -or $state.requests -ne 1) { throw "${Name}: expected exactly one token and one token acquisition." }
  }
  $script:passed++
  Write-Output "PASS: $Name"
}

try {
  $env:BYOK_TOKEN_TRACE_FILE = $null
  Invoke-TokenCase 'Commercial token-only output'
  Invoke-TokenCase 'Government token-only output' -Cloud AzureUSGovernment
  Invoke-TokenCase 'fresh acquisition on the next invocation' { $state.token.accessToken = 'refreshed.payload.signature' }
  Invoke-TokenCase 'cloud mismatch' { $state.cloud = 'AzureUSGovernment' } -Reject
  Invoke-TokenCase 'tenant mismatch' { $state.account.tenantId = [guid]::NewGuid().ToString() } -Reject
  Invoke-TokenCase 'account switch' { $state.account.user.name = 'other-user' } -Reject
  Invoke-TokenCase 'application identity rejected' { $state.account.user.type = 'servicePrincipal' } -Reject
  Invoke-TokenCase 'token failure is sanitized' { $state.failCommand = 'account get-access-token *' } -Reject
  Invoke-TokenCase 'wrong token tenant' { $state.token.tenant = [guid]::NewGuid().ToString() } -Reject
  Invoke-TokenCase 'expired token rejected' { $state.token.expires_on = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToUnixTimeSeconds() } -Reject
  Invoke-TokenCase 'near-expiry token rejected' { $state.token.expires_on = [DateTimeOffset]::UtcNow.AddSeconds(20).ToUnixTimeSeconds() } -Reject
  Invoke-TokenCase 'missing expiration rejected' { $state.token.Remove('expires_on') } -Reject
  Invoke-TokenCase 'malformed token rejected' { $state.token.accessToken = 'not-a-jwt' } -Reject
  Invoke-TokenCase 'multiline credential rejected' { $state.token.accessToken = "fixture.payload.signature`nextra" } -Reject
  Invoke-TokenCase 'trailing newline credential rejected' { $state.token.accessToken = "fixture.payload.signature`n" } -Reject
  $null = New-Item -ItemType Directory -Path $temporaryProfile -Force
  $tracePath = Join-Path $temporaryProfile 'token-renewal.log'
  if (Test-Path -LiteralPath $tracePath) { throw 'Disabled tracing created a file.' }
  $env:BYOK_TOKEN_TRACE_FILE = $tracePath
  $initialExpiry = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
  Invoke-TokenCase 'trace first usable credential' { $state.token.expires_on = $initialExpiry }
  Invoke-TokenCase 'trace cached credential reuse' { $state.token.expires_on = $initialExpiry }
  Invoke-TokenCase 'trace renewed credential expiry' { $state.token.expires_on = $initialExpiry + 3600; $state.token.accessToken = 'renewed.payload.signature' }
  Invoke-TokenCase 'trace sanitized acquisition failure' { $state.failCommand = 'account get-access-token *' } -Reject
  $trace = @(Get-Content -LiteralPath $tracePath | ForEach-Object { $_ | ConvertFrom-Json })
  if ($trace.Count -ne 4 -or $trace[0].event -cne 'token-acquired' -or $trace[1].event -cne 'token-acquired' -or
      $trace[2].event -cne 'token-acquired' -or $trace[3].event -cne 'acquisition-failed' -or $null -ne $trace[3].expiresUtc -or
      $trace[0].expiresUtc -cne $trace[1].expiresUtc -or [DateTimeOffset]$trace[2].expiresUtc -le [DateTimeOffset]$trace[1].expiresUtc) {
    throw 'Token trace does not distinguish reuse, a newer expiry and failure.'
  }
  foreach ($entry in $trace) {
    if ((($entry.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'event,expiresUtc,observedUtc') { throw 'Trace contains an unexpected field.' }
  }
  foreach ($line in Get-Content -LiteralPath $tracePath) {
    $document = [Text.Json.JsonDocument]::Parse($line)
    try {
      if ([DateTimeOffset]::Parse($document.RootElement.GetProperty('observedUtc').GetString()).Offset -ne [TimeSpan]::Zero) {
        throw 'Trace timestamp is not UTC.'
      }
    } finally { $document.Dispose() }
  }
  $traceText = Get-Content -LiteralPath $tracePath -Raw
  foreach ($sensitive in @($appId, $tenantId, 'fixture-user', 'payload', 'private-error-details', $state.config)) {
    if ($traceText.Contains($sensitive)) { throw 'Token trace leaked credential or identity data.' }
  }
  $env:BYOK_TOKEN_TRACE_FILE = Join-Path $temporaryProfile 'missing/token.log'
  Invoke-TokenCase 'trace write failure preserves token-only output'
  $env:BYOK_TOKEN_TRACE_FILE = $null
  Invoke-TokenCase 'wrapper fixture reset'
  $state.config = Join-Path $temporaryProfile 'signed-in-cache'
  $null = New-Item -ItemType Directory -Path $state.config -Force
  $env:USERPROFILE = $temporaryProfile
  $env:AZURE_CONFIG_DIR = $state.config
  $env:COPILOT_PROVIDER_HEADERS = $null
  $env:COPILOT_PROVIDER_API_KEY = 'stale-key'
  $env:COPILOT_PROVIDER_BEARER_TOKEN = 'stale-bearer'
  $env:COPILOT_PROVIDER_API_KEY_COMMAND = 'stale-command'
  $wrapper = Join-Path $PSScriptRoot '../copilot-cli-byok.ps1'
  & $wrapper -AuthMode jwt -Cloud AzureCloud -RefreshToken -AppId $appId -ApimBaseUrl https://gateway.example.test -Model gpt-4o-mini -PrintOnly 6>$null
  if ($env:COPILOT_PROVIDER_API_KEY -or $env:COPILOT_PROVIDER_BEARER_TOKEN -or -not $env:COPILOT_PROVIDER_API_KEY_COMMAND) { throw 'Refresh mode left conflicting credential sources.' }
  $commandMatch = [regex]::Match($env:COPILOT_PROVIDER_API_KEY_COMMAND, '-EncodedCommand ([A-Za-z0-9+/=]+)$')
  if (-not $commandMatch.Success) { throw 'Expected an encoded token-helper command.' }
  $invocation = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($commandMatch.Groups[1].Value))
  if ($invocation.Contains($state.token.accessToken) -or -not $invocation.Contains($state.config) -or -not $invocation.Contains($tenantId)) { throw 'Credential command does not pin only nonsecret configuration.' }
  $first = Invoke-Expression $invocation
  $state.token.accessToken = 'renewed.payload.signature'
  $second = Invoke-Expression $invocation
  if ($first -ne 'fixture.payload.signature' -or $second -ne 'renewed.payload.signature') { throw 'Configured command did not reacquire the token.' }
  Write-Output 'PASS: configured command reacquires credentials and clears static sources'
  $previousCommand = $env:COPILOT_PROVIDER_API_KEY_COMMAND
  $previousRequests = $state.requests
  foreach ($refresh in @($false, $true)) {
    foreach ($failure in @('empty', 'failed', 'failed-json', 'malformed', 'terminating-error')) {
      $state.accountFailure = $failure
      $message = ''
      try {
        & $wrapper -AuthMode jwt -Cloud AzureCloud -RefreshToken:$refresh -AppId $appId -ApimBaseUrl https://gateway.example.test -Model gpt-4o-mini -PrintOnly 6>$null
      } catch { $message = $_.Exception.Message }
      if ($message -notlike '*No usable Azure CLI account*-Login*AZURE_CONFIG_DIR*' -or
          $message.Contains('private-error-details') -or $state.requests -ne $previousRequests -or
          $env:AZURE_CONFIG_DIR -cne $state.config -or $env:COPILOT_PROVIDER_API_KEY_COMMAND -cne $previousCommand -or
          $env:COPILOT_PROVIDER_API_KEY -or $env:COPILOT_PROVIDER_BEARER_TOKEN) {
        throw 'Account lookup failure was not sanitized or changed active authentication.'
      }
    }
  }
  $state.accountFailure = $null
  Write-Output 'PASS: ten wrapper account failures give cloud/cache guidance without token acquisition or credential changes'
  & {
    function Get-Command {
      [CmdletBinding()]
      param([string] $Name)
      if ($Name -eq 'az') { return }
      Microsoft.PowerShell.Core\Get-Command @PSBoundParameters
    }
    function Read-Host { return 'n' }
    $message = ''
    try {
      & $wrapper -AuthMode jwt -Cloud AzureCloud -RefreshToken -AppId $appId -ApimBaseUrl https://gateway.example.test -Model gpt-4o-mini -PrintOnly 6>$null
    } catch { $message = $_.Exception.Message }
    if ($message -notlike '*JWT mode requires Azure CLI (az)*-InstallDeps*' -or $state.requests -ne $previousRequests -or
        $env:COPILOT_PROVIDER_API_KEY_COMMAND -cne $previousCommand) { throw 'Missing Azure CLI prerequisite was not handled safely.' }
  }
  Write-Output 'PASS: missing Azure CLI reports its prerequisite without automatic installation or sign-in'
  $parseErrors = $null
  $wrapperAst = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $wrapper).Path, [ref]$null, [ref]$parseErrors)
  if ($parseErrors.Count) { throw 'Launcher syntax errors prevent prerequisite tests.' }
  $bootstrapFunctions = @{}
  foreach ($name in @('Initialize-AzureCli', 'Install-AzureCli', 'Resolve-AzureCliCommand', 'Resolve-ByokAzureCloud', 'Read-ByokAzureAccount', 'Initialize-ByokAzureAccount', 'Write-ByokJwtAccessGuidance')) {
    $definition = $wrapperAst.Find({ param($ast) $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq $name }, $true)
    if (-not $definition) { throw 'Expected prerequisite function is missing.' }
    $bootstrapFunctions[$name] = $definition.Body.GetScriptBlock()
  }
  & {
    Set-Item Function:Write-ByokJwtAccessGuidance $bootstrapFunctions['Write-ByokJwtAccessGuidance']
    foreach ($case in @('missing', 'empty', 'null', 'standard', 'power', 'custom', 'both', 'non-array', 'malformed', 'oversized')) {
      $payload = @{ sub = 'private-fixture-subject'; aud = $appId }
      switch ($case) {
        'empty' { $payload.roles = @() }
        'null' { $payload.roles = $null }
        'standard' { $payload.roles = @('BYOK.Standard') }
        'power' { $payload.roles = @('BYOK.Power') }
        'custom' { $payload.roles = @('private-custom-role') }
        'both' { $payload.roles = @('BYOK.Standard', 'BYOK.Power') }
        'non-array' { $payload.roles = 'private-custom-role' }
      }
      $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
      $token = 'e30.' + $encoded + '.AA'
      if ($case -eq 'malformed') { $token = 'fixture.payload.signature' }
      if ($case -eq 'oversized') { $token = 'e30.' + ('A' * 65536) + '.AA' }
      $output = @(Write-ByokJwtAccessGuidance -Token $token 3>&1)
      $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
      $expectedWarnings = if ($case -in @('missing', 'empty', 'null')) { 1 } else { 0 }
      $text = $output | Out-String
      if ($output.Count -ne $warnings.Count -or $warnings.Count -ne $expectedWarnings -or
          ($expectedWarnings -and ($text -notlike '*If group-based JWT tiers are enabled*-Login*-UseDeviceCode*not an authorization check*')) -or
          $text.Contains($token) -or $text.Contains($appId) -or $text.Contains('private-fixture-subject') -or $text.Contains('private-custom-role')) {
        throw ('JWT access guidance was not advisory-only and sanitized: ' + $case)
      }
    }
  }
  Write-Output 'PASS: ten JWT guidance cases warn only on absent app roles without leaking claims or rejecting custom/flat configurations'
  $savedToken = $state.token.accessToken
  try {
    foreach ($refresh in @($false, $true)) {
      foreach ($hasRole in @($false, $true)) {
        $payload = @{ sub = 'private-fixture-subject'; aud = $appId }
        if ($hasRole) { $payload.roles = @('BYOK.Standard') }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $state.token.accessToken = 'e30.' + $encoded + '.AA'
        $requestsBefore = $state.requests
        $output = @(& $wrapper -AuthMode jwt -Cloud AzureCloud -RefreshToken:$refresh -AppId $appId -ApimBaseUrl https://gateway.example.test -Model gpt-4o-mini -PrintOnly 3>&1 6>&1)
        $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $text = $output | Out-String
        if ($state.requests -ne $requestsBefore + 1 -or $warnings.Count -ne $(if ($hasRole) { 0 } else { 1 }) -or
            $text -notlike '*APIM authorization has not been checked*' -or $text -notlike '*-RefreshToken alone may reuse the cache*' -or
            $text.Contains($state.token.accessToken) -or $text.Contains('private-fixture-subject') -or $text.Contains($appId)) {
          throw 'Launcher JWT guidance leaked claims, changed acquisition count or failed to distinguish token acquisition from authorization.'
        }
      }
    }
  } finally {
    $state.token.accessToken = $savedToken
    $env:COPILOT_PROVIDER_API_KEY = $null
    $env:COPILOT_PROVIDER_API_KEY_COMMAND = $previousCommand
  }
  Write-Output 'PASS: static and renewable launcher preflight warns about missing roles with one token request and no credential disclosure'
  & {
    Set-Item Function:Resolve-ByokAzureCloud $bootstrapFunctions['Resolve-ByokAzureCloud']
    function Read-Host { return 'AzureUSGovernment' }
    foreach ($case in @(
      @{ url = 'https://fixture.azure-api.us/openai'; expected = 'AzureUSGovernment' },
      @{ url = 'https://fixture.azure-api.net/openai'; expected = 'AzureCloud' },
      @{ url = 'https://FIXTURE.AZURE-API.US./openai'; expected = 'AzureUSGovernment' },
      @{ url = 'https://gateway.example.test/openai'; cloud = 'AzureCloud'; expected = 'AzureCloud' },
      @{ url = 'https://gateway.example.test/openai'; interactive = $true; expected = 'AzureUSGovernment' },
      @{ url = 'https://fixture.azure-api.us/openai'; cloud = 'AzureCloud' },
      @{ url = 'https://fixture.azure-api.net/openai'; cloud = 'AzureUSGovernment' },
      @{ url = 'https://fixture.azure-api.us.example.test/openai' },
      @{ url = 'https://notazure-api.us/openai' },
      @{ url = 'https://gateway.example.test/openai' },
      @{ url = 'http://fixture.azure-api.us/openai' },
      @{ url = 'https://user@fixture.azure-api.us/openai' },
      @{ url = 'https://fixture.azure-api.us/openai?cloud=AzureCloud' },
      @{ url = 'https://fixture.azure-api.us/openai#fragment' },
      @{ url = 'not a URL'; cloud = 'AzureCloud' }
    )) {
      $result = $null
      $rejected = $false
      try { $result = Resolve-ByokAzureCloud -GatewayUrl $case.url -Cloud $case.cloud -Interactive:([bool]$case.interactive) }
      catch { $rejected = $true }
      if ($rejected -ne (-not [bool]$case.expected) -or $result -cne $case.expected) { throw 'Gateway cloud inference did not enforce the hostname boundary.' }
    }
  }
  Write-Output 'PASS: fifteen cloud-inference cases reject ambiguous URLs and conflicting cloud choices'
  & {
    Set-Item Function:Read-ByokAzureAccount $bootstrapFunctions['Read-ByokAzureAccount']
    Set-Item Function:Initialize-ByokAzureAccount $bootstrapFunctions['Initialize-ByokAzureAccount']
    $savedProfile = $env:USERPROFILE
    $savedCache = $env:AZURE_CONFIG_DIR
    function Initialize-AzureCli {
      param([switch] $AllowInstall, [switch] $Interactive)
      $loginState.prerequisites++
      if ($loginState.prerequisiteFailure) { throw 'Synthetic Azure CLI prerequisite failure.' }
      if ($loginState.publishRace) {
        $null = New-Item -ItemType Directory -Path $loginState.cache -ErrorAction Stop
        [IO.File]::WriteAllText((Join-Path $loginState.cache 'preserve.txt'), 'unchanged')
      }
    }
    function Read-Host {
      $loginState.prompts++
      if ($loginState.prompts -eq 1) { return $loginState.answer }
      return $loginState.expectedTenant
    }
    function az {
      $global:LASTEXITCODE = 0
      $isStaging = -not $loginState.existing -and
        (Split-Path -Path $env:AZURE_CONFIG_DIR -Parent) -ceq (Split-Path -Path $loginState.cache -Parent) -and
        (Split-Path -Path $env:AZURE_CONFIG_DIR -Leaf) -cmatch '^\.byok-cache-setup-[a-f0-9]{32}$'
      if ($env:AZURE_CONFIG_DIR -cne $loginState.cache -and -not $isStaging) { throw 'Login used the wrong cache.' }
      switch ($args[0] + ' ' + $args[1]) {
        'cloud show' { return $loginState.cloud }
        'cloud set' {
          if ($loginState.existing -or -not $isStaging) { throw 'Cloud initialization must use an owned staging cache.' }
          if (($args -join ' ') -cne ('cloud set --name ' + $loginState.target + ' --output none --only-show-errors')) { throw 'Unexpected cloud initialization.' }
          $loginState.cloudSets++
          if ($loginState.cloudSetFailure) { $global:LASTEXITCODE = 1; return }
          $loginState.cloud = $loginState.target
        }
        'account show' {
          if (-not $loginState.account) { $global:LASTEXITCODE = 1; return }
          return ($loginState.account | ConvertTo-Json -Depth 5 -Compress)
        }
        'login --tenant' {
          if ($isStaging -or -not (Test-Path -LiteralPath $loginState.cache)) { throw 'Sign-in must use the completed cache, not staging.' }
          $expectedArguments = @('login', '--tenant', $loginState.expectedTenant, '--scope', ($loginState.expectedAppId + '/.default'), '--allow-no-subscriptions', '--output', 'none')
          if ($loginState.device) { $expectedArguments += '--use-device-code' }
          if (($args -join '|') -cne ($expectedArguments -join '|')) { throw 'Sign-in did not use the exact tenant, gateway scope and output restrictions.' }
          $loginState.logins++
          if ($loginState.failed) { $global:LASTEXITCODE = 1; return }
          $loginState.account = @{ tenantId = $loginState.expectedTenant; environmentName = $loginState.target; user = @{ name = 'fixture-user'; type = 'user' } }
          switch ($loginState.after) {
            'tenant' { $loginState.account.tenantId = [guid]::NewGuid().ToString() }
            'cloud' { $loginState.cloud = 'OtherCloud' }
            'principal' { $loginState.account.user.type = 'servicePrincipal' }
            'user' { $loginState.account.user.name = 'other-user' }
          }
        }
        default { throw 'First-run setup attempted an unexpected Azure operation.' }
      }
    }
    try {
      $cases = @(
        @{ name = 'government-device'; target = 'AzureUSGovernment'; login = $true; device = $true; tenant = $true; logins = 1; sets = 1 },
        @{ name = 'commercial-browser'; login = $true; tenant = $true; logins = 1; sets = 1 },
        @{ name = 'existing-government'; target = 'AzureUSGovernment'; existing = $true; signedIn = $true; logins = 0; sets = 0 },
        @{ name = 'existing-commercial'; existing = $true; signedIn = $true; logins = 0; sets = 0 },
        @{ name = 'existing-reauth'; existing = $true; signedIn = $true; login = $true; logins = 1; sets = 0 },
        @{ name = 'existing-empty'; existing = $true; login = $true; tenant = $true; logins = 1; sets = 0 },
        @{ name = 'interactive-first-run'; interactive = $true; answer = 'yes'; logins = 1; sets = 1 },
        @{ name = 'declined'; interactive = $true; answer = 'n'; reject = $true; logins = 0; sets = 0 },
        @{ name = 'unattended'; reject = $true; logins = 0; sets = 0 },
        @{ name = 'missing-tenant'; login = $true; reject = $true; logins = 0; sets = 0 },
        @{ name = 'wrong-cloud-cache'; target = 'AzureUSGovernment'; existing = $true; cloud = 'AzureCloud'; login = $true; tenant = $true; reject = $true; logins = 0; sets = 0 },
        @{ name = 'wrong-tenant-cache'; existing = $true; signedIn = $true; wrongTenant = $true; tenant = $true; login = $true; reject = $true; logins = 0; sets = 0 },
        @{ name = 'non-user-cache'; existing = $true; signedIn = $true; principal = $true; login = $true; reject = $true; logins = 0; sets = 0 },
        @{ name = 'prerequisite-failed'; target = 'AzureUSGovernment'; login = $true; tenant = $true; prerequisiteFailure = $true; retry = $true; reject = $true; logins = 0; sets = 0 },
        @{ name = 'existing-prerequisite-failed'; existing = $true; signedIn = $true; login = $true; prerequisiteFailure = $true; reject = $true; logins = 0; sets = 0 },
        @{ name = 'cloud-initialization-failed'; target = 'AzureUSGovernment'; login = $true; tenant = $true; cloudSetFailure = $true; retry = $true; reject = $true; logins = 0; sets = 1 },
        @{ name = 'cache-publish-race'; login = $true; tenant = $true; publishRace = $true; reject = $true; logins = 0; sets = 1 },
        @{ name = 'cancelled-login'; login = $true; tenant = $true; failed = $true; reject = $true; logins = 1; sets = 1 },
        @{ name = 'wrong-tenant-result'; login = $true; tenant = $true; after = 'tenant'; reject = $true; logins = 1; sets = 1 },
        @{ name = 'wrong-cloud-result'; login = $true; tenant = $true; after = 'cloud'; reject = $true; logins = 1; sets = 1 },
        @{ name = 'non-user-result'; login = $true; tenant = $true; after = 'principal'; reject = $true; logins = 1; sets = 1 },
        @{ name = 'account-switch-result'; existing = $true; signedIn = $true; login = $true; after = 'user'; reject = $true; logins = 1; sets = 0 }
      )
      foreach ($case in $cases) {
        $target = if ($case.target) { $case.target } else { 'AzureCloud' }
        $env:USERPROFILE = Join-Path $temporaryProfile ('login-' + $case.name)
        $null = New-Item -ItemType Directory -Path $env:USERPROFILE -Force
        $cacheName = if ($target -eq 'AzureUSGovernment') { '.azure-byok-government' } else { '.azure-byok-commercial' }
        $cache = Join-Path $env:USERPROFILE $cacheName
        $env:AZURE_CONFIG_DIR = $null
        if ($case.existing) {
          $null = New-Item -ItemType Directory -Path $cache -Force
          $env:AZURE_CONFIG_DIR = $cache
          [IO.File]::WriteAllText((Join-Path $cache 'preserve.txt'), 'unchanged')
        }
        $beforeCache = $env:AZURE_CONFIG_DIR
        $loginState = @{
          cache = $cache; existing = $case.existing; target = $target; device = $case.device
          expectedTenant = $tenantId; expectedAppId = $appId
          cloud = $(if ($case.cloud) { $case.cloud } elseif ($case.existing) { $target } else { 'AzureCloud' })
          failed = $case.failed; after = $case.after; answer = $case.answer; cloudSetFailure = $case.cloudSetFailure
          prerequisiteFailure = $case.prerequisiteFailure; publishRace = $case.publishRace
          prerequisites = 0; prompts = 0; logins = 0; cloudSets = 0; account = $null
        }
        if ($case.signedIn) {
          $loginState.account = @{ tenantId = $tenantId; environmentName = $target; user = @{ name = 'fixture-user'; type = 'user' } }
          if ($case.wrongTenant) { $loginState.account.tenantId = [guid]::NewGuid().ToString() }
          if ($case.principal) { $loginState.account.user.type = 'servicePrincipal' }
        }
        $accountResult = $null
        $rejected = $false
        try {
          Initialize-ByokAzureAccount -Cloud $target -TenantId $(if ($case.tenant) { $tenantId }) -AppId $appId -Login:([bool]$case.login) -UseDeviceCode:([bool]$case.device) -Interactive:([bool]$case.interactive) -Account ([ref]$accountResult) 6>$null
        } catch { $rejected = $true }
        if ($rejected -ne [bool]$case.reject -or $loginState.logins -ne $case.logins -or $loginState.cloudSets -ne $case.sets -or
            ($rejected -and ($accountResult -or $env:AZURE_CONFIG_DIR -cne $beforeCache)) -or
            (-not $rejected -and ($accountResult.tenantId -ine $tenantId -or $env:AZURE_CONFIG_DIR -cne $cache)) -or
            (($case.existing -or $case.publishRace) -and [IO.File]::ReadAllText((Join-Path $cache 'preserve.txt')) -cne 'unchanged') -or
            $env:COPILOT_PROVIDER_API_KEY_COMMAND -cne $previousCommand) { throw ('Cloud-pinned first-run login case failed: ' + $case.name) }
        if (@(Get-ChildItem -LiteralPath $env:USERPROFILE -Filter '.byok-cache-setup-*' -Force).Count) { throw 'Cache setup left an owned staging directory behind.' }
        if ($case.retry) {
          if (Test-Path -LiteralPath $cache) { throw 'Failed setup published an uninitialized cache.' }
          $loginState.prerequisiteFailure = $false
          $loginState.cloudSetFailure = $false
          Initialize-ByokAzureAccount -Cloud $target -TenantId $tenantId -AppId $appId -Login -Account ([ref]$accountResult) 6>$null
          if ($accountResult.tenantId -ine $tenantId -or $env:AZURE_CONFIG_DIR -cne $cache -or
              $loginState.logins -ne 1 -or $loginState.cloudSets -ne $case.sets + 1 -or
              -not (Test-Path -LiteralPath $cache) -or
              @(Get-ChildItem -LiteralPath $env:USERPROFILE -Filter '.byok-cache-setup-*' -Force).Count) {
            throw 'First-run setup did not recover safely on the next explicit attempt.'
          }
        }
      }
    } finally { $env:USERPROFILE = $savedProfile; $env:AZURE_CONFIG_DIR = $savedCache }
  }
  Write-Output 'PASS: twenty-two first-run cases plus two retries cover setup failures, atomic cache publication, existing-cache preservation and sign-in verification'
  & {
    Set-Item Function:Initialize-AzureCli $bootstrapFunctions['Initialize-AzureCli']
    function Resolve-AzureCliCommand { if ($bootstrapState.present) { return 'fixture-az' } }
    function Install-AzureCli {
      $bootstrapState.installs++
      if ($bootstrapState.installFails) { throw 'fixture install failure' }
      $bootstrapState.present = -not $bootstrapState.unresolved
    }
    function Read-Host { $bootstrapState.prompts++; return $bootstrapState.answer }
    function az {
      if (($args -join ' ') -cne 'version --output json --only-show-errors') { throw 'Prerequisite setup attempted authentication or configuration.' }
      $bootstrapState.versionChecks++
      $global:LASTEXITCODE = 0
      if ($bootstrapState.versionFails) { $global:LASTEXITCODE = 1; return 'private-error-details' }
      return (@{ 'azure-cli' = $bootstrapState.version } | ConvertTo-Json -Compress)
    }
    $cases = @(
      @{ name = 'existing'; present = $true; installs = 0; prompts = 0; checks = 1 },
      @{ name = 'existing-opt-in'; present = $true; allow = $true; installs = 0; prompts = 0; checks = 1 },
      @{ name = 'unattended-no-consent'; reject = $true; installs = 0; prompts = 0; checks = 0 },
      @{ name = 'explicit-install'; allow = $true; installs = 1; prompts = 0; checks = 1 },
      @{ name = 'interactive-yes'; interactive = $true; answer = 'yes'; installs = 1; prompts = 1; checks = 1 },
      @{ name = 'interactive-no'; interactive = $true; answer = 'n'; reject = $true; installs = 0; prompts = 1; checks = 0 },
      @{ name = 'interactive-default-no'; interactive = $true; answer = ''; reject = $true; installs = 0; prompts = 1; checks = 0 },
      @{ name = 'failed-install'; allow = $true; installFails = $true; reject = $true; installs = 1; prompts = 0; checks = 0 },
      @{ name = 'not-discoverable'; allow = $true; unresolved = $true; reject = $true; installs = 1; prompts = 0; checks = 0 },
      @{ name = 'too-old'; present = $true; allow = $true; version = '2.53.0'; reject = $true; installs = 0; prompts = 0; checks = 1 },
      @{ name = 'bad-version'; present = $true; version = 'invalid'; reject = $true; installs = 0; prompts = 0; checks = 1 },
      @{ name = 'failed-version'; present = $true; versionFails = $true; reject = $true; installs = 0; prompts = 0; checks = 1 }
    )
    foreach ($case in $cases) {
      $bootstrapState = @{
        present = $case.present; answer = $case.answer; installs = 0; prompts = 0; versionChecks = 0
        installFails = $case.installFails; unresolved = $case.unresolved; versionFails = $case.versionFails
        version = $(if ($case.version) { $case.version } else { '2.90.0' })
      }
      $rejected = $false
      $message = ''
      try { Initialize-AzureCli -AllowInstall:([bool]$case.allow) -Interactive:([bool]$case.interactive) 6>$null }
      catch { $rejected = $true; $message = $_.Exception.Message }
      if ($rejected -ne [bool]$case.reject -or $bootstrapState.installs -ne $case.installs -or
          $bootstrapState.prompts -ne $case.prompts -or $bootstrapState.versionChecks -ne $case.checks -or
          $message.Contains('private-error-details') -or $env:AZURE_CONFIG_DIR -cne $state.config -or
          $env:COPILOT_PROVIDER_API_KEY_COMMAND -cne $previousCommand) { throw ('Azure CLI prerequisite case failed: ' + $case.name) }
    }
  }
  Write-Output 'PASS: twelve Azure CLI prerequisite cases enforce consent, version checks and no authentication/configuration changes'
  & {
    Set-Item Function:Install-AzureCli $bootstrapFunctions['Install-AzureCli']
    $script:AzureCliPortableVersion = '2.90.0'
    $savedLocalAppData = $env:LOCALAPPDATA
    $savedOs = $env:OS
    $archiveFixture = Join-Path $temporaryProfile 'archive-fixture'
    $null = New-Item -ItemType Directory -Path (Join-Path $archiveFixture 'bin') -Force
    [IO.File]::WriteAllText((Join-Path $archiveFixture 'bin/az.cmd'), 'synthetic entry point; never execute')
    function Invoke-WebRequest {
      param([string] $Uri, [string] $OutFile, [switch] $UseBasicParsing, [int] $TimeoutSec)
      $archiveState.downloads++
      if ($Uri -cne 'https://azcliprod.blob.core.windows.net/zip/azure-cli-2.90.0-x64.zip' -or
          -not $UseBasicParsing -or $TimeoutSec -ne 300) { throw 'Unexpected Azure CLI download request.' }
      if ($archiveState.name -eq 'download-failure') { throw 'fixture download failure' }
      if ($archiveState.name -eq 'invalid-zip') { [IO.File]::WriteAllText($OutFile, 'not a ZIP'); return }
      if ($archiveState.name -eq 'missing-entry') {
        Compress-Archive -LiteralPath (Join-Path $archiveFixture 'bin/az.cmd') -DestinationPath $OutFile
      } else {
        Compress-Archive -Path (Join-Path $archiveFixture '*') -DestinationPath $OutFile
      }
      if ($archiveState.name -eq 'destination-race') {
        $null = New-Item -ItemType Directory -Path $archiveState.destination -Force
        [IO.File]::WriteAllText((Join-Path $archiveState.destination 'keep.txt'), 'preserve')
      }
    }
    try {
      $env:OS = 'Windows_NT'
      foreach ($case in @('valid', 'download-failure', 'invalid-zip', 'missing-entry', 'existing', 'destination-race')) {
        $env:LOCALAPPDATA = Join-Path $temporaryProfile ('install-' + $case)
        $root = Join-Path $env:LOCALAPPDATA 'Microsoft/AzureCLI-BYOK'
        $destination = Join-Path $root $script:AzureCliPortableVersion
        $archiveState = @{ name = $case; downloads = 0; destination = $destination }
        if ($case -eq 'existing') {
          $null = New-Item -ItemType Directory -Path $destination -Force
          [IO.File]::WriteAllText((Join-Path $destination 'keep.txt'), 'preserve')
        }
        $rejected = $false
        try { Install-AzureCli 6>$null } catch { $rejected = $true }
        if ($rejected -ne ($case -ne 'valid') -or $archiveState.downloads -ne $(if ($case -eq 'existing') { 0 } else { 1 })) {
          throw ('Azure CLI archive case failed: ' + $case)
        }
        if ($case -eq 'valid' -and [IO.File]::ReadAllText((Join-Path $destination 'bin/az.cmd')) -cne 'synthetic entry point; never execute') {
          throw 'The synthetic archive was not installed in the versioned user directory.'
        }
        if ($case -in @('existing', 'destination-race') -and
            ([IO.File]::ReadAllText((Join-Path $destination 'keep.txt')) -cne 'preserve' -or (Test-Path (Join-Path $destination 'bin')))) {
          throw 'An existing installation directory was changed.'
        }
        if (@(Get-ChildItem -LiteralPath $root -Filter '.install-*' -Force -ErrorAction SilentlyContinue).Count) {
          throw 'Owned installation staging was not cleaned up.'
        }
        if ($env:AZURE_CONFIG_DIR -cne $state.config -or $env:COPILOT_PROVIDER_API_KEY_COMMAND -cne $previousCommand) {
          throw 'Azure CLI archive setup changed authentication state.'
        }
      }
    } finally {
      $env:LOCALAPPDATA = $savedLocalAppData
      $env:OS = $savedOs
    }
  }
  Write-Output 'PASS: six synthetic archive cases cover installation, failure cleanup and no overwrite without network or executable launches'
  & {
    Set-Item Function:Resolve-AzureCliCommand $bootstrapFunctions['Resolve-AzureCliCommand']
    $script:AzureCliPortableVersion = '2.90.0'
    $savedPaths = @{}
    foreach ($name in @('PATH', 'OS', 'LOCALAPPDATA', 'ProgramFiles', 'ProgramFiles(x86)')) {
      $savedPaths[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    function Get-Command {
      [CmdletBinding()]
      param([string] $Name)
      if ($Name -cne 'az') { throw 'Unexpected executable lookup.' }
      if ($resolverState.existing -or ($env:PATH -split [regex]::Escape([string][IO.Path]::PathSeparator)) -contains $resolverState.directory) {
        return [pscustomobject]@{ Source = Join-Path $resolverState.directory 'az.cmd' }
      }
    }
    try {
      $env:OS = 'Windows_NT'
      foreach ($case in @('existing', 'portable', 'machine', 'machine-x86', 'missing')) {
        $caseRoot = Join-Path $temporaryProfile ('resolve-' + $case)
        $env:LOCALAPPDATA = Join-Path $caseRoot 'user'
        $env:ProgramFiles = Join-Path $caseRoot 'machine'
        ${env:ProgramFiles(x86)} = Join-Path $caseRoot 'machine-x86'
        $env:PATH = Join-Path $caseRoot 'unrelated-bin'
        $pathBefore = $env:PATH
        $directory = switch ($case) {
          'machine' { Join-Path $env:ProgramFiles 'Microsoft SDKs/Azure/CLI2/wbin' }
          'machine-x86' { Join-Path ${env:ProgramFiles(x86)} 'Microsoft SDKs/Azure/CLI2/wbin' }
          default { Join-Path $env:LOCALAPPDATA 'Microsoft/AzureCLI-BYOK/2.90.0/bin' }
        }
        $resolverState = @{ existing = $case -eq 'existing'; directory = $directory }
        if ($case -notin @('existing', 'missing')) {
          $null = New-Item -ItemType Directory -Path $directory -Force
          [IO.File]::WriteAllText((Join-Path $directory 'az.cmd'), 'synthetic entry point; never execute')
        }
        $resolved = Resolve-AzureCliCommand
        if (([bool]$resolved -ne ($case -ne 'missing')) -or
            ($resolved -and $resolved.Source -cne (Join-Path $directory 'az.cmd')) -or
            ($case -in @('existing', 'missing') -and $env:PATH -cne $pathBefore) -or
            ($case -notin @('existing', 'missing') -and $env:PATH -cne ($directory + [IO.Path]::PathSeparator + $pathBefore)) -or
            $env:AZURE_CONFIG_DIR -cne $state.config) { throw ('Azure CLI same-shell discovery failed: ' + $case) }
      }
    } finally {
      foreach ($name in $savedPaths.Keys) { [Environment]::SetEnvironmentVariable($name, $savedPaths[$name], 'Process') }
    }
  }
  Write-Output 'PASS: five resolver cases reuse PATH, discover user/MSI installs and change only the process PATH'
  if ($IsWindows) {
    $legacyShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $legacyProbe = {
      param([string] $WrapperPath, [string] $TestAppId)
      $ErrorActionPreference = 'Stop'
      function az {
        if ($args[0] -eq 'version') { $global:LASTEXITCODE = 0; return '{"azure-cli":"2.90.0"}' }
        if ($args[0] -eq 'cloud') { $global:LASTEXITCODE = 0; return 'AzureCloud' }
        & $env:ComSpec /d /c 'echo private-error-details 1>&2 & exit /b 1'
      }
      $previousCommand = $env:COPILOT_PROVIDER_API_KEY_COMMAND
      $message = ''
      try {
        & $WrapperPath -AuthMode jwt -Cloud AzureCloud -RefreshToken -AppId $TestAppId -ApimBaseUrl https://gateway.example.test -Model gpt-4o-mini -PrintOnly 6>$null
      } catch { $message = $_.Exception.Message }
      if ($PSVersionTable.PSVersion.Major -ne 5 -or $message -notlike '*No usable Azure CLI account*AZURE_CONFIG_DIR*' -or
          $message.Contains('private-error-details') -or $env:COPILOT_PROVIDER_API_KEY_COMMAND -cne $previousCommand) {
        throw 'Windows PowerShell native stderr regression failed.'
      }
      Write-Output 'PASS: Windows PowerShell native stderr is sanitized'
      exit 0
    }
    $legacyInvocation = '& { ' + $legacyProbe.ToString() + " } '" + $wrapper.Replace("'", "''") + "' '" + $appId + "'"
    $legacyEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($legacyInvocation))
    $legacyOutput = @(& $legacyShell -NoLogo -NoProfile -NonInteractive -EncodedCommand $legacyEncoded 2>&1) | Out-String
    if ($LASTEXITCODE -ne 0 -or $legacyOutput -notmatch 'PASS: Windows PowerShell native stderr is sanitized' -or
        $legacyOutput.Contains('private-error-details')) { throw 'Windows PowerShell account failure check failed.' }
    Write-Output 'PASS: Windows PowerShell 5.1 native stderr is replaced by pinned-cache sign-in guidance'
    $legacyLoginProbe = {
      param([string] $WrapperPath, [string] $TestAppId, [string] $TestTenantId)
      $ErrorActionPreference = 'Stop'
      $fixture = @{ signedIn = $false; logins = 0 }
      function az {
        $global:LASTEXITCODE = 0
        switch ($args[0] + ' ' + $args[1]) {
          'version --output' { return '{"azure-cli":"2.90.0"}' }
          'cloud show' { return 'AzureUSGovernment' }
          'account show' {
            if (-not $fixture.signedIn) { $global:LASTEXITCODE = 1; return }
            return (@{ tenantId = $TestTenantId; environmentName = 'AzureUSGovernment'; user = @{ name = 'fixture-user'; type = 'user' } } | ConvertTo-Json -Depth 4 -Compress)
          }
          'login --tenant' {
            if ($args -notcontains '--use-device-code' -or $args -notcontains ($TestAppId + '/.default')) { throw 'Wrong login arguments.' }
            $fixture.logins++
            & $env:ComSpec /d /c 'echo fixture-device-instructions 1>&2 & exit /b 0'
            $fixture.signedIn = $true
          }
          'account get-access-token' {
            return (@{ tenant = $TestTenantId; expires_on = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds(); accessToken = 'fixture.payload.signature' } | ConvertTo-Json -Compress)
          }
          default { throw 'Unexpected Azure operation in Windows PowerShell login test.' }
        }
      }
      function copilot { $global:LASTEXITCODE = 0; return 'COPILOT_PROVIDER_API_KEY_COMMAND' }
      & $WrapperPath -AuthMode jwt -RefreshToken -Login -UseDeviceCode -TenantId $TestTenantId -AppId $TestAppId -ApimBaseUrl https://fixture.azure-api.us/openai -Model gpt-4o-mini -PrintOnly 6>$null
      if ($fixture.logins -ne 1 -or -not $env:COPILOT_PROVIDER_API_KEY_COMMAND -or $env:COPILOT_PROVIDER_API_KEY) { throw 'Windows PowerShell sign-in did not configure renewable credentials.' }
      Write-Output 'PASS: Windows PowerShell login preserves device instructions'
      exit 0
    }
    $legacyInvocation = '& { ' + $legacyLoginProbe.ToString() + " } '" + $wrapper.Replace("'", "''") + "' '" + $appId + "' '" + $tenantId + "'"
    $legacyEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($legacyInvocation))
    $legacyStart = [Diagnostics.ProcessStartInfo]::new($legacyShell)
    $legacyStart.UseShellExecute = $false
    $legacyStart.RedirectStandardOutput = $true
    $legacyStart.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-OutputFormat', 'Text', '-EncodedCommand', $legacyEncoded)) {
      $legacyStart.ArgumentList.Add($argument)
    }
    $legacyProcess = [Diagnostics.Process]::Start($legacyStart)
    try {
      $legacyStdout = $legacyProcess.StandardOutput.ReadToEndAsync()
      $legacyStderr = $legacyProcess.StandardError.ReadToEndAsync()
      $legacyProcess.WaitForExit()
      $legacyOutput = $legacyStdout.GetAwaiter().GetResult() + "`n" + $legacyStderr.GetAwaiter().GetResult()
      $legacyExit = $legacyProcess.ExitCode
    } finally { $legacyProcess.Dispose() }
    if ($legacyExit -ne 0 -or $legacyOutput -notmatch 'PASS: Windows PowerShell login preserves device instructions' -or
        $legacyOutput -notmatch 'fixture-device-instructions' -or $legacyOutput.Contains('fixture.payload.signature')) {
      throw 'Windows PowerShell device-code prompt handling failed.'
    }
    Write-Output 'PASS: Windows PowerShell 5.1 explicit device sign-in keeps native instructions visible and exports only the pinned helper'
  }
  $state.legacyCli = $true
  $previousCommand = $env:COPILOT_PROVIDER_API_KEY_COMMAND
  $rejected = $false
  try { & $wrapper -AuthMode jwt -Cloud AzureCloud -RefreshToken -AppId $appId -ApimBaseUrl https://gateway.example.test -Model gpt-4o-mini -PrintOnly 6>$null } catch { $rejected = $_.Exception.Message -like '*credential-command support*' }
  if (-not $rejected -or $env:COPILOT_PROVIDER_API_KEY_COMMAND -ne $previousCommand) { throw 'Unsupported CLI changed active authentication.' }
  $state.legacyCli = $false
  & $wrapper -SubscriptionKey fixture-key -ApimBaseUrl https://gateway.example.test -Model gpt-4o-mini -PrintOnly 6>$null
  if ($env:COPILOT_PROVIDER_API_KEY -ne 'fixture-key' -or $env:COPILOT_PROVIDER_API_KEY_COMMAND -or $env:COPILOT_PROVIDER_BEARER_TOKEN) { throw 'Static-key mode did not clear stale credential commands.' }
  Write-Output 'PASS: unsupported CLI fails closed; static-key mode remains the default'
  $state.oktaConfig=Join-Path $temporaryProfile "fixture's okta.json"
  $state.oktaToken='fixture.okta.signature'
  & $wrapper -AuthMode okta -OktaConfigFile $state.oktaConfig -ApimBaseUrl https://gateway.example.test -Model gpt-4o-mini -PrintOnly 6>$null
  if($env:COPILOT_PROVIDER_API_KEY -or $env:COPILOT_PROVIDER_BEARER_TOKEN -or -not $env:COPILOT_PROVIDER_API_KEY_COMMAND){throw 'Okta mode left conflicting sources.'}
  $encoded=[regex]::Match($env:COPILOT_PROVIDER_API_KEY_COMMAND,'-EncodedCommand ([A-Za-z0-9+/=]+)$').Groups[1].Value
  $invocation=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
  if($invocation.Contains($state.oktaToken) -or $invocation.Contains('-Login')){throw 'Okta credential command contains a token or interactive login.'}
  if((Invoke-Expression $invocation) -cne $state.oktaToken){throw 'Okta command did not invoke its pinned helper.'}
  $state.oktaToken='renewed.okta.signature'
  if((Invoke-Expression $invocation) -cne $state.oktaToken){throw 'Okta command did not reacquire a credential.'}
  $state.oktaFailed=$true
  $previousCommand=$env:COPILOT_PROVIDER_API_KEY_COMMAND
  $rejected=$false
  try{& $wrapper -AuthMode okta -OktaConfigFile $state.oktaConfig -ApimBaseUrl https://gateway.example.test -Model gpt-4o-mini -PrintOnly 6>$null}catch{$rejected=$true}
  if(-not $rejected -or $env:COPILOT_PROVIDER_API_KEY_COMMAND -cne $previousCommand){throw 'Failed Okta renewal changed active credentials.'}
  Write-Output 'PASS: Okta helper quoting, renewal, single-source environment and failed-preflight preservation'
  $agentLauncher=Join-Path $PSScriptRoot '../start-copilot-agent.ps1'
  $agentProfile=Join-Path $temporaryProfile 'agent.json'
  $null=New-Item -ItemType Directory -Path (Join-Path $temporaryProfile 'cache') -Force
  $nativeShell=(Get-Process -Id $PID).Path
  foreach($case in @('valid','http','query-credential','unknown-field','wrong-cloud','missing-user','relative-cache','relative-executable','missing-executable','unsupported-auth')) {
    $settings=@{
      cliExecutable=$nativeShell;gatewayUrl='https://gateway.example.test/openai';model='fixture-model';authMode='jwt'
      appId=$appId;cloud='AzureUSGovernment';tenantId=$tenantId;accountName='fixture-user'
      azureConfigDirectory=(Join-Path $temporaryProfile 'cache');workspace=$temporaryProfile
    }
    switch($case){
      'http'{$settings.gatewayUrl='http://gateway.example.test/openai'}
      'query-credential'{$settings.gatewayUrl='https://gateway.example.test/openai?api-key=forbidden-fixture'}
      'unknown-field'{$settings.accessToken='forbidden-fixture'}
      'wrong-cloud'{$settings.cloud='OtherCloud'}
      'missing-user'{$settings.Remove('accountName')}
      'relative-cache'{$settings.azureConfigDirectory='./cache'}
      'relative-executable'{$settings.cliExecutable='copilot.exe'}
      'missing-executable'{$settings.cliExecutable=Join-Path $temporaryProfile 'missing.exe'}
      'unsupported-auth'{$settings.authMode='subscriptionKey'}
    }
    [IO.File]::WriteAllText($agentProfile,($settings|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    $output=@(& $nativeShell -NoLogo -NoProfile -NonInteractive -File $agentLauncher -ConfigFile $agentProfile -ValidateOnly 2>&1)|Out-String
    if(($LASTEXITCODE -eq 0) -ne ($case -eq 'valid') -or $output.Contains('forbidden-fixture')){throw ('Agent profile validation/redaction failed: '+$case)}
  }
  Write-Output 'PASS: ten noninteractive agent-profile cases pin cloud/user/executable and reject unsafe or secret-bearing configuration without starting the CLI.'
  $env:COPILOT_PROVIDER_HEADERS = 'Authorization: Bearer conflicting-credential'
  $rejected = $false
  try { & $wrapper -SubscriptionKey fixture-key -ApimBaseUrl https://gateway.example.test -Model gpt-4o-mini -PrintOnly 6>$null } catch { $rejected = $_.Exception.Message -like '*Remove credential headers*' }
  if (-not $rejected) { throw 'Custom credential collision was accepted.' }
  Write-Output 'PASS: credential-bearing custom headers are rejected'
  Write-Output "PASS: $passed credential cases"
} finally {
  $env:BYOK_TOKEN_TRACE_FILE = $previousTrace
  $env:AZURE_CONFIG_DIR = $previousConfig
  $env:USERPROFILE = $previousProfile
  $env:PATH = $previousPath
  Get-ChildItem Env: | Where-Object { $_.Name -like 'COPILOT_*' } | ForEach-Object { Remove-Item -LiteralPath $_.PSPath }
  foreach ($name in $savedEnvironment.Keys) { Set-Item -LiteralPath "Env:$name" -Value $savedEnvironment[$name] }
  if (Test-Path -LiteralPath $temporaryProfile) { Remove-Item -LiteralPath $temporaryProfile -Recurse -Force }
  $global:LASTEXITCODE = $previousExitCode
}