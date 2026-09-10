// Shared `byok.internal` private DNS zone + VNet link (originally added for #117).
//
// The zone + link are owned HERE, once, and created whenever an in-VNet proxy that needs a stable
// private hostname is deployed. Today that is only the subkey proxy (#108) — the Claude streaming
// sidecar that was the other consumer was retired in 2.0.0. Each proxy module then adds only its
// OWN A record under this zone (referenced as `existing`), so the zone and the VNet link are never
// double-created and their names never collide.
param proxyDnsZoneName string = 'byok.internal'

@description('Resource id of the VNet to link the zone to, so in-VNet clients resolve the proxy hostnames.')
param vnetId string

param envName string
param suffix string
param tags object = {}

resource zone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: proxyDnsZoneName
  location: 'global'
  tags: tags
}

resource zoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: zone
  name: 'link-${envName}-${suffix}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}

output zoneName string = zone.name
output zoneId string = zone.id
