#requires -Version 7.0
<#
.SYNOPSIS
  Pre-provision guard that stops a provision from WIPING populated pilot values when CI-only
  environment variables are absent. Wired as an azd `preprovision` hook AFTER ensure-byok-groups.

.DESCRIPTION
  `azd provision` is a declarative overwrite: it sets every APIM named value / param-driven resource
  to whatever the parameter file resolves to at that moment. Parameters wired as `${VAR}` (e.g.
  `"foundryCommercialBaseUrl": { "value": "${COMMERCIAL_FOUNDRY_BASE_URL}" }`) are populated by CI,
  which exports the vars from the env's GitHub settings. A LOCAL `azd provision` typically runs
  WITHOUT those vars, so `${VAR}` resolves to empty, the Bicep defaults take over, and the provision
  overwrites the previously-good values with placeholders. This actually broke the cross-cloud
  Commercial Foundry route once (foundry-commercial-* named values reset to `https://unset.invalid`
  / `servicePrincipalFederated` / `organizations` / `unset` -> every call 502).

  This guard reads the parameter file azd actually deploys (infra/main.parameters.json - the
  workflows stage the per-env file into it before provision), resolves `${VAR}` against the
  environment exactly as azd will, and:

    OPTION 2 (HARD gate) - Commercial Foundry route:
      If deployFoundryCommercial=true but foundryCommercialBaseUrl / -TenantId / -ClientId
      (or -ClientSecret in servicePrincipal mode) resolve to empty/placeholder => ABORT (exit 1)
      with guidance. This makes the wipe impossible via the normal azd path.

    OPTION 3 (advisory scan) - any `${VAR}` param that resolves EMPTY:
      Lists every parameter that would deploy blank, with a louder banner on `*-pilot` envs
      (where blanking a currently-populated value is destructive). Non-fatal by design: some
      empties are intentional (e.g. the register Easy Auth two-phase bring-up, or a route that is
      off for this env), so this stays a visible WARNING rather than a hard failure. Secret values
      are NEVER printed - only the parameter + env-var NAME.

  CI-safe: CI exports the vars, so the hard gate passes; it makes no interactive calls.
  Shared-auth preparation trust is always checked when supplied. The legacy backend/advisory
  checks can be bypassed with SKIP_PROVISION_PARAM_CHECK=true; that does not bypass trust checks.
#>
[CmdletBinding()]
param([string] $ParameterFile = (Join-Path $PSScriptRoot '../infra/main.parameters.json'), [switch] $StageCallerAuth,
    [ValidateSet('', 'AzureCloud', 'AzureUSGovernment')] [string] $StandaloneCloud = '')

$ErrorActionPreference = 'Stop'

$paramFile = $ParameterFile
if (-not (Test-Path -LiteralPath $paramFile)) {
    if ($StageCallerAuth -or $PSBoundParameters.ContainsKey('ParameterFile')) {
        Write-Host '[provision-params] Explicit parameter file was not found.' -ForegroundColor Red
        exit 1
    }
    Write-Host "[provision-params] $paramFile not found - skipping guard."
    exit 0
}
try {
    $document = Get-Content -Raw -LiteralPath $paramFile | ConvertFrom-Json
    $params = $document.parameters
    if ($params -isnot [pscustomobject]) { throw 'Invalid parameters object.' }
    if ($StandaloneCloud) {
        if ($StageCallerAuth -or $params.PSObject.Properties.Name -contains 'responseOwnerKey' -or $params.PSObject.Properties.Name -contains 'responseOwnerPreviousKey') { throw 'Standalone owner keys must be environment inputs, not file values.' }
        $params | Add-Member -NotePropertyName cloudEnv -NotePropertyValue ([pscustomobject]@{value=$StandaloneCloud}) -Force
        $products = @($params.existingProductName.value) + @($params.additionalProductNames.value)
        if ($params.PSObject.Properties.Name -cnotcontains 'productTiers') {
            $params | Add-Member -NotePropertyName productTiers -NotePropertyValue ([pscustomobject]@{value=@($products | Where-Object {$_} | ForEach-Object {[pscustomobject]@{name=$_}})})
        }
        if ($params.callerAuthRollout.value -and $params.callerAuthRollout.value -cne 'legacy') {
            if ([string]::IsNullOrWhiteSpace($env:BYOK_RESPONSE_OWNER_PREVIOUS_KEY)) { throw 'Previous ownership key state must be explicit.' }
            $params | Add-Member -NotePropertyName responseOwnerKey -NotePropertyValue ([pscustomobject]@{value=$env:BYOK_RESPONSE_OWNER_KEY})
            $params | Add-Member -NotePropertyName responseOwnerPreviousKey -NotePropertyValue ([pscustomobject]@{value=$(if($env:BYOK_RESPONSE_OWNER_PREVIOUS_KEY -ceq '__none__'){''}else{$env:BYOK_RESPONSE_OWNER_PREVIOUS_KEY})})
        }
    }
    if ($StageCallerAuth) {
        if ($env:BYOK_CALLER_AUTH_PREPARATION) {
            $preparation = ConvertFrom-Json -InputObject $env:BYOK_CALLER_AUTH_PREPARATION -NoEnumerate
            $params | Add-Member -NotePropertyName callerAuthPreparation -NotePropertyValue ([pscustomobject]@{ value = $preparation }) -Force
        }
        if ($env:BYOK_CALLER_AUTH_ROLLOUT) {
            $params | Add-Member -NotePropertyName callerAuthRollout -NotePropertyValue ([pscustomobject]@{ value = $env:BYOK_CALLER_AUTH_ROLLOUT }) -Force
        }
        if ($env:BYOK_CALLER_JWT_TIERING) {
            $tiering = ConvertFrom-Json -InputObject $env:BYOK_CALLER_JWT_TIERING -NoEnumerate
            $params | Add-Member -NotePropertyName callerJwtTiering -NotePropertyValue ([pscustomobject]@{ value = $tiering }) -Force
        }
        if ($params.callerAuthRollout.value -and $params.callerAuthRollout.value -cne 'legacy') {
            if ([string]::IsNullOrWhiteSpace($env:BYOK_RESPONSE_OWNER_PREVIOUS_KEY)) { throw 'Previous ownership key state must be explicit.' }
            $params | Add-Member -NotePropertyName responseOwnerKey -NotePropertyValue ([pscustomobject]@{ value = '${BYOK_RESPONSE_OWNER_KEY}' }) -Force
            $previousReference = if ($env:BYOK_RESPONSE_OWNER_PREVIOUS_KEY -ceq '__none__') { '' } else { '${BYOK_RESPONSE_OWNER_PREVIOUS_KEY}' }
            $params | Add-Member -NotePropertyName responseOwnerPreviousKey -NotePropertyValue ([pscustomobject]@{ value = $previousReference }) -Force
        }
    }
} catch {
    Write-Host '[provision-params] Cannot read a valid deployment parameter document.' -ForegroundColor Red
    exit 1
}

function Resolve-ParamValue {
    param($Params, [string]$Name)
    if (-not ($Params.PSObject.Properties.Name -contains $Name)) { return $null }
    $v = $Params.$Name.value
    if ($v -is [string] -and $v -match '^\$\{(.+)\}$') {
        return [Environment]::GetEnvironmentVariable($Matches[1])
    }
    return $v
}

function Resolve-PreparationValue {
    param($Value)
    if ($Value -is [string]) {
        return [regex]::Replace($Value, '\$\{([A-Za-z_][A-Za-z0-9_]*)\}', {
            param($Placeholder)
            [string][Environment]::GetEnvironmentVariable($Placeholder.Groups[1].Value)
        })
    }
    if ($Value -is [array]) { return ,@($Value | ForEach-Object { Resolve-PreparationValue $_ }) }
    if ($Value -is [pscustomobject]) {
        $resolved = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $resolved[$property.Name] = Resolve-PreparationValue $property.Value }
        return [pscustomobject]$resolved
    }
    return $Value
}

function Test-PreparationProperties {
    param($Value, [string[]] $Names)
    return $Value -is [pscustomobject] -and -not (Compare-Object @($Value.PSObject.Properties.Name | Sort-Object) @($Names | Sort-Object) -CaseSensitive)
}

function Test-PreparationString {
    param($Value, [string] $Pattern)
    return $Value -is [string] -and $Value -cmatch $Pattern
}

function Test-CallerAuthPreparation {
    param($Preparation)
    if (-not (Test-PreparationProperties $Preparation @('enabled', 'keyEnabled', 'entraEnabled', 'entraClientIds', 'oktaTrust', 'jwtProductId'))) { return $false }
    $okta = $Preparation.oktaTrust
    if (-not (Test-PreparationProperties $okta @('enabled', 'issuer', 'openIdConfigUrl', 'audience', 'requiredScope', 'clientIds'))) { return $false }
    foreach ($flag in @($Preparation.enabled, $Preparation.keyEnabled, $Preparation.entraEnabled, $okta.enabled)) {
        if ($flag -isnot [bool]) { return $false }
    }
    foreach ($clients in @(@{ value = $Preparation.entraClientIds }, @{ value = $okta.clientIds })) {
        if ($clients.value -isnot [array] -or @($clients.value | Where-Object { $_ -isnot [string] }).Count) { return $false }
    }
    foreach ($value in @($Preparation.jwtProductId, $okta.issuer, $okta.openIdConfigUrl, $okta.audience, $okta.requiredScope)) {
        if ($value -isnot [string]) { return $false }
    }
    if (-not $Preparation.enabled) { return $true }
    if (-not ($Preparation.keyEnabled -or $Preparation.entraEnabled -or $okta.enabled) -or
        -not (Test-PreparationString $Preparation.jwtProductId '\A[A-Za-z0-9_-]{1,80}\z')) { return $false }
    $tiers = Resolve-ParamValue $params 'productTiers'
    $tierNames = if ($null -eq $tiers) { @('byok-standard', 'byok-power') } else { @($tiers | ForEach-Object { Resolve-PreparationValue $_.name }) }
    if ($StandaloneCloud) { $tierNames = @($tierNames) + @($params.existingProductName.value) + @($params.additionalProductNames.value) }
    if ($tierNames -contains $Preparation.jwtProductId) { return $false }
    $cloud = (Resolve-ParamValue $params 'cloudEnv') ?? 'AzureUSGovernment'
    $mode = (Resolve-ParamValue $params 'authMode') ?? 'subscriptionKey'
    if ($cloud -cnotin @('AzureCloud', 'AzureUSGovernment') -or $mode -cnotin @('subscriptionKey', 'jwt')) { return $false }
    if ($Preparation.entraEnabled) {
        $guidPattern = '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
        $tenant = Resolve-ParamValue $params 'entraTenantId'
        $audience = Resolve-ParamValue $params 'apiAudience'
        $scope = (Resolve-ParamValue $params 'requiredScope') ?? 'cli.invoke'
        foreach ($identifier in @($tenant, $audience) + $Preparation.entraClientIds) {
            if (-not (Test-PreparationString $identifier $guidPattern) -or [guid]$identifier -eq [guid]::Empty) { return $false }
        }
        if (-not (Test-PreparationString $scope '\A[A-Za-z0-9._-]{1,128}\z') -or
            $Preparation.entraClientIds -contains $audience -or
            @($Preparation.entraClientIds | Sort-Object -Unique).Count -ne $Preparation.entraClientIds.Count -or
            ($Preparation.entraClientIds -join ',').Length -gt 4096) { return $false }
    }
    if ($okta.enabled) {
        $issuerPattern = '\Ahttps://(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}(?::443)?/oauth2/[A-Za-z0-9_-]+\z'
        if (-not (Test-PreparationString $okta.issuer $issuerPattern) -or
            ([uri]$okta.issuer).Host -match '\.(invalid|localhost)\z' -or
            $okta.openIdConfigUrl -cne ($okta.issuer + '/.well-known/openid-configuration') -or
            -not (Test-PreparationString $okta.audience '\A[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}\z') -or
            -not (Test-PreparationString $okta.requiredScope '\A[A-Za-z0-9._-]{1,128}\z') -or
            $okta.clientIds.Count -eq 0 -or ($okta.clientIds -join ',').Length -gt 4096 -or
            @($okta.clientIds | Sort-Object -Unique -CaseSensitive).Count -ne $okta.clientIds.Count) { return $false }
        foreach ($client in $okta.clientIds) {
            if (-not (Test-PreparationString $client '\A[A-Za-z0-9_-]{1,128}\z') -or
                $client -cin @('__any__', '__none__', $okta.audience)) { return $false }
        }
    }
    return $true
}

if ($params.PSObject.Properties.Name -contains 'callerAuthPreparation') {
    try { $trustValid = Test-CallerAuthPreparation (Resolve-PreparationValue $params.callerAuthPreparation.value) }
    catch { $trustValid = $false }
    if (-not $trustValid) {
        Write-Host '[provision-params] CALLER AUTH CHECK FAILED: invalid callerAuthPreparation shape, enabled trust settings, or product conflict. See docs/authentication.md. Values are withheld.' -ForegroundColor Red
        exit 1
    }
    Write-Host '[provision-params] Caller-auth preparation checked; this does not enable API coexistence.'
}

function Test-CallerAuthRollout {
    $rollout = (Resolve-ParamValue $params 'callerAuthRollout') ?? 'legacy'
    if ($rollout -cnotin @('legacy', 'shared', 'coexistence')) { return $false }
    if ($rollout -ceq 'legacy') { return $true }
    $preparation = Resolve-PreparationValue $params.callerAuthPreparation.value
    if (-not (Test-CallerAuthPreparation $preparation) -or -not $preparation.enabled) { return $false }
    if ($rollout -ceq 'coexistence' -and (-not $preparation.keyEnabled -or -not ($preparation.entraEnabled -or $preparation.oktaTrust.enabled))) { return $false }
    $currentKey = Resolve-ParamValue $params 'responseOwnerKey'
    $previousKey = (Resolve-ParamValue $params 'responseOwnerPreviousKey') ?? ''
    $keyPattern = '\A[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=\z'
    if (-not (Test-PreparationString $currentKey $keyPattern) -or $currentKey -ceq ('A' * 43 + '=') -or
        $previousKey -isnot [string] -or ($previousKey -ne '' -and (-not (Test-PreparationString $previousKey $keyPattern) -or $previousKey -ceq ('A' * 43 + '=') -or $previousKey -ceq $currentKey))) { return $false }
    $foundry = (Resolve-ParamValue $params 'deployFoundry') ?? $true
    $aoai = (Resolve-ParamValue $params 'deployAoai') ?? $false
    $commercial = (Resolve-ParamValue $params 'deployFoundryCommercial') ?? $false
    foreach ($flag in @($foundry, $aoai, $commercial)) { if ($flag -isnot [bool]) { return $false } }
    if (-not ($foundry -or $aoai)) { return $false }
    $storeCount = [int]$foundry + [int]$aoai + [int]$commercial
    foreach ($family in @(@{ name = 'foundryRegions'; enabled = $foundry }, @{ name = 'aoaiRegions'; enabled = $aoai })) {
        $regions = Resolve-ParamValue $params $family.name
        if ($null -ne $regions -and $regions -isnot [array]) { return $false }
        if ($family.enabled -and $null -ne $regions) { $storeCount += $regions.Count }
    }
    return $storeCount -le 8
}

function Test-CallerJwtTiering {
    if ($params.PSObject.Properties.Name -cnotcontains 'callerJwtTiering') { return $true }
    if (-not (Test-PreparationProperties $params.callerJwtTiering @('value'))) { return $false }
    $tiering = Resolve-PreparationValue $params.callerJwtTiering.value
    if (-not (Test-PreparationProperties $tiering @('entra', 'okta')) -or
        -not (Test-PreparationProperties $tiering.entra @('enabled', 'mappings')) -or
        -not (Test-PreparationProperties $tiering.okta @('enabled', 'claimName', 'mappings'))) { return $false }
    if ($tiering.entra.enabled -isnot [bool] -or $tiering.okta.enabled -isnot [bool] -or
        -not (Test-PreparationString $tiering.okta.claimName '\A[A-Za-z][A-Za-z0-9_.-]{0,63}\z') -or
        $tiering.okta.claimName -cin @('iss', 'aud', 'sub', 'uid', 'cid', 'scp', 'exp', 'nbf', 'iat', 'jti', 'azp', 'tid', 'oid', 'idtyp')) { return $false }
    foreach ($provider in @($tiering.entra, $tiering.okta)) {
        if ($provider.mappings -isnot [array] -or $provider.mappings.Count -gt 16 -or ($provider.enabled -and $provider.mappings.Count -eq 0)) { return $false }
        $claims = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($mapping in $provider.mappings) {
            if (-not (Test-PreparationProperties $mapping @('claimValue', 'tier')) -or
                -not (Test-PreparationString $mapping.claimValue '\A[A-Za-z][A-Za-z0-9_.:-]{0,127}\z') -or
                -not (Test-PreparationString $mapping.tier '\A[a-z][a-z0-9-]{0,79}\z') -or -not $claims.Add($mapping.claimValue)) { return $false }
        }
    }
    if (-not ($tiering.entra.enabled -or $tiering.okta.enabled)) { return $true }
    if ((Resolve-ParamValue $params 'callerAuthRollout') -cnotin @('shared', 'coexistence') -or
        ($params.PSObject.Properties.Name -ccontains 'configureApim' -and
            ((Resolve-ParamValue $params 'configureApim') -isnot [bool] -or (Resolve-ParamValue $params 'configureApim') -ne $true))) { return $false }
    $preparation = Resolve-PreparationValue $params.callerAuthPreparation.value
    if (-not (Test-CallerAuthPreparation $preparation) -or -not $preparation.enabled -or
        ($tiering.entra.enabled -and -not $preparation.entraEnabled) -or ($tiering.okta.enabled -and -not $preparation.oktaTrust.enabled)) { return $false }
    $catalog = Resolve-PreparationValue $params.productTiers.value
    if ($catalog -isnot [array] -or $catalog.Count -eq 0 -or $catalog.Count -gt 8) { return $false }
    $tierNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($tier in $catalog) {
        if ($tier -isnot [pscustomobject] -or -not (Test-PreparationString $tier.name '\A[a-z][a-z0-9-]{0,79}\z') -or -not $tierNames.Add($tier.name)) { return $false }
        foreach ($property in @('callsPerMinute', 'tokensPerMinute', 'monthlyCallQuota')) {
            $limit = $tier.$property
            if (($limit -isnot [int] -and $limit -isnot [long] -and $limit -isnot [double] -and $limit -isnot [decimal]) -or
                $limit -lt 1 -or $limit -gt [int]::MaxValue -or [math]::Floor([double]$limit) -ne $limit) { return $false }
        }
    }
    foreach ($mapping in @($tiering.entra.mappings) + @($tiering.okta.mappings)) {
        if (-not $tierNames.Contains($mapping.tier)) { return $false }
    }
    return $true
}

try { $tieringValid = Test-CallerJwtTiering } catch { $tieringValid = $false }
if (-not $tieringValid) {
    Write-Host '[provision-params] JWT TIER CHECK FAILED: require explicit shared trust, APIM configuration, a valid catalog and unambiguous issuer mappings. Values are withheld.' -ForegroundColor Red
    exit 1
}

try { $rolloutValid = Test-CallerAuthRollout } catch { $rolloutValid = $false }
if ($StandaloneCloud -and $params.callerAuthRollout.value -cin @('shared','coexistence')) {
    try {
        $origin = [string](Resolve-ParamValue $params 'existingBackendOrigin')
        $backend = [uri]$origin
        $mode = (Resolve-ParamValue $params 'foundryAuthMode') ?? 'apiKey'
        $rolloutValid = $rolloutValid -and $origin -cmatch '\Ahttps://(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}(?::443)?\z' -and
            -not $backend.IsLoopback -and $backend.Host -cnotmatch '\.(invalid|localhost)\z' -and $mode -cin @('apiKey','managedIdentity') -and
            ($mode -ceq 'managedIdentity' -or -not [string]::IsNullOrWhiteSpace($env:FOUNDRY_API_KEY))
    } catch { $rolloutValid = $false }
}
if (-not $rolloutValid) {
    Write-Host '[provision-params] CALLER ROLLOUT CHECK FAILED: shared rollout requires enabled trust, stable ownership keys, an OpenAI route and at most eight concrete response stores. Values are withheld.' -ForegroundColor Red
    exit 1
}

if ($StandaloneCloud) {
    Write-Host '[provision-params] Standalone caller trust, native admission, backend origin and ownership secret inputs validated. No deployment was performed.'
    exit 0
}

if ($StageCallerAuth) {
    if ($env:BYOK_CALLER_AUTH_PREPARATION -or $env:BYOK_CALLER_AUTH_ROLLOUT -or $env:BYOK_CALLER_JWT_TIERING -or $params.callerAuthRollout.value -cin @('shared','coexistence')) {
        $temporaryFile = $null
        try {
            $target = (Resolve-Path -LiteralPath $paramFile).Path
            $temporaryFile = $target + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
            [IO.File]::WriteAllText($temporaryFile, ($document | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
            [IO.File]::Move($temporaryFile, $target, $true)
        } finally {
            if ($temporaryFile -and (Test-Path -LiteralPath $temporaryFile)) { Remove-Item -LiteralPath $temporaryFile -Force }
        }
    }
    Write-Host '[provision-params] Caller-auth staging validated; ownership secrets remain environment references. No deployment was performed.'
    exit 0
}

if ($env:SKIP_PROVISION_PARAM_CHECK -eq 'true') {
    Write-Host '[provision-params] SKIP_PROVISION_PARAM_CHECK=true - skipping legacy backend/advisory checks only.' -ForegroundColor Yellow
    exit 0
}

$envName = if ($env:AZURE_ENV_NAME) { $env:AZURE_ENV_NAME } else { [string](Resolve-ParamValue $params 'envName') }
$envLabel = if ($envName) { $envName } else { 'main.parameters.json' }
$isPilot = $envName -match '-pilot$'

# ---- OPTION 2: Commercial Foundry route HARD gate -------------------------------------------
$deployComm = Resolve-ParamValue $params 'deployFoundryCommercial'
if ($deployComm -eq $true -or "$deployComm" -eq 'true') {
    $base     = [string](Resolve-ParamValue $params 'foundryCommercialBaseUrl')
    $tenant   = [string](Resolve-ParamValue $params 'foundryCommercialTenantId')
    $client   = [string](Resolve-ParamValue $params 'foundryCommercialClientId')
    $authMode = [string](Resolve-ParamValue $params 'foundryCommercialAuthMode')
    $secret   = [string](Resolve-ParamValue $params 'foundryCommercialClientSecret')

    $bad = @()
    if ([string]::IsNullOrWhiteSpace($base)   -or $base   -eq 'https://unset.invalid') { $bad += 'foundryCommercialBaseUrl (COMMERCIAL_FOUNDRY_BASE_URL)' }
    if ([string]::IsNullOrWhiteSpace($tenant) -or $tenant -eq 'organizations')         { $bad += 'foundryCommercialTenantId (COMMERCIAL_TENANT_ID)' }
    if ([string]::IsNullOrWhiteSpace($client) -or $client -eq 'unset')                 { $bad += 'foundryCommercialClientId (COMMERCIAL_CLIENT_ID)' }
    if ($authMode -eq 'servicePrincipal' -and [string]::IsNullOrWhiteSpace($secret))   { $bad += 'foundryCommercialClientSecret (COMMERCIAL_FOUNDRY_CLIENT_SECRET)' }

    if ($bad.Count -gt 0) {
        Write-Host ""
        Write-Host "COMMERCIAL BACKEND CHECK FAILED ($envLabel)." -ForegroundColor Red
        Write-Host "  deployFoundryCommercial=true, but these resolve to empty/placeholder:" -ForegroundColor Red
        foreach ($b in $bad) { Write-Host "    - $b" -ForegroundColor Red }
        Write-Host ""
        Write-Host "Provisioning now would OVERWRITE the live foundry-commercial-* APIM named values with" -ForegroundColor Yellow
        Write-Host "placeholders (base-url=https://unset.invalid, auth-mode=servicePrincipalFederated, ...)," -ForegroundColor Yellow
        Write-Host "breaking every commercial-model request (502). Classic 'local azd provision without the" -ForegroundColor Yellow
        Write-Host "COMMERCIAL_* env vars' wipe. Fix ONE of:" -ForegroundColor Yellow
        Write-Host "  1. Provision via CI (deploy.yml) - it exports COMMERCIAL_* from the env's GitHub settings."
        Write-Host "  2. Or export COMMERCIAL_FOUNDRY_BASE_URL, COMMERCIAL_TENANT_ID, COMMERCIAL_CLIENT_ID"
        Write-Host "     (+ COMMERCIAL_FOUNDRY_CLIENT_SECRET for servicePrincipal) before provisioning."
        Write-Host "  3. Or turn the backend off for this provision: deployFoundryCommercial=false."
        Write-Host "  4. Or intentional? Re-run with SKIP_PROVISION_PARAM_CHECK=true."
        exit 1
    }
    Write-Host "[provision-params] Commercial backend enabled and all COMMERCIAL_* values resolved. OK." -ForegroundColor Green
}

# ---- OPTION 3: general empty-${VAR} substitution scan (advisory; louder on pilots) ----------
$emptySubs = @()
foreach ($p in $params.PSObject.Properties) {
    $raw = $p.Value.value
    if ($raw -is [string] -and $raw -match '^\$\{(.+)\}$') {
        $varName = $Matches[1]
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($varName))) {
            $emptySubs += ('{0} (${{{1}}})' -f $p.Name, $varName)
        }
    }
}
if ($emptySubs.Count -gt 0) {
    Write-Host ""
    Write-Host "[provision-params] NOTE ($envLabel): $($emptySubs.Count) parameter(s) reference an env var that is EMPTY and will deploy blank:" -ForegroundColor Yellow
    foreach ($e in $emptySubs) { Write-Host "    - $e" -ForegroundColor Yellow }
    if ($isPilot) {
        Write-Host ""
        Write-Host "  This is a PILOT env. If any of the above are currently populated LIVE, this provision will WIPE them." -ForegroundColor Red
        Write-Host "  That is exactly what a LOCAL 'azd provision' missing the CI env vars does. Strongly prefer CI, or" -ForegroundColor Red
        Write-Host "  export the values first. (Intentional cases like the register Easy Auth two-phase bring-up are expected.)" -ForegroundColor Red
    }
}

exit 0
