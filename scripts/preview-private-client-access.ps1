#requires -Version 7.4
[CmdletBinding(DefaultParameterSetName = 'Snapshot')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Snapshot')][string]$SnapshotFile,
    [Parameter(Mandatory, ParameterSetName = 'Live')][string]$VmResourceId,
    [Parameter(Mandatory, ParameterSetName = 'Live')][string]$GatewayResourceId,
    [Parameter(Mandatory, ParameterSetName = 'Live')][string]$AzureConfigDirectory,
    [Parameter(ParameterSetName = 'Live')][ValidateSet('AzureCloud','AzureUSGovernment')][string]$Cloud = 'AzureUSGovernment',
    [Parameter(ParameterSetName = 'Live')][switch]$ProviderPreview,
    [Parameter(Mandatory, ParameterSetName = 'Definitions')][switch]$DefinitionsOnly
)

$ErrorActionPreference = 'Stop'

function Get-PrivateClientNetwork {
    param([string]$Prefix)
    try { $network = [Net.IPNetwork]::Parse($Prefix) } catch { throw 'Invalid private network prefix.' }
    if ($network.BaseAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $network.ToString() -cne $Prefix) { throw 'Invalid private network prefix.' }
    $octets = $network.BaseAddress.GetAddressBytes()
    $private = ($octets[0] -eq 10 -and $network.PrefixLength -ge 8) -or
        ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31 -and $network.PrefixLength -ge 12) -or
        ($octets[0] -eq 192 -and $octets[1] -eq 168 -and $network.PrefixLength -ge 16)
    if (-not $private) { throw 'Invalid private network prefix.' }
    $network
}

function New-PrivateClientAccessRules {
    param([string]$VmAddress, [string]$GatewayAddress, [string]$ClientPrefix, [string]$GatewayPrefix, [string]$GatewaySubnetPrefix)
    $clientNetwork = Get-PrivateClientNetwork $ClientPrefix
    $gatewayNetwork = Get-PrivateClientNetwork $GatewayPrefix
    $gatewaySubnet = Get-PrivateClientNetwork $GatewaySubnetPrefix
    $vmIp = $null
    $gatewayIp = $null
    if (-not [Net.IPAddress]::TryParse($VmAddress, [ref]$vmIp) -or
        -not [Net.IPAddress]::TryParse($GatewayAddress, [ref]$gatewayIp) -or
        $vmIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $gatewayIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $vmIp.ToString() -cne $VmAddress -or $gatewayIp.ToString() -cne $GatewayAddress -or
        -not $clientNetwork.Contains($vmIp) -or -not $gatewaySubnet.Contains($gatewayIp) -or
        -not $gatewayNetwork.Contains($gatewaySubnet.BaseAddress) -or $gatewaySubnet.PrefixLength -lt $gatewayNetwork.PrefixLength -or
        $clientNetwork.Contains($gatewayNetwork.BaseAddress) -or $gatewayNetwork.Contains($clientNetwork.BaseAddress)) {
        throw 'Client and gateway addresses must belong to distinct private networks.'
    }
    function New-AccessRule {
        param([string]$Name, [int]$Priority, [string]$Direction, [string]$Access, [string]$Protocol, [string]$Source, [string]$Destination, [string]$Port = '*')
        @{name = 'byok-client-access-' + $Name; properties = @{
            priority = $Priority; direction = $Direction; access = $Access; protocol = $Protocol
            sourceAddressPrefix = $Source; sourcePortRange = '*'; destinationAddressPrefix = $Destination; destinationPortRange = $Port
        }}
    }
    @{
        client = @(
            (New-AccessRule 'https' 180 Outbound Allow Tcp ($VmAddress + '/32') ($GatewayAddress + '/32') '443')
            (New-AccessRule 'deny-dev-out' 190 Outbound Deny '*' '*' $GatewayPrefix)
            (New-AccessRule 'deny-dev-in' 190 Inbound Deny '*' $GatewayPrefix '*')
        )
        gateway = @(
            (New-AccessRule 'https' 115 Inbound Allow Tcp ($VmAddress + '/32') $GatewaySubnetPrefix '443')
            (New-AccessRule 'deny-pilot-in' 116 Inbound Deny '*' $ClientPrefix '*')
            (New-AccessRule 'deny-pilot-out' 190 Outbound Deny '*' '*' $ClientPrefix)
        )
        isolation = @(
            (New-AccessRule 'deny-pilot-in' 100 Inbound Deny '*' $ClientPrefix '*')
            (New-AccessRule 'deny-pilot-out' 100 Outbound Deny '*' '*' $ClientPrefix)
        )
    }
}

function Get-PrivateClientResourceParts {
    param([string]$Id, [string]$Type, [string]$SubscriptionId)
    $parts = $Id.Split('/')
    $typeParts = $Type.Split('/')
    if ($parts.Count -ne (7 + 2 * ($typeParts.Count - 1)) -or $parts[0] -cne '' -or
        $parts[1] -ine 'subscriptions' -or $parts[2] -ine $SubscriptionId -or $parts[3] -ine 'resourceGroups' -or
        $parts[5] -ine 'providers' -or $parts[6] -ine $typeParts[0] -or
        $parts[4] -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_().-]{0,89}\z') { throw 'Invalid scoped resource reference.' }
    for ($index = 1; $index -lt $typeParts.Count; $index++) {
        if ($parts[5 + 2 * $index] -ine $typeParts[$index] -or $parts[6 + 2 * $index] -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_.-]{0,79}\z') {
            throw 'Invalid scoped resource reference.'
        }
    }
    @{group = $parts[4];name = $parts[-1];groupId = '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $parts[4]}
}

function Assert-PrivateClientResource {
    param($Resource, [string]$Type, [string]$SubscriptionId)
    if ($Resource -isnot [Collections.IDictionary] -or $Resource.type -ine $Type -or
        $Resource.properties -isnot [Collections.IDictionary]) { throw 'Incomplete resource snapshot.' }
    Get-PrivateClientResourceParts $Resource.id $Type $SubscriptionId
}

function Get-PrivateClientSubnetProperties {
    param($Subnet, [bool]$EnablePrivateEndpointPolicies = $false)
    $writable = @('addressPrefix','addressPrefixes','defaultOutboundAccess','delegations','natGateway','networkSecurityGroup',
        'privateEndpointNetworkPolicies','privateLinkServiceNetworkPolicies','routeTable','serviceEndpointPolicies','serviceEndpoints','sharingScope')
    $readOnly = @('provisioningState','ipConfigurations','privateEndpoints','resourceNavigationLinks','serviceAssociationLinks','purpose')
    $properties = $Subnet.properties
    if ($properties -isnot [Collections.IDictionary] -or @($properties.Keys | Where-Object {$_ -cnotin ($writable + $readOnly)}).Count -or
        $properties.provisioningState -cne 'Succeeded' -or [string]::IsNullOrWhiteSpace($Subnet.etag)) { throw 'Unsupported or incomplete subnet snapshot.' }
    if ($properties.networkSecurityGroup -or $properties.routeTable) { throw 'Existing subnet security or routes require separate review.' }
    $copy = @{}
    foreach ($name in $writable) {
        if ($properties.Contains($name)) {
            $json = ConvertTo-Json -InputObject $properties[$name] -Depth 100 -Compress
            $copy[$name] = ConvertFrom-Json -InputObject $json -AsHashtable -Depth 100 -NoEnumerate
        }
    }
    if ($copy.Contains('defaultOutboundAccess') -and $copy.defaultOutboundAccess -isnot [bool]) { throw 'Invalid immutable outbound setting.' }
    if ($copy.privateEndpointNetworkPolicies -cnotin @('Disabled','Enabled','NetworkSecurityGroupEnabled','RouteTableEnabled') -or
        $copy.privateLinkServiceNetworkPolicies -cnotin @('Disabled','Enabled')) { throw 'Explicit subnet policy state is required.' }
    if ($copy.Contains('delegations')) {
        if ($copy.delegations -isnot [array]) { throw 'Incomplete subnet delegation inventory.' }
        $copy.delegations = @(foreach ($delegation in $copy.delegations) {
            if (@($delegation.Keys | Where-Object {$_ -cnotin @('id','name','type','etag','properties')}).Count -or
                @($delegation.properties.Keys | Where-Object {$_ -cnotin @('serviceName','actions','provisioningState')}).Count -or
                $delegation.name -cnotmatch '\A[A-Za-z0-9_.-]{1,80}\z' -or
                $delegation.properties.serviceName -cnotin @('Microsoft.Network/dnsResolvers','Microsoft.App/environments','Microsoft.ContainerInstance/containerGroups')) {
                throw 'Unsupported subnet delegation.'
            }
            @{name = $delegation.name;properties = @{serviceName = $delegation.properties.serviceName}}
        })
    }
    if ($copy.Contains('serviceEndpoints')) {
        if ($copy.serviceEndpoints -isnot [array]) { throw 'Incomplete service endpoint inventory.' }
        $copy.serviceEndpoints = @(foreach ($endpoint in $copy.serviceEndpoints) {
            if (@($endpoint.Keys | Where-Object {$_ -cnotin @('service','locations','networkIdentifier','provisioningState')}).Count) { throw 'Unsupported service endpoint property.' }
            $endpoint.Remove('provisioningState') | Out-Null
            $endpoint
        })
    }
    foreach ($name in @('natGateway','routeTable','networkSecurityGroup')) {
        if ($copy[$name] -and ($copy[$name] -isnot [Collections.IDictionary] -or $copy[$name].Count -ne 1 -or -not $copy[$name].Contains('id'))) {
            throw 'Embedded resource replacement is not allowed.'
        }
    }
    foreach ($policy in @($copy.serviceEndpointPolicies | Where-Object {$null -ne $_})) {
        if ($policy -isnot [Collections.IDictionary] -or $policy.Count -ne 1 -or -not $policy.Contains('id')) { throw 'Embedded service endpoint policy replacement is not allowed.' }
    }
    if ($EnablePrivateEndpointPolicies) {
        $copy.privateEndpointNetworkPolicies = switch ($copy.privateEndpointNetworkPolicies) {
            'Disabled' { 'NetworkSecurityGroupEnabled' }
            'RouteTableEnabled' { 'Enabled' }
            default { $copy.privateEndpointNetworkPolicies }
        }
    } elseif (@($properties.privateEndpoints | Where-Object {$null -ne $_}).Count) {
        throw 'Private endpoints outside the reviewed PE subnet require separate approval.'
    }
    $copy
}

function Assert-PrivateClientNsgRules {
    param($Nsg, [object[]]$Proposed, [bool]$Gateway)
    if ([string]::IsNullOrWhiteSpace($Nsg.etag) -or $Nsg.properties.provisioningState -cne 'Succeeded' -or
        $Nsg.properties.securityRules -isnot [array] -or $Nsg.properties.defaultSecurityRules -isnot [array] -or
        @($Nsg.properties.networkInterfaces | Where-Object {$null -ne $_}).Count) { throw 'Incomplete or shared NSG snapshot.' }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $priorities = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($rule in $Nsg.properties.securityRules + $Nsg.properties.defaultSecurityRules) {
        $properties = $rule.properties
        if (-not $names.Add([string]$rule.name) -or $rule.name -ilike 'byok-client-access-*' -or
            $properties.direction -cnotin @('Inbound','Outbound') -or $properties.priority -isnot [long] -and $properties.priority -isnot [int] -or
            -not $priorities.Add($properties.direction + ':' + $properties.priority) -or
            @($properties.sourceApplicationSecurityGroups | Where-Object {$null -ne $_}).Count -or
            @($properties.destinationApplicationSecurityGroups | Where-Object {$null -ne $_}).Count) { throw 'Ambiguous or unsupported NSG rules.' }
        $threshold = if ($Gateway -and $properties.direction -ceq 'Inbound') { 116 } else { 190 }
        if ($properties.priority -lt $threshold) {
            $platformRule = $Gateway -and $properties.direction -ceq 'Inbound' -and $properties.access -ceq 'Allow' -and
                $properties.protocol -ceq 'Tcp' -and $properties.sourcePortRange -ceq '*' -and $properties.destinationAddressPrefix -ceq 'VirtualNetwork' -and
                (($properties.priority -eq 100 -and $properties.sourceAddressPrefix -ceq 'ApiManagement' -and $properties.destinationPortRange -ceq '3443') -or
                 ($properties.priority -eq 110 -and $properties.sourceAddressPrefix -ceq 'AzureLoadBalancer' -and $properties.destinationPortRange -ceq '6390'))
            if (-not $platformRule -or @($properties.sourceAddressPrefixes + $properties.destinationAddressPrefixes + $properties.sourcePortRanges + $properties.destinationPortRanges | Where-Object {$_}).Count) {
                throw 'An existing NSG rule can precede the isolation boundary.'
            }
        }
    }
    foreach ($rule in $Proposed) {
        if ($names.Contains($rule.name) -or $priorities.Contains($rule.properties.direction + ':' + $rule.properties.priority)) { throw 'Client-access rule name or priority collision.' }
    }
}

function New-PrivateClientAccessCandidate {
    param($Snapshot)
    $subscription = [guid]::Empty
    if ($Snapshot.version -cne 'private-client-access-v1' -or $Snapshot.cloud -cnotin @('AzureCloud','AzureUSGovernment') -or
        -not [guid]::TryParse([string]$Snapshot.subscriptionId, [ref]$subscription) -or $subscription -eq [guid]::Empty) { throw 'Invalid client-access snapshot.' }
    $subscriptionId = $subscription.ToString()
    try { $age = [DateTimeOffset]::UtcNow - [DateTimeOffset]$Snapshot.capturedAt } catch { throw 'Snapshot timestamp is missing.' }
    if ($age.TotalMinutes -gt 15 -or $age.TotalMinutes -lt -2) { throw 'Client-access snapshot is stale.' }
    $types = @{vm = 'Microsoft.Compute/virtualMachines';nic = 'Microsoft.Network/networkInterfaces';clientVnet = 'Microsoft.Network/virtualNetworks';gatewayVnet = 'Microsoft.Network/virtualNetworks';gateway = 'Microsoft.ApiManagement/service';clientNsg = 'Microsoft.Network/networkSecurityGroups';gatewayNsg = 'Microsoft.Network/networkSecurityGroups';dnsZone = 'Microsoft.Network/privateDnsZones'}
    $parts = @{}
    foreach ($name in $types.Keys) { $parts[$name] = Assert-PrivateClientResource $Snapshot[$name] $types[$name] $subscriptionId }
    $clientGroup = $parts.clientVnet.group
    $gatewayGroup = $parts.gatewayVnet.group
    if ($clientGroup -ieq $gatewayGroup -or $parts.vm.group -ine $clientGroup -or $parts.nic.group -ine $clientGroup -or
        $parts.clientNsg.group -ine $clientGroup -or $parts.dnsZone.group -ine $clientGroup -or
        $parts.gateway.group -ine $gatewayGroup -or $parts.gatewayNsg.group -ine $gatewayGroup -or
        $Snapshot.clientVnet.location -ine $Snapshot.gatewayVnet.location -or
        ([string]$Snapshot.gateway.location).Replace(' ', '') -ine ([string]$Snapshot.gatewayVnet.location).Replace(' ', '') -or
        $Snapshot.vm.properties.storageProfile.osDisk.osType -cne 'Windows' -or
        $Snapshot.vm.properties.provisioningState -cne 'Succeeded' -or $Snapshot.gateway.properties.provisioningState -cne 'Succeeded' -or
        $Snapshot.gateway.properties.virtualNetworkType -cne 'Internal' -or $Snapshot.nic.properties.networkSecurityGroup -or
        $Snapshot.nic.properties.enableIPForwarding -ne $false -or
        @($Snapshot.vm.properties.networkProfile.networkInterfaces).Count -ne 1 -or
        $Snapshot.vm.properties.networkProfile.networkInterfaces[0].id -ine $Snapshot.nic.id -or @($Snapshot.nic.properties.ipConfigurations).Count -ne 1) {
        throw 'The captured topology differs from the isolated client design.'
    }
    foreach ($name in @('clientPeerings','gatewayPeerings','dnsLinks','dnsRecords')) {
        if ($Snapshot[$name].value -isnot [array] -or $Snapshot[$name].nextLink) { throw 'Incomplete client-access inventory.' }
    }
    if ($Snapshot.clientPeerings.value.Count -or $Snapshot.gatewayPeerings.value.Count -or $Snapshot.isolationNsgAbsent -isnot [bool] -or -not $Snapshot.isolationNsgAbsent) {
        throw 'Existing connectivity or isolation resources require reconciliation.'
    }
    $configuration = $Snapshot.nic.properties.ipConfigurations[0].properties
    if ($configuration.publicIPAddress -or $configuration.privateIPAddressVersion -cne 'IPv4') { throw 'The selected VM must remain private IPv4-only.' }
    $vmSubnetId = $configuration.subnet.id
    $gatewaySubnetId = $Snapshot.gateway.properties.virtualNetworkConfiguration.subnetResourceId
    $subnetSets = @{}
    foreach ($side in @('client','gateway')) {
        $vnet = $Snapshot[$side + 'Vnet']
        if ($vnet.properties.provisioningState -cne 'Succeeded' -or [string]::IsNullOrWhiteSpace($vnet.etag) -or
            $vnet.properties.subnets -isnot [array] -or @($vnet.properties.addressSpace.addressPrefixes).Count -ne 1 -or
            @($vnet.properties.virtualNetworkPeerings | Where-Object {$null -ne $_}).Count) { throw 'Unsupported VNet snapshot.' }
        $subnetSets[$side] = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        $vnetNetwork = Get-PrivateClientNetwork $vnet.properties.addressSpace.addressPrefixes[0]
        foreach ($subnet in $vnet.properties.subnets) {
            $subnetParts = Get-PrivateClientResourceParts $subnet.id 'Microsoft.Network/virtualNetworks/subnets' $subscriptionId
            if ($subnet.id -ine ($vnet.id + '/subnets/' + $subnetParts.name) -or $subnet.properties.routeTable -or
                $subnet.properties.provisioningState -cne 'Succeeded' -or [string]::IsNullOrWhiteSpace($subnet.etag)) { throw 'Incomplete or routed subnet snapshot.' }
            $prefixes = @(@($subnet.properties.addressPrefix) + @($subnet.properties.addressPrefixes) | Where-Object {$_})
            if ($prefixes.Count -ne 1) { throw 'Exactly one IPv4 prefix per subnet is required.' }
            $subnetNetwork = Get-PrivateClientNetwork $prefixes[0]
            if (-not $vnetNetwork.Contains($subnetNetwork.BaseAddress) -or $subnetNetwork.PrefixLength -lt $vnetNetwork.PrefixLength -or
                -not $subnetSets[$side].TryAdd($subnetParts.name, $subnet)) { throw 'Invalid or duplicate subnet boundary.' }
        }
    }
    $vmSubnets = @($subnetSets.client.Values | Where-Object {$_.id -ieq $vmSubnetId})
    $gatewaySubnets = @($subnetSets.gateway.Values | Where-Object {$_.id -ieq $gatewaySubnetId})
    $expectedSubnets = @('snet-apim','snet-pe','snet-dns-in','snet-runner','snet-aci','snet-cae-register')
    if ($vmSubnets.Count -ne 1 -or $gatewaySubnets.Count -ne 1 -or $gatewaySubnets[0].name -cne 'snet-apim' -or
        @(Compare-Object ($expectedSubnets | Sort-Object) @($subnetSets.gateway.Keys | Sort-Object)).Count -or
        $vmSubnets[0].properties.networkSecurityGroup.id -ine $Snapshot.clientNsg.id -or
        $gatewaySubnets[0].properties.networkSecurityGroup.id -ine $Snapshot.gatewayNsg.id -or @($Snapshot.gateway.properties.privateIPAddresses).Count -ne 1) {
        throw 'The selected VM/gateway or complete dev subnet coverage changed.'
    }
    $networkValues = @{VmAddress = $configuration.privateIPAddress;GatewayAddress = $Snapshot.gateway.properties.privateIPAddresses[0];ClientPrefix = $Snapshot.clientVnet.properties.addressSpace.addressPrefixes[0];GatewayPrefix = $Snapshot.gatewayVnet.properties.addressSpace.addressPrefixes[0];GatewaySubnetPrefix = $gatewaySubnets[0].properties.addressPrefix}
    if (-not (Get-PrivateClientNetwork $vmSubnets[0].properties.addressPrefix).Contains([Net.IPAddress]::Parse($networkValues.VmAddress))) { throw 'VM address is outside its selected subnet.' }
    $rules = New-PrivateClientAccessRules @networkValues
    foreach ($side in @('client','gateway')) {
        $nsg = $Snapshot[$side + 'Nsg']
        $expectedSubnetId = if ($side -ceq 'client') { $vmSubnetId } else { $gatewaySubnetId }
        if (@($nsg.properties.subnets).Count -ne 1 -or $nsg.properties.subnets[0].id -ine $expectedSubnetId) { throw 'A participating NSG is shared outside the selected subnet.' }
        Assert-PrivateClientNsgRules $nsg $rules[$side] ($side -ceq 'gateway')
    }
    $zoneName = if ($Snapshot.cloud -ceq 'AzureUSGovernment') { 'azure-api.us' } else { 'azure-api.net' }
    $gatewayUrl = $null
    if (-not [uri]::TryCreate([string]$Snapshot.gateway.properties.gatewayUrl, [UriKind]::Absolute, [ref]$gatewayUrl) -or
        $gatewayUrl.Scheme -cne 'https' -or $gatewayUrl.Port -ne 443 -or $gatewayUrl.UserInfo -or $gatewayUrl.Query -or $gatewayUrl.Fragment -or
        $gatewayUrl.AbsolutePath -cne '/' -or $parts.dnsZone.name -cne $zoneName -or
        -not $gatewayUrl.DnsSafeHost.EndsWith('.' + $zoneName, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected gateway DNS contract.' }
    $recordName = $gatewayUrl.DnsSafeHost.Substring(0, $gatewayUrl.DnsSafeHost.Length - $zoneName.Length - 1)
    if ($recordName -cnotmatch '\A[a-z0-9][a-z0-9-]{0,79}\z' -or $Snapshot.dnsLinks.value.Count -ne 1 -or
        $Snapshot.dnsLinks.value[0].properties.virtualNetwork.id -ine $Snapshot.clientVnet.id -or
        @($Snapshot.dnsRecords.value | Where-Object {$_.name -ieq $recordName -or $_.name -ceq '*'}).Count) { throw 'Existing DNS records or links require separate review.' }
    $isolationName = 'byok-client-access-isolation'
    $isolationId = $parts.gatewayVnet.groupId + '/providers/Microsoft.Network/networkSecurityGroups/' + $isolationName
    $subnetUpdates = @(foreach ($name in $expectedSubnets | Where-Object {$_ -cne 'snet-apim'}) {
        @{name = $name;properties = (Get-PrivateClientSubnetProperties $subnetSets.gateway[$name] ($name -ceq 'snet-pe'))}
    })
    $client = @{location = $Snapshot.clientVnet.location;virtualNetworkName = $parts.clientVnet.name;networkSecurityGroupName = $parts.clientNsg.name;rules = $rules.client;isolationNsgName = $isolationName;isolationRules = @();subnets = @();peeringName = 'byok-client-access-to-gateway';remoteVirtualNetworkId = $Snapshot.gatewayVnet.id;dnsZoneName = $zoneName;dnsRecordName = $recordName;gatewayAddress = $networkValues.GatewayAddress}
    $gateway = @{location = $Snapshot.gatewayVnet.location;virtualNetworkName = $parts.gatewayVnet.name;networkSecurityGroupName = $parts.gatewayNsg.name;rules = $rules.gateway;isolationNsgName = $isolationName;isolationRules = $rules.isolation;subnets = $subnetUpdates;peeringName = 'byok-client-access-to-client';remoteVirtualNetworkId = $Snapshot.clientVnet.id;dnsZoneName = $zoneName;dnsRecordName = $recordName;gatewayAddress = $networkValues.GatewayAddress}
    $expected = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($side in @('client','gateway')) {
        foreach ($rule in $rules[$side]) { $expected.Add($Snapshot[$side + 'Nsg'].id + '/securityRules/' + $rule.name, @{change = 'Create';properties = $rule.properties}) }
        $sideConfig = if ($side -ceq 'client') { $client } else { $gateway }
        $expected.Add($Snapshot[$side + 'Vnet'].id + '/virtualNetworkPeerings/' + $sideConfig.peeringName, @{change = 'Create';properties = @{remoteVirtualNetwork = @{id = $sideConfig.remoteVirtualNetworkId};allowVirtualNetworkAccess = $true;allowForwardedTraffic = $false;allowGatewayTransit = $false;useRemoteGateways = $false}})
    }
    $expected.Add($isolationId, @{change = 'Create';properties = @{}})
    foreach ($rule in $rules.isolation) { $expected.Add($isolationId + '/securityRules/' + $rule.name, @{change = 'Create';properties = $rule.properties}) }
    foreach ($subnet in $subnetUpdates) {
        $properties = $subnet.properties.Clone()
        $properties.networkSecurityGroup = @{id = $isolationId}
        $expected.Add($Snapshot.gatewayVnet.id + '/subnets/' + $subnet.name, @{change = 'Modify';properties = $properties})
    }
    $expected.Add($Snapshot.dnsZone.id + '/A/' + $recordName, @{change = 'Create';properties = @{ttl = 60;aRecords = @(@{ipv4Address = $networkValues.GatewayAddress})}})
    @{parameters = @{clientResourceGroup = @{value = $clientGroup};gatewayResourceGroup = @{value = $gatewayGroup};clientConfiguration = @{value = $client};gatewayConfiguration = @{value = $gateway}};expectedResources = $expected;baseline = $Snapshot;canApply = $false;blockers = @('merged-lifecycle-guards-and-idle-jobs-required','effective-policy-and-delegation-review','live-isolation-acceptance','network-apply-approval')}
}

function Get-PrivateClientAccessDigest {
    param($Candidate, $Artifact)
    function Convert-OrderedPrivateValue {
        param($Value)
        if ($Value -is [Collections.IDictionary]) {
            $ordered = [ordered]@{}
            [string[]]$keys = @($Value.Keys)
            [Array]::Sort($keys, [StringComparer]::Ordinal)
            foreach ($key in $keys) { $ordered[$key] = Convert-OrderedPrivateValue $Value[$key] }
            return $ordered
        }
        if ($Value -is [array]) { return ,@(foreach ($item in $Value) { Convert-OrderedPrivateValue $item }) }
        $Value
    }
    $baseline = @{}
    foreach ($key in $Candidate.baseline.Keys) {
        if ($key -cne 'capturedAt') { $baseline[$key] = $Candidate.baseline[$key] }
    }
    $document = Convert-OrderedPrivateValue @{version = 'private-client-access-v1';baseline = $baseline;parameters = $Candidate.parameters;expectedResources = $Candidate.expectedResources;artifact = $Artifact}
    $json = ConvertTo-Json -InputObject $document -Depth 100 -Compress
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}

function Test-PrivateClientExpectedProperties {
    param($Expected, $Actual)
    if ($Expected -is [Collections.IDictionary]) {
        if ($Actual -isnot [Collections.IDictionary]) { return $false }
        foreach ($key in $Expected.Keys) {
            if (-not $Actual.Contains($key)) { return $false }
            if ($key -ceq 'id' -and $Expected[$key] -is [string]) {
                if ($Actual[$key] -isnot [string] -or $Expected[$key] -ine $Actual[$key]) { return $false }
            } elseif (-not (Test-PrivateClientExpectedProperties $Expected[$key] $Actual[$key])) { return $false }
        }
        return $true
    }
    if ($Expected -is [array]) {
        if ($Actual -isnot [array] -or $Expected.Count -ne $Actual.Count) { return $false }
        for ($index = 0; $index -lt $Expected.Count; $index++) {
            if (-not (Test-PrivateClientExpectedProperties $Expected[$index] $Actual[$index])) { return $false }
        }
        return $true
    }
    if ($null -eq $Expected) { return $null -eq $Actual }
    if ($Expected -is [bool]) { return $Actual -is [bool] -and $Expected -eq $Actual }
    if ($Expected -is [string]) { return $Actual -is [string] -and $Expected -ceq $Actual }
    if ($Expected -is [int] -or $Expected -is [long]) { return ($Actual -is [int] -or $Actual -is [long]) -and $Expected -eq $Actual }
    $false
}

function Test-PrivateClientAccessWhatIf {
    param($Preview, $Candidate)
    if ($Preview.status -cne 'Succeeded' -or $Preview.changes -isnot [array] -or
        @($Preview.diagnostics | Where-Object {$null -ne $_}).Count) { throw 'Incomplete or failed private-access what-if.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $ignored = 0
    foreach ($change in $Preview.changes) {
        if ([string]::IsNullOrWhiteSpace($change.resourceId) -or -not $seen.Add($change.resourceId)) { throw 'Ambiguous private-access what-if resource.' }
        if (-not $Candidate.expectedResources.ContainsKey($change.resourceId)) {
            if ($change.changeType -cne 'Ignore') { throw 'Private-access preview writes an unapproved resource.' }
            $ignored++
            continue
        }
        $expected = $Candidate.expectedResources[$change.resourceId]
        $actualProperties = $change.after.properties
        $readOnlyProperties = @('provisioningState','resourceGuid')
        if ($change.resourceId -imatch '/virtualNetworks/[^/]+/subnets/[^/]+$') {
            $readOnlyProperties += @('ipConfigurations','privateEndpoints','resourceNavigationLinks','serviceAssociationLinks','purpose')
            if ($actualProperties -is [Collections.IDictionary] -and $expected.properties.delegations -is [array] -and
                $expected.properties.delegations.Count -eq 0 -and $null -eq $actualProperties.delegations) {
                $actualProperties = $actualProperties.Clone()
                $actualProperties.delegations = @()
            }
        } elseif ($change.resourceId -imatch '/virtualNetworkPeerings/[^/]+$') {
            $readOnlyProperties += @('peeringState','peeringSyncLevel','remoteAddressSpace','remoteVirtualNetworkAddressSpace','remoteBgpCommunities')
        } elseif ($change.resourceId -imatch '/networkSecurityGroups/[^/]+$') {
            $readOnlyProperties += @('defaultSecurityRules','networkInterfaces','subnets')
            if ($change.after.properties.Contains('securityRules')) {
                $expectedRules = @(foreach ($id in $Candidate.expectedResources.Keys) {
                    if ($id.StartsWith($change.resourceId + '/securityRules/', [StringComparison]::OrdinalIgnoreCase)) {
                        @{name = $id.Split('/')[-1];properties = $Candidate.expectedResources[$id].properties}
                    }
                })
                $actualRules = $change.after.properties.securityRules
                if ($actualRules -isnot [array] -or $expectedRules.Count -ne 2 -or
                    -not (Test-PrivateClientExpectedProperties @($expectedRules | Sort-Object name) @($actualRules | Sort-Object name))) {
                    throw 'Private-access preview differs from the preserving candidate.'
                }
                foreach ($rule in $actualRules) {
                    $expectedRule = @($expectedRules | Where-Object name -CEQ $rule.name)
                    if ($expectedRule.Count -ne 1 -or @($rule.properties.Keys | Where-Object {$_ -cne 'provisioningState' -and -not $expectedRule[0].properties.Contains($_)}).Count) {
                        throw 'Private-access preview added an unreviewed writable property.'
                    }
                }
                $readOnlyProperties += 'securityRules'
            }
        } elseif ($change.resourceId -imatch '/privateDnsZones/[^/]+/A/[^/]+$') {
            $readOnlyProperties += @('fqdn','isAutoRegistered')
        }
        $extraProperties = @($actualProperties.Keys | Where-Object {$_ -cnotin $readOnlyProperties -and -not $expected.properties.Contains($_)})
        if ($change.changeType -cne $expected.change -or -not (Test-PrivateClientExpectedProperties $expected.properties $actualProperties)) {
            throw 'Private-access preview differs from the preserving candidate.'
        }
        if ($extraProperties.Count) { throw 'Private-access preview added an unreviewed writable property.' }
    }
    foreach ($id in $Candidate.expectedResources.Keys) {
        if (-not $seen.Contains($id)) { throw 'Private-access what-if omitted an expected resource.' }
    }
    @{expectedResources = $Candidate.expectedResources.Count;creates = 12;modifies = 5;ignored = $ignored;diagnostics = 0;scopeVerified = $true}
}

function Assert-PrivateClientReadOnlyCommand {
    param([string[]]$Arguments)
    $prefix = (@($Arguments | Select-Object -First 3) -join ' ')
    $allowed = $prefix -cmatch '\A(?:account show|cloud show)(?: |$)' -or
        $prefix -cmatch '\Adeployment sub (?:validate|what-if)\z'
    if ($Arguments.Count -gt 2 -and $Arguments[0] -ceq 'rest') {
        $methodIndex = [array]::IndexOf($Arguments, '--method')
        $allowed = $methodIndex -ge 0 -and $methodIndex + 1 -lt $Arguments.Count -and $Arguments[$methodIndex + 1] -ceq 'GET' -and
            @($Arguments | Where-Object {$_ -ceq '--method'}).Count -eq 1 -and
            -not @($Arguments | Where-Object {$_ -cmatch '\A(?:-m|--method=)'}).Count
    }
    if (-not $allowed -or @($Arguments | Where-Object {$_ -cmatch '\A--(?:debug|verbose|body)(?:=|$)'}).Count) { throw 'Only read-only Azure commands are permitted.' }
}

function Invoke-PrivateClientProcess {
    param([string]$Executable, [string[]]$Arguments, [string]$ConfigDirectory = '')
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardInput = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    if ($ConfigDirectory) {
        $start.Environment['AZURE_CONFIG_DIR'] = $ConfigDirectory
        $start.Environment['PYTHONIOENCODING'] = 'utf-8'
    }
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Close()
        $process.WaitForExit()
        @{exitCode = $process.ExitCode;stdout = $stdout.GetAwaiter().GetResult();stderr = $stderr.GetAwaiter().GetResult()}
    } finally { $process.Dispose() }
}

function Invoke-PrivateClientAzure {
    param([string[]]$Arguments, [string]$ConfigDirectory, [switch]$AllowMissing)
    Assert-PrivateClientReadOnlyCommand $Arguments
    if (-not [IO.Path]::IsPathFullyQualified($ConfigDirectory) -or -not (Test-Path -LiteralPath $ConfigDirectory -PathType Container)) { throw 'Select an existing absolute cloud-pinned Azure configuration directory.' }
    $launcher = Get-Command az -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $executable = $launcher.Source
    $commandArguments = $Arguments
    if ($IsWindows -and [IO.Path]::GetExtension($executable) -in @('.cmd','.bat')) {
        $executable = Join-Path (Split-Path (Split-Path $launcher.Source)) 'python.exe'
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Azure CLI embedded interpreter is unavailable.' }
        $commandArguments = @('-m','azure.cli') + $Arguments
    }
    $result = Invoke-PrivateClientProcess $executable $commandArguments $ConfigDirectory
    if ($result.exitCode -ne 0) {
        if ($AllowMissing -and $result.stderr -match '\bResourceNotFound\b' -and $result.stderr -notmatch 'AuthorizationFailed|AADSTS') { return $null }
        $failure = [InvalidOperationException]::new('Azure read-only request failed; raw response suppressed.')
        $failure.Data['AzureCodes'] = @([regex]::Matches(($result.stderr + $result.stdout),
            '\b(?:AuthorizationFailed|InvalidTemplate|InvalidTemplateDeployment|RequestDisallowedByPolicy|InvalidParameter|InvalidRequestFormat|InvalidApiVersionParameter|NoRegisteredProviderFound|MissingSubscriptionRegistration|ResourceNotFound|ResourceGroupNotFound|NotSupported|AADSTS[0-9]+)\b') | ForEach-Object Value | Select-Object -Unique)
        throw $failure
    }
    $result.stdout | ConvertFrom-Json -AsHashtable -Depth 100 -NoEnumerate
}

function Read-PrivateClientSnapshot {
    param([string]$VmId, [string]$GatewayId, [string]$ConfigDirectory, [string]$CloudName)
    $subscriptionId = ($VmId.Split('/'))[2]
    $vmParts = Get-PrivateClientResourceParts $VmId 'Microsoft.Compute/virtualMachines' $subscriptionId
    $gatewayParts = Get-PrivateClientResourceParts $GatewayId 'Microsoft.ApiManagement/service' $subscriptionId
    $account = Invoke-PrivateClientAzure @('account','show','--subscription',$subscriptionId,'--output','json') $ConfigDirectory
    $cloudContext = Invoke-PrivateClientAzure @('cloud','show','--output','json') $ConfigDirectory
    if ($account.id -ine $subscriptionId -or $account.environmentName -cne $CloudName -or $cloudContext.name -cne $CloudName) { throw 'Pinned Azure context does not match the selected resources.' }
    $arm = if ($CloudName -ceq 'AzureUSGovernment') { 'https://management.usgovcloudapi.net' } else { 'https://management.azure.com' }
    function Read-AccessResource {
        param([string]$Id, [string]$Version = '2024-05-01', [switch]$AllowMissing)
        Invoke-PrivateClientAzure @('rest','--method','GET','--url',($arm + $Id + '?api-version=' + $Version),'--headers','Accept=application/json','--subscription',$subscriptionId,'--output','json','--only-show-errors') $ConfigDirectory -AllowMissing:$AllowMissing
    }
    function Read-AccessCollection {
        param([string]$Id, [string]$Version = '2024-05-01')
        $initial = [uri]($arm + $Id + '?api-version=' + $Version)
        $url = $initial.AbsoluteUri
        $values = [Collections.Generic.List[object]]::new()
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        do {
            $next = [uri]$url
            if (-not $seen.Add($url) -or $seen.Count -gt 20 -or $next.Scheme -cne 'https' -or $next.Authority -ine $initial.Authority -or
                $next.AbsolutePath -ine $initial.AbsolutePath -or $next.UserInfo -or $next.Fragment) { throw 'Unsafe or incomplete ARM pagination.' }
            $page = Invoke-PrivateClientAzure @('rest','--method','GET','--url',$url,'--headers','Accept=application/json','--subscription',$subscriptionId,'--output','json','--only-show-errors') $ConfigDirectory
            if ($page.value -isnot [array]) { throw 'Invalid ARM collection.' }
            foreach ($item in $page.value) { $values.Add($item) }
            $url = $page.nextLink
        } while ($url)
        @{value = $values.ToArray()}
    }
    $snapshot = @{version = 'private-client-access-v1';cloud = $CloudName;subscriptionId = $subscriptionId;capturedAt = [DateTimeOffset]::UtcNow.ToString('o')}
    $snapshot.vm = Read-AccessResource $VmId '2024-07-01'
    $snapshot.gateway = Read-AccessResource $GatewayId
    $null = Assert-PrivateClientResource $snapshot.vm 'Microsoft.Compute/virtualMachines' $subscriptionId
    $null = Assert-PrivateClientResource $snapshot.gateway 'Microsoft.ApiManagement/service' $subscriptionId
    $nics = @($snapshot.vm.properties.networkProfile.networkInterfaces)
    if ($nics.Count -ne 1) { throw 'Expected one selected VM NIC.' }
    $null = Get-PrivateClientResourceParts $nics[0].id 'Microsoft.Network/networkInterfaces' $subscriptionId
    $snapshot.nic = Read-AccessResource $nics[0].id
    $ipConfigurations = @($snapshot.nic.properties.ipConfigurations)
    if ($ipConfigurations.Count -ne 1) { throw 'Expected one selected VM IP configuration.' }
    $clientSubnetId = $ipConfigurations[0].properties.subnet.id
    $gatewaySubnetId = $snapshot.gateway.properties.virtualNetworkConfiguration.subnetResourceId
    foreach ($side in @('client','gateway')) {
        $subnetId = if ($side -ceq 'client') { $clientSubnetId } else { $gatewaySubnetId }
        $null = Get-PrivateClientResourceParts $subnetId 'Microsoft.Network/virtualNetworks/subnets' $subscriptionId
        $vnetId = $subnetId.Substring(0, $subnetId.LastIndexOf('/subnets/', [StringComparison]::OrdinalIgnoreCase))
        $snapshot[$side + 'Vnet'] = Read-AccessResource $vnetId
        $subnets = @($snapshot[$side + 'Vnet'].properties.subnets | Where-Object {$_.id -ieq $subnetId})
        if ($subnets.Count -ne 1) { throw 'Selected subnet was not returned by its VNet.' }
        $nsgId = $subnets[0].properties.networkSecurityGroup.id
        $null = Get-PrivateClientResourceParts $nsgId 'Microsoft.Network/networkSecurityGroups' $subscriptionId
        $snapshot[$side + 'Nsg'] = Read-AccessResource $nsgId
        $snapshot[$side + 'Peerings'] = Read-AccessCollection ($vnetId + '/virtualNetworkPeerings')
    }
    $zoneName = if ($CloudName -ceq 'AzureUSGovernment') { 'azure-api.us' } else { 'azure-api.net' }
    $zoneId = $vmParts.groupId + '/providers/Microsoft.Network/privateDnsZones/' + $zoneName
    $snapshot.dnsZone = Read-AccessResource $zoneId '2020-06-01'
    $snapshot.dnsLinks = Read-AccessCollection ($zoneId + '/virtualNetworkLinks') '2020-06-01'
    $snapshot.dnsRecords = Read-AccessCollection ($zoneId + '/ALL') '2020-06-01'
    $isolation = Read-AccessResource ($gatewayParts.groupId + '/providers/Microsoft.Network/networkSecurityGroups/byok-client-access-isolation') -AllowMissing
    $snapshot.isolationNsgAbsent = $null -eq $isolation
    $snapshot
}

function New-PrivateClientTemporaryDirectory {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('byok-client-preview-' + [guid]::NewGuid().ToString('N'))
    if ($IsWindows) {
        $directory = New-Item -ItemType Directory -Path $path -ErrorAction Stop
        $security = Get-Acl -LiteralPath $directory.FullName
        $security.SetAccessRuleProtection($true, $false)
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        Set-Acl -LiteralPath $path -AclObject $security
    } else {
        $null = [IO.Directory]::CreateDirectory($path, ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute))
    }
    $path
}

if ($DefinitionsOnly) { return }

$temporary = $null
$stage = 'snapshot-collection'
try {
    $snapshot = if ($PSCmdlet.ParameterSetName -ceq 'Live') {
        Read-PrivateClientSnapshot $VmResourceId $GatewayResourceId $AzureConfigDirectory $Cloud
    } else {
        if ((Get-Item -LiteralPath $SnapshotFile).Length -gt 8388608) { throw 'Snapshot exceeds the size limit.' }
        Get-Content -LiteralPath $SnapshotFile -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    }
    $stage = 'snapshot-validation'
    $candidate = New-PrivateClientAccessCandidate $snapshot
    $stage = 'template-build'
    $compiler = Get-Command bicep -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $compilerPath = if ($compiler) { $compiler.Source } elseif (Test-Path "$HOME/.azure/bin/bicep.exe") { "$HOME/.azure/bin/bicep.exe" } else { throw 'A standalone Bicep compiler is required.' }
    $temporary = New-PrivateClientTemporaryDirectory
    $templatePath = Join-Path $temporary 'preview.json'
    $sourceTemplate = Join-Path $PSScriptRoot '../infra/modules/private-client-access-preview.bicep'
    $build = Invoke-PrivateClientProcess $compilerPath @('build', $sourceTemplate, '--outfile', $templatePath)
    if ($build.exitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($build.stderr)) { throw 'Bicep preview build has diagnostics; raw output suppressed.' }
    $template = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $artifact = @{template = $template;helperHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash}
    $digest = Get-PrivateClientAccessDigest $candidate $artifact
    $report = @{test = 'private-client-access-preview';passed = $true;validationOnly = $true;canApply = $false;expectedResources = $candidate.expectedResources.Count;candidateDigest = $digest;providerValidated = $false;scopeVerified = $false;networkWrites = 0;modelCalls = 0;blockers = $candidate.blockers}
    if ($ProviderPreview) {
        $stage = 'provider-validation'
        $parameterPath = Join-Path $temporary 'parameters.json'
        [IO.File]::WriteAllText($parameterPath, (@{parameters = $candidate.parameters} | ConvertTo-Json -Depth 100 -Compress), [Text.UTF8Encoding]::new($false))
        $common = @('--subscription', $snapshot.subscriptionId, '--location', $snapshot.gatewayVnet.location, '--template-file', $templatePath, '--parameters', ('@' + $parameterPath), '--output', 'json', '--only-show-errors')
        $validation = Invoke-PrivateClientAzure (@('deployment','sub','validate') + $common) $AzureConfigDirectory
        if ($validation -isnot [Collections.IDictionary] -or $validation.error -or $validation.properties.error) { throw 'Provider validation failed.' }
        $stage = 'provider-what-if'
        $preview = Invoke-PrivateClientAzure (@('deployment','sub','what-if') + $common + @('--result-format','FullResourcePayloads','--no-pretty-print')) $AzureConfigDirectory
        $scope = Test-PrivateClientAccessWhatIf $preview $candidate
        foreach ($key in $scope.Keys) { $report[$key] = $scope[$key] }
        $report.providerValidated = $true
    }
    if ($PSCmdlet.ParameterSetName -ceq 'Live') {
        $stage = 'snapshot-readback'
        $current = New-PrivateClientAccessCandidate (Read-PrivateClientSnapshot $VmResourceId $GatewayResourceId $AzureConfigDirectory $Cloud)
        if ((Get-PrivateClientAccessDigest $current $artifact) -cne $digest) { throw 'Live resources changed during validation; take a new snapshot.' }
        $report.snapshotUnchanged = $true
    }
    $report | ConvertTo-Json -Depth 6 -Compress
} catch {
    $category = switch -Exact ($_.Exception.Message) {
        'The captured topology differs from the isolated client design.' { 'topology-mismatch' }
        'Unsupported or incomplete subnet snapshot.' { 'unsupported-subnet-properties' }
        'An existing NSG rule can precede the isolation boundary.' { 'preceding-nsg-rule' }
        'Existing DNS records or links require separate review.' { 'dns-collision-or-links' }
        'Only read-only Azure commands are permitted.' { 'mutation-command-rejected' }
        'Azure read-only request failed; raw response suppressed.' { 'azure-read-failed' }
        'Incomplete or failed private-access what-if.' { 'incomplete-what-if' }
        'Private-access what-if omitted an expected resource.' { 'missing-what-if-resource' }
        'Private-access preview added an unreviewed writable property.' { 'unexpected-writable-property' }
        'Private-access preview differs from the preserving candidate.' { 'what-if-property-mismatch' }
        'Private-access preview writes an unapproved resource.' { 'unexpected-resource' }
        'Live resources changed during validation; take a new snapshot.' { 'snapshot-drift' }
        default { 'invalid-input-or-unverified-contract' }
    }
    @{test = 'private-client-access-preview';passed = $false;stage = $stage;category = $category;azureCodes = @($_.Exception.Data['AzureCodes'] | Where-Object {$_});validationOnly = $true;canApply = $false;networkWrites = 0;modelCalls = 0;rawInputsSuppressed = $true} | ConvertTo-Json -Compress
    [Console]::Error.WriteLine('Private client-access validation failed; raw inputs suppressed.')
    exit 1
} finally {
    $snapshot = $null;$candidate = $null;$current = $null;$preview = $null;$validation = $null
    if ($temporary -and (Test-Path -LiteralPath $temporary)) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
exit 0