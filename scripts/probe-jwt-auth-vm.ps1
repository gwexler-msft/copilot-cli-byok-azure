#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Prepare', 'Test', 'Cleanup')]
    [string] $Phase = 'Test',
    [ValidatePattern('^jwt-probe-[a-z0-9-]+$')]
    [string] $ProbeId,
    [string] $ProtectedToken,
    [string] $ProtectedExpiredToken,
    [ValidateSet('true', 'false')]
    [string] $AdmissionPayload = 'false',
    [ValidateSet('true', 'false')]
    [string] $ValidationControls = 'false',
    [uri] $GatewayUri,
    [Parameter(Mandatory)]
    [uri] $ArmResource
)

$ErrorActionPreference = 'Stop'
if ($Phase -eq 'Cleanup') {
    if (-not $ProbeId) { throw 'A probe ID is required for cleanup.' }
    Get-ChildItem Cert:\LocalMachine\My | Where-Object Subject -eq "CN=$ProbeId" | ForEach-Object { Remove-Item -LiteralPath $_.PSPath -DeleteKey -Force }
    [pscustomobject]@{ test = 'temporary-transport-certificate-removed'; passed = $true } | ConvertTo-Json -Compress
    return
}
if ($Phase -eq 'Prepare') {
    if (-not $ProbeId) { throw 'A probe ID is required for the temporary certificate.' }
    if (@(Get-ChildItem Cert:\LocalMachine\My | Where-Object Subject -eq "CN=$ProbeId").Count) {
        throw 'Probe certificate already exists. Refusing to replace it.'
    }
    $certificate = New-SelfSignedCertificate -Type DocumentEncryptionCert -Subject "CN=$ProbeId" -CertStoreLocation Cert:\LocalMachine\My -KeyExportPolicy NonExportable -KeyLength 2048 -NotAfter (Get-Date).AddHours(2)
    [pscustomobject]@{ test = 'transport-certificate'; publicCertificate = [Convert]::ToBase64String($certificate.RawData) } | ConvertTo-Json -Compress
    return
}
if ($GatewayUri.Scheme -ne 'https') { throw 'The probe requires HTTPS.' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Test-ProbeRequest {
    param([string] $Name, [hashtable] $Headers, [int] $Expected, [uri] $RequestUri = $GatewayUri)
    $status = 0
    $stripped = $false
    $matchedProbe = $false
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $RequestUri -Headers $Headers -TimeoutSec 45
        $status = [int]$response.StatusCode
        $stripped = $response.Headers['X-JWT-Probe-Credentials-Stripped'] -eq 'True'
        $matchedProbe = $response.Headers['X-JWT-Probe'] -eq $ProbeId
    } catch {
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    }
    $passed = $status -eq $Expected
    if ($Expected -eq 200) { $passed = $passed -and $stripped -and $matchedProbe }
    [pscustomobject]@{ test = $Name; expected = $Expected; actual = $status; passed = $passed } | ConvertTo-Json -Compress
}

Test-ProbeRequest 'missing-credential' @{} 401
Test-ProbeRequest 'malformed-token' @{ 'api-key' = 'not-a-jwt' } 401
Test-ProbeRequest 'bearer-only-current-contract' @{ Authorization = 'Bearer not-a-jwt' } 401
try {
    $tokenUri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' + [uri]::EscapeDataString($ArmResource.AbsoluteUri)
    $managedToken = Invoke-RestMethod -Headers @{ Metadata = 'true' } -Uri $tokenUri -TimeoutSec 20
    Test-ProbeRequest 'managed-identity-arm-token-not-user-gateway-token' @{ 'api-key' = $managedToken.access_token } 401
} catch {
    [pscustomobject]@{ test = 'managed-identity-arm-token-not-user-gateway-token'; status = 'NOT_RUN'; reason = 'VM managed identity token unavailable' } | ConvertTo-Json -Compress
} finally {
    $managedToken = $null
}
if ($ProtectedToken) {
    $certificates = @(Get-ChildItem Cert:\LocalMachine\My | Where-Object Subject -eq "CN=$ProbeId")
    if ($certificates.Count -ne 1) { throw 'Expected one temporary probe certificate.' }
    try {
        $ciphertext = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ProtectedToken))
        $userToken = Unprotect-CmsMessage -To $certificates[0] -Content $ciphertext
        if ($AdmissionPayload -eq 'true') {
            $admission = $userToken | ConvertFrom-Json
            $userToken = $admission.userToken
        }
        Test-ProbeRequest 'valid-delegated-user-token-and-credential-stripping' @{ 'api-key' = $userToken } 200
        if ($ProtectedExpiredToken) {
            $expiredCiphertext = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ProtectedExpiredToken))
            $expiredToken = Unprotect-CmsMessage -To $certificates[0] -Content $expiredCiphertext
            Test-ProbeRequest 'expired-signed-user-token' @{ 'api-key' = $expiredToken } 401
        }
        $parts = $userToken.Split('.')
        $replacement = if ($parts[2][0] -eq 'A') { 'B' } else { 'A' }
        $badSignatureToken = $parts[0] + '.' + $parts[1] + '.' + $replacement + $parts[2].Substring(1)
        Test-ProbeRequest 'tampered-signature' @{ 'api-key' = $badSignatureToken } 401
        if ($ValidationControls -eq 'true') {
            $baseUri = $GatewayUri.AbsoluteUri.Substring(0, $GatewayUri.AbsoluteUri.LastIndexOf('/'))
            Test-ProbeRequest 'valid-token-deliberately-wrong-audience-policy' @{ 'api-key' = $userToken } 401 -RequestUri "$baseUri/wrong-audience"
            Test-ProbeRequest 'valid-token-deliberately-ungranted-scope-policy' @{ 'api-key' = $userToken } 401 -RequestUri "$baseUri/wrong-scope"
        }
        if ($AdmissionPayload -eq 'true') {
            $observations = @()
            if ($admission.openProduct) {
                foreach ($surface in @('inherited', 'explicit')) {
                    $cases = @(
                        @{ name = 'active'; headers = @{ 'api-key' = $admission.keys.active }; expected = 200; context = $(if ($surface -eq 'inherited') { '1110' } else { '1100' }) },
                        @{ name = 'api-scoped'; headers = @{ 'api-key' = $admission.keys.apiRequired }; expected = 200; context = '1000' },
                        @{ name = 'all-apis'; headers = @{ 'api-key' = $admission.keys.allApis }; expected = 200; context = '1000' },
                        @{ name = 'jwt-api-key'; headers = @{ 'api-key' = $userToken }; expected = 200; context = '0101' },
                        @{ name = 'jwt-bearer'; headers = @{ Authorization = 'Bearer ' + $userToken }; expected = 200; context = '0101' },
                        @{ name = 'wrong-scope'; headers = @{ 'api-key' = $admission.keys.wrongScope }; expected = 401 },
                        @{ name = 'wrong-product'; headers = @{ 'api-key' = $admission.keys.wrongProduct }; expected = 401 },
                        @{ name = 'missing'; headers = @{}; expected = 401 }
                    )
                    if ($admission.expanded) {
                        $productContext = if ($surface -eq 'inherited') { '1110' } else { '1100' }
                        $cases += @(
                            @{ name = 'secondary'; headers = @{ 'api-key' = $admission.keys.secondary }; expected = 200; context = $productContext },
                            @{ name = 'suspended'; headers = @{ 'api-key' = $admission.keys.suspended }; expected = 401 },
                            @{ name = 'rotated-old'; headers = @{ 'api-key' = $admission.keys.rotatedOld }; expected = 401 },
                            @{ name = 'rotated-new'; headers = @{ 'api-key' = $admission.keys.rotated }; expected = 200; context = $productContext },
                            @{ name = 'invalid'; headers = @{ 'api-key' = 'invalid-probe-key' }; expected = 401 },
                            @{ name = 'empty'; headers = @{ 'api-key' = '' }; expected = 401 },
                            @{ name = 'empty-bearer'; headers = @{ Authorization = 'Bearer ' }; expected = 401 },
                            @{ name = 'key-plus-jwt'; headers = @{ 'api-key' = $admission.keys.throttle; Authorization = 'Bearer ' + $userToken }; expected = 401 },
                            @{ name = 'invalid-plus-jwt'; headers = @{ 'api-key' = 'invalid-probe-key'; Authorization = 'Bearer ' + $userToken }; expected = 401 },
                            @{ name = 'jwt-plus-jwt'; headers = @{ 'api-key' = $userToken; Authorization = 'Bearer ' + $userToken }; expected = 401 },
                            @{ name = 'duplicate-key'; headers = @{ 'api-key' = $admission.keys.active + ',' + $admission.keys.active }; expected = 401 },
                            @{ name = 'duplicate-bearer'; headers = @{ Authorization = 'Bearer ' + $userToken + ',Bearer ' + $userToken }; expected = 401 },
                            @{ name = 'query-key'; headers = @{}; query = 'api-key=' + [uri]::EscapeDataString($admission.keys.active); expected = 200; context = $productContext },
                            @{ name = 'query-jwt'; headers = @{}; query = 'api-key=header.payload.signature'; expected = 401 },
                            @{ name = 'query-conflict'; headers = @{ Authorization = 'Bearer ' + $userToken }; query = 'api-key=' + [uri]::EscapeDataString($admission.keys.throttle); expected = 401 },
                            @{ name = 'duplicate-query'; headers = @{}; query = 'api-key=' + [uri]::EscapeDataString($admission.keys.active) + '&api-key=' + [uri]::EscapeDataString($admission.keys.active); expected = 401 },
                            @{ name = 'tampered'; headers = @{ 'api-key' = $badSignatureToken }; expected = 401 },
                            @{ name = 'expired'; headers = @{ 'api-key' = $expiredToken }; expected = 401 }
                        )
                        foreach ($control in @('audience', 'scope', 'issuer', 'identity')) {
                            $cases += @{ name = $control; headers = @{ 'api-key' = $userToken }; uri = $admission.urls."$surface-$control"; expected = 401 }
                        }
                        foreach ($attempt in 1..4) {
                            $cases += @{ name = "limit-$attempt"; headers = @{ 'api-key' = $admission.keys.throttle }; expected = $(if ($surface -eq 'inherited' -and $attempt -eq 4) { 429 } else { 200 }); context = $productContext }
                        }
                        $cases += @{ name = 'limit-isolated'; headers = @{ 'api-key' = $admission.keys.'other-throttle' }; expected = 200; context = $productContext }
                        foreach ($attempt in 1..4) {
                            $cases += @{ name = "jwt-limit-$attempt"; headers = @{ 'api-key' = $userToken }; uri = $admission.urls."$surface-jwt-limit"; expected = $(if ($attempt -eq 4) { 429 } else { 200 }); context = '0101' }
                        }
                    }
                    foreach ($case in $cases) {
                        $status = 0
                        $responseHeaders = @{}
                        try {
                            $requestUri = [UriBuilder]::new($(if ($case.uri) { $case.uri } else { $admission.urls.$surface }))
                            if ($case.query) { $requestUri.Query = $case.query }
                            $response = Invoke-WebRequest -UseBasicParsing -Uri $requestUri.Uri -Headers $case.headers -TimeoutSec 45
                            $status = [int]$response.StatusCode
                            $responseHeaders = $response.Headers
                        } catch {
                            if ($_.Exception.Response) {
                                $status = [int]$_.Exception.Response.StatusCode
                                $responseHeaders = $_.Exception.Response.Headers
                            }
                        }
                        $contextFlags = [string]$responseHeaders['X-Probe-Context']
                        $passed = $status -eq $case.expected -and ($case.expected -ne 200 -or $contextFlags -eq $case.context)
                        if ($admission.expanded -and $case.expected -eq 200) { $passed = $passed -and $responseHeaders['X-Probe-Stripped'] -eq 'True' }
                        $observations += [pscustomobject]@{ case = "$($surface.Substring(0,1))-$($case.name)"; http = $status; ctx = $contextFlags; passed = $passed }
                    }
                }
            }
            $modes = if ($admission.openProduct) { @() } else { @('required', 'optional') }
            foreach ($mode in $modes) {
                $apiKey = if ($mode -eq 'required') { $admission.keys.apiRequired } else { $admission.keys.apiOptional }
                $cases = @(
                    @{ name = 'missing'; headers = @{} },
                    @{ name = 'active'; headers = @{ 'api-key' = $admission.keys.active } },
                    @{ name = 'secondary'; headers = @{ 'api-key' = $admission.keys.secondary } },
                    @{ name = 'api-scoped'; headers = @{ 'api-key' = $apiKey } },
                    @{ name = 'all-apis'; headers = @{ 'api-key' = $admission.keys.allApis } },
                    @{ name = 'invalid'; headers = @{ 'api-key' = 'invalid-probe-key' } },
                    @{ name = 'suspended'; headers = @{ 'api-key' = $admission.keys.suspended } },
                    @{ name = 'wrong-scope'; headers = @{ 'api-key' = $admission.keys.wrongScope } },
                    @{ name = 'wrong-product'; headers = @{ 'api-key' = $admission.keys.wrongProduct } },
                    @{ name = 'rotated-old'; headers = @{ 'api-key' = $admission.keys.rotatedOld } },
                    @{ name = 'rotated-new'; headers = @{ 'api-key' = $admission.keys.rotated } },
                    @{ name = 'jwt-api-key'; headers = @{ 'api-key' = $userToken } },
                    @{ name = 'jwt-bearer'; headers = @{ Authorization = 'Bearer ' + $userToken } },
                    @{ name = 'key-plus-jwt'; headers = @{ 'api-key' = $admission.keys.active; Authorization = 'Bearer ' + $userToken } },
                    @{ name = 'invalid-plus-jwt'; headers = @{ 'api-key' = 'invalid-probe-key'; Authorization = 'Bearer ' + $userToken } },
                    @{ name = 'jwt-plus-jwt'; headers = @{ 'api-key' = $userToken; Authorization = 'Bearer ' + $userToken } }
                )
                foreach ($case in $cases) {
                    $status = 0
                    $responseHeaders = @{}
                    try {
                        $response = Invoke-WebRequest -UseBasicParsing -Uri $admission.urls.$mode -Headers $case.headers -TimeoutSec 45
                        $status = [int]$response.StatusCode
                        $responseHeaders = $response.Headers
                    } catch {
                        if ($_.Exception.Response) {
                            $status = [int]$_.Exception.Response.StatusCode
                            $responseHeaders = $_.Exception.Response.Headers
                        }
                    }
                    $isKey = $case.name -in @('active', 'secondary', 'rotated-new')
                    $isJwt = $case.name -in @('jwt-api-key', 'jwt-bearer')
                    $expected = if ($isKey -or $case.name -in @('api-scoped', 'all-apis') -or ($isJwt -and $mode -eq 'optional')) { 200 } else { 401 }
                    $hasContext = $responseHeaders['X-Probe-Subscription'] -eq 'True' -and $responseHeaders['X-Probe-Product'] -eq 'True' -and $responseHeaders['X-Probe-Product-Policy'] -eq 'True'
                    $passed = ($status -eq $expected) -and (-not $isKey -or $hasContext)
                    $observations += [pscustomobject]@{ case = "$($mode.Substring(0,1))-$($case.name)"; http = $status; ctx = [int]$hasContext; passed = $passed }
                }
                foreach ($attempt in 1..4) {
                    $status = 0
                    try {
                        $response = Invoke-WebRequest -UseBasicParsing -Uri $admission.urls.$mode -Headers @{ 'api-key' = $admission.keys.throttle } -TimeoutSec 45
                        $status = [int]$response.StatusCode
                    } catch {
                        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
                    }
                    $expected = if ($attempt -eq 4) { 429 } else { 200 }
                    $observations += [pscustomobject]@{ case = "$($mode.Substring(0,1))-limit-$attempt"; http = $status; passed = ($status -eq $expected) }
                }
            }
            $compactRows = @($observations | ForEach-Object { ,@($_.case, $_.http, $_.ctx, $_.passed) })
            $matrixJson = [pscustomobject]@{ test = 'native-admission-observations'; rows = $compactRows } | ConvertTo-Json -Depth 5 -Compress
            if ($admission.expanded) {
                $stream = [IO.MemoryStream]::new()
                $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Compress, $true)
                $bytes = [Text.Encoding]::UTF8.GetBytes($matrixJson)
                try { $gzip.Write($bytes, 0, $bytes.Length) } finally { $gzip.Dispose() }
                try { [pscustomobject]@{ test = 'compressed-admission'; data = [Convert]::ToBase64String($stream.ToArray()) } | ConvertTo-Json -Compress } finally { $stream.Dispose() }
            } else {
                $matrixJson
            }
        }
    } catch {
        [pscustomobject]@{ test = 'encrypted-user-token-probe'; passed = $false; reason = 'Encrypted token test failed; details suppressed' } | ConvertTo-Json -Compress
    } finally {
        $userToken = $null
        $parts = $null
        $badSignatureToken = $null
        $admission = $null
        $expiredToken = $null
        Remove-Item -LiteralPath $certificates[0].PSPath -DeleteKey -Force
        [pscustomobject]@{ test = 'temporary-transport-certificate-removed'; passed = $true } | ConvertTo-Json -Compress
    }
} else {
    [pscustomobject]@{ test = 'valid-delegated-user-token'; status = 'NOT_RUN'; reason = 'Requires delegated token via encrypted VM transport' } | ConvertTo-Json -Compress
}
if (-not $ProtectedExpiredToken) {
    [pscustomobject]@{ test = 'expired-signed-user-token'; status = 'NOT_RUN'; reason = 'Requires an actually expired signed user token; mutating exp would invalidate the signature' } | ConvertTo-Json -Compress
}