// Test APIM subscriptions for subscriptionKey auth mode, scoped to rate-limit PRODUCTS.
//
// Each entry creates a subscription scoped to a product (apim-products.bicep), so the
// developer inherits that product's rate-limit / token-limit / quota tier AND a key valid
// for every API in the product. Move a developer between tiers by changing their `product`.
// The subscription Name is stamped onto telemetry as the developer (developer_upn).
//
// Fetch a key: az apim subscription show -g <rg> --service-name <apim> --sid dev1 \
//   --query primaryKey -o tsv   (add --query secondaryKey for the backup key)

param apimName string

@description('Test developer subscriptions. Each { name, product } scopes a key to a product tier. product must match a name from apim-products productTiers.')
param subscriptions array = [
  {
    name: 'dev1'
    product: 'byok-standard'
  }
  {
    name: 'dev2'
    product: 'byok-power'
  }
]

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource devSubs 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = [
  for s in subscriptions: {
    parent: apim
    name: s.name
    properties: {
      displayName: '${s.name} (BYOK ${s.product})'
      // Product scope: key inherits the product's throttle tier and all its APIs.
      scope: '${apim.id}/products/${s.product}'
      state: 'active'
      allowTracing: false
    }
  }
]

@description('SubscriptionIds (use as --sid with `az apim subscription show` to fetch keys).')
output subscriptionIds array = [for (s, i) in subscriptions: devSubs[i].name]
