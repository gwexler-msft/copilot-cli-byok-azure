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
    description: 'Standard developer tier: sized so a normal interactive VS Code Copilot Chat session does not throttle. Chat packs editor context into each request (typically 13-15k tokens), so 100k TPM allows roughly 6-7 turns per minute.'
    callsPerMinute: 60
    tokensPerMinute: 100000
    monthlyCallQuota: 50000
  }
  {
    name: 'byok-power'
    displayName: 'BYOK Power'
    description: 'Power developer tier: higher burst + TPM for heavy agentic / batch use.'
    callsPerMinute: 120
    tokensPerMinute: 200000
    monthlyCallQuota: 200000
  }
]

@description('API names to add to every PRODUCT TIER so a tier-scoped subscription is valid for all of them. Pass only the inference APIs actually deployed (foundry/aoai).')
param apiNames array = []

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

// APIM child writes share service-level optimistic concurrency state. Serialize each phase and
// wait for the preceding phase to finish to avoid transient bad-ETag failures on fresh deploys.
@batchSize(1)
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

@batchSize(1)
resource productPolicies 'Microsoft.ApiManagement/service/products/policies@2024-05-01' = [
  for (t, i) in productTiers: {
    parent: products[i]
    name: 'policy'
    properties: {
      format: 'rawxml'
      value: '<policies><inbound><base /><rate-limit-by-key calls="${t.callsPerMinute}" renewal-period="60" counter-key="@(context.Subscription.Id)" increment-condition="@(context.Response.StatusCode == 200)" remaining-calls-header-name="x-byok-calls-remaining" /><azure-openai-token-limit tokens-per-minute="${t.tokensPerMinute}" counter-key="@(context.Subscription.Id)" estimate-prompt-tokens="true" remaining-tokens-header-name="x-byok-tokens-remaining" tokens-consumed-header-name="x-byok-tokens-consumed" /><quota-by-key calls="${t.monthlyCallQuota}" renewal-period="2592000" counter-key="@(context.Subscription.Id)" /></inbound><outbound><base /></outbound><backend><base /></backend><on-error><base /></on-error></policies>'
    }
    dependsOn: [
      products
    ]
  }
]

// Flatten products x apiNames into product-API link pairs.
var productApiPairs = flatten(map(productTiers, t => map(apiNames, a => {
  product: t.name
  api: a
})))

@batchSize(1)
resource productApis 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = [
  for pair in productApiPairs: {
    name: '${apimName}/${pair.product}/${pair.api}'
    dependsOn: [
      productPolicies
    ]
  }
]

var tierProductNames = [for (t, i) in productTiers: products[i].name]

@description('Product names created (use as the productName in apim-subscriptions).')
output productNames array = tierProductNames
