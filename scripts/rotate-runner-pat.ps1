<#
.SYNOPSIS
    One-command weekly rotation for the BYOK self-hosted runner PAT (pat mode).

.DESCRIPTION
    Under an Enterprise Managed Users (EMU) account the GitHub PAT max lifetime is
    capped (commonly 7 days), so the runner credential must be rotated frequently.
    A full rotation touches up to three places from a single fresh PAT:

      1. The GitHub Actions REPO SECRET `GH_RUNNER_PAT` -- the durable source the
         dev envs (comm-dev / gov-dev) inject inline on every (nightly) reprovision.
         setup-gh-runner.ps1 does NOT update this; this wrapper does.
      2. The COMMERCIAL pilot runner Key Vault secret `gh-pat` (comm-pilot).
      3. The GOV pilot runner Key Vault secret `gh-pat` (gov-pilot) -- a separate
         Azure cloud requiring its own `az` session.

    This wrapper updates the repo secret once, then delegates the per-env runner
    secret writes to setup-gh-runner.ps1 (which auto-detects KV vs inline, hops to
    the right subscription, and is a no-op-safe rotation -- no Job re-create, picked
    up on the next runner execution). A single `az` session is bound to one cloud,
    so envs in a different cloud than the active context are SKIPPED with a copy-paste
    follow-up command rather than failing.

    The only step that CANNOT be automated is minting the PAT itself: GitHub has no
    API to create a classic/fine-grained PAT, so you regenerate it in the browser
    first, then feed the value here (via secure prompt, $env:GH_RUNNER_PAT, or -Pat).

.PARAMETER Pat
    The freshly regenerated GitHub PAT. If omitted, falls back to $env:GH_RUNNER_PAT,
    then to a secure hidden prompt. Never logged or echoed.

.PARAMETER Envs
    Runner environment short names whose live secret should be rotated. Default
    `comm-pilot,gov-pilot`. Add `comm-dev` if you also want the currently-running dev
    Job's inline secret refreshed immediately (otherwise the repo secret covers dev on
    its next reprovision). Envs not in the active `az` cloud are skipped with guidance.

.PARAMETER Repository
    GitHub repo in `<owner>/<repo>` form. Default `gwexler_microsoft/copilot-cli-byok-azure`.

.PARAMETER RepoSecretName
    The GitHub Actions repo secret name to update. Default `GH_RUNNER_PAT`.

.PARAMETER SkipRepoSecret
    Skip updating the GitHub Actions repo secret (e.g. on the second, gov-cloud pass
    where the repo secret was already set in the first commercial-cloud pass).

.PARAMETER DryRun
    Print every action without writing anything. Does not require a PAT.

.EXAMPLE
    # Weekly rotation, commercial cloud session. Updates the repo secret + comm-pilot KV,
    # and prints the gov follow-up. Prompts securely for the PAT:
    ./scripts/rotate-runner-pat.ps1

.EXAMPLE
    # Second pass for gov (run after: az cloud set --name AzureUSGovernment; az login).
    # Repo secret already done in pass 1, so skip it:
    ./scripts/rotate-runner-pat.ps1 -Envs gov-pilot -SkipRepoSecret

.EXAMPLE
    # Also refresh the live dev Job inline secret immediately (not just the repo secret):
    ./scripts/rotate-runner-pat.ps1 -Envs comm-pilot,comm-dev

.EXAMPLE
    # See exactly what would happen, no writes, no PAT needed:
    ./scripts/rotate-runner-pat.ps1 -DryRun

.NOTES
    Requires PowerShell 7+, Azure CLI (`az`) logged in to the target cloud, and `gh`
    CLI authenticated for the repo with admin (to set the repo secret).
#>
#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Pat,
    [string[]]$Envs = @('comm-pilot', 'gov-pilot'),
    [string]$Repository = 'gwexler_microsoft/copilot-cli-byok-azure',
    [string]$RepoSecretName = 'GH_RUNNER_PAT',
    [switch]$SkipRepoSecret,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'setup-gh-runner.ps1'
if (-not (Test-Path -LiteralPath $helper)) {
    throw "Required helper not found: $helper"
}

# ---------- helpers ----------
function Get-ExpectedCloud {
    # gov-* envs live in Azure Government; everything else in commercial (public) Azure.
    param([string]$Env)
    if ($Env -match '^gov(-|$)') { 'AzureUSGovernment' } else { 'AzureCloud' }
}

function Read-SecurePat {
    # Hidden prompt -> plaintext. The SecureString -> BSTR round-trip zeroes the
    # unmanaged buffer immediately after copying.
    $secure = Read-Host -AsSecureString -Prompt 'Enter the freshly regenerated GitHub PAT (input hidden)'
    if (-not $secure -or $secure.Length -eq 0) { throw 'No PAT entered.' }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# ---------- gh auth probe ----------
$null = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) { throw "gh CLI not authenticated. Run 'gh auth login' first." }

# ---------- resolve PAT (not needed for a dry run) ----------
$pat = $null
if (-not $DryRun) {
    $pat = if ($Pat) { $Pat } elseif ($env:GH_RUNNER_PAT) { $env:GH_RUNNER_PAT } else { Read-SecurePat }
    if ([string]::IsNullOrWhiteSpace($pat)) { throw 'PAT resolved empty.' }
}

# ---------- current cloud + env split ----------
$currentCloud = az cloud show --query name -o tsv 2>$null
if (-not $currentCloud) { throw "Could not read the active az cloud. Run 'az login' first." }

$thisCloud  = @($Envs | Where-Object { (Get-ExpectedCloud -Env $_) -eq $currentCloud })
$otherCloud = @($Envs | Where-Object { (Get-ExpectedCloud -Env $_) -ne $currentCloud })

Write-Host ""
Write-Host "Rotation plan" -ForegroundColor Cyan
Write-Host "  Repo            : $Repository" -ForegroundColor DarkGray
Write-Host "  Active az cloud : $currentCloud" -ForegroundColor DarkGray
Write-Host "  Repo secret     : $(if ($SkipRepoSecret) { 'skip' } else { "set $RepoSecretName" })" -ForegroundColor DarkGray
Write-Host "  Envs (this cloud): $(if ($thisCloud) { $thisCloud -join ', ' } else { '(none)' })" -ForegroundColor DarkGray
Write-Host "  Envs (other cloud): $(if ($otherCloud) { $otherCloud -join ', ' } else { '(none)' })" -ForegroundColor DarkGray
if ($DryRun) { Write-Host "  MODE            : DRY RUN (no writes)" -ForegroundColor Yellow }

$results = [System.Collections.Generic.List[object]]::new()

# ---------- 1. GitHub Actions repo secret (durable dev source) ----------
if (-not $SkipRepoSecret) {
    Write-Host ""
    Write-Host "==> Updating GitHub Actions repo secret '$RepoSecretName' on $Repository ..." -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "    [dry-run] gh secret set $RepoSecretName --repo $Repository --body <PAT>" -ForegroundColor Yellow
        $results.Add([pscustomobject]@{ Target = "repo-secret:$RepoSecretName"; Result = 'dry-run' })
    }
    else {
        # --body (matches the repo's existing `az keyvault secret set --value` convention):
        # byte-exact value with no stdin trailing-newline risk; the invocation is internal
        # to this script so it never lands in shell history.
        $null = gh secret set $RepoSecretName --repo $Repository --body $pat 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to set repo secret '$RepoSecretName' (need admin on $Repository)."
            $results.Add([pscustomobject]@{ Target = "repo-secret:$RepoSecretName"; Result = 'FAILED' })
        }
        else {
            Write-Host "    OK. Dev envs inject this inline on their next (nightly) reprovision." -ForegroundColor Green
            $results.Add([pscustomobject]@{ Target = "repo-secret:$RepoSecretName"; Result = 'ok' })
        }
    }
}

# ---------- 2. Runner envs in the active cloud (delegate to setup-gh-runner.ps1) ----------
if ($thisCloud.Count -gt 0) {
    Write-Host ""
    Write-Host "==> Rotating runner secret 'gh-pat' for: $($thisCloud -join ', ') ..." -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "    [dry-run] $helper -Action SetSecret -Secret Pat -EnvNames $($thisCloud -join ',') -Repository $Repository (PAT via `$env:GH_RUNNER_PAT)" -ForegroundColor Yellow
        foreach ($e in $thisCloud) { $results.Add([pscustomobject]@{ Target = "runner:$e"; Result = 'dry-run' }) }
    }
    else {
        # Pass the PAT to the child via env var (not -Token) so it never appears on the
        # child process command line. Restore the prior value afterwards.
        $priorEnvPat = $env:GH_RUNNER_PAT
        $env:GH_RUNNER_PAT = $pat
        try {
            & $helper -Action SetSecret -Secret Pat -EnvNames $thisCloud -Repository $Repository
            $delegateExit = $LASTEXITCODE
        }
        finally {
            if ($null -eq $priorEnvPat) { Remove-Item Env:\GH_RUNNER_PAT -ErrorAction SilentlyContinue }
            else { $env:GH_RUNNER_PAT = $priorEnvPat }
        }
        # setup-gh-runner.ps1 exits non-zero if ANY env failed; it prints per-env warnings.
        $res = if ($delegateExit -eq 0) { 'ok' } else { 'see warnings above' }
        foreach ($e in $thisCloud) { $results.Add([pscustomobject]@{ Target = "runner:$e"; Result = $res }) }
    }
}

# ---------- 3. Other-cloud envs: print the follow-up command ----------
if ($otherCloud.Count -gt 0) {
    $otherCloudName = Get-ExpectedCloud -Env $otherCloud[0]
    Write-Host ""
    Write-Host "==> $($otherCloud.Count) env(s) live in '$otherCloudName' (not the active cloud) -- run a second pass there:" -ForegroundColor Yellow
    Write-Host "      az cloud set --name $otherCloudName" -ForegroundColor White
    Write-Host "      az login" -ForegroundColor White
    Write-Host "      ./scripts/rotate-runner-pat.ps1 -Envs $($otherCloud -join ',') -SkipRepoSecret" -ForegroundColor White
    Write-Host "    (Repo secret already handled in this pass; -SkipRepoSecret avoids redoing it.)" -ForegroundColor DarkGray
    foreach ($e in $otherCloud) { $results.Add([pscustomobject]@{ Target = "runner:$e"; Result = "deferred ($otherCloudName)" }) }
}

# ---------- scrub + summary ----------
if ($pat) { $pat = $null; Remove-Variable pat -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "Summary" -ForegroundColor Cyan
$results | Format-Table -AutoSize

$failed = @($results | Where-Object { $_.Result -eq 'FAILED' -or $_.Result -like 'see warnings*' })
if ($failed.Count -gt 0) {
    Write-Warning "$($failed.Count) target(s) need attention -- see warnings above."
    exit 1
}
exit 0
