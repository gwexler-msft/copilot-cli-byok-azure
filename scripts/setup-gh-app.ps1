#requires -Version 7.0
<#
.SYNOPSIS
    ONE-TIME creation + installation of the GitHub App that authenticates the BYOK self-hosted
    runner pool (issue #58, `ghRunnerAuthMode='app'`). Drives GitHub's App-manifest flow end to
    end: builds the manifest (correct permissions, webhook disabled), creates the App, downloads
    its private key, helps you install it on the repo, auto-discovers the Installation ID, and
    (optionally) publishes the credentials to the repo Variables/Secret and the pilot runner Key
    Vaults.

.DESCRIPTION
    IMPORTANT — this is NOT an Entra ID app registration and NOT an `azd` post-provision hook.

      * A *GitHub App* is a GitHub-side identity. It has **no Entra ID footprint**. The only Entra
        identity in the runner stack is the runner **user-assigned managed identity** (UAMI), which
        Bicep already creates ([gh-runner.bicep](../infra/modules/gh-runner.bicep)) and which reads
        the App private key from Key Vault. The Entra app-registration helper
        ([setup-entra.ps1](setup-entra.ps1)) is for the APIM gateway JWT — unrelated to this.
      * GitHub Apps cannot be created non-interactively (no `gh app create`, no ARM/Bicep). The
        only programmatic path is the **App-manifest flow**, which requires a human to click
        "Create" and "Install" in a browser ONCE. That makes it a poor fit for an `azd`
        postprovision hook (those run on every provision, unattended, on headless CI runners, and
        per-env — whereas ONE App serves comm + gov + dev). So it lives here as a standalone,
        run-once operator helper, mirroring how `setup-entra.ps1` is run once for the gateway.

    After this script, the recurring credential placement IS automated:
      - dev: the App ID/Installation ID (repo Variables) + private key (repo Secret) are injected by
        the deploy workflows every night — nothing expires, nothing to rotate.
      - pilots: the private key lives in each pilot runner Key Vault; rotation/roll is a single
        `az keyvault secret set` (or `setup-gh-runner.ps1 -Secret AppKey`).

    Flow:
      1. Build the manifest and host a localhost auto-submit form (App-manifest flow).
      2. You click "Create GitHub App ..." in the browser → GitHub redirects back with a code.
      3. Exchange the code (`POST /app-manifests/{code}/conversions`) → App ID + private key PEM.
      4. Open the install page; you install the App on the repo.
      5. Mint an App JWT from the PEM and poll `GET /repos/{owner}/{repo}/installation` for the
         Installation ID.
      6. (-SetRepoVars) publish GH_APP_ID / GH_APP_INSTALLATION_ID (repo Variables) and
         GH_APP_PRIVATE_KEY (repo Secret) via `gh`.
      7. Print the `setup-gh-runner.ps1 -Secret AppKey` commands to seed the pilot Key Vaults
         (those run per-cloud, so they stay a manual follow-up).

.PARAMETER Owner
    Repo owner / org. Default `gwexler_microsoft`.

.PARAMETER Repo
    Repository name. Default `copilot-cli-byok-azure`.

.PARAMETER AppName
    GitHub App display name (must be globally unique on GitHub). Default `copilot-byok-runner`.

.PARAMETER UserAccount
    Create the App under your personal account instead of the org. Default off (org App).

.PARAMETER Port
    Localhost port for the manifest callback listener. Default 8765.

.PARAMETER PemOutPath
    Where to save the downloaded private key PEM. Default `./gh-app.private-key.pem`.

.PARAMETER SetRepoVars
    Publish GH_APP_ID + GH_APP_INSTALLATION_ID (repo Variables) and GH_APP_PRIVATE_KEY (repo
    Secret) to the repo via `gh`. Requires `gh` admin on the repo.

.EXAMPLE
    # Full guided setup, then publish the repo Variables/Secret:
    ./scripts/setup-gh-app.ps1 -SetRepoVars

.EXAMPLE
    # EMU/SSO blocks the browser manifest flow? Create the App by hand in the GitHub UI
    # (Settings -> Developer settings -> GitHub Apps -> New), generate + download its private key,
    # then import it and publish the credentials:
    ./scripts/setup-gh-app.ps1 -ImportExisting -AppId 123456 -PemOutPath ./gh-app.private-key.pem -SetRepoVars

.NOTES
    Requires PowerShell 7+, `gh` CLI authenticated (`gh auth login`) with rights to create an App
    in the target owner. The private key is downloaded ONCE — store it safely; GitHub cannot show
    it again (you can always generate a new key on the App later).
#>
[CmdletBinding()]
param(
    [string]$Owner = 'gwexler_microsoft',
    [string]$Repo = 'copilot-cli-byok-azure',
    [string]$AppName = 'copilot-byok-runner',
    [switch]$UserAccount,
    [int]$Port = 8765,
    [string]$PemOutPath = './gh-app.private-key.pem',
    [switch]$SetRepoVars,
    # Skip the browser manifest flow entirely and import an App you already created in the GitHub
    # UI (Settings -> Developer settings -> GitHub Apps). Required when the manifest auto-flow is
    # blocked — e.g. EMU/SSO environments redirect the manifest POST and drop its body. Provide
    # -AppId and place the downloaded private key at -PemOutPath.
    [switch]$ImportExisting,
    [string]$AppId
)

$ErrorActionPreference = 'Stop'

# ---------- prereqs ----------
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI ('gh') not found. Install it and run 'gh auth login' first."
}
gh auth status *> $null
if ($LASTEXITCODE -ne 0) { throw "gh CLI is not authenticated. Run 'gh auth login' first." }

# ---------- helpers ----------
function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-AppJwt {
    # Mint a short-lived (<=10 min) RS256 App JWT from the downloaded PEM so we can call the
    # app-authenticated installation endpoint. `iss` is the App ID.
    param([string]$Pem, [string]$AppId)
    $rsa = [System.Security.Cryptography.RSA]::Create()
    $rsa.ImportFromPem($Pem)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $headerJson = '{"alg":"RS256","typ":"JWT"}'
    $payloadJson = (@{ iat = $now - 60; exp = $now + 540; iss = $AppId } | ConvertTo-Json -Compress)
    $header = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($headerJson))
    $payload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($payloadJson))
    $signingInput = "$header.$payload"
    $sig = $rsa.SignData(
        [Text.Encoding]::ASCII.GetBytes($signingInput),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    "$signingInput." + (ConvertTo-Base64Url $sig)
}

function ConvertTo-HtmlAttr {
    param([string]$Value)
    $Value.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace("'", '&#39;')
}

# ---------- 1. obtain the App: import an existing one, OR run the manifest flow ----------
if ($ImportExisting) {
    if (-not $AppId) { throw "-ImportExisting requires -AppId (the numeric App ID from the App's GitHub settings page)." }
    if (-not (Test-Path -LiteralPath $PemOutPath)) { throw "-ImportExisting expects the App private key at -PemOutPath '$PemOutPath' (download it from the App settings -> 'Generate a private key')." }
    Write-Host "==> Importing existing GitHub App (id=$AppId, key=$PemOutPath) ..." -ForegroundColor Cyan
    $appId = "$AppId"
    $pem = Get-Content -LiteralPath $PemOutPath -Raw
    $jwt0 = New-AppJwt -Pem $pem -AppId $appId
    $h0 = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'setup-gh-app'; Authorization = "Bearer $jwt0" }
    try { $appMeta = Invoke-RestMethod -Method GET -Uri 'https://api.github.com/app' -Headers $h0 }
    catch { throw "Could not authenticate with the provided App ID + PEM (check the ID matches the key): $($_.Exception.Message)" }
    $appSlug = $appMeta.slug
    Write-Host "    App      : $($appMeta.html_url)" -ForegroundColor Green
    Write-Host "    App ID   : $appId" -ForegroundColor Green
    Write-Host "    App slug : $appSlug" -ForegroundColor Green
}
else {
# ---------- 1a. manifest + localhost callback ----------
# Repo-scoped runner permissions: Actions Read (queue), Administration Read+Write (register/remove
# runners), Metadata Read (always required). Webhook disabled — the runner polls, it doesn't receive.
$state = [Guid]::NewGuid().ToString('N')
$redirectUrl = "http://localhost:$Port/callback"
$manifest = [ordered]@{
    name           = $AppName
    url            = "https://github.com/$Owner/$Repo"
    redirect_url   = $redirectUrl
    public         = $false
    default_events = @()
    default_permissions = [ordered]@{
        actions        = 'read'
        administration = 'write'
        metadata       = 'read'
    }
    hook_attributes = [ordered]@{ active = $false }
}
$manifestJson = $manifest | ConvertTo-Json -Compress -Depth 5

$newAppUrl = if ($UserAccount) {
    'https://github.com/settings/apps/new'
} else {
    "https://github.com/organizations/$Owner/settings/apps/new"
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
try {
    $listener.Start()
}
catch {
    throw "Could not bind http://localhost:$Port/. Pick another -Port (was: $($_.Exception.Message))."
}

Write-Host "==> Opening the GitHub App-manifest flow in your browser ..." -ForegroundColor Cyan
Write-Host "    App name : $AppName" -ForegroundColor DarkGray
Write-Host "    Owner    : $Owner $(if($UserAccount){'(personal account)'}else{'(organization)'})" -ForegroundColor DarkGray
Write-Host "    If the browser doesn't open, go to: http://localhost:$Port/" -ForegroundColor DarkGray
Start-Process "http://localhost:$Port/"

$code = $null
try {
    while (-not $code) {
        $ctx = $listener.GetContext()            # blocks until a request arrives
        $req = $ctx.Request
        $res = $ctx.Response
        if ($req.Url.AbsolutePath -eq '/callback') {
            $returnedState = $req.QueryString['state']
            $code = $req.QueryString['code']
            if ($returnedState -ne $state) {
                $code = $null
                $body = '<h2>State mismatch.</h2><p>Close this tab and re-run the script.</p>'
            }
            else {
                $body = '<h2>GitHub App created.</h2><p>You can close this tab and return to the terminal.</p>'
            }
            $buf = [Text.Encoding]::UTF8.GetBytes("<!doctype html><meta charset=utf-8><body style='font-family:system-ui'>$body</body>")
            $res.ContentType = 'text/html'
            $res.OutputStream.Write($buf, 0, $buf.Length)
            $res.Close()
        }
        else {
            # Root: auto-submit the manifest POST to GitHub.
            $attr = ConvertTo-HtmlAttr $manifestJson
            $html = @"
<!doctype html><meta charset=utf-8>
<body style='font-family:system-ui;max-width:42rem;margin:3rem auto;line-height:1.5'>
<p>Creating the <b>$AppName</b> GitHub App in <b>$Owner</b>&hellip;</p>
<p>If you are not redirected automatically, click the button:</p>
<form id='f' action='${newAppUrl}?state=$state' method='post'>
  <input type='hidden' name='manifest' value='$attr'>
  <button type='submit' style='font-size:1rem;padding:.6rem 1.2rem;cursor:pointer'>Create GitHub App &rarr;</button>
</form>
<p style='color:#666;font-size:.9rem;margin-top:1.5rem'>Make sure this browser is signed in to github.com as the account that can create Apps in <b>$Owner</b>. If $Owner uses SSO, complete the SSO prompt first. After clicking, GitHub should show a green <b>Create GitHub App</b> confirmation page.</p>
<script>setTimeout(function(){try{document.getElementById('f').submit();}catch(e){}},400);</script>
</body>
"@
            $buf = [Text.Encoding]::UTF8.GetBytes($html)
            $res.ContentType = 'text/html'
            $res.OutputStream.Write($buf, 0, $buf.Length)
            $res.Close()
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}

if (-not $code) { throw "Did not receive a valid manifest code from GitHub." }

# ---------- 2. exchange code -> App (id + private key) ----------
Write-Host "==> Exchanging manifest code for the App definition ..." -ForegroundColor Cyan
$conv = gh api -X POST "/app-manifests/$code/conversions" 2>&1
if ($LASTEXITCODE -ne 0) { throw "Manifest conversion failed: $conv" }
$app = $conv | ConvertFrom-Json
$appId = "$($app.id)"
$appSlug = $app.slug
$pem = $app.pem
if (-not $appId -or -not $pem) { throw "Conversion response missing id/pem." }

Set-Content -LiteralPath $PemOutPath -Value $pem -NoNewline
Write-Host "    App created: $($app.html_url)" -ForegroundColor Green
Write-Host "    App ID     : $appId" -ForegroundColor Green
Write-Host "    Private key: $PemOutPath  (store safely — GitHub won't show it again)" -ForegroundColor Yellow
}

# ---------- 3. install on the repo + discover Installation ID ----------
$installUrl = "https://github.com/apps/$appSlug/installations/new"
Write-Host "==> Install the App on '$Owner/$Repo' in the browser that just opened." -ForegroundColor Cyan
Write-Host "    Install URL: $installUrl" -ForegroundColor DarkGray
Start-Process $installUrl

Write-Host "==> Waiting for the installation to appear (mint App JWT + poll) ..." -ForegroundColor Cyan
$headers = @{
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'setup-gh-app'
}
$installationId = $null
$deadline = (Get-Date).AddMinutes(5)
while (-not $installationId -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    try {
        $jwt = New-AppJwt -Pem $pem -AppId $appId
        $h = $headers.Clone(); $h['Authorization'] = "Bearer $jwt"
        $inst = Invoke-RestMethod -Method GET -Uri "https://api.github.com/repos/$Owner/$Repo/installation" -Headers $h
        $installationId = "$($inst.id)"
    }
    catch {
        Write-Host "    ...not installed yet (complete the install in the browser)" -ForegroundColor DarkGray
    }
}
if (-not $installationId) {
    Write-Warning "Could not auto-discover the Installation ID within 5 min. After installing, find it in the install settings URL (.../installations/<ID>) and set GH_APP_INSTALLATION_ID manually."
}
else {
    Write-Host "    Installation ID: $installationId" -ForegroundColor Green
}

# ---------- 4. publish repo Variables/Secret (optional) ----------
if ($SetRepoVars) {
    Write-Host "==> Publishing repo Variables + Secret via gh ..." -ForegroundColor Cyan
    gh variable set GH_APP_ID --repo "$Owner/$Repo" --body $appId | Out-Null
    if ($installationId) { gh variable set GH_APP_INSTALLATION_ID --repo "$Owner/$Repo" --body $installationId | Out-Null }
    $pem | gh secret set GH_APP_PRIVATE_KEY --repo "$Owner/$Repo"
    Write-Host "    Set: GH_APP_ID, GH_APP_INSTALLATION_ID (vars) + GH_APP_PRIVATE_KEY (secret)." -ForegroundColor Green
}

# ---------- 5. next steps ----------
Write-Host ""
Write-Host "==================== DONE ====================" -ForegroundColor Magenta
Write-Host "GitHub App is created + installed. Remaining steps:" -ForegroundColor Cyan
if (-not $SetRepoVars) {
    Write-Host @"

  1) Repo Variables/Secret (dev workflows inject these every night):
       gh variable set GH_APP_ID --repo $Owner/$Repo --body $appId
       gh variable set GH_APP_INSTALLATION_ID --repo $Owner/$Repo --body $installationId
       Get-Content -Raw $PemOutPath | gh secret set GH_APP_PRIVATE_KEY --repo $Owner/$Repo
     (or re-run this script with -SetRepoVars)
"@ -ForegroundColor Gray
}
Write-Host @"

  2) Seed the pilot runner Key Vaults with the App private key (run once per cloud):
       az cloud set --name AzureCloud;        az login
       ./scripts/setup-gh-runner.ps1 -Action SetSecret -Secret AppKey -AppKeyPath $PemOutPath -EnvNames comm-pilot
       az cloud set --name AzureUSGovernment; az login
       ./scripts/setup-gh-runner.ps1 -Action SetSecret -Secret AppKey -AppKeyPath $PemOutPath -EnvNames gov-pilot

  3) The param files are already set to ghRunnerAuthMode='app'. Provision so the runner Jobs
     pick up app auth (pilots via the two-phase KV bootstrap; dev via the injected repo Secret).

  4) Once app-mode runners are verified, REVOKE any old runner PAT and delete the gh-pat secrets.

  Then delete the local PEM: Remove-Item $PemOutPath
"@ -ForegroundColor Gray
