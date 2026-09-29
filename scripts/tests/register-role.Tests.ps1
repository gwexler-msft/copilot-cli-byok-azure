#requires -Version 7.4
[CmdletBinding()]
param([string]$RenderedSelectionPath, [string]$CompiledMainTemplatePath)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../resolve-register-role-assignment.ps1') -DefinitionsOnly
$subscriptionId = [guid]::NewGuid().ToString()
$tenantId = [guid]::NewGuid().ToString()
$firstPrincipal = [guid]::NewGuid().ToString()
$secondPrincipal = [guid]::NewGuid().ToString()
$roleId = [guid]::NewGuid().ToString()
$assignmentName = [guid]::NewGuid().ToString()
$target = @{subscriptionId=$subscriptionId;tenantId=$tenantId;namePrefix='fixture';envName='test';location='eastus2';arm='https://management.azure.com'}
$groupId = '/subscriptions/'+$subscriptionId+'/resourceGroups/rg-fixture-test'
$serviceId = $groupId+'/providers/Microsoft.ApiManagement/service/apim-fixture-test-abcdef'
$identityId = $groupId+'/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-fixture-register-test-abcdef'
$roleDefinitionId = '/subscriptions/'+$subscriptionId+'/providers/Microsoft.Authorization/roleDefinitions/'+$roleId
$checks = 0

foreach ($case in @('new','identity-missing','existing','recreated','duplicate','wrong-context','wrong-tenant','wrong-role-scope','conditional','incomplete','unsafe-page','invalid-next-link','read-failure','orphaned-identity')) {
    $read = {
        param($url,$allowMissing)
        if ($url.Contains('/deployments/register-role?')) {
            if ($case -cin @('new','orphaned-identity')) { return $null }
            return @{id=$groupId+'/providers/Microsoft.Resources/deployments/register-role';properties=@{parameters=@{
                namePrefix=@{value='fixture'};envName=@{value=$(if ($case -ceq 'wrong-context') {'other'} else {'test'})};location=@{value='eastus2'};suffix=@{value='abcdef'};apimName=@{value='apim-fixture-test-abcdef'}
            }}}
        }
        if ($url.Contains('/userAssignedIdentities?')) { return @{value=@($(if ($case -ceq 'orphaned-identity') {@{id=$identityId;name='id-fixture-register-test-abcdef'}}))} }
        if ($url.Contains('/userAssignedIdentities/')) {
            if ($case -ceq 'identity-missing') { return $null }
            return @{id=$identityId;properties=@{principalId=$(if ($case -ceq 'recreated') {$secondPrincipal} else {$firstPrincipal});tenantId=$(if ($case -ceq 'wrong-tenant') {$subscriptionId} else {$tenantId})}}
        }
        if ($url.Contains('/roleDefinitions?')) {
            return @{value=@(@{id=$roleDefinitionId;name=$roleId;properties=@{roleName='BYOK Register Subscription Manager (test)';type='CustomRole';assignableScopes=@($(if ($case -ceq 'wrong-role-scope') {$serviceId} else {$groupId}))}})}
        }
        if ($url.Contains('/roleAssignments?')) {
            if ($case -ceq 'read-failure') { throw 'fixture read failed' }
            if ($case -ceq 'incomplete') { return @{value=$null} }
            $assignment = @{id=$serviceId+'/providers/Microsoft.Authorization/roleAssignments/'+$assignmentName;name=$assignmentName;properties=@{
                scope=$serviceId;principalId=$firstPrincipal;principalType='ServicePrincipal';roleDefinitionId=$roleDefinitionId;condition=$(if ($case -ceq 'conditional') {'fixture-condition'} else {$null})
            }}
            $rows = @($assignment)
            if ($case -ceq 'duplicate') { $rows += $assignment }
            return @{value=$rows;nextLink=$(if ($case -ceq 'unsafe-page') {'https://example.invalid/roles?api-version=2022-04-01'} elseif ($case -ceq 'invalid-next-link') {$false} else {$null})}
        }
        throw 'Unexpected fixture read.'
    }
    $accepted = $false
    $resolution = $null
    try { $resolution = Get-RegisterRoleResolution $target $read; $accepted = $true } catch {}
    if ($accepted -ne ($case -cin @('new','identity-missing','existing','recreated'))) { throw ('Register role guard failed: '+$case) }
    if ($case -ceq 'existing' -and ($resolution.mode -cne 'reuse-existing' -or $resolution.reference.name -cne $assignmentName -or $resolution.reference.principalId -cne $firstPrincipal)) {
        throw 'An existing valid assignment was not preserved.'
    }
    if ($case -cin @('new','identity-missing','recreated') -and ($resolution.mode -cne 'new-principal' -or $resolution.reference.name)) { throw 'A new principal reused an old assignment.' }
    if ($case -ceq 'recreated' -and $resolution.otherPrincipalAssignments -ne 1) { throw 'The old assignment was not retained as a separate recovery concern.' }
    $checks++
}
$readTrace = [Collections.Generic.List[string]]::new()
$collectionUrl = 'https://management.azure.com'+$serviceId+'/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01'
$pages = @(Get-RegisterRoleRows $collectionUrl {
    param($url,$allowMissing)
    $readTrace.Add($url)
    if ($readTrace.Count -eq 1) { return @{value=@(@{id=$serviceId+'/first'});nextLink=$collectionUrl+'&$skiptoken=next'} }
    @{value=@(@{id=$serviceId+'/second'})}
})
if ($readTrace.Count -ne 2 -or $pages.Count -ne 2) { throw 'Register inventory did not read the complete valid page chain.' }
$checks++

$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('register-role-tests-'+[guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporaryDirectory
try {
    $path = Join-Path $temporaryDirectory 'parameters.json'
    $document = @{parameters=@{responseOwnerKey=@{value='${BYOK_RESPONSE_OWNER_KEY}'};deployRegisterApp=@{value=$true}}}
    [IO.File]::WriteAllText($path,($document | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    $bytes = [IO.File]::ReadAllBytes($path)
    $reference = @{name=$assignmentName;principalId=$firstPrincipal;scope=$serviceId;roleDefinitionId=$roleDefinitionId}
    Set-RegisterRoleReference $path $bytes $document $reference
    $staged = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    if ($staged.parameters.existingRegisterRoleAssignment.value.name -cne $assignmentName -or $staged.parameters.responseOwnerKey.value -cne '${BYOK_RESPONSE_OWNER_KEY}') { throw 'Register staging lost the binding or an existing secret reference.' }
    $checks++
    $after = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $rejected = $false
    try { Set-RegisterRoleReference $path $bytes $document $reference } catch { $rejected = $true }
    if (-not $rejected -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $after) { throw 'Register staging overwrote a concurrent parameter change.' }
    $checks++
    $resolver = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../resolve-register-role-assignment.ps1'))
    $pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    foreach ($case in @('disabled','unset','invalid-flag','missing-context','invalid-json','missing-file')) {
        $entryPath = Join-Path $temporaryDirectory ($case+'.json')
        $parameters = @{responseOwnerKey=@{value='${BYOK_RESPONSE_OWNER_KEY}'}}
        if ($case -cne 'unset') { $parameters.deployRegisterApp = @{value=$(if ($case -ceq 'disabled') {$false} elseif ($case -ceq 'invalid-flag') {'true'} else {$true})} }
        if ($case -ceq 'missing-context') {
            foreach ($name in @('namePrefix','envName','location','cloudEnv')) {
                $parameters[$name] = @{value=$(switch ($name) {'namePrefix' {'fixture'} 'envName' {'test'} 'location' {'eastus2'} 'cloudEnv' {'AzureCloud'}})}
            }
        }
        if ($case -cne 'missing-file') {
            $text = if ($case -ceq 'invalid-json') {'{"parameters":'} else {@{parameters=$parameters} | ConvertTo-Json -Depth 10}
            [IO.File]::WriteAllText($entryPath,$text,[Text.UTF8Encoding]::new($false))
        }
        $beforeHash = if (Test-Path -LiteralPath $entryPath) {(Get-FileHash -LiteralPath $entryPath -Algorithm SHA256).Hash} else {''}
        $start = [Diagnostics.ProcessStartInfo]::new($pwsh)
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $null = $start.Environment.Remove('AZURE_SUBSCRIPTION_ID')
        foreach ($argument in @('-NoProfile','-NonInteractive','-File',$resolver,'-ParameterFile',$entryPath,'-Stage')) { $start.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            $expectedExit = if ($case -cin @('disabled','unset')) {0} else {1}
            if ($process.ExitCode -ne $expectedExit -or ($stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()).Contains('BYOK_RESPONSE_OWNER_KEY')) { throw ('Register entry-point guard failed: '+$case) }
        } finally { $process.Dispose() }
        $afterHash = if (Test-Path -LiteralPath $entryPath) {(Get-FileHash -LiteralPath $entryPath -Algorithm SHA256).Hash} else {''}
        if ($beforeHash -cne $afterHash) { throw ('Register entry-point guard changed the parameter file: '+$case) }
        $checks++
    }
    $wrapperSource = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../resolve-register-role-assignment.sh'))
    $wrapperDirectory = Join-Path $temporaryDirectory 'scripts'
    $parameterDirectory = Join-Path $temporaryDirectory 'infra'
    $null = New-Item -ItemType Directory -Path $wrapperDirectory,$parameterDirectory
    $wrapper = Join-Path $wrapperDirectory 'resolve-register-role-assignment.sh'
    Copy-Item -LiteralPath $wrapperSource -Destination $wrapper
    $bash = if ($IsWindows) { Join-Path $env:ProgramFiles 'Git/bin/bash.exe' } else { (Get-Command bash -CommandType Application | Select-Object -First 1).Source }
    foreach ($case in @('disabled','unset','missing')) {
        $defaultParameters = Join-Path $parameterDirectory 'main.parameters.json'
        if ($case -ceq 'missing') { Remove-Item -LiteralPath $defaultParameters } else {
            $values = if ($case -ceq 'disabled') { @{deployRegisterApp=@{value=$false}} } else { @{} }
            [IO.File]::WriteAllText($defaultParameters,(@{parameters=$values} | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        }
        $start = [Diagnostics.ProcessStartInfo]::new($bash)
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @($wrapper,'-Stage')) { $start.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            if ($process.ExitCode -ne 0 -or $stdout.GetAwaiter().GetResult() -notlike '*no resolution performed*' -or $stderr.GetAwaiter().GetResult()) {
                throw ('The Bash hook attempted PowerShell resolution for registration-disabled input: '+$case)
            }
        } finally { $process.Dispose() }
        $checks++
    }
} finally { Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force }

if ($RenderedSelectionPath) {
    $selections = (Get-Content -LiteralPath $RenderedSelectionPath -Raw | ConvertFrom-Json -AsHashtable).parameters.selections.value
    if ($selections.newIdentity -cne $selections.newIdentityAgain -or $selections.newIdentity -ceq $selections.recreatedIdentity -or
        $selections.recreatedIdentity -cne $selections.recreatedIdentityDefault -or $selections.preservedLegacy -cne $selections.legacyName -or
        $selections.caseInsensitive -cne $selections.legacyName -or $selections.wrongScope -cne $selections.newIdentity -or
        $selections.wrongRole -cne $selections.newIdentity) { throw 'Compiled Bicep assignment selection does not preserve principal-bound lifecycle semantics.' }
    $checks += 7
}
if ($CompiledMainTemplatePath) {
    $main = Get-Content -LiteralPath $CompiledMainTemplatePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $resources = if ($main.resources -is [Collections.IDictionary]) { @($main.resources.Values) } else { @($main.resources) }
    $modules = @($resources | Where-Object { $_.type -ceq 'Microsoft.Resources/deployments' -and $_.name -ceq 'register-role' })
    if ($modules.Count -ne 1 -or $modules[0].properties.parameters.existingRoleAssignment.value -cne "[parameters('existingRegisterRoleAssignment')]" -or
        $main.parameters.existingRegisterRoleAssignment.defaultValue.name) { throw 'Main does not forward the default-empty existing register assignment reference.' }
    $roleTemplate = $modules[0].properties.template
    $children = if ($roleTemplate.resources -is [Collections.IDictionary]) { @($roleTemplate.resources.Values) } else { @($roleTemplate.resources) }
    $assignments = @($children | Where-Object { $_.type -ceq 'Microsoft.Resources/deployments' -and $_.name -ceq 'register-apim-assignment' })
    if ($assignments.Count -ne 1 -or $assignments[0].properties.mode -cne 'Incremental' -or
        $assignments[0].properties.parameters.principalId.value -notmatch '\.principalId\]' -or
        $assignments[0].properties.parameters.roleDefinitionId.value -cne "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', variables('roleDefName'))]" -or
        -not @($assignments[0].dependsOn | Where-Object { $_ -match 'roleDef' }).Count -or
        $assignments[0].properties.parameters.existingRoleAssignment.value -cne "[parameters('existingRoleAssignment')]") { throw 'Register assignment does not wait for the actual managed identity principal.' }
    $checks += 2
}
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../azure.yaml') -Raw
foreach ($extension in @('ps1','sh')) {
    if (-not $manifest.Contains('./scripts/check-provision-params.'+$extension+' && ./scripts/resolve-register-role-assignment.'+$extension+' -Stage')) {
        throw 'The register assignment resolver must run after parameter validation in both pre-provision hooks.'
    }
    $checks++
}
foreach ($workflowName in @('deploy','deploy-dev')) {
    $workflowText = Get-Content -LiteralPath (Join-Path $PSScriptRoot ('../../.github/workflows/'+$workflowName+'.yml')) -Raw
    if ([regex]::Matches($workflowText, 'run: ./scripts/resolve-register-role-assignment\.ps1 -Stage').Count -ne 1) {
        throw 'Preview must explicitly resolve register assignments because azd preview skips provisioning hooks.'
    }
    $checks++
}

Write-Output ('PASS: '+$checks+' register role reuse, recreation, read-only inventory and staging checks.')