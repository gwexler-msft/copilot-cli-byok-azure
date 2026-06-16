#requires -Version 5.1
<#
.SYNOPSIS
  Configure the current shell to run `copilot` (GitHub Copilot CLI) against the private APIM,
  or run a one-shot smoke test of the gateway.
.DESCRIPTION
  Exports the four COPILOT_PROVIDER_* environment variables with the per-developer credential,
  and (optionally) runs a curl smoke test against the chat-completions route.

  Two auth modes, matching the gateway's `authMode` Bicep parameter:
    - subscriptionKey (DEFAULT): you present a long-lived per-developer APIM subscription key.
      No token mint, no expiry, no Entra round-trip. This matches the default deployment.
    - jwt: the script mints a short-lived (~1h) Entra JWT for the BYOK API app. Opt in with
      `-AuthMode jwt`. Re-run to refresh the token.

  Notes:
    - The credential rides in COPILOT_PROVIDER_API_KEY (the `api-key` header) because the CLI
      cannot send custom headers (github/copilot-cli#3399). APIM strips it before the backend.
    - jwt mode: with v2 access tokens the JWT 'aud' is the app (client) ID GUID, NOT the api://
      URI. We mint with `--scope "<AppId>/.default"`, which also dodges az's per-resource token
      cache handing back a stale-audience token. Works in AzureCloud and AzureUSGovernment.
.PARAMETER ApimBaseUrl
  Full HTTPS base URL of the APIM gateway (e.g. https://apim-...azure-api.us). The /openai
  suffix is appended automatically if you omit it, so https://apim-...azure-api.us and
  https://apim-...azure-api.us/openai are equivalent.
.PARAMETER Model
  Model/deployment name to use (matches what was deployed), e.g. gpt-5.1.
.PARAMETER AuthMode
  'subscriptionKey' (default) or 'jwt'. Selects which credential is sent to the gateway.
.PARAMETER SubscriptionKey
  (subscriptionKey mode) The per-developer APIM subscription key. If omitted, falls back to
  the APIM_SUBSCRIPTION_KEY environment variable. Avoid passing secrets on the command line;
  prefer the env var.
.PARAMETER AppId
  (jwt mode) The app (client) ID GUID of the BYOK gateway app (output of setup-entra). Used as
  the token scope and equals the JWT audience validated by APIM. Required only for -AuthMode jwt.
.PARAMETER ApimPrivateIp
  Optional. APIM Internal-VNet private IP. When set, curl uses --resolve so you do not need a
  hosts entry or private DNS zone. Only used by -Test.
.PARAMETER MaxPromptTokens
  Optional. Sets COPILOT_PROVIDER_MAX_PROMPT_TOKENS. Needed when -Model is a value the CLI does
  not have in its built-in catalog (e.g. the gateway 'auto' router): without it the CLI warns and
  falls back to small defaults. Defaults to 272000 (gpt-5.1 input cap, the smaller of the 'auto'
  pool) for any non-catalog model.
.PARAMETER MaxOutputTokens
  Optional. Sets COPILOT_PROVIDER_MAX_OUTPUT_TOKENS. Same rationale as -MaxPromptTokens. Defaults
  to 32768 (gpt-4.1-mini output cap, the smaller of the 'auto' pool) for any non-catalog model.
.PARAMETER Test
  Send a chat-completion to the gateway, printing the HTTP status and body.
.PARAMETER PrintOnly
  Export the env vars but do not print the "run copilot now" hint.
.PARAMETER InstallDeps
  If the Copilot CLI (or its prerequisites) are missing, attempt to install them with WinGet
  (PowerShell 7+, Node.js 22+ and the Copilot CLI). Without this switch the script only PRINTS
  the install commands and stops. Requires WinGet (App Installer); if WinGet itself is missing
  the script prints how to get it (https://aka.ms/getwinget).
.EXAMPLE
  # DEFAULT (subscription key) — configure the shell for the real Copilot CLI:
  $env:APIM_SUBSCRIPTION_KEY = '<your per-developer key>'
  ./copilot-cli-byok.ps1 -ApimBaseUrl 'https://<apim-name>.azure-api.us/openai' `
                         -Model gpt-5.1
  copilot "what does this repo do?"
.EXAMPLE
  # DEFAULT (subscription key) — smoke test from the in-VNet VM (no hosts edit needed):
  ./copilot-cli-byok.ps1 -ApimBaseUrl 'https://<apim-name>.azure-api.us/openai' `
                         -Model gpt-5.1 `
                         -SubscriptionKey '<your per-developer key>' `
                         -ApimPrivateIp 10.60.1.4 `
                         -Test
.EXAMPLE
  # OPT-IN (Entra JWT) — mint a ~1h token instead of using a subscription key:
  ./copilot-cli-byok.ps1 -AuthMode jwt `
                         -AppId <entra-app-client-id> `
                         -ApimBaseUrl 'https://<apim-name>.azure-api.us/openai' `
                         -Model gpt-5.1
#>
[CmdletBinding()]
param(
  # Leave these empty to be prompted (and to reuse the saved config from a previous run). If you
  # prefer a turn-key script, you MAY hardcode your own defaults here, e.g.
  #   [string] $ApimBaseUrl = 'https://<apim>.azure-api.us/openai',
  #   [string] $SubscriptionKey = '<your per-developer key>',
  # A hardcoded value here always wins over the saved config and the interactive prompt. (Note: a
  # baked-in subscription key lives in the file in plaintext — prefer $env:APIM_SUBSCRIPTION_KEY.)
  [string] $ApimBaseUrl = '',
  [string] $Model = '',
  [ValidateSet('subscriptionKey', 'jwt')] [string] $AuthMode = 'subscriptionKey',
  [string] $SubscriptionKey = '',
  [string] $AppId,
  [string] $ApimPrivateIp,
  [int] $MaxPromptTokens,
  [int] $MaxOutputTokens,
  [switch] $Test,
  [switch] $PrintOnly,
  [switch] $InstallDeps
)

$ErrorActionPreference = 'Stop'

$script:IsInteractive = $Host.Name -ne 'Default Host' -and -not [Console]::IsInputRedirected

function Install-PowerShell7 {
  # Prefer WinGet; otherwise fall back to Microsoft's official installer script, which downloads
  # and silently installs the MSI — no WinGet / Store required (works on stock Windows Server).
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
# The wrapper's own steps — prompting, installing, minting the JWT, exporting the env vars — all
# work in Windows PowerShell 5.1, so we do EVERYTHING in THIS process. That matters: the
# COPILOT_PROVIDER_* env vars must be set in the real session, and a relaunched child process
# would lose them on exit. If we're on 5.1 we just make sure PS7 is available; at the very end we
# drop the user into an interactive PS7 shell that INHERITS those env vars (child processes inherit
# the parent environment), so `copilot` runs on a supported PowerShell with the right config.
$script:PwshForFinalLaunch = $null
if ($PSVersionTable.PSVersion.Major -lt 7) {
  $existingPwsh = Get-PwshPath
  if ($existingPwsh) {
    # PS7 already present — remember it; we'll launch into it at the end (after env vars are set).
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
if (-not $Model)       { throw '-Model is required (the deployed model/deployment name, e.g. gpt-5.1, or "auto" to let the gateway route).' }

# Normalize: the gateway routes live under /openai, so append it if the dev left it off (and
# tolerate a trailing slash). This way a forgotten suffix can't silently break things later.
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
    # Prompt for the key (masked). NEVER persisted to disk — only held in this session.
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
else {
  if (-not $AppId) { throw 'jwt mode: -AppId (the BYOK gateway app/client ID GUID) is required.' }
  $ctx = az account show 2>$null | ConvertFrom-Json
  if (-not $ctx) { throw 'Run `az login` first (use the cloud matching the deployment).' }
  Write-Verbose "Cloud=$($ctx.environmentName) Tenant=$($ctx.tenantId) Account=$($ctx.user.name)"

  # v2 token: scope "<AppId>/.default" => aud == AppId GUID (what APIM validate-jwt expects).
  $credential = az account get-access-token --scope "$AppId/.default" --query accessToken -o tsv 2>$null
  if (-not $credential) {
    throw "Could not get token for $AppId. Did you run setup-entra and is this user able to consent to the 'cli.invoke' scope?"
  }
  $credKind = 'Entra JWT (~1h)'
}

$baseUrl = $ApimBaseUrl.TrimEnd('/')

if ($Test) {
  $uri  = "$baseUrl/v1/chat/completions"
  $body = '{"model":"' + $Model + '","messages":[{"role":"user","content":"say hi in three words"}]}'

  $curlArgs = @('-sk', '-w', "`nhttp=%{http_code}`n", '--max-time', '40')
  if ($ApimPrivateIp) {
    $apimHost = ([Uri]$baseUrl).Host
    $curlArgs += @('--resolve', "${apimHost}:443:$ApimPrivateIp")
  }
  $curlArgs += @('-X', 'POST', $uri,
                 '-H', "api-key: $credential",
                 '-H', 'Content-Type: application/json',
                 '-d', $body)

  Write-Host "POST $uri  (authMode=$AuthMode, model=$Model, credential=$credKind, length=$($credential.Length))"
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
      # the CLI. This is the bare-Windows-Server path — no Store, no WinGet required.
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

$env:COPILOT_PROVIDER_BASE_URL = $baseUrl
$env:COPILOT_PROVIDER_TYPE     = 'azure'
$env:COPILOT_PROVIDER_API_KEY  = $credential
$env:COPILOT_MODEL             = $Model

# The CLI looks up token limits from a built-in model catalog. A gateway-routed name like 'auto'
# isn't in that catalog, so the CLI warns and falls back to tiny defaults. Set the limits
# explicitly: honor -MaxPromptTokens/-MaxOutputTokens if given, else apply conservative defaults
# for any non-catalog model. The defaults are the SMALLER limit of each model the gateway 'auto'
# router can pick, so a prompt/response can't overflow whichever way it routes:
#   prompt  272000 = gpt-5.1 input cap (gpt-4.1-mini allows more, so this is the floor)
#   output   32768 = gpt-4.1-mini output cap (gpt-5.1 allows 128000, so this is the floor)
$catalogModels = @('gpt-4.1', 'gpt-4.1-mini', 'gpt-4o', 'gpt-4o-mini', 'gpt-5.1', 'gpt-5', 'o3', 'o4-mini')
$isCatalogModel = $catalogModels -contains $Model
if ($MaxPromptTokens -gt 0) {
  $env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS = "$MaxPromptTokens"
}
elseif (-not $isCatalogModel) {
  $env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS = '272000'
}
if ($MaxOutputTokens -gt 0) {
  $env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS = "$MaxOutputTokens"
}
elseif (-not $isCatalogModel) {
  $env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS = '32768'
}

Write-Host "Configured Copilot CLI for BYOK ($AuthMode):"
Write-Host "  COPILOT_PROVIDER_BASE_URL = $env:COPILOT_PROVIDER_BASE_URL"
Write-Host "  COPILOT_PROVIDER_TYPE     = $env:COPILOT_PROVIDER_TYPE"
Write-Host "  COPILOT_PROVIDER_API_KEY  = <hidden $credKind, length=$($credential.Length)>"
Write-Host "  COPILOT_MODEL             = $env:COPILOT_MODEL"
if ($env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS) {
  Write-Host "  COPILOT_PROVIDER_MAX_PROMPT_TOKENS = $env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS"
}
if ($env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS) {
  Write-Host "  COPILOT_PROVIDER_MAX_OUTPUT_TOKENS = $env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS"
}
Write-Host ""
if ($PrintOnly) { return }
if ($AuthMode -eq 'jwt') {
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

