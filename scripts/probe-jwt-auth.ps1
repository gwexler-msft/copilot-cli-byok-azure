#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('AzureCloud', 'AzureUSGovernment')]
    [string] $Cloud,
    [Parameter(Mandatory)]
    [string] $ResourceGroup,
    [Parameter(Mandatory)]
    [string] $ApimName,
    [Parameter(Mandatory)]
    [string] $VmName,
    [ValidatePattern('^jwt-probe-[a-z0-9-]+$')]
    [string] $ProbeId = ('jwt-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 12)),
    [switch] $TestExisting,
    [switch] $IncludeUserToken,
    [switch] $AddValidationControls,
    [switch] $AdmissionProbe,
    [switch] $ProductContextGuard,
    [switch] $OpenProductProbe,
    [switch] $ExpandedGate,
    [securestring] $ExpiredUserToken,
    [switch] $ValidateOnly
)

$ErrorActionPreference = 'Stop'
if ($ProductContextGuard -and -not $AdmissionProbe) { throw 'ProductContextGuard requires AdmissionProbe.' }
if ($OpenProductProbe -and (-not $AdmissionProbe -or $ProductContextGuard)) { throw 'OpenProductProbe requires AdmissionProbe and cannot use ProductContextGuard.' }
if ($ExpandedGate -and (-not $OpenProductProbe -or -not $ExpiredUserToken)) { throw 'ExpandedGate requires OpenProductProbe and an expired signed user token.' }
$source = Get-Content -Raw (Join-Path $PSScriptRoot '../policies/byok-foundry-policy.xml')
$authMatch = [regex]::Match($source, '(?s)<base\s*/>(?<auth>.*?)<!-- 4\. Extract developer identity')
if (-not $authMatch.Success -or $authMatch.Groups['auth'].Value -notmatch '</validate-jwt>') {
    throw 'Cannot locate the existing Foundry JWT authentication block.'
}
$authBlock = $authMatch.Groups['auth'].Value
$policy = @"
<policies><inbound>
$authBlock
<set-header name="api-key" exists-action="delete" />
<set-header name="Authorization" exists-action="delete" />
<set-variable name="probeCredentialsStripped" value="@(!context.Request.Headers.ContainsKey("api-key") &amp;&amp; !context.Request.Headers.ContainsKey("Authorization"))" />
<return-response>
  <set-status code="200" reason="JWT probe accepted" />
  <set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header>
  <set-header name="X-JWT-Probe" exists-action="override"><value>$ProbeId</value></set-header>
    <set-header name="X-JWT-Probe-Credentials-Stripped" exists-action="override"><value>@(((bool)context.Variables["probeCredentialsStripped"]).ToString())</value></set-header>
  <set-body>{"probe":"jwt-auth-only","validated":true,"backendCalled":false}</set-body>
</return-response>
</inbound><backend /><outbound /><on-error /></policies>
"@
if ($ValidateOnly) {
    if ([regex]::Matches($policy, '<validate-jwt\b').Count -ne 1 -or $policy -match '<(?:forward-request|send-request|set-backend-service)\b') {
        throw 'Probe must contain exactly one validator and no backend call.'
    }
    if ($policy -notmatch '\{\{entra-openid-config-url\}\}' -or $policy -notmatch '\{\{api-audience\}\}' -or $policy -notmatch '\{\{required-scope\}\}') {
        throw 'Probe must preserve the existing issuer, audience and scope settings.'
    }
    'PASS: authentication extraction and no-backend probe checks.'
    return
}

$cloudRaw = & az cloud show -o json --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Cannot read the current Azure cloud.' }
$cloudInfo = $cloudRaw | ConvertFrom-Json
if ($cloudInfo.name -ne $Cloud) { throw 'Wrong Azure cloud. Use the separately pinned terminal; this script never switches clouds.' }
$accountRaw = & az account show -o json --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Azure sign-in required in the pinned terminal.' }
$account = $accountRaw | ConvertFrom-Json
$tokenRaw = & az account get-access-token --resource-type arm -o json --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) { throw 'ARM authentication failed. Reauthenticate in the pinned terminal.' }
$armCredential = $tokenRaw | ConvertFrom-Json
$armHeaders = @{ Authorization = 'Bearer ' + $armCredential.accessToken }
$serviceId = "/subscriptions/$($account.id)/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"
$armBase = $cloudInfo.endpoints.resourceManager.TrimEnd('/')

function Invoke-ProbeArm {
    param([string] $Method, [string] $Path, [object] $Body)
    $request = @{ Method = $Method; Uri = "$armBase${Path}?api-version=2024-05-01"; Headers = $armHeaders }
    if ($null -ne $Body) {
        $request.ContentType = 'application/json'
        $request.Body = $Body | ConvertTo-Json -Depth 30 -Compress
    }
    try { Invoke-RestMethod @request }
    catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $code = ''
        try { $code = ($_.ErrorDetails.Message | ConvertFrom-Json).error.code } catch { }
        throw "Probe ARM request failed: HTTP $status $code. No response body or credentials displayed."
    }
}

function Invoke-ProbeVm {
    param([string[]] $Parameters)
    $remoteFile = Join-Path $PSScriptRoot 'probe-jwt-auth-vm.ps1'
    $temporaryScript = $null
    try {
        $scriptText = Get-Content -Raw $remoteFile
        $shortParameters = @()
        foreach ($parameter in $Parameters) {
            if ($parameter -match '^(ProtectedToken|ProtectedExpiredToken)=([A-Za-z0-9+/=]+)$') {
                $parameterName = $Matches[1]
                $ciphertextValue = $Matches[2]
                $scriptText = $scriptText.Replace('[string] $' + $parameterName + ',', '[string] $' + $parameterName + " = '$ciphertextValue',")
            } else {
                $shortParameters += $parameter
            }
        }
        if ($shortParameters.Count -ne $Parameters.Count) {
            $temporaryScript = Join-Path ([IO.Path]::GetTempPath()) ('jwt-probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
            [IO.File]::WriteAllText($temporaryScript, $scriptText, [Text.UTF8Encoding]::new($true))
            $remoteFile = $temporaryScript
        }
        $resultRaw = & az vm run-command invoke --resource-group $ResourceGroup --name $VmName --command-id RunPowerShellScript --scripts "@$remoteFile" --parameters @shortParameters -o json --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) { throw "VM probe invocation failed. Probe API $ProbeId remains; no existing API was changed." }
    } finally {
        if ($temporaryScript) { Remove-Item -LiteralPath $temporaryScript -Force }
    }
    $result = $resultRaw | ConvertFrom-Json
    $resultCount = 0
    foreach ($entry in $result.value) {
        foreach ($line in ($entry.message -split '\r?\n')) {
            if ($line -match '^\{"test":') {
                $resultCount++
                $row = $line | ConvertFrom-Json
                if ($row.test -eq 'compressed-admission') {
                    $stream = [IO.MemoryStream]::new([Convert]::FromBase64String($row.data))
                    $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Decompress)
                    $reader = [IO.StreamReader]::new($gzip)
                    try { $row = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose(); $gzip.Dispose(); $stream.Dispose() }
                }
                if ($row.test -eq 'native-admission-observations') {
                    $expanded = @($row.rows | ForEach-Object { [pscustomobject]@{ case = $_[0]; http = $_[1]; ctx = $_[2]; passed = $_[3] } })
                    [pscustomobject]@{ test = $row.test; results = $expanded }
                } else {
                    $row
                }
            }
        }
    }
    if ($resultCount -eq 0) {
        $messages = ($result.value | ForEach-Object { $_.message }) -join "`n"
        $categories = @('ParserError', 'ParameterBinding', 'Unprotect-CmsMessage', 'ConvertFrom-Json', 'OutOfMemory', 'cannot find', 'Access is denied') | Where-Object { $messages -match [regex]::Escape($_) }
        throw "VM returned no structured results (characters=$($messages.Length); categories=$($categories -join ',')). Details suppressed to protect credentials."
    }
}

$certificatePrepared = $false
$certificateRemoved = $false
try {
    if ($ExpiredUserToken -and -not $IncludeUserToken) { throw 'Expiry replay requires IncludeUserToken for a fresh positive control.' }
    if ($ExpiredUserToken) {
        $expiredPlaintext = ConvertFrom-SecureString $ExpiredUserToken -AsPlainText
        $encodedClaims = $expiredPlaintext.Split('.')[1].Replace('-', '+').Replace('_', '/')
        $encodedClaims = $encodedClaims.PadRight($encodedClaims.Length + ((4 - $encodedClaims.Length % 4) % 4), '=')
        $expiryClaims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedClaims)) | ConvertFrom-Json
        if (-not $expiryClaims.exp -or [DateTimeOffset]::FromUnixTimeSeconds($expiryClaims.exp).AddMinutes(5) -gt [DateTimeOffset]::UtcNow) {
            throw 'Captured token has not expired beyond the five-minute clock-skew allowance; retry later without changing the signed token.'
        }
    }
    $existing = Invoke-ProbeArm GET "$serviceId/apis"
    $matching = @($existing.value | Where-Object { $_.name -eq $ProbeId -or $_.properties.path -eq $ProbeId })
    if ($TestExisting) {
        if ($matching.Count -ne 1 -or $matching[0].name -ne $ProbeId -or $matching[0].properties.path -ne $ProbeId -or $matching[0].properties.displayName -ne 'Isolated JWT authentication probe') {
            throw 'Existing API does not match the isolated probe contract.'
        }
    } elseif ($matching.Count) {
        throw 'Probe ID/path already exists. Refusing to overwrite it.'
    }
    $service = Invoke-ProbeArm GET $serviceId
    $gateway = $service.properties.gatewayUrl.TrimEnd('/')
    $apiPath = "$serviceId/apis/$ProbeId"
    if (-not $TestExisting) {
        $null = Invoke-ProbeArm PUT $apiPath @{ properties = @{ displayName = 'Isolated JWT authentication probe'; path = $ProbeId; protocols = @('https'); subscriptionRequired = $false; description = 'Temporary auth-only probe. No model backend. Existing APIs unchanged.' } }
        Write-Output "Created isolated API: $ProbeId"
        $null = Invoke-ProbeArm PUT "$apiPath/policies/policy" @{ properties = @{ format = 'rawxml'; value = $policy } }
        $null = Invoke-ProbeArm PUT "$apiPath/operations/check" @{ properties = @{ displayName = 'Validate JWT without inference'; method = 'GET'; urlTemplate = '/check'; responses = @() } }
        Write-Output 'APIM accepted the existing JWT validation block. No backend is configured.'
    }
    if ($AddValidationControls) {
        $operations = Invoke-ProbeArm GET "$apiPath/operations"
        foreach ($control in @('wrong-audience', 'wrong-scope')) {
            if (@($operations.value | Where-Object name -eq $control).Count) { throw 'Validation control already exists; refusing to overwrite it.' }
        }
        foreach ($control in @('wrong-audience', 'wrong-scope')) {
            $controlPolicy = if ($control -eq 'wrong-audience') {
                $policy.Replace('{{api-audience}}', 'api://jwt-probe-deliberately-wrong-audience')
            } else {
                $policy.Replace('{{required-scope}}', 'jwt.probe.deliberately.ungranted')
            }
            $null = Invoke-ProbeArm PUT "$apiPath/operations/$control" @{ properties = @{ displayName = "JWT rejection control: $control"; method = 'GET'; urlTemplate = "/$control"; responses = @() } }
            $null = Invoke-ProbeArm PUT "$apiPath/operations/$control/policies/policy" @{ properties = @{ format = 'rawxml'; value = $controlPolicy } }
        }
        Write-Output 'Added isolated wrong-audience and ungranted-scope validation controls.'
    }
    $admissionSecrets = $null
    if ($AdmissionProbe) {
        if (-not $IncludeUserToken) { throw 'Admission testing requires IncludeUserToken.' }
        $admissionPrefix = $ProbeId + '-admission-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
        $productId = $admissionPrefix + '-product'
        $productPath = "$serviceId/products/$productId"
        $productPolicy = '<policies><inbound><set-variable name="probeProductPolicy" value="@(true)" /><choose><when condition="@(context.Subscription.Id.EndsWith("-throttle"))"><rate-limit-by-key calls="3" renewal-period="300" counter-key="@(context.Subscription.Id + context.Api.Id)" /></when></choose></inbound><backend /><outbound /><on-error /></policies>'
        $null = Invoke-ProbeArm PUT $productPath @{ properties = @{ displayName = "$admissionPrefix product"; subscriptionRequired = $true; approvalRequired = $false; state = 'published' } }
        $null = Invoke-ProbeArm PUT "$productPath/policies/policy" @{ properties = @{ format = 'rawxml'; value = $productPolicy } }
        $otherProductPath = "$serviceId/products/$admissionPrefix-other-product"
        $null = Invoke-ProbeArm PUT $otherProductPath @{ properties = @{ displayName = "$admissionPrefix unlinked product"; subscriptionRequired = $true; approvalRequired = $false; state = 'published' } }
        $admissionPolicy = @'
<policies><inbound><base />
<choose><when condition="@(context.Subscription == null)">
<choose><when condition="@(context.Request.Headers.GetValueOrDefault("Authorization", "").StartsWith("Bearer "))">
<set-header name="api-key" exists-action="override"><value>@(context.Request.Headers.GetValueOrDefault("Authorization", "").Substring(7))</value></set-header>
</when></choose>
__AUTH_BLOCK__
</when></choose>
<set-variable name="probeHasSubscription" value="@(context.Subscription != null)" />
<set-variable name="probeHasProduct" value="@(context.Product != null)" />
<set-header name="api-key" exists-action="delete" />
<set-header name="Authorization" exists-action="delete" />
<return-response><set-status code="200" reason="Isolated admission probe" />
<set-header name="X-Probe-Subscription" exists-action="override"><value>@(((bool)context.Variables["probeHasSubscription"]).ToString())</value></set-header>
<set-header name="X-Probe-Product" exists-action="override"><value>@(((bool)context.Variables["probeHasProduct"]).ToString())</value></set-header>
<set-header name="X-Probe-Product-Policy" exists-action="override"><value>@(context.Variables.ContainsKey("probeProductPolicy") ? "True" : "False")</value></set-header>
<set-body>{"probe":"admission-only","backendCalled":false}</set-body>
</return-response></inbound><backend /><outbound /><on-error>
<set-header name="X-Probe-Error" exists-action="override"><value>@(context.LastError.Reason)</value></set-header>
</on-error></policies>
'@.Replace('__AUTH_BLOCK__', $authBlock)
    if ($ProductContextGuard) {
        $guard = @'
<choose><when condition="@((context.Request.Headers.ContainsKey("api-key") &amp;&amp; context.Request.Headers.ContainsKey("Authorization")) || context.Request.OriginalUrl.Query.ContainsKey("api-key") || context.Request.Headers.ContainsKey("x-api-key") || context.Request.Headers.ContainsKey("Ocp-Apim-Subscription-Key"))">
<return-response><set-status code="401" reason="Ambiguous or unsupported credential source" /></return-response>
</when></choose>
<base />
<choose><when condition="@(context.Subscription != null &amp;&amp; (context.Product == null || !context.Variables.ContainsKey("probeProductPolicy")))">
<return-response><set-status code="401" reason="Subscription lacks authorized product context" /></return-response>
</when></choose>
'@
        $admissionPolicy = $admissionPolicy.Replace('<policies><inbound><base />', '<policies><inbound>' + $guard)
    }
        $admissionUrls = @{}
        $modes = if ($OpenProductProbe) { @('required') } else { @('required', 'optional') }
        if ($OpenProductProbe) {
            $openProductId = "$admissionPrefix-open"
            $openProductPath = "$serviceId/products/$openProductId"
            $conflictGuard = @'
<choose><when condition="@((context.Request.Headers.ContainsKey("api-key") &amp;&amp; context.Request.Headers.ContainsKey("Authorization")) || context.Request.OriginalUrl.Query.ContainsKey("api-key") || context.Request.Headers.ContainsKey("x-api-key") || context.Request.Headers.ContainsKey("Ocp-Apim-Subscription-Key"))">
<return-response><set-status code="401" reason="Ambiguous or unsupported probe credential source" /></return-response>
</when></choose>
'@
            $admissionPolicy = $admissionPolicy.Replace('<policies><inbound><base />', '<policies><inbound>' + $conflictGuard)
            $admissionPolicy = $admissionPolicy.Replace('context.Subscription == null', 'context.Subscription == null || (context.Product != null &amp;&amp; context.Product.Id == "' + $openProductId + '")')
            $admissionPolicy = $admissionPolicy.Replace($authBlock, $authBlock + '<set-variable name="probeJwtValidated" value="@(true)" />')
            $admissionPolicy = $admissionPolicy.Replace('<set-variable name="probeHasSubscription"', '<base /><set-variable name="probeHasSubscription"')
            $contextHeader = '<set-header name="X-Probe-Context" exists-action="override"><value>@((context.Subscription != null ? "1" : "0") + (context.Product != null ? "1" : "0") + (context.Variables.ContainsKey("probeProductPolicy") ? "1" : "0") + (context.Variables.ContainsKey("probeJwtValidated") ? "1" : "0"))</value></set-header>'
            $admissionPolicy = $admissionPolicy.Replace('<set-body>{"probe":"admission-only"', $contextHeader + '<set-body>{"probe":"admission-only"')
            $admissionPolicy = $admissionPolicy.Replace('<on-error>', '<on-error>' + $contextHeader)
            if ($ExpandedGate) {
                $expandedConflict = @'
<choose><when condition="@{
    var headerKey = context.Request.Headers.ContainsKey("api-key");
    var bearer = context.Request.Headers.ContainsKey("Authorization");
    var queryKey = context.Request.OriginalUrl.Query.ContainsKey("api-key");
    var sourceCount = (headerKey ? 1 : 0) + (bearer ? 1 : 0) + (queryKey ? 1 : 0);
    var keyValue = context.Request.Headers.GetValueOrDefault("api-key", "");
    var authValue = context.Request.Headers.GetValueOrDefault("Authorization", "");
    var queryValue = context.Request.OriginalUrl.Query.GetValueOrDefault("api-key", "");
    return sourceCount != 1 || context.Request.Headers.ContainsKey("x-api-key") || context.Request.Headers.ContainsKey("Ocp-Apim-Subscription-Key") || context.Request.OriginalUrl.Query.ContainsKey("subscription-key")
        || (headerKey &amp;&amp; (context.Request.Headers["api-key"].Length != 1 || string.IsNullOrWhiteSpace(keyValue) || keyValue.Contains(",")))
        || (bearer &amp;&amp; (context.Request.Headers["Authorization"].Length != 1 || !authValue.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) || string.IsNullOrWhiteSpace(authValue.Substring(7)) || authValue.Contains(",")))
        || (queryKey &amp;&amp; (context.Request.OriginalUrl.Query["api-key"].Length != 1 || string.IsNullOrWhiteSpace(queryValue) || queryValue.Contains(",") || context.Subscription == null || (context.Product != null &amp;&amp; context.Product.Id == "__OPEN_PRODUCT__")));
}"><return-response><set-status code="401" reason="Invalid credential sources" /></return-response></when></choose>
'@.Replace('__OPEN_PRODUCT__', $openProductId)
                $identityGuard = @'
<choose><when condition="@(string.IsNullOrWhiteSpace(((Jwt)context.Variables["parsedJwt"]).Claims.GetValueOrDefault("tid", "")) || string.IsNullOrWhiteSpace(((Jwt)context.Variables["parsedJwt"]).Claims.GetValueOrDefault("oid", "")))">
<return-response><set-status code="401" reason="Missing stable identity" /></return-response>
</when></choose>
'@
                $admissionPolicy = $admissionPolicy.Replace($conflictGuard, $expandedConflict).Replace('.StartsWith("Bearer ")', '.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)')
                $admissionPolicy = $admissionPolicy.Replace('<claim name="scp" match="any">', '<claim name="scp" match="any" separator=" ">')
                $admissionPolicy = $admissionPolicy.Replace('<set-variable name="probeJwtValidated"', $identityGuard + '<set-variable name="probeJwtValidated"')
                $stripCheck = '<set-query-parameter name="api-key" exists-action="delete" /><set-variable name="probeStripped" value="@(!context.Request.Headers.ContainsKey("api-key") &amp;&amp; !context.Request.Headers.ContainsKey("Authorization") &amp;&amp; !context.Request.Url.Query.ContainsKey("api-key"))" />'
                $admissionPolicy = $admissionPolicy.Replace('<return-response><set-status code="200"', $stripCheck + '<return-response><set-status code="200"')
                $admissionPolicy = $admissionPolicy.Replace('<set-body>{"probe":"admission-only"', '<set-header name="X-Probe-Stripped" exists-action="override"><value>@(((bool)context.Variables["probeStripped"]).ToString())</value></set-header><set-body>{"probe":"admission-only"')
            }
            $null = Invoke-ProbeArm PUT $openProductPath @{ properties = @{ displayName = "$admissionPrefix JWT guarded open product"; subscriptionRequired = $false; state = 'notPublished' } }
            $openPolicy = '<policies><inbound><choose><when condition="@(!context.Variables.ContainsKey("probeJwtValidated"))"><return-response><set-status code="401" reason="JWT gate must run first" /></return-response></when></choose></inbound><backend /><outbound /><on-error /></policies>'
            $null = Invoke-ProbeArm PUT "$openProductPath/policies/policy" @{ properties = @{ format = 'rawxml'; value = $openPolicy } }
        }
        foreach ($mode in $modes) {
            $admissionApiId = "$admissionPrefix-$mode"
            $admissionApiPath = "$serviceId/apis/$admissionApiId"
            $null = Invoke-ProbeArm PUT $admissionApiPath @{ properties = @{ displayName = "$admissionPrefix $mode"; path = $admissionApiId; protocols = @('https'); subscriptionRequired = ($mode -eq 'required'); subscriptionKeyParameterNames = @{ header = 'api-key'; query = 'api-key' } } }
            $null = Invoke-ProbeArm PUT "$admissionApiPath/policies/policy" @{ properties = @{ format = 'rawxml'; value = $admissionPolicy } }
            $null = Invoke-ProbeArm PUT "$admissionApiPath/operations/check" @{ properties = @{ displayName = 'Admission check'; method = 'GET'; urlTemplate = '/check'; responses = @() } }
            $null = Invoke-ProbeArm PUT "$productPath/apis/$admissionApiId" @{}
            $admissionUrls[$mode] = "$gateway/$admissionApiId/check"
            if ($OpenProductProbe) {
                $null = Invoke-ProbeArm PUT "$admissionApiPath/operations/explicit" @{ properties = @{ displayName = 'Explicit auth without inheritance'; method = 'GET'; urlTemplate = '/explicit'; responses = @() } }
                $null = Invoke-ProbeArm PUT "$admissionApiPath/operations/explicit/policies/policy" @{ properties = @{ format = 'rawxml'; value = $admissionPolicy.Replace('<base />', '') } }
                $admissionUrls.inherited = "$gateway/$admissionApiId/check"
                $admissionUrls.explicit = "$gateway/$admissionApiId/explicit"
                if ($ExpandedGate) {
                    foreach ($surface in @('inherited', 'explicit')) {
                        $surfacePolicy = $admissionPolicy.Replace('<base />', '')
                        foreach ($control in @('audience', 'scope', 'issuer', 'identity', 'jwt-limit')) {
                            $controlPolicy = switch ($control) {
                                'audience' { $surfacePolicy.Replace('{{api-audience}}', 'api://probe-wrong-audience') }
                                'scope' { $surfacePolicy.Replace('{{required-scope}}', 'probe.ungranted') }
                                'issuer' { $surfacePolicy.Replace('<required-claims>', '<required-claims><claim name="iss" match="all"><value>https://invalid.example/probe-issuer</value></claim>') }
                                'identity' { $surfacePolicy.Replace('GetValueOrDefault("oid", "")', 'GetValueOrDefault("probe_deliberately_missing_identity", "")') }
                                'jwt-limit' { $surfacePolicy.Replace('<set-variable name="probeHasSubscription"', '<choose><when condition="@(context.Variables.ContainsKey("probeJwtValidated"))"><rate-limit-by-key calls="3" renewal-period="300" counter-key="@(((Jwt)context.Variables["parsedJwt"]).Issuer + ((Jwt)context.Variables["parsedJwt"]).Claims.GetValueOrDefault("tid", "") + ((Jwt)context.Variables["parsedJwt"]).Claims.GetValueOrDefault("oid", "") + context.Api.Id + context.Operation.Id)" /></when></choose><set-variable name="probeHasSubscription"') }
                            }
                            $controlId = "$surface-$control"
                            $null = Invoke-ProbeArm PUT "$admissionApiPath/operations/$controlId" @{ properties = @{ displayName = "Isolated $controlId control"; method = 'GET'; urlTemplate = "/$controlId"; responses = @() } }
                            $null = Invoke-ProbeArm PUT "$admissionApiPath/operations/$controlId/policies/policy" @{ properties = @{ format = 'rawxml'; value = $controlPolicy } }
                            $admissionUrls[$controlId] = "$gateway/$admissionApiId/$controlId"
                        }
                    }
                }
                $null = Invoke-ProbeArm PUT "$openProductPath/apis/$admissionApiId" @{}
            }
        }
        $admissionSecrets = @{ urls = $admissionUrls; keys = @{}; openProduct = [bool]$OpenProductProbe; expanded = [bool]$ExpandedGate }
        $kinds = if ($OpenProductProbe) { @('active', 'wrongScope', 'wrongProduct', 'apiRequired', 'allApis') } else { @('active', 'suspended', 'wrongScope', 'wrongProduct', 'rotated', 'throttle', 'apiRequired', 'apiOptional', 'allApis') }
        if ($ExpandedGate) { $kinds += @('suspended', 'rotated', 'throttle', 'other-throttle') }
        foreach ($kind in $kinds) {
            $subscriptionPath = "$serviceId/subscriptions/$admissionPrefix-$kind"
            $primary = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
            $secondary = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
            $subscriptionScope = if ($kind -eq 'wrongScope') { "$serviceId/apis/$ProbeId" } else { $productPath }
            if ($kind -eq 'wrongProduct') { $subscriptionScope = $otherProductPath }
            if ($kind -eq 'apiRequired') { $subscriptionScope = "$serviceId/apis/$admissionPrefix-required" }
            if ($kind -eq 'apiOptional') { $subscriptionScope = "$serviceId/apis/$admissionPrefix-optional" }
            if ($kind -eq 'allApis') { $subscriptionScope = "$serviceId/apis" }
            $subscriptionState = if ($kind -eq 'suspended') { 'suspended' } else { 'active' }
            $null = Invoke-ProbeArm PUT $subscriptionPath @{ properties = @{ displayName = "$admissionPrefix $kind"; scope = $subscriptionScope; state = $subscriptionState; primaryKey = $primary; secondaryKey = $secondary } }
            $admissionSecrets.keys[$kind] = $primary
            if ($kind -eq 'active') { $admissionSecrets.keys.secondary = $secondary }
            if ($kind -eq 'rotated') {
                $admissionSecrets.keys.rotatedOld = $primary
                $newPrimary = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
                $null = Invoke-ProbeArm PATCH $subscriptionPath @{ properties = @{ primaryKey = $newPrimary } }
                $admissionSecrets.keys.rotated = $newPrimary
            }
        }
        Write-Output "Created isolated admission resources: $admissionPrefix"
    }
    $vmParameters = @("GatewayUri=$gateway/$ProbeId/check", "ArmResource=$($cloudInfo.endpoints.activeDirectoryResourceId)", "ProbeId=$ProbeId")
    $operations = Invoke-ProbeArm GET "$apiPath/operations"
    if (@($operations.value | Where-Object { $_.name -in @('wrong-audience', 'wrong-scope') }).Count -eq 2) {
        $vmParameters += 'ValidationControls=true'
    }
    if ($IncludeUserToken) {
        $appUri = Invoke-ProbeArm GET "$serviceId/namedValues/api-app-id-uri"
        $scope = $appUri.properties.value.TrimEnd('/') + '/.default'
        $userRaw = & az account get-access-token --scope $scope -o json --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Gateway-scoped user token unavailable; sign in securely in the pinned terminal.' }
        $userCredential = $userRaw | ConvertFrom-Json
        $publicResult = @(Invoke-ProbeVm -Parameters @('Phase=Prepare', "ArmResource=$($cloudInfo.endpoints.activeDirectoryResourceId)", "ProbeId=$ProbeId"))
        $publicMaterial = @($publicResult | Where-Object test -eq 'transport-certificate')
        if ($publicMaterial.Count -ne 1) { throw 'VM certificate preparation failed. No user token was sent.' }
        $certificatePrepared = $true
        $publicCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($publicMaterial[0].publicCertificate))
        if ($admissionSecrets) {
            $admissionSecrets.userToken = $userCredential.accessToken
            $encrypted = Protect-CmsMessage -To $publicCertificate -Content ($admissionSecrets | ConvertTo-Json -Depth 10 -Compress)
            $vmParameters += 'AdmissionPayload=true'
        } else {
            $encrypted = Protect-CmsMessage -To $publicCertificate -Content $userCredential.accessToken
        }
        $vmParameters += 'ProtectedToken=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($encrypted))
        if ($ExpiredUserToken) {
            $encryptedExpiry = Protect-CmsMessage -To $publicCertificate -Content $expiredPlaintext
            $vmParameters += 'ProtectedExpiredToken=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($encryptedExpiry))
        }
        $userCredential = $null
        $userRaw = $null
    }
    $testResults = @(Invoke-ProbeVm -Parameters $vmParameters)
    $certificateRemoved = @($testResults | Where-Object { $_.test -eq 'temporary-transport-certificate-removed' -and $_.passed }).Count -eq 1
    $testResults | ForEach-Object { $_ | ConvertTo-Json -Compress }
    if ($testResults.Count -lt 6) { throw "VM returned incomplete probe results. Probe API $ProbeId remains; inspect sanitized VM diagnostics." }
    $requiredTests = @('missing-credential', 'malformed-token', 'bearer-only-current-contract')
    if ($IncludeUserToken) { $requiredTests += @('valid-delegated-user-token-and-credential-stripping', 'tampered-signature', 'temporary-transport-certificate-removed') }
    if ($ExpiredUserToken) { $requiredTests += 'expired-signed-user-token' }
    foreach ($testName in $requiredTests) {
        $matchingResults = @($testResults | Where-Object test -eq $testName)
        if ($matchingResults.Count -ne 1 -or $matchingResults[0].passed -ne $true) { throw "Required probe assertion missing or failed: $testName" }
    }
    if ($AdmissionProbe) {
        $matrix = @($testResults | Where-Object test -eq 'native-admission-observations')
        $expandedCases = @('secondary', 'suspended', 'rotated-old', 'rotated-new', 'invalid', 'empty', 'empty-bearer', 'key-plus-jwt', 'invalid-plus-jwt', 'jwt-plus-jwt', 'duplicate-key', 'duplicate-bearer', 'query-key', 'query-jwt', 'query-conflict', 'duplicate-query', 'tampered', 'expired', 'audience', 'scope', 'issuer', 'identity', 'limit-1', 'limit-2', 'limit-3', 'limit-4', 'limit-isolated', 'jwt-limit-1', 'jwt-limit-2', 'jwt-limit-3', 'jwt-limit-4')
        $expectedCount = if ($ExpandedGate) { 16 + 2 * $expandedCases.Count } elseif ($OpenProductProbe) { 16 } else { 40 }
        if ($matrix.Count -ne 1 -or @($matrix[0].results).Count -ne $expectedCount) { throw 'Incomplete native admission matrix; do not infer coexistence readiness.' }
        if ($OpenProductProbe) {
            $expectedNames = @(foreach ($surface in @('i', 'e')) { foreach ($caseName in @('active', 'api-scoped', 'all-apis', 'jwt-api-key', 'jwt-bearer', 'wrong-scope', 'wrong-product', 'missing')) { "$surface-$caseName" } })
            if ($ExpandedGate) { $expectedNames += @(foreach ($surface in @('i', 'e')) { foreach ($caseName in $expandedCases) { "$surface-$caseName" } }) }
            if (Compare-Object ($expectedNames | Sort-Object) (@($matrix[0].results.case) | Sort-Object)) { throw 'Open-product matrix case names do not match the required gate.' }
        }
        $failures = @($matrix[0].results | Where-Object { -not $_.passed })
        if ($failures.Count) {
            if ($OpenProductProbe) { throw ('Open-product admission gate failed: ' + ($failures.case -join ', ')) }
            Write-Warning ('Native admission contract NOT satisfied: ' + (($failures | ForEach-Object { $_.case }) -join ', '))
        }
    }
    if (@($testResults | Where-Object { $_.passed -eq $false }).Count) { throw 'One or more probe assertions failed; do not infer authentication readiness.' }
    Write-Output "Probe retained for follow-up: $ProbeId. Existing APIs unchanged."
} finally {
    if ($certificatePrepared -and -not $certificateRemoved) {
        $cleanup = @(Invoke-ProbeVm -Parameters @('Phase=Cleanup', "ArmResource=$($cloudInfo.endpoints.activeDirectoryResourceId)", "ProbeId=$ProbeId"))
        $cleanup | ForEach-Object { $_ | ConvertTo-Json -Compress }
    }
    $armHeaders.Clear()
    $armCredential = $null
    $tokenRaw = $null
    $userRaw = $null
    $userCredential = $null
    $admissionSecrets = $null
    $primary = $null
    $secondary = $null
    $newPrimary = $null
    $expiredPlaintext = $null
    $encodedClaims = $null
    $expiryClaims = $null
}