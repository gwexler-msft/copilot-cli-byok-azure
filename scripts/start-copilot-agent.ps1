#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigFile,
    [ValidateSet('acp','terminal')][string]$Mode = 'acp',
    [switch]$ValidateOnly
)
$ErrorActionPreference='Stop'
$saved=@{}
$exitCode=1
try {
    $file=Get-Item -LiteralPath $ConfigFile
    if($file.Length -gt 16384){throw 'Agent profile exceeds its bound.'}
    $profile=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json -AsHashtable
    $allowed=@('cliExecutable','gatewayUrl','model','authMode','appId','cloud','tenantId','accountName','azureConfigDirectory','oktaConfigFile','workspace')
    if($profile -isnot [Collections.IDictionary] -or @($profile.Keys|Where-Object {$_ -notin $allowed}).Count){throw 'Only nonsecret agent configuration fields are supported.'}
    foreach($name in @('cliExecutable','gatewayUrl','model','authMode','workspace')){
        if($profile[$name] -isnot [string] -or [string]::IsNullOrWhiteSpace($profile[$name]) -or $profile[$name] -match '[\r\n<>]'){throw 'Required agent settings are missing or unsafe.'}
    }
    if($profile.authMode -cnotin @('jwt','okta')){throw 'This agent launcher requires a renewable JWT mode.'}
    $gateway=[uri]$profile.gatewayUrl
    if(-not $gateway.IsAbsoluteUri -or $gateway.Scheme -cne 'https' -or $gateway.UserInfo -or $gateway.Query -or $gateway.Fragment -or -not $gateway.AbsolutePath.TrimEnd('/').EndsWith('/openai',[StringComparison]::Ordinal)){throw 'An exact HTTPS gateway base ending in /openai is required.'}
    foreach($name in @('cliExecutable','workspace')){if(-not [IO.Path]::IsPathFullyQualified($profile[$name])){throw 'The CLI and workspace paths must be absolute.'}}
    $executable=Get-Item -LiteralPath $profile.cliExecutable
    if($executable.PSIsContainer -or ($IsWindows -and $executable.Extension -ine '.exe')){throw 'Use the native Copilot executable, not an editor/shell shim.'}
    $workspace=Get-Item -LiteralPath $profile.workspace
    if(-not $workspace.PSIsContainer){throw 'The configured workspace is not a directory.'}
    if($profile.authMode -eq 'jwt'){
        if($profile.appId -cnotmatch '\A[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z' -or
            $profile.tenantId -cnotmatch '\A[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z' -or
            $profile.cloud -cnotin @('AzureCloud','AzureUSGovernment') -or
            $profile.accountName -isnot [string] -or [string]::IsNullOrWhiteSpace($profile.accountName) -or $profile.accountName -match '[\r\n<>]' -or
            $profile.azureConfigDirectory -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($profile.azureConfigDirectory) -or
            -not(Test-Path -LiteralPath $profile.azureConfigDirectory -PathType Container)){throw 'Entra mode requires a pinned existing CLI cache and gateway audience.'}
    }elseif($profile.oktaConfigFile -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($profile.oktaConfigFile) -or -not(Test-Path -LiteralPath $profile.oktaConfigFile -PathType Leaf)){throw 'Okta mode requires an absolute local client configuration path.'}
    if($ValidateOnly){'PASS: nonsecret CLI agent profile validated; no process, login or model request was started.';exit 0}
    $version=(& $executable.FullName --version 2>$null)-join ' '
    if($LASTEXITCODE -ne 0 -or $version -notmatch '\b1\.0\.(?:8[5-9]|9[0-9]|[1-9][0-9]{2,})(?:\b|-)'){throw 'Use a tested CLI version at least 1.0.85 and revalidate newer versions.'}
    $providerHelp=(& $executable.FullName help providers 2>$null)-join "`n"
    if($LASTEXITCODE -ne 0 -or $providerHelp -notmatch '\bCOPILOT_PROVIDER_API_KEY_COMMAND\b'){throw 'The selected CLI does not advertise credential-command support.'}
    $names=@('AZURE_CONFIG_DIR','COPILOT_PROVIDER_BASE_URL','COPILOT_PROVIDER_TYPE','COPILOT_PROVIDER_WIRE_API','COPILOT_PROVIDER_API_KEY_COMMAND','COPILOT_PROVIDER_API_KEY','COPILOT_PROVIDER_BEARER_TOKEN','COPILOT_PROVIDER_HEADERS','COPILOT_MODEL')
    foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
    if($env:COPILOT_PROVIDER_HEADERS){throw 'Remove custom provider headers before starting the pinned agent profile.'}
    $helper=if($profile.authMode -eq 'jwt'){'get-byok-token.ps1'}else{'get-okta-token.ps1'}
    $tokenParameters=[ordered]@{}
    if($profile.authMode -eq 'jwt'){
        $env:AZURE_CONFIG_DIR=$profile.azureConfigDirectory
        $tokenParameters.AppId=$profile.appId
        $tokenParameters.Cloud=$profile.cloud
        $tokenParameters.TenantId=$profile.tenantId
        $tokenParameters.AccountName=$profile.accountName
        $tokenParameters.AzureConfigDirectory=$profile.azureConfigDirectory
    }else{$tokenParameters.ConfigFile=$profile.oktaConfigFile}
    $helperPath=Join-Path $PSScriptRoot $helper
    $null=& $helperPath @tokenParameters
    if($LASTEXITCODE -ne 0){throw 'The pinned token helper failed preflight.'}
    $parts=@("& '"+$helperPath.Replace("'","''")+"'")
    foreach($name in $tokenParameters.Keys){$parts+='-'+$name+" '"+([string]$tokenParameters[$name]).Replace("'","''")+"'"}
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($parts -join ' ')))
    $shell=(Get-Process -Id $PID).Path
    $env:COPILOT_PROVIDER_API_KEY_COMMAND='"'+$shell+'" -NoLogo -NoProfile -NonInteractive -EncodedCommand '+$encoded
    $env:COPILOT_PROVIDER_API_KEY=$null
    $env:COPILOT_PROVIDER_BEARER_TOKEN=$null
    $env:COPILOT_PROVIDER_HEADERS=$null
    $env:COPILOT_PROVIDER_BASE_URL=$profile.gatewayUrl.TrimEnd('/')
    $env:COPILOT_PROVIDER_TYPE='azure'
    $env:COPILOT_PROVIDER_WIRE_API='responses'
    $env:COPILOT_MODEL=$profile.model
    Push-Location -LiteralPath $workspace.FullName
    try {
        $cliArguments=@('--no-remote','--no-remote-export','--log-level=none')
        if($Mode -eq 'acp'){$cliArguments=@('--acp','--stdio')+$cliArguments}
        & $executable.FullName @cliArguments
        $exitCode=$LASTEXITCODE
    } finally {Pop-Location}
} catch {
    [Console]::Error.WriteLine('BYOK agent startup failed. Verify the native CLI, nonsecret profile and pinned sign-in outside the editor. No fallback credential was selected.')
} finally {
    foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
}
exit $exitCode