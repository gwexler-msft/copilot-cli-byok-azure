#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ParametersFile,
    [ValidateSet('foundry-basic','foundry-fixed','aoai-fixed')][string]$Profile = 'foundry-basic',
    [switch]$Apply,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
if ($Apply -and $ValidateOnly) { throw 'Choose Apply or ValidateOnly, not both.' }

function New-CallerUpgradePolicies {
    param([string]$Inference,[string]$Models,$Package,[string]$Prefix,[bool]$KeyEnabled,[string]$BackendId,[string]$Audience,[string]$ResponsesId,[string]$BackendPath,[string]$BackendAuth)
    if ($Prefix -cnotmatch '\A[A-Za-z][A-Za-z0-9-]{0,30}-\z' -or $BackendId -cnotmatch '\A[A-Za-z0-9_-]{1,80}\z' -or $ResponsesId -cnotmatch '\A[A-Za-z0-9_-]{1,80}\z' -or $BackendPath -notin @('','/openai') -or $BackendAuth -notin @('managedIdentity','apiKey') -or $Audience -notin @('https://cognitiveservices.azure.us','https://cognitiveservices.azure.com')) { throw 'Invalid caller upgrade namespace or backend contract.' }
    foreach ($name in @('authenticationEntry','responsesPreparation','throttleTelemetry','responses')) {
        if ([string]::IsNullOrWhiteSpace([string]$Package.$name)) { throw 'Render a fresh, complete caller policy package.' }
    }
    $entry = $Package.authenticationEntry.Replace('{{', '{{'+$Prefix).Replace('fragment-id="byok-', 'fragment-id="'+$Prefix+'byok-').Replace('__NATIVE_SUBSCRIPTION_REQUIRED__', $KeyEnabled.ToString().ToLowerInvariant())
    $auth = $entry.Replace('<include-fragment fragment-id="'+$Prefix+'byok-strip-caller-credentials" />', '')
    $preparation = $Package.responsesPreparation.Replace('fragment-id="byok-', 'fragment-id="'+$Prefix+'byok-').Replace('context.Operation.Id == &quot;responses&quot;', 'context.Operation.Id == &quot;'+$ResponsesId+'&quot;')
        $deferredAnthropic = @'
<choose><when condition="@((string)context.Variables[&quot;callerAuthMethod&quot;] != &quot;subscriptionKey&quot;)">
<set-variable name="byokDeferredAnthropic" value="@{
    var path = context.Request.OriginalUrl.Path.ToLowerInvariant();
    var deployment = System.Text.RegularExpressions.Regex.Match(path, &quot;/deployments/([^/]+)/&quot;);
    var model = deployment.Success ? deployment.Groups[1].Value : &quot;&quot;;
    if (!deployment.Success) {
        try { model = ((string)context.Request.Body?.As&lt;JObject&gt;(preserveContent: true)?[&quot;model&quot;] ?? &quot;&quot;).ToLowerInvariant(); } catch { }
    }
    return model.StartsWith(&quot;claude&quot;) || model.StartsWith(&quot;anthropic&quot;);
}" />
<choose><when condition="@((bool)context.Variables[&quot;byokDeferredAnthropic&quot;])"><return-response><set-status code="400" reason="Shared caller authentication is not enabled for Anthropic" /></return-response></when></choose>
</when></choose>
'@
    $inferenceText = [regex]::Replace($Inference, '(?s)<!--.*?-->', '')
    if ([regex]::Matches($inferenceText,'<inbound>\s*<base\s*/>').Count -ne 1 -or $inferenceText -match '<validate-jwt\b|include-fragment') { throw 'Upgrade requires an unmodified supported wizard key-policy baseline.' }
    $inferenceText = [regex]::Replace($inferenceText,'<inbound>\s*<base\s*/>',('<inbound>'+$auth+'<base />'+$deferredAnthropic+'<include-fragment fragment-id="'+$Prefix+'byok-apply-caller-limits" /><include-fragment fragment-id="'+$Prefix+'byok-strip-caller-credentials" />'+$preparation))
    $limiterPattern = '(?s)<(?:llm|azure-openai)-token-limit\s+.*?tokens-consumed-header-name="x-consumed-tokens"\s*/>'
    if ([regex]::Matches($inferenceText,$limiterPattern).Count -ne 1) { throw 'Expected one supported native token limiter.' }
    $inferenceText = [regex]::Replace($inferenceText,$limiterPattern,[Text.RegularExpressions.MatchEvaluator]{param($match) '<choose><when condition="@((string)context.Variables[&quot;callerAuthMethod&quot;] == &quot;subscriptionKey&quot;)">'+$match.Value+'</when></choose>'})
    $primaryPattern = '<set-backend-service(?:\s+id="[^"]+")?\s+backend-id="[^"]+"\s*/>'
    $primary = [regex]::Match($inferenceText,$primaryPattern)
    if (-not $primary.Success) { throw 'Wizard primary backend binding was not found.' }
    $inferenceText = $inferenceText.Remove($primary.Index,$primary.Length).Insert($primary.Index,('<set-backend-service backend-id="'+$BackendId+'" />'))
    $inferenceText = $inferenceText.Replace('REPLACE-WITH-YOUR-FOUNDRY-MI-AUDIENCE',$Audience)
    $modelsText = [regex]::Replace($Models,'(?s)<!--.*?-->','')
    $modelsText = $modelsText.Replace('<inbound>','<inbound>'+$entry).Replace('REPLACE-WITH-YOUR-FOUNDRY-BACKEND-ID',$BackendId).Replace('REPLACE-WITH-YOUR-FOUNDRY-MI-AUDIENCE',$Audience)
    if ($BackendPath -eq '') { $modelsText=$modelsText.Replace('template="/deployments?','template="/openai/deployments?') }
    $utility = $Package.responses.Replace('intellij-', $Prefix).Replace('__NATIVE_SUBSCRIPTION_REQUIRED__',$KeyEnabled.ToString().ToLowerInvariant())
    if ($BackendPath -eq '/openai') { $utility=$utility.Replace('&quot;/openai/v1/responses/&quot;','&quot;/v1/responses/&quot;') }
    $backendCredential = if ($BackendAuth -eq 'apiKey') { '<set-header name="api-key" exists-action="override"><value>{{'+$Prefix+'foundry-api-key}}</value></set-header>' } else { '<authentication-managed-identity resource="'+$Audience+'" />' }
    $managedIdentityPattern = '<authentication-managed-identity resource="'+[regex]::Escape($Audience)+'"\s*/>'
    if ([regex]::IsMatch($inferenceText, $managedIdentityPattern)) {
        $inferenceText = [regex]::Replace($inferenceText, $managedIdentityPattern, $backendCredential)
    } else {
        $inferenceText = $inferenceText.Replace('<set-backend-service backend-id="'+$BackendId+'" />', '<set-backend-service backend-id="'+$BackendId+'" />'+$backendCredential)
    }
    $modelsText = [regex]::Replace($modelsText, $managedIdentityPattern, $backendCredential)
    $affinity = '<choose><when condition="@(context.Operation.Id == &quot;'+$ResponsesId+'&quot; &amp;&amp; !string.IsNullOrEmpty((string)context.Variables[&quot;byokResponseReference&quot;]))"><choose><when condition="@(!(bool)context.Variables[&quot;byokResponseOwnerAuthorized&quot;] || (string)context.Variables[&quot;byokResponseBackendId&quot;] != &quot;'+$BackendId+'&quot;)"><return-response><set-status code="400" reason="Response continuation requires its original backend" /></return-response></when></choose><set-backend-service backend-id="@((string)context.Variables[&quot;byokResponseBackendId&quot;])" /></when></choose>'
    $inferenceText = $inferenceText.Replace('</inbound>', $affinity+'</inbound>')
    $inferenceText = $inferenceText.Replace('</on-error>', $Package.throttleTelemetry+'</on-error>')
    return @{inference=$inferenceText;models=$modelsText;responses=$utility}
}

function Get-CallerUpgradeOperations {
    param([object[]]$Operations,[string]$ModelsId,[string]$ResponsesId)
    $definitions = @(
        @{name='responses-get';method='GET';path='/v1/responses/{response_id}'},
        @{name='responses-delete';method='DELETE';path='/v1/responses/{response_id}'},
        @{name='responses-cancel';method='POST';path='/v1/responses/{response_id}/cancel'},
        @{name='responses-input-items';method='GET';path='/v1/responses/{response_id}/input_items'}
    )
    $modelsFound=$false;$responsesFound=$false;$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($operation in $Operations) {
        if($operation.name -cnotmatch '\A[A-Za-z0-9_-]{1,80}\z' -or -not $seen.Add([string]$operation.name)){throw 'Invalid or duplicate existing operation identity.'}
        if($operation.name -ceq $ModelsId -and $operation.method -ceq 'GET' -and $operation.urlTemplate -ceq '/v1/models'){$modelsFound=$true;continue}
        if($operation.name -ceq $ResponsesId -and $operation.method -ceq 'POST' -and $operation.urlTemplate -ceq '/v1/responses'){$responsesFound=$true}
        else {
            $utility=@($definitions | Where-Object {$_.method -ceq $operation.method -and $_.path -ceq $operation.urlTemplate})
            if($utility.Count -eq 1){$utility[0].name=$operation.name;continue}
            if($operation.method -cne 'POST' -or $operation.urlTemplate -cnotmatch '\A(?:/v1/(?:chat/completions|completions|embeddings)|/deployments/\{[A-Za-z_][A-Za-z0-9_]*\}/chat/completions)\z'){throw 'Uncovered operation found. Review its caller and ownership contract before linking a JWT product.'}
        }
        if(-not [string]::IsNullOrWhiteSpace([string]$operation.policy)) {
            [xml]$policy=$operation.policy
            $inbound=$policy.SelectSingleNode('/policies/inbound')
            if($null -eq $inbound -or $inbound.SelectNodes('*').Count -ne 1 -or $inbound.FirstChild.Name -cne 'base' -or $inbound.FirstChild.Attributes.Count -ne 0){throw 'Inference operation overrides API admission. Merge and review its policy before upgrading.'}
        }
    }
    if(-not $modelsFound -or -not $responsesFound){throw 'Configured discovery and Responses operations must already exist on this API.'}
    if(@($definitions.name|Select-Object -Unique).Count -ne 4){throw 'Stored Responses operation identity collision.'}
    foreach($definition in $definitions){if($seen.Contains($definition.name) -and -not @($Operations|Where-Object {$_.name -ceq $definition.name -and $_.method -ceq $definition.method -and $_.urlTemplate -ceq $definition.path}).Count){throw 'Reserved Responses operation ID is bound to another route.'}}
    return $definitions
}

function New-CallerUpgradePrivateDirectory {
    param([string]$Path)
    if($IsWindows) {
        $directory=New-Item -ItemType Directory -Path $Path -ErrorAction Stop
        $security=Get-Acl -LiteralPath $directory.FullName
        $security.SetAccessRuleProtection($true,$false)
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
        Set-Acl -LiteralPath $directory.FullName -AclObject $security
    } else {
        $null=[IO.Directory]::CreateDirectory($Path,([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute))
    }
}

$root = Split-Path $PSScriptRoot
$parameters = (Get-Content -LiteralPath $ParametersFile -Raw | ConvertFrom-Json -AsHashtable).parameters
if ($parameters -isnot [Collections.IDictionary]) { throw 'Expected an ARM-style parameter document.' }
function Get-CallerUpgradeValue { param([string]$Name,$Default=''); if($parameters.Contains($Name)){return $parameters[$Name].value};return $Default }
foreach($name in @('apimName','apimResourceGroup','apiId','modelsOperationId','existingBackendName','existingBackendOrigin','resourcePrefix','cloudEnv')) {
    if ([string]::IsNullOrWhiteSpace([string](Get-CallerUpgradeValue $name)) -or [string](Get-CallerUpgradeValue $name) -match '[<>\r\n]') { throw 'Set every required caller upgrade parameter; values are not displayed.' }
}
$cloud=Get-CallerUpgradeValue 'cloudEnv'
$null=& "$PSScriptRoot/check-provision-params.ps1" -ParameterFile $ParametersFile -StandaloneCloud $cloud
if ($LASTEXITCODE -ne 0 -or (Get-CallerUpgradeValue 'callerAuthRollout') -notin @('shared','coexistence')) { throw 'Caller upgrade requires validated shared/coexistence configuration.' }
$compiler=Get-Command bicep -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
$bicep=if($compiler){$compiler.Source}elseif(Test-Path "$HOME/.azure/bin/bicep.exe"){"$HOME/.azure/bin/bicep.exe"}else{throw 'A current standalone Bicep compiler is required.'}
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('caller-upgrade-'+[guid]::NewGuid().ToString('N'))
New-CallerUpgradePrivateDirectory -Path $temporary
try {
    $packagePath=Join-Path $temporary 'package.json'
    & $bicep build-params "$root/samples/intellij/standalone/caller-policies.bicepparam" --outfile $packagePath
    if ($LASTEXITCODE -ne 0) { throw 'Caller package rendering failed.' }
    $package=(Get-Content $packagePath -Raw|ConvertFrom-Json -Depth 100).parameters.callerPackage.value
    $profileFile=@{'foundry-basic'='wizard-foundry-policy-basic.xml';'foundry-fixed'='wizard-foundry-policy-fixed.xml';'aoai-fixed'='wizard-aoai-policy-fixed.xml'}[$Profile]
    $inference=Get-Content -LiteralPath (Join-Path $root ('policies/'+$profileFile)) -Raw
    $models=Get-Content -LiteralPath "$root/policies/wizard-foundry-policy-basic-models.xml" -Raw
    $trust=Get-CallerUpgradeValue 'callerAuthPreparation'
    $audience=if($cloud -eq 'AzureUSGovernment'){'https://cognitiveservices.azure.us'}else{'https://cognitiveservices.azure.com'}
    $backendPath=Get-CallerUpgradeValue 'existingBackendPath' '/openai'
    $backendMode=Get-CallerUpgradeValue 'foundryAuthMode' 'managedIdentity'
    $responseId=Get-CallerUpgradeValue 'responsesOperationId' 'responses'
    $policies=New-CallerUpgradePolicies -Inference $inference -Models $models -Package $package -Prefix (Get-CallerUpgradeValue 'resourcePrefix') -KeyEnabled $trust.keyEnabled -BackendId (Get-CallerUpgradeValue 'existingBackendName') -Audience $audience -ResponsesId $responseId -BackendPath $backendPath -BackendAuth $backendMode
    if ($ValidateOnly) { 'PASS: supported wizard consumer composition and shared caller configuration; no Azure calls.'; return }
    function Read-CallerUpgradeAzure {param([string[]]$Arguments);$raw=& az @Arguments -o json --only-show-errors 2>$null;if($LASTEXITCODE -ne 0){throw 'Caller upgrade Azure preflight failed; details suppressed.'};$raw|ConvertFrom-Json}
    $context=Read-CallerUpgradeAzure @('cloud','show')
    if($context.name -cne $cloud){throw 'Wrong cloud; this upgrade never switches the active cloud.'}
    $apimName=Get-CallerUpgradeValue 'apimName';$group=Get-CallerUpgradeValue 'apimResourceGroup';$apiId=Get-CallerUpgradeValue 'apiId'
    $service=Read-CallerUpgradeAzure @('apim','show','-g',$group,'-n',$apimName)
    if($service.virtualNetworkType -ne 'Internal' -or $service.provisioningState -ne 'Succeeded'){throw 'Caller upgrade requires stable internal APIM.'}
    $tiering=Get-CallerUpgradeValue 'callerJwtTiering' $null
    if(($tiering.entra.enabled -or $tiering.okta.enabled) -and $service.sku.name -cnotin @('Developer','Premium')){throw 'JWT tiers currently require classic Developer or Premium APIM.'}
    $api=Read-CallerUpgradeAzure @('apim','api','show','-g',$group,'--service-name',$apimName,'--api-id',$apiId)
    if($api.subscriptionRequired -ne $trust.keyEnabled -or ($trust.keyEnabled -and ($api.subscriptionKeyParameterNames.header -cne 'api-key' -or $api.subscriptionKeyParameterNames.query -cne 'api-key'))){throw 'Existing API native admission must match the requested caller mode before this policy-only upgrade.'}
    $arm=$context.endpoints.resourceManager.TrimEnd('/')
    $backend=Read-CallerUpgradeAzure @('rest','--method','get','--url',($arm+$service.id+'/backends/'+(Get-CallerUpgradeValue 'existingBackendName')+'?api-version=2024-05-01'))
    if(([uri]$backend.properties.url).GetLeftPart([UriPartial]::Authority) -ine (Get-CallerUpgradeValue 'existingBackendOrigin') -or ([uri]$backend.properties.url).AbsolutePath.TrimEnd('/') -cne $backendPath){throw 'Selected backend origin/path does not match the approved wizard contract.'}
    $operations=@(Read-CallerUpgradeAzure @('apim','api','operation','list','-g',$group,'--service-name',$apimName,'--api-id',$apiId))
    foreach($operation in $operations){
        $operationPolicies=Read-CallerUpgradeAzure @('rest','--method','get','--url',($arm+$api.id+'/operations/'+$operation.name+'/policies?api-version=2024-05-01'))
        if($operationPolicies.nextLink -or @($operationPolicies.value).Count -gt 1){throw 'Unexpected operation policy inventory.'}
        $policyValue=if(@($operationPolicies.value).Count){[string]$operationPolicies.value[0].properties.value}else{''}
        $operation|Add-Member -NotePropertyName policy -NotePropertyValue $policyValue
    }
    $responseOperations=@(Get-CallerUpgradeOperations -Operations $operations -ModelsId (Get-CallerUpgradeValue 'modelsOperationId') -ResponsesId $responseId)
    foreach($definition in $responseOperations){
        $defaultName=switch($definition.method+' '+$definition.path){'GET /v1/responses/{response_id}'{'responses-get'};'DELETE /v1/responses/{response_id}'{'responses-delete'};'POST /v1/responses/{response_id}/cancel'{'responses-cancel'};default{'responses-input-items'}}
        $policies.responses=$policies.responses.Replace('&quot;'+$defaultName+'&quot;','&quot;'+$definition.name+'&quot;')
    }
    $products=Read-CallerUpgradeAzure @('rest','--method','get','--url',($arm+$api.id+'/products?api-version=2024-05-01'))
    if($products.nextLink -or @($products.value|Where-Object {$_.properties.subscriptionRequired -eq $false -and $_.name -cne $trust.jwtProductId}).Count){throw 'Unreviewed subscription-free product or incomplete product inventory; caller upgrade is blocked.'}
    $serviceProducts=Read-CallerUpgradeAzure @('apim','product','list','-g',$group,'--service-name',$apimName)
    $existingProduct=@($serviceProducts|Where-Object {$_.name -ceq $trust.jwtProductId})
    if($existingProduct.Count){
        $guard=Read-CallerUpgradeAzure @('rest','--method','get','--url',($arm+$service.id+'/products/'+$trust.jwtProductId+'/policies/policy?api-version=2024-05-01'))
        [xml]$actualGuard=$guard.properties.value
        [xml]$activeGuard=$package.jwtProductGuard.Replace('__ACTIVE__','true')
        [xml]$inactiveGuard=$package.jwtProductGuard.Replace('__ACTIVE__','false')
        if($existingProduct[0].subscriptionRequired -ne $false -or $actualGuard.OuterXml -cnotin @($activeGuard.OuterXml,$inactiveGuard.OuterXml)){throw 'JWT product ID collides with an existing product that is not this exact guarded admission contract.'}
        $links=Read-CallerUpgradeAzure @('rest','--method','get','--url',($arm+$service.id+'/products/'+$trust.jwtProductId+'/apis?api-version=2024-05-01'))
        if($links.nextLink -or @($links.value|Where-Object {$_.name -cne $apiId}).Count){throw 'This upgrade cannot change a JWT product shared with other APIs.'}
    }
    $deployment=[ordered]@{}
    foreach($name in @('apimName','apiId','modelsOperationId','callerAuthPreparation','callerAuthRollout','callerJwtTiering','productTiers','entraTenantId','apiAudience','requiredScope','resourcePrefix','existingBackendName','existingBackendOrigin','jwtDefaultCallsPerMinute','jwtDefaultTokensPerMinute','jwtDefaultMonthlyCallQuota')) {if($parameters.Contains($name)){$deployment[$name]=@{value=$parameters[$name].value}}}
    $deployment.responseOperations=@{value=$responseOperations};$deployment.foundryAuthMode=@{value=$backendMode}
    $deployment.backendKind=@{value=$(if($Profile -eq 'aoai-fixed'){'aoai'}else{'foundry'})}
    $deployment.inferencePolicy=@{value=$policies.inference};$deployment.modelsPolicy=@{value=$policies.models};$deployment.responsePolicy=@{value=$policies.responses}
    $deployment.ownershipCredentialPolicy=@{value=$package.ownershipCredential.Replace('__BACKEND_AUTH_MODE__',$backendMode)}
    $deployment.responseOwnerKey=@{value=$env:BYOK_RESPONSE_OWNER_KEY}
    $deployment.responseOwnerPreviousKey=@{value=$(if($env:BYOK_RESPONSE_OWNER_PREVIOUS_KEY -ceq '__none__'){''}else{$env:BYOK_RESPONSE_OWNER_PREVIOUS_KEY})}
    $deployment.foundryApiKey=@{value=$(if($backendMode -eq 'apiKey'){$env:FOUNDRY_API_KEY}else{''})}
    $deploymentPath=Join-Path $temporary 'parameters.json'
    [IO.File]::WriteAllText($deploymentPath,(@{parameters=$deployment}|ConvertTo-Json -Depth 100),[Text.UTF8Encoding]::new($false))
    $operation=if($Apply){'create'}else{'what-if'}
    $null=& az deployment group $operation -g $group --name ('caller-upgrade-'+$apiId) --template-file "$root/infra/modules/apim-caller-upgrade.bicep" --parameters "@$deploymentPath" --only-show-errors -o none 2>&1
    if($LASTEXITCODE -ne 0){throw 'Caller upgrade did not complete; inspect deployment diagnostics in the pinned session.'}
    'Caller upgrade command completed. Validate live callers and detach JWT product links first before rollback.'
} finally {Remove-Item -LiteralPath $temporary -Recurse -Force}