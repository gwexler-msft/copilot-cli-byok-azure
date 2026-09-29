#requires -Version 5.1
<#
.SYNOPSIS
  Configure the current shell to run `copilot` (GitHub Copilot CLI) against the private APIM,
  or run a one-shot smoke test of the gateway.
.DESCRIPTION
  Exports the COPILOT_PROVIDER_* environment variables with the per-developer credential,
  and (optionally) runs a curl smoke test against the selected wire API route.

  Credential choices, each requiring matching gateway admission:
    - subscriptionKey (DEFAULT): you present a long-lived per-developer APIM subscription key.
      No token mint, no expiry, no Entra round-trip. This matches the default deployment.
    - jwt: the script mints a short-lived (~1h) Entra JWT for the BYOK API app. Opt in with
      `-AuthMode jwt`. Add `-RefreshToken` for per-request acquisition through the CLI's
      credential command; otherwise re-run to refresh the static token.

  Notes:
    - The credential rides in the Azure provider's `api-key` header. APIM strips it before
      the backend. Custom credential headers are rejected to keep one credential source.
    - jwt mode: with v2 access tokens the JWT 'aud' is the app (client) ID GUID, NOT the api://
      URI. We mint with `--scope "<AppId>/.default"`, which also dodges az's per-resource token
      cache handing back a stale-audience token. Works in AzureCloud and AzureUSGovernment.
.PARAMETER ApimBaseUrl
  Full HTTPS base URL of the APIM gateway (e.g. https://apim-...azure-api.us). The /openai
  suffix is appended automatically if you omit it, so https://apim-...azure-api.us and
  https://apim-...azure-api.us/openai are equivalent.
.PARAMETER Model
  Model/deployment name to use (matches what was deployed), e.g. gpt-5.6-sol.
.PARAMETER WireApi
  Copilot CLI wire API: 'responses' (default) or 'completions'. Responses is required for
  GPT-5.6 agent tool calls and avoids newer CLI payload fields rejected by Chat Completions.
.PARAMETER AuthMode
  'subscriptionKey' (default), 'jwt' (Entra), or 'okta'. Okta always uses the renewable
  credential command and requires the opt-in shared gateway configuration.
.PARAMETER SubscriptionKey
  (subscriptionKey mode) The per-developer APIM subscription key. If omitted, falls back to
  the APIM_SUBSCRIPTION_KEY environment variable. Avoid passing secrets on the command line;
  prefer the env var.
.PARAMETER AppId
  (jwt mode) The app (client) ID GUID of the BYOK gateway app (output of setup-entra). Used as
  the token scope and equals the JWT audience validated by APIM. Required only for -AuthMode jwt.
.PARAMETER Cloud
  (jwt mode) AzureCloud or AzureUSGovernment. Inferred from an exact .azure-api.net or
  .azure-api.us HTTPS hostname. Custom gateway domains require this value or an interactive
  choice. A conflicting override is rejected.
.PARAMETER TenantId
  (jwt mode) Gateway directory tenant GUID, not AppId. Prompted for first sign-in when missing;
  a matching existing delegated account can supply it on later runs.
.PARAMETER Login
  (jwt mode) Explicitly start Entra sign-in, including when an account is already cached.
  Without this switch, a missing account prompts for approval only in an interactive terminal.
.PARAMETER UseDeviceCode
  (jwt mode) Use device-code sign-in instead of the Azure CLI browser/broker default when
  login is needed. Complete the sign-in directly in a browser; do not share the code in chat.
.PARAMETER OktaConfigFile
  Nonsecret pinned Okta client settings. Complete explicit PKCE sign-in using get-okta-token.ps1
  -Login before selecting -AuthMode okta. Never put tokens or a client secret in this file.
.PARAMETER RefreshToken
  (jwt mode) Configure COPILOT_PROVIDER_API_KEY_COMMAND to acquire a usable token before each
  provider request. Requires CLI credential-command support. The launcher can guide first-run
  sign-in; the per-request helper pins cloud, tenant, account and cache and never logs in or
  switches clouds.
  Does not apply to -Test or provide automatic renewal for VS Code Custom Endpoint.
.PARAMETER ApimPrivateIp
  Optional. APIM Internal-VNet private IP. When set, curl uses --resolve so you do not need a
  hosts entry or private DNS zone. Only used by -Test.
.PARAMETER MaxPromptTokens
  Optional. Sets COPILOT_PROVIDER_MAX_PROMPT_TOKENS. Needed when -Model is a value the CLI does
  not have in its built-in catalog (e.g. the gateway 'auto' router): without it the CLI warns and
  falls back to small defaults. Defaults to 1050000 (the GPT-5.6 family input cap) for any
  non-catalog model.
.PARAMETER MaxOutputTokens
  Optional. Sets COPILOT_PROVIDER_MAX_OUTPUT_TOKENS. Same rationale as -MaxPromptTokens. Defaults
  to 128000 (the GPT-5.6 family output cap) for any non-catalog model.
.PARAMETER Test
  Send a request using the selected wire API, printing the HTTP status and body.
.PARAMETER PrintOnly
  Export the env vars but do not print the "run copilot now" hint.
.PARAMETER InstallDeps
  Install missing prerequisites (PowerShell 7+, Node.js 22+ and Copilot CLI). JWT mode also
  installs Azure CLI from Microsoft's version-pinned x64 ZIP (preview) under LOCALAPPDATA,
  without administrator privileges or persistent PATH changes. Interactive users can approve
  installation when prompted; noninteractive runs require this switch. Installation does not
  authorize sign-in; use the first-run prompt or -Login. Downloads require approved outbound HTTPS.
.EXAMPLE
  # DEFAULT (subscription key) - configure the shell for the real Copilot CLI:
  $env:APIM_SUBSCRIPTION_KEY = '<your per-developer key>'
  ./copilot-cli-byok.ps1 -ApimBaseUrl 'https://<apim-name>.azure-api.us/openai' `
                         -Model gpt-5.6-sol
  copilot "what does this repo do?"
.EXAMPLE
  # DEFAULT (subscription key) - smoke test from the in-VNet VM (no hosts edit needed):
  ./copilot-cli-byok.ps1 -ApimBaseUrl 'https://<apim-name>.azure-api.us/openai' `
                         -Model gpt-5.6-sol `
                         -SubscriptionKey '<your per-developer key>' `
                         -ApimPrivateIp 10.60.1.4 `
                         -Test
.EXAMPLE
  # OPT-IN (Entra JWT) - mint a ~1h token instead of using a subscription key:
  ./copilot-cli-byok.ps1 -AuthMode jwt `
                         -AppId <entra-app-client-id> `
                         -ApimBaseUrl 'https://<apim-name>.azure-api.us/openai' `
                         -Model gpt-5.6-sol
#>
[CmdletBinding()]
param(
  # Leave these empty to be prompted (and to reuse the saved config from a previous run). If you
  # prefer a turn-key script, you MAY hardcode your own defaults here, e.g.
  #   [string] $ApimBaseUrl = 'https://<apim>.azure-api.us/openai',
  #   [string] $SubscriptionKey = '<your per-developer key>',
  # A hardcoded value here always wins over the saved config and the interactive prompt. (Note: a
  # baked-in subscription key lives in the file in plaintext - prefer $env:APIM_SUBSCRIPTION_KEY.)
  [string] $ApimBaseUrl = '',
  [string] $Model = '',
  [ValidateSet('responses', 'completions')] [string] $WireApi = 'responses',
  [ValidateSet('subscriptionKey', 'jwt', 'okta')] [string] $AuthMode = 'subscriptionKey',
  [string] $SubscriptionKey = '',
  [string] $AppId,
  [ValidateSet('AzureCloud', 'AzureUSGovernment')] [string] $Cloud,
  [string] $TenantId,
  [switch] $Login,
  [switch] $UseDeviceCode,
  [string] $OktaConfigFile,
  [switch] $RefreshToken,
  [string] $ApimPrivateIp,
  [int] $MaxPromptTokens,
  [int] $MaxOutputTokens,
  [switch] $Test,
  [switch] $PrintOnly,
  [switch] $InstallDeps
)

$ErrorActionPreference = 'Stop'
if ($AuthMode -ne 'jwt' -and ($Cloud -or $TenantId -or $Login -or $UseDeviceCode)) { throw '-Cloud, -TenantId, -Login and -UseDeviceCode require -AuthMode jwt.' }
if ($AuthMode -eq 'okta') { $RefreshToken = $true }
if ($RefreshToken -and ($AuthMode -notin @('jwt','okta') -or $Test)) { throw '-RefreshToken requires -AuthMode jwt or okta and cannot be combined with -Test.' }
if (@(($env:COPILOT_PROVIDER_HEADERS -split '\\n|\r?\n') | Where-Object { $_ -match '^\s*(Authorization|api-key|x-api-key|Ocp-Apim-Subscription-Key)\s*:' }).Count) {
  throw 'Remove credential headers from COPILOT_PROVIDER_HEADERS before configuring BYOK; use one credential source.'
}

$script:IsInteractive = $Host.Name -ne 'Default Host' -and -not [Console]::IsInputRedirected -and
  -not ([Environment]::GetCommandLineArgs() -match '^-(noni|noninteractive)$')
$script:AzureCliPortableVersion = '2.90.0'

function Install-PowerShell7 {
  # Prefer WinGet; otherwise fall back to Microsoft's official installer script, which downloads
  # and silently installs the MSI - no WinGet / Store required (works on stock Windows Server).
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host 'Installing PowerShell 7 (WinGet: Microsoft.PowerShell)...'
    winget install --id Microsoft.PowerShell --accept-source-agreements --accept-package-agreements -e
    return
  }
  Write-Host 'WinGet not found. Installing PowerShell 7 via the official MSI installer (https://aka.ms/install-powershell.ps1)...'
  $installer = Invoke-RestMethod -Uri 'https://aka.ms/install-powershell.ps1' -UseBasicParsing
  & ([scriptblock]::Create($installer)) -UseMSI -Quiet
}

function Get-PwshPath {
  # Find pwsh.exe even right after an MSI install, when PATH hasn't refreshed in this session.
  $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
    if (-not $root) { continue }
    $candidate = Join-Path $root 'PowerShell\7\pwsh.exe'
    if (Test-Path $candidate) { return $candidate }
  }
  return $null
}

function Install-NodeJs {
  # Install Node.js 22 LTS. Prefer WinGet; otherwise download the official MSI from nodejs.org
  # (no WinGet / Store required) and install it silently. Adds the install dir to this session's
  # PATH so `node`/`npm` are usable immediately without opening a new shell.
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host 'Installing Node.js 22+ (WinGet: OpenJS.NodeJS.LTS)...'
    winget install --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements -e
  }
  else {
    Write-Host 'WinGet not found. Installing Node.js 22 LTS via the official nodejs.org MSI...'
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    # Resolve the newest v22 LTS build from the official dist index.
    $index   = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -UseBasicParsing
    $latest  = $index | Where-Object { $_.version -like 'v22.*' } | Select-Object -First 1
    if (-not $latest) { throw 'Could not resolve a Node.js 22 LTS release from nodejs.org.' }
    $msiUrl  = "https://nodejs.org/dist/$($latest.version)/node-$($latest.version)-$arch.msi"
    $msiPath = Join-Path $env:TEMP "node-$($latest.version)-$arch.msi"
    Write-Host "Downloading $msiUrl ..."
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
    Write-Host 'Installing Node.js (msiexec /qn)...'
    $p = Start-Process msiexec.exe -ArgumentList '/i', "`"$msiPath`"", '/qn', '/norestart' -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Node.js MSI install failed (exit $($p.ExitCode))." }
    # PATH won't refresh in this session; add the default install dir so npm/node work now.
    $nodeDir = Join-Path $env:ProgramFiles 'nodejs'
    if (Test-Path $nodeDir) { $env:PATH = "$nodeDir;$env:PATH" }
  }
}

function Update-SessionPath {
  # Rebuild $env:PATH from the Machine + User registry values so binaries installed earlier in
  # THIS session (Node MSI, npm -g shims) become resolvable without opening a new shell.
  try {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $merged  = ($machine, $user, $env:PATH | Where-Object { $_ }) -join ';'
    # De-dupe while preserving order.
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $env:PATH = (($merged -split ';') | Where-Object { $_ -and $seen.Add($_) }) -join ';'
  }
  catch { Write-Verbose "Could not refresh PATH from registry: $($_.Exception.Message)" }
}

function Resolve-AzureCliCommand {
  $command = Get-Command az -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($command) { return $command }
  if ($env:OS -ne 'Windows_NT') { return $null }
  $candidates = @()
  foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if ($root) { $candidates += Join-Path $root 'Microsoft SDKs/Azure/CLI2/wbin' }
  }
  if ($env:LOCALAPPDATA) {
    $candidates += Join-Path $env:LOCALAPPDATA "Microsoft/AzureCLI-BYOK/$script:AzureCliPortableVersion/bin"
  }
  foreach ($directory in $candidates) {
    if (Test-Path -LiteralPath (Join-Path $directory 'az.cmd') -PathType Leaf) {
      $env:PATH = $directory + [IO.Path]::PathSeparator + $env:PATH
      $command = Get-Command az -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($command) { return $command }
    }
  }
  return $null
}

function Install-AzureCli {
  if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem -or -not $env:LOCALAPPDATA) {
    throw 'Automatic Azure CLI installation requires 64-bit Windows and LOCALAPPDATA. Install Azure CLI for your platform: https://learn.microsoft.com/cli/azure/install-azure-cli'
  }
  $root = Join-Path $env:LOCALAPPDATA 'Microsoft/AzureCLI-BYOK'
  $destination = Join-Path $root $script:AzureCliPortableVersion
  if (Test-Path -LiteralPath $destination) {
    throw 'The per-user Azure CLI installation directory already exists but is not usable. Repair it explicitly; this launcher will not overwrite it.'
  }
  $staging = Join-Path $root ('.install-' + [guid]::NewGuid().ToString('N'))
  $null = New-Item -ItemType Directory -Path $staging -ErrorAction Stop
  try {
    $archive = Join-Path $staging 'azure-cli.zip'
    $package = Join-Path $staging 'package'
    $uri = "https://azcliprod.blob.core.windows.net/zip/azure-cli-$script:AzureCliPortableVersion-x64.zip"
    Write-Host "Installing Azure CLI $script:AzureCliPortableVersion for the current user (Microsoft ZIP preview)..."
    Invoke-WebRequest -Uri $uri -OutFile $archive -UseBasicParsing -TimeoutSec 300
    Expand-Archive -LiteralPath $archive -DestinationPath $package
    if (-not (Test-Path -LiteralPath (Join-Path $package 'bin/az.cmd') -PathType Leaf)) {
      throw 'The Azure CLI archive does not contain the expected bin/az.cmd entry point.'
    }
    [IO.Directory]::Move($package, $destination)
  } finally {
    Remove-Item -LiteralPath $staging -Recurse -Force
  }
}

function Initialize-AzureCli {
  param([switch] $AllowInstall, [switch] $Interactive)
  if (-not (Resolve-AzureCliCommand)) {
    $approved = [bool]$AllowInstall
    if (-not $approved -and $Interactive) {
      $answer = Read-Host 'Azure CLI is missing. Install the Microsoft per-user x64 ZIP (preview) now? [y/N]'
      $approved = $answer -match '^(y|yes)$'
    }
    if (-not $approved) {
      throw 'JWT mode requires Azure CLI (az). Rerun with -InstallDeps to install the Microsoft per-user Windows ZIP (preview), or install Azure CLI separately. No sign-in or cloud change was performed.'
    }
    Install-AzureCli
    if (-not (Resolve-AzureCliCommand)) { throw 'Azure CLI installation completed but az is not discoverable in this shell. No sign-in was attempted.' }
  }
  $version = $null
  try {
    $versionJson = az version --output json --only-show-errors 2>$null
    if ($LASTEXITCODE -eq 0) { $version = [version](($versionJson | ConvertFrom-Json).'azure-cli') }
  } catch { $version = $null }
  if (-not $version -or $version -lt [version]'2.54.0') {
    throw 'Azure CLI could not be verified as version 2.54.0 or newer. Repair or upgrade the existing installation explicitly, then rerun this launcher.'
  }
}

function Resolve-ByokAzureCloud {
  param([string] $GatewayUrl, [string] $Cloud, [switch] $Interactive)
  $gatewayUri = $null
  if (-not [uri]::TryCreate($GatewayUrl, [UriKind]::Absolute, [ref]$gatewayUri) -or
      $gatewayUri.Scheme -ne 'https' -or $gatewayUri.UserInfo -or $gatewayUri.Query -or $gatewayUri.Fragment) {
    throw 'JWT mode requires an absolute HTTPS gateway URL without user information, query parameters or fragments.'
  }
  $hostname = $gatewayUri.DnsSafeHost.TrimEnd('.').ToLowerInvariant()
  $inferredCloud = if ($hostname.EndsWith('.azure-api.us')) { 'AzureUSGovernment' }
    elseif ($hostname.EndsWith('.azure-api.net')) { 'AzureCloud' } else { '' }
  if ($Cloud -and $inferredCloud -and $Cloud -cne $inferredCloud) {
    throw 'The requested cloud conflicts with the APIM hostname. Use the matching cloud in a dedicated terminal.'
  }
  if (-not $Cloud) { $Cloud = $inferredCloud }
  if (-not $Cloud -and $Interactive) {
    $Cloud = Read-Host 'Custom gateway domain: enter AzureCloud or AzureUSGovernment'
  }
  if ($Cloud -cnotin @('AzureCloud', 'AzureUSGovernment')) {
    throw 'Cannot infer the cloud from this gateway hostname. Supply -Cloud AzureCloud or -Cloud AzureUSGovernment.'
  }
  return $Cloud
}

function Read-ByokAzureAccount {
  try {
    $accountJson = az account show --output json --only-show-errors 2>$null
    if ($LASTEXITCODE -eq 0 -and $accountJson) { return ($accountJson | ConvertFrom-Json) }
  } catch { }
  return $null
}

function Write-ByokJwtAccessGuidance {
  param([string] $Token)
  $missingRoles = $false
  try {
    if ($Token.Length -le 65536 -and $Token -cmatch '\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z') {
      $payload = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
      $payload = $payload.PadRight($payload.Length + (4 - $payload.Length % 4) % 4, '=')
      $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
      if ($claims -is [pscustomobject]) {
        $missingRoles = $null -eq $claims.roles -or ($claims.roles -is [array] -and $claims.roles.Count -eq 0)
      }
    }
  } catch { } finally { $claims = $null; $payload = $null; $Token = $null }
  if ($missingRoles) {
    Write-Warning 'The acquired gateway token has no app roles. If group-based JWT tiers are enabled, APIM will deny inference with 403. After a group change, allow propagation and rerun this launcher with -Login (add -UseDeviceCode on a VM). If access is still denied, ask your administrator to verify exactly one mapped gateway tier. This is a local metadata hint, not an authorization check.' -WarningAction Continue
  }
}

function Initialize-ByokAzureAccount {
  param(
    [string] $Cloud, [string] $TenantId, [string] $AppId,
    [switch] $Login, [switch] $UseDeviceCode, [switch] $Interactive,
    [switch] $AllowInstall, [ref] $Account
  )
  $tenantPattern = '\A[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z'
  if ($TenantId -and $TenantId -notmatch $tenantPattern) { throw '-TenantId must be the gateway directory tenant GUID, not AppId or a login authority URL.' }
  $previousConfig = $env:AZURE_CONFIG_DIR
  $cache = if ($previousConfig) { [IO.Path]::GetFullPath($previousConfig) } else {
    $cacheName = if ($Cloud -eq 'AzureUSGovernment') { '.azure-byok-government' } else { '.azure-byok-commercial' }
    Join-Path $env:USERPROFILE $cacheName
  }
  $newCache = -not (Test-Path -LiteralPath $cache)
  if (-not $newCache -and -not (Test-Path -LiteralPath $cache -PathType Container)) { throw 'AZURE_CONFIG_DIR must identify a directory.' }
  $completed = $false
  $readCloud = {
    try {
      $current = az cloud show --query name --output tsv --only-show-errors 2>$null
      if ($LASTEXITCODE -eq 0) { return ([string]$current).Trim() }
    } catch { }
    return ''
  }
  $context = $null
  try {
    if (-not $newCache) {
      $env:AZURE_CONFIG_DIR = $cache
      Initialize-AzureCli -AllowInstall:$AllowInstall -Interactive:$Interactive
      if ((& $readCloud) -cne $Cloud) { throw 'The selected Azure CLI cache is not pinned to the gateway cloud. Use a different dedicated terminal/cache; this cache will not be switched.' }
      $context = Read-ByokAzureAccount
    }
    if ($context) {
      if (@($context).Count -ne 1 -or $context.environmentName -cne $Cloud -or
          $context.user.type -cne 'user' -or [string]::IsNullOrWhiteSpace($context.user.name) -or
          $context.tenantId -notmatch $tenantPattern) { throw 'The cached account must be one delegated user in the gateway cloud. Use a dedicated user cache.' }
      if ($TenantId -and $context.tenantId -ine $TenantId) { throw 'The cached account belongs to a different tenant. Select the intended dedicated cache; the launcher will not replace this account.' }
      if (-not $TenantId) { $TenantId = $context.tenantId }
    }
    if (-not $context -or $Login) {
      $approved = [bool]$Login
      Write-Host "Gateway authentication cloud: $Cloud."
      if (-not $approved -and $Interactive) {
        $answer = Read-Host "Sign in to $Cloud for this gateway now? [y/N]"
        $approved = $answer -match '^(y|yes)$'
      }
      if (-not $approved) { throw 'No usable Azure CLI account in the selected cache. Rerun interactively or use -Login -TenantId <TENANT_ID>; use -UseDeviceCode for a remote VM. AZURE_CONFIG_DIR must be dedicated to the gateway cloud.' }
      if (-not $TenantId -and $Interactive) { $TenantId = Read-Host 'Gateway directory Tenant ID (GUID, not the application AppId)' }
      if (-not $TenantId -or $TenantId -notmatch $tenantPattern -or $TenantId -ieq $AppId) { throw 'Sign-in requires the gateway directory Tenant ID. Supply -TenantId <TENANT_ID>; it cannot be inferred from the APIM URL or AppId.' }
      if ($newCache) {
        $stagingCache = Join-Path (Split-Path -Path $cache -Parent) ('.byok-cache-setup-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $stagingCache -ErrorAction Stop
        try {
          $env:AZURE_CONFIG_DIR = $stagingCache
          Initialize-AzureCli -AllowInstall:$AllowInstall -Interactive:$Interactive
          $cloudExit = -1
          try { $null = az cloud set --name $Cloud --output none --only-show-errors 2>$null; $cloudExit = $LASTEXITCODE } catch { }
          if ($cloudExit -ne 0 -or (& $readCloud) -cne $Cloud) { throw 'Could not initialize the new cloud-specific Azure CLI cache. No login was attempted.' }
          [IO.Directory]::Move($stagingCache, $cache)
          $env:AZURE_CONFIG_DIR = $cache
        } finally {
          if (Test-Path -LiteralPath $stagingCache) { Remove-Item -LiteralPath $stagingCache -Recurse -Force }
        }
      }
      $loginArguments = @('login', '--tenant', $TenantId, '--scope', "$AppId/.default", '--allow-no-subscriptions', '--output', 'none')
      if ($UseDeviceCode) { $loginArguments += '--use-device-code' }
      $loginExit = -1
      $previousErrorPreference = $ErrorActionPreference
      try {
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        az @loginArguments
        $loginExit = $LASTEXITCODE
      } finally { $ErrorActionPreference = $previousErrorPreference }
      if ($loginExit -ne 0) { throw 'Azure sign-in did not complete. Provider credentials were not changed. Check identity connectivity and retry explicitly; use -UseDeviceCode when a local browser is unavailable.' }
      $signedIn = Read-ByokAzureAccount
      if ((& $readCloud) -cne $Cloud -or @($signedIn).Count -ne 1 -or -not $signedIn -or
          $signedIn.environmentName -cne $Cloud -or $signedIn.tenantId -ine $TenantId -or
          $signedIn.user.type -cne 'user' -or [string]::IsNullOrWhiteSpace($signedIn.user.name) -or
          ($context -and $signedIn.user.name -ine $context.user.name)) {
        throw 'The resulting sign-in does not match the expected cloud, tenant and delegated user. Provider credentials were not changed.'
      }
      $context = $signedIn
    }
    $Account.Value = $context
    $completed = $true
  } finally {
    if (-not $completed) { $env:AZURE_CONFIG_DIR = $previousConfig }
  }
}

function Resolve-CopilotCommand {
  # Find the `copilot` executable after an install, even when PATH hasn't refreshed. Returns the
  # full path or $null. Refreshes PATH from the registry, then asks npm where it puts global bins.
  Update-SessionPath
  $cmd = Get-Command copilot -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }

  # Ask npm for its global prefix (where copilot.cmd lands on Windows), plus common fallbacks.
  $candidates = @()
  $npm = Get-Command npm -ErrorAction SilentlyContinue
  if ($npm) {
    try {
      $prefix = (& $npm.Source prefix -g 2>$null | Select-Object -First 1)
      if ($prefix) { $candidates += $prefix }
    }
    catch { }
  }
  if ($env:APPDATA)      { $candidates += (Join-Path $env:APPDATA 'npm') }
  if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'nodejs') }

  foreach ($dir in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
    foreach ($leaf in @('copilot.cmd', 'copilot.exe', 'copilot')) {
      $p = Join-Path $dir $leaf
      if (Test-Path $p) {
        if ($env:PATH -notlike "*$dir*") { $env:PATH = "$dir;$env:PATH" }
        return $p
      }
    }
  }
  return $null
}

# PowerShell 7+ is RECOMMENDED (the Copilot CLI wants PS 6+ for its Windows shell integration).
# The wrapper's own steps - prompting, installing, minting the JWT, exporting the env vars - all
# work in Windows PowerShell 5.1, so we do EVERYTHING in THIS process. That matters: the
# COPILOT_PROVIDER_* env vars must be set in the real session, and a relaunched child process
# would lose them on exit. If we're on 5.1 we just make sure PS7 is available; at the very end we
# drop the user into an interactive PS7 shell that INHERITS those env vars (child processes inherit
# the parent environment), so `copilot` runs on a supported PowerShell with the right config.
$script:PwshForFinalLaunch = $null
if ($PSVersionTable.PSVersion.Major -lt 7) {
  $existingPwsh = Get-PwshPath
  if ($existingPwsh) {
    # PS7 already present - remember it; we'll launch into it at the end (after env vars are set).
    $script:PwshForFinalLaunch = $existingPwsh
  }
  else {
    Write-Warning "Running Windows PowerShell $($PSVersionTable.PSVersion). PowerShell 7+ is recommended: this wrapper works here, but the 'copilot' CLI itself wants PS 6+ and may misbehave under 5.1."

    $doInstall = $false
    if ($InstallDeps) {
      $doInstall = $true
    }
    elseif ($script:IsInteractive) {
      $ans = Read-Host 'Install PowerShell 7 now? [Y/n]'
      $doInstall = ($ans -notmatch '^(n|no)$')
    }
    else {
      Write-Warning 'To install PowerShell 7 non-interactively, re-run with -InstallDeps.'
    }

    if ($doInstall) {
      try {
        Install-PowerShell7
        # PATH won't refresh in this 5.1 session; locate pwsh.exe directly so we can launch it later.
        $script:PwshForFinalLaunch = Get-PwshPath
        if (-not $script:PwshForFinalLaunch) {
          Write-Warning "PowerShell 7 installed but pwsh.exe could not be located. Open a NEW shell and re-run in pwsh after this completes."
        }
      }
      catch {
        Write-Warning "Automatic PowerShell 7 install failed: $($_.Exception.Message)`nInstall manually from https://aka.ms/powershell (MSI), then re-run in pwsh."
      }
    }

    Write-Host 'Continuing under Windows PowerShell 5.1...'
  }
}

# Required params are NOT declared [Parameter(Mandatory)] on purpose: a mandatory prompt fires
# during param binding, BEFORE the PS-version check above can run, so a 5.1 user would be asked
# for ApimBaseUrl before being told to install PS7. Instead we load saved defaults, prompt for
# any missing value interactively, then persist the (non-secret) answers for next time.
$configDir  = Join-Path $env:USERPROFILE '.copilot-byok'
$configPath = Join-Path $configDir 'config.json'
$savedConfig = $null
if (Test-Path $configPath) {
  try { $savedConfig = Get-Content $configPath -Raw | ConvertFrom-Json } catch { $savedConfig = $null }
}

function Resolve-Setting {
  param([string] $Value, [string] $Saved, [string] $Prompt, [string] $Default)
  if ($Value)  { return $Value }   # explicit -param wins
  $fallback = if ($Saved) { $Saved } else { $Default }   # saved value beats the built-in default
  if ($script:IsInteractive) {
    $hint    = if ($fallback) { " [$fallback]" } else { '' }
    $entered = Read-Host ($Prompt + $hint)
    if (-not $entered -and $fallback) { return $fallback }   # Enter accepts the shown default
    return $entered
  }
  return $fallback   # non-interactive: fall back to saved, else built-in default
}

$ApimBaseUrl = Resolve-Setting -Value $ApimBaseUrl -Saved $savedConfig.ApimBaseUrl -Prompt 'APIM base URL (the /openai suffix is added automatically if omitted)'
$Model       = Resolve-Setting -Value $Model       -Saved $savedConfig.Model       -Prompt 'Model / deployment name' -Default 'auto'

if (-not $ApimBaseUrl) { throw '-ApimBaseUrl is required (the APIM gateway base URL, e.g. https://<apim>.azure-api.us).' }
if (-not $Model)       { throw '-Model is required (the deployed model/deployment name, e.g. gpt-5.6-sol, or "auto" to let the gateway route).' }
if ($AuthMode -eq 'okta' -and ([uri]$ApimBaseUrl).Scheme -ne 'https') { throw 'Okta credentials require an HTTPS gateway URL.' }

# Normalize: the inference routes live under /openai (the default route, and the only path the CLI's
# azure provider actually keeps), so append /openai only if the dev passed a bare host (and tolerate
# a trailing slash). This way a forgotten suffix can't silently break things later.
$ApimBaseUrl = $ApimBaseUrl.TrimEnd('/')
if ($ApimBaseUrl -notmatch '(?i)/openai$') { $ApimBaseUrl = "$ApimBaseUrl/openai" }


# Persist non-secret defaults (NEVER the subscription key or JWT) for the next run.
try {
  if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
  [pscustomobject]@{ ApimBaseUrl = $ApimBaseUrl; Model = $Model } |
    ConvertTo-Json | Set-Content -Path $configPath -Encoding utf8
}
catch { Write-Verbose "Could not save config to ${configPath}: $($_.Exception.Message)" }

# Resolve the credential that will ride in the api-key header, per auth mode.
if ($AuthMode -eq 'subscriptionKey') {
  if (-not $SubscriptionKey) { $SubscriptionKey = $env:APIM_SUBSCRIPTION_KEY }
  if (-not $SubscriptionKey -and $script:IsInteractive) {
    # Prompt for the key (masked). NEVER persisted to disk - only held in this session.
    $secure = Read-Host 'APIM subscription key (input hidden; not saved to disk)' -AsSecureString
    if ($secure -and $secure.Length -gt 0) {
      $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
      try { $SubscriptionKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
      finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
  }
  if (-not $SubscriptionKey) {
    throw 'subscriptionKey mode: provide -SubscriptionKey or set $env:APIM_SUBSCRIPTION_KEY (your per-developer APIM subscription key).'
  }
  $credential = $SubscriptionKey
  $credKind   = 'APIM subscription key'
}
elseif ($AuthMode -eq 'okta') {
  if (-not $OktaConfigFile) { throw 'okta mode: -OktaConfigFile is required; sign in explicitly with get-okta-token first.' }
  $tokenHelper = Join-Path $PSScriptRoot 'get-okta-token.ps1'
  $oktaPath = [IO.Path]::GetFullPath($OktaConfigFile)
  & $tokenHelper -ConfigFile $oktaPath | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'The pinned Okta credential helper failed preflight.' }
  $invocation = "& '" + $tokenHelper.Replace("'", "''") + "' -ConfigFile '" + $oktaPath.Replace("'", "''") + "'"
  $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($invocation))
  $tokenShell = Get-PwshPath
  if (-not $tokenShell) { $tokenShell = Join-Path $PSHOME 'powershell.exe' }
  $credentialCommand = '"' + $tokenShell + '" -NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encodedCommand
  $credKind = 'Okta JWT (OS-protected renewable user grant)'
}
else {
  if (-not $AppId) { throw 'jwt mode: -AppId (the BYOK gateway app/client ID GUID) is required.' }
  $targetCloud = Resolve-ByokAzureCloud -GatewayUrl $ApimBaseUrl -Cloud $Cloud -Interactive:$script:IsInteractive
  $ctx = $null
  Initialize-ByokAzureAccount -Cloud $targetCloud -TenantId $TenantId -AppId $AppId -Login:$Login -UseDeviceCode:$UseDeviceCode -Interactive:$script:IsInteractive -AllowInstall:$InstallDeps -Account ([ref]$ctx)

  if ($RefreshToken) {
    $tokenHelper = Join-Path $PSScriptRoot 'get-byok-token.ps1'
    $azureConfigDirectory = if ($env:AZURE_CONFIG_DIR) { [IO.Path]::GetFullPath($env:AZURE_CONFIG_DIR) } else { Join-Path $env:USERPROFILE '.azure' }
    $tokenParameters = [ordered]@{
      AppId = $AppId
      Cloud = $ctx.environmentName
      TenantId = $ctx.tenantId
      AccountName = $ctx.user.name
      AzureConfigDirectory = $azureConfigDirectory
    }
    $preflightToken = $null
    try {
      $preflightToken = & $tokenHelper @tokenParameters
      if ($LASTEXITCODE -ne 0) { throw 'Gateway token acquisition failed. Rerun this launcher with -Login (add -UseDeviceCode on a VM), using the intended cloud, account and cache.' }
      Write-ByokJwtAccessGuidance -Token $preflightToken
    } finally { $preflightToken = $null }
    $invokeParts = @("& '" + $tokenHelper.Replace("'", "''") + "'")
    foreach ($name in $tokenParameters.Keys) { $invokeParts += '-' + $name + " '" + ([string]$tokenParameters[$name]).Replace("'", "''") + "'" }
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($invokeParts -join ' ')))
    $tokenShell = Get-PwshPath
    if (-not $tokenShell) { $tokenShell = Join-Path $PSHOME 'powershell.exe' }
    $credentialCommand = '"' + $tokenShell + '" -NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encodedCommand
    $credKind = 'Entra JWT (per-request Azure CLI cache)'
  }
  else {
    $credential = az account get-access-token --scope "$AppId/.default" --query accessToken -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $credential) {
      throw 'Could not acquire the gateway token. Sign in in the pinned cloud and verify the delegated gateway permission.'
    }
    Write-ByokJwtAccessGuidance -Token $credential
    $credKind = 'Entra JWT (~1h)'
  }
}

$baseUrl = $ApimBaseUrl.TrimEnd('/')

if ($Test) {
  if ($WireApi -eq 'responses') {
    $uri  = "$baseUrl/v1/responses"
    $body = '{"model":"' + $Model + '","input":"say hi in three words"}'
  }
  else {
    $uri  = "$baseUrl/v1/chat/completions"
    $body = '{"model":"' + $Model + '","messages":[{"role":"user","content":"say hi in three words"}]}'
  }

  $curlArgs = @('-sk', '-w', "`nhttp=%{http_code}`n", '--max-time', '40')
  if ($ApimPrivateIp) {
    $apimHost = ([Uri]$baseUrl).Host
    $curlArgs += @('--resolve', "${apimHost}:443:$ApimPrivateIp")
  }
  $curlArgs += @('-X', 'POST', $uri,
                 '-H', "api-key: $credential",
                 '-H', 'Content-Type: application/json',
                 '-d', $body)

  Write-Host "POST $uri  (wireApi=$WireApi, authMode=$AuthMode, model=$Model, credential=$credKind, length=$($credential.Length))"
  & curl.exe @curlArgs
  return
}

# Configuring env vars is pointless without the CLI. Detect a missing CLI and either install it
# (with -InstallDeps, or after an interactive prompt) or print the exact commands and stop.
if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) {
  $hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
  $hasNode   = [bool](Get-Command node   -ErrorAction SilentlyContinue)

  # Decide whether to install: -InstallDeps forces it; otherwise ask interactively.
  $doInstallCli = $false
  if ($InstallDeps) {
    $doInstallCli = $true
  }
  elseif ($script:IsInteractive) {
    $ans = Read-Host 'GitHub Copilot CLI is not installed. Install it now? [Y/n]'
    $doInstallCli = ($ans -notmatch '^(n|no)$')
  }

  if ($doInstallCli) {
    if ($hasWinget) {
      if (-not $hasNode) { Install-NodeJs }
      Write-Host 'Installing GitHub Copilot CLI (WinGet: GitHub.Copilot)...'
      winget install --id GitHub.Copilot --accept-source-agreements --accept-package-agreements -e
    }
    else {
      # No WinGet: ensure Node/npm exist (install from the official MSI if needed), then npm-install
      # the CLI. This is the bare-Windows-Server path - no Store, no WinGet required.
      if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        Install-NodeJs
      }
      if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        throw 'Node.js/npm is still not available after install. Install Node.js 22+ from https://nodejs.org/en/download, then re-run this script.'
      }
      Write-Host 'Installing the Copilot CLI via npm (npm install -g @github/copilot@latest)...'
      # npm prints version "notice" lines to stderr; under PS7's native-command error handling
      # ($ErrorActionPreference=Stop) that can surface as a terminating error even on success.
      # Relax it for just this call and key off the real exit code instead.
      $prevEap = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      try { & npm install -g '@github/copilot@latest' }
      finally { $ErrorActionPreference = $prevEap }
      if ($LASTEXITCODE -ne 0) {
        throw "npm install -g @github/copilot@latest failed (exit $LASTEXITCODE). Check network/proxy and retry."
      }
    }

    # PATH may not be refreshed in this session right after an install. Refresh from the registry
    # and ask npm where it placed the global bin so we can keep going without a new shell.
    $copilotPath = Resolve-CopilotCommand
    if (-not $copilotPath) {
      throw 'Install completed but `copilot` could not be located. Open a new shell (so PATH refreshes), verify with `copilot --version`, then re-run this script.'
    }
    Write-Host "Copilot CLI installed: $copilotPath"
  }
  else {
    $wingetHint = if ($hasWinget) {
      'WinGet (no npm needed):
  winget install OpenJS.NodeJS.LTS         # Node.js 22+ (CLI runtime)
  winget install GitHub.Copilot            # the Copilot CLI (>= 1.0.54)'
    } else {
      'WinGet is not installed. Install App Installer first:
  - Microsoft Store: search "App Installer", or
  - msixbundle: https://aka.ms/getwinget  ->  Add-AppxPackage -Path .\Microsoft.DesktopAppInstaller_*.msixbundle
Then:
  winget install OpenJS.NodeJS.LTS
  winget install GitHub.Copilot'
    }
    throw @"
GitHub Copilot CLI (``copilot``) was not found on PATH.

Re-run this script with -InstallDeps to install automatically, or install manually:

$wingetHint

  -- OR npm (needs Node.js 22+ already installed): npm install -g @github/copilot@latest

Verify with: copilot --version
"@
  }
}

if ($RefreshToken) {
  $providerHelp = (& copilot help providers 2>$null) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $providerHelp -notmatch '\bCOPILOT_PROVIDER_API_KEY_COMMAND\b') {
    throw 'This Copilot CLI does not advertise credential-command support. Update it before enabling -RefreshToken.'
  }
}

$env:COPILOT_PROVIDER_BASE_URL = $baseUrl
$env:COPILOT_PROVIDER_TYPE     = 'azure'
$env:COPILOT_PROVIDER_WIRE_API = $WireApi
$env:COPILOT_PROVIDER_BEARER_TOKEN = $null
if ($RefreshToken) {
  $env:COPILOT_PROVIDER_API_KEY = $null
  $env:COPILOT_PROVIDER_API_KEY_COMMAND = $credentialCommand
  $credential = $null
} else {
  $env:COPILOT_PROVIDER_API_KEY_COMMAND = $null
  $env:COPILOT_PROVIDER_API_KEY = $credential
}
$env:COPILOT_MODEL             = $Model

# The CLI looks up token limits from a built-in model catalog. A gateway-routed name like 'auto'
# isn't in that catalog, so the CLI warns and falls back to tiny defaults. Set the limits
# explicitly: honor -MaxPromptTokens/-MaxOutputTokens if given, else apply conservative defaults
# for any non-catalog model. The defaults are the SMALLER limit of each model the gateway 'auto'
# router can pick, so a prompt/response can't overflow whichever way it routes:
#   prompt 1050000 and output 128000 = shared GPT-5.6 Sol/Luna limits.
$catalogModels = @('gpt-4.1', 'gpt-4.1-mini', 'gpt-4o', 'gpt-4o-mini', 'gpt-5.1', 'gpt-5', 'gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna', 'o3', 'o4-mini')
$isCatalogModel = $catalogModels -contains $Model
if ($MaxPromptTokens -gt 0) {
  $env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS = "$MaxPromptTokens"
}
elseif (-not $isCatalogModel) {
  $env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS = '1050000'
}
if ($MaxOutputTokens -gt 0) {
  $env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS = "$MaxOutputTokens"
}
elseif (-not $isCatalogModel) {
  $env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS = '128000'
}

Write-Host "Configured Copilot CLI for BYOK ($AuthMode):"
Write-Host "  COPILOT_PROVIDER_BASE_URL = $env:COPILOT_PROVIDER_BASE_URL"
Write-Host "  COPILOT_PROVIDER_TYPE     = $env:COPILOT_PROVIDER_TYPE"
Write-Host "  COPILOT_PROVIDER_WIRE_API = $env:COPILOT_PROVIDER_WIRE_API"
if ($RefreshToken) {
  Write-Host '  COPILOT_PROVIDER_API_KEY_COMMAND = <pinned token helper>'
} else {
  Write-Host "  COPILOT_PROVIDER_API_KEY  = <hidden $credKind, length=$($credential.Length)>"
}
Write-Host "  COPILOT_MODEL             = $env:COPILOT_MODEL"
if ($env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS) {
  Write-Host "  COPILOT_PROVIDER_MAX_PROMPT_TOKENS = $env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS"
}
if ($env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS) {
  Write-Host "  COPILOT_PROVIDER_MAX_OUTPUT_TOKENS = $env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS"
}
if ($AuthMode -eq 'jwt') {
  Write-Host '  Entra token acquired; APIM authorization has not been checked by this launcher.'
  Write-Host '  A cached token can retain old tier roles. After group changes, use -Login (and -UseDeviceCode on a VM); -RefreshToken alone may reuse the cache.'
}
Write-Host ""
if ($PrintOnly) { return }
if ($RefreshToken) {
  Write-Host "Copilot will acquire the gateway token per request using the pinned credential helper. Run 'copilot' now."
}
elseif ($AuthMode -eq 'jwt') {
  Write-Host "Token expires in ~1 hour. Re-run to refresh, then run 'copilot'."
}
else {
  Write-Host "Subscription key does not expire. Run 'copilot' now."
}

# If we did all this under Windows PowerShell 5.1 but PS7 is available, drop the user into an
# interactive PS7 shell now. It inherits the COPILOT_PROVIDER_* env vars we just set (and the PATH
# entry for the npm-global copilot), so `copilot` runs on the supported PowerShell with BYOK config.
if ($script:PwshForFinalLaunch -and $script:IsInteractive) {
  Write-Host ""
  Write-Host "Opening PowerShell 7 with your BYOK configuration loaded. Type 'copilot' to start; 'exit' to return."
  & $script:PwshForFinalLaunch -NoLogo -NoExit
}

