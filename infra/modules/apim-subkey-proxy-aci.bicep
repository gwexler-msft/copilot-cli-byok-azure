// In-VNet "subkey proxy": a stock nginx running as an Azure Container Instance INJECTED into the
// VNet (snet-aci). It translates `Authorization: Bearer <apim-subscription-key>` into the `api-key`
// header and forwards the request to the private /openai route on APIM. This is what lets
// OpenAI-compatible IDE clients (e.g. JetBrains AI Assistant) that can ONLY send the credential as
// a Bearer token use their normal APIM subscription key (no expiring Entra token) — behaving exactly
// like calling Foundry with its endpoint + key.
//
// WHY ACI (not a loopback policy / Container App):
//  - APIM cannot validate a subscription key delivered as a Bearer token in-policy, and the only
//    bridge (looping APIM back to its own gateway) FAILS on Internal-mode APIM (Azure Load Balancer
//    does not support the backend->own-frontend hairpin -> connect timeout -> 500).
//  - The register Container App environment is NOT VNet-injected, so a container there cannot reach
//    the Internal (private) APIM.
//  - ACI injected into the VNet gets a private IP, resolves the APIM gateway FQDN via the VNet's
//    private DNS, and reaches it directly (no load balancer, no L7-routing bug). Reachable only
//    in-VNet (private IP, no public exposure).
//
// Streaming: nginx `proxy_buffering off` streams SSE (stream:true) end to end.

param location string
param namePrefix string
param envName string
param suffix string

@description('Resource id of the ACI-delegated subnet (network.outputs.aciSubnetId).')
param aciSubnetId string

@description('APIM gateway host (e.g. apim-...azure-api.us) the proxy forwards to. Pass apim.outputs.apimGatewayHost.')
param apimGatewayHost string

@description('nginx container image. The standard Docker Hub nginx mirrored on MCR (reachable under restricted egress; same /etc/nginx/conf.d layout this config targets).')
param image string = 'mcr.microsoft.com/mirror/docker/library/nginx:1.25'

@description('Path segment of the private inference route the proxy targets (matches the client base path). Default "openai".')
param targetPath string = 'openai'

param tags object = {}

@description('Resource id of the VNet to link the proxy private DNS zone to, so in-VNet clients resolve the stable proxy hostname. Pass network.outputs.vnetId.')
param vnetId string

@description('Private DNS zone (VNet-linked) that hosts the stable proxy hostname. An A record for proxyHostLabel is (re)set to the ACI CURRENT private IP on every provision, so clients use a fixed FQDN and never chase the dynamic ACI IP.')
param proxyDnsZoneName string = 'byok.internal'

@description('Host label under proxyDnsZoneName for the proxy A record. FQDN = <proxyHostLabel>.<proxyDnsZoneName> (e.g. proxy.byok.internal).')
param proxyHostLabel string = 'proxy'

var cgName = take('aci-${namePrefix}-subkeyproxy-${envName}-${suffix}', 63)

// nginx conf mounted at /etc/nginx/conf.d/default.conf (included by the stock nginx.conf inside
// http{}). The `map` extracts the key from `Authorization: Bearer <key>` (empty when absent/not
// Bearer). EVERY path (including GET /v1/models) re-injects the key as `api-key`, drops
// Authorization, and proxies to the private APIM host preserving the request URI (client base =
// http://${proxyHostLabel}.${proxyDnsZoneName}:8080/<targetPath>/v1 via the VNet private DNS zone). The model list is served BY APIM: its list-models
// policy fetches the live Foundry deployments, reshapes them to the OpenAI /v1/models format, and
// injects the "auto" sentinel — so the proxy no longer hardcodes a list and new deployments appear
// automatically. nginx variables ($http_authorization, $byok_key, $1) are literal here; only
// ${apimGatewayHost} is a Bicep interpolation.
var nginxConf = 'map $http_authorization $byok_key {\n    default "";\n    "~*^Bearer (.+)$" $1;\n}\n\nserver {\n    listen 8080;\n    server_name _;\n    location / {\n        proxy_pass https://${apimGatewayHost};\n        proxy_set_header Host ${apimGatewayHost};\n        proxy_set_header api-key $byok_key;\n        proxy_set_header Authorization "";\n        proxy_ssl_server_name on;\n        proxy_http_version 1.1;\n        proxy_buffering off;\n        proxy_request_buffering off;\n        proxy_read_timeout 600s;\n        client_max_body_size 50m;\n    }\n}\n'

resource cg 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: cgName
  location: location
  tags: tags
  properties: {
    osType: 'Linux'
    restartPolicy: 'Always'
    subnetIds: [
      { id: aciSubnetId }
    ]
    ipAddress: {
      type: 'Private'
      ports: [
        { protocol: 'TCP', port: 8080 }
      ]
    }
    volumes: [
      {
        name: 'nginxconf'
        secret: {
          'default.conf': base64(nginxConf)
        }
      }
    ]
    containers: [
      {
        name: 'nginx'
        properties: {
          image: image
          ports: [
            { protocol: 'TCP', port: 8080 }
          ]
          resources: {
            requests: {
              cpu: json('0.5')
              memoryInGB: json('0.5')
            }
          }
          volumeMounts: [
            {
              name: 'nginxconf'
              mountPath: '/etc/nginx/conf.d'
              readOnly: true
            }
          ]
        }
      }
    ]
  }
}

output privateIp string = cg.properties.ipAddress.ip

// Stable private DNS name for the proxy. ACI in a VNet gets a DYNAMIC private IP with no way to pin
// it, so rather than expose the changing IP we give clients a fixed FQDN: a VNet-linked private DNS
// zone whose A record points at the ACI's CURRENT IP. Bicep resets the A record to
// cg.properties.ipAddress.ip on every provision, so a full reprovision (which can move the IP)
// transparently updates the record and IDE base URLs never change. Low TTL so any move converges fast.
resource proxyZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: proxyDnsZoneName
  location: 'global'
  tags: tags
}

resource proxyZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: proxyZone
  name: 'link-${envName}-${suffix}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}

resource proxyARecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: proxyZone
  name: proxyHostLabel
  properties: {
    ttl: 60
    aRecords: [
      { ipv4Address: cg.properties.ipAddress.ip }
    ]
  }
}

output proxyFqdn string = '${proxyHostLabel}.${proxyDnsZoneName}'
output proxyBaseUrl string = 'http://${proxyHostLabel}.${proxyDnsZoneName}:8080/${targetPath}/v1'
output containerGroupName string = cg.name
output proxyDnsZoneName string = proxyDnsZoneName
output proxyHostLabel string = proxyHostLabel
