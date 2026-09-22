# Quick probe of a BASIC-profile Foundry gateway, without Copilot CLI or VS Code.
#
#   ./test-basic-foundry-gateway.ps1 -BaseUrl https://<apim-host>/openai
#
# Prompts for the key hidden, so it stays out of the terminal and Get-History.
# Uses Invoke-WebRequest, not curl: in Windows PowerShell `curl` is an alias for it,
# -Headers wants a hashtable, and single-quoted JSON keeps its backslashes.

param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [string]$Model = 'gpt-5.6-sol'
)

$BaseUrl = $BaseUrl.TrimEnd('/')
$sec = Read-Host -AsSecureString 'APIM subscription key (hidden)'
$key = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))

function Probe($name, $method, $url, $body) {
    Write-Host "`n== $name : $method $url" -ForegroundColor Cyan
    $p = @{ Uri = $url; Method = $method; Headers = @{ 'api-key' = $key }; UseBasicParsing = $true }
    if ($body) {
        $p.Body = ($body | ConvertTo-Json -Depth 6 -Compress)
        $p.ContentType = 'application/json'
    }
    try {
        $r = Invoke-WebRequest @p
        Write-Host "PASS $([int]$r.StatusCode)" -ForegroundColor Green
    } catch {
        $resp = $_.Exception.Response
        if (-not $resp) { Write-Host "FAIL (no response) $($_.Exception.Message)" -ForegroundColor Red; return }
        Write-Host "FAIL $([int]$resp.StatusCode)" -ForegroundColor Red
        # The body says which layer failed: "Resource not found" = APIM has no such
        # operation; anything else = the backend answered.
        Write-Host (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
    }
}

Probe 'models'    'GET'  "$BaseUrl/v1/models"
Probe 'responses' 'POST' "$BaseUrl/v1/responses"        @{ model = $Model; input = 'say ok' }
Probe 'chat'      'POST' "$BaseUrl/v1/chat/completions" @{ model = $Model; messages = @(@{ role = 'user'; content = 'say ok' }) }
