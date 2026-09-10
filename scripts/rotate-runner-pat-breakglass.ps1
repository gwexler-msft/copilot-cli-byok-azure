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
                    ALWAYS - even on error / Ctrl-C - so the vault is never left open.
      4. RE-RESOLVE Force the runner Container Apps Job to re-read the secret so the new PAT takes
                    effect on the NEXT execution. This step is REQUIRED: Azure Container Apps caches
                    Key Vault secret references at the JOB level, so a rotated PAT otherwise does NOT
                    reach the runner until ACA's periodic refresh (observed up to hours) - the runner
                    keeps failing registration with HTTP 401 on the stale token in the meantime.
                    It is a control-plane call (`az containerapp job secret set`, no data-plane KV
                    access), so it works with the vault already re-locked.

    GOVERNED SUBSCRIPTIONS (e.g. the commercial managed MngEnv tenant): a `modify`-effect Azure
    Policy can silently force `publicNetworkAccess=Disabled` on every write, so the vault never opens
    (the OPEN step "succeeds" but the value stays Disabled) and the data-plane write 403s. The script
    detects this and falls back to writing the secret through a RESOURCE MANAGER deployment
    (`Microsoft.KeyVault/vaults/secrets`): ARM is a trusted service and the vault keeps
    `bypass: AzureServices`, so the write succeeds with the vault still locked -- no in-VNet host and
    no PNA toggle required. gov-pilot uses the fast OPEN/WRITE path; comm-pilot uses the ARM fallback.

    Why `defaultAction=Allow` (not a single `/32`): the az CLI's egress IP to the vault is an Azure
    SNAT address that differs from your public IP and can rotate between calls, so an IP allowlist is
    unreliable. The window is a few seconds and still requires `Key Vault Secrets Officer` to write.

    SCOPE: the two RUNNER vaults (gov-pilot + comm-pilot) are the private ones, so this is where
    break-glass rotation is needed. Run once per cloud - an `az` session is bound to one cloud;
    switch with `az cloud set` + `az login` for the other.

    The PAT itself can't be minted by API - regenerate it in GitHub first (fine-grained:
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

# A wrong-cloud tab reports the same "no kvrun* vault" error as a genuinely missing vault.
if (-not $cloud) {
    Write-Host 'ERROR: not logged in (az account show returned nothing). Set AZURE_CONFIG_DIR, then az login.' -ForegroundColor Red
    exit 2
}
$expectedCloud = switch -Wildcard ($Env) {
    'comm*' { 'AzureCloud' }
    'gov*'  { 'AzureUSGovernment' }
    default { $null }
}
if ($expectedCloud -and $cloud -ne $expectedCloud) {
    $dirHint = if ($expectedCloud -eq 'AzureCloud') { '.azure-comm' } else { '.azure-gov' }
    Write-Host "ERROR: env '$Env' expects cloud '$expectedCloud' but this shell is on '$cloud'." -ForegroundColor Red
    Write-Host "       Run it in the matching tab: `$env:AZURE_CONFIG_DIR = `"`$HOME\$dirHint`"" -ForegroundColor Red
    exit 2
}

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
$written = $false
try {
    # 1. Open: PNA Enabled + allow (auth-gated) for the minimal write window.
    Write-Step "Opening $VaultName for the write window (publicNetworkAccess=Enabled, defaultAction=Allow) ..."
    az keyvault update -n $VaultName -g $ResourceGroup --public-network-access Enabled --default-action Allow --bypass AzureServices -o none 2>$null
    $opened = $true
    Write-Host "    Waiting ${PropagationSeconds}s for the network change to propagate ..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $PropagationSeconds

    # 1a. Verify the vault ACTUALLY opened. On governed subscriptions (e.g. the commercial managed
    #     MngEnv tenant) a `modify`-effect Azure Policy silently rewrites publicNetworkAccess back to
    #     Disabled on every PUT, so the open "succeeds" with no error but the vault never opens and the
    #     data-plane write below would 403 (ForbiddenByConnection). Detect that and skip straight to
    #     the ARM fallback rather than burning the write attempt.
    $pnaNow = az keyvault show -n $VaultName -g $ResourceGroup --query "properties.publicNetworkAccess" -o tsv 2>$null
    if ($pnaNow -ne 'Enabled') {
        Write-Host "    Vault did not open (publicNetworkAccess=$pnaNow) - governance likely forces it Disabled. Falling back to the ARM-deployment write." -ForegroundColor DarkYellow
    } else {
        # 2. Data-plane write. `-o none` suppresses stdout (which would echo the secret JSON); stderr
        #    is captured so a firewall/RBAC failure surfaces without leaking the value.
        Write-Step "Writing '$SecretName' (data-plane) ..."
        $writeErr = az keyvault secret set --vault-name $VaultName -n $SecretName --value $Pat -o none 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            $written = $true
            $upd = az keyvault secret show --vault-name $VaultName -n $SecretName --query "attributes.updated" -o tsv 2>$null
            Write-Host "    OK. '$SecretName' updated at $upd (data-plane)." -ForegroundColor Green
        } else {
            Write-Host "    Data-plane write blocked ($($writeErr.Trim())). Falling back to the ARM-deployment write." -ForegroundColor DarkYellow
        }
    }
}
finally {
    # 3. ALWAYS re-lock, even on error / Ctrl-C. (Safe to run before the ARM fallback below: the ARM
    #    write goes through the trusted-services bypass and does not need the vault open.)
    Write-Step "Re-locking $VaultName (publicNetworkAccess=Disabled) ..."
    az keyvault update -n $VaultName -g $ResourceGroup --public-network-access Disabled --default-action Deny --bypass AzureServices -o none 2>$null
    $finalPna = az keyvault show -n $VaultName -g $ResourceGroup --query "properties.publicNetworkAccess" -o tsv 2>$null
    if ($finalPna -eq 'Disabled') { Write-Host "    Re-locked: publicNetworkAccess = Disabled." -ForegroundColor Green }
    else { Write-Host "    !!! WARNING: publicNetworkAccess is '$finalPna' - vault may still be open. Re-run: az keyvault update -n $VaultName -g $ResourceGroup --public-network-access Disabled --default-action Deny" -ForegroundColor Red }
}

# --- ARM-deployment fallback (trusted-services bypass) -----------------------------------------
# When the vault could not be opened (governance modify-policy) or the data-plane write was blocked,
# write the secret through a RESOURCE MANAGER deployment instead. ARM is a trusted Azure service and
# the vault keeps `bypass: AzureServices`, so a `Microsoft.KeyVault/vaults/secrets` deployment
# succeeds even with publicNetworkAccess=Disabled - this is how the original provision seeded the
# locked vault. The `modify` policy only rewrites the network property; it does not block secret
# writes. This is a control-plane call, so it works from anywhere (no in-VNet host needed).
if (-not $written) {
    Write-Step "Writing '$SecretName' via ARM deployment (trusted-services bypass; vault stays locked) ..."
    $tmpl = @'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "vaultName":   { "type": "string" },
    "secretName":  { "type": "string" },
    "secretValue": { "type": "securestring" }
  },
  "resources": [
    {
      "type": "Microsoft.KeyVault/vaults/secrets",
      "apiVersion": "2023-07-01",
      "name": "[format('{0}/{1}', parameters('vaultName'), parameters('secretName'))]",
      "properties": { "value": "[parameters('secretValue')]" }
    }
  ]
}
'@
    $tmplPath = Join-Path ([System.IO.Path]::GetTempPath()) "breakglass-kvsecret-$([guid]::NewGuid().ToString('N')).json"
    Set-Content -Path $tmplPath -Value $tmpl -Encoding utf8
    try {
        $depName = "breakglass-ghpat-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
        # secretValue is a securestring template param, so ARM stores it as null in deployment history.
        $depErr = az deployment group create -g $ResourceGroup --name $depName --template-file $tmplPath `
            --parameters vaultName=$VaultName secretName=$SecretName secretValue=$Pat -o none 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "ARM secret write failed. Detail: $($depErr.Trim())" }
        $written = $true
        Write-Host "    OK. '$SecretName' written via ARM deployment '$depName' (vault remained locked)." -ForegroundColor Green
    }
    finally {
        Remove-Item -Path $tmplPath -ErrorAction SilentlyContinue
    }
}

# --- Force the runner Job to re-resolve the secret so the new PAT takes effect NOW -----------
# CRITICAL (learned 2026-07-05): ACA caches Key Vault secret references at the Job level. A new
# ephemeral runner execution reuses the CACHED value and does NOT re-read the vault per-run, so a
# freshly rotated PAT silently does NOT take effect until ACA's periodic refresh (observed up to
# hours) - the runner keeps 401'ing on the old token in the meantime. Re-pointing the Job secret
# to the SAME keyvaultref forces an immediate re-resolution over the Private Endpoint. This is a
# control-plane call (management.azure.com), NOT data-plane KV access, so it works even though the
# vault was re-locked in the finally above. Only runs after a successful write (a failed write
# throws out of the try/finally before reaching here). Best-effort: never fails the rotation.
Write-Step "Forcing the runner Job to re-resolve '$SecretName' (so the new value is used now) ..."
$reResolved = $false
$runnerJob = az containerapp job list -g $ResourceGroup -o json 2>$null |
    ConvertFrom-Json | Where-Object { $_.name -like 'caj-runner-*' } | Select-Object -First 1
if (-not $runnerJob) {
    Write-Host "    No runner Job (caj-runner-*) found in $ResourceGroup; skipping re-resolution." -ForegroundColor DarkYellow
} else {
    $jobSecret = $runnerJob.properties.configuration.secrets | Where-Object { $_.name -eq $SecretName } | Select-Object -First 1
    if (-not $jobSecret -or -not $jobSecret.keyVaultUrl) {
        Write-Host "    Runner Job '$($runnerJob.name)' has no Key Vault-backed '$SecretName' (INLINE mode); skipping re-resolution." -ForegroundColor DarkYellow
    } else {
        # ACA silently ignores a byte-identical secret write, so echoing $jobSecret.identity straight
        # back no-ops and the scaler keeps the dead token (comm-pilot, 2026-09-02: 55 min of queued
        # jobs). Flip the case of the resourceGroups segment so the value always differs; ARM resource
        # ids are case-insensitive, so both forms resolve the same managed identity.
        $identityRef = if ($jobSecret.identity -cmatch '/resourceGroups/') {
            $jobSecret.identity -creplace '/resourceGroups/', '/resourcegroups/'
        } else {
            $jobSecret.identity -creplace '/resourcegroups/', '/resourceGroups/'
        }
        $ref = "keyvaultref:$($jobSecret.keyVaultUrl),identityref:$identityRef"
        az containerapp job secret set -g $ResourceGroup -n $runnerJob.name --secrets "$SecretName=$ref" -o none 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $reResolved = $true; Write-Host "    Re-resolve submitted on '$($runnerJob.name)'." -ForegroundColor Green }
        else { Write-Host "    !!! Re-resolution failed; new value applies on ACA's next periodic refresh (up to a few hours). Force it with: az containerapp job secret set -g $ResourceGroup -n $($runnerJob.name) --secrets '$SecretName=<same keyvaultref>'" -ForegroundColor DarkYellow }
    }
}

# The vault write can succeed while the runner still uses a STALE credential (inline-mode Job, or
# a failed re-resolve). Do NOT report unqualified success in that case - a misleading "Done" here
# has previously hidden a dead runner for hours.
if ($reResolved) {
    Write-Host "`nDone. '$SecretName' rotated and a re-resolve was submitted to the runner Job." -ForegroundColor Green
    # exit 0 above only means the API accepted the write; a no-op write also returns 0.
    Write-Host "NOT YET PROVEN: only a Job EXECUTION shows the scaler picked up the new value. Verify with:" -ForegroundColor Yellow
    Write-Host "  gh workflow run runner-ping.yml -f label=$Env    # expect green, and a new execution within ~1 min" -ForegroundColor Yellow
} else {
    Write-Host "`nPARTIAL: '$SecretName' was written to the vault, but the runner Job did NOT pick it up." -ForegroundColor Yellow
    Write-Host "The runner is still using its OLD credential. If the Job secret is inline, the env's CI" -ForegroundColor Yellow
    Write-Host "param file must set ghRunnerSecretFromKeyVault=true (issue #86) and be re-provisioned;" -ForegroundColor Yellow
    Write-Host "verify with: az containerapp job show -g $ResourceGroup -n <caj-runner-*> --query properties.configuration.secrets" -ForegroundColor Yellow
    exit 2
}
