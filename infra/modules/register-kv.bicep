// Key Vault for the self-serve "register" app's Easy Auth client secret (issue #64 / #68).
//
// The register app is fronted by Entra Easy Auth, whose confidential-client login leg needs a
// client secret (there is no managed-identity / federated-credential option for that leg). We
// keep that secret OUT of source control and out of azd state by storing it in this RBAC-mode
// Key Vault: the `scripts/setup-register-entra.*` helper writes it, and the Container App
// references it by `keyVaultUrl` (no plaintext ever flows through a Bicep param).
//
// Access model (RBAC, no access policies):
//   - the register UAMI gets "Key Vault Secrets User" (read) so the Container App can resolve
//     the secret reference at runtime;
//   - the deploying principal optionally gets "Key Vault Secrets Officer" (write) so the
//     setup script can set/rotate the secret. When `deployerPrincipalId` is empty (e.g. CI,
//     where it is resolved at runtime) the script self-grants this role instead.
//
// Only created when deployRegisterApp=true (gated in main.bicep).

@description('Environment short name, e.g. gov-pilot, comm-pilot. Used in names.')
param envName string

@description('Stable 6-char suffix shared across the deployment for global uniqueness.')
param suffix string

@description('Azure region.')
param location string

@description('Tenant ID the vault belongs to.')
param tenantId string

@description('Principal ID of the register app UAMI (from apim-register-role.bicep). Granted Key Vault Secrets User (read) so the Container App can resolve the Easy Auth secret reference.')
param registerUamiPrincipalId string

@description('Object ID of the deploying principal, granted Key Vault Secrets Officer (write) so the setup script can set the secret. Empty => the script self-grants at runtime (CI path).')
param deployerPrincipalId string = ''

@description('Lock the vault down: publicNetworkAccess=Disabled + a Private Endpoint. The register env MUST be VNet-integrated (infrastructureSubnetId set on the env) to resolve the Easy Auth secret over the PE. Requires peSubnetId + vaultDnsZoneId.')
param privateNetworking bool = false

@description('Subnet id for the Private Endpoint (snet-pe). Required when privateNetworking=true.')
param peSubnetId string = ''

@description('Resource id of the privatelink.vaultcore.<cloud> zone the PE binds to. Required when privateNetworking=true.')
param vaultDnsZoneId string = ''

@description('Tags applied to every resource the module creates.')
param tags object = {}

// KV names: 3-24 chars, alphanumeric + hyphens, must start with a letter, globally unique.
var vaultName = take('kvreg${replace(envName, '-', '')}${suffix}', 24)

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
    // Locked down => only the Private Endpoint reaches the vault; the VNet-integrated register env
    // resolves the Easy Auth secret over the PE. bypass:AzureServices kept for first-party services.
    publicNetworkAccess: privateNetworking ? 'Disabled' : 'Enabled'
    networkAcls: privateNetworking ? {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    } : null
  }
}

// Register UAMI: read the Easy Auth secret (Container App keyVaultUrl reference resolves as the UAMI).
resource uamiSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: kv
  name: guid(kv.id, registerUamiPrincipalId, secretsUserRoleId)
  properties: {
    principalId: registerUamiPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: secretsUserRoleId
  }
}

// Deploying principal (when known): write/rotate the secret via the setup script.
resource deployerSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerPrincipalId)) {
  scope: kv
  name: guid(kv.id, deployerPrincipalId, secretsOfficerRoleId)
  properties: {
    principalId: deployerPrincipalId
    roleDefinitionId: secretsOfficerRoleId
  }
}

// Private Endpoint (locked-down mode). Binds the vault 'vault' sub-resource to a NIC in snet-pe and
// registers its A record in the privatelink.vaultcore.<cloud> zone. The VNet-integrated register env
// resolves the Easy Auth secret over the VNet.
resource pe 'Microsoft.Network/privateEndpoints@2024-01-01' = if (privateNetworking) {
  name: take('pe-${vaultName}', 64)
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'register-kv'
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
// Deterministic URI of the Easy Auth secret the setup script writes and the Container App reads.
output easyAuthSecretUri string = '${kv.properties.vaultUri}secrets/register-easyauth-secret'
output easyAuthSecretName string = 'register-easyauth-secret'
