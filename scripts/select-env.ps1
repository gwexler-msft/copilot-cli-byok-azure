#requires -Version 7.0
<#
.SYNOPSIS
  Switch the active BYOK deployment environment (Gov vs Commercial) in one step.
.DESCRIPTION
  Removes the friction of manually swapping infra/main.parameters.json when moving
  between clouds. It keeps ONE persistent, gitignored parameters file per environment
  (infra/main.parameters.<EnvName>.json) so your filled-in secrets — tenant id,
  publisher email, app audience, etc. — survive every switch. The "active" file that
  azd / az read (infra/main.parameters.json) is just a copy of the selected env's file.

  WHAT IT DOES:
    1. Seeds infra/main.parameters.<EnvName>.json from the matching example profile
       the first time you select an env (then stops so you can fill placeholders).
    2. Copies that per-env file over infra/main.parameters.json (the active file).
    3. Selects the azd environment (.azure/<EnvName>/), creating it if missing.
    4. With -SetCloud, also points the Azure CLI + azd at the right cloud.

  Both clouds can coexist: each has its own .azure/<EnvName>/ folder, its own
  main.parameters.<EnvName>.json, and lands in its own resource group
  (rg-copilot-byok-<EnvName>).

.PARAMETER EnvName
  Environment short name, e.g. gov-pilot or comm-pilot. Drives the per-env params
  file name, the azd environment, and (via Bicep) the resource group name.
.PARAMETER Profile
  Which example profile to seed from: 'gov' (AzureUSGovernment) or 'commercial'
  (AzureCloud). If omitted, inferred from EnvName ('gov-*' -> gov, 'comm-*' ->
  commercial); otherwise required.
.PARAMETER SetCloud
  Also run 'az cloud set' and 'azd config set cloud.name' for the profile's cloud.
  NOTE: azd's cloud.name is a GLOBAL setting, so this affects all azd environments
  on this machine until changed again. You still need to 'az login' afterwards.
.PARAMETER Force
  Overwrite the active infra/main.parameters.json without confirmation (it is only a
  copy, so this is always safe).
.EXAMPLE
  ./select-env.ps1 -EnvName gov-pilot
  Switch to the Gov pilot environment.
.EXAMPLE
  ./select-env.ps1 -EnvName comm-pilot -SetCloud
  Switch to the Commercial pilot, and point az + azd at AzureCloud.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$EnvName,
  [ValidateSet('gov', 'commercial')]
  [string]$Profile,
  [switch]$SetCloud,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Resolve repo root (scripts/ is directly under the repo root).
$repoRoot = Split-Path -Parent $PSScriptRoot
$infraDir = Join-Path $repoRoot 'infra'

# Infer the profile from the env name when not given.
if (-not $Profile) {
  switch -Wildcard ($EnvName) {
    'gov-*'  { $Profile = 'gov' }
    'comm-*' { $Profile = 'commercial' }
    default {
      throw "Cannot infer -Profile from EnvName '$EnvName'. Pass -Profile gov|commercial."
    }
  }
}

$profileMap = @{
  gov        = @{ Example = 'main.parameters.gov.example.json';        Cloud = 'AzureUSGovernment' }
  commercial = @{ Example = 'main.parameters.commercial.example.json'; Cloud = 'AzureCloud' }
}
$exampleFile = Join-Path $infraDir $profileMap[$Profile].Example
$cloudName   = $profileMap[$Profile].Cloud
$perEnvFile  = Join-Path $infraDir "main.parameters.$EnvName.json"
$activeFile  = Join-Path $infraDir 'main.parameters.json'

if (-not (Test-Path $exampleFile)) { throw "Example profile not found: $exampleFile" }

Write-Host "Environment: $EnvName"
Write-Host "Profile:     $Profile ($cloudName)"

# 1. Seed the per-env params file on first use.
if (-not (Test-Path $perEnvFile)) {
  if (Test-Path $activeFile) {
    # Adopt an already-filled active file (e.g. an existing single-env setup) so its
    # secrets are preserved as this env's persistent copy.
    Copy-Item $activeFile $perEnvFile
    Write-Host "`nSeeded $([IO.Path]::GetFileName($perEnvFile)) from your existing infra/main.parameters.json."
  }
  else {
    # No active file yet — seed from the example template, then stop for placeholders.
    Copy-Item $exampleFile $perEnvFile
    Write-Host "`nSeeded $([IO.Path]::GetFileName($perEnvFile)) from $($profileMap[$Profile].Example)."
    Write-Host "Fill in every <PLACEHOLDER> value in that file, then re-run this script." -ForegroundColor Yellow
    exit 2
  }
}

# Guard against shipping unfilled placeholders.
if ((Get-Content $perEnvFile -Raw) -match '<[A-Z0-9_]+>') {
  Write-Host "`n$([IO.Path]::GetFileName($perEnvFile)) still contains <PLACEHOLDER> values." -ForegroundColor Yellow
  Write-Host 'Fill them in before provisioning.' -ForegroundColor Yellow
}

# 2. Copy the per-env file over the active file.
if ((Test-Path $activeFile) -and -not $Force) {
  $ans = Read-Host "Overwrite active infra/main.parameters.json from $([IO.Path]::GetFileName($perEnvFile))? [Y/n]"
  if ($ans -and $ans -notmatch '^(y|yes)$') { throw 'Aborted by user.' }
}
Copy-Item $perEnvFile $activeFile -Force
Write-Host "Active params -> infra/main.parameters.json (copy of $([IO.Path]::GetFileName($perEnvFile)))"

# 3. Optionally point az + azd at the right cloud (azd cloud.name is global).
if ($SetCloud) {
  az cloud set --name $cloudName 1>$null
  azd config set cloud.name $cloudName 1>$null
  Write-Host "Cloud set to $cloudName (az + azd global). Run 'az login' if your session is for a different cloud."
}

# 4. Select the azd environment, creating it if it does not exist.
$envs = azd env list -o json 2>$null | ConvertFrom-Json
$exists = $envs | Where-Object { $_.Name -eq $EnvName }
if ($exists) {
  azd env select $EnvName
  Write-Host "Selected existing azd environment: $EnvName"
}
else {
  Write-Host "azd environment '$EnvName' not found — creating it (you'll be prompted for subscription + location)."
  azd env new $EnvName
}

Write-Host "`nDone. Active environment: $EnvName -> resource group rg-copilot-byok-$EnvName"
Write-Host "Next: review infra/main.parameters.$EnvName.json, then 'azd provision'."
