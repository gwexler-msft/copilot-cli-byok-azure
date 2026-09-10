#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Patch APIM -> Log Analytics diagnostic setting to use the resource-specific
  table (ApiManagementGatewayLogs) instead of the legacy AzureDiagnostics table.

.DESCRIPTION
  The Bicep `infra/modules/apim.bicep` historically omitted
  `logAnalyticsDestinationType: 'Dedicated'`, which made gateway logs land in
  the legacy `AzureDiagnostics` table. All KQL files in `monitoring/kql/`
  query `ApiManagementGatewayLogs` (the modern resource-specific table) and
  therefore returned 0 rows on every live deployment.

  This script idempotently re-creates the `to-log-analytics` diagnostic setting
  with `--export-to-resource-specific true`. Safe to re-run; the existing
  Application Insights wiring (logger + service-level diagnostic) is unaffected.

  Run AFTER selecting the right cloud / subscription (`az cloud set` +
  `az account set`). Discover RG + APIM names from the existing deployment
  outputs or `az apim list -g <rg>`.

.PARAMETER ResourceGroup
  Resource group containing the APIM service and Log Analytics workspace.

.PARAMETER ApimName
  APIM service name (e.g. apim-copilot-byok-gov-dev-cukafb).

.PARAMETER WorkspaceName
  Log Analytics workspace name (e.g. log-copilot-byok-gov-dev-cukafb).
  Defaults to the APIM name with `apim-` -> `log-` substitution.

.EXAMPLE
  ./scripts/apply-diag-dedicated.ps1 -ResourceGroup rg-copilot-byok-gov-dev `
    -ApimName apim-copilot-byok-gov-dev-cukafb
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $ApimName,
    [string] $WorkspaceName = ($ApimName -replace '^apim-', 'log-')
)

$ErrorActionPreference = 'Stop'

$sub = az account show --query id -o tsv
if (-not $sub) { throw "az account show returned no subscription id - run 'az login' first." }

$apimId = "/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"
$wsId   = "/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName"

Write-Host "APIM:      $apimId" -ForegroundColor Cyan
Write-Host "Workspace: $wsId"   -ForegroundColor Cyan

$current = az monitor diagnostic-settings show --resource $apimId --name to-log-analytics -o json 2>$null | ConvertFrom-Json
if ($current -and $current.logAnalyticsDestinationType -eq 'Dedicated') {
    Write-Host "Already 'Dedicated' - nothing to do." -ForegroundColor Green
    return
}

Write-Host "Re-creating 'to-log-analytics' with --export-to-resource-specific..." -ForegroundColor Yellow
$result = az monitor diagnostic-settings create `
    --resource $apimId `
    --name to-log-analytics `
    --workspace $wsId `
    --export-to-resource-specific true `
    --logs '[{\"categoryGroup\":\"allLogs\",\"enabled\":true}]' `
    --metrics '[{\"category\":\"AllMetrics\",\"enabled\":true}]' `
    -o json | ConvertFrom-Json

if ($result.logAnalyticsDestinationType -eq 'Dedicated') {
    Write-Host "OK - logAnalyticsDestinationType is now 'Dedicated'." -ForegroundColor Green
    Write-Host "New gateway calls will populate ApiManagementGatewayLogs within a few minutes."
} else {
    throw "Unexpected destination type: $($result.logAnalyticsDestinationType)"
}
