targetScope = 'resourceGroup'

@allowed(['client', 'gateway'])
param side string

@description('Non-secret, fully validated snapshot projection; generate through the validation-only helper.')
param configuration object

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: configuration.virtualNetworkName
}

resource boundary 'Microsoft.Network/networkSecurityGroups@2024-05-01' existing = {
  name: configuration.networkSecurityGroupName
}

resource boundaryRules 'Microsoft.Network/networkSecurityGroups/securityRules@2024-05-01' = [for rule in configuration.rules: {
  parent: boundary
  name: rule.name
  properties: rule.properties
}]

resource isolation 'Microsoft.Network/networkSecurityGroups@2024-05-01' = if (side == 'gateway') {
  name: configuration.isolationNsgName
  location: configuration.location
  properties: {}
}

resource isolationRules 'Microsoft.Network/networkSecurityGroups/securityRules@2024-05-01' = [for rule in configuration.isolationRules: if (side == 'gateway') {
  parent: isolation
  name: rule.name
  properties: rule.properties
}]

@batchSize(1)
resource isolatedSubnets 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = [for subnet in configuration.subnets: if (side == 'gateway') {
  parent: vnet
  name: subnet.name
  properties: union(subnet.properties, {
    networkSecurityGroup: {
      id: resourceId('Microsoft.Network/networkSecurityGroups', configuration.isolationNsgName)
    }
  })
  dependsOn: [isolationRules]
}]

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: vnet
  name: configuration.peeringName
  properties: {
    remoteVirtualNetwork: {
      id: configuration.remoteVirtualNetworkId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
  dependsOn: [boundaryRules, isolatedSubnets]
}

resource dnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = if (side == 'client') {
  name: configuration.dnsZoneName
}

resource dnsRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = if (side == 'client') {
  parent: dnsZone
  name: configuration.dnsRecordName
  properties: {
    ttl: 60
    aRecords: [
      {
        ipv4Address: configuration.gatewayAddress
      }
    ]
  }
  dependsOn: [peering]
}
