@description('Short prefix used in all resource names.')
param namePrefix string

@description('Environment short name.')
param envName string

@description('Resource name suffix.')
param suffix string

@description('Azure region.')
param location string

@description('Resource ID of the subnet to place the test VM NIC in (snet-vm).')
param vmSubnetId string

@description('Admin username for the Windows test VM.')
param adminUsername string

@description('Admin password for the Windows test VM. 12-123 chars, complexity required.')
@secure()
param adminPassword string

@description('Test VM size.')
param vmSize string = 'Standard_D2as_v6'

var vmName       = take('vm-${namePrefix}-test-${suffix}', 15)
var nicName      = 'nic-${namePrefix}-test-${suffix}'
var bastionName  = 'bas-${namePrefix}-${envName}-${suffix}'
var bastionPipName = 'pip-bas-${namePrefix}-${envName}-${suffix}'
var bastionSubnetId = '${substring(vmSubnetId, 0, lastIndexOf(vmSubnetId, '/'))}/AzureBastionSubnet'

resource nic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: vmSubnetId }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [
        { id: nic.id }
      ]
    }
  }
}

resource bastionPip 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: bastionPipName
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-01-01' = {
  name: bastionName
  location: location
  sku: { name: 'Basic' }
  properties: {
    ipConfigurations: [
      {
        name: 'IpConf'
        properties: {
          subnet: { id: bastionSubnetId }
          publicIPAddress: { id: bastionPip.id }
        }
      }
    ]
  }
}

output vmName string = vm.name
output bastionName string = bastion.name
output vmPrivateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
