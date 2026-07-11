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
      -Action SetSecret   (default) Writes the runner auth secret. Choose which credential
                                     with -Secret:
                                       Pat    -> Job secret `gh-pat` (PAT auth, opt-in fallback),
                                                 from -Token / $env:GH_RUNNER_PAT / secure prompt.
                                       AppKey -> Job secret `gh-app-key` (GitHub App private key
                                                 PEM, PRIMARY path), from -AppKeyPath / $env:GH_APP_PRIVATE_KEY.
                                     Idempotent -- re-running just overwrites the secret value.
                                     Auto-detects how the Job sources the secret: if it's a Key
                                     Vault reference (production, ghRunnerSecretFromKeyVault=true) the
                                     value is written to the runner Key Vault (`az keyvault secret
                                     set`) and resolved by the runner UAMI on the next execution;
                                     otherwise it's written as an inline Job secret (`az
                                     containerapp job secret set`). No Job re-create either way.
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

.PARAMETER Secret
    Which runner credential SetSecret writes: `Pat` (Job secret `gh-pat`, PAT auth) or
    `AppKey` (Job secret `gh-app-key`, GitHub App private key PEM). Default `Pat`. Match
    this to the deployment's `ghRunnerAuthMode` (`pat` / `app`).

.PARAMETER Token
    The GitHub PAT to store as the ACA Job secret (-Secret Pat). Sourced from the
    GH_RUNNER_PAT env var if -Token is omitted. Never logged or echoed.

.PARAMETER AppKeyPath
    Path to the GitHub App private key PEM file (-Secret AppKey). Falls back to
    $env:GH_APP_PRIVATE_KEY when omitted. Never logged or echoed.

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
    `AZURE_ENV_NAME` env var, then to `comm-pilot`. Ignored when -EnvNames is given.

.PARAMETER EnvNames
    One or more environment short names to act on in a single invocation (e.g.
    `comm-pilot,gov-pilot`). For each env the script derives its resource group
    (`rg-copilot-byok-<env>`) and auto-discovers the `caj-runner-*` Job. In
    -Action SetSecret mode, when no -Token/$env:GH_RUNNER_PAT is supplied the script
    SECURELY PROMPTS for the PAT once per env (input hidden, never stored or echoed),
    so the value never lands in shell history or the console. For each env the script
    auto-discovers the right subscription: if the resource group isn't visible in the
    current `az` context it scans every subscription in the CURRENT cloud and switches
    to the one that holds it (the original subscription is restored when done). Envs in
    a different cloud (e.g. gov-* under AzureUSGovernment) still require a separate `az`
    session — run `az cloud set --name AzureUSGovernment; az login` first for those.

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
    # App mode (primary): write the GitHub App private key PEM into the pilot runner KVs:
    .\scripts\setup-gh-runner.ps1 -Action SetSecret -Secret AppKey -AppKeyPath .\gh-app.private-key.pem -EnvNames comm-pilot

.EXAMPLE
    # Rotate every runner in the CURRENT cloud/subscription, prompting securely
    # (input hidden) once per environment:
    .\scripts\setup-gh-runner.ps1 -Action SetSecret -EnvNames comm-pilot,comm-dev

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

    # Which runner credential to write in SetSecret mode:
    #   Pat    -> Job secret 'gh-pat'      (PAT auth, opt-in fallback)
    #   AppKey -> Job secret 'gh-app-key'  (GitHub App private key PEM, primary path)
    [ValidateSet('Pat', 'AppKey')]
    [string]$Secret = 'Pat',

    [string]$Token,

    # Path to the GitHub App private key PEM file (-Secret AppKey). Falls back to
    # $env:GH_APP_PRIVATE_KEY when omitted. Never logged.
    [string]$AppKeyPath,

    [string]$ResourceGroup,

    [string]$JobName,

    [string]$Repository = 'gwexler_microsoft/copilot-cli-byok-azure',

    [string]$Labels,

    [string]$EnvName,

    [string[]]$EnvNames,

    [string]$WorkflowFile = 'smoke-test.yml'
)

$ErrorActionPreference = 'Stop'

# ---------- defaults from environment ----------
if (-not $EnvName) {
    $EnvName = $env:AZURE_ENV_NAME
    if (-not $EnvName) { $EnvName = 'comm-pilot' }
}

# ---------- helpers ----------
function Read-SecurePat {
    # Prompt for a PAT with hidden input and return it as plaintext. The caller is
    # responsible for clearing the returned string. The SecureString -> plaintext
    # round-trip zeroes the unmanaged BSTR buffer immediately after copying.
    param([string]$EnvLabel)
    $secure = Read-Host -AsSecureString -Prompt "  Enter GitHub PAT for '$EnvLabel' (input hidden)"
    if (-not $secure -or $secure.Length -eq 0) { throw "No PAT entered for '$EnvLabel'." }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-ExpectedCloud {
    # Infer the Azure cloud an env lives in from its short name. gov-* envs are in
    # Azure Government; everything else is commercial (public) Azure.
    param([string]$Env)
    if ($Env -match '^gov(-|$)') { 'AzureUSGovernment' } else { 'AzureCloud' }
}

function Resolve-EnvSubscription {
    # Ensure the runner resource group is visible in the active `az` context. If the
    # RG isn't found in the current subscription, scan every subscription in the
    # CURRENT cloud and switch to the one that contains it. Returns the subscription
    # id now in context. Throws if no subscription in this cloud holds the RG (e.g.
    # the env lives in a different cloud such as Azure Government).
    param([string]$Rg)

    # Fast path: already visible in the current subscription.
    if ((az group exists -g $Rg 2>$null) -eq 'true') {
        return (az account show --query id -o tsv 2>$null)
    }

    Write-Host "==> '$Rg' not visible in the current subscription; scanning subscriptions in this cloud ..." -ForegroundColor Cyan
    $subs = @(az account list --query "[].{id:id,name:name}" -o json 2>$null | ConvertFrom-Json)
    if (-not $subs) {
        throw "No subscriptions are available in the current 'az' context. Run 'az login' first."
    }
    foreach ($s in $subs) {
        if ((az group exists -g $Rg --subscription $s.id 2>$null) -eq 'true') {
            Write-Host "    Found in subscription '$($s.name)' ($($s.id)); switching context." -ForegroundColor Green
            az account set --subscription $s.id 2>$null | Out-Null
            return $s.id
        }
    }
    throw "Resource group '$Rg' was not found in any subscription of the current cloud. If it lives in a different cloud (e.g. Azure Government), run 'az cloud set --name AzureUSGovernment; az login' first, then re-run for that env."
}

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
        [string]$SecretName,
        [string]$Value
    )
    # The runner Job's auth secret ('gh-app-key' in app mode, 'gh-pat' in pat mode) is
    # sourced one of two ways (see infra/modules/gh-runner.bicep):
    #   - Key Vault reference (keyVaultUrl): rotation = `az keyvault secret set`, picked up on the
    #     next runner execution. This is the production path (ghRunnerSecretFromKeyVault=true) and is
    #     identical in both clouds.
    #   - inline Job secret (value): rotation = `az containerapp job secret set`.
    # Detect which one this Job uses and route the write accordingly.
    $kvUrl = az containerapp job show -g $Rg -n $Job --query "properties.configuration.secrets[?name=='$SecretName'].keyVaultUrl | [0]" -o tsv 2>$null
    if ($kvUrl -and $kvUrl -ne 'None' -and $kvUrl.Trim()) {
        # keyVaultUrl shape: https://<vault>.<dns>/secrets/<SecretName>[/<version>]
        $uri = [Uri]$kvUrl
        $vaultName  = $uri.Host.Split('.')[0]
        $segments   = $uri.AbsolutePath.Trim('/').Split('/')
        $resolvedName = if ($segments.Length -ge 2) { $segments[1] } else { $SecretName }
        Write-Host "==> Rotating '$resolvedName' in Key Vault '$vaultName' ..." -ForegroundColor Cyan
        # Ensure the caller can WRITE. runner-kv.bicep grants the deploying principal 'Key Vault
        # Secrets Officer' ONLY when deployerPrincipalId is set; for an interactive deployer with
        # deployerPrincipalId='' it isn't, so self-heal here (this is the "helper self-grants"
        # behavior runner-kv.bicep's header documents). Best-effort + idempotent: only fires when
        # the role is missing, needs Owner/User Access Administrator; if the caller lacks that (or
        # is a service principal, e.g. CI, which is granted the role out-of-band) it silently falls
        # through to the write, which still surfaces the explicit grant guidance on failure.
        $vaultId   = az keyvault show -n $vaultName --query id -o tsv 2>$null
        $callerOid = az ad signed-in-user show --query id -o tsv 2>$null
        if ($vaultId -and $callerOid) {
            $hasRole = az role assignment list --assignee-object-id $callerOid --scope $vaultId --query "[?roleDefinitionName=='Key Vault Secrets Officer'] | length(@)" -o tsv 2>$null
            if ($hasRole -ne '1') {
                Write-Host "    Granting 'Key Vault Secrets Officer' to the current principal (missing) ..." -ForegroundColor DarkGray
                az role assignment create --role 'Key Vault Secrets Officer' --assignee-object-id $callerOid --assignee-principal-type User --scope $vaultId -o none 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "    Granted. Waiting ~30s for RBAC propagation ..." -ForegroundColor DarkGray
                    Start-Sleep -Seconds 30
                }
                else {
                    Write-Host "    Could not self-grant (need Owner / User Access Administrator). Attempting the write anyway ..." -ForegroundColor DarkYellow
                }
            }
        }
        $null = az keyvault secret set --vault-name $vaultName --name $resolvedName --value $Value -o none
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to set secret '$resolvedName' in Key Vault '$vaultName'. Ensure you hold 'Key Vault Secrets Officer' on the vault (the deploying principal is granted it by runner-kv.bicep; otherwise grant it: az role assignment create --role 'Key Vault Secrets Officer' --assignee <you> --scope <vaultId>)."
        }
        Write-Host "    OK. Stored in Key Vault." -ForegroundColor Green
        Write-Host "    The runner Job resolves this via its UAMI on the NEXT execution -- KEDA picks it up within one poll interval. No Job re-create or re-provision needed." -ForegroundColor Green
    }
    else {
        Write-Host "==> Updating inline Job secret '$SecretName' on $Job ..." -ForegroundColor Cyan
        # `az containerapp job secret set` requires the existing secret list passed inline
        # (it's a PUT, not a PATCH), so re-asserting the full set is necessary. We only
        # manage one secret here, so just pass it.
        $null = az containerapp job secret set `
            -g $Rg `
            -n $Job `
            --secrets "$SecretName=$Value" `
            -o none
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to set '$SecretName' secret on Job $Job."
        }
        Write-Host "    OK." -ForegroundColor Green

        # Verify by reading back the secret's `name` only (NEVER the value).
        $names = az containerapp job secret list -g $Rg -n $Job --query "[].name" -o tsv 2>$null
        if ($names -notmatch "^$SecretName$") {
            Write-Warning "Secret list did not include '$SecretName' after set: '$names'"
        } else {
            Write-Host "    Verified '$SecretName' present on Job." -ForegroundColor Green
        }
        Write-Host "    TIP: for KV-backed rotation (single 'az keyvault secret set', no re-provision), set ghRunnerSecretFromKeyVault=true and re-provision once." -ForegroundColor DarkGray
    }

    # Inform about trigger state -- the script doesn't flip the trigger itself
    # (that's Bicep's job via ghRunnerAuthMode / ghRunnerSecretFromKeyVault). Just report what's there.
    $trigger = az containerapp job show -g $Rg -n $Job --query 'properties.configuration.triggerType' -o tsv
    Write-Host "    Job triggerType = $trigger" -ForegroundColor Yellow
    if ($trigger -ne 'Event') {
        Write-Host @"

NOTE: triggerType is '$trigger', not 'Event'. The KEDA scaler is NOT yet active.
      Setting the secret alone does NOT flip the trigger -- the Bicep template
      drives that via the 'ghRunnerAuthMode' / 'ghRunnerSecretFromKeyVault' params. Run:

        azd provision --parameters ghRunnerSecretFromKeyVault=true

      (after writing the secret to the runner Key Vault) so Bicep sees the KV reference
      and writes triggerType=Event + the KEDA rule. This script kept the secret value
      in sync so subsequent rotations are a one-call no-op.
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

# ---------- run ----------
# A PAT supplied via -Token or $env:GH_RUNNER_PAT is reused for ALL targets. When
# absent (SetSecret + -Secret Pat) the loop prompts securely PER environment below.
$suppliedToken = if ($Token) { $Token } elseif ($env:GH_RUNNER_PAT) { $env:GH_RUNNER_PAT } else { $null }

# In app mode (-Secret AppKey) the GitHub App private key PEM is read once from -AppKeyPath
# or $env:GH_APP_PRIVATE_KEY and reused for ALL targets (there is no interactive prompt for a
# multi-line PEM). Acquired up front so a bad path fails fast before touching any env.
$suppliedAppKey = if ($Action -eq 'SetSecret' -and $Secret -eq 'AppKey') {
    if ($AppKeyPath) {
        if (-not (Test-Path -LiteralPath $AppKeyPath)) { throw "-AppKeyPath '$AppKeyPath' not found." }
        Get-Content -Raw -LiteralPath $AppKeyPath
    } elseif ($env:GH_APP_PRIVATE_KEY) { $env:GH_APP_PRIVATE_KEY }
    else { throw "App mode (-Secret AppKey) needs the GitHub App private key PEM via -AppKeyPath <file.pem> or `$env:GH_APP_PRIVATE_KEY." }
} else { $null }

# Single-env (-EnvName / defaults) or multi-env (-EnvNames). The -ResourceGroup and
# -JobName overrides only apply to a single explicit target; across multiple envs each
# is derived/auto-discovered.
$targets = if ($EnvNames -and $EnvNames.Count -gt 0) { $EnvNames } else { @($EnvName) }
$single  = $targets.Count -eq 1

# Capture the starting subscription so per-env context switches can be undone at the
# end (the loop may hop subscriptions to find each env's runner RG).
$originalSub = az account show --query id -o tsv 2>$null

$failures = @()
foreach ($targetEnv in $targets) {
    Write-Host ""
    Write-Host "==================== $targetEnv ====================" -ForegroundColor Magenta
    try {
        $Labels = if ($single -and $Labels) { $Labels } else { $targetEnv }
        $Rg     = if ($single -and $ResourceGroup) { $ResourceGroup } else { "rg-copilot-byok-$targetEnv" }

        # Guard: a single `az` session is bound to one cloud. If this env belongs to a
        # different cloud than the active context, skip it with guidance rather than
        # emitting a confusing 'RG not found' from the subscription scan.
        $expectedCloud = Get-ExpectedCloud -Env $targetEnv
        $currentCloud  = az cloud show --query name -o tsv 2>$null
        if ($currentCloud -and $expectedCloud -ne $currentCloud) {
            throw "Env '$targetEnv' lives in cloud '$expectedCloud' but the current 'az' context is '$currentCloud'. Run it in a separate session: 'az cloud set --name $expectedCloud; az login' then re-run for this env."
        }

        # Make sure we're pointed at the subscription that actually holds this env's
        # runner RG (auto-switches within the current cloud if needed).
        $sub = Resolve-EnvSubscription -Rg $Rg
        Write-Host "    Subscription: $sub" -ForegroundColor DarkGray

        $Job = if ($single -and $JobName) { $JobName } else { $null }
        if (-not $Job) {
            Write-Host "==> Discovering Job name in $Rg ..." -ForegroundColor Cyan
            $Job = Get-RunnerJobName -Rg $Rg
            Write-Host "    Found: $Job" -ForegroundColor Green
        }

        switch ($Action) {
            'SetSecret' {
                if ($Secret -eq 'AppKey') {
                    # PEM already acquired up front ($suppliedAppKey); write it to 'gh-app-key'.
                    Set-RunnerSecret -Rg $Rg -Job $Job -SecretName 'gh-app-key' -Value $suppliedAppKey
                }
                else {
                    $pat = if ($suppliedToken) { $suppliedToken } else { Read-SecurePat -EnvLabel $targetEnv }
                    try {
                        Set-RunnerSecret -Rg $Rg -Job $Job -SecretName 'gh-pat' -Value $pat
                    } finally {
                        # Only the per-env prompted value is ours to clear; never wipe a
                        # caller-supplied token mid-loop (other targets still need it).
                        if (-not $suppliedToken) { $pat = $null; Remove-Variable pat -ErrorAction SilentlyContinue }
                    }
                }
            }
            'Status' {
                Assert-GhAuth -Repo $Repository
                Get-RegisteredRunners -Repo $Repository -LabelFilter $Labels
            }
            'Test' {
                Assert-GhAuth -Repo $Repository
                Invoke-RunnerTest -Repo $Repository -Workflow $WorkflowFile -Rg $Rg -Job $Job
            }
        }
    } catch {
        Write-Warning "[$targetEnv] $($_.Exception.Message)"
        $failures += $targetEnv
    }
}

# Restore the caller's original subscription if the loop switched away from it.
if ($originalSub) {
    $nowSub = az account show --query id -o tsv 2>$null
    if ($nowSub -and $nowSub -ne $originalSub) {
        az account set --subscription $originalSub 2>$null | Out-Null
    }
}

if ($failures.Count -gt 0) {
    throw "Completed with failures for: $($failures -join ', '). See warnings above."
}
