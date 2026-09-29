#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$')]
    [string] $GatewayHost,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
    [string] $BaseModel,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
    [string] $Deployment
)

# The approved launcher must pin the Entra ID/Okta JWT token helper before this fragment runs.
if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('COPILOT_PROVIDER_API_KEY_COMMAND', 'Process'))) {
    throw 'COPILOT_PROVIDER_API_KEY_COMMAND must already be set by the approved launcher token helper; no values were printed or changed.'
}

$conflictingNames = @(
    'COPILOT_PROVIDER_API_KEY'
    'COPILOT_PROVIDER_BEARER_TOKEN'
    'COPILOT_PROVIDER_HEADERS'
    'COPILOT_PROVIDER_BASE_URL'
    'COPILOT_PROVIDER_TYPE'
    'COPILOT_PROVIDER_AZURE_API_VERSION'
    'COPILOT_PROVIDER_WIRE_API'
    'COPILOT_PROVIDER_TRANSPORT'
    'COPILOT_PROVIDER_MODEL_ID'
    'COPILOT_PROVIDER_WIRE_MODEL'
    'COPILOT_PROVIDER_MAX_PROMPT_TOKENS'
    'COPILOT_PROVIDER_MAX_OUTPUT_TOKENS'
    'COPILOT_MODEL'
    'COPILOT_PROVIDERS_CONFIG'
    'COPILOT_GITHUB_TOKEN'
    'GH_TOKEN'
    'GITHUB_TOKEN'
    'COPILOT_ALLOW_ALL'
    'COPILOT_OFFLINE'
    'NODE_TLS_REJECT_UNAUTHORIZED'
)
foreach ($name in $conflictingNames) {
    if ($null -ne [Environment]::GetEnvironmentVariable($name, 'Process')) {
        throw "Conflicting variable is present: $name. Use an approved clean launch process; no values were printed or changed."
    }
}

$env:COPILOT_PROVIDER_TYPE = 'azure'
$env:COPILOT_PROVIDER_BASE_URL = "https://$GatewayHost/openai"
$env:COPILOT_PROVIDER_MODEL_ID = $BaseModel
$env:COPILOT_PROVIDER_WIRE_MODEL = $Deployment
$env:COPILOT_PROVIDER_WIRE_API = 'responses'
$env:COPILOT_PROVIDER_TRANSPORT = 'http'

Write-Output 'Configured the gateway route in this process only; credential comes from the launcher''s token helper; nothing launched.'
