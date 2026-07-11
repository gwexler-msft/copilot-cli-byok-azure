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

@description('Add `snet-runner` (/27) for the VNet-injected GitHub Actions runner (ACA Job env). Only takes effect when the gh-runner stack is deployed; the subnet egresses through the shared NAT gateway (no implicit default-outbound).')
param deployGhRunner bool = false

@description('CIDR for snet-runner. Must be /27 or larger (Workload Profiles requirement). Default derives from `vnetCidr` first two octets so the runner subnet stays inside the VNet (e.g. vnetCidr=10.61.0.0/16 -> 10.61.4.0/27). Override only to customize within a single VNet.')
param runnerSubnetCidr string = ''

@description('Deploy a NAT Gateway on the test-VM subnet for deterministic, controlled outbound egress (replaces the deprecated Azure default-outbound the VM otherwise relies on). Only applies when deployTestVm=true. Default true so the egress-restricted VM subnet has a working outbound path; set false only for quick dev/test where the NAT cost is unwanted.')
param deployNatGateway bool = true

@description('Apply an egress-allowlist NSG to the test-VM subnet: permit only GitHub, npm, nodejs and Azure-management outbound; deny all other internet egress. A discovery tool to observe exactly what the Copilot CLI install/runtime needs. Only applies when deployTestVm=true. Default true (default-deny posture, matching restrictApimEgress); the allowed FQDN-CDN ranges are IP/service-tag based and may need refreshing from api.github.com/meta. Pair with deployNatGateway so allowed traffic has an egress path.')
param restrictVmEgress bool = true

@description('Add a default-deny outbound allowlist to the APIM subnet NSG: permit only the Azure-internal service-tag dependencies APIM (Internal VNet mode, stv2) MUST reach to stay healthy (Entra, Storage, SQL, Key Vault, Azure Monitor) plus intra-VNet (to reach the model private endpoint), then deny all other internet egress. Default true (recommended default-deny posture); APIM has a mandatory egress contract so this allowlist tracks Microsoft service tags and the subnet gets a NAT gateway for the allowed path. Set false only for quick dev/test where the NAT cost or the immutable private-subnet choice is unwanted. The platform channel 168.63.129.16 (DNS/health) is exempt from NSG rules, so management stays reachable.')
param restrictApimEgress bool = true

@description('Destination IPv4 CIDRs (or NSG-usable service tags) the APIM subnet is allowed to reach OUTBOUND on 443 for the COMMERCIAL Foundry route, added ABOVE the default-deny when restrictApimEgress=true. Placeholder <COMMERCIAL_DESTINATION_CIDRS_OR_SERVICE_TAGS>. NSG cannot match FQDNs, so supply public IP ranges. In servicePrincipal backend-auth mode this MUST include BOTH (a) the commercial Foundry data endpoint AND (b) the commercial AAD token endpoint (login.microsoftonline.com) — the Gov AzureActiveDirectory service tag does NOT cover commercial AAD. The cleaner end-state for FQDN egress control is Azure Firewall application rules. Empty = no commercial egress rule (the commercial route is unreachable while the deny is in force).')
param apimCommercialEgressDestinations array = []

@description('Apply an egress-allowlist NSG to the runner subnet (snet-runner): permit only the ACA-platform service tags the VNet-injected runner Job needs (ARM, Entra, Azure Monitor, Storage, Key Vault, Microsoft Container Registry, Azure Container Registry) plus GitHub/npm-node CIDRs and intra-VNet, then deny the rest of the internet. Only applies when deployGhRunner=true. Default FALSE (opt-in): the runner is production CI and a too-tight allowlist silently breaks it (e.g. the myoung34/github-runner image pull from Docker Hub, or a tool-install CDN), so this stays off until validated. NOTE: NSG cannot match FQDNs, so Docker Hub image-pull egress must be supplied via runnerImageRegistryCidrs (or the image pre-mirrored to the allowed ACR — see #94, which pre-bakes the image to ACR to remove the Docker Hub + tool-CDN egress entirely). The desired end-state for real FQDN egress control is Azure Firewall application rules.')
param restrictRunnerEgress bool = false

@description('PROTOTYPE (ships dormant). Route snet-runner egress through an Azure Firewall whose application rules allowlist GitHub/Azure FQDNs — the correct primitive for the runner control plane that restrictRunnerEgress (NSG) cannot express. Only takes effect when deployGhRunner=true. Default FALSE: the firewall has a real fixed cost (~$288-$361/mo Basic per pilot; see infra/modules/firewall.bicep) and must not turn on silently. When true, adds AzureFirewallSubnet + AzureFirewallManagementSubnet (/26 each), a route table sending snet-runner 0.0.0.0/0 to the firewall, and drops the NAT gateway from snet-runner (firewall provides egress via its own public IP).')
param deployRunnerFirewall bool = false

@description('Add `snet-aci` (/27 at <vnetBase>.9.0/27) delegated to Microsoft.ContainerInstance/containerGroups for the in-VNet subkey proxy (an nginx Azure Container Instance). Only takes effect when the subkey proxy is deployed. The subnet keeps default outbound (for the MCR image pull) and reaches the Internal APIM via the VNet + private DNS.')
param deployAciSubnet bool = false

@description('Add `snet-cae-register` (/27 at <vnetBase>.10.0/27) delegated to Microsoft.App/environments for the VNet-integrated register Container Apps environment. Egresses through the shared NAT gateway. Only takes effect when the register app is VNet-integrated.')
param deployRegisterEnvSubnet bool = false

@description('Explicitly pin `defaultOutboundAccess: false` on the subnets that otherwise omit it (snet-pe, snet-dns-in, AzureBastionSubnet, GatewaySubnet, snet-cae-register). Set true for environments whose EXISTING subnets were already created with defaultOutboundAccess=false (Azure secure-by-default), so a re-PUT matches the deployed state instead of computing the immutable default (true) and trying to recreate in-use subnets. Leave false for environments whose subnets are still on the legacy implicit outbound (true).')
param pinSubnetPrivateOutbound bool = false

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

@description('Entra ID sign-in page CDN IPv4 CIDRs allowed outbound when restrictVmEgress=true, so the PRIVATE register app\'s Easy Auth login page renders from inside the egress-locked VM (the only in-VNet machine that can reach the register PE). The login HOST (login.microsoftonline.com/.us) is already covered by the AzureActiveDirectory service tag, and the Gov image CDN (aadcdn.msftauthimages.us) by the AzureFrontDoor.Frontend tag, but the global convergence sign-in SCRIPT/CSS (aadcdn.msauth.net, *.microsoftonline-p.com) resolves to first-party Front Door IPs (13.107.246.x / 13.107.253.x) that are NOT exposed via any NSG-usable service tag (AzureFrontDoor.FirstParty is rejected by NSG). These ranges are identical in Commercial and Gov (global CDN). Akamai-fronted aadcdn.msftauth.net is NOT included (no tag, ranges drift widely) and is not required by the modern convergence page. As with githubEgressCidrs/npmNodeEgressCidrs, the desired end-state for real FQDN egress control is Azure Firewall application rules (allow aadcdn.msauth.net by hostname).')
param entraSignInCdnCidrs array = [
  '13.107.246.0/24' // aadcdn.msauth.net / secure.aadcdn.microsoftonline-p.com
  '13.107.253.0/24' // aadcdn.msauth.net (alternate convergence range)
]

@description('IPv4 CIDRs for the runner image registry, allowed outbound when restrictRunnerEgress=true so ACA can pull the event-driven runner image (default myoung34/github-runner from Docker Hub, which is Cloudflare-fronted and DRIFTS). Default empty `[]` (no rule added) — supply the current Docker Hub / Cloudflare ranges, OR pre-mirror the image into the deployment ACR (covered by the AzureContainerRegistry tag) and leave this empty. INTERIM knob: #94 pre-bakes the runner image to ACR, which removes the need for this entirely. As with githubEgressCidrs, NSG is IP-based and cannot match FQDNs; the desired end-state is Azure Firewall application rules (allow registry-1.docker.io / auth.docker.io by hostname).')
param runnerImageRegistryCidrs array = []

var vnetName       = take('vnet-${namePrefix}-${envName}-${suffix}', 64)
var nsgApimName    = take('nsg-${namePrefix}-apim-${envName}-${suffix}', 64)
var nsgVmName      = take('nsg-${namePrefix}-vm-${envName}-${suffix}', 64)
var nsgRunnerName  = take('nsg-${namePrefix}-runner-${envName}-${suffix}', 64)
var natGwName      = take('natgw-${namePrefix}-${envName}-${suffix}', 80)
var natPipName     = take('pip-natgw-${namePrefix}-${envName}-${suffix}', 80)
var vpnGwName      = take('vpngw-${namePrefix}-${envName}-${suffix}', 80)

// Derive a `<octet1>.<octet2>` base from vnetCidr (e.g. '10.60.0.0/16' -> '10.60')
// so subnet prefixes stay inside the VNet without hand-curating every dev env's
// CIDR scheme. Assumes a /16 VNet (all envs use /16 today). The trailing-octet
// allocation (1.0/27, 2.0/24, 3.0/28, 4.0/27, 5.0/27, 6.0/26, 255.0/27) is the
// pilot layout — preserved verbatim for backwards compat with comm-pilot/gov-pilot.
var vnetOctets    = split(split(vnetCidr, '/')[0], '.')
var vnetBase      = '${vnetOctets[0]}.${vnetOctets[1]}'
var effectiveRunnerSubnetCidr = empty(runnerSubnetCidr) ? '${vnetBase}.4.0/27' : runnerSubnetCidr

// Runner egress firewall (PROTOTYPE, gated by deployRunnerFirewall). AzureFirewallSubnet
// and AzureFirewallManagementSubnet must be /26 and named EXACTLY this. The free trailing
// octets after the pilot layout (.1-.6, .255) are .7 and .8. The firewall's data-path
// private IP is deterministically the first non-reserved address of AzureFirewallSubnet
// (Azure reserves .0-.3, firewall takes .4) -> cidrHost(cidr, 3). Deriving it this way lets
// the runner route table point at it WITHOUT a dependency on the firewall resource, which
// breaks the otherwise-circular VNet<->routeTable<->firewall<->VNet reference.
var effectiveDeployFirewall    = deployGhRunner && deployRunnerFirewall
var azureFirewallSubnetCidr    = '${vnetBase}.7.0/26'
var azureFirewallMgmtSubnetCidr = '${vnetBase}.8.0/26'
var firewallPrivateIp          = cidrHost(azureFirewallSubnetCidr, 3)
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

// COMMERCIAL Foundry egress allow rule for the APIM subnet. Inserted at priority 260 (BELOW the
// 4000 default-deny in apimEgressRules, so it is evaluated FIRST) when the operator supplies
// destination CIDRs/tags. This is the ONLY network change needed to let APIM reach the commercial
// endpoint(s) over the public internet from the otherwise locked-down Gov subnet; egress leaves via
// the shared NAT gateway public IP. In servicePrincipal backend-auth mode the destinations must
// cover BOTH the commercial Foundry data endpoint AND the commercial AAD token endpoint
// (login.microsoftonline.com). NSG is IP/service-tag based (no FQDN matching) so these must be
// refreshed if the ranges change — Azure Firewall application rules are the FQDN end-state.
// Empty destinations => no rule (commercial route stays unreachable).
var apimCommercialEgressRule = empty(apimCommercialEgressDestinations) ? [] : [
  {
    name: 'Allow-Out-FoundryCommercial'
    properties: {
      priority: 260
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefixes: apimCommercialEgressDestinations
      destinationPortRange: '443'
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
    ], restrictApimEgress ? concat(apimEgressRules, apimCommercialEgressRule) : [])
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
        // Entra sign-in page image/asset CDN (aadcdn.msftauthimages.us in Gov,
        // aadcdn.msftauthimages.net in Commercial) is Front-Door-fronted; the tag
        // auto-resolves to the correct per-cloud ranges.
        name: 'Allow-Out-EntraSignInCdn-FrontDoor'
        properties: {
          priority: 232
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureFrontDoor.Frontend'
          destinationPortRange: '443'
        }
      }
      {
        // Global convergence sign-in script/CSS CDN (aadcdn.msauth.net,
        // *.microsoftonline-p.com) — first-party Front Door IPs with no
        // NSG-usable service tag, so allowed by explicit CIDR. Same in both clouds.
        name: 'Allow-Out-EntraSignInCdn-Convergence'
        properties: {
          priority: 234
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefixes: entraSignInCdnCidrs
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

// Egress-allowlist NSG for the VNet-injected runner subnet (snet-runner). Opt-in
// (restrictRunnerEgress=true) because the runner is production CI and a too-tight
// allowlist silently breaks it. Permits the ACA-platform service tags the runner
// Job MUST reach (ARM/Entra/Monitor/Storage/Key Vault/MCR/ACR) plus GitHub + npm/node
// CIDRs and intra-VNet, then denies the rest. The default myoung34/github-runner image
// is pulled from Docker Hub (no service tag, NSG can't match the FQDN) — supply its
// ranges via runnerImageRegistryCidrs, or pre-mirror the image into the ACR (covered by
// the AzureContainerRegistry tag). End-state for true FQDN control is Azure Firewall.
var runnerImageRule = empty(runnerImageRegistryCidrs) ? [] : [
  {
    name: 'Allow-Out-RunnerImageRegistry'
    properties: {
      priority: 235
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefixes: runnerImageRegistryCidrs
      destinationPortRange: '443'
    }
  }
]

var runnerBaseRules = [
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
    // ACA env -> Log Analytics / Azure Monitor ingestion for runner Job logs.
    name: 'Allow-Out-AzureMonitor'
    properties: {
      priority: 215
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'AzureMonitor'
      destinationPortRange: '443'
    }
  }
  {
    // ACA Workload Profiles env has a mandatory Storage egress dependency.
    name: 'Allow-Out-Storage'
    properties: {
      priority: 218
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
    // Runner UAMI resolves the GitHub App private key / PAT from runner-kv.
    name: 'Allow-Out-KeyVault'
    properties: {
      priority: 222
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
    // mcr.microsoft.com base images (azure-cli placeholder + ACA system images).
    name: 'Allow-Out-MCR'
    properties: {
      priority: 224
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'MicrosoftContainerRegistry'
      destinationPortRange: '443'
    }
  }
  {
    // The register-app `azd deploy register` queues `az acr build` against the gated ACR.
    name: 'Allow-Out-ACR'
    properties: {
      priority: 226
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'AzureContainerRegistry'
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

resource nsgRunner 'Microsoft.Network/networkSecurityGroups@2024-01-01' = if (deployGhRunner && restrictRunnerEgress) {
  name: nsgRunnerName
  location: location
  properties: {
    securityRules: concat(runnerBaseRules, runnerImageRule)
  }
}

// NAT Gateway for deterministic, controlled egress. Azure default-outbound is being retired, so an
// explicit egress method is required for the allowlisted traffic to leave. A single NAT gateway is
// shared by every subnet that needs a controlled egress path (test-VM, APIM, and/or runner).
var deployNat = (deployTestVm && deployNatGateway) || restrictApimEgress || deployGhRunner

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

// When an environment's existing subnets were created with defaultOutboundAccess=false, the template
// must set it explicitly (this immutable property can't be changed on an in-use subnet). This object
// is unioned into the subnets that otherwise omit it. Empty when the env stays on legacy outbound.
var privateOutbound = pinSubnetPrivateOutbound ? { defaultOutboundAccess: false } : {}

var baseSubnets = [
  {
    name: 'snet-apim'
    properties: union(
      {
        addressPrefix: '${vnetBase}.1.0/27'
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
    properties: union({
      addressPrefix: '${vnetBase}.2.0/24'
      privateEndpointNetworkPolicies: 'Disabled'
    }, privateOutbound)
  }
  {
    name: 'snet-dns-in'
    properties: union({
      addressPrefix: '${vnetBase}.3.0/28'
      delegations: [
        {
          name: 'Microsoft.Network.dnsResolvers'
          properties: { serviceName: 'Microsoft.Network/dnsResolvers' }
        }
      ]
    }, privateOutbound)
  }
]

var gatewaySubnet = [
  {
    name: 'GatewaySubnet'
    properties: union({ addressPrefix: '${vnetBase}.255.0/27' }, privateOutbound)
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
        { addressPrefix: '${vnetBase}.5.0/27' },
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
    properties: union({ addressPrefix: '${vnetBase}.6.0/26' }, privateOutbound)
  }
]

// Runner subnet for the VNet-injected ACA Job that hosts the self-hosted GitHub Actions
// runner (issue #57). Workload Profiles requires /27 or larger; the subnet is delegated
// to Microsoft.App/environments and egresses through the shared NAT Gateway (no implicit
// default-outbound). defaultOutboundAccess is immutable post-create, so a later
// `deployGhRunner=true` flip on a subnet that was created without it cannot be patched
// in place — destroy/recreate snet-runner (which means destroying the env on it first).
//
// PROTOTYPE egress firewall: when deployRunnerFirewall=true, snet-runner egresses through
// the Azure Firewall (route table 0.0.0.0/0 -> firewall private IP) and the NAT gateway is
// dropped (the firewall SNATs via its own public IP). The route table targets the
// deterministic firewall IP (cidrHost(AzureFirewallSubnet, 3)) so it has NO dependency on
// the firewall resource — that is what breaks the otherwise-circular subnet<->firewall ref.
resource rtRunner 'Microsoft.Network/routeTables@2024-01-01' = if (effectiveDeployFirewall) {
  name: take('rt-${namePrefix}-runner-${envName}-${suffix}', 80)
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-to-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

var runnerSubnets = [
  {
    name: 'snet-runner'
    properties: union(
      {
        addressPrefix: effectiveRunnerSubnetCidr
        defaultOutboundAccess: false
        networkSecurityGroup: (deployGhRunner && restrictRunnerEgress) ? { id: nsgRunner.id } : null
        delegations: [
          {
            name: 'Microsoft.App.environments'
            properties: { serviceName: 'Microsoft.App/environments' }
          }
        ]
      },
      effectiveDeployFirewall
        ? { routeTable: { id: rtRunner.id } }
        : { natGateway: { id: natGw.id } }
    )
  }
]

// AzureFirewallSubnet + AzureFirewallManagementSubnet (Basic SKU mandates the latter).
// Names are fixed by Azure; both must be /26. Only added when the firewall is enabled.
var firewallSubnets = [
  {
    name: 'AzureFirewallSubnet'
    properties: { addressPrefix: azureFirewallSubnetCidr }
  }
  {
    name: 'AzureFirewallManagementSubnet'
    properties: { addressPrefix: azureFirewallMgmtSubnetCidr }
  }
]

var optionalSubnets = concat(
  deployVpnGateway ? gatewaySubnet : [],
  deployTestVm ? testVmSubnets : [],
  deployGhRunner ? runnerSubnets : [],
  effectiveDeployFirewall ? firewallSubnets : [],
  deployAciSubnet ? aciSubnets : [],
  deployRegisterEnvSubnet ? registerEnvSubnets : []
)

// snet-aci: dedicated /27 delegated to Azure Container Instances for the in-VNet subkey proxy.
// A delegated ACI subnet can only host container groups. Keeps default outbound so the container
// can pull its stock nginx image from MCR; reaches the Internal APIM via the VNet + private DNS.
var aciSubnets = [
  {
    name: 'snet-aci'
    properties: {
      addressPrefix: '${vnetBase}.9.0/27'
      delegations: [
        {
          name: 'Microsoft.ContainerInstance.containerGroups'
          properties: { serviceName: 'Microsoft.ContainerInstance/containerGroups' }
        }
      ]
    }
  }
]

// snet-cae-register: /27 delegated to Azure Container Apps environments for the VNet-integrated
// register environment. Egresses through the shared NAT gateway (Graph / ARM / image pull) and
// reaches the private register Key Vault + Internal APIM over the VNet.
var registerEnvSubnets = [
  {
    name: 'snet-cae-register'
    properties: union(
      {
        addressPrefix: '${vnetBase}.10.0/27'
        delegations: [
          {
            name: 'Microsoft.App.environments'
            properties: { serviceName: 'Microsoft.App/environments' }
          }
        ]
      },
      deployNatGateway ? { natGateway: { id: natGw.id } } : {},
      privateOutbound
    )
  }
]

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [vnetCidr] }
    // Subnets are managed as CHILD resources (below), NOT inline here. A VNet PUT that OMITS the
    // subnets property preserves existing subnets, and child subnet resources are reconciled BY NAME
    // (not by array position). This avoids Azure's inline-array reorder behavior, which tries to
    // delete+recreate in-use subnets when a pre-existing VNet's stored subnet order differs from the
    // template's order (e.g. an env first created by an older template) — that fails with
    // InUseSubnetCannotBeDeleted. By-name child management adds/updates subnets without touching the
    // order of the others.
  }
}

// Serial (Azure requires one subnet operation at a time on a VNet) by-name reconciliation of every
// subnet. Adding a new subnet (e.g. snet-cae-register) updates only that subnet; existing in-use
// subnets are matched by name and left in place.
@batchSize(1)
resource vnetSubnets 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = [for s in concat(baseSubnets, optionalSubnets): {
  parent: vnet
  name: s.name
  properties: s.properties
}]

resource vpnPip 'Microsoft.Network/publicIPAddresses@2024-01-01' = if (deployVpnGateway) {
  name: vpnPipName
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource vpnGw 'Microsoft.Network/virtualNetworkGateways@2024-01-01' = if (deployVpnGateway) {
  name: vpnGwName
  location: location
  dependsOn: [ vnetSubnets ]
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
  dependsOn: [ vnetSubnets ]
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
output runnerSubnetId string = deployGhRunner ? '${vnet.id}/subnets/snet-runner' : ''
output natGatewayPublicIp string = deployNat ? (natPip.?properties.ipAddress ?? '') : ''
output runnerSubnetCidr string = deployGhRunner ? effectiveRunnerSubnetCidr : ''
output firewallSubnetId string = effectiveDeployFirewall ? '${vnet.id}/subnets/AzureFirewallSubnet' : ''
output firewallManagementSubnetId string = effectiveDeployFirewall ? '${vnet.id}/subnets/AzureFirewallManagementSubnet' : ''
output aciSubnetId string = deployAciSubnet ? '${vnet.id}/subnets/snet-aci' : ''
output registerEnvSubnetId string = deployRegisterEnvSubnet ? '${vnet.id}/subnets/snet-cae-register' : ''
