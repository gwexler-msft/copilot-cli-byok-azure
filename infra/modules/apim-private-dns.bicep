@description('Private DNS zone apex for APIM gateway, e.g. azure-api.us (Gov) or azure-api.net (Commercial).')
param apimDnsZone string

@description('APIM gateway FQDN, e.g. apim-...azure-api.us.')
param apimGatewayHost string

@description('APIM Internal-VNet private IP.')
param apimPrivateIp string

@description('Resource ID of the VNet to link the zone to.')
param vnetId string

@description('Suffix for the VNet link name uniqueness.')
param suffix string

// First DNS label of the gateway host (zone-relative A record name).
var gatewayRecordName = split(apimGatewayHost, '.')[0]

resource zone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: apimDnsZone
  location: 'global'
}

resource gatewayA 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: zone
  name: gatewayRecordName
  properties: {
    ttl: 3600
    aRecords: [
      { ipv4Address: apimPrivateIp }
    ]
  }
}

resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: zone
  name: 'link-${suffix}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}

output zoneName string = zone.name
output gatewayFqdn string = '${gatewayRecordName}.${apimDnsZone}'
