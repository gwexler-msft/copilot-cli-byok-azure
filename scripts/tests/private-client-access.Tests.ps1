#requires -Version 7.4
[CmdletBinding()]
param([string]$SecurityTemplatePath)

$ErrorActionPreference = 'Stop'
$helperPath = Join-Path $PSScriptRoot '../preview-private-client-access.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Private-access helper does not parse.' }
foreach ($name in @('Get-PrivateClientNetwork', 'New-PrivateClientAccessRules', 'Get-PrivateClientResourceParts', 'Assert-PrivateClientResource', 'Get-PrivateClientSubnetProperties', 'Assert-PrivateClientNsgRules', 'New-PrivateClientAccessCandidate', 'Get-PrivateClientAccessDigest', 'Test-PrivateClientExpectedProperties', 'Test-PrivateClientAccessWhatIf', 'Assert-PrivateClientReadOnlyCommand', 'Read-PrivateClientSnapshot')) {
    $definition = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name}, $false))
    if ($definition.Count -ne 1) { throw 'Private-access helper is ambiguous.' }
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
if (@($ast.ParamBlock.Parameters | Where-Object {$_.Name.VariablePath.UserPath -match '^(Apply|Deploy|Delete|Remove)$'}).Count) {
    throw 'Validation-only tooling must not expose an apply operation.'
}
$clientBase = [Net.IPAddress]::new([byte[]]@(10, 81, 0, 0)).ToString()
$gatewayBase = [Net.IPAddress]::new([byte[]]@(10, 82, 0, 0)).ToString()
$vmAddress = [Net.IPAddress]::new([byte[]]@(10, 81, 3, 4)).ToString()
$gatewayAddress = [Net.IPAddress]::new([byte[]]@(10, 82, 1, 4)).ToString()
$gatewaySubnetBase = [Net.IPAddress]::new([byte[]]@(10, 82, 1, 0)).ToString()
$inputValues = @{VmAddress = $vmAddress;GatewayAddress = $gatewayAddress;ClientPrefix = $clientBase + '/16';GatewayPrefix = $gatewayBase + '/16';GatewaySubnetPrefix = $gatewaySubnetBase + '/27'}
$checks = 0
$managerPath = Join-Path $PSScriptRoot '../manage-private-client-access.ps1'
$managerAst = [Management.Automation.Language.Parser]::ParseFile($managerPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Private-access manager does not parse.' }
foreach ($name in @('New-PrivateClientTransition','Invoke-PrivateClientTransition','New-PrivateClientRecoveryState','Assert-PrivateClientRecoveryState','Assert-PrivateClientOwnedWrite','Test-PrivateClientWriteProperties','Assert-PrivateClientReviewedSource','Assert-PrivateClientLifecycleIdle','Invoke-PrivateClientArm','Assert-PrivateClientGuardedPair','Set-PrivateClientResource','Remove-PrivateClientResource','Restore-PrivateClientSubnet','Invoke-PrivateClientSessionStep','Refresh-PrivateClientIsolationVersion','Set-PrivateClientSessionHolds','Assert-PrivateClientSessionHolds','Assert-PrivateClientHoldReservation')) {
    $definition = @($managerAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name}, $false))
    if ($definition.Count -ne 1) { throw 'Private-access manager helper is ambiguous.' }
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
$transitionDigest = 'c' * 64
$transitionCommit = 'd' * 40
$transitionHold = 'v1:' + $transitionCommit + ':' + $transitionDigest
foreach ($case in @('government','commercial','other-client','other-gateway','unknown-cloud')) {
    $prefix = if ($case -ceq 'commercial') {'comm'} else {'gov'}
    $state = @{candidate = @{baseline = @{cloud = $(if ($case -ceq 'commercial') {'AzureCloud'} else {'AzureUSGovernment'})};parameters = @{clientResourceGroup = @{value = 'rg-copilot-byok-' + $prefix + '-pilot'};gatewayResourceGroup = @{value = 'rg-copilot-byok-' + $prefix + '-dev'}}}}
    switch ($case) {
        'other-client' {$state.candidate.parameters.clientResourceGroup.value = 'another-group'}
        'other-gateway' {$state.candidate.parameters.gatewayResourceGroup.value = 'another-group'}
        'unknown-cloud' {$state.candidate.baseline.cloud = 'unknown'}
    }
    $accepted = $false
    try {Assert-PrivateClientGuardedPair $state;$accepted = $true} catch {}
    if ($accepted -ne ($case -cin @('government','commercial'))) {throw 'Execution escaped the groups covered by lifecycle guards.'}
    $checks++
}
foreach ($case in @('green','changed-main','failed-ci','missing-scan','failed-scan','truncated-jobs')) {
    $reader = {
        param($path)
        if ($path.EndsWith('/branches/main')) { return @{commit = @{sha = $(if ($case -ceq 'changed-main') {'e' * 40} else {$transitionCommit})}} }
        if ($path.Contains('/jobs?')) { return @{total_count = $(if ($case -ceq 'truncated-jobs') {101} else {1});jobs = @(@{name = $(if ($case -ceq 'missing-scan') {'different-job'} else {'Private access security scan'});conclusion = $(if ($case -ceq 'failed-scan') {'failure'} else {'success'})})} }
        @{workflow_runs = @(@{id = 1;head_sha = $transitionCommit;status = 'completed';conclusion = $(if ($case -ceq 'failed-ci') {'failure'} else {'success'})})}
    }
    $accepted = $false
    try { Assert-PrivateClientReviewedSource 'owner/repository' $transitionCommit $reader;$accepted = $true } catch {}
    if ($accepted -ne ($case -ceq 'green')) { throw ('Reviewed CI gate failed: ' + $case) }
    $checks++
}
foreach ($case in @('idle','queued','in_progress','waiting','pending','requested','truncated')) {
    $reader = {param($path)
        $active = $case -cne 'idle' -and $path.Contains('status=' + $case + '&')
        $runList = @()
        if ($active) { $runList += @{path = '.github/workflows/deploy-dev.yml'} }
        @{total_count = $(if ($case -ceq 'truncated') {101} elseif ($active) {1} else {0});workflow_runs = $runList}
    }
    $accepted = $false
    try { Assert-PrivateClientLifecycleIdle 'owner/repository' $reader;$accepted = $true } catch {}
    if ($accepted -ne ($case -ceq 'idle')) { throw ('Lifecycle inactivity gate failed: ' + $case) }
    $checks++
}
foreach ($operation in @('Plan','Apply','Rollback')) {
    $transition = New-PrivateClientTransition $operation $transitionDigest $transitionCommit $(if ($operation -ceq 'Rollback') {$transitionHold} else {''})
    $trace = [Collections.Generic.List[string]]::new()
    Invoke-PrivateClientTransition $transition {param($step) $trace.Add($step)}
    if ($operation -ceq 'Plan' -and $trace.Count) { throw 'A plan executed a mutation.' }
    if ($operation -ceq 'Apply' -and ($trace.IndexOf('reserve-holds') -gt $trace.IndexOf('create-isolation') -or
        $trace.IndexOf('persist-recovery-state') -gt $trace.IndexOf('reserve-holds') -or
        $trace.IndexOf('verify-isolation') -gt $trace.IndexOf('connect-client'))) { throw 'Access can open before recovery state, holds or isolation.' }
    if ($operation -ceq 'Rollback' -and ($trace.IndexOf('verify-disconnected') -gt $trace.IndexOf('restore-subnets') -or
        $trace.IndexOf('disconnect-gateway') -gt $trace.IndexOf('verify-disconnected') -or $trace[-1] -cne 'release-holds')) { throw 'Rollback can relax isolation before disconnection.' }
    foreach ($failureStep in $transition.steps) {
        $trace.Clear()
        $failed = $false
        try { Invoke-PrivateClientTransition $transition {param($step) $trace.Add($step);if ($step -ceq $failureStep) {throw 'fixture-failure'}} } catch { $failed = $true }
        if (-not $failed -or $trace[-1] -cne $failureStep -or $trace.Count -ne [array]::IndexOf($transition.steps, $failureStep) + 1) { throw 'A failed transition continued or retried.' }
        $checks++
    }
    $checks++
}
foreach ($case in @('wrong-hold','existing-apply','tampered-order','invalid-digest')) {
    $rejected = $false
    try {
        switch ($case) {
            'wrong-hold' { $null = New-PrivateClientTransition Rollback $transitionDigest $transitionCommit 'another-hold' }
            'existing-apply' { $null = New-PrivateClientTransition Apply $transitionDigest $transitionCommit $transitionHold }
            'invalid-digest' { $null = New-PrivateClientTransition Apply 'invalid' $transitionCommit }
            'tampered-order' { $transition = New-PrivateClientTransition Rollback $transitionDigest $transitionCommit $transitionHold;$transition.steps = @('release-holds');Invoke-PrivateClientTransition $transition {throw 'must-not-run'} }
        }
    } catch { $rejected = $true }
    if (-not $rejected) { throw ('Private-access transition gate failed: ' + $case) }
    $checks++
}
foreach ($workflowName in @('deploy-dev','teardown-dev','deploy','smoke-test')) {
    $workflowText = Get-Content -LiteralPath (Join-Path $PSScriptRoot ('../../.github/workflows/' + $workflowName + '.yml')) -Raw
    $guards = [regex]::Matches($workflowText, '(?ms)^      - name: Guard private client access\r?\n(?<body>.*?)(?=^      - |\z)')
    if ($guards.Count -ne $(if ($workflowName -ceq 'deploy') {2} else {1})) {throw ('Lifecycle workflow guard count changed: ' + $workflowName)}
    foreach ($guard in $guards) {
        if ($guard.Groups['body'].Value -match '(?m)^        if:' -or $guard.Groups['body'].Value -notmatch 'shell: pwsh' -or
            $guard.Groups['body'].Value -notmatch 'check-private-client-access-hold\.ps1 -EnvironmentName \$env:TARGET_ENVIRONMENT -SubscriptionId \$env:TARGET_SUBSCRIPTION -Cloud \$env:TARGET_CLOUD') {
            throw ('Lifecycle workflow can bypass its private-access guard: ' + $workflowName)
        }
    }
    $mutation = switch ($workflowName) {
        'deploy-dev' { '- name: Preview development infrastructure only' }
        'teardown-dev' { '- name: Delete RG (or dry-run plan)' }
        'deploy' { '- name: Provision (phase 1' }
        'smoke-test' { '- name: Run smoke probes' }
    }
    if ($workflowText.IndexOf($mutation, [StringComparison]::Ordinal) -lt $guards[-1].Index -or
        $workflowText.IndexOf('uses: actions/checkout@v4', [StringComparison]::Ordinal) -lt 0 -or
        $workflowText.IndexOf('uses: actions/checkout@v4', [StringComparison]::Ordinal) -gt $guards[0].Index) {
        throw ('Private-access guard is not before work with a checked-out helper: ' + $workflowName)
    }
    if ($workflowName -ceq 'deploy' -and ($workflowText.IndexOf('- name: What-if preview (no changes applied)', [StringComparison]::Ordinal) -lt $guards[0].Index -or
        $workflowText.IndexOf("`n  deploy:", [StringComparison]::Ordinal) -gt $guards[1].Index)) {throw 'Pilot preview hooks or deploy job can bypass access coordination.'}
    $checks++
}
$holdHelper = Join-Path $PSScriptRoot '../check-private-client-access-hold.ps1'
$holdAst = [Management.Automation.Language.Parser]::ParseFile($holdHelper, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Private-access lifecycle guard does not parse.' }
$holdDefinition = @($holdAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-PrivateClientLifecycleState'}, $false))
if ($holdDefinition.Count -ne 1) { throw 'Private-access lifecycle guard is ambiguous.' }
. ([scriptblock]::Create($holdDefinition[0].Extent.Text))
$holdGroupId = '/subscriptions/' + [guid]::NewGuid().ToString() + '/resourceGroups/rg-copilot-byok-gov-dev'
foreach ($case in @('available','caller-held','empty-caller-hold','access-held','wrong-group','denied')) {
    $current = @{status = 200;body = @{id = $holdGroupId;properties = @{provisioningState = 'Succeeded'};tags = @{}}}
    switch ($case) {
        'caller-held' {$current.body.tags.byokCallerTransition = 'fixture'}
        'empty-caller-hold' {$current.body.tags.byokCallerTransition = ''}
        'access-held' {$current.body.tags.byokPrivateClientAccess = 'fixture'}
        'wrong-group' {$current.body.id += '-other'}
        'denied' {$current.status = 403}
    }
    $accepted = $false
    try {Assert-PrivateClientHoldReservation $current $holdGroupId;$accepted = $true} catch {}
    if ($accepted -ne ($case -ceq 'available')) {throw 'Access reservation can collide with another rollout.'}
    $checks++
}
foreach ($case in @('unheld','null-tags','missing-group','active','empty','expired','malformed','case-insensitive-tag','wrong-group','deleting','forbidden','other-404','invalid-tags')) {
    $status = 200
    $group = @{id = $holdGroupId;properties = @{provisioningState = 'Succeeded'};tags = @{}}
    switch ($case) {
        'null-tags' { $group.tags = $null }
        'missing-group' { $status = 404;$group = @{error = @{code = 'ResourceGroupNotFound'}} }
        'active' { $group.tags.byokPrivateClientAccess = 'active' }
        'empty' { $group.tags.byokPrivateClientAccess = '' }
        'expired' { $group.tags.byokPrivateClientAccess = 'expired-fixture' }
        'malformed' { $group.tags.byokPrivateClientAccess = 'invalid' }
        'case-insensitive-tag' { $group.tags.BYOKPRIVATECLIENTACCESS = 'active' }
        'wrong-group' { $group.id += '-other' }
        'deleting' { $group.properties.provisioningState = 'Deleting' }
        'forbidden' { $status = 403;$group = @{error = @{code = 'AuthorizationFailed'}} }
        'other-404' { $status = 404;$group = @{error = @{code = 'NotFound'}} }
        'invalid-tags' { $group.tags = 'unverified' }
    }
    $allowed = $false
    try { Assert-PrivateClientLifecycleState $status $group $holdGroupId;$allowed = $true } catch {}
    if ($allowed -ne ($case -cin @('unheld','null-tags','missing-group'))) { throw ('Private-access lifecycle hold gate failed: ' + $case) }
    $checks++
}
foreach ($case in @(
    @{arguments = @('account','show','--output','json');allowed = $true},
    @{arguments = @('cloud','show','--output','json');allowed = $true},
    @{arguments = @('rest','--method','GET');allowed = $true},
    @{arguments = @('deployment','sub','validate');allowed = $true},
    @{arguments = @('deployment','sub','what-if');allowed = $true},
    @{arguments = @('deployment','sub','create');allowed = $false},
    @{arguments = @('rest','--method','PUT');allowed = $false},
    @{arguments = @('rest','--method','PATCH');allowed = $false},
    @{arguments = @('rest','--method','DELETE');allowed = $false},
    @{arguments = @('network','vnet','update');allowed = $false},
    @{arguments = @('login');allowed = $false},
    @{arguments = @('cloud','set');allowed = $false},
    @{arguments = @('account','set');allowed = $false},
    @{arguments = @('feature','register');allowed = $false},
    @{arguments = @('rest','--method','GET','--debug');allowed = $false},
    @{arguments = @('rest','--method','GET','--method','PUT');allowed = $false},
    @{arguments = @('rest','--method','GET','-m','DELETE');allowed = $false},
    @{arguments = @('rest','--method','GET','--debug=true');allowed = $false}
)) {
    $accepted = $false
    try { Assert-PrivateClientReadOnlyCommand $case.arguments;$accepted = $true } catch {}
    if ($accepted -ne $case.allowed) { throw 'Read-only Azure command boundary failed.' }
    $checks++
}
foreach ($case in @('valid', 'public-client', 'overlap', 'vm-outside', 'gateway-outside', 'subnet-outside', 'noncanonical', 'invalid-ip', 'ipv6')) {
    $candidate = $inputValues.Clone()
    switch ($case) {
        'public-client' { $candidate.ClientPrefix = ([Net.IPAddress]::new([byte[]]@(8, 0, 0, 0)).ToString() + '/8') }
        'overlap' { $candidate.ClientPrefix = $gatewayBase + '/16';$candidate.VmAddress = $gatewayAddress }
        'vm-outside' { $candidate.VmAddress = $gatewayAddress }
        'gateway-outside' { $candidate.GatewayAddress = $vmAddress }
        'subnet-outside' { $candidate.GatewaySubnetPrefix = $clientBase + '/16' }
        'noncanonical' { $candidate.ClientPrefix = $vmAddress + '/16' }
        'invalid-ip' { $candidate.VmAddress = 'invalid' }
        'ipv6' { $candidate.VmAddress = [Net.IPAddress]::IPv6Loopback.ToString() }
    }
    $accepted = $false
    try { $rules = New-PrivateClientAccessRules @candidate;$accepted = $true } catch {}
    if ($accepted -ne ($case -ceq 'valid')) { throw ('Private network gate failed: ' + $case) }
    $checks++
}
$rules = New-PrivateClientAccessRules @inputValues
if ($rules.client.Count -ne 3 -or $rules.gateway.Count -ne 3 -or $rules.isolation.Count -ne 2) { throw 'The approved rule footprint changed.' }
$allowRules = @($rules.client + $rules.gateway + $rules.isolation | Where-Object {$_.properties.access -ceq 'Allow'})
if ($allowRules.Count -ne 2 -or @($allowRules | Where-Object {$_.properties.protocol -cne 'Tcp' -or $_.properties.destinationPortRange -cne '443' -or $_.properties.sourceAddressPrefix -cne ($vmAddress + '/32')}).Count) { throw 'HTTPS allowance was broadened.' }
if ($rules.client[0].properties.destinationAddressPrefix -cne ($gatewayAddress + '/32') -or $rules.gateway[0].properties.destinationAddressPrefix -cne $inputValues.GatewaySubnetPrefix) { throw 'Gateway VIP and translated subnet boundaries changed.' }
foreach ($side in @('client', 'gateway', 'isolation')) {
    if (@($rules[$side] | Where-Object {$_.properties.access -ceq 'Deny' -and ($_.properties.protocol -cne '*' -or $_.properties.destinationPortRange -cne '*')}).Count) { throw 'Cross-network deny coverage was narrowed.' }
    $checks++
}
$checks++
$subscription = [guid]::NewGuid().ToString()
$clientGroup = '/subscriptions/' + $subscription + '/resourceGroups/client-fixture'
$gatewayGroup = '/subscriptions/' + $subscription + '/resourceGroups/gateway-fixture'
$clientVnetId = $clientGroup + '/providers/Microsoft.Network/virtualNetworks/client-fixture'
$gatewayVnetId = $gatewayGroup + '/providers/Microsoft.Network/virtualNetworks/gateway-fixture'
$clientNsgId = $clientGroup + '/providers/Microsoft.Network/networkSecurityGroups/client-fixture'
$gatewayNsgId = $gatewayGroup + '/providers/Microsoft.Network/networkSecurityGroups/gateway-fixture'
$nicId = $clientGroup + '/providers/Microsoft.Network/networkInterfaces/client-fixture'
$gatewayLabel = 'fixture-' + [guid]::NewGuid().ToString('N')
function New-AccessFixtureResource {
    param([string]$Id, [string]$Type, $Properties)
    @{id = $Id;name = $Id.Split('/')[-1];type = $Type;location = 'usgovvirginia';etag = 'fixture-etag';properties = $Properties}
}
function New-AccessFixtureSubnet {
    param([string]$VnetId, [string]$Name, [string]$Prefix, [string]$NsgId = '')
    $properties = @{addressPrefix = $Prefix;provisioningState = 'Succeeded';privateEndpointNetworkPolicies = 'Disabled';privateLinkServiceNetworkPolicies = 'Enabled';defaultOutboundAccess = $false;delegations = @();serviceEndpoints = @()}
    if ($NsgId) { $properties.networkSecurityGroup = @{id = $NsgId} }
    New-AccessFixtureResource ($VnetId + '/subnets/' + $Name) 'Microsoft.Network/virtualNetworks/subnets' $properties
}
$clientSubnet = New-AccessFixtureSubnet $clientVnetId 'snet-vm' ([Net.IPAddress]::new([byte[]]@(10,81,3,0)).ToString() + '/27') $clientNsgId
$gatewaySubnet = New-AccessFixtureSubnet $gatewayVnetId 'snet-apim' $inputValues.GatewaySubnetPrefix $gatewayNsgId
$devSubnets = @($gatewaySubnet)
$subnetOctet = 2
foreach ($name in @('snet-pe','snet-dns-in','snet-runner','snet-aci','snet-cae-register')) {
    $devSubnets += New-AccessFixtureSubnet $gatewayVnetId $name ([Net.IPAddress]::new([byte[]]@(10,82,$subnetOctet,0)).ToString() + '/27')
    $subnetOctet++
}
$devSubnets[3].properties.delegations = @(@{name = 'fixture-apps';properties = @{serviceName = 'Microsoft.App/environments';actions = @('join/action');provisioningState = 'Succeeded'}})
$fixture = @{
    version = 'private-client-access-v1';cloud = 'AzureUSGovernment';subscriptionId = $subscription;capturedAt = [DateTimeOffset]::UtcNow.ToString('o')
    vm = (New-AccessFixtureResource ($clientGroup + '/providers/Microsoft.Compute/virtualMachines/client-fixture') 'Microsoft.Compute/virtualMachines' @{provisioningState = 'Succeeded';storageProfile = @{osDisk = @{osType = 'Windows'}};networkProfile = @{networkInterfaces = @(@{id = $nicId})}})
    nic = (New-AccessFixtureResource $nicId 'Microsoft.Network/networkInterfaces' @{enableIPForwarding = $false;ipConfigurations = @(@{properties = @{privateIPAddress = $vmAddress;privateIPAddressVersion = 'IPv4';subnet = @{id = $clientSubnet.id}}})})
    clientVnet = (New-AccessFixtureResource $clientVnetId 'Microsoft.Network/virtualNetworks' @{provisioningState = 'Succeeded';addressSpace = @{addressPrefixes = @($inputValues.ClientPrefix)};subnets = @($clientSubnet);virtualNetworkPeerings = @()})
    gatewayVnet = (New-AccessFixtureResource $gatewayVnetId 'Microsoft.Network/virtualNetworks' @{provisioningState = 'Succeeded';addressSpace = @{addressPrefixes = @($inputValues.GatewayPrefix)};subnets = $devSubnets;virtualNetworkPeerings = @()})
    gateway = (New-AccessFixtureResource ($gatewayGroup + '/providers/Microsoft.ApiManagement/service/' + $gatewayLabel) 'Microsoft.ApiManagement/service' @{provisioningState = 'Succeeded';virtualNetworkType = 'Internal';privateIPAddresses = @($gatewayAddress);gatewayUrl = ('https://' + $gatewayLabel + '.azure-api.us');virtualNetworkConfiguration = @{subnetResourceId = $gatewaySubnet.id}})
    clientNsg = (New-AccessFixtureResource $clientNsgId 'Microsoft.Network/networkSecurityGroups' @{provisioningState = 'Succeeded';securityRules = @();defaultSecurityRules = @();subnets = @(@{id = $clientSubnet.id})})
    gatewayNsg = (New-AccessFixtureResource $gatewayNsgId 'Microsoft.Network/networkSecurityGroups' @{provisioningState = 'Succeeded';securityRules = @();defaultSecurityRules = @();subnets = @(@{id = $gatewaySubnet.id})})
    dnsZone = (New-AccessFixtureResource ($clientGroup + '/providers/Microsoft.Network/privateDnsZones/azure-api.us') 'Microsoft.Network/privateDnsZones' @{})
    clientPeerings = @{value = @()};gatewayPeerings = @{value = @()};dnsRecords = @{value = @()};dnsLinks = @{value = @(@{properties = @{virtualNetwork = @{id = $clientVnetId}}})};isolationNsgAbsent = $true
}
foreach ($case in @('valid','case-insensitive-id','location-display','wrong-region','stale','other-subscription','same-group','extra-nic','public-vm','forwarding','external-apim','multiple-gateway-ips','peering','pagination','missing-subnet','extra-subnet','duplicate-subnet','subnet-nsg','route-table','unknown-subnet-field','missing-etag','priority-collision','early-rule','dns-record','wildcard','dns-other-vnet','existing-isolation-nsg','unknown-delegation','immutable-outbound-type')) {
    $snapshot = $fixture | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
    switch ($case) {
        'case-insensitive-id' { $snapshot.nic.properties.ipConfigurations[0].properties.subnet.id = $clientSubnet.id.ToUpperInvariant() }
        'location-display' { $snapshot.gateway.location = 'USGov Virginia' }
        'wrong-region' { $snapshot.gateway.location = 'USGov Arizona' }
        'stale' { $snapshot.capturedAt = [DateTimeOffset]::UtcNow.AddHours(-1).ToString('o') }
        'other-subscription' { $snapshot.subscriptionId = [guid]::NewGuid().ToString() }
        'same-group' { $snapshot.gatewayVnet.id = $clientVnetId }
        'extra-nic' { $snapshot.vm.properties.networkProfile.networkInterfaces += @{id = $nicId} }
        'public-vm' { $snapshot.nic.properties.ipConfigurations[0].properties.publicIPAddress = @{id = 'fixture'} }
        'forwarding' { $snapshot.nic.properties.enableIPForwarding = $true }
        'external-apim' { $snapshot.gateway.properties.virtualNetworkType = 'External' }
        'multiple-gateway-ips' { $snapshot.gateway.properties.privateIPAddresses += $gatewayAddress }
        'peering' { $snapshot.clientPeerings.value = @(@{name = 'existing'}) }
        'pagination' { $snapshot.dnsLinks.nextLink = 'unread-page' }
        'missing-subnet' { $snapshot.gatewayVnet.properties.subnets = @($snapshot.gatewayVnet.properties.subnets | Select-Object -Skip 1) }
        'extra-subnet' { $snapshot.gatewayVnet.properties.subnets += New-AccessFixtureSubnet $gatewayVnetId 'extra' ([Net.IPAddress]::new([byte[]]@(10,82,20,0)).ToString() + '/27') }
        'duplicate-subnet' { $snapshot.gatewayVnet.properties.subnets += $snapshot.gatewayVnet.properties.subnets[0] }
        'subnet-nsg' { $snapshot.gatewayVnet.properties.subnets[1].properties.networkSecurityGroup = @{id = $gatewayNsgId} }
        'route-table' { $snapshot.gatewayVnet.properties.subnets[1].properties.routeTable = @{id = 'fixture'} }
        'unknown-subnet-field' { $snapshot.gatewayVnet.properties.subnets[1].properties.unknownWritable = 'must-not-drop' }
        'missing-etag' { $snapshot.gatewayVnet.properties.subnets[1].Remove('etag') }
        'priority-collision' { $snapshot.clientNsg.properties.securityRules = @($rules.client[0]) }
        'early-rule' { $snapshot.clientNsg.properties.securityRules = @(@{name = 'early';properties = @{priority = 100;direction = 'Outbound';access = 'Allow'}}) }
        'dns-record' { $snapshot.dnsRecords.value = @(@{name = $gatewayLabel}) }
        'wildcard' { $snapshot.dnsRecords.value = @(@{name = '*'}) }
        'dns-other-vnet' { $snapshot.dnsLinks.value[0].properties.virtualNetwork.id = $gatewayVnetId }
        'existing-isolation-nsg' { $snapshot.isolationNsgAbsent = $false }
        'unknown-delegation' { $snapshot.gatewayVnet.properties.subnets[1].properties.delegations = @(@{name = 'fixture';properties = @{serviceName = 'Unsupported/service'}}) }
        'immutable-outbound-type' { $snapshot.gatewayVnet.properties.subnets[1].properties.defaultOutboundAccess = 'false' }
    }
    $accepted = $false
    try { $candidate = New-PrivateClientAccessCandidate $snapshot;$accepted = $true } catch { if ($case -cin @('valid','case-insensitive-id','location-display')) { throw } }
    if ($accepted -ne ($case -cin @('valid','case-insensitive-id','location-display'))) { throw ('Private-access topology gate failed: ' + $case) }
    $checks++
}
$candidate = New-PrivateClientAccessCandidate $fixture
$recoveryArtifact = @{fixture = 'artifact'}
$recovery = New-PrivateClientRecoveryState $candidate $recoveryArtifact $transitionCommit
foreach ($case in @('create','update','preexisting','drift','async','readback-failure')) {
    & {
        $state = $recovery | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
        $entry = @($state.writes | Where-Object change -CEQ $(if ($case -cin @('update','drift')) {'Modify'} else {'Create'}))[0]
        $trace = [Collections.Generic.List[string]]::new()
        $current = if ($entry.change -ceq 'Modify') {@{status = 200;etag = $entry.beforeEtag;body = @{properties = $entry.beforeProperties}}} else {@{status = 404}}
        if ($case -ceq 'preexisting') {$current = @{status = 200;etag = 'other';body = @{properties = @{}}}}
        if ($case -ceq 'drift') {$current.etag = 'changed'}
        $storage = @{current = $current}
        function Assert-PrivateClientSessionHolds {param($Context,$State) $trace.Add('holds')}
        function Save-PrivateClientSession {param($Context,$State) $trace.Add('save:' + $entry.status)}
        function Wait-PrivateClientResource {param($Context,$Id) $trace.Add('wait')}
        function Invoke-PrivateClientArm {
            param($Context,[string]$Method,[string]$Id,$Body=$null,[string]$ETag='',[switch]$CreateOnly)
            if ($Id -cne $entry.id) {throw 'Effect addressed an unreviewed resource.'}
            $trace.Add($Method)
            if ($Method -ceq 'GET') {return $storage.current}
            if ($Method -cne 'PUT' -or $entry.status -cne 'Pending' -or -not $trace.Contains('save:Pending') -or
                ($entry.change -ceq 'Create' -and -not $CreateOnly) -or ($entry.change -ceq 'Modify' -and $ETag -cne $entry.beforeEtag)) {throw 'Write escaped conditional journaling.'}
            $properties = $Body.properties | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
            if ($case -ceq 'readback-failure') {$properties = @{unexpected = $true}}
            $storage.current = @{status = 200;etag = 'after-etag';body = @{properties = $properties}}
            @{status = $(if ($case -ceq 'async') {202} else {200});body = @{properties = @{provisioningState = 'Succeeded'}}}
        }
        $accepted = $false
        try {Set-PrivateClientResource @{} $state $entry;$accepted = $true} catch {}
        if ($accepted -ne ($case -cin @('create','update','async'))) {throw ('Conditional resource effect failed: ' + $case)}
        if ($accepted -and ($entry.status -cne 'Complete' -or $entry.afterEtag -cne 'after-etag')) {throw 'Successful effect did not persist readback ownership.'}
        if ($case -cin @('preexisting','drift') -and $trace.Contains('PUT')) {throw 'A refused effect performed a write.'}
        if ($case -ceq 'readback-failure' -and $entry.status -cne 'Pending') {throw 'Unknown write outcome was falsely finalized.'}
        if ($case -ceq 'async' -and -not $trace.Contains('wait')) {throw 'Async write was not waited for.'}
    }
    $checks++
}
foreach ($case in @('original','wrong-digest','wrong-commit','wrong-group','changed-target','changed-before','changed-artifact','changed-allowlist','duplicate-write')) {
    $state = $recovery | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
    $digest = $state.digest
    $commit = $transitionCommit
    switch ($case) {
        'wrong-digest' { $digest = 'e' * 64 }
        'wrong-commit' { $commit = 'e' * 40 }
        'wrong-group' { $state.groups[0].id += '-other' }
        'changed-target' { $state.writes[0].id = $nicId }
        'changed-before' { ($state.writes | Where-Object change -CEQ 'Modify' | Select-Object -First 1).beforeProperties.defaultOutboundAccess = $true }
        'changed-artifact' { $state.artifact.fixture = 'changed' }
        'changed-allowlist' {
            $write = @($state.writes | Where-Object {$_.id -imatch '/securityRules/'})[0]
            $state.candidate.expectedResources[$write.id].properties.access = 'Allow'
            $write.afterProperties.access = 'Allow'
            $state.candidate.expectedResources[$write.id].properties.destinationPortRange = '*'
            $write.afterProperties.destinationPortRange = '*'
        }
        'duplicate-write' { $state.writes[0] = $state.writes[1] }
    }
    $accepted = $false
    try { Assert-PrivateClientRecoveryState $state $digest $commit;$accepted = $true } catch { if ($case -ceq 'original') { throw } }
    if ($accepted -ne ($case -ceq 'original')) { throw ('Recovery state guard failed: ' + $case) }
    $checks++
}
foreach ($case in @('owned','changed-etag','changed-properties','pending','missing','unstarted')) {
    $entry = @{status = 'Complete';afterEtag = 'known-etag';afterProperties = @{allowGatewayTransit = $false}}
    $current = @{status = 200;etag = 'known-etag';body = @{properties = @{allowGatewayTransit = $false}}}
    switch ($case) {
        'changed-etag' { $current.etag = 'new-etag' }
        'changed-properties' { $current.body.properties.allowGatewayTransit = $true }
        'pending' { $entry.status = 'Pending' }
        'unstarted' { $entry.status = 'Unstarted' }
        'missing' { $current.status = 404 }
    }
    $accepted = $false
    try { Assert-PrivateClientOwnedWrite $entry $current;$accepted = $true } catch {}
    if ($accepted -ne ($case -ceq 'owned')) { throw ('Conditional resource ownership check failed: ' + $case) }
    $checks++
}
foreach ($case in @('ordered-empty','null-empty','missing-nonempty','actual-nonempty')) {
    $expected = @{delegations = @()}
    $actual = [ordered]@{provisioningState = 'Succeeded'}
    switch ($case) {
        'null-empty' {$actual.delegations = $null}
        'missing-nonempty' {$expected.delegations = @(@{name = 'required'})}
        'actual-nonempty' {$actual.delegations = @(@{name = 'unexpected'})}
    }
    $accepted = Test-PrivateClientWriteProperties ($gatewayVnetId + '/subnets/snet-pe') $expected $actual
    if ($accepted -ne ($case -cin @('ordered-empty','null-empty'))) {throw 'Runtime subnet normalization accepted an actual delegation change.'}
    if ($case -ceq 'ordered-empty' -and $actual.Contains('delegations')) {throw 'Runtime subnet normalization mutated the original response.'}
    $checks++
}
foreach ($sessionCase in @('complete','holds-only','partial-isolation','missing-empty-delegations','pending-dns')) {
& {
    $state = $recovery | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
    $store = @{}
    $effects = [Collections.Generic.List[string]]::new()
    foreach ($group in $state.groups) {$store[$group.id] = @{id = $group.id;properties = @{provisioningState = 'Succeeded'};tags = @{preserved = 'original'}}}
    foreach ($entry in $state.writes | Where-Object change -CEQ 'Modify') {
        $store[$entry.id] = @{id = $entry.id;etag = $entry.beforeEtag;properties = ($entry.beforeProperties | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100)}
    }
    $version = @{counter = 0}
    $parentId = @($state.writes | Where-Object {$_.id -imatch '/networkSecurityGroups/[^/]+$'})[0].id
    function Copy-SessionFixture {param($Value) ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 100) -AsHashtable -Depth 100 -NoEnumerate}
    function Save-PrivateClientSession {param($Context,$State) $effects.Add('journal')}
    function Assert-PrivateClientReviewedSource {param($RepositoryName,$Commit) $effects.Add('review')}
    function Assert-PrivateClientWorkingSource {param($Commit,$Artifact) $effects.Add('source')}
    function Assert-PrivateClientProviderPreview {param($Context,$State) $effects.Add('provider-preview')}
    function Assert-PrivateClientLifecycleIdle {param($RepositoryName) $effects.Add('idle')}
    function Read-PrivateClientSnapshot {param($VmId,$GatewayId,$ConfigDirectory,$CloudName) Copy-SessionFixture $fixture}
    function Wait-PrivateClientResource {param($Context,$Id,[switch]$Deleted) throw 'Synchronous fixture unexpectedly waited.'}
    function Invoke-PrivateClientArm {
        param($Context,[string]$Method,[string]$Id,$Body=$null,[string]$ETag='',[switch]$CreateOnly)
        if ($Method -ceq 'GET') {
            if (-not $store.ContainsKey($Id)) {return @{status = 404}}
            $bodyCopy = Copy-SessionFixture $store[$Id]
            if ($sessionCase -ceq 'missing-empty-delegations' -and $Id -imatch '/subnets/' -and
                $bodyCopy.properties.delegations -is [array] -and $bodyCopy.properties.delegations.Count -eq 0) {$bodyCopy.properties.Remove('delegations')}
            return @{status = 200;etag = $store[$Id].etag;body = $bodyCopy}
        }
        $effects.Add($Method + ':' + $Id)
        if ($Method -ceq 'PATCH') {
            $groupId = $Id.Substring(0, $Id.IndexOf('/providers/', [StringComparison]::OrdinalIgnoreCase))
            if (-not $store.ContainsKey($groupId) -or $Body.properties.tags.Count -ne 1 -or $Body.properties.tags.byokPrivateClientAccess -cne $state.hold) {throw 'Tag mutation escaped exact session scope.'}
            if ($Body.operation -ceq 'Merge') {$store[$groupId].tags.byokPrivateClientAccess = $state.hold}
            elseif ($Body.operation -ceq 'Delete') {$store[$groupId].tags.Remove('byokPrivateClientAccess')}
            else {throw 'Unexpected tag operation.'}
            return @{status = 200}
        }
        if (-not $state.candidate.expectedResources.Contains($Id)) {throw 'Fixture received an unapproved resource write.'}
        if ($CreateOnly) {if ($store.ContainsKey($Id)) {throw 'Conditional create collided.'}}
        elseif (-not $store.ContainsKey($Id) -or $store[$Id].etag -cne $ETag) {throw 'Conditional write version mismatch.'}
        if ($Method -ceq 'PUT' -and $Id -imatch '/virtualNetworkPeerings/') {
            if (@($state.writes | Where-Object {$_.id -inotmatch '/virtualNetworkPeerings/|/privateDnsZones/' -and $_.status -cne 'Complete'}).Count) {throw 'Peering opened before every isolation write was verified.'}
        }
        if ($Method -ceq 'PUT' -and $state.phase -ceq 'RollingBack' -and $Id -imatch '/subnets/') {
            if (@($store.Keys | Where-Object {$_ -imatch '/virtualNetworkPeerings/'}).Count) {throw 'Subnet protection removed while peering exists.'}
        }
        $version.counter++
        if ($Method -ceq 'DELETE') {$store.Remove($Id)}
        elseif ($Method -ceq 'PUT') {
            $store[$Id] = @{id = $Id;etag = 'version-' + $version.counter;properties = (Copy-SessionFixture $Body.properties)}
            $store[$Id].properties.provisioningState = 'Succeeded'
        } else {throw 'Unexpected resource mutation.'}
        if ($Id -imatch '/virtualNetworkPeerings/') {
            $peers = @($store.Keys | Where-Object {$_ -imatch '/virtualNetworkPeerings/'})
            foreach ($peer in $peers) {
                $store[$peer].properties.peeringState = if ($peers.Count -eq 2) {'Connected'} elseif ($Method -ceq 'DELETE') {'Disconnected'} else {'Initiated'}
                $version.counter++
                $store[$peer].etag = 'version-' + $version.counter
            }
        }
        if ($store.ContainsKey($parentId)) {
            $store[$parentId].properties.securityRules = @(foreach ($key in @($store.Keys)) {if ($key.StartsWith($parentId + '/securityRules/', [StringComparison]::OrdinalIgnoreCase)) {@{id = $key;name = $key.Split('/')[-1];properties = (Copy-SessionFixture $store[$key].properties)}}})
            $store[$parentId].properties.subnets = @(foreach ($key in @($store.Keys)) {if ($key -imatch '/subnets/' -and $store[$key].properties.networkSecurityGroup.id -ieq $parentId) {@{id = $key}}})
            $version.counter++
            $store[$parentId].etag = 'version-' + $version.counter
        }
        if ($Method -ceq 'DELETE') {return @{status = 204}}
        @{status = 200;body = (Copy-SessionFixture $store[$Id])}
    }
    $context = @{repository = 'owner/repository';configDirectory = 'fixture'}
    $transition = New-PrivateClientTransition Apply $state.digest $state.commit
    $stopped = $false
    try {
        Invoke-PrivateClientTransition $transition {param($step)
            if (($sessionCase -ceq 'holds-only' -and $step -ceq 'create-isolation') -or
                ($sessionCase -ceq 'partial-isolation' -and $step -ceq 'attach-isolation')) {throw 'fixture-interruption'}
            Invoke-PrivateClientSessionStep $step $context $state
        }
    } catch {if ($_.Exception.Message -cne 'fixture-interruption') {throw};$stopped = $true}
    if ($stopped -ne ($sessionCase -cin @('holds-only','partial-isolation'))) {throw 'Mocked interruption boundary changed.'}
    if (-not $stopped -and ($state.phase -cne 'Open' -or @($state.writes | Where-Object status -CNE 'Complete').Count -or
        @($state.groups | Where-Object status -CNE 'Held').Count)) {throw 'Mocked apply did not open a fully verified, held session.'}
    if ($sessionCase -ceq 'pending-dns') {($state.writes | Where-Object {$_.id -imatch '/privateDnsZones/'}).status = 'Pending'}
    $transition = New-PrivateClientTransition Rollback $state.digest $state.commit $state.hold
    $rollbackStopped = $false
    try {Invoke-PrivateClientTransition $transition {param($step) Invoke-PrivateClientSessionStep $step $context $state}}
    catch {if ($sessionCase -cne 'pending-dns' -or $_.Exception.Message -cne 'An interrupted write requires read-only reconciliation before cleanup.') {throw};$rollbackStopped = $true}
    if ($sessionCase -ceq 'pending-dns') {
        if (-not $rollbackStopped -or @($store.Keys | Where-Object {$_ -imatch '/virtualNetworkPeerings/'}).Count -or
            @($state.groups | Where-Object status -CNE 'Held').Count -or @($effects | Where-Object {$_ -clike 'DELETE:*'}).Count -ne 2 -or
            @($state.writes | Where-Object {$_.id -imatch '/securityRules/|/subnets/' -and $_.status -cne 'Complete'}).Count) {
            throw 'Uncertain DNS recovery did not disconnect known peerings while retaining all isolation and holds.'
        }
        return
    }
    if ($state.phase -cne 'Closed' -or @($state.groups | Where-Object status -CNE 'Released').Count -or
        @($store.Keys | Where-Object {$_ -imatch '/virtualNetworkPeerings/|/securityRules/|/privateDnsZones/'}).Count) {throw 'Mocked rollback left access resources or holds behind.'}
    foreach ($group in $state.groups) {if ($store[$group.id].tags.preserved -cne 'original' -or $store[$group.id].tags.Contains('byokPrivateClientAccess')) {throw 'Rollback changed original group tags.'}}
    $expectedDeletes = switch ($sessionCase) {'holds-only' {0};'partial-isolation' {3};default {12}}
    if (@($effects | Where-Object {$_ -clike 'DELETE:*'}).Count -ne $expectedDeletes) {throw 'Rollback deletion count escaped the approved footprint.'}
}
$checks++
}
if ($candidate.expectedResources.Count -ne 17 -or $candidate.canApply -ne $false -or $candidate.blockers -cnotcontains 'merged-lifecycle-guards-and-idle-jobs-required') { throw 'Preview footprint or apply-readiness gate changed.' }
foreach ($configuration in @($candidate.parameters.clientConfiguration.value, $candidate.parameters.gatewayConfiguration.value)) {
    foreach ($name in @('virtualNetworkName','networkSecurityGroupName','isolationNsgName','dnsZoneName','dnsRecordName')) {
        if ([string]::IsNullOrWhiteSpace($configuration[$name])) { throw 'ARM still requires well-formed names in disabled branches.' }
    }
}
if ($candidate.parameters.clientConfiguration.value.isolationRules.Count -ne 0 -or $candidate.parameters.clientConfiguration.value.subnets.Count -ne 0) { throw 'Disabled client-side isolation branches acquired writes.' }
$checks++
$subnetUpdates = $candidate.parameters.gatewayConfiguration.value.subnets
if ($subnetUpdates.Count -ne 5 -or @($subnetUpdates | Where-Object {$_.properties.defaultOutboundAccess -ne $false -or $_.properties.privateEndpointNetworkPolicies -cne $(if ($_.name -ceq 'snet-pe') {'NetworkSecurityGroupEnabled'} else {'Disabled'})}).Count -or
    @($fixture.gatewayVnet.properties.subnets | Where-Object {$_.properties.privateEndpointNetworkPolicies -cne 'Disabled'}).Count) { throw 'Subnet projection changed the original snapshot or immutable settings.' }
$checks++
foreach ($case in @('single-page','paginated','foreign-host','foreign-path','duplicate-page','wrong-cloud')) {
    & {
        $requests = [Collections.Generic.List[string]]::new()
        $responses = @{}
        foreach ($name in @('vm','nic','clientVnet','gatewayVnet','gateway','clientNsg','gatewayNsg','dnsZone')) { $responses[$fixture[$name].id] = $fixture[$name] }
        $responses[$clientVnetId + '/virtualNetworkPeerings'] = $fixture.clientPeerings
        $responses[$gatewayVnetId + '/virtualNetworkPeerings'] = $fixture.gatewayPeerings
        $responses[$fixture.dnsZone.id + '/virtualNetworkLinks'] = $fixture.dnsLinks
        $recordsPath = $fixture.dnsZone.id + '/ALL'
        function Invoke-PrivateClientAzure {
            param([string[]]$Arguments, [string]$ConfigDirectory, [switch]$AllowMissing)
            Assert-PrivateClientReadOnlyCommand $Arguments
            if ($ConfigDirectory -cne 'fixture-cache') { throw 'Collector changed the selected Azure cache.' }
            if ($Arguments[0] -ceq 'account') { return @{id = $subscription;environmentName = 'AzureUSGovernment'} }
            if ($Arguments[0] -ceq 'cloud') { return @{name = $(if ($case -ceq 'wrong-cloud') {'AzureCloud'} else {'AzureUSGovernment'})} }
            $url = $Arguments[[array]::IndexOf($Arguments, '--url') + 1]
            $requests.Add($url)
            $uri = [uri]$url
            if ($uri.DnsSafeHost -cne 'management.usgovcloudapi.net') { throw 'Collector sent a request to an untrusted host.' }
            if ($uri.AbsolutePath -ceq $recordsPath) {
                if ($uri.Query.Contains('page=2')) { return @{value = @(@{name = 'unrelated-record'})} }
                if ($case -ceq 'single-page') { return @{value = @()} }
                $next = 'https://management.usgovcloudapi.net' + $recordsPath + '?api-version=2020-06-01&page=2'
                switch ($case) {
                    'foreign-host' { $next = 'https://untrusted.invalid' + $recordsPath + '?page=2' }
                    'foreign-path' { $next = 'https://management.usgovcloudapi.net' + $nicId + '?page=2' }
                    'duplicate-page' { $next = $url }
                }
                return @{value = @();nextLink = $next}
            }
            if ($responses.ContainsKey($uri.AbsolutePath)) { return $responses[$uri.AbsolutePath] }
            if ($AllowMissing -and $uri.AbsolutePath -ceq ($gatewayGroup + '/providers/Microsoft.Network/networkSecurityGroups/byok-client-access-isolation')) { return $null }
            throw 'Collector requested an unexpected fixture resource.'
        }
        $accepted = $false
        try {
            $collected = Read-PrivateClientSnapshot $fixture.vm.id $fixture.gateway.id 'fixture-cache' 'AzureUSGovernment'
            $null = New-PrivateClientAccessCandidate $collected
            $accepted = $true
        } catch { if ($case -cin @('single-page','paginated')) { throw } }
        if ($accepted -ne ($case -cin @('single-page','paginated'))) { throw ('Collector pagination/context gate failed: ' + $case) }
        if ($case -ceq 'paginated' -and $collected.dnsRecords.value.Count -ne 1) { throw 'Collector dropped a pagination result.' }
        if (@($requests | Where-Object {([uri]$_).DnsSafeHost -cne 'management.usgovcloudapi.net'}).Count) { throw 'Collector forwarded authentication to another host.' }
    }
    $checks++
}
$receipt = Get-PrivateClientAccessDigest $candidate @{source = 'fixture'}
foreach ($case in @('same','key-order','capture-time','etag','ip','template')) {
    $snapshot = $fixture | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
    $artifact = @{source = 'fixture'}
    switch ($case) {
        'key-order' { $reordered = [ordered]@{};foreach ($key in @($snapshot.Keys | Sort-Object -Descending)) {$reordered[$key] = $snapshot[$key]};$snapshot = $reordered }
        'capture-time' { $snapshot.capturedAt = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o') }
        'etag' { $snapshot.clientNsg.etag = 'another-etag' }
        'ip' { $snapshot.nic.properties.ipConfigurations[0].properties.privateIPAddress = [Net.IPAddress]::new([byte[]]@(10,81,3,5)).ToString() }
        'template' { $artifact.source = 'changed' }
    }
    $digest = Get-PrivateClientAccessDigest (New-PrivateClientAccessCandidate $snapshot) $artifact
    if ($digest -cnotmatch '\A[0-9a-f]{64}\z' -or ($digest -ceq $receipt) -ne ($case -cin @('same','key-order','capture-time'))) { throw ('Snapshot digest binding failed: ' + $case) }
    $checks++
}
foreach ($case in @('valid','diagnostic','missing','duplicate','delete','unapproved','ignored-expected','widened-port','transit','lost-outbound-setting','extra-ignore','unreviewed-route','unreviewed-inline-rule','approved-inline-rules','changed-inline-rule','extra-inline-property','omitted-empty-delegations','null-empty-delegations','omitted-populated-delegations','malformed-delegations')) {
    $preview = @{status = 'Succeeded';changes = @(foreach ($id in $candidate.expectedResources.Keys) {
        @{resourceId = $id;changeType = $candidate.expectedResources[$id].change;after = @{properties = ($candidate.expectedResources[$id].properties | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100)}}
    })}
    if ($case -cin @('approved-inline-rules','changed-inline-rule','extra-inline-property')) {
        $parentId = $gatewayGroup + '/providers/Microsoft.Network/networkSecurityGroups/byok-client-access-isolation'
        $inlineRules = @(foreach ($id in $candidate.expectedResources.Keys) {
            if ($id.StartsWith($parentId + '/securityRules/', [StringComparison]::OrdinalIgnoreCase)) {
                @{name = $id.Split('/')[-1];properties = ($candidate.expectedResources[$id].properties | ConvertTo-Json | ConvertFrom-Json -AsHashtable)}
            }
        })
        if ($case -ceq 'changed-inline-rule') { $inlineRules[0].properties.access = 'Allow' }
        if ($case -ceq 'extra-inline-property') { $inlineRules[0].properties.sourceAddressPrefixes = @('*') }
        ($preview.changes | Where-Object {$_.resourceId -ieq $parentId}).after.properties.securityRules = $inlineRules
    }
    switch ($case) {
        'diagnostic' { $preview.diagnostics = @(@{message = 'fixture'}) }
        'missing' { $preview.changes = @($preview.changes | Select-Object -Skip 1) }
        'duplicate' { $preview.changes += $preview.changes[0] }
        'delete' { $preview.changes[0].changeType = 'Delete' }
        'unapproved' { $preview.changes += @{resourceId = $nicId;changeType = 'Modify';after = @{properties = @{}}} }
        'ignored-expected' { $preview.changes[0].changeType = 'Ignore' }
        'widened-port' { ($preview.changes | Where-Object {$_.resourceId -ieq ($clientNsgId + '/securityRules/byok-client-access-https')}).after.properties.destinationPortRange = '*' }
        'transit' { ($preview.changes | Where-Object {$_.resourceId -ieq ($clientVnetId + '/virtualNetworkPeerings/byok-client-access-to-gateway')}).after.properties.allowGatewayTransit = $true }
        'lost-outbound-setting' { ($preview.changes | Where-Object {$_.resourceId -ieq ($gatewayVnetId + '/subnets/snet-pe')}).after.properties.Remove('defaultOutboundAccess') }
        'extra-ignore' { $preview.changes += @{resourceId = $nicId;changeType = 'Ignore'} }
        'unreviewed-route' { ($preview.changes | Where-Object {$_.resourceId -ieq ($gatewayVnetId + '/subnets/snet-pe')}).after.properties.routeTable = @{id = 'unreviewed'} }
        'unreviewed-inline-rule' { ($preview.changes | Where-Object {$_.resourceId -ieq ($gatewayGroup + '/providers/Microsoft.Network/networkSecurityGroups/byok-client-access-isolation')}).after.properties.securityRules = @(@{name = 'unreviewed'}) }
        'omitted-empty-delegations' { ($preview.changes | Where-Object {$_.resourceId -ieq ($gatewayVnetId + '/subnets/snet-pe')}).after.properties.Remove('delegations') }
        'null-empty-delegations' { ($preview.changes | Where-Object {$_.resourceId -ieq ($gatewayVnetId + '/subnets/snet-pe')}).after.properties.delegations = $null }
        'omitted-populated-delegations' { ($preview.changes | Where-Object {$_.resourceId -ieq ($gatewayVnetId + '/subnets/snet-runner')}).after.properties.Remove('delegations') }
        'malformed-delegations' { ($preview.changes | Where-Object {$_.resourceId -ieq ($gatewayVnetId + '/subnets/snet-pe')}).after.properties.delegations = @{} }
    }
    $accepted = $false
    try { $null = Test-PrivateClientAccessWhatIf $preview $candidate;$accepted = $true } catch {}
    if ($accepted -ne ($case -cin @('valid','extra-ignore','approved-inline-rules','omitted-empty-delegations','null-empty-delegations'))) { throw ('Private-access what-if gate failed: ' + $case) }
    $checks++
}
$compiler = Get-Command bicep -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$compilerPath = if ($compiler) { $compiler.Source } elseif (Test-Path "$HOME/.azure/bin/bicep.exe") { "$HOME/.azure/bin/bicep.exe" } else { throw 'Bicep is required for private-access preview tests.' }
$compiledPath = Join-Path ([IO.Path]::GetTempPath()) ('private-client-access-tests-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    & $compilerPath build (Join-Path $PSScriptRoot '../../infra/modules/private-client-access-preview.bicep') --outfile $compiledPath
    if ($LASTEXITCODE -ne 0) { throw 'Private-access Bicep preview does not compile.' }
    $template = Get-Content -LiteralPath $compiledPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $modules = if ($template.resources -is [Collections.IDictionary]) { @($template.resources.Values) } else { @($template.resources) }
    if ($modules.Count -ne 2 -or @($modules | Where-Object type -CNE 'Microsoft.Resources/deployments').Count) { throw 'Preview must reference exactly two existing resource groups.' }
    foreach ($module in $modules) {
        $children = $module.properties.template.resources
        $resources = if ($children -is [Collections.IDictionary]) { @($children.Values) } else { @($children) }
        $writes = @($resources | Where-Object {$_.existing -ne $true})
        $nsgs = @($writes | Where-Object type -CEQ 'Microsoft.Network/networkSecurityGroups')
        if ($nsgs.Count -ne 1 -or $nsgs[0].name -cne "[parameters('configuration').isolationNsgName]") { throw 'Preview must not recreate existing NSGs.' }
        $peering = @($writes | Where-Object type -CEQ 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings')[0]
        $subnets = @($writes | Where-Object type -CEQ 'Microsoft.Network/virtualNetworks/subnets')[0]
        $dnsRecord = @($writes | Where-Object type -CEQ 'Microsoft.Network/privateDnsZones/A')[0]
        if ($nsgs[0].condition -cne "[equals(parameters('side'), 'gateway')]" -or $dnsRecord.condition -cne "[equals(parameters('side'), 'client')]") { throw 'Inactive module branches are not disabled.' }
        if ($peering.properties.allowForwardedTraffic -ne $false -or $peering.properties.allowGatewayTransit -ne $false -or $peering.properties.useRemoteGateways -ne $false) { throw 'Preview must not enable forwarding or gateway transit.' }
        if (($peering.dependsOn -join ',') -cne 'boundaryRules,isolatedSubnets' -or
            ($subnets.dependsOn -join ',') -cne 'isolationRules' -or
            $dnsRecord.dependsOn.Count -ne 1 -or $dnsRecord.dependsOn[0] -cne "[resourceId('Microsoft.Network/virtualNetworks/virtualNetworkPeerings', parameters('configuration').virtualNetworkName, parameters('configuration').peeringName)]") { throw 'Isolation must precede connectivity and DNS.' }
        if (@($writes | Where-Object {$_.type -cnotin @('Microsoft.Network/networkSecurityGroups', 'Microsoft.Network/networkSecurityGroups/securityRules', 'Microsoft.Network/virtualNetworks/subnets', 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings', 'Microsoft.Network/privateDnsZones/A')}).Count) { throw 'Unexpected private-access resource type.' }
        $checks++
    }
} finally {
    if (Test-Path -LiteralPath $compiledPath) { Remove-Item -LiteralPath $compiledPath }
}
$snapshotPath = Join-Path ([IO.Path]::GetTempPath()) ('private-client-fixture-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    [IO.File]::WriteAllText($snapshotPath, ($fixture | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
    $output = & pwsh -NoProfile -File $helperPath -SnapshotFile $snapshotPath
    if ($LASTEXITCODE -ne 0) { throw 'Offline private-access CLI failed.' }
    $report = $output | ConvertFrom-Json -AsHashtable
    if ($report.canApply -ne $false -or $report.expectedResources -ne 17 -or $report.providerValidated -ne $false -or
        $report.scopeVerified -ne $false -or $report.modelCalls -ne 0 -or $report.networkWrites -ne 0 -or
        ($output -join '').Contains($subscription) -or ($output -join '').Contains($vmAddress)) { throw 'CLI reported false readiness or leaked snapshot values.' }
    $checks++
    $bash = if ($IsWindows) { Join-Path $env:ProgramFiles 'Git/bin/bash.exe' } else { (Get-Command bash -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source }
    $wrapper = Join-Path $PSScriptRoot '../preview-private-client-access.sh'
    & $bash -n $wrapper
    if ($LASTEXITCODE -ne 0) { throw 'Private-access Bash wrapper does not parse.' }
    $bashOutput = & $bash $wrapper -SnapshotFile $snapshotPath
    if ($LASTEXITCODE -ne 0) { throw 'Private-access Bash wrapper failed.' }
    $bashReport = $bashOutput | ConvertFrom-Json -AsHashtable
    if ($bashReport.candidateDigest -cne $report.candidateDigest -or $bashReport.canApply -ne $false) { throw 'PowerShell and Bash private-access previews differ.' }
    $checks++
    $privateParent = Join-Path ([IO.Path]::GetTempPath()) ('private-manager-test-' + [guid]::NewGuid().ToString('N'))
    $statePath = Join-Path $privateParent 'recovery.json'
    try {
        $managerOutput = & pwsh -NoProfile -File $managerPath -Action Plan -SnapshotFile $snapshotPath -StateFile $statePath -ReviewedCommit $transitionCommit
        if ($LASTEXITCODE -ne 0) {throw 'Offline private-access manager plan failed.'}
        $managerReport = $managerOutput | ConvertFrom-Json -AsHashtable
        if ($managerReport.action -cne 'Plan' -or $managerReport.networkWrites -ne 0 -or $managerReport.expectedResources -ne 17 -or
            ($managerOutput -join '').Contains($subscription)) {throw 'Manager plan claimed execution or leaked identifiers.'}
        $planned = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        Assert-PrivateClientRecoveryState $planned $managerReport.digest $transitionCommit
        $checks++
    } finally {
        if (Test-Path -LiteralPath $privateParent) {Remove-Item -LiteralPath $privateParent -Recurse -Force}
    }
} finally {
    if (Test-Path -LiteralPath $snapshotPath) { Remove-Item -LiteralPath $snapshotPath }
}
if ($SecurityTemplatePath) {
    if (Test-Path -LiteralPath $SecurityTemplatePath) {throw 'Use a new security-template path; existing artifacts are not overwritten.'}
    $scanResources = @(foreach ($id in $candidate.expectedResources.Keys) {
        $segments = $id.Split('/')
        $providerIndex = [array]::IndexOf($segments, 'providers')
        $typeSegments = @($segments[$providerIndex + 1])
        $nameSegments = @()
        for ($index = $providerIndex + 2; $index -lt $segments.Count; $index += 2) {$typeSegments += $segments[$index];$nameSegments += $segments[$index + 1]}
        $resource = @{type = $typeSegments -join '/';name = $nameSegments -join '/';apiVersion = $(if ($id -imatch '/privateDnsZones/') {'2020-06-01'} else {'2024-05-01'});properties = $candidate.expectedResources[$id].properties}
        if ($resource.type -ceq 'Microsoft.Network/networkSecurityGroups') {
            $resource.location = 'usgovvirginia'
            $resource.properties = @{securityRules = @($candidate.parameters.gatewayConfiguration.value.isolationRules)}
        }
        $resource
    })
    $scanTemplate = @{'$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#';contentVersion = '1.0.0.0';resources = $scanResources}
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($SecurityTemplatePath), (ConvertTo-Json -InputObject $scanTemplate -Depth 100), [Text.UTF8Encoding]::new($false))
}
Write-Output "PASS: $checks private client-access scope/rule checks; no Azure calls."
exit 0