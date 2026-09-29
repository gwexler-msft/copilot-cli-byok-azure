using none

import { sourcePolicies, disabledValidator, callerTierBranchTemplate, callerTierLimitsTemplate } from '../../../infra/modules/apim-caller-auth.bicep'
import { lookupSources } from '../../../infra/modules/apim-response-ownership.bicep'
import { jwtProductGuardTemplate } from '../../../infra/modules/apim-jwt-product.bicep'
import { sharedModelsAuthentication, sharedResponsesPreparation, sharedCallerThrottleTelemetry, nativeCallerGuard } from '../../../infra/modules/apim-foundry-api.bicep'
import { standaloneInferenceTemplate, standaloneModelsTemplate, standaloneResponsesTemplate, standaloneOwnershipCredential } from './modules/intellij-apim.bicep'

var authenticationWithSource = replace(sourcePolicies['byok-authenticate'], '<include-fragment fragment-id="byok-credential-source" />', replace(replace(sourcePolicies['byok-credential-source'], '<fragment>', ''), '</fragment>', ''))
var evaluationOnly = substring(lookupSources.verify, length('<fragment>'), indexOf(lookupSources.verify, '<choose>') - length('<fragment>'))
var ownerLookup = replace(replace(replace(lookupSources.locate, '<include-fragment fragment-id="byok-response-backend-credential" />', replace(replace(standaloneOwnershipCredential, '<fragment>', ''), '</fragment>', '')), '<include-fragment fragment-id="byok-read-response-owner" />', replace(replace(lookupSources.read, '<fragment>', ''), '</fragment>', '')), '<include-fragment fragment-id="byok-evaluate-response-owner" />', evaluationOnly)

param callerPackage = {
  version: 1
  tiering: {
    version: 1
    branchTemplate: callerTierBranchTemplate
    policyTemplate: callerTierLimitsTemplate
  }
  authentication: authenticationWithSource
  entraValidator: sourcePolicies['byok-validate-entra']
  oktaValidator: sourcePolicies['byok-validate-okta']
  disabledValidator: disabledValidator
  jwtProductGuard: jwtProductGuardTemplate
  ownershipCredential: standaloneOwnershipCredential
  authenticationEntry: sharedModelsAuthentication
  responsesPreparation: sharedResponsesPreparation
  throttleTelemetry: sharedCallerThrottleTelemetry
  nativeCallerGuard: nativeCallerGuard
  fragments: {
    'byok-strip-caller-credentials': sourcePolicies['byok-strip-caller-credentials']
    'byok-apply-caller-limits': sourcePolicies['byok-apply-caller-limits']
    'byok-response-owner-context': loadTextContent('../../../policies/fragments/byok-response-owner-context.xml')
    'byok-prepare-responses-request': loadTextContent('../../../policies/fragments/byok-prepare-responses-request.xml')
    'byok-read-response-owner': lookupSources.read
    'byok-verify-response-owner': lookupSources.verify
    'byok-locate-response-owner': ownerLookup
  }
  inference: standaloneInferenceTemplate
  models: standaloneModelsTemplate
  responses: standaloneResponsesTemplate
}