#requires -Version 7.0
<#
.SYNOPSIS
  Allowlist gov gateway NAT egress IP(s) on THIS deployment's Foundry account firewall (enable
  public network access with defaultAction=Deny + ipRules). No-op unless FoundryIngressIps is set.
  Idempotent. Cloud-agnostic. Wired as an azd `postprovision` hook.
.DESCRIPTION
  The commercial Foundry that backs the Gov `/openai-commercial` route (docs/commercial-foundry-route.md)
  lives in the COMMERCIAL tenant and is reached over the public internet from the Gov gateway's NAT
  egress IP. That IP must be allowlisted on the Foundry account firewall. This runs on the COMMERCIAL
  deployment (comm-pilot) so the Foundry owner manages its own ingress allowlist from a single
  environment Variable (FOUNDRY_PUBLIC_INGRESS_IPS) — the Gov deployment cannot touch a resource in
  another tenant/cloud.

  WHY A POST-PROVISION SCRIPT (not Bicep): foundry.bicep pins `publicNetworkAccess: 'Disabled'` +
  `ipRules: []` (private-endpoint-only default). This hook runs AFTER provision and overrides that to
  Enabled + the configured ipRules, so the private-endpoint path (comm-pilot's own APIM) is unchanged
  (PE bypasses networkAcls) while the listed public IPs are additionally allowed. Because Bicep clears
  ipRules to [] each provision and this hook re-adds exactly the current list, removed IPs converge out.

  NO-OP unless FoundryIngressIps is non-empty, so Gov and any other deployment are untouched.

.PARAMETER FoundryIngressIps
  Space/comma-separated gov NAT egress IPs (or CIDRs) to allow. Falls back to
  $env:FOUNDRY_PUBLIC_INGRESS_IPS. Empty => skip (exit 0).
.PARAMETER ResourceGroup
  Resource group holding the Foundry account. Falls back to azd output $env:resourceGroup.
.PARAMETER FoundryAccountName
  Foundry (kind=AIServices) account name. Falls back to azd output $env:foundryAccountName. Empty => skip.
.EXAMPLE
  FOUNDRY_PUBLIC_INGRESS_IPS="20.159.140.229 20.141.70.93" ./allow-foundry-ingress-ips.ps1
#>
[CmdletBinding()]
param(
  [string]$FoundryIngressIps   = $env:FOUNDRY_PUBLIC_INGRESS_IPS,
  [string]$ResourceGroup       = $env:resourceGroup,
  [string]$FoundryAccountName  = $env:foundryAccountName
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($FoundryIngressIps)) {
  Write-Host 'FOUNDRY_PUBLIC_INGRESS_IPS is empty — no Foundry ingress allowlist to apply (skipping).'
  exit 0
}
if (-not $FoundryAccountName) {
  Write-Host 'foundryAccountName not available (Foundry not deployed?) — skipping ingress allowlist.'
  exit 0
}
if (-not $ResourceGroup) { throw 'ResourceGroup not provided and $env:resourceGroup is empty.' }

az version *> $null 2>&1 || throw 'Azure CLI not found. Install it first.'
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' (matching the deployment cloud) first." }
Write-Host "Cloud:   $($ctx.environmentName)"
Write-Host "Foundry: $FoundryAccountName (rg $ResourceGroup)"

$id = az cognitiveservices account show -g $ResourceGroup -n $FoundryAccountName --query id -o tsv
if (-not $id) { throw "Could not resolve Foundry account '$FoundryAccountName' in '$ResourceGroup'." }

$ips = $FoundryIngressIps -split '[,\s]+' | Where-Object { $_ }
if ($ips.Count -eq 0) {
  Write-Host "No valid ingress IPs parsed from '$FoundryIngressIps' - nothing to allowlist (skipping)."
  exit 0
}
Write-Warning "Allowlisting $($ips.Count) public ingress IP(s) on '$FoundryAccountName' and enabling public network access (defaultAction stays Deny)."
$ipRules = '[' + (($ips | ForEach-Object { '{{"value":"{0}"}}' -f $_ }) -join ',') + ']'
# Apply PNA + defaultAction=Deny + the full ipRules list in ONE call, addressing the account by its
# resource id (--ids). This deliberately avoids `az cognitiveservices account network-rule add`,
# which does not accept --ids and refused the -g/-n it was given inside the azd hook environment.
# `az resource update --ids` is the same call the PNA line used and is known-good here. Idempotent:
# Bicep resets ipRules=[] each provision and this re-sets exactly the current list, so removed
# IPs converge out. Non-fatal: a firewall convenience must never abort the whole provision.
az resource update --ids $id `
  --set properties.publicNetworkAccess=Enabled `
        properties.networkAcls.defaultAction=Deny `
        "properties.networkAcls.ipRules=$ipRules" -o none
if ($LASTEXITCODE -ne 0) {
  Write-Warning "Failed to update Foundry firewall on '$FoundryAccountName'; leaving provision green. Re-run this hook or set the ipRules manually."
  exit 0
}
$ips | ForEach-Object { Write-Host "  allowed $_" }
$net = az cognitiveservices account show --ids $id --query "{pna:properties.publicNetworkAccess, defaultAction:properties.networkAcls.defaultAction, ipRules:properties.networkAcls.ipRules[].value}" -o json
Write-Host "Foundry firewall now: $net"
