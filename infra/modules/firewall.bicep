// =====================================================================================
// Azure Firewall — runner egress FQDN allowlist (PROTOTYPE, ships dormant)
// =====================================================================================
// This module is the *desired end-state* egress control for the self-hosted GitHub
// Actions runner subnet (snet-runner), replacing the IP/service-tag NSG allowlist that
// CANNOT express GitHub's control-plane FQDNs. It is wired behind `deployRunnerFirewall`
// in main.bicep and is **OFF BY DEFAULT** — provisioning it has a real, non-trivial cost
// (see the pricing table below) and it must not turn on for existing pilots silently.
//
// WHY A FIREWALL AND NOT AN NSG
// -----------------------------
// An NSG can only allowlist by IP/CIDR or service tag. The GitHub Actions control plane
// (OIDC token endpoint + runner broker, `*.actions.githubusercontent.com`) lives in vast,
// constantly-drifting Azure IP space that no service tag isolates — so an NSG deny-Internet
// allowlist takes the runner OFFLINE (it cannot reach the broker to register, and the
// federated-token fetch in `azd deploy` times out). See docs/github-egress-allowlist.md
// "Incident (2026-06): restrictRunnerEgress NSG breaks the GitHub-Actions runner". Azure
// Firewall application rules allowlist by **FQDN**, which is the correct primitive here.
//
// COST STRUCTURE (retail, pulled 2026-06-24 via Azure Retail Prices API)
// ---------------------------------------------------------------------
// Two charges per firewall: a fixed deployment $/hour + a $/GB data-processed meter.
// Monthly fixed = hourly x 730. Data-processed for CI egress is tens of GB/mo (a few $).
//
//   Tier      | Commercial (eastus2)        | Gov (usgovvirginia)
//   ----------|-----------------------------|-----------------------------
//   Basic     | $0.395/hr  -> ~$288/mo      | $0.494/hr   -> ~$361/mo      + data
//             | + $0.065/GB data            | + $0.0812/GB data
//   Standard  | $1.25/hr   -> ~$913/mo      | $1.5625/hr  -> ~$1,141/mo    + data
//             | + $0.016/GB data            | + $0.02/GB data
//   Premium   | $1.75/hr   -> ~$1,278/mo    | $2.187/hr   -> ~$1,597/mo    + data
//             | + $0.016/GB data            | + $0.02/GB data
//
// comm-pilot and gov-pilot are isolated clouds -> a firewall CANNOT span them, so a full
// rollout needs ONE PER PILOT (additive): Basic ~= $649/mo both sides (~$7.8k/yr);
// Standard ~= $2,054/mo both sides (~$24.6k/yr). Basic is the cheapest tier that supports
// FQDN application rules and is sufficient for this workload (CI throughput << 250 Mbps).
//
// SKU GOTCHA: Azure Firewall **Basic** MANDATES a second subnet (AzureFirewallManagementSubnet,
// /26) and a second public IP for its management plane. Standard only needs that for forced
// tunneling. Both subnets + IPs are provisioned by this module / the network module.
// =====================================================================================

@description('Resource name prefix (e.g. copilot-byok).')
param namePrefix string

@description('Environment name (e.g. comm-pilot).')
param envName string

@description('Unique suffix appended to resource names.')
param suffix string

@description('Azure region for the firewall and its public IP(s).')
param location string

@description('Resource ID of the AzureFirewallSubnet (/26) the firewall data path attaches to. Provisioned by the network module when deployRunnerFirewall=true.')
param firewallSubnetId string

@description('Resource ID of the AzureFirewallManagementSubnet (/26). REQUIRED for the Basic SKU (and for Standard forced-tunneling). Provisioned by the network module when deployRunnerFirewall=true.')
param managementSubnetId string

@allowed([ 'Basic', 'Standard' ])
@description('Azure Firewall SKU tier. Basic is the cheapest tier that supports FQDN application rules and is sufficient for the runner egress allowlist (CI throughput << 250 Mbps). Basic mandates the management subnet + second public IP. See the cost table at the top of this file.')
param tier string = 'Basic'

@description('Source CIDR(s) the application rules apply to — the runner subnet (snet-runner).')
param sourceAddresses array

@description('Allowlisted destination FQDNs the runner may reach outbound on 80/443. STARTING POINT — validate against real runner traffic and extend via additionalFqdns. Azure Firewall wildcards (`*.foo.com`) match subdomains at any depth.')
param allowedFqdns array = [
  // --- GitHub Actions control plane (the part an NSG cannot express) ---
  'github.com'
  '*.github.com'                       // api.github.com, codeload.github.com, etc.
  '*.githubusercontent.com'            // raw/objects + pkg-containers (ghcr layers)
  '*.actions.githubusercontent.com'    // OIDC token endpoint + runner broker (the lockout culprit)
  #disable-next-line no-hardcoded-env-urls // intentional firewall FQDN rule, not an SDK endpoint
  '*.blob.core.windows.net'            // job logs, artifacts, actions cache, ACR layer blobs
  '*.pkg.github.com'                   // GitHub Packages
  'ghcr.io'                            // GitHub Container Registry (if pulling images)
  // --- Azure control plane the deploy workflow drives (azd / az / azure login) ---
  #disable-next-line no-hardcoded-env-urls // intentional firewall FQDN rule, not an SDK endpoint
  'management.azure.com'
  'management.usgovcloudapi.net'       // Gov ARM
  #disable-next-line no-hardcoded-env-urls // intentional firewall FQDN rule, not an SDK endpoint
  'login.microsoftonline.com'
  'login.microsoftonline.us'           // Gov Entra
  '*.azurecr.io'                       // pull the pre-baked runner image from ACR
  'mcr.microsoft.com'
  '*.data.mcr.microsoft.com'
]

@description('Extra FQDNs to append to allowedFqdns without editing the default list (env-specific endpoints discovered during validation).')
param additionalFqdns array = []

var tags = {
  workload: 'copilot-cli-byok'
  component: 'runner-egress-firewall'
  env: envName
}

var fwName     = take('afw-${namePrefix}-runner-${envName}-${suffix}', 56)
var policyName = take('afwp-${namePrefix}-runner-${envName}-${suffix}', 80)
var pipName    = take('pip-afw-${namePrefix}-runner-${envName}-${suffix}', 80)
var pipMgmtName = take('pip-afwmgmt-${namePrefix}-runner-${envName}-${suffix}', 80)

var needsManagement = tier == 'Basic' // Basic always needs the management plane IP + subnet

// Data-path public IP (SNAT to the internet for allowed flows).
resource pipData 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: pipName
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Regional' }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

// Management public IP — mandatory for Basic SKU.
resource pipMgmt 'Microsoft.Network/publicIPAddresses@2024-01-01' = if (needsManagement) {
  name: pipMgmtName
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Regional' }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

// Firewall policy (tier must match the firewall SKU tier).
resource policy 'Microsoft.Network/firewallPolicies@2024-01-01' = {
  name: policyName
  location: location
  tags: tags
  properties: {
    sku: { tier: tier }
    // Threat intel is alert-only on Basic; keep it simple and tier-agnostic.
    threatIntelMode: 'Alert'
  }
}

// Application rule collection group: allow the runner subnet outbound to the FQDN allowlist
// on http/https, deny-by-default for everything else (implicit on Azure Firewall).
resource ruleGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-01-01' = {
  parent: policy
  name: 'runner-egress'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-runner-fqdns'
        priority: 200
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'github-and-azure-fqdns'
            sourceAddresses: sourceAddresses
            targetFqdns: concat(allowedFqdns, additionalFqdns)
            protocols: [
              { protocolType: 'Https', port: 443 }
              { protocolType: 'Http', port: 80 }
            ]
          }
        ]
      }
    ]
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2024-01-01' = {
  name: fwName
  location: location
  tags: tags
  properties: {
    sku: { name: 'AZFW_VNet', tier: tier }
    firewallPolicy: { id: policy.id }
    ipConfigurations: [
      {
        name: 'ipconfig-data'
        properties: {
          subnet: { id: firewallSubnetId }
          publicIPAddress: { id: pipData.id }
        }
      }
    ]
    // Basic requires a dedicated management IP configuration in AzureFirewallManagementSubnet.
    managementIpConfiguration: needsManagement ? {
      name: 'ipconfig-mgmt'
      properties: {
        subnet: { id: managementSubnetId }
        publicIPAddress: { id: pipMgmt.id }
      }
    } : null
  }
  dependsOn: [ ruleGroup ]
}

@description('Private IP of the firewall data path. The runner route table sends 0.0.0.0/0 here. Equals the first non-reserved address of AzureFirewallSubnet (base+4).')
output privateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress

@description('Resource ID of the firewall.')
output firewallId string = firewall.id

@description('Firewall data-path public (SNAT) IP.')
output publicIp string = pipData.properties.ipAddress
