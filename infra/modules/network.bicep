param namePrefix string
param envName string
param suffix string
param location string
param vnetCidr string
param deployVpnGateway bool

@secure()
param vpnRootCertPublicData string

param peerVnetResourceId string

@description('Deploy a test VM + Azure Bastion for manual in-VNet validation of the Internal APIM.')
param deployTestVm bool = false

@description('Deploy a NAT Gateway on the test-VM subnet for deterministic, controlled outbound egress (replaces the deprecated Azure default-outbound the VM otherwise relies on). Only applies when deployTestVm=true. Default true so the egress-restricted VM subnet has a working outbound path; set false only for quick dev/test where the NAT cost is unwanted.')
param deployNatGateway bool = true

@description('Apply an egress-allowlist NSG to the test-VM subnet: permit only GitHub, npm, nodejs and Azure-management outbound; deny all other internet egress. A discovery tool to observe exactly what the Copilot CLI install/runtime needs. Only applies when deployTestVm=true. Default true (default-deny posture, matching restrictApimEgress); the allowed FQDN-CDN ranges are IP/service-tag based and may need refreshing from api.github.com/meta. Pair with deployNatGateway so allowed traffic has an egress path.')
param restrictVmEgress bool = true

@description('Add a default-deny outbound allowlist to the APIM subnet NSG: permit only the Azure-internal service-tag dependencies APIM (Internal VNet mode, stv2) MUST reach to stay healthy (Entra, Storage, SQL, Key Vault, Azure Monitor) plus intra-VNet (to reach the model private endpoint), then deny all other internet egress. Default true (recommended default-deny posture); APIM has a mandatory egress contract so this allowlist tracks Microsoft service tags and the subnet gets a NAT gateway for the allowed path. Set false only for quick dev/test where the NAT cost or the immutable private-subnet choice is unwanted. The platform channel 168.63.129.16 (DNS/health) is exempt from NSG rules, so management stays reachable.')
param restrictApimEgress bool = true

@description('GitHub IPv4 CIDRs allowed outbound when restrictVmEgress=true. NSG is IP/service-tag based and CANNOT match FQDNs, so these must be refreshed from https://api.github.com/meta (api/web/git/packages unions). True FQDN egress control needs Azure Firewall.')
param githubEgressCidrs array = [
  '140.82.112.0/20'
  '143.55.64.0/20'
  '185.199.108.0/22'
  '192.30.252.0/22'
  '20.175.192.0/18'
  '20.200.245.0/24'
]

@description('npm + nodejs CDN IPv4 CIDRs allowed outbound when restrictVmEgress=true. registry.npmjs.org and nodejs.org are Cloudflare-fronted. These are TIGHTENED to the specific /20 prefixes Cloudflare currently assigns to those zones (observed 2026-06-01: registry.npmjs.org -> 104.16.0-11.x, nodejs.org -> 104.16.212-213.x), deliberately EXCLUDING other Cloudflare /20s used by unrelated sites (e.g. example.com -> 104.20.x, api.ipify.org -> 104.26.x). This is intentionally narrow to demonstrate a working allowlist, but Cloudflare can re-map zones to other prefixes at any time, so this WILL drift. The desired end-state for real FQDN-based egress control is Azure Firewall application rules (allow registry.npmjs.org / nodejs.org by hostname), not IP CIDRs. Refresh by re-resolving the hostnames and mapping each A record to its enclosing /20.')
param npmNodeEgressCidrs array = [
  '104.16.0.0/20'   // registry.npmjs.org (104.16.0-11.x)
  '104.16.208.0/20' // nodejs.org (104.16.212-213.x)
]

var vnetName       = take('vnet-${namePrefix}-${envName}-${suffix}', 64)
var nsgApimName    = take('nsg-${namePrefix}-apim-${envName}-${suffix}', 64)
var nsgVmName      = take('nsg-${namePrefix}-vm-${envName}-${suffix}', 64)
var natGwName      = take('natgw-${namePrefix}-${envName}-${suffix}', 80)
var natPipName     = take('pip-natgw-${namePrefix}-${envName}-${suffix}', 80)
var vpnGwName      = take('vpngw-${namePrefix}-${envName}-${suffix}', 80)
var vpnPipName     = take('pip-vpngw-${namePrefix}-${envName}-${suffix}', 80)
var p2sAddressPool = '172.16.200.0/24'

// Mandatory outbound dependencies for APIM Internal VNet mode (stv2). Applied only when
// restrictApimEgress=true; service-tag based so they track Microsoft's published ranges.
// Omitting any of these (or pairing the deny without them) makes APIM go Unhealthy.
var apimEgressRules = [
  {
    name: 'Allow-Out-VNet'
    properties: {
      priority: 200
      direction: 'Outbound'
      access: 'Allow'
      protocol: '*'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRange: '*'
    }
  }
  {
    name: 'Allow-Out-Entra'
    properties: {
      priority: 210
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'AzureActiveDirectory'
      destinationPortRange: '443'
    }
  }
  {
    name: 'Allow-Out-Storage'
    properties: {
      priority: 220
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'Storage'
      destinationPortRange: '443'
    }
  }
  {
    name: 'Allow-Out-SQL'
    properties: {
      priority: 230
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'SQL'
      destinationPortRange: '1433'
    }
  }
  {
    name: 'Allow-Out-KeyVault'
    properties: {
      priority: 240
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'AzureKeyVault'
      destinationPortRange: '443'
    }
  }
  {
    name: 'Allow-Out-Monitor'
    properties: {
      priority: 250
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'AzureMonitor'
      destinationPortRanges: [ '443', '1886' ]
    }
  }
  {
    name: 'Deny-Out-Internet'
    properties: {
      priority: 4000
      direction: 'Outbound'
      access: 'Deny'
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'Internet'
      destinationPortRange: '*'
    }
  }
]

resource nsgApim 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: nsgApimName
  location: location
  properties: {
    securityRules: concat([
      {
        name: 'Allow-APIM-Management'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'ApiManagement'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '3443'
        }
      }
      {
        name: 'Allow-AzureLB'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '6390'
        }
      }
      {
        name: 'Allow-VNet-Inbound-HTTPS'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '443'
        }
      }
    ], restrictApimEgress ? apimEgressRules : [])
  }
}

// Egress-allowlist NSG for the test-VM subnet: permit only GitHub / npm / nodejs / Azure-management
// outbound (HTTPS 443) plus intra-VNet, then DENY all other internet egress. NSG rules are
// IP/service-tag based (no FQDN matching), so the GitHub + CDN ranges are supplied as CIDR params
// and must be refreshed periodically. The Azure platform channel (168.63.129.16: DNS, IMDS, guest
// agent / az vm run-command) is NOT subject to these rules, so management stays reachable.
resource nsgVm 'Microsoft.Network/networkSecurityGroups@2024-01-01' = if (deployTestVm && restrictVmEgress) {
  name: nsgVmName
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-Out-AzureManagement'
        properties: {
          priority: 200
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureResourceManager'
          destinationPortRange: '443'
        }
      }
      {
        name: 'Allow-Out-Entra'
        properties: {
          priority: 210
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureActiveDirectory'
          destinationPortRange: '443'
        }
      }
      {
        name: 'Allow-Out-GitHub'
        properties: {
          priority: 220
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefixes: githubEgressCidrs
          destinationPortRange: '443'
        }
      }
      {
        name: 'Allow-Out-NpmNode'
        properties: {
          priority: 230
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefixes: npmNodeEgressCidrs
          destinationPortRange: '443'
        }
      }
      {
        name: 'Allow-Out-VNet'
        properties: {
          priority: 240
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-Out-Internet'
        properties: {
          priority: 4000
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// NAT Gateway for deterministic, controlled egress. Azure default-outbound is being retired, so an
// explicit egress method is required for the allowlisted traffic to leave. A single NAT gateway is
// shared by every subnet that needs a controlled egress path (test-VM and/or APIM). It is deployed
// when the test VM asks for it OR when APIM egress is locked down (APIM must keep a real egress path
// once its subnet becomes private).
var deployNat = (deployTestVm && deployNatGateway) || restrictApimEgress

resource natPip 'Microsoft.Network/publicIPAddresses@2024-01-01' = if (deployNat) {
  name: natPipName
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource natGw 'Microsoft.Network/natGateways@2024-01-01' = if (deployNat) {
  name: natGwName
  location: location
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [ { id: natPip.id } ]
  }
}

var baseSubnets = [
  {
    name: 'snet-apim'
    properties: union(
      {
        addressPrefix: '10.60.1.0/27'
        networkSecurityGroup: { id: nsgApim.id }
        privateEndpointNetworkPolicies: 'Enabled'
      },
      // When APIM egress is locked down, make snet-apim a private subnet (remove the deprecated
      // implicit default-outbound) and route its allowed egress through the shared NAT gateway.
      // defaultOutboundAccess is immutable post-creation, so toggling this on an existing subnet
      // requires recreating snet-apim (which means recreating APIM on it).
      restrictApimEgress ? {
        defaultOutboundAccess: false
        natGateway: { id: natGw.id }
      } : {}
    )
  }
  {
    name: 'snet-pe'
    properties: {
      addressPrefix: '10.60.2.0/24'
      privateEndpointNetworkPolicies: 'Disabled'
    }
  }
  {
    name: 'snet-dns-in'
    properties: {
      addressPrefix: '10.60.3.0/28'
      delegations: [
        {
          name: 'Microsoft.Network.dnsResolvers'
          properties: { serviceName: 'Microsoft.Network/dnsResolvers' }
        }
      ]
    }
  }
]

var gatewaySubnet = [
  {
    name: 'GatewaySubnet'
    properties: { addressPrefix: '10.60.255.0/27' }
  }
]

var testVmSubnets = [
  {
    name: 'snet-vm'
    properties: union(
      // When egress is restricted, make this a "private subnet" (defaultOutboundAccess:false) so the
      // deprecated Azure implicit default-outbound is removed and the ONLY egress path is the NAT
      // Gateway. NOTE: defaultOutboundAccess is immutable post-creation — changing it on an existing
      // subnet requires recreating snet-vm (tear down VM/NIC/Bastion on it first).
      union(
        { addressPrefix: '10.60.5.0/27' },
        (deployTestVm && restrictVmEgress) ? { defaultOutboundAccess: false } : {}
      ),
      union(
        (deployTestVm && restrictVmEgress) ? { networkSecurityGroup: { id: nsgVm.id } } : {},
        (deployTestVm && deployNatGateway)  ? { natGateway: { id: natGw.id } } : {}
      )
    )
  }
  {
    name: 'AzureBastionSubnet'
    properties: { addressPrefix: '10.60.6.0/26' }
  }
]

var optionalSubnets = concat(
  deployVpnGateway ? gatewaySubnet : [],
  deployTestVm ? testVmSubnets : []
)

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [vnetCidr] }
    subnets: concat(baseSubnets, optionalSubnets)
  }
}

resource vpnPip 'Microsoft.Network/publicIPAddresses@2024-01-01' = if (deployVpnGateway) {
  name: vpnPipName
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource vpnGw 'Microsoft.Network/virtualNetworkGateways@2024-01-01' = if (deployVpnGateway) {
  name: vpnGwName
  location: location
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    sku: { name: 'VpnGw1', tier: 'VpnGw1' }
    activeActive: false
    enableBgp: false
    ipConfigurations: [
      {
        name: 'default'
        properties: {
          publicIPAddress: { id: vpnPip.id }
          subnet: { id: '${vnet.id}/subnets/GatewaySubnet' }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
    vpnClientConfiguration: {
      vpnClientAddressPool: { addressPrefixes: [p2sAddressPool] }
      vpnClientProtocols: ['OpenVPN']
      vpnAuthenticationTypes: ['Certificate']
      vpnClientRootCertificates: empty(vpnRootCertPublicData) ? [] : [
        {
          name: 'P2SRootCert'
          properties: { publicCertData: vpnRootCertPublicData }
        }
      ]
    }
  }
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = if (!empty(peerVnetResourceId)) {
  parent: vnet
  name: 'to-peer'
  properties: {
    remoteVirtualNetwork: { id: peerVnetResourceId }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output apimSubnetId string = '${vnet.id}/subnets/snet-apim'
output peSubnetId   string = '${vnet.id}/subnets/snet-pe'
output gatewaySubnetId string = deployVpnGateway ? '${vnet.id}/subnets/GatewaySubnet' : ''
output vmSubnetId string = deployTestVm ? '${vnet.id}/subnets/snet-vm' : ''
output bastionSubnetId string = deployTestVm ? '${vnet.id}/subnets/AzureBastionSubnet' : ''
output natGatewayPublicIp string = deployNat ? (natPip.?properties.ipAddress ?? '') : ''
