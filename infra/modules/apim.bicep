param namePrefix string
param envName string
param suffix string
param location string

@allowed(['Developer', 'Premium'])
param apimSku string

param apimPublisherEmail string
param apimPublisherName string
param apimSubnetId string

param appInsightsId string
@secure()
param appInsightsInstrumentationKey string

param logAnalyticsId string

var apimName = take('apim-${namePrefix}-${envName}-${suffix}', 50)

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  sku: {
    name: apimSku
    capacity: 1
  }
  identity: { type: 'SystemAssigned' }
  properties: {
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
    virtualNetworkType: 'Internal'
    virtualNetworkConfiguration: { subnetResourceId: apimSubnetId }
    // Internal VNet mode already isolates all endpoints to private VNet IPs (no public
    // data-plane endpoint). `publicNetworkAccess: Disabled` is for the External + Private
    // Endpoint pattern and is rejected at create time for Internal mode
    // (ActivateServiceWithPrivateEndpointAccessNotAllowed).
  }
}

resource appiLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'appinsights'
  properties: {
    loggerType: 'applicationInsights'
    resourceId: appInsightsId
    credentials: { instrumentationKey: appInsightsInstrumentationKey }
    isBuffered: true
  }
}

// Wire the logger into the request pipeline. WITHOUT this service-level `diagnostics`
// resource the `appinsights` logger exists but APIM emits NO request/dependency
// telemetry to Application Insights (the logger alone is inert). Applies to all APIs
// unless an API-level diagnostics overrides it. Sampling 100% for the pilot.
resource appiDiagnostics 'Microsoft.ApiManagement/service/diagnostics@2024-05-01' = {
  parent: apim
  name: 'applicationinsights'
  properties: {
    loggerId: appiLogger.id
    alwaysLog: 'allErrors'
    // metrics:true is REQUIRED for `emit-metric` policy to flow into Application
    // Insights customMetrics/AppMetrics. Without it APIM logs:
    //   "No diagnostic settings have metric enabled. Metric emission skipped."
    // (silently dropping every emit-metric call). See:
    // https://learn.microsoft.com/azure/api-management/api-management-advanced-policies#emit-metric
    metrics: true
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    httpCorrelationProtocol: 'W3C'
    verbosity: 'information'
    logClientIp: true
    frontend: {
      request: { headers: [], body: { bytes: 0 } }
      response: { headers: [], body: { bytes: 0 } }
    }
    backend: {
      request: { headers: [], body: { bytes: 0 } }
      response: { headers: [], body: { bytes: 0 } }
    }
  }
}

resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: apim
  name: 'to-log-analytics'
  properties: {
    workspaceId: logAnalyticsId
    // `Dedicated` routes each provider's logs into a resource-specific table
    // (`ApiManagementGatewayLogs`, `ApiManagementWebSocketConnectionLogs`, ...)
    // instead of the catch-all legacy `AzureDiagnostics` table. The KQL files in
    // monitoring/kql/ (error-rate.kql, throttle-hits-per-developer.kql, ...)
    // query the resource-specific table; without this setting they return 0 rows
    // even when traffic is flowing.
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

output apimName string = apim.name
output apimGatewayUrl string = apim.properties.gatewayUrl
output apimPrincipalId string = apim.identity.principalId
output appiLoggerId string = appiLogger.id
output apimPrivateIp string = apim.properties.privateIPAddresses[0]
output apimGatewayHost string = replace(apim.properties.gatewayUrl, 'https://', '')
