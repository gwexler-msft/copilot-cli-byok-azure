<#
.SYNOPSIS
    Idempotent bootstrap helper for the BYOK self-hosted GitHub Actions runner pool
    (issue #58 — phase 3 of #52).

.DESCRIPTION
    The runner stack (issue #57) is provisioned by Bicep. When `ghRunnerPat` is set
    on the deployment, the ACA Job flips from a Phase 1 manual placeholder to a
    KEDA-scaled, event-driven, ephemeral self-hosted runner pool. This script is the
    "Phase 3 bootstrap": it takes a GitHub PAT, writes it into the Job secret
    (`gh-pat`), and verifies the runner pool reacts to a queued workflow.

    Three modes (mutually exclusive):
      -Action SetSecret   (default) Updates the Job secret `gh-pat` with the supplied
                                     -Token. Idempotent — re-running just overwrites
                                     the secret value. No Job re-create needed because
                                     `ACCESS_TOKEN` is `secretRef: gh-pat`.
      -Action Status      Lists registered runners on the repo whose labels intersect
                                     with -Labels. Useful after a workflow run to
                                     confirm the runner registered + deregistered.
      -Action Test        Triggers a `workflow_dispatch` against -WorkflowFile so the
                                     KEDA scaler spins up a runner. Watches the Job
                                     execution list for a new execution and reports
                                     its status.

    All actions are safe to run repeatedly. The script never creates duplicate
    runners — registration is handled inside the container by myoung34/github-runner
    in EPHEMERAL mode (registers, runs one job, deregisters, exits).

.PARAMETER Action
    SetSecret (default), Status, or Test. See description.

.PARAMETER Token
    The GitHub PAT to store as the ACA Job secret. Required for -Action SetSecret.
    Sourced from the GH_RUNNER_PAT env var if -Token is omitted. Never logged or
    echoed.

.PARAMETER ResourceGroup
    Azure resource group containing the runner Job. Defaults to the current azd
    env's resource group (read from `azd env get-values`); falls back to
    rg-copilot-byok-<EnvName>.

.PARAMETER JobName
    The ACA Job name. Defaults to the value of the `ghRunnerJobName` deployment
    output; falls back to `caj-runner-<EnvName>-<suffix>` derived heuristically.

.PARAMETER Repository
    GitHub repo in `<owner>/<repo>` form. Defaults to
    `gwexler_microsoft/copilot-cli-byok-azure`.

.PARAMETER Labels
    Comma-separated runner labels to filter on for -Action Status. Defaults to
    the env name (matches the Bicep default `ghRunnerLabels = envName`).

.PARAMETER EnvName
    The azd env / environment short name (e.g. `comm-pilot`). Defaults to the
    `AZURE_ENV_NAME` env var, then to `comm-pilot`.

.PARAMETER WorkflowFile
    Workflow filename (under `.github/workflows/`) to dispatch for -Action Test.
    Default `smoke-test.yml` (planned, lands in #56).

.EXAMPLE
    # Initial bootstrap — write a freshly-minted PAT into the Job secret:
    $env:GH_RUNNER_PAT = "ghp_..."
    .\scripts\setup-gh-runner.ps1 -Action SetSecret

.EXAMPLE
    # Rotate the PAT (no Job re-create needed):
    .\scripts\setup-gh-runner.ps1 -Action SetSecret -Token "ghp_newpat"

.EXAMPLE
    # Check which runners are registered for this env:
    .\scripts\setup-gh-runner.ps1 -Action Status -EnvName comm-pilot

.EXAMPLE
    # Trigger a smoke-test run to validate the pool scales up:
    .\scripts\setup-gh-runner.ps1 -Action Test -EnvName comm-pilot

.NOTES
    Requires PowerShell 7+, Azure CLI (`az`) logged in to the target subscription,
    and `gh` CLI authenticated for the target repo.
#>
#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('SetSecret', 'Status', 'Test')]
    [string]$Action = 'SetSecret',

    [string]$Token,

    [string]$ResourceGroup,

    [string]$JobName,

    [string]$Repository = 'gwexler_microsoft/copilot-cli-byok-azure',

    [string]$Labels,

    [string]$EnvName,

    [string]$WorkflowFile = 'smoke-test.yml'
)

$ErrorActionPreference = 'Stop'

# ---------- defaults from environment ----------
if (-not $EnvName) {
    $EnvName = $env:AZURE_ENV_NAME
    if (-not $EnvName) { $EnvName = 'comm-pilot' }
}
if (-not $Labels) { $Labels = $EnvName }
if (-not $ResourceGroup) { $ResourceGroup = "rg-copilot-byok-$EnvName" }

# ---------- helpers ----------
function Get-RunnerJobName {
    param([string]$Rg)
    # Try to read the most recent successful subscription deployment's output first
    # so the script auto-discovers the suffix-suffixed name. Fall back to a list scan.
    $jobs = az containerapp job list -g $Rg --query "[?starts_with(name, 'caj-runner-')].name" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $jobs) {
        $list = @($jobs -split "`n" | Where-Object { $_ })
        if ($list.Count -eq 1) { return $list[0] }
        if ($list.Count -gt 1) {
            Write-Warning "Multiple runner Jobs found in $Rg; pass -JobName explicitly: $($list -join ', ')"
            return $list[0]
        }
    }
    throw "No ACA Job matching 'caj-runner-*' found in resource group '$Rg'. Pass -JobName explicitly or verify deployGhRunner=true was provisioned."
}

function Assert-GhAuth {
    param([string]$Repo)
    $whoami = gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "gh CLI not authenticated. Run 'gh auth login' first."
    }
    # Lightweight repo-access probe.
    $probe = gh api "repos/$Repo" -q '.full_name' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot read repo '$Repo' via gh CLI. Output: $probe"
    }
}

function Set-RunnerSecret {
    param(
        [string]$Rg,
        [string]$Job,
        [string]$Pat
    )
    Write-Host "==> Updating Job secret 'gh-pat' on $Job ..." -ForegroundColor Cyan
    # `az containerapp job secret set` requires the existing secret list passed inline
    # (it's a PUT, not a PATCH), so re-asserting the full set is necessary. We only
    # manage one secret here, so just pass it.
    $null = az containerapp job secret set `
        -g $Rg `
        -n $Job `
        --secrets "gh-pat=$Pat" `
        -o none
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set 'gh-pat' secret on Job $Job."
    }
    Write-Host "    OK." -ForegroundColor Green

    # Verify by reading back the secret's `name` only (NEVER the value).
    $names = az containerapp job secret list -g $Rg -n $Job --query "[].name" -o tsv 2>$null
    if ($names -notmatch '^gh-pat$') {
        Write-Warning "Secret list did not include 'gh-pat' after set: '$names'"
    } else {
        Write-Host "    Verified 'gh-pat' present on Job." -ForegroundColor Green
    }

    # Inform about trigger state — the script doesn't flip the trigger itself
    # (that's Bicep's job via ghRunnerPat param). Just report what's there.
    $trigger = az containerapp job show -g $Rg -n $Job --query 'properties.configuration.triggerType' -o tsv
    Write-Host "    Job triggerType = $trigger" -ForegroundColor Yellow
    if ($trigger -ne 'Event') {
        Write-Host @"

NOTE: triggerType is '$trigger', not 'Event'. The KEDA scaler is NOT yet active.
      Setting the Job secret alone does NOT flip the trigger -- the Bicep template
      drives that via the 'ghRunnerPat' deployment parameter. Run:

        azd provision --parameters ghRunnerPat=<same-pat>

      (or supply the same PAT to your CI/CD deploy invocation) so Bicep sees a
      non-empty value and writes triggerType=Event + the KEDA rule. This script
      kept the secret value in sync so subsequent rotations are a one-call no-op.
"@ -ForegroundColor Yellow
    } else {
        Write-Host "    KEDA event trigger active. Runner pool will scale on queued jobs matching labels '$Labels'." -ForegroundColor Green
    }
}

function Get-RegisteredRunners {
    param(
        [string]$Repo,
        [string]$LabelFilter
    )
    Write-Host "==> Listing runners registered on $Repo ..." -ForegroundColor Cyan
    $payload = gh api "repos/$Repo/actions/runners" 2>$null | ConvertFrom-Json
    if (-not $payload) {
        Write-Warning "No runner data returned (PAT may lack 'Administration: read' permission)."
        return
    }
    $matchedLabels = $LabelFilter -split ',' | ForEach-Object { $_.Trim() }
    $rows = foreach ($r in $payload.runners) {
        $runnerLabels = ($r.labels | ForEach-Object { $_.name }) -join ','
        $matches = ($matchedLabels | Where-Object { $runnerLabels -split ',' -contains $_ }).Count -gt 0
        if ($matches) {
            [PSCustomObject]@{
                Name   = $r.name
                Status = $r.status
                Busy   = $r.busy
                Labels = $runnerLabels
            }
        }
    }
    if ($rows) {
        $rows | Format-Table -AutoSize
    } else {
        Write-Host "    No runners currently registered matching label(s) '$LabelFilter'." -ForegroundColor Yellow
        Write-Host "    (Ephemeral runners deregister immediately after each job, so this is normal between runs.)" -ForegroundColor DarkGray
    }
}

function Invoke-RunnerTest {
    param(
        [string]$Repo,
        [string]$Workflow,
        [string]$Rg,
        [string]$Job
    )
    Write-Host "==> Dispatching workflow '$Workflow' on $Repo ..." -ForegroundColor Cyan
    $dispatch = gh workflow run $Workflow --repo $Repo 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "gh workflow run failed: $dispatch"
    }
    Write-Host "    Dispatched. Watching for new Job executions on $Job ..." -ForegroundColor Cyan
    # Capture baseline + poll for a new execution (KEDA polls every 30s by default,
    # so the first new execution typically appears within ~30-60s).
    $baselineIds = @(az containerapp job execution list -g $Rg -n $Job --query "[].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ }
    $deadline = (Get-Date).AddMinutes(3)
    $newExec = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        $current = @(az containerapp job execution list -g $Rg -n $Job --query "[].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ }
        $delta = $current | Where-Object { $_ -notin $baselineIds }
        if ($delta) {
            $newExec = $delta[0]
            break
        }
        Write-Host "    ...still waiting (KEDA poll interval is ~30s)" -ForegroundColor DarkGray
    }
    if (-not $newExec) {
        Write-Warning "No new Job execution observed within 3 min. Common causes: workflow file '$Workflow' doesn't exist or doesn't target labels '$Labels'; KEDA scaler not configured (re-deploy with ghRunnerPat set); PAT lacks 'Actions: read' permission."
        return
    }
    Write-Host "    New execution: $newExec" -ForegroundColor Green
    Write-Host "    Tail logs: az containerapp job execution show -g $Rg -n $Job --job-execution-name $newExec" -ForegroundColor DarkGray
}

# ---------- preflight ----------
if (-not $JobName) {
    Write-Host "==> Discovering Job name in $ResourceGroup ..." -ForegroundColor Cyan
    $JobName = Get-RunnerJobName -Rg $ResourceGroup
    Write-Host "    Found: $JobName" -ForegroundColor Green
}

# ---------- dispatch ----------
switch ($Action) {
    'SetSecret' {
        if (-not $Token) { $Token = $env:GH_RUNNER_PAT }
        if (-not $Token) {
            throw "No -Token supplied and `$env:GH_RUNNER_PAT is empty. Set the PAT either way."
        }
        Set-RunnerSecret -Rg $ResourceGroup -Job $JobName -Pat $Token
    }
    'Status' {
        Assert-GhAuth -Repo $Repository
        Get-RegisteredRunners -Repo $Repository -LabelFilter $Labels
    }
    'Test' {
        Assert-GhAuth -Repo $Repository
        Invoke-RunnerTest -Repo $Repository -Workflow $WorkflowFile -Rg $ResourceGroup -Job $JobName
    }
}
