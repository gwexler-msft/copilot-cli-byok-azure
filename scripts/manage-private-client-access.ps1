#requires -Version 7.4
[CmdletBinding(DefaultParameterSetName = 'Plan')]
param(
    [Parameter(ParameterSetName = 'Plan')][Parameter(ParameterSetName = 'Execute')][ValidateSet('Plan','Apply','Rollback')][string]$Action = 'Plan',
    [Parameter(Mandatory, ParameterSetName = 'Plan')][Parameter(Mandatory, ParameterSetName = 'Execute')][string]$StateFile,
    [Parameter(ParameterSetName = 'Plan')][Parameter(ParameterSetName = 'Execute')][string]$SnapshotFile,
    [Parameter(ParameterSetName = 'Plan')][string]$VmResourceId,
    [Parameter(ParameterSetName = 'Plan')][string]$GatewayResourceId,
    [Parameter(ParameterSetName = 'Plan')][ValidateSet('AzureCloud','AzureUSGovernment')][string]$Cloud = 'AzureUSGovernment',
    [Parameter(Mandatory, ParameterSetName = 'Execute')][string]$ReviewedDigest,
    [Parameter(ParameterSetName = 'Plan')][Parameter(Mandatory, ParameterSetName = 'Execute')][string]$ReviewedCommit,
    [Parameter(Mandatory, ParameterSetName = 'Execute')][string]$Repository,
    [Parameter(ParameterSetName = 'Plan')][Parameter(Mandatory, ParameterSetName = 'Execute')][string]$AzureConfigDirectory,
    [Parameter(ParameterSetName = 'Execute')][switch]$IsolationReviewConfirmed,
    [Parameter(ParameterSetName = 'Execute')][switch]$ApproveNetworkChanges,
    [Parameter(Mandatory, ParameterSetName = 'Definitions')][switch]$DefinitionsOnly
)

$ErrorActionPreference = 'Stop'
$previewModule = New-Module -Name PrivateClientAccessPreview -ArgumentList (Join-Path $PSScriptRoot 'preview-private-client-access.ps1') -ScriptBlock {
    param($Path)
    . $Path -DefinitionsOnly
    Export-ModuleMember -Function *
}
Import-Module $previewModule -Scope Local -DisableNameChecking

function New-PrivateClientTransition {
    param([string]$Operation, [string]$Digest, [string]$Commit, [string]$ExistingHold = '')
    if ($Operation -cnotin @('Plan','Apply','Rollback') -or $Digest -cnotmatch '\A[0-9a-f]{64}\z' -or $Commit -cnotmatch '\A[0-9a-f]{40}\z') {
        throw 'Invalid reviewed private-access transition.'
    }
    $hold = 'v1:' + $Commit + ':' + $Digest
    if ($Operation -ceq 'Apply' -and $ExistingHold) { throw 'A private-access hold already requires reconciliation.' }
    if ($Operation -ceq 'Rollback' -and $ExistingHold -cne $hold) { throw 'Rollback must own the exact retained access hold.' }
    $steps = if ($Operation -ceq 'Rollback') {
        @('verify-state','verify-holds','drain-lifecycle','disconnect-client','disconnect-gateway','verify-disconnected',
            'remove-dns','restore-subnets','remove-boundary-rules','remove-isolation','verify-restored','release-holds')
    } elseif ($Operation -ceq 'Apply') {
        @('verify-reviewed-source','verify-provider-preview','persist-recovery-state','reserve-holds','drain-lifecycle','revalidate-snapshot',
            'create-isolation','attach-isolation','create-boundary-rules','verify-isolation','verify-holds',
            'drain-lifecycle','connect-client','connect-gateway','verify-connected','create-dns','verify-access-state')
    } else { @() }
    @{operation = $Operation;hold = $hold;digest = $Digest;commit = $Commit;steps = $steps}
}

function Invoke-PrivateClientTransition {
    param($Transition, [scriptblock]$Execute)
    if ($Transition.operation -ceq 'Plan') { return }
    $expected = New-PrivateClientTransition $Transition.operation $Transition.digest $Transition.commit $(if ($Transition.operation -ceq 'Rollback') {$Transition.hold} else {''})
    if ($Transition.hold -cne $expected.hold -or ($Transition.steps -join ',') -cne ($expected.steps -join ',')) {
        throw 'Private-access transition ordering changed.'
    }
    foreach ($step in $expected.steps) { & $Execute $step }
}

function Get-PrivateClientManagerArtifact {
    $root = Split-Path $PSScriptRoot
    $paths = @('scripts/preview-private-client-access.ps1','scripts/check-private-client-access-hold.ps1','scripts/manage-private-client-access.ps1',
        'scripts/preview-private-client-access.sh','scripts/check-private-client-access-hold.sh','scripts/manage-private-client-access.sh',
        'scripts/tests/private-client-access.Tests.ps1','scripts/tests/private-client-access-requirements.txt',
        'infra/modules/private-client-access-preview.bicep','infra/modules/private-client-access-side.bicep',
        '.github/workflows/deploy-dev.yml','.github/workflows/teardown-dev.yml','.github/workflows/deploy.yml','.github/workflows/smoke-test.yml','.github/workflows/validate.yml')
    $hashes = @{}
    foreach ($path in $paths) { $hashes[$path] = (Get-FileHash -LiteralPath (Join-Path $root $path) -Algorithm SHA256).Hash.ToLowerInvariant() }
    $hashes
}

function New-PrivateClientRecoveryState {
    param($Candidate, $Artifact, [string]$Commit)
    $digest = Get-PrivateClientAccessDigest $Candidate $Artifact
    $transition = New-PrivateClientTransition Apply $digest $Commit
    $writes = [Collections.Generic.List[object]]::new()
    foreach ($id in $Candidate.expectedResources.Keys) {
        $entry = $Candidate.expectedResources[$id]
        $before = $null
        $beforeEtag = ''
        if ($entry.change -ceq 'Modify') {
            $subnets = @($Candidate.baseline.gatewayVnet.properties.subnets | Where-Object {$_.id -ieq $id})
            if ($subnets.Count -ne 1) { throw 'Recovery state is missing an original subnet.' }
            $before = Get-PrivateClientSubnetProperties $subnets[0] ($subnets[0].name -ceq 'snet-pe')
            $before.privateEndpointNetworkPolicies = $subnets[0].properties.privateEndpointNetworkPolicies
            $beforeEtag = $subnets[0].etag
        }
        $writes.Add(@{id = $id;change = $entry.change;beforeProperties = $before;beforeEtag = $beforeEtag;afterProperties = $entry.properties;status = 'Unstarted';afterEtag = ''})
    }
    @{
        version = 'private-client-access-recovery-v1';commit = $Commit;digest = $digest;hold = $transition.hold;artifact = $Artifact;candidate = $Candidate
        phase = 'Planned';createdAt = [DateTimeOffset]::UtcNow.ToString('o');openedAt = $null;steps = @();writes = $writes.ToArray()
        groups = @(
            @{id = '/subscriptions/' + $Candidate.baseline.subscriptionId + '/resourceGroups/' + $Candidate.parameters.clientResourceGroup.value;status = 'Unstarted'}
            @{id = '/subscriptions/' + $Candidate.baseline.subscriptionId + '/resourceGroups/' + $Candidate.parameters.gatewayResourceGroup.value;status = 'Unstarted'}
        )
    }
}

function Assert-PrivateClientRecoveryState {
    param($State, [string]$Digest, [string]$Commit)
    if ($State.version -cne 'private-client-access-recovery-v1' -or $State.digest -cne $Digest -or $State.commit -cne $Commit -or
        $State.hold -cne ('v1:' + $Commit + ':' + $Digest) -or $State.writes -isnot [array] -or $State.writes.Count -ne 17 -or
        $State.groups -isnot [array] -or $State.groups.Count -ne 2 -or $State.steps -isnot [array] -or
        (Get-PrivateClientAccessDigest $State.candidate $State.artifact) -cne $Digest) { throw 'Private-access recovery state or reviewed receipt changed.' }
    $expectedGroups = @(
        ('/subscriptions/' + $State.candidate.baseline.subscriptionId + '/resourceGroups/' + $State.candidate.parameters.clientResourceGroup.value)
        ('/subscriptions/' + $State.candidate.baseline.subscriptionId + '/resourceGroups/' + $State.candidate.parameters.gatewayResourceGroup.value)
    )
    if (@(Compare-Object ($expectedGroups | Sort-Object) @($State.groups.id | Sort-Object)).Count) { throw 'Recovery state contains another resource group.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $State.writes) {
        if (-not $seen.Add($entry.id) -or -not $State.candidate.expectedResources.Contains($entry.id) -or
            $entry.change -cne $State.candidate.expectedResources[$entry.id].change -or
            -not [Text.Json.Nodes.JsonNode]::DeepEquals([Text.Json.Nodes.JsonNode]::Parse((ConvertTo-Json -InputObject $entry.afterProperties -Depth 100)),
                [Text.Json.Nodes.JsonNode]::Parse((ConvertTo-Json -InputObject $State.candidate.expectedResources[$entry.id].properties -Depth 100))) -or
            $entry.status -cnotin @('Unstarted','Pending','Complete','Restored','Removed') ) { throw 'Recovery state contains an unreviewed resource write.' }
        if ($entry.change -ceq 'Modify') {
            $subnet = @($State.candidate.baseline.gatewayVnet.properties.subnets | Where-Object {$_.id -ieq $entry.id})
            if ($subnet.Count -ne 1 -or $entry.beforeEtag -cne $subnet[0].etag) { throw 'Recovery subnet version changed.' }
            $expectedBefore = Get-PrivateClientSubnetProperties $subnet[0] ($subnet[0].name -ceq 'snet-pe')
            $expectedBefore.privateEndpointNetworkPolicies = $subnet[0].properties.privateEndpointNetworkPolicies
            if (-not [Text.Json.Nodes.JsonNode]::DeepEquals([Text.Json.Nodes.JsonNode]::Parse((ConvertTo-Json -InputObject $expectedBefore -Depth 100)),
                [Text.Json.Nodes.JsonNode]::Parse((ConvertTo-Json -InputObject $entry.beforeProperties -Depth 100)))) { throw 'Recovery subnet properties changed.' }
        }
    }
}

function Write-PrivateClientRecoveryState {
    param([string]$Path, $State)
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $State -Depth 100 -Compress), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}

function Assert-PrivateClientOwnedWrite {
    param($Entry, $Current)
    if ($Entry.status -ceq 'Pending') { throw 'An interrupted write requires read-only reconciliation before cleanup.' }
    if ($Entry.status -cne 'Complete' -or $Current.status -ne 200 -or [string]::IsNullOrWhiteSpace($Entry.afterEtag) -or
        $Current.etag -cne $Entry.afterEtag -or -not (Test-PrivateClientWriteProperties $Entry.id $Entry.afterProperties $Current.body.properties)) {
        throw 'An access resource changed after this session; do not overwrite it.'
    }
}

function Test-PrivateClientWriteProperties {
    param([string]$Id, $Expected, $Actual)
    if ($Id -imatch '/virtualNetworks/[^/]+/subnets/[^/]+$' -and $Actual -is [Collections.IDictionary] -and
        $Expected.delegations -is [array] -and $Expected.delegations.Count -eq 0 -and $null -eq $Actual.delegations) {
        $normalized = @{}
        foreach ($key in $Actual.Keys) { $normalized[$key] = $Actual[$key] }
        $normalized.delegations = @()
        $Actual = $normalized
    }
    Test-PrivateClientExpectedProperties $Expected $Actual
}

function Read-PrivateClientGitHub {
    param([string]$Path)
    $executable = Get-Command gh -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $result = Invoke-PrivateClientProcess $executable.Source @('api', $Path, '--method', 'GET')
    if ($result.exitCode -ne 0) { throw 'Cannot verify private-access GitHub evidence.' }
    $result.stdout | ConvertFrom-Json -AsHashtable -Depth 100
}

function Assert-PrivateClientReviewedSource {
    param([string]$RepositoryName, [string]$Commit, [scriptblock]$Read = ${function:Read-PrivateClientGitHub})
    if ($RepositoryName -cnotmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z' -or $Commit -cnotmatch '\A[0-9a-f]{40}\z') { throw 'Invalid source review reference.' }
    $branch = & $Read ('repos/' + $RepositoryName + '/branches/main')
    if ($branch.commit.sha -cne $Commit) { throw 'Private access requires the reviewed current main commit.' }
    $proof = & $Read ('repos/' + $RepositoryName + '/actions/workflows/validate.yml/runs?head_sha=' + $Commit + '&per_page=5')
    $successful = @($proof.workflow_runs | Where-Object {$_.head_sha -ceq $Commit -and $_.status -ceq 'completed' -and $_.conclusion -ceq 'success'})
    if (-not $successful.Count) { throw 'Successful exact-source validation CI is required.' }
    $jobs = & $Read ('repos/' + $RepositoryName + '/actions/runs/' + $successful[0].id + '/jobs?per_page=100')
    $scans = @($jobs.jobs | Where-Object {$_.name -ceq 'Private access security scan' -and $_.conclusion -ceq 'success'})
    if ($jobs.total_count -gt 100 -or $scans.Count -ne 1) { throw 'The exact-source private-access security scan must pass.' }
}

function Assert-PrivateClientLifecycleIdle {
    param([string]$RepositoryName, [scriptblock]$Read = ${function:Read-PrivateClientGitHub})
    foreach ($status in @('queued','in_progress','waiting','pending','requested')) {
        $runs = & $Read ('repos/' + $RepositoryName + '/actions/runs?status=' + $status + '&per_page=100')
        if ($runs.workflow_runs -isnot [array] -or $runs.total_count -gt 100) { throw 'Complete lifecycle inactivity cannot be verified.' }
        $active = @($runs.workflow_runs | Where-Object {$_.path -cin @('.github/workflows/deploy-dev.yml','.github/workflows/teardown-dev.yml','.github/workflows/deploy.yml','.github/workflows/smoke-test.yml')})
        if ($active.Count) { throw 'Wait for existing lifecycle jobs to finish; no job was cancelled.' }
    }
}

function Assert-PrivateClientWorkingSource {
    param([string]$Commit, $Artifact)
    $root = Split-Path $PSScriptRoot
    $currentArtifact = Get-PrivateClientManagerArtifact
    if (@(Compare-Object @($currentArtifact.Keys | Sort-Object) @($Artifact.Keys | Sort-Object)).Count) { throw 'The review does not cover every private-access execution file.' }
    $git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    foreach ($path in $Artifact.Keys) {
        if ($currentArtifact[$path] -cne $Artifact[$path]) { throw 'Private-access tooling changed since its plan was reviewed.' }
        $working = Invoke-PrivateClientProcess $git.Source @('-C', $root, 'hash-object', ('--path=' + $path), (Join-Path $root $path))
        $committed = Invoke-PrivateClientProcess $git.Source @('-C', $root, 'rev-parse', ($Commit + ':' + $path))
        if ($working.exitCode -ne 0 -or $committed.exitCode -ne 0 -or $working.stdout.Trim() -cne $committed.stdout.Trim()) { throw 'Private-access tooling differs from the reviewed commit.' }
    }
}

function Assert-PrivateClientProviderPreview {
    param($Context, $State)
    $baseline = $State.candidate.baseline
    $pwsh = Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $result = Invoke-PrivateClientProcess $pwsh.Source @('-NoProfile','-NonInteractive','-File',
        (Join-Path $PSScriptRoot 'preview-private-client-access.ps1'),'-VmResourceId',$baseline.vm.id,'-GatewayResourceId',$baseline.gateway.id,
        '-AzureConfigDirectory',$Context.configDirectory,'-Cloud',$baseline.cloud,'-ProviderPreview')
    if ($result.exitCode -ne 0) { throw 'A fresh complete private-access provider preview must pass before applying.' }
    $report = $result.stdout | ConvertFrom-Json -AsHashtable -Depth 30
    if ($report.passed -ne $true -or $report.providerValidated -ne $true -or $report.scopeVerified -ne $true -or
        $report.snapshotUnchanged -ne $true -or $report.expectedResources -ne 17 -or $report.diagnostics -ne 0 -or
        $report.networkWrites -ne 0 -or $report.modelCalls -ne 0 -or $report.canApply -ne $false) { throw 'The provider preview is incomplete or not read-only.' }
}

function Assert-PrivateClientGuardedPair {
    param($State)
    $cloud = $State.candidate.baseline.cloud
    if ($cloud -cnotin @('AzureCloud','AzureUSGovernment')) { throw 'Unsupported guarded cloud.' }
    $prefix = if ($cloud -ceq 'AzureUSGovernment') { 'gov' } else { 'comm' }
    if ($State.candidate.parameters.clientResourceGroup.value -cne ('rg-copilot-byok-' + $prefix + '-pilot') -or
        $State.candidate.parameters.gatewayResourceGroup.value -cne ('rg-copilot-byok-' + $prefix + '-dev')) { throw 'The selected groups are not covered by the reviewed lifecycle guards.' }
}

function Get-PrivateClientArmToken {
    param([string]$Subscription, [string]$ConfigDirectory)
    if (-not [IO.Path]::IsPathFullyQualified($ConfigDirectory) -or -not (Test-Path -LiteralPath $ConfigDirectory -PathType Container)) { throw 'A cloud-pinned configuration directory is required.' }
    $launcher = Get-Command az -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $executable = $launcher.Source
    $arguments = @('account','get-access-token','--subscription',$Subscription,'--resource-type','arm','--output','json')
    if ($IsWindows -and [IO.Path]::GetExtension($executable) -in @('.cmd','.bat')) {
        $executable = Join-Path (Split-Path (Split-Path $executable)) 'python.exe'
        $arguments = @('-m','azure.cli') + $arguments
    }
    $result = Invoke-PrivateClientProcess $executable $arguments $ConfigDirectory
    if ($result.exitCode -ne 0) { throw 'A token from the selected cloud cache is required.' }
    $token = $result.stdout | ConvertFrom-Json -AsHashtable
    if ([string]::IsNullOrWhiteSpace($token.accessToken)) { throw 'A token from the selected cloud cache is required.' }
    $token
}

function Get-PrivateClientApiVersion {
    param([string]$ResourceId)
    if ($ResourceId -imatch '/providers/Microsoft\.Resources/tags/default$') { return '2021-04-01' }
    if ($ResourceId -imatch '/providers/Microsoft\.Network/privateDnsZones/') { return '2020-06-01' }
    if ($ResourceId -imatch '/providers/Microsoft\.Network/') { return '2024-05-01' }
    if ($ResourceId -imatch '\A/subscriptions/[^/]+/resourceGroups/[^/]+$') { return '2022-09-01' }
    throw 'Unreviewed private-access resource type.'
}

function Invoke-PrivateClientArm {
    param($Context, [string]$Method, [string]$Id, $Body = $null, [string]$ETag = '', [switch]$CreateOnly)
    if ($Method -cnotin @('GET','PUT','PATCH','DELETE') -or -not $Context.allowedIds.Contains($Id) -or
        ($Method -cin @('PUT','DELETE') -and -not $CreateOnly -and [string]::IsNullOrWhiteSpace($ETag)) -or
        ($CreateOnly -and $Method -cne 'PUT') -or ($Method -ceq 'PATCH' -and $Id -inotmatch '/providers/Microsoft\.Resources/tags/default$')) {
        throw 'Private-access ARM operation is outside the reviewed conditional scope.'
    }
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Context.arm + $Id + '?api-version=' + (Get-PrivateClientApiVersion $Id))
    try {
        if ($CreateOnly) { $null = $request.Headers.TryAddWithoutValidation('If-None-Match', '*') }
        elseif ($ETag) { $null = $request.Headers.TryAddWithoutValidation('If-Match', $ETag) }
        if ($null -ne $Body) { $request.Content = [Net.Http.StringContent]::new((ConvertTo-Json -InputObject $Body -Depth 100 -Compress), [Text.Encoding]::UTF8, 'application/json') }
        $response = $Context.client.SendAsync($request).GetAwaiter().GetResult()
        try {
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $bodyValue = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json -AsHashtable -Depth 100 }
            $status = [int]$response.StatusCode
            if ($status -eq 404 -and $Method -ceq 'GET' -and $bodyValue.error.code -cin @('ResourceNotFound','ResourceGroupNotFound','NotFound')) {
                return @{status = 404;body = $bodyValue;etag = ''}
            }
            if ($status -notin @(200,201,202,204)) { throw 'Conditional private-access ARM request failed; no write was retried.' }
            $etagValue = if ($response.Headers.ETag) { [string]$response.Headers.ETag } else { [string]$bodyValue.etag }
            @{status = $status;body = $bodyValue;etag = $etagValue}
        } finally { $response.Dispose() }
    } finally { $request.Dispose() }
}

function Wait-PrivateClientResource {
    param($Context, [string]$Id, [switch]$Deleted)
    $launcher = Get-Command az -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $executable = $launcher.Source
    $arguments = @('resource','wait','--ids',$Id,'--api-version',(Get-PrivateClientApiVersion $Id),'--subscription',$Context.subscription,
        '--interval','5','--timeout','180','--only-show-errors')
    $arguments += if ($Deleted) { '--deleted' } else { '--updated' }
    if ($IsWindows -and [IO.Path]::GetExtension($executable) -in @('.cmd','.bat')) {
        $executable = Join-Path (Split-Path (Split-Path $executable)) 'python.exe'
        $arguments = @('-m','azure.cli') + $arguments
    }
    $result = Invoke-PrivateClientProcess $executable $arguments $Context.configDirectory
    if ($result.exitCode -ne 0) { throw 'Private-access operation completion is unknown; retain state and holds for reconciliation.' }
}

function Assert-PrivateClientStateDirectory {
    param([string]$Path, [switch]$Create)
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or [IO.Path]::GetExtension($Path) -cne '.json') { throw 'Choose an absolute private recovery JSON path.' }
    $directory = Split-Path $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        if (-not $Create -or -not (Test-Path -LiteralPath (Split-Path $directory) -PathType Container)) { throw 'A private recovery directory is required.' }
        if ($IsWindows) {
            $null = New-Item -ItemType Directory -Path $directory -ErrorAction Stop
            $security = Get-Acl -LiteralPath $directory
            $security.SetAccessRuleProtection($true, $false)
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
            Set-Acl -LiteralPath $directory -AclObject $security
        } else {
            $null = [IO.Directory]::CreateDirectory($directory, ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute))
        }
    }
    if ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Recovery directory must not be a link.' }
    if ($IsWindows) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        foreach ($rule in (Get-Acl -LiteralPath $directory).Access) {
            if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -cnotin @($identity,'S-1-5-18','S-1-5-32-544')) { throw 'Recovery directory grants access to another identity.' }
        }
    } elseif (([IO.File]::GetUnixFileMode($directory) -band ([IO.UnixFileMode]::GroupRead -bor [IO.UnixFileMode]::GroupWrite -bor [IO.UnixFileMode]::GroupExecute -bor [IO.UnixFileMode]::OtherRead -bor [IO.UnixFileMode]::OtherWrite -bor [IO.UnixFileMode]::OtherExecute)) -ne 0) {
        throw 'Recovery directory must be private to its owner.'
    }
}

function Save-PrivateClientSession {
    param($Context, $State)
    Write-PrivateClientRecoveryState $Context.stateFile $State
}

function Assert-PrivateClientSessionHolds {
    param($Context, $State, [switch]$AllowUnreserved)
    foreach ($group in $State.groups) {
        $current = Invoke-PrivateClientArm $Context GET $group.id
        if ($current.status -ne 200 -or $current.body.properties.provisioningState -cne 'Succeeded') { throw 'Access session group is not available.' }
        $holdNames = @($current.body.tags.Keys | Where-Object {$_ -ieq 'byokPrivateClientAccess'})
        if ($holdNames.Count -eq 0 -and $AllowUnreserved -and $group.status -ceq 'Unstarted' -and
            -not @($State.writes | Where-Object {$_.id.StartsWith($group.id + '/', [StringComparison]::OrdinalIgnoreCase) -and $_.status -cnotin @('Unstarted','Removed','Restored')}).Count) { continue }
        if ($holdNames.Count -ne 1 -or $current.body.tags[$holdNames[0]] -cne $State.hold) { throw 'The exact access-session hold is not retained.' }
    }
}

function Assert-PrivateClientHoldReservation {
    param($Current, [string]$ExpectedId)
    if ($Current.status -ne 200 -or $Current.body.id -ine $ExpectedId -or $Current.body.properties.provisioningState -cne 'Succeeded' -or
        ($null -ne $Current.body.tags -and $Current.body.tags -isnot [Collections.IDictionary]) -or
        @($Current.body.tags.Keys | Where-Object {$_ -ieq 'byokCallerTransition' -or $_ -ieq 'byokPrivateClientAccess'}).Count) {
        throw 'A caller rollout or access hold must be reconciled before reserving temporary access.'
    }
}

function Set-PrivateClientSessionHolds {
    param($Context, $State, [switch]$Release)
    foreach ($group in $State.groups) {
        $current = Invoke-PrivateClientArm $Context GET $group.id
        if ($current.status -ne 200 -or $current.body.properties.provisioningState -cne 'Succeeded') { throw 'Cannot update the access hold on an unavailable group.' }
        $holdNames = @($current.body.tags.Keys | Where-Object {$_ -ieq 'byokPrivateClientAccess'})
        if ($Release) {
            if ($group.status -ceq 'Released' -and $holdNames.Count -eq 0) { continue }
            if ($group.status -ceq 'Unstarted' -and $holdNames.Count -eq 0) { $group.status = 'Released';Save-PrivateClientSession $Context $State;continue }
            if ($holdNames.Count -ne 1 -or $current.body.tags[$holdNames[0]] -cne $State.hold) { throw 'Refusing to remove another access-session hold.' }
        } elseif ($holdNames.Count -or $group.status -cne 'Unstarted') {
            throw 'An existing access-session hold requires reconciliation.'
        }
        if (-not $Release) { Assert-PrivateClientHoldReservation $current $group.id }
        $group.status = if ($Release) { 'Releasing' } else { 'Reserving' }
        Save-PrivateClientSession $Context $State
        $tagName = if ($Release) { $holdNames[0] } else { 'byokPrivateClientAccess' }
        $tags = @{}
        $tags[$tagName] = $State.hold
        $operation = if ($Release) { 'Delete' } else { 'Merge' }
        $null = Invoke-PrivateClientArm $Context PATCH ($group.id + '/providers/Microsoft.Resources/tags/default') @{operation = $operation;properties = @{tags = $tags}}
        $after = Invoke-PrivateClientArm $Context GET $group.id
        $afterNames = @($after.body.tags.Keys | Where-Object {$_ -ieq 'byokPrivateClientAccess'})
        if ($after.status -ne 200 -or ($Release -and $afterNames.Count) -or
            (-not $Release -and ($afterNames.Count -ne 1 -or $after.body.tags[$afterNames[0]] -cne $State.hold))) { throw 'Access hold update could not be verified.' }
        foreach ($key in $current.body.tags.Keys | Where-Object {$_ -ine 'byokPrivateClientAccess'}) {
            if ($after.body.tags[$key] -cne $current.body.tags[$key]) { throw 'An unrelated group tag changed during access coordination.' }
        }
        $group.status = if ($Release) { 'Released' } else { 'Held' }
        Save-PrivateClientSession $Context $State
    }
}

function Set-PrivateClientResource {
    param($Context, $State, $Entry)
    Assert-PrivateClientSessionHolds $Context $State
    if ($Entry.status -cne 'Unstarted') { throw 'An access write cannot be repeated automatically.' }
    $current = Invoke-PrivateClientArm $Context GET $Entry.id
    if ($Entry.change -ceq 'Create') {
        if ($current.status -ne 404) { throw 'A proposed access resource already exists.' }
    } elseif ($current.status -ne 200 -or $current.etag -cne $Entry.beforeEtag -or
        -not (Test-PrivateClientWriteProperties $Entry.id $Entry.beforeProperties $current.body.properties)) {
        throw 'The subnet changed before its preserving update.'
    }
    if ($Entry.id -imatch '/virtualNetworkPeerings/' -and $State.openedAt -and
        ([DateTimeOffset]::UtcNow - [DateTimeOffset]$State.openedAt).TotalMinutes -ge 30) { throw 'The approved access-open window expired before connectivity completed.' }
    $body = @{properties = $Entry.afterProperties}
    if ($Entry.id -imatch '/networkSecurityGroups/[^/]+$') { $body.location = $State.candidate.baseline.gatewayVnet.location }
    $Entry.status = 'Pending'
    Save-PrivateClientSession $Context $State
    $result = Invoke-PrivateClientArm $Context PUT $Entry.id $body $Entry.beforeEtag -CreateOnly:($Entry.change -ceq 'Create')
    if ($result.status -eq 202 -or $result.body.properties.provisioningState -cnotin @($null,'Succeeded')) { Wait-PrivateClientResource $Context $Entry.id }
    $after = Invoke-PrivateClientArm $Context GET $Entry.id
    if ($after.status -ne 200 -or [string]::IsNullOrWhiteSpace($after.etag) -or
        $after.body.properties.provisioningState -cnotin @($null,'Succeeded') -or
        -not (Test-PrivateClientWriteProperties $Entry.id $Entry.afterProperties $after.body.properties)) { throw 'The conditional access write did not pass readback.' }
    $Entry.afterEtag = $after.etag
    $Entry.status = 'Complete'
    Save-PrivateClientSession $Context $State
}

function Refresh-PrivateClientIsolationVersion {
    param($Context, $State)
    $parent = @($State.writes | Where-Object {$_.id -imatch '/networkSecurityGroups/[^/]+$'})
    if ($parent.Count -ne 1 -or $parent[0].status -cne 'Complete') { throw 'The new isolation NSG is not owned by this session.' }
    $current = Invoke-PrivateClientArm $Context GET $parent[0].id
    $rules = @($State.writes | Where-Object {$_.id.StartsWith($parent[0].id + '/securityRules/', [StringComparison]::OrdinalIgnoreCase) -and $_.status -ceq 'Complete'})
    $attached = @($State.writes | Where-Object {$_.change -ceq 'Modify' -and $_.status -ceq 'Complete'} | ForEach-Object id)
    $actualRules = @($current.body.properties.securityRules | Where-Object {$null -ne $_})
    $actualSubnets = @($current.body.properties.subnets | Where-Object {$null -ne $_} | ForEach-Object id)
    if ($current.status -ne 200 -or [string]::IsNullOrWhiteSpace($current.etag) -or $current.body.properties.provisioningState -cne 'Succeeded' -or
        $current.body.properties.flushConnection -eq $true -or @($current.body.tags.Keys | Where-Object {$null -ne $_}).Count -or
        @($current.body.properties.networkInterfaces | Where-Object {$null -ne $_}).Count -or
        $actualRules.Count -ne $rules.Count -or @(Compare-Object @($attached | Sort-Object) @($actualSubnets | Sort-Object)).Count) {
        throw 'Isolation NSG associations or settings changed outside the session.'
    }
    foreach ($rule in $rules) {
        $actual = @($actualRules | Where-Object {$_.id -ieq $rule.id})
        if ($actual.Count -ne 1 -or -not (Test-PrivateClientExpectedProperties $rule.afterProperties $actual[0].properties)) { throw 'The isolation NSG contains an unreviewed rule.' }
    }
    $parent[0].afterEtag = $current.etag
    Save-PrivateClientSession $Context $State
}

function Remove-PrivateClientResource {
    param($Context, $State, $Entry)
    Assert-PrivateClientSessionHolds $Context $State -AllowUnreserved:($State.phase -ceq 'RollingBack')
    $current = Invoke-PrivateClientArm $Context GET $Entry.id
    if ($Entry.status -cin @('Unstarted','Removed')) {
        if ($current.status -ne 404) { throw 'An unowned access resource exists; do not delete it.' }
        return
    }
    Assert-PrivateClientOwnedWrite $Entry $current
    $Entry.status = 'Pending'
    Save-PrivateClientSession $Context $State
    $result = Invoke-PrivateClientArm $Context DELETE $Entry.id $null $Entry.afterEtag
    if ($result.status -eq 202) { Wait-PrivateClientResource $Context $Entry.id -Deleted }
    if ((Invoke-PrivateClientArm $Context GET $Entry.id).status -ne 404) { throw 'Access resource deletion is not confirmed.' }
    $Entry.status = 'Removed'
    Save-PrivateClientSession $Context $State
}

function Restore-PrivateClientSubnet {
    param($Context, $State, $Entry)
    Assert-PrivateClientSessionHolds $Context $State -AllowUnreserved:($State.phase -ceq 'RollingBack')
    $current = Invoke-PrivateClientArm $Context GET $Entry.id
    if ($Entry.status -cin @('Unstarted','Restored')) {
        if ($current.status -ne 200 -or -not (Test-PrivateClientWriteProperties $Entry.id $Entry.beforeProperties $current.body.properties) -or
            $current.body.properties.networkSecurityGroup) { throw 'The original unmodified subnet state is not verified.' }
        return
    }
    Assert-PrivateClientOwnedWrite $Entry $current
    $Entry.status = 'Pending'
    Save-PrivateClientSession $Context $State
    $result = Invoke-PrivateClientArm $Context PUT $Entry.id @{properties = $Entry.beforeProperties} $Entry.afterEtag
    if ($result.status -eq 202 -or $result.body.properties.provisioningState -cnotin @($null,'Succeeded')) { Wait-PrivateClientResource $Context $Entry.id }
    $after = Invoke-PrivateClientArm $Context GET $Entry.id
    if ($after.status -ne 200 -or $after.body.properties.networkSecurityGroup -or
        -not (Test-PrivateClientWriteProperties $Entry.id $Entry.beforeProperties $after.body.properties)) { throw 'Original subnet settings were not restored.' }
    $Entry.status = 'Restored'
    Save-PrivateClientSession $Context $State
}

function Invoke-PrivateClientSessionStep {
    param([string]$Step, $Context, $State)
    $peerings = @($State.writes | Where-Object {$_.id -imatch '/virtualNetworkPeerings/'})
    $dns = @($State.writes | Where-Object {$_.id -imatch '/privateDnsZones/[^/]+/A/'})
    $isolation = @($State.writes | Where-Object {$_.id -imatch '/networkSecurityGroups/[^/]+$'})
    $isolationRules = @($State.writes | Where-Object {$_.id.StartsWith($isolation[0].id + '/securityRules/', [StringComparison]::OrdinalIgnoreCase)})
    $boundaryRules = @($State.writes | Where-Object {$_.id -imatch '/securityRules/' -and -not $_.id.StartsWith($isolation[0].id + '/securityRules/', [StringComparison]::OrdinalIgnoreCase)})
    $subnets = @($State.writes | Where-Object change -CEQ 'Modify')
    if ($peerings.Count -ne 2 -or $dns.Count -ne 1 -or $isolation.Count -ne 1 -or $isolationRules.Count -ne 2 -or $boundaryRules.Count -ne 6 -or $subnets.Count -ne 5) { throw 'Recovery execution footprint is not exact.' }
    switch ($Step) {
        'verify-reviewed-source' {
            Assert-PrivateClientReviewedSource $Context.repository $State.commit
            Assert-PrivateClientWorkingSource $State.commit $State.artifact
        }
        'verify-provider-preview' { Assert-PrivateClientProviderPreview $Context $State }
        'persist-recovery-state' { $State.phase = 'Applying';Save-PrivateClientSession $Context $State }
        'reserve-holds' { Set-PrivateClientSessionHolds $Context $State }
        'drain-lifecycle' { Assert-PrivateClientLifecycleIdle $Context.repository }
        'revalidate-snapshot' {
            $baseline = $State.candidate.baseline
            $current = New-PrivateClientAccessCandidate (Read-PrivateClientSnapshot $baseline.vm.id $baseline.gateway.id $Context.configDirectory $baseline.cloud)
            if ((Get-PrivateClientAccessDigest $current $State.artifact) -cne $State.digest) { throw 'Network snapshot changed after lifecycle protection.' }
        }
        'create-isolation' {
            Set-PrivateClientResource $Context $State $isolation[0]
            foreach ($entry in $isolationRules) { Set-PrivateClientResource $Context $State $entry }
            Refresh-PrivateClientIsolationVersion $Context $State
        }
        'attach-isolation' {
            foreach ($entry in $subnets) { Set-PrivateClientResource $Context $State $entry }
            Refresh-PrivateClientIsolationVersion $Context $State
        }
        'create-boundary-rules' { foreach ($entry in $boundaryRules) { Set-PrivateClientResource $Context $State $entry } }
        'verify-isolation' {
            Refresh-PrivateClientIsolationVersion $Context $State
            foreach ($entry in $subnets + $isolationRules + $boundaryRules) { Assert-PrivateClientOwnedWrite $entry (Invoke-PrivateClientArm $Context GET $entry.id) }
        }
        'verify-holds' { Assert-PrivateClientSessionHolds $Context $State -AllowUnreserved:($State.phase -ceq 'RollingBack') }
        'connect-client' {
            Assert-PrivateClientReviewedSource $Context.repository $State.commit
            $entry = @($peerings | Where-Object {$_.id.StartsWith($State.candidate.baseline.clientVnet.id + '/', [StringComparison]::OrdinalIgnoreCase)})[0]
            Set-PrivateClientResource $Context $State $entry
            $State.openedAt = [DateTimeOffset]::UtcNow.ToString('o')
            Save-PrivateClientSession $Context $State
        }
        'connect-gateway' {
            $entry = @($peerings | Where-Object {$_.id.StartsWith($State.candidate.baseline.gatewayVnet.id + '/', [StringComparison]::OrdinalIgnoreCase)})[0]
            Set-PrivateClientResource $Context $State $entry
        }
        'verify-connected' {
            foreach ($entry in $peerings) {
                $current = Invoke-PrivateClientArm $Context GET $entry.id
                if ($current.status -ne 200 -or $current.body.properties.peeringState -cne 'Connected' -or
                    -not (Test-PrivateClientExpectedProperties $entry.afterProperties $current.body.properties)) { throw 'Both reviewed peerings must be Connected.' }
                $entry.afterEtag = $current.etag
            }
            Save-PrivateClientSession $Context $State
        }
        'create-dns' { Set-PrivateClientResource $Context $State $dns[0] }
        'verify-access-state' {
            foreach ($entry in $peerings + $dns) { Assert-PrivateClientOwnedWrite $entry (Invoke-PrivateClientArm $Context GET $entry.id) }
            Assert-PrivateClientSessionHolds $Context $State
            $State.phase = 'Open'
            Save-PrivateClientSession $Context $State
        }
        'verify-state' {
            Assert-PrivateClientRecoveryState $State $State.digest $State.commit
            Assert-PrivateClientWorkingSource $State.commit $State.artifact
            $State.phase = 'RollingBack'
            Save-PrivateClientSession $Context $State
        }
        'disconnect-client' {
            $entry = @($peerings | Where-Object {$_.id.StartsWith($State.candidate.baseline.clientVnet.id + '/', [StringComparison]::OrdinalIgnoreCase)})[0]
            Remove-PrivateClientResource $Context $State $entry
        }
        'disconnect-gateway' {
            $entry = @($peerings | Where-Object {$_.id.StartsWith($State.candidate.baseline.gatewayVnet.id + '/', [StringComparison]::OrdinalIgnoreCase)})[0]
            if ($entry.status -ceq 'Complete') {
                $current = Invoke-PrivateClientArm $Context GET $entry.id
                if ($current.status -ne 200 -or $current.body.properties.peeringState -cnotin @('Disconnected','Initiated') -or
                    -not (Test-PrivateClientExpectedProperties $entry.afterProperties $current.body.properties)) { throw 'Remaining owned peering did not disconnect.' }
                $entry.afterEtag = $current.etag
                Save-PrivateClientSession $Context $State
            }
            Remove-PrivateClientResource $Context $State $entry
        }
        'verify-disconnected' { foreach ($entry in $peerings) { if ((Invoke-PrivateClientArm $Context GET $entry.id).status -ne 404) { throw 'Connectivity remains; retain all isolation and holds.' } } }
        'remove-dns' { Remove-PrivateClientResource $Context $State $dns[0] }
        'restore-subnets' { foreach ($entry in $subnets) { Restore-PrivateClientSubnet $Context $State $entry } }
        'remove-boundary-rules' { foreach ($entry in $boundaryRules) { Remove-PrivateClientResource $Context $State $entry } }
        'remove-isolation' {
            if ($isolation[0].status -ceq 'Complete') {
                Refresh-PrivateClientIsolationVersion $Context $State
                foreach ($entry in $isolationRules) { Remove-PrivateClientResource $Context $State $entry }
                Refresh-PrivateClientIsolationVersion $Context $State
            }
            Remove-PrivateClientResource $Context $State $isolation[0]
        }
        'verify-restored' {
            foreach ($entry in $State.writes) {
                $current = Invoke-PrivateClientArm $Context GET $entry.id
                if ($entry.change -ceq 'Create') {
                    if ($current.status -ne 404) { throw 'A temporary access resource remains.' }
                } elseif ($current.status -ne 200 -or $current.body.properties.networkSecurityGroup -or
                    -not (Test-PrivateClientWriteProperties $entry.id $entry.beforeProperties $current.body.properties)) { throw 'Original subnet state is not restored.' }
            }
        }
        'release-holds' { Set-PrivateClientSessionHolds $Context $State -Release;$State.phase = 'Closed';Save-PrivateClientSession $Context $State }
        default { throw 'Unknown private-access session step.' }
    }
    $State.steps += $Step
    Save-PrivateClientSession $Context $State
}

if ($DefinitionsOnly) { return }

$context = $null
$sessionLock = $null
try {
    Assert-PrivateClientStateDirectory $StateFile -Create:($Action -ceq 'Plan')
    $sessionLock = [IO.File]::Open($StateFile + '.lock', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    if ($Action -ceq 'Plan') {
        if (Test-Path -LiteralPath $StateFile) { throw 'Use a new recovery-state path; never overwrite a previous session.' }
        $snapshot = if ($SnapshotFile) {
            Get-Content -LiteralPath $SnapshotFile -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        } else { Read-PrivateClientSnapshot $VmResourceId $GatewayResourceId $AzureConfigDirectory $Cloud }
        $candidate = New-PrivateClientAccessCandidate $snapshot
        $artifact = Get-PrivateClientManagerArtifact
        if (-not $ReviewedCommit) {
            $git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
            $result = Invoke-PrivateClientProcess $git.Source @('-C', (Split-Path $PSScriptRoot), 'rev-parse', 'HEAD')
            if ($result.exitCode -ne 0) { throw 'Select a reviewed source commit.' }
            $ReviewedCommit = $result.stdout.Trim()
        }
        $state = New-PrivateClientRecoveryState $candidate $artifact $ReviewedCommit
        Assert-PrivateClientRecoveryState ($state | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100) $state.digest $ReviewedCommit
        Write-PrivateClientRecoveryState $StateFile $state
        @{test = 'private-client-access-session';action = 'Plan';digest = $state.digest;expectedResources = 17;networkWrites = 0;modelCalls = 0;requiresSeparateApproval = $true} | ConvertTo-Json -Compress
    } else {
        if ($PSCmdlet.ParameterSetName -cne 'Execute' -or -not $ApproveNetworkChanges -or
            ($Action -ceq 'Apply' -and -not $IsolationReviewConfirmed)) { throw 'Explicit reviewed network and isolation approval is required.' }
        $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        Assert-PrivateClientRecoveryState $state $ReviewedDigest $ReviewedCommit
        Assert-PrivateClientGuardedPair $state
        if ($Action -ceq 'Apply' -and $state.phase -cne 'Planned') { throw 'Apply cannot repeat or resume an uncertain session.' }
        if ($Action -ceq 'Rollback' -and $state.phase -ceq 'Closed') { throw 'This access session is already closed.' }
        $account = Invoke-PrivateClientAzure @('account','show','--subscription',$state.candidate.baseline.subscriptionId,'--output','json') $AzureConfigDirectory
        if ($account.id -ine $state.candidate.baseline.subscriptionId -or $account.environmentName -cne $state.candidate.baseline.cloud) { throw 'Execution context differs from the reviewed snapshot.' }
        $token = Get-PrivateClientArmToken $account.id $AzureConfigDirectory
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $client = [Net.Http.HttpClient]::new($handler)
        $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token.accessToken)
        $client.DefaultRequestHeaders.Accept.ParseAdd('application/json')
        $token = $null
        $allowedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $state.writes) { $null = $allowedIds.Add($entry.id) }
        foreach ($group in $state.groups) { $null = $allowedIds.Add($group.id);$null = $allowedIds.Add($group.id + '/providers/Microsoft.Resources/tags/default') }
        $context = @{stateFile = $StateFile;repository = $Repository;subscription = $account.id;configDirectory = $AzureConfigDirectory;allowedIds = $allowedIds;client = $client;arm = $(if ($account.environmentName -ceq 'AzureUSGovernment') {'https://management.usgovcloudapi.net'} else {'https://management.azure.com'})}
        $transition = New-PrivateClientTransition $Action $ReviewedDigest $ReviewedCommit $(if ($Action -ceq 'Rollback') {$state.hold} else {''})
        Invoke-PrivateClientTransition $transition {param($step) Invoke-PrivateClientSessionStep $step $context $state}
        @{test = 'private-client-access-session';action = $Action;phase = $state.phase;digest = $state.digest;holdsRetained = $state.phase -cne 'Closed';modelCalls = 0} | ConvertTo-Json -Compress
    }
} catch {
    @{test = 'private-client-access-session';passed = $false;action = $Action;manualReconciliationRequired = $Action -cne 'Plan';rawInputsSuppressed = $true} | ConvertTo-Json -Compress
    [Console]::Error.WriteLine('Private client access stopped. Preserve the state file and retained holds; no operation was retried.')
    exit 1
} finally {
    if ($context.client) { $context.client.Dispose() }
    if ($sessionLock) { $sessionLock.Dispose() }
    $token = $null
    $snapshot = $null
    $state = $null
}
exit 0