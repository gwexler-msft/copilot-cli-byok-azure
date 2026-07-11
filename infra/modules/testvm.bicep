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

@description('Admin password for the Windows test VM. If empty, a random one is generated; sign in with Entra ID (AADLoginForWindows) instead. On an existing VM the password is non-updatable, so the running value is unchanged.')
@secure()
param adminPassword string = ''

@description('Internal: random password used only when adminPassword is empty. Do not set explicitly.')
@secure()
param generatedAdminPassword string = '${newGuid()}Aa1!'

@description('Principal (object) ID granted the "Virtual Machine Administrator Login" role on the VM. Empty disables the assignment.')
param aadLoginPrincipalId string = ''

@description('Principal type for aadLoginPrincipalId.')
@allowed([ 'User', 'Group', 'ServicePrincipal' ])
param aadLoginPrincipalType string = 'Group'

@description('Test VM size.')
param vmSize string = 'Standard_D2as_v6'

var effectiveAdminPassword = empty(adminPassword) ? generatedAdminPassword : adminPassword

// Virtual Machine Administrator Login
var vmAdminLoginRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1c0163c0-47e6-4577-8991-ea5c82e286e4')

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
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: effectiveAdminPassword
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

// Entra ID login agent for Windows. Enables `az ssh`/RDP sign-in with Azure AD
// credentials so no local password is needed for day-to-day access.
resource aadLogin 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'AADLoginForWindows'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.0'
    autoUpgradeMinorVersion: true
  }
}

// Grant the chosen principal (default: BYOK Admins group) admin login over the VM.
resource vmAdminLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(aadLoginPrincipalId)) {
  name: guid(vm.id, aadLoginPrincipalId, vmAdminLoginRoleId)
  scope: vm
  properties: {
    roleDefinitionId: vmAdminLoginRoleId
    principalId: aadLoginPrincipalId
    principalType: aadLoginPrincipalType
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
