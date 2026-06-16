# Apply the dedicated 'copilot-byok-discovery' API + 'byok-discovery' product +
# 'smoke' subscription on an APIM instance, and DELETE the now-obsolete list-models
# operation from copilot-byok-foundry. Idempotent (PUTs by name).
#
# Usage: ./apply-discovery-topology.ps1 -SubId <guid> -Rg <rg> -Apim <apim>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubId,
    [Parameter(Mandatory)][string]$Rg,
    [Parameter(Mandatory)][string]$Apim
)

$ErrorActionPreference = 'Stop'
$arm = (az cloud show --query 'endpoints.resourceManager' -o tsv).TrimEnd('/')
$svc = "$arm/subscriptions/$SubId/resourceGroups/$Rg/providers/Microsoft.ApiManagement/service/$Apim"
$ApiVer = '2024-05-01'

function Put-Json {
    param([string]$Url, [hashtable]$Body)
    $bodyFile = New-TemporaryFile
    try {
        $json = $Body | ConvertTo-Json -Depth 10 -Compress
        # Write WITHOUT a BOM so az rest's request body doesn't include the U+FEFF
        # that the response-parsing code chokes on with 'charmap' on Windows.
        [System.IO.File]::WriteAllText($bodyFile.FullName, $json, [System.Text.UTF8Encoding]::new($false))
        az rest --method put --url $Url --body "@$($bodyFile.FullName)" --headers 'Content-Type=application/json' -o none 2>&1 | Out-String | %{ $_.TrimEnd() } | ?{ $_ -notmatch '^WARNING.*Not a json response|charmap.*can.t encode' }
    } finally {
        Remove-Item $bodyFile.FullName -ErrorAction SilentlyContinue
    }
}

function Get-Url { param([string]$Url) az rest --method get --url $Url -o json 2>$null | ConvertFrom-Json }

Write-Host "==> APIM: $Apim ($Rg)" -ForegroundColor Cyan

# 1) Create the dedicated discovery API
Write-Host "  [1/5] API copilot-byok-discovery (path=discovery)"
Put-Json -Url "$svc/apis/copilot-byok-discovery?api-version=$ApiVer" -Body @{
    properties = @{
        displayName              = 'Copilot BYOK -> Discovery (list models)'
        path                     = 'discovery'
        protocols                = @('https')
        subscriptionRequired     = $true
        subscriptionKeyParameterNames = @{ header = 'api-key'; query = 'api-key' }
        apiType                  = 'http'
    }
}

# 2) Create the GET /v1/models operation on it
Write-Host "  [2/5] OP list-models GET /v1/models"
Put-Json -Url "$svc/apis/copilot-byok-discovery/operations/list-models?api-version=$ApiVer" -Body @{
    properties = @{ displayName = 'List Models'; method = 'GET'; urlTemplate = '/v1/models' }
}

# 3) Attach the API-level policy
Write-Host "  [3/5] API policy <- policies/byok-discovery-policy.xml"
$policyXml = Get-Content -Raw policies/byok-discovery-policy.xml
Put-Json -Url "$svc/apis/copilot-byok-discovery/policies/policy?api-version=$ApiVer" -Body @{
    properties = @{ format = 'rawxml'; value = $policyXml }
}

# 4) Create the byok-discovery product + product policy + product-api link
Write-Host "  [4/5] Product byok-discovery + policy + API link + smoke sub"
Put-Json -Url "$svc/products/byok-discovery?api-version=$ApiVer" -Body @{
    properties = @{
        displayName          = 'BYOK Discovery'
        description          = 'Restricted product for model discovery (GET /v1/models). Subscriptions in this product are issued only to the smoke runner and explicitly named admin developers.'
        subscriptionRequired = $true
        approvalRequired     = $false
        state                = 'published'
    }
}
$prodPolicy = '<policies><inbound><base /><rate-limit-by-key calls="30" renewal-period="60" counter-key="@(context.Subscription.Id)" remaining-calls-header-name="x-byok-calls-remaining" /><quota-by-key calls="5000" renewal-period="2592000" counter-key="@(context.Subscription.Id)" /></inbound><outbound><base /></outbound><backend><base /></backend><on-error><base /></on-error></policies>'
Put-Json -Url "$svc/products/byok-discovery/policies/policy?api-version=$ApiVer" -Body @{
    properties = @{ format = 'rawxml'; value = $prodPolicy }
}
# Link the discovery API to the product (PUT with empty body is the API-link verb)
az rest --method put --url "$svc/products/byok-discovery/apis/copilot-byok-discovery?api-version=$ApiVer" -o none 2>&1 | Out-String | %{ $_.TrimEnd() } | ?{ $_ -notmatch '^WARNING.*Not a json response|charmap.*can.t encode' }

# Smoke subscription
$svcId = "$svc"
Put-Json -Url "$svc/subscriptions/smoke?api-version=$ApiVer" -Body @{
    properties = @{
        displayName = 'smoke (BYOK byok-discovery)'
        scope       = "$svcId/products/byok-discovery"
        state       = 'active'
        allowTracing = $false
    }
}

# 5) Delete the now-obsolete list-models op from the foundry API (was added in the
#    earlier #61 surgical step before we moved discovery onto its own API).
Write-Host "  [5/5] DELETE copilot-byok-foundry/operations/list-models (obsolete)"
$exists = Get-Url -Url "$svc/apis/copilot-byok-foundry/operations/list-models?api-version=$ApiVer"
if ($exists) {
    az rest --method delete --url "$svc/apis/copilot-byok-foundry/operations/list-models?api-version=$ApiVer" -o none 2>&1 | Out-String | %{ $_.TrimEnd() } | ?{ $_ }
    Write-Host "      -> deleted"
} else {
    Write-Host "      -> already absent"
}

Write-Host "  ✔ done: $Apim" -ForegroundColor Green
