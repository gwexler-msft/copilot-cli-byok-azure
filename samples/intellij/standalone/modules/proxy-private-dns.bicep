param domainName string
param ingressIp string
param vnetId string
param linkName string

@allowed([true])
param privateEnvironmentValidated bool

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: domainName
  location: 'global'
}

resource wildcard 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: zone
  name: '*'
  properties: {
    ttl: 60
    aRecords: [{ ipv4Address: ingressIp }]
  }
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: linkName
  location: 'global'
  properties: {
    registrationEnabled: !privateEnvironmentValidated
    virtualNetwork: { id: vnetId }
  }
}