#requires -Version 7.0
<#
.SYNOPSIS
  COMMERCIAL-tenant peer setup for the parallel /openai-commercial route. Creates the secretless
  service principal the Gov APIM federates to, trusts the Gov APIM managed identity via a
  federated identity credential (workload identity federation), grants it data-plane access on
  the commercial Foundry account, and (optionally) allowlists the Gov gateway's NAT egress IP on
  the Foundry firewall. Idempotent. Runs in AzureCloud (the COMMERCIAL tenant).

.DESCRIPTION
  This is the cross-tenant "peer setup" half of docs/commercial-foundry-route.md that the Gov
  `infra/main.bicep` CANNOT perform: it is a DIRECTORY + RBAC write in a DIFFERENT tenant and a
  DIFFERENT cloud (AzureCloud), so it can never be an azd pre/postprovision hook on the Gov
  deployment. Run it once (per commercial Foundry) while signed in to the COMMERCIAL tenant; it
  emits the app (client) id you then plug into the Gov side as `foundryCommercialClientId`
  (CI Variable COMMERCIAL_CLIENT_ID) with `foundryCommercialAuthMode=servicePrincipalFederated`.

  WHAT IT DOES (all idempotent / reuse-on-rerun):
    1. Create or reuse a single-tenant app registration + service principal (NO secret, NO cert).
    2. Create or reuse federated identity credential(s) that trust the GOV APIM managed identity
       (issuer = Gov tenant STS, subject = the APIM MI object id, audience
       api://AzureADTokenExchange). By default BOTH a v1 (sts.windows.net) and a v2
       (login.microsoftonline.us) issuer are added to hedge the exact token format the Gov MI
       emits — whichever matches at runtime is used; the other is inert.
    3. Grant the SP "Cognitive Services OpenAI User" (data plane) on the commercial Foundry
       account so the federated token can call the model deployments.
    4. With -AllowGovEgressIp: add the Gov gateway NAT egress IP to the Foundry firewall and set
       publicNetworkAccess=Enabled (defaultAction stays Deny). This is a SECURITY-RELEVANT change
       to a running resource — only the single Gov egress IP is permitted; private-endpoint paths
       are unaffected. Omit the switch to leave the firewall untouched.
    5. Emit COMMERCIAL_CLIENT_ID / COMMERCIAL_TENANT_ID (to stdout, and to azd env + $GITHUB_ENV
       when present) for the Gov-side parameters.

  GET THE GOV INPUTS FIRST (run these signed in to AzureUSGovernment, in the Gov subscription):
    az apim show -g <gov-rg> -n <gov-apim> --query identity.principalId -o tsv   # -> GovApimMiObjectId
    az network public-ip show -g <gov-rg> -n pip-natgw-copilot-byok-<env>-<sfx> --query ipAddress -o tsv  # -> GovEgressIp
    (Gov tenant id is the entraTenantId in your Gov parameters file.)

.PARAMETER FoundryAccountName
  Commercial Foundry (kind=AIServices) account name. With -FoundryResourceGroup resolves the
  account resource id. Falls back to $env:foundryCommercialAccountName.
.PARAMETER FoundryResourceGroup
  Resource group of the commercial Foundry account. Falls back to $env:foundryCommercialResourceGroup.
.PARAMETER FoundryResourceId
  Full resource id of the commercial Foundry account. Overrides the name+rg pair when supplied.
.PARAMETER GovTenantId
  GOV tenant GUID whose STS issues the APIM MI token (used to build the FIC issuer URLs).
  Required. Falls back to $env:GOV_TENANT_ID.
.PARAMETER GovApimMiObjectId
  Object (principal) id of the GOV APIM system-assigned managed identity = the FIC subject.
  Required. Falls back to $env:GOV_APIM_MI_OBJECT_ID. Changes whenever the Gov APIM is recreated.
.PARAMETER GovEgressIp
  GOV gateway NAT egress public IP to allowlist on the Foundry firewall. Required only with
  -AllowGovEgressIp. Falls back to $env:GOV_EGRESS_IP.
.PARAMETER AppName
  App registration display name. Default 'copilot-byok-commercial-backend'.
.PARAMETER RoleName
  Data-plane role granted on the Foundry account. Default 'Cognitive Services OpenAI User'.
.PARAMETER SourceIssuerV1
  Override the v1 (sts.windows.net) FIC issuer. Default https://sts.windows.net/<GovTenantId>/.
.PARAMETER SourceIssuerV2
  Override the v2 FIC issuer. Default https://login.microsoftonline.us/<GovTenantId>/v2.0
  (Azure Government authority). Use https://login.microsoftonline.com/<tenant>/v2.0 if the
  source APIM is itself in a Commercial tenant.
.PARAMETER FicName
  Base name for the federated credential(s). Default 'gov-apim-fed' -> '<name>-v1' / '<name>-v2'.
.PARAMETER OnlyIssuer
  Create just one FIC: 'v1', 'v2', or 'both' (default 'both').
.PARAMETER AllowGovEgressIp
  Also allowlist -GovEgressIp on the Foundry firewall and enable public network access.
.PARAMETER ExpectedCommercialTenantId
  Optional guard: fail fast if the signed-in tenant does not match this GUID.
.EXAMPLE
  ./setup-commercial-backend.ps1 -FoundryAccountName aifcopilotbyokcommpilotjzjre3 `
    -FoundryResourceGroup rg-copilot-byok-comm-pilot `
    -GovTenantId ec95faea-ef9e-4337-8df0-c8d52a2ea281 `
    -GovApimMiObjectId 75a9babe-a41b-4e51-8b1f-c9a8301943bc `
    -GovEgressIp 20.159.140.229 -AllowGovEgressIp
#>
[CmdletBinding()]
param(
  [string]$FoundryAccountName   = $env:foundryCommercialAccountName,
  [string]$FoundryResourceGroup = $env:foundryCommercialResourceGroup,
  [string]$FoundryResourceId,
  [string]$GovTenantId          = $env:GOV_TENANT_ID,
  [string]$GovApimMiObjectId    = $env:GOV_APIM_MI_OBJECT_ID,
  [string]$GovEgressIp          = $env:GOV_EGRESS_IP,
  [string]$AppName              = 'copilot-byok-commercial-backend',
  [string]$RoleName             = 'Cognitive Services OpenAI User',
  [string]$SourceIssuerV1,
  [string]$SourceIssuerV2,
  [string]$FicName              = 'gov-apim-fed',
  [ValidateSet('v1', 'v2', 'both')]
  [string]$OnlyIssuer           = 'v2',
  [switch]$SkipFederatedCredential,
  [switch]$CreateSecret,
  [int]$SecretYears             = 1,
  [switch]$AllowGovEgressIp,
  [string]$ExpectedCommercialTenantId
)

$ErrorActionPreference = 'Stop'

function Set-OutputVar {
  param([string]$Name, [string]$Value)
  if (Get-Command azd -ErrorAction SilentlyContinue) { azd env set $Name $Value 2>$null | Out-Null }
  if ($env:GITHUB_ENV) { "$Name=$Value" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8 }
  Write-Host "  $Name=$Value"
}

az version *> $null 2>&1 || throw 'Azure CLI not found. Install it first.'
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az cloud set --name AzureCloud; az login' (the COMMERCIAL tenant) first." }
Write-Host "Cloud:   $($ctx.environmentName)"
Write-Host "Tenant:  $($ctx.tenantId)"
Write-Host "Account: $($ctx.user.name)`n"
if ($ctx.environmentName -ne 'AzureCloud') {
  Write-Warning "Signed-in cloud is '$($ctx.environmentName)', not 'AzureCloud'. This script targets the COMMERCIAL tenant that hosts the Foundry account."
}
if ($ExpectedCommercialTenantId -and $ctx.tenantId -ne $ExpectedCommercialTenantId) {
  throw "Signed-in tenant $($ctx.tenantId) != expected commercial tenant $ExpectedCommercialTenantId."
}

if (-not $GovTenantId)       { throw 'GovTenantId is required (the Gov tenant whose APIM MI token you trust).' }
if (-not $GovApimMiObjectId) { throw 'GovApimMiObjectId is required (the Gov APIM system-assigned MI object id = FIC subject).' }

# Resolve the Foundry account resource id.
if (-not $FoundryResourceId) {
  if (-not $FoundryAccountName -or -not $FoundryResourceGroup) {
    throw 'Provide -FoundryResourceId, or both -FoundryAccountName and -FoundryResourceGroup.'
  }
  $FoundryResourceId = az cognitiveservices account show -g $FoundryResourceGroup -n $FoundryAccountName --query id -o tsv
  if (-not $FoundryResourceId) { throw "Could not resolve Foundry account '$FoundryAccountName' in '$FoundryResourceGroup'." }
}
Write-Host "Foundry account: $FoundryResourceId`n"

# Issuer defaults (Gov authority). v1 = managed identities' classic STS; v2 = Gov AAD authority.
if (-not $SourceIssuerV1) { $SourceIssuerV1 = "https://sts.windows.net/$GovTenantId/" }
if (-not $SourceIssuerV2) { $SourceIssuerV2 = "https://login.microsoftonline.us/$GovTenantId/v2.0" }

# 1. App registration + service principal (no secret, no certificate).
$appId = az ad app list --display-name $AppName --query '[0].appId' -o tsv 2>$null
if ($appId) {
  Write-Host "Reusing app registration '$AppName' (appId $appId)."
}
else {
  $appId = az ad app create --display-name $AppName --sign-in-audience AzureADMyOrg --query appId -o tsv
  if (-not $appId) { throw "Failed to create app registration '$AppName'." }
  Write-Host "Created app registration '$AppName' (appId $appId)."
}
$spId = az ad sp show --id $appId --query id -o tsv 2>$null
if (-not $spId) {
  $spId = az ad sp create --id $appId --query id -o tsv
  if (-not $spId) { throw "Failed to create service principal for appId $appId." }
  Write-Host "Created service principal (objectId $spId)."
}
else {
  Write-Host "Reusing service principal (objectId $spId)."
}

# 2. Federated identity credential(s) trusting the Gov APIM managed identity.
function Set-Fic([string]$name, [string]$issuer) {
  $existing = az ad app federated-credential list --id $appId --query "[?name=='$name'] | [0]" -o json 2>$null | ConvertFrom-Json
  if ($existing) {
    if ($existing.subject -eq $GovApimMiObjectId -and $existing.issuer -eq $issuer) {
      Write-Host "  FIC '$name' already correct (issuer/subject match) — skipping."
      return
    }
    Write-Host "  FIC '$name' exists but differs — recreating."
    az ad app federated-credential delete --id $appId --federated-credential-id $existing.id 1>$null
  }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("fic-" + [Guid]::NewGuid().ToString('N') + '.json')
  @{ name = $name; issuer = $issuer; subject = $GovApimMiObjectId; audiences = @('api://AzureADTokenExchange'); description = 'Secretless cross-tenant token exchange for the BYOK commercial route' } | ConvertTo-Json | Set-Content -Path $tmp -Encoding utf8
  try {
    az ad app federated-credential create --id $appId --parameters "@$tmp" 1>$null
    if ($LASTEXITCODE -ne 0) { throw "federated-credential create failed for '$name' (issuer $issuer)." }
    Write-Host "  FIC '$name' set (issuer $issuer)."
  }
  finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

Write-Host "Federated identity credentials (subject=$GovApimMiObjectId, aud=api://AzureADTokenExchange):"
if ($SkipFederatedCredential) {
  Write-Host "  -SkipFederatedCredential set - not creating any FIC (use this for Gov -> Commercial, which"
  Write-Host "  can only use servicePrincipal secret mode; cross-sovereign-cloud WIF is blocked, AADSTS700238)."
}
else {
  # NOTE: Entra allows only ONE FIC per subject (a v1+v2 hedge fails at runtime with AADSTS700263).
  # APIM managed identities mint a v2 token, so the default is the single v2 FIC.
  if ($OnlyIssuer -in @('v1', 'both')) { Set-Fic "$FicName-v1" $SourceIssuerV1 }
  if ($OnlyIssuer -in @('v2', 'both')) { Set-Fic "$FicName-v2" $SourceIssuerV2 }
}

# 3. Data-plane role on the Foundry account.
az role assignment create --assignee-object-id $spId --assignee-principal-type ServicePrincipal --role $RoleName --scope $FoundryResourceId 1>$null
if ($LASTEXITCODE -ne 0) { throw "Failed to grant '$RoleName' to the SP on the Foundry account." }
Write-Host "`nGranted '$RoleName' to the SP on the Foundry account."

# 3b. Optional client secret for servicePrincipal (secret) mode. REQUIRED for Gov -> Commercial,
# where the secretless federated path is blocked (AADSTS700238).
if ($CreateSecret) {
  $clientSecret = az ad app credential reset --id $appId --display-name "$AppName-secret" --years $SecretYears --append --query password -o tsv
  if (-not $clientSecret) { throw 'Failed to create a client secret on the SP.' }
  Write-Warning 'A client secret was created. Protect it: store it in Key Vault / a secure variable; never commit it.'
}

# 4. Optional firewall allowlist for the Gov egress IP.
if ($AllowGovEgressIp) {
  if (-not $GovEgressIp) { throw '-AllowGovEgressIp requires -GovEgressIp (the Gov gateway NAT egress public IP).' }
  Write-Warning "Allowlisting $GovEgressIp on the Foundry firewall and enabling public network access (defaultAction stays Deny)."
  az cognitiveservices account network-rule add --ids $FoundryResourceId --ip-address $GovEgressIp -o none
  az resource update --ids $FoundryResourceId --set properties.publicNetworkAccess=Enabled -o none
  $net = az cognitiveservices account show --ids $FoundryResourceId --query "{pna:properties.publicNetworkAccess, defaultAction:properties.networkAcls.defaultAction, ipRules:properties.networkAcls.ipRules[].value}" -o json
  Write-Host "Foundry firewall now: $net"
}
else {
  Write-Host "`nSkipping firewall change (no -AllowGovEgressIp). The Gov gateway will be blocked until $($GovEgressIp ? $GovEgressIp : '<gov-egress-ip>') is allowlisted on the Foundry."
}

# 5. Emit the values the Gov side needs.
Write-Host "`nGov-side parameters (set on the Gov deployment):"
Set-OutputVar 'COMMERCIAL_CLIENT_ID' $appId
Set-OutputVar 'COMMERCIAL_TENANT_ID' $ctx.tenantId
if ($CreateSecret) {
  Set-OutputVar 'COMMERCIAL_FOUNDRY_CLIENT_SECRET' $clientSecret
  Write-Host "`nGov -> Commercial is cross-sovereign-cloud: set foundryCommercialAuthMode=servicePrincipal,"
  Write-Host "deployFoundryCommercial=true, foundryCommercialClientId=$appId, foundryCommercialTenantId=$($ctx.tenantId),"
  Write-Host "and foundryCommercialClientSecret=<the secret above>, then re-provision the Gov gateway."
}
else {
  Write-Host "`nSame-cloud cross-tenant: foundryCommercialAuthMode=servicePrincipalFederated, deployFoundryCommercial=true,"
  Write-Host "foundryCommercialClientId=$appId, foundryCommercialTenantId=$($ctx.tenantId), then re-provision the Gov gateway."
  Write-Host "(Gov -> Commercial cannot use the federated path - AADSTS700238; re-run with -SkipFederatedCredential -CreateSecret.)"
}
