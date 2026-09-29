#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Prepare', 'Test', 'Cleanup', 'ParameterTest', 'TransportTest', 'Http2ClientTest', 'Http2TransportTest', 'TelemetryTest', 'SharedTelemetryTest', 'SharedRollbackTest', 'CliPrerequisiteTest', 'AssociationTest', 'HeaderParityTransport', 'HeaderParityTest', 'AnthropicMeteringTest', 'SharedRuntimeTest', 'SharedConsumerTest', 'SharedGovernanceTest', 'RealResponsesTest')]
    [string] $Phase = 'Test',
    [ValidatePattern('^jwt-probe-[a-z0-9-]+$')]
    [string] $ProbeId,
    [string] $ProtectedToken,
    [string] $ProtectedExpiredToken,
    [string] $Http2ClientArchive,
    [string] $Http2ClientSha256,
    [ValidateSet('AzureCloud', 'AzureUSGovernment')]
    [string] $TelemetryCloud = 'AzureCloud',
    [string] $TelemetryWorkspaceId,
    [ValidateSet('true', 'false')]
    [string] $AdmissionPayload = 'false',
    [ValidateSet('true', 'false')]
    [string] $ValidationControls = 'false',
    [uri] $GatewayUri,
    [string] $MockAddress,
    [string] $MockSourcePrefix,
    [string] $MeteringFixtures,
    [ValidateSet('main','packages')]
    [string] $ConsumerInventory = 'main',
    [ValidateSet('before','detached','legacy')]
    [string] $RollbackStage = 'before',
    [Parameter(Mandatory)]
    [uri] $ArmResource
)

$ErrorActionPreference = 'Stop'
if ($Phase -eq 'CliPrerequisiteTest') {
    $previousOffline = $env:COPILOT_OFFLINE
    $cli = Get-Command copilot.exe, copilot.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $azure = Get-Command az -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $pwsh = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }) {
        $azurePath = Join-Path $root 'Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
        if (-not $azure -and (Test-Path -LiteralPath $azurePath)) { $azure = [pscustomobject]@{ Source = $azurePath } }
        $pwshPath = Join-Path $root 'PowerShell\7\pwsh.exe'
        if (-not $pwsh -and (Test-Path -LiteralPath $pwshPath)) { $pwsh = [pscustomobject]@{ Source = $pwshPath } }
    }
    $userCliCount = @(Get-ChildItem -Path 'C:\Users\*\AppData\Roaming\npm\copilot.cmd' -File -ErrorAction SilentlyContinue).Count
    $cliVersion = ''
    $commandSupported = $false
    $azureVersion = ''
    $signedIn = $false
    $delegated = $false
    $cloudMatches = $false
    try {
        $env:COPILOT_OFFLINE = 'true'
        if ($cli) {
            try {
                $versionOutput = (& $cli.Source --version 2>$null) -join ' '
                $versionMatch = [regex]::Match($versionOutput, '\b[0-9]+\.[0-9]+\.[0-9]+\b')
                if ($LASTEXITCODE -eq 0 -and $versionMatch.Success) { $cliVersion = $versionMatch.Value }
                $helpOutput = (& $cli.Source help providers 2>$null) -join ' '
                $commandSupported = $LASTEXITCODE -eq 0 -and $helpOutput -match '\bCOPILOT_PROVIDER_API_KEY_COMMAND\b'
            } catch { }
        }
        if ($azure) {
            try {
                $versionInfo = (& $azure.Source version -o json --only-show-errors 2>$null) | ConvertFrom-Json
                if ($LASTEXITCODE -eq 0 -and $versionInfo.'azure-cli' -match '^[0-9]+\.[0-9]+\.[0-9]+$') { $azureVersion = $versionInfo.'azure-cli' }
                $accountInfo = (& $azure.Source account show -o json --only-show-errors 2>$null) | ConvertFrom-Json
                $signedIn = $LASTEXITCODE -eq 0 -and [bool]$accountInfo.tenantId
                $delegated = $signedIn -and $accountInfo.user.type -eq 'user'
                $cloudMatches = $signedIn -and $accountInfo.environmentName -eq $TelemetryCloud
            } catch { }
        }
        [pscustomobject]@{
            test = 'cli-prerequisites'
            runningAsSystem = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
            powershell = $PSVersionTable.PSVersion.ToString()
            pwshAvailable = [bool]$pwsh
            nodeAvailable = [bool](Get-Command node -CommandType Application -ErrorAction SilentlyContinue)
            cliAvailable = [bool]$cli
            userLocalCliInstallations = $userCliCount
            cliVersion = $cliVersion
            credentialCommandSupported = $commandSupported
            azureCliAvailable = [bool]$azure
            azureCliVersion = $azureVersion
            azureSignedIn = $signedIn
            delegatedSignIn = $delegated
            expectedCloudMatches = $cloudMatches
        } | ConvertTo-Json -Compress
    } finally {
        $env:COPILOT_OFFLINE = $previousOffline
        $accountInfo = $null
    }
    return
}
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
if ($Phase -notin @('TelemetryTest','SharedTelemetryTest') -and $GatewayUri.Scheme -ne 'https') { throw 'The probe requires HTTPS.' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-ProbeSharedTelemetryResult {
    param([object[]]$Rows)
    $safeRows=@()
    $values=@{}
    foreach($row in $Rows){
        if(@($row).Count -ne 5 -or $row[0] -notin @('legacy','caller') -or $row[1] -notin @('burst','tokens','quota') -or $values.ContainsKey($row[0]+':'+$row[1])){throw 'Unexpected shared telemetry result shape.'}
        $total=[double]$row[2];$subjects=[int]$row[3];$invalid=[long]$row[4]
        if([double]::IsNaN($total) -or [double]::IsInfinity($total) -or $total -lt 0 -or $subjects -lt 0 -or $invalid -lt 0){throw 'Invalid shared telemetry aggregate.'}
        $values[$row[0]+':'+$row[1]]=@{total=$total;subjects=$subjects;invalid=$invalid}
        $safeRows+=,@([string]$row[0],[string]$row[1],$total,$subjects,$invalid)
    }
    $complete=$values.Count -eq 6
    foreach($kind in @('burst','tokens','quota')){
        $legacy=$values['legacy:'+$kind];$caller=$values['caller:'+$kind]
        $complete=$complete -and $legacy -and $caller -and $legacy.total -ge 2 -and $legacy.total -eq $caller.total -and
            $legacy.subjects -eq 2 -and $caller.subjects -eq 2 -and $legacy.invalid -eq 0 -and $caller.invalid -eq 0
    }
    return [pscustomobject]@{test='shared-governance-telemetry';querySucceeded=$true;complete=[bool]$complete;columns=@('metric','throttle','total','subjects','invalidIdentity');rows=$safeRows}
}

if($Phase -eq 'SharedTelemetryTest'){
    $workspaceGuid=[guid]::Empty
    if(-not $ProbeId -or -not [guid]::TryParse($TelemetryWorkspaceId,[ref]$workspaceGuid)){throw 'A run-scoped telemetry query and workspace are required.'}
    $certificates=@(Get-ChildItem Cert:\LocalMachine\My|Where-Object Subject -eq "CN=$ProbeId")
    if($certificates.Count -ne 1){throw 'Expected one owned telemetry transport certificate.'}
    $query=@'
AppMetrics
| where TimeGenerated > ago(2h)
| where (Name == 'copilot_byok_throttled' and tostring(Properties.backend) startswith '__OWNER__:')
    or (Name == 'copilot_byok_caller_throttled' and tostring(Properties.operation) startswith '__OWNER__:')
| extend Metric=iff(Name == 'copilot_byok_throttled','legacy','caller'), Throttle=tostring(Properties.throttle)
| extend Subject=iff(Metric == 'legacy',tostring(Properties.developer_oid),tostring(Properties.principal)), Issuer=tostring(Properties.issuer)
| extend Invalid=isempty(Subject) or (Metric == 'caller' and (tostring(Properties.auth_method) != 'entraJwt' or isempty(Issuer) or not(Subject startswith strcat('entraJwt:',strlen(Issuer),':',Issuer,':'))))
| summarize Total=sum(Sum), Subjects=dcount(Subject), InvalidIdentity=countif(Invalid) by Metric, Throttle
| project Metric, Throttle, Total, Subjects, InvalidIdentity
'@.Replace('__OWNER__',$ProbeId)
    $queryToken=$null
    try{
        $queryToken=Unprotect-CmsMessage -To $certificates[0] -Content ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ProtectedToken)))
        $endpoint=if($TelemetryCloud -eq 'AzureUSGovernment'){'https://api.loganalytics.us'}else{'https://api.loganalytics.io'}
        $result=Invoke-RestMethod -Method Post -Uri ($endpoint+'/v1/workspaces/'+$workspaceGuid.ToString()+'/query') -Headers @{Authorization='Bearer '+$queryToken} -ContentType 'application/json' -Body (@{query=$query}|ConvertTo-Json -Compress) -TimeoutSec 60
        Get-ProbeSharedTelemetryResult -Rows @($result.tables[0].rows) | ConvertTo-Json -Depth 6 -Compress
    }catch{
        $status=if($_.Exception.Response){[int]$_.Exception.Response.StatusCode}else{0}
        [pscustomobject]@{test='shared-governance-telemetry';querySucceeded=$false;complete=$false;http=$status;failure=$_.Exception.GetBaseException().GetType().Name}|ConvertTo-Json -Compress
    }finally{
        $queryToken=$null
        Remove-Item -LiteralPath $certificates[0].PSPath -DeleteKey -Force
        [pscustomobject]@{test='temporary-transport-certificate-removed';passed=$true}|ConvertTo-Json -Compress
    }
    return
}

if ($Phase -eq 'TelemetryTest') {
    $workspaceGuid = [guid]::Empty
    if (-not [guid]::TryParse($TelemetryWorkspaceId, [ref]$workspaceGuid)) { throw 'A valid workspace ID is required for telemetry.' }
    $logEndpoint = if ($TelemetryCloud -eq 'AzureUSGovernment') { 'https://api.loganalytics.us' } else { 'https://api.loganalytics.io' }
    $query = @'
AppMetrics
| where TimeGenerated > ago(2h)
| extend Fixture=tostring(Properties.backend), Subject=tostring(Properties.developer_oid)
| where Fixture startswith 'probe-'
| where Name in ('copilot_byok_request', 'copilot_byok_throttled', 'Total Tokens', 'Prompt Tokens', 'Completion Tokens')
| summarize Measurements=sum(ItemCount), Total=sum(Sum), Subjects=dcountif(Subject, isnotempty(Subject)) by Name, Fixture
| order by Fixture asc, Name asc
'@
    $telemetryToken = $null
    try {
        $tokenUri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' + [uri]::EscapeDataString($logEndpoint)
        $telemetryToken = Invoke-RestMethod -Headers @{ Metadata = 'true' } -Uri $tokenUri -TimeoutSec 20
        $result = Invoke-RestMethod -Method Post -Uri ($logEndpoint + '/v1/workspaces/' + $workspaceGuid.ToString() + '/query') -Headers @{ Authorization = 'Bearer ' + $telemetryToken.access_token } -ContentType 'application/json' -Body (@{ query = $query } | ConvertTo-Json -Compress) -TimeoutSec 60
        $rows = @($result.tables[0].rows)
        $safeRows = @(foreach ($row in $rows) {
            if ($row[0] -notin @('copilot_byok_request', 'copilot_byok_throttled', 'Total Tokens', 'Prompt Tokens', 'Completion Tokens') -or $row[1] -notmatch '^probe-(baseline|rpm|tpm|quota)-(chat|responses)-(json|stream)$') { throw 'Unexpected telemetry shape.' }
            ,@([string]$row[0], [string]$row[1], [long]$row[2], [double]$row[3], [int]$row[4])
        })
        [pscustomobject]@{ test = 'production-pipeline-telemetry'; columns = @('metric', 'fixture', 'measurements', 'total', 'subjects'); rows = $safeRows; querySucceeded = $true } | ConvertTo-Json -Depth 5 -Compress
    } catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        [pscustomobject]@{ test = 'production-pipeline-telemetry'; querySucceeded = $false; http = $status; failure = $_.Exception.GetBaseException().GetType().Name } | ConvertTo-Json -Compress
    } finally { $telemetryToken = $null }
    return
}

function New-ProbeWireRequest {
    param([uri] $RequestUri, [string[]] $HeaderLines, [ValidateSet('GET','POST','DELETE')] [string] $Method = 'GET', [string] $Body)
    if ($RequestUri.Scheme -ne 'https' -or $RequestUri.UserInfo) { throw 'Raw probe requires HTTPS without user information.' }
    foreach ($header in $HeaderLines) {
        if ($header -match '[\r\n]' -or $header -notmatch '^(api-key|x-api-key|Authorization|Ocp-Apim-Subscription-Key|X-Probe-Case|X-Probe-Ready|X-Probe-Run):[^\r\n]*$') {
            throw 'Unsupported raw probe header.'
        }
    }
    $lines = @($HeaderLines)
    if ($PSBoundParameters.ContainsKey('Body')) {
        if ($Method -ne 'POST' -or [Text.Encoding]::UTF8.GetByteCount($Body) -gt 65536) { throw 'The bounded JSON probe body is supported only for POST.' }
        $lines += @('Content-Type: application/json', ('Content-Length: ' + [Text.Encoding]::UTF8.GetByteCount($Body)))
    } elseif ($Method -eq 'POST') { $lines += 'Content-Length: 0' }
    return "$Method $($RequestUri.PathAndQuery) HTTP/1.1`r`nHost: $($RequestUri.Authority)`r`nConnection: close`r`n$($lines -join "`r`n")`r`n`r`n$Body"
}

function Read-ProbeWireResponse {
    param([IO.TextReader] $Reader, [switch] $ReadContent)
    $status = 0
    foreach ($responseNumber in 1..4) {
        $statusLine = $Reader.ReadLine()
        if ($statusLine -notmatch '^HTTP/1\.[01] ([0-9]{3}) ') { throw 'Invalid raw probe response.' }
        $status = [int]$Matches[1]
        $headers = @{}
        $total = 0
        while ($null -ne ($line = $Reader.ReadLine()) -and $line.Length -gt 0) {
            $total += $line.Length
            if ($total -gt 32768) { throw 'Raw probe response headers too large.' }
            $separator = $line.IndexOf(':')
            if ($separator -le 0) { throw 'Invalid raw response header.' }
            $name = $line.Substring(0, $separator)
            if ($name -in @('Content-Length','Transfer-Encoding') -and $headers.ContainsKey($name)) { throw 'Ambiguous response framing.' }
            $headers[$name] = $line.Substring($separator + 1).Trim()
        }
        if ($null -eq $line) { throw 'Incomplete response headers.' }
        if ($status -ge 200) { break }
    }
    if ($status -lt 200) { throw 'No final probe response.' }
    $content = ''
    if ($ReadContent -and $status -notin @(204,304)) {
        if ($headers['Content-Encoding'] -and $headers['Content-Encoding'] -cne 'identity') { throw 'Unexpected encoded response.' }
        if ($headers.ContainsKey('Content-Length') -and $headers.ContainsKey('Transfer-Encoding')) { throw 'Ambiguous response length.' }
        $buffer = New-Object char[] 131073
        $count = 0
        if ($headers.ContainsKey('Transfer-Encoding')) {
            if ($headers['Transfer-Encoding'] -ine 'chunked') { throw 'Unsupported response transfer encoding.' }
            while ($true) {
                $sizeLine = $Reader.ReadLine()
                if ($null -eq $sizeLine -or $sizeLine.Length -gt 256 -or $sizeLine -notmatch '\A([a-fA-F0-9]{1,8})(?:;[^\r\n]*)?\z') { throw 'Invalid response chunk size.' }
                $size = [Convert]::ToInt64($Matches[1],16)
                if ($size -eq 0) {
                    $trailerSize = 0
                    do { $trailer = $Reader.ReadLine(); $trailerSize += ([string]$trailer).Length; if ($null -eq $trailer -or $trailerSize -gt 8192) { throw 'Invalid response trailers.' } } while ($trailer.Length)
                    break
                }
                if ($size + $count -gt 131072 -or $Reader.ReadBlock($buffer, $count, [int]$size) -ne $size -or $Reader.ReadLine() -cne '') { throw 'Incomplete or oversized response chunk.' }
                $count += [int]$size
            }
        } elseif ($headers.ContainsKey('Content-Length')) {
            if ($headers['Content-Length'] -notmatch '\A[0-9]{1,7}\z') { throw 'Invalid response length.' }
            $count = [int]$headers['Content-Length']
            if ($count -gt 131072 -or $Reader.ReadBlock($buffer,0,$count) -ne $count) { throw 'Incomplete or oversized response.' }
        } else {
            $count = $Reader.ReadBlock($buffer,0,$buffer.Length)
            if ($count -gt 131072) { throw 'Response exceeded the fixture bound.' }
        }
        $wireBytes = [Text.Encoding]::GetEncoding(28591).GetBytes($buffer,0,$count)
        $content = [Text.UTF8Encoding]::new($false,$true).GetString($wireBytes)
    }
    return @{ StatusCode = $status; Headers = $headers; Content = $content }
}

function Invoke-ProbeWireRequest {
    param([uri] $RequestUri, [string[]] $HeaderLines, [hashtable] $Diagnostics = @{}, [ValidateSet('GET','POST','DELETE')] [string] $Method = 'GET', [string] $Body, [switch] $ReadContent)
    $wireParameters = @{ RequestUri = $RequestUri; HeaderLines = $HeaderLines; Method = $Method }
    if ($PSBoundParameters.ContainsKey('Body')) { $wireParameters.Body = $Body }
    $wireRequest = New-ProbeWireRequest @wireParameters
    $client = [Net.Sockets.TcpClient]::new()
    $tls = $null
    $reader = $null
    $transportStage = 'dns'
    $certificateStatus = @{ errors = ''; chain = '' }
    $timings = @{}
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $addresses = @([Net.Dns]::GetHostAddresses($RequestUri.DnsSafeHost) | Where-Object AddressFamily -eq $client.Client.AddressFamily)
        if (-not $addresses.Count) { throw 'No gateway address matches the client address family.' }
        $timings.dns = $timer.ElapsedMilliseconds
        $timer.Restart()
        $transportStage = 'connect'
        $connection = $client.BeginConnect($addresses[0], $RequestUri.Port, $null, $null)
        try {
            if (-not $connection.AsyncWaitHandle.WaitOne(15000)) { throw 'Raw probe connection timed out.' }
            $client.EndConnect($connection)
        } finally { $connection.AsyncWaitHandle.Close() }
        $timings.connect = $timer.ElapsedMilliseconds
        $timer.Restart()
        $validateCertificate = {
            param($sender, $certificate, $chain, $errors)
            $certificateStatus.errors = $errors.ToString()
            $certificateStatus.chain = ($chain.ChainStatus | ForEach-Object { $_.Status.ToString() }) -join ','
            $Diagnostics.revocationUrls = @($chain.ChainElements | ForEach-Object {
                foreach ($extension in $_.Certificate.Extensions) {
                    if ($extension.Oid.Value -eq '2.5.29.31') {
                        foreach ($match in [regex]::Matches($extension.Format($false), 'https?://[^\s<>\[\]]+')) {
                            $match.Value
                        }
                    }
                }
            } | Select-Object -Unique)
            return $errors -eq [Net.Security.SslPolicyErrors]::None
        }.GetNewClosure()
        $tls = [Net.Security.SslStream]::new($client.GetStream(), $false, [Net.Security.RemoteCertificateValidationCallback]$validateCertificate)
        $tls.ReadTimeout = 45000
        $tls.WriteTimeout = 45000
        $transportStage = 'tls'
        $tls.AuthenticateAsClient($RequestUri.DnsSafeHost, $null, [Security.Authentication.SslProtocols]::Tls12, $true)
        $timings.tls = $timer.ElapsedMilliseconds
        $timer.Restart()
        $transportStage = 'write'
        $bytes = [Text.Encoding]::UTF8.GetBytes($wireRequest)
        $tls.Write($bytes, 0, $bytes.Length)
        $tls.Flush()
        $timings.write = $timer.ElapsedMilliseconds
        $timer.Restart()
        $reader = [IO.StreamReader]::new($tls, [Text.Encoding]::GetEncoding(28591), $false)
        $transportStage = 'response'
        return Read-ProbeWireResponse -Reader $reader -ReadContent:$ReadContent
    } catch {
        $Diagnostics.transportStage = $transportStage
        throw "Raw probe transport failed at $transportStage ($($_.Exception.GetBaseException().GetType().Name)); certificate=$($certificateStatus.errors); chain=$($certificateStatus.chain)."
    } finally {
        $timer.Stop()
        $timings[$transportStage] = $timer.ElapsedMilliseconds
        $Diagnostics.timings = $timings
        $Diagnostics.certificateErrors = $certificateStatus.errors
        $Diagnostics.chainStatus = $certificateStatus.chain
        if ($reader) { $reader.Dispose() }
        if ($tls) { $tls.Dispose() }
        $client.Dispose()
    }
}

function Get-ProbeAdmissionResult {
    param(
        [hashtable] $Case,
        [int] $Status,
        $ResponseHeaders,
        [bool] $Expanded,
        [bool] $BackendGate,
        $Receipt
    )
    $name = $Case.name -replace '^h2-', ''
    $identicalCase = $name -in @('wire-duplicate-bearer', 'wire-duplicate-bearer-case')
    $rejectCase = $name -in @('wire-duplicate-expired', 'wire-duplicate-tampered', 'wire-bearer-valid-first', 'wire-bearer-valid-last',
        'wire-two-users-first', 'wire-two-users-last')
    $duplicateRejection = $false
    if ($identicalCase -or $rejectCase) {
        $credentialLines = @($Case.wire | Where-Object { $_ -notmatch '^X-Probe-Case:' })
        if ($credentialLines.Count -ne 2 -or @($credentialLines | Where-Object { $_ -notmatch '^Authorization: Bearer [^,\r\n]+$' }).Count) {
            return [pscustomobject]@{ passed = $false; expectedReceipt = $false; duplicateException = $false }
        }
        if ($identicalCase -and (($credentialLines[0] -creplace '^[^:]+: ', '') -cne ($credentialLines[1] -creplace '^[^:]+: ', '') -or
            $Case.expected -ne 200 -or $Case.context -cne '0101')) {
            return [pscustomobject]@{ passed = $false; expectedReceipt = $false; duplicateException = $false }
        }
        if ($name -in @('wire-bearer-valid-first', 'wire-bearer-valid-last', 'wire-two-users-first', 'wire-two-users-last') -and
            ($credentialLines[0] -creplace '^[^:]+: ', '') -ceq ($credentialLines[1] -creplace '^[^:]+: ', '')) {
            return [pscustomobject]@{ passed = $false; expectedReceipt = $false; duplicateException = $false }
        }
        $duplicateRejection = $Status -in @(400, 401)
    }
    $expectedReceipt = $Case.expected -eq 200 -and -not $duplicateRejection
    $contextFlags = [string]$ResponseHeaders['X-Probe-Context']
    $passed = ($Status -eq $Case.expected -or $duplicateRejection) -and
        (-not $expectedReceipt -or $contextFlags -ceq $Case.context) -and (-not $rejectCase -or $duplicateRejection)
    if ($Expanded -and $expectedReceipt) { $passed = $passed -and $ResponseHeaders['X-Probe-Stripped'] -ceq 'True' }
    if ($duplicateRejection -and ($contextFlags.EndsWith('1') -or $ResponseHeaders['X-Probe-Backend'] -eq 'received')) { $passed = $false }
    if ($BackendGate) {
        $received = $null -ne $Receipt
        $passed = $passed -and $received -eq $expectedReceipt
        if ($received) { $passed = $passed -and $Receipt.count -eq 1 -and $Receipt.stripped -and $ResponseHeaders['X-Probe-Backend'] -ceq 'received' }
    }
    return [pscustomobject]@{ passed = [bool]$passed; expectedReceipt = [bool]$expectedReceipt; duplicateException = [bool]$duplicateRejection }
}

function Initialize-ProbeHttp2Client {
    param([string] $ClientDirectory, [string] $ArchiveBase64 = $Http2ClientArchive, [string] $ArchiveSha256 = $Http2ClientSha256)
    if (-not $ArchiveBase64 -or $ArchiveSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'A verified HTTP/2 client archive and SHA256 are required.' }
    $null = New-Item -ItemType Directory -Path $ClientDirectory
    $archive = Join-Path $ClientDirectory 'curl.zip'
    $archiveBytes = [Convert]::FromBase64String($ArchiveBase64)
    if ($archiveBytes.Length -gt 2097152) { throw 'HTTP/2 client archive exceeds the transport limit.' }
    [IO.File]::WriteAllBytes($archive, $archiveBytes)
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $ArchiveSha256) { throw 'HTTP/2 client checksum mismatch.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $expectedFiles = @('curl.exe', 'curl-LICENSE.txt', 'nghttp2-LICENSE.txt')
        if (@($zip.Entries).Count -ne 3 -or (Compare-Object ($expectedFiles | Sort-Object) (@($zip.Entries.FullName) | Sort-Object))) { throw 'Unexpected HTTP/2 client archive entries.' }
        if (($zip.Entries | Measure-Object Length -Sum).Sum -gt 8388608) { throw 'HTTP/2 client archive expands beyond the limit.' }
    } finally { $zip.Dispose() }
    Expand-Archive -LiteralPath $archive -DestinationPath $ClientDirectory
    $clientPath = Join-Path $ClientDirectory 'curl.exe'
    $previousBackend = $env:CURL_SSL_BACKEND
    try {
        $env:CURL_SSL_BACKEND = 'schannel'
        $version = (& $clientPath -q --version 2>$null) -join ' '
        if ($LASTEXITCODE -ne 0 -or $version -notmatch '\bHTTP2\b' -or $version -notmatch 'libcurl/8\.22\.0 Schannel' -or $version -notmatch 'nghttp2/1\.70\.0') { throw 'Required pinned HTTP/2 and Schannel support unavailable.' }
    } finally { $env:CURL_SSL_BACKEND = $previousBackend }
    return $clientPath
}

function Invoke-ProbeHttp2Request {
    param([string] $ClientPath, [uri] $RequestUri, [string[]] $HeaderLines)
    $null = New-ProbeWireRequest $RequestUri $HeaderLines
    $config = @('url = "' + $RequestUri.AbsoluteUri.Replace('\', '\\').Replace('"', '\"') + '"')
    foreach ($header in $HeaderLines) { $config += 'header = "' + $header.Replace('\', '\\').Replace('"', '\"') + '"' }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $ClientPath
    $start.Arguments = '-q --http2-prior-knowledge --proto =https --noproxy * --connect-timeout 15 --max-time 45 --silent --show-error --output NUL --dump-header - --write-out "\nprobe-protocol:%{http_version}" --config -'
    $start.EnvironmentVariables['CURL_SSL_BACKEND'] = 'schannel'
    $start.EnvironmentVariables.Remove('SSLKEYLOGFILE')
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.WriteLine(($config -join "`n"))
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'HTTP/2 client timeout.' }
        $output = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $tlsCodes = @([regex]::Matches($errorText, '0x[0-9a-fA-F]{8}') | ForEach-Object Value | Select-Object -Unique) -join ','
            throw "HTTP/2 client failed: exit $($process.ExitCode); tls=$tlsCodes."
        }
        if ($output -notmatch '(?m)^probe-protocol:2\s*$') { throw 'HTTP/2 was not negotiated; no downgrade accepted.' }
        $statusMatches = [regex]::Matches($output, '(?m)^HTTP/2 ([0-9]{3})')
        if ($statusMatches.Count -ne 1) { throw 'Unexpected HTTP/2 response shape.' }
        $headers = @{}
        foreach ($line in ($output -split '\r?\n')) {
            $separator = $line.IndexOf(':')
            if ($separator -gt 0) { $headers[$line.Substring(0, $separator)] = $line.Substring($separator + 1).Trim() }
        }
        return @{ StatusCode = [int]$statusMatches[0].Groups[1].Value; Headers = $headers; Protocol = '2' }
    } finally { $process.Dispose(); $config = $null }
}

if ($Phase -in @('Http2ClientTest', 'Http2TransportTest')) {
    $clientDirectory = Join-Path ([IO.Path]::GetTempPath()) ('jwt-probe-http2-' + [guid]::NewGuid().ToString('N'))
    try {
        $clientPath = Initialize-ProbeHttp2Client $clientDirectory
        if ($Phase -eq 'Http2ClientTest') {
            [pscustomobject]@{ test = 'verified-http2-client'; client = 'curl-8.22.0-schannel-nghttp2'; passed = $true } | ConvertTo-Json -Compress
        } else {
            $response = Invoke-ProbeHttp2Request $clientPath $GatewayUri @('Authorization: Bearer not-a-jwt')
            [pscustomobject]@{ test = 'http2-transport'; client = 'curl-8.22.0-schannel-nghttp2'; protocol = $response.Protocol; http = $response.StatusCode; passed = ($response.StatusCode -eq 401) } | ConvertTo-Json -Compress
        }
    } catch {
        $message = $_.Exception.GetBaseException().Message
        $clientError = if ($message -match '^HTTP/2 client failed: exit [0-9]+; tls=(0x[0-9a-fA-F]{8}(,0x[0-9a-fA-F]{8})*)?\.$') { $message } elseif ($message -eq 'HTTP/2 was not negotiated; no downgrade accepted.') { 'protocol-not-http2' } else { '' }
        [pscustomobject]@{ test = $(if ($Phase -eq 'Http2ClientTest') { 'verified-http2-client' } else { 'http2-transport' }); passed = $false; failure = $_.Exception.GetBaseException().GetType().Name; clientError = $clientError } | ConvertTo-Json -Compress
    } finally {
        if (Test-Path -LiteralPath $clientDirectory) { Remove-Item -LiteralPath $clientDirectory -Recurse -Force }
        [pscustomobject]@{ test = 'temporary-http2-client-removed'; passed = (-not (Test-Path -LiteralPath $clientDirectory)) } | ConvertTo-Json -Compress
    }
    return
}

if ($Phase -eq 'TransportTest') {
    $diagnostics = @{}
    foreach ($transport in @('web-request', 'raw-tls')) {
        try {
            $response = if ($transport -eq 'raw-tls') {
                Invoke-ProbeWireRequest $GatewayUri @('Authorization: Bearer not-a-jwt') -Diagnostics $diagnostics
            } else {
                Invoke-WebRequest -UseBasicParsing -Uri $GatewayUri -Headers @{ Authorization = 'Bearer not-a-jwt' } -TimeoutSec 45
            }
            [pscustomobject]@{ test = $transport; http = [int]$response.StatusCode } | ConvertTo-Json -Compress
        } catch {
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            $failure = if ($transport -eq 'raw-tls') { $_.Exception.Message } else { $_.Exception.GetBaseException().GetType().Name }
            [pscustomobject]@{ test = $transport; http = $status; failure = $failure } | ConvertTo-Json -Compress
        }
    }
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    $curlVersion = if ($curl) { (& $curl.Source --version) -join ' ' } else { '' }
    [pscustomobject]@{ test = 'http2-client-capability'; curlHttp2 = ($curlVersion -match '\bHTTP2\b'); pwshAvailable = [bool](Get-Command pwsh.exe -ErrorAction SilentlyContinue); nodeAvailable = [bool](Get-Command node.exe -ErrorAction SilentlyContinue); dotnetAvailable = [bool](Get-Command dotnet.exe -ErrorAction SilentlyContinue) } | ConvertTo-Json -Compress
    foreach ($url in $diagnostics.revocationUrls) {
        $endpoint = [uri]$url
        if ($endpoint.DnsSafeHost -notmatch '(^|\.)(microsoft\.com|digicert\.com|msocsp\.com|identrust\.com)$') {
            [pscustomobject]@{ test = 'revocation-endpoint'; status = 'NOT_RUN'; reason = 'CA host is outside the diagnostic allowlist' } | ConvertTo-Json -Compress
            continue
        }
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $endpoint -TimeoutSec 15 -MaximumRedirection 0
            [pscustomobject]@{ test = 'revocation-endpoint'; host = $endpoint.DnsSafeHost; scheme = $endpoint.Scheme; http = [int]$response.StatusCode } | ConvertTo-Json -Compress
        } catch {
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            [pscustomobject]@{ test = 'revocation-endpoint'; host = $endpoint.DnsSafeHost; scheme = $endpoint.Scheme; http = $status; failure = $_.Exception.GetBaseException().GetType().Name } | ConvertTo-Json -Compress
        }
    }
    return
}

if ($Phase -eq 'HeaderParityTransport') {
    $diagnostics = @{}
    try {
        $response = Invoke-ProbeWireRequest $GatewayUri @() -Diagnostics $diagnostics
        [pscustomobject]@{ test = 'header-parity-transport'; http = $response.StatusCode; passed = $response.StatusCode -eq 404; timings = $diagnostics.timings } | ConvertTo-Json -Depth 4 -Compress
    } catch {
        [pscustomobject]@{ test = 'header-parity-transport'; http = 0; passed = $false; failure = $_.Exception.Message; timings = $diagnostics.timings; stage = $diagnostics.transportStage; certificate = $diagnostics.certificateErrors; chain = $diagnostics.chainStatus } | ConvertTo-Json -Depth 4 -Compress
    }
    return
}

if ($Phase -eq 'HeaderParityTest') {
    if (-not $ProbeId -or $GatewayUri.AbsolutePath.TrimEnd('/') -cne ('/' + $ProbeId)) { throw 'Header observation requires its own temporary API path.' }
    $cases = @(
        @{ name = 'missing'; headers = @(); control = $true },
        @{ name = 'single'; headers = @('Authorization: Bearer probe-alpha'); control = $true },
        @{ name = 'identical'; headers = @('Authorization: Bearer probe-alpha', 'Authorization: Bearer probe-alpha') },
        @{ name = 'case-variant'; headers = @('Authorization: Bearer probe-alpha', 'authorization: Bearer probe-alpha') },
        @{ name = 'different-first'; headers = @('Authorization: Bearer probe-alpha', 'Authorization: Bearer probe-beta') },
        @{ name = 'different-last'; headers = @('Authorization: Bearer probe-beta', 'Authorization: Bearer probe-alpha') },
        @{ name = 'combined'; headers = @('Authorization: Bearer probe-alpha,Bearer probe-alpha') },
        @{ name = 'single-after'; headers = @('Authorization: Bearer probe-beta'); control = $true }
    )
    $rows = @()
    foreach ($stage in @('blind', 'array', 'joined')) {
        $requestUri = [uri]($GatewayUri.AbsoluteUri.TrimEnd('/') + '/' + $stage)
        foreach ($case in $cases) {
            $response = Invoke-ProbeWireRequest $requestUri $case.headers
            $marked = $response.Headers['X-Parity-Probe'] -ceq $ProbeId -and $response.Headers['X-Parity-Stage'] -ceq $stage
            if ($case.control -and ($response.StatusCode -ne 401 -or -not $marked)) { throw 'Header observation control did not reach its owned operation; matrix is incomplete.' }
            $count = $null
            $equal = $null
            $comma = $null
            if ($marked -and $stage -ne 'blind') {
                if ($response.Headers['X-Parity-Count'] -notmatch '\A[0-9]{1,3}\z' -or
                    $response.Headers['X-Parity-Equal'] -notin @('True', 'False')) { throw 'Invalid header observation metadata.' }
                $count = [int]$response.Headers['X-Parity-Count']
                $equal = $response.Headers['X-Parity-Equal'] -eq 'True'
            }
            if ($marked -and $stage -eq 'joined') {
                if ($response.Headers['X-Parity-Joined-Comma'] -notin @('True', 'False')) { throw 'Invalid joined-header observation metadata.' }
                $comma = $response.Headers['X-Parity-Joined-Comma'] -eq 'True'
            }
            $expressionFailed = $response.Headers['X-Parity-Probe'] -ceq $ProbeId -and $response.Headers['X-Parity-Stage'] -ceq ($stage + '-error')
            $rows += ,@($stage, $case.name, $response.StatusCode, $marked, $count, $equal, $comma, $expressionFailed)
        }
    }
    [pscustomobject]@{ test = 'header-parity-observations'; protocol = 'HTTP/1.1'; completed = $true; columns = @('stage', 'case', 'http', 'marked', 'count', 'equal', 'joinedComma', 'expressionFailed'); rows = $rows } | ConvertTo-Json -Depth 5 -Compress
    return
}

function Get-ProbeRealResponseDocument {
    param([string] $Content)
    if ($Content.TrimStart().StartsWith('{')) { return $Content | ConvertFrom-Json }
    $document = $null
    $eventLines = [Collections.Generic.List[string]]::new()
    foreach ($line in @($Content -split '\r?\n') + @('')) {
        if ($line.StartsWith('data:',[StringComparison]::Ordinal)) { $eventLines.Add($line.Substring(5).TrimStart(' ')) }
        elseif ($line.Length -eq 0 -and $eventLines.Count) {
            $data = $eventLines -join "`n"
            $eventLines.Clear()
            if ($data -ceq '[DONE]') { continue }
            $event = $data | ConvertFrom-Json
            if ($event.response -and $event.response.object -ceq 'response') {
                if ($document -and $document.id -cne $event.response.id) { throw 'Multiple response identities in one creation stream.' }
                $document = $event.response
            }
        }
    }
    if (-not $document) { throw 'No response object was returned by the creation.' }
    return $document
}

if ($Phase -eq 'RealResponsesTest') {
    $certificates = @(Get-ChildItem Cert:\LocalMachine\My | Where-Object Subject -eq "CN=$ProbeId")
    if ($certificates.Count -ne 1 -or $GatewayUri.Scheme -ne 'https' -or $GatewayUri.AbsolutePath -cne ('/'+$ProbeId+'-real')) { throw 'Real response acceptance requires its owned API and certificate.' }
    $statePath = Join-Path ([IO.Path]::GetTempPath()) ($ProbeId+'-real-state.cms')
    $observations = [Collections.Generic.List[object]]::new()
    $passed = $false
    $state = $null
    $settings = $null
    $cancellationCovered = $false
    function Save-RealResponseState {
        $sealed = Protect-CmsMessage -To $certificates[0] -Content ($state | ConvertTo-Json -Depth 20 -Compress)
        [IO.File]::WriteAllText($statePath,$sealed,[Text.UTF8Encoding]::new($false))
        return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sealed))
    }
    function Invoke-RealResponseRequest {
        param([string]$Method,[string]$Path,[ValidateSet('first','second','native','missing','malformed')][string]$Caller,[object]$Body,[switch]$WithoutNonce)
        if ($Path -cnotmatch '\A/v1/(?:models|responses(?:/resp_[A-Za-z0-9_-]{1,128}(?:/(?:cancel|input_items))?(?:\?stream=true&starting_after=0)?)?)\z') { throw 'Real response request is outside the bounded registered surface.' }
        $headers = @()
        if (-not $WithoutNonce) { $headers += 'X-Probe-Run: '+$settings.nonce }
        if ($Caller -eq 'native') { $headers += 'api-key: '+$settings.nativeKey }
        elseif ($Caller -in @('first','second')) { $headers += 'Authorization: Bearer '+$settings.($Caller+'Token') }
        elseif ($Caller -eq 'malformed') { $headers += 'Authorization: Bearer not-a-jwt' }
        $request = @{RequestUri=[uri]($GatewayUri.AbsoluteUri.TrimEnd('/')+$Path);Method=$Method;HeaderLines=$headers;ReadContent=$true}
        if ($null -ne $Body) { $request.Body=$Body|ConvertTo-Json -Depth 20 -Compress }
        try { return Invoke-ProbeWireRequest @request }
        catch { return @{StatusCode=0;Headers=@{};Content=''} }
    }
    function Assert-RealResponseStatus {
        param([string]$Name,$Response,[int[]]$Expected=@(200),[bool]$Condition=$true)
        $valid=$Response.StatusCode -in $Expected -and $Condition
        $observations.Add(@{name=$Name;http=[int]$Response.StatusCode;passed=$valid})
        if (-not $valid) { throw 'Real response acceptance control failed; details withheld.' }
    }
    function New-RealResponseBody {
        param([switch]$Background,[string]$Previous)
        $body=@{model=$settings.model;input='Reply with OK. Do not call the fixture function.';max_output_tokens=256;store=$true;background=[bool]$Background;stream=[bool]$Background;reasoning=@{effort='low'};
            tools=@(@{type='function';name='fixture_noop';description='Synthetic acceptance function.';parameters=@{type='object';properties=@{};additionalProperties=$false;required=@()};strict=$true});metadata=@{byok_owner_v1='client-forged';acceptance=$ProbeId}}
        if ($Previous) { $body.previous_response_id=$Previous }
        return $body
    }
    function Invoke-RealResponseCreation {
        param([string]$Name,[string]$Caller,[hashtable]$Body,[int]$Expected=200,[string]$Epoch='old')
        if ($state.attempts -ge 4 -or $state.unknownCreation) { throw 'Approved real response creation budget is exhausted or unresolved.' }
        $state.attempts++
        $state.unknownCreation=$true
        $null=Save-RealResponseState
        $response=Invoke-RealResponseRequest -Method POST -Path '/v1/responses' -Caller $Caller -Body $Body
        $created=$null
        try { if ($response.StatusCode -eq 200) { $created=Get-ProbeRealResponseDocument -Content $response.Content } } catch { }
        if ($created -and $created.id -cmatch '\Aresp_[A-Za-z0-9_-]{1,128}\z' -and $created.object -ceq 'response') {
            $state.items=@($state.items)+@([pscustomobject]@{id=$created.id;caller=$Caller;epoch=$Epoch;marker=[string]$created.metadata.byok_owner_v1;name=$Name})
            $state.unknownCreation=$false
        } elseif ($response.StatusCode -in @(400,401,403,404,429)) { $state.unknownCreation=$false }
        $null=Save-RealResponseState
        Assert-RealResponseStatus -Name $Name -Response $response -Expected @($Expected)
        if ($Expected -eq 200) {
            if (-not $created -or $created.metadata.byok_owner_v1 -cnotmatch '\Av1\.[a-f0-9]{64}\z' -or $created.metadata.acceptance -cne $ProbeId) { throw 'Real response owner stamp was not persisted as expected.' }
            return $created
        }
    }
    try {
        $settings=(Unprotect-CmsMessage -To $certificates[0] -Content ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ProtectedToken))))|ConvertFrom-Json
        if ($settings.nonce -cnotmatch '\A[A-Fa-f0-9]{64}\z' -or $settings.model -cnotmatch '\A[A-Za-z0-9._-]{1,128}\z' -or $settings.stage -notin @('initial','rotation','retired','cleanup')) { throw 'Invalid bounded real-response configuration.' }
        if (Test-Path -LiteralPath $statePath) { $state=(Unprotect-CmsMessage -To $certificates[0] -Content ([IO.File]::ReadAllText($statePath)))|ConvertFrom-Json }
        elseif ($settings.state) { $state=(Unprotect-CmsMessage -To $certificates[0] -Content ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($settings.state))))|ConvertFrom-Json }
        else {
            if ($settings.stage -eq 'cleanup') { throw 'No encrypted response ledger was recovered for cleanup.' }
            $state=[pscustomobject]@{owner=$ProbeId;attempts=0;unknownCreation=$false;items=@()}
        }
        if ($state.owner -cne $ProbeId -or $state.attempts -gt 4 -or @($state.items).Count -gt 4 -or
            @($state.items|Where-Object {$_.id -cnotmatch '\Aresp_[A-Za-z0-9_-]{1,128}\z' -or $_.caller -notin @('first','native') -or $_.epoch -notin @('old','new')}).Count) { throw 'Encrypted response state does not match this fixture.' }
        if ($settings.stage -eq 'initial') {
            if ($state.attempts -ne 0) { throw 'Initial real-response phase cannot be replayed.' }
            Assert-RealResponseStatus 'nonce-required' (Invoke-RealResponseRequest GET '/v1/models' first -WithoutNonce) @(403)
            Assert-RealResponseStatus 'credential-required' (Invoke-RealResponseRequest GET '/v1/models' missing) @(401)
            Assert-RealResponseStatus 'malformed-rejected' (Invoke-RealResponseRequest GET '/v1/models' malformed) @(401)
            foreach ($caller in @('first','second','native')) {
                $response=Invoke-RealResponseRequest GET '/v1/models' $caller
                $listed=$false
                try { $models=$response.Content|ConvertFrom-Json; $listed=@($models.data|Where-Object id -ceq $settings.model).Count -eq 1 } catch { }
                Assert-RealResponseStatus ('discovery-'+$caller) $response @(200) $listed
            }
            $background=Invoke-RealResponseCreation -Name 'create-background' -Caller first -Body (New-RealResponseBody -Background)
            $native=Invoke-RealResponseCreation -Name 'create-native' -Caller native -Body (New-RealResponseBody)
            foreach ($item in @($state.items)) {
                foreach ($caller in @('second',$(if ($item.caller -eq 'first') {'native'} else {'first'}))) {
                    foreach ($operation in @(@{name='get';method='GET';suffix=''},@{name='delete';method='DELETE';suffix=''},@{name='cancel';method='POST';suffix='/cancel'},@{name='input-items';method='GET';suffix='/input_items'})) {
                        Assert-RealResponseStatus ('cross-'+$item.name+'-'+$caller+'-'+$operation.name) (Invoke-RealResponseRequest $operation.method ('/v1/responses/'+$item.id+$operation.suffix) $caller) @(404)
                    }
                }
                $response=Invoke-RealResponseRequest GET ('/v1/responses/'+$item.id) $item.caller
                $stored=$null
                try { $stored=$response.Content|ConvertFrom-Json } catch { }
                Assert-RealResponseStatus ('owner-read-'+$item.name) $response @(200) ($stored.id -ceq $item.id -and $stored.metadata.byok_owner_v1 -ceq $item.marker)
                Assert-RealResponseStatus ('owner-input-'+$item.name) (Invoke-RealResponseRequest GET ('/v1/responses/'+$item.id+'/input_items') $item.caller)
            }
            $null=Invoke-RealResponseCreation -Name 'cross-owner-continuation' -Caller second -Body (New-RealResponseBody -Previous $native.id) -Expected 404
            $resume=Invoke-RealResponseRequest GET ('/v1/responses/'+$background.id+'?stream=true&starting_after=0') first
            Assert-RealResponseStatus 'background-resume' $resume @(200) ($resume.Content.Contains('data:'))
            $beforeCancel=Invoke-RealResponseRequest GET ('/v1/responses/'+$background.id) first
            $status=($beforeCancel.Content|ConvertFrom-Json).status
            $cancel=Invoke-RealResponseRequest POST ('/v1/responses/'+$background.id+'/cancel') first
            if ($cancel.StatusCode -eq 200) {
                $cancelled=$cancel.Content|ConvertFrom-Json
                Assert-RealResponseStatus 'owner-cancel' $cancel @(200) ($cancelled.id -ceq $background.id -and $cancelled.status -eq 'cancelled')
                $cancellationCovered=$true
            } elseif ($status -in @('completed','incomplete','failed','cancelled') -and $cancel.StatusCode -eq 400) {
                $observations.Add(@{name='owner-cancel-completed-before-test';http=400;passed=$true;coverage='inconclusive'})
            } else { Assert-RealResponseStatus 'owner-cancel' $cancel }
        } elseif ($settings.stage -eq 'rotation') {
            if ($state.attempts -ne 3) { throw 'Rotation phase requires the completed initial bounded creation attempts.' }
            foreach ($item in @($state.items)) { Assert-RealResponseStatus ('previous-key-read-'+$item.name) (Invoke-RealResponseRequest GET ('/v1/responses/'+$item.id) $item.caller) }
            $parent=@($state.items|Where-Object name -eq 'create-native')
            if ($parent.Count -ne 1) { throw 'Native continuation parent is unavailable.' }
            $created=Invoke-RealResponseCreation -Name 'owner-continuation-after-rotation' -Caller native -Body (New-RealResponseBody -Previous $parent[0].id) -Epoch new
            if ($created.metadata.byok_owner_v1 -ceq $parent[0].marker) { throw 'New response did not receive the rotated ownership marker.' }
        } elseif ($settings.stage -eq 'retired') {
            foreach ($item in @($state.items)) {
                $expected=if($item.epoch -eq 'old'){404}else{200}
                Assert-RealResponseStatus ('retired-key-'+$item.name) (Invoke-RealResponseRequest GET ('/v1/responses/'+$item.id) $item.caller) @($expected)
            }
        } else {
            foreach ($item in @($state.items)) {
                $response=Invoke-RealResponseRequest DELETE ('/v1/responses/'+$item.id) $item.caller
                $absent=Invoke-RealResponseRequest GET ('/v1/responses/'+$item.id) $item.caller
                Assert-RealResponseStatus ('cleanup-'+$item.name) $response @(200,404) ($absent.StatusCode -eq 404)
                $state.items=@($state.items|Where-Object id -cne $item.id)
                $null=Save-RealResponseState
            }
            if ($state.unknownCreation) { throw 'An uncertain creation requires recovery before cleanup can pass.' }
        }
        $passed=$true
    } catch {
        $observations.Add(@{name='stage-incomplete';http=0;passed=$false})
    } finally {
        if ($state) {
            $sealed=Save-RealResponseState
            [pscustomobject]@{test='real-responses-state';ciphertext=$sealed}|ConvertTo-Json -Compress
            if ($settings.stage -eq 'cleanup' -and $passed -and @($state.items).Count -eq 0) { Remove-Item -LiteralPath $statePath -Force }
        }
        [pscustomobject]@{test='real-responses-stage';stage=$settings.stage;passed=$passed;cases=$observations.Count;failed=@($observations|Where-Object {-not $_.passed});attempts=$state.attempts;remaining=@($state.items).Count;unknownCreation=[bool]$state.unknownCreation;cancellationCovered=$cancellationCovered;modelCallsSynthetic=$false}|ConvertTo-Json -Depth 6 -Compress
        $settings=$null;$state=$null
    }
    return
}

if ($Phase -eq 'SharedGovernanceTest') {
    $certificates = @(Get-ChildItem Cert:\LocalMachine\My | Where-Object Subject -eq "CN=$ProbeId")
    if ($certificates.Count -ne 1) { throw 'Expected one owned governance transport certificate.' }
    $listener = $null; $worker = $null; $task = $null; $ruleAttempted = $false
    $previousRevocation = [Net.ServicePointManager]::CheckCertificateRevocationList
    $receipts = [Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
    $stores = [Collections.Concurrent.ConcurrentDictionary[string,string]]::new()
    $observations = [Collections.Generic.List[object]]::new()
    $audit = [Collections.Generic.List[object]]::new()
    $summaryWritten = $false
    $governanceStage = 'decrypt'
    $readinessResult = $null
    try {
        $governance = (Unprotect-CmsMessage -To $certificates[0] -Content ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ProtectedToken)))) | ConvertFrom-Json
        if ($governance.nonce -notmatch '\A[A-Fa-f0-9]{64}\z' -or $governance.sourcePrefix -notmatch '\A(?:[0-9]{1,3}\.){3}[0-9]{1,3}/(?:[0-9]|[12][0-9]|3[0-2])\z' -or
            -not (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq $governance.mockAddress) -or
            (Get-NetFirewallRule -Name $ProbeId -ErrorAction SilentlyContinue) -or (Get-NetTCPConnection -LocalPort 18741 -State Listen -ErrorAction SilentlyContinue)) { throw 'Governance listener scope is not uniquely available on the selected VM.' }
        foreach ($property in $governance.urls.PSObject.Properties) {
            $uri = [uri]$property.Value
            if ($uri.Scheme -ne 'https' -or $uri.Authority -cne $GatewayUri.Authority -or $uri.AbsolutePath -cne ('/' + $ProbeId + '-' + $property.Name) -or $uri.Query -or $uri.UserInfo) { throw 'Governance request URL is outside its owned API scope.' }
        }
        $governanceStage = 'listener'
        [Net.ServicePointManager]::CheckCertificateRevocationList = $true
        $listener = [Net.HttpListener]::new()
        $listener.Prefixes.Add("http://+:18741/$ProbeId/")
        $listener.Start()
        $ruleAttempted = $true
        $null = New-NetFirewallRule -Name $ProbeId -DisplayName $ProbeId -Direction Inbound -Action Allow -Protocol TCP -LocalPort 18741 -LocalAddress $governance.mockAddress -RemoteAddress $governance.sourcePrefix -Profile Any
        $worker = [PowerShell]::Create()
        $null = $worker.AddScript({
            param($Listener, $Receipts, $Stores, $Nonce)
            while ($Listener.IsListening) {
                try { $exchange = $Listener.GetContext() } catch { break }
                try {
                    $request = $exchange.Request
                    $caseId = $request.Headers['X-Probe-Case']
                    if ($caseId -notmatch '\A[a-f0-9]{32}\z') { $caseId = 'untagged' }
                    $lookup = $request.Headers['X-Probe-Lookup'] -ceq 'true'
                    $backendCredential = if ($lookup) { $request.Headers['api-key'] } else { $request.Headers['X-Probe-Backend-Nonce'] }
                    $stripped = $backendCredential -ceq $Nonce -and -not $request.Headers['Authorization'] -and -not $request.Headers['x-api-key'] -and
                        -not $request.Headers['Ocp-Apim-Subscription-Key'] -and (-not $request.Headers['api-key'] -or $request.Headers['api-key'] -ceq $Nonce) -and
                        -not $request.QueryString['api-key'] -and -not $request.QueryString['subscription-key']
                    $prior = $null
                    if (-not $Receipts.TryGetValue($caseId, [ref]$prior)) { $prior = @{ calls = 0; lookups = 0; stripped = $true; body = $null; resumed = $false } }
                    $receipt = @{ calls = $prior.calls + [int](-not $lookup); lookups = $prior.lookups + [int]$lookup; stripped = $prior.stripped -and $stripped; body = $null; resumed = $false }
                    $Receipts[$caseId] = $receipt
                    if (-not $stripped) { $exchange.Response.StatusCode = 403; continue }
                    $body = $null
                    if ($request.HasEntityBody) {
                        $reader = New-Object IO.StreamReader($request.InputStream, [Text.Encoding]::UTF8)
                        try {
                            $buffer = New-Object char[] 65537
                            $length = $reader.ReadBlock($buffer, 0, $buffer.Length)
                            if ($length -ge $buffer.Length) { $exchange.Response.StatusCode = 413; continue }
                            $text = -join $buffer[0..([Math]::Max(0, $length - 1))]
                            if ($length) { $body = $text | ConvertFrom-Json }
                        } finally { $reader.Dispose() }
                    }
                    $receipt.body = $body
                    $status = 200
                    $stream = $body -and $body.stream -eq $true
                    $text = 'probe ' * 180
                    $usage = if ($request.Headers['X-Probe-Usage'] -ceq '270') { @{ input_tokens = 20; output_tokens = 250; total_tokens = 270 } } else { @{ input_tokens = 1; output_tokens = 1; total_tokens = 2 } }
                    $responses = $request.Url.AbsolutePath -match '/openai/v1/responses(?:/|$)'
                    if ($responses -and $request.Url.AbsolutePath -match '/responses/(?<reference>resp_[A-Za-z0-9_-]+)(?:/(?<action>cancel|input_items))?\z') {
                        $reference = $Matches.reference
                        $action = $Matches.action
                        $stored = $null
                        if (-not $Stores.TryGetValue($reference, [ref]$stored)) { $status = 404; $payload = @{ error = @{ code = 'NotFound' } } }
                        else {
                            $payload = $stored | ConvertFrom-Json
                            if (-not $lookup) {
                                if ($request.HttpMethod -eq 'DELETE') {
                                    $removed = $null
                                    $null = $Stores.TryRemove($reference, [ref]$removed)
                                    $payload = @{ id = $reference; object = 'response'; deleted = $true }
                                } elseif ($action -eq 'cancel') {
                                    $payload.status = 'cancelled'
                                    $Stores[$reference] = $payload | ConvertTo-Json -Depth 20 -Compress
                                } elseif ($action -eq 'input_items') { $payload = @{ object = 'list'; data = @(@{ type = 'message'; role = 'user'; content = 'fixture' }); has_more = $false } }
                                elseif ($request.QueryString['stream'] -eq 'true') { $stream = $true; $receipt.resumed = $request.QueryString['starting_after'] -eq '7' }
                            }
                        }
                    } elseif ($responses -and $request.HttpMethod -eq 'POST') {
                        $reference = 'resp_' + [guid]::NewGuid().ToString('N')
                        $payload = @{ id = $reference; object = 'response'; model = 'gpt-4o-mini'; status = $(if ($body.background) { 'in_progress' } else { 'completed' }); metadata = $body.metadata; output = @(@{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = $text }) }); usage = $usage }
                        if ($body.store -ne $false) { $Stores[$reference] = $payload | ConvertTo-Json -Depth 20 -Compress }
                    } else {
                        $payload = @{ id = 'chatcmpl_fixture'; object = 'chat.completion'; created = 0; model = 'gpt-4o-mini'; choices = @(@{ index = 0; message = @{ role = 'assistant'; content = $text }; finish_reason = 'stop' }); usage = @{ prompt_tokens = $usage.input_tokens; completion_tokens = $usage.output_tokens; total_tokens = $usage.total_tokens } }
                    }
                    $Receipts[$caseId] = $receipt
                    if ($stream -and $status -eq 200) {
                        if ($responses) {
                            $delta = @{ type = 'response.output_text.delta'; delta = $text } | ConvertTo-Json -Compress
                            $completed = @{ type = 'response.completed'; response = $payload } | ConvertTo-Json -Depth 20 -Compress
                            $responseBody = "event: response.output_text.delta`ndata: $delta`n`nevent: response.completed`ndata: $completed`n`n"
                        } else {
                            $delta = @{ id = 'chatcmpl_fixture'; object = 'chat.completion.chunk'; model = 'gpt-4o-mini'; choices = @(@{ index = 0; delta = @{ content = $text }; finish_reason = $null }) } | ConvertTo-Json -Depth 8 -Compress
                            $final = @{ id = 'chatcmpl_fixture'; object = 'chat.completion.chunk'; model = 'gpt-4o-mini'; choices = @(); usage = $payload.usage } | ConvertTo-Json -Depth 8 -Compress
                            $responseBody = "data: $delta`n`ndata: $final`n`ndata: [DONE]`n`n"
                        }
                    } else { $responseBody = $payload | ConvertTo-Json -Depth 20 -Compress }
                    $bytes = [Text.Encoding]::UTF8.GetBytes($responseBody)
                    $exchange.Response.StatusCode = $status
                    $exchange.Response.Headers['X-Probe-Backend'] = 'governance-mock'
                    $exchange.Response.ContentType = if ($stream) { 'text/event-stream' } else { 'application/json' }
                    $exchange.Response.ContentLength64 = $bytes.Length
                    $exchange.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                } catch {
                    $Receipts['worker-error'] = @{ calls = 1; lookups = 0; stripped = $false }
                    try { $exchange.Response.StatusCode = 500 } catch { }
                } finally { $exchange.Response.Close() }
            }
        }).AddArgument($listener).AddArgument($receipts).AddArgument($stores).AddArgument($governance.nonce)
        $task = $worker.BeginInvoke()
        function Test-ProbeGovernanceRequest {
            param([string] $Name, [string] $Uri, [string] $Method = 'GET', [hashtable] $Headers = @{}, [object] $Body, [int[]] $ExpectedStatus = @(200), [int] $ExpectedLookups = 0, [string[]] $Wire, [string] $ExpectedMethod = '', [string] $ExpectedProduct = '')
            $caseId = [guid]::NewGuid().ToString('N')
            $status = 0; $responseHeaders = @{}; $content = ''
            try {
                [string[]]$headerLines = @(if ($Wire) { $Wire } else { $Headers.GetEnumerator() | ForEach-Object { $_.Key + ': ' + $_.Value } })
                $request = @{ RequestUri = [uri]$Uri; Method = $Method; HeaderLines = @($headerLines + ('X-Probe-Case: ' + $caseId)); ReadContent = $true }
                if ($null -ne $Body) { $request.Body = $Body | ConvertTo-Json -Depth 20 -Compress }
                $response = Invoke-ProbeWireRequest @request
                $content = [string]$response.Content
                $status = [int]$response.StatusCode; $responseHeaders = $response.Headers
            } catch { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode; $responseHeaders = $_.Exception.Response.Headers } }
            $expectedCalls = [int]($status -eq 200)
            $receipt = $null
            $found = $receipts.TryGetValue($caseId, [ref]$receipt)
            $calls = if ($found) { $receipt.calls } else { 0 }
            $lookups = if ($found) { $receipt.lookups } else { 0 }
            $passed = $status -in $ExpectedStatus -and $calls -eq $expectedCalls -and $lookups -eq $ExpectedLookups -and (-not $found -or $receipt.stripped)
            if ($status -eq 200 -and $ExpectedMethod) { $passed = $passed -and $responseHeaders['X-Probe-Method'] -ceq $ExpectedMethod -and $responseHeaders['X-Probe-Accounted'] -ceq 'True' }
            if ($status -eq 200 -and $ExpectedProduct) { $passed = $passed -and $responseHeaders['X-Probe-Product'] -ceq $ExpectedProduct }
            $rejectedBy = [string]$responseHeaders['X-Probe-Rejected']
            if ($rejectedBy -cnotmatch '\Abyok-[a-z-]+\z') { $rejectedBy = '' }
            $errorCode = ''
            if ($status -ne 200 -and $content.StartsWith('{')) {
                try { $candidate = ($content | ConvertFrom-Json).error.code; if ($candidate -in @('InvalidCredentialSource','InvalidCallerToken','InvalidCallerIdentity','CallerAccountingInvalid','ResponseOwnershipUnavailable','ResponseUnavailable')) { $errorCode = $candidate } } catch { }
            }
            $observations.Add(@{ name = $Name; http = $status; calls = $calls; lookups = $lookups; passed = [bool]$passed; rejectedBy = $rejectedBy; errorCode = $errorCode })
            $audit.Add(@{ id = $caseId; calls = $expectedCalls; lookups = $ExpectedLookups })
            if ($status -eq 0) { throw 'Governance transport failed; no network changes were attempted.' }
            return @{ status = $status; headers = $responseHeaders; content = $content; receipt = $receipt; observation = $observations[$observations.Count - 1] }
        }
        foreach ($property in $governance.urls.PSObject.Properties) {
            $governanceStage = 'readiness-' + $property.Name
            $ready = $false
            foreach ($attempt in 1..6) {
                $readinessResult = @{ attempt = $attempt; http = 0; marked = $false; transport = '' }
                try {
                    $response = Invoke-ProbeWireRequest -RequestUri ($property.Value + '/v1/chat/completions') -Method POST -HeaderLines @(('X-Probe-Ready: ' + $ProbeId), ('api-key: ' + $governance.keys.first)) -Body '{}' -ReadContent
                    $ready = $response.StatusCode -eq 204 -and $response.Headers['X-Probe-Governance'] -ceq $ProbeId
                    $readinessResult.http = [int]$response.StatusCode
                    $readinessResult.marked = $response.Headers['X-Probe-Governance'] -ceq $ProbeId
                    if ($ready) { break }
                    if ($response.StatusCode -notin @(401,404)) { throw 'Unexpected readiness response.' }
                } catch {
                    if ($_.Exception.Response) { $readinessResult.http = [int]$_.Exception.Response.StatusCode }
                    else { $readinessResult.transport = if ($_.Exception -is [Net.WebException]) { $_.Exception.Status.ToString() } else { $_.Exception.GetBaseException().GetType().Name } }
                    if (-not $_.Exception.Response -or $readinessResult.http -notin @(401,404)) { throw 'Governance readiness failed; no measured request was sent.' }
                }
            }
            if (-not $ready) { throw 'Governance API publication was not ready within the bounded checks.' }
        }
        $governanceStage = 'measured'
        $check = $governance.urls.stateful + '/check'
        foreach ($kind in @('first','second','secondary','api','all','rotated','wrongScope','wrongProduct','suspended','rotatedOld')) {
            $expected = if ($kind -in @('wrongScope','wrongProduct','suspended','rotatedOld')) { 401 } else { 200 }
            $product = 'False'
            $null = Test-ProbeGovernanceRequest -Name ('key-' + $kind) -Uri $check -Headers @{ 'api-key' = $governance.keys.$kind } -ExpectedStatus @($expected) -ExpectedMethod 'subscriptionKey' -ExpectedProduct $product
        }
        $null = Test-ProbeGovernanceRequest -Name 'missing' -Uri $check -ExpectedStatus @(401)
        $null = Test-ProbeGovernanceRequest -Name 'invalid' -Uri $check -Headers @{ 'api-key' = 'fixture-invalid' } -ExpectedStatus @(401)
        $parts = $governance.firstToken.Split('.')
        $tampered = $parts[0] + '.' + $parts[1] + $(if ($parts[2][0] -eq 'A') { '.B' } else { '.A' }) + $parts[2].Substring(1)
        $null = Test-ProbeGovernanceRequest -Name 'tampered' -Uri $check -Headers @{ Authorization = 'Bearer ' + $tampered } -ExpectedStatus @(401)
        $null = Test-ProbeGovernanceRequest -Name 'mixed-source' -Uri $check -Headers @{ 'api-key' = $governance.keys.first; Authorization = 'Bearer ' + $governance.firstToken } -ExpectedStatus @(401)
        $null = Test-ProbeGovernanceRequest -Name 'query-key' -Uri ($check + '?api-key=' + [uri]::EscapeDataString($governance.keys.first)) -ExpectedMethod 'subscriptionKey' -ExpectedProduct 'False'
        $null = Test-ProbeGovernanceRequest -Name 'query-jwt' -Uri ($check + '?api-key=' + [uri]::EscapeDataString($governance.firstToken)) -ExpectedStatus @(401)
        foreach ($user in @('first','second')) {
            $token = $governance.($user + 'Token')
            $null = Test-ProbeGovernanceRequest -Name ('jwt-' + $user) -Uri $check -Headers @{ Authorization = 'Bearer ' + $token } -ExpectedMethod 'entraJwt' -ExpectedProduct 'False'
            $null = Test-ProbeGovernanceRequest -Name ('wire-single-' + $user) -Uri $check -Wire @('Authorization: Bearer ' + $token) -ExpectedMethod 'entraJwt' -ExpectedProduct 'False'
        }
        foreach ($ordered in @(@($governance.firstToken,$governance.secondToken), @($governance.secondToken,$governance.firstToken))) {
            $null = Test-ProbeGovernanceRequest -Name 'two-valid-users-conflict' -Uri $check -Wire @(('Authorization: Bearer ' + $ordered[0]), ('Authorization: Bearer ' + $ordered[1])) -ExpectedStatus @(400,401)
        }
        $null = Test-ProbeGovernanceRequest -Name 'identical-bearer' -Uri $check -Wire @(('Authorization: Bearer ' + $governance.firstToken), ('Authorization: Bearer ' + $governance.firstToken)) -ExpectedStatus @(200,400,401) -ExpectedMethod 'entraJwt' -ExpectedProduct 'False'
        if (@($observations | Where-Object { -not $_.passed }).Count) { $governanceStage = 'admission'; throw 'Admission controls failed; quota/stateful checks were not started.' }
        $actors = @(
            @{ name = 'jwt-first'; headers = @{ Authorization = 'Bearer ' + $governance.firstToken }; method = 'entraJwt'; product = 'False' },
            @{ name = 'jwt-second'; headers = @{ Authorization = 'Bearer ' + $governance.secondToken }; method = 'entraJwt'; product = 'False' },
            @{ name = 'key-first'; headers = @{ 'api-key' = $governance.keys.first }; method = 'subscriptionKey'; product = 'True' },
            @{ name = 'key-second'; headers = @{ 'api-key' = $governance.keys.second }; method = 'subscriptionKey'; product = 'True' }
        )
        $normal = @{ model = 'gpt-4o-mini'; messages = @(@{ role = 'user'; content = 'ping' }); max_tokens = 256; stream = $false }
        foreach ($mode in @('rpm','quota')) {
            $null = Test-ProbeGovernanceRequest -Name ($mode + '-conflict') -Uri ($governance.urls.$mode + '/v1/chat/completions') -Method POST -Headers @{ 'api-key' = $governance.keys.first; Authorization = 'Bearer ' + $governance.firstToken } -Body $normal -ExpectedStatus @(401)
            foreach ($actor in $actors) {
                foreach ($attempt in 1..5) {
                    $expected = if ($attempt -le 3) { @(200) } elseif ($mode -eq 'quota') { @(403) } elseif ($attempt -eq 4 -and $actor.method -eq 'entraJwt') { @(200,429) } else { @(429) }
                    $path = if ($attempt -ge 4) { '/alias/chat/completions' } else { '/v1/chat/completions' }
                    $null = Test-ProbeGovernanceRequest -Name ($mode + '-' + $actor.name + '-' + $attempt) -Uri ($governance.urls.$mode + $path) -Method POST -Headers $actor.headers -Body $normal -ExpectedStatus $expected -ExpectedMethod $actor.method -ExpectedProduct $actor.product
                }
            }
        }
        $meteringRows = @()
        foreach ($mode in @('tpm-chat-json','tpm-chat-stream','tpm-responses-json','tpm-responses-stream')) {
            $isResponses = $mode.Contains('-responses-'); $stream = $mode.EndsWith('-stream')
            $body = if ($isResponses) { @{ model = 'gpt-4o-mini'; input = 'ping'; store = $false; stream = $stream; max_output_tokens = 256 } } else { $normal.Clone() }
            $body.stream = $stream
            if ($stream -and -not $isResponses) { $body.stream_options = @{ include_usage = $true } }
            foreach ($actor in $actors | Where-Object method -eq 'entraJwt') {
                foreach ($attempt in 1..3) {
                    $expected = if ($attempt -eq 1) { @(200) } elseif ($attempt -eq 2) { @(200,429) } else { @(429) }
                    $result = Test-ProbeGovernanceRequest -Name ($mode + '-' + $actor.name + '-' + $attempt) -Uri ($governance.urls.$mode + $(if ($isResponses) { '/v1/responses' } else { '/v1/chat/completions' })) -Method POST -Headers $actor.headers -Body $body -ExpectedStatus $expected -ExpectedMethod 'entraJwt' -ExpectedProduct 'False'
                    $consumed = [string]$result.headers['x-byok-tokens-consumed']
                    if ($consumed -notmatch '\A[0-9]{1,8}\z') { $consumed = '' }
                    if ($attempt -eq 1) {
                        $shape = $result.content.Contains('probe') -and $(if ($stream) { $result.content.Contains($(if ($isResponses) { 'response.completed' } else { '[DONE]' })) } else { $result.content.Contains('usage') })
                        $result.observation.passed = $result.observation.passed -and $shape
                    }
                    $meteringRows += ,@($mode, $actor.name, $attempt, $result.status, $consumed)
                }
            }
        }
        $owned = @{}
        foreach ($actor in $actors) {
            $body = @{ model = 'gpt-4o-mini'; input = 'fixture'; store = $true; background = $true; reasoning = @{ effort = 'low' }; tools = @(@{ type = 'function'; name = 'fixture'; parameters = @{ type = 'object'; properties = @{} } }); metadata = @{ byok_owner_v1 = 'client-forged'; fixture = 'preserved' } }
            $result = Test-ProbeGovernanceRequest -Name ('create-' + $actor.name) -Uri ($governance.urls.stateful + '/v1/responses') -Method POST -Headers $actor.headers -Body $body -ExpectedMethod $actor.method -ExpectedProduct $actor.product
            $created = if ($result.status -eq 200) { $result.content | ConvertFrom-Json } else { $null }
            $preserved = $created -and $created.id -match '\Aresp_[a-f0-9]{32}\z' -and $created.metadata.byok_owner_v1 -match '\Av1\.[a-f0-9]{64}\z' -and $created.metadata.fixture -ceq 'preserved' -and
                $result.receipt.body.background -eq $true -and $result.receipt.body.store -eq $true -and $result.receipt.body.reasoning.effort -ceq 'low' -and @($result.receipt.body.tools).Count -eq 1
            $result.observation.passed = $result.observation.passed -and $preserved
            if (-not $preserved) { throw 'Stateful creation/stamping failed; ownership matrix cannot proceed.' }
            $owned[$actor.name] = $created.id
        }
        foreach ($owner in $actors) {
            foreach ($caller in $actors | Where-Object name -ne $owner.name) {
                foreach ($operation in @(@{ name = 'get'; method = 'GET'; suffix = '' }, @{ name = 'delete'; method = 'DELETE'; suffix = '' }, @{ name = 'cancel'; method = 'POST'; suffix = '/cancel' }, @{ name = 'input-items'; method = 'GET'; suffix = '/input_items' })) {
                    $null = Test-ProbeGovernanceRequest -Name ('cross-owner-' + $operation.name + '-' + $caller.name + '-' + $owner.name) -Uri ($governance.urls.stateful + '/v1/responses/' + $owned[$owner.name] + $operation.suffix) -Method $operation.method -Headers $caller.headers -ExpectedStatus @(404) -ExpectedLookups 1
                }
            }
            $uri = $governance.urls.stateful + '/v1/responses/' + $owned[$owner.name]
            $null = Test-ProbeGovernanceRequest -Name ('owner-get-' + $owner.name) -Uri $uri -Headers $owner.headers -ExpectedLookups 1
            $null = Test-ProbeGovernanceRequest -Name ('owner-input-' + $owner.name) -Uri ($uri + '/input_items') -Headers $owner.headers -ExpectedLookups 1
            $result = Test-ProbeGovernanceRequest -Name ('owner-resume-' + $owner.name) -Uri ($uri + '?stream=true&starting_after=7') -Headers $owner.headers -ExpectedLookups 1
            $result.observation.passed = $result.observation.passed -and $result.receipt.resumed -and $result.content.Contains('response.completed')
            $null = Test-ProbeGovernanceRequest -Name ('owner-cancel-' + $owner.name) -Uri ($uri + '/cancel') -Method POST -Headers $owner.headers -ExpectedLookups 1
            $continuation = @{ model = 'gpt-4o-mini'; input = 'continue'; previous_response_id = $owned[$owner.name]; store = $true }
            $null = Test-ProbeGovernanceRequest -Name ('owner-continue-' + $owner.name) -Uri ($governance.urls.stateful + '/v1/responses') -Method POST -Headers $owner.headers -Body $continuation -ExpectedLookups 1
            $other = @($actors | Where-Object name -ne $owner.name)[0]
            $null = Test-ProbeGovernanceRequest -Name ('cross-owner-continue-' + $other.name + '-' + $owner.name) -Uri ($governance.urls.stateful + '/v1/responses') -Method POST -Headers $other.headers -Body $continuation -ExpectedStatus @(404) -ExpectedLookups 1
        }
        foreach ($actor in $actors) {
            $uri = $governance.urls.stateful + '/v1/responses/' + $owned[$actor.name]
            $null = Test-ProbeGovernanceRequest -Name ('owner-delete-' + $actor.name) -Uri $uri -Method DELETE -Headers $actor.headers -ExpectedLookups 1
            $null = Test-ProbeGovernanceRequest -Name ('deleted-unavailable-' + $actor.name) -Uri $uri -Headers $actor.headers -ExpectedStatus @(404) -ExpectedLookups 1
        }
        $stores['resp_unstamped'] = '{"id":"resp_unstamped","object":"response","metadata":{}}'
        $null = Test-ProbeGovernanceRequest -Name 'unstamped-unavailable' -Uri ($governance.urls.stateful + '/v1/responses/resp_unstamped') -Headers $actors[0].headers -ExpectedStatus @(404) -ExpectedLookups 1
        $null = Test-ProbeGovernanceRequest -Name 'utility-tampered' -Uri ($governance.urls.stateful + '/v1/responses/resp_unstamped') -Headers @{ Authorization = 'Bearer ' + $tampered } -ExpectedStatus @(401)
        $audited = $true
        foreach ($entry in $audit) {
            $receipt = $null
            $found = $receipts.TryGetValue($entry.id, [ref]$receipt)
            if (($found -and ($receipt.calls -ne $entry.calls -or $receipt.lookups -ne $entry.lookups -or -not $receipt.stripped)) -or (-not $found -and ($entry.calls -ne 0 -or $entry.lookups -ne 0))) { $audited = $false }
        }
        if ($receipts.ContainsKey('worker-error') -or $receipts.ContainsKey('untagged') -or @($receipts.Keys | Where-Object { $_ -notin $audit.id }).Count) { $audited = $false }
        $failed = @($observations | Where-Object { -not $_.passed })
        [pscustomobject]@{ test = 'shared-governance-metering'; columns = @('fixture','caller','attempt','http','consumed'); rows = $meteringRows; modelCalled = $false } | ConvertTo-Json -Depth 6 -Compress
        [pscustomobject]@{ test = 'shared-governance-summary'; passed = $failed.Count -eq 0 -and $audited; cases = $observations.Count; failures = $failed.Count; failedCases = @($failed | Select-Object -First 8); receiptAudit = $audited; contract = 'single-credential-v1'; modelCalled = $false; backendTlsValidated = $false } | ConvertTo-Json -Depth 6 -Compress
        $summaryWritten = $true
    } finally {
        if (-not $summaryWritten) {
            $failed = @($observations | Where-Object { -not $_.passed })
            [pscustomobject]@{ test = 'shared-governance-summary'; passed = $false; completed = $false; stage = $governanceStage; readiness = $readinessResult; cases = $observations.Count; failures = $failed.Count; failedCases = @($failed | Select-Object -First 8); receiptAudit = $false; contract = 'single-credential-v1'; modelCalled = $false } | ConvertTo-Json -Depth 6 -Compress
        }
        $governance = $null; $tampered = $null; $actors = $null
        try {
            if ($listener) { $listener.Stop(); $listener.Close() }
            if ($worker -and $task) { $null = $worker.EndInvoke($task) }
        } finally {
            if ($worker) { $worker.Dispose() }
            [Net.ServicePointManager]::CheckCertificateRevocationList = $previousRevocation
            if ($ruleAttempted -and (Get-NetFirewallRule -Name $ProbeId -ErrorAction SilentlyContinue)) { Remove-NetFirewallRule -Name $ProbeId }
            Remove-Item -LiteralPath $certificates[0].PSPath -DeleteKey -Force
            $clean = -not (Get-NetFirewallRule -Name $ProbeId -ErrorAction SilentlyContinue) -and -not (Get-NetTCPConnection -LocalPort 18741 -State Listen -ErrorAction SilentlyContinue) -and -not (Get-ChildItem Cert:\LocalMachine\My | Where-Object Subject -eq "CN=$ProbeId")
            [pscustomobject]@{ test = 'shared-governance-cleanup'; passed = [bool]$clean } | ConvertTo-Json -Compress
        }
    }
    return
}

if ($Phase -eq 'SharedConsumerTest') {
    if (-not $ProbeId -or $GatewayUri.AbsolutePath.TrimEnd('/') -cne ('/' + $ProbeId)) { throw 'Consumer validation requires its own temporary API path.' }
    $consumerNames=@('foundry-inference', 'aoai-inference', 'foundry-models', 'responses-item')
    if($ConsumerInventory -eq 'packages'){
        foreach($kind in @('inference','models','responses')){$consumerNames+='intellij-'+$kind}
        foreach($profile in @('foundry-basic','foundry-fixed','aoai-fixed')){foreach($kind in @('inference','models','responses')){$consumerNames+='wizard-'+$profile+'-'+$kind}}
    }
    foreach ($consumer in $consumerNames) {
        $diagnostics = @{}
        $status = 0
        $passed = $false
        try {
            $response = Invoke-ProbeWireRequest ([uri]($GatewayUri.AbsoluteUri.TrimEnd('/') + '/compile-' + $consumer)) @() -Diagnostics $diagnostics
            $status = $response.StatusCode
            $passed = $status -eq 403 -and $response.Headers['X-Probe-Consumer'] -ceq ($ProbeId + ':' + $consumer)
        } catch { }
        $stage = if ($diagnostics.transportStage -in @('dns','connect','tls','write','response')) { $diagnostics.transportStage } else { '' }
        [pscustomobject]@{ test = 'shared-consumer-denial'; consumer = $consumer; http = $status; passed = [bool]$passed; transportStage = $stage; backendEnabled = $false } | ConvertTo-Json -Compress
        if (-not $passed) { break }
    }
    return
}

if($Phase -eq 'SharedRollbackTest'){
    if(-not $ProbeId -or $GatewayUri.Scheme -ne 'https' -or $GatewayUri.AbsolutePath -cne ('/'+$ProbeId+'-stateful/check') -or $GatewayUri.Query -or $GatewayUri.UserInfo){throw 'Rollback requests must target the owned no-backend operation.'}
    $certificates=@(Get-ChildItem Cert:\LocalMachine\My|Where-Object Subject -eq "CN=$ProbeId")
    if($certificates.Count -ne 1){throw 'Expected the owned rollback transport certificate.'}
    $settings=$null;$cases=@()
    try{
        $settings=(Unprotect-CmsMessage -To $certificates[0] -Content ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ProtectedToken))))|ConvertFrom-Json
        foreach($kind in @('first','second','secondary','api','all','wrongScope')){
            $cases+=@{name='native-'+$kind;headers=@('api-key: '+$settings.keys.$kind);expected=$(if($kind -eq 'wrongScope'){401}else{200})}
        }
        foreach($user in @('first','second')){$cases+=@{name='jwt-'+$user;headers=@('Authorization: Bearer '+$settings.($user+'Token'));expected=$(if($RollbackStage -eq 'before'){200}else{401})}}
        $cases+=@(@{name='missing';headers=@();expected=401},@{name='invalid';headers=@('api-key: fixture-invalid');expected=401})
        foreach($case in $cases){
            $response=Invoke-ProbeWireRequest $GatewayUri $case.headers
            $passed=$response.StatusCode -eq $case.expected
            if($response.StatusCode -eq 200){$passed=$passed -and $response.Headers['X-Probe-Rollback'] -ceq $ProbeId -and $response.Headers['X-Probe-Stripped'] -ceq 'True'}
            [pscustomobject]@{test='shared-admission-rollback';stage=$RollbackStage;case=$case.name;http=$response.StatusCode;passed=[bool]$passed;backendCalled=$false}|ConvertTo-Json -Compress
        }
    }finally{$settings=$null;$cases=$null}
    return
}

if ($Phase -eq 'SharedRuntimeTest') {
    $certificates = @(Get-ChildItem Cert:\LocalMachine\My | Where-Object Subject -eq "CN=$ProbeId")
    if ($certificates.Count -ne 1) { throw 'Expected the owned temporary token transport certificate.' }
    try {
        $token = Unprotect-CmsMessage -To $certificates[0] -Content ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ProtectedToken)))
        $parts = $token.Split('.')
        if ($parts.Count -ne 3) { throw 'Transported token was not JWT-shaped.' }
        $changed = if ($parts[2][0] -eq 'A') { 'B' } else { 'A' }
        $tampered = $parts[0] + '.' + $parts[1] + '.' + $changed + $parts[2].Substring(1)
        $cases = @(
            @{ name = 'missing'; headers = @(); expected = 401 },
            @{ name = 'malformed'; headers = @('Authorization: Bearer not-a-jwt'); expected = 401 },
            @{ name = 'api-key-jwt'; headers = @('api-key: ' + $token); expected = 200 },
            @{ name = 'bearer-jwt'; headers = @('Authorization: Bearer ' + $token); expected = 200 },
            @{ name = 'tampered'; headers = @('Authorization: Bearer ' + $tampered); expected = 401 },
            @{ name = 'mixed-source'; headers = @(('api-key: ' + $token), ('Authorization: Bearer ' + $token)); expected = 401 },
            @{ name = 'identical-bearer'; headers = @(('Authorization: Bearer ' + $token), ('Authorization: Bearer ' + $token)); expected = 200; duplicate = $true }
        )
        foreach ($case in $cases) {
            $response = Invoke-ProbeWireRequest $GatewayUri $case.headers
            $accepted = $response.StatusCode -eq 200
            $passed = $response.StatusCode -eq $case.expected -or ($case.duplicate -and $response.StatusCode -in @(400,401))
            if ($accepted) { $passed = $passed -and $response.Headers['X-Probe-Shared'] -ceq $ProbeId -and $response.Headers['X-Probe-Validated'] -ceq 'True' -and $response.Headers['X-Probe-Stripped'] -ceq 'True' }
            [pscustomobject]@{ test = 'shared-runtime-auth'; case = $case.name; http = $response.StatusCode; accepted = $accepted; passed = [bool]$passed; contract = 'single-credential-v1'; modelCalled = $false } | ConvertTo-Json -Compress
        }
    } finally {
        $token = $null; $tampered = $null; $cases = $null
        Remove-Item -LiteralPath $certificates[0].PSPath -DeleteKey -Force
        [pscustomobject]@{ test = 'temporary-transport-certificate-removed'; passed = $true } | ConvertTo-Json -Compress
    }
    return
}

if ($Phase -eq 'AnthropicMeteringTest') {
    if (-not $ProbeId -or $GatewayUri.AbsolutePath.TrimEnd('/') -cne ('/' + $ProbeId) -or
        $MockSourcePrefix -notmatch '^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$') { throw 'Metering requires its owned path and verified APIM source subnet.' }
    $fixtures = @($MeteringFixtures -split ',')
    if (-not $fixtures.Count -or $fixtures.Count -gt 8 -or @($fixtures | Where-Object { $_ -notmatch '^(old|llm)-(openai|anthropic)-(json|stream)$' }).Count -or
        @($fixtures | Select-Object -Unique).Count -ne $fixtures.Count) { throw 'Invalid metering fixture inventory.' }
    if (Get-NetFirewallRule -Name $ProbeId -ErrorAction SilentlyContinue) { throw 'Metering firewall rule already exists.' }
    if (-not (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq $MockAddress)) { throw 'Metering mock address does not belong to this VM.' }
    if (Get-NetTCPConnection -LocalPort 18741 -State Listen -ErrorAction SilentlyContinue) { throw 'Metering mock port is already in use.' }
    $listener = $null
    $worker = $null
    $task = $null
    $ruleAttempted = $false
    $previousRevocationCheck = [Net.ServicePointManager]::CheckCertificateRevocationList
    [Net.ServicePointManager]::CheckCertificateRevocationList = $true
    $receipts = [Collections.Concurrent.ConcurrentDictionary[string,int]]::new()
    try {
        $listener = [Net.HttpListener]::new()
        $listener.Prefixes.Add("http://+:18741/$ProbeId/")
        $listener.Start()
        $ruleAttempted = $true
        $null = New-NetFirewallRule -Name $ProbeId -DisplayName $ProbeId -Direction Inbound -Action Allow -Protocol TCP -LocalPort 18741 -LocalAddress $MockAddress -RemoteAddress $MockSourcePrefix -Profile Any
        $worker = [PowerShell]::Create()
        $null = $worker.AddScript({
            param($Listener, $Receipts)
            while ($Listener.IsListening) {
                try { $requestContext = $Listener.GetContext() } catch { break }
                try {
                    $fixture = $requestContext.Request.Url.Segments[-1]
                    if ($fixture -notmatch '^(old|llm)-(openai|anthropic)-(json|stream)$') { $requestContext.Response.StatusCode = 404; continue }
                    $caseId = $requestContext.Request.Headers['X-Probe-Case']
                    if ($caseId -notmatch '^[a-f0-9]{32}$') { $requestContext.Response.StatusCode = 400; continue }
                    if ($requestContext.Request.ContentLength64 -lt 0 -or $requestContext.Request.ContentLength64 -gt 16384) { $requestContext.Response.StatusCode = 413; continue }
                    $requestReader = New-Object IO.StreamReader($requestContext.Request.InputStream, [Text.Encoding]::UTF8)
                    try { $null = $requestReader.ReadToEnd() | ConvertFrom-Json } finally { $requestReader.Dispose() }
                    $Receipts[$caseId] = 1
                    $anthropic = $fixture -match '-anthropic-'
                    $stream = $fixture.EndsWith('-stream')
                    $text = 'probe ' * 180
                    if ($anthropic) {
                        $payload = @{ id = 'msg_fixture'; type = 'message'; role = 'assistant'; model = 'claude-sonnet-4-6'; content = @(@{ type = 'text'; text = $text }); stop_reason = 'end_turn'; stop_sequence = $null; usage = @{ input_tokens = 20; output_tokens = 250 } }
                        if ($stream) {
                            $start = @{ type = 'message_start'; message = @{ id = 'msg_fixture'; type = 'message'; role = 'assistant'; model = 'claude-sonnet-4-6'; content = @(); stop_reason = $null; stop_sequence = $null; usage = @{ input_tokens = 20; output_tokens = 0 } } } | ConvertTo-Json -Depth 8 -Compress
                            $delta = @{ type = 'content_block_delta'; index = 0; delta = @{ type = 'text_delta'; text = $text } } | ConvertTo-Json -Depth 5 -Compress
                            $body = "event: message_start`ndata: $start`n`nevent: content_block_start`ndata: {`"type`":`"content_block_start`",`"index`":0,`"content_block`":{`"type`":`"text`",`"text`":`"`"}}`n`nevent: content_block_delta`ndata: $delta`n`nevent: content_block_stop`ndata: {`"type`":`"content_block_stop`",`"index`":0}`n`nevent: message_delta`ndata: {`"type`":`"message_delta`",`"delta`":{`"stop_reason`":`"end_turn`",`"stop_sequence`":null},`"usage`":{`"output_tokens`":250}}`n`nevent: message_stop`ndata: {`"type`":`"message_stop`"}`n`n"
                        } else { $body = $payload | ConvertTo-Json -Depth 8 -Compress }
                    } else {
                        $payload = @{ id = 'chatcmpl_fixture'; object = 'chat.completion'; created = 0; model = 'gpt-4o-mini'; choices = @(@{ index = 0; message = @{ role = 'assistant'; content = $text }; finish_reason = 'stop' }); usage = @{ prompt_tokens = 20; completion_tokens = 250; total_tokens = 270 } }
                        if ($stream) {
                            $delta = @{ id = 'chatcmpl_fixture'; object = 'chat.completion.chunk'; created = 0; model = 'gpt-4o-mini'; choices = @(@{ index = 0; delta = @{ content = $text }; finish_reason = $null }) } | ConvertTo-Json -Depth 8 -Compress
                            $usage = @{ id = 'chatcmpl_fixture'; object = 'chat.completion.chunk'; created = 0; model = 'gpt-4o-mini'; choices = @(); usage = $payload.usage } | ConvertTo-Json -Depth 5 -Compress
                            $body = "data: $delta`n`ndata: $usage`n`ndata: [DONE]`n`n"
                        } else { $body = $payload | ConvertTo-Json -Depth 8 -Compress }
                    }
                    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
                    $requestContext.Response.StatusCode = 200
                    $requestContext.Response.Headers['X-Probe-Backend'] = 'synthetic-usage'
                    $requestContext.Response.ContentType = if ($stream) { 'text/event-stream' } else { 'application/json' }
                    $requestContext.Response.ContentLength64 = $bytes.Length
                    $requestContext.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                } finally { $requestContext.Response.Close() }
            }
        }).AddArgument($listener).AddArgument($receipts)
        $task = $worker.BeginInvoke()
        foreach ($fixture in $fixtures) {
            $anthropic = $fixture -match '-anthropic-'
            $stream = $fixture.EndsWith('-stream')
            $suffix = if ($anthropic) { 'v1/messages' } else { 'v1/chat/completions' }
            $fixtureUri = $GatewayUri.AbsoluteUri.TrimEnd('/') + '/' + $fixture + '/' + $suffix
            $ready = $false
            foreach ($readinessAttempt in 1..6) {
                try {
                    $readiness = Invoke-WebRequest -UseBasicParsing -DisableKeepAlive -Method Post -Uri $fixtureUri -Headers @{ 'X-Probe-Ready' = $ProbeId } -ContentType 'application/json' -Body '{}' -TimeoutSec 30
                    $ready = $readiness.StatusCode -eq 204 -and $readiness.Headers['X-Probe-Metering'] -ceq $fixture
                    if (-not $ready) { throw 'Unexpected response from metering readiness operation.' }
                    break
                } catch {
                    if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -notin @(401,404)) { throw 'Metering readiness failed; no measured request was sent.' }
                }
            }
            if (-not $ready) { throw 'Metering operation did not become ready within the bounded checks.' }
            $requestBody = @{ model = $(if ($anthropic) { 'claude-sonnet-4-6' } else { 'gpt-4o-mini' }); messages = @(@{ role = 'user'; content = 'ping' }); max_tokens = 256; stream = $stream }
            if ($stream -and -not $anthropic) { $requestBody.stream_options = @{ include_usage = $true } }
            $attempts = @()
            foreach ($attempt in 1..3) {
                $caseId = [guid]::NewGuid().ToString('N')
                $status = 0
                $headers = @{}
                $content = ''
                $transportFailure = ''
                try {
                    $response = Invoke-WebRequest -UseBasicParsing -DisableKeepAlive -Method Post -Uri $fixtureUri -Headers @{ 'X-Probe-Case' = $caseId; 'anthropic-version' = '2023-06-01' } -ContentType 'application/json' -Body ($requestBody | ConvertTo-Json -Depth 6 -Compress) -TimeoutSec 30
                    $status = [int]$response.StatusCode
                    $headers = $response.Headers
                    $content = [string]$response.Content
                } catch {
                    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode; $headers = $_.Exception.Response.Headers }
                    else { $transportFailure = if ($_.Exception -is [Net.WebException]) { $_.Exception.Status.ToString() } else { $_.Exception.GetBaseException().GetType().Name } }
                }
                $consumed = [string]$headers['x-probe-tokens']
                if ($consumed -notmatch '^[0-9]{1,8}$') { $consumed = '' }
                $shape = $status -eq 200 -and $content.Contains('probe') -and $(if ($stream) { $content.Contains($(if ($anthropic) { 'message_stop' } else { '[DONE]' })) } else { $content.Contains('usage') })
                $attempts += [pscustomobject]@{ attempt = $attempt; http = $status; backendReceived = $receipts.ContainsKey($caseId); consumed = $consumed; shape = $shape; transportFailure = $transportFailure }
            }
            $passed = $attempts[0].http -eq 200 -and $attempts[0].backendReceived -and $attempts[0].shape -and
                $attempts[2].http -eq 429 -and -not $attempts[2].backendReceived -and @($attempts | Where-Object { $_.http -notin @(200,429) -or ($_.http -eq 429 -and $_.backendReceived) }).Count -eq 0
            $compactAttempts = @($attempts | ForEach-Object { ,@($_.attempt, $_.http, $_.backendReceived, $_.consumed, $_.shape, $_.transportFailure) })
            [pscustomobject]@{ test = 'synthetic-token-metering'; fixture = $fixture; passed = [bool]$passed; columns = @('attempt', 'http', 'backendReceived', 'consumed', 'shape', 'transportFailure'); attempts = $compactAttempts; modelCalled = $false } | ConvertTo-Json -Depth 5 -Compress
            if (@($attempts | Where-Object http -eq 0).Count) { throw 'Metering transport failed; no network changes attempted.' }
        }
    } finally {
        try {
            if ($listener) { $listener.Stop(); $listener.Close() }
            if ($worker -and $task) { $null = $worker.EndInvoke($task) }
        } finally {
            if ($worker) { $worker.Dispose() }
            [Net.ServicePointManager]::CheckCertificateRevocationList = $previousRevocationCheck
            if ($ruleAttempted -and (Get-NetFirewallRule -Name $ProbeId -ErrorAction SilentlyContinue)) { Remove-NetFirewallRule -Name $ProbeId }
            $clean = -not (Get-NetFirewallRule -Name $ProbeId -ErrorAction SilentlyContinue) -and -not (Get-NetTCPConnection -LocalPort 18741 -State Listen -ErrorAction SilentlyContinue)
            [pscustomobject]@{ test = 'metering-mock-cleanup'; passed = [bool]$clean } | ConvertTo-Json -Compress
        }
    }
    return
}

if ($Phase -eq 'ParameterTest') {
    $cases = @(
        @{ name = 'schema-single-valid'; headers = @('Authorization: Bearer probe-valid'); expected = 200 },
        @{ name = 'schema-single-invalid'; headers = @('Authorization: Bearer probe-invalid'); expected = 400; source = 'validate-parameters' },
        @{ name = 'schema-missing'; headers = @(); expected = 400; source = 'validate-parameters' },
        @{ name = 'schema-duplicate-identical'; headers = @('Authorization: Bearer probe-valid', 'Authorization: Bearer probe-valid'); expected = 200 },
        @{ name = 'schema-duplicate-case'; headers = @('Authorization: Bearer probe-valid', 'authorization: Bearer probe-valid'); expected = 200 },
        @{ name = 'schema-different-valid-first'; headers = @('Authorization: Bearer probe-valid', 'Authorization: Bearer probe-invalid'); expected = 400 },
        @{ name = 'schema-different-valid-last'; headers = @('Authorization: Bearer probe-invalid', 'Authorization: Bearer probe-valid'); expected = 400 },
        @{ name = 'schema-single-valid-after'; headers = @('Authorization: Bearer probe-valid'); expected = 200 }
    )
    foreach ($case in $cases) {
        $response = Invoke-ProbeWireRequest $GatewayUri $case.headers
        $passed = $response.StatusCode -eq $case.expected
        if ($case.expected -eq 200) { $passed = $passed -and $response.Headers['X-Schema-Probe'] -eq 'validated' -and $response.Headers['X-Schema-Authorization-Count'] -eq '1' }
        if ($case.source) { $passed = $passed -and $response.Headers['X-Schema-Source'] -eq $case.source }
        [pscustomobject]@{ test = $case.name; http = $response.StatusCode; authorizationValues = [string]$response.Headers['X-Schema-Authorization-Count']; source = [string]$response.Headers['X-Schema-Source']; passed = $passed } | ConvertTo-Json -Compress
        if ($case.name -in @('schema-single-valid', 'schema-single-invalid', 'schema-missing') -and -not $passed) { return }
    }
    return
}

if ($Phase -eq 'AssociationTest') {
    $certificates = @(Get-ChildItem Cert:\LocalMachine\My | Where-Object Subject -eq "CN=$ProbeId")
    if ($certificates.Count -ne 1) { throw 'Expected one temporary probe certificate.' }
    try {
        $ciphertext = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ProtectedToken))
        $association = (Unprotect-CmsMessage -To $certificates[0] -Content $ciphertext) | ConvertFrom-Json
        foreach ($surface in @('inherited', 'explicit')) {
            $cases = @(
                @{ name = 'product-key'; headers = @{ 'api-key' = $association.keys.active }; expected = $(if ($association.nativeLinked) { 200 } else { 401 }); context = $(if ($surface -eq 'inherited') { '1110' } else { '1100' }) },
                @{ name = 'api-key'; headers = @{ 'api-key' = $association.keys.apiRequired }; expected = 200; context = '1000' },
                @{ name = 'all-apis'; headers = @{ 'api-key' = $association.keys.allApis }; expected = 200; context = '1000' },
                @{ name = 'jwt'; headers = @{ Authorization = 'Bearer ' + $association.userToken }; expected = $(if ($association.openLinked) { 200 } else { 401 }); context = '0101' },
                @{ name = 'missing'; headers = @{}; expected = 401 }
            )
            foreach ($case in $cases) {
                $consecutive = 0
                $attempt = 0
                $deadline = [DateTime]::UtcNow.AddMinutes(2)
                do {
                    $attempt++
                    $status = 0
                    $contextFlags = ''
                    try {
                        $response = Invoke-WebRequest -UseBasicParsing -Uri $association.urls.$surface -Headers $case.headers -TimeoutSec 15
                        $status = [int]$response.StatusCode
                        $contextFlags = [string]$response.Headers['X-Probe-Context']
                    } catch { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } }
                    $passed = $status -eq $case.expected -and ($case.expected -ne 200 -or $contextFlags -eq $case.context)
                    $consecutive = if ($passed) { $consecutive + 1 } else { 0 }
                } until ($consecutive -eq 3 -or $attempt -ge 30 -or [DateTime]::UtcNow -ge $deadline)
                [pscustomobject]@{ test = 'association-' + $association.stage + '-' + $surface + '-' + $case.name; http = $status; attempts = $attempt; passed = ($consecutive -eq 3) } | ConvertTo-Json -Compress
            }
        }
    } finally {
        $association = $null
        Remove-Item -LiteralPath $certificates[0].PSPath -DeleteKey -Force
        [pscustomobject]@{ test = 'temporary-transport-certificate-removed'; passed = $true } | ConvertTo-Json -Compress
    }
    return
}

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

function Get-ProbePipelineCases {
    param($Pipeline, [string] $FirstToken, [string] $SecondToken, [string] $ExpiredToken, [string] $TamperedToken)
    $normal = @{ model = 'gpt-4o-mini'; messages = @(@{ role = 'user'; content = 'ping' }); max_tokens = 1 }
    $reasoning = @{ model = 'gpt-5'; messages = @(@{ role = 'user'; content = 'ping' }); max_tokens = 1; temperature = 0.1; snippy = $true }
    $chatStream = $reasoning.Clone()
    $chatStream.stream = $true
    $responses = @{ model = 'gpt-4o-mini'; input = 'ping'; max_output_tokens = 1 }
    $responsesStream = $responses.Clone()
    $responsesStream.stream = $true
    $auto = $normal.Clone()
    $auto.model = 'auto'
    $cases = @(
        @{ name = 'normal-first'; token = $FirstToken; body = $normal; expected = 200 },
        @{ name = 'normal-second'; token = $SecondToken; body = $normal; expected = 200 },
        @{ name = 'reasoning'; token = $FirstToken; body = $reasoning; expected = 200; reasoning = $true },
        @{ name = 'chat-stream'; token = $FirstToken; body = $chatStream; expected = 200; reasoning = $true; stream = $true },
        @{ name = 'responses'; token = $FirstToken; body = $responses; expected = 200; responses = $true },
        @{ name = 'responses-stream'; token = $SecondToken; body = $responsesStream; expected = 200; responses = $true; stream = $true },
        @{ name = 'auto-short'; token = $FirstToken; body = $auto; expected = 200; auto = $true },
        @{ name = 'missing'; body = $normal; expected = 401 },
        @{ name = 'expired'; token = $ExpiredToken; body = $normal; expected = 401 },
        @{ name = 'tampered'; token = $TamperedToken; body = $normal; expected = 401 },
        @{ name = 'missing-model'; token = $FirstToken; body = @{ messages = @(@{ role = 'user'; content = 'ping' }) }; expected = 400 }
    )
    foreach ($case in $cases) { $case.uri = if ($case.responses) { $Pipeline.baseline.responses } else { $Pipeline.baseline.primary } }
    foreach ($mode in @('rpm', 'quota', 'tpm')) {
        $maximum = if ($mode -eq 'tpm') { 2 } elseif ($mode -eq 'rpm') { 5 } else { 4 }
        foreach ($principal in @('first', 'second')) {
            $token = if ($principal -eq 'first') { $FirstToken } else { $SecondToken }
            foreach ($attempt in 1..$maximum) {
                $denied = $attempt -eq $maximum
                $deferredBoundary = $mode -eq 'rpm' -and $attempt -eq 4
                $cases += @{ name = "$mode-$principal-$attempt"; token = $token; body = $normal; uri = $(if ($denied -or $deferredBoundary) { $Pipeline.$mode.alias } else { $Pipeline.$mode.primary }); expected = $(if (-not $denied) { 200 } elseif ($mode -eq 'quota') { 403 } else { 429 }); deferredBoundary = $deferredBoundary }
            }
        }
    }
    return $cases
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
        $probeStage = 'decrypt'
        $ciphertext = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ProtectedToken))
        $userToken = Unprotect-CmsMessage -To $certificates[0] -Content $ciphertext
        if ($AdmissionPayload -eq 'true') {
            $admission = $userToken | ConvertFrom-Json
            $userToken = $admission.userToken
        }
        if ($admission.http2Gate) {
            $probeStage = 'http2-client'
            $clientDirectory = Join-Path ([IO.Path]::GetTempPath()) ('jwt-probe-http2-' + [guid]::NewGuid().ToString('N'))
            $clientPath = Initialize-ProbeHttp2Client $clientDirectory
        }
        if ($admission.backendGate) {
            $probeStage = 'mock-start'
            if (Get-NetFirewallRule -Name $ProbeId -ErrorAction SilentlyContinue) { throw 'Mock firewall rule already exists.' }
            if (-not (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq $admission.backend.address)) { throw 'Mock address does not belong to this VM.' }
            if (Get-NetTCPConnection -LocalPort 18741 -State Listen -ErrorAction SilentlyContinue) { throw 'Mock port is already in use.' }
            $receipts = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
            $expectedReceipts = @{}
            $listener = [Net.HttpListener]::new()
            $listener.Prefixes.Add("http://+:18741/$ProbeId/")
            $listener.Start()
            $null = New-NetFirewallRule -Name $ProbeId -DisplayName $ProbeId -Direction Inbound -Action Allow -Protocol TCP -LocalPort 18741 -LocalAddress $admission.backend.address -RemoteAddress $admission.backend.sourcePrefix -Profile Any
            $mockRuleCreated = $true
            $mockWorker = [PowerShell]::Create()
            $null = $mockWorker.AddScript({
                param($Listener, $Receipts, $Nonce)
                while ($Listener.IsListening) {
                    try { $requestContext = $Listener.GetContext() } catch { break }
                    try {
                        $request = $requestContext.Request
                        $caseId = $request.Headers['X-Probe-Case']
                        $validNonce = $request.Headers['X-Probe-Backend-Nonce'] -ceq $Nonce
                        $stripped = $true
                        foreach ($name in @('api-key', 'x-api-key', 'Authorization', 'Ocp-Apim-Subscription-Key')) {
                            if ($request.Headers.AllKeys -contains $name) { $stripped = $false }
                        }
                        foreach ($name in @('api-key', 'subscription-key')) {
                            if ($request.QueryString.AllKeys -contains $name) { $stripped = $false }
                        }
                        $pipelineMode = $request.Headers['X-Probe-Pipeline-Mode']
                        $pipelineBody = $null
                        $pipelineReceipt = $null
                        if ($pipelineMode -in @('baseline', 'rpm', 'tpm', 'quota')) {
                            if ($request.ContentLength64 -gt 16384) { throw 'Pipeline request exceeded the fixture bound.' }
                            $bodyReader = New-Object IO.StreamReader($request.InputStream, [Text.Encoding]::UTF8)
                            try { $pipelineBody = $bodyReader.ReadToEnd() | ConvertFrom-Json } finally { $bodyReader.Dispose() }
                            $isResponses = $request.Url.AbsolutePath.EndsWith('/openai/v1/responses')
                            $reasoningNormalized = $pipelineBody.model -eq 'gpt-5' -and $null -eq $pipelineBody.temperature -and $null -eq $pipelineBody.max_tokens -and $pipelineBody.max_completion_tokens -eq 1
                            $pipelineReceipt = @{
                                reasoningNormalized = $reasoningNormalized
                                snippyRemoved = $null -eq $pipelineBody.snippy
                                resolvedModel = $pipelineBody.model -eq 'gpt-4o-mini'
                                correctPath = $isResponses -or $request.Url.AbsolutePath.EndsWith('/openai/deployments/' + $pipelineBody.model + '/chat/completions')
                                correctVersion = $(if ($isResponses) { -not $request.QueryString['api-version'] } else { $request.QueryString['api-version'] -eq '2024-10-21' })
                                usageOption = $(if ($isResponses) { $null -eq $pipelineBody.stream_options } elseif ($pipelineBody.stream) { $pipelineBody.stream_options.include_usage -eq $true } else { $true })
                            }
                        }
                        if ($caseId -notmatch '^[a-f0-9]{32}$') { $caseId = 'untagged' }
                        if ($Receipts.ContainsKey($caseId)) {
                            $Receipts[$caseId] = @{ count = $Receipts[$caseId].count + 1; stripped = $false }
                        } else {
                            $Receipts[$caseId] = @{ count = 1; stripped = ($stripped -and $validNonce); pipeline = $pipelineReceipt }
                        }
                        $requestContext.Response.StatusCode = if ($validNonce) { 200 } else { 403 }
                        $requestContext.Response.Headers['X-Probe-Backend'] = 'received'
                        $requestContext.Response.Headers['X-Probe-Backend-Stripped'] = $stripped.ToString()
                        $requestContext.Response.ContentType = 'application/json'
                        $body = [Text.Encoding]::UTF8.GetBytes('{"id":"probe","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"probe"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}')
                        if ($pipelineBody) {
                            $usage = if ($pipelineMode -eq 'tpm') { @{ prompt_tokens = 20; completion_tokens = 80; total_tokens = 100 } } else { @{ prompt_tokens = 1; completion_tokens = 1; total_tokens = 2 } }
                            if ($isResponses) {
                                $payload = @{ id = 'resp_probe'; object = 'response'; status = 'completed'; output = @(@{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'probe' }) }); usage = @{ input_tokens = $usage.prompt_tokens; output_tokens = $usage.completion_tokens; total_tokens = $usage.total_tokens } }
                            } else {
                                $payload = @{ id = 'probe'; object = 'chat.completion'; model = $pipelineBody.model; choices = @(@{ index = 0; message = @{ role = 'assistant'; content = 'probe' }; finish_reason = 'stop' }); usage = $usage }
                            }
                            if ($pipelineBody.stream) {
                                $requestContext.Response.ContentType = 'text/event-stream'
                                if ($isResponses) {
                                    $eventJson = @{ type = 'response.completed'; response = $payload } | ConvertTo-Json -Depth 8 -Compress
                                    $text = "event: response.output_text.delta`ndata: {`"type`":`"response.output_text.delta`",`"delta`":`"probe`"}`n`nevent: response.completed`ndata: $eventJson`n`n"
                                } else {
                                    $usageJson = @{ id = 'probe'; object = 'chat.completion.chunk'; model = $pipelineBody.model; choices = @(); usage = $usage } | ConvertTo-Json -Depth 6 -Compress
                                    $text = "data: {`"id`":`"probe`",`"object`":`"chat.completion.chunk`",`"choices`":[{`"index`":0,`"delta`":{`"content`":`"probe`"},`"finish_reason`":null}]}`n`ndata: $usageJson`n`ndata: [DONE]`n`n"
                                }
                            } else { $text = $payload | ConvertTo-Json -Depth 8 -Compress }
                            $body = [Text.Encoding]::UTF8.GetBytes($text)
                        }
                        $requestContext.Response.ContentLength64 = $body.Length
                        $requestContext.Response.OutputStream.Write($body, 0, $body.Length)
                    } finally { $requestContext.Response.Close() }
                }
            }).AddArgument($listener).AddArgument($receipts).AddArgument($admission.backend.nonce)
            $mockTask = $mockWorker.BeginInvoke()
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
            [pscustomobject]@{ test = 'admission-acceptance-contract'; contract = 'single-credential-v1'; passed = $true } | ConvertTo-Json -Compress
            $observations = @()
            $wireObservations = @()
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
                            @{ name = 'wire-duplicate-key'; wire = @(('api-key: ' + $admission.keys.active), ('api-key: ' + $admission.keys.active)); expected = 401 },
                            @{ name = 'wire-duplicate-bearer'; wire = @(('Authorization: Bearer ' + $userToken), ('Authorization: Bearer ' + $userToken)); expected = 200; context = '0101' },
                            @{ name = 'wire-duplicate-bearer-case'; wire = @(('Authorization: Bearer ' + $userToken), ('authorization: Bearer ' + $userToken)); expected = 200; context = '0101' },
                            @{ name = 'wire-duplicate-expired'; wire = @(('Authorization: Bearer ' + $expiredToken), ('Authorization: Bearer ' + $expiredToken)); expected = 401 },
                            @{ name = 'wire-duplicate-tampered'; wire = @(('Authorization: Bearer ' + $badSignatureToken), ('Authorization: Bearer ' + $badSignatureToken)); expected = 401 },
                            @{ name = 'wire-mixed-case-key'; wire = @(('api-key: ' + $admission.keys.active), 'Api-Key: invalid-probe-key'); expected = 401 },
                            @{ name = 'token-shaped-key'; headers = @{ 'api-key' = 'header.payload.signature' }; expected = 401 },
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
                    if ($admission.backendGate) {
                        $cases += @{ name = 'wire-bearer-valid-first'; wire = @(('Authorization: Bearer ' + $userToken), 'Authorization: Bearer not-a-jwt'); expected = 400 }
                        $cases += @{ name = 'wire-bearer-valid-last'; wire = @('Authorization: Bearer not-a-jwt', ('Authorization: Bearer ' + $userToken)); expected = 400 }
                        $cases += @{ name = 'quota-conflict'; headers = @{ 'api-key' = $admission.keys.quota; Authorization = 'Bearer ' + $userToken }; expected = 401 }
                        foreach ($attempt in 1..4) {
                            $cases += @{ name = "quota-$attempt"; headers = @{ 'api-key' = $admission.keys.quota }; expected = $(if ($surface -eq 'inherited' -and $attempt -eq 4) { 403 } else { 200 }); context = $productContext }
                        }
                        $cases += @{ name = 'quota-isolated'; headers = @{ 'api-key' = $admission.keys.'other-quota' }; expected = 200; context = $productContext }
                    }
                    if ($admission.secondUserToken) {
                        if ($admission.secondUserToken -ceq $userToken) { throw 'Two-user conflict coverage requires distinct credentials.' }
                        $cases += @{ name = 'wire-single-key'; wire = @('api-key: ' + $admission.keys.active); expected = 200; context = $productContext }
                        $cases += @{ name = 'wire-single-bearer'; wire = @('Authorization: Bearer ' + $userToken); expected = 200; context = '0101' }
                        $cases += @{ name = 'wire-single-second-bearer'; wire = @('Authorization: Bearer ' + $admission.secondUserToken); expected = 200; context = '0101' }
                        $cases += @{ name = 'wire-two-users-first'; wire = @(('Authorization: Bearer ' + $userToken), ('Authorization: Bearer ' + $admission.secondUserToken)); expected = 400 }
                        $cases += @{ name = 'wire-two-users-last'; wire = @(('Authorization: Bearer ' + $admission.secondUserToken), ('Authorization: Bearer ' + $userToken)); expected = 400 }
                        foreach ($limiter in @('rate', 'quota')) {
                            $primaryUri = $admission.urls."$surface-isolation-$limiter-primary"
                            $aliasUri = $admission.urls."$surface-isolation-$limiter-alias"
                            $deniedStatus = if ($limiter -eq 'rate') { 429 } else { 403 }
                            $cases += @{ name = "isolation-$limiter-conflict"; headers = @{ 'api-key' = $admission.keys.active; Authorization = 'Bearer ' + $userToken }; uri = $primaryUri; expected = 401 }
                            foreach ($principal in @('first', 'second')) {
                                $principalToken = if ($principal -eq 'first') { $userToken } else { $admission.secondUserToken }
                                foreach ($attempt in 1..4) {
                                    $cases += @{ name = "isolation-$limiter-$principal-$attempt"; headers = @{ Authorization = 'Bearer ' + $principalToken }; uri = $(if ($attempt -eq 4) { $aliasUri } else { $primaryUri }); expected = $(if ($attempt -eq 4) { $deniedStatus } else { 200 }); context = '0101' }
                                }
                            }
                            $cases += @{ name = "isolation-$limiter-first-still-blocked"; headers = @{ Authorization = 'Bearer ' + $userToken }; uri = $aliasUri; expected = $deniedStatus }
                        }
                    }
                    if ($admission.http2Gate) {
                        $http2Cases = @($cases | Where-Object { $_.wire -and $_.name -notlike 'wire-single-*' } | ForEach-Object { $copy = $_.Clone(); $copy.name = 'h2-' + $_.name; $copy.http2 = $true; $copy })
                        $http2Cases += @(
                            @{ name = 'h2-key'; wire = @('api-key: ' + $admission.keys.active); expected = 200; context = $productContext; http2 = $true },
                            @{ name = 'h2-jwt'; wire = @('Authorization: Bearer ' + $userToken); expected = 200; context = '0101'; http2 = $true },
                            @{ name = 'h2-missing'; wire = @(); expected = 401; http2 = $true },
                            @{ name = 'h2-conflict'; wire = @(('api-key: ' + $admission.keys.active), ('Authorization: Bearer ' + $userToken)); expected = 401; http2 = $true },
                            @{ name = 'h2-combined-bearer'; wire = @('Authorization: Bearer ' + $userToken + ',Bearer ' + $userToken); expected = 401; http2 = $true }
                        )
                        $cases += $http2Cases
                    }
                    foreach ($case in $cases) {
                        $probeStage = 'matrix-' + $case.name
                        $status = 0
                        $responseHeaders = @{}
                        $caseId = [guid]::NewGuid().ToString('N')
                        if ($admission.backendGate) {
                            $expectedReceipts[$caseId] = ($case.expected -eq 200)
                            if ($case.headers -and $case.headers.ContainsKey('api-key') -and $admission.credentialHeader -eq 'x-api-key') {
                                $case.headers['x-api-key'] = $case.headers['api-key']
                                $case.headers.Remove('api-key')
                            }
                            if ($case.wire -or $case.http2) {
                                if ($admission.credentialHeader -eq 'x-api-key') { $case.wire = @($case.wire | ForEach-Object { $_ -replace '^api-key:', 'x-api-key:' -replace '^Api-Key:', 'X-Api-Key:' }) }
                                $case.wire += 'X-Probe-Case: ' + $caseId
                            } else { $case.headers['X-Probe-Case'] = $caseId }
                        }
                        try {
                            $requestUri = [UriBuilder]::new($(if ($case.uri) { $case.uri } else { $admission.urls.$surface }))
                            if ($case.query) { $requestUri.Query = $case.query }
                            $response = if ($case.http2) {
                                Invoke-ProbeHttp2Request -ClientPath $clientPath -RequestUri $requestUri.Uri -HeaderLines $case.wire
                            } elseif ($case.wire) {
                                Invoke-ProbeWireRequest -RequestUri $requestUri.Uri -HeaderLines $case.wire
                            } else {
                                Invoke-WebRequest -UseBasicParsing -Uri $requestUri.Uri -Headers $case.headers -TimeoutSec 45
                            }
                            $status = [int]$response.StatusCode
                            $responseHeaders = $response.Headers
                        } catch {
                            if ($_.Exception.Response) {
                                $status = [int]$_.Exception.Response.StatusCode
                                $responseHeaders = $_.Exception.Response.Headers
                            }
                        }
                        $contextFlags = [string]$responseHeaders['X-Probe-Context']
                        $receipt = $null
                        $received = $false
                        if ($admission.backendGate) {
                            $received = $receipts.TryGetValue($caseId, [ref]$receipt)
                        }
                        $verdict = Get-ProbeAdmissionResult -Case $case -Status $status -ResponseHeaders $responseHeaders -Expanded ([bool]$admission.expanded) -BackendGate ([bool]$admission.backendGate) -Receipt $receipt
                        $passed = $verdict.passed
                        if ($admission.backendGate) { $expectedReceipts[$caseId] = $verdict.expectedReceipt }
                        $errorCode = [string]$responseHeaders['X-Probe-Error']
                        if ($errorCode -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$') { $errorCode = '' }
                        $authorizationCount = [string]$responseHeaders['X-Probe-Authorization-Count']
                        if ($authorizationCount -notmatch '^[0-9]{1,4}$') { $authorizationCount = '' }
                        $observations += [pscustomobject]@{ case = "$($surface.Substring(0,1))-$($case.name)"; http = $status; ctx = $contextFlags; passed = $passed; detail = $(if (-not $passed) { @{ error = $errorCode; received = [bool]$received; sourceGuard = ($responseHeaders['X-Probe-Rejected-By'] -eq 'credential-source-guard'); authorizationValues = $authorizationCount; combined = ($responseHeaders['X-Probe-Authorization-Combined'] -eq 'True') } } else { $null }) }
                        if ($case.wire -and -not $case.http2 -and $case.name -notlike 'wire-single-*' -and $admission.backendGate) { $wireObservations += @{ case = "$($surface.Substring(0,1))-$($case.name)"; http = $status; authorizationValues = [string]$responseHeaders['X-Probe-Authorization-Count']; backendReceived = $received } }
                    }
                }
            }
            if ($admission.backendGate) {
                foreach ($surface in $admission.surfaces) {
                    $cases = @(
                        @{ name = 'key'; headers = @{ ($admission.credentialHeader) = $admission.keys.active }; expected = 200 },
                        @{ name = 'api-scoped'; headers = @{ ($admission.credentialHeader) = $admission.keys.apiRequired }; expected = 200 },
                        @{ name = 'all-apis'; headers = @{ ($admission.credentialHeader) = $admission.keys.allApis }; expected = 200 },
                        @{ name = 'jwt'; headers = @{ Authorization = 'Bearer ' + $userToken }; expected = 200 },
                        @{ name = 'missing'; headers = @{}; expected = 401 },
                        @{ name = 'invalid'; headers = @{ ($admission.credentialHeader) = 'header.payload.signature' }; expected = 401 },
                        @{ name = 'wrong-scope'; headers = @{ ($admission.credentialHeader) = $admission.keys.wrongScope }; expected = 401 },
                        @{ name = 'conflict'; headers = @{ ($admission.credentialHeader) = $admission.keys.active; Authorization = 'Bearer ' + $userToken }; expected = 401 }
                    )
                    foreach ($case in $cases) {
                        $probeStage = 'surface-' + $surface.name + '-' + $case.name
                        $caseId = [guid]::NewGuid().ToString('N')
                        $expectedReceipts[$caseId] = ($case.expected -eq 200)
                        $case.headers['X-Probe-Case'] = $caseId
                        $status = 0
                        $headers = @{}
                        try {
                            $request = @{ UseBasicParsing = $true; Uri = $surface.uri; Method = $surface.method; Headers = $case.headers; TimeoutSec = 45 }
                            if ($surface.method -eq 'POST') { $request.Body = '{"model":"probe-fixture","messages":[{"role":"user","content":"probe"}],"max_tokens":1}'; $request.ContentType = 'application/json' }
                            $response = Invoke-WebRequest @request
                            $status = [int]$response.StatusCode
                            $headers = $response.Headers
                        } catch {
                            if ($_.Exception.Response) {
                                $status = [int]$_.Exception.Response.StatusCode
                                $headers = $_.Exception.Response.Headers
                            }
                        }
                        $receipt = $null
                        $received = $receipts.TryGetValue($caseId, [ref]$receipt)
                        $passed = $status -eq $case.expected -and ($received -eq ($case.expected -eq 200))
                        if ($received) { $passed = $passed -and $receipt.count -eq 1 -and $receipt.stripped -and $headers['X-Probe-Backend'] -eq 'received' }
                        $errorCode = [string]$headers['X-Probe-Error']
                        if ($errorCode -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$') { $errorCode = '' }
                        $observations += [pscustomobject]@{ case = "surface-$($surface.name)-$($case.name)"; http = $status; ctx = [string]$headers['X-Probe-Context']; passed = $passed; detail = $(if (-not $passed) { @{ error = $errorCode; received = $received } } else { $null }) }
                    }
                }
                if ($admission.pipeline) {
                    $pipelineCases = @(Get-ProbePipelineCases $admission.pipeline $userToken $admission.secondUserToken $expiredToken $badSignatureToken)
                    $pipelineResults = @()
                    $pipelineCaseIds = @()
                    foreach ($case in $pipelineCases) {
                        $caseId = [guid]::NewGuid().ToString('N')
                        $pipelineCaseIds += $caseId
                        $expectedReceipts[$caseId] = $case.expected -eq 200
                        $headers = @{ 'X-Probe-Case' = $caseId }
                        if ($case.token) { $headers['api-key'] = $case.token }
                        $status = 0
                        $responseHeaders = @{}
                        $content = ''
                        $transportFailure = ''
                        $elapsed = [Diagnostics.Stopwatch]::StartNew()
                        try {
                            $response = Invoke-WebRequest -UseBasicParsing -Uri $case.uri -Method Post -Headers $headers -ContentType 'application/json' -Body ($case.body | ConvertTo-Json -Depth 8 -Compress) -TimeoutSec 45
                            $status = [int]$response.StatusCode
                            $responseHeaders = $response.Headers
                            $content = [string]$response.Content
                        } catch {
                            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode; $responseHeaders = $_.Exception.Response.Headers }
                            else { $transportFailure = if ($_.Exception -is [Net.WebException]) { $_.Exception.Status.ToString() } else { $_.Exception.GetBaseException().GetType().Name } }
                        }
                        $elapsed.Stop()
                        $receipt = $null
                        $received = $receipts.TryGetValue($caseId, [ref]$receipt)
                        $boundaryDenied = $case.deferredBoundary -and $status -eq 429
                        $expectedReceipts[$caseId] = $case.expected -eq 200 -and -not $boundaryDenied
                        $passed = ($status -eq $case.expected -or $boundaryDenied) -and $received -eq $expectedReceipts[$caseId]
                        if ($received) {
                            $passed = $passed -and $receipt.count -eq 1 -and $receipt.stripped -and $receipt.pipeline.correctPath -and $receipt.pipeline.correctVersion -and $receipt.pipeline.snippyRemoved -and $receipt.pipeline.usageOption
                            if ($case.reasoning) { $passed = $passed -and $receipt.pipeline.reasoningNormalized }
                            if ($case.auto) { $passed = $passed -and $receipt.pipeline.resolvedModel }
                            if ($case.stream) {
                                $passed = $passed -and $responseHeaders['Content-Type'] -match '^text/event-stream' -and $content.Contains('probe') -and $content.Contains('usage')
                                $passed = $passed -and $(if ($case.responses) { $content.Contains('response.completed') } else { $content.Contains('[DONE]') })
                            } else { $passed = $passed -and $content.Contains('usage') -and $content.Contains('probe') }
                        }
                        $errorCode = [string]$responseHeaders['X-Probe-Error']
                        if ($errorCode -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$') { $errorCode = '' }
                        $row = [pscustomobject]@{ case = 'pipeline-' + $case.name; http = $status; ctx = ''; passed = [bool]$passed; detail = $(if (-not $passed) { @{ error = $errorCode; received = $received; shape = $receipt.pipeline; transport = $transportFailure; elapsedMs = $elapsed.ElapsedMilliseconds } } else { $null }) }
                        $observations += $row
                        $pipelineResults += $row
                    }
                    [pscustomobject]@{ test = 'production-pipeline-summary'; cases = $pipelineResults.Count; passed = (@($pipelineResults | Where-Object { -not $_.passed }).Count -eq 0); telemetryVerified = $false } | ConvertTo-Json -Compress
                }
                $listener.Stop()
                $mockWorker.EndInvoke($mockTask) | Out-Null
                $receiptAuditPassed = -not $receipts.ContainsKey('untagged')
                foreach ($caseId in $expectedReceipts.Keys) {
                    $receipt = $null
                    $received = $receipts.TryGetValue($caseId, [ref]$receipt)
                    if ($received -ne $expectedReceipts[$caseId]) { $receiptAuditPassed = $false }
                    if ($received -and ($receipt.count -ne 1 -or -not $receipt.stripped)) { $receiptAuditPassed = $false }
                }
                if (@($receipts.Keys | Where-Object { -not $expectedReceipts.ContainsKey($_) }).Count) { $receiptAuditPassed = $false }
                [pscustomobject]@{ test = 'final-backend-receipt-audit'; cases = $expectedReceipts.Count; passed = $receiptAuditPassed } | ConvertTo-Json -Compress
                if ($admission.pipeline) {
                    $pipelineAuditPassed = $pipelineCaseIds.Count -eq $pipelineCases.Count -and -not $receipts.ContainsKey('untagged')
                    foreach ($pipelineCaseId in $pipelineCaseIds) {
                        $receipt = $null
                        $received = $receipts.TryGetValue($pipelineCaseId, [ref]$receipt)
                        if ($received -ne $expectedReceipts[$pipelineCaseId] -or ($received -and ($receipt.count -ne 1 -or -not $receipt.stripped))) { $pipelineAuditPassed = $false }
                    }
                    [pscustomobject]@{ test = 'production-pipeline-receipt-audit'; cases = $pipelineCaseIds.Count; passed = $pipelineAuditPassed } | ConvertTo-Json -Compress
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
            $compactRows = @($observations | ForEach-Object {
                $compact = @($_.case, $_.http, $_.ctx, $_.passed)
                if ($_.detail) { $compact += $_.detail }
                ,$compact
            })
            if ($admission.backendGate -and -not $admission.pipeline -and -not $admission.http2Gate) { [pscustomobject]@{ test = 'wire-header-observations'; results = $wireObservations } | ConvertTo-Json -Depth 5 -Compress }
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
        [pscustomobject]@{ test = 'encrypted-user-token-probe'; passed = $false; stage = $probeStage; reason = 'Encrypted token test failed; details suppressed' } | ConvertTo-Json -Compress
    } finally {
        if ($clientDirectory) {
            try {
                if (Test-Path -LiteralPath $clientDirectory) { Remove-Item -LiteralPath $clientDirectory -Recurse -Force }
                [pscustomobject]@{ test = 'temporary-http2-client-removed'; passed = (-not (Test-Path -LiteralPath $clientDirectory)) } | ConvertTo-Json -Compress
            } catch {
                [pscustomobject]@{ test = 'temporary-http2-client-removed'; passed = $false } | ConvertTo-Json -Compress
            }
        }
        if ($listener) { $listener.Stop(); $listener.Close() }
        if ($mockWorker) { $mockWorker.Dispose() }
        if ($mockRuleCreated) {
            Remove-NetFirewallRule -Name $ProbeId
            [pscustomobject]@{ test = 'mock-listener-and-firewall-removed'; passed = (-not [bool](Get-NetFirewallRule -Name $ProbeId -ErrorAction SilentlyContinue) -and -not [bool](Get-NetTCPConnection -LocalPort 18741 -State Listen -ErrorAction SilentlyContinue)) } | ConvertTo-Json -Compress
        }
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