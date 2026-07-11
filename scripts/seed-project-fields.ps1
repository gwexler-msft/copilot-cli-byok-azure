# Populate Priority / Theme / Effort / Votes fields on Project v2 from issue labels + 👍 reactions.
# Idempotent: re-running just refreshes Votes and re-applies labels (no duplicate side effects).
[CmdletBinding()]
param(
    [string]$Owner       = 'gwexler_microsoft',
    [string]$Repo        = 'copilot-cli-byok-azure',
    [int]   $ProjectNumber = 1
)

$ErrorActionPreference = 'Stop'

Write-Host "=== Fetching project + field option IDs via GraphQL ==="
$query = @"
query(`$owner: String!, `$num: Int!) {
  user(login: `$owner) {
    projectV2(number: `$num) {
      id
      fields(first: 50) {
        nodes {
          __typename
          ... on ProjectV2FieldCommon { id name dataType }
          ... on ProjectV2SingleSelectField {
            id name
            options { id name }
          }
        }
      }
    }
  }
}
"@
# Capture stderr + exit code: gh writes auth/SSO/token-policy failures (e.g. the Microsoft
# EMU "classic PAT lifetime > 8 days is forbidden" error) ONLY to stderr and returns a null
# projectV2, which otherwise surfaces downstream as a misleading "Missing one or more required
# fields. Found:" throw. Fail fast here with the real cause instead.
$respRaw = gh api graphql -f query=$query -F owner=$Owner -F num=$ProjectNumber 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "gh api graphql failed (exit $LASTEXITCODE): $($respRaw -join "`n")`n" +
          "If this mentions token lifetime, the PROJECT_TOKEN classic PAT exceeds the Microsoft EMU 8-day limit — " +
          "regenerate it with an expiry <= 8 days (or use a fine-grained PAT owned by $Owner with Projects read/write + Issues read) and update the secret."
}
$resp = $respRaw | ConvertFrom-Json
$projectId = $resp.data.user.projectV2.id
$fields    = $resp.data.user.projectV2.fields.nodes
if (-not $projectId) {
    throw "GraphQL returned no project for user '$Owner' project #$ProjectNumber. Check the PROJECT_TOKEN scopes (Projects read/write + repo/Issues read) and that it is authorized for the $Owner org (SSO). Raw response: $($respRaw -join "`n")"
}
Write-Host "Project ID: $projectId"
Write-Host "Field count: $($fields.Count)"

function Get-Field([string]$Name) { $fields | Where-Object { $_.name -eq $Name } | Select-Object -First 1 }
function Get-OptionId([object]$Field, [string]$OptionName) {
    if (-not $Field.options) { return $null }
    ($Field.options | Where-Object { $_.name -eq $OptionName } | Select-Object -First 1).id
}

$fPriority = Get-Field 'Priority'
$fTheme    = Get-Field 'Theme'
$fEffort   = Get-Field 'Effort'
$fVotes    = Get-Field 'Votes'

if (-not $fPriority -or -not $fTheme -or -not $fEffort -or -not $fVotes) {
    throw "Missing one or more required fields. Found: $($fields.name -join ', ')"
}
Write-Host "Priority options: $(($fPriority.options.name) -join ', ')"
Write-Host "Theme    options: $(($fTheme.options.name) -join ', ')"
Write-Host "Effort   options: $(($fEffort.options.name) -join ', ')"

Write-Host "`n=== Fetching project items (issue number -> item ID) ==="
# Capture stderr too: `gh project item-list` can fail (auth/SSO/scope) and write
# only to stderr, which—when piped straight to ConvertFrom-Json—silently yields
# zero items and a misleading "skip: not in project" for every issue.
$itemJson = gh project item-list $ProjectNumber --owner $Owner --format json --limit 200 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "gh project item-list failed (exit $LASTEXITCODE): $($itemJson -join "`n")"
}
$itemsRaw = $itemJson | ConvertFrom-Json
$itemMap = @{}
foreach ($it in $itemsRaw.items) {
    if ($it.content.number) { $itemMap[[int]$it.content.number] = $it.id }
}
Write-Host "Items returned: $($itemsRaw.items.Count)  |  mapped (with issue number): $($itemMap.Count)"

Write-Host "`n=== Fetching issue metadata (labels + reactions) ==="
$issues = gh issue list --repo "$Owner/$Repo" --state all --limit 200 --json number,labels,reactionGroups | ConvertFrom-Json
Write-Host "Issues fetched: $($issues.Count)"

$updates = 0
$skips   = 0
foreach ($issue in $issues) {
    $num    = [int]$issue.number
    $itemId = $itemMap[$num]
    if (-not $itemId) { Write-Host "  #$num  (skip: not in project)"; $skips++; continue }

    $labelNames = @($issue.labels | ForEach-Object { $_.name })

    $priorityLabel = $labelNames | Where-Object { $_ -like 'priority:*' } | Select-Object -First 1
    $themeLabel    = $labelNames | Where-Object { $_ -like 'theme:*' }    | Select-Object -First 1
    $effortLabel   = $labelNames | Where-Object { $_ -like 'effort:*' }   | Select-Object -First 1

    $votes = 0
    $thumbs = $issue.reactionGroups | Where-Object { $_.content -eq 'THUMBS_UP' } | Select-Object -First 1
    if ($thumbs) { $votes = [int]$thumbs.users.totalCount }

    $set = @()

    if ($priorityLabel) {
        $optName = ($priorityLabel -replace 'priority:p', 'P')
        $optId   = Get-OptionId $fPriority $optName
        if ($optId) {
            gh project item-edit --id $itemId --project-id $projectId --field-id $fPriority.id --single-select-option-id $optId | Out-Null
            $set += "Priority=$optName"
        }
    }
    if ($themeLabel) {
        $optName = ($themeLabel -replace 'theme:', '')
        $optId   = Get-OptionId $fTheme $optName
        if ($optId) {
            gh project item-edit --id $itemId --project-id $projectId --field-id $fTheme.id --single-select-option-id $optId | Out-Null
            $set += "Theme=$optName"
        }
    }
    if ($effortLabel) {
        $optName = ($effortLabel -replace 'effort:', '')
        $optId   = Get-OptionId $fEffort $optName
        if ($optId) {
            gh project item-edit --id $itemId --project-id $projectId --field-id $fEffort.id --single-select-option-id $optId | Out-Null
            $set += "Effort=$optName"
        }
    }
    # Always set Votes (may be 0)
    gh project item-edit --id $itemId --project-id $projectId --field-id $fVotes.id --number $votes | Out-Null
    $set += "Votes=$votes"

    Write-Host ("  #{0,-3}  {1}" -f $num, ($set -join ', '))
    $updates++
}

Write-Host "`n=== Done. updated=$updates  skipped=$skips ==="
