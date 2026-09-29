#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('AzureCloud', 'AzureUSGovernment')]
    [string] $Cloud,
    [Parameter(Mandatory)]
    [string] $ResourceGroup,
    [Parameter(Mandatory)]
    [string] $ApimName,
    [Parameter(Mandatory)]
    [string] $VmName,
    [ValidatePattern('^jwt-probe-[a-z0-9-]+$')]
    [string] $ProbeId = ('jwt-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 12)),
    [switch] $TestExisting,
    [switch] $IncludeUserToken,
    [switch] $AddValidationControls,
    [switch] $AdmissionProbe,
    [switch] $ProductContextGuard,
    [switch] $OpenProductProbe,
    [switch] $ExpandedGate,
    [switch] $BackendGate,
    [switch] $ProductionPipelineGate,
    [switch] $Http2Gate,
    [string] $Http2ClientArchivePath,
    [string] $Http2ClientSha256,
    [switch] $ParameterGate,
    [switch] $HeaderParityGate,
    [switch] $AnthropicMeteringGate,
    [switch] $SharedRuntimeGate,
    [switch] $SharedGovernanceGate,
    [switch] $OperationalGate,
    [switch] $RealResponsesGate,
    [string] $SharedConsumerPolicyPath,
    [string] $CallerPackagePath,
    [ValidateSet('web','cli')]
    [string] $ArmTransport = 'web',
    [ValidateSet('both', 'azure-openai-token-limit', 'llm-token-limit')]
    [string] $MeteringPolicy = 'both',
    [switch] $AssociationGate,
    [ValidateSet('api-key', 'x-api-key')]
    [string] $CredentialHeader = 'api-key',
    [string] $BackendAddress,
    [string] $ApimSourcePrefix,
    [securestring] $ExpiredUserToken,
    [securestring] $SecondUserToken,
    [scriptblock] $SecondUserTokenProvider,
    [switch] $ValidateOnly
)

$ErrorActionPreference = 'Stop'
if (($HeaderParityGate -or $AnthropicMeteringGate -or $SharedRuntimeGate) -and ($TestExisting -or $IncludeUserToken -or $AddValidationControls -or $AdmissionProbe -or
    $ProductContextGuard -or $OpenProductProbe -or $ExpandedGate -or $BackendGate -or $ProductionPipelineGate -or
    $Http2Gate -or $ParameterGate -or $AssociationGate -or $ExpiredUserToken -or ($SecondUserToken -and -not ($SharedGovernanceGate -or $RealResponsesGate)))) {
    throw 'HeaderParityGate is an isolated inert HTTP/1.1 observation and cannot combine with credential, admission or backend gates.'
}
if (@($HeaderParityGate, $AnthropicMeteringGate, $SharedRuntimeGate | Where-Object { $_ }).Count -gt 1) { throw 'Run isolated diagnostics separately.' }
if ($SharedConsumerPolicyPath -and -not $SharedRuntimeGate) { throw 'Rendered consumer checks require the isolated shared runtime gate.' }
if ($CallerPackagePath -and (-not $SharedRuntimeGate -or -not $SharedConsumerPolicyPath)) { throw 'Package compatibility requires the shared runtime and rendered consumer gates.' }
if($OperationalGate -and (-not $SharedGovernanceGate -or -not $CallerPackagePath)){throw 'Operational acceptance requires shared mock governance and a freshly rendered caller package.'}
if ($SharedGovernanceGate -and (-not $SharedRuntimeGate -or -not $SharedConsumerPolicyPath -or (-not $ValidateOnly -and -not ($SecondUserToken -or $SecondUserTokenProvider)))) { throw 'Shared governance requires the shared runtime gate, rendered consumers and a second delegated user credential source.' }
if ($RealResponsesGate -and ($SharedGovernanceGate -or -not $SharedRuntimeGate -or -not $SharedConsumerPolicyPath -or (-not $ValidateOnly -and -not ($SecondUserToken -or $SecondUserTokenProvider)))) { throw 'Real Responses acceptance requires isolated shared runtime, rendered policies and two delegated credentials; it cannot combine with mock governance.' }
if ($SecondUserToken -and -not ($BackendGate -or $SharedGovernanceGate -or $RealResponsesGate)) { throw 'SecondUserToken requires an isolated two-user backend gate.' }
if ($SecondUserTokenProvider -and (-not ($SharedGovernanceGate -or $RealResponsesGate) -or $SecondUserToken)) { throw 'A delayed second-user credential source is exclusive to shared backend gates and cannot combine with a captured token.' }

function Resolve-ProbeSecondUserToken {
    param([securestring] $Token, [scriptblock] $Provider)
    if ($Token -and $Provider) { throw 'Use one second-user credential source.' }
    try { $values = @(if ($Provider) { & $Provider } else { $Token }) }
    catch { throw 'Second-user credential refresh failed; reauthenticate securely in the existing pinned cache.' }
    if ($values.Count -ne 1 -or $values[0] -isnot [securestring] -or $values[0].Length -eq 0) { throw 'Second-user credential source must return exactly one nonempty SecureString.' }
    return $values[0]
}

function New-ProbeSharedRuntimeFragments {
    param([string] $MockBackendUrl, [string] $MockBackendNonce, [string] $SourceRoot = $PSScriptRoot)
    $fragmentRoot = Join-Path $SourceRoot '../policies/fragments'
    $sources = @{}
    foreach ($name in @('byok-authenticate', 'byok-credential-source', 'byok-validate-entra', 'byok-strip-caller-credentials', 'byok-apply-caller-limits',
        'byok-response-owner-context', 'byok-prepare-responses-request', 'byok-read-response-owner', 'byok-verify-response-owner', 'byok-locate-response-owner', 'byok-response-backend-credential')) {
        $sources[$name] = [xml](Get-Content -Raw (Join-Path $fragmentRoot ($name + '.xml')))
    }
    $sources['byok-validate-okta'] = [xml]'<fragment><return-response><set-status code="401" reason="Fixture issuer disabled" /></return-response></fragment>'
    if ($MockBackendUrl -or $MockBackendNonce) {
        if ($MockBackendUrl -cnotmatch '\Ahttp://(?:[0-9]{1,3}\.){3}[0-9]{1,3}:18741/jwt-probe-[a-z0-9-]+\z' -or $MockBackendNonce -cnotmatch '\A[A-Fa-f0-9]{64}\z') { throw 'Shared ownership mock requires its bounded private listener and disposable nonce.' }
        $sources['byok-response-backend-credential'] = [xml]('<fragment><set-variable name="byokResponseBackendCredentialHeader" value="api-key" /><set-variable name="byokResponseBackendCredential" value="' + $MockBackendNonce + '" /></fragment>')
        $lookup = $sources['byok-read-response-owner'].SelectSingleNode('/fragment/send-request')
        $lookup.SelectSingleNode('set-url').InnerText = '@("' + $MockBackendUrl + '" + new Uri((string)context.Variables["byokResponseLookupUrl"]).PathAndQuery)'
        $header = $sources['byok-read-response-owner'].CreateElement('set-header')
        $header.SetAttribute('name', 'X-Probe-Case')
        $header.SetAttribute('exists-action', 'override')
        $value = $sources['byok-read-response-owner'].CreateElement('value')
        $value.InnerText = '@(context.Request.Headers.GetValueOrDefault("X-Probe-Case", ""))'
        $null = $header.AppendChild($value)
        $null = $lookup.AppendChild($header)
        $header = $sources['byok-read-response-owner'].CreateElement('set-header')
        $header.SetAttribute('name', 'X-Probe-Lookup')
        $header.SetAttribute('exists-action', 'override')
        $value = $sources['byok-read-response-owner'].CreateElement('value')
        $value.InnerText = 'true'
        $null = $header.AppendChild($value)
        $null = $lookup.AppendChild($header)
    }
    $evaluation = [xml]$sources['byok-verify-response-owner'].OuterXml
    $null = $evaluation.fragment.RemoveChild($evaluation.SelectSingleNode('/fragment/choose'))
    $sources['byok-evaluate-response-owner'] = $evaluation
    $result = @{}
    foreach ($name in @('byok-authenticate', 'byok-strip-caller-credentials', 'byok-apply-caller-limits', 'byok-response-owner-context',
        'byok-prepare-responses-request', 'byok-read-response-owner', 'byok-verify-response-owner', 'byok-locate-response-owner')) {
        [xml]$document = $sources[$name].OuterXml
        foreach ($include in @($document.SelectNodes('//include-fragment'))) {
            $component = $sources[$include.GetAttribute('fragment-id')]
            if (-not $component) { throw 'Unknown shared runtime fragment dependency.' }
            foreach ($node in @($component.fragment.ChildNodes)) { $null = $include.ParentNode.InsertBefore($document.ImportNode($node, $true), $include) }
            $null = $include.ParentNode.RemoveChild($include)
        }
        if ($document.SelectNodes('//include-fragment').Count) { throw 'Runtime fixture must flatten every nested include.' }
        $result[$name] = $document.OuterXml
    }
    return $result
}

function New-ProbeRollbackPolicy {
    param([ValidatePattern('^jwt-probe-[a-z0-9-]+$')][string]$Owner,[string]$AuthenticationEntry,[string]$NativeGuard,[switch]$Legacy)
    $entry=if($Legacy){
        if($NativeGuard -notmatch 'context.Subscription == null' -or $NativeGuard -notmatch 'Product.SubscriptionRequired'){throw 'Rollback requires the canonical native-admission guard.'}
        $NativeGuard+'<set-header name="api-key" exists-action="delete" /><set-header name="Authorization" exists-action="delete" />'
    }else{
        if($AuthenticationEntry -notmatch 'fragment-id="byok-authenticate"' -or $AuthenticationEntry -notmatch '__NATIVE_SUBSCRIPTION_REQUIRED__'){throw 'Rollback baseline requires the canonical shared authentication entry.'}
        $AuthenticationEntry.Replace('__NATIVE_SUBSCRIPTION_REQUIRED__','true').Replace('fragment-id="byok-','fragment-id="'+$Owner+'-byok-')
    }
    return '<policies><inbound>'+$entry+'<return-response><set-status code="200" reason="Isolated rollback check" /><set-header name="X-Probe-Rollback" exists-action="override"><value>'+$Owner+'</value></set-header><set-header name="X-Probe-Stripped" exists-action="override"><value>@((!context.Request.Headers.ContainsKey(&quot;api-key&quot;) &amp;&amp; !context.Request.Headers.ContainsKey(&quot;Authorization&quot;)).ToString())</value></set-header><set-body>{"backendCalled":false}</set-body></return-response></inbound><backend /><outbound /><on-error /></policies>'
}

function New-ProbeSharedGovernancePolicies {
    param([ValidatePattern('^jwt-probe-[a-z0-9-]+$')] [string] $Owner, [string] $MockBackendUrl, [string] $Nonce, [string] $ResponsesPolicy, [string] $SourceRoot = $PSScriptRoot, [string]$ThrottleTelemetry)
    if ($MockBackendUrl -cnotmatch ('\Ahttp://(?:[0-9]{1,3}\.){3}[0-9]{1,3}:18741/' + [regex]::Escape($Owner) + '\z') -or $Nonce -cnotmatch '\A[A-Fa-f0-9]{64}\z') { throw 'Governance policies require the owned private mock and nonce.' }
    [xml]$utility = $ResponsesPolicy
    $referenceNames = @('byok-authenticate', 'byok-strip-caller-credentials', 'byok-response-owner-context', 'byok-locate-response-owner')
    if ((@($utility.SelectNodes('//include-fragment') | ForEach-Object { $_.GetAttribute('fragment-id') }) -join ',') -cne ($referenceNames -join ',')) { throw 'Expected the actual owner-checked Responses utility template.' }
    foreach ($include in $utility.SelectNodes('//include-fragment')) { $include.SetAttribute('fragment-id', ($Owner + '-' + $include.GetAttribute('fragment-id'))) }
    foreach ($route in $utility.SelectNodes('//set-backend-service')) { $route.SetAttribute('backend-id', ($Owner + '-mock')) }
    $correlation = '<set-header name="X-Probe-Backend-Nonce" exists-action="override"><value>' + $Nonce + '</value></set-header>'
    $utilityText = $utility.OuterXml.Replace('</inbound>', ($correlation + '</inbound>'))
    $utilityText = $utilityText.Replace('&quot;/openai/v1/responses/&quot;', ('&quot;/' + $Owner + '/openai/v1/responses/&quot;'))
    $preparation = @'
<choose><when condition="@(context.Operation.Id == &quot;responses&quot;)">
<include-fragment fragment-id="__OWNER__-byok-response-owner-context" />
<include-fragment fragment-id="__OWNER__-byok-prepare-responses-request" />
<choose><when condition="@(!string.IsNullOrEmpty((string)context.Variables[&quot;byokResponseReference&quot;]))">
<include-fragment fragment-id="__OWNER__-byok-locate-response-owner" />
<set-variable name="byokResponseBackendCredential" value="" />
</when></choose></when></choose>
'@.Replace('__OWNER__', $Owner)
    $inference = @'
<policies><inbound>
<set-variable name="byokCredentialHeader" value="api-key" />
<include-fragment fragment-id="__OWNER__-byok-authenticate" />
<base />
<include-fragment fragment-id="__OWNER__-byok-apply-caller-limits" />
<include-fragment fragment-id="__OWNER__-byok-strip-caller-credentials" />
__PREPARATION__
<set-backend-service backend-id="__OWNER__-mock" />
<set-header name="X-Probe-Backend-Nonce" exists-action="override"><value>__NONCE__</value></set-header>
<rewrite-uri template="@(&quot;/__OWNER__&quot; + (context.Operation.Id == &quot;responses&quot; ? &quot;/openai/v1/responses&quot; : &quot;/openai/v1/chat/completions&quot;))" copy-unmatched-params="true" />
</inbound><backend><forward-request timeout="30" buffer-response="false" /></backend>
<outbound><set-header name="X-Probe-Method" exists-action="override"><value>@((string)context.Variables["callerAuthMethod"])</value></set-header>
<set-header name="X-Probe-Product" exists-action="override"><value>@(context.Variables.ContainsKey("probeNativeProduct") ? "True" : "False")</value></set-header>
<set-header name="X-Probe-Accounted" exists-action="override"><value>@(((bool)context.Variables["byokCallerAccountingApplied"]).ToString())</value></set-header>
</outbound><on-error /></policies>
'@.Replace('__OWNER__', $Owner).Replace('__NONCE__', $Nonce).Replace('__PREPARATION__', $preparation)
    if($ThrottleTelemetry){
        [xml]$telemetry='<fragment>'+$ThrottleTelemetry+'</fragment>'
                $metrics=@($telemetry.SelectNodes('/fragment/choose/when/emit-metric'))
                $tierMetrics=@($telemetry.SelectNodes('/fragment/choose/when/choose/when/emit-metric'))
                if($metrics.Count -ne 2 -or ($metrics.name -join ',') -cne 'copilot_byok_throttled,copilot_byok_caller_throttled' -or
                    @($metrics|Where-Object {$_.SelectNodes('dimension').Count -ne 5}).Count -or $tierMetrics.Count -gt 1 -or
                    @($tierMetrics|Where-Object {$_.name -cne 'copilot_byok_tier_throttled' -or ($_.SelectNodes('dimension').name -join ',') -cne 'auth_method,tier,operation,throttle'}).Count -or
                    $telemetry.SelectNodes('//emit-metric').Count -ne $metrics.Count+$tierMetrics.Count){throw 'Expected canonical caller metrics and only the optional bounded tier metric.'}
                foreach($operation in $telemetry.SelectNodes('//emit-metric[@name="copilot_byok_caller_throttled" or @name="copilot_byok_tier_throttled"]/dimension[@name="operation"]')){
                    if($operation.GetAttribute('value') -cne '@(context.Operation.Id)'){throw 'Shared caller metric operation binding changed.'}
                    $operation.SetAttribute('value',('@("'+$Owner+':" + context.Operation.Id)'))
                }
        $marker='<set-variable name="backendName" value="'+$Owner+':governance" /><set-variable name="deploymentName" value="probe-governance" />'
        $inference=$inference.Replace('<include-fragment fragment-id="'+$Owner+'-byok-apply-caller-limits" />',$marker+'<include-fragment fragment-id="'+$Owner+'-byok-apply-caller-limits" />').Replace('<on-error />','<on-error>'+$telemetry.fragment.InnerXml+'</on-error>')
    }
    $productSource = Get-Content -Raw (Join-Path $SourceRoot '../infra/modules/apim-jwt-product.bicep')
    $productMatch = [regex]::Match($productSource, "var jwtProductGuardTemplate string = '(?<policy><policies>.*?</policies>)'")
    if (-not $productMatch.Success) { throw 'Expected the actual JWT product guard source.' }
    $product = $productMatch.Groups['policy'].Value.Replace('__ACTIVE__', 'true')
    [xml]$inferenceDocument = $inference
    if ($inferenceDocument.SelectNodes('//send-request|//authentication-managed-identity|//validate-jwt').Count -or $inferenceDocument.SelectSingleNode('/policies/backend/forward-request').GetAttribute('buffer-response') -ne 'false') { throw 'Unexpected governance mock routing or buffering.' }
    return @{ inference = $inference; utility = $utilityText; jwtProduct = $product }
}

function New-ProbeRealResponsesPolicies {
    param([ValidatePattern('^jwt-probe-[a-z0-9-]+$')] [string] $Owner, [ValidatePattern('^[A-Fa-f0-9]{64}$')] [string] $Nonce,
        [ValidatePattern('^[A-Za-z0-9._-]{1,128}$')] [string] $Model, [string] $Inference, [string] $Utility, [string] $Models)
    $guard = '<choose><when condition="@(context.Request.Headers.GetValueOrDefault(&quot;X-Probe-Run&quot;, &quot;&quot;) != &quot;' + $Nonce + '&quot;)"><return-response><set-status code="403" reason="Diagnostic access required" /></return-response></when></choose><set-header name="X-Probe-Run" exists-action="delete" />'
    $bodyGuard = @'
<choose><when condition="@{
  try {
    var body = context.Request.Body.As&lt;Newtonsoft.Json.Linq.JObject&gt;(preserveContent: true);
    return context.Operation.Id != &quot;responses&quot; || (string)body[&quot;model&quot;] != &quot;__MODEL__&quot;
      || body[&quot;input&quot;]?.Type != Newtonsoft.Json.Linq.JTokenType.String || ((string)body[&quot;input&quot;]).Length &gt; 256
      || body[&quot;max_output_tokens&quot;]?.Type != Newtonsoft.Json.Linq.JTokenType.Integer || (int)body[&quot;max_output_tokens&quot;] &lt; 1 || (int)body[&quot;max_output_tokens&quot;] &gt; 256;
  } catch { return true; }
}"><return-response><set-status code="400" reason="Diagnostic request exceeds approval" /></return-response></when></choose>
<quota-by-key calls="4" renewal-period="86400" counter-key="__OWNER__:real-response-attempts" />
'@.Replace('__MODEL__', $Model).Replace('__OWNER__', $Owner)
    $result = @{}
    foreach ($entry in @(@{name='inference';value=$Inference},@{name='utility';value=$Utility},@{name='models';value=$Models})) {
        $content = [regex]::Replace($entry.value, '(?s)<!--.*?-->', '').Trim()
        if ([regex]::Matches($content, '<inbound>').Count -ne 1 -or $content -match '__NATIVE_SUBSCRIPTION_REQUIRED__|__SHARED_AUTHENTICATION__' -or
            -not $content.Contains('<include-fragment fragment-id="byok-authenticate" />')) { throw 'Real-backend fixture requires a fully rendered shared consumer.' }
        foreach ($reference in [regex]::Matches($content, '<include-fragment\s+fragment-id="(byok-[a-z-]+)"\s*/>')) {
            $content = $content.Replace($reference.Value, ('<include-fragment fragment-id="' + $Owner + '-' + $reference.Groups[1].Value + '" />'))
        }
        $content = $content.Replace('<inbound>', ('<inbound>' + $guard + $(if ($entry.name -eq 'inference') { $bodyGuard } else { '' })))
        if ($entry.name -eq 'inference') {
            $retryPattern = '(?s)<retry\b(?:"[^"]*"|[^">])*>\s*(<forward-request\b[^>]*/>)\s*</retry>'
            if ([regex]::Matches($content, $retryPattern).Count -ne 1) { throw 'Expected exactly one inference retry wrapper to disable for the real-call budget.' }
            $content = [regex]::Replace($content, $retryPattern, '$1')
            if ($content -match '<retry\b' -or [regex]::Matches($content, '<forward-request\b').Count -ne 1) { throw 'Real inference must never retry an approved model call automatically.' }
            $content = $content.Replace('copilot_byok_', 'copilot_byok_probe_')
        }
        if ($entry.name -eq 'models') {
            [xml]$modelsDocument=$content
            $backend=$modelsDocument.SelectSingleNode('/policies/backend')
            $backend.RemoveAll()
            $null=$backend.AppendChild($modelsDocument.CreateElement('forward-request'))
            $content=$modelsDocument.OuterXml
        }
        $result[$entry.name] = $content
    }
    return $result
}

function New-ProbePackageConsumerPolicies {
    param($Package,$Standalone,[ValidateSet('AzureCloud','AzureUSGovernment')][string]$Cloud,[string]$SourceRoot=$PSScriptRoot)
    if($Package.version -ne 1 -or -not $Standalone.inference -or -not $Standalone.models -or -not $Standalone.responses){throw 'Fresh complete standalone policy packages are required.'}
    $errors=$null
    $upgradeAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'update-caller-auth.ps1'),[ref]$null,[ref]$errors)
    $definition=@($upgradeAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-CallerUpgradePolicies'},$false))
    if($errors.Count -or $definition.Count -ne 1){throw 'Wizard policy composition function is unavailable.'}
    . ([scriptblock]::Create($definition[0].Extent.Text))
    $audience=if($Cloud -eq 'AzureUSGovernment'){'https://cognitiveservices.azure.us'}else{'https://cognitiveservices.azure.com'}
    $values=@{
        'foundry-backend-id'='foundry';'foundry-api-key'='fixture-backend-key';'foundry-mi-audience'=$audience
        'api-version'='2025-04-01-preview';'auto-sentinel'='';'auto-mini-deployment'='';'auto-full-deployment'=''
        'auto-length-threshold'='1000';'auto-ambiguous-band'='100';'metrics-enabled'='false'
    }
    $entries=@(foreach($kind in @('inference','models','responses')){
        [pscustomobject]@{name='intellij-'+$kind;format=$(if($kind -eq 'responses'){'xml'}else{'rawxml'});value=[string]$Standalone.$kind}
    })
    $models=Get-Content -LiteralPath (Join-Path $SourceRoot '../policies/wizard-foundry-policy-basic-models.xml') -Raw
    foreach($profile in @('foundry-basic','foundry-fixed','aoai-fixed')){
        $file=@{'foundry-basic'='wizard-foundry-policy-basic.xml';'foundry-fixed'='wizard-foundry-policy-fixed.xml';'aoai-fixed'='wizard-aoai-policy-fixed.xml'}[$profile]
        $baseline=Get-Content -LiteralPath (Join-Path $SourceRoot ('../policies/'+$file)) -Raw
        $bound=New-CallerUpgradePolicies -Inference $baseline -Models $models -Package $Package -Prefix 'wizard-probe-' -KeyEnabled $false -BackendId 'foundry' -Audience $audience -ResponsesId 'responses' -BackendPath '/openai' -BackendAuth 'managedIdentity'
        foreach($kind in @('inference','models','responses')){
            $entries+=[pscustomobject]@{name='wizard-'+$profile+'-'+$kind;format=$(if($kind -eq 'inference'){'rawxml'}else{'xml'});value=[string]$bound.$kind}
        }
    }
    foreach($entry in $entries){
        $content=$entry.value.Replace('__NATIVE_SUBSCRIPTION_REQUIRED__','false')
        foreach($prefix in @('intellij-','wizard-probe-')){
            $content=$content.Replace('fragment-id="'+$prefix+'byok-','fragment-id="byok-')
            foreach($reference in [regex]::Matches($content,'\{\{'+[regex]::Escape($prefix)+'([A-Za-z0-9-]+)\}\}')){
                $name=$reference.Groups[1].Value
                $replacement=if($values.ContainsKey($name)){[Security.SecurityElement]::Escape([string]$values[$name])}else{'{{'+$name+'}}'}
                $content=$content.Replace($reference.Value,$replacement)
            }
        }
        [pscustomobject]@{name=$entry.name;format=$entry.format;value=$content}
    }
}

function New-ProbeSharedConsumerPolicies {
    param([object[]] $Policies, [ValidatePattern('^jwt-probe-[a-z0-9-]+$')] [string] $Owner, [object[]]$PackagePolicies=@())
    $expected = @{ 'foundry-inference' = 'rawxml'; 'aoai-inference' = 'rawxml'; 'foundry-models' = 'xml'; 'responses-item' = 'xml' }
    if ($Policies.Count -ne $expected.Count -or @($Policies.name | Select-Object -Unique).Count -ne $expected.Count) { throw 'Expected all four rendered shared consumer policies.' }
    if($PackagePolicies.Count){
        foreach($kind in @('inference','models','responses')){$expected['intellij-'+$kind]=$(if($kind -eq 'responses'){'xml'}else{'rawxml'})}
        foreach($profile in @('foundry-basic','foundry-fixed','aoai-fixed')){
            foreach($kind in @('inference','models','responses')){$expected['wizard-'+$profile+'-'+$kind]=$(if($kind -eq 'inference'){'rawxml'}else{'xml'})}
        }
        $Policies=@($Policies)+@($PackagePolicies)
        if($Policies.Count -ne 16 -or @($Policies.name|Select-Object -Unique).Count -ne 16){throw 'Expected all twelve standalone/wizard consumers alongside the four main policies.'}
    }
    $fragmentNames = @('byok-authenticate', 'byok-strip-caller-credentials', 'byok-apply-caller-limits', 'byok-response-owner-context', 'byok-prepare-responses-request', 'byok-locate-response-owner')
    foreach ($entry in $Policies) {
        if (-not $expected.ContainsKey($entry.name) -or $entry.format -cne $expected[$entry.name] -or $entry.value -isnot [string]) { throw 'Unexpected rendered shared consumer shape.' }
        $content = [regex]::Replace($entry.value, '(?s)<!--.*?-->', '').Trim()
        if (-not $content.StartsWith('<policies>', [StringComparison]::Ordinal) -or -not $content.EndsWith('</policies>', [StringComparison]::Ordinal) -or
            [regex]::Matches($content, '<inbound>').Count -ne 1 -or [regex]::Matches($content, '</inbound>').Count -ne 1 -or
            $content.Contains('__NATIVE_SUBSCRIPTION_REQUIRED__') -or $content.Contains('__SHARED_AUTHENTICATION__') -or
            -not $content.Contains('<include-fragment fragment-id="byok-authenticate" />')) { throw 'Consumer rendering is incomplete or its inbound boundary is ambiguous.' }
        foreach ($reference in [regex]::Matches($content, '<include-fragment\s+fragment-id="([^"]+)"\s*/>')) {
            $fragmentName = $reference.Groups[1].Value
            if ($fragmentName -notin $fragmentNames) { throw 'Consumer references an unexpected fragment.' }
            $content = $content.Replace($reference.Value, ('<include-fragment fragment-id="' + $Owner + '-' + $fragmentName + '" />'))
        }
        if ([regex]::Matches($content, '<include-fragment\b').Count -ne [regex]::Matches($content, ('<include-fragment fragment-id="' + [regex]::Escape($Owner) + '-byok-[a-z-]+" />')).Count) { throw 'Consumer contains an unbound fragment reference.' }
        $denial = '<return-response><set-status code="403" reason="Isolated consumer compilation" /><set-header name="X-Probe-Consumer" exists-action="override"><value>' + $Owner + ':' + $entry.name + '</value></set-header><set-body>{"modelCalled":false}</set-body></return-response>'
        $content = $content.Replace('<inbound>', ('<inbound>' + $denial))
        if ($entry.format -eq 'xml') {
            [xml]$document = $content
            if ($document.SelectSingleNode('/policies/inbound/*[1]').Name -ne 'return-response') { throw 'Consumer denial must be its first inbound statement.' }
        }
        [pscustomobject]@{ name = $entry.name; format = $entry.format; value = $content }
    }
}

function Set-ProbeSharedRuntimePolicy {
    param([string] $ApiPath, [string] $Policy, [string[]] $FragmentPaths, [string] $OwnerDescription, [string[]] $RedactedValues)
    foreach ($attempt in 1..6) {
        foreach ($fragmentPath in $FragmentPaths) {
            $readback = Invoke-ProbeArm GET $fragmentPath
            if ($readback.properties.description -cne $OwnerDescription -or [string]::IsNullOrWhiteSpace($readback.properties.value)) { throw 'Runtime fragment readback did not confirm ownership and content.' }
        }
        try {
            $null = Invoke-ProbeArm PUT "$ApiPath/policies/policy" @{ properties = @{ format = 'xml'; value = $Policy } } -PolicyDiagnostics -RedactedValues $RedactedValues
            return
        } catch {
            if ($attempt -eq 6 -or $_.Exception.Message -notmatch "Policy fragment with id 'jwt-probe-[a-z0-9-]+' could not be found") { throw }
        }
    }
}

function Remove-ProbeGovernanceProductLinks {
    param([string] $ProductPath, [string] $OwnerDescription, [string] $Owner)
    $product = Invoke-ProbeArm GET $ProductPath -AllowNotFound
    if (-not $product) { return }
    if ($product.properties.description -cne $OwnerDescription -or -not $ProductPath.EndsWith('/' + $product.name, [StringComparison]::Ordinal) -or
        -not $product.name.StartsWith($Owner + '-', [StringComparison]::Ordinal)) { throw 'Governance product ownership changed; no detachment attempted.' }
    $associations = Invoke-ProbeArm GET "$ProductPath/apis"
    if ($associations.nextLink) { throw 'Governance product links exceed the bounded cleanup inventory.' }
    foreach ($api in @($associations.value | Where-Object { $null -ne $_ })) {
        if (-not $api.name.StartsWith($Owner + '-', [StringComparison]::Ordinal) -or $api.properties.description -cne $OwnerDescription) { throw 'Governance product has an association outside its owned diagnostic APIs.' }
        $null = Invoke-ProbeArm DELETE "$ProductPath/apis/$($api.name)" -RequestHeaders @{ 'If-Match' = '*' } -PolicyDiagnostics
    }
    $readback = Invoke-ProbeArm GET "$ProductPath/apis"
    if (@($readback.value | Where-Object { $null -ne $_ }).Count -or $readback.nextLink) { throw 'Governance product detachment has not reached verified absence.' }
}

function Invoke-ProbeSharedGovernanceGate {
    param([string] $ServiceId, [string] $Owner, [string] $ArmResource, [hashtable] $Policies, [string] $MockUrl, [string] $Nonce, [string] $SourcePrefix, [hashtable] $Settings, [string] $GatewayUrl)
    $description = 'No-model shared governance; owner=' + $Owner
    $resources = [Collections.Generic.List[object]]::new()
    $links = [Collections.Generic.List[string]]::new()
    $certificateAttempted = $false
    $keys = @{}
    $urls = @{}
    $modes = @('stateful', 'rpm', 'quota', 'tpm-chat-json', 'tpm-chat-stream', 'tpm-responses-json', 'tpm-responses-stream')
    $telemetryLogger=$null
    if($OperationalGate){
        $apiInventory=Invoke-ProbeArm GET "$ServiceId/apis"
        $primary=@($apiInventory.value|Where-Object {$_.properties.path -ceq 'openai'})
        if($apiInventory.nextLink -or $primary.Count -ne 1){throw 'Operational telemetry requires one existing primary gateway API.'}
        $diagnostics=Invoke-ProbeArm GET "$ServiceId/apis/$($primary[0].name)/diagnostics"
        if(-not @($diagnostics.value|Where-Object {$null -ne $_}).Count){$diagnostics=Invoke-ProbeArm GET "$ServiceId/diagnostics"}
        $loggers=@($diagnostics.value|Where-Object {$_.name -ceq 'applicationinsights' -and $_.properties.loggerId})
        if($diagnostics.nextLink -or $loggers.Count -ne 1){throw 'Operational telemetry requires the existing primary Application Insights logger.'}
        $telemetryLogger=[string]$loggers[0].properties.loggerId
        if(-not $telemetryLogger.StartsWith($ServiceId+'/loggers/',[StringComparison]::OrdinalIgnoreCase)){throw 'Diagnostic logger is outside the selected gateway.'}
    }
    function Install-ProbeGovernanceResource {
        param([string] $Path, [hashtable] $Properties, [string] $IdentityProperty = 'description')
        if ($null -ne (Invoke-ProbeArm GET $Path -AllowNotFound)) { throw 'Governance resource already exists; refusing replacement.' }
        $Properties[$IdentityProperty] = $description
        $resources.Add(@{ path = $Path; identityProperty = $IdentityProperty })
        $null = Invoke-ProbeArm PUT $Path @{ properties = $Properties } -PolicyDiagnostics -RedactedValues @($Nonce, $Properties.primaryKey, $Properties.secondaryKey)
    }
    function Bind-ProbeGovernancePolicy {
        param([string] $Policy)
        foreach ($setting in $Settings.Keys) { $Policy = $Policy.Replace('{{' + $setting + '}}', [Security.SecurityElement]::Escape([string]$Settings[$setting])) }
        if ($Policy -match '\{\{') { throw 'Governance policy contains an unresolved named value.' }
        return $Policy
    }
    try {
        $backendPath = "$ServiceId/backends/$Owner-mock"
        Install-ProbeGovernanceResource $backendPath @{ protocol = 'http'; url = ([uri]$MockUrl).GetLeftPart([UriPartial]::Authority); title = $Owner + '-mock' }
        $nativeProduct = "$ServiceId/products/$Owner-native"
        $jwtProduct = "$ServiceId/products/$Owner-product"
        $otherProduct = "$ServiceId/products/$Owner-unlinked"
        foreach ($product in @($nativeProduct, $jwtProduct, $otherProduct)) {
            $productProperties = @{ displayName = ($product.Split('/')[-1]); subscriptionRequired = ($product -ne $jwtProduct); state = 'notPublished' }
            if ($product -ne $jwtProduct) { $productProperties.approvalRequired = $false }
            Install-ProbeGovernanceResource $product $productProperties
        }
        $nativePolicy = @'
<policies><inbound><set-variable name="probeNativeProduct" value="@(true)" />
<choose><when condition="@(context.Api.Id.EndsWith(&quot;-rpm&quot;))"><rate-limit-by-key calls="3" renewal-period="300" counter-key="@(&quot;__OWNER__:native-rpm:&quot; + context.Subscription.Id)" /></when>
<when condition="@(context.Api.Id.EndsWith(&quot;-quota&quot;))"><quota-by-key calls="3" renewal-period="3600" counter-key="@(&quot;__OWNER__:native-quota:&quot; + context.Subscription.Id)" /></when></choose>
</inbound><backend /><outbound /><on-error /></policies>
'@.Replace('__OWNER__', $Owner)
        $null = Invoke-ProbeArm PUT "$nativeProduct/policies/policy" @{ properties = @{ format = 'xml'; value = $nativePolicy } } -PolicyDiagnostics
        $null = Invoke-ProbeArm PUT "$jwtProduct/policies/policy" @{ properties = @{ format = 'xml'; value = $Policies.jwtProduct } } -PolicyDiagnostics
        $readiness = '<choose><when condition="@(context.Request.Headers.GetValueOrDefault(&quot;X-Probe-Ready&quot;, &quot;&quot;) == &quot;' + $Owner + '&quot;)"><return-response><set-status code="204" reason="Governance fixture ready" /><set-header name="X-Probe-Governance" exists-action="override"><value>' + $Owner + '</value></set-header></return-response></when></choose>'
        foreach ($mode in $modes) {
            $apiName = "$Owner-$mode"
            $apiPath = "$ServiceId/apis/$apiName"
            Install-ProbeGovernanceResource $apiPath @{ displayName = $apiName; path = $apiName; protocols = @('https'); subscriptionRequired = $true; subscriptionKeyParameterNames = @{ header = 'api-key'; query = 'api-key' } }
            $inference = $Policies.inference
            if ($mode -ne 'stateful') {
                if (-not $Policies.limits.ContainsKey($mode)) { throw 'Missing isolated caller accounting fixture.' }
                [xml]$limits = $Policies.limits[$mode]
                $inference = $inference.Replace('<include-fragment fragment-id="' + $Owner + '-byok-apply-caller-limits" />', $limits.fragment.InnerXml)
            }
            $inference = $inference.Replace('<inbound>', ('<inbound>' + $readiness))
            if ($mode.StartsWith('tpm-')) { $inference = $inference.Replace('</inbound>', '<set-header name="X-Probe-Usage" exists-action="override"><value>270</value></set-header></inbound>') }
            $null = Invoke-ProbeArm PUT "$apiPath/policies/policy" @{ properties = @{ format = 'xml'; value = (Bind-ProbeGovernancePolicy $inference) } } -PolicyDiagnostics -RedactedValues @($Nonce)
            if($telemetryLogger){
                $emptyMessageLog=@{headers=@();body=@{bytes=0}}
                $null=Invoke-ProbeArm PUT "$apiPath/diagnostics/applicationinsights" @{properties=@{
                    loggerId=$telemetryLogger;alwaysLog='allErrors';sampling=@{samplingType='fixed';percentage=100};logClientIp=$false;metrics=$true
                    frontend=@{request=$emptyMessageLog;response=$emptyMessageLog};backend=@{request=$emptyMessageLog;response=$emptyMessageLog}
                }}
            }
            $operations = @(@{ name = 'chat'; method = 'POST'; path = '/v1/chat/completions' }, @{ name = 'alias'; method = 'POST'; path = '/alias/chat/completions' }, @{ name = 'responses'; method = 'POST'; path = '/v1/responses' })
            if ($mode -eq 'stateful') {
                $operations += @(@{ name = 'check'; method = 'GET'; path = '/check' }, @{ name = 'responses-get'; method = 'GET'; path = '/v1/responses/{response_id}' },
                    @{ name = 'responses-delete'; method = 'DELETE'; path = '/v1/responses/{response_id}' }, @{ name = 'responses-cancel'; method = 'POST'; path = '/v1/responses/{response_id}/cancel' }, @{ name = 'responses-input-items'; method = 'GET'; path = '/v1/responses/{response_id}/input_items' })
            }
            foreach ($operation in $operations) {
                $operationPath = "$apiPath/operations/$($operation.name)"
                $properties = @{ displayName = $operation.name; method = $operation.method; urlTemplate = $operation.path; responses = @() }
                if ($operation.path.Contains('{response_id}')) { $properties.templateParameters = @(@{ name = 'response_id'; type = 'string'; required = $true }) }
                $null = Invoke-ProbeArm PUT $operationPath @{ properties = $properties }
                if ($operation.name.StartsWith('responses-')) { $null = Invoke-ProbeArm PUT "$operationPath/policies/policy" @{ properties = @{ format = 'xml'; value = (Bind-ProbeGovernancePolicy $Policies.utility) } } -PolicyDiagnostics -RedactedValues @($Nonce) }
                if ($operation.name -eq 'check') {
                    $checkPolicy = $inference.Replace('<base />', '').Replace('<include-fragment fragment-id="' + $Owner + '-byok-apply-caller-limits" />', '<set-variable name="byokCallerAccountingApplied" value="@(true)" />')
                    $null = Invoke-ProbeArm PUT "$operationPath/policies/policy" @{ properties = @{ format = 'xml'; value = (Bind-ProbeGovernancePolicy $checkPolicy) } } -PolicyDiagnostics -RedactedValues @($Nonce)
                }
            }
            foreach ($product in @($nativeProduct, $jwtProduct)) {
                $link = "$product/apis/$apiName"
                $links.Add($link)
                $null = Invoke-ProbeArm PUT $link @{}
            }
            $urls[$mode] = $GatewayUrl.TrimEnd('/') + '/' + $apiName
        }
        foreach ($kind in @('first', 'second', 'api', 'all', 'wrongScope', 'wrongProduct', 'suspended', 'rotated')) {
            $keyPath = "$ServiceId/subscriptions/$Owner-$kind"
            $primary = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
            $secondary = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
            $scope = switch ($kind) { 'api' { "$ServiceId/apis/$Owner-stateful" }; 'all' { "$ServiceId/apis" }; 'wrongScope' { "$ServiceId/apis/$Owner" }; 'wrongProduct' { $otherProduct }; default { $nativeProduct } }
            Install-ProbeGovernanceResource $keyPath @{ scope = $scope; state = $(if ($kind -eq 'suspended') { 'suspended' } else { 'active' }); primaryKey = $primary; secondaryKey = $secondary } 'displayName'
            $keys[$kind] = $primary
            if ($kind -eq 'first') { $keys.secondary = $secondary }
            if ($kind -eq 'rotated') {
                $keys.rotatedOld = $primary
                $keys.rotated = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
                $null = Invoke-ProbeArm PATCH $keyPath @{ properties = @{ primaryKey = $keys.rotated } }
            }
        }
        $certificateAttempted = $true
        $publicRows = @(Invoke-ProbeVm @('Phase=Prepare', ('ProbeId=' + $Owner), ('ArmResource=' + $ArmResource)))
        $public = @($publicRows | Where-Object test -eq 'transport-certificate')
        if ($public.Count -ne 1) { throw 'Governance token transport certificate was not prepared.' }
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($public[0].publicCertificate))
        $appIdUri = Invoke-ProbeArm GET "$ServiceId/namedValues/api-app-id-uri"
        if ([string]::IsNullOrWhiteSpace([string]$appIdUri.properties.value)) { throw 'Governance requires the existing gateway API identifier URI.' }
        $delegatedScope = ([string]$appIdUri.properties.value).TrimEnd('/') + '/' + $Settings['required-scope']
        $secondCredential = Resolve-ProbeSecondUserToken -Token $SecondUserToken -Provider $SecondUserTokenProvider
        $tokenRaw = & az account get-access-token --tenant $Settings['caller-entra-tenant-id'] --scope $delegatedScope -o json --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Pinned first-user token acquisition failed.' }
        $firstToken = ($tokenRaw | ConvertFrom-Json).accessToken
        $secondToken = ConvertFrom-SecureString $secondCredential -AsPlainText
        $secondCredential = $null
        $identities = @(foreach ($token in @($firstToken, $secondToken)) {
            $encoded = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
            $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded.PadRight($encoded.Length + ((4 - $encoded.Length % 4) % 4), '='))) | ConvertFrom-Json
            if (-not $claims.oid -or -not $claims.tid -or -not $claims.scp -or [DateTimeOffset]::FromUnixTimeSeconds([long]$claims.exp) -lt [DateTimeOffset]::UtcNow.AddMinutes(15)) { throw 'Governance fixtures require delegated tokens with at least fifteen minutes remaining; parsing does not establish trust.' }
            $claims.tid + ':' + $claims.oid
        })
        if ($identities[0] -ceq $identities[1] -or $firstToken -ceq $secondToken) { throw 'Governance requires two distinct real users.' }
        $payload = @{ keys = $keys; urls = $urls; firstToken = $firstToken; secondToken = $secondToken; nonce = $Nonce; mockAddress = ([uri]$MockUrl).Host; sourcePrefix = $SourcePrefix }
        $encrypted = Protect-CmsMessage -To $certificate -Content ($payload | ConvertTo-Json -Depth 10 -Compress)
        $payload = $null; $firstToken = $null; $secondToken = $null; $tokenRaw = $null
        $rows = @(Invoke-ProbeVm @('Phase=SharedGovernanceTest', ('ProbeId=' + $Owner), ('GatewayUri=' + $GatewayUrl), ('ArmResource=' + $ArmResource), ('ProtectedToken=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($encrypted)))))
        $rows
        if (@($rows | Where-Object { $_.test -eq 'shared-governance-cleanup' -and $_.passed }).Count -eq 1) { $certificateAttempted = $false }
        if (@($rows | Where-Object { $_.test -eq 'shared-governance-summary' -and $_.passed }).Count -ne 1 -or $certificateAttempted) { throw 'Integrated shared governance matrix or cleanup did not pass.' }
        if($OperationalGate){
            Invoke-ProbeSharedRollback -ServiceId $ServiceId -Owner $Owner -ArmResource $ArmResource -JwtProduct $jwtProduct -OwnerDescription $description -GatewayUrl $GatewayUrl -Keys $keys -Settings $Settings -Package $Policies.package
            Invoke-ProbeSharedTelemetry -ServiceId $ServiceId -Owner $Owner -ArmResource $ArmResource -LoggerId $telemetryLogger
        }
    } catch {
        [pscustomobject]@{ test = 'shared-governance-stage-failed'; passed = $false; failure = $_.Exception.Message }
        throw
    } finally {
        $payload = $null; $firstToken = $null; $secondToken = $null; $secondCredential = $null; $tokenRaw = $null; $keys = $null
        if ($certificateAttempted) { Invoke-ProbeVm @('Phase=Cleanup', ('ProbeId=' + $Owner), ('ArmResource=' + $ArmResource)) }
        foreach ($parentPath in @($links | ForEach-Object { $_.Substring(0, $_.LastIndexOf('/apis/', [StringComparison]::Ordinal)) } | Select-Object -Unique)) {
            Remove-ProbeGovernanceProductLinks -ProductPath $parentPath -OwnerDescription $description -Owner $Owner
        }
        for ($resourceIndex = $resources.Count - 1; $resourceIndex -ge 0; $resourceIndex--) {
            $entry = $resources[$resourceIndex]
            $owned = Invoke-ProbeArm GET $entry.path -AllowNotFound
            if ($owned) {
                if ($owned.properties.($entry.identityProperty) -cne $description) { throw 'Governance resource ownership changed; refusing deletion.' }
                $null = Invoke-ProbeArm DELETE $entry.path -RequestHeaders @{ 'If-Match' = '*' } -CompleteOwnedOperation -PolicyDiagnostics
            }
            if ($null -ne (Invoke-ProbeArm GET $entry.path -AllowNotFound)) { throw 'Governance resource removal is not verified.' }
        }
        [pscustomobject]@{ test = 'shared-governance-resources-removed'; passed = $true }
    }
}

function Invoke-ProbeSharedRollback {
    param([string]$ServiceId,[string]$Owner,[string]$ArmResource,[string]$JwtProduct,[string]$OwnerDescription,[string]$GatewayUrl,[hashtable]$Keys,[hashtable]$Settings,$Package)
    $apiPath="$ServiceId/apis/$Owner-stateful"
    $operationPath="$apiPath/operations/check/policies/policy"
    $ownerFragment="$ServiceId/policyFragments/$Owner-byok-response-owner-context"
    $before=Invoke-ProbeArm GET $ownerFragment
    $ownerContent=[string]$before.properties.value
    $before=$null
    $certificateAttempted=$true
    $firstToken=$null;$secondToken=$null;$payload=$null
    try{
        $publicRows=@(Invoke-ProbeVm @('Phase=Prepare',('ProbeId='+$Owner),('ArmResource='+$ArmResource)))
        $public=@($publicRows|Where-Object test -eq 'transport-certificate')
        if($public.Count -ne 1){throw 'Rollback transport certificate was not prepared.'}
        $certificate=[Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($public[0].publicCertificate))
        $appIdUri=Invoke-ProbeArm GET "$ServiceId/namedValues/api-app-id-uri"
        $scope=([string]$appIdUri.properties.value).TrimEnd('/')+'/'+$Settings['required-scope']
        $secondCredential=Resolve-ProbeSecondUserToken -Token $SecondUserToken -Provider $SecondUserTokenProvider
        $firstToken=& az account get-access-token --tenant $Settings['caller-entra-tenant-id'] --scope $scope --query accessToken -o tsv --only-show-errors 2>$null
        if($LASTEXITCODE -ne 0 -or -not $firstToken){throw 'Rollback delegated token acquisition failed.'}
        $secondToken=ConvertFrom-SecureString $secondCredential -AsPlainText
        $secondCredential=$null
        $payload=@{keys=$Keys;firstToken=$firstToken;secondToken=$secondToken}
        $encrypted=Protect-CmsMessage -To $certificate -Content ($payload|ConvertTo-Json -Depth 8 -Compress)
        $payload=$null;$firstToken=$null;$secondToken=$null
        $shared=New-ProbeRollbackPolicy -Owner $Owner -AuthenticationEntry $Package.authenticationEntry -NativeGuard $Package.nativeCallerGuard
        foreach($name in $Settings.Keys){$shared=$shared.Replace('{{'+$name+'}}',[Security.SecurityElement]::Escape([string]$Settings[$name]))}
        if($shared.Contains('{{')){throw 'Rollback policy has unresolved configuration.'}
        $null=Invoke-ProbeArm PUT $operationPath @{properties=@{format='xml';value=$shared}} -PolicyDiagnostics
        foreach($stage in @('before','detached','legacy')){
            if($stage -eq 'detached'){
                Remove-ProbeGovernanceProductLinks -ProductPath $JwtProduct -OwnerDescription $OwnerDescription -Owner $Owner
                [pscustomobject]@{test='shared-rollback-jwt-links-detached';passed=$true}
            }
            if($stage -eq 'legacy'){
                $legacy=New-ProbeRollbackPolicy -Owner $Owner -NativeGuard $Package.nativeCallerGuard -Legacy
                $null=Invoke-ProbeArm PUT $operationPath @{properties=@{format='xml';value=$legacy}} -PolicyDiagnostics
            }
            $rows=@(Invoke-ProbeVm @('Phase=SharedRollbackTest',('RollbackStage='+$stage),('ProbeId='+$Owner),('GatewayUri='+$GatewayUrl.TrimEnd('/')+'/'+$Owner+'-stateful/check'),('ArmResource='+$ArmResource),('ProtectedToken='+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($encrypted)))))
            $rows
            if(@($rows|Where-Object {$_.test -eq 'shared-admission-rollback' -and $_.passed}).Count -ne 10 -or @($rows|Where-Object {$_.passed -eq $false}).Count){throw 'Rollback admission did not pass every required caller case.'}
        }
        $after=Invoke-ProbeArm GET $ownerFragment
        if([string]$after.properties.value -cne $ownerContent){throw 'Rollback modified the retained ownership keys/context.'}
        foreach($operation in @('responses-get','responses-delete','responses-cancel','responses-input-items')){
            $utility=Invoke-ProbeArm GET "$apiPath/operations/$operation/policies/policy"
            if(-not $utility.properties.value.Contains($Owner+'-byok-locate-response-owner')){throw 'Rollback removed retained utility ownership protection.'}
        }
        [pscustomobject]@{test='shared-rollback-retained-ownership';ownerKeysUnchanged=$true;protectedUtilityOperations=4;passed=$true}
    }finally{
        $ownerContent=$null;$firstToken=$null;$secondToken=$null;$payload=$null
        if($certificateAttempted){Invoke-ProbeVm @('Phase=Cleanup',('ProbeId='+$Owner),('ArmResource='+$ArmResource))}
    }
}

function Invoke-ProbeSharedTelemetry {
    param([string]$ServiceId,[ValidatePattern('^jwt-probe-[a-z0-9-]+$')][string]$Owner,[string]$ArmResource,[string]$LoggerId)
    $logger=Invoke-ProbeArm GET $LoggerId
    $componentId=[string]$logger.properties.resourceId
    $logger=$null
    if($componentId -notmatch '(?i)/providers/Microsoft.Insights/components/[^/]+$'){throw 'The existing logger is not bound to a workspace-based Application Insights resource.'}
    $workspaceResource=& az resource show --ids $componentId --api-version 2020-02-02 --query properties.WorkspaceResourceId -o tsv --only-show-errors 2>$null
    if($LASTEXITCODE -ne 0 -or $workspaceResource -notmatch '(?i)/providers/Microsoft.OperationalInsights/workspaces/[^/]+$'){throw 'The logger workspace binding is unavailable.'}
    $workspaceId=& az resource show --ids $workspaceResource --api-version 2022-10-01 --query properties.customerId -o tsv --only-show-errors 2>$null
    $workspaceGuid=[guid]::Empty
    if($LASTEXITCODE -ne 0 -or -not [guid]::TryParse([string]$workspaceId,[ref]$workspaceGuid)){throw 'The telemetry workspace identity is unavailable.'}
    $certificateAttempted=$true
    $queryToken=$null
    try{
        $publicRows=@(Invoke-ProbeVm @('Phase=Prepare',('ProbeId='+$Owner),('ArmResource='+$ArmResource)))
        $public=@($publicRows|Where-Object test -eq 'transport-certificate')
        if($public.Count -ne 1){throw 'Telemetry transport certificate was not prepared.'}
        $certificate=[Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($public[0].publicCertificate))
        $logEndpoint=if($Cloud -eq 'AzureUSGovernment'){'https://api.loganalytics.us'}else{'https://api.loganalytics.io'}
        $queryToken=& az account get-access-token --resource $logEndpoint --query accessToken -o tsv --only-show-errors 2>$null
        if($LASTEXITCODE -ne 0 -or -not $queryToken){throw 'Pinned operator telemetry token could not be acquired; no role change attempted.'}
        $encrypted=Protect-CmsMessage -To $certificate -Content ([string]$queryToken)
        $queryToken=$null
        $rows=@(Invoke-ProbeVm @('Phase=SharedTelemetryTest',('ProbeId='+$Owner),('TelemetryCloud='+$Cloud),('TelemetryWorkspaceId='+$workspaceGuid.ToString()),('ArmResource='+$ArmResource),('ProtectedToken='+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($encrypted)))))
        $rows
        if(@($rows|Where-Object {$_.test -eq 'temporary-transport-certificate-removed' -and $_.passed}).Count -eq 1){$certificateAttempted=$false}
        if(@($rows|Where-Object {$_.test -eq 'shared-governance-telemetry' -and $_.querySucceeded -and $_.complete}).Count -ne 1){throw 'Shared throttle telemetry is not yet verified; no repeated inference was sent.'}
    }finally{
        $queryToken=$null
        if($certificateAttempted){Invoke-ProbeVm @('Phase=Cleanup',('ProbeId='+$Owner),('ArmResource='+$ArmResource))}
    }
}

function Invoke-ProbeRealResponsesGate {
    param([string] $ServiceId, [string] $Owner, [string] $ArmResource, [string] $Location, [string] $GatewayUrl,
        [hashtable] $Settings, [hashtable] $Policies, [string] $Model, [string] $Nonce, [string] $OwnerFragment)
    $description = 'Bounded real Responses acceptance; owner=' + $Owner
    $apiPath = "$ServiceId/apis/$Owner-real"
    $nativeProduct = "$ServiceId/products/$Owner-real-native"
    $jwtProduct = "$ServiceId/products/$Owner-product"
    $keyPath = "$ServiceId/subscriptions/$Owner-real-native"
    $resources = [Collections.Generic.List[object]]::new()
    $certificateAttempted = $false
    $backendAttempted = $false
    $responseCleanupVerified = $false
    $sealedState = ''
    $payload = $null
    $currentKey = $Settings['caller-response-owner-key']
    $rotatedKey = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    function Set-ProbeRealOwnerKey {
        param([string] $Current, [string] $Previous)
        $fragmentPath = "$ServiceId/policyFragments/$Owner-byok-response-owner-context"
        $existing = Invoke-ProbeArm GET $fragmentPath
        if ($existing.properties.description -cne ('No-model shared authentication runtime; owner=' + $Owner)) { throw 'Ownership fragment no longer belongs to the diagnostic.' }
        $value = $OwnerFragment.Replace('{{caller-response-owner-key}}', $Current).Replace('{{caller-response-owner-key-previous}}', $Previous)
        $null = Invoke-ProbeArm PUT $fragmentPath @{properties=@{description=$existing.properties.description;format='xml';value=$value}} -CompleteFragmentOperation -ResourceLocation $Location -PolicyDiagnostics -RedactedValues @($Current,$Previous)
    }
    function Invoke-ProbeRealPhase {
        param([string] $Stage)
        $payload.stage = $Stage
        $payload.state = $sealedState
        $encrypted = Protect-CmsMessage -To $certificate -Content ($payload | ConvertTo-Json -Depth 15 -Compress)
        $rows = @(Invoke-ProbeVm @('Phase=RealResponsesTest',('ProbeId='+$Owner),('GatewayUri='+$GatewayUrl.TrimEnd('/')+'/'+$Owner+'-real'),('ArmResource='+$ArmResource),('ProtectedToken='+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($encrypted)))))
        return ,$rows
    }
    try {
        foreach ($entry in @(@{path=$nativeProduct;properties=@{displayName=$Owner+'-real-native';subscriptionRequired=$true;approvalRequired=$false;state='notPublished'}},
            @{path=$jwtProduct;properties=@{displayName=$Owner+'-product';subscriptionRequired=$false;state='notPublished'}},
            @{path=$apiPath;properties=@{displayName=$Owner+'-real';path=$Owner+'-real';protocols=@('https');subscriptionRequired=$true;subscriptionKeyParameterNames=@{header='api-key';query='api-key'}}})) {
            if ($null -ne (Invoke-ProbeArm GET $entry.path -AllowNotFound)) { throw 'Real acceptance resource already exists; refusing replacement.' }
            $entry.properties.description = $description
            $resources.Add(@{path=$entry.path;property='description'})
            $null = Invoke-ProbeArm PUT $entry.path @{properties=$entry.properties} -PolicyDiagnostics
        }
        $productSource = Get-Content -Raw (Join-Path $PSScriptRoot '../infra/modules/apim-jwt-product.bicep')
        $productMatch = [regex]::Match($productSource, "var jwtProductGuardTemplate string = '(?<policy><policies>.*?</policies>)'")
        if (-not $productMatch.Success) { throw 'JWT product guard source is unavailable.' }
        $null = Invoke-ProbeArm PUT "$jwtProduct/policies/policy" @{properties=@{format='xml';value=$productMatch.Groups['policy'].Value.Replace('__ACTIVE__','true')}} -PolicyDiagnostics
        $null = Invoke-ProbeArm PUT "$apiPath/policies/policy" @{properties=@{format='rawxml';value=$Policies.inference}} -PolicyDiagnostics -RedactedValues @($Nonce)
        foreach ($operation in @(@{name='responses';method='POST';path='/v1/responses'},@{name='list-models';method='GET';path='/v1/models'},
            @{name='responses-get';method='GET';path='/v1/responses/{response_id}'},@{name='responses-delete';method='DELETE';path='/v1/responses/{response_id}'},
            @{name='responses-cancel';method='POST';path='/v1/responses/{response_id}/cancel'},@{name='responses-input-items';method='GET';path='/v1/responses/{response_id}/input_items'})) {
            $operationPath = "$apiPath/operations/$($operation.name)"
            $properties = @{displayName=$operation.name;method=$operation.method;urlTemplate=$operation.path;responses=@()}
            if ($operation.path.Contains('{response_id}')) { $properties.templateParameters=@(@{name='response_id';type='string';required=$true}) }
            $null = Invoke-ProbeArm PUT $operationPath @{properties=$properties}
            if ($operation.name -ne 'responses') {
                $value = if ($operation.name -eq 'list-models') { $Policies.models } else { $Policies.utility }
                $null = Invoke-ProbeArm PUT "$operationPath/policies/policy" @{properties=@{format='xml';value=$value}} -PolicyDiagnostics -RedactedValues @($Nonce)
            }
        }
        foreach ($product in @($nativeProduct,$jwtProduct)) { $null = Invoke-ProbeArm PUT "$product/apis/$Owner-real" @{} }
        if ($null -ne (Invoke-ProbeArm GET $keyPath -AllowNotFound)) { throw 'Real acceptance subscription already exists.' }
        $nativeKey = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
        $resources.Add(@{path=$keyPath;property='displayName'})
        $null = Invoke-ProbeArm PUT $keyPath @{properties=@{displayName=$description;scope=$nativeProduct;state='active';primaryKey=$nativeKey;secondaryKey=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))}} -PolicyDiagnostics -RedactedValues @($nativeKey)
        $certificateAttempted = $true
        $publicRows = @(Invoke-ProbeVm @('Phase=Prepare',('ProbeId='+$Owner),('ArmResource='+$ArmResource)))
        $public = @($publicRows | Where-Object test -eq 'transport-certificate')
        if ($public.Count -ne 1) { throw 'Real acceptance transport certificate was not prepared.' }
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($public[0].publicCertificate))
        $app = Invoke-ProbeArm GET "$ServiceId/namedValues/api-app-id-uri"
        $scope = ([string]$app.properties.value).TrimEnd('/')+'/'+$Settings['required-scope']
        $secondCredential = Resolve-ProbeSecondUserToken -Token $SecondUserToken -Provider $SecondUserTokenProvider
        $tokenRaw = & az account get-access-token --tenant $Settings['caller-entra-tenant-id'] --scope $scope -o json --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Real acceptance first-user token acquisition failed.' }
        $firstToken = ($tokenRaw | ConvertFrom-Json).accessToken
        $secondToken = ConvertFrom-SecureString $secondCredential -AsPlainText
        $identities = @(foreach ($token in @($firstToken,$secondToken)) {
            $encoded=$token.Split('.')[1].Replace('-','+').Replace('_','/')
            $claims=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded.PadRight($encoded.Length+((4-$encoded.Length%4)%4),'='))) | ConvertFrom-Json
            if (-not $claims.scp -or -not $claims.oid -or $claims.tid -cne $Settings['caller-entra-tenant-id'] -or [DateTimeOffset]::FromUnixTimeSeconds([long]$claims.exp) -lt [DateTimeOffset]::UtcNow.AddMinutes(15)) { throw 'Real acceptance needs two fresh delegated credentials in the configured tenant.' }
            $claims.tid+':'+$claims.oid
        })
        if ($identities[0] -ceq $identities[1]) { throw 'Real acceptance requires two distinct users.' }
        $payload = @{firstToken=$firstToken;secondToken=$secondToken;nativeKey=$nativeKey;nonce=$Nonce;model=$Model;stage='initial';state=''}
        foreach ($stage in @('initial','rotation','retired')) {
            if ($stage -eq 'rotation') { Set-ProbeRealOwnerKey -Current $rotatedKey -Previous $currentKey }
            if ($stage -eq 'retired') { Set-ProbeRealOwnerKey -Current $rotatedKey -Previous '__none__' }
            $backendAttempted = $true
            [pscustomobject]@{test='real-responses-phase-start';stage=$stage;maximumCreationAttempts=4}
            $rows = Invoke-ProbeRealPhase $stage
            $states = @($rows | Where-Object test -eq 'real-responses-state')
            if ($states.Count -ne 1 -or $states[0].ciphertext -cnotmatch '\A[A-Za-z0-9+/=]+\z') { throw 'Real response recovery state is missing; retain owned resources for inspection.' }
            $sealedState = $states[0].ciphertext
            $rows | Where-Object test -ne 'real-responses-state'
            if (@($rows | Where-Object { $_.test -eq 'real-responses-stage' -and $_.stage -ceq $stage -and $_.passed }).Count -ne 1) { throw 'Real Responses stage failed; no further model creation will be attempted.' }
        }
    } finally {
        if ($backendAttempted) {
            $script:preserveRealResponses = $true
            Set-ProbeRealOwnerKey -Current $rotatedKey -Previous $currentKey
            $cleanup = Invoke-ProbeRealPhase 'cleanup'
            $cleanup | Where-Object test -ne 'real-responses-state'
            $responseCleanupVerified = @($cleanup | Where-Object { $_.test -eq 'real-responses-stage' -and $_.stage -ceq 'cleanup' -and $_.passed -and $_.remaining -eq 0 }).Count -eq 1
            if (-not $responseCleanupVerified) { $script:preserveRealResponses = $true; throw 'Stored-response cleanup is incomplete; owned diagnostic API/fragments retained for recovery.' }
            $script:preserveRealResponses = $false
        }
        if ($certificateAttempted) { Invoke-ProbeVm @('Phase=Cleanup',('ProbeId='+$Owner),('ArmResource='+$ArmResource)) }
        $payload=$null;$firstToken=$null;$secondToken=$null;$secondCredential=$null;$tokenRaw=$null;$nativeKey=$null
        foreach ($product in @($jwtProduct,$nativeProduct)) { Remove-ProbeGovernanceProductLinks -ProductPath $product -OwnerDescription $description -Owner $Owner }
        for ($index=$resources.Count-1;$index -ge 0;$index--) {
            $entry=$resources[$index]
            $owned=Invoke-ProbeArm GET $entry.path -AllowNotFound
            if ($owned) {
                if ($owned.properties.($entry.property) -cne $description) { throw 'Real acceptance cleanup ownership changed.' }
                $null=Invoke-ProbeArm DELETE $entry.path -CompleteOwnedOperation -PolicyDiagnostics
            }
            if ($null -ne (Invoke-ProbeArm GET $entry.path -AllowNotFound)) { throw 'Real acceptance resource removal is not verified.' }
        }
        [pscustomobject]@{test='real-responses-resources-removed';passed=$true;storedResponseCleanup=(!$backendAttempted -or $responseCleanupVerified)}
    }
}

function Invoke-ProbeSharedRuntimeGate {
    param([string] $ServiceId, [string] $ProbeName, [string] $ArmResource)
    $consumers = @()
    if ($SharedConsumerPolicyPath) {
        $rendered = Get-Content -LiteralPath $SharedConsumerPolicyPath -Raw | ConvertFrom-Json -Depth 30
        $packages=@()
        if($CallerPackagePath){
            $package=(Get-Content -LiteralPath $CallerPackagePath -Raw|ConvertFrom-Json -Depth 100).parameters.callerPackage.value
            $packages=@(New-ProbePackageConsumerPolicies -Package $package -Standalone $rendered.parameters.standalone.value -Cloud $Cloud)
        }
        $consumers = @(New-ProbeSharedConsumerPolicies -Policies $rendered.parameters.policies.value -Owner $ProbeName -PackagePolicies $packages)
    }
    $service = Invoke-ProbeArm GET $ServiceId
    if ($service.properties.provisioningState -ne 'Succeeded' -or $service.properties.virtualNetworkType -ne 'Internal') { throw 'Shared runtime validation requires a stable internal gateway.' }
    $gatewayUri = $service.properties.gatewayUrl.TrimEnd('/') + '/' + $ProbeName
    $transport = @(Invoke-ProbeVm @('Phase=HeaderParityTransport', ('ProbeId=' + $ProbeName), ('GatewayUri=' + $gatewayUri + '/preflight'), ('ArmResource=' + $ArmResource)))
    if ($transport.Count -ne 1 -or $transport[0].passed -ne $true) { throw 'Strict transport failed; no shared runtime fixture was created.' }
    $metadata = Invoke-ProbeArm GET "$ServiceId/namedValues/entra-openid-config-url"
    $audience = Invoke-ProbeArm GET "$ServiceId/namedValues/api-audience"
    $scopeValue = Invoke-ProbeArm GET "$ServiceId/namedValues/required-scope"
    $issuer = ([string]$metadata.properties.value).Replace('/.well-known/openid-configuration', '')
    $hostName = if ($Cloud -eq 'AzureUSGovernment') { 'login.microsoftonline.us' } else { 'login.microsoftonline.com' }
    if ($issuer -cnotmatch ('\Ahttps://' + [regex]::Escape($hostName) + '/([0-9a-f-]{36})/v2\.0\z') -or
        $audience.properties.value -cnotmatch '\A[0-9a-f-]{36}\z') { throw 'Existing gateway Entra settings do not match the pinned cloud fixture.' }
    $tenantId = ([uri]$issuer).AbsolutePath.Split('/')[1]
    $fixtureValues = @{
        'caller-configuration-valid' = 'true'; 'caller-key-enabled' = 'false'; 'caller-native-subscription-required' = 'false'
        'caller-entra-enabled' = 'true'; 'caller-entra-login-host' = $hostName; 'caller-entra-tenant-id' = $tenantId; 'caller-entra-issuer' = $issuer
        'caller-entra-client-ids' = '__any__'; 'caller-okta-enabled' = 'false'; 'caller-jwt-product-id' = $ProbeName + '-product'
        'caller-okta-issuer' = 'https://fixture.example.test/oauth2/disabled'; 'caller-okta-openid-config-url' = 'https://fixture.example.test/oauth2/disabled/.well-known/openid-configuration'
        'caller-okta-audience' = '__none__'; 'caller-okta-required-scope' = '__none__'; 'caller-okta-client-ids' = '__none__'
        'entra-openid-config-url' = [string]$metadata.properties.value; 'api-audience' = [string]$audience.properties.value; 'required-scope' = [string]$scopeValue.properties.value
        'caller-response-owner-key' = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)); 'caller-response-owner-key-previous' = '__none__'
        'caller-response-backend-origins' = '["https://fixture.example.test"]'; 'caller-response-stores' = '[{"origin":"https://fixture.example.test","backendId":"fixture","kind":"foundry"}]'
    }
    $fragments = New-ProbeSharedRuntimeFragments
    $governancePolicies = $null
    $realPolicies = $null
    if ($RealResponsesGate) {
        $backendBinding=Invoke-ProbeArm GET "$ServiceId/namedValues/foundry-backend-id"
        if ($backendBinding.properties.value -cne 'foundry') { throw 'Bounded real acceptance currently requires the existing single Foundry backend.' }
        $backend=Invoke-ProbeArm GET "$ServiceId/backends/foundry"
        $backendUri=[uri]$backend.properties.url
        if ($backendUri.Scheme -ne 'https' -or $backendUri.Port -ne 443 -or $backendUri.UserInfo -or $backendUri.Query -or $backendUri.Fragment -or
            $backend.properties.tls.validateCertificateChain -eq $false -or $backend.properties.tls.validateCertificateName -eq $false) { throw 'Real acceptance requires strict HTTPS backend validation.' }
        $types=Invoke-ProbeArm GET "$ServiceId/namedValues/foundry-model-types"
        $modelTypes=$types.properties.value | ConvertFrom-Json
        $models=@($modelTypes.PSObject.Properties | Where-Object { $_.Name -cmatch '\Agpt-5[.A-Za-z0-9_-]*\z' -and @($_.Value) -contains 'responses' } | Sort-Object @{Expression={if($_.Name -match 'luna|mini'){0}else{1}}},Name)
        if (-not $models.Count) { throw 'No configured GPT-5 Responses model is available for the bounded reasoning/tool test.' }
        $realModel=$models[0].Name
        foreach ($name in @('aoai-pinned-models','commercial-models')) {
            $setting=Invoke-ProbeArm GET "$ServiceId/namedValues/$name"
            if (@(([string]$setting.properties.value).Split(',') | Where-Object { $_.Trim() -ne '' -and $realModel.StartsWith($_.Trim(),[StringComparison]::OrdinalIgnoreCase) }).Count) { throw 'The selected model is routed outside the approved primary Foundry store.' }
        }
        $origin=$backendUri.GetLeftPart([UriPartial]::Authority)
        $fixtureValues['caller-key-enabled']='true';$fixtureValues['caller-native-subscription-required']='true'
        $fixtureValues['caller-response-backend-origins']=[string](ConvertTo-Json -InputObject @($origin) -Compress)
        $fixtureValues['caller-response-stores']=[string](ConvertTo-Json -InputObject @(@{origin=$origin;backendId='foundry';kind='foundry'}) -Compress)
        $realNonce=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
        $realPolicies=New-ProbeRealResponsesPolicies -Owner $ProbeName -Nonce $realNonce -Model $realModel -Inference $rendered.parameters.realResponsesInferencePolicy.value -Utility $rendered.parameters.ownedResponsesPolicy.value -Models $rendered.parameters.realResponsesModelsPolicy.value
        foreach ($name in @('inference','utility','models')) {
            foreach ($setting in $fixtureValues.Keys) { $realPolicies[$name]=$realPolicies[$name].Replace('{{'+$setting+'}}',[Security.SecurityElement]::Escape([string]$fixtureValues[$setting])) }
        }
        [xml]$limits=$fragments['byok-apply-caller-limits']
        foreach ($limiter in $limits.SelectNodes('//rate-limit-by-key|//quota-by-key|//azure-openai-token-limit')) { $limiter.SetAttribute('counter-key',('@("'+$ProbeName+':real:" + (string)context.Variables["callerPrincipalKey"])')) }
        $fragments['byok-apply-caller-limits']=$limits.OuterXml
    }
    if ($SharedGovernanceGate) {
        $vm = (& az vm show -g $ResourceGroup -n $VmName -o json --only-show-errors 2>$null) | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or @($vm.networkProfile.networkInterfaces).Count -ne 1) { throw 'Governance requires a uniquely selected test VM interface.' }
        $nic = (& az network nic show --ids $vm.networkProfile.networkInterfaces[0].id -o json --only-show-errors 2>$null) | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or @($nic.ipConfigurations).Count -ne 1) { throw 'Governance requires a uniquely selected private VM address.' }
        $subnet = (& az network vnet subnet show --ids $service.properties.virtualNetworkConfiguration.subnetResourceId -o json --only-show-errors 2>$null) | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $subnet.addressPrefix -notmatch '^(?:[0-9]{1,3}\.){3}[0-9]{1,3}/(?:[0-9]|[12][0-9]|3[0-2])$' -or
            $nic.ipConfigurations[0].subnet.id.Split('/subnets/')[0] -ne $service.properties.virtualNetworkConfiguration.subnetResourceId.Split('/subnets/')[0]) { throw 'Governance mock and APIM must be on the verified same VNet.' }
        $mockUrl = 'http://' + $nic.ipConfigurations[0].privateIPAddress + ':18741/' + $ProbeName
        $mockNonce = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
        $mockSourcePrefix = $subnet.addressPrefix
        $fixtureValues['caller-key-enabled'] = 'true'; $fixtureValues['caller-native-subscription-required'] = 'true'
        $fixtureValues['caller-response-stores'] = '[{"origin":"https://fixture.example.test","backendId":"' + $ProbeName + '-mock","kind":"foundry"}]'
        $fragments = New-ProbeSharedRuntimeFragments -MockBackendUrl $mockUrl -MockBackendNonce $mockNonce
        $governancePolicies = New-ProbeSharedGovernancePolicies -Owner $ProbeName -MockBackendUrl $mockUrl -Nonce $mockNonce -ResponsesPolicy $rendered.parameters.ownedResponsesPolicy.value -ThrottleTelemetry $(if($OperationalGate){$package.throttleTelemetry}else{''})
        if($OperationalGate){$governancePolicies.package=$package}
        $governancePolicies.limits = @{}
        foreach ($mode in @('stateful', 'rpm', 'quota', 'tpm-chat-json', 'tpm-chat-stream', 'tpm-responses-json', 'tpm-responses-stream')) {
            [xml]$limits = $fragments['byok-apply-caller-limits']
            foreach ($limiter in $limits.SelectNodes('//rate-limit-by-key|//quota-by-key|//azure-openai-token-limit')) { $limiter.SetAttribute('counter-key', ('@("' + $ProbeName + ':' + $mode + ':" + (string)context.Variables["callerPrincipalKey"])')) }
            $limits.SelectSingleNode('//rate-limit-by-key').SetAttribute('calls', $(if ($mode -eq 'rpm') { '3' } else { '100000' }))
            $limits.SelectSingleNode('//quota-by-key').SetAttribute('calls', $(if ($mode -eq 'quota') { '3' } else { '100000' }))
            $limits.SelectSingleNode('//azure-openai-token-limit').SetAttribute('tokens-per-minute', $(if ($mode.StartsWith('tpm-')) { '50' } else { '100000' }))
            if ($mode -eq 'stateful') { $fragments['byok-apply-caller-limits'] = $limits.OuterXml }
            else { $governancePolicies.limits[$mode] = $limits.OuterXml }
        }
    }
    $created = [Collections.Generic.List[string]]::new()
    $apiPath = "$ServiceId/apis/$ProbeName"
    $description = 'No-model shared authentication runtime; owner=' + $ProbeName
    $apiAttempted = $false
    $certificateAttempted = $false
    try {
        foreach ($name in $fragments.Keys | Sort-Object) {
            $fragmentName = $ProbeName + '-' + $name
            $fragmentPath = "$ServiceId/policyFragments/$fragmentName"
            if ($null -ne (Invoke-ProbeArm GET $fragmentPath -AllowNotFound)) { throw 'Shared runtime fragment ID already exists; refusing replacement.' }
            $content = $fragments[$name]
            foreach ($setting in $fixtureValues.Keys) { $content = $content.Replace('{{' + $setting + '}}', [Security.SecurityElement]::Escape([string]$fixtureValues[$setting])) }
            if ($SharedGovernanceGate) {
                [xml]$markedFragment = $content
                foreach ($rejection in $markedFragment.SelectNodes('//return-response')) {
                    $header = $markedFragment.CreateElement('set-header')
                    $header.SetAttribute('name', 'X-Probe-Rejected')
                    $header.SetAttribute('exists-action', 'override')
                    $value = $markedFragment.CreateElement('value')
                    $value.InnerText = $name
                    $null = $header.AppendChild($value)
                    $bodyNode = $rejection.SelectSingleNode('set-body')
                    if ($bodyNode) { $null = $rejection.InsertBefore($header, $bodyNode) } else { $null = $rejection.AppendChild($header) }
                }
                $content = $markedFragment.OuterXml
            }
            $created.Add($fragmentPath)
            try { $null = Invoke-ProbeArm PUT $fragmentPath @{ properties = @{ description = $description; format = 'xml'; value = $content } } -PolicyDiagnostics -RedactedValues ([string[]]$fixtureValues.Values) -CompleteFragmentOperation -ResourceLocation $service.location }
            catch { throw ('Shared fragment installation failed: ' + $name + '; ' + $_.Exception.Message) }
            [pscustomobject]@{ test = 'shared-fragment-accepted'; fragment = $name; passed = $true }
        }
        if ($null -ne (Invoke-ProbeArm GET $apiPath -AllowNotFound)) { throw 'Shared runtime API ID already exists; refusing replacement.' }
        $apiAttempted = $true
        $null = Invoke-ProbeArm PUT $apiPath @{ properties = @{ displayName = 'Shared auth runtime ' + $ProbeName; description = $description; path = $ProbeName; protocols = @('https'); subscriptionRequired = $false } }
        $runtimePolicy = @"
<policies><inbound>
<set-variable name="byokCredentialHeader" value="api-key" />
<include-fragment fragment-id="$ProbeName-byok-authenticate" />
<include-fragment fragment-id="$ProbeName-byok-strip-caller-credentials" />
<return-response><set-status code="200" reason="Shared auth runtime validated" />
<set-header name="X-Probe-Shared" exists-action="override"><value>$ProbeName</value></set-header>
<set-header name="X-Probe-Validated" exists-action="override"><value>@(((bool)context.Variables[&quot;byokJwtValidated&quot;] &amp;&amp; (bool)context.Variables[&quot;byokCallerAuthenticated&quot;]).ToString())</value></set-header>
<set-header name="X-Probe-Stripped" exists-action="override"><value>@((!context.Request.Headers.ContainsKey(&quot;api-key&quot;) &amp;&amp; !context.Request.Headers.ContainsKey(&quot;Authorization&quot;)).ToString())</value></set-header>
<set-body>{"modelCalled":false,"validated":true}</set-body></return-response>
</inbound><backend /><outbound /><on-error /></policies>
"@
        Set-ProbeSharedRuntimePolicy -ApiPath $apiPath -Policy $runtimePolicy -FragmentPaths $created.ToArray() -OwnerDescription $description -RedactedValues ([string[]]$fixtureValues.Values)
        $null = Invoke-ProbeArm PUT "$apiPath/operations/check" @{ properties = @{ displayName = 'Shared validator check'; method = 'GET'; urlTemplate = '/check'; responses = @() } }
        foreach ($consumer in $consumers) {
            $operationPath = "$apiPath/operations/compile-$($consumer.name)"
            $null = Invoke-ProbeArm PUT $operationPath @{ properties = @{ displayName = 'Denied shared consumer ' + $consumer.name; method = 'GET'; urlTemplate = '/compile-' + $consumer.name; responses = @() } }
            $consumerPolicy = $consumer.value
            foreach ($setting in $fixtureValues.Keys) { $consumerPolicy = $consumerPolicy.Replace('{{' + $setting + '}}', [Security.SecurityElement]::Escape([string]$fixtureValues[$setting])) }
            try { $null = Invoke-ProbeArm PUT "$operationPath/policies/policy" @{ properties = @{ format = $consumer.format; value = $consumerPolicy } } -PolicyDiagnostics -RedactedValues ([string[]]$fixtureValues.Values) }
            catch { throw ('Denied shared consumer installation failed: ' + $consumer.name + '; ' + $_.Exception.Message) }
            [pscustomobject]@{ test = 'shared-consumer-policy-accepted'; consumer = $consumer.name; passed = $true; backendEnabled = $false }
        }
        if ($consumers.Count) {
            $consumerResults = @(Invoke-ProbeVm @('Phase=SharedConsumerTest', ('ConsumerInventory='+$(if($CallerPackagePath){'packages'}else{'main'})), ('ProbeId=' + $ProbeName), ('GatewayUri=' + $gatewayUri), ('ArmResource=' + $ArmResource)))
            $consumerResults
            if (@($consumerResults | Where-Object { $_.test -eq 'shared-consumer-denial' -and $_.passed }).Count -ne $consumers.Count) { throw 'Every installed consumer must return its owned denial before executing feature policies.' }
        }
        $tokenRaw = & az account get-access-token --tenant $tenantId --scope ($audience.properties.value + '/.default') -o json --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Pinned delegated token acquisition unavailable; resources will be cleaned.' }
        $credential = $tokenRaw | ConvertFrom-Json
        if (-not $credential.accessToken) { throw 'Delegated token was not returned.' }
        $certificateAttempted = $true
        $publicRows = @(Invoke-ProbeVm @('Phase=Prepare', ('ProbeId=' + $ProbeName), ('ArmResource=' + $ArmResource)))
        $public = @($publicRows | Where-Object test -eq 'transport-certificate')
        if ($public.Count -ne 1) { throw 'Temporary token transport could not be prepared.' }
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($public[0].publicCertificate))
        $encrypted = Protect-CmsMessage -To $certificate -Content $credential.accessToken
        $credential = $null; $tokenRaw = $null
        $results = @(Invoke-ProbeVm @('Phase=SharedRuntimeTest', ('ProbeId=' + $ProbeName), ('GatewayUri=' + $gatewayUri + '/check'), ('ArmResource=' + $ArmResource), ('ProtectedToken=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($encrypted)))))
        $results
        if (@($results | Where-Object { $_.test -eq 'temporary-transport-certificate-removed' -and $_.passed }).Count -eq 1) { $certificateAttempted = $false }
        if (@($results | Where-Object { $_.test -eq 'shared-runtime-auth' }).Count -ne 7 -or @($results | Where-Object { $_.passed -eq $false }).Count) { throw 'Shared runtime authentication did not pass every required control.' }
        if ($SharedGovernanceGate) {
            Invoke-ProbeSharedGovernanceGate -ServiceId $ServiceId -Owner $ProbeName -ArmResource $ArmResource -Policies $governancePolicies -MockUrl $mockUrl -Nonce $mockNonce -SourcePrefix $mockSourcePrefix -Settings $fixtureValues -GatewayUrl $service.properties.gatewayUrl
        }
        if ($RealResponsesGate) {
            Invoke-ProbeRealResponsesGate -ServiceId $ServiceId -Owner $ProbeName -ArmResource $ArmResource -Location $service.location -GatewayUrl $service.properties.gatewayUrl -Settings $fixtureValues -Policies $realPolicies -Model $realModel -Nonce $realNonce -OwnerFragment $fragments['byok-response-owner-context']
        }
    } finally {
        if ($script:preserveRealResponses) { throw 'Real response recovery is required; diagnostic resources were deliberately retained.' }
        $credential = $null; $tokenRaw = $null; $fixtureValues = $null
        if ($certificateAttempted) { Invoke-ProbeVm @('Phase=Cleanup', ('ProbeId=' + $ProbeName), ('ArmResource=' + $ArmResource)) }
        if ($apiAttempted) {
            $owned = Invoke-ProbeArm GET $apiPath -AllowNotFound
            if ($null -ne $owned) {
                if ($owned.properties.description -cne $description -or $owned.properties.path -cne $ProbeName -or $owned.properties.serviceUrl) { throw 'Shared runtime API ownership changed; cleanup requires inspection.' }
                $null = Invoke-ProbeArm DELETE $apiPath -RequestHeaders @{ 'If-Match' = '*' } -CompleteOwnedOperation
            }
            if ($null -ne (Invoke-ProbeArm GET $apiPath -AllowNotFound)) { throw 'Shared runtime API deletion readback is pending; fragment cleanup must follow verified API removal.' }
        }
        foreach ($fragmentPath in $created) {
            $owned = Invoke-ProbeArm GET $fragmentPath -AllowNotFound
            if ($null -ne $owned) {
                if ($owned.properties.description -cne $description) { throw 'Shared runtime fragment ownership changed; refusing deletion.' }
                $null = Invoke-ProbeArm DELETE $fragmentPath -RequestHeaders @{ 'If-Match' = '*' } -CompleteFragmentOperation
            }
            if ($null -ne (Invoke-ProbeArm GET $fragmentPath -AllowNotFound)) { throw 'Shared runtime fragment removal is not yet verified.' }
        }
        [pscustomobject]@{ test = 'shared-runtime-resources-removed'; passed = $true }
    }
}

if ($SharedRuntimeGate -and $ValidateOnly) {
    $fixtures = New-ProbeSharedRuntimeFragments
    if ($fixtures.Count -ne 8) { throw 'Incomplete shared runtime fragment inventory.' }
    foreach ($name in $fixtures.Keys) {
        [xml]$document = $fixtures[$name]
        if ($document.SelectNodes('//include-fragment').Count) { throw 'Nested runtime fragment was not flattened.' }
        if ($fixtures[$name] -match '\bUri(?:Kind|Partial)\b') { throw 'Shared policy expressions cannot depend on unsupported URI enum types.' }
    }
    Write-Output 'PASS: eight actual shared runtime fragments flattened without Azure or model calls.'
    return
}

function New-ProbeMeteringPolicy {
    param(
        [ValidatePattern('^jwt-probe-[a-z0-9-]+$')] [string] $Owner,
        [ValidateSet('azure-openai-token-limit', 'llm-token-limit')] [string] $Limiter,
        [ValidatePattern('^(old|llm)-(openai|anthropic)-(json|stream)$')] [string] $Fixture,
        [string] $MockAddress
    )
    $address = $null
    if (-not [ipaddress]::TryParse($MockAddress, [ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Metering requires a verified VM IPv4 address.' }
    return @"
<policies><inbound>
<choose><when condition="@(context.Request.Headers.GetValueOrDefault(&quot;X-Probe-Ready&quot;, &quot;&quot;) == &quot;$Owner&quot;)">
<return-response><set-status code="204" reason="Metering operation ready" />
<set-header name="X-Probe-Metering" exists-action="override"><value>$Fixture</value></set-header>
</return-response></when></choose>
<set-header name="Authorization" exists-action="delete" />
<set-header name="api-key" exists-action="delete" />
<set-header name="x-api-key" exists-action="delete" />
<$Limiter counter-key="$Owner-$Fixture" tokens-per-minute="50" estimate-prompt-tokens="false" tokens-consumed-header-name="x-probe-tokens" remaining-tokens-header-name="x-probe-tokens-remaining" />
<set-backend-service base-url="http://${MockAddress}:18741" />
<rewrite-uri template="/$Owner/$Fixture" copy-unmatched-params="false" />
</inbound><backend><forward-request buffer-request-body="true" buffer-response="false" /></backend>
<outbound><set-header name="X-Probe-Metering" exists-action="override"><value>$Fixture</value></set-header></outbound>
<on-error><set-header name="X-Probe-Metering-Error" exists-action="override"><value>@(context.LastError.Source)</value></set-header></on-error>
</policies>
"@
}

function Invoke-ProbeAnthropicMeteringGate {
    param([string] $ServiceId, [string] $ProbeName, [string] $ArmResource, [string] $MockAddress, [string] $SourcePrefix)
    $apiPath = "$ServiceId/apis/$ProbeName"
    $displayName = 'Isolated token metering ' + $ProbeName
    $description = 'Synthetic model usage only; owner=' + $ProbeName
    $before = Invoke-ProbeArm GET $ServiceId
    if ($before.properties.provisioningState -ne 'Succeeded' -or $before.properties.virtualNetworkType -ne 'Internal') { throw 'Metering requires a stable internal gateway.' }
    if ($null -ne (Invoke-ProbeArm GET $apiPath -AllowNotFound)) { throw 'Metering API ID already exists; nothing was changed.' }
    $gatewayUri = $before.properties.gatewayUrl.TrimEnd('/') + '/' + $ProbeName
    $transport = @(Invoke-ProbeVm @('Phase=HeaderParityTransport', ('ProbeId=' + $ProbeName), ('GatewayUri=' + $gatewayUri + '/preflight'), ('ArmResource=' + $ArmResource)))
    if ($transport.Count -ne 1 -or $transport[0].passed -ne $true) { throw 'Strict transport preflight failed; no metering API or firewall rule was created.' }
    $attemptedCreation = $false
    $acceptedFixtures = @()
    try {
        $attemptedCreation = $true
        $null = Invoke-ProbeArm PUT $apiPath @{ properties = @{ displayName = $displayName; description = $description; path = $ProbeName; protocols = @('https'); subscriptionRequired = $false } }
        $null = Invoke-ProbeArm PUT "$apiPath/policies/policy" @{ properties = @{ format = 'xml'; value = (New-ProbeHeaderParityPolicy $ProbeName 'blind') } }
        $limiters = if ($MeteringPolicy -eq 'both') { @('azure-openai-token-limit', 'llm-token-limit') } else { @($MeteringPolicy) }
        foreach ($limiter in $limiters) {
            $prefix = if ($limiter -eq 'llm-token-limit') { 'llm' } else { 'old' }
            foreach ($family in @('openai', 'anthropic')) {
                foreach ($format in @('json', 'stream')) {
                    $fixture = "$prefix-$family-$format"
                    $suffix = if ($family -eq 'anthropic') { 'v1/messages' } else { 'v1/chat/completions' }
                    $null = Invoke-ProbeArm PUT "$apiPath/operations/$fixture" @{ properties = @{ displayName = $fixture; method = 'POST'; urlTemplate = "/$fixture/$suffix"; responses = @() } }
                    try {
                        $null = Invoke-ProbeArm PUT "$apiPath/operations/$fixture/policies/policy" @{ properties = @{ format = 'xml'; value = (New-ProbeMeteringPolicy $ProbeName $limiter $fixture $MockAddress) } }
                        $acceptedFixtures += $fixture
                    } catch {
                        if ($_.Exception.Message -notmatch '^Probe ARM request failed: HTTP 400 ') { throw }
                        [pscustomobject]@{ test = 'metering-policy-accepted'; fixture = $fixture; passed = $false; reason = 'policy-validation-rejected' }
                    }
                }
            }
        }
        if ($acceptedFixtures.Count) {
            $rows = @(Invoke-ProbeVm @('Phase=AnthropicMeteringTest', ('ProbeId=' + $ProbeName), ('GatewayUri=' + $gatewayUri), ('ArmResource=' + $ArmResource),
                ('MockAddress=' + $MockAddress), ('MockSourcePrefix=' + $SourcePrefix), ('MeteringFixtures=' + ($acceptedFixtures -join ','))))
            $rows
            if (@($rows | Where-Object { $_.test -eq 'metering-mock-cleanup' -and $_.passed -eq $true }).Count -ne 1) { throw 'Metering listener/firewall cleanup was not verified.' }
            if (@($rows | Where-Object test -eq 'synthetic-token-metering').Count -ne $acceptedFixtures.Count) { throw 'Metering returned incomplete fixture results.' }
        }
    } finally {
        if ($attemptedCreation) {
            $owned = Invoke-ProbeArm GET $apiPath -AllowNotFound
            if ($null -ne $owned) {
                if ($owned.properties.displayName -cne $displayName -or $owned.properties.description -cne $description -or
                    $owned.properties.path -cne $ProbeName -or $owned.properties.serviceUrl) { throw 'Metering API ownership changed; refusing to delete an unverified resource.' }
                $null = Invoke-ProbeArm DELETE $apiPath -RequestHeaders @{ 'If-Match' = '*' }
            }
            $removed = $null -eq (Invoke-ProbeArm GET $apiPath -AllowNotFound)
            [pscustomobject]@{ test = 'metering-api-removed'; passed = $removed }
            if (-not $removed) { throw 'Metering API deletion readback is pending; verify before another run.' }
            $after = Invoke-ProbeArm GET $ServiceId
            if ($after.properties.provisioningState -ne 'Succeeded' -or $after.properties.virtualNetworkType -cne $before.properties.virtualNetworkType -or
                $after.properties.virtualNetworkConfiguration.subnetResourceId -cne $before.properties.virtualNetworkConfiguration.subnetResourceId -or
                $after.properties.customProperties.'Microsoft.WindowsAzure.ApiManagement.Gateway.Protocols.Server.Http2' -cne $before.properties.customProperties.'Microsoft.WindowsAzure.ApiManagement.Gateway.Protocols.Server.Http2') { throw 'Gateway settings changed during the isolated metering probe.' }
            [pscustomobject]@{ test = 'metering-service-unchanged'; passed = $true }
        }
    }
}

if ($AnthropicMeteringGate -and $ValidateOnly) {
    foreach ($limiter in @('azure-openai-token-limit', 'llm-token-limit')) {
        [xml]$fixturePolicy = New-ProbeMeteringPolicy $ProbeId $limiter 'llm-anthropic-json' '127.0.0.1'
        if ($fixturePolicy.SelectNodes('//base|//include-fragment|//validate-jwt|//send-request|//authentication-managed-identity').Count -or
            $fixturePolicy.SelectNodes('//' + $limiter).Count -ne 1 -or $fixturePolicy.SelectNodes('//set-backend-service').Count -ne 1 -or
            $fixturePolicy.SelectSingleNode('/policies/backend/forward-request').GetAttribute('buffer-response') -ne 'false') { throw 'Metering fixture has an uncontrolled call path or buffers the stream.' }
    }
    Write-Output 'PASS: synthetic token-metering policies target only the supplied mock and preserve streaming.'
    return
}

function New-ProbeHeaderParityPolicy {
    param(
        [ValidatePattern('^jwt-probe-[a-z0-9-]+$')] [string] $Owner,
        [ValidateSet('blind', 'array', 'joined')] [string] $Stage
    )
    $observation = ''
    $responseHeaders = ''
    if ($Stage -eq 'joined') {
        $observation += '<set-variable name="probeJoinedComma" value="@(context.Request.Headers.GetValueOrDefault(&quot;Authorization&quot;, &quot;&quot;).Contains(&quot;,&quot;))" />'
        $responseHeaders += '<set-header name="X-Parity-Joined-Comma" exists-action="override"><value>@(((bool)context.Variables[&quot;probeJoinedComma&quot;]).ToString())</value></set-header>'
    }
    if ($Stage -ne 'blind') {
        $observation += @'
<set-variable name="probeHeaderCount" value="@(context.Request.Headers.ContainsKey(&quot;Authorization&quot;) ? context.Request.Headers[&quot;Authorization&quot;].Length : 0)" />
<set-variable name="probeHeaderEqual" value="@{
    if (!context.Request.Headers.ContainsKey(&quot;Authorization&quot;)) { return true; }
    var values = context.Request.Headers[&quot;Authorization&quot;];
    return values.Length &lt; 2 || values.All(value =&gt; string.Equals(value, values[0], StringComparison.Ordinal));
}" />
'@
        $responseHeaders += @'
<set-header name="X-Parity-Count" exists-action="override"><value>@(((int)context.Variables[&quot;probeHeaderCount&quot;]).ToString())</value></set-header>
<set-header name="X-Parity-Equal" exists-action="override"><value>@(((bool)context.Variables[&quot;probeHeaderEqual&quot;]).ToString())</value></set-header>
'@
    }
    return @"
<policies><inbound>
$observation
<return-response><set-status code="401" reason="Isolated header observation" />
<set-header name="X-Parity-Probe" exists-action="override"><value>$Owner</value></set-header>
<set-header name="X-Parity-Stage" exists-action="override"><value>$Stage</value></set-header>
$responseHeaders
<set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header>
<set-body>{"diagnostic":"header-observation","backendCalled":false}</set-body>
</return-response></inbound><backend /><outbound /><on-error>
<return-response><set-status code="500" reason="Header observation expression failed" />
<set-header name="X-Parity-Probe" exists-action="override"><value>$Owner</value></set-header>
<set-header name="X-Parity-Stage" exists-action="override"><value>$Stage-error</value></set-header>
</return-response></on-error></policies>
"@
}

function Invoke-ProbeHeaderParityGate {
    param([string] $ServiceId, [string] $ProbeName, [string] $ArmResource)
    if ($ProbeName -notmatch '^jwt-probe-[a-z0-9-]+$') { throw 'Invalid header-probe ownership ID.' }
    $apiPath = "$ServiceId/apis/$ProbeName"
    $displayName = 'Isolated header parity ' + $ProbeName
    $description = 'Temporary no-backend header observation; owner=' + $ProbeName
    $before = Invoke-ProbeArm GET $ServiceId
    if ($before.properties.provisioningState -ne 'Succeeded' -or $before.properties.virtualNetworkType -ne 'Internal') { throw 'Header parity requires a stable internal gateway.' }
    $beforeSettings = [ordered]@{
        http2 = $before.properties.customProperties.'Microsoft.WindowsAzure.ApiManagement.Gateway.Protocols.Server.Http2'
        network = $before.properties.virtualNetworkType
        subnet = $before.properties.virtualNetworkConfiguration.subnetResourceId
    } | ConvertTo-Json -Compress
    if ($null -ne (Invoke-ProbeArm GET $apiPath -AllowNotFound)) { throw 'Diagnostic API ID already exists; nothing was changed.' }
    $gatewayUri = $before.properties.gatewayUrl.TrimEnd('/') + '/' + $ProbeName
    $transport = @(Invoke-ProbeVm @('Phase=HeaderParityTransport', ('ProbeId=' + $ProbeName), ('GatewayUri=' + $gatewayUri + '/preflight'), ('ArmResource=' + $ArmResource)))
    if ($transport.Count -ne 1 -or $transport[0].test -ne 'header-parity-transport' -or $transport[0].passed -ne $true) {
        $transport
        throw 'Strict HTTP/1.1 transport preflight failed; no diagnostic API was created and no network change was attempted.'
    }
    $attemptedCreation = $false
    try {
        $attemptedCreation = $true
        $null = Invoke-ProbeArm PUT $apiPath @{ properties = @{
            displayName = $displayName; description = $description; path = $ProbeName
            protocols = @('https'); subscriptionRequired = $false
        } }
        $null = Invoke-ProbeArm PUT "$apiPath/policies/policy" @{ properties = @{ format = 'xml'; value = (New-ProbeHeaderParityPolicy $ProbeName 'blind') } }
        foreach ($stage in @('blind', 'array', 'joined')) {
            $null = Invoke-ProbeArm PUT "$apiPath/operations/$stage" @{ properties = @{
                displayName = 'Header observation ' + $stage; method = 'GET'; urlTemplate = '/' + $stage; responses = @()
            } }
            $null = Invoke-ProbeArm PUT "$apiPath/operations/$stage/policies/policy" @{ properties = @{ format = 'xml'; value = (New-ProbeHeaderParityPolicy $ProbeName $stage) } }
        }
        $observations = @(Invoke-ProbeVm @('Phase=HeaderParityTest', ('ProbeId=' + $ProbeName), ('GatewayUri=' + $gatewayUri), ('ArmResource=' + $ArmResource)))
        if ($observations.Count -ne 1 -or $observations[0].test -ne 'header-parity-observations' -or
            $observations[0].completed -ne $true -or @($observations[0].rows).Count -ne 24) { throw 'Header parity returned an incomplete observation matrix.' }
        $observations
    } finally {
        if ($attemptedCreation) {
            $owned = Invoke-ProbeArm GET $apiPath -AllowNotFound
            if ($null -ne $owned) {
                if ($owned.name -ne $ProbeName -or $owned.properties.displayName -cne $displayName -or
                    $owned.properties.description -cne $description -or $owned.properties.path -cne $ProbeName -or
                    $owned.properties.subscriptionRequired -ne $false -or $owned.properties.serviceUrl) {
                    throw 'Diagnostic API ownership/configuration changed; refusing cleanup of an unverified resource.'
                }
                $null = Invoke-ProbeArm DELETE $apiPath -RequestHeaders @{ 'If-Match' = '*' }
            }
            if ($null -ne (Invoke-ProbeArm GET $apiPath -AllowNotFound)) { throw 'Diagnostic API deletion has not been verified; inspect before starting another run.' }
            [pscustomobject]@{ test = 'header-parity-api-removed'; passed = $true }
            $after = Invoke-ProbeArm GET $ServiceId
            $afterSettings = [ordered]@{
                http2 = $after.properties.customProperties.'Microsoft.WindowsAzure.ApiManagement.Gateway.Protocols.Server.Http2'
                network = $after.properties.virtualNetworkType
                subnet = $after.properties.virtualNetworkConfiguration.subnetResourceId
            } | ConvertTo-Json -Compress
            if ($beforeSettings -cne $afterSettings -or $after.properties.provisioningState -ne 'Succeeded') { throw 'Gateway state/settings changed during the probe; no restoration write was attempted.' }
            [pscustomobject]@{ test = 'header-parity-service-unchanged'; passed = $true }
        }
    }
}

if ($HeaderParityGate -and $ValidateOnly) {
    foreach ($stage in @('blind', 'array', 'joined')) {
        [xml]$diagnosticPolicy = New-ProbeHeaderParityPolicy $ProbeId $stage
        if ($diagnosticPolicy.SelectNodes('//base|//include-fragment|//validate-jwt|//send-request|//forward-request|//set-backend-service|//authentication-managed-identity').Count -or
            $diagnosticPolicy.SelectSingleNode('/policies/inbound/return-response/set-status').code -ne '401' -or
            ($stage -eq 'blind' -and $diagnosticPolicy.OuterXml.Contains('context.Request'))) { throw 'Header observation is not isolated.' }
    }
    Write-Output 'PASS: three isolated inert header policies; no inheritance, validators or backend calls.'
    return
}
if ($Http2Gate -and -not $BackendGate) { throw 'Http2Gate requires BackendGate.' }
if ($Http2Gate) {
    if (-not $Http2ClientArchivePath -or $Http2ClientSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Http2Gate requires a locally verified client archive and SHA256.' }
    if ((Get-Item -LiteralPath $Http2ClientArchivePath).Length -gt 2097152 -or (Get-FileHash -LiteralPath $Http2ClientArchivePath -Algorithm SHA256).Hash -ne $Http2ClientSha256) { throw 'HTTP/2 client archive size or checksum failed preflight.' }
}
if ($ProductionPipelineGate -and (-not $BackendGate -or -not $SecondUserToken -or $CredentialHeader -ne 'api-key')) { throw 'ProductionPipelineGate requires the Foundry backend gate and two real users.' }
if ($AssociationGate -and (-not $OpenProductProbe -or $ExpandedGate -or $BackendGate -or $ParameterGate)) { throw 'AssociationGate requires OpenProductProbe and cannot combine with expanded, backend or parameter gates.' }
if ($ParameterGate -and (-not $TestExisting -or $AdmissionProbe -or $IncludeUserToken -or $AddValidationControls -or $ExpiredUserToken)) { throw 'ParameterGate requires TestExisting and cannot be combined with credential/admission tests.' }
if ($ProductContextGuard -and -not $AdmissionProbe) { throw 'ProductContextGuard requires AdmissionProbe.' }
if ($OpenProductProbe -and (-not $AdmissionProbe -or $ProductContextGuard)) { throw 'OpenProductProbe requires AdmissionProbe and cannot use ProductContextGuard.' }
if ($ExpandedGate -and (-not $OpenProductProbe -or -not $ExpiredUserToken)) { throw 'ExpandedGate requires OpenProductProbe and an expired signed user token.' }
if ($BackendGate -and (-not $ExpandedGate -or -not $BackendAddress -or -not $ApimSourcePrefix)) { throw 'BackendGate requires ExpandedGate, BackendAddress and ApimSourcePrefix.' }
if ($CredentialHeader -ne 'api-key' -and -not $BackendGate) { throw 'Alternate header testing requires BackendGate.' }
if ($BackendGate -or $AnthropicMeteringGate) {
    $address = $null
    if (-not [ipaddress]::TryParse($BackendAddress, [ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'BackendAddress must be an IPv4 address.' }
    if ($ApimSourcePrefix -notmatch '^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$') { throw 'ApimSourcePrefix must be an IPv4 subnet.' }
}
$source = ''
$authBlock = ''
if (-not $HeaderParityGate -and -not $AnthropicMeteringGate -and -not $SharedRuntimeGate) {
    $source = Get-Content -Raw (Join-Path $PSScriptRoot '../policies/byok-foundry-policy.xml')
    $authMatch = [regex]::Match($source, '(?s)<base\s*/>(?<auth>.*?)<!-- 4\. Extract developer identity')
    if (-not $authMatch.Success -or $authMatch.Groups['auth'].Value -notmatch '</validate-jwt>') { throw 'Cannot locate the existing Foundry JWT authentication block.' }
    $authBlock = $authMatch.Groups['auth'].Value
}
function New-ProbeProductionPipeline {
    param(
        [string] $SourcePolicy,
        [ValidateSet('baseline', 'rpm', 'tpm', 'quota')]
        [string] $Mode,
        [string] $ProbeName,
        [string] $MockAddress,
        [string] $Nonce,
        [string] $ListenerPrefix = $ProbeName
    )
    if ($ProbeName -notmatch '^jwt-probe-[a-z0-9-]+$' -or $ListenerPrefix -notmatch '^jwt-probe-[a-z0-9-]+$' -or $Nonce -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Invalid production fixture ownership marker.' }
    $address = $null
    if (-not [ipaddress]::TryParse($MockAddress, [ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Production fixture requires an IPv4 mock address.' }
    $backendPattern = '(?s)<!-- 8\. Mint a managed identity token.*?(?=<!-- 9\. Rewrite the OpenAI-style)'
    if ([regex]::Matches($SourcePolicy, $backendPattern).Count -ne 1) { throw 'Production backend boundary changed; fixture not generated.' }
    $fixture = [regex]::Replace($SourcePolicy, $backendPattern, '<set-backend-service base-url="http://' + $MockAddress + ':18741" />')
    if ([regex]::Matches($fixture, '<send-request\b').Count -ne 1 -or [regex]::Matches($fixture, '<authentication-managed-identity\b').Count -ne 1) { throw 'Unexpected remaining production side calls.' }
    $fixture = [regex]::Replace($fixture, '(?s)<send-request\b.*?</send-request>', '')
    $fixture = [regex]::Replace($fixture, '<authentication-managed-identity\b[^>]+/>', '')
    $counter = 'counter-key="@((string)context.Variables["developerOid"])"'
    if ([regex]::Matches($fixture, [regex]::Escape($counter)).Count -ne 3) { throw 'Production accounting counter shape changed.' }
    $fixture = $fixture.Replace($counter, 'counter-key="@("' + $ProbeName + '-' + $Mode + ':" + (string)context.Variables["developerOid"])"')
    $fixture = $fixture.Replace('namespace="copilot.byok"', 'namespace="copilot.byok.probe"')
    $backendLabel = '<set-variable name="backendName" value="@((bool)context.Variables["isCommercialModel"] ? "foundry-commercial" : ((bool)context.Variables["routeToAoai"] ? "aoai" : "foundry"))" />'
    if (-not $fixture.Contains($backendLabel)) { throw 'Production telemetry backend dimension changed.' }
    $mockLabel = @'
<set-variable name="backendName" value="@{
    var body = context.Request.Body?.As<JObject>(preserveContent: true);
    var surface = context.Request.OriginalUrl.Path.EndsWith("/responses") ? "responses" : "chat";
    var stream = (bool?)body?["stream"] ?? false;
    return "probe-__MODE__-" + surface + (stream ? "-stream" : "-json");
}" />
'@.Replace('__MODE__', $Mode)
    $fixture = $fixture.Replace($backendLabel, $mockLabel)
    $values = @{
        'auto-route-sentinel' = 'auto,byok-auto'
        'auto-route-length-threshold' = '1200'
        'auto-route-ambiguous-band' = '300'
        'auto-route-classifier-enabled' = 'false'
        'auto-route-classifier-deployment' = 'gpt-4o-mini'
        'auto-route-mini-deployment' = 'gpt-4o-mini'
        'auto-route-full-deployment' = 'gpt-5'
        'aoai-pinned-models' = '__none__'
        'commercial-models' = '__none__'
        'foundry-commercial-anthropic-models' = '__none__'
        'foundry-model-types' = '{}'
        'jwt-calls-per-minute' = $(if ($Mode -eq 'rpm') { '3' } else { '10000' })
        'jwt-tokens-per-minute' = $(if ($Mode -eq 'tpm') { '40' } else { '1000000' })
        'jwt-monthly-call-quota' = $(if ($Mode -eq 'quota') { '3' } else { '1000000' })
        'foundry-commercial-api-version' = '2024-10-21'
        'aoai-default-api-version' = '2024-10-21'
    }
    foreach ($name in $values.Keys) { $fixture = $fixture.Replace('{{' + $name + '}}', $values[$name]) }
    $allowedValues = @('api-app-id-uri', 'entra-openid-config-url', 'api-audience', 'required-scope')
    $remainingValues = @([regex]::Matches($fixture, '\{\{([^}]+)\}\}') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    if (@($remainingValues | Where-Object { $_ -notin $allowedValues }).Count) { throw 'Uncontrolled named values remain in the production fixture.' }
    $fixture = $fixture.Replace('<base />', '')
    $mockRouting = @'
<set-header name="X-Probe-Backend-Nonce" exists-action="override"><value>__NONCE__</value></set-header>
<set-header name="X-Probe-Pipeline-Mode" exists-action="override"><value>__MODE__</value></set-header>
<rewrite-uri template="@("/__PROBE__" + context.Request.Url.Path)" copy-unmatched-params="true" />
'@.Replace('__NONCE__', $Nonce).Replace('__MODE__', $Mode).Replace('__PROBE__', $ListenerPrefix)
    $fixture = $fixture.Replace('</inbound>', $mockRouting + '</inbound>')
    $fixture = $fixture.Replace('<on-error>', '<on-error><set-header name="X-Probe-Error" exists-action="override"><value>@(context.LastError.Reason)</value></set-header><set-header name="X-Probe-Error-Source" exists-action="override"><value>@(context.LastError.Source)</value></set-header>')
    $executablePolicy = [regex]::Replace($fixture, '(?s)<!--.*?-->', '')
    if ($executablePolicy -match '<(?:send-request|authentication-managed-identity|include-fragment)\b|backend-id=' -or [regex]::Matches($executablePolicy, '<set-backend-service\b').Count -ne 1) { throw 'Production fixture still contains an uncontrolled outbound path.' }
    foreach ($required in @('renewal-period="60"', 'renewal-period="2592000"', '<azure-openai-token-limit', '<llm-emit-token-metric', 'buffer-request-body="true"', 'stream_options', 'body.Remove("snippy")')) {
        if (-not $fixture.Contains($required)) { throw 'Required production pipeline behavior was lost during fixture generation.' }
    }
    return $fixture
}

$policy = @"
<policies><inbound>
$authBlock
<set-header name="api-key" exists-action="delete" />
<set-header name="Authorization" exists-action="delete" />
<set-variable name="probeCredentialsStripped" value="@(!context.Request.Headers.ContainsKey("api-key") &amp;&amp; !context.Request.Headers.ContainsKey("Authorization"))" />
<return-response>
  <set-status code="200" reason="JWT probe accepted" />
  <set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header>
  <set-header name="X-JWT-Probe" exists-action="override"><value>$ProbeId</value></set-header>
    <set-header name="X-JWT-Probe-Credentials-Stripped" exists-action="override"><value>@(((bool)context.Variables["probeCredentialsStripped"]).ToString())</value></set-header>
  <set-body>{"probe":"jwt-auth-only","validated":true,"backendCalled":false}</set-body>
</return-response>
</inbound><backend /><outbound /><on-error /></policies>
"@
if ($ValidateOnly) {
    if ($ProductionPipelineGate) {
        foreach ($mode in @('baseline', 'rpm', 'tpm', 'quota')) {
            $null = New-ProbeProductionPipeline $source $mode $ProbeId $BackendAddress ('A' * 64)
        }
        'PASS: production pipeline fixture isolation and accounting structure checks.'
        return
    }
    if ([regex]::Matches($policy, '<validate-jwt\b').Count -ne 1 -or $policy -match '<(?:forward-request|send-request|set-backend-service)\b') {
        throw 'Probe must contain exactly one validator and no backend call.'
    }
    if ($policy -notmatch '\{\{entra-openid-config-url\}\}' -or $policy -notmatch '\{\{api-audience\}\}' -or $policy -notmatch '\{\{required-scope\}\}') {
        throw 'Probe must preserve the existing issuer, audience and scope settings.'
    }
    'PASS: authentication extraction and no-backend probe checks.'
    return
}

$cloudRaw = & az cloud show -o json --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Cannot read the current Azure cloud.' }
$cloudInfo = $cloudRaw | ConvertFrom-Json
if ($cloudInfo.name -ne $Cloud) { throw 'Wrong Azure cloud. Use the separately pinned terminal; this script never switches clouds.' }
$vmOs = & az vm show --resource-group $ResourceGroup --name $VmName --query storageProfile.osDisk.osType -o tsv --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0 -or $vmOs -ne 'Windows') { throw 'The probe requires an existing Windows test VM; no probe resources were created.' }
$accountRaw = & az account show -o json --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Azure sign-in required in the pinned terminal.' }
$account = $accountRaw | ConvertFrom-Json
$tokenRaw = & az account get-access-token --resource-type arm -o json --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) { throw 'ARM authentication failed. Reauthenticate in the pinned terminal.' }
$armCredential = $tokenRaw | ConvertFrom-Json
$armHeaders = @{ Authorization = 'Bearer ' + $armCredential.accessToken }
$armRefreshAt = if ($armCredential.expires_on) { [DateTimeOffset]::FromUnixTimeSeconds([long]$armCredential.expires_on).AddMinutes(-5) } else { [DateTimeOffset]::UtcNow }
$serviceId = "/subscriptions/$($account.id)/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"
$armBase = $cloudInfo.endpoints.resourceManager.TrimEnd('/')

function Invoke-ProbeArm {
    param([string] $Method, [string] $Path, [object] $Body, [switch] $AllowNotFound, [hashtable] $RequestHeaders = @{}, [switch] $PolicyDiagnostics, [string[]] $RedactedValues = @(), [switch] $CompleteFragmentOperation, [switch] $CompleteOwnedOperation, [string] $ResourceLocation)
    if ([DateTimeOffset]::UtcNow -ge $script:armRefreshAt) {
        $renewedRaw = & az account get-access-token --resource-type arm -o json --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'ARM token renewal failed; reauthenticate securely in the pinned cloud.' }
        $renewed = $renewedRaw | ConvertFrom-Json
        if (-not $renewed.accessToken) { throw 'ARM token renewal returned no access token.' }
        $script:armHeaders.Authorization = 'Bearer ' + $renewed.accessToken
        $script:armRefreshAt = if ($renewed.expires_on) { [DateTimeOffset]::FromUnixTimeSeconds([long]$renewed.expires_on).AddMinutes(-5) } else { [DateTimeOffset]::UtcNow.AddMinutes(5) }
        $renewedRaw = $null
        $renewed = $null
    }
    $headers = $armHeaders.Clone()
    $headers.Accept = 'application/json'
    foreach ($headerName in $RequestHeaders.Keys) { $headers[$headerName] = $RequestHeaders[$headerName] }
    if (-not $script:probeArmWebSession) { $script:probeArmWebSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new() }
    $request = @{ Method = $Method; Uri = "$armBase${Path}?api-version=2024-05-01"; Headers = $headers; WebSession = $script:probeArmWebSession }
    if ($null -ne $Body) {
        $request.ContentType = 'application/json'
        $request.Body = $Body | ConvertTo-Json -Depth 30 -Compress
    }
    try {
        if ($CompleteFragmentOperation -or $CompleteOwnedOperation) {
            $permitted = if ($CompleteOwnedOperation) { $Method -eq 'DELETE' -and $Path -cmatch '(?i:/(?:apis|products|subscriptions|backends))/jwt-probe-[a-zA-Z0-9-]+\z' } else { $Path -cmatch '(?i:/policyFragments)/jwt-probe-[a-z0-9-]+\z' -and $Method -in @('PUT', 'DELETE') }
            if (-not $permitted) { throw 'Completed operations are restricted to owned diagnostic resource IDs.' }
            $bodyFile = $null
            try {
                if ($Method -eq 'PUT') {
                    if ([string]::IsNullOrWhiteSpace($ResourceLocation)) { throw 'The parent gateway location is required for a completed fragment write.' }
                    $bodyFile = Join-Path ([IO.Path]::GetTempPath()) ('jwt-probe-fragment-' + [guid]::NewGuid().ToString('N') + '.json')
                    $fragmentResource = @{ location = $ResourceLocation; properties = $Body.properties }
                    [IO.File]::WriteAllText($bodyFile, ($fragmentResource | ConvertTo-Json -Depth 30 -Compress), [Text.UTF8Encoding]::new($false))
                    $resultLines = @(& az resource create --id $Path --api-version 2024-05-01 --is-full-object --properties "@$bodyFile" -o json --only-show-errors 2>&1)
                } elseif ($CompleteOwnedOperation -and $Path -cmatch '(?i:/products)/(?<product>jwt-probe-[a-z0-9-]+)\z') {
                    $productName = $Matches.product
                    $productApis = if($ArmTransport -eq 'cli'){Invoke-ProbeArm GET "$Path/apis"}else{Invoke-RestMethod -Method GET -Uri "$armBase${Path}/apis?api-version=2024-05-01" -Headers $headers -WebSession $script:probeArmWebSession}
                    $productSubscriptions = if($ArmTransport -eq 'cli'){Invoke-ProbeArm GET "$Path/subscriptions"}else{Invoke-RestMethod -Method GET -Uri "$armBase${Path}/subscriptions?api-version=2024-05-01" -Headers $headers -WebSession $script:probeArmWebSession}
                    if (@($productApis.value | Where-Object { $null -ne $_ }).Count -or $productApis.nextLink -or $productSubscriptions.nextLink -or
                        @($productSubscriptions.value | Where-Object { $_ -and $_.properties.scope -ine $Path }).Count) { throw 'Owned product cleanup has unexpected associations or subscription scopes.' }
                    $resultLines = @(& az apim product delete --resource-group $ResourceGroup --service-name $ApimName --product-id $productName --delete-subscriptions true --if-match '*' --yes -o none --only-show-errors 2>&1)
                } else {
                    $resultLines = @(& az resource delete --ids $Path --api-version 2024-05-01 -o none --only-show-errors 2>&1)
                }
                if ($LASTEXITCODE -ne 0) {
                    $record = [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('APIM fragment operation failed.'), 'FragmentOperationFailed', [Management.Automation.ErrorCategory]::InvalidOperation, $null)
                    $record.ErrorDetails = [Management.Automation.ErrorDetails]::new((@{ error = @{ message = ($resultLines -join "`n") } } | ConvertTo-Json -Compress))
                    throw $record
                }
            } finally { if ($bodyFile -and (Test-Path -LiteralPath $bodyFile)) { Remove-Item -LiteralPath $bodyFile -Force } }
            $response = $null
            if ($Method -eq 'PUT') {
                $response = Invoke-ProbeArm -Method GET -Path $Path
                if ($response.properties.provisioningState -and $response.properties.provisioningState -ne 'Succeeded') { throw 'APIM fragment did not reach a successful state.' }
            }
        } elseif ($ArmTransport -eq 'cli') {
            $bodyFile=$null
            $previousEncoding=$env:PYTHONIOENCODING
            try {
                $env:PYTHONIOENCODING='utf-8'
                $arguments=@('rest','--method',$Method,'--url',$request.Uri,'--only-show-errors','-o','json')
                $cliHeaders=@('Content-Type=application/json','Accept=application/json')
                foreach($name in $RequestHeaders.Keys){$cliHeaders+=$name+'='+[string]$RequestHeaders[$name]}
                $arguments+=@('--headers')+$cliHeaders
                if($null -ne $Body){
                    $bodyFile=Join-Path ([IO.Path]::GetTempPath()) ('jwt-probe-arm-'+[guid]::NewGuid().ToString('N')+'.json')
                    [IO.File]::WriteAllText($bodyFile,($Body|ConvertTo-Json -Depth 30 -Compress),[Text.UTF8Encoding]::new($false))
                    $arguments+=@('--body',('@'+$bodyFile))
                }
                $resultLines=@(& az @arguments 2>&1)
                if($LASTEXITCODE -ne 0){
                    $message=$resultLines -join "`n"
                    if($AllowNotFound -and $Method -eq 'GET' -and $message -match '(?i)\((?:ResourceNotFound|NotFound|EntityNotFound)\)|"code"\s*:\s*"(?:ResourceNotFound|NotFound|EntityNotFound)"'){return $null}
                    $record=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('Diagnostic ARM CLI operation failed.'),'ProbeCliOperationFailed',[Management.Automation.ErrorCategory]::InvalidOperation,$null)
                    $record.ErrorDetails=[Management.Automation.ErrorDetails]::new((@{error=@{message=$message}}|ConvertTo-Json -Compress))
                    throw $record
                }
                $responseText=($resultLines -join "`n").TrimStart([char]0xFEFF)
                $response=if(-not [string]::IsNullOrWhiteSpace($responseText)){$responseText|ConvertFrom-Json -Depth 100}else{$null}
            } finally {
                $env:PYTHONIOENCODING=$previousEncoding
                if($bodyFile -and (Test-Path -LiteralPath $bodyFile)){Remove-Item -LiteralPath $bodyFile -Force}
            }
        } else { $response = Invoke-RestMethod @request }
        return $response
    }
    catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($AllowNotFound -and $Method -eq 'GET' -and $status -eq 404) { return $null }
        $code = ''
        try { $code = ($_.ErrorDetails.Message | ConvertFrom-Json).error.code } catch { }
        if ($PolicyDiagnostics -and ($status -in @(0,400) -or $_.FullyQualifiedErrorId -match 'FragmentOperationFailed')) {
            $details = @()
            try {
                $messages = @()
                if ($_.ErrorDetails.Message) {
                    try {
                        $errorData = ($_.ErrorDetails.Message | ConvertFrom-Json).error
                        $messages = @($errorData.details | ForEach-Object message | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
                        if (-not $messages.Count -and $errorData.message) { $messages = @($errorData.message) }
                    } catch { }
                }
                if (-not $messages.Count) { $messages = @($_.Exception.Message) }
                foreach ($message in $messages | Select-Object -First 4) {
                    $safe = [string]$message
                    foreach ($value in $RedactedValues | Where-Object { $_.Length -gt 6 }) { $safe = $safe.Replace($value, '<redacted>').Replace([Security.SecurityElement]::Escape($value), '<redacted>') }
                    $safe = [regex]::Replace($safe, 'https?://[^\s"<>]+|[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}|[A-Za-z0-9+/]{40,}={0,2}', '<redacted>')
                    $safe = [regex]::Replace($safe, '"[^"\r\n]*"', '"<literal>"')
                    $details += $safe.Substring(0, [Math]::Min(700, $safe.Length))
                }
            } catch { $details = @('Policy validation details unavailable.') }
            throw ('Probe policy validation failed: ' + ($details -join ' | '))
        }
        $category = $_.Exception.GetBaseException().GetType().Name
        throw "Probe ARM request failed: HTTP $status $code ($category; $Method). No response body or credentials displayed."
    }
}

function Invoke-ProbeVm {
    param([string[]] $Parameters)
    $remoteFile = Join-Path $PSScriptRoot 'probe-jwt-auth-vm.ps1'
    $temporaryScript = $null
    try {
        $scriptText = Get-Content -Raw $remoteFile
        if ($Http2Gate -and $Parameters -contains 'AdmissionPayload=true') {
            $Parameters += 'Http2ClientArchive=' + [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Http2ClientArchivePath).Path))
            $Parameters += 'Http2ClientSha256=' + $Http2ClientSha256
        }
        $shortParameters = @()
        foreach ($parameter in $Parameters) {
            if ($parameter -match '^(ProtectedToken|ProtectedExpiredToken|Http2ClientArchive)=([A-Za-z0-9+/=]+)$') {
                $parameterName = $Matches[1]
                $ciphertextValue = $Matches[2]
                $scriptText = $scriptText.Replace('[string] $' + $parameterName + ',', '[string] $' + $parameterName + " = '$ciphertextValue',")
            } else {
                $shortParameters += $parameter
            }
        }
        if ($shortParameters.Count -ne $Parameters.Count) {
            $temporaryScript = Join-Path ([IO.Path]::GetTempPath()) ('jwt-probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
            [IO.File]::WriteAllText($temporaryScript, $scriptText, [Text.UTF8Encoding]::new($true))
            $remoteFile = $temporaryScript
        }
        $resultRaw = & az vm run-command invoke --resource-group $ResourceGroup --name $VmName --command-id RunPowerShellScript --scripts "@$remoteFile" --parameters @shortParameters -o json --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) { throw "VM probe invocation failed. Probe API $ProbeId remains; no existing API was changed." }
    } finally {
        if ($temporaryScript) { Remove-Item -LiteralPath $temporaryScript -Force }
    }
    $result = $resultRaw | ConvertFrom-Json
    $resultCount = 0
    foreach ($entry in $result.value) {
        foreach ($line in ($entry.message -split '\r?\n')) {
            if ($line -match '^\{"test":') {
                $resultCount++
                $row = $line | ConvertFrom-Json
                if ($row.test -eq 'compressed-admission') {
                    $stream = [IO.MemoryStream]::new([Convert]::FromBase64String($row.data))
                    $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Decompress)
                    $reader = [IO.StreamReader]::new($gzip)
                    try { $row = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose(); $gzip.Dispose(); $stream.Dispose() }
                }
                if ($row.test -eq 'native-admission-observations') {
                    $expanded = @($row.rows | ForEach-Object {
                        $result = [ordered]@{ case = $_[0]; http = $_[1]; ctx = $_[2]; passed = $_[3] }
                        if ($_.Count -gt 4) { $result.detail = $_[4] }
                        [pscustomobject]$result
                    })
                    [pscustomobject]@{ test = $row.test; results = $expanded }
                } else {
                    $row
                }
            }
        }
    }
    if ($resultCount -eq 0) {
        $messages = ($result.value | ForEach-Object { $_.message }) -join "`n"
        $categories = @('ParserError', 'ParameterBinding', 'Unprotect-CmsMessage', 'ConvertFrom-Json', 'OutOfMemory', 'cannot find', 'Access is denied') | Where-Object { $messages -match [regex]::Escape($_) }
        throw "VM returned no structured results (characters=$($messages.Length); categories=$($categories -join ',')). Details suppressed to protect credentials."
    }
}

if ($HeaderParityGate) {
    Invoke-ProbeHeaderParityGate -ServiceId $serviceId -ProbeName $ProbeId -ArmResource $cloudInfo.endpoints.activeDirectoryResourceId
    return
}
if ($AnthropicMeteringGate) {
    Invoke-ProbeAnthropicMeteringGate -ServiceId $serviceId -ProbeName $ProbeId -ArmResource $cloudInfo.endpoints.activeDirectoryResourceId -MockAddress $BackendAddress -SourcePrefix $ApimSourcePrefix
    return
}
if ($SharedRuntimeGate) {
    Invoke-ProbeSharedRuntimeGate -ServiceId $serviceId -ProbeName $ProbeId -ArmResource $cloudInfo.endpoints.activeDirectoryResourceId
    return
}

$certificatePrepared = $false
$certificateRemoved = $false
try {
    if ($ExpiredUserToken -and -not $IncludeUserToken) { throw 'Expiry replay requires IncludeUserToken for a fresh positive control.' }
    if ($ExpiredUserToken) {
        $expiredPlaintext = ConvertFrom-SecureString $ExpiredUserToken -AsPlainText
        $encodedClaims = $expiredPlaintext.Split('.')[1].Replace('-', '+').Replace('_', '/')
        $encodedClaims = $encodedClaims.PadRight($encodedClaims.Length + ((4 - $encodedClaims.Length % 4) % 4), '=')
        $expiryClaims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedClaims)) | ConvertFrom-Json
        if (-not $expiryClaims.exp -or [DateTimeOffset]::FromUnixTimeSeconds($expiryClaims.exp).AddMinutes(5) -gt [DateTimeOffset]::UtcNow) {
            throw 'Captured token has not expired beyond the five-minute clock-skew allowance; retry later without changing the signed token.'
        }
    }
    $existing = Invoke-ProbeArm GET "$serviceId/apis"
    $matching = @($existing.value | Where-Object { $_.name -eq $ProbeId -or $_.properties.path -eq $ProbeId })
    if ($TestExisting) {
        if ($matching.Count -ne 1 -or $matching[0].name -ne $ProbeId -or $matching[0].properties.path -ne $ProbeId -or $matching[0].properties.displayName -ne 'Isolated JWT authentication probe') {
            throw 'Existing API does not match the isolated probe contract.'
        }
    } elseif ($matching.Count) {
        throw 'Probe ID/path already exists. Refusing to overwrite it.'
    }
    $service = Invoke-ProbeArm GET $serviceId
    $gateway = $service.properties.gatewayUrl.TrimEnd('/')
    $apiPath = "$serviceId/apis/$ProbeId"
    if ($ParameterGate) {
        $operationId = 'schema-header-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
        $operationPath = "$apiPath/operations/$operationId"
        $schemaPolicy = @'
<policies><inbound>
<set-variable name="schemaAuthorizationCount" value="@(context.Request.Headers.ContainsKey("Authorization") ? context.Request.Headers["Authorization"].Length : 0)" />
<validate-parameters specified-parameter-action="prevent" unspecified-parameter-action="ignore" errors-variable-name="schemaErrors" />
<return-response><set-status code="200" reason="Schema accepted" />
<set-header name="X-Schema-Probe" exists-action="override"><value>validated</value></set-header>
<set-header name="X-Schema-Authorization-Count" exists-action="override"><value>@(((int)context.Variables["schemaAuthorizationCount"]).ToString())</value></set-header>
</return-response></inbound><backend /><outbound /><on-error>
<return-response><set-status code="400" reason="Schema probe rejected" />
<set-header name="X-Schema-Source" exists-action="override"><value>@(context.LastError.Source)</value></set-header>
<set-header name="X-Schema-Authorization-Count" exists-action="override"><value>@(context.Variables.GetValueOrDefault&lt;int&gt;("schemaAuthorizationCount", -1).ToString())</value></set-header>
</return-response></on-error></policies>
'@
        try {
            $null = Invoke-ProbeArm PUT $operationPath @{ properties = @{ displayName = 'Disposable header schema probe'; method = 'GET'; urlTemplate = "/$operationId"; request = @{ headers = @(@{ name = 'Authorization'; type = 'string'; required = $true; values = @('Bearer probe-valid') }) }; responses = @() } }
            $persisted = Invoke-ProbeArm GET $operationPath
            $header = @($persisted.properties.request.headers | Where-Object name -eq 'Authorization')
            if ($header.Count -ne 1 -or $header[0].type -ne 'string' -or -not $header[0].required -or @($header[0].values).Count -ne 1 -or $header[0].values[0] -ne 'Bearer probe-valid') { throw 'Authorization schema did not persist exactly; test is inconclusive.' }
            [pscustomobject]@{ test = 'authorization-schema-persisted'; passed = $true } | ConvertTo-Json -Compress
            $null = Invoke-ProbeArm PUT "$operationPath/policies/policy" @{ properties = @{ format = 'rawxml'; value = $schemaPolicy } }
            $parameterResults = @(Invoke-ProbeVm -Parameters @('Phase=ParameterTest', "GatewayUri=$gateway/$ProbeId/$operationId", "ArmResource=$($cloudInfo.endpoints.activeDirectoryResourceId)"))
            $parameterResults | ForEach-Object { $_ | ConvertTo-Json -Compress }
            $expectedNames = @('schema-single-valid', 'schema-single-invalid', 'schema-missing', 'schema-duplicate-identical', 'schema-duplicate-case', 'schema-different-valid-first', 'schema-different-valid-last', 'schema-single-valid-after')
            if ($parameterResults.Count -ne $expectedNames.Count -or @(Compare-Object $expectedNames @($parameterResults.test)).Count) { throw 'Schema probe returned incomplete results; do not infer duplicate behavior.' }
            if (@($parameterResults | Where-Object { -not $_.passed }).Count) { throw 'Schema duplicate-header gate failed; see sanitized results.' }
        } finally {
            $null = Invoke-ProbeArm DELETE $operationPath
            $remaining = Invoke-ProbeArm GET "$apiPath/operations"
            if (@($remaining.value | Where-Object name -eq $operationId).Count) { throw 'Disposable schema operation cleanup failed.' }
            [pscustomobject]@{ test = 'schema-operation-removed'; passed = $true } | ConvertTo-Json -Compress
        }
        return
    }
    if (-not $TestExisting) {
        $null = Invoke-ProbeArm PUT $apiPath @{ properties = @{ displayName = 'Isolated JWT authentication probe'; path = $ProbeId; protocols = @('https'); subscriptionRequired = $false; description = 'Temporary auth-only probe. No model backend. Existing APIs unchanged.' } }
        Write-Output "Created isolated API: $ProbeId"
        $null = Invoke-ProbeArm PUT "$apiPath/policies/policy" @{ properties = @{ format = 'rawxml'; value = $policy } }
        $null = Invoke-ProbeArm PUT "$apiPath/operations/check" @{ properties = @{ displayName = 'Validate JWT without inference'; method = 'GET'; urlTemplate = '/check'; responses = @() } }
        Write-Output 'APIM accepted the existing JWT validation block. No backend is configured.'
    }
    if ($AddValidationControls) {
        $operations = Invoke-ProbeArm GET "$apiPath/operations"
        foreach ($control in @('wrong-audience', 'wrong-scope')) {
            if (@($operations.value | Where-Object name -eq $control).Count) { throw 'Validation control already exists; refusing to overwrite it.' }
        }
        foreach ($control in @('wrong-audience', 'wrong-scope')) {
            $controlPolicy = if ($control -eq 'wrong-audience') {
                $policy.Replace('{{api-audience}}', 'api://jwt-probe-deliberately-wrong-audience')
            } else {
                $policy.Replace('{{required-scope}}', 'jwt.probe.deliberately.ungranted')
            }
            $null = Invoke-ProbeArm PUT "$apiPath/operations/$control" @{ properties = @{ displayName = "JWT rejection control: $control"; method = 'GET'; urlTemplate = "/$control"; responses = @() } }
            $null = Invoke-ProbeArm PUT "$apiPath/operations/$control/policies/policy" @{ properties = @{ format = 'rawxml'; value = $controlPolicy } }
        }
        Write-Output 'Added isolated wrong-audience and ungranted-scope validation controls.'
    }
    $admissionSecrets = $null
    if ($AdmissionProbe) {
        if (-not $IncludeUserToken) { throw 'Admission testing requires IncludeUserToken.' }
        $admissionPrefix = $ProbeId + '-admission-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
        $productId = $admissionPrefix + '-product'
        $productPath = "$serviceId/products/$productId"
        $productPolicy = '<policies><inbound><set-variable name="probeProductPolicy" value="@(true)" /><choose><when condition="@(context.Subscription.Id.EndsWith("-throttle"))"><rate-limit-by-key calls="3" renewal-period="300" counter-key="@(context.Subscription.Id + context.Api.Id)" /></when><when condition="@(context.Subscription.Id.EndsWith("-quota"))"><quota-by-key calls="3" renewal-period="3600" counter-key="@(context.Subscription.Id + context.Api.Id)" /></when></choose></inbound><backend /><outbound /><on-error /></policies>'
        $null = Invoke-ProbeArm PUT $productPath @{ properties = @{ displayName = "$admissionPrefix product"; subscriptionRequired = $true; approvalRequired = $false; state = 'published' } }
        $null = Invoke-ProbeArm PUT "$productPath/policies/policy" @{ properties = @{ format = 'rawxml'; value = $productPolicy } }
        $otherProductPath = "$serviceId/products/$admissionPrefix-other-product"
        $null = Invoke-ProbeArm PUT $otherProductPath @{ properties = @{ displayName = "$admissionPrefix unlinked product"; subscriptionRequired = $true; approvalRequired = $false; state = 'published' } }
        $admissionPolicy = @'
<policies><inbound><base />
<choose><when condition="@(context.Subscription == null)">
<choose><when condition="@(context.Request.Headers.GetValueOrDefault("Authorization", "").StartsWith("Bearer "))">
<set-header name="api-key" exists-action="override"><value>@(context.Request.Headers.GetValueOrDefault("Authorization", "").Substring(7))</value></set-header>
</when></choose>
__AUTH_BLOCK__
</when></choose>
<set-variable name="probeHasSubscription" value="@(context.Subscription != null)" />
<set-variable name="probeHasProduct" value="@(context.Product != null)" />
<set-header name="api-key" exists-action="delete" />
<set-header name="Authorization" exists-action="delete" />
<return-response><set-status code="200" reason="Isolated admission probe" />
<set-header name="X-Probe-Subscription" exists-action="override"><value>@(((bool)context.Variables["probeHasSubscription"]).ToString())</value></set-header>
<set-header name="X-Probe-Product" exists-action="override"><value>@(((bool)context.Variables["probeHasProduct"]).ToString())</value></set-header>
<set-header name="X-Probe-Product-Policy" exists-action="override"><value>@(context.Variables.ContainsKey("probeProductPolicy") ? "True" : "False")</value></set-header>
<set-body>{"probe":"admission-only","backendCalled":false}</set-body>
</return-response></inbound><backend /><outbound /><on-error>
<set-header name="X-Probe-Error" exists-action="override"><value>@(context.LastError.Reason)</value></set-header>
</on-error></policies>
'@.Replace('__AUTH_BLOCK__', $authBlock)
    if ($ProductContextGuard) {
        $guard = @'
<choose><when condition="@((context.Request.Headers.ContainsKey("api-key") &amp;&amp; context.Request.Headers.ContainsKey("Authorization")) || context.Request.OriginalUrl.Query.ContainsKey("api-key") || context.Request.Headers.ContainsKey("x-api-key") || context.Request.Headers.ContainsKey("Ocp-Apim-Subscription-Key"))">
<return-response><set-status code="401" reason="Ambiguous or unsupported credential source" /></return-response>
</when></choose>
<base />
<choose><when condition="@(context.Subscription != null &amp;&amp; (context.Product == null || !context.Variables.ContainsKey("probeProductPolicy")))">
<return-response><set-status code="401" reason="Subscription lacks authorized product context" /></return-response>
</when></choose>
'@
        $admissionPolicy = $admissionPolicy.Replace('<policies><inbound><base />', '<policies><inbound>' + $guard)
    }
        $admissionUrls = @{}
        $surfaceDefinitions = @()
        $modes = if ($OpenProductProbe) { @('required') } else { @('required', 'optional') }
        if ($OpenProductProbe) {
            $openProductId = "$admissionPrefix-open"
            $openProductPath = "$serviceId/products/$openProductId"
            $conflictGuard = @'
<choose><when condition="@((context.Request.Headers.ContainsKey("api-key") &amp;&amp; context.Request.Headers.ContainsKey("Authorization")) || context.Request.OriginalUrl.Query.ContainsKey("api-key") || context.Request.Headers.ContainsKey("x-api-key") || context.Request.Headers.ContainsKey("Ocp-Apim-Subscription-Key"))">
<return-response><set-status code="401" reason="Ambiguous or unsupported probe credential source" /></return-response>
</when></choose>
'@
            $admissionPolicy = $admissionPolicy.Replace('<policies><inbound><base />', '<policies><inbound>' + $conflictGuard)
            $admissionPolicy = $admissionPolicy.Replace('context.Subscription == null', 'context.Subscription == null || (context.Product != null &amp;&amp; context.Product.Id == "' + $openProductId + '")')
            $admissionPolicy = $admissionPolicy.Replace($authBlock, $authBlock + '<set-variable name="probeJwtValidated" value="@(true)" />')
            $admissionPolicy = $admissionPolicy.Replace('<set-variable name="probeHasSubscription"', '<base /><set-variable name="probeHasSubscription"')
            $contextHeader = '<set-header name="X-Probe-Context" exists-action="override"><value>@((context.Subscription != null ? "1" : "0") + (context.Product != null ? "1" : "0") + (context.Variables.ContainsKey("probeProductPolicy") ? "1" : "0") + (context.Variables.ContainsKey("probeJwtValidated") ? "1" : "0"))</value></set-header>'
            $admissionPolicy = $admissionPolicy.Replace('<set-body>{"probe":"admission-only"', $contextHeader + '<set-body>{"probe":"admission-only"')
            $admissionPolicy = $admissionPolicy.Replace('<on-error>', '<on-error>' + $contextHeader)
            if ($ExpandedGate) {
                $expandedConflict = @'
<choose><when condition="@{
    var headerKey = context.Request.Headers.ContainsKey("api-key");
    var bearer = context.Request.Headers.ContainsKey("Authorization");
    var queryKey = context.Request.OriginalUrl.Query.ContainsKey("api-key");
    var sourceCount = (headerKey ? 1 : 0) + (bearer ? 1 : 0) + (queryKey ? 1 : 0);
    var keyValue = context.Request.Headers.GetValueOrDefault("api-key", "");
    var authValue = context.Request.Headers.GetValueOrDefault("Authorization", "");
    var queryValue = context.Request.OriginalUrl.Query.GetValueOrDefault("api-key", "");
    return sourceCount != 1 || context.Request.Headers.ContainsKey("x-api-key") || context.Request.Headers.ContainsKey("Ocp-Apim-Subscription-Key") || context.Request.OriginalUrl.Query.ContainsKey("subscription-key")
        || (headerKey &amp;&amp; (context.Request.Headers["api-key"].Length != 1 || string.IsNullOrWhiteSpace(keyValue) || keyValue.Contains(",")))
        || (bearer &amp;&amp; (context.Request.Headers["Authorization"].Length != 1 || !authValue.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) || string.IsNullOrWhiteSpace(authValue.Substring(7)) || authValue.Contains(",")))
        || (queryKey &amp;&amp; (context.Request.OriginalUrl.Query["api-key"].Length != 1 || string.IsNullOrWhiteSpace(queryValue) || queryValue.Contains(",") || context.Subscription == null || (context.Product != null &amp;&amp; context.Product.Id == "__OPEN_PRODUCT__")));
}"><return-response><set-status code="401" reason="Invalid credential sources" />
<set-header name="X-Probe-Rejected-By" exists-action="override"><value>credential-source-guard</value></set-header>
<set-header name="X-Probe-Authorization-Count" exists-action="override"><value>@((context.Request.Headers.ContainsKey("Authorization") ? context.Request.Headers["Authorization"].Length : 0).ToString())</value></set-header>
<set-header name="X-Probe-Authorization-Combined" exists-action="override"><value>@(context.Request.Headers.GetValueOrDefault("Authorization", "").Contains(",").ToString())</value></set-header>
</return-response></when></choose>
'@.Replace('__OPEN_PRODUCT__', $openProductId)
                $identityGuard = @'
<choose><when condition="@(string.IsNullOrWhiteSpace(((Jwt)context.Variables["parsedJwt"]).Claims.GetValueOrDefault("tid", "")) || string.IsNullOrWhiteSpace(((Jwt)context.Variables["parsedJwt"]).Claims.GetValueOrDefault("oid", "")))">
<return-response><set-status code="401" reason="Missing stable identity" /></return-response>
</when></choose>
'@
                $admissionPolicy = $admissionPolicy.Replace($conflictGuard, $expandedConflict).Replace('.StartsWith("Bearer ")', '.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)')
                $admissionPolicy = $admissionPolicy.Replace('<claim name="scp" match="any">', '<claim name="scp" match="any" separator=" ">')
                $admissionPolicy = $admissionPolicy.Replace('<set-variable name="probeJwtValidated"', $identityGuard + '<set-variable name="probeJwtValidated"')
                $stripCheck = '<set-query-parameter name="api-key" exists-action="delete" /><set-variable name="probeStripped" value="@(!context.Request.Headers.ContainsKey("api-key") &amp;&amp; !context.Request.Headers.ContainsKey("Authorization") &amp;&amp; !context.Request.Url.Query.ContainsKey("api-key"))" />'
                $admissionPolicy = $admissionPolicy.Replace('<return-response><set-status code="200"', $stripCheck + '<return-response><set-status code="200"')
                $admissionPolicy = $admissionPolicy.Replace('<set-body>{"probe":"admission-only"', '<set-header name="X-Probe-Stripped" exists-action="override"><value>@(((bool)context.Variables["probeStripped"]).ToString())</value></set-header><set-body>{"probe":"admission-only"')
            }
            $null = Invoke-ProbeArm PUT $openProductPath @{ properties = @{ displayName = "$admissionPrefix JWT guarded open product"; subscriptionRequired = $false; state = 'notPublished' } }
            $openPolicy = '<policies><inbound><choose><when condition="@(!context.Variables.ContainsKey("probeJwtValidated"))"><return-response><set-status code="401" reason="JWT gate must run first" /></return-response></when></choose></inbound><backend /><outbound /><on-error /></policies>'
            $null = Invoke-ProbeArm PUT "$openProductPath/policies/policy" @{ properties = @{ format = 'rawxml'; value = $openPolicy } }
        }
        if ($BackendGate) {
            $backendNonce = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
            $admissionPolicy = $admissionPolicy.Replace('<policies><inbound>', '<policies><inbound><set-variable name="probeAuthorizationValueCount" value="@(context.Request.Headers.ContainsKey("Authorization") ? context.Request.Headers["Authorization"].Length : 0)" />')
            $contextHeader += '<set-header name="X-Probe-Authorization-Count" exists-action="override"><value>@(((int)context.Variables["probeAuthorizationValueCount"]).ToString())</value></set-header>'
            $forwarding = '<set-backend-service base-url="http://' + $BackendAddress + ':18741" /><rewrite-uri template="/' + $ProbeId + '/" copy-unmatched-params="true" /><set-header name="X-Probe-Backend-Nonce" exists-action="override"><value>' + $backendNonce + '</value></set-header>'
            $successPattern = '(?s)<return-response><set-status code="200".*?</return-response>'
            if ([regex]::Matches($admissionPolicy, $successPattern).Count -ne 1) { throw 'Expected exactly one success response to replace with the mock backend.' }
            $admissionPolicy = [regex]::Replace($admissionPolicy, $successPattern, [Text.RegularExpressions.MatchEvaluator]{ param($match) $forwarding })
            $admissionPolicy = $admissionPolicy.Replace('<backend />', '<backend><forward-request timeout="30" /></backend>').Replace('<outbound />', '<outbound>' + $contextHeader + '<set-header name="X-Probe-Stripped" exists-action="override"><value>@(((bool)context.Variables["probeStripped"]).ToString())</value></set-header></outbound>')
            if ($CredentialHeader -eq 'x-api-key') {
                $admissionPolicy = $admissionPolicy.Replace('Headers.ContainsKey("x-api-key")', 'Headers.ContainsKey("__OTHER_HEADER__")')
                foreach ($expression in @('Headers.ContainsKey("api-key")', 'Headers.GetValueOrDefault("api-key",', 'Headers["api-key"]', 'name="api-key" exists-action=')) {
                    $admissionPolicy = $admissionPolicy.Replace($expression, $expression.Replace('api-key', 'x-api-key'))
                }
                $admissionPolicy = $admissionPolicy.Replace('__OTHER_HEADER__', 'api-key').Replace('<set-query-parameter name="x-api-key"', '<set-query-parameter name="api-key"')
            }
        }
        foreach ($mode in $modes) {
            $admissionApiId = "$admissionPrefix-$mode"
            $admissionApiPath = "$serviceId/apis/$admissionApiId"
            $null = Invoke-ProbeArm PUT $admissionApiPath @{ properties = @{ displayName = "$admissionPrefix $mode"; path = $admissionApiId; protocols = @('https'); subscriptionRequired = ($mode -eq 'required'); subscriptionKeyParameterNames = @{ header = $CredentialHeader; query = 'api-key' } } }
            $null = Invoke-ProbeArm PUT "$admissionApiPath/policies/policy" @{ properties = @{ format = 'rawxml'; value = $admissionPolicy } }
            $null = Invoke-ProbeArm PUT "$admissionApiPath/operations/check" @{ properties = @{ displayName = 'Admission check'; method = 'GET'; urlTemplate = '/check'; responses = @() } }
            $null = Invoke-ProbeArm PUT "$productPath/apis/$admissionApiId" @{}
            $admissionUrls[$mode] = "$gateway/$admissionApiId/check"
            if ($OpenProductProbe) {
                $null = Invoke-ProbeArm PUT "$admissionApiPath/operations/explicit" @{ properties = @{ displayName = 'Explicit auth without inheritance'; method = 'GET'; urlTemplate = '/explicit'; responses = @() } }
                $null = Invoke-ProbeArm PUT "$admissionApiPath/operations/explicit/policies/policy" @{ properties = @{ format = 'rawxml'; value = $admissionPolicy.Replace('<base />', '') } }
                $admissionUrls.inherited = "$gateway/$admissionApiId/check"
                $admissionUrls.explicit = "$gateway/$admissionApiId/explicit"
                if ($ExpandedGate) {
                    foreach ($surface in @('inherited', 'explicit')) {
                        $surfacePolicy = $admissionPolicy.Replace('<base />', '')
                        foreach ($control in @('audience', 'scope', 'issuer', 'identity', 'jwt-limit')) {
                            $controlPolicy = switch ($control) {
                                'audience' { $surfacePolicy.Replace('{{api-audience}}', 'api://probe-wrong-audience') }
                                'scope' { $surfacePolicy.Replace('{{required-scope}}', 'probe.ungranted') }
                                'issuer' { $surfacePolicy.Replace('<required-claims>', '<required-claims><claim name="iss" match="all"><value>https://invalid.example/probe-issuer</value></claim>') }
                                'identity' { $surfacePolicy.Replace('GetValueOrDefault("oid", "")', 'GetValueOrDefault("probe_deliberately_missing_identity", "")') }
                                'jwt-limit' { $surfacePolicy.Replace('<set-variable name="probeHasSubscription"', '<choose><when condition="@(context.Variables.ContainsKey("probeJwtValidated"))"><rate-limit-by-key calls="3" renewal-period="300" counter-key="@(((Jwt)context.Variables["parsedJwt"]).Issuer + ((Jwt)context.Variables["parsedJwt"]).Claims.GetValueOrDefault("tid", "") + ((Jwt)context.Variables["parsedJwt"]).Claims.GetValueOrDefault("oid", "") + context.Api.Id + context.Operation.Id)" /></when></choose><set-variable name="probeHasSubscription"') }
                            }
                            $controlId = "$surface-$control"
                            $null = Invoke-ProbeArm PUT "$admissionApiPath/operations/$controlId" @{ properties = @{ displayName = "Isolated $controlId control"; method = 'GET'; urlTemplate = "/$controlId"; responses = @() } }
                            $null = Invoke-ProbeArm PUT "$admissionApiPath/operations/$controlId/policies/policy" @{ properties = @{ format = 'rawxml'; value = $controlPolicy } }
                            $admissionUrls[$controlId] = "$gateway/$admissionApiId/$controlId"
                        }
                        if ($SecondUserToken) {
                            foreach ($limiter in @('rate', 'quota')) {
                                $counter = '@("probe-' + $surface + '-' + $limiter + ':" + context.Api.Id + ":" + ((Jwt)context.Variables["parsedJwt"]).Issuer + ":" + ((Jwt)context.Variables["parsedJwt"]).Claims.GetValueOrDefault("tid", "") + ":" + ((Jwt)context.Variables["parsedJwt"]).Claims.GetValueOrDefault("oid", ""))'
                                $limitPolicy = if ($limiter -eq 'rate') { '<rate-limit-by-key calls="3" renewal-period="300" counter-key="' + $counter + '" />' } else { '<quota-by-key calls="3" renewal-period="3600" counter-key="' + $counter + '" />' }
                                $isolationPolicy = $surfacePolicy.Replace('<set-variable name="probeHasSubscription"', '<choose><when condition="@(context.Variables.ContainsKey("probeJwtValidated"))">' + $limitPolicy + '</when></choose><set-variable name="probeHasSubscription"')
                                foreach ($alias in @('primary', 'alias')) {
                                    $controlId = "$surface-isolation-$limiter-$alias"
                                    $null = Invoke-ProbeArm PUT "$admissionApiPath/operations/$controlId" @{ properties = @{ displayName = "Isolated $controlId control"; method = 'GET'; urlTemplate = "/$controlId"; responses = @() } }
                                    $null = Invoke-ProbeArm PUT "$admissionApiPath/operations/$controlId/policies/policy" @{ properties = @{ format = 'rawxml'; value = $isolationPolicy } }
                                    $admissionUrls[$controlId] = "$gateway/$admissionApiId/$controlId"
                                }
                            }
                        }
                    }
                }
                if ($BackendGate) {
                    $sourceApiName = if ($CredentialHeader -eq 'x-api-key') { 'copilot-byok-anthropic' } else { 'copilot-byok-foundry' }
                    $sourceOperations = Invoke-ProbeArm GET "$serviceId/apis/$sourceApiName/operations"
                    foreach ($operation in $sourceOperations.value) {
                        $operationId = 'surface-' + $operation.name
                        $operationPath = "$admissionApiPath/operations/$operationId"
                        $properties = @{ displayName = "Probe surface $($operation.name)"; method = $operation.properties.method; urlTemplate = $operation.properties.urlTemplate; templateParameters = @($operation.properties.templateParameters) }
                        $null = Invoke-ProbeArm PUT $operationPath @{ properties = $properties }
                        $noBase = $operation.name -in @('list-models', 'responses-get', 'responses-delete', 'responses-cancel', 'responses-input-items')
                        if ($noBase) {
                            $sourcePolicy = Invoke-ProbeArm GET "$serviceId/apis/$sourceApiName/operations/$($operation.name)/policies/policy"
                            $inbound = [regex]::Match($sourcePolicy.properties.value, '(?s)<inbound>(.*?)</inbound>').Groups[1].Value
                            $inbound = [regex]::Replace($inbound, '(?s)<!--.*?-->', '')
                            if (-not $inbound -or $inbound -match '<base\s*/>') { throw 'Source operation inheritance differs from the expected no-base contract.' }
                            $null = Invoke-ProbeArm PUT "$operationPath/policies/policy" @{ properties = @{ format = 'rawxml'; value = $admissionPolicy.Replace('<base />', '') } }
                        }
                        $testPath = [regex]::Replace($operation.properties.urlTemplate, '\{[^}]+\}', 'probe-fixture')
                        $surfaceDefinitions += @{ name = $operation.name; method = $operation.properties.method; uri = "$gateway/$admissionApiId$testPath"; noBase = $noBase }
                    }
                }
                $null = Invoke-ProbeArm PUT "$openProductPath/apis/$admissionApiId" @{}
            }
        }
        $admissionSecrets = @{ urls = $admissionUrls; keys = @{}; openProduct = [bool]$OpenProductProbe; expanded = [bool]$ExpandedGate; backendGate = [bool]$BackendGate; http2Gate = [bool]$Http2Gate; credentialHeader = $CredentialHeader; surfaces = $surfaceDefinitions }
        if ($BackendGate) { $admissionSecrets.backend = @{ address = $BackendAddress; sourcePrefix = $ApimSourcePrefix; nonce = $backendNonce } }
        if ($ProductionPipelineGate) {
            $admissionSecrets.pipeline = @{}
            $diagnostics = Invoke-ProbeArm GET "$serviceId/apis/copilot-byok-foundry/diagnostics"
            if (-not @($diagnostics.value).Count) { $diagnostics = Invoke-ProbeArm GET "$serviceId/diagnostics" }
            $logger = @($diagnostics.value | Where-Object { $_.properties.loggerId -and $_.name -eq 'applicationinsights' })
            if ($logger.Count -ne 1) { throw 'Production pipeline fixture requires one existing Application Insights diagnostic logger.' }
            foreach ($mode in @('baseline', 'rpm', 'tpm', 'quota')) {
                $pipelineId = "$admissionPrefix-pipeline-$mode"
                $pipelinePath = "$serviceId/apis/$pipelineId"
                $pipelinePolicy = New-ProbeProductionPipeline $source $mode $admissionPrefix $BackendAddress $backendNonce $ProbeId
                $null = Invoke-ProbeArm PUT $pipelinePath @{ properties = @{ displayName = "$admissionPrefix production pipeline $mode"; path = $pipelineId; protocols = @('https'); subscriptionRequired = $false; description = 'Disposable JWT-mode production pipeline fixture. Private mock only; isolated counters and metric namespace.' } }
                $null = Invoke-ProbeArm PUT "$pipelinePath/policies/policy" @{ properties = @{ format = 'rawxml'; value = $pipelinePolicy } }
                $admissionSecrets.pipeline[$mode] = @{}
                foreach ($operation in @(@{ name = 'primary'; path = '/v1/chat/completions' }, @{ name = 'alias'; path = '/alias/chat/completions' }, @{ name = 'responses'; path = '/v1/responses' })) {
                    $null = Invoke-ProbeArm PUT "$pipelinePath/operations/$($operation.name)" @{ properties = @{ displayName = "Pipeline $($operation.name)"; method = 'POST'; urlTemplate = $operation.path; responses = @() } }
                    $admissionSecrets.pipeline[$mode][$operation.name] = "$gateway/$pipelineId$($operation.path)"
                }
                $emptyMessageLog = @{ headers = @(); body = @{ bytes = 0 } }
                $null = Invoke-ProbeArm PUT "$pipelinePath/diagnostics/applicationinsights" @{ properties = @{
                    loggerId = $logger[0].properties.loggerId
                    alwaysLog = 'allErrors'
                    sampling = @{ samplingType = 'fixed'; percentage = 100 }
                    logClientIp = $false
                    metrics = $true
                    frontend = @{ request = $emptyMessageLog; response = $emptyMessageLog }
                    backend = @{ request = $emptyMessageLog; response = $emptyMessageLog }
                } }
            }
        }
        $kinds = if ($OpenProductProbe) { @('active', 'wrongScope', 'wrongProduct', 'apiRequired', 'allApis') } else { @('active', 'suspended', 'wrongScope', 'wrongProduct', 'rotated', 'throttle', 'apiRequired', 'apiOptional', 'allApis') }
        if ($ExpandedGate) { $kinds += @('suspended', 'rotated', 'throttle', 'other-throttle') }
        if ($BackendGate) { $kinds += @('quota', 'other-quota') }
        foreach ($kind in $kinds) {
            $subscriptionPath = "$serviceId/subscriptions/$admissionPrefix-$kind"
            $primary = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
            $secondary = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
            $subscriptionScope = if ($kind -eq 'wrongScope') { "$serviceId/apis/$ProbeId" } else { $productPath }
            if ($kind -eq 'wrongProduct') { $subscriptionScope = $otherProductPath }
            if ($kind -eq 'apiRequired') { $subscriptionScope = "$serviceId/apis/$admissionPrefix-required" }
            if ($kind -eq 'apiOptional') { $subscriptionScope = "$serviceId/apis/$admissionPrefix-optional" }
            if ($kind -eq 'allApis') { $subscriptionScope = "$serviceId/apis" }
            $subscriptionState = if ($kind -eq 'suspended') { 'suspended' } else { 'active' }
            $null = Invoke-ProbeArm PUT $subscriptionPath @{ properties = @{ displayName = "$admissionPrefix $kind"; scope = $subscriptionScope; state = $subscriptionState; primaryKey = $primary; secondaryKey = $secondary } }
            $admissionSecrets.keys[$kind] = $primary
            if ($kind -eq 'active') { $admissionSecrets.keys.secondary = $secondary }
            if ($kind -eq 'rotated') {
                $admissionSecrets.keys.rotatedOld = $primary
                $newPrimary = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
                $null = Invoke-ProbeArm PATCH $subscriptionPath @{ properties = @{ primaryKey = $newPrimary } }
                $admissionSecrets.keys.rotated = $newPrimary
            }
        }
        Write-Output "Created isolated admission resources: $admissionPrefix"
    }
    $vmParameters = @("GatewayUri=$gateway/$ProbeId/check", "ArmResource=$($cloudInfo.endpoints.activeDirectoryResourceId)", "ProbeId=$ProbeId")
    $operations = Invoke-ProbeArm GET "$apiPath/operations"
    if (@($operations.value | Where-Object { $_.name -in @('wrong-audience', 'wrong-scope') }).Count -eq 2) {
        $vmParameters += 'ValidationControls=true'
    }
    if ($IncludeUserToken) {
        $appUri = Invoke-ProbeArm GET "$serviceId/namedValues/api-app-id-uri"
        $scope = $appUri.properties.value.TrimEnd('/') + '/.default'
        $userRaw = & az account get-access-token --scope $scope -o json --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Gateway-scoped user token unavailable; sign in securely in the pinned terminal.' }
        $userCredential = $userRaw | ConvertFrom-Json
        if ($SecondUserToken) {
            $secondPlaintext = ConvertFrom-SecureString $SecondUserToken -AsPlainText
            $identities = @(foreach ($tokenText in @($userCredential.accessToken, $secondPlaintext)) {
                $encoded = $tokenText.Split('.')[1].Replace('-', '+').Replace('_', '/')
                $encoded = $encoded.PadRight($encoded.Length + ((4 - $encoded.Length % 4) % 4), '=')
                $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
                if (-not $claims.tid -or -not $claims.oid -or -not $claims.scp -or [DateTimeOffset]::FromUnixTimeSeconds([long]$claims.exp) -lt [DateTimeOffset]::UtcNow.AddMinutes(15)) { throw 'Two-user fixtures require delegated identity claims and at least fifteen minutes remaining.' }
                [pscustomobject]@{ tenant = $claims.tid; subject = $claims.oid }
            })
            if ($identities[0].tenant -ne $identities[1].tenant -or $identities[0].subject -eq $identities[1].subject) { throw 'Two-user fixture requires distinct users in the same tenant; gateway validation still determines trust.' }
            $admissionSecrets.secondUserToken = $secondPlaintext
            $secondPlaintext = $null
            $claims = $null
            $tokenText = $null
        }
        $publicResult = @(Invoke-ProbeVm -Parameters @('Phase=Prepare', "ArmResource=$($cloudInfo.endpoints.activeDirectoryResourceId)", "ProbeId=$ProbeId"))
        $publicMaterial = @($publicResult | Where-Object test -eq 'transport-certificate')
        if ($publicMaterial.Count -ne 1) { throw 'VM certificate preparation failed. No user token was sent.' }
        $certificatePrepared = $true
        $publicCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($publicMaterial[0].publicCertificate))
        if ($admissionSecrets) {
            $admissionSecrets.userToken = $userCredential.accessToken
            $encrypted = Protect-CmsMessage -To $publicCertificate -Content ($admissionSecrets | ConvertTo-Json -Depth 10 -Compress)
            $vmParameters += 'AdmissionPayload=true'
        } else {
            $encrypted = Protect-CmsMessage -To $publicCertificate -Content $userCredential.accessToken
        }
        $vmParameters += 'ProtectedToken=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($encrypted))
        if ($ExpiredUserToken) {
            $encryptedExpiry = Protect-CmsMessage -To $publicCertificate -Content $expiredPlaintext
            $vmParameters += 'ProtectedExpiredToken=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($encryptedExpiry))
        }
        $userCredential = $null
        $userRaw = $null
    }
    $testResults = @(Invoke-ProbeVm -Parameters $vmParameters)
    $certificateRemoved = @($testResults | Where-Object { $_.test -eq 'temporary-transport-certificate-removed' -and $_.passed }).Count -eq 1
    $testResults | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }
    if ($testResults.Count -lt 6) { throw "VM returned incomplete probe results. Probe API $ProbeId remains; inspect sanitized VM diagnostics." }
    $requiredTests = @('missing-credential', 'malformed-token', 'bearer-only-current-contract')
    if ($AdmissionProbe) { $requiredTests += 'admission-acceptance-contract' }
    if ($IncludeUserToken) { $requiredTests += @('valid-delegated-user-token-and-credential-stripping', 'tampered-signature', 'temporary-transport-certificate-removed') }
    if ($ExpiredUserToken) { $requiredTests += 'expired-signed-user-token' }
    if ($BackendGate) { $requiredTests += @('mock-listener-and-firewall-removed', 'final-backend-receipt-audit') }
    if ($ProductionPipelineGate) { $requiredTests += @('production-pipeline-summary', 'production-pipeline-receipt-audit') }
    if ($Http2Gate) { $requiredTests += 'temporary-http2-client-removed' }
    foreach ($testName in $requiredTests) {
        $matchingResults = @($testResults | Where-Object test -eq $testName)
        if ($matchingResults.Count -ne 1 -or $matchingResults[0].passed -ne $true) { throw "Required probe assertion missing or failed: $testName" }
    }
    if ($AdmissionProbe) {
        $acceptance = @($testResults | Where-Object test -eq 'admission-acceptance-contract')
        if ($acceptance.Count -ne 1 -or $acceptance[0].contract -cne 'single-credential-v1') { throw 'Admission results do not identify the approved acceptance contract.' }
        $matrix = @($testResults | Where-Object test -eq 'native-admission-observations')
        $expandedCases = @('secondary', 'suspended', 'rotated-old', 'rotated-new', 'invalid', 'empty', 'empty-bearer', 'key-plus-jwt', 'invalid-plus-jwt', 'jwt-plus-jwt', 'duplicate-key', 'duplicate-bearer', 'wire-duplicate-key', 'wire-duplicate-bearer', 'wire-mixed-case-key', 'token-shaped-key', 'query-key', 'query-jwt', 'query-conflict', 'duplicate-query', 'tampered', 'expired', 'audience', 'scope', 'issuer', 'identity', 'limit-1', 'limit-2', 'limit-3', 'limit-4', 'limit-isolated', 'jwt-limit-1', 'jwt-limit-2', 'jwt-limit-3', 'jwt-limit-4')
        $surfaceCases = @('key', 'api-scoped', 'all-apis', 'jwt', 'missing', 'invalid', 'wrong-scope', 'conflict')
        $expandedCases += @('wire-duplicate-bearer-case', 'wire-duplicate-expired', 'wire-duplicate-tampered')
        if ($Http2Gate) { $expandedCases += @('h2-wire-duplicate-key', 'h2-wire-duplicate-bearer', 'h2-wire-duplicate-bearer-case', 'h2-wire-duplicate-expired', 'h2-wire-duplicate-tampered', 'h2-wire-mixed-case-key', 'h2-wire-bearer-valid-first', 'h2-wire-bearer-valid-last', 'h2-key', 'h2-jwt', 'h2-missing', 'h2-conflict', 'h2-combined-bearer') }
        if ($SecondUserToken) {
            $expandedCases += @('wire-single-key', 'wire-single-bearer', 'wire-single-second-bearer', 'wire-two-users-first', 'wire-two-users-last')
            if ($Http2Gate) { $expandedCases += @('h2-wire-two-users-first', 'h2-wire-two-users-last') }
            $expandedCases += @(foreach ($limiter in @('rate', 'quota')) { foreach ($caseName in @('conflict', 'first-1', 'first-2', 'first-3', 'first-4', 'second-1', 'second-2', 'second-3', 'second-4', 'first-still-blocked')) { "isolation-$limiter-$caseName" } })
        }
        $expectedCount = if ($ExpandedGate) { 16 + 2 * $expandedCases.Count } elseif ($OpenProductProbe) { 16 } else { 40 }
        if ($BackendGate) { $expectedCount += $surfaceDefinitions.Count * $surfaceCases.Count + 16 }
        $pipelineExpectedNames = @()
        if ($ProductionPipelineGate) {
            $pipelineExpectedNames = @('pipeline-normal-first', 'pipeline-normal-second', 'pipeline-reasoning', 'pipeline-chat-stream', 'pipeline-responses', 'pipeline-responses-stream', 'pipeline-auto-short', 'pipeline-missing', 'pipeline-expired', 'pipeline-tampered', 'pipeline-missing-model')
            foreach ($mode in @('rpm', 'quota')) {
                $lastAttempt = if ($mode -eq 'rpm') { 5 } else { 4 }
                foreach ($principal in @('first', 'second')) { foreach ($attempt in 1..$lastAttempt) { $pipelineExpectedNames += "pipeline-$mode-$principal-$attempt" } }
            }
            foreach ($principal in @('first', 'second')) { foreach ($attempt in 1..2) { $pipelineExpectedNames += "pipeline-tpm-$principal-$attempt" } }
            $expectedCount += $pipelineExpectedNames.Count
        }
        if ($matrix.Count -ne 1 -or @($matrix[0].results).Count -ne $expectedCount) { throw 'Incomplete native admission matrix; do not infer coexistence readiness.' }
        if ($OpenProductProbe) {
            $expectedNames = @(foreach ($surface in @('i', 'e')) { foreach ($caseName in @('active', 'api-scoped', 'all-apis', 'jwt-api-key', 'jwt-bearer', 'wrong-scope', 'wrong-product', 'missing')) { "$surface-$caseName" } })
            if ($ExpandedGate) { $expectedNames += @(foreach ($surface in @('i', 'e')) { foreach ($caseName in $expandedCases) { "$surface-$caseName" } }) }
            if ($BackendGate) { $expectedNames += @(foreach ($surface in $surfaceDefinitions) { foreach ($caseName in $surfaceCases) { "surface-$($surface.name)-$caseName" } }) }
            if ($BackendGate) { $expectedNames += @(foreach ($surface in @('i', 'e')) { foreach ($caseName in @('quota-conflict', 'quota-1', 'quota-2', 'quota-3', 'quota-4', 'quota-isolated', 'wire-bearer-valid-first', 'wire-bearer-valid-last')) { "$surface-$caseName" } }) }
            $expectedNames += $pipelineExpectedNames
            if (Compare-Object ($expectedNames | Sort-Object) (@($matrix[0].results.case) | Sort-Object)) { throw 'Open-product matrix case names do not match the required gate.' }
        }
        $failures = @($matrix[0].results | Where-Object { -not $_.passed })
        if ($failures.Count) {
            if ($OpenProductProbe) { throw ('Open-product admission gate failed: ' + ($failures.case -join ', ')) }
            Write-Warning ('Native admission contract NOT satisfied: ' + (($failures | ForEach-Object { $_.case }) -join ', '))
        }
    }
    if (@($testResults | Where-Object { $_.passed -eq $false }).Count) { throw 'One or more probe assertions failed; do not infer authentication readiness.' }
    if ($AssociationGate) {
        $nativeLink = "$productPath/apis/$admissionApiId"
        $openLink = "$openProductPath/apis/$admissionApiId"
        $stages = @(
            @{ name = 'native-unlinked'; method = 'DELETE'; path = $nativeLink; native = $false; open = $true },
            @{ name = 'native-restored'; method = 'PUT'; path = $nativeLink; native = $true; open = $true },
            @{ name = 'open-unlinked'; method = 'DELETE'; path = $openLink; native = $true; open = $false },
            @{ name = 'open-restored'; method = 'PUT'; path = $openLink; native = $true; open = $true },
            @{ name = 'rollback'; method = 'DELETE'; path = $openLink; native = $true; open = $false }
        )
        try {
            foreach ($stage in $stages) {
                $userRaw = & az account get-access-token --scope $scope -o json --only-show-errors 2>$null
                if ($LASTEXITCODE -ne 0) { throw 'Association user token renewal failed.' }
                $userCredential = $userRaw | ConvertFrom-Json
                if (-not $userCredential.accessToken) { throw 'Association user token renewal returned no token.' }
                $admissionSecrets.userToken = $userCredential.accessToken
                $userCredential = $null
                $userRaw = $null
                $null = Invoke-ProbeArm $stage.method $stage.path $(if ($stage.method -eq 'PUT') { @{} } else { $null })
                foreach ($link in @(@{ product = $productPath; expected = $stage.native }, @{ product = $openProductPath; expected = $stage.open })) {
                    $linkedApis = Invoke-ProbeArm GET "$($link.product)/apis"
                    if ((@($linkedApis.value | Where-Object name -eq $admissionApiId).Count -eq 1) -ne $link.expected) { throw 'Product association readback differs from requested state.' }
                }
                $publicResult = @(Invoke-ProbeVm -Parameters @('Phase=Prepare', "ArmResource=$($cloudInfo.endpoints.activeDirectoryResourceId)", "ProbeId=$ProbeId"))
                $publicMaterial = @($publicResult | Where-Object test -eq 'transport-certificate')
                if ($publicMaterial.Count -ne 1) { throw 'Association certificate preparation failed.' }
                $certificateRemoved = $false
                $publicCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($publicMaterial[0].publicCertificate))
                $payload = @{ stage = $stage.name; nativeLinked = $stage.native; openLinked = $stage.open; keys = $admissionSecrets.keys; urls = $admissionSecrets.urls; userToken = $admissionSecrets.userToken }
                $encrypted = Protect-CmsMessage -To $publicCertificate -Content ($payload | ConvertTo-Json -Depth 10 -Compress)
                $stageResults = @(Invoke-ProbeVm -Parameters @('Phase=AssociationTest', "ProbeId=$ProbeId", "GatewayUri=$gateway/$ProbeId/check", "ArmResource=$($cloudInfo.endpoints.activeDirectoryResourceId)", ('ProtectedToken=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($encrypted)))))
                $certificateRemoved = @($stageResults | Where-Object { $_.test -eq 'temporary-transport-certificate-removed' -and $_.passed }).Count -eq 1
                $stageResults | ForEach-Object { $_ | ConvertTo-Json -Compress }
                $expectedNames = @(foreach ($surface in @('inherited', 'explicit')) { foreach ($kind in @('product-key', 'api-key', 'all-apis', 'jwt', 'missing')) { "association-$($stage.name)-$surface-$kind" } }) + @('temporary-transport-certificate-removed')
                if ($stageResults.Count -ne 11 -or @(Compare-Object $expectedNames @($stageResults.test)).Count -or @($stageResults | Where-Object { -not $_.passed }).Count) { throw 'Association propagation gate failed or returned incomplete evidence.' }
            }
        } finally {
            $null = Invoke-ProbeArm DELETE $openLink
            $null = Invoke-ProbeArm PUT $nativeLink @{}
            $openApis = Invoke-ProbeArm GET "$openProductPath/apis"
            $nativeApis = Invoke-ProbeArm GET "$productPath/apis"
            if (@($openApis.value | Where-Object name -eq $admissionApiId).Count -or @($nativeApis.value | Where-Object name -eq $admissionApiId).Count -ne 1) { throw 'Association rollback state not verified.' }
            [pscustomobject]@{ test = 'association-rollback-state'; openProductUnlinked = $true; nativeProductLinked = $true; passed = $true } | ConvertTo-Json -Compress
        }
    }
    Write-Output "Probe retained for follow-up: $ProbeId. Existing APIs unchanged."
} finally {
    if ($certificatePrepared -and -not $certificateRemoved) {
        $cleanup = @(Invoke-ProbeVm -Parameters @('Phase=Cleanup', "ArmResource=$($cloudInfo.endpoints.activeDirectoryResourceId)", "ProbeId=$ProbeId"))
        $cleanup | ForEach-Object { $_ | ConvertTo-Json -Compress }
    }
    $armHeaders.Clear()
    $armCredential = $null
    $tokenRaw = $null
    $userRaw = $null
    $userCredential = $null
    $admissionSecrets = $null
    $primary = $null
    $secondary = $null
    $newPrimary = $null
    $expiredPlaintext = $null
    $encodedClaims = $null
    $expiryClaims = $null
}