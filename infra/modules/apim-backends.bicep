// APIM Backend entities for the AI accounts, with optional multi-region load-balanced pools
// and circuit breakers — while keeping the managed-identity auth route unchanged.
//
// Why this exists:
//   The policies select the backend with `set-backend-service backend-id="{{...-backend-id}}"`
//   instead of an inline base-url. A Backend *entity* can be either a single Url backend
//   (functionally identical to the old base-url) OR a Pool backend that load-balances and
//   fails over across several per-region Url backends. MI auth is orthogonal: the policy still
//   mints one Entra token (audience = the shared Cognitive Services audience) that is valid
//   against every regional account, so pooling composes with MI for free. RBAC must be granted
//   on EVERY member account (done in rbac.bicep) or that member silently returns 401/403.
//
// Single-region (default): one Url backend named `foundry` / `aoai`.
// Multi-region (deployBackendPool): `foundry` + `foundry-r1`, `foundry-r2`, ... and a
//   `foundry-pool` Pool backend that the backend-id named value points at.

param apimName string

@description('Foundry primary private base URL. Empty = Foundry backend not created.')
param foundryPrimaryUrl string = ''

@description('Foundry secondary-region private base URLs (backend-pool members beyond the primary).')
param foundryRegionalUrls array = []

@description('AOAI primary private base URL. Empty = AOAI backend not created.')
param aoaiPrimaryUrl string = ''

@description('AOAI secondary-region private base URLs (backend-pool members beyond the primary).')
param aoaiRegionalUrls array = []

@description('COMMERCIAL Foundry PUBLIC base URL (reached over the public internet from the Gov VNet via the NAT gateway). Empty = the foundry-commercial backend is not created. Placeholder <COMMERCIAL_FOUNDRY_BASE_URL> until supplied. Single endpoint only — no multi-region pool for the commercial route.')
param foundryCommercialUrl string = ''

@description('Attach a circuit breaker to each Url backend (trips on 429 + 5xx, honoring Retry-After for PTU->PAYG spillover).')
param enableCircuitBreaker bool = false

@description('Circuit breaker: failures within the interval that trip the breaker.')
param breakerFailureCount int = 5

@description('Circuit breaker: rolling window the failures are counted over (ISO-8601 duration).')
param breakerInterval string = 'PT1M'

@description('Circuit breaker: how long the backend stays tripped once opened (ISO-8601 duration).')
param breakerTripDuration string = 'PT1M'

@description('Pool member distribution. priority = active/passive (primary serves all traffic; secondary regions only take over when the primary trips/opens its breaker). weighted = active/active, load-balanced equally across every region.')
@allowed([
  'priority'
  'weighted'
])
param poolStrategy string = 'priority'

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

// Status ranges that count as a backend failure: 429 (throttle / capacity) + all 5xx.
var breakerRules = enableCircuitBreaker ? [
  {
    name: 'capacity-and-5xx'
    failureCondition: {
      count: breakerFailureCount
      interval: breakerInterval
      statusCodeRanges: [
        { min: 429, max: 429 }
        { min: 500, max: 599 }
      ]
    }
    tripDuration: breakerTripDuration
    // Honor a Foundry Retry-After so PTU 429s spill over to the next pool member promptly.
    acceptRetryAfter: true
  }
] : []

var foundryEnabled = !empty(foundryPrimaryUrl)
var aoaiEnabled    = !empty(aoaiPrimaryUrl)
var foundryCommercialEnabled = !empty(foundryCommercialUrl)
// Ordered member lists, primary-first. A Pool is only created when there is more than one member.
var foundryBaseUrls = foundryEnabled ? concat([foundryPrimaryUrl], foundryRegionalUrls) : []
var aoaiBaseUrls    = aoaiEnabled ? concat([aoaiPrimaryUrl], aoaiRegionalUrls) : []
var foundryPooled   = length(foundryBaseUrls) > 1
var aoaiPooled      = length(aoaiBaseUrls) > 1

// ---- Foundry Url backends (one per region) -------------------------------------------------
resource foundryUrlBackends 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = [for (url, i) in foundryBaseUrls: {
  parent: apim
  name: i == 0 ? 'foundry' : 'foundry-r${i}'
  properties: {
    protocol: 'http'
    url: url
    circuitBreaker: enableCircuitBreaker ? { rules: breakerRules } : null
  }
}]

resource foundryPool 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = if (foundryPooled) {
  parent: apim
  name: 'foundry-pool'
  properties: {
    type: 'Pool'
    pool: {
      // weighted => every region priority 1 (load-balanced by weight). priority => primary-first
      // failover tiers (primary=1, r1=2, r2=3, ...) so secondaries only serve when higher tiers are down.
      services: [for (url, i) in foundryBaseUrls: {
        id: foundryUrlBackends[i].id
        priority: poolStrategy == 'weighted' ? 1 : min(i + 1, 100)
        weight: 100
      }]
    }
  }
}

// ---- AOAI Url backends (one per region) ----------------------------------------------------
resource aoaiUrlBackends 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = [for (url, i) in aoaiBaseUrls: {
  parent: apim
  name: i == 0 ? 'aoai' : 'aoai-r${i}'
  properties: {
    protocol: 'http'
    url: url
    circuitBreaker: enableCircuitBreaker ? { rules: breakerRules } : null
  }
}]

resource aoaiPool 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = if (aoaiPooled) {
  parent: apim
  name: 'aoai-pool'
  properties: {
    type: 'Pool'
    pool: {
      services: [for (url, i) in aoaiBaseUrls: {
        id: aoaiUrlBackends[i].id
        priority: poolStrategy == 'weighted' ? 1 : min(i + 1, 100)
        weight: 100
      }]
    }
  }
}

// ---- Commercial Foundry Url backend (single, no pool) --------------------------------------
// A plain Url backend pointing at the COMMERCIAL Foundry public endpoint. The commercial policy
// targets it via set-backend-service backend-id="{{foundry-commercial-backend-id}}". Circuit
// breaker is reused (same toggle) so a flapping commercial endpoint trips out the same way.
resource foundryCommercialBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = if (foundryCommercialEnabled) {
  parent: apim
  name: 'foundry-commercial'
  properties: {
    protocol: 'http'
    url: foundryCommercialUrl
    circuitBreaker: enableCircuitBreaker ? { rules: breakerRules } : null
  }
}

@description('Backend-id the Foundry API policy should target. Empty when Foundry not deployed.')
output foundryBackendId string = foundryEnabled ? (foundryPooled ? 'foundry-pool' : 'foundry') : ''

@description('Backend-id the AOAI API policy should target. Empty when AOAI not deployed.')
output aoaiBackendId string = aoaiEnabled ? (aoaiPooled ? 'aoai-pool' : 'aoai') : ''

@description('Backend-id the Commercial Foundry API policy should target. Empty when the commercial backend is not created.')
output foundryCommercialBackendId string = foundryCommercialEnabled ? 'foundry-commercial' : ''
