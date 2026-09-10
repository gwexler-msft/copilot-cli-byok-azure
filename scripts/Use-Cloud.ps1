# Pin the current terminal to one Azure cloud (commercial or US-Gov) and rename
# the VS Code terminal tab so you can see which cloud you're driving at a glance.
#
# Why this exists:
#   The `az` CLI stores credentials, active subscription, and cloud endpoint in
#   a single directory (`$env:AZURE_CONFIG_DIR`, default `~/.azure`). Without
#   isolation, running `az login` in any VS Code terminal silently changes the
#   active cloud / sub for every other terminal on the same Windows account.
#   This script gives each terminal its own `AZURE_CONFIG_DIR` and matching tab
#   name so commercial and gov work can run side-by-side without bleed.
#
# Usage (dot-source so the env var sticks in the parent terminal):
#   . .\scripts\Use-Cloud.ps1 comm
#   . .\scripts\Use-Cloud.ps1 gov
#   . .\scripts\Use-Cloud.ps1 comm -SubscriptionId 62dff173-...
#   . .\scripts\Use-Cloud.ps1 comm -Reauth     # after activating a PIM role
#
# After the first call in a new tab, it will:
#   1. Set `$env:AZURE_CONFIG_DIR` to `~/.azure-<cloud>`
#   2. Print the OSC-633 title sequence so VS Code renames the tab
#   3. If not logged in, prompt for device-code login against the right tenant
#   4. Set the active subscription if -SubscriptionId is supplied or known
#   5. Print the current `az account show` summary
#
# The script never mutates global / user env vars, only the current process.

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('comm', 'commercial', 'gov', 'government', 'usgov')]
    [string]$Cloud,

    # Optional explicit subscription id (overrides the per-cloud defaults below).
    [string]$SubscriptionId,

    # Skip login even if not authenticated (just pin the dir + name).
    [switch]$NoLogin,

    # Force a fresh `az login` even if a valid cached token exists. Use this right
    # after activating a PIM role (e.g. Owner) - the CLI otherwise reuses the old
    # token until it expires (~1h), so ARM keeps authorizing off the PRE-activation
    # claims and writes fail with AuthorizationFailed while reads still succeed.
    [switch]$Reauth
)

$ErrorActionPreference = 'Stop'

# ---- Cloud aliases + per-cloud defaults --------------------------------------
$normalized = switch ($Cloud) {
    'commercial' { 'comm' }
    'government' { 'gov' }
    'usgov'      { 'gov' }
    default      { $Cloud }
}

# Tenant / subscription are resolved from the environment so no directory ID is committed. Set
# them once per machine (e.g. in $PROFILE):
#   $env:BYOK_COMM_TENANT_ID / $env:BYOK_COMM_SUBSCRIPTION_ID
#   $env:BYOK_GOV_TENANT_ID  / $env:BYOK_GOV_SUBSCRIPTION_ID
# A gitignored scripts/.cloud-config.json overrides them when present:
#   { "comm": { "tenantId": "...", "subscriptionId": "..." }, "gov": { ... } }
$localCfgPath = Join-Path $PSScriptRoot '.cloud-config.json'
$localCfg = if (Test-Path $localCfgPath) { Get-Content $localCfgPath -Raw | ConvertFrom-Json } else { $null }

function Resolve-CloudId([string] $Key, [string] $Field, [string] $EnvVar) {
    if ($localCfg -and $localCfg.$Key -and $localCfg.$Key.$Field) { return $localCfg.$Key.$Field }
    return [Environment]::GetEnvironmentVariable($EnvVar)
}

$cfg = @{
    comm = @{
        AzCloud        = 'AzureCloud'
        TenantId       = Resolve-CloudId 'comm' 'tenantId'       'BYOK_COMM_TENANT_ID'
        DefaultSubId   = Resolve-CloudId 'comm' 'subscriptionId' 'BYOK_COMM_SUBSCRIPTION_ID'
        TitlePrefix    = 'AZ-COMM'
        ConfigDir      = Join-Path $HOME '.azure-comm'
    }
    gov = @{
        AzCloud        = 'AzureUSGovernment'
        TenantId       = Resolve-CloudId 'gov' 'tenantId'       'BYOK_GOV_TENANT_ID'
        DefaultSubId   = Resolve-CloudId 'gov' 'subscriptionId' 'BYOK_GOV_SUBSCRIPTION_ID'
        TitlePrefix    = 'AZ-GOV'
        ConfigDir      = Join-Path $HOME '.azure-gov'
    }
}[$normalized]

# ---- Pin AZURE_CONFIG_DIR (process scope only) -------------------------------
New-Item -ItemType Directory -Path $cfg.ConfigDir -Force | Out-Null
$env:AZURE_CONFIG_DIR = $cfg.ConfigDir
[Environment]::SetEnvironmentVariable('AZURE_CONFIG_DIR', $cfg.ConfigDir, 'Process')

# ---- Rename the VS Code terminal tab via OSC-633 -----------------------------
# VS Code shell integration honors ESC ] 633 ; P ; Task=<title> BEL to set the
# tab name. Falls back gracefully outside VS Code (the sequence is just ignored).
$title = "$($cfg.TitlePrefix)  $(Split-Path $PWD -Leaf)"
$esc = [char]27
$bel = [char]7
Write-Host "$esc]0;$title$bel" -NoNewline   # classic xterm title (PowerShell host)
Write-Host "$esc]633;P;Task=$title$bel" -NoNewline  # VS Code shell integration
try { $Host.UI.RawUI.WindowTitle = $title } catch { }

Write-Host ""
Write-Host "[$($cfg.TitlePrefix)] AZURE_CONFIG_DIR = $($cfg.ConfigDir)" -ForegroundColor Cyan
Write-Host "[$($cfg.TitlePrefix)] Cloud            = $($cfg.AzCloud)" -ForegroundColor Cyan
Write-Host "[$($cfg.TitlePrefix)] Tenant           = $(if ($cfg.TenantId) { $cfg.TenantId } else { '(not set)' })" -ForegroundColor Cyan
Write-Host ""

# ---- Ensure the cloud is selected in this config dir -------------------------
$activeCloud = (az cloud show --query name -o tsv 2>$null)
if ($activeCloud -ne $cfg.AzCloud) {
    az cloud set --name $cfg.AzCloud | Out-Null
}

# ---- Login if needed ---------------------------------------------------------
# Use `az account show` rather than `az account list | length` - the latter
# returns "[]" / 0 in some edge cases (e.g. stale token cache, transient
# refresh errors) even when a working credential is present. `account show`
# either succeeds with the active sub or exits non-zero, which is the real
# signal we care about.
$loggedIn = $false
try {
    $null = az account show --query id -o tsv 2>$null
    if ($LASTEXITCODE -eq 0) { $loggedIn = $true }
} catch { $loggedIn = $false }

# Without a configured tenant, let `az login` pick the default rather than passing an empty --tenant.
$tenantArgs = if ($cfg.TenantId) { @('--tenant', $cfg.TenantId) } else { @() }
$tenantLabel = if ($cfg.TenantId) { "tenant $($cfg.TenantId)" } else { 'the default tenant' }

if ($Reauth) {
    # Force a fresh credential regardless of cache. -Reauth wins over -NoLogin.
    Write-Host "Forcing fresh login against $tenantLabel (-Reauth)..." -ForegroundColor Yellow
    az login --use-device-code @tenantArgs | Out-Null
}
elseif (-not $loggedIn) {
    if ($NoLogin) {
        Write-Warning "Not logged in to $($cfg.AzCloud); skipping (-NoLogin)."
        return
    }
    Write-Host "Not logged in. Starting device-code login against $tenantLabel..." -ForegroundColor Yellow
    az login --use-device-code @tenantArgs | Out-Null
}

# ---- Pick subscription -------------------------------------------------------
$targetSub = if ($SubscriptionId) { $SubscriptionId } else { $cfg.DefaultSubId }
if ($targetSub) {
    az account set --subscription $targetSub 2>$null
}

# ---- Show what the user got --------------------------------------------------
az account show --query '{env:environmentName, sub:name, id:id, tenantId:tenantId}' -o jsonc
