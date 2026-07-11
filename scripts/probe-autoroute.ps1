$ErrorActionPreference = 'Stop'
$key  = '__KEY__'
$host0 = '__APIM_HOST__'   # e.g. apim-<namePrefix>-<env>-<suffix>.azure-api.us (Gov) / .azure-api.net (Public)

function Invoke-Probe {
    param($Label, $PathBase, $Model, $Prompt, $MaxTokens = 200)
    $url = "https://$host0/$PathBase/v1/chat/completions"
    $payload = @{
        model = $Model
        messages = @(@{ role = 'user'; content = $Prompt })
        max_completion_tokens = $MaxTokens
    } | ConvertTo-Json -Depth 6 -Compress
    try {
        $resp = Invoke-RestMethod -Method Post -Uri $url -Headers @{ 'api-key' = $key } -ContentType 'application/json' -Body $payload -TimeoutSec 40
        $model = $resp.model
        $content = ($resp.choices[0].message.content -replace '\s+',' ')
        if ($content.Length -gt 50) { $content = $content.Substring(0,50) + '...' }
        "[$Label] OK path=$PathBase req-model=$Model -> resp.model=$model | $content"
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        $msg  = $_.ErrorDetails.Message
        if (-not $msg) { $msg = $_.Exception.Message }
        if ($msg.Length -gt 180) { $msg = $msg.Substring(0,180) }
        "[$Label] FAIL path=$PathBase req-model=$Model HTTP=$code | $msg"
    }
}

$short = 'What is the capital of France? Answer in one word.'
$codingLong = "Refactor this Python function for clarity and add error handling. Explain every change in detail for a production system processing millions of requests.`n`n``````python`ndef f(a,b):`n  return a/b`n```````n`nAlso write pytest unit tests and show how to mock dependencies."

$results = @()
# Foundry /openai path
$results += Invoke-Probe -Label 'explicit-full'  -PathBase 'openai' -Model 'gpt-5.1'      -Prompt $short
$results += Invoke-Probe -Label 'explicit-mini'  -PathBase 'openai' -Model 'gpt-4.1-mini' -Prompt $short
$results += Invoke-Probe -Label 'auto-short'     -PathBase 'openai' -Model 'auto'         -Prompt $short
$results += Invoke-Probe -Label 'auto-coding'    -PathBase 'openai' -Model 'auto'         -Prompt $codingLong -MaxTokens 300
# AOAI /aoai legacy path
$results += Invoke-Probe -Label 'aoai-auto-short'  -PathBase 'aoai' -Model 'auto' -Prompt $short
$results += Invoke-Probe -Label 'aoai-auto-coding' -PathBase 'aoai' -Model 'auto' -Prompt $codingLong -MaxTokens 300

$results | ForEach-Object { Write-Output $_ }
