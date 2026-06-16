#!/usr/bin/env pwsh
# Probe whether APIM telemetry is flowing into Log Analytics + App Insights.
# Pass the LAW customerId, the App Insights appId, and the cloud (commercial|gov).
param(
    [Parameter(Mandatory)] [string] $WorkspaceId,
    [Parameter(Mandatory)] [string] $AppInsightsAppId,
    [ValidateSet('commercial', 'gov')] [string] $Cloud = 'commercial',
    [int] $LookbackMinutes = 120
)

$laHost  = if ($Cloud -eq 'gov') { 'api.loganalytics.us' }    else { 'api.loganalytics.io' }
$aiHost  = if ($Cloud -eq 'gov') { 'api.applicationinsights.us' } else { 'api.applicationinsights.io' }
$laRes   = "https://$laHost"
$aiRes   = "https://$aiHost"

$tokenLa = az account get-access-token --resource $laRes --query accessToken -o tsv
$tokenAi = az account get-access-token --resource $aiRes --query accessToken -o tsv

function Invoke-Kql([string] $endpoint, [string] $token, [string] $query) {
    $body = @{ query = $query } | ConvertTo-Json -Compress
    $resp = Invoke-RestMethod -Method POST -Uri $endpoint -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } -Body $body
    if ($resp.tables -and $resp.tables[0].rows) { $resp.tables[0].rows } else { @() }
}

Write-Host "=== Log Analytics workspace ($WorkspaceId) ===" -ForegroundColor Cyan
$laUri = "$laRes/v1/workspaces/$WorkspaceId/query"

Write-Host "ApiManagementGatewayLogs (gateway requests):"
$rows = Invoke-Kql $laUri $tokenLa "ApiManagementGatewayLogs | where TimeGenerated > ago(${LookbackMinutes}m) | summarize requests=count() by bin(TimeGenerated, 10m) | order by TimeGenerated desc"
if (-not $rows) { Write-Host "  (no rows)" -ForegroundColor Yellow } else { $rows | ForEach-Object { "  $($_[0])  $($_[1]) requests" } }

Write-Host "`n=== Application Insights ($AppInsightsAppId) ===" -ForegroundColor Cyan
$aiUri = "$aiRes/v1/apps/$AppInsightsAppId/query"

Write-Host "requests (APIM frontend traces):"
$rows = Invoke-Kql $aiUri $tokenAi "requests | where timestamp > ago(${LookbackMinutes}m) | summarize calls=count() by bin(timestamp, 10m) | order by timestamp desc"
if (-not $rows) { Write-Host "  (no rows — APIM may not be sending request telemetry yet)" -ForegroundColor Yellow } else { $rows | ForEach-Object { "  $($_[0])  $($_[1]) calls" } }

Write-Host "`ncustomMetrics (emit-metric output — copilot_byok_*):"
$rows = Invoke-Kql $aiUri $tokenAi "customMetrics | where timestamp > ago(${LookbackMinutes}m) | where name startswith 'copilot_byok_' | summarize total=sum(value), points=count() by name | order by name asc"
if (-not $rows) { Write-Host "  (no copilot_byok_* metrics emitted — check that diagnostics.metrics=true and emit-metric ran)" -ForegroundColor Yellow } else { $rows | ForEach-Object { "  $($_[0])  total=$($_[1])  points=$($_[2])" } }

Write-Host "`n=== Diagnosis ===" -ForegroundColor Cyan
Write-Host "Live Metrics (App Insights -> Live Metrics blade): expected to be EMPTY."
Write-Host "  APIM's logger pushes via classic ingestion (instrumentation key, not connection string +"
Write-Host "  QuickPulse), so APIM does not stream to the Live Metrics endpoint. Live Metrics only"
Write-Host "  lights up when an SDK-instrumented app (Function/AppService/.NET/Node/Python with the"
Write-Host "  App Insights SDK) is also reporting to this App Insights resource. We have none."
Write-Host ""
Write-Host "APIM portal -> Monitoring -> Analytics blade: built off the APIM Reports API (internal"
Write-Host "  aggregation), which updates slowly on low-traffic gateways (15-60 min lag, and often"
Write-Host "  hours on a brand-new APIM that has only seen a handful of smoke calls). For real-time"
Write-Host "  visibility use:"
Write-Host "    - APIM -> Monitoring -> Logs (KQL against ApiManagementGatewayLogs, 1-3 min lag)"
Write-Host "    - App Insights -> Logs (KQL against requests / customMetrics, 1-5 min lag)"
Write-Host "    - The KQL files in monitoring/kql/ point at exactly these tables."
