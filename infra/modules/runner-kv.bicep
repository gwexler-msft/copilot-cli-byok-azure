// Key Vault for the self-hosted GitHub Actions runner's GitHub PAT (issue #58 — KV-backed rotation).
//
// The KEDA-scaled runner Job needs a GitHub PAT for two things: KEDA polling the Actions queue
// and the runner container fetching a registration token. Storing that PAT directly as a Job
// secret means every rotation is an `az containerapp job secret set` and the plaintext flows
// through a @secure() Bicep param. Instead we keep it in this RBAC-mode Key Vault: the runner
// UAMI gets "Key Vault Secrets User" (read) so the Container Apps Job resolves the secret via a
// `keyVaultUrl` reference, and rotation becomes a single `az keyvault secret set` that the next
// runner execution picks up automatically — identical in both Azure clouds (the vault URI is
// cloud-correct: .vault.azure.net vs .vault.usgovcloudapi.net).
//
// Access model (RBAC, no access policies):
//   - the runner UAMI gets "Key Vault Secrets User" (read) for the Job's keyVaultUrl reference;
//   - the deploying principal optionally gets "Key Vault Secrets Officer" (write) so the
//     rotation helper can set/rotate the PAT. When `deployerPrincipalId` is empty (CI, where it
//     is resolved at runtime) the helper self-grants this role instead.
//
// Only created when deployGhRunner=true (gated in main.bicep). The vault NAME is supplied by
// main.bicep (single source of truth) so the parent can build the deterministic secret URI it
// passes to the runner Job WITHOUT taking a module dependency on this one. That one-way edge is
// deliberate: this module already depends on the runner UAMI principalId (a gh-runner output),
// so if gh-runner also depended on this module's vault URI the graph would cycle. Bootstrap is
// therefore a two-phase flow (documented in main.bicep + the operations runbook): provision once
// to create the empty vault + placeholder Job, write the PAT, then provision again with the
// KV-reference toggle on.

@description('Key Vault name (3-24 chars), owned/computed by main.bicep so the runner Job secret URI and this vault stay in sync.')
@minLength(3)
@maxLength(24)
param vaultName string

@description('Azure region.')
param location string

@description('Tenant ID the vault belongs to.')
param tenantId string

@description('Principal ID of the runner UAMI (gh-runner module output). Granted Key Vault Secrets User (read) so the Container Apps Job resolves the gh-pat secret reference.')
param runnerUamiPrincipalId string

@description('Object ID of the deploying principal, granted Key Vault Secrets Officer (write) so the rotation helper can set the PAT. Empty => the helper self-grants at runtime (CI path).')
param deployerPrincipalId string = ''

@description('Lock the vault down: publicNetworkAccess=Disabled + a Private Endpoint. Secret resolution + rotation then happen ONLY in-VNet (the VNet-integrated runner env resolves the gh-pat reference over the PE; rotation must run from an in-VNet host). Requires peSubnetId + vaultDnsZoneId.')
param privateNetworking bool = false

@description('Subnet id for the Private Endpoint (snet-pe). Required when privateNetworking=true.')
param peSubnetId string = ''

@description('Resource id of the privatelink.vaultcore.<cloud> zone the PE binds to. Required when privateNetworking=true.')
param vaultDnsZoneId string = ''

@description('Tags applied to every resource the module creates.')
param tags object = {}

// Built-in roles.
var secretsUserRoleId    = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6') // Key Vault Secrets User (read)
var secretsOfficerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7') // Key Vault Secrets Officer (write)

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: vaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: null
    // When locked down, only the Private Endpoint can reach the vault. The VNet-integrated runner
    // environment resolves the gh-pat reference over the PE; a `bypass: AzureServices` is kept so
    // trusted first-party services (e.g. portal/backup) still work if PNA is later re-enabled.
    publicNetworkAccess: privateNetworking ? 'Disabled' : 'Enabled'
    networkAcls: privateNetworking ? {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    } : null
  }
}

// Runner UAMI: read the gh-pat secret (the Container Apps Job keyVaultUrl reference resolves as the UAMI).
resource uamiSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: kv
  name: guid(kv.id, runnerUamiPrincipalId, secretsUserRoleId)
  properties: {
    principalId: runnerUamiPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: secretsUserRoleId
  }
}

// Deploying principal (when known): write/rotate the PAT via the rotation helper.
resource deployerSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerPrincipalId)) {
  scope: kv
  name: guid(kv.id, deployerPrincipalId, secretsOfficerRoleId)
  properties: {
    principalId: deployerPrincipalId
    roleDefinitionId: secretsOfficerRoleId
  }
}

// Private Endpoint (locked-down mode). Binds the vault 'vault' sub-resource to a NIC in snet-pe and
// registers its A record in the privatelink.vaultcore.<cloud> zone, so in-VNet callers resolve the
// vault FQDN to the PE. The VNet-integrated runner env then resolves gh-pat over the VNet.
resource pe 'Microsoft.Network/privateEndpoints@2024-01-01' = if (privateNetworking) {
  name: take('pe-${vaultName}', 64)
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'runner-kv'
        properties: {
          privateLinkServiceId: kv.id
          groupIds: [ 'vault' ]
        }
      }
    ]
  }
}

resource peDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = if (privateNetworking) {
  parent: pe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'vault'
        properties: {
          #disable-next-line BCP318 // guarded by the same privateNetworking condition
          privateDnsZoneId: vaultDnsZoneId
        }
      }
    ]
  }
}

output vaultName string = kv.name
output vaultUri string = kv.properties.vaultUri
output vaultId string = kv.id
output patSecretName string = 'gh-pat'
// Deterministic URI of the PAT secret the rotation helper writes and the runner Job reads.
output patSecretUri string = '${kv.properties.vaultUri}secrets/gh-pat'
output appKeySecretName string = 'gh-app-key'
// Deterministic URI of the GitHub App private-key secret (app auth mode). Same vault, same
// RBAC (runner UAMI holds Key Vault Secrets User over all secrets); written out-of-band by
// the rotation helper and read by the runner Job as a Key Vault reference.
output appKeySecretUri string = '${kv.properties.vaultUri}secrets/gh-app-key'
