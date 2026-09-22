#requires -Version 7.0
<#
.SYNOPSIS
    Discover which API surface(s) each deployed model supports, per APIM route, and write the
    resulting model->types capability map into the committed CI param file(s). (Issue #119 Phase 1
    / #122.)

.DESCRIPTION
    HYBRID discovery (decision locked on #122):
      1. ENUMERATE  - GET <gateway>/<route>/v1/models -> the model id list (reshaped OpenAI shape).
      2. PROBE      - for each model, send a minimal request to each candidate surface through the
                      SAME gateway route and record which return 200 (supported) vs a typed 4xx
                      (unsupported). The /v1/models response carries no `responses` capability flag,
                      so the surfaces are PROBED, not inferred.
    Surfaces probed: chat/completions, responses, embeddings, messages (Anthropic). completions is
    treated as an alias of chat-capable models and is not probed by default (legacy, rarely used).

    The result is a compact JSON object { "<model>": ["chat/completions","responses", ...], ... }
    written into the matching CI param file under the route's param key:
      /openai            -> foundryModelTypes           (main.parameters.ci.<gov|commercial>*.json)
      /aoai              -> aoaiModelTypes
    The param file is the AUTHORITATIVE source; a subsequent provision applies the named value.
    This script never calls `az apim nv update` (a provision would reset it) unless -AlsoWriteNamedValue
    is passed for an instant dev refresh.

    NOT probed: the commercial map (foundryCommercialModelTypes / named value
    foundry-commercial-model-types). It is still live - the /anthropic route policy reads it - but
    commercial models are now selected by the commercial-models sentinel on /openai rather than by a
    route of their own, and /anthropic exposes only /v1/messages (no /v1/models to enumerate), so
    there is nothing here to probe. Maintain that map by hand in the CI param file.

.PARAMETER GatewayUrl
    APIM gateway base URL (e.g. https://<apim>.azure-api.net). If omitted, resolved from
    -ApimName/-ResourceGroup via `az apim show`.

.PARAMETER Routes
    Route prefixes to discover. Default: openai. Add 'aoai' when that route is live on the target env.

.PARAMETER ParamFile
    Path to the CI param file to update. If omitted, nothing is written (dry-run print only) unless
    -ParamFile is supplied. Use the file matching the env you discovered against.

.PARAMETER ApiKeyEnvVar
    Name of the environment variable holding the APIM subscription key. Default BYOK_DISCOVERY_KEY.
    The key is read from the environment and sent in the `api-key` header; it is NEVER echoed,
    logged, or passed on the command line.

.PARAMETER IncludeEmbeddings
    Also probe the /v1/embeddings surface. Default off (embeddings clients are rare here).

.PARAMETER AlsoWriteNamedValue
    In addition to the param file, immediately `az apim nv update` the route's named value for an
    instant (non-authoritative) dev refresh. Requires -ApimName/-ResourceGroup.

.EXAMPLE
    $env:BYOK_DISCOVERY_KEY = '<subscription-key>'   # set out-of-band; not echoed
    ./scripts/discover-model-types.ps1 -ApimName <apim> -ResourceGroup <rg> `
        -Routes openai -ParamFile infra/main.parameters.ci.commercial.json
#>
[CmdletBinding()]
param(
    [string] $GatewayUrl,
    [string] $ApimName,
    [string] $ResourceGroup,
    [string[]] $Routes = @('openai'),
    [string] $ParamFile,
    [string] $ApiKeyEnvVar = 'BYOK_DISCOVERY_KEY',
    [switch] $IncludeEmbeddings,
    [switch] $AlsoWriteNamedValue,
    [int] $TimeoutSec = 40
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# route prefix -> CI param-file key + named-value name (Phase 1 storage side, apim-named-values.bicep)
$RouteMap = @{
    'openai' = @{ Param = 'foundryModelTypes'; Nv = 'foundry-model-types' }
    'aoai'   = @{ Param = 'aoaiModelTypes';    Nv = 'aoai-model-types' }
}

# The 'auto'/'byok-auto' sentinels are NOT real backend deployments (auto-routing) -> never probe.
$SentinelModels = @('auto', 'byok-auto')

function Get-ApiKey {
    $key = [Environment]::GetEnvironmentVariable($ApiKeyEnvVar)
    if ([string]::IsNullOrWhiteSpace($key)) {
        throw "APIM subscription key not found. Set `$env:$ApiKeyEnvVar out-of-band (it is never echoed)."
    }
    return $key
}

function Resolve-GatewayUrl {
    if ($GatewayUrl) { return $GatewayUrl.TrimEnd('/') }
    if (-not $ApimName -or -not $ResourceGroup) {
        throw 'Provide -GatewayUrl, or both -ApimName and -ResourceGroup to resolve it.'
    }
    $gw = az apim show -g $ResourceGroup -n $ApimName --query 'gatewayUrl' -o tsv 2>$null
    if (-not $gw) { throw "Could not resolve gateway URL for APIM '$ApimName' in '$ResourceGroup'." }
    return $gw.TrimEnd('/')
}

# Send one probe; return $true if the surface is supported (HTTP 2xx), $false on a typed 4xx that
# indicates the surface/model is unsupported, and $null on an inconclusive error (network/5xx/auth)
# so the caller can distinguish "no" from "couldn't tell".
function Test-Surface {
    param(
        [string] $Url,
        [hashtable] $Headers,
        [string] $BodyJson
    )
    try {
        $resp = Invoke-WebRequest -Method Post -Uri $Url -Headers $Headers -ContentType 'application/json' `
            -Body $BodyJson -TimeoutSec $TimeoutSec -SkipHttpErrorCheck -ErrorAction Stop
        $code = [int] $resp.StatusCode
    }
    catch {
        Write-Verbose "  probe error: $($_.Exception.Message)"
        return $null
    }
    if ($code -ge 200 -and $code -lt 300) { return $true }
    # 400/404/422 = surface exists but rejects this model/shape => unsupported.
    if ($code -in 400, 404, 405, 422) { return $false }
    # 401/403/429/5xx are inconclusive (auth/throttle/backend) - don't record a false negative.
    Write-Verbose "  inconclusive HTTP $code"
    return $null
}

function Get-ModelIds {
    param([string] $Base, [hashtable] $Headers)
    $url = "$Base/v1/models"
    try {
        $resp = Invoke-WebRequest -Method Get -Uri $url -Headers $Headers -TimeoutSec $TimeoutSec `
            -SkipHttpErrorCheck -ErrorAction Stop
    }
    catch {
        Write-Warning "  GET $url failed: $($_.Exception.Message)"
        return @()
    }
    if ([int]$resp.StatusCode -ne 200) {
        Write-Warning "  GET /v1/models -> HTTP $([int]$resp.StatusCode) (route not deployed or key invalid); skipping."
        return @()
    }
    $json = $resp.Content | ConvertFrom-Json
    $ids = @($json.data | ForEach-Object { $_.id } | Where-Object { $_ })
    return $ids
}

function Get-RouteMap {
    param([string] $Base, [string] $Route, [hashtable] $Headers)

    $ids = Get-ModelIds -Base $Base -Headers $Headers
    $ids = @($ids | Where-Object { $SentinelModels -notcontains $_.ToLowerInvariant() })
    if ($ids.Count -eq 0) { Write-Host "    (no models enumerated on /$Route)"; return @{} }
    Write-Host "    models: $($ids -join ', ')"

    $map = [ordered]@{}
    foreach ($model in $ids) {
        $types = New-Object System.Collections.Generic.List[string]

        # NOTE: use max_completion_tokens (NOT max_tokens) - the gpt-5.x family 400s on max_tokens
        # ('use max_completion_tokens'), which would be a FALSE NEGATIVE for chat/completions.
        $chat = Test-Surface -Url "$Base/v1/chat/completions" -Headers $Headers -BodyJson (@{
                model = $model; messages = @(@{ role = 'user'; content = 'ping' }); max_completion_tokens = 16
            } | ConvertTo-Json -Depth 6 -Compress)
        if ($chat) { $types.Add('chat/completions') }

        $responses = Test-Surface -Url "$Base/v1/responses" -Headers $Headers -BodyJson (@{
                model = $model; input = 'ping'; max_output_tokens = 16
            } | ConvertTo-Json -Depth 6 -Compress)
        if ($responses) { $types.Add('responses') }

        # Anthropic Messages: native body. A non-Claude model returns a typed 4xx here.
        $messages = Test-Surface -Url "$Base/v1/messages" -Headers $Headers -BodyJson (@{
                model = $model; messages = @(@{ role = 'user'; content = 'ping' }); max_tokens = 1
            } | ConvertTo-Json -Depth 6 -Compress)
        if ($messages) { $types.Add('messages') }

        if ($IncludeEmbeddings) {
            $embed = Test-Surface -Url "$Base/v1/embeddings" -Headers $Headers -BodyJson (@{
                    model = $model; input = 'ping'
                } | ConvertTo-Json -Depth 6 -Compress)
            if ($embed) { $types.Add('embeddings') }
        }

        Write-Host ("      {0,-24} -> [{1}]" -f $model, ($types -join ', '))
        $map[$model] = @($types)
    }
    return $map
}

function Update-ParamFile {
    param([string] $Path, [string] $ParamKey, [hashtable] $Map)

    if (-not (Test-Path $Path)) { throw "Param file not found: $Path" }
    $raw = Get-Content -Raw -Path $Path
    $doc = $raw | ConvertFrom-Json -AsHashtable
    if (-not $doc.ContainsKey('parameters')) { $doc['parameters'] = @{} }

    # Compact JSON string is the named-value payload the bicep param expects.
    $compact = ($Map | ConvertTo-Json -Depth 6 -Compress)
    $doc['parameters'][$ParamKey] = @{ value = $compact }

    # Preserve azd's { "parameters": { ... } } shape; pretty-print with 2-space indent.
    $out = $doc | ConvertTo-Json -Depth 20
    Set-Content -Path $Path -Value $out -Encoding utf8NoBOM
    Write-Host "    wrote $ParamKey ($($Map.Count) models) -> $Path" -ForegroundColor Green
}

# ---- main -----------------------------------------------------------------------------------
$apiKey = Get-ApiKey
$gw = Resolve-GatewayUrl
$headers = @{ 'api-key' = $apiKey }
Write-Host "Gateway: $gw"
Write-Host "Routes : $($Routes -join ', ')`n"

$results = @{}
foreach ($route in $Routes) {
    if (-not $RouteMap.ContainsKey($route)) { Write-Warning "Unknown route '$route' (no param mapping); skipping."; continue }
    Write-Host "== /$route ==" -ForegroundColor Cyan
    $map = Get-RouteMap -Base "$gw/$route" -Route $route -Headers $headers
    $results[$route] = $map
    Write-Host ''
}

foreach ($route in $results.Keys) {
    $map = $results[$route]
    if ($map.Count -eq 0) { continue }
    $info = $RouteMap[$route]
    if ($ParamFile) {
        Update-ParamFile -Path $ParamFile -ParamKey $info.Param -Map $map
    }
    else {
        Write-Host "-- /$route ($($info.Param)) --" -ForegroundColor Yellow
        Write-Host ($map | ConvertTo-Json -Depth 6 -Compress)
    }
    if ($AlsoWriteNamedValue) {
        if (-not $ApimName -or -not $ResourceGroup) { Write-Warning 'AlsoWriteNamedValue needs -ApimName/-ResourceGroup; skipped.'; continue }
        $compact = ($map | ConvertTo-Json -Depth 6 -Compress)
        az apim nv update -g $ResourceGroup --service-name $ApimName --named-value-id $info.Nv --value $compact 1>$null
        if ($LASTEXITCODE -eq 0) { Write-Host "    az apim nv update $($info.Nv) OK (non-authoritative dev refresh)" -ForegroundColor DarkYellow }
        else { Write-Warning "    az apim nv update $($info.Nv) failed ($LASTEXITCODE)" }
    }
}

Write-Host "`nDone."
exit 0
