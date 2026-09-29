#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigFile,
    [switch]$Login,
    [switch]$Logout,
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
try {
    if(@($Login,$Logout,$ValidateOnly | Where-Object {$_}).Count -gt 1){throw 'Choose one operation.'}
    if(-not (Get-Command node -CommandType Application -ErrorAction SilentlyContinue)){throw 'Node.js 22+ is required.'}
    $arguments=@((Join-Path $PSScriptRoot 'okta/token.mjs'),'--config',[IO.Path]::GetFullPath($ConfigFile))
    if($Login){$arguments+='--login'}elseif($Logout){$arguments+='--logout'}elseif($ValidateOnly){$arguments+='--validate-config'}
    & node @arguments
    exit $LASTEXITCODE
} catch {
    Write-Error 'BYOK Okta helper could not start. Install its dependencies and check the nonsecret client settings.' -ErrorAction Continue
    exit 1
}