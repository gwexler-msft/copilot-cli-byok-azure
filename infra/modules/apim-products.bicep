// APIM products = developer rate-limit / token-limit / quota TIERS (subscriptionKey mode).
//
// Each product carries a product-scope policy with three independent throttles, all keyed
// on the calling subscription (the per-developer key):
//   1. rate-limit-by-key      — burst control (calls per minute)
//   2. azure-openai-token-limit — the real AI-cost guard (tokens per minute, prompt+completion)
//   3. quota-by-key           — hard monthly ceiling (calls per 30 days)
//
// Developers are GROUPED by assigning their subscription to a product (see
// apim-subscriptions.bicep). Move a developer between tiers by changing which product their
// subscription is scoped to — no policy edit. Tune a tier's numbers by editing productTiers
// and redeploying; the values are baked into each product's policy.
//
// Because the limits live here (product scope) the subscriptionKey API policies carry NO
// rate-limit of their own. In jwt mode there are no subscriptions/products, so the jwt API
// policies keep their own per-oid limits (parameterized via named values).

param apimName string

@description('Rate-limit tiers. Each becomes a published APIM product with a product-scope throttle policy. callsPerMinute=burst, tokensPerMinute=TPM cost guard, monthlyCallQuota=hard 30-day call ceiling.')
param productTiers array = [
  {
    name: 'byok-standard'
    displayName: 'BYOK Standard'
    description: 'Standard developer tier: modest burst + TPM, suitable for typical interactive coding use.'
    callsPerMinute: 60
    tokensPerMinute: 20000
    monthlyCallQuota: 50000
  }
  {
    name: 'byok-power'
    displayName: 'BYOK Power'
    description: 'Power developer tier: higher burst + TPM for heavy agentic / batch use.'
    callsPerMinute: 120
    tokensPerMinute: 60000
    monthlyCallQuota: 200000
  }
]

@description('API names to add to every PRODUCT TIER so a tier-scoped subscription is valid for all of them. Pass only the inference APIs actually deployed (foundry/aoai); do NOT include the discovery API here -- it has its own dedicated product.')
param apiNames array = []

@description('Name of the discovery API (modules/apim-discovery-api.bicep). Empty string skips creating the discovery product. The discovery API is linked ONLY to the byok-discovery product so standard tier keys cannot list models.')
param discoveryApiName string = ''

@description('Burst limit (calls/min) for the byok-discovery product. Discovery is a cheap metadata read, but we still cap to limit abuse of any leaked key. Ignored when discoveryApiName is empty.')
param discoveryCallsPerMinute int = 30

@description('Hard 30-day call ceiling for the byok-discovery product. Defaults small because discovery clients only need to list once per session. Ignored when discoveryApiName is empty.')
param discoveryMonthlyCallQuota int = 5000

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource products 'Microsoft.ApiManagement/service/products@2024-05-01' = [
  for t in productTiers: {
    parent: apim
    name: t.name
    properties: {
      displayName: t.displayName
      description: t.description
      subscriptionRequired: true
      approvalRequired: false
      state: 'published'
    }
  }
]

resource productPolicies 'Microsoft.ApiManagement/service/products/policies@2024-05-01' = [
  for (t, i) in productTiers: {
    parent: products[i]
    name: 'policy'
    properties: {
      format: 'rawxml'
      value: '<policies><inbound><base /><rate-limit-by-key calls="${t.callsPerMinute}" renewal-period="60" counter-key="@(context.Subscription.Id)" increment-condition="@(context.Response.StatusCode == 200)" remaining-calls-header-name="x-byok-calls-remaining" /><azure-openai-token-limit tokens-per-minute="${t.tokensPerMinute}" counter-key="@(context.Subscription.Id)" estimate-prompt-tokens="true" remaining-tokens-header-name="x-byok-tokens-remaining" tokens-consumed-header-name="x-byok-tokens-consumed" /><quota-by-key calls="${t.monthlyCallQuota}" renewal-period="2592000" counter-key="@(context.Subscription.Id)" /></inbound><outbound><base /></outbound><backend><base /></backend><on-error><base /></on-error></policies>'
    }
  }
]

// Flatten products x apiNames into product-API link pairs.
var productApiPairs = flatten(map(productTiers, t => map(apiNames, a => {
  product: t.name
  api: a
})))

resource productApis 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = [
  for pair in productApiPairs: {
    name: '${apimName}/${pair.product}/${pair.api}'
    dependsOn: [
      products
    ]
  }
]

// ------------------------------------------------------------------------------------
// byok-discovery product: dedicated product that contains ONLY the discovery API
// (apim-discovery-api.bicep). Subscriptions scoped to this product (e.g. 'smoke',
// 'admin-*' from apim-subscriptions.bicep) can GET /discovery/v1/models; standard
// tier subscriptions (byok-standard / byok-power) cannot. This is the gating
// mechanism for "who can list models?" -- it's a product-membership question
// auditable in the portal, not a policy expression allowlist.
//
// Throttles are deliberately minimal: no azure-openai-token-limit (discovery has no
// token usage), just a modest burst + quota guard in case a key leaks. Skipped
// entirely when discoveryApiName is empty (e.g. tests that don't deploy discovery).
// ------------------------------------------------------------------------------------

resource discoveryProduct 'Microsoft.ApiManagement/service/products@2024-05-01' = if (!empty(discoveryApiName)) {
  parent: apim
  name: 'byok-discovery'
  properties: {
    displayName: 'BYOK Discovery'
    description: 'Restricted product for model discovery (GET /v1/models). Subscriptions in this product are issued only to the smoke runner and explicitly named admin developers.'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

resource discoveryProductPolicy 'Microsoft.ApiManagement/service/products/policies@2024-05-01' = if (!empty(discoveryApiName)) {
  parent: discoveryProduct
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: '<policies><inbound><base /><rate-limit-by-key calls="${discoveryCallsPerMinute}" renewal-period="60" counter-key="@(context.Subscription.Id)" remaining-calls-header-name="x-byok-calls-remaining" /><quota-by-key calls="${discoveryMonthlyCallQuota}" renewal-period="2592000" counter-key="@(context.Subscription.Id)" /></inbound><outbound><base /></outbound><backend><base /></backend><on-error><base /></on-error></policies>'
  }
}

resource discoveryProductApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = if (!empty(discoveryApiName)) {
  name: '${apimName}/byok-discovery/${discoveryApiName}'
  dependsOn: [
    discoveryProduct
  ]
}

var tierProductNames = [for (t, i) in productTiers: products[i].name]

@description('Product names created (use as the productName in apim-subscriptions). Includes the byok-discovery product when discoveryApiName is non-empty.')
output productNames array = empty(discoveryApiName) ? tierProductNames : concat(tierProductNames, [ 'byok-discovery' ])
