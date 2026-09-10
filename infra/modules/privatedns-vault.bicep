// Private DNS zone for Key Vault (privatelink.vaultcore.<cloud>). Created only when a runner /
// register vault is locked down with a Private Endpoint. The zone is linked to the local VNet (and
// the peer VNet, if any) so in-VNet callers — including the VNet-integrated Container Apps runner
// environment resolving its gh-pat Key Vault reference — resolve the vault FQDN to the PE.

@description('Key Vault privatelink zone name, e.g. privatelink.vaultcore.usgovcloudapi.net (gov) or privatelink.vaultcore.azure.net (commercial).')
param vaultDnsZoneName string

@description('Resource id of the VNet to link the zone to.')
param vnetId string

@description('Optional peer VNet resource id to also link (e.g. a hub). Empty = no peer link.')
param peerVnetResourceId string = ''

@description('Tags applied to the zone.')
param tags object = {}

resource vaultZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: vaultDnsZoneName
  location: 'global'
  tags: tags
}

resource vaultLinkLocal 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: vaultZone
  name: 'link-local'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}

resource vaultLinkPeer 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (!empty(peerVnetResourceId)) {
  parent: vaultZone
  name: 'link-peer'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: peerVnetResourceId }
  }
}

output vaultZoneId string = vaultZone.id
