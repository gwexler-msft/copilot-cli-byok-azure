<#
.SYNOPSIS
    Deploy the BASIC Foundry gateway profile onto an existing APIM instance.

.DESCRIPTION
    Creates (idempotently) everything the BASIC profile needs, so nobody has to hand-type
    operations in the portal:

      1. A backend pointing at the Foundry account, with the REQUIRED trailing /openai.
      2. The API, imported from policies/wizard-foundry-basic-openapi.json, which creates
         all four operations: /v1/responses, /v1/chat/completions,
         /deployments/{deployment}/chat/completions and /v1/models.
      3. subscriptionKeyParameterNames set to 'api-key'. APIM's DEFAULT is
         'Ocp-Apim-Subscription-Key'; Copilot CLI (COPILOT_PROVIDER_TYPE=azure) can only
         send 'api-key', so leaving the default gives an unfixable-looking 401.
      4. The API-scope policy, with placeholders substituted.
      5. The operation-scope policy on listModels only (it must NOT inherit the API policy,
         which parses a request body a GET does not have).
      6. Optionally, the 'Cognitive Services OpenAI User' role for the APIM managed identity.

    Safe to re-run: every step is a PUT of desired state.

.PARAMETER ResourceGroup
    Resource group holding the APIM instance.

.PARAMETER ApimName
    APIM service name.

.PARAMETER FoundryAccountName
    Foundry / AI Services account name. Its real endpoint is read from Azure, so the script
    never has to guess between openai.azure.us, cognitiveservices.azure.us and services.ai.

.PARAMETER FoundryResourceGroup
    Resource group of the Foundry account. Defaults to -ResourceGroup.

.PARAMETER ApiPath
    API URL suffix. MUST be 'openai' for Copilot CLI: the azure provider discards any path
    on the base URL and always calls <origin>/openai/...

.PARAMETER GrantRbac
    Also grant the APIM managed identity 'Cognitive Services OpenAI User' on the account.

.PARAMETER DryRun
    Print what would change and exit without writing anything.

.EXAMPLE
    ./scripts/deploy-basic-foundry-gateway.ps1 -ResourceGroup rg-ai -ApimName apim-dev -FoundryAccountName myfoundry -DryRun

.EXAMPLE
    ./scripts/deploy-basic-foundry-gateway.ps1 -ResourceGroup rg-ai -ApimName apim-dev -FoundryAccountName myfoundry -GrantRbac

.NOTES
    Windows PowerShell 5.1 compatible. Requires the Azure CLI, logged in to the right cloud
    and subscription (`az account show`).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$ApimName,
    [Parameter(Mandatory = $true)][string]$FoundryAccountName,
    [string]$FoundryResourceGroup,
    [string]$ApiId = 'copilot-byok-foundry-basic',
    [string]$ApiDisplayName = 'Copilot BYOK -> Foundry (basic)',
    [string]$ApiPath = 'openai',
    [string]$BackendId = 'foundry-backend',
    [string]$SpecPath = 'policies/wizard-foundry-basic-openapi.json',
    [string]$ApiPolicyPath = 'policies/wizard-foundry-policy-basic.xml',
    [string]$ModelsPolicyPath = 'policies/wizard-foundry-policy-basic-models.xml',
    [string]$ModelsOperationId = 'listModels',
    [switch]$GrantRbac,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ApiVersion = '2024-05-01'
if (-not $FoundryResourceGroup) { $FoundryResourceGroup = $ResourceGroup }

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Info { param([string]$m) Write-Host "    $m" }
function Write-Warn { param([string]$m) Write-Host "!!  $m" -ForegroundColor Yellow }

function Invoke-Arm {
    param([string]$Method, [string]$Url, [string]$BodyJson)
    if ($DryRun) { Write-Info "DRY RUN would $Method $($Url -replace '\?.*$','')"; return $null }
    if ($BodyJson) {
        $tmp = [IO.Path]::GetTempFileName()
        try {
            [IO.File]::WriteAllText($tmp, $BodyJson, [Text.UTF8Encoding]::new($false))
            return az rest --method $Method --url $Url --headers "Content-Type=application/json" --body "@$tmp" -o json 2>&1
        } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
    return az rest --method $Method --url $Url -o json 2>&1
}

# --- context -----------------------------------------------------------------
Write-Step 'Resolving Azure context'
$sub = az account show --query id -o tsv
if (-not $sub) { throw 'Not logged in. Run az login (in the correct cloud) first.' }
$cloud = az cloud show --query name -o tsv
$arm = (az cloud show --query endpoints.resourceManager -o tsv).TrimEnd('/')
Write-Info "cloud=$cloud  subscription=$sub"

# Audience follows the CLOUD, not the model or api-version.
switch ($cloud) {
    'AzureUSGovernment' { $miAudience = 'https://cognitiveservices.azure.us' }
    'AzureCloud'        { $miAudience = 'https://cognitiveservices.azure.com' }
    default             { throw "Unsupported cloud '$cloud'. Add its Cognitive Services audience above." }
}
Write-Info "managed-identity audience = $miAudience"

# --- backend -----------------------------------------------------------------
Write-Step "Resolving Foundry endpoint for '$FoundryAccountName'"
$endpoint = az cognitiveservices account show -n $FoundryAccountName -g $FoundryResourceGroup --query properties.endpoint -o tsv
if (-not $endpoint) { throw "Could not read the endpoint for '$FoundryAccountName' in '$FoundryResourceGroup'." }
# The BASIC policies do no path rewriting for inference, so /openai has to live on the backend.
$backendUrl = $endpoint.TrimEnd('/') + '/openai'
Write-Info "backend url = $backendUrl"

Write-Step "Upserting backend '$BackendId'"
$backendBody = @{ properties = @{ url = $backendUrl; protocol = 'http'; description = 'Foundry account (BASIC profile)' } } | ConvertTo-Json -Depth 5
Invoke-Arm -Method put -Url "$arm/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/backends/$BackendId`?api-version=$ApiVersion" -BodyJson $backendBody | Out-Null

# --- api + operations --------------------------------------------------------
Write-Step "Importing API '$ApiId' (path '$ApiPath') from $SpecPath"
if (-not (Test-Path $SpecPath)) { throw "Spec not found: $SpecPath" }
if ($DryRun) {
    Write-Info 'DRY RUN would import the OpenAPI spec (4 operations)'
} else {
    az apim api import --resource-group $ResourceGroup --service-name $ApimName `
        --api-id $ApiId --path $ApiPath --specification-format OpenApi --specification-path $SpecPath `
        --display-name $ApiDisplayName --protocols https --subscription-required true -o none
}

# APIM defaults this to 'Ocp-Apim-Subscription-Key'. Copilot CLI can only send 'api-key'.
Write-Step "Forcing subscription key header/query to 'api-key'"
$apiBody = @{
    properties = @{
        displayName                   = $ApiDisplayName
        path                          = $ApiPath
        protocols                     = @('https')
        subscriptionRequired          = $true
        subscriptionKeyParameterNames = @{ header = 'api-key'; query = 'api-key' }
        serviceUrl                    = $backendUrl
    }
} | ConvertTo-Json -Depth 6
Invoke-Arm -Method patch -Url "$arm/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/apis/$ApiId`?api-version=$ApiVersion" -BodyJson $apiBody | Out-Null

# --- policies ----------------------------------------------------------------
function Set-Policy {
    param([string]$Path, [string]$Url, [string]$Label)
    if (-not (Test-Path $Path)) { throw "Policy not found: $Path" }
    $xml = Get-Content -Path $Path -Raw
    $xml = $xml.Replace('REPLACE-WITH-YOUR-FOUNDRY-BACKEND-ID', $BackendId)
    $xml = $xml.Replace('REPLACE-WITH-YOUR-FOUNDRY-MI-AUDIENCE', $miAudience)
    if ($xml -match 'REPLACE-WITH-') {
        throw "$Label still contains an unsubstituted placeholder; refusing to upload."
    }
    Write-Step "Applying $Label"
    $body = @{ properties = @{ format = 'rawxml'; value = $xml } } | ConvertTo-Json -Depth 5
    Invoke-Arm -Method put -Url $Url -BodyJson $body | Out-Null
}

Set-Policy -Path $ApiPolicyPath -Label 'API-scope policy' `
    -Url "$arm/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/apis/$ApiId/policies/policy`?api-version=$ApiVersion"

Set-Policy -Path $ModelsPolicyPath -Label "operation-scope policy on '$ModelsOperationId'" `
    -Url "$arm/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/apis/$ApiId/operations/$ModelsOperationId/policies/policy`?api-version=$ApiVersion"

# --- rbac --------------------------------------------------------------------
if ($GrantRbac) {
    Write-Step 'Granting APIM managed identity Cognitive Services OpenAI User'
    $principal = az apim show -n $ApimName -g $ResourceGroup --query identity.principalId -o tsv
    if (-not $principal) {
        Write-Warn 'APIM has no system-assigned managed identity. Enable one, then re-run with -GrantRbac.'
    } else {
        $scope = az cognitiveservices account show -n $FoundryAccountName -g $FoundryResourceGroup --query id -o tsv
        if ($DryRun) {
            Write-Info "DRY RUN would grant $principal -> Cognitive Services OpenAI User on the account"
        } else {
            az role assignment create --assignee-object-id $principal --assignee-principal-type ServicePrincipal `
                --role 'Cognitive Services OpenAI User' --scope $scope -o none 2>&1 | Out-Null
            Write-Info 'Granted (or already present). Allow a few minutes to propagate; it 401s until it does.'
        }
    }
}

# --- summary -----------------------------------------------------------------
$gateway = az apim show -n $ApimName -g $ResourceGroup --query gatewayUrl -o tsv
Write-Host ''
Write-Step 'Done'
Write-Info "Gateway    : $gateway"
Write-Info "Base URL   : $gateway/$ApiPath"
Write-Info "Backend    : $backendUrl"
Write-Host ''
Write-Info 'Point a client at it with:'
Write-Info "  COPILOT_PROVIDER_TYPE=azure"
Write-Info "  COPILOT_PROVIDER_BASE_URL=$gateway/$ApiPath"
Write-Info '  COPILOT_PROVIDER_API_KEY=<an APIM subscription key for this API>'
Write-Host ''
Write-Info 'Smoke check (expects a JSON model list):'
Write-Info "  curl.exe -i `"$gateway/$ApiPath/v1/models`" -H `"api-key: <key>`""
