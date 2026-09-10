// Shared private DNS zones for Cognitive Services / OpenAI / Foundry (AIServices) accounts.
//
// Why shared (not per-account): a Private DNS zone NAME (e.g. privatelink.openai.azure.us)
// can be linked to a given VNet only once. Both the classic AOAI (kind=OpenAI) account and
// the Foundry (kind=AIServices) account resolve their *.openai.* endpoint through the SAME
// privatelink.openai zone, each contributing its own A record (distinct custom-subdomain
// host). So PEs stay separate (one per account) but the zones are shared here.
//
// Foundry additionally exposes a *.cognitiveservices.* endpoint, so we also create that zone.
// In Commercial there is a third forwarder (services.ai), created only when aiDnsZoneName set.

param openaiDnsZoneName string
param cognitiveDnsZoneName string

@description('Optional third zone (Commercial only: privatelink.services.ai.azure.com). Empty = skip.')
param aiDnsZoneName string = ''

param vnetId string
param peerVnetResourceId string = ''

resource openaiZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: openaiDnsZoneName
  location: 'global'
}

resource openaiLinkLocal 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: openaiZone
  name: 'link-local'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnetId }
    registrationEnabled: false
  }
}

resource openaiLinkPeer 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (!empty(peerVnetResourceId)) {
  parent: openaiZone
  name: 'link-peer'
  location: 'global'
  properties: {
    virtualNetwork: { id: peerVnetResourceId }
    registrationEnabled: false
  }
}

resource cognitiveZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: cognitiveDnsZoneName
  location: 'global'
}

resource cognitiveLinkLocal 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: cognitiveZone
  name: 'link-local'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnetId }
    registrationEnabled: false
  }
}

resource cognitiveLinkPeer 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (!empty(peerVnetResourceId)) {
  parent: cognitiveZone
  name: 'link-peer'
  location: 'global'
  properties: {
    virtualNetwork: { id: peerVnetResourceId }
    registrationEnabled: false
  }
}

resource aiZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (!empty(aiDnsZoneName)) {
  name: empty(aiDnsZoneName) ? 'placeholder.invalid' : aiDnsZoneName
  location: 'global'
}

resource aiLinkLocal 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (!empty(aiDnsZoneName)) {
  parent: aiZone
  name: 'link-local'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnetId }
    registrationEnabled: false
  }
}

output openaiZoneId string = openaiZone.id
output cognitiveZoneId string = cognitiveZone.id
output aiZoneId string = empty(aiDnsZoneName) ? '' : aiZone.id
