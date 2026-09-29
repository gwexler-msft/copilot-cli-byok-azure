#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$ParameterFile = (Join-Path $PSScriptRoot '../infra/main.parameters.json'),
    [string]$AzureConfigDirectory = $(if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path $HOME '.azure' }),
    [switch]$Stage,
    [switch]$DefinitionsOnly
)

$ErrorActionPreference = 'Stop'

function Get-RegisterRoleRows {
    param([string]$Url, [scriptblock]$Read, [switch]$AllowMissing)
    $origin = [uri]$Url
    $next = $Url
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    while ($next) {
        $uri = [uri]$next
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or $uri.Authority -ine $origin.Authority -or
            $uri.AbsolutePath -ine $origin.AbsolutePath -or $uri.UserInfo -or $uri.Fragment -or
            -not $seen.Add($next) -or $seen.Count -gt 20 -or
            [System.Web.HttpUtility]::ParseQueryString($uri.Query)['api-version'] -cne [System.Web.HttpUtility]::ParseQueryString($origin.Query)['api-version']) {
            throw 'Register role inventory pagination is unsafe or incomplete.'
        }
        $page = & $Read $next ([bool]$AllowMissing)
        if ($null -eq $page -and $AllowMissing -and $seen.Count -eq 1) { return }
        if ($page -isnot [Collections.IDictionary] -or $page.value -isnot [array] -or $page.error -or
            ($page.Contains('nextLink') -and $null -ne $page.nextLink -and $page.nextLink -isnot [string])) { throw 'Register role inventory is incomplete.' }
        foreach ($row in $page.value) {
            if ($row.id -isnot [string] -or -not $ids.Add($row.id)) { throw 'Register role inventory has an invalid or duplicate resource.' }
            $row
        }
        $next = [string]$page.nextLink
    }
}

function Get-RegisterRoleResolution {
    param($Target, [scriptblock]$Read)
    $emptyReference = @{name='';principalId='';scope='';roleDefinitionId=''}
    if ($Target.subscriptionId -notmatch '\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z' -or
        $Target.namePrefix -cnotmatch '\A[a-z][a-z0-9-]{0,63}\z' -or $Target.envName -cnotmatch '\A[a-z][a-z0-9-]{0,63}\z' -or
        $Target.location -cnotmatch '\A[a-z][a-z0-9]+\z' -or
        $Target.arm -cnotin @('https://management.azure.com','https://management.usgovcloudapi.net')) { throw 'Register role target is invalid.' }
    $groupId = '/subscriptions/'+$Target.subscriptionId+'/resourceGroups/rg-'+$Target.namePrefix+'-'+$Target.envName
    $groupUrl = $Target.arm+$groupId
    $deploymentId = $groupId+'/providers/Microsoft.Resources/deployments/register-role'
    $deployment = & $Read ($Target.arm+$deploymentId+'?api-version=2022-09-01') $true
    if ($null -eq $deployment) {
        $identities = @(Get-RegisterRoleRows ($groupUrl+'/providers/Microsoft.ManagedIdentity/userAssignedIdentities?api-version=2023-01-31') $Read -AllowMissing)
        $prefix = 'id-'+$Target.namePrefix+'-register-'+$Target.envName+'-'
        $prefix = $prefix.Substring(0,[Math]::Min(64,$prefix.Length))
        if (@($identities | Where-Object { $_.name.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) }).Count) {
            throw 'An existing register identity has no compatible deployment record; review adoption before provisioning.'
        }
        return @{reference=$emptyReference;mode='new-principal';otherPrincipalAssignments=0}
    }
    $parameters = $deployment.properties.parameters
    $expectedApimName = 'apim-'+$Target.namePrefix+'-'+$Target.envName+'-'+$parameters.suffix.value
    $expectedApimName = $expectedApimName.Substring(0,[Math]::Min(50,$expectedApimName.Length))
    if ($deployment.id -ine $deploymentId -or $parameters.namePrefix.value -cne $Target.namePrefix -or
        $parameters.envName.value -cne $Target.envName -or $parameters.location.value -ine $Target.location -or
        $parameters.suffix.value -cnotmatch '\A[a-z0-9]{6}\z' -or
        $parameters.apimName.value -cne $expectedApimName) {
        throw 'Register role deployment context differs from the selected parameters.'
    }
    $identityName = 'id-'+$Target.namePrefix+'-register-'+$Target.envName+'-'+$parameters.suffix.value
    $identityName = $identityName.Substring(0,[Math]::Min(64,$identityName.Length))
    $identityId = $groupId+'/providers/Microsoft.ManagedIdentity/userAssignedIdentities/'+$identityName
    $identity = & $Read ($Target.arm+$identityId+'?api-version=2023-01-31') $true
    if ($null -eq $identity) { return @{reference=$emptyReference;mode='new-principal';otherPrincipalAssignments=0} }
    $principalId = [string]$identity.properties.principalId
    $parsed = [guid]::Empty
    if ($identity.id -ine $identityId -or -not [guid]::TryParseExact($principalId,'D',[ref]$parsed) -or
        $identity.properties.tenantId -ine $Target.tenantId) { throw 'Register identity binding could not be verified.' }
    $serviceId = $groupId+'/providers/Microsoft.ApiManagement/service/'+$parameters.apimName.value
    $roleName = 'BYOK Register Subscription Manager ('+$Target.envName+')'
    $filter = [uri]::EscapeDataString("roleName eq '$roleName'")
    $roles = @(Get-RegisterRoleRows ($groupUrl+'/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01&$filter='+$filter) $Read)
    if ($roles.Count -eq 0) { return @{reference=$emptyReference;mode='new-principal';otherPrincipalAssignments=0} }
    if ($roles.Count -ne 1 -or $roles[0].properties.roleName -cne $roleName -or $roles[0].properties.type -cne 'CustomRole' -or
        @($roles[0].properties.assignableScopes).Count -ne 1 -or $roles[0].properties.assignableScopes[0] -ine $groupId -or
        -not [guid]::TryParseExact([string]$roles[0].name,'D',[ref]$parsed)) { throw 'Register custom role is ambiguous or outside the selected scope.' }
    $assignments = @(Get-RegisterRoleRows ($Target.arm+$serviceId+'/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=atScope()') $Read -AllowMissing)
    $sameRole = @($assignments | Where-Object { $_.properties.scope -ieq $serviceId -and
        ([string]$_.properties.roleDefinitionId).Split('/')[-1] -ieq $roles[0].name })
    $matches = @($sameRole | Where-Object { $_.properties.principalId -ieq $principalId })
    $otherCount = @($sameRole | Where-Object { $_.properties.principalId -ine $principalId }).Count
    if ($matches.Count -eq 0) { return @{reference=$emptyReference;mode='new-principal';otherPrincipalAssignments=$otherCount} }
    if ($matches.Count -ne 1 -or -not [guid]::TryParseExact([string]$matches[0].name,'D',[ref]$parsed) -or
        $matches[0].id -ine ($serviceId+'/providers/Microsoft.Authorization/roleAssignments/'+$matches[0].name) -or
        $matches[0].properties.principalType -cne 'ServicePrincipal' -or $matches[0].properties.condition -or
        $matches[0].properties.delegatedManagedIdentityResourceId) { throw 'Register assignment cannot be safely reused.' }
    @{reference=@{name=$matches[0].name;principalId=$principalId;scope=$serviceId;roleDefinitionId=$matches[0].properties.roleDefinitionId};mode='reuse-existing';otherPrincipalAssignments=$otherCount}
}

function Set-RegisterRoleReference {
    param([string]$Path, [byte[]]$OriginalBytes, $Document, $Reference)
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -cne [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($OriginalBytes))) {
        throw 'Parameter file changed during register role resolution; no update was written.'
    }
    $Document.parameters.existingRegisterRoleAssignment = @{value=$Reference}
    $temporary = $Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,($Document | ConvertTo-Json -Depth 100)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
        if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -cne [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($OriginalBytes))) {
            throw 'Parameter file changed during register role resolution; no update was written.'
        }
        [IO.File]::Move($temporary,$Path,$true)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}

if ($DefinitionsOnly) { return }

try {
    if (-not (Test-Path -LiteralPath $ParameterFile -PathType Leaf)) {
        if ($PSBoundParameters.ContainsKey('ParameterFile')) { throw 'Explicit register parameter file is missing.' }
        Write-Output '[register-role] No staged parameter file; no resolution performed.'
        exit 0
    }
    $path = (Resolve-Path -LiteralPath $ParameterFile).Path
    $originalBytes = [IO.File]::ReadAllBytes($path)
    $document = [Text.Encoding]::UTF8.GetString($originalBytes).TrimStart([char]0xFEFF) | ConvertFrom-Json -AsHashtable -Depth 100
    if ($document.parameters -isnot [Collections.IDictionary]) { throw 'Invalid register parameter document.' }
    $enabled = $document.parameters.deployRegisterApp.value
    if ($null -ne $enabled -and $enabled -isnot [bool]) { throw 'deployRegisterApp must be an explicit boolean.' }
    if (-not $enabled) {
        Write-Output '[register-role] Registration is disabled; no resolution performed.'
        exit 0
    }
    $values = @{}
    foreach ($name in @('namePrefix','envName','location','cloudEnv')) {
        $value = $document.parameters[$name].value
        if ($value -isnot [string]) { throw 'Register role resolution requires explicit deployment context.' }
        if ($value -cmatch '\A\$\{([A-Za-z_][A-Za-z0-9_]*)\}\z') { $value = [Environment]::GetEnvironmentVariable($Matches[1]) }
        if ([string]::IsNullOrWhiteSpace($value)) { throw 'Register role deployment context is unresolved.' }
        $values[$name] = $value
    }
    if ($values.cloudEnv -cnotin @('AzureCloud','AzureUSGovernment') -or [string]::IsNullOrWhiteSpace($env:AZURE_SUBSCRIPTION_ID)) {
        throw 'Register role resolution requires an explicit subscription and supported cloud.'
    }
    $helpers = New-Module -ArgumentList (Join-Path $PSScriptRoot 'preview-private-client-access.ps1') -ScriptBlock {
        param($Path)
        . $Path -DefinitionsOnly
        Export-ModuleMember -Function Invoke-PrivateClientAzure
    }
    Import-Module $helpers -Scope Local -DisableNameChecking
    $account = Invoke-PrivateClientAzure @('account','show','--subscription',$env:AZURE_SUBSCRIPTION_ID,'--output','json') $AzureConfigDirectory
    $cloud = Invoke-PrivateClientAzure @('cloud','show','--output','json') $AzureConfigDirectory
    if ($account.id -ine $env:AZURE_SUBSCRIPTION_ID -or $account.environmentName -cne $values.cloudEnv -or $cloud.name -cne $values.cloudEnv) {
        throw 'Register role resolution requires the matching cloud-pinned session.'
    }
    $target = @{subscriptionId=$account.id;tenantId=$account.tenantId;namePrefix=$values.namePrefix;envName=$values.envName;location=$values.location;
        arm=$(if ($values.cloudEnv -ceq 'AzureUSGovernment') {'https://management.usgovcloudapi.net'} else {'https://management.azure.com'})}
    $groupPath = '/subscriptions/'+$target.subscriptionId+'/resourceGroups/rg-'+$target.namePrefix+'-'+$target.envName+'/'
    $reader = {
        param([string]$Url, [bool]$AllowMissing)
        $uri = [uri]$Url
        if ($uri.Scheme -cne 'https' -or $uri.Authority -ine ([uri]$target.arm).Authority -or $uri.UserInfo -or $uri.Fragment -or
            -not $uri.AbsolutePath.StartsWith($groupPath,[StringComparison]::OrdinalIgnoreCase)) { throw 'Register role read leaves the selected resource group.' }
        try {
            Invoke-PrivateClientAzure @('rest','--method','GET','--url',$Url,'--headers','Accept=application/json','--subscription',$target.subscriptionId,'--output','json','--only-show-errors') $AzureConfigDirectory
        } catch {
            $codes = @($_.Exception.Data['AzureCodes'])
            if ($AllowMissing -and @($codes | Where-Object { $_ -cin @('ResourceNotFound','ResourceGroupNotFound') }).Count -and
                -not @($codes | Where-Object { $_ -cnotin @('ResourceNotFound','ResourceGroupNotFound') }).Count) { return $null }
            throw 'Register role read failed; no assignment or parameter change was made.'
        }
    }
    $resolution = Get-RegisterRoleResolution $target $reader
    if ($Stage) { Set-RegisterRoleReference $path $originalBytes $document $resolution.reference }
    @{mode=$resolution.mode;otherPrincipalAssignmentsRetained=$resolution.otherPrincipalAssignments;parameterStaged=[bool]$Stage;azureWrites=0} | ConvertTo-Json -Compress
    exit 0
} catch {
    [Console]::Error.WriteLine('[register-role] Resolution failed; no Azure write was attempted. Verify the selected context and existing assignment before provisioning.')
    exit 1
}