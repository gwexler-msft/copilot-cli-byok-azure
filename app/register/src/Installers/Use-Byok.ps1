#requires -Version 7.0
<#
.SYNOPSIS
  One-shot local installer for BYOK on VS Code + GitHub Copilot CLI. Rendered per-developer by
  the register app (the APIM host + your personal subscription key are already inlined below).
.DESCRIPTION
  Merges three local surfaces in place, NEVER clobbering unrelated config (idempotent re-runs):
    1. VS Code  chatLanguageModels.json  - adds/refreshes the "BYOK ..." provider blocks only.
    2. VS Code  settings.json            - utility-model pair + telemetry/call-home lockdown.
    3. Copilot CLI  COPILOT_PROVIDER_*    - User-scope (HKCU) environment variables.

  It NEVER sets COPILOT_OFFLINE - that kill switch breaks BYOK (suppresses the identity/token
  call). CLI/editor privacy is enforced at the network layer (egress allowlist), not a switch.

  Opt-outs:  -SkipUtilityModels  -SkipPrivacyLockdown  -SkipCliEnv
  Targets:   stable VS Code by default; add -Insiders to also target "Code - Insiders".
#>
[CmdletBinding()]
param(
  [switch]$SkipUtilityModels,
  [switch]$SkipPrivacyLockdown,
  [switch]$SkipCliEnv,
  [switch]$Insiders
)

$ErrorActionPreference = 'Stop'

# ---- Rendered per-developer by the register app -------------------------------------------
$apimHost = '@@APIM_HOST@@'
$apimKey  = '@@APIM_KEY@@'
$baseUrl  = '@@BASE_URL@@'
$cliModel = '@@CLI_MODEL@@'
$miniModelName = '@@MINI_MODEL_NAME@@'
$chatModelsJson = @'
@@CHAT_MODELS_JSON@@
'@
# -------------------------------------------------------------------------------------------

function Get-VsCodeUserDirs {
  $dirs = @()
  $variants = @('Code')
  if ($Insiders) { $variants += 'Code - Insiders' }
  foreach ($v in $variants) {
    $d = Join-Path $env:APPDATA (Join-Path $v 'User')
    if (Test-Path $d) { $dirs += $d } else { Write-Host "  (skip) $v not installed at $d" }
  }
  return $dirs
}

function Merge-ChatLanguageModels([string]$userDir) {
  $path = Join-Path $userDir 'chatLanguageModels.json'
  $ours = $chatModelsJson | ConvertFrom-Json
  if (Test-Path $path) {
    Copy-Item $path "$path.byok.bak" -Force
    try {
      $existing = (Get-Content $path -Raw | ConvertFrom-Json -Depth 50)
    } catch {
      Write-Warning "  $path is not valid JSON; backed up to $path.byok.bak and replacing."
      $existing = @()
    }
    if ($null -eq $existing) { $existing = @() }
    if ($existing -isnot [System.Array]) { $existing = @($existing) }
    # Drop our previous provider blocks (matched by the 'BYOK ' name prefix), keep everything else.
    $kept = @($existing | Where-Object { $_.name -notlike 'BYOK *' })
    $merged = @($kept) + @($ours)
  } else {
    $merged = @($ours)
  }
  ($merged | ConvertTo-Json -Depth 50 -AsArray) | Set-Content $path -Encoding utf8
  Write-Host "  chatLanguageModels.json: wrote $($merged.Count) provider block(s) -> $path"
}

function Merge-Settings([string]$userDir) {
  $desired = [ordered]@{}
  if (-not $SkipUtilityModels) {
    $desired['chat.utilityModel']      = $miniModelName
    $desired['chat.utilitySmallModel'] = $miniModelName
  }
  if (-not $SkipPrivacyLockdown) {
    $desired['telemetry.telemetryLevel']                       = 'off'
    $desired['update.mode']                                    = 'none'
    $desired['update.showReleaseNotes']                        = $false
    $desired['extensions.autoCheckUpdates']                    = $false
    $desired['extensions.autoUpdate']                          = $false
    $desired['workbench.enableExperiments']                    = $false
    $desired['workbench.settings.enableNaturalLanguageSearch'] = $false
    $desired['npm.fetchOnlinePackageInfo']                     = $false
    $desired['json.schemaDownload.enable']                     = $false
    $desired['redhat.telemetry.enabled']                       = $false
    $desired['github.copilot.enable']                          = @{ '*' = $false }
  }
  if ($desired.Count -eq 0) { Write-Host '  settings.json: nothing to write (both groups skipped).'; return }

  $path = Join-Path $userDir 'settings.json'
  $current = $null
  if (Test-Path $path) {
    Copy-Item $path "$path.byok.bak" -Force
    try {
      $current = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable -Depth 50 -IgnoreComments
    } catch {
      $frag = Join-Path $userDir 'byok.settings-fragment.json'
      ($desired | ConvertTo-Json -Depth 10) | Set-Content $frag -Encoding utf8
      Write-Warning "  settings.json has comments/trailing commas this script can't safely parse."
      Write-Warning "  Wrote the keys to merge by hand -> $frag (your settings.json was NOT modified)."
      return
    }
  }
  if ($null -eq $current) { $current = @{} }
  foreach ($k in $desired.Keys) { $current[$k] = $desired[$k] }
  ($current | ConvertTo-Json -Depth 50) | Set-Content $path -Encoding utf8
  Write-Host "  settings.json: merged $($desired.Count) key(s) -> $path"
}

function Set-CliEnv {
  if ($SkipCliEnv) { Write-Host '  CLI env: skipped (-SkipCliEnv).'; return }
  # User scope (HKCU) - per-developer, never machine-wide (no admin, no key sharing).
  [Environment]::SetEnvironmentVariable('COPILOT_PROVIDER_TYPE',              'azure',   'User')
  [Environment]::SetEnvironmentVariable('COPILOT_PROVIDER_BASE_URL',          $baseUrl,  'User')
  [Environment]::SetEnvironmentVariable('COPILOT_PROVIDER_API_KEY',           $apimKey,  'User')
  [Environment]::SetEnvironmentVariable('COPILOT_PROVIDER_WIRE_API',          'responses', 'User')
  # Without COPILOT_MODEL the CLI refuses to start: "BYOK providers require an explicit model."
  [Environment]::SetEnvironmentVariable('COPILOT_MODEL',                      $cliModel, 'User')
  [Environment]::SetEnvironmentVariable('COPILOT_PROVIDER_MAX_PROMPT_TOKENS', '1050000', 'User')
  [Environment]::SetEnvironmentVariable('COPILOT_PROVIDER_MAX_OUTPUT_TOKENS', '128000',  'User')
  Write-Host "  CLI env: set COPILOT_PROVIDER_* + COPILOT_MODEL=$cliModel in User scope (open a NEW terminal to pick up)."
}

# Reports only. Missing CLI tooling must not block the VS Code half of the install, and installing
# Node/PowerShell needs elevation this script deliberately never takes.
function Show-Prereqs {
  Write-Host 'Prerequisites:'
  Write-Host "  PowerShell  : $($PSVersionTable.PSVersion)"

  if (Get-Command node -ErrorAction SilentlyContinue) {
    Write-Host "  Node.js     : $(& node --version)"
  } else {
    Write-Host '  Node.js     : NOT FOUND - needed only by the Copilot CLI' -ForegroundColor Yellow
    Write-Host '                install Node.js 22+ : winget install OpenJS.NodeJS.LTS' -ForegroundColor Yellow
    Write-Host '                or download from https://nodejs.org/en/download' -ForegroundColor Yellow
  }

  $copilot = Get-Command copilot -ErrorAction SilentlyContinue
  if ($copilot) {
    Write-Host "  Copilot CLI : $($copilot.Source)"
  } else {
    Write-Host '  Copilot CLI : NOT FOUND' -ForegroundColor Yellow
    Write-Host '                npm install -g @github/copilot@latest   (or: winget install GitHub.Copilot)' -ForegroundColor Yellow
  }
  Write-Host ''
}

Write-Host "BYOK local installer - APIM host: $apimHost`n"
Show-Prereqs

$userDirs = Get-VsCodeUserDirs
if ($userDirs.Count -eq 0) {
  Write-Warning 'No VS Code User folder found. Install VS Code (or pass -Insiders) then re-run.'
} else {
  foreach ($d in $userDirs) {
    Write-Host "VS Code User dir: $d"
    Merge-ChatLanguageModels $d
    Merge-Settings $d
  }
}

Set-CliEnv

Write-Host @"

Done. Next steps:
  1. Reload VS Code (Command Palette -> 'Developer: Reload Window') so the BYOK models register.
  2. Open a NEW terminal so the Copilot CLI env vars load, then run:  copilot "say hello"
  3. Pick a 'BYOK ...' model in the chat model picker.
  4. If chat returns 'invalid subscription key', VS Code is sending a key from its own secret
     storage instead of the one in the config file. Fix it with 'Chat: Manage Language Models'
     -> gear icon next to the BYOK provider -> paste your key.

Re-running this installer is safe: it preserves unrelated providers, settings, and environment.
"@
