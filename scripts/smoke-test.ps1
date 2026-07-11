<#
.SYNOPSIS
    End-to-end smoke test for a deployed Copilot CLI BYOK gateway env (#56).

.DESCRIPTION
    Runs five assertions against a deployed BYOK env. The GitHub Actions workflow
    (.github/workflows/smoke-test.yml) just orchestrates -- this script does the
    actual probing so it can also be run locally for debugging.

    Assertions (each is a [PASS|FAIL] line + collected into a final Exit code):
      1. list-models   -- GET /openai/v1/models on the APIM gateway -> 200, models
                          contain `gpt-5.1` and `gpt-4.1-mini`.
      2. chat dev1     -- POST /openai/v1/chat/completions with the byok-standard
                          key -> 200, response shape valid.
      3. chat dev2     -- same, with the byok-power key (separate tier).
      3b. commercial-route -- POST /openai-commercial/v1/chat/completions (byok-standard key) -> 200
                          from the Commercial Foundry (the cross-cloud route). SKIPs where the route
                          is not deployed (404, e.g. comm-* envs); FAILs on 502 (route up but the
                          backend auth / firewall / egress is broken).
      3c. commercial-only-model -- same route with a Commercial-only model (gpt-5-mini) not hosted in
                          Gov; asserts the echoed model name -> proves the cross-cloud path serves a
                          Gov-unavailable model. Same 404/403 SKIP semantics as 3b.
      4. emit-metric   -- KQL on App Insights customMetrics for copilot_byok_* in
                          last 15m -> Hits > 0. This is the #16 regression net:
                          if the apim diagnostic loses `metrics: true`, this fails.
      5. token-limit   -- Oversized prompt -> 429 from `llm-token-limit` policy.
                          Asserts the throttle path is wired before tokens are spent.
      6. register-app  -- GET /healthz on the self-serve register app (#64), when the env
                          was provisioned with deployRegisterApp=true. Accepts 200 (pre-auth
                          placeholder) or 302/401/403 (Easy Auth on) as "app is up". SKIPs
                          when the env has no register app -- best-effort, never a hard gate.
      7. register-auth -- POST /api/register on the register app WITHOUT a token. Easy Auth on
                          -> 302 login redirect (before the app runs); not-yet-attached -> 401.
                          Either denies provisioning. A 2xx = the privileged endpoint is
                          anonymously reachable -> FAIL. SKIPs when no register app.
      8. register-rbac -- The register UAMI holds the custom 'BYOK Register Subscription Manager'
                          role at the APIM scope (the right that lets the app provision per-dev
                          subscriptions). Control-plane only. SKIPs when no register app.
      9. provision-roundtrip -- Mirrors the register app's ApimProvisioner end-to-end via ARM:
                          PUT an ephemeral APIM subscription scoped to a tier product
                          (-ProvisionProduct, default byok-standard) -> listSecrets -> chat 200
                          with the fresh key -> DELETE the subscription. MUTATES APIM (cleaned up
                          in a finally). SKIPs where the smoke identity lacks subscriptions/write
                          (read-only pilots) or via -SkipProvisionProbe.

    Discovery (default): reads `azd env get-values` for the active env so the script
    just works on the runner / locally / in CI. Override any of the discovery values
    via -ResourceGroup / -ApimName / -AppInsightsName.

    Exit codes:
      0 = all assertions PASS.
      1 = any assertion FAIL or any preflight error.
      2 = usage / config error (missing required tool, no env, etc.).

.PARAMETER EnvName
    azd env / GitHub Environment short name (e.g. `comm-pilot`). Defaults to
    AZURE_ENV_NAME env var, then to the current azd default env.

.PARAMETER ResourceGroup
    Azure RG holding APIM + App Insights. Defaults to deployment output / env value.

.PARAMETER ApimName
    APIM instance name. Defaults to deployment output / env value.

.PARAMETER AppInsightsName
    App Insights resource name. Defaults to deployment output / env value.

.PARAMETER PrimaryModel
    Model deployment name to use for the chat probes. Default `gpt-5.1`.

.PARAMETER MiniModel
    Mini model deployment name to require in the model list. Default `gpt-4.1-mini`.

.PARAMETER CommercialOnlyModel
    A model deployed ONLY on the Commercial Foundry (not hosted in Gov). Assertion 3c calls it
    through the gov gateway's /openai-commercial route to prove the cross-cloud path reaches a
    Gov-unavailable model. Default `gpt-5-mini` (a reasoning model).

.PARAMETER OversizedTokens
    Number of PROMPT tokens per request in assertion #5's token burst. The
    token-limit policy's `estimate-prompt-tokens` counts PROMPT tokens on the inbound
    (NOT `max_completion_tokens`) and accumulates them per subscription, so the probe
    sends a burst of moderate, well-formed requests until the product's
    `tokens-per-minute` (byok-standard default 20000 TPM) is spent and the gateway
    returns 429. Default 5000 (a single oversized prompt 400s before the throttle fires).

.PARAMETER SkipTokenLimit
    Skip assertion #5 (some envs intentionally don't configure llm-token-limit;
    treat as "best-effort pass" in those cases).

.PARAMETER ProvisionProduct
    Tier product to scope the assertion #9 provisioning round-trip subscription to.
    Default `byok-standard` (the register app's DefaultProductId / least-privileged tier).

.PARAMETER SkipProvisionProbe
    Skip assertion #9 (the sub-key provisioning round-trip that MUTATES APIM). The probe
    already auto-SKIPs where the identity lacks subscriptions/write; use this to opt out
    entirely (e.g. when you don't want any APIM writes from a smoke run).

.EXAMPLE
    # Standard run (CI):
    .\scripts\smoke-test.ps1

.EXAMPLE
    # Local run targeting comm-pilot explicitly:
    .\scripts\smoke-test.ps1 -EnvName comm-pilot

.EXAMPLE
    # Skip throttle probe (env without llm-token-limit):
    .\scripts\smoke-test.ps1 -SkipTokenLimit

.NOTES
    Requires PowerShell 7+ and Azure CLI logged in to the target subscription.
    The Az identity needs `Reader` on the RG plus `Microsoft.ApiManagement/.../listSecrets/action`
    (Subscription Reader role on APIM) to fetch subscription keys, plus
    Log Analytics Reader to run the KQL. The runner UAMI (#53) has all three.
#>
#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$EnvName,
    [string]$ResourceGroup,
    [string]$ApimName,
    [string]$AppInsightsName,
    [string]$PrimaryModel = 'gpt-5.1',
    [string]$MiniModel    = 'gpt-4.1-mini',
    [string]$CommercialOnlyModel = 'gpt-5-mini',
    [int]   $OversizedTokens = 5000,
    [int]   $TokenBurstMax   = 20,
    [switch]$SkipTokenLimit,
    [string]$ProvisionProduct = 'byok-standard',
    [switch]$SkipProvisionProbe
)

$ErrorActionPreference = 'Stop'
$script:results = @()

function Write-Step  { param([string]$Msg) Write-Host "==> $Msg" -ForegroundColor Cyan }
function Write-Pass  { param([string]$Name, [string]$Detail = '') Write-Host "    [PASS] $Name $Detail" -ForegroundColor Green; $script:results += @{ Name=$Name; Status='PASS'; Detail=$Detail } }
function Write-Fail  { param([string]$Name, [string]$Detail = '') Write-Host "    [FAIL] $Name $Detail" -ForegroundColor Red;   $script:results += @{ Name=$Name; Status='FAIL'; Detail=$Detail } }
function Write-Skip  { param([string]$Name, [string]$Detail = '') Write-Host "    [SKIP] $Name $Detail" -ForegroundColor Yellow; $script:results += @{ Name=$Name; Status='SKIP'; Detail=$Detail } }

# ---------------------------------------------------------------------------
# Setup: resolve env, APIM gateway, dev keys
# ---------------------------------------------------------------------------
Write-Step 'Setup'

if (-not $EnvName) {
    $EnvName = $env:AZURE_ENV_NAME
    if (-not $EnvName) {
        $EnvName = (azd env get-value AZURE_ENV_NAME 2>$null)
    }
}
if (-not $EnvName) {
    Write-Host "ERROR: -EnvName not supplied and AZURE_ENV_NAME / azd default env not set." -ForegroundColor Red
    exit 2
}
Write-Host "    EnvName        = $EnvName"

# Pull discovery from azd env (single source of truth: deployment outputs are written here).
$envValues = @{}
try {
    azd env get-values --output dotenv 2>$null | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z0-9_]+)\s*=\s*"?([^"]*)"?\s*$') { $envValues[$matches[1]] = $matches[2] }
    }
} catch {}

if (-not $ResourceGroup)    { $ResourceGroup    = $envValues['RESOURCE_GROUP']    }
if (-not $ApimName)         { $ApimName         = $envValues['APIM_NAME']         }
if (-not $AppInsightsName)  { $AppInsightsName  = $envValues['APP_INSIGHTS_NAME'] }
if (-not $ResourceGroup)    { $ResourceGroup    = "rg-copilot-byok-$EnvName" }

# Fall back to az resource list if azd outputs weren't populated.
if (-not $ApimName -and $ResourceGroup) {
    $ApimName = az apim list -g $ResourceGroup --query '[0].name' -o tsv 2>$null
}
if (-not $AppInsightsName -and $ResourceGroup) {
    $AppInsightsName = az monitor app-insights component show -g $ResourceGroup --query '[0].name' -o tsv 2>$null
    if (-not $AppInsightsName) {
        $AppInsightsName = (az resource list -g $ResourceGroup --resource-type Microsoft.Insights/components --query '[0].name' -o tsv 2>$null)
    }
}

if (-not $ApimName)        { Write-Host "ERROR: cannot determine APIM name (set -ApimName)." -ForegroundColor Red; exit 2 }
if (-not $AppInsightsName) { Write-Host "ERROR: cannot determine App Insights name (set -AppInsightsName)." -ForegroundColor Red; exit 2 }

# Build gateway URL (works in both Commercial .net and Gov .us, regardless of cloud).
$apimGw = az apim show -g $ResourceGroup -n $ApimName --query 'gatewayUrl' -o tsv
if (-not $apimGw) { Write-Host "ERROR: cannot read APIM gateway URL." -ForegroundColor Red; exit 2 }
Write-Host "    ResourceGroup  = $ResourceGroup"
Write-Host "    ApimName       = $ApimName"
Write-Host "    GatewayUrl     = $apimGw"
Write-Host "    AppInsights    = $AppInsightsName"

# Fetch dev1 + dev2 primary keys via control plane (no plaintext on disk).
# `az apim subscription show` does NOT exist in the current Azure CLI -- and
# there's no `apim` extension that adds it -- so call ARM listSecrets via
# `az rest`. ARM host MUST come from `az cloud show` (#59): hardcoding
# management.azure.com fails on gov, and the silent `az apim subscription`
# failure used to cascade every assertion to SKIP on both clouds.
$armEndpoint = (az cloud show --query 'endpoints.resourceManager' -o tsv 2>$null).TrimEnd('/')
if (-not $armEndpoint) { $armEndpoint = 'https://management.azure.com' }
$subId = az account show --query id -o tsv 2>$null
function Get-DevKey {
    param([string]$Sid)
    if (-not $subId) { throw "Not logged in to az (no subscription)." }
    $url = "$armEndpoint/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/subscriptions/$Sid/listSecrets?api-version=2024-05-01"
    $k = az rest --method POST --url $url --query 'primaryKey' -o tsv 2>$null
    if (-not $k) { throw "Subscription '$Sid' not found on APIM $ApimName. Re-deploy with deployTestSubscriptions=true." }
    return $k
}
$dev1Key = $null; $dev2Key = $null
try { $dev1Key  = Get-DevKey 'dev1'  } catch { Write-Host "WARN: $($_.Exception.Message)" -ForegroundColor Yellow }
try { $dev2Key  = Get-DevKey 'dev2'  } catch { Write-Host "WARN: $($_.Exception.Message)" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Assertion 1: list models. Served by the foundry inference API to ANY valid inference
# key (the dedicated 'discovery' API + 'smoke' subscription were consolidated away), so
# we assert with the normal dev1 tier key.
# ---------------------------------------------------------------------------
Write-Step 'Assertion 1: GET /openai/v1/models'
$assertionName = 'list-models'
if (-not $dev1Key) {
    Write-Skip $assertionName '(no dev1 key)'
} else {
    try {
        $modelsUrl = "$apimGw/openai/v1/models"
        $headers = @{ 'api-key' = $dev1Key }
        # Use Invoke-WebRequest so we always capture status + raw body for diagnostics.
        $raw = Invoke-WebRequest -Method Get -Uri $modelsUrl -Headers $headers -TimeoutSec 30 -SkipHttpErrorCheck -ErrorAction Stop
        $status = $raw.StatusCode
        $bodyText = [string]$raw.Content
        $resp = try { $bodyText | ConvertFrom-Json -ErrorAction Stop } catch { $null }
        $ids = @($resp.data | ForEach-Object { $_.id })
        $hasPrimary = $ids -contains $PrimaryModel
        $hasMini    = $ids -contains $MiniModel
        if ($hasPrimary -and $hasMini) {
            Write-Pass $assertionName "(HTTP $status; found $($ids.Count) models incl. $PrimaryModel + $MiniModel)"
        } else {
            $snippet = if ($bodyText.Length -gt 400) { $bodyText.Substring(0,400) } else { $bodyText }
            $snippet = ($snippet -replace '\s+',' ')
            Write-Fail $assertionName "(HTTP $status; expected $PrimaryModel + $MiniModel; got ids: '$($ids -join ',')'; body[0:400]='$snippet')"
        }
    } catch {
        Write-Fail $assertionName "($($_.Exception.Message))"
    }
}

# ---------------------------------------------------------------------------
# Assertions 2 & 3: chat completions with each dev key
# ---------------------------------------------------------------------------
function Test-ChatCompletion {
    param([string]$Sid, [string]$Key)
    $name = "chat-$Sid"
    if (-not $Key) { Write-Skip $name '(no key available)'; return }
    try {
        $url = "$apimGw/openai/v1/chat/completions"
        $headers = @{ 'api-key' = $Key }
        $body = @{
            model = $PrimaryModel
            messages = @(@{ role = 'user'; content = 'Reply with the single word: pong.' })
            max_completion_tokens = 50
        } | ConvertTo-Json -Depth 6 -Compress
        $resp = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 60
        $content = ($resp.choices[0].message.content -replace '\s+',' ').Trim()
        if ($content) {
            $snippet = if ($content.Length -gt 40) { $content.Substring(0,40) + '...' } else { $content }
            Write-Pass $name "(model=$($resp.model); reply='$snippet')"
        } else {
            Write-Fail $name "(200 but empty content)"
        }
    } catch {
        $code = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { 'n/a' }
        Write-Fail $name "(HTTP $code; $($_.Exception.Message))"
    }
}
Write-Step 'Assertion 2: chat completions with dev1 key'
Test-ChatCompletion 'dev1' $dev1Key
Write-Step 'Assertion 3: chat completions with dev2 key'
Test-ChatCompletion 'dev2' $dev2Key

# ---------------------------------------------------------------------------
# Assertion 3b: commercial route (/openai-commercial -> Commercial Foundry)
# Only meaningful where the parallel route is deployed (deployFoundryCommercial=true, e.g. the gov
# envs). 404 = route not on this env -> SKIP (comm-* and gov with it off). 200 = the cross-cloud
# path (caller key -> strip -> commercial SP token -> Commercial Foundry) works. Anything else
# (e.g. 502 CommercialTokenFederationFailed / CommercialTokenAcquisitionFailed) = deployed but the
# backend auth / firewall / egress is broken -> FAIL. Exception: a 403 firewall rejection is a
# soft-fail (SKIP) on ephemeral dev envs (NAT egress IP rotates on teardown/reprovision and falls
# off the Commercial Foundry allowlist); still FAIL on stable pilots.
# ---------------------------------------------------------------------------
function Test-CommercialRoute {
    param([string]$Key)
    $name = 'commercial-route'
    if (-not $Key) { Write-Skip $name '(no dev1 key)'; return }
    try {
        $url = "$apimGw/openai-commercial/v1/chat/completions"
        $headers = @{ 'api-key' = $Key }
        $body = @{
            model = $PrimaryModel
            messages = @(@{ role = 'user'; content = 'Reply with the single word: pong.' })
            max_completion_tokens = 50
        } | ConvertTo-Json -Depth 6 -Compress
        $raw = Invoke-WebRequest -Method Post -Uri $url -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 60 -SkipHttpErrorCheck -ErrorAction Stop
        $status = $raw.StatusCode
        if ($status -eq 404) {
            Write-Skip $name '(/openai-commercial not deployed on this env)'
        } elseif ($status -eq 200) {
            $resp = try { $raw.Content | ConvertFrom-Json -ErrorAction Stop } catch { $null }
            $content = ($resp.choices[0].message.content -replace '\s+',' ').Trim()
            if ($content) {
                $snippet = if ($content.Length -gt 40) { $content.Substring(0,40) + '...' } else { $content }
                Write-Pass $name "(model=$($resp.model); reply='$snippet')"
            } else {
                Write-Fail $name '(200 but empty content)'
            }
        } elseif ($status -eq 403) {
            # 403 "Access denied due to Virtual Network/Firewall rules" = the Commercial Foundry
            # firewall rejected this env's NAT egress IP. Ephemeral dev envs get a NEW NAT public IP
            # on every teardown/reprovision, so their egress IP falls off the allowlist -> expected
            # -> SKIP (soft-fail). On stable pilots a 403 is a real firewall break -> FAIL.
            if ($EnvName -like '*-dev') {
                Write-Skip $name '(HTTP 403 firewall; ephemeral dev NAT egress IP not on the Commercial Foundry allowlist -- expected after teardown/reprovision, NAT IP rotates)'
            } else {
                $snippet = if ($raw.Content.Length -gt 200) { $raw.Content.Substring(0,200) } else { $raw.Content }
                Write-Fail $name "(HTTP 403; body=$snippet)"
            }
        } else {
            $snippet = if ($raw.Content.Length -gt 200) { $raw.Content.Substring(0,200) } else { $raw.Content }
            Write-Fail $name "(HTTP $status; body=$snippet)"
        }
    } catch {
        Write-Fail $name "($($_.Exception.Message))"
    }
}
Write-Step 'Assertion 3b: commercial route (/openai-commercial -> Commercial Foundry)'
Test-CommercialRoute $dev1Key

# ---------------------------------------------------------------------------
# Assertion 3c: commercial-only model over the commercial route
# Exercises the cross-cloud route with a model that exists ONLY on the Commercial Foundry (e.g.
# gpt-5-mini), which Gov does not host. A 200 whose echoed .model matches proves the gov gateway
# routed to the Commercial backend AND served a Gov-unavailable model. Reuses 3b response-code
# semantics: 404 -> SKIP; 403 firewall reject -> SKIP on ephemeral dev, FAIL on pilots; other
# non-200 -> FAIL. gpt-5-mini is a reasoning model, so the budget is generous and the assertion
# checks the echoed model name (content may be empty when reasoning consumes the budget).
# ---------------------------------------------------------------------------
function Test-CommercialOnlyModel {
    param([string]$Key)
    $name = 'commercial-only-model'
    if (-not $Key) { Write-Skip $name '(no dev1 key)'; return }
    if (-not $CommercialOnlyModel) { Write-Skip $name '(no commercial-only model configured)'; return }
    try {
        $url = "$apimGw/openai-commercial/v1/chat/completions"
        $headers = @{ 'api-key' = $Key }
        $body = @{
            model = $CommercialOnlyModel
            messages = @(@{ role = 'user'; content = 'Reply with the single word: pong.' })
            max_completion_tokens = 400
        } | ConvertTo-Json -Depth 6 -Compress
        $raw = Invoke-WebRequest -Method Post -Uri $url -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 60 -SkipHttpErrorCheck -ErrorAction Stop
        $status = $raw.StatusCode
        if ($status -eq 404) {
            Write-Skip $name '(/openai-commercial not deployed on this env)'
        } elseif ($status -eq 200) {
            $resp = try { $raw.Content | ConvertFrom-Json -ErrorAction Stop } catch { $null }
            $model = [string]$resp.model
            if ($model -like "$CommercialOnlyModel*") {
                Write-Pass $name "(model=$model; Gov-unavailable model served via commercial route)"
            } else {
                Write-Fail $name "(200 but echoed model='$model', expected '$CommercialOnlyModel*')"
            }
        } elseif ($status -eq 403) {
            if ($EnvName -like '*-dev') {
                Write-Skip $name '(HTTP 403 firewall; ephemeral dev NAT egress IP not on the Commercial Foundry allowlist -- expected after teardown/reprovision, NAT IP rotates)'
            } else {
                $snippet = if ($raw.Content.Length -gt 200) { $raw.Content.Substring(0,200) } else { $raw.Content }
                Write-Fail $name "(HTTP 403; body=$snippet)"
            }
        } else {
            $snippet = if ($raw.Content.Length -gt 200) { $raw.Content.Substring(0,200) } else { $raw.Content }
            Write-Fail $name "(HTTP $status; body=$snippet)"
        }
    } catch {
        Write-Fail $name "($($_.Exception.Message))"
    }
}
Write-Step "Assertion 3c: commercial-only model ($CommercialOnlyModel) over the commercial route"
Test-CommercialOnlyModel $dev1Key

# ---------------------------------------------------------------------------
# Assertion 4: emit-metric is flowing (the #16 gate)
# ---------------------------------------------------------------------------
Write-Step 'Assertion 4: customMetrics emit-metric flow (KQL)'
$assertionName = 'emit-metric'
try {
    # App Insights ID = the resource ID, not the instrumentation key.
    $appId = az monitor app-insights component show -g $ResourceGroup --app $AppInsightsName --query 'appId' -o tsv 2>$null
    if (-not $appId) { throw "Cannot resolve appId for App Insights '$AppInsightsName'." }
    $kqlPath = Join-Path $PSScriptRoot '..\monitoring\kql\smoke-emit-metric.kql'
    if (-not (Test-Path $kqlPath)) { throw "KQL file not found: $kqlPath" }
    # We POST directly to the App Insights query REST API via `az rest`. The
    # `az monitor app-insights query` CLI extension is unusable for this:
    #   - Multi-line bodies silently drop the `| summarize` clause and return
    #     the full unaggregated schema with rows=[] (exit 0, but wrong).
    #   - Single-line bodies return `BadArgumentError: The request had some
    #     invalid properties` with no inner error code.
    # `az rest` exposes the real server-side error (e.g. `SEM0100 ... itemCount`)
    # which is how we caught the wrong-column-name bug behind #60. The endpoint
    # hostname is cloud-aware via `az cloud show --query endpoints.appInsightsResourceId`.
    $aiApi = az cloud show --query 'endpoints.appInsightsResourceId' -o tsv
    if (-not $aiApi) { throw 'Cannot resolve cloud endpoints.appInsightsResourceId.' }
    # Strip `//` line comments and blank lines (smaller request body, easier to debug).
    $kql = ((Get-Content $kqlPath) | Where-Object { $_ -notmatch '^\s*(//|$)' }) -join "`n"
    $bodyFile = New-TemporaryFile
    @{ query = $kql } | ConvertTo-Json -Compress | Set-Content -Path $bodyFile.FullName -NoNewline
    try {
        # APIM `emit-metric` flows via the appinsights logger with isBuffered:true,
        # then through AI's ingestion pipeline. Measured end-to-end latency from
        # policy emit to customMetrics queryability is ~75-100s typical; we allow
        # up to ~3 min before declaring the metrics pipeline broken. Poll every 15s
        # so we return as soon as ingestion lands rather than always blocking the
        # full deadline.
        $deadline = (Get-Date).AddSeconds(480)
        $hits = 0; $latest = ''; $distinct = 0; $cliExit = 0; $json = $null
        while ((Get-Date) -lt $deadline) {
            $json = az rest --method post --url "$aiApi/v1/apps/$appId/query" --headers 'Content-Type=application/json' --body "@$($bodyFile.FullName)" --resource $aiApi -o json 2>&1
            $cliExit = $LASTEXITCODE
            if ($cliExit -ne 0 -or -not $json) { break }
            $row = ("$json" | ConvertFrom-Json).tables[0].rows[0]
            if ($row) {
                $hits = [int]$row[0]; $latest = $row[1]; $distinct = [int]$row[2]
                if ($hits -gt 0) { break }
            }
            Start-Sleep -Seconds 15
        }
    } finally {
        Remove-Item -Path $bodyFile.FullName -ErrorAction SilentlyContinue
    }
    if ($cliExit -ne 0 -or -not $json) {
        $errStr = "$json"
        $errMsg = $errStr.Substring(0, [Math]::Min(400, $errStr.Length))
        throw "az rest exit=$cliExit; err: $errMsg"
    }
    if ($hits -gt 0) {
        Write-Pass $assertionName "(hits=$hits, distinctMetricNames=$distinct, latestEmit=$latest)"
    } else {
        Write-Fail $assertionName "(hits=0 after 480s polling -- check APIM diagnostic metrics:true (#16) AND that this run actually fired chat assertions before assertion 4)"
    }
} catch {
    Write-Fail $assertionName "($($_.Exception.Message))"
}

# ---------------------------------------------------------------------------
# Assertion 5: token burst -> 429 from llm-token-limit
# ---------------------------------------------------------------------------
Write-Step "Assertion 5: token burst -> 429 (llm-token-limit)"
$assertionName = 'token-limit'
if ($SkipTokenLimit) {
    Write-Skip $assertionName '(-SkipTokenLimit set)'
} else {
    try {
        $url = "$apimGw/openai/v1/chat/completions"
        $headers = @{ 'api-key' = ($dev1Key ?? $dev2Key) }
        if (-not $headers['api-key']) { throw 'No dev key to use for throttle probe.' }
        # The token-limit policy's estimate-prompt-tokens counts PROMPT tokens on the
        # inbound and accumulates them against a per-subscription counter -- it does NOT
        # pre-count max_completion_tokens (completion is only tallied from the backend
        # response). A single huge prompt is too large for the gateway to buffer/parse
        # (the backend 400s with ModelNotSpecified before the throttle fires), so send a
        # BURST of moderate, well-formed requests until the product's tokens-per-minute
        # budget is spent and the gateway returns 429.
        $bigPrompt = ('token ' * $OversizedTokens)
        $body = @{
            model = $PrimaryModel
            messages = @(@{ role = 'user'; content = $bigPrompt })
            max_completion_tokens = 16
        } | ConvertTo-Json -Depth 6 -Compress
        $resp = $null
        for ($i = 1; $i -le $TokenBurstMax; $i++) {
            # Use Invoke-WebRequest so we can read the status even on 4xx.
            $resp = Invoke-WebRequest -Method Post -Uri $url -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 30 -SkipHttpErrorCheck
            if ($resp.StatusCode -eq 429) { break }
            if ($resp.StatusCode -ne 200) { break }
        }
        if ($resp.StatusCode -eq 429) {
            Write-Pass $assertionName "(HTTP 429 after burst, retry-after=$($resp.Headers['Retry-After'] -join ','))"
        } else {
            Write-Fail $assertionName "(expected 429 from token burst vs product TPM, got HTTP $($resp.StatusCode) after up to ${TokenBurstMax}x ~$OversizedTokens-token reqs)"
        }
    } catch {
        Write-Fail $assertionName "($($_.Exception.Message))"
    }
}

# ---------------------------------------------------------------------------
# Assertion 6: register app reachable (best-effort; opt-in deployRegisterApp envs)
# ---------------------------------------------------------------------------
Write-Step 'Assertion 6: register app health (best-effort)'
$assertionName = 'register-app'
# The register app (#64) is opt-in: only present when the env was provisioned with
# deployRegisterApp=true. Discover its URL from the azd output, else from the ACA app
# tagged azd-service-name=register. SKIP (not FAIL) when the env has no register app.
$registerUrl = $envValues['REGISTER_APP_URL']
if (-not $registerUrl -and $ResourceGroup) {
    $registerFqdn = az containerapp list -g $ResourceGroup --query "[?tags.\"azd-service-name\"=='register'].properties.configuration.ingress.fqdn | [0]" -o tsv 2>$null
    if ($registerFqdn) { $registerUrl = "https://$registerFqdn" }
}
if (-not $registerUrl) {
    Write-Skip $assertionName '(no register app in this env)'
} else {
    try {
        # Easy Auth (RedirectToLoginPage) answers /healthz with a 302 to the login page when
        # auth is on, or 200 when it is the pre-auth placeholder. Either proves the app is up
        # and serving; only a 5xx / connection failure is a real failure. Don't follow the
        # redirect (we're probing liveness, not completing a login).
        $probe = Invoke-WebRequest -Method Get -Uri "$($registerUrl.TrimEnd('/'))/healthz" -TimeoutSec 30 -SkipHttpErrorCheck -MaximumRedirection 0 -ErrorAction Stop
        $code = [int]$probe.StatusCode
        if ($code -in 200, 302, 401, 403) {
            Write-Pass $assertionName "(HTTP $code from $registerUrl)"
        } else {
            Write-Fail $assertionName "(HTTP $code from $registerUrl; expected 200/302/401/403)"
        }
    } catch {
        Write-Fail $assertionName "($($_.Exception.Message))"
    }
}

# ---------------------------------------------------------------------------
# Assertion 7: register app Easy Auth enforcement (best-effort)
# ---------------------------------------------------------------------------
Write-Step 'Assertion 7: register Easy Auth enforcement (unauth must be denied)'
$assertionName = 'register-auth'
if (-not $registerUrl) {
    Write-Skip $assertionName '(no register app in this env)'
} else {
    try {
        # POST /api/register WITHOUT a token. With Easy Auth on (RedirectToLoginPage) the
        # platform returns 302 to the login page BEFORE the app runs; with Easy Auth not yet
        # attached the app's own check returns 401. Either way provisioning is denied. A 2xx
        # would mean the privileged endpoint is anonymously reachable -> hard FAIL.
        $probe = Invoke-WebRequest -Method Post -Uri "$($registerUrl.TrimEnd('/'))/api/register" `
            -Body '{}' -ContentType 'application/json' -TimeoutSec 30 -SkipHttpErrorCheck -MaximumRedirection 0 -ErrorAction Stop
        $code = [int]$probe.StatusCode
        if ($code -eq 302) {
            Write-Pass $assertionName '(HTTP 302 -> Easy Auth login enforced)'
        } elseif ($code -in 401, 403) {
            Write-Pass $assertionName "(HTTP $code -> provisioning denied; Easy Auth may not be attached yet)"
        } elseif ($code -in 200, 201) {
            Write-Fail $assertionName "(HTTP $code -> /api/register reachable ANONYMOUSLY; Easy Auth not enforcing)"
        } else {
            Write-Fail $assertionName "(HTTP $code from /api/register; expected 302/401/403)"
        }
    } catch {
        Write-Fail $assertionName "($($_.Exception.Message))"
    }
}

# ---------------------------------------------------------------------------
# Assertion 8: register provisioning RBAC wired (best-effort; control-plane)
# ---------------------------------------------------------------------------
Write-Step 'Assertion 8: register UAMI has the custom APIM subscription role'
$assertionName = 'register-rbac'
# Prefer the azd output (clientId), but fall back to discovering the UAMI by its deterministic
# name (id-<prefix>-register-<env>-<suffix>) so the assertion still runs when the smoke job's
# azd env lacks the output. A register-less env has no such identity -> SKIP (not FAIL).
$registerUamiClientId = $envValues['REGISTER_UAMI_CLIENT_ID']
$uamiPrincipalId = $null
if ($registerUamiClientId) {
    $uamiPrincipalId = az identity list -g $ResourceGroup --query "[?clientId=='$registerUamiClientId'].principalId | [0]" -o tsv 2>$null
}
if (-not $uamiPrincipalId) {
    $uamiPrincipalId = az identity list -g $ResourceGroup --query "[?contains(name, '-register-')].principalId | [0]" -o tsv 2>$null
}
if (-not $uamiPrincipalId) {
    Write-Skip $assertionName '(no register app in this env)'
} else {
    try {
        $apimId = az apim show -g $ResourceGroup -n $ApimName --query id -o tsv 2>$null
        if (-not $apimId) {
            Write-Skip $assertionName '(cannot resolve APIM id)'
        } else {
            # List assignments AT the APIM scope and match the custom role by name. Reader on the
            # RG (which the runner UAMI has) includes Microsoft.Authorization/roleAssignments/read.
            $roles = az role assignment list --scope $apimId --query "[?principalId=='$uamiPrincipalId'].roleDefinitionName" -o tsv 2>$null
            if ($roles -match 'BYOK Register Subscription Manager') {
                Write-Pass $assertionName '(custom role assigned at APIM scope)'
            } else {
                Write-Fail $assertionName "(register UAMI has no 'BYOK Register Subscription Manager' role at APIM scope; got: '$($roles -replace "`n",', ')')"
            }
        }
    } catch {
        Write-Fail $assertionName "($($_.Exception.Message))"
    }
}

# ---------------------------------------------------------------------------
# Assertion 9: sub-key provisioning round-trip (best-effort; MUTATES APIM)
# ---------------------------------------------------------------------------
Write-Step 'Assertion 9: provision a sub key -> chat -> revoke (register app path)'
$assertionName = 'provision-roundtrip'
if ($SkipProvisionProbe) {
    Write-Skip $assertionName '(-SkipProvisionProbe set)'
} elseif (-not $subId) {
    Write-Skip $assertionName '(no subscription context)'
} else {
    $probeSid = 'smoke-prov-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $apimId = az apim show -g $ResourceGroup -n $ApimName --query id -o tsv 2>$null
    $subBase = "$armEndpoint/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/subscriptions/$probeSid"
    $created = $false
    try {
        # Mirror the register app's ApimProvisioner.EnsureSubscriptionAsync: PUT a subscription
        # scoped to a tier PRODUCT. Needs subscriptions/write -- the register UAMI and the dev
        # runner (Contributor) have it; a read-only pilot smoke identity gets 403 -> SKIP.
        $putBody = @{ properties = @{ scope = "$apimId/products/$ProvisionProduct"; displayName = 'smoke provision probe'; state = 'active' } } | ConvertTo-Json -Depth 6 -Compress
        $putErr = az rest --method PUT --url "${subBase}?api-version=2024-05-01" --headers 'Content-Type=application/json' --body $putBody -o none 2>&1
        if ($LASTEXITCODE -ne 0) {
            if ("$putErr" -match '403|Authorization|Forbidden') {
                Write-Skip $assertionName "(identity lacks subscriptions/write -> $ProvisionProduct)"
            } else {
                $em = "$putErr"; Write-Fail $assertionName "(create sub failed: $($em.Substring(0, [Math]::Min(300, $em.Length))))"
            }
        } else {
            $created = $true
            $provKey = $null
            for ($i = 0; $i -lt 6 -and -not $provKey; $i++) {
                $provKey = az rest --method POST --url "$subBase/listSecrets?api-version=2024-05-01" --query primaryKey -o tsv 2>$null
                if (-not $provKey) { Start-Sleep -Seconds 3 }
            }
            if (-not $provKey) {
                Write-Fail $assertionName "(provisioned '$probeSid' but listSecrets returned no key)"
            } else {
                # Use the freshly provisioned key on the gateway. Key activation can lag a few
                # seconds, so retry the chat briefly on 401/403.
                $url = "$apimGw/openai/v1/chat/completions"
                $body = @{ model = $PrimaryModel; messages = @(@{ role = 'user'; content = 'Reply with the single word: pong.' }); max_completion_tokens = 16 } | ConvertTo-Json -Depth 6 -Compress
                $status = 0; $ok = $false
                for ($i = 0; $i -lt 6 -and -not $ok; $i++) {
                    $r = Invoke-WebRequest -Method Post -Uri $url -Headers @{ 'api-key' = $provKey } -ContentType 'application/json' -Body $body -TimeoutSec 60 -SkipHttpErrorCheck
                    $status = [int]$r.StatusCode
                    if ($status -eq 200) { $ok = $true; break }
                    if ($status -in 401, 403) { Start-Sleep -Seconds 3; continue }
                    break
                }
                if ($ok) {
                    Write-Pass $assertionName "(provisioned '$probeSid' on $ProvisionProduct; chat HTTP 200)"
                } else {
                    Write-Fail $assertionName "(provisioned key chat returned HTTP $status; expected 200)"
                }
            }
        }
    } catch {
        Write-Fail $assertionName "($($_.Exception.Message))"
    } finally {
        if ($created) {
            az rest --method DELETE --url "${subBase}?api-version=2024-05-01" -o none 2>$null | Out-Null
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Step 'Summary'
$pass = ($script:results | Where-Object Status -eq 'PASS').Count
$fail = ($script:results | Where-Object Status -eq 'FAIL').Count
$skip = ($script:results | Where-Object Status -eq 'SKIP').Count
$script:results | ForEach-Object {
    $color = switch ($_.Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
    Write-Host ("    {0,-4} {1,-14} {2}" -f $_.Status, $_.Name, $_.Detail) -ForegroundColor $color
}
Write-Host ''
Write-Host ("    Total: {0} PASS, {1} FAIL, {2} SKIP" -f $pass, $fail, $skip) -ForegroundColor Cyan
if ($fail -gt 0) {
    Write-Host '    Smoke test FAILED.' -ForegroundColor Red
    exit 1
}
Write-Host '    Smoke test PASSED.' -ForegroundColor Green
exit 0
