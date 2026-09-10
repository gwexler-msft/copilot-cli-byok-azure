#requires -Version 7.0
<#
.SYNOPSIS
  Create/refresh the Entra app registration that fronts the self-serve "register" app with
  Easy Auth, store its client secret in Key Vault, and hand the client id + secret URI back to
  azd so a follow-up `azd provision` attaches the login flow. Idempotent. Cloud-aware
  (AzureCloud + AzureUSGovernment). Degrades gracefully (prints the manual command, exits 0)
  when the caller lacks directory-write rights - so deployment never breaks.

.DESCRIPTION
  EASY AUTH WIRING for the register app (issue #64 / #68). This is the second phase of the
  register app's two-phase bring-up:

    phase 1:  azd provision (deployRegisterApp=true, auth params empty)  -> hosting + KV + UAMI
    deploy:   azd deploy register                                        -> real Blazor image
    phase 2:  THIS SCRIPT                                                 -> app reg + secret->KV
              azd provision (auth params now populated)                  -> Easy Auth attached

  Why a script and not Bicep: creating an Entra app registration and minting a client secret
  are DIRECTORY writes (Application.ReadWrite.OwnedBy). The redirect URI also needs the
  Container App FQDN, which only exists after the first provision. So we mirror the repo's
  established pattern (setup-entra / grant-register-graph-perms): a standalone, idempotent,
  cloud-aware hook that degrades to a printed manual command when the principal lacks rights.

  What it does (all idempotent / reuse-on-rerun):
    1. Create or reuse an app registration named "copilot-byok-register-<envName>".
    2. Set the Easy Auth web redirect URI https://<fqdn>/.auth/login/aad/callback, request v2
       tokens + api://<appId> identifier, and emit the SecurityGroup groups claim (so the tier
       resolver can read group membership inline, avoiding the Graph-overage fallback).
    3. Mint a client secret (only when the Key Vault secret is absent, or -Rotate is passed)
       and store it in the register Key Vault secret "register-easyauth-secret". The plaintext
       never touches azd state or a Bicep param.
    4. Publish REGISTER_EASYAUTH_CLIENT_ID and REGISTER_EASYAUTH_SECRET_KV_URI to the azd env
       (and to $GITHUB_ENV when running in Actions) for the follow-up provision.

.PARAMETER AppFqdn
  Container App ingress FQDN. Falls back to azd output $env:registerAppFqdn. Empty => the
  register app is not deployed => script skips (exit 0).
.PARAMETER KeyVaultName
  Register Key Vault name. Falls back to azd output $env:registerKeyVaultName.
.PARAMETER EnvName
  Environment short name used in the app-reg display name. Falls back to $env:AZURE_ENV_NAME.
.PARAMETER SecretName
  Key Vault secret name for the Easy Auth client secret. Default 'register-easyauth-secret'.
.PARAMETER Rotate
  Force minting a new client secret even if one already exists in Key Vault.
.EXAMPLE
  ./setup-register-entra.ps1 -AppFqdn ca-register-comm-dev-abc123.bluefoo.eastus2.azurecontainerapps.io -KeyVaultName kvregcommdevabc123 -EnvName comm-dev
#>
[CmdletBinding()]
param(
  # azd stores bicep outputs UPPER_SNAKE-cased; keep the camelCase name as a secondary fallback.
  [string]$AppFqdn      = ($env:REGISTER_APP_FQDN ?? $env:registerAppFqdn),
  [string]$KeyVaultName = ($env:REGISTER_KEY_VAULT_NAME ?? $env:registerKeyVaultName),
  [string]$EnvName      = $env:AZURE_ENV_NAME,
  [string]$SecretName   = 'register-easyauth-secret',
  [switch]$Rotate
)

$ErrorActionPreference = 'Stop'

function Set-OutputVar {
  param([string]$Name, [string]$Value)
  # azd env (drives the follow-up provision via ${...} substitution in the CI params file).
  # GUARD: with no default azd environment, `azd env set` PROMPTS ("Select an environment") and
  # blocks on stdin forever. `2>$null | Out-Null` hides the prompt but does not stop the wait, so
  # the script just appears to freeze - and it froze on the very path the degrade message tells an
  # admin to run by hand. Only publish to azd when an environment is actually selected.
  if ((Get-Command azd -ErrorAction SilentlyContinue) -and (Test-AzdEnvSelected)) {
    azd env set $Name $Value 2>$null | Out-Null
  }
  # GitHub Actions env (so later workflow steps see it too).
  if ($env:GITHUB_ENV) { "$Name=$Value" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8 }
  Write-Host "  $Name=$Value"
}

function Test-AzdEnvSelected {
  if ($env:AZURE_ENV_NAME) { return $true }
  $envs = azd env list --output json 2>$null | ConvertFrom-Json
  return [bool]($envs | Where-Object { $_.IsDefault })
}

az version *> $null 2>&1 || throw 'Azure CLI not found. Install it first.'
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' (matching the deployment cloud) first." }
Write-Host "Cloud:   $($ctx.environmentName)"
Write-Host "Account: $($ctx.user.name)"

if (-not $AppFqdn) {
  Write-Host 'Register app not deployed (registerAppFqdn is empty) - skipping Easy Auth setup.'
  return
}
if (-not $KeyVaultName) {
  Write-Host 'No register Key Vault name supplied (registerKeyVaultName is empty) - skipping Easy Auth setup.'
  return
}
if (-not $EnvName) { $EnvName = 'register' }

$tenantId    = $ctx.tenantId
$displayName = "copilot-byok-register-$EnvName"
$redirectUri = "https://$AppFqdn/.auth/login/aad/callback"
$graph       = (az cloud show --query 'endpoints.microsoftGraphResourceId' -o tsv).TrimEnd('/')

Write-Host "App reg: $displayName"
Write-Host "Redirect: $redirectUri`n"

function Invoke-GraphAppPatch {
  param([string]$ObjectId, [hashtable]$Patch)
  $tmp = New-TemporaryFile
  ($Patch | ConvertTo-Json -Depth 10) | Set-Content -Path $tmp.FullName -Encoding utf8
  try {
    $out = az rest --method PATCH `
      --uri "$graph/v1.0/applications/$ObjectId" `
      --resource $graph `
      --headers 'Content-Type=application/json' `
      --body "@$($tmp.FullName)" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Graph PATCH failed: $out" }
  } finally { Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue }
}

function Show-ManualFallback {
  # $Explanation defaults to the directory-rights case because that is by far the most common
  # degradation, but it MUST be overridable: this warning previously asserted "the deploy
  # principal lacks Entra app-management rights" for EVERY failure, including Key Vault ones
  # where the directory writes had already succeeded. That sent a reader chasing Entra
  # permissions while the real cause was a locked vault. Never state a cause you did not test.
  param(
    [string]$Reason,
    [string]$Explanation = @'
This is EXPECTED when the deploy principal lacks Entra app-management rights
(Application.ReadWrite.OwnedBy).
'@
  )
  # NOTE: double-quoted here-string => a lone backtick is an ESCAPE. `azd rendered as BEL+"zd"
  # ('`a' = alert), printing "re-run zd provision". Doubled backticks emit one literal backtick.
  Write-Warning @"
Could not complete Easy Auth app-registration setup - $Reason

$($Explanation.Trim()) The deployment itself is fine; the register app stays
reachable WITHOUT auth until an admin wires Easy Auth. Have an admin run, in THIS cloud:

  az login    # correct cloud (Commercial or Gov)
  ./scripts/setup-register-entra.ps1 -AppFqdn $AppFqdn -KeyVaultName $KeyVaultName -EnvName $EnvName

Then re-run ``azd provision`` to attach the login flow.
"@
}

function Write-KvSecretViaArm {
  <#
    Write a Key Vault secret through a RESOURCE MANAGER deployment instead of the data plane.

    Why: the register vaults ship locked down (publicNetworkAccess=Disabled), so `az keyvault
    secret set` is unreachable from anywhere outside the VNet NO MATTER WHAT ROLE THE CALLER
    HOLDS - it fails before RBAC is even consulted. ARM is a trusted service, so a
    Microsoft.KeyVault/vaults/secrets deployment lands while the vault stays locked. Same
    trusted-services bypass proven in scripts/rotate-runner-pat-breakglass.ps1.

    secretValue is a securestring template param, so ARM records it as null in deployment history.
  #>
  param([string]$VaultName, [string]$SecretName, [string]$SecretValue)

  $rgName = az keyvault show --name $VaultName --query resourceGroup -o tsv 2>$null
  if (-not $rgName) { return $false }

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
  $tmplPath = Join-Path ([System.IO.Path]::GetTempPath()) "easyauth-kvsecret-$([guid]::NewGuid().ToString('N')).json"
  Set-Content -Path $tmplPath -Value $tmpl -Encoding utf8
  try {
    $depName = "easyauth-secret-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
    az deployment group create -g $rgName --name $depName --template-file $tmplPath `
      --parameters vaultName=$VaultName secretName=$SecretName secretValue=$SecretValue -o none 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
  }
  finally { Remove-Item -Path $tmplPath -ErrorAction SilentlyContinue }
}

# 1. Create or reuse the app registration.
try {
  $appId = az ad app list --display-name $displayName --query '[0].appId' -o tsv 2>$null
  if ($appId) {
    Write-Host "Reusing existing app registration appId=$appId."
  } else {
    Write-Host "Creating app registration '$displayName'..."
    $appId = az ad app create --display-name $displayName --sign-in-audience AzureADMyOrg --query appId -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) { throw $appId }
  }
} catch {
  $t = "$_"
  if ($t -match 'Authorization_RequestDenied|Insufficient privileges|Forbidden|\b403\b') { Show-ManualFallback 'directory write denied.'; return }
  throw
}

$objectId = az ad app show --id $appId --query id -o tsv

# 2. Redirect URI + v2 tokens + identifier + SecurityGroup / login_hint claims.
Write-Host 'Configuring redirect URI, v2 tokens, and claims...'
try {
  Invoke-GraphAppPatch -ObjectId $objectId -Patch @{
    # ACA/App Service Easy Auth drives the AAD login with the hybrid 'id_token' response_type,
    # so the app registration MUST allow ID-token issuance. Leaving this false yields
    # AADSTS700054 ("response_type 'id_token' is not enabled") -> HTTP 401 at /.auth/login/aad/callback.
    web = @{
      redirectUris          = @($redirectUri)
      implicitGrantSettings = @{ enableIdTokenIssuance = $true }
    }
    identifierUris        = @("api://$appId")
    groupMembershipClaims = 'SecurityGroup'
    api                   = @{ requestedAccessTokenVersion = 2 }
    # login_hint is what the sign-out flow passes as logout_hint to skip the "pick an account to
    # sign out of" prompt (#136). Entra only emits it when requested as an optional claim, and the
    # docs are explicit that a UPN is not a valid substitute.
    optionalClaims        = @{
      idToken     = @(@{ name = 'login_hint'; essential = $false })
      accessToken = @()
      saml2Token  = @()
    }
  }
} catch {
  if ("$_" -match 'Authorization_RequestDenied|Insufficient privileges|Forbidden|\b403\b') { Show-ManualFallback 'directory write denied.'; return }
  throw
}

# Ensure a service principal exists for the app (Easy Auth needs it in the tenant).
if (-not (az ad sp show --id $appId --query id -o tsv 2>$null)) {
  az ad sp create --id $appId 2>$null | Out-Null
}

# 3. Client secret -> Key Vault. Only mint when absent (or -Rotate), to keep re-provisions stable.
$vaultUri = (az keyvault show --name $KeyVaultName --query 'properties.vaultUri' -o tsv 2>$null)
if (-not $vaultUri) { Show-ManualFallback "Key Vault '$KeyVaultName' not found."; return }
$secretUri = "${vaultUri}secrets/$SecretName"

$haveSecret = az keyvault secret show --vault-name $KeyVaultName --name $SecretName --query id -o tsv 2>$null
if ($haveSecret -and -not $Rotate) {
  Write-Host "Key Vault already holds '$SecretName' - reusing (pass -Rotate to force a new secret)."
} else {
  Write-Host 'Minting a client secret...'
  # Capture stdout only (2>$null): az emits a "protect these credentials" WARNING to stderr,
  # and 2>&1 would merge it into the value, corrupting the secret. Trim + last-line guard.
  $secretValue = az ad app credential reset --id $appId --display-name 'byok-easyauth' --years 1 --query password -o tsv 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $secretValue) {
    Show-ManualFallback 'cannot mint a client secret (directory write denied?).'; return
  }
  $secretValue = ("$secretValue" -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim()

  # Write to Key Vault. Two DIFFERENT failure modes, and conflating them cost real debugging time:
  #   a) authorization  - caller lacks Secrets Officer  => self-grant + wait for propagation.
  #   b) network        - vault is publicNetworkAccess=Disabled (the register vaults' default)
  #                       => the data plane is unreachable from outside the VNet and NO amount of
  #                          RBAC or waiting fixes it. Retrying here just burns 60s and then
  #                          reports "role not propagated", which is simply untrue.
  # So: classify first, and fall back to the ARM (trusted-services) write, which needs neither.
  $written = $false
  $set = az keyvault secret set --vault-name $KeyVaultName --name $SecretName --value $secretValue -o none 2>&1
  if ($LASTEXITCODE -eq 0) { $written = $true }

  $networkBlocked = "$set" -match '[Pp]ublic network access is disabled|private link|not from a trusted service|ForbiddenByFirewall|ForbiddenByConnection'

  if (-not $written -and -not $networkBlocked) {
    if ("$set" -match 'Forbidden|does not have secrets set permission|AuthorizationFailed|\b403\b') {
      Write-Host 'No Key Vault write yet - self-granting Key Vault Secrets Officer and retrying...'
      # Detect principal type: a human admin running the documented fallback is a User;
      # the CI deploy identity is a ServicePrincipal. A wrong type hint => PrincipalNotFound
      # => the grant silently fails and every retry then 403s.
      $callerOid = az ad signed-in-user show --query id -o tsv 2>$null
      $callerType = 'User'
      if (-not $callerOid) { $callerOid = az ad sp show --id $ctx.user.name --query id -o tsv 2>$null; $callerType = 'ServicePrincipal' }
      $kvId = az keyvault show --name $KeyVaultName --query id -o tsv
      if ($callerOid) {
        az role assignment create --assignee-object-id $callerOid --assignee-principal-type $callerType `
          --role 'Key Vault Secrets Officer' --scope $kvId 2>$null | Out-Null
      }
      foreach ($i in 1..6) {
        Start-Sleep -Seconds 10
        $set = az keyvault secret set --vault-name $KeyVaultName --name $SecretName --value $secretValue -o none 2>&1
        if ($LASTEXITCODE -eq 0) { $written = $true; break }
        Write-Host "  retry $i/6 - role propagation pending..."
      }
    } else {
      throw "Key Vault secret set failed: $set"
    }
  }

  if (-not $written) {
    if ($networkBlocked) {
      Write-Host 'Vault data plane is closed to the public network - writing via ARM deployment (vault stays locked)...'
    } else {
      Write-Host 'Data-plane write still denied - trying the ARM deployment path...'
    }
    $written = Write-KvSecretViaArm -VaultName $KeyVaultName -SecretName $SecretName -SecretValue $secretValue
  }

  if (-not $written) {
    Show-ManualFallback 'could not write the client secret to Key Vault (data plane AND ARM deployment both failed).' @'
The app registration itself is fine - this is the Key Vault step. Check that the caller can
deploy to the vault's resource group, and that the vault is not additionally restricted.
'@
    return
  }
  Write-Host "Stored Easy Auth client secret in Key Vault as '$SecretName'."
}

# 4. Publish for the follow-up provision.
Write-Host "`nPublishing Easy Auth values for the follow-up provision:"
Set-OutputVar -Name 'REGISTER_EASYAUTH_CLIENT_ID'      -Value $appId
Set-OutputVar -Name 'REGISTER_EASYAUTH_SECRET_KV_URI'  -Value $secretUri

Write-Host "`nDone. Re-run ``azd provision`` to attach Easy Auth to the register app."
