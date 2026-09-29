using none

import { sharedInferenceTemplate as foundryInference, sharedModelsTemplate, sharedModelsAuthentication, responsesItemTemplate } from '../../infra/modules/apim-foundry-api.bicep'
import { sharedInferenceTemplate as aoaiInference } from '../../infra/modules/apim-aoai-api.bicep'
import { standaloneInferenceTemplate, standaloneModelsTemplate, standaloneResponsesTemplate, standaloneOwnershipCredential } from '../../samples/intellij/standalone/modules/intellij-apim.bicep'
import { defaultCallerJwtTiering, renderCallerLimits, renderCallerTierConfiguration } from '../../infra/modules/apim-caller-auth.bicep'

var tierCatalog = [
  { name: 'byok-standard', callsPerMinute: 60, tokensPerMinute: 100000, monthlyCallQuota: 50000 }
  { name: 'byok-power', callsPerMinute: 120, tokensPerMinute: 200000, monthlyCallQuota: 200000 }
]
var tierMappings = [
  { claimValue: 'Byok.Standard', tier: 'byok-standard' }
  { claimValue: 'Byok.Power', tier: 'byok-power' }
]
var tierConfigurations = {
  disabled: defaultCallerJwtTiering
  entra: { entra: { enabled: true, mappings: tierMappings }, okta: defaultCallerJwtTiering.okta }
  okta: { entra: defaultCallerJwtTiering.entra, okta: { enabled: true, claimName: 'byok_tier', mappings: tierMappings } }
  both: { entra: { enabled: true, mappings: tierMappings }, okta: { enabled: true, claimName: 'byok_tier', mappings: tierMappings } }
}
param callerTierLimits = [for entry in items(tierConfigurations): {
  name: entry.key
  configuration: renderCallerTierConfiguration(entry.value, tierCatalog)
  policy: renderCallerLimits(entry.value, tierCatalog)
}]

var maximumNamePadding = 'tttttttttttttttt'
var maximumClaimPadding = 'rrrrrrrrrrrrrrrr'
var maximumCatalog = map(['0', '1', '2', '3', '4', '5', '6', '7'], ordinal => {
  name: '${maximumNamePadding}${maximumNamePadding}${maximumNamePadding}${maximumNamePadding}ttttttttttttttt${ordinal}'
  callsPerMinute: 2147483647
  tokensPerMinute: 2147483647
  monthlyCallQuota: 2147483647
})
var maximumMappings = map(['00', '01', '02', '03', '04', '05', '06', '07', '08', '09', '10', '11', '12', '13', '14', '15'], ordinal => {
  claimValue: '${maximumClaimPadding}${maximumClaimPadding}${maximumClaimPadding}${maximumClaimPadding}${maximumClaimPadding}${maximumClaimPadding}${maximumClaimPadding}rrrrrrrrrrrrrr${ordinal}'
  tier: maximumCatalog[int(ordinal) % 8].name
})
param maximumCallerTierLimits = renderCallerLimits({
  entra: { enabled: true, mappings: maximumMappings }
  okta: { enabled: true, claimName: '${maximumClaimPadding}${maximumClaimPadding}${maximumClaimPadding}${maximumClaimPadding}', mappings: maximumMappings }
}, maximumCatalog)

param policies = [
  { name: 'foundry-inference', format: 'rawxml', value: replace(foundryInference, '__NATIVE_SUBSCRIPTION_REQUIRED__', 'false') }
  { name: 'aoai-inference', format: 'rawxml', value: replace(aoaiInference, '__NATIVE_SUBSCRIPTION_REQUIRED__', 'false') }
  { name: 'foundry-models', format: 'xml', value: replace(sharedModelsTemplate, '__NATIVE_SUBSCRIPTION_REQUIRED__', 'false') }
  { name: 'responses-item', format: 'xml', value: replace(responsesItemTemplate, '__SHARED_AUTHENTICATION__', replace(sharedModelsAuthentication, '__NATIVE_SUBSCRIPTION_REQUIRED__', 'false')) }
]

param ownedResponsesPolicy = replace(responsesItemTemplate, '__SHARED_AUTHENTICATION__', replace(sharedModelsAuthentication, '__NATIVE_SUBSCRIPTION_REQUIRED__', 'true'))

param realResponsesInferencePolicy = replace(foundryInference, '__NATIVE_SUBSCRIPTION_REQUIRED__', 'true')
param realResponsesModelsPolicy = replace(sharedModelsTemplate, '__NATIVE_SUBSCRIPTION_REQUIRED__', 'true')

param standalone = {
  inference: standaloneInferenceTemplate
  models: standaloneModelsTemplate
  responses: standaloneResponsesTemplate
  backendCredential: standaloneOwnershipCredential
}