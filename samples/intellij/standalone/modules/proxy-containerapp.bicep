@description('Name of the proxy Container App.')
param proxyAppName string

param location string

@description('Derived from the existing environment by containerapp.bicep; only private VNet-integrated environments are accepted.')
@allowed([true])
param privateEnvironmentValidated bool

@description('Existing private VNet-integrated environment. Use deploy-containerapp helpers to enforce the internal or private-endpoint preflight.')
param environmentName string

@description('Resource group of the existing environment, in this subscription.')
param environmentResourceGroup string

@description('Approved nginx image with /etc/nginx/conf.d and the system CA bundle. Must be anonymously pullable from the environment.')
param proxyImage string

param apimPrivateIp string
param apimGatewayHost string
param intellijApiPath string = 'intellij'

@minValue(1)
@maxValue(10)
param maxReplicas int = 3

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: environmentName
  scope: resourceGroup(environmentResourceGroup)
}

var nginxConf = replace(replace(replace(loadTextContent('../nginx.containerapp.conf'), '__APIM_PRIVATE_IP__', apimPrivateIp), '__APIM_GATEWAY_HOST__', apimGatewayHost), '__INTELLIJ_API_PATH__', intellijApiPath)

resource proxy 'Microsoft.App/containerApps@2024-03-01' = {
  name: proxyAppName
  location: location
  properties: {
    managedEnvironmentId: environment.id
    configuration: {
      activeRevisionsMode: 'Single'
      secrets: [
        #disable-next-line use-secure-value-for-secure-inputs
        { name: 'nginx-config', value: nginxConf }
      ]
      ingress: {
        external: privateEnvironmentValidated
        targetPort: 8080
        transport: 'http'
        allowInsecure: false
      }
    }
    template: {
      containers: [
        {
          name: 'nginx'
          image: proxyImage
          env: [
            { name: 'NGINX_CONFIG_VERSION', value: uniqueString(nginxConf) }
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          volumeMounts: [
            { volumeName: 'nginx-config', mountPath: '/etc/nginx/conf.d' }
          ]
          probes: [for probeType in ['Startup', 'Readiness', 'Liveness']: {
            type: probeType
            httpGet: {
              path: '/healthz'
              port: 8080
              scheme: 'HTTP'
            }
            initialDelaySeconds: 3
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          }]
        }
      ]
      volumes: [
        {
          name: 'nginx-config'
          storageType: 'Secret'
          secrets: [
            { secretRef: 'nginx-config', path: 'default.conf' }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http-concurrency'
            http: {
              metadata: { concurrentRequests: '20' }
            }
          }
        ]
      }
    }
  }
}

output clientBaseUrl string = 'https://${proxy.properties.configuration.ingress.fqdn}/${intellijApiPath}/v1'