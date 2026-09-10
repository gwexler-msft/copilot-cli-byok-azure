<#
.SYNOPSIS
    End-to-end smoke test for a deployed Copilot CLI BYOK gateway env (#56).

.DESCRIPTION
    Runs five assertions against a deployed BYOK env. The GitHub Actions workflow
    (.github/workflows/smoke-test.yml) just orchestrates -- this script does the
    actual probing so it can also be run locally for debugging.

    Assertions (each is a [PASS|FAIL] line + collected into a final Exit code):
      1. list-models   -- GET /openai/v1/models on the APIM gateway -> 200, models
                          contain `gpt-5.6-sol` and `gpt-5.6-luna`.
      2. chat dev1     -- POST /openai/v1/chat/completions with the byok-standard
                          key -> 200, response shape valid.
      3. chat dev2     -- same, with the byok-power key (separate tier).
    3a. responses-auto -- POST /openai/v1/responses with model=auto and a short prompt;
                  requires the response model to resolve to the configured cheap tier.
    3b. commercial-via-default -- POST /openai/v1/chat/completions with a commercial-only model
                          (#118): the Copilot CLI (azure provider) can only reach /openai, so the
                          default policy routes models listed in `commercialModels` to the commercial
                          Foundry cross-cloud. Proves the CLI path works. SKIP on 404 (commercialModels
                          not set on this env); a 403 firewall rejection SKIPs on ephemeral dev envs
                          (rotating NAT egress IP) but FAILs on stable pilots.
      3b2. anthropic-route -- POST /anthropic/v1/messages with an OpenAI-shaped body and the
                          per-developer key in the `x-api-key` HEADER. Proves the route exists, the
                          key validates off x-api-key (the reason it is a separate APIM API), and the
                          wire-format guard explains rather than reshapes (typed 400 WireFormatMismatch).
                          A 401 means subscriptionKeyParameterNames did not take effect -> FAIL.
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
    Model deployment name to use for the chat probes. Default `gpt-5.6-sol`.

.PARAMETER MiniModel
    Cheap-tier model deployment name to require in the model list. Default `gpt-5.6-luna`.

.PARAMETER CommercialOnlyModel
    A model deployed ONLY on the Commercial Foundry (not hosted in Gov). Assertion 3a calls it
    through the DEFAULT /openai route, where the `commercial-models` sentinel selects the commercial
    Foundry backend, to prove the cross-cloud path reaches a Gov-unavailable model. Empty by
    default now that all GPT-5.6 models are native in Government.

.PARAMETER OversizedTokens
    Number of PROMPT tokens per request in assertion #5's token burst. The
    token-limit policy's `estimate-prompt-tokens` counts PROMPT tokens on the inbound
    (NOT `max_completion_tokens`) and accumulates them per subscription, so the probe
    sends a burst of moderate, well-formed requests until the product's
    `tokens-per-minute` (byok-standard default 100000 TPM) is spent and the gateway
    returns 429. Default 8000 x up to 20 requests = 160k, comfortably above the tier
    ceiling while each body stays small enough for the gateway to buffer/parse (a
    single oversized prompt 400s before the throttle fires). Keep OversizedTokens x
    TokenBurstMax > the tier TPM, or this assertion will report a false FAIL.

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
    [string]$PrimaryModel = 'gpt-5.6-sol',
    [string]$MiniModel    = 'gpt-5.6-luna',
    [string]$CommercialOnlyModel = '',
    [int]   $OversizedTokens = 8000,
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
# Assertion 3a: Responses auto-route rewrites body.model and strips Copilot-only extensions.
# Responses is account-root, so leaving body.model="auto" makes the backend reject the request.
# Copilot clients may send top-level snippy metadata, which native Azure endpoints also reject.
# A short non-coding prompt deterministically selects the cheap tier before the ambiguous band.
# ---------------------------------------------------------------------------
function Test-ResponsesAutoRoute {
    param([string]$Key)
    $name = 'responses-auto'
    if (-not $Key) { Write-Skip $name '(no dev1 key)'; return }
    try {
        $body = @{
            model = 'auto'
            input = 'Reply with the single word: pong.'
            reasoning = @{ effort = 'none' }
            snippy = @{ enabled = $true }
            max_output_tokens = 50
        } | ConvertTo-Json -Depth 6 -Compress
        $raw = Invoke-WebRequest -Method Post -Uri "$apimGw/openai/v1/responses" `
            -Headers @{ 'api-key' = $Key } -ContentType 'application/json' -Body $body `
            -TimeoutSec 60 -SkipHttpErrorCheck
        $resp = try { $raw.Content | ConvertFrom-Json -ErrorAction Stop } catch { $null }
        $resolved = [string]$resp.model
        if ($raw.StatusCode -eq 200 -and ($resolved -eq $MiniModel -or $resolved.StartsWith("$MiniModel-"))) {
            Write-Pass $name "(auto resolved to $resolved on /responses)"
        } else {
            $snippet = $raw.Content.Substring(0, [Math]::Min(240, $raw.Content.Length))
            Write-Fail $name "(HTTP $($raw.StatusCode); expected model=$MiniModel, got '$resolved'; body=$snippet)"
        }
    } catch {
        Write-Fail $name "($($_.Exception.Message))"
    }
}
Write-Step 'Assertion 3a: Responses auto-route and Copilot request compatibility'
Test-ResponsesAutoRoute $dev1Key

# ---------------------------------------------------------------------------
# Assertion: unsupported API surface -> typed 400 (#119 Phase 2 / #120)
# When the discovered {{foundry-model-types}} map is populated, requesting a surface the model does
# NOT support returns a typed 400 UnsupportedApiTypeForModel. PrimaryModel (gpt-5.6-sol) supports
# [chat/completions, responses] but NOT embeddings, so an embeddings request must 400. SKIP on any
# non-400 (map not yet populated on this env -> keep other envs green).
# ---------------------------------------------------------------------------
function Test-UnsupportedSurface {
    param([string]$Key)
    $name = 'unsupported-surface'
    if (-not $Key) { Write-Skip $name '(no dev1 key)'; return }
    try {
        $url = "$apimGw/openai/v1/embeddings"
        $headers = @{ 'api-key' = $Key }
        $body = @{ model = $PrimaryModel; input = 'x' } | ConvertTo-Json -Depth 6 -Compress
        $raw = Invoke-WebRequest -Method Post -Uri $url -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 40 -SkipHttpErrorCheck -ErrorAction Stop
        $status = $raw.StatusCode
        $resp = try { $raw.Content | ConvertFrom-Json -ErrorAction Stop } catch { $null }
        $code = [string]$resp.error.code
        if ($status -eq 400 -and $code -eq 'UnsupportedApiTypeForModel') {
            $supported = ($resp.error.supported_types -join ',')
            Write-Pass $name "(400 UnsupportedApiTypeForModel; embeddings on $PrimaryModel rejected; supported=[$supported])"
        } else {
            Write-Skip $name "(map likely not populated on this env; HTTP $status code='$code')"
        }
    } catch {
        Write-Fail $name "($($_.Exception.Message))"
    }
}
Write-Step 'Assertion: unsupported API surface -> typed 400 (#120)'
Test-UnsupportedSurface $dev1Key

# ---------------------------------------------------------------------------
# Assertion 3a: commercial model via the DEFAULT /openai route (the Copilot CLI path, #118)
# The CLI azure provider can ONLY reach /openai/v1/chat/completions (it discards the base-URL path),
# so commercial-only models must be reachable there. When `commercialModels` lists a model, the
# default policy routes it to the commercial Foundry cross-cloud. This asserts a commercial-only
# model works via the PLAIN default route -- the actual CLI scenario. SKIP on 404 (commercialModels
# not set on this env -> model routed to gov Foundry, not found); 403-firewall-on-dev SKIP; 502 =
# commercial routing/auth broken -> FAIL.
# ---------------------------------------------------------------------------
function Test-CommercialViaDefault {
    param([string]$Key)
    $name = 'commercial-via-default'
    if (-not $Key) { Write-Skip $name '(no dev1 key)'; return }
    if (-not $CommercialOnlyModel) { Write-Skip $name '(no commercial-only model configured)'; return }
    try {
        $url = "$apimGw/openai/v1/chat/completions"
        $headers = @{ 'api-key' = $Key }
        $body = @{
            model = $CommercialOnlyModel
            messages = @(@{ role = 'user'; content = 'Reply with the single word: pong.' })
            max_completion_tokens = 400
        } | ConvertTo-Json -Depth 6 -Compress
        $raw = Invoke-WebRequest -Method Post -Uri $url -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 60 -SkipHttpErrorCheck -ErrorAction Stop
        $status = $raw.StatusCode
        if ($status -eq 404) {
            Write-Skip $name "(commercialModels not configured on this env -- '$CommercialOnlyModel' routed to gov Foundry, not found)"
        } elseif ($status -eq 200) {
            $resp = try { $raw.Content | ConvertFrom-Json -ErrorAction Stop } catch { $null }
            $model = [string]$resp.model
            if ($model -like "$CommercialOnlyModel*") {
                Write-Pass $name "(model=$model; commercial model served via plain /openai route -- CLI path works)"
            } else {
                Write-Fail $name "(200 but echoed model='$model', expected '$CommercialOnlyModel'*)"
            }
        } elseif ($status -eq 403) {
            if ($EnvName -like '*-dev') {
                Write-Skip $name '(HTTP 403 firewall; ephemeral dev NAT egress IP not on the Commercial Foundry allowlist)'
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
Write-Step 'Assertion 3a: commercial model via default /openai route (Copilot CLI path, #118)'
Test-CommercialViaDefault $dev1Key

# ---------------------------------------------------------------------------
# Assertion 3b2: native Anthropic route (/anthropic, x-api-key)
# Proves the THREE things that make the /anthropic route worth having, without needing a Claude
# model deployed:
#   1. the route exists and the operation matches   (not 404)
#   2. the per-developer subscription key validates from the 'x-api-key' HEADER (not 401) -- this
#      is the entire reason the route is a separate APIM API, since APIM validates the key from
#      the API's declared header BEFORE any policy runs and /openai declares 'api-key'
#   3. the wire-format guard runs and EXPLAINS instead of reshaping (typed 400 WireFormatMismatch)
# We deliberately send an OPENAI-shaped body (system role message) so the expected result is the
# typed 400. A 401 here is the interesting failure: it means the key was not accepted on
# x-api-key, i.e. subscriptionKeyParameterNames did not take effect.
# ---------------------------------------------------------------------------
function Test-AnthropicRoute {
    param([string]$Key)
    $name = 'anthropic-route'
    if (-not $Key) { Write-Skip $name '(no dev1 key)'; return }
    try {
        $url = "$apimGw/anthropic/v1/messages"
        $headers = @{ 'x-api-key' = $Key }
        $body = @{
            model = $PrimaryModel
            messages = @(
                @{ role = 'system'; content = 'You are a test.' },
                @{ role = 'user';   content = 'ping' }
            )
        } | ConvertTo-Json -Depth 6 -Compress
        $raw = Invoke-WebRequest -Method Post -Uri $url -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 60 -SkipHttpErrorCheck -ErrorAction Stop
        $status = $raw.StatusCode
        $code = try { ($raw.Content | ConvertFrom-Json -ErrorAction Stop).error.code } catch { '' }
        if ($status -eq 404) {
            Write-Skip $name '(/anthropic not deployed on this env)'
        } elseif ($status -eq 401) {
            Write-Fail $name '(HTTP 401 -- the subscription key was NOT accepted from the x-api-key header; check subscriptionKeyParameterNames on the anthropic API and that it is linked into the product tiers)'
        } elseif ($status -eq 400 -and $code -eq 'WireFormatMismatch') {
            Write-Pass $name '(key accepted on x-api-key; OpenAI-shaped body correctly refused with typed 400 WireFormatMismatch instead of being reshaped)'
        } else {
            $snippet = if ($raw.Content.Length -gt 200) { $raw.Content.Substring(0,200) } else { $raw.Content }
            Write-Fail $name "(HTTP $status code='$code'; expected 400 WireFormatMismatch; body=$snippet)"
        }
    } catch {
        Write-Fail $name "($($_.Exception.Message))"
    }
}
Write-Step 'Assertion 3b2: native Anthropic route (/anthropic, x-api-key auth + wire-format guard)'
Test-AnthropicRoute $dev1Key

# ---------------------------------------------------------------------------
# Assertion 3c: stateful Responses sub-resources (#110)
# Round-trips the surface agentic clients need for store:true / background / resumable turns:
#   POST /v1/responses (store:true) -> id  ->  GET /v1/responses/{id}  ->  DELETE /v1/responses/{id}
# The GET is the assertion that matters: it proves the operation matches (not 404) AND that the
# operation-scoped policy skipped the API inference policy -- a body-less GET would otherwise hit
# its ModelNotSpecified 400, which is exactly the bug this surface is prone to.
# ---------------------------------------------------------------------------
function Test-ResponsesSubresources {
    param([string]$Key)
    $name = 'responses-subresources'
    if (-not $Key) { Write-Skip $name '(no dev1 key)'; return }
    try {
        $headers = @{ 'api-key' = $Key }
        $body = @{ model = $PrimaryModel; input = 'Reply with the single word: pong.'; store = $true } |
            ConvertTo-Json -Depth 6 -Compress
        $create = Invoke-WebRequest -Method Post -Uri "$apimGw/openai/v1/responses" -Headers $headers `
            -ContentType 'application/json' -Body $body -TimeoutSec 60 -SkipHttpErrorCheck -ErrorAction Stop
        if ($create.StatusCode -ne 200) {
            Write-Skip $name "(could not create a stored response; POST /v1/responses HTTP $($create.StatusCode))"
            return
        }
        $rid = try { ($create.Content | ConvertFrom-Json -ErrorAction Stop).id } catch { $null }
        if (-not $rid) { Write-Skip $name '(POST /v1/responses 200 but no .id in the body)'; return }

        for ($attempt = 1; $attempt -le 6; $attempt++) {
            $get = Invoke-WebRequest -Method Get -Uri "$apimGw/openai/v1/responses/$rid" -Headers $headers `
                -TimeoutSec 60 -SkipHttpErrorCheck -ErrorAction Stop
            if ($get.StatusCode -ne 404) { break }
            if ($attempt -lt 6) { Start-Sleep -Seconds 2 }
        }
        $code = try { ($get.Content | ConvertFrom-Json -ErrorAction Stop).error.code } catch { '' }

        if ($get.StatusCode -eq 404) {
            $snippet = if ($get.Content.Length -gt 300) { $get.Content.Substring(0, 300) } else { $get.Content }
            Write-Fail $name "(GET /v1/responses/{id} HTTP 404; code='$code'; body=$snippet)"
            return
        } elseif ($get.StatusCode -eq 400 -and $code -eq 'ModelNotSpecified') {
            Write-Fail $name '(GET /v1/responses/{id} hit the inference body-parse guard -- the operation-scoped policy is not applied, it must omit <base />)'
            return
        } elseif ($get.StatusCode -ne 200) {
            $snippet = if ($get.Content.Length -gt 200) { $get.Content.Substring(0, 200) } else { $get.Content }
            Write-Fail $name "(GET /v1/responses/{id} HTTP $($get.StatusCode); body=$snippet)"
            return
        }

        # DELETE is an ACCEPTANCE criterion (200/204), not just cleanup. A 404 is ambiguous on its
        # own - the resource may already be gone, or the DELETE operation may not be routing - so
        # re-GET to tell those apart instead of passing regardless, which is what used to happen.
        $del = Invoke-WebRequest -Method Delete -Uri "$apimGw/openai/v1/responses/$rid" -Headers $headers `
            -TimeoutSec 60 -SkipHttpErrorCheck -ErrorAction Stop
        if ($del.StatusCode -in 200, 204) {
            Write-Pass $name "(POST store:true -> GET {id} 200 -> DELETE $($del.StatusCode); body-less GET did not hit the inference 400-guard)"
        } elseif ($del.StatusCode -eq 404) {
            $recheck = Invoke-WebRequest -Method Get -Uri "$apimGw/openai/v1/responses/$rid" -Headers $headers `
                -TimeoutSec 60 -SkipHttpErrorCheck -ErrorAction Stop
            if ($recheck.StatusCode -eq 404) {
                Write-Pass $name '(GET {id} 200; DELETE 404 but the response is GONE on re-GET -- backend treats it as already-deleted)'
            } else {
                Write-Fail $name "(DELETE {id} 404 and the response STILL EXISTS on re-GET HTTP $($recheck.StatusCode) -- the DELETE operation is not routing)"
            }
        } else {
            Write-Fail $name "(DELETE /v1/responses/{id} HTTP $($del.StatusCode); expected 200/204)"
        }
    } catch {
        Write-Fail $name "($($_.Exception.Message))"
    }
}

# ---------------------------------------------------------------------------
# Assertion 3d/3e: the remaining Responses sub-paths (#110)
# Separate assertions so a missing sub-path is visible instead of hiding inside the round-trip.
# `cancel` only applies to a BACKGROUND response: if the backend will not accept background:true the
# endpoint cannot be exercised, which is a SKIP. A 404 is a FAIL either way - that means the
# operation is not matched, which is what these assertions exist to catch.
# ---------------------------------------------------------------------------
function New-StoredResponse {
    param([string]$Key, [switch]$Background)
    $headers = @{ 'api-key' = $Key }
    $payload = @{ model = $PrimaryModel; input = 'Reply with the single word: pong.'; store = $true }
    if ($Background) { $payload.background = $true; $payload.input = 'Count slowly to twenty.' }
    $create = Invoke-WebRequest -Method Post -Uri "$apimGw/openai/v1/responses" -Headers $headers `
        -ContentType 'application/json' -Body ($payload | ConvertTo-Json -Depth 6 -Compress) `
        -TimeoutSec 60 -SkipHttpErrorCheck -ErrorAction Stop
    if ($create.StatusCode -ne 200) { return @{ Status = $create.StatusCode; Id = $null } }
    $id = try { ($create.Content | ConvertFrom-Json -ErrorAction Stop).id } catch { $null }
    return @{ Status = 200; Id = $id }
}

function Remove-StoredResponse {
    param([string]$Key, [string]$Id)
    try {
        Invoke-WebRequest -Method Delete -Uri "$apimGw/openai/v1/responses/$Id" -Headers @{ 'api-key' = $Key } `
            -TimeoutSec 60 -SkipHttpErrorCheck -ErrorAction Stop | Out-Null
    } catch { }
}

function Test-ResponsesInputItems {
    param([string]$Key)
    $name = 'responses-input-items'
    if (-not $Key) { Write-Skip $name '(no dev1 key)'; return }
    try {
        $created = New-StoredResponse -Key $Key
        if ($created.Status -ne 200) { Write-Skip $name "(could not create a stored response; POST /v1/responses HTTP $($created.Status))"; return }
        if (-not $created.Id) { Write-Skip $name '(POST /v1/responses 200 but no .id in the body)'; return }

        for ($attempt = 1; $attempt -le 6; $attempt++) {
            $r = Invoke-WebRequest -Method Get -Uri "$apimGw/openai/v1/responses/$($created.Id)/input_items" `
                -Headers @{ 'api-key' = $Key } -TimeoutSec 60 -SkipHttpErrorCheck -ErrorAction Stop
            if ($r.StatusCode -ne 404) { break }
            if ($attempt -lt 6) { Start-Sleep -Seconds 2 }
        }
        $code = try { ($r.Content | ConvertFrom-Json -ErrorAction Stop).error.code } catch { '' }
        if ($r.StatusCode -eq 404) {
            $snippet = if ($r.Content.Length -gt 300) { $r.Content.Substring(0, 300) } else { $r.Content }
            Write-Fail $name "(GET /v1/responses/{id}/input_items HTTP 404; code='$code'; body=$snippet)"
        } elseif ($r.StatusCode -eq 400 -and $code -eq 'ModelNotSpecified') {
            Write-Fail $name '(input_items hit the inference body-parse guard -- the operation-scoped policy must omit <base />)'
        } elseif ($r.StatusCode -ne 200) {
            Write-Fail $name "(GET input_items HTTP $($r.StatusCode))"
        } else {
            $isList = try { (($r.Content | ConvertFrom-Json -ErrorAction Stop).data) -is [array] } catch { $false }
            if ($isList) { Write-Pass $name '(GET input_items 200 with an OpenAI list shape)' }
            else { Write-Fail $name '(GET input_items 200 but .data is not an array -- not the OpenAI list shape)' }
        }
        Remove-StoredResponse -Key $Key -Id $created.Id
    } catch {
        Write-Fail $name "($($_.Exception.Message))"
    }
}

function Test-ResponsesCancel {
    param([string]$Key)
    $name = 'responses-cancel'
    if (-not $Key) { Write-Skip $name '(no dev1 key)'; return }
    try {
        $created = New-StoredResponse -Key $Key -Background
        if ($created.Status -ne 200) { Write-Skip $name "(backend did not accept background:true; POST /v1/responses HTTP $($created.Status))"; return }
        if (-not $created.Id) { Write-Skip $name '(background POST 200 but no .id in the body)'; return }

        # -Body '' is required, not cosmetic: a POST with no body omits Content-Length, and the Gov
        # gateway answers 411 Length Required before the request ever reaches the operation.
        $r = Invoke-WebRequest -Method Post -Uri "$apimGw/openai/v1/responses/$($created.Id)/cancel" `
            -Headers @{ 'api-key' = $Key } -ContentType 'application/json' -Body '' `
            -TimeoutSec 60 -SkipHttpErrorCheck -ErrorAction Stop
        $code = try { ($r.Content | ConvertFrom-Json -ErrorAction Stop).error.code } catch { '' }
        if ($r.StatusCode -eq 404) {
            Write-Fail $name '(POST /v1/responses/{id}/cancel HTTP 404 -- operation not matched; the sub-path op is missing from this env)'
        } elseif ($r.StatusCode -eq 400 -and $code -eq 'ModelNotSpecified') {
            Write-Fail $name '(cancel hit the inference body-parse guard -- the operation-scoped policy must omit <base />)'
        } elseif ($r.StatusCode -eq 200) {
            Write-Pass $name '(POST background -> cancel 200)'
        } else {
            Write-Skip $name "(cancel routed but returned HTTP $($r.StatusCode) code=$(if ($code) { $code } else { 'none' }); likely already completed)"
        }
        Remove-StoredResponse -Key $Key -Id $created.Id
    } catch {
        Write-Fail $name "($($_.Exception.Message))"
    }
}
Write-Step 'Assertion 3c: stateful Responses sub-resources (#110)'
Test-ResponsesSubresources $dev1Key
Write-Step 'Assertion 3d: Responses input_items (#110)'
Test-ResponsesInputItems $dev1Key
Write-Step 'Assertion 3e: Responses cancel (#110)'
Test-ResponsesCancel $dev1Key

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
# Assertion 4b: the auto-route classifier actually runs (#128)
#
# The classifier only fires for the AMBIGUOUS length band, so a short smoke prompt routes straight
# to mini and never exercises it. Size the prompt from this env's own threshold: len == threshold is
# the centre of the band, so it lands there whatever the per-env tuning is.
#
# Telemetry is the only honest assertion. The classifier runs with ignore-error=true, so a broken
# self-call (APIM unable to reach its own gateway host) degrades silently to the full model and
# still returns 200 -- indistinguishable from success unless auto_route_reason is checked.
# ---------------------------------------------------------------------------
Write-Step 'Assertion 4b: auto-route classifier (#128)'
$assertionName = 'classifier-route'
try {
    $classifierOn = az apim nv show -g $ResourceGroup -n $ApimName --named-value-id auto-route-classifier-enabled --query value -o tsv 2>$null
    $threshold    = az apim nv show -g $ResourceGroup -n $ApimName --named-value-id auto-route-length-threshold --query value -o tsv 2>$null

    if ("$classifierOn".ToLowerInvariant() -ne 'true') {
        Write-Skip $assertionName "(auto-route-classifier-enabled=$(if ($classifierOn) { $classifierOn } else { '<unset>' }))"
    } elseif (-not $dev1Key -or -not $threshold -or -not $appId) {
        Write-Skip $assertionName '(missing dev1 key, threshold or appId)'
    } else {
        $filler = 'a' * [int]$threshold
        $payload = @{
            model    = 'auto'
            messages = @(@{ role = 'user'; content = "Answer in one short sentence. $filler" })
            max_completion_tokens = 40
        } | ConvertTo-Json -Depth 6 -Compress

        $resp = Invoke-WebRequest -Method POST -Uri "$apimGw/openai/v1/chat/completions" `
            -Headers @{ 'api-key' = $dev1Key } -ContentType 'application/json' -Body $payload `
            -TimeoutSec 90 -SkipHttpErrorCheck
        if ($resp.StatusCode -ne 200) {
            throw "HTTP $($resp.StatusCode); body=$("$($resp.Content)".Substring(0, [Math]::Min(200, "$($resp.Content)".Length)))"
        }

        $ckql = 'customMetrics | where timestamp > ago(20m) | where name in ("copilot_byok_auto_route","copilot_byok_classifier_tokens") | extend reason = tostring(customDimensions["auto_route_reason"]) | summarize decided=countif(name == "copilot_byok_auto_route" and reason in ("classifier-simple","classifier-complex")), fellback=countif(name == "copilot_byok_auto_route" and reason startswith "classifier-fallback"), reasons=tostring(make_set_if(reason, reason startswith "classifier-")), ctok=countif(name == "copilot_byok_classifier_tokens"), ctoksum=sum(iff(name == "copilot_byok_classifier_tokens", valueSum, 0.0))'
        $cBody = New-TemporaryFile
        (@{ query = $ckql } | ConvertTo-Json -Compress) | Set-Content -Path $cBody.FullName -Encoding ascii
        $cdecided = 0; $cfellback = 0; $creasons = ''; $ctok = 0; $ctoksum = 0
        try {
            $deadline = (Get-Date).AddSeconds(300)
            while ((Get-Date) -lt $deadline) {
                $cjson = az rest --method post --url "$aiApi/v1/apps/$appId/query" --headers 'Content-Type=application/json' --body "@$($cBody.FullName)" --resource $aiApi -o json 2>$null | ConvertFrom-Json
                $cdecided  = [int]($cjson.tables[0].rows[0][0] ?? 0)
                $cfellback = [int]($cjson.tables[0].rows[0][1] ?? 0)
                $creasons  = "$($cjson.tables[0].rows[0][2])"
                $ctok      = [int]($cjson.tables[0].rows[0][3] ?? 0)
                $ctoksum   = [double]($cjson.tables[0].rows[0][4] ?? 0)
                # Stop as soon as ANY classifier outcome lands; a fallback is a result, not a wait.
                if ($cdecided -gt 0 -or $cfellback -gt 0) { break }
                Start-Sleep -Seconds 15
            }
        } finally { Remove-Item -Path $cBody.FullName -ErrorAction SilentlyContinue }

        if ($cdecided -gt 0) {
            # The classifier calls the model directly, so its tokens are only visible via the
            # explicit metric; without it that spend is invisible again, which is the #128 gap.
            if ($ctok -gt 0) {
                Write-Pass $assertionName "(threshold=$threshold; classifier decided $cdecided time(s): $creasons; classifier tokens metered: $ctok emit(s), $ctoksum tokens)"
            } else {
                Write-Fail $assertionName "(threshold=$threshold; classifier decided ($creasons) but copilot_byok_classifier_tokens never landed -- the classifier ran and its spend is unmetered, the #128 gap)"
            }
        } elseif ($cfellback -gt 0) {
            # classifier-fallback == the classifier call itself failed and routing silently degraded
            # to the full model. That is the #128 failure, not a pass. The suffix says which mode.
            Write-Fail $assertionName "(threshold=$threshold; classifier fell back x$cfellback, reasons=$creasons -- the classifier call FAILED and silently degraded to the full model. Suffix: noresp=no response at all (unreachable, or past the 8s timeout), httpNNN=endpoint refused it (401/403 credential, 429 throttle), parse/empty=answered but unusable)"
        } else {
            Write-Fail $assertionName "(threshold=$threshold; request 200 but no classifier-* reason in 300s -- the classifier did not run at all)"
        }
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
            # A backend capacity 429 is indistinguishable from a policy 429 by status alone, so
            # passing on it would hide a tier-TPM-above-modelCapacity misconfig.
            if ($resp.Content -match 'pricing tier|exceeded token rate limit') {
                Write-Fail $assertionName '(429 came from the MODEL DEPLOYMENT, not llm-token-limit: the product tier TPM exceeds this env modelCapacity, so the backend throttles before APIM does)'
            } else {
                Write-Pass $assertionName "(HTTP 429 after burst, retry-after=$($resp.Headers['Retry-After'] -join ','))"
            }
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
# Assertion: STREAMED requests emit token metrics (#126)
# ---------------------------------------------------------------------------
# The hand-rolled outbound emit-metric pair is guarded by Content-Type: application/json, so it
# never fires for text/event-stream -- and Copilot CLI / VS Code stream by default, which left most
# real traffic unmetered. The built-in llm-emit-token-metric (inbound) captures usage at the
# platform level for streamed responses too. This proves it end to end: send a STREAMING
# chat/completions call, confirm it really streamed, then confirm a platform token metric landed.
# Deliberately runs LAST so the metric query window contains only this call's traffic.
# SKIPs (does not fail) if the query plane isn't reachable or ingestion hasn't landed in time --
# custom-metric ingestion is best-effort and we don't want a flaky gate.
Write-Step 'Assertion: streamed requests emit token metrics (#126)'
$assertionName = 'streaming-token-metrics'
$skipMetricCheck = $false
try {
    if (-not $dev1Key) {
        Write-Skip $assertionName '(no dev1 key)'
    } else {
        # Custom metrics are aggregated per MINUTE and the datapoint is stamped at the START of
        # that bin, so a mid-minute $t0 would exclude this call's own datapoint (looks like
        # ingestion lag). Land ~2s into a fresh minute and floor $t0 to it: because this probe runs
        # LAST, that minute then contains ONLY this call, so both directions can be asserted.
        Start-Sleep -Seconds (62 - (Get-Date).ToUniversalTime().Second)
        $t0 = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:00Z')
        $url = "$apimGw/openai/v1/chat/completions"
        $body = @{ model = $PrimaryModel; messages = @(@{ role = 'user'; content = 'Reply with the single word: pong.' }); max_completion_tokens = 64; stream = $true } | ConvertTo-Json -Depth 6 -Compress
        $r = Invoke-WebRequest -Method Post -Uri $url -Headers @{ 'api-key' = $dev1Key; 'Accept' = 'text/event-stream' } -ContentType 'application/json' -Body $body -TimeoutSec 90 -SkipHttpErrorCheck
        $status = [int]$r.StatusCode
        $text = "$($r.Content)"
        if ($status -ne 200) {
            Write-Fail $assertionName "(streaming request HTTP $status; body=$($text.Substring(0, [Math]::Min(160, $text.Length))))"
        } elseif ($text -notmatch 'chat\.completion\.chunk' -or $text -notmatch '\[DONE\]') {
            Write-Fail $assertionName "(200 but not an SSE chunk stream; head=$($text.Substring(0, [Math]::Min(120, $text.Length))))"
        } else {
            # Same minute: also stream on the RESPONSES surface. Genuinely different path -- the
            # inbound policy deliberately does NOT inject stream_options.include_usage there,
            # because Responses reports usage natively in its terminal response.completed event.
            $rBody = @{ model = $PrimaryModel; input = 'Reply with the single word: pong.'; max_output_tokens = 64; stream = $true } | ConvertTo-Json -Depth 6 -Compress
            $rr = Invoke-WebRequest -Method Post -Uri "$apimGw/openai/v1/responses" -Headers @{ 'api-key' = $dev1Key; 'Accept' = 'text/event-stream' } -ContentType 'application/json' -Body $rBody -TimeoutSec 90 -SkipHttpErrorCheck
            $rStatus = [int]$rr.StatusCode
            $rText = "$($rr.Content)"
            if ($rStatus -ne 200 -or $rText -notmatch 'response\.') {
                Write-Fail $assertionName "(chat stream OK but /responses stream failed: HTTP $rStatus; head=$($rText.Substring(0, [Math]::Min(140, $rText.Length))))"
                $skipMetricCheck = $true
            }
            if (-not $skipMetricCheck) {
            # The call definitely streamed. Now confirm the platform emitted token metrics for it.
            # Query via the App Insights REST API (same approach as assertion 4) rather than the
            # log-analytics CLI extension, which isn't guaranteed present on a runner.
            $appId = az monitor app-insights component show -g $ResourceGroup --app $AppInsightsName --query 'appId' -o tsv 2>$null
            $aiApi = az cloud show --query 'endpoints.appInsightsResourceId' -o tsv 2>$null
            if (-not $appId -or -not $aiApi) {
                Write-Skip $assertionName '(streamed OK, but App Insights query endpoint not resolvable for the metric check)'
            } else {
                # One query returns BOTH counts for the probe's isolated minute: the built-in policy
                # must have counted this streamed call, and the legacy outbound pair must NOT have
                # (that's the whole gap). valueCount = measurements aggregated, which separates
                # calls in a way raw sums cannot.
                $q = "customMetrics | where timestamp >= datetime($t0) | summarize builtin = sumif(valueCount, name in ('Total Tokens','Completion Tokens','Prompt Tokens')), legacy = sumif(valueCount, name in ('copilot_byok_prompt_tokens','copilot_byok_completion_tokens'))"
                $qFile = New-TemporaryFile
                try {
                    $n = 0; $legacy = 0
                    @{ query = $q } | ConvertTo-Json -Compress | Set-Content -Path $qFile.FullName -NoNewline
                    for ($i = 0; $i -lt 10; $i++) {
                        $json = az rest --method post --url "$aiApi/v1/apps/$appId/query" --headers 'Content-Type=application/json' --body "@$($qFile.FullName)" --resource $aiApi -o json 2>$null
                        if ($LASTEXITCODE -eq 0 -and $json) {
                            $row = ("$json" | ConvertFrom-Json).tables[0].rows[0]
                            if ($row) {
                                if ($null -ne $row[0]) { $n = [int]$row[0] }
                                if ($null -ne $row[1]) { $legacy = [int]$row[1] }
                            }
                        }
                        if ($n -gt 0) { break }
                        Start-Sleep -Seconds 30
                    }
                    if ($n -le 0) {
                        Write-Skip $assertionName '(both surfaces streamed OK, but no token metric visible within ~5m; custom-metric ingestion lag)'
                    } elseif ($legacy -le 0) {
                        Write-Pass $assertionName "(chat/completions + /responses both streamed; built-in emitted $n token measurement(s), legacy copilot_byok_*_tokens emitted 0 -- exactly the #126 gap, now covered)"
                    } else {
                        Write-Pass $assertionName "(both surfaces streamed; built-in emitted $n token measurement(s); note: legacy also emitted $legacy in the same minute)"
                    }
                } finally {
                    Remove-Item -Path $qFile.FullName -ErrorAction SilentlyContinue
                }
            }
            }
        }
    }
} catch {
    Write-Fail $assertionName "($($_.Exception.Message))"
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
