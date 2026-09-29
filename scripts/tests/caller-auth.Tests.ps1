#requires -Version 7.0
[CmdletBinding()]
param([string] $CompiledTemplatePath, [string] $CompiledMainTemplatePath, [string] $CompiledFoundryTemplatePath, [string] $CompiledOwnershipTemplatePath, [string] $CompiledAoaiTemplatePath, [string] $RenderedConsumerPolicyPath, [string] $CallerPackagePath, [string[]] $CompiledTierEntryTemplatePaths, [switch] $CheckProvisionGuards)

$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '../..'
if ($CallerPackagePath) {
  $upgradeErrors = $null
  $upgradeAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/update-caller-auth.ps1'), [ref]$null, [ref]$upgradeErrors)
  if ($upgradeErrors.Count) { throw 'Caller upgrade helper does not parse.' }
  $upgradeFunction = @($upgradeAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-CallerUpgradePolicies' }, $false))
  if ($upgradeFunction.Count -ne 1) { throw 'Expected one wizard composition function.' }
  . ([scriptblock]::Create($upgradeFunction[0].Extent.Text))
  foreach($name in @('Get-CallerUpgradeOperations','New-CallerUpgradePrivateDirectory')) {
    $definition=@($upgradeAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$false))
    if($definition.Count -ne 1){throw 'Expected one caller upgrade preflight helper.'}
    . ([scriptblock]::Create($definition[0].Extent.Text))
  }
  $package = (Get-Content -LiteralPath $CallerPackagePath -Raw | ConvertFrom-Json -Depth 100).parameters.callerPackage.value
  if ($package.tiering.version -ne 1 -or
      [regex]::Matches($package.tiering.branchTemplate, '__BYOK_TIER_NAME__').Count -ne 1 -or
      [regex]::Matches($package.tiering.policyTemplate, '__BYOK_JWT_TIERING_CONFIG__').Count -ne 1 -or
      [regex]::Matches($package.tiering.policyTemplate, '__BYOK_JWT_TIER_BRANCHES__').Count -ne 1) { throw 'Caller package is missing its versioned canonical tier templates.' }
  $models = Get-Content -Raw (Join-Path $root 'policies/wizard-foundry-policy-basic-models.xml')
  $wizardCases = 0
  foreach ($profile in @('foundry-policy-basic','foundry-policy-fixed','aoai-policy-fixed')) {
    $baseline = Get-Content -Raw (Join-Path $root ('policies/wizard-'+$profile+'.xml'))
    foreach ($backendMode in @('managedIdentity','apiKey')) {
      foreach ($nativeRequired in @($true,$false)) {
        foreach ($backendPath in @('','/openai')) {
          $bound = New-CallerUpgradePolicies -Inference $baseline -Models $models -Package $package -Prefix 'fixture-' -KeyEnabled $nativeRequired -BackendId 'fixture-backend' -Audience 'https://cognitiveservices.azure.us' -ResponsesId 'fixture-responses' -BackendPath $backendPath -BackendAuth $backendMode
          $authenticationOffset = $bound.inference.IndexOf('fragment-id="fixture-byok-authenticate"', [StringComparison]::Ordinal)
          $baseOffset = $bound.inference.IndexOf('<base />', [StringComparison]::Ordinal)
          $limitsOffset = $bound.inference.IndexOf('fragment-id="fixture-byok-apply-caller-limits"', [StringComparison]::Ordinal)
          $stripOffset = $bound.inference.IndexOf('fragment-id="fixture-byok-strip-caller-credentials"', [StringComparison]::Ordinal)
          $ownerOffset = $bound.inference.IndexOf('fragment-id="fixture-byok-prepare-responses-request"', [StringComparison]::Ordinal)
          $backendOffset = $bound.inference.IndexOf('<set-backend-service', [StringComparison]::Ordinal)
          if ($authenticationOffset -lt 0 -or $baseOffset -lt $authenticationOffset -or $limitsOffset -lt $baseOffset -or $stripOffset -lt $limitsOffset -or $ownerOffset -lt $stripOffset -or $backendOffset -lt $ownerOffset) { throw 'Wizard auth/accounting/ownership order mismatch.' }
          $credential = if ($backendMode -eq 'managedIdentity') { '<authentication-managed-identity resource="https://cognitiveservices.azure.us" />' } else { '<set-header name="api-key" exists-action="override"><value>{{fixture-foundry-api-key}}</value></set-header>' }
          if (-not $bound.inference.Contains($credential) -or -not $bound.models.Contains($credential)) { throw 'Wizard inference/discovery backend credential mismatch.' }
          if (-not $bound.inference.Contains('callerAuthMethod&quot;] == &quot;subscriptionKey&quot;') -or -not $bound.inference.Contains('context.Operation.Id == &quot;fixture-responses&quot;') -or -not $bound.inference.Contains('copilot_byok_caller_throttled') -or -not $bound.inference.Contains('byokDeferredAnthropic') -or -not $bound.inference.Contains('Response continuation requires its original backend')) { throw 'Wizard native limits, configured Responses ownership, Anthropic deferral or telemetry missing.' }
          foreach ($policy in $bound.Values) {
            if ($policy -match 'intellij-|__NATIVE_SUBSCRIPTION_REQUIRED__|REPLACE-WITH-YOUR-' -or [regex]::Matches($policy, 'fragment-id="fixture-byok-authenticate"').Count -ne 1) { throw 'Wizard namespace, placeholders or authentication multiplicity mismatch.' }
          }
          [xml]$utility = $bound.responses
          [xml]$discovery = $bound.models
          if ($utility.SelectNodes('/policies/inbound/base').Count -or $discovery.SelectNodes('/policies/inbound/base').Count -or $discovery.SelectNodes('/policies/inbound//set-body').Count -ne 1) { throw 'Bodyless wizard policy inheritance changed.' }
          $rewrite = $utility.SelectSingleNode('/policies/inbound/rewrite-uri').GetAttribute('template')
          $expectedPath = if ($backendPath -eq '/openai') { '"/v1/responses/"' } else { '"/openai/v1/responses/"' }
          if (-not $rewrite.Contains($expectedPath)) { throw 'Stored Responses backend path mismatch.' }
          $wizardCases++
        }
      }
    }
  }
  Write-Output "PASS: $wizardCases wizard composition cases preserve admission, separate backend credentials, bodyless policies and configured Responses paths."
  foreach($case in @('baseline','existing-utilities','inherit','uncovered','override','missing-models','wrong-response','name-collision')) {
    $operations=@(
      [pscustomobject]@{name='models';method='GET';urlTemplate='/v1/models';policy=''},
      [pscustomobject]@{name='responses';method='POST';urlTemplate='/v1/responses';policy=''},
      [pscustomobject]@{name='chat';method='POST';urlTemplate='/v1/chat/completions';policy=''}
    )
    switch($case) {
      'existing-utilities'{$operations+=[pscustomobject]@{name='existing-cancel';method='POST';urlTemplate='/v1/responses/{response_id}/cancel';policy=''}}
      'inherit'{$operations[2].policy='<policies><inbound><base /></inbound></policies>'}
      'uncovered'{$operations+=[pscustomobject]@{name='uncovered';method='GET';urlTemplate='/v1/conversations';policy=''}}
      'override'{$operations[2].policy='<policies><inbound /></policies>'}
      'missing-models'{$operations=$operations[1..2]}
      'wrong-response'{$operations[1].urlTemplate='/responses'}
      'name-collision'{$operations[2].name='responses-cancel'}
    }
    $failed=$false
    try{$definitions=@(Get-CallerUpgradeOperations -Operations $operations -ModelsId 'models' -ResponsesId 'responses')}catch{$failed=$true}
    if($failed -ne ($case -in @('uncovered','override','missing-models','wrong-response','name-collision'))){throw "Wizard operation preflight mismatch: $case"}
    if($case -eq 'existing-utilities' -and $definitions[2].name -cne 'existing-cancel'){throw 'Existing utility operation ID was not retained.'}
  }
  $privateDirectory=Join-Path ([IO.Path]::GetTempPath()) ('caller-upgrade-permissions-'+[guid]::NewGuid().ToString('N'))
  try {
    New-CallerUpgradePrivateDirectory -Path $privateDirectory
    if($IsWindows) {
      $security=Get-Acl -LiteralPath $privateDirectory
      if(-not $security.AreAccessRulesProtected -or $security.Access.Count -ne 1 -or $security.Access[0].IsInherited){throw 'Temporary caller parameter directory is not private.'}
    } elseif([IO.File]::GetUnixFileMode($privateDirectory) -ne ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)){throw 'Temporary caller directory must have mode 0700.'}
  } finally {if(Test-Path -LiteralPath $privateDirectory){Remove-Item -LiteralPath $privateDirectory -Force}}
  Write-Output 'PASS: eight wizard operation-inventory gates and private temporary parameter directory; no Azure calls.'
  $basicAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/deploy-basic-foundry-gateway.ps1'),[ref]$null,[ref]$upgradeErrors)
  if($upgradeErrors.Count){throw 'BASIC installer does not parse.'}
  $definition=@($basicAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-LegacyCallerUpgradeSafe'},$false))
  . ([scriptblock]::Create($definition[0].Extent.Text))
  foreach($case in @('legacy','shared-policy','open-product')) {
    $policy=if($case -eq 'shared-policy'){'<include-fragment fragment-id="fixture-byok-authenticate" />'}else{'<policies />'}
    $products=@([pscustomobject]@{properties=[pscustomobject]@{subscriptionRequired=($case -ne 'open-product')}})
    $failed=$false
    try{Assert-LegacyCallerUpgradeSafe -Policy $policy -Products $products}catch{$failed=$true}
    if($failed -ne ($case -ne 'legacy')){throw 'BASIC installer rollback guard failed.'}
  }
  Write-Output 'PASS: legacy installer refuses shared policy or open-product overwrite before mutations.'
  & {
    $ownerBefore=$env:BYOK_RESPONSE_OWNER_KEY
    $previousBefore=$env:BYOK_RESPONSE_OWNER_PREVIOUS_KEY
    $fixtureFile=Join-Path ([IO.Path]::GetTempPath()) ('wizard-upgrade-fixture-'+[guid]::NewGuid().ToString('N')+'.json')
    $state=@{scenario='';deployments=0}
    $serviceId='/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/fixture/providers/Microsoft.ApiManagement/service/fixture'
    function az {
      $global:LASTEXITCODE=0
      $command=$args -join ' '
      switch -Wildcard ($command) {
        'cloud show*' {return (@{name='AzureCloud';endpoints=@{resourceManager='https://management.azure.com/'}}|ConvertTo-Json -Depth 5)}
        'apim show*' {return (@{id=$serviceId;virtualNetworkType='Internal';provisioningState='Succeeded';sku=@{name=$(if($state.scenario -ceq 'tier-v2'){'StandardV2'}else{'Developer'})}}|ConvertTo-Json -Depth 5)}
        'apim api show*' {return (@{id=$serviceId+'/apis/fixture-api';subscriptionRequired=$true;subscriptionKeyParameterNames=@{header='api-key';query='api-key'}}|ConvertTo-Json)}
        'apim api operation list*' {return (@(@{name='models';method='GET';urlTemplate='/v1/models'},@{name='responses';method='POST';urlTemplate='/v1/responses'},@{name='chat';method='POST';urlTemplate='/v1/chat/completions'})|ConvertTo-Json)}
        'apim product list*' {return '[]'}
        'rest *' {
          $uri=[string]$args[([array]::IndexOf($args,'--url')+1)]
          if($uri -like '*/backends/fixture-backend?*'){return (@{properties=@{url='https://backend.example.test/openai'}}|ConvertTo-Json)}
          if($uri -like '*/operations/*/policies?*') {
            $value=if($state.scenario -eq 'override' -and $uri -like '*/operations/chat/*'){@(@{properties=@{value='<policies><inbound /></policies>'}})}else{@()}
            return (@{value=@($value)}|ConvertTo-Json -Depth 8)
          }
          if($uri -like '*/products?*') {
            $value=if($state.scenario -eq 'open-product'){@(@{name='unrelated';properties=@{subscriptionRequired=$false}})}else{@()}
            return (@{value=@($value)}|ConvertTo-Json -Depth 8)
          }
          throw 'Unexpected wizard ARM request.'
        }
        'deployment group what-if*' {
          $state.deployments++
          $path=([string]$args[([array]::IndexOf($args,'--parameters')+1)]).TrimStart('@')
          $candidate=(Get-Content -LiteralPath $path -Raw|ConvertFrom-Json).parameters
          if($candidate.responseOwnerKey.value -cne $env:BYOK_RESPONSE_OWNER_KEY -or $candidate.responseOperations.value.Count -ne 4){throw 'Private caller deployment binding mismatch.'}
          if($state.scenario -clike 'tier-*'){
            if($candidate.productTiers.value.Count -ne 1 -or $candidate.productTiers.value[0].monthlyCallQuota -ne 50000 -or
              $candidate.callerJwtTiering.value.entra.enabled -ne ($state.scenario -ceq 'tier-entra') -or
              $candidate.callerJwtTiering.value.okta.enabled -ne ($state.scenario -ceq 'tier-okta')){throw 'Wizard dropped or changed the reviewed tier configuration.'}
          }
          return
        }
        default {throw 'Unexpected Azure command in the isolated wizard preflight.'}
      }
    }
    try {
      $env:BYOK_RESPONSE_OWNER_KEY=[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
      $env:BYOK_RESPONSE_OWNER_PREVIOUS_KEY='__none__'
      $settings=@{parameters=@{
        apimName=@{value='fixture'};apimResourceGroup=@{value='fixture'};apiId=@{value='fixture-api'};modelsOperationId=@{value='models'}
        existingBackendName=@{value='fixture-backend'};existingBackendOrigin=@{value='https://backend.example.test'};resourcePrefix=@{value='fixture-'}
        cloudEnv=@{value='AzureCloud'};callerAuthRollout=@{value='shared'};foundryAuthMode=@{value='managedIdentity'}
        callerAuthPreparation=@{value=@{enabled=$true;keyEnabled=$true;entraEnabled=$false;entraClientIds=@();jwtProductId='fixture-jwt';oktaTrust=@{enabled=$false;issuer='';openIdConfigUrl='';audience='';requiredScope='';clientIds=@()}}}
      }}
      foreach($scenario in @('empty-policies','override','open-product','tier-entra','tier-okta','tier-v2')) {
        $wizardSettings=$settings|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable
        if($scenario -clike 'tier-*'){
          $wizardSettings.parameters.entraTenantId=@{value=[guid]::NewGuid().ToString()}
          $wizardSettings.parameters.apiAudience=@{value=[guid]::NewGuid().ToString()}
          $wizardSettings.parameters.callerAuthPreparation.value.entraEnabled=$scenario -cne 'tier-okta'
          if($scenario -ceq 'tier-okta'){$wizardSettings.parameters.callerAuthPreparation.value.oktaTrust=@{enabled=$true;issuer='https://fixture.example.test/oauth2/fixture';openIdConfigUrl='https://fixture.example.test/oauth2/fixture/.well-known/openid-configuration';audience='api://fixture-gateway';requiredScope='cli.invoke';clientIds=@('fixture-client')}}
          $wizardSettings.parameters.callerJwtTiering=@{value=@{entra=@{enabled=$scenario -cne 'tier-okta';mappings=@(@{claimValue='Byok.Standard';tier='byok-standard'})};okta=@{enabled=$scenario -ceq 'tier-okta';claimName='byok_tier';mappings=@(@{claimValue='Byok.Standard';tier='byok-standard'})}}}
          $wizardSettings.parameters.productTiers=@{value=@(@{name='byok-standard';callsPerMinute=60;tokensPerMinute=100000;monthlyCallQuota=50000})}
        }
        [IO.File]::WriteAllText($fixtureFile,($wizardSettings|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        $state.scenario=$scenario;$state.deployments=0;$failed=$false
        try{$output=@(& (Join-Path $root 'scripts/update-caller-auth.ps1') -ParametersFile $fixtureFile)|Out-String}catch{$failed=$true}
        $valid=$scenario -cin @('empty-policies','tier-entra','tier-okta')
        if($failed -eq $valid -or $state.deployments -ne $(if($valid){1}else{0})){throw ('Wizard full preflight failed: '+$scenario)}
        if($output -and $output.Contains($env:BYOK_RESPONSE_OWNER_KEY)){throw 'Wizard preflight emitted an ownership secret.'}
      }
    } finally {
      $env:BYOK_RESPONSE_OWNER_KEY=$ownerBefore;$env:BYOK_RESPONSE_OWNER_PREVIOUS_KEY=$previousBefore
      if(Test-Path -LiteralPath $fixtureFile){Remove-Item -LiteralPath $fixtureFile -Force}
    }
  }
  Write-Output 'PASS: complete wizard preflight accepts empty policy collections and rejects admission bypasses before a mocked deployment command.'
}
[xml]$sourceFragment = Get-Content -Raw (Join-Path $root 'policies/fragments/byok-credential-source.xml')
$expression = $sourceFragment.SelectSingleNode('/fragment/set-variable[@name="byokCredentialSource"]').GetAttribute('value')
if (-not $expression.StartsWith('@{') -or -not $expression.EndsWith('}')) { throw 'Expected the executable credential-source expression.' }
$body = $expression.Substring(2, $expression.Length - 3)
foreach ($name in @('caller-configuration-valid', 'caller-native-subscription-required', 'caller-key-enabled', 'caller-entra-enabled', 'caller-okta-enabled', 'caller-jwt-product-id')) {
    $body = $body.Replace(('"{{' + $name + '}}"'), ('context.Settings["' + $name + '"]'))
}
$issuerFragments = @{}
$claimMethods = @()
function Get-PolicyExpressionBody {
  param([xml] $Fragment, [string] $Variable)
  $value = $Fragment.SelectSingleNode('//set-variable[@name="' + $Variable + '"]').GetAttribute('value')
  $code = if ($value.StartsWith('@{')) { $value.Substring(2, $value.Length - 3) }
    elseif ($value.StartsWith('@(')) { 'return ' + $value.Substring(2, $value.Length - 3) + ';' }
    else { throw 'Expected a policy expression.' }
  foreach ($match in [regex]::Matches($code, '"\{\{([a-z0-9-]+)\}\}"')) {
    $code = $code.Replace($match.Value, ('context.Settings["' + $match.Groups[1].Value + '"]'))
  }
  $code
}
foreach ($issuer in @('entra', 'okta')) {
    [xml]$fragment = Get-Content -Raw (Join-Path $root ('policies/fragments/byok-validate-' + $issuer + '.xml'))
    $issuerFragments[$issuer] = $fragment
    $claimExpression = $fragment.SelectSingleNode('/fragment/set-variable[@name="byokJwtClaimsValid"]').GetAttribute('value')
    $claimBody = $claimExpression.Substring(2, $claimExpression.Length - 3)
    foreach ($match in [regex]::Matches($claimBody, '"\{\{([a-z0-9-]+)\}\}"')) {
        $claimBody = $claimBody.Replace($match.Value, ('context.Settings["' + $match.Groups[1].Value + '"]'))
    }
    $claimMethods += 'public static bool ' + $issuer + 'Claims(Context context) { ' + $claimBody + ' }'
    $claimMethods += 'public static string ' + $issuer + 'Subject(Context context) { ' + (Get-PolicyExpressionBody $fragment 'callerSubject') + ' }'
}
  [xml]$authentication = Get-Content -Raw (Join-Path $root 'policies/fragments/byok-authenticate.xml')
  $claimMethods += 'public static bool Configuration(Context context) { ' + (Get-PolicyExpressionBody $sourceFragment 'byokConfigurationValid') + ' }'
  $claimMethods += 'public static string Token(Context context) { ' + (Get-PolicyExpressionBody $authentication 'byokJwtToken') + ' }'
  $claimMethods += 'public static bool Shape(Context context) { ' + (Get-PolicyExpressionBody $authentication 'byokJwtShapeValid') + ' }'
  $claimMethods += 'public static string Branch(Context context) { ' + (Get-PolicyExpressionBody $authentication 'byokJwtIssuerBranch') + ' }'
  $claimMethods += 'public static string Principal(Context context) { ' + (Get-PolicyExpressionBody $authentication 'callerPrincipalKey') + ' }'
  [xml]$accounting = Get-Content -Raw (Join-Path $root 'policies/fragments/byok-apply-caller-limits.xml')
  $claimMethods += 'public static string Accounting(Context context) { ' + (Get-PolicyExpressionBody $accounting 'byokCallerAccountingMode') + ' }'
  [xml]$tierSelection = Get-Content -Raw (Join-Path $root 'policies/fragments/byok-select-caller-tier.xml')
  $tierBody = (Get-PolicyExpressionBody $tierSelection 'byokCallerTier').Replace('"__BYOK_JWT_TIERING_CONFIG__"', 'context.Settings["caller-jwt-tiering-config"]')
  $claimMethods += 'public static string Tier(Context context) { ' + $tierBody + ' }'
  [xml]$ownerContext = Get-Content -Raw (Join-Path $root 'policies/fragments/byok-response-owner-context.xml')
  [xml]$verifyOwner = Get-Content -Raw (Join-Path $root 'policies/fragments/byok-verify-response-owner.xml')
  $claimMethods += 'public static string OwnerMarkers(Context context) { ' + (Get-PolicyExpressionBody $ownerContext 'byokResponseOwnerMarkers') + ' }'
  $claimMethods += 'public static bool OwnsResponse(Context context) { ' + (Get-PolicyExpressionBody $verifyOwner 'byokResponseOwnerAuthorized') + ' }'
  [xml]$prepareResponse = Get-Content -Raw (Join-Path $root 'policies/fragments/byok-prepare-responses-request.xml')
  $claimMethods += 'public static string PrepareResponse(Context context) { ' + (Get-PolicyExpressionBody $prepareResponse 'byokPreparedResponseRequest') + ' }'
  [xml]$readResponseOwner = Get-Content -Raw (Join-Path $root 'policies/fragments/byok-read-response-owner.xml')
  $claimMethods += 'public static string ResponseLookupUrl(Context context) { ' + (Get-PolicyExpressionBody $readResponseOwner 'byokResponseLookupUrl') + ' }'
  [xml]$locateResponseOwner = Get-Content -Raw (Join-Path $root 'policies/fragments/byok-locate-response-owner.xml')
  $claimMethods += 'public static bool ResponseStoresValid(Context context) { ' + (Get-PolicyExpressionBody $locateResponseOwner 'byokResponseStoresValid') + ' }'
  $jwtProductSource = Get-Content -Raw (Join-Path $root 'infra/modules/apim-jwt-product.bicep')
  $jwtProductMatch = [regex]::Match($jwtProductSource, "var jwtProductGuardTemplate string = '(?<policy><policies>.*?</policies>)'")
  if (-not $jwtProductMatch.Success) { throw 'Expected the literal JWT product guard template.' }
  [xml]$jwtProductPolicy = $jwtProductMatch.Groups['policy'].Value.Replace('__ACTIVE__', 'true')
  $productCondition = $jwtProductPolicy.SelectSingleNode('/policies/inbound/choose/when').GetAttribute('condition')
  $claimMethods += 'public static bool RejectProduct(Context context, bool active) { return ' + $productCondition.Substring(2, $productCondition.Length - 3).Replace('!true', '!active') + '; }'
$namespace = 'ByokAuth' + [guid]::NewGuid().ToString('N')
$types = @'
using System;
using System.Collections.Generic;
using System.Linq;
namespace __NAMESPACE__ {
  public sealed class Jwt {
    public string Algorithm = "RS256";
    public string Issuer;
    public string Subject;
    public string[] Audiences;
    public DateTime? ExpirationTime;
    public DateTime? NotBefore;
    public Dictionary<string, string[]> Claims = new Dictionary<string, string[]>();
  }
  public static class TokenParser {
    public static Dictionary<string, Jwt> Tokens = new Dictionary<string, Jwt>();
    public static Jwt AsJwt(this string value) { return Tokens.ContainsKey(value) ? Tokens[value] : null; }
  }
  public sealed class IdentityContext { public string Id { get; set; } public string Name { get; set; } }
  public sealed class UrlContext { public Dictionary<string, string[]> Query = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase); }
  public sealed class BodyContext {
    public string Content;
    public T As<T>(bool preserveContent = false) { return Newtonsoft.Json.JsonConvert.DeserializeObject<T>(Content); }
  }
  public sealed class RequestContext {
    public Dictionary<string, string[]> Headers = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
    public UrlContext OriginalUrl = new UrlContext();
    public BodyContext Body = new BodyContext();
  }
  public sealed class Context {
    public DateTime Timestamp = DateTime.UtcNow;
    public RequestContext Request = new RequestContext();
    public IdentityContext Subscription;
    public IdentityContext Product;
    public Dictionary<string, object> Variables = new Dictionary<string, object>();
    public Dictionary<string, string> Settings = new Dictionary<string, string>();
  }
  public static class SourceGuard {
    public static string Evaluate(Context context) { __BODY__ }
    __CLAIM_METHODS__
  }
}
'@.Replace('__NAMESPACE__', $namespace).Replace('__BODY__', $body).Replace('__CLAIM_METHODS__', ($claimMethods -join "`n"))
$references = @((Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -Filter '*.dll').FullName) + @([Newtonsoft.Json.Linq.JObject].Assembly.Location)
$null = Add-Type -TypeDefinition $types -ReferencedAssemblies $references -CompilerOptions @('/langversion:7.3', '/nowarn:1701')
$contextType = ($namespace + '.Context') -as [type]
$identityType = ($namespace + '.IdentityContext') -as [type]
$guardType = ($namespace + '.SourceGuard') -as [type]
$count = 0
foreach ($header in @('api-key', 'x-api-key')) {
    foreach ($case in @(
        @{ name = 'product-key'; key = @('fixture-key'); subscription = $true; product = 'byok-standard'; expected = 'key-header' },
        @{ name = 'api-key'; key = @('fixture-key'); subscription = $true; expected = 'key-header' },
        @{ name = 'all-api-key'; key = @('fixture-key'); subscription = $true; expected = 'key-header' },
        @{ name = 'query-key'; query = @('fixture-key'); subscription = $true; expected = 'key-query' },
        @{ name = 'jwt-header'; key = @('fixture.token.signature'); product = 'byok-jwt'; expected = 'jwt-header' },
        @{ name = 'jwt-bearer'; bearer = @('Bearer fixture.token.signature'); product = 'byok-jwt'; expected = 'jwt-bearer' },
        @{ name = 'mixed-case-bearer'; bearer = @('bearer fixture.token.signature'); product = 'byok-jwt'; expected = 'jwt-bearer' },
        @{ name = 'open-product-subscription-not-native'; key = @('fixture.token.signature'); subscription = $true; product = 'byok-jwt'; expected = 'jwt-header' },
        @{ name = 'missing'; expected = 'invalid' },
        @{ name = 'empty-key'; key = @(''); expected = 'invalid' },
        @{ name = 'empty-bearer'; bearer = @('Bearer '); expected = 'invalid' },
        @{ name = 'bare-authorization'; bearer = @('fixture.token.signature'); expected = 'invalid' },
        @{ name = 'key-and-bearer'; key = @('fixture-key'); bearer = @('Bearer fixture.token.signature'); subscription = $true; expected = 'invalid' },
        @{ name = 'header-and-query'; key = @('fixture-key'); query = @('fixture-key'); subscription = $true; expected = 'invalid' },
        @{ name = 'duplicate-key'; key = @('fixture-key', 'fixture-key'); subscription = $true; expected = 'invalid' },
        @{ name = 'duplicate-query'; query = @('fixture-key', 'fixture-key'); subscription = $true; expected = 'invalid' },
        @{ name = 'policy-visible-duplicate-bearer'; bearer = @('Bearer fixture.token.signature', 'Bearer fixture.token.signature'); expected = 'invalid' },
        @{ name = 'combined-bearer'; bearer = @('Bearer fixture.token.signature,Bearer other.token.signature'); expected = 'invalid' },
        @{ name = 'query-jwt'; query = @('fixture.token.signature'); product = 'byok-jwt'; expected = 'invalid' },
        @{ name = 'wrong-scope-query-fallback'; query = @('fixture-key'); subscription = $true; product = 'byok-jwt'; expected = 'invalid' },
        @{ name = 'jwt-disabled'; bearer = @('Bearer fixture.token.signature'); jwtDisabled = $true; expected = 'invalid' },
        @{ name = 'invalid-key-with-jwt-disabled'; key = @('fixture-key'); jwtDisabled = $true; expected = 'invalid' },
        @{ name = 'key-disabled'; query = @('fixture-key'); subscription = $true; keyDisabled = $true; expected = 'invalid' },
        @{ name = 'other-key-header'; key = @('fixture-key'); other = $true; subscription = $true; expected = 'invalid' },
        @{ name = 'query-token-collision'; bearer = @('Bearer fixture.token.signature'); accessTokenQuery = $true; expected = 'invalid' },
        @{ name = 'invalid-trust-configuration'; key = @('fixture-key'); subscription = $true; invalidConfig = $true; expected = 'invalid' },
        @{ name = 'optional-native-admission'; key = @('fixture-key'); subscription = $true; optionalAdmission = $true; expected = 'invalid' },
        @{ name = 'jwt-only-header'; key = @('fixture.token.signature'); subscription = $true; keyDisabled = $true; expected = 'jwt-header' },
        @{ name = 'okta-only-bearer'; bearer = @('Bearer fixture.token.signature'); jwtDisabled = $true; oktaEnabled = $true; expected = 'jwt-bearer' }
    )) {
        $context = [Activator]::CreateInstance($contextType)
        $context.Variables['byokCredentialHeader'] = $header
        $context.Settings['caller-configuration-valid'] = $(if ($case.invalidConfig) { 'false' } else { 'true' })
        $context.Variables['byokConfigurationValid'] = -not $case.invalidConfig
        $context.Settings['caller-native-subscription-required'] = $(if ($case.optionalAdmission) { 'false' } else { 'true' })
        $context.Settings['caller-key-enabled'] = $(if ($case.keyDisabled) { 'false' } else { 'true' })
        $context.Settings['caller-entra-enabled'] = $(if ($case.jwtDisabled) { 'false' } else { 'true' })
        $context.Settings['caller-okta-enabled'] = $(if ($case.oktaEnabled) { 'true' } else { 'false' })
        $context.Settings['caller-jwt-product-id'] = 'byok-jwt'
        if ($case.ContainsKey('key')) { $context.Request.Headers[$header] = [string[]]$case.key }
        if ($case.bearer) { $context.Request.Headers['Authorization'] = [string[]]$case.bearer }
        if ($case.query) { $context.Request.OriginalUrl.Query['api-key'] = [string[]]$case.query }
        if ($case.other) { $context.Request.Headers[$(if ($header -eq 'api-key') { 'x-api-key' } else { 'api-key' })] = [string[]]@('other-key') }
        if ($case.accessTokenQuery) { $context.Request.OriginalUrl.Query['access_token'] = [string[]]@('fixture.token.signature') }
        if ($case.subscription) { $context.Subscription = [Activator]::CreateInstance($identityType); $context.Subscription.Id = 'fixture-subscription' }
        if ($case.product) { $context.Product = [Activator]::CreateInstance($identityType); $context.Product.Id = $case.product }
        $actual = $guardType::Evaluate($context)
        if ($actual -cne $case.expected) { throw ('Credential selection failed: ' + $header + ' ' + $case.name + ' expected=' + $case.expected + ' actual=' + $actual) }
        $count++
    }
}
if ($sourceFragment.SelectNodes('//validate-jwt|//send-request|//authentication-managed-identity').Count) { throw 'Source selection must not validate or forward credentials.' }
Write-Output ('PASS: ' + $count + ' executable shared credential-source checks; selection is not JWT validation or native APIM admission proof.')
$jwtType = ($namespace + '.Jwt') -as [type]
$tenant = [guid]::NewGuid().ToString()
$subject = [guid]::NewGuid().ToString()
$client = [guid]::NewGuid().ToString()
$claimsChecked = 0
foreach ($issuer in @('entra', 'okta')) {
  $fragment = $issuerFragments[$issuer]
  $validator = $fragment.SelectSingleNode('/fragment/validate-jwt')
  if ($fragment.SelectNodes('//validate-jwt').Count -ne 1 -or $validator.GetAttribute('token-value') -ne '@((string)context.Variables["byokJwtToken"])' -or
    $validator.GetAttribute('output-token-variable-name') -ne 'parsedJwt' -or $validator.GetAttribute('require-expiration-time') -ne 'true' -or
    $validator.GetAttribute('require-signed-tokens') -ne 'true' -or $validator.GetAttribute('clock-skew') -ne '0' -or
    $validator.SelectNodes('issuers/issuer').Count -ne 1 -or $validator.SelectNodes('audiences/audience').Count -ne 1) { throw 'Issuer validation contract changed.' }
  $expectedIssuer = '{{caller-' + $issuer + '-issuer}}'
  $expectedAudience = if ($issuer -eq 'entra') { '{{api-audience}}' } else { '{{caller-okta-audience}}' }
  if ($validator.SelectSingleNode('issuers/issuer').InnerText -ne $expectedIssuer -or $validator.SelectSingleNode('audiences/audience').InnerText -ne $expectedAudience) { throw 'Issuer/audience branches were mixed.' }
  $scope = $validator.SelectSingleNode('required-claims/claim[@name="scp"]')
  if ($scope.GetAttribute('match') -ne 'any' -or ($issuer -eq 'entra' -and $scope.GetAttribute('separator') -ne ' ') -or
    ($issuer -eq 'okta' -and $scope.HasAttribute('separator'))) { throw 'Issuer scope representation changed.' }
  foreach ($case in @('valid', 'multiple-scopes', 'wrong-issuer', 'wrong-audience', 'multiple-audiences', 'expired', 'no-expiry', 'not-yet-valid',
    'missing-subject', 'duplicate-subject', 'missing-user', 'duplicate-user', 'missing-client', 'untrusted-client', 'missing-scope', 'wrong-scope',
    'scope-prefix', 'wrong-scope-shape', 'app-only', 'mutable-subject', 'wrong-tenant', 'any-client', 'empty-client-list', 'client-is-audience')) {
    $context = [Activator]::CreateInstance($contextType)
    $token = [Activator]::CreateInstance($jwtType)
    $token.Issuer = 'https://' + $issuer + '.example.test/issuer'
    $token.Audiences = [string[]]@('fixture-audience')
    $token.ExpirationTime = $context.Timestamp.AddMinutes(5)
    $token.NotBefore = $context.Timestamp.AddMinutes(-1)
    if ($issuer -eq 'entra') {
      foreach ($entry in @{ tid = $tenant; oid = $subject; azp = $client; scp = 'cli.invoke'; ver = '2.0'; idtyp = 'user' }.GetEnumerator()) { $token.Claims[$entry.Key] = [string[]]@($entry.Value) }
      $context.Settings['caller-entra-tenant-id'] = $tenant
      $context.Settings['caller-entra-client-ids'] = $client
      $context.Settings['api-audience'] = 'fixture-audience'
      $context.Settings['required-scope'] = 'cli.invoke'
    } else {
      $token.Subject = 'fixture-user'
      foreach ($entry in @{ sub = 'fixture-user'; uid = 'fixture-user'; cid = 'fixture-client'; scp = 'cli.invoke' }.GetEnumerator()) { $token.Claims[$entry.Key] = [string[]]@($entry.Value) }
      $context.Settings['caller-okta-client-ids'] = 'fixture-client'
      $context.Settings['caller-okta-audience'] = 'fixture-audience'
      $context.Settings['caller-okta-required-scope'] = 'cli.invoke'
    }
    $context.Settings['caller-' + $issuer + '-issuer'] = $token.Issuer
    $subjectClaim = if ($issuer -eq 'entra') { 'oid' } else { 'sub' }
    $userClaim = if ($issuer -eq 'entra') { 'tid' } else { 'uid' }
    $clientClaim = if ($issuer -eq 'entra') { 'azp' } else { 'cid' }
    switch ($case) {
      'multiple-scopes' { $token.Claims['scp'] = $(if ($issuer -eq 'entra') { [string[]]@('other cli.invoke extra') } else { [string[]]@('other', 'cli.invoke', 'extra') }) }
      'wrong-issuer' { $token.Issuer = 'https://untrusted.example.test/issuer' }
      'wrong-audience' { $token.Audiences = [string[]]@('wrong-audience') }
      'multiple-audiences' { $token.Audiences = [string[]]@('fixture-audience', 'wrong-audience') }
      'expired' { $token.ExpirationTime = $context.Timestamp.AddSeconds(-1) }
      'no-expiry' { $token.ExpirationTime = $null }
      'not-yet-valid' { $token.NotBefore = $context.Timestamp.AddMinutes(1) }
      'missing-subject' { $null = $token.Claims.Remove($subjectClaim) }
      'duplicate-subject' { $token.Claims[$subjectClaim] = [string[]]@('first', 'second') }
      'missing-user' { $null = $token.Claims.Remove($userClaim) }
      'duplicate-user' { $token.Claims[$userClaim] = [string[]]@('first', 'second') }
      'missing-client' { $null = $token.Claims.Remove($clientClaim) }
      'untrusted-client' { $token.Claims[$clientClaim] = [string[]]@([guid]::NewGuid().ToString()) }
      'missing-scope' { $null = $token.Claims.Remove('scp') }
      'wrong-scope' { $token.Claims['scp'] = [string[]]@('other') }
      'scope-prefix' { $token.Claims['scp'] = [string[]]@('cli.invoke.extra') }
      'wrong-scope-shape' { $token.Claims['scp'] = $(if ($issuer -eq 'entra') { [string[]]@('cli.invoke', 'other') } else { [string[]]@('cli.invoke other') }) }
      'app-only' { if ($issuer -eq 'entra') { $token.Claims['idtyp'] = [string[]]@('app') } else { $null = $token.Claims.Remove('uid') } }
      'mutable-subject' { $token.Claims[$subjectClaim] = [string[]]@('mutable-login'); if ($issuer -eq 'okta') { $token.Subject = 'mutable-login' } }
      'wrong-tenant' { if ($issuer -eq 'entra') { $token.Claims['tid'] = [string[]]@([guid]::NewGuid().ToString()) } else { $token.Issuer = 'https://another.example.test/issuer' } }
      'any-client' { $context.Settings['caller-' + $issuer + '-client-ids'] = '__any__' }
      'empty-client-list' { $context.Settings['caller-' + $issuer + '-client-ids'] = '' }
      'client-is-audience' {
        $audienceSetting = if ($issuer -eq 'entra') { 'api-audience' } else { 'caller-okta-audience' }
        $context.Settings[$audienceSetting] = $token.Claims[$clientClaim][0]
        $token.Audiences = [string[]]@($token.Claims[$clientClaim][0])
      }
    }
    $context.Variables['parsedJwt'] = $token
    $actual = if ($issuer -eq 'entra') { $guardType::entraClaims($context) } else { $guardType::oktaClaims($context) }
    $expected = $case -in @('valid', 'multiple-scopes') -or ($issuer -eq 'entra' -and $case -eq 'any-client')
    if ($actual -ne $expected) { throw ('Validated claim contract failed: ' + $issuer + ' ' + $case) }
    if ($actual) {
      $stableSubject = if ($issuer -eq 'entra') { $guardType::entraSubject($context) } else { $guardType::oktaSubject($context) }
      $expectedSubject = if ($issuer -eq 'entra') { $tenant + ':' + $subject } else { 'fixture-user' }
      if ($stableSubject -cne $expectedSubject) { throw 'Validated stable subject was not preserved.' }
    }
    $claimsChecked++
  }
}
Write-Output ('PASS: ' + $claimsChecked + ' executable validated-claim checks; APIM signature validation and live Okta remain separate gates.')
$tokenParser = ($namespace + '.TokenParser') -as [type]
$dispatchChecked = 0
foreach ($case in @('entra', 'okta', 'unknown', 'disabled-entra', 'disabled-okta', 'overlapping-trust', 'malformed', 'too-long',
  'trailing-newline', 'unsigned', 'wrong-algorithm', 'duplicate-issuer', 'missing-issuer', 'issuer-case', 'issuer-suffix')) {
  $context = [Activator]::CreateInstance($contextType)
  $token = [Activator]::CreateInstance($jwtType)
  $context.Settings['caller-entra-enabled'] = 'true'
  $context.Settings['caller-okta-enabled'] = 'true'
  $context.Settings['caller-entra-issuer'] = 'https://entra.example.test/tenant/v2.0'
  $context.Settings['caller-okta-issuer'] = 'https://okta.example.test/oauth2/fixture'
  $token.Issuer = $context.Settings[$(if ($case -in @('okta', 'disabled-okta')) { 'caller-okta-issuer' } else { 'caller-entra-issuer' })]
  $value = 'fixture.payload.signature'
  switch ($case) {
    'unknown' { $token.Issuer = 'https://unknown.example.test' }
    'disabled-entra' { $context.Settings['caller-entra-enabled'] = 'false' }
    'disabled-okta' { $context.Settings['caller-okta-enabled'] = 'false' }
    'overlapping-trust' { $context.Settings['caller-okta-issuer'] = $context.Settings['caller-entra-issuer'] }
    'malformed' { $value = 'not a jwt' }
    'too-long' { $value = ('a' * 32769) + '.payload.signature' }
    'trailing-newline' { $value += "`n" }
    'unsigned' { $token.Algorithm = 'none' }
    'wrong-algorithm' { $token.Algorithm = 'HS256' }
    'issuer-case' { $token.Issuer = $token.Issuer.ToUpperInvariant() }
    'issuer-suffix' { $token.Issuer += '/untrusted' }
  }
  if ($case -ne 'missing-issuer') { $token.Claims['iss'] = $(if ($case -eq 'duplicate-issuer') { [string[]]@($token.Issuer, $token.Issuer) } else { [string[]]@($token.Issuer) }) }
  $tokenParser::Tokens[$value] = $token
  $context.Variables['byokJwtToken'] = $value
  $context.Variables['byokJwtShapeValid'] = $case -notin @('malformed', 'too-long', 'trailing-newline')
  $expected = if ($case -in @('entra', 'okta')) { $case } else { 'invalid' }
  if ($guardType::Branch($context) -cne $expected) { throw ('Fixed issuer dispatch failed: ' + $case) }
  if ($context.Variables.ContainsKey('callerSubject') -or $context.Variables.ContainsKey('byokJwtValidated')) { throw 'Unverified issuer dispatch established identity.' }
  $dispatchChecked++
}
foreach ($header in @('api-key', 'x-api-key')) {
  foreach ($source in @('jwt-header', 'jwt-bearer', 'invalid')) {
    $context = [Activator]::CreateInstance($contextType)
    $context.Variables['byokCredentialHeader'] = $header
    $context.Variables['byokCredentialSource'] = $source
    $context.Request.Headers[$header] = [string[]]@('fixture.payload.signature')
    $context.Request.Headers['Authorization'] = [string[]]@('Bearer fixture.payload.signature')
    $expected = if ($source -eq 'invalid') { '' } else { 'fixture.payload.signature' }
    if ($guardType::Token($context) -cne $expected) { throw 'JWT extraction mixed credential sources.' }
    $dispatchChecked++
  }
}
$principalKeys = [Collections.Generic.HashSet[string]]::new()
foreach ($method in @('subscriptionKey', 'entraJwt', 'oktaJwt')) {
  foreach ($issuer in @('https://first.example.test', 'https://second.example.test')) {
    $context = [Activator]::CreateInstance($contextType)
    $context.Variables['callerAuthMethod'] = $method
    $context.Variables['callerIssuer'] = $(if ($method -eq 'subscriptionKey') { 'apim' } else { $issuer })
    $context.Variables['callerSubject'] = 'fixture-subject'
    $context.Variables['byokJwtValidated'] = $method -ne 'subscriptionKey'
    if ($method -eq 'subscriptionKey') { $context.Subscription = [Activator]::CreateInstance($identityType); $context.Subscription.Id = 'fixture-subject' }
    $principal = $guardType::Principal($context)
    if ([string]::IsNullOrWhiteSpace($principal)) { throw 'Validated principal was rejected.' }
    if (-not $principalKeys.Add($principal) -and $method -ne 'subscriptionKey') { throw 'Issuer/method identity collision.' }
    $context.Variables['byokJwtValidated'] = $false
    $context.Subscription = $null
    if ($guardType::Principal($context) -ne '') { throw 'Unvalidated principal was accepted.' }
    $dispatchChecked++
  }
}
if ($principalKeys.Count -ne 5) { throw 'Principal namespacing changed.' }
foreach ($issuer in @('entra', 'okta')) {
  $branch = $authentication.SelectSingleNode('//when[include-fragment/@fragment-id="byok-validate-' + $issuer + '"]')
  if (-not $branch -or -not $branch.GetAttribute('condition').Contains('"' + $issuer + '"')) { throw 'Issuer validator binding is not fixed.' }
}
if ($authentication.SelectNodes('//openid-config|//send-request|//authentication-managed-identity').Count -or
  $authentication.SelectSingleNode('/fragment/set-variable[@name="byokJwtValidated"]').GetAttribute('value') -ne '@(false)' -or
  $authentication.SelectNodes('//set-header[not(ancestor::return-response)]|//set-query-parameter').Count) { throw 'Authentication sequencing changed.' }
[xml]$strip = Get-Content -Raw (Join-Path $root 'policies/fragments/byok-strip-caller-credentials.xml')
foreach ($header in @('api-key', 'x-api-key', 'Authorization', 'Ocp-Apim-Subscription-Key')) {
  if ($strip.SelectNodes('/fragment/set-header[@name="' + $header + '" and @exists-action="delete"]').Count -ne 1) { throw 'Caller credential header is not stripped.' }
}
foreach ($queryName in @('api-key', 'subscription-key', 'x-api-key', 'Authorization', 'access_token')) {
  if ($strip.SelectNodes('/fragment/set-query-parameter[@name="' + $queryName + '" and @exists-action="delete"]').Count -ne 1) { throw 'Caller credential query parameter is not stripped.' }
}
if ($strip.fragment.FirstChild.Name -ne 'choose' -or -not $strip.fragment.FirstChild.InnerXml.Contains('byokCallerAuthenticated')) { throw 'Credential stripping lost the authenticated-caller guard.' }
Write-Output ('PASS: ' + $dispatchChecked + ' fixed-dispatch, extraction and principal checks; fragment bindings and stripping are structurally verified.')
$accountingChecked = 0
foreach ($case in @('product-key', 'api-key', 'all-api-key', 'entra', 'okta', 'unauthenticated', 'unvalidated-jwt',
  'missing-subscription', 'wrong-subscription', 'missing-principal', 'changed-principal', 'unknown-method', 'already-accounted', 'missing-subject')) {
  $context = [Activator]::CreateInstance($contextType)
  $method = if ($case -in @('product-key', 'api-key', 'all-api-key', 'missing-subscription', 'wrong-subscription')) { 'subscriptionKey' } elseif ($case -eq 'okta') { 'oktaJwt' } else { 'entraJwt' }
  $context.Variables['byokCallerAuthenticated'] = $true
  $context.Variables['byokJwtValidated'] = $method -ne 'subscriptionKey'
  $context.Variables['callerAuthMethod'] = $method
  $context.Variables['callerIssuer'] = if ($method -eq 'subscriptionKey') { 'apim' } else { 'https://issuer.example.test' }
  $context.Variables['callerSubject'] = 'fixture-subject'
  if ($method -eq 'subscriptionKey') {
    $context.Subscription = [Activator]::CreateInstance($identityType)
    $context.Subscription.Id = 'fixture-subject'
  }
  $context.Variables['callerPrincipalKey'] = $guardType::Principal($context)
  switch ($case) {
    'unauthenticated' { $context.Variables['byokCallerAuthenticated'] = $false }
    'unvalidated-jwt' { $context.Variables['byokJwtValidated'] = $false }
    'missing-subscription' { $context.Subscription = $null }
    'wrong-subscription' { $context.Subscription.Id = 'other-subscription' }
    'missing-principal' { $null = $context.Variables.Remove('callerPrincipalKey') }
    'changed-principal' { $context.Variables['callerPrincipalKey'] = 'another-principal' }
    'unknown-method' { $context.Variables['callerAuthMethod'] = 'unknown' }
    'already-accounted' { $context.Variables['byokCallerAccountingApplied'] = $true }
    'missing-subject' { $context.Variables['callerSubject'] = '' }
  }
  $expected = if ($case -in @('product-key', 'api-key', 'all-api-key')) { 'native' } elseif ($case -in @('entra', 'okta')) { 'jwt' } else { 'invalid' }
  if ($guardType::Accounting($context) -cne $expected) { throw ('Caller accounting selection failed: ' + $case) }
  $accountingChecked++
}
$jwtLimits = $accounting.SelectSingleNode('/fragment/choose/when[2]')
if ($jwtLimits.GetAttribute('condition') -cne '@((string)context.Variables["byokCallerAccountingMode"] == "jwt")' -or
  $accounting.SelectNodes('//rate-limit-by-key|//azure-openai-token-limit|//quota-by-key').Count -ne 3 -or
  $jwtLimits.SelectNodes('rate-limit-by-key|azure-openai-token-limit|quota-by-key').Count -ne 3 -or
  $accounting.SelectNodes('//base|//include-fragment|//send-request|//authentication-managed-identity').Count -ne 0) { throw 'Shared accounting must charge JWTs only and cannot add inherited/backend paths.' }
foreach ($limiter in $jwtLimits.ChildNodes | Where-Object NodeType -eq ([Xml.XmlNodeType]::Element)) {
  if ($limiter.GetAttribute('counter-key') -cne '@((string)context.Variables["callerPrincipalKey"])') { throw 'JWT counters lost the validated issuer-qualified identity.' }
}
Write-Output ('PASS: ' + $accountingChecked + ' caller accounting gates; native keys bypass JWT limits and invalid/repeated accounting fails closed.')
$ownerChecked = 0
$ownerKey = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
$previousOwnerKey = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
$ownerMarkerSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($principal in @('entraJwt:7:issuer1:user-one', 'entraJwt:7:issuer1:user-two', 'entraJwt:7:issuer2:user-one', 'oktaJwt:7:issuer1:user-one', 'subscriptionKey:4:apim:user-one')) {
  $context = [Activator]::CreateInstance($contextType)
  $context.Variables['byokCallerAuthenticated'] = $true
  $context.Variables['callerPrincipalKey'] = $principal
  $context.Settings['caller-response-owner-key'] = $ownerKey
  $context.Settings['caller-response-owner-key-previous'] = '__none__'
  $marker = $guardType::OwnerMarkers($context)
  if ($marker -cnotmatch '\Av1\.[0-9a-f]{64}\z' -or -not $ownerMarkerSet.Add($marker) -or $marker.Contains('user-one')) { throw 'Response ownership marker is missing, exposes identity or collides across callers/providers.' }
  if ($guardType::OwnerMarkers($context) -cne $marker) { throw 'Response ownership must survive token renewal for the same validated principal.' }
  $ownerChecked++
}
foreach ($case in @('owner', 'previous-key', 'different-owner', 'wrong-id', 'wrong-object', 'missing-marker', 'array-marker', 'forged-marker',
  'missing-document', 'malformed-document', 'bad-reference', 'unauthenticated', 'missing-principal', 'empty-key', 'short-key', 'bad-key',
  'bad-previous-key', 'removed-previous-key')) {
  $context = [Activator]::CreateInstance($contextType)
  $context.Variables['byokCallerAuthenticated'] = $true
  $context.Variables['callerPrincipalKey'] = 'entraJwt:7:issuer1:fixture-subject'
  $context.Settings['caller-response-owner-key'] = $previousOwnerKey
  $context.Settings['caller-response-owner-key-previous'] = '__none__'
  $oldMarker = $guardType::OwnerMarkers($context)
  $context.Settings['caller-response-owner-key'] = $ownerKey
  $context.Settings['caller-response-owner-key-previous'] = $previousOwnerKey
  $markers = $guardType::OwnerMarkers($context)
  $document = @{ id = 'resp_fixture'; object = 'response'; metadata = @{ byok_owner_v1 = ($markers -split ',')[0] } }
  $context.Variables['byokResponseReference'] = 'resp_fixture'
  switch ($case) {
    'previous-key' { $document.metadata.byok_owner_v1 = $oldMarker }
    'different-owner' { $context.Variables['callerPrincipalKey'] = 'entraJwt:7:issuer1:another-user' }
    'wrong-id' { $document.id = 'resp_other' }
    'wrong-object' { $document.object = 'list' }
    'missing-marker' { $document.metadata.Clear() }
    'array-marker' { $document.metadata.byok_owner_v1 = @($document.metadata.byok_owner_v1) }
    'forged-marker' { $document.metadata.byok_owner_v1 = 'v1.' + ('0' * 64) }
    'bad-reference' { $context.Variables['byokResponseReference'] = '../resp_fixture' }
    'unauthenticated' { $context.Variables['byokCallerAuthenticated'] = $false }
    'missing-principal' { $context.Variables['callerPrincipalKey'] = '' }
    'empty-key' { $context.Settings['caller-response-owner-key'] = '' }
    'short-key' { $context.Settings['caller-response-owner-key'] = [Convert]::ToBase64String([byte[]]@(1,2,3)) }
    'bad-key' { $context.Settings['caller-response-owner-key'] = 'not-base64' }
    'bad-previous-key' { $context.Settings['caller-response-owner-key-previous'] = 'not-base64' }
    'removed-previous-key' { $context.Settings['caller-response-owner-key-previous'] = '__none__'; $document.metadata.byok_owner_v1 = $oldMarker }
  }
  $context.Variables['byokResponseOwnerMarkers'] = $guardType::OwnerMarkers($context)
  $context.Variables['byokResponseOwnershipDocument'] = [string]($document | ConvertTo-Json -Depth 5 -Compress)
  if ($case -eq 'missing-document') { $null = $context.Variables.Remove('byokResponseOwnershipDocument') }
  if ($case -eq 'malformed-document') { $context.Variables['byokResponseOwnershipDocument'] = '{invalid' }
  $expected = $case -in @('owner', 'previous-key')
  if ($guardType::OwnsResponse($context) -ne $expected) { throw ('Stored response ownership failed closed validation: ' + $case) }
  $ownerChecked++
}
if ($verifyOwner.SelectSingleNode('/fragment/choose/when/return-response/set-status').code -ne '404' -or
  $verifyOwner.SelectSingleNode('/fragment/set-variable[@name="byokResponseOwnershipDocument"]').GetAttribute('value') -ne '' -or
  $ownerContext.SelectNodes('//send-request|//base|//include-fragment').Count -or $verifyOwner.SelectNodes('//send-request|//base|//include-fragment').Count) { throw 'Response ownership primitives must not introduce uncontrolled calls or expose denial details.' }
Write-Output ('PASS: ' + $ownerChecked + ' response-owner HMAC/identity/rotation checks; backend persistence and operation integration remain separate gates.')
$responseRequestChecked = 0
foreach ($case in @('new', 'previous', 'background', 'stream', 'reserved-overwrite', 'fifteen-metadata', 'null-metadata',
  'array-metadata', 'too-many-metadata', 'nonstring-metadata', 'oversize-metadata', 'unsafe-previous', 'array-previous',
  'conversation-reference', 'item-reference', 'missing-authentication', 'missing-marker', 'malformed')) {
  $context = [Activator]::CreateInstance($contextType)
  $context.Variables['byokCallerAuthenticated'] = $true
  $context.Variables['byokResponseOwnerMarker'] = 'v1.' + ('a' * 64)
  $body = @{ model = 'fixture-model'; input = @(@{ role = 'user'; content = 'fixture-input' }); tools = @(@{ type = 'function'; name = 'fixture_tool' }); reasoning = @{ effort = 'medium' }; metadata = @{ label = 'fixture-label' } }
  switch ($case) {
    'previous' { $body.previous_response_id = 'resp_fixture' }
    'background' { $body.background = $true; $body.store = $true }
    'stream' { $body.stream = $true }
    'reserved-overwrite' { $body.metadata.byok_owner_v1 = 'forged-owner' }
    'fifteen-metadata' { $body.metadata.Clear(); foreach ($index in 1..15) { $body.metadata['fixture' + $index] = 'value' } }
    'null-metadata' { $body.metadata = $null }
    'array-metadata' { $body.metadata = @('invalid') }
    'too-many-metadata' { $body.metadata.Clear(); foreach ($index in 1..16) { $body.metadata['fixture' + $index] = 'value' } }
    'nonstring-metadata' { $body.metadata.label = 7 }
    'oversize-metadata' { $body.metadata.label = 'a' * 513 }
    'unsafe-previous' { $body.previous_response_id = 'resp_fixture/../other' }
    'array-previous' { $body.previous_response_id = @('resp_fixture') }
    'conversation-reference' { $body.conversation = 'conv_fixture' }
    'item-reference' { $body.input = @(@{ type = 'item_reference'; id = 'msg_fixture' }) }
    'missing-authentication' { $context.Variables['byokCallerAuthenticated'] = $false }
    'missing-marker' { $null = $context.Variables.Remove('byokResponseOwnerMarker') }
  }
  $context.Request.Body.Content = [string]($body | ConvertTo-Json -Depth 12 -Compress)
  if ($case -eq 'malformed') { $context.Request.Body.Content = '{invalid' }
  $prepared = $guardType::PrepareResponse($context)
  $expected = $case -in @('new', 'previous', 'background', 'stream', 'reserved-overwrite', 'fifteen-metadata', 'null-metadata')
  if ((-not [string]::IsNullOrEmpty($prepared)) -ne $expected) { throw ('Response ownership request guard failed: ' + $case) }
  if ($expected) {
    $result = $prepared | ConvertFrom-Json -AsHashtable
    if ($result.metadata.byok_owner_v1 -cne ('v1.' + ('a' * 64)) -or $result.reasoning.effort -cne 'medium' -or
      $result.tools[0].name -cne 'fixture_tool' -or ($result.input | ConvertTo-Json -Depth 10 -Compress) -cne ($body.input | ConvertTo-Json -Depth 10 -Compress) -or
      $result.previous_response_id -cne $body.previous_response_id -or $result.background -ne $body.background -or $result.stream -ne $body.stream) { throw 'Ownership stamping changed model/tool/stream/state behavior or trusted caller metadata.' }
  }
  $responseRequestChecked++
}
Write-Output ('PASS: ' + $responseRequestChecked + ' Responses request stamping checks; tools, reasoning, background, streaming and previous-response IDs are preserved.')
$responseLookupChecked = 0
foreach ($case in @('configured-origin', 'configured-with-path', 'unknown-origin', 'userinfo', 'query', 'fragment', 'http', 'wrong-port', 'bad-id',
  'missing-origins', 'malformed-origins', 'unauthenticated', 'missing-backend', 'nonstring-origin')) {
  $context = [Activator]::CreateInstance($contextType)
  $context.Variables['byokCallerAuthenticated'] = $true
  $context.Variables['byokResponseReference'] = 'resp_fixture'
  $context.Variables['byokResponseBackendUrl'] = 'https://backend.example.test'
  $context.Variables['byokResponseBackendOrigins'] = '["https://backend.example.test"]'
  switch ($case) {
    'configured-with-path' { $context.Variables['byokResponseBackendUrl'] += '/openai/v1/responses' }
    'unknown-origin' { $context.Variables['byokResponseBackendUrl'] = 'https://other.example.test' }
    'userinfo' { $context.Variables['byokResponseBackendUrl'] = 'https://caller@backend.example.test' }
    'query' { $context.Variables['byokResponseBackendUrl'] += '?redirect=other' }
    'fragment' { $context.Variables['byokResponseBackendUrl'] += '#other' }
    'http' { $context.Variables['byokResponseBackendUrl'] = 'http://backend.example.test' }
    'wrong-port' { $context.Variables['byokResponseBackendUrl'] = 'https://backend.example.test:444' }
    'bad-id' { $context.Variables['byokResponseReference'] = 'resp_fixture?other=true' }
    'missing-origins' { $context.Variables['byokResponseBackendOrigins'] = '[]' }
    'malformed-origins' { $context.Variables['byokResponseBackendOrigins'] = '{invalid' }
    'unauthenticated' { $context.Variables['byokCallerAuthenticated'] = $false }
    'missing-backend' { $null = $context.Variables.Remove('byokResponseBackendUrl') }
    'nonstring-origin' { $context.Variables['byokResponseBackendOrigins'] = '[7]' }
  }
  $expected = if ($case -in @('configured-origin', 'configured-with-path')) { 'https://backend.example.test/openai/v1/responses/resp_fixture' } else { '' }
  if ($guardType::ResponseLookupUrl($context) -cne $expected) { throw ('Ownership lookup escaped its deployment-configured origin/ID boundary: ' + $case) }
  $responseLookupChecked++
}
if ($readResponseOwner.SelectSingleNode('/fragment/send-request').GetAttribute('mode') -ne 'new' -or
  $readResponseOwner.SelectSingleNode('/fragment/send-request/set-method').InnerText -ne 'GET' -or
  $readResponseOwner.SelectNodes('//base|//include-fragment|//authentication-managed-identity').Count -or
  $readResponseOwner.OuterXml.Contains('context.Request.Headers') -or $readResponseOwner.OuterXml.Contains('context.Request.OriginalUrl')) { throw 'Ownership lookup must not inherit caller headers or caller-selected origins.' }
Write-Output ('PASS: ' + $responseLookupChecked + ' configured response-lookup origin/ID checks; no backend requests executed.')
$storeChecked = 0
foreach ($case in @('valid', 'empty', 'too-many', 'invalid-kind', 'duplicate-backend', 'duplicate-origin', 'http', 'userinfo', 'query', 'port', 'path', 'placeholder', 'loopback', 'scalar')) {
  $context = [Activator]::CreateInstance($contextType)
  $stores = @(@{ origin = 'https://backend.example.test'; backendId = 'foundry'; kind = 'foundry' })
  switch ($case) {
    'empty' { $stores = @() }
    'too-many' { $stores = @($stores[0]) * 9 }
    'invalid-kind' { $stores[0].kind = 'caller' }
    'duplicate-backend' { $stores += @{ origin = 'https://other.example.test'; backendId = 'foundry'; kind = 'foundry' } }
    'duplicate-origin' { $stores += @{ origin = 'https://backend.example.test'; backendId = 'other'; kind = 'foundry' } }
    'http' { $stores[0].origin = 'http://backend.example.test' }
    'userinfo' { $stores[0].origin = 'https://user@backend.example.test' }
    'query' { $stores[0].origin += '?query=value' }
    'port' { $stores[0].origin = 'https://backend.example.test:444' }
    'path' { $stores[0].origin += '/other' }
    'placeholder' { $stores[0].origin = 'https://unset.invalid' }
    'loopback' { $stores[0].origin = 'https://localhost' }
    'scalar' { $stores = @('not-an-object') }
  }
  $context.Variables['byokResponseStores'] = [string](ConvertTo-Json -InputObject $stores -Depth 5 -Compress)
  if ($guardType::ResponseStoresValid($context) -ne ($case -eq 'valid')) { throw ('Response store configuration was not fail-closed: ' + $case) }
  $storeChecked++
}
$productChecked = 0
foreach ($active in @($true, $false)) {
  foreach ($case in @('entra', 'okta', 'key', 'unvalidated', 'unauthenticated', 'missing-method')) {
    $context = [Activator]::CreateInstance($contextType)
    $context.Variables['byokCallerAuthenticated'] = $case -ne 'unauthenticated'
    $context.Variables['byokJwtValidated'] = $case -ne 'unvalidated'
    $context.Variables['callerAuthMethod'] = if ($case -eq 'okta') { 'oktaJwt' } elseif ($case -eq 'key') { 'subscriptionKey' } else { 'entraJwt' }
    if ($case -eq 'missing-method') { $null = $context.Variables.Remove('callerAuthMethod') }
    if ($guardType::RejectProduct($context, $active) -ne (-not ($active -and $case -in @('entra', 'okta')))) { throw 'JWT product authorized an inactive or unvalidated caller path.' }
    $productChecked++
  }
}
Write-Output ('PASS: ' + $storeChecked + ' response-store configuration checks and ' + $productChecked + ' deny-by-default JWT product gates.')
$tierChecked = 0
foreach ($method in @('entraJwt', 'oktaJwt')) {
  foreach ($case in @('standard', 'power', 'unrelated-role', 'same-tier-alias', 'conflicting-tiers', 'reverse-conflict',
      'duplicate-role', 'no-matched-role', 'missing-role', 'empty-role', 'role-case', 'scalar-role', 'non-string-role',
      'object-role', 'projection-mismatch', 'unvalidated', 'unauthenticated', 'native-accounting', 'wrong-method',
      'wrong-issuer', 'invalid-token', 'provider-disabled', 'other-provider-disabled', 'bad-config', 'wrong-version',
      'unknown-config-field', 'non-boolean-flag', 'unknown-tier', 'duplicate-mapping', 'missing-mapping',
      'reserved-claim', 'duplicate-tier', 'unsafe-tier', 'non-string-mapping', 'tier-change', 'token-renewal')) {
    $context = [Activator]::CreateInstance($contextType)
    $token = [Activator]::CreateInstance(($namespace + '.Jwt') -as [type])
    $token.Issuer = if ($method -ceq 'entraJwt') { 'https://issuer.example.test/tenant/v2.0' } else { 'https://issuer.example.test/oauth2/fixture' }
    $claimName = if ($method -ceq 'entraJwt') { 'roles' } else { 'byok_tier' }
    $mapping = @(@{claimValue = 'Byok.Standard'; tier = 'byok-standard'}, @{claimValue = 'Byok.Power'; tier = 'byok-power'})
    $configuration = @{version = 1; tiers = @('byok-standard', 'byok-power'); entra = @{enabled = $true; claimName = 'roles'; mappings = $mapping}; okta = @{enabled = $true; claimName = 'byok_tier'; mappings = $mapping}}
    $selected = if ($method -ceq 'entraJwt') { $configuration.entra } else { $configuration.okta }
    $other = if ($method -ceq 'entraJwt') { $configuration.okta } else { $configuration.entra }
    $roles = @('Byok.Standard')
    $context.Variables['byokCallerAuthenticated'] = $true
    $context.Variables['byokJwtValidated'] = $true
    $context.Variables['byokCallerAccountingMode'] = 'jwt'
    $context.Variables['callerAuthMethod'] = $method
    $context.Variables['callerIssuer'] = $token.Issuer
    $context.Variables['callerSubject'] = 'fixture-user'
    $principal = $method + ':' + $token.Issuer.Length + ':' + $token.Issuer + ':fixture-user'
    $context.Variables['callerPrincipalKey'] = $principal
    $context.Variables['byokResponseOwnerMarkers'] = 'unchanged-owner-marker'
    $expected = '__invalid__'
    switch ($case) {
      'standard' { $expected = 'byok-standard' }
      'power' { $roles = @('Byok.Power'); $expected = 'byok-power' }
      'unrelated-role' { $roles += 'Unrelated.Reader'; $expected = 'byok-standard' }
      'same-tier-alias' { $selected.mappings += @{claimValue = 'Byok.Alias'; tier = 'byok-standard'}; $roles += 'Byok.Alias'; $expected = 'byok-standard' }
      'conflicting-tiers' { $roles += 'Byok.Power' }
      'reverse-conflict' { $roles = @('Byok.Power', 'Byok.Standard') }
      'duplicate-role' { $roles += 'Byok.Standard' }
      'no-matched-role' { $roles = @('Unrelated.Reader') }
      'empty-role' { $roles = @('') }
      'role-case' { $roles = @('byok.standard') }
      'scalar-role' { if ($method -ceq 'oktaJwt') { $expected = 'byok-standard' } }
      'unvalidated' { $context.Variables['byokJwtValidated'] = $false }
      'unauthenticated' { $context.Variables['byokCallerAuthenticated'] = $false }
      'native-accounting' { $context.Variables['byokCallerAccountingMode'] = 'native' }
      'wrong-method' { $context.Variables['callerAuthMethod'] = 'unknown' }
      'wrong-issuer' { $context.Variables['callerIssuer'] = 'https://other.example.test' }
      'provider-disabled' { $selected.enabled = $false; $roles = @('Byok.Standard', 'Byok.Power'); $expected = '__flat__' }
      'other-provider-disabled' { $other.enabled = $false; $expected = 'byok-standard' }
      'wrong-version' { $configuration.version = 2 }
      'unknown-config-field' { $configuration.unexpected = $true }
      'non-boolean-flag' { $selected.enabled = 'true' }
      'unknown-tier' { $selected.mappings[0].tier = 'unknown' }
      'duplicate-mapping' { $selected.mappings += @{claimValue = 'Byok.Standard'; tier = 'byok-power'} }
      'missing-mapping' { $selected.mappings = @() }
      'reserved-claim' { $selected.claimName = 'sub' }
      'duplicate-tier' { $configuration.tiers += 'byok-standard' }
      'unsafe-tier' { $configuration.tiers[0] = 'unsafe"tier' }
      'non-string-mapping' { $selected.mappings[0].claimValue = 7 }
      'tier-change' { $expected = 'byok-standard' }
      'token-renewal' { $expected = 'byok-standard' }
    }
    $token.Claims[$claimName] = [string[]]$roles
    $payload = @{iss = $token.Issuer; sub = 'fixture-user'; exp = 2000000000; $claimName = $roles}
    switch ($case) {
      'missing-role' { $payload.Remove($claimName); $null = $token.Claims.Remove($claimName) }
      'scalar-role' { $payload[$claimName] = 'Byok.Standard' }
      'non-string-role' { $payload[$claimName] = @(7) }
      'object-role' { $payload[$claimName] = @{value = 'Byok.Standard'} }
      'projection-mismatch' { $payload[$claimName] = @('Byok.Power') }
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 8 -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $context.Variables['byokJwtToken'] = 'fixture.' + $encoded + '.signature'
    if ($case -ceq 'invalid-token') { $context.Variables['byokJwtToken'] = 'not-a-token' }
    $context.Variables['parsedJwt'] = $token
    $context.Settings['caller-jwt-tiering-config'] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($configuration | ConvertTo-Json -Depth 8 -Compress)))
    if ($case -ceq 'bad-config') { $context.Settings['caller-jwt-tiering-config'] = 'invalid-base64' }
    if ($guardType::Tier($context) -cne $expected) { throw ('JWT tier resolution failed: ' + $method + '/' + $case) }
    if ($case -ceq 'tier-change') {
      $selected.mappings[0].tier = 'byok-power'
      $context.Settings['caller-jwt-tiering-config'] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($configuration | ConvertTo-Json -Depth 8 -Compress)))
      if ($guardType::Tier($context) -cne 'byok-power') { throw 'Changing the deployment tier map did not change the selected tier.' }
    }
    if ($case -ceq 'token-renewal') {
      $payload.exp = 2000003600
      $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 8 -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
      $context.Variables['byokJwtToken'] = 'fixture.' + $encoded + '.renewed-signature'
      if ($guardType::Tier($context) -cne $expected) { throw 'Renewal changed the selected tier.' }
    }
    if ($context.Variables['callerPrincipalKey'] -cne $principal -or $context.Variables['byokResponseOwnerMarkers'] -cne 'unchanged-owner-marker') { throw 'Tier resolution mutated counter or ownership identity.' }
    $tierChecked++
  }
}
if ($tierSelection.SelectNodes('//base|//include-fragment|//send-request|//authentication-managed-identity|//rate-limit-by-key|//quota-by-key').Count -or
    $tierSelection.SelectNodes('/fragment/set-variable').Count -ne 1 -or $tierSelection.OuterXml.Contains('context.Request') -or
    $tierSelection.SelectSingleNode('//return-response/set-status').GetAttribute('code') -cne '403') { throw 'Tier selection changed identity, performed IO or trusted client request data.' }
Write-Output ('PASS: ' + $tierChecked + ' default-off Entra/Okta tier selector cases; immutable counter/owner identities and no provider requests.')
if ($RenderedConsumerPolicyPath) {
  $tierFixtures = (Get-Content -LiteralPath $RenderedConsumerPolicyPath -Raw | ConvertFrom-Json -Depth 40).parameters.callerTierLimits.value
  if (@($tierFixtures).Count -ne 4) { throw 'Expected disabled, Entra, Okta and dual-issuer tier render fixtures.' }
  $flatSource = Get-Content -LiteralPath (Join-Path $root 'policies/fragments/byok-apply-caller-limits.xml') -Raw
  foreach ($fixture in $tierFixtures) {
    if ($fixture.name -ceq 'disabled') {
      if ($fixture.policy -cne $flatSource) { throw 'Disabled tiering changed the existing caller-limit policy bytes.' }
      continue
    }
    [xml]$tierPolicyDocument = $fixture.policy
    if ($CallerPackagePath) {
      $packagedBranches = foreach ($tier in @(@{name = 'byok-standard'; calls = '60'; tokens = '100000'; quota = '50000'}, @{name = 'byok-power'; calls = '120'; tokens = '200000'; quota = '200000'})) {
        $encodedName = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($tier.name))
        $package.tiering.branchTemplate.Replace('__BYOK_TIER_NAME__', $encodedName).Replace('{{jwt-calls-per-minute}}', $tier.calls).Replace('{{jwt-tokens-per-minute}}', $tier.tokens).Replace('{{jwt-monthly-call-quota}}', $tier.quota)
      }
      $packagedPolicy = $package.tiering.policyTemplate.Replace('__BYOK_JWT_TIERING_CONFIG__', $fixture.configuration).Replace('__BYOK_JWT_TIER_BRANCHES__', ($packagedBranches -join ''))
      if ($packagedPolicy -cne $fixture.policy) { throw 'External package tier composition differs from the canonical Bicep renderer.' }
    }
    $branch = $tierPolicyDocument.SelectSingleNode('/fragment/choose/when[contains(@condition, "jwt")]')
    $selector = $branch.SelectSingleNode('set-variable[@name="byokCallerTier"]')
    $expectedExpression = $tierSelection.SelectSingleNode('/fragment/set-variable').GetAttribute('value').Replace('__BYOK_JWT_TIERING_CONFIG__', $fixture.configuration)
    if ($null -eq $selector -or $selector.GetAttribute('value') -cne $expectedExpression -or $tierPolicyDocument.SelectNodes('//include-fragment|//base').Count) { throw 'The compiled limiter must inline the exact tested selector without nested fragments.' }
    $choices = @($branch.SelectNodes('choose[2]/when'))
    if ($choices.Count -ne 3 -or $branch.SelectSingleNode('choose[1]/when/return-response/set-status').GetAttribute('code') -cne '403' -or
        $branch.SelectSingleNode('choose[2]/otherwise/return-response/set-status').GetAttribute('code') -cne '403') { throw 'Tier selection must deny before choosing one flat/standard/power branch.' }
    $limits = @(@('60', '100000', '50000'), @('120', '200000', '200000'))
    for ($tierIndex = 0; $tierIndex -lt 2; $tierIndex++) {
      $choice = $choices[$tierIndex + 1]
      $checks = @(@('rate-limit-by-key', 'calls'), @('azure-openai-token-limit', 'tokens-per-minute'), @('quota-by-key', 'calls'))
      for ($limitIndex = 0; $limitIndex -lt $checks.Count; $limitIndex++) {
        $node = $choice.SelectSingleNode($checks[$limitIndex][0])
        if ($node.GetAttribute($checks[$limitIndex][1]) -cne $limits[$tierIndex][$limitIndex] -or $node.GetAttribute('counter-key') -cne '@((string)context.Variables["callerPrincipalKey"])') { throw 'A tier ceiling or immutable principal counter was changed by rendering.' }
      }
      if ($choice.SelectSingleNode('rate-limit-by-key').GetAttribute('renewal-period') -cne '60' -or
          $choice.SelectSingleNode('quota-by-key').GetAttribute('renewal-period') -cne '2592000' -or
          $choice.SelectSingleNode('rate-limit-by-key').GetAttribute('increment-condition') -cne '@(context.Response.StatusCode == 200)' -or
          $choice.SelectSingleNode('azure-openai-token-limit').GetAttribute('estimate-prompt-tokens') -cne 'true') { throw 'Tier rendering changed accounting windows, successful-call increments or prompt estimation.' }
    }
    foreach ($node in $tierPolicyDocument.SelectNodes('//rate-limit-by-key|//azure-openai-token-limit|//quota-by-key')) {
      if ($node.GetAttribute('counter-key') -cne '@((string)context.Variables["callerPrincipalKey"])') { throw 'A disabled-provider or tier branch can reset the accounting identity.' }
    }
    if ($tierPolicyDocument.SelectNodes('/fragment/set-variable[@name="byokCallerAccountingApplied"]').Count -ne 1 -or $fixture.policy.Contains('__BYOK_JWT_TIERING_CONFIG__')) { throw 'Tier rendering left unresolved configuration or changed exactly-once accounting.' }
    $tierMetric = $branch.SelectSingleNode('choose[3]/when/emit-metric')
    if ($null -eq $tierMetric -or $tierMetric.name -cne 'copilot_byok_tier_admitted' -or
      ($tierMetric.SelectNodes('dimension').name -join ',') -cne 'auth_method,tier,operation' -or
      $tierMetric.ParentNode.condition -cne '@((string)context.Variables["byokCallerTier"] != "__flat__")' -or
      $tierMetric.OuterXml -match 'parsedJwt|byokJwtToken|callerSubject|callerPrincipalKey|Request\.|claims|groups') { throw 'Tier admission telemetry must follow successful limits and exclude flat callers and identity/claim data.' }
  }
  Write-Output 'PASS: four compiled JWT tier fixtures preserve disabled bytes, inline selection, literal quota ceilings, stable counters and exactly-once accounting.'
  $maximumPolicy = (Get-Content -LiteralPath $RenderedConsumerPolicyPath -Raw | ConvertFrom-Json -Depth 40).parameters.maximumCallerTierLimits.value
  $maximumPolicy = $maximumPolicy.Replace('{{', '{{' + ('p' * 32))
  [xml]$maximumTierDocument = $maximumPolicy
  if ($maximumTierDocument.SelectNodes('/fragment/choose/when[contains(@condition, "jwt")]/choose[2]/when').Count -ne 9 -or
      $maximumTierDocument.SelectNodes('//rate-limit-by-key').Count -ne 9 -or $maximumPolicy.Contains('__BYOK_') -or
      [Text.Encoding]::UTF8.GetByteCount($maximumPolicy) -gt 32768) { throw 'The largest supported tier policy must be complete and remain within the conservative fragment size budget.' }
  Write-Output ('PASS: maximum catalog/mapping fixture stays within the fragment size budget (' + [Text.Encoding]::UTF8.GetByteCount($maximumPolicy) + ' bytes).')
}
$configChecked = 0
foreach ($case in @('key-only', 'entra-only', 'coexistence', 'okta-only', 'all-methods', 'no-methods', 'invalid-flag', 'invalid-module-flag',
  'optional-key-admission', 'empty-product', 'bad-tenant', 'bad-audience', 'wrong-entra-cloud', 'wrong-entra-metadata', 'empty-entra-scope', 'empty-entra-clients',
  'entra-client-is-audience', 'okta-org-server', 'okta-http', 'okta-query', 'okta-user-info', 'okta-port', 'okta-placeholder', 'okta-metadata-mismatch',
  'okta-empty-audience', 'okta-empty-scope', 'okta-any-clients', 'okta-no-clients', 'okta-client-is-audience')) {
  $context = [Activator]::CreateInstance($contextType)
  $audience = [guid]::NewGuid().ToString()
  $entraIssuer = 'https://login.microsoftonline.us/' + $tenant + '/v2.0'
  foreach ($entry in @{
    'caller-configuration-valid' = 'true'; 'caller-key-enabled' = 'true'; 'caller-native-subscription-required' = 'true'
    'caller-entra-enabled' = 'true'; 'caller-okta-enabled' = 'true'; 'caller-jwt-product-id' = 'byok-jwt'
    'caller-entra-login-host' = 'login.microsoftonline.us'; 'caller-entra-tenant-id' = $tenant; 'caller-entra-issuer' = $entraIssuer
    'entra-openid-config-url' = $entraIssuer + '/.well-known/openid-configuration'; 'api-audience' = $audience; 'required-scope' = 'cli.invoke'; 'caller-entra-client-ids' = $client
    'caller-okta-issuer' = 'https://fixture.example.test/oauth2/fixture'; 'caller-okta-openid-config-url' = 'https://fixture.example.test/oauth2/fixture/.well-known/openid-configuration'
    'caller-okta-audience' = 'api://fixture-gateway'; 'caller-okta-required-scope' = 'cli.invoke'; 'caller-okta-client-ids' = 'fixture-client'
  }.GetEnumerator()) { $context.Settings[$entry.Key] = $entry.Value }
  switch ($case) {
    'key-only' { $context.Settings['caller-entra-enabled'] = 'false'; $context.Settings['caller-okta-enabled'] = 'false'; $context.Settings['caller-okta-issuer'] = ''; $context.Settings['caller-entra-issuer'] = '' }
    'entra-only' { $context.Settings['caller-key-enabled'] = 'false'; $context.Settings['caller-native-subscription-required'] = 'false'; $context.Settings['caller-okta-enabled'] = 'false' }
    'coexistence' { $context.Settings['caller-okta-enabled'] = 'false' }
    'okta-only' { $context.Settings['caller-key-enabled'] = 'false'; $context.Settings['caller-native-subscription-required'] = 'false'; $context.Settings['caller-entra-enabled'] = 'false' }
    'no-methods' { $context.Settings['caller-key-enabled'] = 'false'; $context.Settings['caller-native-subscription-required'] = 'false'; $context.Settings['caller-entra-enabled'] = 'false'; $context.Settings['caller-okta-enabled'] = 'false' }
    'invalid-flag' { $context.Settings['caller-key-enabled'] = 'TRUE' }
    'invalid-module-flag' { $context.Settings['caller-configuration-valid'] = 'false' }
    'optional-key-admission' { $context.Settings['caller-native-subscription-required'] = 'false' }
    'empty-product' { $context.Settings['caller-jwt-product-id'] = '' }
    'bad-tenant' { $context.Settings['caller-entra-tenant-id'] = 'bad-tenant' }
    'bad-audience' { $context.Settings['api-audience'] = 'api://not-a-v2-guid' }
    'wrong-entra-cloud' { $context.Settings['caller-entra-login-host'] = 'login.microsoftonline.com' }
    'wrong-entra-metadata' { $context.Settings['entra-openid-config-url'] = 'https://untrusted.example.test/metadata' }
    'empty-entra-scope' { $context.Settings['required-scope'] = '' }
    'empty-entra-clients' { $context.Settings['caller-entra-client-ids'] = '' }
    'entra-client-is-audience' { $context.Settings['caller-entra-client-ids'] = $audience }
    'okta-org-server' { $context.Settings['caller-okta-issuer'] = 'https://fixture.example.test' }
    'okta-http' { $context.Settings['caller-okta-issuer'] = 'http://fixture.example.test/oauth2/fixture' }
    'okta-query' { $context.Settings['caller-okta-issuer'] += '?unsafe=true' }
    'okta-user-info' { $context.Settings['caller-okta-issuer'] = 'https://user@fixture.example.test/oauth2/fixture' }
    'okta-port' { $context.Settings['caller-okta-issuer'] = 'https://fixture.example.test:444/oauth2/fixture' }
    'okta-placeholder' { $context.Settings['caller-okta-issuer'] = 'https://unset.invalid/oauth2/fixture' }
    'okta-metadata-mismatch' { $context.Settings['caller-okta-openid-config-url'] = 'https://other.example.test/.well-known/openid-configuration' }
    'okta-empty-audience' { $context.Settings['caller-okta-audience'] = '' }
    'okta-empty-scope' { $context.Settings['caller-okta-required-scope'] = '' }
    'okta-any-clients' { $context.Settings['caller-okta-client-ids'] = '__any__' }
    'okta-no-clients' { $context.Settings['caller-okta-client-ids'] = '' }
    'okta-client-is-audience' { $context.Settings['caller-okta-client-ids'] = $context.Settings['caller-okta-audience'] }
  }
  $expected = $case -in @('key-only', 'entra-only', 'coexistence', 'okta-only', 'all-methods')
  if ($guardType::Configuration($context) -ne $expected) { throw ('Trust configuration was not fail-closed: ' + $case) }
  $configChecked++
}
Write-Output ('PASS: ' + $configChecked + ' executable cloud/issuer configuration checks; no deployment was performed.')
$shapeChecked = 0
foreach ($case in @('valid', 'scope-array', 'nested-same-property', 'colon-in-string', 'escaped-claim', 'duplicate-issuer', 'escaped-duplicate-issuer',
  'duplicate-subject', 'duplicate-header', 'nested-duplicate', 'array-subject', 'object-subject', 'array-audience', 'string-expiry', 'no-expiry',
  'object-scope', 'non-string-scope-member', 'malformed-json', 'trailing-newline', 'too-long', 'unsigned',
  'duplicate-with-single-quoted-property', 'duplicate-with-unquoted-property', 'commented-payload', 'entra-array-scope', 'okta-scalar-scope')) {
  $headerJson = '{"alg":"RS256","typ":"JWT"}'
  $payload = [ordered]@{ iss = 'https://issuer.example.test'; aud = 'fixture-audience'; sub = 'fixture-user'; exp = 2000000000; scp = 'cli.invoke' }
  switch ($case) {
    'scope-array' { $payload.iss = 'https://okta.example.test/oauth2/fixture'; $payload.scp = @('other', 'cli.invoke') }
    'entra-array-scope' { $payload.scp = @('cli.invoke') }
    'okta-scalar-scope' { $payload.iss = 'https://okta.example.test/oauth2/fixture' }
    'nested-same-property' { $payload.extra = @{ sub = 'nested-subject'; value = @{ sub = 'deeper-subject' } } }
    'colon-in-string' { $payload.extra = 'quoted "iss": value and backslash \\' }
    'array-subject' { $payload.sub = @('fixture-user') }
    'object-subject' { $payload.sub = @{ value = 'fixture-user' } }
    'array-audience' { $payload.aud = @('fixture-audience') }
    'string-expiry' { $payload.exp = '2000000000' }
    'no-expiry' { $payload.Remove('exp') }
    'object-scope' { $payload.scp = @{ value = 'cli.invoke' } }
    'non-string-scope-member' { $payload.scp = @('cli.invoke', 1) }
    'duplicate-header' { $headerJson = '{"alg":"none","alg":"RS256","typ":"JWT"}' }
  }
  $payloadJson = $payload | ConvertTo-Json -Depth 6 -Compress
  switch ($case) {
    'escaped-claim' { $payloadJson = $payloadJson.Replace('"iss":', '"\u0069ss":') }
    'duplicate-issuer' { $payloadJson = $payloadJson.Replace('{"iss":', '{"iss":"https://other.example.test","iss":') }
    'escaped-duplicate-issuer' { $payloadJson = $payloadJson.Replace('{"iss":', '{"\u0069ss":"https://other.example.test","iss":') }
    'duplicate-subject' { $payloadJson = $payloadJson.Replace('"sub":', '"sub":"another-user","sub":') }
    'nested-duplicate' { $payloadJson = $payloadJson.TrimEnd('}') + ',"extra":{"name":1,"name":2}}' }
    'duplicate-with-single-quoted-property' { $payloadJson = $payloadJson.Replace('{"iss":', '{''extra'':0,"iss":"https://other.example.test","iss":') }
    'duplicate-with-unquoted-property' { $payloadJson = $payloadJson.Replace('{"iss":', '{true:0,"iss":"https://other.example.test","iss":') }
    'commented-payload' { $payloadJson = '/* comment */' + $payloadJson }
    'malformed-json' { $payloadJson = '{"iss":' }
  }
  $headerPart = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($headerJson)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
  $payloadPart = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payloadJson)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
  $value = $headerPart + '.' + $payloadPart + '.fixture-signature'
  if ($case -eq 'trailing-newline') { $value += "`n" }
  if ($case -eq 'too-long') { $value = ('a' * 32769) + '.payload.signature' }
  if ($case -eq 'unsigned') { $value = $headerPart + '.' + $payloadPart + '.' }
  $context = [Activator]::CreateInstance($contextType)
  $context.Settings['caller-entra-issuer'] = 'https://issuer.example.test'
  $context.Settings['caller-okta-issuer'] = 'https://okta.example.test/oauth2/fixture'
  $context.Variables['byokJwtToken'] = $value
  $expected = $case -in @('valid', 'scope-array', 'nested-same-property', 'colon-in-string', 'escaped-claim')
  if ($guardType::Shape($context) -ne $expected) { throw ('Ambiguous raw JWT shape was misclassified: ' + $case) }
  $shapeChecked++
}
Write-Output ('PASS: ' + $shapeChecked + ' raw JSON/JWT ambiguity checks; parsing does not replace signature validation.')
$probeParseErrors = $null
$probeAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/probe-jwt-auth-vm.ps1'), [ref]$null, [ref]$probeParseErrors)
if ($probeParseErrors.Count) { throw 'Raw-header probe source does not parse.' }
& {
  $definition=@($probeAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ProbeSharedTelemetryResult'},$false))
  . ([scriptblock]::Create($definition[0].Extent.Text))
  foreach($scenario in @('complete','pending','one-user','missing-identity','counter-drift','duplicate','unknown-throttle')){
    $rows=@(foreach($metric in @('legacy','caller')){foreach($kind in @('burst','tokens','quota')){,@($metric,$kind,4,2,0)}})
    switch($scenario){
      'pending'{$rows=@($rows|Select-Object -Skip 1)}
      'one-user'{$rows[4][3]=1}
      'missing-identity'{$rows[4][4]=1}
      'counter-drift'{$rows[4][2]=3}
      'duplicate'{$rows+=,@($rows[0])}
      'unknown-throttle'{$rows[4][1]='other'}
    }
    $rejected=$false;$result=$null
    try{$result=Get-ProbeSharedTelemetryResult -Rows $rows}catch{$rejected=$true}
    if($rejected -ne ($scenario -in @('duplicate','unknown-throttle')) -or (-not $rejected -and $result.complete -ne ($scenario -eq 'complete'))){throw ('Telemetry evidence evaluator mismatch: '+$scenario)}
  }
  Write-Output 'PASS: seven telemetry evidence cases require both metrics, two identities, matched totals and complete throttle coverage.'
  $state=@{removed=$false;queried=$false}
  function Get-ChildItem {
    param([string]$Path)
    if($Path -cne 'Cert:\LocalMachine\My'){throw 'Unexpected telemetry certificate store.'}
    [pscustomobject]@{Subject='CN=jwt-probe-fixture';PSPath='fixture-certificate'}
  }
  function Unprotect-CmsMessage { 'fixture-query-token' }
  function Remove-Item {
    param([string]$LiteralPath,[switch]$DeleteKey,[switch]$Force)
    if($LiteralPath -cne 'fixture-certificate' -or -not $DeleteKey){throw 'Unexpected telemetry cleanup.'}
    $state.removed=$true
  }
  function Invoke-RestMethod {
    param([string]$Method,[string]$Uri,[hashtable]$Headers,[string]$ContentType,[string]$Body,[int]$TimeoutSec)
    if($Method -cne 'Post' -or $Uri -notlike 'https://api.loganalytics.us/v1/workspaces/*/query' -or $Headers.Authorization -cne 'Bearer fixture-query-token' -or $Body -notmatch 'jwt-probe-fixture:'){throw 'Telemetry query lost its cloud or run scope.'}
    $state.queried=$true
    return @{tables=@(@{rows=@(foreach($metric in @('legacy','caller')){foreach($kind in @('burst','tokens','quota')){,@($metric,$kind,4,2,0)}})})}
  }
  $result=@(& (Join-Path $root 'scripts/probe-jwt-auth-vm.ps1') -Phase SharedTelemetryTest -ProbeId jwt-probe-fixture -TelemetryCloud AzureUSGovernment -TelemetryWorkspaceId ([guid]::NewGuid().ToString()) -ArmResource https://management.core.usgovcloudapi.net/ -ProtectedToken Zml4dHVyZQ== | ForEach-Object {$_|ConvertFrom-Json})
  if(-not $state.queried -or -not $state.removed -or @($result|Where-Object {$_.test -eq 'shared-governance-telemetry' -and $_.complete}).Count -ne 1){throw 'The complete telemetry VM entry point did not query and clean up without a gateway URL.'}
  Write-Output 'PASS: full telemetry VM phase requires no unrelated gateway URL and cleans up its protected transport.'
}
$transportFunction = @($probeAst.FindAll({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Invoke-ProbeWireRequest' }, $false))
if ($transportFunction.Count -ne 1 -or
  -not $transportFunction[0].Extent.Text.Contains('[Net.Dns]::GetHostAddresses($RequestUri.DnsSafeHost)') -or
  -not $transportFunction[0].Extent.Text.Contains('$client.BeginConnect($addresses[0], $RequestUri.Port, $null, $null)') -or
  -not $transportFunction[0].Extent.Text.Contains('$tls.AuthenticateAsClient($RequestUri.DnsSafeHost, $null, [Security.Authentication.SslProtocols]::Tls12, $true)')) { throw 'DNS-resolved transport must retain the original TLS hostname and revocation checks.' }
& {
  $requestFunction = @($probeAst.FindAll({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Test-ProbeGovernanceRequest' }, $true))
  if ($requestFunction.Count -ne 1) { throw 'Expected one governance request evaluator.' }
  . ([scriptblock]::Create($requestFunction[0].Extent.Text))
  $receipts = [Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
  $observations = [Collections.Generic.List[object]]::new()
  $audit = [Collections.Generic.List[object]]::new()
  $fixture = @{}
  function Invoke-ProbeWireRequest {
    param([uri] $RequestUri, [string[]] $HeaderLines, [string] $Method, [string] $Body, [switch] $ReadContent)
    if (-not $ReadContent -or $Method -cne 'GET' -or $RequestUri.AbsoluteUri -cne 'https://gateway.example.test/fixture' -or $HeaderLines[-1] -notmatch '\AX-Probe-Case: ([a-f0-9]{32})\z') { throw 'Governance request lost its bounded transport contract.' }
    $caseId = $Matches[1]
    if ($HeaderLines.Count -ne @($fixture.requestHeaders).Count + 1) { throw 'Credential and correlation headers must remain separate fields for zero, one and multiple credentials.' }
    foreach ($header in $fixture.requestHeaders) { if ($HeaderLines -cnotcontains $header) { throw 'Governance transport changed a credential header value.' } }
    if ($fixture.calls -or $fixture.lookups) { $receipts[$caseId] = @{ calls = $fixture.calls; lookups = $fixture.lookups; stripped = $fixture.stripped } }
    if ($fixture.status -eq 400 -and ($HeaderLines.Count -ne 3 -or $HeaderLines[0] -cne 'Authorization: Bearer fixture-first' -or $HeaderLines[1] -cne 'Authorization: Bearer fixture-second')) { throw 'Two-user raw headers were not serialized as independent fields.' }
    return @{ StatusCode = $fixture.status; Headers = @{ 'X-Probe-Method' = $fixture.method; 'X-Probe-Product' = 'False'; 'X-Probe-Accounted' = 'True' }; Content = '{}' }
  }
  $requestCases = 0
  foreach ($scenario in @('accepted','rejected','leaked-credential','duplicate-receipt','unexpected-receipt','owner-denied','owner-denied-operation','wrong-method','duplicate-rejected','server-error','single-key','single-bearer','single-wire','empty-key','mixed-headers')) {
    $fixture.Clear()
    $fixture.status = 200; $fixture.calls = 1; $fixture.lookups = 0; $fixture.stripped = $true; $fixture.method = 'entraJwt'
    $expected = @(200); $expectedLookups = 0; $wire = $null; $headers = @{}
    switch ($scenario) {
      'rejected' { $fixture.status = 401; $fixture.calls = 0; $expected = @(401) }
      'leaked-credential' { $fixture.stripped = $false }
      'duplicate-receipt' { $fixture.calls = 2 }
      'unexpected-receipt' { $fixture.status = 401; $expected = @(401) }
      'owner-denied' { $fixture.status = 404; $fixture.calls = 0; $fixture.lookups = 1; $expected = @(404); $expectedLookups = 1 }
      'owner-denied-operation' { $fixture.status = 404; $fixture.lookups = 1; $expected = @(404); $expectedLookups = 1 }
      'wrong-method' { $fixture.method = 'subscriptionKey' }
      'duplicate-rejected' { $fixture.status = 400; $fixture.calls = 0; $expected = @(400,401); $wire = @('Authorization: Bearer fixture-first','Authorization: Bearer fixture-second') }
      'server-error' { $fixture.status = 500; $fixture.calls = 0; $expected = @(401) }
      'single-key' { $headers = @{ 'api-key' = 'fixture-key' } }
      'single-bearer' { $headers = @{ Authorization = 'Bearer fixture-first' } }
      'single-wire' { $wire = @('Authorization: Bearer fixture-first') }
      'empty-key' { $headers = @{ 'api-key' = '' }; $fixture.status = 401; $fixture.calls = 0; $expected = @(401) }
      'mixed-headers' { $headers = @{ 'api-key' = 'fixture-key'; Authorization = 'Bearer fixture-first' }; $fixture.status = 401; $fixture.calls = 0; $expected = @(401) }
    }
    $fixture.requestHeaders = @(if ($wire) { $wire } else { $headers.GetEnumerator() | ForEach-Object { $_.Key + ': ' + $_.Value } })
    $result = Test-ProbeGovernanceRequest -Name $scenario -Uri 'https://gateway.example.test/fixture' -ExpectedStatus $expected -ExpectedLookups $expectedLookups -ExpectedMethod 'entraJwt' -ExpectedProduct 'False' -Wire $wire -Headers $headers
    if ($result.observation.passed -ne ($scenario -in @('accepted','rejected','owner-denied','duplicate-rejected','single-key','single-bearer','single-wire','empty-key','mixed-headers'))) { throw ('Governance evaluator accepted a wrong receipt/status/identity contract: ' + $scenario) }
    $requestCases++
  }
  if ($audit.Count -ne $requestCases -or $observations.Count -ne $requestCases) { throw 'Governance evaluator did not retain every result for the final receipt audit.' }
  Write-Output ('PASS: ' + $requestCases + ' governance receipt/status/identity checks, including two independent raw user-token fields; no network requests.')
}
& {
  foreach ($name in @('Get-ProbeRealResponseDocument','New-RealResponseBody','Invoke-RealResponseCreation','Assert-RealResponseStatus')) {
    $definition=@($probeAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
    if($definition.Count -ne 1){throw 'Expected one bounded real-response helper.'}
    . ([scriptblock]::Create($definition[0].Extent.Text))
  }
  $settings=@{model='gpt-5-fixture'};$ProbeId='jwt-probe-fixture'
  $body=New-RealResponseBody -Background
  if($body.max_output_tokens -ne 256 -or -not $body.store -or -not $body.background -or -not $body.stream -or
    $body.reasoning.effort -cne 'low' -or @($body.tools).Count -ne 1){throw 'Real test must preserve tools/reasoning and enable stored background streaming within its token bound.'}
  $fixture=@{status=200;calls=0;ledger=@();content=''}
  $responseJson=@{id='resp_fixture';object='response';metadata=@{byok_owner_v1=('v1.'+('a'*64));acceptance=$ProbeId}}|ConvertTo-Json -Depth 6 -Compress
  function Save-RealResponseState {$fixture.ledger+=,($state|ConvertTo-Json -Depth 10 -Compress);'encrypted-fixture'}
  function Invoke-RealResponseRequest {
    param([string]$Method,[string]$Path,[string]$Caller,[object]$Body)
    if($Method -cne 'POST' -or $Path -cne '/v1/responses' -or -not $state.unknownCreation -or $fixture.ledger.Count -lt 1){throw 'Creation must persist its attempt before sending exactly one POST.'}
    $fixture.calls++
    return @{StatusCode=$fixture.status;Content=$fixture.content}
  }
  foreach($scenario in @('json','stream','denied','uncertain','budget-exhausted','prior-uncertain','bad-id')) {
    $state=[pscustomobject]@{owner=$ProbeId;attempts=0;unknownCreation=$false;items=@()}
    $observations=[Collections.Generic.List[object]]::new()
    $fixture.status=200;$fixture.calls=0;$fixture.ledger=@();$fixture.content=$responseJson
    $expected=200
    switch($scenario){
      'stream' {$fixture.content='event: response.created'+"`ndata: "+(@{type='response.created';response=($responseJson|ConvertFrom-Json)}|ConvertTo-Json -Depth 10 -Compress)+"`n`n"}
      'denied' {$fixture.status=404;$fixture.content='{}';$expected=404}
      'uncertain' {$fixture.status=0;$fixture.content=''}
      'budget-exhausted' {$state.attempts=4}
      'prior-uncertain' {$state.unknownCreation=$true}
      'bad-id' {$fixture.content='{"id":"wrong","object":"response","metadata":{}}'}
    }
    $failed=$false
    try{$null=Invoke-RealResponseCreation -Name 'fixture-create' -Caller first -Body $body -Expected $expected}catch{$failed=$true}
    $sent=$scenario -notin @('budget-exhausted','prior-uncertain')
    if($fixture.calls -ne [int]$sent -or $failed -ne ($scenario -in @('uncertain','budget-exhausted','prior-uncertain','bad-id')) -or
      ($sent -and $state.attempts -ne 1) -or ($scenario -in @('json','stream') -and (@($state.items).Count -ne 1 -or $state.unknownCreation)) -or
      ($scenario -eq 'denied' -and $state.unknownCreation) -or ($scenario -in @('uncertain','bad-id') -and -not $state.unknownCreation)){throw ('Real creation budget/recovery invariant failed: '+$scenario)}
  }
  Write-Output 'PASS: seven real-response creation budget/ledger cases, JSON/SSE identity extraction and retained tools/reasoning; no model call.'
}
$wireFunction = @($probeAst.FindAll({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'New-ProbeWireRequest' }, $false))
if ($wireFunction.Count -ne 1) { throw 'Expected one raw-header serializer; do not execute the VM probe to import it.' }
. ([scriptblock]::Create($wireFunction[0].Extent.Text))
$wireChecked = 0
foreach ($headerLines in @(
  @{ lines = @('Authorization: Bearer fixture-first') },
  @{ lines = @('Authorization: Bearer fixture-first', 'Authorization: Bearer fixture-first') },
  @{ lines = @('Authorization: Bearer fixture-first', 'authorization: Bearer fixture-first') },
  @{ lines = @('Authorization: Bearer fixture-first', 'Authorization: Bearer fixture-second') },
  @{ lines = @('Authorization: Bearer fixture-second', 'Authorization: Bearer fixture-first') },
  @{ lines = @('Authorization: Bearer fixture-first,Bearer fixture-first') }
)) {
  $wire = New-ProbeWireRequest -RequestUri 'https://gateway.example.test/fixture/check' -HeaderLines $headerLines.lines
  $expected = "GET /fixture/check HTTP/1.1`r`nHost: gateway.example.test`r`nConnection: close`r`n" + ($headerLines.lines -join "`r`n") + "`r`n`r`n"
  if ($wire -cne $expected -or [Text.Encoding]::ASCII.GetString([Text.Encoding]::ASCII.GetBytes($wire)) -cne $expected) { throw 'Raw HTTP/1.1 serializer changed header count, case, order or framing.' }
  $wireChecked++
}
foreach ($invalid in @(
  @{ uri = 'http://gateway.example.test/fixture/check'; headers = @('Authorization: Bearer fixture-first') },
  @{ uri = 'https://gateway.example.test/fixture/check'; headers = @("Authorization: Bearer fixture-first`r`nX-Injected: invalid") }
)) {
  $rejected = $false
  try { $null = New-ProbeWireRequest -RequestUri $invalid.uri -HeaderLines $invalid.headers } catch { $rejected = $true }
  if (-not $rejected) { throw 'Raw-header serializer accepted an unsafe transport or injected header line.' }
  $wireChecked++
}
Write-Output ('PASS: ' + $wireChecked + ' raw HTTP/1.1 probe serialization checks; no socket, credential or gateway request was used.')
& {
  $responseFunction = @($probeAst.FindAll({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Read-ProbeWireResponse' }, $false))
  . ([scriptblock]::Create($responseFunction[0].Extent.Text))
  $json = '{"fixture":"' + [char]0x00e9 + '"}'
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  $bodyWire = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
  $post = New-ProbeWireRequest -RequestUri 'https://gateway.example.test/check' -HeaderLines @('api-key: fixture') -Method POST -Body $json
  if (-not $post.Contains('Content-Length: ' + $bytes.Length) -or -not $post.EndsWith("`r`n`r`n" + $json, [StringComparison]::Ordinal)) { throw 'POST body length must count UTF-8 bytes.' }
  $emptyPost = New-ProbeWireRequest -RequestUri 'https://gateway.example.test/check' -HeaderLines @('api-key: fixture') -Method POST
  if (-not $emptyPost.Contains("`r`nContent-Length: 0`r`n`r`n") -or $emptyPost.Contains('Content-Type:') -or
    -not $emptyPost.EndsWith("`r`n`r`n", [StringComparison]::Ordinal)) { throw 'Bodyless POST must explicitly declare zero length without adding a JSON payload.' }
  foreach ($scenario in @('length','chunked','closed','interim','no-content','short','too-large','duplicate-length','ambiguous','short-chunk','invalid-utf8')) {
    $wire = "HTTP/1.1 200 OK`r`nContent-Length: $($bytes.Length)`r`n`r`n$bodyWire"
    switch ($scenario) {
      'chunked' { $wire = "HTTP/1.1 200 OK`r`nTransfer-Encoding: chunked`r`n`r`n$($bytes.Length.ToString('x'))`r`n$bodyWire`r`n0`r`n`r`n" }
      'closed' { $wire = "HTTP/1.1 200 OK`r`n`r`n$bodyWire" }
      'interim' { $wire = "HTTP/1.1 100 Continue`r`n`r`n$wire" }
      'no-content' { $wire = "HTTP/1.1 204 No Content`r`n`r`n" }
      'short' { $wire = "HTTP/1.1 200 OK`r`nContent-Length: 5`r`n`r`nx" }
      'too-large' { $wire = "HTTP/1.1 200 OK`r`nContent-Length: 131073`r`n`r`n" }
      'duplicate-length' { $wire = "HTTP/1.1 200 OK`r`nContent-Length: 0`r`nContent-Length: 1`r`n`r`n" }
      'ambiguous' { $wire = "HTTP/1.1 200 OK`r`nContent-Length: 0`r`nTransfer-Encoding: chunked`r`n`r`n0`r`n`r`n" }
      'short-chunk' { $wire = "HTTP/1.1 200 OK`r`nTransfer-Encoding: chunked`r`n`r`n2`r`nx" }
      'invalid-utf8' { $wire = "HTTP/1.1 200 OK`r`nContent-Length: 1`r`n`r`n" + [char]0xff }
    }
    $reader = [IO.StringReader]::new($wire)
    $failed = $false
    try { $result = Read-ProbeWireResponse -Reader $reader -ReadContent } catch { $failed = $true } finally { $reader.Dispose() }
    $valid = $scenario -in @('length','chunked','closed','interim','no-content')
    if ($failed -eq $valid -or ($valid -and $result.Content -cne $(if ($scenario -eq 'no-content') { '' } else { $json }))) { throw ('Bounded wire response framing failed: ' + $scenario) }
  }
  Write-Output 'PASS: UTF-8 and bodyless POST framing plus 11 bounded HTTP response cases, including chunked SSE transport; strict TLS is unchanged.'
}
& {
  $definition = @($probeAst.FindAll({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Get-ProbeAdmissionResult' }, $false))
  if ($definition.Count -ne 1) { throw 'Expected one admission acceptance evaluator.' }
  . ([scriptblock]::Create($definition[0].Extent.Text))
  $acceptanceChecked = 0
  foreach ($scenario in @('normalized-valid', 'identical-400', 'identical-401', 'conflict-400', 'conflict-401',
    'conflict-200', 'expired-400', 'tampered-401', 'expired-200', 'tampered-200', 'two-users-200', 'two-users-400', 'two-users-401',
    'missing-validation', 'missing-stripping', 'missing-receipt', 'duplicate-receipt', 'credentials-forwarded', 'rejected-backend-receipt',
    'rejected-validated-context', 'unexpected-403', 'transport-failure', 'server-error', 'single-valid-401', 'single-invalid-400',
    'combined-400', 'duplicate-key-400', 'mixed-source-400', 'misnamed-conflict', 'h2-identical-401', 'mixed-case-identical',
    'h2-two-users-401', 'two-users-same-credential', 'two-users-last-400', 'two-users-last-200')) {
    $case = @{ name = 'wire-duplicate-bearer'; expected = 200; context = '0101'; wire = @('Authorization: Bearer fixture-first', 'Authorization: Bearer fixture-first') }
    $status = 200
    $headers = @{ 'X-Probe-Context' = '0101'; 'X-Probe-Stripped' = 'True'; 'X-Probe-Backend' = 'received' }
    $receipt = [pscustomobject]@{ count = 1; stripped = $true }
    $expected = $scenario -in @('normalized-valid', 'identical-400', 'identical-401', 'conflict-400', 'conflict-401',
      'expired-400', 'tampered-401', 'two-users-400', 'two-users-401', 'h2-identical-401', 'mixed-case-identical', 'h2-two-users-401', 'two-users-last-400')
    if ($scenario -match '(400|401|403)\z') { $status = [int]$Matches[1]; $headers = @{}; $receipt = $null }
    switch -Regex ($scenario) {
      '^conflict-' { $case.name = 'wire-bearer-valid-first'; $case.expected = 400; $case.wire[1] = 'Authorization: Bearer fixture-invalid' }
      '^expired-' { $case.name = 'wire-duplicate-expired'; $case.expected = 401 }
      '^tampered-' { $case.name = 'wire-duplicate-tampered'; $case.expected = 401 }
      '^two-users-' { $case.name = 'wire-two-users-first'; $case.expected = 400; $case.wire[1] = 'Authorization: Bearer fixture-second' }
    }
    switch ($scenario) {
      'missing-validation' { $headers['X-Probe-Context'] = '0100' }
      'missing-stripping' { $headers.Remove('X-Probe-Stripped') }
      'missing-receipt' { $receipt = $null }
      'duplicate-receipt' { $receipt.count = 2 }
      'credentials-forwarded' { $receipt.stripped = $false }
      'rejected-backend-receipt' { $status = 401 }
      'rejected-validated-context' { $status = 401; $receipt = $null; $headers.Remove('X-Probe-Backend') }
      'transport-failure' { $status = 0; $headers = @{}; $receipt = $null }
      'server-error' { $status = 500; $headers = @{}; $receipt = $null }
      'single-valid-401' { $case.name = 'wire-single-bearer'; $case.wire = @('Authorization: Bearer fixture-first') }
      'single-invalid-400' { $case.name = 'tampered'; $case.expected = 401 }
      'combined-400' { $case.name = 'duplicate-bearer'; $case.expected = 401; $case.wire = @('Authorization: Bearer fixture-first,Bearer fixture-first') }
      'duplicate-key-400' { $case.name = 'wire-duplicate-key'; $case.expected = 401; $case.wire = @('api-key: fixture-key', 'api-key: fixture-key') }
      'mixed-source-400' { $case.wire[1] = 'api-key: fixture-key' }
      'misnamed-conflict' { $case.wire[1] = 'Authorization: Bearer fixture-second' }
      'h2-identical-401' { $case.name = 'h2-wire-duplicate-bearer' }
      'mixed-case-identical' { $case.name = 'wire-duplicate-bearer-case'; $case.wire[1] = 'authorization: Bearer fixture-first' }
      'h2-two-users-401' { $case.name = 'h2-wire-two-users-first'; $case.expected = 400; $case.wire[1] = 'Authorization: Bearer fixture-second' }
      'two-users-same-credential' { $status = 401; $headers = @{}; $receipt = $null; $case.wire[1] = $case.wire[0] }
      'two-users-last-400' { $case.name = 'wire-two-users-last'; $case.wire = @('Authorization: Bearer fixture-second', 'Authorization: Bearer fixture-first') }
      'two-users-last-200' { $case.name = 'wire-two-users-last'; $case.wire = @('Authorization: Bearer fixture-second', 'Authorization: Bearer fixture-first') }
    }
    $verdict = Get-ProbeAdmissionResult -Case $case -Status $status -ResponseHeaders $headers -Expanded $true -BackendGate $true -Receipt $receipt
    if ($verdict.passed -ne $expected) { throw ('Duplicate-header exception changed a security invariant: ' + $scenario) }
    if ($expected -and $verdict.expectedReceipt -ne ($status -eq 200)) { throw 'Duplicate-header exception changed the final receipt audit expectation.' }
    $acceptanceChecked++
  }
  Write-Output ('PASS: ' + $acceptanceChecked + ' revised duplicate-Authorization acceptance checks; single-credential and backend-isolation requirements remain strict.')
}
$policyValidation = @(& (Join-Path $root 'scripts/probe-jwt-auth.ps1') -Cloud AzureCloud -ResourceGroup fixture -ApimName fixture -VmName fixture -HeaderParityGate -ValidateOnly)
if ($policyValidation.Count -ne 1 -or $policyValidation[0] -cne 'PASS: three isolated inert header policies; no inheritance, validators or backend calls.') { throw 'Inert parity policy validation failed.' }
Write-Output 'PASS: no-backend parity policy generation for blind, array and joined observations.'
$meteringValidation = @(& (Join-Path $root 'scripts/probe-jwt-auth.ps1') -Cloud AzureCloud -ResourceGroup fixture -ApimName fixture -VmName fixture -AnthropicMeteringGate -ValidateOnly)
if ($meteringValidation.Count -ne 1 -or $meteringValidation[0] -cne 'PASS: synthetic token-metering policies target only the supplied mock and preserve streaming.') { throw 'Synthetic metering policy validation failed.' }
Write-Output 'PASS: isolated OpenAI/Anthropic token-metering policy generation; no model or cloud call was made.'
$runtimeValidation = @(& (Join-Path $root 'scripts/probe-jwt-auth.ps1') -Cloud AzureCloud -ResourceGroup fixture -ApimName fixture -VmName fixture -SharedRuntimeGate -ValidateOnly)
if ($runtimeValidation.Count -ne 1 -or $runtimeValidation[0] -cne 'PASS: eight actual shared runtime fragments flattened without Azure or model calls.') { throw 'Actual shared fragment runtime fixture preparation failed.' }
Write-Output 'PASS: actual auth/accounting/ownership runtime fragment preparation; no cloud operation was made.'
& {
  $orchestratorErrors = $null
  $orchestratorAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/probe-jwt-auth.ps1'), [ref]$null, [ref]$orchestratorErrors)
  if ($orchestratorErrors.Count) { throw 'Parity orchestrator source does not parse.' }
  foreach ($name in @('New-ProbeHeaderParityPolicy', 'Invoke-ProbeHeaderParityGate', 'Set-ProbeSharedRuntimePolicy', 'New-ProbeSharedConsumerPolicies', 'New-ProbeSharedRuntimeFragments', 'New-ProbeSharedGovernancePolicies', 'New-ProbeRealResponsesPolicies', 'Remove-ProbeGovernanceProductLinks', 'Resolve-ProbeSecondUserToken')) {
    $definition = @($orchestratorAst.FindAll({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $name }, $false))
    if ($definition.Count -ne 1) { throw 'Expected one testable parity lifecycle definition.' }
    . ([scriptblock]::Create($definition[0].Extent.Text))
  }
  $secureFixture = ConvertTo-SecureString 'synthetic-credential' -AsPlainText -Force
  $providerState = @{ calls = 0 }
  $provider = { $providerState.calls++; $secureFixture }
  if ($providerState.calls -ne 0 -or (Resolve-ProbeSecondUserToken -Provider $provider) -isnot [securestring] -or $providerState.calls -ne 1 -or
    (Resolve-ProbeSecondUserToken -Token $secureFixture) -isnot [securestring]) { throw 'Delayed second-user acquisition must occur exactly once and keep captured-token compatibility.' }
  foreach ($invalid in @(@{ Provider = { 'plaintext' } }, @{ Provider = { $null } }, @{ Provider = { $secureFixture; $secureFixture } },
    @{ Provider = { [securestring]::new() } }, @{ Provider = { throw 'synthetic-private-value' } }, @{ Token = $secureFixture; Provider = $provider })) {
    $failure = ''
    try { $null = Resolve-ProbeSecondUserToken @invalid } catch { $failure = $_.Exception.Message }
    if (-not $failure -or $failure.Contains('synthetic-private-value')) { throw 'Delayed second-user credentials must reject ambiguous/empty/plaintext results and suppress provider errors.' }
  }
  $governanceDefinition = @($orchestratorAst.FindAll({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Invoke-ProbeSharedGovernanceGate' }, $false))[0].Extent.Text
  if ($governanceDefinition.IndexOf('Resolve-ProbeSecondUserToken', [StringComparison]::Ordinal) -lt $governanceDefinition.IndexOf('Phase=Prepare', [StringComparison]::Ordinal) -or
    -not $governanceDefinition.Contains('[DateTimeOffset]::UtcNow.AddMinutes(15)')) { throw 'Token acquisition must follow fixture/certificate setup without weakening the freshness gate.' }
  if (-not $governanceDefinition.Contains('/namedValues/api-app-id-uri') -or -not $governanceDefinition.Contains('--scope $delegatedScope') -or
    $governanceDefinition.Contains("'/.default'")) { throw 'Measured governance credentials must use the same explicit delegated scope as the refresher, not another cached default-scope token.' }
  if (-not $governanceDefinition.Contains('$limits.fragment.InnerXml') -or $governanceDefinition.Contains('-byok-apply-caller-limits-')) { throw 'Limiter fixtures must inline the actual source rather than creating redundant fragment resources.' }
  Write-Output 'PASS: delayed two-user token acquisition occurs after setup, returns only SecureString and retains the fifteen-minute freshness gate.'
  if ($RenderedConsumerPolicyPath) {
    $dryRun = @(& (Join-Path $root 'scripts/probe-jwt-auth.ps1') -Cloud AzureCloud -ResourceGroup fixture -ApimName fixture -VmName fixture -SharedRuntimeGate -SharedGovernanceGate -SharedConsumerPolicyPath $RenderedConsumerPolicyPath -SecondUserToken (ConvertTo-SecureString 'fixture-user-token' -AsPlainText -Force) -ValidateOnly)
    if ($dryRun.Count -ne 1 -or $dryRun[0] -cne 'PASS: eight actual shared runtime fragments flattened without Azure or model calls.') { throw 'The isolated shared governance argument contract rejected its second-user fixture.' }
    $renderedConsumers = (Get-Content -LiteralPath $RenderedConsumerPolicyPath -Raw | ConvertFrom-Json -Depth 30).parameters.policies.value
    $standalone = (Get-Content -LiteralPath $RenderedConsumerPolicyPath -Raw | ConvertFrom-Json -Depth 30).parameters.standalone.value
    foreach ($method in @('true','false')) {
      foreach ($kind in @('inference','models','responses')) {
        $policyText = $standalone.$kind.Replace('__NATIVE_SUBSCRIPTION_REQUIRED__',$method)
        $executable = [regex]::Replace($policyText,'(?s)<!--.*?-->','')
        if ($executable.Contains('fragment-id="byok-') -or $executable -match '\{\{(?:caller-|entra-|api-audience|required-scope|jwt-)' -or
          -not $executable.Contains('fragment-id="intellij-byok-authenticate"')) { throw 'Standalone consumers must isolate their shared fragment/named-value namespace.' }
        if ($kind -eq 'inference') {
          $order=@('fragment-id="intellij-byok-authenticate"','<base />','fragment-id="intellij-byok-apply-caller-limits"','fragment-id="intellij-byok-strip-caller-credentials"','fragment-id="intellij-byok-response-owner-context"','name="pathHasDeployment"')
          $previous=-1
          foreach($marker in $order){$position=$executable.IndexOf($marker,[StringComparison]::Ordinal);if($position -le $previous){throw 'Standalone inference auth/accounting/ownership ordering changed.'};$previous=$position}
        } else {
          $inbound=[regex]::Match($executable,'(?s)<inbound>(.*?)</inbound>')
          if (-not $inbound.Success -or $inbound.Groups[1].Value -match '<base\s*/>|<(?:rate-limit-by-key|quota-by-key|azure-openai-token-limit)\b' -or $executable.Contains('context.Request.Body')) { throw 'Standalone bodyless operations must bypass inference accounting/parsing.' }
          if ($kind -eq 'responses') { [xml]$bodyless=$executable; if ($bodyless.SelectNodes('//include-fragment').Count -ne 4) { throw 'Standalone Responses must retain all explicit auth/ownership components.' } }
        }
      }
    }
    Write-Output 'PASS: standalone shared inference/discovery/Responses preserve namespace, native admission binding and bodyless ownership contracts.'
    $deniedConsumers = @(New-ProbeSharedConsumerPolicies -Policies $renderedConsumers -Owner 'jwt-probe-fixture')
    foreach ($consumer in $deniedConsumers) {
      if ($consumer.value -notmatch '<inbound><return-response><set-status code="403"' -or
        -not $consumer.value.Contains('<value>jwt-probe-fixture:' + $consumer.name + '</value>') -or
        $consumer.value.Contains('fragment-id="byok-') -or $consumer.value -match '__NATIVE_SUBSCRIPTION_REQUIRED__|__SHARED_AUTHENTICATION__') { throw 'Compiled consumer isolation lost its first-statement denial or owned fragments.' }
    }
    foreach ($scenario in @('missing', 'duplicate', 'format', 'unknown-fragment', 'unbound-admission')) {
      $fixture = $renderedConsumers | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
      switch ($scenario) {
        'missing' { $fixture = @($fixture | Select-Object -Skip 1) }
        'duplicate' { $fixture[1] = $fixture[0] }
        'format' { $fixture[0].format = 'xml' }
        'unknown-fragment' { $fixture[0].value = $fixture[0].value.Replace('fragment-id="byok-authenticate"', 'fragment-id="unowned"') }
        'unbound-admission' { $fixture[0].value = $fixture[0].value.Replace('value="api-key"', 'value="__NATIVE_SUBSCRIPTION_REQUIRED__"') }
      }
      $rejected = $false
      try { $null = New-ProbeSharedConsumerPolicies -Policies $fixture -Owner 'jwt-probe-fixture' } catch { $rejected = $true }
      if (-not $rejected) { throw ('Unsafe consumer fixture accepted: ' + $scenario) }
    }
    Write-Output 'PASS: four actual Bicep-rendered consumer policies are deny-prefixed and isolated; five malformed fixture inventories reject.'
    if($CallerPackagePath){
      $definition=@($orchestratorAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-ProbePackageConsumerPolicies'},$false))
      . ([scriptblock]::Create($definition[0].Extent.Text))
      $package=(Get-Content -LiteralPath $CallerPackagePath -Raw|ConvertFrom-Json -Depth 100).parameters.callerPackage.value
      $packageConsumers=@(New-ProbePackageConsumerPolicies -Package $package -Standalone $standalone -Cloud AzureUSGovernment -SourceRoot (Join-Path $root 'scripts'))
      $allConsumers=@(New-ProbeSharedConsumerPolicies -Policies $renderedConsumers -PackagePolicies $packageConsumers -Owner 'jwt-probe-fixture')
      if($allConsumers.Count -ne 16){throw 'The full package compatibility inventory is incomplete.'}
      foreach($consumer in $allConsumers){
        if($consumer.value -notmatch '<inbound><return-response><set-status code="403"' -or $consumer.value -match 'fragment-id="(?:intellij|wizard-probe)-|\{\{(?:intellij|wizard-probe)-'){throw 'Package compilation must retain first-statement denial and isolated references.'}
      }
      foreach($scenario in @('missing','duplicate')){
        $broken=if($scenario -eq 'missing'){@($packageConsumers|Select-Object -Skip 1)}else{@($packageConsumers|Select-Object -Skip 1)+@($packageConsumers[1])}
        $rejected=$false
        try{$null=New-ProbeSharedConsumerPolicies -Policies $renderedConsumers -PackagePolicies $broken -Owner 'jwt-probe-fixture'}catch{$rejected=$true}
        if(-not $rejected){throw 'Incomplete or duplicate package policy inventory was admitted.'}
      }
      Write-Output 'PASS: all sixteen main/standalone/wizard consumers are compiled from actual sources behind isolated first-statement denials.'
    }
    & {
      $fixtureSourceRoot = Join-Path $root 'scripts'
      $responsesTemplate = (Get-Content -LiteralPath $RenderedConsumerPolicyPath -Raw | ConvertFrom-Json -Depth 30).parameters.ownedResponsesPolicy.value
      $realTemplates = (Get-Content -LiteralPath $RenderedConsumerPolicyPath -Raw | ConvertFrom-Json -Depth 30).parameters
      $realPolicies = New-ProbeRealResponsesPolicies -Owner 'jwt-probe-fixture' -Nonce ('B' * 64) -Model 'gpt-5-fixture' -Inference $realTemplates.realResponsesInferencePolicy.value -Utility $responsesTemplate -Models $realTemplates.realResponsesModelsPolicy.value
      foreach ($entry in $realPolicies.GetEnumerator()) {
        if (-not $entry.Value.Contains('X-Probe-Run') -or $entry.Value.Contains('fragment-id="byok-') -or -not $entry.Value.Contains('fragment-id="jwt-probe-fixture-byok-authenticate"')) { throw 'Real response fixture lost its run-only access guard or isolated shared auth.' }
      }
      if ($realPolicies.inference -match '<retry\b' -or -not $realPolicies.inference.Contains('calls="4"') -or
        -not $realPolicies.inference.Contains('max_output_tokens') -or -not $realPolicies.inference.Contains('copilot_byok_probe_') -or
        -not $realPolicies.inference.Contains('<rewrite-uri template="/openai/v1/responses"')) { throw 'Real response fixture must preserve native routing and bound every potential model creation.' }
      [xml]$realUtility = $realPolicies.utility
      if ($realUtility.SelectNodes('//base|//quota-by-key').Count -or $realUtility.SelectSingleNode('/policies/inbound/rewrite-uri').template -notmatch '/openai/v1/responses/') { throw 'Real utilities must preserve ownership/native paths without inference quotas.' }
      Write-Output 'PASS: actual real-response policies require the diagnostic nonce, cap attempts/output and disable automatic model retries.'
      $mockUrl = 'http://192.0.2.1:18741/jwt-probe-fixture'
      $mockFragments = New-ProbeSharedRuntimeFragments -MockBackendUrl $mockUrl -MockBackendNonce ('A' * 64) -SourceRoot $fixtureSourceRoot
      [xml]$mockLookup = $mockFragments['byok-locate-response-owner']
      if ($mockLookup.SelectNodes('//authentication-managed-identity|//include-fragment').Count -or $mockLookup.SelectNodes('//send-request').Count -ne 1 -or
        -not $mockLookup.SelectSingleNode('//send-request/set-url').InnerText.Contains($mockUrl) -or
        $mockLookup.SelectSingleNode('//set-variable[@name="byokResponseLookupUrl"]').value -notmatch 'configured.Any') { throw 'Ownership mock must retain configured-origin validation and replace only the external credential/transport dependency.' }
      $mockPolicies = New-ProbeSharedGovernancePolicies -Owner 'jwt-probe-fixture' -MockBackendUrl $mockUrl -Nonce ('A' * 64) -ResponsesPolicy $responsesTemplate -SourceRoot $fixtureSourceRoot
      [xml]$mockInference = $mockPolicies.inference
      [xml]$mockUtility = $mockPolicies.utility
      if ($mockInference.SelectSingleNode('/policies/inbound/*[2]').GetAttribute('fragment-id') -cne 'jwt-probe-fixture-byok-authenticate' -or
        $mockInference.SelectSingleNode('/policies/inbound/*[3]').Name -ne 'base' -or
        $mockUtility.SelectNodes('//base').Count -or
        $mockUtility.SelectSingleNode('/policies/inbound/rewrite-uri').template -notmatch '/jwt-probe-fixture/openai/v1/responses/' -or
        $mockUtility.SelectSingleNode('/policies/backend/retry/forward-request').GetAttribute('buffer-response') -ne 'false') { throw 'Governance fixture lost actual auth/ownership ordering or native stream behavior.' }
      Write-Output 'PASS: governance fixture retains actual shared auth/accounting/ownership and isolates only backend credentials/transport.'
      if($CallerPackagePath){
        $operational=New-ProbeSharedGovernancePolicies -Owner 'jwt-probe-fixture' -MockBackendUrl $mockUrl -Nonce ('A'*64) -ResponsesPolicy $responsesTemplate -SourceRoot $fixtureSourceRoot -ThrottleTelemetry $package.throttleTelemetry
        [xml]$telemetryPolicy=$operational.inference
        if($telemetryPolicy.SelectNodes('/policies/on-error/choose/when/emit-metric').Count -ne 2 -or
          $telemetryPolicy.SelectNodes('/policies/on-error//emit-metric').Count -ne 3 -or $telemetryPolicy.SelectNodes('//trace').Count){throw 'Operational fixture lost canonical private throttle metrics.'}
        $tierOperation=$telemetryPolicy.SelectSingleNode('/policies/on-error//emit-metric[@name="copilot_byok_tier_throttled"]/dimension[@name="operation"]')
        if($null -eq $tierOperation -or $tierOperation.value -cne '@("jwt-probe-fixture:" + context.Operation.Id)'){throw 'Tier telemetry is not isolated to the diagnostic operation marker.'}
        $definition=@($orchestratorAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-ProbeRollbackPolicy'},$false))
        . ([scriptblock]::Create($definition[0].Extent.Text))
        foreach($legacy in @($false,$true)){
          [xml]$rollback=New-ProbeRollbackPolicy -Owner 'jwt-probe-fixture' -AuthenticationEntry $package.authenticationEntry -NativeGuard $package.nativeCallerGuard -Legacy:$legacy
          if($rollback.SelectNodes('//forward-request|//send-request|//base|//set-backend-service').Count -or $rollback.SelectNodes('//include-fragment').Count -ne $(if($legacy){0}else{2})){throw 'Rollback admission fixture must never invoke a backend or skip its selected guard.'}
        }
        $definition=@($orchestratorAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-ProbeSharedRollback'},$false))[0].Extent.Text
        if($definition.IndexOf('Remove-ProbeGovernanceProductLinks') -gt $definition.IndexOf('$legacy=New-ProbeRollbackPolicy') -or $definition -notmatch 'ownerKeysUnchanged=\$true'){throw 'Rollback must detach first and verify retained ownership state.'}
        Write-Output 'PASS: operational fixture retains canonical metrics and detach-first/native-only rollback with no backend call.'
      }
    }
  }
  $state = @{}
  function Invoke-ProbeArm {
    param([string] $Method, [string] $Path, [object] $Body, [switch] $AllowNotFound, [hashtable] $RequestHeaders = @{})
    if ($Method -eq 'GET' -and $Path -eq '/fixture-service') {
      return [pscustomobject]@{ properties = [pscustomobject]@{
        provisioningState = 'Succeeded'; virtualNetworkType = 'Internal'; gatewayUrl = 'https://gateway.example.test'
        customProperties = @{'Microsoft.WindowsAzure.ApiManagement.Gateway.Protocols.Server.Http2' = 'False'}
        virtualNetworkConfiguration = @{ subnetResourceId = '/fixture-subnet' }
      } }
    }
    if (-not $Path.StartsWith('/fixture-service/apis/jwt-probe-fixture', [StringComparison]::Ordinal)) { throw 'Parity attempted an out-of-scope ARM request.' }
    if ($Method -eq 'GET') {
      if (-not $AllowNotFound) { throw 'Parity ownership read must distinguish absent resources.' }
      return $state.api
    }
    if ($Method -eq 'PUT') {
      $state.writes++
      if ($Path -eq '/fixture-service/apis/jwt-probe-fixture') {
        if ($Body.properties.subscriptionRequired -ne $false -or $Body.properties.serviceUrl) { throw 'Diagnostic API was not inert.' }
        $state.api = [pscustomobject]@{ name = 'jwt-probe-fixture'; properties = [pscustomobject]$Body.properties }
        if ($state.mode -eq 'create-failure') { throw 'Fixture failure after API creation.' }
      } elseif ($Path.EndsWith('/policies/policy')) {
        [xml]$policyDocument = $Body.properties.value
        if ($Body.properties.format -ne 'xml' -or $policyDocument.SelectNodes('//base|//include-fragment|//validate-jwt|//send-request|//forward-request|//set-backend-service').Count) { throw 'Parity policy introduced an uncontrolled path.' }
      } elseif ($Body.properties.method -ne 'GET') { throw 'Unexpected diagnostic operation.' }
      return
    }
    if ($Method -eq 'DELETE' -and $Path -eq '/fixture-service/apis/jwt-probe-fixture') {
      if ($RequestHeaders['If-Match'] -ne '*') { throw 'Cleanup lacks the conditional delete header.' }
      $state.deleted++
      $state.api = $null
      return
    }
    throw 'Unexpected parity lifecycle request.'
  }
  function Invoke-ProbeVm {
    param([string[]] $Parameters)
    if ($Parameters -contains 'Phase=HeaderParityTransport') {
      return [pscustomobject]@{ test = 'header-parity-transport'; passed = $state.mode -ne 'transport-failure' }
    }
    if ($Parameters -notcontains 'Phase=HeaderParityTest') { throw 'Parity invoked an unexpected VM phase.' }
    if ($state.mode -eq 'matrix-failure') { throw 'Fixture matrix failure.' }
    if ($state.mode -eq 'ownership-changed') { $state.api.properties.description = 'another-owner' }
    return [pscustomobject]@{ test = 'header-parity-observations'; completed = $true; rows = @(1..24) }
  }
  $lifecycleChecked = 0
  foreach ($scenario in @('success', 'existing-api', 'transport-failure', 'create-failure', 'matrix-failure', 'ownership-changed')) {
    $state.Clear()
    $state.mode = $scenario
    $state.api = if ($scenario -eq 'existing-api') { [pscustomobject]@{ name = 'jwt-probe-fixture'; properties = @{ description = 'existing-owner' } } } else { $null }
    $state.writes = 0
    $state.deleted = 0
    $failed = $false
    $result = @()
    try { $result = @(Invoke-ProbeHeaderParityGate -ServiceId '/fixture-service' -ProbeName 'jwt-probe-fixture' -ArmResource 'https://management.example.test/') }
    catch { $failed = $true }
    if ($failed -ne ($scenario -ne 'success')) { throw ('Unexpected parity lifecycle outcome: ' + $scenario) }
    if ($scenario -in @('existing-api', 'transport-failure') -and ($state.writes -ne 0 -or $state.deleted -ne 0)) { throw 'Parity mutated resources after failed preflight.' }
    if ($scenario -in @('success', 'create-failure', 'matrix-failure') -and ($state.deleted -ne 1 -or $null -ne $state.api)) { throw 'Parity did not clean up its own partial or completed API.' }
    if ($scenario -eq 'ownership-changed' -and ($state.deleted -ne 0 -or $null -eq $state.api)) { throw 'Parity deleted a resource after losing ownership.' }
    if ($scenario -eq 'success' -and @($result | Where-Object { $_.test -eq 'header-parity-api-removed' -and $_.passed }).Count -ne 1) { throw 'Parity success did not verify cleanup.' }
    $lifecycleChecked++
  }
  Write-Output ('PASS: ' + $lifecycleChecked + ' isolated parity lifecycle/cleanup scenarios with mocked ARM and VM calls.')
  function Invoke-ProbeArm {
    param([string] $Method, [string] $Path, [object] $Body, [switch] $PolicyDiagnostics, [string[]] $RedactedValues)
    if ($Method -eq 'GET') {
      $state.reads++
      return [pscustomobject]@{ properties = @{ description = $(if ($state.mode -eq 'wrong-owner') { 'other-owner' } else { 'fixture-owner' }); value = '<fragment />' } }
    }
    $state.writes++
    if (-not $PolicyDiagnostics -or $Body.properties.format -ne 'xml') { throw 'Runtime policy diagnostics/representation changed.' }
    if ($state.mode -eq 'invalid-policy') { throw 'Probe policy validation failed: invalid expression.' }
    if ($state.mode -eq 'missing-persistent' -or ($state.mode -eq 'missing-once' -and $state.writes -eq 1)) { throw "Probe policy validation failed: Policy fragment with id 'jwt-probe-fixture-byok-authenticate' could not be found." }
  }
  foreach ($scenario in @('ready', 'missing-once', 'missing-persistent', 'invalid-policy', 'wrong-owner')) {
    $state.Clear(); $state.mode = $scenario; $state.writes = 0; $state.reads = 0
    $failed = $false
    try { Set-ProbeSharedRuntimePolicy -ApiPath '/fixture-api' -Policy '<policies />' -FragmentPaths @('/fixture-fragment') -OwnerDescription 'fixture-owner' }
    catch { $failed = $true }
    $expectedWrites = switch ($scenario) { 'ready' { 1 }; 'missing-once' { 2 }; 'missing-persistent' { 6 }; 'invalid-policy' { 1 }; 'wrong-owner' { 0 } }
    if ($state.writes -ne $expectedWrites -or $failed -ne ($scenario -in @('missing-persistent', 'invalid-policy', 'wrong-owner')) -or $state.reads -lt 1) { throw ('Fragment publication retries lost their ownership/bounds: ' + $scenario) }
  }
  Write-Output 'PASS: five fragment-publication scenarios; only owned not-found references retry and validation errors do not.'
  $armDefinition = @($orchestratorAst.FindAll({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Invoke-ProbeArm' }, $false))
  if ($armDefinition.Count -ne 1) { throw 'Expected one ARM helper for completion/redaction coverage.' }
  . ([scriptblock]::Create($armDefinition[0].Extent.Text))
  $script:armRefreshAt = [DateTimeOffset]::UtcNow.AddHours(1)
  $armHeaders = @{ Authorization = 'fixture-transport' }
  $armBase = 'https://management.example.test'
  function Invoke-RestMethod {
    param([string] $Method, [string] $Uri, [hashtable] $Headers, [Microsoft.PowerShell.Commands.WebRequestSession] $WebSession)
    if ($Method -cne 'GET' -or $Uri -cne 'https://management.example.test/fixture?api-version=2024-05-01' -or $Headers.Authorization -cne $armHeaders.Authorization -or $null -eq $WebSession) { throw 'ARM session lost its endpoint or current authorization contract.' }
    if ($state.armSession -and -not [object]::ReferenceEquals($state.armSession, $WebSession)) { throw 'ARM requests did not reuse the per-run session.' }
    $state.armSession = $WebSession
    return @{ properties = @{ fixture = $true } }
  }
  $null = Invoke-ProbeArm GET '/fixture'
  $armHeaders.Authorization = 'fixture-renewed'
  $null = Invoke-ProbeArm GET '/fixture'
  Write-Output 'PASS: ARM calls reuse one session while sending the current authorization headers; no cloud call.'
  & {
    $ArmTransport='cli'
    $state=@{mode='';calls=0;bodyFile=$null}
    function az {
      $state.calls++
      $global:LASTEXITCODE=0
      if($args[0] -cne 'rest' -or $args -contains '--debug' -or ($args -join ' ') -match 'fixture-secret'){throw 'CLI transport must not pass credentials or enable debug in arguments.'}
      if($args -notcontains 'Accept=application/json'){throw 'APIM policy requests must explicitly select the ARM JSON envelope.'}
      $bodyIndex=[Array]::IndexOf($args,'--body')
      if($bodyIndex -ge 0){
        $state.bodyFile=([string]$args[$bodyIndex+1]).TrimStart('@')
        if((Get-Content -LiteralPath $state.bodyFile -Raw|ConvertFrom-Json).properties.value -cne 'fixture-secret'){throw 'CLI body content changed.'}
      }
      switch($state.mode){
        'ok'{'{"properties":{"fixture":true}}'}
        'bom'{[string][char]0xFEFF+'{"properties":{"fixture":true}}'}
        'empty'{}
        'missing'{$global:LASTEXITCODE=1;'ERROR: (ResourceNotFound) synthetic missing resource'}
        'denied'{$global:LASTEXITCODE=1;'ERROR: (AuthorizationFailed) not allowed'}
        'failure'{$global:LASTEXITCODE=1;'ERROR: synthetic-cli-failure fixture-secret'}
      }
    }
    foreach($case in @('ok','bom','empty','missing','denied','failure','write','write-failure')){
      $state.mode=switch($case){'write'{'ok'};'write-failure'{'failure'};default{$case}}
      $state.calls=0;$state.bodyFile=$null;$failed=$false;$result=$null
      try{
        if($case -like 'write*'){$result=Invoke-ProbeArm PUT '/fixture' @{properties=@{value='fixture-secret'}} -PolicyDiagnostics -RedactedValues @('fixture-secret')}
        else{$result=Invoke-ProbeArm GET '/fixture' -AllowNotFound -PolicyDiagnostics -RedactedValues @('fixture-secret')}
      }catch{$failed=$true;if($_.Exception.Message.Contains('fixture-secret')){throw 'CLI failure exposed a credential.'}}
      if($failed -ne ($case -in @('denied','failure','write-failure')) -or $state.calls -ne 1){throw ('CLI transport result/retry mismatch: '+$case)}
      if($case -eq 'missing' -and $null -ne $result){throw 'Explicit CLI missing-resource response must return null.'}
      if($case -eq 'bom' -and $result.properties.fixture -ne $true){throw 'CLI response BOM was not decoded correctly.'}
      if($state.bodyFile -and (Test-Path -LiteralPath $state.bodyFile)){throw 'CLI transport left its temporary request body.'}
    }
  }
  Write-Output 'PASS: eight explicit ARM CLI transport cases preserve errors, decode BOM responses, avoid write retries and remove private request bodies.'
  function az {
    $propertiesIndex = [Array]::IndexOf($args, '--properties')
    if ($propertiesIndex -lt 0 -or $args -notcontains '--is-full-object' -or $args -contains '--no-wait') { throw 'Fragment creation must provide the full object and wait for completion.' }
    $state.fragmentFile = ([string]$args[$propertiesIndex + 1]).TrimStart('@')
    $fragmentResource = Get-Content -LiteralPath $state.fragmentFile -Raw | ConvertFrom-Json
    if ($fragmentResource.location -cne 'fixture-region' -or $fragmentResource.properties.value -cne '<fragment />') { throw 'The full fragment object must include its parent location and unchanged properties.' }
    $global:LASTEXITCODE = 1
    'ERROR: synthetic-validation-failure: fixture-private-value at https://private.example.test'
  }
  $diagnostic = ''
  $previousExitCode = $global:LASTEXITCODE
  try { $null = Invoke-ProbeArm PUT '/fixture/policyFragments/jwt-probe-fixture' @{ properties = @{ value = '<fragment />' } } -CompleteFragmentOperation -ResourceLocation 'fixture-region' -PolicyDiagnostics -RedactedValues @('fixture-private-value') }
  catch { $diagnostic = $_.Exception.Message }
  finally { $global:LASTEXITCODE = $previousExitCode }
  if (-not $diagnostic.Contains('synthetic-validation-failure') -or $diagnostic.Contains('fixture-private-value') -or $diagnostic.Contains('https://private.example.test')) { throw 'Completed fragment failure lost its diagnostic or exposed private values.' }
  if (Test-Path -LiteralPath $state.fragmentFile) { throw 'The temporary fragment body was not removed after the CLI failure.' }
  Write-Output 'PASS: completed fragment failure preserves a sanitized diagnostic rather than treating initial acceptance as completion.'
  function az {
    if (($args[0..1] -join ' ') -cne 'resource delete' -or $args -contains '--no-wait') { throw 'Fragment cleanup must wait for the completed delete.' }
    $state.fragmentDeletes++
    $global:LASTEXITCODE = 0
  }
  foreach ($resourcePath in @('/fixture/policyfragments/jwt-probe-fixture','/fixture/policyFragments/jwt-probe-fixture','/fixture/policyFragments/not-a-probe')) {
    $state.fragmentDeletes = 0; $failed = $false
    try { $null = Invoke-ProbeArm DELETE $resourcePath -CompleteFragmentOperation -PolicyDiagnostics } catch { $failed = $true }
    $allowed = $resourcePath.EndsWith('/jwt-probe-fixture', [StringComparison]::Ordinal)
    if ($failed -eq $allowed -or $state.fragmentDeletes -ne [int]$allowed) { throw 'Fragment cleanup must honor case-insensitive ARM type names and exact diagnostic identifiers.' }
  }
  function Invoke-RestMethod {
    param([string] $Method, [string] $Uri, [hashtable] $Headers)
    if ($Method -ne 'GET') { throw 'Unexpected product-cleanup REST mutation.' }
    if ($Uri.EndsWith('/apis?api-version=2024-05-01')) { return @{ value = $(if ($state.cleanupMode -eq 'linked') { @(@{name='fixture'}) } else { @() }) } }
    if ($Uri.EndsWith('/subscriptions?api-version=2024-05-01')) { return @{ value = @(@{ properties = @{ scope = $(if ($state.cleanupMode -eq 'wrong-scope') { '/another-product' } else { '/fixture/products/jwt-probe-fixture-native' }) } }); nextLink = $(if ($state.cleanupMode -eq 'paged') { 'https://management.example.test/next' } else { $null }) } }
    throw 'Unexpected product-cleanup read scope.'
  }
  function az {
    if (($args[0..2] -join ' ') -cne 'apim product delete' -or $args -notcontains '--delete-subscriptions' -or $args -notcontains '--yes' -or $args -contains '--no-wait') { throw 'Product cleanup must complete supported scoped subscription deletion.' }
    $state.productDeletes++
    $global:LASTEXITCODE = 0
  }
  foreach ($scenario in @('owned','linked','wrong-scope','paged')) {
    $state.cleanupMode = $scenario; $state.productDeletes = 0
    $failed = $false
    try { $null = Invoke-ProbeArm DELETE '/fixture/products/jwt-probe-fixture-native' -CompleteOwnedOperation -PolicyDiagnostics } catch { $failed = $true }
    if ($failed -ne ($scenario -ne 'owned') -or $state.productDeletes -ne [int]($scenario -eq 'owned')) { throw ('Unsafe owned product cleanup behavior: ' + $scenario) }
  }
  $global:LASTEXITCODE = $previousExitCode
  Write-Output 'PASS: owned product cleanup completes generated subscription removal only after detached, bounded scope checks.'
  function Invoke-ProbeArm {
    param([string] $Method, [string] $Path, [switch] $AllowNotFound, [hashtable] $RequestHeaders, [switch] $PolicyDiagnostics)
    $productPath = '/fixture/products/jwt-probe-fixture-native'
    if ($Method -eq 'GET' -and $Path -ceq $productPath) { return @{ name = 'jwt-probe-fixture-native'; properties = @{ description = $(if ($state.linkMode -eq 'wrong-product') { 'other-owner' } else { 'fixture-owner' }) } } }
    if ($Method -eq 'GET' -and $Path -ceq ($productPath + '/apis')) {
      return @{ value = $(if ($state.detached -and $state.linkMode -ne 'pending') { @() } else { @(@{ name = 'jwt-probe-fixture-stateful'; properties = @{ description = $(if ($state.linkMode -eq 'wrong-api') { 'other-owner' } else { 'fixture-owner' }) } }) }); nextLink = $(if ($state.linkMode -eq 'paged') { 'fixture-next' } else { $null }) }
    }
    if ($Method -eq 'DELETE' -and $Path -ceq ($productPath + '/apis/jwt-probe-fixture-stateful') -and $RequestHeaders['If-Match'] -ceq '*') { $state.detached = $true; return }
    throw 'Product association cleanup must use collection readback, never unsupported single-association GET.'
  }
  foreach ($scenario in @('owned','wrong-product','wrong-api','paged','pending')) {
    $state.linkMode = $scenario; $state.detached = $false
    $failed = $false
    try { Remove-ProbeGovernanceProductLinks -ProductPath '/fixture/products/jwt-probe-fixture-native' -OwnerDescription 'fixture-owner' -Owner 'jwt-probe-fixture' } catch { $failed = $true }
    if ($failed -ne ($scenario -ne 'owned') -or $state.detached -ne ($scenario -in @('owned','pending'))) { throw ('Product link ownership/absence contract failed: ' + $scenario) }
  }
  Write-Output 'PASS: five product-link cleanup cases use supported collection readback and refuse changed ownership or unverified absence.'
}
foreach ($entryPath in $CompiledTierEntryTemplatePaths) {
  $entryTemplate = Get-Content -LiteralPath $entryPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
  if ($entryTemplate.parameters.callerJwtTiering.defaultValue.entra.enabled -ne $false -or
    $entryTemplate.parameters.callerJwtTiering.defaultValue.okta.enabled -ne $false -or @($entryTemplate.parameters.productTiers.defaultValue).Count) { throw 'Standalone/wizard tier entry points must preserve disabled defaults.' }
  $entryResources = if ($entryTemplate.resources -is [array]) { @($entryTemplate.resources) } else { @($entryTemplate.resources.Values) }
  $entryBindings = @($entryResources | Where-Object { $_.type -ceq 'Microsoft.Resources/deployments' -and ($_.properties.parameters.Contains('callerJwtTiering') -or $_.properties.parameters.Contains('jwtTiering')) })
  if ($entryBindings.Count -ne 1) { throw 'Each entry point must bind exactly one caller-tier module.' }
  $entryParameters = $entryBindings[0].properties.parameters
  $tierParameterName = if ($entryParameters.Contains('callerJwtTiering')) { 'callerJwtTiering' } else { 'jwtTiering' }
  $catalogParameterName = if ($entryParameters.Contains('productTiers')) { 'productTiers' } else { 'tierCatalog' }
  if ($entryParameters[$tierParameterName].value -cne "[parameters('callerJwtTiering')]" -or
    -not (($entryParameters[$catalogParameterName] | ConvertTo-Json -Depth 20 -Compress).Contains("parameters('productTiers')"))) { throw 'A deployment entry point dropped or replaced the reviewed tier mapping/catalog.' }
}
if ($CompiledTierEntryTemplatePaths) { Write-Output ('PASS: ' + $CompiledTierEntryTemplatePaths.Count + ' compiled standalone/wizard entry points preserve the default-off tier contract and canonical catalog.') }
if ($CompiledTemplatePath) {
  $template = Get-Content -Raw -LiteralPath $CompiledTemplatePath | ConvertFrom-Json
  if (-not $template.parameters.keyEnabled.defaultValue -or $template.parameters.entraTrust.defaultValue.enabled -or $template.parameters.oktaTrust.defaultValue.enabled) { throw 'Caller module no longer defaults to key-only.' }
  $tierDefaults = $template.parameters.jwtTiering.defaultValue
  if ($tierDefaults.entra.enabled -ne $false -or $tierDefaults.okta.enabled -ne $false -or $tierDefaults.okta.claimName -cne 'byok_tier' -or
      @($tierDefaults.entra.mappings).Count -or @($tierDefaults.okta.mappings).Count -or @($template.parameters.tierCatalog.defaultValue).Count) { throw 'Caller tier selection must remain explicitly disabled with no implicit mappings or catalog.' }
  $resources = @($template.resources.PSObject.Properties | ForEach-Object Value | Where-Object { -not $_.existing })
  if ($resources.Count -ne 2 -or @($resources | Where-Object { $_.type -notin @('Microsoft.ApiManagement/service/namedValues', 'Microsoft.ApiManagement/service/policyFragments') }).Count) { throw 'Caller module changed API admission or associations.' }
  $deployed = @($template.variables.fragmentPolicies)
  if ($deployed.Count -ne 3 -or $deployed[0].name -ne 'byok-authenticate' -or $deployed[1].name -ne 'byok-strip-caller-credentials' -or $deployed[2].name -ne 'byok-apply-caller-limits' -or
    $deployed[0].value -cne "[variables('authenticationPolicy')]" -or
    $deployed[1].value -cne "[variables('sourcePolicies')['byok-strip-caller-credentials']]" -or
    $deployed[2].value -cne "[__bicep.renderCallerLimits(parameters('jwtTiering'), parameters('tierCatalog'))]" -or
    $template.resources.fragments.dependsOn[0] -ne 'callerSettings' -or $template.resources.fragments.properties.format -ne 'xml') { throw 'Fragment deployment order or representation changed.' }
  $disabled = [xml]$template.variables.disabledValidator
  if ($disabled.SelectNodes('//openid-config|//validate-jwt|//include-fragment|//send-request').Count -or
    $disabled.SelectSingleNode('/fragment/return-response/set-status').code -ne '401') { throw 'Disabled issuers must reject without metadata lookup.' }
  $compiledSources = @{}
  foreach ($name in @('byok-credential-source', 'byok-validate-entra', 'byok-validate-okta', 'byok-strip-caller-credentials', 'byok-authenticate', 'byok-apply-caller-limits')) {
    $source = (Get-Content -Raw (Join-Path $root ('policies/fragments/' + $name + '.xml'))).Replace("`r`n", "`n")
    $binding = $template.variables.sourcePolicies.$name
    $embedded = @($template.variables.PSObject.Properties | Where-Object { $_.Value -is [string] -and $_.Value.Replace("`r`n", "`n") -ceq $source })
    $bindingMatches = $binding.Replace("`r`n", "`n") -ceq $source
    if ($bindingMatches) { $compiledSources[$name] = $binding }
    elseif ($embedded.Count -eq 1) {
      $bindingMatches = $binding -ceq ("[variables('" + $embedded[0].Name + "')]")
      $compiledSources[$name] = $embedded[0].Value
    }
    if (-not $bindingMatches) { throw ('Compiled fragment is stale or mismatched: ' + $name) }
  }
  foreach ($issuer in @('entra', 'okta')) {
    $binding = $template.variables.($issuer + 'Validator')
    $expectedBinding = "[if(and(parameters('${issuer}Trust').enabled, variables('configurationValid')), variables('sourcePolicies')['byok-validate-$issuer'], variables('disabledValidator'))]"
    if ($binding -cne $expectedBinding) { throw 'Disabled or invalid issuer did not select its rejecting stub.' }
  }
  foreach ($stage in @(
    @{ name = 'authenticationWithSource'; input = "variables('sourcePolicies')['byok-authenticate']"; component = 'byok-credential-source'; value = "variables('sourcePolicies')['byok-credential-source']" },
    @{ name = 'authenticationWithEntra'; input = "variables('authenticationWithSource')"; component = 'byok-validate-entra'; value = "variables('entraValidator')" },
    @{ name = 'authenticationPolicy'; input = "variables('authenticationWithEntra')"; component = 'byok-validate-okta'; value = "variables('oktaValidator')" }
  )) {
    $binding = $template.variables.($stage.name)
    $marker = '<include-fragment fragment-id="' + $stage.component + '" />'
    $expectedBinding = "[replace($($stage.input), '$marker', replace(replace($($stage.value), '<fragment>', ''), '</fragment>', ''))]"
    if ($binding -cne $expectedBinding) { throw 'Compiled authentication composition changed.' }
  }
  foreach ($validConfiguration in @($false, $true)) {
    foreach ($entraEnabled in @($false, $true)) {
      foreach ($oktaEnabled in @($false, $true)) {
        $expanded = $compiledSources['byok-authenticate']
        $enabledComponents = @{
          'byok-credential-source' = $true
          'byok-validate-entra' = $validConfiguration -and $entraEnabled
          'byok-validate-okta' = $validConfiguration -and $oktaEnabled
        }
        foreach ($name in @('byok-credential-source', 'byok-validate-entra', 'byok-validate-okta')) {
          $component = if ($enabledComponents[$name]) { $compiledSources[$name] } else { $template.variables.disabledValidator }
          $expanded = $expanded.Replace(('<include-fragment fragment-id="' + $name + '" />'), $component.Replace('<fragment>', '').Replace('</fragment>', ''))
        }
        [xml]$flatPolicy = $expanded
        $validatorCount = [int]($validConfiguration -and $entraEnabled) + [int]($validConfiguration -and $oktaEnabled)
        if ($flatPolicy.SelectNodes('//validate-jwt').Count -ne $validatorCount) { throw 'Rendered auth selected the wrong issuer validators.' }
        foreach ($content in @($expanded, $compiledSources['byok-strip-caller-credentials'], $compiledSources['byok-apply-caller-limits'])) {
          [xml]$renderedFragmentDocument = $content
          if ($renderedFragmentDocument.DocumentElement.Name -ne 'fragment' -or $renderedFragmentDocument.SelectNodes('//fragment').Count -ne 1 -or
            $renderedFragmentDocument.SelectNodes('//include-fragment|//base|//policies|//inbound|//outbound|//backend|//on-error').Count -or
            [Text.Encoding]::UTF8.GetByteCount($content) -gt 32768) { throw 'Every rendered fragment must be flat and within the conservative size budget.' }
        }
      }
    }
  }
  Write-Output 'PASS: fresh sources, key-only defaults, rejecting disabled issuers, and flat ordered fragment packaging.'
}
if ($CompiledMainTemplatePath) {
  $mainTemplate = Get-Content -Raw -LiteralPath $CompiledMainTemplatePath | ConvertFrom-Json -Depth 100
  $tierDefaults = $mainTemplate.parameters.callerJwtTiering.defaultValue
  if ($tierDefaults.entra.enabled -ne $false -or $tierDefaults.okta.enabled -ne $false -or @($tierDefaults.entra.mappings).Count -or @($tierDefaults.okta.mappings).Count) { throw 'Main must not enable or preassign JWT tiers.' }
  $preparation = $mainTemplate.parameters.callerAuthPreparation.defaultValue
  if ($preparation.enabled -ne $false -or $preparation.oktaTrust.enabled -ne $false -or
    $preparation.keyEnabled -cne "[equals(parameters('authMode'), 'subscriptionKey')]" -or
    $preparation.entraEnabled -cne "[equals(parameters('authMode'), 'jwt')]") { throw 'Shared-auth preparation changed the legacy defaults.' }
  $mainResources = if ($mainTemplate.resources -is [array]) { @($mainTemplate.resources) } else { @($mainTemplate.resources.PSObject.Properties.Value) }
  $callerModule = @($mainResources | Where-Object name -eq 'apim-caller-auth')
  if ($callerModule.Count -ne 1 -or $callerModule[0].condition -cne "[parameters('callerAuthPreparation').enabled]" -or
    $callerModule[0].properties.parameters.entraLoginHost.value -cne "[variables('v').entraLoginHost]" -or
    $callerModule[0].properties.parameters.entraTrust.value.issuer -cne "[format('https://{0}/{1}/v2.0', variables('v').entraLoginHost, parameters('entraTenantId'))]" -or
    -not ($callerModule[0].properties.parameters.namedValueIds.value -match 'apimNamedValues|apim-named-values') -or
    -not (@($callerModule[0].dependsOn) -match 'apimNamedValues|apim-named-values')) { throw 'Caller preparation lost its opt-in, cloud pinning or named-value dependency.' }
  if ($callerModule[0].properties.parameters.jwtTiering.value -cne "[parameters('callerJwtTiering')]" -or
      $callerModule[0].properties.parameters.tierCatalog.value -cne "[variables('callerTierCatalog')]" -or
      -not (($mainTemplate.variables | ConvertTo-Json -Depth 100 -Compress).Contains("parameters('productTiers')"))) { throw 'Main JWT tier limits must come from the deployment-owned product catalog.' }
  if ($mainTemplate.parameters.callerAuthRollout.defaultValue -cne 'legacy' -or
    $mainTemplate.parameters.responseOwnerKey.type -cne 'securestring' -or $mainTemplate.parameters.responseOwnerPreviousKey.type -cne 'securestring' -or
    $mainTemplate.variables.sharedCallerAuth -cne "[not(equals(parameters('callerAuthRollout'), 'legacy'))]") { throw 'Shared rollout must remain explicit and ownership keys secure.' }
  foreach ($name in @('apim-foundry-api', 'apim-aoai-api')) {
    $api = @($mainResources | Where-Object name -eq $name)[0]
    if ($api.properties.parameters.authMode.value -cne "[variables('effectiveOpenAiAuthMode')]" -or
      $api.properties.parameters.sharedInferenceAuth.value -cne "[variables('sharedCallerAuth')]" -or
      -not (($api.dependsOn -join ',') -match 'apimResponseOwnership|apim-response-ownership')) { throw 'OpenAI consumer activation lost its explicit rollout or ownership ordering.' }
  }
  $anthropic = @($mainResources | Where-Object name -eq 'apim-anthropic-api')[0]
  if ($anthropic.properties.parameters.authMode.value -cne "[parameters('authMode')]" -or
    ($anthropic.properties.parameters | ConvertTo-Json -Depth 100 -Compress) -match 'callerAuth|responseOwnership|sharedInference') { throw 'Deferred Anthropic new auth must remain unchanged.' }
  foreach ($name in @('apim-products', 'apim-subscriptions')) {
    $resource = @($mainResources | Where-Object name -eq $name)[0]
    if ($resource.condition -cne "[and(variables('nativeKeysAccepted'), parameters('deployTestSubscriptions'))]") { throw 'Native products/subscriptions must be provisioned whenever an active route accepts keys.' }
  }
  $jwtProduct = @($mainResources | Where-Object name -eq 'apim-jwt-product')[0]
  if ($jwtProduct.condition -cne "[parameters('callerAuthPreparation').enabled]" -or
    $jwtProduct.properties.parameters.active.value -cne "[and(and(equals(parameters('callerAuthRollout'), 'coexistence'), parameters('callerAuthPreparation').keyEnabled), or(parameters('callerAuthPreparation').entraEnabled, parameters('callerAuthPreparation').oktaTrust.enabled))]" -or
    $jwtProduct.properties.parameters.apiNames.value -match 'anthropic' -or
    ($jwtProduct.dependsOn -join ',') -notmatch 'apimFoundryApi|apim-foundry-api' -or
    ($jwtProduct.dependsOn -join ',') -notmatch 'apimAoaiApi|apim-aoai-api') { throw 'JWT product must link only OpenAI APIs after consumer policies under explicit coexistence activation.' }
  foreach ($parameterFile in Get-ChildItem (Join-Path $root 'infra/main.parameters.ci.*.json')) {
    $parameters = (Get-Content -Raw $parameterFile.FullName | ConvertFrom-Json).parameters
    if ($parameters.authMode.value -ne 'subscriptionKey' -or $parameters.PSObject.Properties.Name -contains 'callerAuthPreparation' -or
      $parameters.PSObject.Properties.Name -contains 'callerAuthRollout' -or $parameters.PSObject.Properties.Name -contains 'callerJwtTiering') { throw 'CI environment authentication must remain unchanged.' }
  }
  Write-Output 'PASS: main rollout defaults to legacy; auth/ownership precede OpenAI consumers and JWT links; Anthropic and all CI settings remain unchanged.'
}
if ($CompiledFoundryTemplatePath) {
  $foundryTemplate = Get-Content -Raw -LiteralPath $CompiledFoundryTemplatePath | ConvertFrom-Json -Depth 100
  $foundryResources = if ($foundryTemplate.resources -is [array]) { @($foundryTemplate.resources) } else { @($foundryTemplate.resources.PSObject.Properties.Value) }
  $foundryApi = @($foundryResources | Where-Object type -eq 'Microsoft.ApiManagement/service/apis')
  $modelsPolicyResource = @($foundryResources | Where-Object { $_.type -eq 'Microsoft.ApiManagement/service/apis/operations/policies' -and $_.name -match 'list-models' })
  if ($foundryApi.Count -ne 1 -or $modelsPolicyResource.Count -ne 1) { throw 'Expected one Foundry API and discovery policy.' }
  if ($foundryTemplate.parameters.sharedDiscoveryAuth.defaultValue -ne $false -or
    $foundryApi[0].properties.subscriptionRequired -cne "[equals(parameters('authMode'), 'subscriptionKey')]" -or
    $foundryTemplate.outputs.callerAuthFragmentDependency.value -cne "[parameters('callerAuthFragmentIds')]") { throw 'Discovery integration changed native admission or fragment ordering contract.' }
  if ($modelsPolicyResource[0].properties.format -cne "[if(parameters('sharedDiscoveryAuth'), 'xml', 'rawxml')]" -or
    $modelsPolicyResource[0].properties.value -cne "[if(parameters('sharedDiscoveryAuth'), variables('sharedModelsPolicy'), if(equals(parameters('authMode'), 'jwt'), variables('modelsPolicySources').jwt, __bicep.guardNativePolicy(variables('modelsPolicySources').subscriptionKey)))]") { throw 'Discovery integration is not explicitly opt-in with legacy defaults.' }
  $sources = @{}
  foreach ($mode in @('jwt', 'subscriptionKey')) {
    $path = if ($mode -eq 'jwt') { 'policies/byok-foundry-models-policy.xml' } else { 'policies/byok-foundry-models-policy-subkey.xml' }
    $source = Get-Content -Raw (Join-Path $root $path)
    $binding = $foundryTemplate.variables.modelsPolicySources.$mode
    if ($binding -match "^\[variables\('([^']+)'\)\]$") { $binding = $foundryTemplate.variables.($Matches[1]) }
    if ($binding.Replace("`r`n", "`n") -cne $source.Replace("`r`n", "`n")) { throw 'Compiled discovery source is stale.' }
    $sources[$mode] = $binding
  }
  $expectedComposition = "[replace(replace(variables('modelsPolicySources').subscriptionKey, '<set-header name=`"api-key`" exists-action=`"delete`" />', variables('sharedModelsAuthentication')), '<set-header name=`"Authorization`" exists-action=`"delete`" />', '')]"
  if ($foundryTemplate.variables.sharedModelsTemplate -cne $expectedComposition -or
    $foundryTemplate.variables.sharedModelsPolicy -cne "[replace(variables('sharedModelsTemplate'), '__NATIVE_SUBSCRIPTION_REQUIRED__', toLower(string(equals(parameters('authMode'), 'subscriptionKey'))))]") { throw 'Discovery authentication composition changed.' }
  foreach ($mode in @('jwt', 'subscriptionKey')) {
    $required = ($mode -eq 'subscriptionKey').ToString().ToLowerInvariant()
    $authenticationText = $foundryTemplate.variables.sharedModelsAuthentication.Replace('__NATIVE_SUBSCRIPTION_REQUIRED__', $required)
    $content = $sources.subscriptionKey.Replace('<set-header name="api-key" exists-action="delete" />', $authenticationText).Replace('<set-header name="Authorization" exists-action="delete" />', '')
    [xml]$policy = $content
    [xml]$legacyKey = $sources.subscriptionKey
    $inbound = @($policy.policies.inbound.ChildNodes | Where-Object NodeType -eq ([Xml.XmlNodeType]::Element))
    if ($policy.SelectNodes('/policies/inbound//base|/policies/inbound//validate-jwt|/policies/inbound//send-request|//rate-limit-by-key|//quota-by-key|//azure-openai-token-limit|//llm-emit-token-metric').Count -or
      $content.Contains('context.Request.Body') -or $content.Contains('__NATIVE_SUBSCRIPTION_REQUIRED__') -or
      $policy.SelectNodes('//include-fragment').Count -ne 2 -or $inbound[0].name -ne 'byokCredentialHeader' -or
      $inbound[2].GetAttribute('fragment-id') -ne 'byok-authenticate' -or $inbound[3].GetAttribute('fragment-id') -ne 'byok-strip-caller-credentials' -or
      $inbound[4].Name -ne 'set-backend-service' -or $inbound[5].Name -ne 'authentication-managed-identity') { throw 'Bodyless discovery lost explicit auth/stripping order or inherited inference behavior.' }
    if ($policy.policies.outbound.OuterXml -cne $legacyKey.policies.outbound.OuterXml -or
      $policy.SelectSingleNode('/policies/inbound/rewrite-uri').OuterXml -cne $legacyKey.SelectSingleNode('/policies/inbound/rewrite-uri').OuterXml -or
      $policy.SelectSingleNode('/policies/inbound/set-backend-service').OuterXml -cne $legacyKey.SelectSingleNode('/policies/inbound/set-backend-service').OuterXml -or
      $policy.SelectSingleNode('/policies/inbound/authentication-managed-identity').OuterXml -cne $legacyKey.SelectSingleNode('/policies/inbound/authentication-managed-identity').OuterXml) { throw 'Discovery integration changed backend routing/authentication or response shape.' }
    $condition = $policy.SelectSingleNode('/policies/inbound/choose/when').GetAttribute('condition')
    foreach ($keyFlag in @('true', 'false')) {
      foreach ($nativeFlag in @('true', 'false')) {
        $expectedCondition = '@("' + $keyFlag + '" != "' + $required + '" || "' + $nativeFlag + '" != "' + $required + '")'
        if ($condition.Replace('{{caller-key-enabled}}', $keyFlag).Replace('{{caller-native-subscription-required}}', $nativeFlag) -cne $expectedCondition -or
          $policy.SelectSingleNode('/policies/inbound/choose/when/return-response/set-status').code -ne '401') { throw 'Consumer admission guard does not bind to actual API subscription mode.' }
      }
    }
  }
  Write-Output 'PASS: default-off discovery consumer, native admission binding, explicit shared authentication/stripping, and unchanged bodyless backend/response behavior.'
  $inferenceResource = @($foundryResources | Where-Object type -eq 'Microsoft.ApiManagement/service/apis/policies')
  if ($inferenceResource.Count -ne 1 -or $foundryTemplate.parameters.sharedInferenceAuth.defaultValue -ne $false -or
    $inferenceResource[0].properties.format -cne 'rawxml' -or
    $inferenceResource[0].properties.value -cne "[if(parameters('sharedInferenceAuth'), variables('sharedInferencePolicy'), if(equals(parameters('authMode'), 'jwt'), variables('inferencePolicySources').jwt, __bicep.guardNativePolicy(variables('inferencePolicySources').subscriptionKey)))]") { throw 'Shared inference must remain explicitly opt-in with unchanged legacy selection.' }
  $inferenceSources = @{}
  foreach ($mode in @('jwt', 'subscriptionKey')) {
    $path = if ($mode -eq 'jwt') { 'policies/byok-foundry-policy.xml' } else { 'policies/byok-foundry-policy-subkey.xml' }
    $source = Get-Content -Raw (Join-Path $root $path)
    $binding = $foundryTemplate.variables.inferencePolicySources.$mode
    if ($binding -match "^\[variables\('([^']+)'\)\]$") { $binding = $foundryTemplate.variables.($Matches[1]) }
    if ($binding.Replace("`r`n", "`n") -cne $source.Replace("`r`n", "`n")) { throw 'Compiled inference source is stale.' }
    $inferenceSources[$mode] = $binding
  }
  $identityMarker = '<set-variable name="developerOid" value="@(context.Subscription?.Id ?? "unknown")" />'
  $displayMarker = '<set-variable name="developerUpn" value="@(context.Subscription?.Name ?? context.Subscription?.Id ?? "unknown")" />'
  $limitsAndStrip = '<include-fragment fragment-id="byok-apply-caller-limits" /><include-fragment fragment-id="byok-strip-caller-credentials" />'
  foreach ($marker in @($identityMarker, $displayMarker)) {
    if ([regex]::Matches($inferenceSources.subscriptionKey, [regex]::Escape($marker)).Count -ne 1) { throw 'Inference composition marker is missing or ambiguous.' }
  }
  $expectedAuth = "[replace(variables('sharedModelsAuthentication'), '<include-fragment fragment-id=`"byok-strip-caller-credentials`" />', '')]"
  $expectedInbound = "[format('{0}{1}{2}', substring(variables('inferencePolicySources').subscriptionKey, 0, variables('inferenceInboundEnd')), variables('sharedInferenceAuthentication'), substring(variables('inferencePolicySources').subscriptionKey, variables('inferenceInboundEnd')))]"
  $expectedLimits = "[replace(variables('sharedInferenceWithAuthentication'), '$identityMarker', format('$limitsAndStrip{0}', variables('sharedResponsesPreparation')))]"
  $expectedIdentity = "[replace(variables('sharedInferenceWithAccounting'), '$displayMarker', '')]"
  if ($foundryTemplate.variables.sharedInferenceAuthentication -cne $expectedAuth -or
    $foundryTemplate.variables.sharedInferenceWithAuthentication -cne $expectedInbound -or
    $foundryTemplate.variables.sharedInferenceWithAccounting -cne $expectedLimits -or
    $foundryTemplate.variables.sharedInferenceWithoutLegacyIdentity -cne $expectedIdentity -or
    $foundryTemplate.variables.sharedInferenceWithAffinity -cne "[format('{0}{1}{2}', substring(variables('sharedInferenceWithoutLegacyIdentity'), 0, variables('responseAffinityOffset')), variables('sharedResponseAffinity'), substring(variables('sharedInferenceWithoutLegacyIdentity'), variables('responseAffinityOffset')))]" -or
    $foundryTemplate.variables.sharedInferenceTemplate -cne "[replace(variables('sharedInferenceWithAffinity'), '</on-error>', format('{0}</on-error>', variables('sharedCallerThrottleTelemetry')))]" -or
    $foundryTemplate.variables.sharedInferencePolicy -cne "[replace(variables('sharedInferenceTemplate'), '__NATIVE_SUBSCRIPTION_REQUIRED__', toLower(string(equals(parameters('authMode'), 'subscriptionKey'))))]") { throw 'Compiled inference authentication/accounting composition changed.' }
  foreach ($mode in @('jwt', 'subscriptionKey')) {
    $required = ($mode -eq 'subscriptionKey').ToString().ToLowerInvariant()
    $authText = $foundryTemplate.variables.sharedModelsAuthentication.Replace('<include-fragment fragment-id="byok-strip-caller-credentials" />', '').Replace('__NATIVE_SUBSCRIPTION_REQUIRED__', $required)
    $inboundEnd = $inferenceSources.subscriptionKey.IndexOf('<inbound>', [StringComparison]::Ordinal) + '<inbound>'.Length
    $rendered = $inferenceSources.subscriptionKey.Insert($inboundEnd, $authText).Replace($identityMarker, ($limitsAndStrip + $foundryTemplate.variables.sharedResponsesPreparation)).Replace($displayMarker, '')
    $affinityOffset = $rendered.IndexOf('    <!-- 7. Rewrite the OpenAI-style /v1/<op> path', [StringComparison]::Ordinal)
    if ($affinityOffset -lt 0) { throw 'Response backend affinity insertion point is missing.' }
    $rendered = $rendered.Insert($affinityOffset, $foundryTemplate.variables.sharedResponseAffinity)
    $executable = [regex]::Replace($rendered, '(?s)<!--.*?-->', '')
    $order = @('<include-fragment fragment-id="byok-authenticate" />', '<base />', '<include-fragment fragment-id="byok-apply-caller-limits" />', '<include-fragment fragment-id="byok-strip-caller-credentials" />', '<set-variable name="pathHasDeployment"', '<send-request')
    $previous = -1
    foreach ($marker in $order) {
      $position = $executable.IndexOf($marker, [StringComparison]::Ordinal)
      if ($position -le $previous) { throw 'Authentication, native accounting, JWT accounting and stripping must precede classifier/backend access.' }
      $previous = $position
    }
    if ($executable -match '<validate-jwt\b|<set-variable name="developer(?:Oid|Upn)"|<rate-limit-by-key\b|<quota-by-key\b|<azure-openai-token-limit\b' -or
      [regex]::Matches($executable, '<include-fragment\b').Count -ne 6) { throw 'Shared inference duplicated identity or limits.' }
    $bodyMarker = '<set-variable name="pathHasDeployment"'
    $withoutOwnershipAffinity = $rendered.Replace($foundryTemplate.variables.sharedResponseAffinity, '')
    if ($withoutOwnershipAffinity.Substring($withoutOwnershipAffinity.IndexOf($bodyMarker, [StringComparison]::Ordinal)) -cne
      $inferenceSources.subscriptionKey.Substring($inferenceSources.subscriptionKey.IndexOf($bodyMarker, [StringComparison]::Ordinal))) { throw 'Inference feature logic changed during shared-auth composition.' }
  }
  Write-Output 'PASS: shared Foundry inference orders authentication/native accounting/JWT accounting/stripping before feature logic; native routing, streaming and backend credentials are unchanged.'
  [xml]$throttleTelemetry = '<fragment>' + $foundryTemplate.variables.sharedCallerThrottleTelemetry + '</fragment>'
  $throttleGate = $throttleTelemetry.SelectSingleNode('/fragment/choose/when').condition
  $throttleMetrics = @($throttleTelemetry.SelectNodes('/fragment/choose/when/emit-metric'))
  if ($throttleMetrics.Count -ne 2 -or $throttleGate -notmatch 'byokCallerAuthenticated' -or $throttleGate -notmatch 'byokJwtValidated' -or
    $throttleGate -notmatch 'StatusCode == 403' -or $throttleGate -notmatch 'quota-by-key' -or
    ($throttleMetrics.name -join ',') -cne 'copilot_byok_throttled,copilot_byok_caller_throttled' -or
    @($throttleMetrics | Where-Object { $_.SelectNodes('dimension').Count -gt 5 }).Count -or
    $foundryTemplate.variables.sharedCallerThrottleTelemetry -match 'byokJwtToken|Request.Headers|Request.Body') { throw 'Shared throttle telemetry must preserve compatibility without attributing invalid tokens or logging credentials.' }
  if (($throttleMetrics[1].SelectNodes('dimension').name -join ',') -cne 'auth_method,issuer,principal,operation,throttle') { throw 'Issuer-qualified throttle dimensions changed.' }
  $tierThrottle = $throttleTelemetry.SelectSingleNode('/fragment/choose/when/choose/when/emit-metric')
  if ($null -eq $tierThrottle -or $tierThrottle.name -cne 'copilot_byok_tier_throttled' -or
      ($tierThrottle.SelectNodes('dimension').name -join ',') -cne 'auth_method,tier,operation,throttle' -or
      -not $tierThrottle.ParentNode.condition.Contains('Regex.IsMatch') -or -not $tierThrottle.ParentNode.condition.Contains('"burst", "tokens", "quota"') -or
      $tierThrottle.OuterXml -match 'parsedJwt|byokJwtToken|callerSubject|callerPrincipalKey|Request\.|claims|groups') { throw 'Tier throttle telemetry must exclude flat/invalid selection and backend errors without changing identity metrics.' }
  Write-Output 'PASS: shared JWT throttle telemetry retains legacy dimensions and adds issuer-qualified identity with the five-dimension limit.'
  [xml]$responsePreparation = '<fragment>' + $foundryTemplate.variables.sharedResponsesPreparation + '</fragment>'
  $preparationIncludes = @($responsePreparation.SelectNodes('//include-fragment') | ForEach-Object { $_.GetAttribute('fragment-id') })
  if (($preparationIncludes -join ',') -cne 'byok-response-owner-context,byok-prepare-responses-request,byok-locate-response-owner' -or
    $responsePreparation.SelectNodes('//set-body|//forward-request').Count) { throw 'Response stamping/ownership verification must precede model execution without replacing stream behavior.' }
  foreach ($mode in @('jwt', 'subscriptionKey')) {
    $required = ($mode -eq 'subscriptionKey').ToString().ToLowerInvariant()
    $responseText = $foundryTemplate.variables.responsesItemTemplate.Replace('__SHARED_AUTHENTICATION__', $foundryTemplate.variables.sharedModelsAuthentication.Replace('__NATIVE_SUBSCRIPTION_REQUIRED__', $required))
    [xml]$responsePolicy = $responseText
    $includes = @($responsePolicy.SelectNodes('//include-fragment') | ForEach-Object { $_.GetAttribute('fragment-id') })
    if (($includes -join ',') -cne 'byok-authenticate,byok-strip-caller-credentials,byok-response-owner-context,byok-locate-response-owner' -or
      $responsePolicy.SelectNodes('//base|//rate-limit-by-key|//quota-by-key|//azure-openai-token-limit|//llm-emit-token-metric').Count -or
      $responseText.Contains('context.Request.Body') -or
      $responsePolicy.SelectSingleNode('/policies/backend/retry/forward-request').GetAttribute('buffer-response') -ne 'false' -or
      $responsePolicy.SelectSingleNode('/policies/inbound/rewrite-uri').GetAttribute('copy-unmatched-params') -ne 'true') { throw 'Responses utilities must explicitly authenticate/authorize without inherited inference accounting or stream buffering.' }
    $lookupPosition = $responseText.IndexOf('<include-fragment fragment-id="byok-locate-response-owner" />', [StringComparison]::Ordinal)
    if ($lookupPosition -gt $responseText.IndexOf('<set-backend-service', [StringComparison]::Ordinal)) { throw 'A stored response operation was routed before ownership verification.' }
    $jwtRejection = $responsePolicy.SelectSingleNode('/policies/on-error/choose/when')
    if ($jwtRejection.condition -cne '@(context.LastError.Source == "validate-jwt" && context.Response != null && context.Response.StatusCode == 401)' -or
      $jwtRejection.SelectSingleNode('return-response/set-status').code -ne '401' -or
      $responsePolicy.SelectSingleNode('/policies/on-error/return-response/set-status').code -ne '503') { throw 'Responses errors must preserve JWT rejection and sanitize backend failures.' }
  }
  $responsePolicyResources = @($foundryResources | Where-Object { $_.type -eq 'Microsoft.ApiManagement/service/apis/operations/policies' -and $_.name -match 'responses-(get|delete|cancel|input-items)' })
  if ($responsePolicyResources.Count -ne 4 -or @($responsePolicyResources | Where-Object { $_.properties.value -cne "[variables('responsesItemPolicy')]" }).Count -or
    -not $foundryTemplate.variables.responsesItemPolicy.StartsWith("[if(parameters('sharedInferenceAuth'), variables('sharedResponsesItemPolicy'), ")) { throw 'All four registered Responses follow-ups must select the ownership policy together.' }
  Write-Output 'PASS: all four stored Responses operations explicitly authenticate, verify ownership, pin the owning backend and preserve streaming; continuation ownership is required before inference.'
}
if ($CompiledAoaiTemplatePath) {
  $aoaiTemplate = Get-Content -Raw -LiteralPath $CompiledAoaiTemplatePath | ConvertFrom-Json -Depth 100
  $resources = if ($aoaiTemplate.resources -is [array]) { @($aoaiTemplate.resources) } else { @($aoaiTemplate.resources.PSObject.Properties.Value) }
  $api = @($resources | Where-Object type -eq 'Microsoft.ApiManagement/service/apis')[0]
  $aoaiPolicyResource = @($resources | Where-Object type -eq 'Microsoft.ApiManagement/service/apis/policies')[0]
  if ($aoaiTemplate.parameters.sharedInferenceAuth.defaultValue -ne $false -or $api.properties.path -cne 'aoai' -or
    $api.properties.subscriptionRequired -cne "[equals(parameters('authMode'), 'subscriptionKey')]" -or
    -not $aoaiPolicyResource.properties.value.StartsWith("[if(parameters('sharedInferenceAuth'), variables('sharedInferencePolicy'), if(equals(parameters('authMode'), 'jwt'), variables('inferencePolicySources').jwt, __bicep.")) { throw 'AOAI shared consumer changed default admission or legacy policy selection.' }
  foreach ($mode in @('jwt', 'subscriptionKey')) {
    $path = if ($mode -eq 'jwt') { 'policies/byok-aoai-policy.xml' } else { 'policies/byok-aoai-policy-subkey.xml' }
    $binding = $aoaiTemplate.variables.inferencePolicySources.$mode
    if ($binding -match "^\[variables\('([^']+)'\)\]$") { $binding = $aoaiTemplate.variables.($Matches[1]) }
    if ($binding.Replace("`r`n", "`n") -cne (Get-Content -Raw (Join-Path $root $path)).Replace("`r`n", "`n")) { throw 'AOAI compiled source is stale.' }
  }
  foreach ($sourceName in @('sharedModelsAuthentication', 'sharedResponsesPreparation', 'sharedResponseAffinity', 'responsesItemTemplate')) {
    $imported = @($aoaiTemplate.variables.PSObject.Properties | Where-Object { $_.Name.EndsWith('.' + $sourceName) -or $_.Name -ceq $sourceName })
    if ($imported.Count -ne 1 -or $imported[0].Value -isnot [string] -or $imported[0].Value.StartsWith('[')) { throw ('Shared AOAI consumer block is not a compile-time imported constant: ' + $sourceName) }
  }
  $itemPolicies = @($resources | Where-Object { $_.type -eq 'Microsoft.ApiManagement/service/apis/operations/policies' })
  if ($itemPolicies.Count -ne 1 -or $itemPolicies[0].condition -cne "[parameters('sharedInferenceAuth')]" -or
    $itemPolicies[0].properties.value -cne "[variables('ownedResponsePolicy')]" -or @($aoaiTemplate.variables.responseOperations).Count -ne 4 -or
    ($aoaiTemplate.variables.responseOperations.name -join ',') -cne 'responses-get,responses-delete,responses-cancel,responses-input-items') { throw 'AOAI Responses follow-ups are not all protected under the opt-in.' }
  $affinity = @($aoaiTemplate.variables.PSObject.Properties | Where-Object { $_.Name.EndsWith('.sharedResponseAffinity') -or $_.Name -ceq 'sharedResponseAffinity' })[0].Value
  $aoaiAffinity = $affinity.Replace('((bool)context.Variables[&quot;isCommercialModel&quot;] ? &quot;commercial&quot; : ((bool)context.Variables[&quot;routeToAoai&quot;] ? &quot;aoai&quot; : &quot;foundry&quot;))', '&quot;aoai&quot;')
  if ($aoaiAffinity.Contains('isCommercialModel') -or $aoaiAffinity.Contains('routeToAoai') -or -not $aoaiAffinity.Contains('!= &quot;aoai&quot;')) { throw 'AOAI response continuation did not pin its original backend family.' }
  Write-Output 'PASS: AOAI reuses the shared auth/ownership blocks, retains legacy defaults and protects all four opt-in Responses follow-ups.'
}
if ($CompiledOwnershipTemplatePath) {
  $ownershipTemplate = Get-Content -Raw -LiteralPath $CompiledOwnershipTemplatePath | ConvertFrom-Json -Depth 100
  if ($ownershipTemplate.parameters.responseOwnerKey.type -cne 'securestring' -or
    $ownershipTemplate.parameters.responseOwnerKey.PSObject.Properties.Name -contains 'defaultValue' -or
    $ownershipTemplate.parameters.responseOwnerPreviousKey.type -cne 'securestring' -or
    $ownershipTemplate.parameters.backendOrigins.minLength -ne 1 -or $ownershipTemplate.parameters.backendOrigins.maxLength -ne 8 -or
    $ownershipTemplate.parameters.responseStores.minLength -ne 1 -or $ownershipTemplate.parameters.responseStores.maxLength -ne 8 -or
    $ownershipTemplate.outputs.callerAuthDependency.value -cne "[parameters('callerAuthFragmentIds')]") { throw 'Ownership deployment must require its stable secret and bounded configured origins.' }
  $ownershipResources = if ($ownershipTemplate.resources -is [array]) { @($ownershipTemplate.resources) } else { @($ownershipTemplate.resources.PSObject.Properties.Value) }
  $keyResources = @($ownershipResources | Where-Object { $_.type -eq 'Microsoft.ApiManagement/service/namedValues' -and $_.name -match 'caller-response-owner-key' })
  if ($keyResources.Count -ne 2 -or @($keyResources | Where-Object { $_.properties.secret -ne $true }).Count -or
    ($ownershipTemplate.outputs | ConvertTo-Json -Depth 20 -Compress) -match 'responseOwnerKey|responseOwnerPreviousKey') { throw 'Ownership secrets must not be plaintext named values or module outputs.' }
  foreach ($entry in $ownershipTemplate.variables.ownershipPolicies | Where-Object name -ne 'byok-locate-response-owner') {
    $source = Get-Content -Raw (Join-Path $root ('policies/fragments/' + $entry.name + '.xml'))
    $binding = $entry.value
    if ($binding -match "^\[variables\('([^']+)'\)\]$") { $binding = $ownershipTemplate.variables.($Matches[1]) }
    if ($binding.Replace("`r`n", "`n") -cne $source.Replace("`r`n", "`n")) { throw 'Compiled ownership policy is stale.' }
    [xml]$policy = $binding
    if ($policy.DocumentElement.Name -ne 'fragment' -or $policy.SelectNodes('//include-fragment|//base|//inbound|//backend|//outbound|//on-error').Count -or
      [Text.Encoding]::UTF8.GetByteCount($binding) -gt 32768) { throw 'Ownership policies must be flat valid fragments within the project size budget.' }
  }
  $lookupSources = @{}
  foreach ($entry in @(@{ key='locate'; name='byok-locate-response-owner' }, @{ key='credential'; name='byok-response-backend-credential' }, @{ key='read'; name='byok-read-response-owner' }, @{ key='verify'; name='byok-verify-response-owner' })) {
    $binding = $ownershipTemplate.variables.lookupSources.($entry.key)
    if ($binding -match "^\[variables\('([^']+)'\)\]$") { $binding = $ownershipTemplate.variables.($Matches[1]) }
    $source = Get-Content -Raw (Join-Path $root ('policies/fragments/' + $entry.name + '.xml'))
    if ($binding.Replace("`r`n", "`n") -cne $source.Replace("`r`n", "`n")) { throw 'Compiled ownership lookup source is stale.' }
    $lookupSources[$entry.key] = $binding
  }
  $evaluationOnly = $lookupSources.verify.Substring('<fragment>'.Length, $lookupSources.verify.IndexOf('<choose>', [StringComparison]::Ordinal) - '<fragment>'.Length)
  $flatLookup = $lookupSources.locate.Replace('<include-fragment fragment-id="byok-response-backend-credential" />', $lookupSources.credential.Replace('<fragment>', '').Replace('</fragment>', '')).Replace('<include-fragment fragment-id="byok-read-response-owner" />', $lookupSources.read.Replace('<fragment>', '').Replace('</fragment>', '')).Replace('<include-fragment fragment-id="byok-evaluate-response-owner" />', $evaluationOnly)
  [xml]$lookupPolicy = $flatLookup
  if ($lookupPolicy.SelectNodes('//include-fragment|//base|//inbound|//outbound|//backend|//on-error').Count -or
    $lookupPolicy.SelectSingleNode('/fragment/retry').count -ne '7' -or
    $lookupPolicy.SelectSingleNode('/fragment/choose[last()]/when').condition -cne '@(!(bool)context.Variables["byokResponseOwnerAuthorized"])' -or
    [Text.Encoding]::UTF8.GetByteCount($flatLookup) -gt 32768) { throw 'Ownership lookup must be flat, bounded and reject unless a configured store proves ownership.' }
  if (@($ownershipTemplate.variables.ownershipPolicies).Count -ne 5) { throw 'Ownership package is missing a required component.' }
  Write-Output 'PASS: ownership package requires stable secure inputs, exposes no key output, and embeds flat ownership policies with bounded configured-store lookup.'
}
if ($CheckProvisionGuards) {
  $fixturePath = Join-Path ([IO.Path]::GetTempPath()) ('caller-params-' + [guid]::NewGuid().ToString('N') + '.json')
  $bash = if ($IsWindows) { Join-Path $env:ProgramFiles 'Git/bin/bash.exe' } else { (Get-Command bash -ErrorAction Stop).Source }
  $savedSkip = $env:SKIP_PROVISION_PARAM_CHECK
  $savedIssuer = $env:BYOK_FIXTURE_ISSUER
  $checked = 0
  try {
    foreach ($case in @('legacy-key', 'legacy-jwt', 'disabled', 'key-only', 'entra-only', 'okta-only', 'all-methods', 'commercial',
      'nested-substitution', 'no-methods', 'string-flag', 'missing-property', 'unknown-property', 'unknown-cloud', 'empty-tenant',
      'zero-tenant', 'uppercase-tenant', 'bad-audience', 'empty-scope', 'client-is-audience', 'bad-entra-client', 'duplicate-entra-client',
      'product-collision', 'bad-product', 'okta-org-server', 'okta-http', 'okta-user-info', 'okta-query', 'okta-port',
      'okta-placeholder', 'okta-localhost', 'okta-metadata', 'okta-empty-audience', 'okta-unsafe-audience', 'okta-empty-scope',
      'okta-no-clients', 'okta-any-client', 'okta-client-is-audience', 'okta-duplicate-client', 'okta-string-clients',
      'unresolved-substitution', 'skip-does-not-bypass-trust', 'rollout-shared', 'rollout-coexistence', 'rollout-jwt-only',
      'rollout-unknown', 'rollout-unprepared', 'rollout-no-key', 'rollout-bad-key', 'rollout-noncanonical-key', 'rollout-zero-key',
      'rollout-same-rotation-key', 'rollout-zero-previous-key', 'rollout-rotation-key', 'rollout-too-many-stores', 'rollout-no-routes', 'coexistence-no-native', 'coexistence-no-issuer',
      'tier-disabled', 'tier-entra', 'tier-okta', 'tier-both', 'tier-legacy', 'tier-unprepared', 'tier-disabled-issuer',
      'tier-bad-shape', 'tier-unknown-field', 'tier-string-flag', 'tier-map-scalar', 'tier-empty-map', 'tier-duplicate-map',
      'tier-unknown-map', 'tier-unsafe-claim', 'tier-reserved-claim', 'tier-missing-catalog', 'tier-empty-catalog',
      'tier-large-catalog', 'tier-duplicate-catalog', 'tier-bad-name', 'tier-zero-limit', 'tier-string-limit',
      'tier-fraction-limit', 'tier-large-limit', 'tier-boolean-limit', 'tier-skip-bypass')) {
      $env:SKIP_PROVISION_PARAM_CHECK = $null
      $env:BYOK_FIXTURE_ISSUER = 'https://fixture.example.test/oauth2/fixture'
      $fixtureTenant = [guid]::NewGuid().ToString()
      $fixtureAudience = [guid]::NewGuid().ToString()
      $fixtureClient = [guid]::NewGuid().ToString()
      $fixtureOwnerKey = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
      $preparation = [ordered]@{
        enabled = $true; keyEnabled = $true; entraEnabled = $true; entraClientIds = @($fixtureClient); jwtProductId = 'byok-jwt'
        oktaTrust = [ordered]@{
          enabled = $true; issuer = $env:BYOK_FIXTURE_ISSUER; openIdConfigUrl = $env:BYOK_FIXTURE_ISSUER + '/.well-known/openid-configuration'
          audience = 'api://fixture-gateway'; requiredScope = 'cli.invoke'; clientIds = @('fixture-client')
        }
      }
      $fixtureParameters = [ordered]@{
        authMode = @{ value = 'subscriptionKey' }; cloudEnv = @{ value = 'AzureUSGovernment' }
        entraTenantId = @{ value = $fixtureTenant }; apiAudience = @{ value = $fixtureAudience }; requiredScope = @{ value = 'cli.invoke' }
        callerAuthPreparation = @{ value = $preparation }
      }
      if ($case -like 'rollout-*' -or $case -like 'coexistence-*' -or $case -like 'tier-*') {
        $fixtureParameters.callerAuthRollout = @{ value = 'shared' }
        $fixtureParameters.responseOwnerKey = @{ value = $fixtureOwnerKey }
      }
      if ($case -like 'tier-*') {
        $fixtureParameters.callerJwtTiering = @{value = @{
          entra = @{enabled = $true; mappings = @(@{claimValue = 'Byok.Standard'; tier = 'byok-standard'})}
          okta = @{enabled = $case -cin @('tier-okta', 'tier-both'); claimName = 'byok_tier'; mappings = @(@{claimValue = 'Byok.Standard'; tier = 'byok-standard'})}
        }}
        $fixtureParameters.productTiers = @{value = @(@{name = 'byok-standard'; callsPerMinute = 60; tokensPerMinute = 100000; monthlyCallQuota = 50000})}
      }
      switch ($case) {
        'legacy-key' { $fixtureParameters.Remove('callerAuthPreparation') }
        'legacy-jwt' { $fixtureParameters.Remove('callerAuthPreparation'); $fixtureParameters.authMode.value = 'jwt' }
        'disabled' { $preparation.enabled = $false; $fixtureParameters.entraTenantId.value = '<TENANT_ID>' }
        'key-only' { $preparation.entraEnabled = $false; $preparation.oktaTrust.enabled = $false; $fixtureParameters.entraTenantId.value = '<TENANT_ID>' }
        'entra-only' { $preparation.keyEnabled = $false; $preparation.oktaTrust.enabled = $false; $preparation.entraClientIds = @() }
        'okta-only' { $preparation.keyEnabled = $false; $preparation.entraEnabled = $false }
        'commercial' { $fixtureParameters.cloudEnv.value = 'AzureCloud' }
        'nested-substitution' { $preparation.oktaTrust.issuer = '${BYOK_FIXTURE_ISSUER}'; $preparation.oktaTrust.openIdConfigUrl = '${BYOK_FIXTURE_ISSUER}/.well-known/openid-configuration' }
        'no-methods' { $preparation.keyEnabled = $false; $preparation.entraEnabled = $false; $preparation.oktaTrust.enabled = $false }
        'string-flag' { $preparation.enabled = 'false' }
        'missing-property' { $preparation.Remove('keyEnabled') }
        'unknown-property' { $preparation.extra = $true }
        'unknown-cloud' { $fixtureParameters.cloudEnv.value = 'unknown' }
        'empty-tenant' { $fixtureParameters.entraTenantId.value = '' }
        'zero-tenant' { $fixtureParameters.entraTenantId.value = [guid]::Empty.ToString() }
        'uppercase-tenant' { $fixtureParameters.entraTenantId.value = $fixtureTenant.ToUpperInvariant() }
        'bad-audience' { $fixtureParameters.apiAudience.value = 'api://fixture' }
        'empty-scope' { $fixtureParameters.requiredScope.value = '' }
        'client-is-audience' { $preparation.entraClientIds = @($fixtureAudience) }
        'bad-entra-client' { $preparation.entraClientIds = @('not-a-client-id') }
        'duplicate-entra-client' { $preparation.entraClientIds = @($fixtureClient, $fixtureClient) }
        'product-collision' { $preparation.jwtProductId = 'byok-standard' }
        'bad-product' { $preparation.jwtProductId = '../product' }
        'okta-org-server' { $preparation.oktaTrust.issuer = 'https://fixture.example.test' }
        'okta-http' { $preparation.oktaTrust.issuer = 'http://fixture.example.test/oauth2/fixture' }
        'okta-user-info' { $preparation.oktaTrust.issuer = 'https://user@fixture.example.test/oauth2/fixture' }
        'okta-query' { $preparation.oktaTrust.issuer += '?query=value' }
        'okta-port' { $preparation.oktaTrust.issuer = 'https://fixture.example.test:444/oauth2/fixture' }
        'okta-placeholder' { $preparation.oktaTrust.issuer = 'https://unset.invalid/oauth2/fixture' }
        'okta-localhost' { $preparation.oktaTrust.issuer = 'https://fixture.localhost/oauth2/fixture' }
        'okta-metadata' { $preparation.oktaTrust.openIdConfigUrl = 'https://other.example.test/metadata' }
        'okta-empty-audience' { $preparation.oktaTrust.audience = '' }
        'okta-unsafe-audience' { $preparation.oktaTrust.audience = 'private-fixture"value' }
        'okta-empty-scope' { $preparation.oktaTrust.requiredScope = '' }
        'okta-no-clients' { $preparation.oktaTrust.clientIds = @() }
        'okta-any-client' { $preparation.oktaTrust.clientIds = @('__any__') }
        'okta-client-is-audience' { $preparation.oktaTrust.audience = 'fixture-client' }
        'okta-duplicate-client' { $preparation.oktaTrust.clientIds = @('fixture-client', 'fixture-client') }
        'okta-string-clients' { $preparation.oktaTrust.clientIds = 'fixture-client' }
        'unresolved-substitution' { $env:BYOK_FIXTURE_ISSUER = $null; $preparation.oktaTrust.issuer = '${BYOK_FIXTURE_ISSUER}' }
        'skip-does-not-bypass-trust' { $env:SKIP_PROVISION_PARAM_CHECK = 'true'; $fixtureParameters.entraTenantId.value = '' }
        'rollout-coexistence' { $fixtureParameters.callerAuthRollout.value = 'coexistence' }
        'rollout-jwt-only' { $preparation.keyEnabled = $false; $preparation.oktaTrust.enabled = $false }
        'rollout-unknown' { $fixtureParameters.callerAuthRollout.value = 'unknown' }
        'rollout-unprepared' { $preparation.enabled = $false }
        'rollout-no-key' { $fixtureParameters.responseOwnerKey.value = '' }
        'rollout-bad-key' { $fixtureParameters.responseOwnerKey.value = 'invalid' }
        'rollout-noncanonical-key' { $fixtureParameters.responseOwnerKey.value = ('A' * 42) + 'B=' }
        'rollout-zero-key' { $fixtureParameters.responseOwnerKey.value = ('A' * 43) + '=' }
        'rollout-same-rotation-key' { $fixtureParameters.responseOwnerPreviousKey = @{ value = $fixtureOwnerKey } }
        'rollout-zero-previous-key' { $fixtureParameters.responseOwnerPreviousKey = @{ value = ('A' * 43) + '=' } }
        'rollout-rotation-key' { $fixtureParameters.responseOwnerPreviousKey = @{ value = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) } }
        'rollout-too-many-stores' { $fixtureParameters.foundryRegions = @{ value = @('region-a') * 8 } }
        'rollout-no-routes' { $fixtureParameters.deployFoundry = @{ value = $false }; $fixtureParameters.deployAoai = @{ value = $false } }
        'coexistence-no-native' { $fixtureParameters.callerAuthRollout.value = 'coexistence'; $preparation.keyEnabled = $false }
        'coexistence-no-issuer' { $fixtureParameters.callerAuthRollout.value = 'coexistence'; $preparation.entraEnabled = $false; $preparation.oktaTrust.enabled = $false }
        'tier-disabled' { $fixtureParameters.callerJwtTiering.value.entra.enabled = $false; $fixtureParameters.callerAuthRollout.value = 'legacy'; $fixtureParameters.Remove('productTiers') }
        'tier-okta' { $fixtureParameters.callerJwtTiering.value.entra.enabled = $false }
        'tier-legacy' { $fixtureParameters.callerAuthRollout.value = 'legacy' }
        'tier-unprepared' { $preparation.enabled = $false }
        'tier-disabled-issuer' { $preparation.entraEnabled = $false }
        'tier-bad-shape' { $fixtureParameters.callerJwtTiering.value = @($fixtureParameters.callerJwtTiering.value) }
        'tier-unknown-field' { $fixtureParameters.callerJwtTiering.value.extra = $true }
        'tier-string-flag' { $fixtureParameters.callerJwtTiering.value.entra.enabled = 'true' }
        'tier-map-scalar' { $fixtureParameters.callerJwtTiering.value.entra.mappings = 'Byok.Standard' }
        'tier-empty-map' { $fixtureParameters.callerJwtTiering.value.entra.mappings = @() }
        'tier-duplicate-map' { $fixtureParameters.callerJwtTiering.value.entra.mappings += $fixtureParameters.callerJwtTiering.value.entra.mappings[0] }
        'tier-unknown-map' { $fixtureParameters.callerJwtTiering.value.entra.mappings[0].tier = 'missing-tier' }
        'tier-unsafe-claim' { $fixtureParameters.callerJwtTiering.value.entra.mappings[0].claimValue = 'private-fixture"role' }
        'tier-reserved-claim' { $fixtureParameters.callerJwtTiering.value.okta.claimName = 'sub' }
        'tier-missing-catalog' { $fixtureParameters.Remove('productTiers') }
        'tier-empty-catalog' { $fixtureParameters.productTiers.value = @() }
        'tier-large-catalog' { $fixtureParameters.productTiers.value = @($fixtureParameters.productTiers.value[0]) * 9 }
        'tier-duplicate-catalog' { $fixtureParameters.productTiers.value += $fixtureParameters.productTiers.value[0] }
        'tier-bad-name' { $fixtureParameters.productTiers.value[0].name = 'bad"tier' }
        'tier-zero-limit' { $fixtureParameters.productTiers.value[0].tokensPerMinute = 0 }
        'tier-string-limit' { $fixtureParameters.productTiers.value[0].tokensPerMinute = '200000' }
        'tier-fraction-limit' { $fixtureParameters.productTiers.value[0].monthlyCallQuota = 2.5 }
        'tier-large-limit' { $fixtureParameters.productTiers.value[0].callsPerMinute = 2147483648 }
        'tier-boolean-limit' { $fixtureParameters.productTiers.value[0].callsPerMinute = $true }
        'tier-skip-bypass' { $env:SKIP_PROVISION_PARAM_CHECK = 'true'; $fixtureParameters.callerJwtTiering.value.entra.mappings = @() }
      }
      @{ parameters = $fixtureParameters } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $fixturePath -Encoding utf8
      $output = @(& (Join-Path $root 'scripts/check-provision-params.ps1') -ParameterFile $fixturePath 6>&1) | Out-String
      $expected = $case -in @('legacy-key', 'legacy-jwt', 'disabled', 'key-only', 'entra-only', 'okta-only', 'all-methods', 'commercial', 'nested-substitution', 'rollout-shared', 'rollout-coexistence', 'rollout-jwt-only', 'rollout-rotation-key', 'tier-disabled', 'tier-entra', 'tier-okta', 'tier-both')
      if (($LASTEXITCODE -eq 0) -ne $expected -or $output.Contains($fixtureTenant) -or $output.Contains($fixtureAudience) -or
        $output.Contains('private-fixture') -or $output.Contains('fixture.example.test') -or $output.Contains($fixtureOwnerKey)) { throw ('Pre-provision trust result or redaction failed: ' + $case) }
      $bashOutput = @(& $bash (Join-Path $root 'scripts/check-provision-params.sh').Replace('\', '/') $fixturePath.Replace('\', '/') 2>&1) | Out-String
      if (($LASTEXITCODE -eq 0) -ne $expected -or $bashOutput.Contains($fixtureTenant) -or $bashOutput.Contains($fixtureAudience) -or
        $bashOutput.Contains('private-fixture') -or $bashOutput.Contains('fixture.example.test') -or $bashOutput.Contains($fixtureOwnerKey)) { throw ('Bash pre-provision trust result or redaction failed: ' + $case) }
      $checked++
    }
    $env:SKIP_PROVISION_PARAM_CHECK = $null
    foreach ($example in Get-ChildItem (Join-Path $root 'infra/main.parameters.*.example.json')) {
      $parameters = (Get-Content -Raw $example.FullName | ConvertFrom-Json).parameters
      if ($parameters.callerAuthPreparation.value.enabled -ne $false -or $parameters.callerAuthPreparation.value.oktaTrust.enabled -ne $false) { throw 'Published examples must not enable caller-auth preparation.' }
      $null = & (Join-Path $root 'scripts/check-provision-params.ps1') -ParameterFile $example.FullName 6>&1
      if ($LASTEXITCODE -ne 0) { throw 'Published example failed the PowerShell preparation guard.' }
      $null = & $bash (Join-Path $root 'scripts/check-provision-params.sh').Replace('\', '/') $example.FullName.Replace('\', '/') 2>&1
      if ($LASTEXITCODE -ne 0) { throw 'Published example failed the Bash preparation guard.' }
      $checked++
    }
    $stageNames = @('BYOK_CALLER_AUTH_PREPARATION','BYOK_CALLER_AUTH_ROLLOUT','BYOK_CALLER_JWT_TIERING','BYOK_RESPONSE_OWNER_KEY','BYOK_RESPONSE_OWNER_PREVIOUS_KEY','FOUNDRY_API_KEY')
    $stageSaved = @{}
    foreach ($name in $stageNames) { $stageSaved[$name] = [Environment]::GetEnvironmentVariable($name) }
    $stageChecked = 0
    try {
      foreach ($scenario in @('absent','prepare-only','legacy','shared','coexistence','rotation','rotation-slash-current','rotation-slash-previous','rotation-plus-current','rotation-plus-previous','missing-key','missing-previous','zero-previous','invalid-json','array-preparation','unknown-rollout','coexistence-key-only','tier-entra','tier-disabled','tier-bad-json','tier-invalid-map','tier-legacy')) {
        foreach ($name in $stageNames) { [Environment]::SetEnvironmentVariable($name, $null) }
        $ownerKey = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
        $previousOwnerKey = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
        $stagePreparation = [ordered]@{
          enabled = $true; keyEnabled = $true; entraEnabled = $true; entraClientIds = @(); jwtProductId = 'byok-jwt'
          oktaTrust = [ordered]@{ enabled = $false; issuer = ''; openIdConfigUrl = ''; audience = ''; requiredScope = ''; clientIds = @() }
        }
        $baseline = @{ parameters = [ordered]@{
          cloudEnv = @{value='AzureUSGovernment'}; authMode = @{value='subscriptionKey'}
          entraTenantId = @{value=[guid]::NewGuid().ToString()}; apiAudience = @{value=[guid]::NewGuid().ToString()}; requiredScope = @{value='cli.invoke'}
          productTiers = @{value = @(@{name = 'byok-standard'; callsPerMinute = 60; tokensPerMinute = 100000; monthlyCallQuota = 50000})}
        } } | ConvertTo-Json -Depth 20
        if ($scenario -ne 'absent') {
          $env:BYOK_CALLER_AUTH_ROLLOUT = if ($scenario -in @('coexistence','coexistence-key-only')) { 'coexistence' } elseif ($scenario -eq 'legacy') { 'legacy' } elseif ($scenario -eq 'prepare-only') { '' } else { 'shared' }
          $env:BYOK_CALLER_AUTH_PREPARATION = $stagePreparation | ConvertTo-Json -Depth 10 -Compress
          $env:BYOK_RESPONSE_OWNER_KEY = $ownerKey
          $env:BYOK_RESPONSE_OWNER_PREVIOUS_KEY = '__none__'
        }
        if ($scenario -like 'tier-*') {
          $stageTiering = @{entra = @{enabled = $scenario -cne 'tier-disabled'; mappings = @(@{claimValue = 'Byok.Standard'; tier = 'byok-standard'})}; okta = @{enabled = $false; claimName = 'byok_tier'; mappings = @()}}
          if ($scenario -ceq 'tier-invalid-map') { $stageTiering.entra.mappings[0].tier = 'missing-tier' }
          $env:BYOK_CALLER_JWT_TIERING = $stageTiering | ConvertTo-Json -Depth 8 -Compress
          if ($scenario -ceq 'tier-bad-json') { $env:BYOK_CALLER_JWT_TIERING = '{invalid-json' }
          if ($scenario -ceq 'tier-legacy') { $env:BYOK_CALLER_AUTH_ROLLOUT = 'legacy' }
        }
        if ($scenario -like 'rotation-*') {
          $syntheticByte = if ($scenario -like 'rotation-slash-*') { 255 } else { 251 }
          $encodedFixture = [Convert]::ToBase64String([byte[]](@($syntheticByte) * 32))
          if ($scenario.EndsWith('-current', [StringComparison]::Ordinal)) { $ownerKey = $encodedFixture } else { $previousOwnerKey = $encodedFixture }
          $env:BYOK_RESPONSE_OWNER_KEY = $ownerKey
          $env:BYOK_RESPONSE_OWNER_PREVIOUS_KEY = $previousOwnerKey
        }
        switch ($scenario) {
          'rotation' { $env:BYOK_RESPONSE_OWNER_PREVIOUS_KEY = $previousOwnerKey }
          'missing-key' { $env:BYOK_RESPONSE_OWNER_KEY = $null }
          'missing-previous' { $env:BYOK_RESPONSE_OWNER_PREVIOUS_KEY = $null }
          'zero-previous' { $env:BYOK_RESPONSE_OWNER_PREVIOUS_KEY = ('A' * 43) + '=' }
          'invalid-json' { $env:BYOK_CALLER_AUTH_PREPARATION = '{"broken":' }
          'array-preparation' { $env:BYOK_CALLER_AUTH_PREPARATION = '[' + $env:BYOK_CALLER_AUTH_PREPARATION + ']' }
          'unknown-rollout' { $env:BYOK_CALLER_AUTH_ROLLOUT = 'unknown' }
          'coexistence-key-only' { $stagePreparation.entraEnabled = $false; $env:BYOK_CALLER_AUTH_PREPARATION = $stagePreparation | ConvertTo-Json -Depth 10 -Compress }
        }
        $valid = $scenario -in @('absent','prepare-only','legacy','shared','coexistence','rotation','rotation-slash-current','rotation-slash-previous','rotation-plus-current','rotation-plus-previous','tier-entra','tier-disabled')
        $representations = @()
        foreach ($helper in @('powershell','bash')) {
          [IO.File]::WriteAllText($fixturePath, $baseline, [Text.UTF8Encoding]::new($false))
          $before = (Get-FileHash -LiteralPath $fixturePath).Hash
          $output = if ($helper -eq 'powershell') {
            @(& (Join-Path $root 'scripts/check-provision-params.ps1') -ParameterFile $fixturePath -StageCallerAuth 6>&1) | Out-String
          } else {
            @(& $bash (Join-Path $root 'scripts/check-provision-params.sh').Replace('\','/') --stage-caller-auth $fixturePath.Replace('\','/') 2>&1) | Out-String
          }
          $succeeded = $LASTEXITCODE -eq 0
          $text = Get-Content -LiteralPath $fixturePath -Raw
          if ($succeeded -ne $valid -or $output.Contains($ownerKey) -or $output.Contains($previousOwnerKey) -or $text.Contains($ownerKey) -or $text.Contains($previousOwnerKey)) { throw ('Caller staging result or secret redaction failed: ' + $helper + ':' + $scenario) }
          if (($scenario -eq 'absent' -or -not $valid) -and (Get-FileHash -LiteralPath $fixturePath).Hash -cne $before) { throw 'Absent/invalid caller staging modified its target.' }
          $staged = ($text | ConvertFrom-Json).parameters
          if ($valid -and $scenario -like 'tier-*' -and $staged.callerJwtTiering.value.entra.enabled -ne ($scenario -cne 'tier-disabled')) { throw 'Explicit JWT tier staging did not retain the reviewed enabled/disabled state.' }
          if ($valid -and ($scenario -in @('shared','coexistence') -or $scenario -like 'rotation*') -and
            ($staged.responseOwnerKey.value -cne '${BYOK_RESPONSE_OWNER_KEY}' -or $staged.responseOwnerPreviousKey.value -cne $(if ($scenario -like 'rotation*') { '${BYOK_RESPONSE_OWNER_PREVIOUS_KEY}' } else { '' }))) { throw 'Active caller staging must use key references or the explicit no-previous-key choice.' }
          $representations += ($staged | ConvertTo-Json -Depth 20 -Compress)
        }
        if ($representations[0] -cne $representations[1]) { throw ('PowerShell/Bash caller staging differs: ' + $scenario) }
        $stageChecked++
      }
      $standaloneChecked=0
      foreach($scenario in @('managed-identity','api-key','commercial','rotation','missing-current','missing-previous','file-secret','collision','http-origin','numeric-origin','path-origin','missing-backend-key','unknown-backend-mode','tier-disabled','tier-entra','tier-okta','tier-both','tier-catalog-missing','tier-collision','tier-additional-collision','tier-no-apim','tier-aca','tier-aca-string','tier-aca-number','tier-wrong-issuer','tier-unknown-tier')) {
        $env:BYOK_RESPONSE_OWNER_KEY=[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
        $env:BYOK_RESPONSE_OWNER_PREVIOUS_KEY='__none__'
        $env:FOUNDRY_API_KEY='fixture-backend-credential'
        $cloud=if($scenario -eq 'commercial'){'AzureCloud'}else{'AzureUSGovernment'}
        $values=[ordered]@{
          callerAuthRollout=@{value='shared'};foundryAuthMode=@{value='managedIdentity'};existingBackendOrigin=@{value='https://backend.example.test'}
          existingProductName=@{value='native-fixture'}
          callerAuthPreparation=@{value=[ordered]@{
            enabled=$true;keyEnabled=$true;entraEnabled=$false;entraClientIds=@();jwtProductId='intellij-jwt'
            oktaTrust=@{enabled=$false;issuer='';openIdConfigUrl='';audience='';requiredScope='';clientIds=@()}
          }}
        }
        switch($scenario) {
          'api-key'{$values.foundryAuthMode.value='apiKey'}
          'rotation'{$env:BYOK_RESPONSE_OWNER_PREVIOUS_KEY=[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))}
          'missing-current'{$env:BYOK_RESPONSE_OWNER_KEY=$null}
          'missing-previous'{$env:BYOK_RESPONSE_OWNER_PREVIOUS_KEY=$null}
          'file-secret'{$values.responseOwnerKey=@{value='forbidden-fixture-secret'}}
          'collision'{$values.existingProductName.value='intellij-jwt'}
          'http-origin'{$values.existingBackendOrigin.value='http://backend.example.test'}
          'numeric-origin'{$values.existingBackendOrigin.value='https://127.0.0.1'}
          'path-origin'{$values.existingBackendOrigin.value='https://backend.example.test/openai'}
          'missing-backend-key'{$values.foundryAuthMode.value='apiKey';$env:FOUNDRY_API_KEY=$null}
          'unknown-backend-mode'{$values.foundryAuthMode.value='implicit'}
        }
        if($scenario -like 'tier-*'){
          $values.callerJwtTiering=@{value=@{
            entra=@{enabled=$scenario -cnotin @('tier-disabled','tier-okta');mappings=@(@{claimValue='Byok.Standard';tier='byok-standard'})}
            okta=@{enabled=$scenario -cin @('tier-okta','tier-both');claimName='byok_tier';mappings=@(@{claimValue='Byok.Standard';tier='byok-standard'})}
          }}
          if($scenario -cne 'tier-disabled'){
            $values.productTiers=@{value=@(@{name='byok-standard';callsPerMinute=60;tokensPerMinute=100000;monthlyCallQuota=50000})}
            $values.entraTenantId=@{value=[guid]::NewGuid().ToString()}
            $values.apiAudience=@{value=[guid]::NewGuid().ToString()}
            $values.callerAuthPreparation.value.entraEnabled=$values.callerJwtTiering.value.entra.enabled
            $values.callerAuthPreparation.value.oktaTrust=@{enabled=$values.callerJwtTiering.value.okta.enabled;issuer='https://fixture.example.test/oauth2/fixture';openIdConfigUrl='https://fixture.example.test/oauth2/fixture/.well-known/openid-configuration';audience='api://fixture-gateway';requiredScope='cli.invoke';clientIds=@('fixture-client')}
          }
          switch($scenario){
            'tier-catalog-missing'{$values.Remove('productTiers')}
            'tier-collision'{$values.existingProductName.value='intellij-jwt'}
            'tier-additional-collision'{$values.additionalProductNames=@{value=@('intellij-jwt')}}
            'tier-no-apim'{$values.configureApim=@{value=$false}}
            'tier-aca'{$values.configureApim=@{value=$true}}
            'tier-aca-string'{$values.configureApim=@{value='true'}}
            'tier-aca-number'{$values.configureApim=@{value=1}}
            'tier-wrong-issuer'{$values.callerAuthPreparation.value.entraEnabled=$false}
            'tier-unknown-tier'{$values.callerJwtTiering.value.entra.mappings[0].tier='missing-tier'}
          }
        }
        [IO.File]::WriteAllText($fixturePath,(@{parameters=$values}|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        $before=(Get-FileHash -LiteralPath $fixturePath).Hash
        $valid=$scenario -in @('managed-identity','api-key','commercial','rotation','tier-disabled','tier-entra','tier-okta','tier-both','tier-aca')
        foreach($helper in @('powershell','bash')) {
          $output=if($helper -eq 'powershell') {
            @(& (Join-Path $root 'scripts/check-provision-params.ps1') -ParameterFile $fixturePath -StandaloneCloud $cloud 6>&1)|Out-String
          } else {
            @(& $bash (Join-Path $root 'scripts/check-provision-params.sh').Replace('\','/') --standalone-cloud $cloud $fixturePath.Replace('\','/') 2>&1)|Out-String
          }
          if(($LASTEXITCODE -eq 0) -ne $valid -or (Get-FileHash -LiteralPath $fixturePath).Hash -cne $before){throw ('Standalone paired guard result or file mutation: '+$helper+':'+$scenario)}
          foreach($secret in @($env:BYOK_RESPONSE_OWNER_KEY,$env:BYOK_RESPONSE_OWNER_PREVIOUS_KEY,$env:FOUNDRY_API_KEY,'forbidden-fixture-secret')){
            if($secret -and $secret -ne '__none__' -and $output.Contains($secret)){throw 'Standalone guard disclosed a credential.'}
          }
        }
        $standaloneChecked++
      }
      Write-Output "PASS: $standaloneChecked paired standalone cases enforce explicit backend/ownership credentials without file writes or secret output."
    } finally { foreach ($name in $stageNames) { [Environment]::SetEnvironmentVariable($name, $stageSaved[$name]) } }
    Write-Output ('PASS: ' + $stageChecked + ' paired caller-auth staging cases preserve defaults, validate before writing and never serialize ownership secrets.')
  } finally {
    $env:SKIP_PROVISION_PARAM_CHECK = $savedSkip
    $env:BYOK_FIXTURE_ISSUER = $savedIssuer
    if (Test-Path -LiteralPath $fixturePath) { Remove-Item -LiteralPath $fixturePath -Force }
  }
  Write-Output ('PASS: ' + $checked + ' matching PowerShell/Bash preparation guard cases using synthetic parameter files; no Azure calls.')
}
exit 0