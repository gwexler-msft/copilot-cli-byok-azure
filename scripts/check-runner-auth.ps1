#requires -Version 7.0
<#
.SYNOPSIS
  Pre-provision guard for the self-hosted runner's GitHub auth (issue #58). Wired as an azd
  `preprovision` hook AFTER check-deploy-access. Fails fast (exit 1) when the runner would be
  deployed in **app** mode but the GitHub App credentials are not resolvable — preventing a silent
  fall-back to the Phase-1 placeholder runner (no scaling).

.DESCRIPTION
  App ID + Installation ID are PROVISION-TIME Bicep params baked into the runner Job spec, so they
  must exist BEFORE `azd provision`. This guard reads the parameter file azd actually deploys
  (infra/main.parameters.json — the workflows stage the per-env file into it before provision),
  resolves any `${VAR}` placeholders against the environment (exactly as azd will), and checks
  coherence:

    - deployGhRunner != true ............ skip (no runner).
    - ghRunnerAuthMode = app ............ require ghAppId + ghAppInstallationId, AND a key source
                                          (ghRunnerSecretFromKeyVault=true [pilots, key in KV] OR
                                          inline ghAppPrivateKey [dev]). Missing => HARD FAIL.
    - ghRunnerAuthMode = pat ............ require ghRunnerPat OR ghRunnerSecretFromKeyVault, else
                                          WARN (PAT is the opt-in fallback; absence => placeholder,
                                          which may be intentional).

  CI-safe: it makes no interactive calls and needs no browser. In CI the App ID/Installation ID
  arrive as repo Variables (GH_APP_ID / GH_APP_INSTALLATION_ID); if the App was never created the
  guard aborts the provision loudly instead of shipping a dead runner. The guard does NOT verify
  that the Key Vault secret itself exists (that's the documented two-phase bootstrap) — it only
  confirms the configuration is coherent.

  Escape hatch: set SKIP_RUNNER_AUTH_CHECK=true to bypass (e.g. intentionally provisioning a
  placeholder before the App exists).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if ($env:SKIP_RUNNER_AUTH_CHECK -eq 'true') {
    Write-Host "[runner-auth] SKIP_RUNNER_AUTH_CHECK=true — skipping runner auth guard." -ForegroundColor Yellow
    exit 0
}

# azd always provisions from infra/main.parameters.json (the workflows stage the per-env file into
# it before `azd provision`). Read that staged file so the guard reflects what will actually deploy.
$paramFile = Join-Path $PSScriptRoot '../infra/main.parameters.json'
if (-not (Test-Path -LiteralPath $paramFile)) {
    Write-Host "[runner-auth] $paramFile not found — skipping guard."
    exit 0
}
$envLabel = if ($env:AZURE_ENV_NAME) { $env:AZURE_ENV_NAME } else { 'main.parameters.json' }

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

$deployRunner = Resolve-ParamValue $params 'deployGhRunner'
if ($deployRunner -ne $true -and "$deployRunner" -ne 'true') {
    Write-Host "[runner-auth] deployGhRunner is not true ($envLabel) — runner not deployed; skipping guard."
    exit 0
}

$authMode = Resolve-ParamValue $params 'ghRunnerAuthMode'
if (-not $authMode) { $authMode = 'app' }   # matches the template default
$secretFromKv = Resolve-ParamValue $params 'ghRunnerSecretFromKeyVault'
$kvOn = ($secretFromKv -eq $true -or "$secretFromKv" -eq 'true')

Write-Host "[runner-auth] env=$envLabel  mode=$authMode  secretFromKeyVault=$kvOn"

if ($authMode -eq 'app') {
    $appId = Resolve-ParamValue $params 'ghAppId'
    $instId = Resolve-ParamValue $params 'ghAppInstallationId'
    $inlineKey = Resolve-ParamValue $params 'ghAppPrivateKey'

    $missing = @()
    if ([string]::IsNullOrWhiteSpace($appId)) { $missing += 'ghAppId (GH_APP_ID)' }
    if ([string]::IsNullOrWhiteSpace($instId)) { $missing += 'ghAppInstallationId (GH_APP_INSTALLATION_ID)' }
    $keyOk = $kvOn -or -not [string]::IsNullOrWhiteSpace($inlineKey)

    if ($missing.Count -gt 0 -or -not $keyOk) {
        Write-Host ""
        Write-Host "RUNNER AUTH CHECK FAILED ($envLabel, mode 'app')." -ForegroundColor Red
        if ($missing.Count -gt 0) {
            Write-Host ("  Missing App identifiers: {0}" -f ($missing -join ', ')) -ForegroundColor Red
        }
        if (-not $keyOk) {
            Write-Host "  No private-key source: ghRunnerSecretFromKeyVault is false AND inline ghAppPrivateKey (GH_APP_PRIVATE_KEY) is empty." -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "Provisioning now would leave the runner as a Phase-1 placeholder (no autoscaling)." -ForegroundColor Yellow
        Write-Host "Fix ONE of:" -ForegroundColor Yellow
        Write-Host "  1. Create/connect the GitHub App once:  ./scripts/setup-gh-app.ps1 -SetRepoVars"
        Write-Host "     (sets repo Variables GH_APP_ID + GH_APP_INSTALLATION_ID and Secret GH_APP_PRIVATE_KEY;"
        Write-Host "      for pilots it also prints the runner Key Vault seeding commands)."
        Write-Host "  2. Or use PAT for this env: set ghRunnerAuthMode=pat in the param file + provide GH_RUNNER_PAT."
        Write-Host "  3. Or intentionally bootstrapping a placeholder first? Re-run with SKIP_RUNNER_AUTH_CHECK=true."
        exit 1
    }

    Write-Host "[runner-auth] App credentials resolved (App ID + Installation ID present, key source configured). OK." -ForegroundColor Green
    exit 0
}

# pat mode (opt-in fallback)
$pat = Resolve-ParamValue $params 'ghRunnerPat'
$patOk = $kvOn -or -not [string]::IsNullOrWhiteSpace($pat)
if (-not $patOk) {
    Write-Host ""
    Write-Host "[runner-auth] WARNING: mode 'pat' but neither GH_RUNNER_PAT nor ghRunnerSecretFromKeyVault is set." -ForegroundColor Yellow
    Write-Host "             The runner will provision as a Phase-1 placeholder (no autoscaling) until a PAT is supplied." -ForegroundColor Yellow
    exit 0
}

Write-Host "[runner-auth] PAT credential source configured. OK." -ForegroundColor Green
exit 0
