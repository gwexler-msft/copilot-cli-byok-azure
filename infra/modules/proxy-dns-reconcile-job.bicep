// Scheduled Container Apps Job that keeps the subkey proxy's stable hostname (proxy.byok.internal)
// pointed at the proxy ACI's CURRENT private IP.
//
// WHY a Container Apps Job (and not an in-ACI sidecar): a VNet-injected ACI cannot obtain a
// managed-identity token in-container (IMDS 169.254.169.254 is unreachable in a VNet ACI), so a
// sidecar there can't authenticate to Azure. Container Apps supplies the identity via
// IDENTITY_ENDPOINT, so a job CAN. The job only calls ARM control-plane APIs (read the ACI IP,
// update the DNS record) — it needs no in-VNet data-path access — and runs in the existing runner
// environment (cae-runner), whose egress already allows ARM + Entra + ACR.
//
// Each cron run authenticates with this job's UAMI, reads the proxy ACI's ipAddress.ip, and repoints
// the A record if it drifted (the ACI IP moves whenever the container group is recreated). Least
// privilege: AcrPull on the shared ACR (image pull), Reader on the proxy ACI (read its IP), and
// Private DNS Zone Contributor on the proxy zone (repoint the record).

param location string
param namePrefix string
param envName string
param suffix string
param tags object = {}

@description('Cloud name for `az cloud set` in the reconcile script: AzureCloud or AzureUSGovernment. Pass cloudEnv.')
param cloudName string

@description('Resource id of the Container Apps environment that hosts this job (the runner env, cae-runner). Pass ghRunner.outputs.envId.')
param managedEnvironmentId string

@description('Workload profile on the environment to run the job in.')
param workloadProfileName string = 'Consumption'

@description('Login server of the shared ACR holding the pre-baked proxy-dns-reconciler image.')
param acrLoginServer string

@description('Name of the shared ACR (for scoping AcrPull to the reconciler UAMI).')
param acrName string

@description('Repository of the pre-baked reconciler image in the ACR.')
param imageRepository string = 'proxy-dns-reconciler'

@description('Tag of the pre-baked reconciler image (pin to a SHA in production; latest is fine for the pilots).')
param imageTag string = 'latest'

@description('Proxy container group (ACI) name whose current IP the job tracks.')
param proxyContainerGroupName string

@description('Private DNS zone hosting the proxy A record.')
param proxyDnsZoneName string

@description('Host label of the proxy A record under proxyDnsZoneName.')
param proxyHostLabel string

@description('Cron expression (UTC) for the reconcile cadence. Default every 15 minutes.')
param cronExpression string = '*/15 * * * *'

var jobName = take('caj-proxydns-${envName}-${suffix}', 32)

// UAMI the job authenticates as (Container Apps IDENTITY_ENDPOINT).
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: take('id-${namePrefix}-proxydnsjob-${envName}-${suffix}', 128)
  location: location
  tags: tags
}

// Existing resources the job touches (all in this resource group).
resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: acrName
}

resource proxyAci 'Microsoft.ContainerInstance/containerGroups@2023-05-01' existing = {
  name: proxyContainerGroupName
}

resource proxyZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: proxyDnsZoneName
}

// Built-in roles.
var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d') // AcrPull
var readerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7') // Reader
var dnsZoneContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b12aa53e-6015-4669-85d0-8515ebb3ae7f') // Private DNS Zone Contributor

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: acr
  name: guid(acr.id, uami.id, acrPullRoleId)
  properties: {
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleId
  }
}

resource aciReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: proxyAci
  name: guid(proxyAci.id, uami.id, readerRoleId)
  properties: {
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: readerRoleId
  }
}

resource dnsContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: proxyZone
  name: guid(proxyZone.id, uami.id, dnsZoneContributorRoleId)
  properties: {
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: dnsZoneContributorRoleId
  }
}

resource job 'Microsoft.App/jobs@2024-10-02-preview' = {
  name: jobName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  dependsOn: [
    acrPull
    aciReader
    dnsContributor
  ]
  properties: {
    environmentId: managedEnvironmentId
    workloadProfileName: workloadProfileName
    configuration: {
      triggerType: 'Schedule'
      replicaTimeout: 300
      replicaRetryLimit: 1
      scheduleTriggerConfig: {
        cronExpression: cronExpression
        parallelism: 1
        replicaCompletionCount: 1
      }
      // Pull the pre-baked image from the shared ACR via this job's UAMI (AcrPull).
      registries: [
        {
          server: acrLoginServer
          identity: uami.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'reconcile'
          image: '${acrLoginServer}/${imageRepository}:${imageTag}'
          env: [
            { name: 'AZ_CLOUD', value: cloudName }
            { name: 'MI_CLIENT_ID', value: uami.properties.clientId }
            { name: 'SUBSCRIPTION_ID', value: subscription().subscriptionId }
            { name: 'RG', value: resourceGroup().name }
            { name: 'CG', value: proxyContainerGroupName }
            { name: 'ZONE', value: proxyDnsZoneName }
            { name: 'LABEL', value: proxyHostLabel }
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]
    }
  }
}

output jobName string = job.name
output uamiPrincipalId string = uami.properties.principalId
