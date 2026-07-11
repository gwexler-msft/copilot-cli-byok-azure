// IntelliJ BYOK bolt-on — proxy VM (Option A).
//
// A small Ubuntu VM (no public IP) with a STATIC private IP running nginx, which translates
// `Authorization: Bearer <APIM subscription key>` into the `api-key` header and forwards to the
// customer's Internal APIM by PRIVATE IP (Host + TLS SNI = gateway host, so no DNS is needed).
// Because the IP is static there is nothing to reconcile — the pilots' ACI+reconciler is not used here.

@description('Azure region.')
param location string

@description('VM name.')
param vmName string = 'vm-byok-intellij-proxy'

@description('VM size. B2s is plenty for an nginx forward proxy.')
param vmSize string = 'Standard_B2s'

@description('Resource id of the EXISTING subnet for a deployment-created NIC. Required when proxyNicId is empty.')
param subnetId string = ''

@description('OPTIONAL full resource id of a customer-created, unattached NIC. When set, no NIC is created and the VM attaches this NIC.')
param proxyNicId string = ''

@description('The STATIC private IP to assign the proxy (a free address the customer reserved in that subnet). This is the permanent proxy address.')
param staticPrivateIp string

@description('Private IP of the customer Internal APIM (nginx connects here directly — no DNS).')
param apimPrivateIp string

@description('APIM gateway hostname (used as the Host header + TLS SNI when forwarding by IP).')
param apimGatewayHost string

@description('The only APIM API path the standalone proxy accepts (all other paths return 404).')
param intellijApiPath string = 'intellij'

@description('Admin username for the VM.')
param adminUsername string = 'byokadmin'

@description('SSH public key for the admin user (password auth is disabled).')
param adminSshPublicKey string

@description('Tags applied to every resource the module creates.')
param tags object = {}

@description('OPTIONAL resource id of a pre-baked Azure Compute Gallery image version (nginx already installed) for air-gapped subnets with no package egress. Empty = use the Ubuntu marketplace image and install nginx at boot.')
param proxyImageId string = ''

// Bake the APIM private IP + gateway host into the cloud-init nginx config. When a pre-baked image is
// supplied, use the config-only cloud-init (no apt) since nginx already ships in the image.
var cloudInitSource = empty(proxyImageId) ? loadTextContent('../cloud-init.yaml') : loadTextContent('../cloud-init.prebaked.yaml')
var cloudInit = replace(replace(replace(cloudInitSource, '__APIM_PRIVATE_IP__', apimPrivateIp), '__APIM_GATEWAY_HOST__', apimGatewayHost), '__INTELLIJ_API_PATH__', intellijApiPath)

var createNic = empty(proxyNicId)

// NIC with a STATIC private IP, no public IP. Skipped when the customer supplies one.
resource nic 'Microsoft.Network/networkInterfaces@2024-01-01' = if (createNic) {
  name: 'nic-${vmName}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: staticPrivateIp
          subnet: { id: subnetId }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: vmSize }
    // A pre-baked gallery image is built TrustedLaunch (gen2, no feature flag), so match it here.
    // The marketplace path leaves this null (deploys as an ordinary gen2 VM, as before).
    securityProfile: empty(proxyImageId) ? null : {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      // No password — SSH key only.
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
        provisionVMAgent: true
        // Marketplace image: fully platform-managed OS patching. A pre-baked gallery image is not
        // registered for platform guest-patching, so fall back to ImageDefault on that path
        // (patch by publishing a new image version).
        patchSettings: {
          patchMode: empty(proxyImageId) ? 'AutomaticByPlatform' : 'ImageDefault'
          assessmentMode: empty(proxyImageId) ? 'AutomaticByPlatform' : 'ImageDefault'
        }
      }
    }
    storageProfile: {
      imageReference: empty(proxyImageId) ? {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      } : {
        id: proxyImageId
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [
        { id: createNic ? nic.id : proxyNicId }
      ]
    }
  }
}

output vmName string = vm.name
output proxyNicId string = createNic ? nic.id : proxyNicId
output proxyPrivateIp string = staticPrivateIp
