#requires -Version 7.0
<#
.SYNOPSIS
  Pre-provision guard that stops a provision from WIPING populated pilot values when CI-only
  environment variables are absent. Wired as an azd `preprovision` hook AFTER ensure-byok-groups.

.DESCRIPTION
  `azd provision` is a declarative overwrite: it sets every APIM named value / param-driven resource
  to whatever the parameter file resolves to at that moment. Parameters wired as `${VAR}` (e.g.
  `"foundryCommercialBaseUrl": { "value": "${COMMERCIAL_FOUNDRY_BASE_URL}" }`) are populated by CI,
  which exports the vars from the env's GitHub settings. A LOCAL `azd provision` typically runs
  WITHOUT those vars, so `${VAR}` resolves to empty, the Bicep defaults take over, and the provision
  overwrites the previously-good values with placeholders. This actually broke the cross-cloud
  Commercial Foundry route once (foundry-commercial-* named values reset to `https://unset.invalid`
  / `servicePrincipalFederated` / `organizations` / `unset` -> every call 502).

  This guard reads the parameter file azd actually deploys (infra/main.parameters.json - the
  workflows stage the per-env file into it before provision), resolves `${VAR}` against the
  environment exactly as azd will, and:

    OPTION 2 (HARD gate) - Commercial Foundry route:
      If deployFoundryCommercial=true but foundryCommercialBaseUrl / -TenantId / -ClientId
      (or -ClientSecret in servicePrincipal mode) resolve to empty/placeholder => ABORT (exit 1)
      with guidance. This makes the wipe impossible via the normal azd path.

    OPTION 3 (advisory scan) - any `${VAR}` param that resolves EMPTY:
      Lists every parameter that would deploy blank, with a louder banner on `*-pilot` envs
      (where blanking a currently-populated value is destructive). Non-fatal by design: some
      empties are intentional (e.g. the register Easy Auth two-phase bring-up, or a route that is
      off for this env), so this stays a visible WARNING rather than a hard failure. Secret values
      are NEVER printed - only the parameter + env-var NAME.

  CI-safe: CI exports the vars, so the hard gate passes; it makes no interactive calls.
  Escape hatch: SKIP_PROVISION_PARAM_CHECK=true bypasses the whole guard.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if ($env:SKIP_PROVISION_PARAM_CHECK -eq 'true') {
    Write-Host "[provision-params] SKIP_PROVISION_PARAM_CHECK=true - skipping guard." -ForegroundColor Yellow
    exit 0
}

$paramFile = Join-Path $PSScriptRoot '../infra/main.parameters.json'
if (-not (Test-Path -LiteralPath $paramFile)) {
    Write-Host "[provision-params] $paramFile not found - skipping guard."
    exit 0
}
$params = (Get-Content -Raw -LiteralPath $paramFile | ConvertFrom-Json).parameters

function Resolve-ParamValue {
    param($Params, [string]$Name)
    if (-not ($Params.PSObject.Properties.Name -contains $Name)) { return $null }
    $v = $Params.$Name.value
    if ($v -is [string] -and $v -match '^\$\{(.+)\}$') {
        return [Environment]::GetEnvironmentVariable($Matches[1])
    }
    return $v
}

$envName = if ($env:AZURE_ENV_NAME) { $env:AZURE_ENV_NAME } else { [string](Resolve-ParamValue $params 'envName') }
$envLabel = if ($envName) { $envName } else { 'main.parameters.json' }
$isPilot = $envName -match '-pilot$'

# ---- OPTION 2: Commercial Foundry route HARD gate -------------------------------------------
$deployComm = Resolve-ParamValue $params 'deployFoundryCommercial'
if ($deployComm -eq $true -or "$deployComm" -eq 'true') {
    $base     = [string](Resolve-ParamValue $params 'foundryCommercialBaseUrl')
    $tenant   = [string](Resolve-ParamValue $params 'foundryCommercialTenantId')
    $client   = [string](Resolve-ParamValue $params 'foundryCommercialClientId')
    $authMode = [string](Resolve-ParamValue $params 'foundryCommercialAuthMode')
    $secret   = [string](Resolve-ParamValue $params 'foundryCommercialClientSecret')

    $bad = @()
    if ([string]::IsNullOrWhiteSpace($base)   -or $base   -eq 'https://unset.invalid') { $bad += 'foundryCommercialBaseUrl (COMMERCIAL_FOUNDRY_BASE_URL)' }
    if ([string]::IsNullOrWhiteSpace($tenant) -or $tenant -eq 'organizations')         { $bad += 'foundryCommercialTenantId (COMMERCIAL_TENANT_ID)' }
    if ([string]::IsNullOrWhiteSpace($client) -or $client -eq 'unset')                 { $bad += 'foundryCommercialClientId (COMMERCIAL_CLIENT_ID)' }
    if ($authMode -eq 'servicePrincipal' -and [string]::IsNullOrWhiteSpace($secret))   { $bad += 'foundryCommercialClientSecret (COMMERCIAL_FOUNDRY_CLIENT_SECRET)' }

    if ($bad.Count -gt 0) {
        Write-Host ""
        Write-Host "COMMERCIAL BACKEND CHECK FAILED ($envLabel)." -ForegroundColor Red
        Write-Host "  deployFoundryCommercial=true, but these resolve to empty/placeholder:" -ForegroundColor Red
        foreach ($b in $bad) { Write-Host "    - $b" -ForegroundColor Red }
        Write-Host ""
        Write-Host "Provisioning now would OVERWRITE the live foundry-commercial-* APIM named values with" -ForegroundColor Yellow
        Write-Host "placeholders (base-url=https://unset.invalid, auth-mode=servicePrincipalFederated, ...)," -ForegroundColor Yellow
        Write-Host "breaking every commercial-model request (502). Classic 'local azd provision without the" -ForegroundColor Yellow
        Write-Host "COMMERCIAL_* env vars' wipe. Fix ONE of:" -ForegroundColor Yellow
        Write-Host "  1. Provision via CI (deploy.yml) - it exports COMMERCIAL_* from the env's GitHub settings."
        Write-Host "  2. Or export COMMERCIAL_FOUNDRY_BASE_URL, COMMERCIAL_TENANT_ID, COMMERCIAL_CLIENT_ID"
        Write-Host "     (+ COMMERCIAL_FOUNDRY_CLIENT_SECRET for servicePrincipal) before provisioning."
        Write-Host "  3. Or turn the backend off for this provision: deployFoundryCommercial=false."
        Write-Host "  4. Or intentional? Re-run with SKIP_PROVISION_PARAM_CHECK=true."
        exit 1
    }
    Write-Host "[provision-params] Commercial backend enabled and all COMMERCIAL_* values resolved. OK." -ForegroundColor Green
}

# ---- OPTION 3: general empty-${VAR} substitution scan (advisory; louder on pilots) ----------
$emptySubs = @()
foreach ($p in $params.PSObject.Properties) {
    $raw = $p.Value.value
    if ($raw -is [string] -and $raw -match '^\$\{(.+)\}$') {
        $varName = $Matches[1]
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($varName))) {
            $emptySubs += ('{0} (${{{1}}})' -f $p.Name, $varName)
        }
    }
}
if ($emptySubs.Count -gt 0) {
    Write-Host ""
    Write-Host "[provision-params] NOTE ($envLabel): $($emptySubs.Count) parameter(s) reference an env var that is EMPTY and will deploy blank:" -ForegroundColor Yellow
    foreach ($e in $emptySubs) { Write-Host "    - $e" -ForegroundColor Yellow }
    if ($isPilot) {
        Write-Host ""
        Write-Host "  This is a PILOT env. If any of the above are currently populated LIVE, this provision will WIPE them." -ForegroundColor Red
        Write-Host "  That is exactly what a LOCAL 'azd provision' missing the CI env vars does. Strongly prefer CI, or" -ForegroundColor Red
        Write-Host "  export the values first. (Intentional cases like the register Easy Auth two-phase bring-up are expected.)" -ForegroundColor Red
    }
}

exit 0
