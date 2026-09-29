#requires -Version 7.4
[CmdletBinding(DefaultParameterSetName = 'Live')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Live')][ValidateSet('comm-dev','gov-dev','comm-pilot','gov-pilot')][string]$EnvironmentName,
    [Parameter(Mandatory, ParameterSetName = 'Live')][guid]$SubscriptionId,
    [Parameter(Mandatory, ParameterSetName = 'Live')][ValidateSet('AzureCloud','AzureUSGovernment')][string]$Cloud,
    [Parameter(ParameterSetName = 'Live')][switch]$IncludeCallerTransition,
    [Parameter(Mandatory, ParameterSetName = 'Definitions')][switch]$DefinitionsOnly
)

$ErrorActionPreference = 'Stop'

function Assert-PrivateClientLifecycleState {
    param([int]$StatusCode, $Group, [string]$ExpectedGroupId, [bool]$IncludeCallerTransition = $false)
    if ($StatusCode -eq 404 -and $Group.error.code -ceq 'ResourceGroupNotFound') { return }
    if ($StatusCode -ne 200 -or $Group -isnot [Collections.IDictionary] -or
        $Group.id -ine $ExpectedGroupId -or $Group.properties.provisioningState -cne 'Succeeded' -or
        ($null -ne $Group.tags -and $Group.tags -isnot [Collections.IDictionary])) {
        throw 'Private client-access lifecycle state cannot be verified.'
    }
    if (@($Group.tags.Keys | Where-Object {$_ -ieq 'byokPrivateClientAccess'}).Count) {
        throw 'Private client access requires cleanup before mutation.'
    }
    if ($IncludeCallerTransition -and @($Group.tags.Keys | Where-Object {$_ -ieq 'byokCallerTransition'}).Count) {
        throw 'Caller transition requires reconciliation before mutation.'
    }
}

function Invoke-PrivateClientLifecycleAzureRead {
    param([string[]]$Arguments)
    $launcher = Get-Command az -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $executable = $launcher.Source
    if ($IsWindows -and [IO.Path]::GetExtension($executable) -in @('.cmd','.bat')) {
        $executable = Join-Path (Split-Path (Split-Path $executable)) 'python.exe'
        $Arguments = @('-m','azure.cli') + $Arguments
    }
    $start = [Diagnostics.ProcessStartInfo]::new($executable)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $start.Environment['PYTHONIOENCODING'] = 'utf-8'
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = $stdout.GetAwaiter().GetResult()
        $null = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'Private client-access lifecycle state cannot be verified.' }
        $output | ConvertFrom-Json -AsHashtable -Depth 30
    } finally { $process.Dispose();$output = $null }
}

if ($DefinitionsOnly) { return }

$client = $null
$token = $null
try {
    $expectedCloud = if ($EnvironmentName.StartsWith('gov-', [StringComparison]::Ordinal)) { 'AzureUSGovernment' } else { 'AzureCloud' }
    if ($Cloud -cne $expectedCloud -or $SubscriptionId -eq [guid]::Empty) { throw 'Private client-access lifecycle state cannot be verified.' }
    $account = Invoke-PrivateClientLifecycleAzureRead @('account','show','--subscription',$SubscriptionId.ToString(),'--output','json')
    if ($account.id -ine $SubscriptionId.ToString() -or $account.environmentName -cne $Cloud) { throw 'Private client-access lifecycle state cannot be verified.' }
    $groupId = '/subscriptions/' + $SubscriptionId.ToString() + '/resourceGroups/rg-copilot-byok-' + $EnvironmentName
    $arm = if ($Cloud -ceq 'AzureUSGovernment') { 'https://management.usgovcloudapi.net' } else { 'https://management.azure.com' }
    $token = Invoke-PrivateClientLifecycleAzureRead @('account','get-access-token','--subscription',$SubscriptionId.ToString(),'--resource-type','arm','--output','json')
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token.accessToken)
    $client.DefaultRequestHeaders.Accept.ParseAdd('application/json')
    $token = $null
    $response = $client.GetAsync($arm + $groupId + '?api-version=2022-09-01').GetAwaiter().GetResult()
    try {
        $group = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable -Depth 30
        Assert-PrivateClientLifecycleState ([int]$response.StatusCode) $group $groupId -IncludeCallerTransition:$IncludeCallerTransition
    } finally { $response.Dispose() }
    @{test = 'private-client-access-lifecycle';allowed = $true;environment = $EnvironmentName} | ConvertTo-Json -Compress
} catch {
    $held = $_.Exception.Message -cin @('Private client access requires cleanup before mutation.','Caller transition requires reconciliation before mutation.')
    @{test = 'private-client-access-lifecycle';allowed = $false;held = $held;rawInputsSuppressed = $true} | ConvertTo-Json -Compress
    exit 2
} finally {
    if ($client) { $client.Dispose() }
    $token = $null
    $account = $null
    $group = $null
}
exit 0