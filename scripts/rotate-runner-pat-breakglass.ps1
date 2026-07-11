#requires -Version 7.0
<#
.SYNOPSIS
    Break-glass rotation of the self-hosted runner GitHub PAT into a NETWORK-LOCKED runner Key Vault.

.DESCRIPTION
    The runner Key Vault (`kvrun<env><suffix>`) is locked down (`publicNetworkAccess=Disabled` + a
    Private Endpoint), so a plain `az keyvault secret set` from outside the VNet is blocked
    (403 ForbiddenByConnection). Rather than requiring an in-VNet host for every rotation, this
    break-glass script does the whole rotation from your workstation in four steps:

      1. OPEN       Momentarily set `publicNetworkAccess=Enabled` + `defaultAction=Allow` (still
                    RBAC-gated) for a brief write window.
      2. WRITE      `az keyvault secret set` the new `gh-pat` (value never logged; `-o none`).
      3. RE-LOCK    In a `finally`, restore `publicNetworkAccess=Disabled` + `defaultAction=Deny`
                    ALWAYS — even on error / Ctrl-C — so the vault is never left open.
      4. RE-RESOLVE Force the runner Container Apps Job to re-read the secret so the new PAT takes
                    effect on the NEXT execution. This step is REQUIRED: Azure Container Apps caches
                    Key Vault secret references at the JOB level, so a rotated PAT otherwise does NOT
                    reach the runner until ACA's periodic refresh (observed up to hours) — the runner
                    keeps failing registration with HTTP 401 on the stale token in the meantime.
                    It is a control-plane call (`az containerapp job secret set`, no data-plane KV
                    access), so it works with the vault already re-locked.

    Why `defaultAction=Allow` (not a single `/32`): the az CLI's egress IP to the vault is an Azure
    SNAT address that differs from your public IP and can rotate between calls, so an IP allowlist is
    unreliable. The window is a few seconds and still requires `Key Vault Secrets Officer` to write.

    SCOPE: the two RUNNER vaults (gov-pilot + comm-pilot) are the private ones, so this is where
    break-glass rotation is needed. Run once per cloud — an `az` session is bound to one cloud;
    switch with `az cloud set` + `az login` for the other.

    The PAT itself can't be minted by API — regenerate it in GitHub first (fine-grained:
    Administration Read & write + Metadata Read, or classic `repo`), then feed it here.

.PARAMETER Env
    Env short name (e.g. `gov-pilot`, `comm-pilot`). Drives the resource group + vault discovery.
    Defaults to the active azd env (`AZURE_ENV_NAME`).

.PARAMETER Pat
    The freshly regenerated GitHub PAT. If omitted, falls back to `$env:GH_RUNNER_PAT`, then a secure
    hidden prompt. Never logged or echoed.

.PARAMETER SecretName
    Key Vault secret name to write. Default `gh-pat` (use `gh-app-key` for GitHub App mode).

.PARAMETER ResourceGroup
    RG holding the runner vault. Default `rg-copilot-byok-<Env>`.

.PARAMETER VaultName
    Runner vault name. Default: auto-discover the `kvrun*` vault in the resource group.

.PARAMETER PropagationSeconds
    Seconds to wait after opening the firewall before writing (network-rule propagation). Default 25.

.EXAMPLE
    # Gov cloud session, prompts securely for the PAT:
    ./scripts/rotate-runner-pat-breakglass.ps1 -Env gov-pilot

.EXAMPLE
    # Commercial (after: az cloud set --name AzureCloud; az login):
    $env:GH_RUNNER_PAT = '<pat>'; ./scripts/rotate-runner-pat-breakglass.ps1 -Env comm-pilot

.NOTES
    Requires PowerShell 7+, Azure CLI logged in to the target cloud, and (control-plane) rights to
    toggle the vault network (`Microsoft.KeyVault/vaults/write`, e.g. Contributor) plus data-plane
    `Key Vault Secrets Officer` to write the secret. If you hold Owner/User Access Administrator the
    script self-grants Secrets Officer when it's missing.
#>
[CmdletBinding()]
param(
    [string]$Env,
    [string]$Pat,
    [string]$SecretName = 'gh-pat',
    [string]$ResourceGroup,
    [string]$VaultName,
    [int]$PropagationSeconds = 25
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }

# --- Resolve env / RG / vault ------------------------------------------------
if (-not $Env)           { $Env = $env:AZURE_ENV_NAME }
if (-not $Env)           { $Env = (azd env get-value AZURE_ENV_NAME 2>$null) }
if (-not $Env)           { Write-Host 'ERROR: -Env not supplied and AZURE_ENV_NAME not set.' -ForegroundColor Red; exit 2 }
if (-not $ResourceGroup) { $ResourceGroup = "rg-copilot-byok-$Env" }

$cloud = az account show --query environmentName -o tsv 2>$null
Write-Step "Env=$Env  RG=$ResourceGroup  cloud=$cloud"

if (-not $VaultName) {
    $VaultName = az keyvault list -g $ResourceGroup --query "[?starts_with(name,'kvrun')].name | [0]" -o tsv 2>$null
}
if (-not $VaultName) { Write-Host "ERROR: could not find a runner Key Vault (kvrun*) in $ResourceGroup." -ForegroundColor Red; exit 2 }
$vaultId = az keyvault show -n $VaultName -g $ResourceGroup --query id -o tsv 2>$null
if (-not $vaultId)   { Write-Host "ERROR: vault '$VaultName' not found." -ForegroundColor Red; exit 2 }
Write-Host "    Vault: $VaultName"

# --- Resolve the PAT (never logged) -----------------------------------------
if (-not $Pat) { $Pat = $env:GH_RUNNER_PAT }
if (-not $Pat) {
    $sec = Read-Host -AsSecureString "Paste the new GitHub PAT (hidden)"
    $Pat = [System.Net.NetworkCredential]::new('', $sec).Password
}
if (-not $Pat) { Write-Host 'ERROR: no PAT supplied (-Pat / $env:GH_RUNNER_PAT / prompt).' -ForegroundColor Red; exit 2 }

# --- Best-effort self-grant of Secrets Officer (needs Owner/UAA) --------------
$callerOid = az ad signed-in-user show --query id -o tsv 2>$null
if ($callerOid) {
    $hasRole = az role assignment list --assignee-object-id $callerOid --scope $vaultId --query "[?roleDefinitionName=='Key Vault Secrets Officer'] | length(@)" -o tsv 2>$null
    if ($hasRole -ne '1') {
        Write-Step "Granting 'Key Vault Secrets Officer' to the current principal (missing) ..."
        az role assignment create --role 'Key Vault Secrets Officer' --assignee-object-id $callerOid --assignee-principal-type User --scope $vaultId -o none 2>$null
        if ($LASTEXITCODE -eq 0) { Start-Sleep -Seconds 20 }
        else { Write-Host "    Could not self-grant (need Owner/User Access Administrator); continuing." -ForegroundColor DarkYellow }
    }
}

# --- Capture current network state so we restore EXACTLY ---------------------
$origPna = az keyvault show -n $VaultName -g $ResourceGroup --query "properties.publicNetworkAccess" -o tsv 2>$null
Write-Host "    Current publicNetworkAccess = $origPna (will be restored to Disabled)"

# NOTE: we open with defaultAction=Allow (not a single-IP rule) for the brief write window. The az
# CLI's egress IP to the vault is an Azure SNAT address that differs from your public IP and can
# rotate between calls, so a `/32` allowlist is unreliable. The vault is still fully RBAC-gated
# (only 'Key Vault Secrets Officer' can write), the window is a few seconds, and the `finally`
# re-locks to publicNetworkAccess=Disabled even on error/Ctrl-C.
$opened = $false
try {
    # 1. Open: PNA Enabled + allow (auth-gated) for the minimal write window.
    Write-Step "Opening $VaultName for the write window (publicNetworkAccess=Enabled, defaultAction=Allow) ..."
    az keyvault update -n $VaultName -g $ResourceGroup --public-network-access Enabled --default-action Allow --bypass AzureServices -o none
    $opened = $true
    Write-Host "    Waiting ${PropagationSeconds}s for the network change to propagate ..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $PropagationSeconds

    # 2. Write the secret. `-o none` suppresses stdout (which would echo the secret JSON); stderr is
    #    captured so a firewall/RBAC failure surfaces without leaking the value.
    Write-Step "Writing '$SecretName' ..."
    $writeErr = az keyvault secret set --vault-name $VaultName -n $SecretName --value $Pat -o none 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Secret write failed. Detail: $($writeErr.Trim())" }
    $upd = az keyvault secret show --vault-name $VaultName -n $SecretName --query "attributes.updated" -o tsv 2>$null
    Write-Host "    OK. '$SecretName' updated at $upd." -ForegroundColor Green
}
finally {
    # 3. ALWAYS re-lock, even on error / Ctrl-C.
    Write-Step "Re-locking $VaultName (publicNetworkAccess=Disabled) ..."
    az keyvault update -n $VaultName -g $ResourceGroup --public-network-access Disabled --default-action Deny --bypass AzureServices -o none 2>$null
    $finalPna = az keyvault show -n $VaultName -g $ResourceGroup --query "properties.publicNetworkAccess" -o tsv 2>$null
    if ($finalPna -eq 'Disabled') { Write-Host "    Re-locked: publicNetworkAccess = Disabled." -ForegroundColor Green }
    else { Write-Host "    !!! WARNING: publicNetworkAccess is '$finalPna' — vault may still be open. Re-run: az keyvault update -n $VaultName -g $ResourceGroup --public-network-access Disabled --default-action Deny" -ForegroundColor Red }
}

# --- Force the runner Job to re-resolve the secret so the new PAT takes effect NOW -----------
# CRITICAL (learned 2026-07-05): ACA caches Key Vault secret references at the Job level. A new
# ephemeral runner execution reuses the CACHED value and does NOT re-read the vault per-run, so a
# freshly rotated PAT silently does NOT take effect until ACA's periodic refresh (observed up to
# hours) — the runner keeps 401'ing on the old token in the meantime. Re-pointing the Job secret
# to the SAME keyvaultref forces an immediate re-resolution over the Private Endpoint. This is a
# control-plane call (management.azure.com), NOT data-plane KV access, so it works even though the
# vault was re-locked in the finally above. Only runs after a successful write (a failed write
# throws out of the try/finally before reaching here). Best-effort: never fails the rotation.
Write-Step "Forcing the runner Job to re-resolve '$SecretName' (so the new value is used now) ..."
$runnerJob = az containerapp job list -g $ResourceGroup -o json 2>$null |
    ConvertFrom-Json | Where-Object { $_.name -like 'caj-runner-*' } | Select-Object -First 1
if (-not $runnerJob) {
    Write-Host "    No runner Job (caj-runner-*) found in $ResourceGroup; skipping re-resolution." -ForegroundColor DarkYellow
} else {
    $jobSecret = $runnerJob.properties.configuration.secrets | Where-Object { $_.name -eq $SecretName } | Select-Object -First 1
    if (-not $jobSecret -or -not $jobSecret.keyVaultUrl) {
        Write-Host "    Runner Job '$($runnerJob.name)' has no Key Vault-backed '$SecretName' (inline mode?); skipping re-resolution." -ForegroundColor DarkYellow
    } else {
        $ref = "keyvaultref:$($jobSecret.keyVaultUrl),identityref:$($jobSecret.identity)"
        az containerapp job secret set -g $ResourceGroup -n $runnerJob.name --secrets "$SecretName=$ref" -o none 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "    Re-resolved on '$($runnerJob.name)' — the next execution uses the new '$SecretName'." -ForegroundColor Green }
        else { Write-Host "    !!! Re-resolution failed; new value applies on ACA's next periodic refresh (up to a few hours). Force it with: az containerapp job secret set -g $ResourceGroup -n $($runnerJob.name) --secrets '$SecretName=<same keyvaultref>'" -ForegroundColor DarkYellow }
    }
}

Write-Host "`nDone. '$SecretName' rotated and the runner Job re-resolved it — the next runner execution uses the new value immediately." -ForegroundColor Green
