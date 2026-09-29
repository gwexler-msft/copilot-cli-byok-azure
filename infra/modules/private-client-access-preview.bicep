targetScope = 'subscription'

@description('Existing test-VM resource group. This template is for an isolated validation preview, not normal provisioning.')
param clientResourceGroup string

@description('Existing development gateway resource group. No resource group is created.')
param gatewayResourceGroup string

@description('Validated client-side snapshot projection from preview-private-client-access.ps1.')
param clientConfiguration object

@description('Validated gateway-side snapshot projection from preview-private-client-access.ps1.')
param gatewayConfiguration object

module client 'private-client-access-side.bicep' = {
  name: 'private-client-access-client-preview'
  scope: resourceGroup(clientResourceGroup)
  params: {
    side: 'client'
    configuration: clientConfiguration
  }
}

module gateway 'private-client-access-side.bicep' = {
  name: 'private-client-access-gateway-preview'
  scope: resourceGroup(gatewayResourceGroup)
  params: {
    side: 'gateway'
    configuration: gatewayConfiguration
  }
}
