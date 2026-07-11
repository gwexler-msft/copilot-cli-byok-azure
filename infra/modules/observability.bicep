param namePrefix string
param envName string
param suffix string
param location string

var lawName = take('log-${namePrefix}-${envName}-${suffix}', 63)
var aiName  = take('appi-${namePrefix}-${envName}-${suffix}', 63)

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: aiName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

output logAnalyticsId string = law.id
output logAnalyticsName string = law.name
output logAnalyticsCustomerId string = law.properties.customerId
output appInsightsId string = appi.id
output appInsightsName string = appi.name
output appInsightsInstrumentationKey string = appi.properties.InstrumentationKey
// Full connection string (carries IngestionEndpoint + LiveEndpoint + ProfilerEndpoint). The APIM
// logger MUST use this (not the bare instrumentation key) so its Live Metrics/QuickPulse client
// targets the correct per-cloud endpoint. In Azure Government LiveEndpoint is
// https://live.applicationinsights.azure.us/ -- with only an ikey APIM defaults to the Commercial
// live endpoint and the Live Metrics blade shows "couldn't connect to your application".
output appInsightsConnectionString string = appi.properties.ConnectionString
