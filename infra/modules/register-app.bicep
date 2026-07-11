// Hosting for the self-serve "register" web app (issue #64 / #68).
//
// An EXTERNAL Azure Container Apps environment + Container App that runs the Blazor
// register UI / minimal-API. The env is NOT VNet-injected (control-plane-only app: it calls
// ARM to manage APIM subscriptions, not the APIM data plane), which sidesteps the documented
// internal-ingress L7 routing bug. Reachability is controlled by `privateNetworking`:
//   * true  (default): env publicNetworkAccess=Disabled + a managedEnvironments Private
//            Endpoint in snet-pe + privatelink ACA zone. The app stays external (so it
//            registers on the env public envoy) but is only reachable in-VNet (P2S VPN /
//            test VM). This is the validated "fully private" ACA pattern.
//   * false: plain public ingress (e.g. a laptop demo not on the VNet).
//
// Access control is layered:
//   1. Entra Easy Auth (authConfig 'current') — unauthenticated callers are redirected to
//      the Entra login page; only tenant users with a valid token reach the app.
//   2. The app runs as the least-privilege UAMI from apim-register-role.bicep (APIM
//      subscription CRUD + key actions + product read only).
//
// Easy Auth is wired only when `easyAuthClientId` is supplied. The first `azd provision`
// can run with it empty (placeholder image, no auth) so hosting comes up before the Entra
// app registration exists; a follow-up provision with the client id/secret turns auth on.

@description('Environment short name, e.g. gov-pilot, comm-pilot. Used in names.')
param envName string

@description('Stable 6-char suffix shared across the deployment for global uniqueness.')
param suffix string

@description('Azure region.')
param location string

@description('Log Analytics workspace name the ACA env streams app logs to. The module reads its customer ID and shared key directly to keep the secret out of the parent template.')
param logAnalyticsName string

@description('Resource ID of the user-assigned managed identity the app runs as (from apim-register-role.bicep).')
param registerUamiId string

@description('Client ID of that UAMI, surfaced to the app as AZURE_CLIENT_ID for DefaultAzureCredential.')
param registerUamiClientId string

@description('APIM service name, surfaced to the app so it can target the right service when provisioning subscriptions.')
param apimName string

@description('APIM gateway base URL, surfaced to the app to render the BYOK base URL in generated config.')
param apimGatewayUrl string

@description('Cloud moniker: AzureCloud or AzureUSGovernment. Surfaced to the app so its ARM client targets the right cloud.')
param cloudEnv string

@description('Entra login host for the cloud (login.microsoftonline.com / login.microsoftonline.us). Used to build the Easy Auth OpenID issuer.')
param entraLoginHost string

@description('Entra tenant ID. Used to build the Easy Auth OpenID issuer.')
param entraTenantId string

@description('Entra security group object ID whose members get the admin/offboard (revoke) surface. Empty disables the admin surface. Config-only; binds to Byok:AdminGroupId.')
param adminGroupId string = ''

@description('Entra security group object ID whose members get the byok-power tier instead of the default byok-standard. Empty => everyone defaults to byok-standard. Config-only; binds to Byok:TierMap[0].GroupId.')
param powerGroupId string = ''

@description('Make the app private: set the ACA env public network access to Disabled and front it with a Private Endpoint (managedEnvironments) in peSubnetId, plus a privatelink ACA zone linked to the VNet. The app stays external (registers on the env public envoy) but is only reachable in-VNet. Default true.')
param privateNetworking bool = true

@description('Resource ID of the subnet (snet-pe, privateEndpointNetworkPolicies Disabled) the env Private Endpoint NIC lands in. Required when privateNetworking=true.')
param peSubnetId string = ''

@description('Resource ID of the VNet the privatelink ACA zone links to. Required when privateNetworking=true.')
param vnetId string = ''

@description('Private DNS zone name for the ACA env, EXACTLY privatelink.<region>.azurecontainerapps.<io|us>. PE auto-A-record registration only happens when the name matches this scheme.')
param acaDnsZoneName string = ''

@description('Entra app registration (client) ID for Easy Auth. Leave empty to provision hosting WITHOUT auth (placeholder bring-up); set it to enable the login redirect.')
param easyAuthClientId string = ''

@description('Entra app registration client secret for Easy Auth. Required only when easyAuthClientId is set. Stored as a Container App secret. Prefer easyAuthSecretKeyVaultUri (Key Vault reference); this is the back-compat inline fallback.')
@secure()
param easyAuthClientSecret string = ''

@description('Key Vault secret URI for the Easy Auth client secret (from register-kv.bicep). When set, the Container App secret is a managed-identity Key Vault reference instead of an inline value, so the secret never flows through a Bicep param. Takes precedence over easyAuthClientSecret.')
#disable-next-line secure-secrets-in-params // this is a Key Vault reference URI, not the secret value
param easyAuthSecretKeyVaultUri string = ''

@description('Container image the app runs. Defaults to the .NET ASP.NET sample (listens on 8080) so `azd provision` produces a healthy revision before the real image is built; azd deploy swaps in the Blazor image.')
param registerImage string = 'mcr.microsoft.com/dotnet/samples:aspnetapp'

@description('ACR login server (e.g. acrreg<env><suffix>.azurecr.io) the real image is pushed to. Empty leaves the app pulling the public placeholder image; when set, a registries entry is added so the Container App pulls via its UAMI (which holds AcrPull). From register-acr.bicep.')
param acrLoginServer string = ''

@description('Container ingress target port. The Blazor app and the placeholder sample both listen on 8080.')
param targetPort int = 8080

@description('CPU cores per replica.')
param cpu string = '0.5'

@description('Memory per replica.')
param memory string = '1Gi'

@description('Tags applied to every resource the module creates.')
param tags object = {}

@description('Infrastructure subnet id (delegated to Microsoft.App/environments) to VNet-integrate the environment. When set, the env routes outbound through the VNet (so it can resolve a PRIVATE register Key Vault over a Private Endpoint) and the env is RECREATED. Empty = non-VNet-integrated (Azure-managed egress).')
param infrastructureSubnetId string = ''

var envNameAca = take('cae-register-${envName}-${suffix}', 32)
var appName    = take('ca-register-${envName}-${suffix}', 32)

var easyAuthEnabled = !empty(easyAuthClientId)

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsName
}

// External env + PNA-Disabled + PE = internal-only ingress (no public access allowed). When
// infrastructureSubnetId is set the env is ALSO VNet-integrated (outbound through the VNet), so it
// can resolve a PRIVATE register Key Vault over a Private Endpoint. NOTE: adding vnetConfiguration
// RECREATES the env (immutable) -> the app FQDN changes -> update the Easy Auth redirect URI after.
resource env 'Microsoft.App/managedEnvironments@2024-10-02-preview' = {
  name: envNameAca
  location: location
  tags: tags
  properties: {
    publicNetworkAccess: privateNetworking ? 'Disabled' : 'Enabled'
    vnetConfiguration: empty(infrastructureSubnetId) ? null : {
      infrastructureSubnetId: infrastructureSubnetId
      internal: false
    }
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

// Private inbound path (privateNetworking=true). The env's public access is Disabled above;
// a Private Endpoint binds the env's managed load balancer to a NIC in snet-pe, and the
// privatelink ACA zone (name MUST be privatelink.<region>.azurecontainerapps.<io|us>) gives
// the env apex an A record to that NIC, so in-VNet callers resolve <app>.<envDomain> to it.
resource pe 'Microsoft.Network/privateEndpoints@2024-01-01' = if (privateNetworking) {
  name: take('pe-${appName}', 64)
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'register-env'
        properties: {
          privateLinkServiceId: env.id
          groupIds: [ 'managedEnvironments' ]
        }
      }
    ]
  }
}

resource acaZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (privateNetworking) {
  name: acaDnsZoneName
  location: 'global'
  tags: tags
}

resource acaZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (privateNetworking) {
  parent: acaZone
  name: 'link-${envName}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}

resource peDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = if (privateNetworking) {
  parent: pe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'aca'
        properties: {
          #disable-next-line BCP318 // guarded by the same privateNetworking condition
          privateDnsZoneId: acaZone.id
        }
      }
    ]
  }
}

resource app 'Microsoft.App/containerApps@2024-10-02-preview' = {
  name: appName
  location: location
  // azd-service-name tag lets `azd deploy register` resolve this Container App once the
  // azure.yaml `register` service + a container registry output are wired in M3.
  tags: union(tags, { 'azd-service-name': 'register' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${registerUamiId}': {}
    }
  }
  properties: {
    environmentId: env.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      // When the ACR is wired (azd deploy path) the app pulls the real image via its UAMI,
      // which holds AcrPull on the registry. Empty until the registry exists; the public
      // placeholder image needs no registry credential.
      registries: empty(acrLoginServer) ? [] : [
        {
          server: acrLoginServer
          identity: registerUamiId
        }
      ]
      ingress: {
        external: true
        targetPort: targetPort
        transport: 'auto'
        allowInsecure: false
      }
      secrets: easyAuthEnabled ? [
        empty(easyAuthSecretKeyVaultUri) ? {
          name: 'easyauth-client-secret'
          value: easyAuthClientSecret
        } : {
          name: 'easyauth-client-secret'
          keyVaultUrl: easyAuthSecretKeyVaultUri
          identity: registerUamiId
        }
      ] : []
    }
    template: {
      containers: [
        {
          name: 'register'
          image: registerImage
          resources: {
            cpu: json(cpu)
            memory: memory
          }
          env: [
            {
              name: 'AZURE_CLIENT_ID'
              value: registerUamiClientId
            }
            {
              name: 'Byok__CloudEnv'
              value: cloudEnv
            }
            {
              name: 'Byok__SubscriptionId'
              value: subscription().subscriptionId
            }
            {
              name: 'Byok__ResourceGroup'
              value: resourceGroup().name
            }
            {
              name: 'Byok__ApimName'
              value: apimName
            }
            {
              name: 'Byok__ApimGatewayUrl'
              value: apimGatewayUrl
            }
            {
              name: 'Byok__TenantId'
              value: entraTenantId
            }
            {
              name: 'Byok__UamiClientId'
              value: registerUamiClientId
            }
            // Tier resolution (config-only group object IDs). Kept in the template so the
            // env array is deterministic and re-provisions don't drop the mapping.
            {
              name: 'Byok__DefaultProductId'
              value: 'byok-standard'
            }
            {
              name: 'Byok__AdminGroupId'
              value: adminGroupId
            }
            {
              name: 'Byok__TierMap__0__GroupId'
              value: powerGroupId
            }
            {
              name: 'Byok__TierMap__0__ProductId'
              value: 'byok-power'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

// Entra Easy Auth. Only created when a client id is supplied; otherwise the app is
// reachable without auth (placeholder bring-up phase).
resource auth 'Microsoft.App/containerApps/authConfigs@2024-10-02-preview' = if (easyAuthEnabled) {
  parent: app
  name: 'current'
  properties: {
    platform: {
      enabled: true
    }
    globalValidation: {
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureactivedirectory'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          openIdIssuer: 'https://${entraLoginHost}/${entraTenantId}/v2.0'
          clientId: easyAuthClientId
          clientSecretSettingName: 'easyauth-client-secret'
        }
        validation: {
          allowedAudiences: [
            'api://${easyAuthClientId}'
          ]
        }
      }
    }
  }
}

output envName string = env.name
output appName string = app.name
output appFqdn string = app.properties.configuration.ingress.fqdn
output appUrl string = 'https://${app.properties.configuration.ingress.fqdn}'
output easyAuthEnabled bool = easyAuthEnabled
output privateNetworking bool = privateNetworking
