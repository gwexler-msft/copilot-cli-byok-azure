#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$CompiledMainTemplatePath,[Parameter(Mandatory)][string]$CompiledApimTemplatePath)

$ErrorActionPreference='Stop'
$workflows=[Console]::In.ReadToEnd()|ConvertFrom-Json -AsHashtable
$workflow=$workflows.deploy
$teardown=$workflows.teardown
$pilot=$workflows.pilot
$smoke=$workflows.smoke
if(-not $workflow.jobs -or -not $teardown.jobs -or -not $pilot.jobs -or -not $smoke.jobs){throw 'Provide development, pilot and smoke lifecycle workflow documents.'}
function Assert-DevAzureCliRefreshBoundaries {
  param($Workflow)
  $job=$Workflow.jobs.provision
  if($job.'timeout-minutes' -cne '${{ endsWith(matrix.env, ''-dev'') && 70 || 60 }}' -or
    $job.concurrency.group -cne 'dev-env-${{ matrix.env }}' -or $job.concurrency.'cancel-in-progress' -cne 'false' -or
    $job.strategy.'fail-fast' -cne 'false'){throw 'Dev time budget or lifecycle isolation changed.'}
  $initial=@($job.steps|Where-Object name -CEQ 'Azure CLI login (OIDC)')
  if($initial.Count -ne 1 -or $initial[0].uses -cne 'azure/login@v2'){throw 'Initial Azure CLI federation binding changed.'}
  $expected=[ordered]@{
    'Refresh Azure CLI OIDC before phase one'='azd provision (phase 1*'
    'Refresh Azure CLI OIDC before register image deployment'='Deploy register app image'
    'Refresh Azure CLI OIDC before Easy Auth setup'='Easy Auth setup (app reg + secret -> Key Vault)'
    'Refresh Azure CLI OIDC before phase two'='azd provision (phase 2*'
    'Refresh Azure CLI OIDC before completion marker'='Mark dev environment complete'
  }
  if(@($job.steps|Where-Object {$_.name -like 'Refresh Azure CLI OIDC*'}).Count -ne $expected.Count){throw 'OIDC refresh boundaries are incomplete.'}
  foreach($name in $expected.Keys){
    $refresh=@($job.steps|Where-Object name -CEQ $name)
    $target=@($job.steps|Where-Object {$_.name -like $expected[$name]})
    if($refresh.Count -ne 1 -or $target.Count -ne 1 -or
      [array]::IndexOf($job.steps,$refresh[0])+1 -ne [array]::IndexOf($job.steps,$target[0]) -or
      $refresh[0].uses -cne $initial[0].uses -or $refresh[0]['if'] -cne $target[0]['if'] -or
      $refresh[0]['if'] -notlike '*steps.preflight.outputs.provision*true*' -or
      $refresh[0].env.AZURE_LOGIN_PRE_CLEANUP -cne 'true' -or $refresh[0].Contains('continue-on-error') -or
      $refresh[0].with.Count -ne 4){throw 'OIDC refresh must immediately precede its guarded phase and fail closed.'}
    foreach($field in @('client-id','tenant-id','subscription-id','environment')){
      if($refresh[0].with[$field] -cne $initial[0].with[$field]){throw 'OIDC refresh changed the cloud or deployment identity.'}
    }
  }
}
Assert-DevAzureCliRefreshBoundaries $workflow
foreach($case in @('missing-refresh','late-refresh','wrong-client','wrong-tenant','wrong-subscription','wrong-cloud',
  'missing-guard','stale-cache','ignored-failure','secret-credential','unbounded-dev','pilot-budget','cancel-in-progress','fail-fast')){
  $candidateWorkflow=$workflow|ConvertTo-Json -Depth 100|ConvertFrom-Json -AsHashtable
  $candidateJob=$candidateWorkflow.jobs.provision
  $candidateRefresh=@($candidateJob.steps|Where-Object name -CEQ 'Refresh Azure CLI OIDC before phase two')[0]
  switch($case){
    'missing-refresh'{$candidateJob.steps=@($candidateJob.steps|Where-Object name -CNE $candidateRefresh.name)}
    'late-refresh'{
      $refreshIndex=[array]::IndexOf($candidateJob.steps,$candidateRefresh)
      $candidateJob.steps[$refreshIndex]=$candidateJob.steps[$refreshIndex+1]
      $candidateJob.steps[$refreshIndex+1]=$candidateRefresh
    }
    'wrong-client'{$candidateRefresh.with.'client-id'='different-client'}
    'wrong-tenant'{$candidateRefresh.with.'tenant-id'='different-tenant'}
    'wrong-subscription'{$candidateRefresh.with.'subscription-id'='different-subscription'}
    'wrong-cloud'{$candidateRefresh.with.environment='AzureCloud'}
    'missing-guard'{$candidateRefresh.Remove('if')}
    'stale-cache'{$candidateRefresh.env.AZURE_LOGIN_PRE_CLEANUP='false'}
    'ignored-failure'{$candidateRefresh['continue-on-error']='true'}
    'secret-credential'{$candidateRefresh.with.creds='forbidden-static-credential'}
    'unbounded-dev'{$candidateJob.'timeout-minutes'='360'}
    'pilot-budget'{$candidateJob.'timeout-minutes'='70'}
    'cancel-in-progress'{$candidateJob.concurrency.'cancel-in-progress'='true'}
    'fail-fast'{$candidateJob.strategy.'fail-fast'='true'}
  }
  $rejected=$false
  try{Assert-DevAzureCliRefreshBoundaries $candidateWorkflow}catch{$rejected=$true}
  if(-not $rejected){throw ('Workflow OIDC/time-budget mutation was accepted: '+$case)}
}
Write-Output 'PASS: fourteen workflow OIDC/time-budget mutations reject missing refreshes, identity changes and weakened lifecycle guards.'
$preview=@($workflow.jobs.provision.steps|Where-Object name -CEQ 'Preview development infrastructure only')
if($preview.Count -ne 1 -or $preview[0].env.MANAGE_BYOK_GROUPS -cne '' -or -not $preview[0]['if'].Contains('inputs.preview_only')){throw 'Preview dispatch guard changed.'}
$script=$preview[0].run
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($script,[ref]$null,[ref]$errors)
if($errors.Count){throw 'Development preview script does not parse.'}
foreach($name in @('Assert-DevCallerGroup','Get-DevCallerServiceId','Read-DevApimPreviewCollection','Get-DevPreviewSummary','Get-DevApimPreviewPaths','Get-DevCallerPreviewFingerprint','New-DevCallerCandidate','Resolve-DevCallerArtifactSource','New-DevCallerTransitionPlan','Invoke-DevCallerTransitionPlan','ConvertTo-DevRawPolicyXml','Test-DevCallerProperties','Assert-DevCallerReadback','Assert-DevCallerTieringParameters','New-DevApimPreviewParameters','Get-DevPreviewRegisterConfig','ConvertFrom-DevPreviewAuthResponse','Test-DevRecoveryTemplate','Get-DevRecoveryRegisterConfig','New-DevPreviewCandidate','Resolve-DevPreviewParameters','Invoke-DevPreviewProcess')){
  $definition=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$false))
  if($definition.Count -ne 1){throw 'Development preview helper is ambiguous.'}
  . ([scriptblock]::Create($definition[0].Extent.Text))
}
$staging=@((@($workflow.jobs.Values)+@($pilot.jobs.Values))|ForEach-Object {$_.steps}|Where-Object {$_.env -and $_.env.Contains('BYOK_CALLER_AUTH_PREPARATION')})
if($staging.Count -ne 3 -or @($staging|Where-Object {$_.env.BYOK_CALLER_JWT_TIERING -cne '${{ vars.BYOK_CALLER_JWT_TIERING }}'}).Count){throw 'All caller staging paths must explicitly bind the optional tier configuration.'}
$preflight=@($workflow.jobs.provision.steps|Where-Object id -CEQ 'preflight')
if($preflight.Count -ne 1 -or $preflight[0].env.PREVIEW_ONLY -notlike '*inputs.preview_only*' -or
  $preflight[0].run -notmatch '(?s)\$PREVIEW_ONLY.*?then\s+provision=false'){throw 'Preview preflight must disable provisioning.'}
$afterPreflight=$false
foreach($step in $workflow.jobs.provision.steps){
  if($step.id -ceq 'preflight'){$afterPreflight=$true;continue}
  if($afterPreflight -and $step.run -match '(?m)azd (?:provision|deploy)|az .*(?:delete|purge|update|create)|setup-register-easyauth' -and
    $step['if'] -notlike '*steps.preflight.outputs.provision*true*'){throw 'A development mutation is not guarded by preflight.'}
}
foreach($job in $workflow.jobs.Values|Where-Object {$_.uses -like '*smoke-test.yml*'}){
  if($job['if'] -notlike '*!inputs.preview_only*'){throw 'Preview must exclude smoke jobs.'}
}
if($workflow.on.workflow_dispatch.inputs.preview_jwt.default -cne 'false'){throw 'JWT candidate preview must be opt-in.'}
if($workflow.on.workflow_dispatch.inputs.preview_apim_only.default -cne 'false'){throw 'Focused APIM preview must be opt-in.'}
if($workflow.on.workflow_dispatch.inputs.recover_phase_two.default -cne 'false'){throw 'Recovery must be opt-in.'}
foreach($stepName in @('Purge soft-deleted tombstones (self-heal)','Deploy register app image','Easy Auth setup (app reg + secret -> Key Vault)')){
  $guarded=@($workflow.jobs.provision.steps|Where-Object name -CEQ $stepName)
  if($guarded.Count -ne 1 -or $guarded[0]['if'] -notlike '*!inputs.recover_phase_two*'){throw 'Recovery can run an excluded mutation.'}
}
$phaseOne=@($workflow.jobs.provision.steps|Where-Object {$_.name -like 'azd provision (phase 1*'})
if($phaseOne.Count -ne 1 -or $phaseOne[0]['if'] -notlike '*!inputs.recover_phase_two*'){throw 'Recovery can run phase one.'}
foreach($job in $workflow.jobs.Values|Where-Object {$_.uses -like '*smoke-test.yml*'}){
  if($job['if'] -notlike '*!inputs.recover_phase_two*' -or $job['if'] -notlike "*inputs.caller_action == 'none'*"){throw 'Recovery and caller transitions must exclude smoke.'}
}
if($workflow.on.workflow_dispatch.inputs.caller_action.default -cne 'none' -or
  ($workflow.on.workflow_dispatch.inputs.caller_action.options -join ',') -cne 'none,activate,rollback,finalize' -or
  $preflight[0].env.CALLER_ACTION -notlike '*inputs.caller_action*' -or $preflight[0].run -notlike '*$CALLER_ACTION*'){
  throw 'Caller transitions must be explicit and isolated from normal provisioning.'
}
$configStep=@($workflow.jobs.provision.steps|Where-Object id -CEQ 'cfg')
if($configStep.Count -ne 1 -or $configStep[0].run -notmatch '(?s)\$PREVIEW_JWT.*?\$PREVIEW_ONLY.*?exit 2'){throw 'Applying dispatch must reject JWT preview input before auth or provisioning.'}
if($configStep[0].env.EVENT_NAME -cne '${{ github.event_name }}' -or
  $workflow.jobs.provision.'runs-on'[1] -notlike "*matrix.env == 'gov-pilot'*"){throw 'Pilot caller dispatch must retain the event and Government runner binding.'}
$checkout=@($workflow.jobs.provision.steps|Where-Object uses -CEQ 'actions/checkout@v4')
if($checkout.Count -ne 1 -or $checkout[0].with.'fetch-depth' -cne '0' -or
  -not $script.Contains("git @('merge-base','--is-ancestor',"+'$artifactSha,$workflowSha)') -or
  -not $script.Contains("git @('diff','--quiet',"+'$artifactSha,$workflowSha'+",'--','infra','policies','azure.yaml',") -or
  -not $script.Contains("'scripts/check-provision-params.ps1','scripts/check-provision-params.sh'")){
  throw 'Original-source finalization requires complete history and unchanged deployment/staging inputs.'
}
if(-not $script.Contains('if(-not $previewOnly -or $callerAction -ceq ''finalize'')') -or
  -not $script.Contains('$summary.callerArtifactSource=$artifactSourceSha') -or
  -not $script.Contains('$summary.callerVerifierSource=$env:GITHUB_SHA')){
  throw 'Finalize previews must execute readback and report separate artifact/verifier identities.'
}
$holdGuard=@($workflow.jobs.provision.steps|Where-Object name -CEQ 'Guard caller transition hold')
if($holdGuard.Count -ne 1 -or $holdGuard[0].run -notmatch 'tags.byokCallerTransition' -or
  $holdGuard[0].run -notmatch '(?s)\[\[ -n "\$hold" \]\].*?exit 2' -or
  [array]::IndexOf($workflow.jobs.provision.steps,$holdGuard[0]) -gt [array]::IndexOf($workflow.jobs.provision.steps,$preview[0])){
  throw 'Caller transition hold must fail closed before preview or provisioning.'
}

$subscription=[guid]::NewGuid().ToString()
$groupId='/subscriptions/'+$subscription+'/resourceGroups/rg-copilot-byok-comm-dev'
$baselineTypes=@('Microsoft.ApiManagement/service','Microsoft.CognitiveServices/accounts','Microsoft.App/managedEnvironments',
  'Microsoft.App/jobs','Microsoft.App/containerApps','Microsoft.ContainerRegistry/registries','Microsoft.KeyVault/vaults',
  'Microsoft.ContainerInstance/containerGroups','Microsoft.Network/virtualNetworks')
$baselineChanges=@($baselineTypes|ForEach-Object {@{changeType='Create';resourceId=$groupId+'/providers/'+$_+'/fixture'}})
$checks=0
$rolloutSelection=@($ast.FindAll({param($node)
  $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$callerRollout' -and
    $node.Right.Extent.Text.Contains('$previewJwt')
},$false))
$registerReadback=@($ast.FindAll({param($node)
  $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses.Count -eq 1 -and
    $node.Clauses[0].Item2.Statements.Count -gt 0 -and
    $node.Clauses[0].Item2.Statements[0].Extent.Text.StartsWith('$apps=Invoke-DevPreviewProcess az',[StringComparison]::Ordinal)
},$false))
if($rolloutSelection.Count -ne 1 -or $registerReadback.Count -ne 1){throw 'Stored caller preview routing is ambiguous.'}
$selectRollout=[scriptblock]::Create($rolloutSelection[0].Extent.Text+'; $callerRollout')
$readRegister=[scriptblock]::Create($registerReadback[0].Clauses[0].Item1.Extent.Text)
foreach($storedRollout in @('legacy','shared','coexistence','unexpected')){
  foreach($case in @('preserve','applying','disabled','malformed','focused','caller-action')){
    $previewOnly=$case -cne 'applying'
    $previewJwt=$false
    $previewApimOnly=$case -ceq 'focused'
    $recoverPhaseTwo=$false
    $manualCaller=$case -ceq 'caller-action'
    $storedPreparation=if($case -ceq 'malformed'){'true'}else{$case -cne 'disabled'}
    $callerRollout=& $selectRollout
    $expectedRollout=if($storedRollout -cin @('shared','coexistence') -and $case -cin @('preserve','focused','caller-action')){$storedRollout}else{'legacy'}
    if($callerRollout -cne $expectedRollout -or (& $readRegister) -ne ($expectedRollout -cne 'legacy' -and $case -ceq 'preserve')){
      throw ('Stored caller preview routing failed: '+$storedRollout+'/'+$case)
    }
    $checks++
  }
}
foreach($case in @('single','empty','paginated','foreign-host','foreign-path','wrong-version','http','credentials','fragment','relative',
  'duplicate-entry','case-duplicate','repeated-page','too-many-pages','malformed-page','bad-next-link','missing-name')){
  $calls=[Collections.Generic.List[string]]::new()
  $serviceId=$groupId+'/providers/Microsoft.ApiManagement/service/apim-fixture'
  $collectionUrl='https://management.azure.com'+$serviceId+'/namedValues?api-version=2024-05-01'
  $reader={param($url)
    $calls.Add($url)
    if($case -ceq 'too-many-pages'){return @{value=@(@{name=('entry-'+$calls.Count)});nextLink=($collectionUrl+'&$skip='+$calls.Count)}}
    if($calls.Count -gt 1){return @{value=@(@{name=$(if($case -ceq 'duplicate-entry'){'first'}elseif($case -ceq 'case-duplicate'){'FIRST'}else{'second'})})}}
    $page=@{value=@(@{name='first'})}
    if($case -cnotin @('single','empty')){$page.nextLink=$collectionUrl+'&$skip=1'}
    switch($case){
      'empty'{$page.value=@()}
      'foreign-host'{$page.nextLink=$page.nextLink.Replace('management.azure.com','other.example.test')}
      'foreign-path'{$page.nextLink=$page.nextLink.Replace('/namedValues','/products')}
      'wrong-version'{$page.nextLink=$page.nextLink.Replace('2024-05-01','2022-01-01')}
      'http'{$page.nextLink=$page.nextLink.Replace('https:','http:')}
      'credentials'{$page.nextLink=$page.nextLink.Replace('https://','https://untrusted@')}
      'fragment'{$page.nextLink+='#unexpected'}
      'relative'{$page.nextLink='/relative'}
      'repeated-page'{$page.nextLink=$collectionUrl}
      'malformed-page'{$page.value=@{name='not-an-array'}}
      'bad-next-link'{$page.nextLink=@{unexpected=$true}}
      'missing-name'{$page.value=@(@{id='missing-name'})}
    }
    $page
  }
  $accepted=$false
  try{$inventory=Read-DevApimPreviewCollection 'https://management.azure.com' $serviceId '/namedValues' $reader;$accepted=$true}catch{}
  if($accepted -ne ($case -cin @('single','empty','paginated'))){throw ('APIM inventory pagination failed: '+$case)}
  if($accepted -and $inventory.value.Count -ne $(if($case -ceq 'empty'){0}elseif($case -ceq 'paginated'){2}else{1})){throw 'APIM inventory lost an item.'}
  if($case -cin @('foreign-host','foreign-path','wrong-version','http','credentials','fragment','relative','repeated-page','malformed-page','bad-next-link','missing-name') -and $calls.Count -ne 1){throw 'Untrusted pagination performed another read.'}
  if($case -ceq 'too-many-pages' -and $calls.Count -ne 20){throw 'APIM pagination limit changed.'}
  $checks++
}
$guardPath=Join-Path $PSScriptRoot '../check-private-client-access-hold.ps1'
$guardErrors=$null
$guardAst=[Management.Automation.Language.Parser]::ParseFile($guardPath,[ref]$null,[ref]$guardErrors)
$guardDefinition=@($guardAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-PrivateClientLifecycleState'},$false))
if($guardErrors.Count -or $guardDefinition.Count -ne 1){throw 'Caller lifecycle guard is invalid.'}
. ([scriptblock]::Create($guardDefinition[0].Extent.Text))
foreach($case in @('clear','missing','held','empty','case-insensitive','malformed','private-held','forbidden','wrong-group','unknown-404','deleting','transition-owned')){
  $status=200
  $group=@{id=$groupId;properties=@{provisioningState='Succeeded'};tags=@{}}
  $includeCaller=$true
  switch($case){
    'missing'{$status=404;$group=@{error=@{code='ResourceGroupNotFound'}}}
    'held'{$group.tags.byokCallerTransition='v1:fixture'}
    'empty'{$group.tags.byokCallerTransition=''}
    'case-insensitive'{$group.tags.BYOKCALLERTRANSITION='fixture'}
    'malformed'{$group.tags.byokCallerTransition=@{unexpected=$true}}
    'private-held'{$group.tags.byokPrivateClientAccess='fixture'}
    'forbidden'{$status=403}
    'wrong-group'{$group.id+='-other'}
    'unknown-404'{$status=404;$group=@{error=@{code='NotFound'}}}
    'deleting'{$group.properties.provisioningState='Deleting'}
    'transition-owned'{$group.tags.byokCallerTransition='fixture';$includeCaller=$false}
  }
  $accepted=$false
  try{Assert-PrivateClientLifecycleState $status $group $groupId -IncludeCallerTransition:$includeCaller;$accepted=$true}catch{}
  if($accepted -ne ($case -cin @('clear','missing','transition-owned'))){throw ('Caller lifecycle coordination failed: '+$case)}
  $checks++
}
foreach($jobName in @('validate','deploy')){
  $job=$pilot.jobs[$jobName]
  if($job.concurrency.group -cne 'dev-env-${{ matrix.cloud == ''AzureUSGovernment'' && ''gov-pilot'' || ''comm-pilot'' }}' -or
    $job.concurrency.'cancel-in-progress' -cne 'false'){throw 'Pilot jobs must share the caller-transition lifecycle lock.'}
  $guardIndex=-1
  for($stepIndex=0;$stepIndex -lt $job.steps.Count;$stepIndex++){
    $step=$job.steps[$stepIndex]
    if($step.name -ceq 'Guard private client access'){
      if($guardIndex -ge 0 -or $step.Contains('if') -or $step.Contains('continue-on-error') -or $step.run -notlike '* -IncludeCallerTransition'){
        throw 'Pilot lifecycle jobs can bypass a held caller transition.'
      }
      $guardIndex=$stepIndex
    }
    if($step.run -match '(?m)azd provision' -and $guardIndex -lt 0){throw 'Pilot azd hooks can precede the caller hold guard.'}
  }
  if($guardIndex -lt 0){throw 'Pilot lifecycle hold guard is missing.'}
  $checks++
}
$smokeGuard=@($smoke.jobs.smoke.steps|Where-Object name -CEQ 'Guard private client access')
if($smoke.concurrency.group -cne 'dev-env-${{ inputs.env }}' -or $smoke.concurrency.'cancel-in-progress' -cne 'false' -or
  $smokeGuard.Count -ne 1 -or $smokeGuard[0].Contains('if') -or $smokeGuard[0].run -notlike '* -IncludeCallerTransition'){
  throw 'Smoke must respect caller holds under the shared lifecycle lock.'
}
$ordinaryGuard=@($workflow.jobs.provision.steps|Where-Object name -CEQ 'Guard private client access')
if($ordinaryGuard.Count -ne 1 -or $ordinaryGuard[0].env.GUARD_CALLER_TRANSITION -cne '${{ (inputs.caller_action == '''' || inputs.caller_action == ''none'') && ''true'' || ''false'' }}' -or
  $ordinaryGuard[0].run -notlike '* -IncludeCallerTransition:*'){throw 'Ordinary dev jobs must check caller holds while manual transitions reconcile their own.'}
$checks++
foreach($environment in @('comm-dev','gov-dev','comm-pilot','gov-pilot')){
  foreach($case in @('complete','no-marker','wrong-group','deleting','failed')){
    $group=@{id=('/subscriptions/'+$subscription+'/resourceGroups/rg-copilot-byok-'+$environment);properties=@{provisioningState='Succeeded'};tags=@{deployDevStatus='complete'}}
    switch($case){
      'no-marker'{$group.tags.Remove('deployDevStatus')}
      'wrong-group'{$group.id+='-other'}
      'deleting'{$group.properties.provisioningState='Deleting'}
      'failed'{$group.properties.provisioningState='Failed'}
    }
    $accepted=$false
    try{Assert-DevCallerGroup $group $environment $subscription;$accepted=$true}catch{}
    if($accepted -ne ($case -ceq 'complete' -or ($case -ceq 'no-marker' -and $environment -clike '*-pilot'))){throw ('Caller baseline binding failed: '+$environment+'/'+$case)}
    $checks++
  }
}
foreach($case in @('exact','wrong-group','wrong-deployment','failed','missing-output','unsafe-output')){
  $deployment=@{id=($groupId+'/providers/Microsoft.Resources/deployments/apim');properties=@{provisioningState='Succeeded';outputs=@{apimName=@{value='apim-fixture'}}}}
  switch($case){
    'wrong-group'{$deployment.id=$deployment.id.Replace('comm-dev','gov-pilot')}
    'wrong-deployment'{$deployment.id+='-other'}
    'failed'{$deployment.properties.provisioningState='Failed'}
    'missing-output'{$deployment.properties.outputs.Remove('apimName')}
    'unsafe-output'{$deployment.properties.outputs.apimName.value='../other'}
  }
  $accepted=$false
  try{$target=Get-DevCallerServiceId $deployment $groupId;$accepted=$target -ceq ($groupId+'/providers/Microsoft.ApiManagement/service/apim-fixture')}catch{}
  if($accepted -ne ($case -ceq 'exact')){throw ('Exact deployment reference failed: '+$case)}
  $checks++
}
foreach($case in @('create','modify','ignore','delete','unsupported','deploy','no-state-unsupported','other-group','other-subscription','other-group-ignore','duplicate','empty','failed','malformed','nested-type','extension-type','lowercase-type','diagnostics','missing-resource')){
  $change=@{changeType='Create';resourceId=$groupId;after=@{type='Microsoft.Resources/resourceGroups';name='sensitive-fixture-marker'};delta=@(@{path='properties.fixture';after='sensitive-fixture-marker'})}
  switch($case){
    'modify'{$change.changeType='Modify'}
    'ignore'{$change.changeType='Ignore'}
    'delete'{$change.changeType='Delete'}
    'unsupported'{$change.changeType='Unsupported'}
    'deploy'{$change.changeType='Deploy'}
    'no-state-unsupported'{$change.changeType='Unsupported';$change.Remove('after');$change.Remove('delta')}
    'other-group'{$change.resourceId=$groupId+'-other'}
    'other-subscription'{$change.resourceId=$change.resourceId.Replace($subscription,[guid]::NewGuid().ToString())}
    'other-group-ignore'{$change.resourceId=$groupId+'-other';$change.changeType='Ignore'}
    'nested-type'{$change.resourceId=$groupId+'/providers/Microsoft.ApiManagement/service/fixture/apis/openai/operations/get-response'}
    'extension-type'{$change.resourceId=$groupId+'/providers/Microsoft.ApiManagement/service/fixture/providers/Microsoft.Authorization/roleAssignments/fixture'}
    'lowercase-type'{$change.resourceId=$groupId+'/providers/microsoft.network/networksecuritygroups/fixture'}
  }
  $inventory=@{status='Succeeded';changes=@($change)+$baselineChanges}
  if($case -in @('other-group-ignore','nested-type','extension-type','lowercase-type')){$inventory.changes+=@{changeType='Create';resourceId=$groupId}}
  if($case -eq 'empty'){$inventory.changes=@()}
  if($case -eq 'duplicate'){$inventory.changes=@($change,$change)}
  if($case -eq 'failed'){$inventory.status='Failed'}
  if($case -eq 'diagnostics'){$inventory.diagnostics=@(@{level='Warning';message='sensitive-fixture-marker'})}
  if($case -eq 'missing-resource'){$inventory.changes=@($change)}
  $payload=$inventory|ConvertTo-Json -Depth 20
  if($case -eq 'malformed'){$payload='{broken'}
  $accepted=$false
  try{
    $result=Get-DevPreviewSummary -Output $payload -Environment comm-dev -SubscriptionId $subscription
    $accepted=$result.passed
    $summary=$result|ConvertTo-Json -Depth 10 -Compress
    if($summary.Contains('sensitive-fixture-marker') -or $summary.Contains($subscription)){throw 'Raw preview fields leaked.'}
  }catch{if($_.Exception.Message -ceq 'Raw preview fields leaked.'){throw}}
  if($accepted -ne ($case -in @('create','modify','other-group-ignore','nested-type','extension-type','lowercase-type'))){throw ('ARM preview assertion failed: '+$case)}
  $checks++
}
foreach($diagnosticCase in @(
  @{code='NestedDeploymentShortCircuited';category='nested-deployment-short-circuited'},
  @{code='ResourceNotSupported';category='unsupported-resource'},
  @{code='AuthorizationFailed';category='authorization'},
  @{code='RequestDisallowedByPolicy';category='policy'},
  @{code='InvalidTemplate';category='template'},
  @{code='sensitive-fixture-marker';category='other'},
  @{code=$null;category='other'})){
  $diagnostic=@{code=$diagnosticCase.code;message='sensitive-fixture-marker';target=$groupId}
  $inventory=@{status='Succeeded';changes=@(@{changeType='NoChange';resourceId=$groupId})+$baselineChanges;diagnostics=@($diagnostic,$diagnostic)}
  $result=Get-DevPreviewSummary ($inventory|ConvertTo-Json -Depth 20) comm-dev $subscription
  $summary=$result|ConvertTo-Json -Depth 10 -Compress
  if($result.passed -or $result.diagnostics -ne 2 -or $result.diagnosticCategories.Count -ne 1 -or
    $result.diagnosticCategories[0].category -cne $diagnosticCase.category -or $result.diagnosticCategories[0].count -ne 2 -or
    $summary.Contains('sensitive-fixture-marker') -or $summary.Contains($subscription)){
    throw 'Preview diagnostics must remain blocking and expose only fixed categories and counts.'
  }
  $checks++
}
$root=Join-Path $PSScriptRoot '../..'
$template=Get-Content -LiteralPath $CompiledMainTemplatePath -Raw|ConvertFrom-Json -AsHashtable
$focused=Get-Content -LiteralPath $CompiledApimTemplatePath -Raw|ConvertFrom-Json -AsHashtable -Depth 100
$allResources=if($focused.resources -is [Collections.IDictionary]){@($focused.resources.Values)}else{@($focused.resources)}
$modules=@($allResources|Where-Object {$_.existing -ne $true})
if($modules.Count -ne 4 -or @($modules|Where-Object type -CNE 'Microsoft.Resources/deployments').Count){throw 'Unexpected focused rollout writes.'}
foreach($dependency in @(@{module='ownership';parent='authentication'},@{module='consumer';parent='ownership'},@{module='admission';parent='consumer'})){
  $parents=@($focused.resources[$dependency.module].dependsOn)
  if($parents.Count -ne 1 -or $parents[0] -cne $dependency.parent){throw 'Focused JWT admission must follow ownership and consumer policies.'}
}
$consumerParameters=$focused.resources.consumer.properties.parameters
if($focused.resources.consumer.properties.template.resources.api.properties.apiType -cne 'http'){
  throw 'Focused API create type must remain HTTP before comparing its write-only readback field.'
}
if([string]::IsNullOrWhiteSpace($focused.resources.admission.properties.template.variables.jwtProductGuardTemplate)){
  throw 'Canonical product guard must be available to the conditional rollback write.'
}
if($consumerParameters.authMode.value -cne 'subscriptionKey' -or $consumerParameters.sharedDiscoveryAuth.value -ne $true -or
  $consumerParameters.sharedInferenceAuth.value -ne $true -or $focused.resources.authentication.properties.parameters.keyEnabled.value -ne $true){throw 'Focused native admission or shared consumers changed.'}
if($focused.parameters.callerAuthRollout.defaultValue -cne 'shared' -or
  ($focused.parameters.callerAuthRollout.allowedValues -join ',') -cne 'shared,coexistence' -or
  $focused.resources.admission.properties.parameters.active.value -cne "[equals(parameters('callerAuthRollout'), 'coexistence')]"){
  throw 'Focused admission must require explicit coexistence and retain protected consumers in shared mode.'
}
foreach($module in $modules){
  $nested=$module.properties.template.resources
  $children=if($nested -is [Collections.IDictionary]){@($nested.Values)}else{@($nested)}
  if(@($children|Where-Object {$_.existing -ne $true -and $_.type -cnotlike 'Microsoft.ApiManagement/service/*'}).Count){throw 'Non-APIM write in focused rollout.'}
  foreach($parameter in $module.properties.parameters.Values){if(($parameter|ConvertTo-Json -Depth 100 -Compress) -match '(?i)\breference\('){throw 'Runtime module dependency in focused rollout.'}}
}
if($focused.parameters.responseOwnerKey.type -ine 'securestring' -or $focused.parameters.responseOwnerPreviousKey.type -ine 'securestring'){throw 'Focused ownership inputs must stay secure.'}
if($focused.parameters.callerJwtTiering.defaultValue.entra.enabled -ne $false -or $focused.parameters.callerJwtTiering.defaultValue.okta.enabled -ne $false -or
  $focused.resources.authentication.properties.parameters.jwtTiering.value -cne "[parameters('callerJwtTiering')]" -or
  ($focused.resources.authentication.properties.parameters.tierCatalog|ConvertTo-Json -Depth 10 -Compress) -notmatch "parameters\('productTiers'\)"){throw 'Focused tiering must be default off and bound to its reviewed catalog.'}
$paths=@(Get-DevApimPreviewPaths byok-jwt)
if($paths.Count -ne 49 -or @($paths|Sort-Object -Unique).Count -ne 49){throw 'Focused resource coverage changed.'}
$sharedPaths=@(Get-DevApimPreviewPaths byok-jwt $false)
if($sharedPaths.Count -ne 48 -or @($sharedPaths|Where-Object {$_ -ceq 'products/byok-jwt/apis/copilot-byok-foundry'}).Count){throw 'Shared rollback must not recreate JWT admission.'}
foreach($environment in @('comm-pilot','gov-pilot')){
  $pilotGroupId='/subscriptions/'+$subscription+'/resourceGroups/rg-copilot-byok-'+$environment
  $pilotApimId=$pilotGroupId+'/providers/Microsoft.ApiManagement/service/apim-fixture'
  foreach($case in @('scoped','full-stack','wrong-environment','missing-operation','network-change')){
    $inventory=@{status='Succeeded';changes=@($paths|ForEach-Object {@{changeType='Create';resourceId=($pilotApimId+'/'+$_);after=@{properties=@{subscriptionRequired=$true;subscriptionKeyParameterNames=@{header='api-key';query='api-key'}}}}})}
    $boundEnvironment=$environment
    $boundId=$pilotApimId
    switch($case){
      'full-stack'{$boundId=''}
      'wrong-environment'{$boundEnvironment=if($environment -ceq 'comm-pilot'){'gov-pilot'}else{'comm-pilot'}}
      'missing-operation'{$inventory.changes=$inventory.changes[0..47]}
      'network-change'{$inventory.changes+=@{changeType='Create';resourceId=($pilotGroupId+'/providers/Microsoft.Network/virtualNetworks/unapproved')}}
    }
    $accepted=$false
    try{$result=Get-DevPreviewSummary ($inventory|ConvertTo-Json -Depth 20) $boundEnvironment $subscription $boundId $paths;$accepted=$result.passed}catch{}
    if($accepted -ne ($case -ceq 'scoped')){throw ('Pilot APIM-only scope failed: '+$case)}
    $checks++
  }
  foreach($case in @('explicit','implicit','legacy','wrong-cloud')){
    $location=if($environment -ceq 'gov-pilot'){'usgovvirginia'}else{'eastus2'}
    $cloud=if($environment -ceq 'gov-pilot'){'AzureUSGovernment'}else{'AzureCloud'}
    $document=@{parameters=@{envName=@{value=$environment};namePrefix=@{value='copilot-byok'};cloudEnv=@{value=$cloud};location=@{value=$location};authMode=@{value='subscriptionKey'};
      callerAuthPreparation=@{value=@{enabled=$true;keyEnabled=$true;entraEnabled=$true;oktaTrust=@{enabled=$false}}};callerAuthRollout=@{value='coexistence'};
      responseOwnerKey=@{value=[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))};responseOwnerPreviousKey=@{value=''}}}
    $rollout='coexistence'
    $allowPilot=$true
    switch($case){
      'implicit'{$allowPilot=$false}
      'legacy'{$rollout='legacy';$document.parameters.callerAuthRollout.value='legacy'}
      'wrong-cloud'{$document.parameters.cloudEnv.value='unsupported'}
    }
    $accepted=$false
    try{$null=Resolve-DevPreviewParameters $document $template $environment $location $rollout -AllowPilotCaller:$allowPilot;$accepted=$true}catch{}
    if($accepted -ne ($case -ceq 'explicit')){throw ('Pilot caller parameter scope failed: '+$case)}
    $checks++
  }
}
$fingerprintSource='a'*40
$fingerprintParameters=@{parameters=@{responseOwnerKey=@{value='synthetic-owner-marker'};callerAuthRollout=@{value='coexistence'};
  callerJwtTiering=@{value=@{entra=@{enabled=$true;mappings=@(@{claimValue='Byok.Standard';tier='byok-standard'})};okta=@{enabled=$false;claimName='byok_tier';mappings=@()}}};
  productTiers=@{value=@(@{name='byok-standard';callsPerMinute=60;tokensPerMinute=100000;monthlyCallQuota=50000})}}}
$fingerprintTarget=$groupId+'/providers/Microsoft.ApiManagement/service/fixture'
$fingerprintContract=@{apiAudience='fixture-audience';requiredScope='cli.invoke';jwtDefaultCallsPerMinute=120}
$fingerprint=Get-DevCallerPreviewFingerprint $focused $fingerprintParameters comm-dev $fingerprintSource $fingerprintTarget $fingerprintContract
foreach($case in @('same','property-order','key','mode','source','environment','template','target','audience','scope','budget','tier-role','tier-target','tier-enabled','tier-ceiling')){
  $bound=$fingerprintParameters|ConvertTo-Json -Depth 100|ConvertFrom-Json -AsHashtable
  $candidateTemplate=$focused|ConvertTo-Json -Depth 100|ConvertFrom-Json -AsHashtable
  $contract=$fingerprintContract|ConvertTo-Json|ConvertFrom-Json -AsHashtable
  $target=$fingerprintTarget
  $source=$fingerprintSource;$environment='comm-dev'
  switch($case){
    'property-order'{$reordered=[ordered]@{};foreach($name in @($bound.parameters.Keys|Sort-Object -Descending)){$reordered[$name]=$bound.parameters[$name]};$bound.parameters=$reordered}
    'key'{$bound.parameters.responseOwnerKey.value='another-synthetic-marker'}
    'mode'{$bound.parameters.callerAuthRollout.value='shared'}
    'source'{$source='b'*40}
    'environment'{$environment='gov-dev'}
    'template'{$candidateTemplate.contentVersion='2.0.0.0'}
    'target'{$target=$target.Replace($subscription,[guid]::NewGuid().ToString())}
    'audience'{$contract.apiAudience='other-audience'}
    'scope'{$contract.requiredScope='other.invoke'}
    'budget'{$contract.jwtDefaultCallsPerMinute=240}
    'tier-role'{$bound.parameters.callerJwtTiering.value.entra.mappings[0].claimValue='Byok.Other'}
    'tier-target'{$bound.parameters.callerJwtTiering.value.entra.mappings[0].tier='byok-power'}
    'tier-enabled'{$bound.parameters.callerJwtTiering.value.entra.enabled=$false}
    'tier-ceiling'{$bound.parameters.productTiers.value[0].monthlyCallQuota=60000}
  }
  $actual=Get-DevCallerPreviewFingerprint $candidateTemplate $bound $environment $source $target $contract
  if($actual -cnotmatch '\A[0-9a-f]{64}\z' -or ($actual -ceq $fingerprint) -ne ($case -cin @('same','property-order'))){throw ('Caller receipt binding failed: '+$case)}
  $checks++
}
foreach($case in @('same-source','verified-ancestor','changed-inputs','unrelated-source','missing-hold','malformed-hold','missing-proof','activate','rollback')){
  $action='finalize';$workflowSha='b'*40;$heldSha='a'*40;$hold='v1:'+$heldSha+':coexistence:'+$fingerprint
  $proof={param($artifact,$workflow) $artifact -ceq $heldSha -and $workflow -ceq $workflowSha -and $case -cnotin @('changed-inputs','unrelated-source')}
  switch($case){
    'same-source'{$workflowSha=$heldSha}
    'missing-hold'{$hold=''}
    'malformed-hold'{$hold='v1:invalid:coexistence:'+ $fingerprint}
    'missing-proof'{$proof=$null}
    'activate'{$action='activate'}
    'rollback'{$action='rollback'}
  }
  $accepted=$false
  try{$artifact=Resolve-DevCallerArtifactSource $action $workflowSha $hold $proof;$accepted=$true}catch{}
  if($accepted -ne ($case -cin @('same-source','verified-ancestor','activate','rollback'))){throw ('Original caller source gate failed: '+$case)}
  if($accepted -and $artifact -cne $(if($action -ceq 'finalize'){$heldSha}else{$workflowSha})){throw 'Caller action used the wrong source binding.'}
  $checks++
}
$sourceCommand=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Resolve-DevCallerArtifactSource'},$true))
if($sourceCommand.Count -ne 1 -or $sourceCommand[0].CommandElements[-1] -isnot [Management.Automation.Language.ScriptBlockExpressionAst]){
  throw 'Caller source proof must be connected to the runtime resolver.'
}
$sourceProof=$sourceCommand[0].CommandElements[-1].ScriptBlock.GetScriptBlock()
foreach($case in @('unchanged-inputs','unrelated-source','changed-inputs')){
  & {
    $commands=[Collections.Generic.List[object]]::new()
    function Invoke-DevPreviewProcess {
      param([string]$FileName,[string[]]$Arguments)
      $commands.Add(@{file=$FileName;arguments=$Arguments})
      if(($case -ceq 'unrelated-source' -and $Arguments[0] -ceq 'merge-base') -or
        ($case -ceq 'changed-inputs' -and $Arguments[0] -ceq 'diff')){throw 'fixture-source-proof-failure'}
    }
    $actual=& $sourceProof ('a'*40) ('b'*40)
    if($actual -isnot [bool] -or $actual -ne ($case -ceq 'unchanged-inputs')){throw 'Runtime caller source proof accepted changed or unrelated inputs.'}
    $expectedCount=if($case -ceq 'unrelated-source'){1}else{2}
    if($commands.Count -ne $expectedCount -or @($commands|Where-Object file -CNE 'git').Count -or
      ($commands[0].arguments -join ',') -cne ('merge-base,--is-ancestor,'+('a'*40)+','+('b'*40))){throw 'Runtime caller ancestry check changed.'}
    if($commands.Count -eq 2 -and ($commands[1].arguments -join ',') -cne
      ('diff,--quiet,'+('a'*40)+','+('b'*40)+',--,infra,policies,azure.yaml,scripts/check-provision-params.ps1,scripts/check-provision-params.sh')){
      throw 'Runtime caller source proof omitted a deployment input.'
    }
  }
  $checks++
}
foreach($case in @('preview','activate','rollback','finalize','finalize-preview','wrong-receipt','branch','automatic','rerun','unknown-hold','other-hold','missing-hold','wrong-mode')){
  $action='activate';$mode='coexistence';$previewOnly=$false;$reviewed=$fingerprint;$sourceRef='refs/heads/main';$githubEvent='workflow_dispatch';$attempt=1;$hold=''
  switch($case){
    'preview'{$previewOnly=$true;$reviewed='';$sourceRef='refs/heads/fixture'}
    'rollback'{$action='rollback';$mode='shared'}
    'finalize'{$action='finalize';$hold='v1:'+$fingerprintSource+':coexistence:'+$fingerprint}
    'finalize-preview'{$action='finalize';$previewOnly=$true;$hold='v1:'+$fingerprintSource+':coexistence:'+$fingerprint}
    'wrong-receipt'{$reviewed='0'*64}
    'branch'{$sourceRef='refs/heads/fixture'}
    'automatic'{$githubEvent='schedule'}
    'rerun'{$attempt=2}
    'unknown-hold'{$hold='unknown'}
    'other-hold'{$hold='v1:'+('b'*40)+':coexistence:'+$fingerprint}
    'missing-hold'{$action='finalize'}
    'wrong-mode'{$mode='shared'}
  }
  $accepted=$false
  try{$plan=New-DevCallerTransitionPlan $action $mode $previewOnly $fingerprint $reviewed $fingerprintSource $sourceRef $githubEvent $attempt $hold;$accepted=$true}catch{}
  if($accepted -ne ($case -cin @('preview','activate','rollback','finalize','finalize-preview'))){throw ('Caller transition authorization failed: '+$case)}
  if($accepted){
    $trace=[Collections.Generic.List[string]]::new()
    Invoke-DevCallerTransitionPlan $plan {param($step) $trace.Add($step)}
    $expected=switch($case){
      'preview' {''}
      'activate' {'set-hold,apply-coexistence,verify-coexistence'}
      'rollback' {'set-hold,close-jwt-guard,detach-jwt-link,verify-link-absent,apply-shared,verify-shared'}
      'finalize' {'verify-persisted-settings,verify-coexistence,clear-hold'}
      'finalize-preview' {'verify-coexistence'}
    }
    if(($trace -join ',') -cne $expected){throw 'Caller transition order changed.'}
    if($case -ceq 'rollback'){
      $trace.Clear();$stopped=$false
      try{Invoke-DevCallerTransitionPlan $plan {param($step) $trace.Add($step);if($step -ceq 'detach-jwt-link'){throw 'fixture-failure'}}}catch{$stopped=$true}
      if(-not $stopped -or ($trace -join ',') -cne 'set-hold,close-jwt-guard,detach-jwt-link'){throw 'Caller transition continued after a failed detach.'}
    }
  }
  $checks++
}
foreach($step in @('clear-hold','set-hold','apply-coexistence','detach-jwt-link')){
  $plan=@{action='finalize';rollout='coexistence';previewOnly=$true;steps=@($step)}
  $trace=[Collections.Generic.List[string]]::new();$rejected=$false
  try{Invoke-DevCallerTransitionPlan $plan {param($operation) $trace.Add($operation)}}catch{$rejected=$true}
  if(-not $rejected -or $trace.Count){throw 'A finalize preview attempted a mutation.'}
  $checks++
}
foreach($case in @('same','extra-runtime-field','policy-format','policy-change','key-admission','array-order','case-change','type-change','missing-field')){
  $expected=@{subscriptionRequired=$true;protocols=@('https','fixture');value='<policies><inbound /><backend /><outbound /><on-error /></policies>';format='rawxml';counter=1}
  $actual=$expected|ConvertTo-Json -Depth 10|ConvertFrom-Json -AsHashtable
  switch($case){
    'extra-runtime-field'{$actual.runtime='ignored'}
    'policy-format'{$actual.format='xml';$actual.value="<policies>`n  <inbound />`n<backend /><outbound /><on-error /></policies>"}
    'policy-change'{$actual.value='<policies><inbound><base /></inbound></policies>'}
    'key-admission'{$actual.subscriptionRequired=$false}
    'array-order'{$actual.protocols=@('fixture','https')}
    'case-change'{$actual.protocols[0]='HTTPS'}
    'type-change'{$actual.counter='1'}
    'missing-field'{$actual.Remove('subscriptionRequired')}
  }
  if((Test-DevCallerProperties $expected $actual) -ne ($case -cin @('same','extra-runtime-field','policy-format'))){throw ('Caller readback comparison failed: '+$case)}
  $checks++
}
foreach($case in @('same','layout','expression-spacing','text-expression-spacing','block-spacing','xml-comment-example','unterminated-comment','string-space-change','verbatim-string-change','operator-change','identifier-change','entity-string-change','policy-change','expression-removed','text-expression-change','dotted-expression-change','closing-tag-change','malformed','directive')){
  $source='<policies><inbound><set-variable name="operation" value="@(context.Operation.Id)" /><set-variable name="guard" value="@(context.Variables["value"] != null && new [] { "@(", ")" }.Length > 0)" /><set-header name="fixture" exists-action="override"><value>@((string)context.Variables["value"])</value></set-header><set-body>@{ var text = @"value } with ""quote"""; return "a  b &amp; c" + text; }</set-body></inbound><backend /><outbound /><on-error /></policies>'
  $actual=$source
  switch($case){
    'layout'{$actual=$actual.Replace('><',">`n  <")}
    'expression-spacing'{$actual=$actual.Replace(' != null && ','  !=  null  &&  ')}
    'text-expression-spacing'{$actual=$actual.Replace('@((string)context.Variables["value"])','@( (string) context.Variables[ "value" ] )')}
    'block-spacing'{$actual=$actual.Replace('@{ var text',"@{`n    var text").Replace('; return ',";`n  return ")}
    'xml-comment-example'{$source=$source.Replace('<inbound>','<!-- Literal @() and @{ are documentation only. --><inbound>');$actual=$source}
    'unterminated-comment'{$source=$source.Replace('<inbound>','<!-- Literal @() and @{ <inbound>');$actual=$source}
    'string-space-change'{$actual=$actual.Replace('a  b','a b')}
    'verbatim-string-change'{$actual=$actual.Replace('value } with','value }  with')}
    'operator-change'{$actual=$actual.Replace(' != null && ',' == null || ')}
    'identifier-change'{$actual=$actual.Replace('Variables','Parameters')}
    'entity-string-change'{$actual=$actual.Replace('&amp;','&')}
    'policy-change'{$actual=$actual.Replace('name="guard"','name="other"')}
    'expression-removed'{$actual=$actual.Replace('@{ var text = @"value } with ""quote"""; return "a  b &amp; c" + text; }','literal')}
    'text-expression-change'{$actual=$actual.Replace('@((string)context.Variables["value"])','@((string)context.Variables["other"])')}
    'dotted-expression-change'{$actual=$actual.Replace('context.Operation.Id','context.Operation.Name')}
    'closing-tag-change'{$actual=$actual.Replace('</value>','</other>')}
    'malformed'{$source=$source.Replace('</policies>','');$actual=$source}
    'directive'{$source=$source.Replace('@{ var text',"@{`n#if true`nvar text").Replace('; }</set-body>',";`n#endif`n}</set-body>");$actual=$source}
  }
  if((Test-DevCallerProperties @{format='rawxml';value=$source} @{format='rawxml';value=$actual}) -ne
    ($case -cin @('same','layout','expression-spacing','text-expression-spacing','block-spacing','xml-comment-example'))){throw ('Raw policy expression comparison failed: '+$case)}
  $checks++
}
$apimId=$groupId+'/providers/Microsoft.ApiManagement/service/fixture'
foreach($case in @('valid','wrong-key','public-key','vault-key','missing-resource','wrong-resource','policy-change')){
  $keyPath='namedValues/caller-response-owner-key'
  $policyPath='apis/copilot-byok-foundry/policies/policy'
  $properties=@{displayName='caller-response-owner-key';secret=$true;value='arm-masked-value'}
  $policy=@{format='rawxml';value='<policies><inbound /><backend /><outbound /><on-error /></policies>'}
  $preview=@{changes=@(@{resourceId=$apimId+'/'+$keyPath;changeType='Modify';after=@{properties=$properties}},@{resourceId=$apimId+'/'+$policyPath;changeType='NoChange';before=@{properties=$policy}})}
  $read={
    param($path,$method)
    if($path.EndsWith('/listValue')){return @{value=$(if($case -ceq 'wrong-key'){'other-synthetic-key'}else{'synthetic-owner-marker'})}}
    if($path -ceq ('/'+$keyPath)){
      $resource=@{id=$apimId+$path;properties=@{displayName='caller-response-owner-key';secret=$case -cne 'public-key'}}
      if($case -ceq 'vault-key'){$resource.properties.keyVault=@{secretIdentifier='https://vault.example.test/secrets/fixture'}}
      if($case -ceq 'wrong-resource'){$resource.id+='-other'}
      return $resource
    }
    $actualPolicy=$policy|ConvertTo-Json|ConvertFrom-Json -AsHashtable
    if($case -ceq 'policy-change'){$actualPolicy.value='<policies><inbound><base /></inbound></policies>'}
    @{id=$apimId+$path;properties=$actualPolicy}
  }
  if($case -ceq 'missing-resource'){$preview.changes=@($preview.changes[0])}
  $accepted=$false
  try{Assert-DevCallerReadback $preview $apimId @($keyPath,$policyPath) $fingerprintParameters $read;$accepted=$true}catch{}
  if($accepted -ne ($case -ceq 'valid')){throw ('Caller live readback gate failed: '+$case)}
  $checks++
}
foreach($case in @('fragment-default','fragment-null-format','fragment-link-format','fragment-value-change','api-type-alias','api-type-change','api-type-write-only','api-type-redacted','api-type-redacted-conflict','api-other-masked-property','api-type-null','api-type-conflict','api-runtime-type-missing','api-create-type-change','api-admission-change','unrelated-format','unrelated-type')){
  $path='policyFragments/byok-authenticate'
  $expected=@{format='xml';value='<fragment><return-response /></fragment>'}
  $actual=@{value=$expected.value}
  switch($case){
    'fragment-null-format'{$actual.format=$null}
    'fragment-link-format'{$actual.format='xml-link'}
    'fragment-value-change'{$actual.value='<fragment><base /></fragment>'}
    {$_ -clike 'api-*'} {
      $path='apis/copilot-byok-foundry';$expected=@{apiType='http';subscriptionRequired=$true};$actual=@{type='http';subscriptionRequired=$true}
      if($case -ceq 'api-type-change'){$actual.type='websocket'}
      if($case -ceq 'api-type-write-only'){[void]$actual.Remove('type')}
      if($case -clike 'api-type-redacted*'){$expected.apiType='*******';[void]$actual.Remove('type')}
      if($case -ceq 'api-type-redacted-conflict'){$actual.type='soap'}
      if($case -ceq 'api-other-masked-property'){$expected.serviceUrl='*******';$actual.serviceUrl='https://backend.example.test'}
      if($case -ceq 'api-type-null'){$actual.type=$null}
      if($case -ceq 'api-type-conflict'){$actual.apiType='http';$actual.type='websocket'}
      if($case -ceq 'api-runtime-type-missing'){$expected.type='http';[void]$actual.Remove('type')}
      if($case -ceq 'api-create-type-change'){$expected.apiType='soap'}
      if($case -ceq 'api-admission-change'){$actual.subscriptionRequired=$false}
    }
    'unrelated-format'{$path='namedValues/fixture'}
    'unrelated-type'{$path='namedValues/fixture';$expected=@{apiType='http'};$actual=@{type='http'}}
  }
  $preview=@{changes=@(@{resourceId=$apimId+'/'+$path;changeType='Modify';after=@{properties=$expected}})}
  $original=$actual|ConvertTo-Json -Depth 10 -Compress
  $accepted=$false
  try{
    Assert-DevCallerReadback $preview $apimId @($path) $fingerprintParameters {
      param($resourcePath,$method)
      if($method -cne 'GET'){throw 'Unexpected resource normalization read.'}
      @{id=$apimId+$resourcePath;properties=$actual}
    }
    $accepted=$true
  }catch{}
  if($accepted -ne ($case -cin @('fragment-default','api-type-alias','api-type-write-only','api-type-redacted'))){throw ('APIM GET contract normalization failed: '+$case)}
  if(($actual|ConvertTo-Json -Depth 10 -Compress) -cne $original){throw 'APIM readback normalization mutated its input.'}
  $checks++
}
foreach($format in @('xml','rawxml')){
  $path='apis/copilot-byok-foundry/operations/responses-get/policies/policy'
  $properties=@{format=$format;value='<policies><inbound /><backend /><outbound /><on-error /></policies>'}
  $preview=@{changes=@(@{resourceId=$apimId+'/'+$path;changeType='Modify';after=@{properties=$properties}})}
  Assert-DevCallerReadback $preview $apimId @($path) $fingerprintParameters {
    param($resourcePath,$method,$requestedFormat)
    if($method -cne 'GET' -or $requestedFormat -cne $format){throw 'Policy readback must request its submitted content format.'}
    @{id=$apimId+$resourcePath;properties=$properties}
  }
  $checks++
}
foreach($status in @(204,404,200)){
  $linkPath='products/byok-jwt/apis/copilot-byok-foundry'
  $preview=@{changes=@(@{resourceId=$apimId+'/'+$linkPath;changeType='Create'})}
  $accepted=$false
  try{
    Assert-DevCallerReadback $preview $apimId @($linkPath) $fingerprintParameters {
      param($path,$method)
      if($path -cne ('/'+$linkPath) -or $method -cne 'HEAD'){throw 'Association must use the bodyless HEAD contract.'}
      @{status=$status}
    }
    $accepted=$true
  }catch{}
  if($accepted -ne ($status -eq 204)){throw 'Caller association existence contract failed.'}
  $checks++
}
$sharedChanges=@($sharedPaths|ForEach-Object {@{resourceId=$apimId+'/'+$_;changeType='NoChange';after=@{properties=@{subscriptionRequired=$true;subscriptionKeyParameterNames=@{header='api-key';query='api-key'}}}}})
$sharedPreview=@{status='Succeeded';changes=$sharedChanges+@{resourceId=$apimId+'/products/byok-jwt/apis/copilot-byok-foundry';changeType='Ignore'}}
$sharedSummary=Get-DevPreviewSummary ($sharedPreview|ConvertTo-Json -Depth 20) comm-dev $subscription $apimId $sharedPaths $true
if(-not $sharedSummary.passed){throw 'Protected shared preview must cover all 48 resources and treat detach as a separate operation.'}
$checks++
foreach($case in @('complete','missing','ignored','unrelated-ignore','network-write','backend-write','native-product-write','delete','diagnostics','native-disabled')){
  $changes=@($paths|ForEach-Object {@{resourceId=$apimId+'/'+$_;changeType='Modify';after=@{properties=@{subscriptionRequired=$true;subscriptionKeyParameterNames=@{header='api-key';query='api-key'}}}}})
  $preview=@{status='Succeeded';changes=$changes}
  switch($case){
    'missing'{$preview.changes=$changes[1..($changes.Count-1)]}
    'ignored'{$changes[0].changeType='Ignore'}
    'unrelated-ignore'{$preview.changes+=@{resourceId=$groupId+'/providers/Microsoft.Network/virtualNetworks/fixture';changeType='Ignore'}}
    'network-write'{$preview.changes+=@{resourceId=$groupId+'/providers/Microsoft.Network/virtualNetworks/fixture';changeType='Modify'}}
    'backend-write'{$preview.changes+=@{resourceId=$apimId+'/backends/foundry';changeType='Modify'}}
    'native-product-write'{$preview.changes+=@{resourceId=$apimId+'/products/byok-standard';changeType='Modify'}}
    'delete'{$changes[0].changeType='Delete'}
    'diagnostics'{$preview.diagnostics=@(@{code='NestedDeploymentShortCircuited'})}
    'native-disabled'{($changes|Where-Object resourceId -CEQ ($apimId+'/apis/copilot-byok-foundry')).after.properties.subscriptionRequired=$false}
  }
  $accepted=$false
  try{$result=Get-DevPreviewSummary ($preview|ConvertTo-Json -Depth 20) comm-dev $subscription $apimId $paths;$accepted=$result.passed}catch{}
  if($accepted -ne ($case -cin @('complete','unrelated-ignore'))){throw ('Focused resource boundary failed: '+$case)}
  $checks++
}
foreach($profile in @(@{environment='comm-dev';path='infra/main.parameters.ci.commercial-dev.json';location='eastus2'},@{environment='gov-dev';path='infra/main.parameters.ci.gov-dev.json';location='usgovvirginia'})){
  $document=Get-Content -Raw -LiteralPath (Join-Path $root $profile.path)|ConvertFrom-Json -AsHashtable
  $resolved=Resolve-DevPreviewParameters $document $template $profile.environment $profile.location
  if($resolved.parameters.envName.value -cne $profile.environment){throw 'Baseline parameter resolution failed.'}
  foreach($case in @('shared','preparation','owner-key','location','mixed-substitution','unknown-param','tier-entra','tier-okta','tier-malformed')){
    $modified=$document|ConvertTo-Json -Depth 100|ConvertFrom-Json -AsHashtable
    switch($case){
      'shared'{$modified.parameters.callerAuthRollout=@{value='coexistence'}}
      'preparation'{$modified.parameters.callerAuthPreparation=@{value=@{enabled=$true}}}
      'owner-key'{$modified.parameters.responseOwnerKey=@{value='fixture'}}
      'location'{$modified.parameters.location=@{value='elsewhere'}}
      'mixed-substitution'{$modified.parameters.apiAudience=@{value='prefix-${API_AUDIENCE}'}}
      'unknown-param'{$modified.parameters.unknownFixture=@{value='fixture'}}
      'tier-entra'{$modified.parameters.callerJwtTiering=@{value=@{entra=@{enabled=$true};okta=@{enabled=$false}}}}
      'tier-okta'{$modified.parameters.callerJwtTiering=@{value=@{entra=@{enabled=$false};okta=@{enabled=$true}}}}
      'tier-malformed'{$modified.parameters.callerJwtTiering=@{value=@{entra=@{enabled='false'};okta=@{enabled=$false}}}}
    }
    $rejected=$false
    try{$null=Resolve-DevPreviewParameters $modified $template $profile.environment $profile.location}catch{$rejected=$true}
    if(-not $rejected){throw ('Unsafe baseline parameters accepted: '+$case)}
    $checks++
  }
  $checks++
}
foreach($case in @('list','absent','absent-root','forbidden','unauthorized','other-missing','server-error','malformed','wrong-status','null-list')){
  $status=200
  $payload=@{value=@()}
  switch($case){
    'absent'{$status=404;$payload=@{error=@{code='AuthConfigNotFound'}}}
    'absent-root'{$status=404;$payload=@{code='AuthConfigNotFound'}}
    'forbidden'{$status=403;$payload=@{error=@{code='AuthorizationFailed'}}}
    'unauthorized'{$status=401;$payload=@{error=@{code='AuthConfigNotFound'}}}
    'other-missing'{$status=404;$payload=@{error=@{code='ResourceNotFound'}}}
    'server-error'{$status=503;$payload=@{error=@{code='ServiceUnavailable'}}}
    'wrong-status'{$payload=@{error=@{code='AuthConfigNotFound'}}}
    'null-list'{$payload.value=$null}
  }
  $output=if($case -ceq 'malformed'){'{broken'}else{$payload|ConvertTo-Json -Depth 5 -Compress}
  $accepted=$false
  try{$config=ConvertFrom-DevPreviewAuthResponse $status $output;$accepted=$true}catch{}
  if($accepted -ne ($case -cin @('list','absent','absent-root'))){throw ('Register HTTP contract failed: '+$case)}
  if($accepted -and ($config.value -isnot [array] -or $config.value.Count -ne 0)){throw 'Absent auth response was not normalized to an empty list.'}
  $checks++
}
foreach($case in @('inactive','active','missing-auth','unexpected-auth','client-mismatch','missing-secret-uri','image-mismatch','failed-deployment','malformed-auth-list','multiple-auth','disabled-auth','inline-secret')){
  $clientId=[guid]::NewGuid().ToString()
  $app=@{tags=@{'azd-service-name'='register'};properties=@{provisioningState='Succeeded';template=@{containers=@(@{image='registry.example.test/register:fixture'})}}}
  $parameters=@{easyAuthClientId=@{value=$clientId};easyAuthSecretKeyVaultUri=@{value='https://vault.example.test/secrets/register-easyauth-secret'};registerImage=@{value='registry.example.test/register:fixture'}}
  $deployment=@{properties=@{provisioningState='Succeeded';parameters=$parameters}}
  $auth=@{value=@(@{name='current';properties=@{platform=@{enabled=$true};identityProviders=@{azureActiveDirectory=@{enabled=$true;registration=@{clientId=$clientId;clientSecretSettingName='easyauth-client-secret'}}}}})}
  switch($case){
    'inactive'{$parameters.easyAuthClientId.value='';$parameters.easyAuthSecretKeyVaultUri.value='';$auth.value=@()}
    'missing-auth'{$auth.value=@()}
    'unexpected-auth'{$parameters.easyAuthClientId.value='';$parameters.easyAuthSecretKeyVaultUri.value=''}
    'client-mismatch'{$auth.value[0].properties.identityProviders.azureActiveDirectory.registration.clientId=[guid]::NewGuid().ToString()}
    'missing-secret-uri'{$parameters.easyAuthSecretKeyVaultUri.value=''}
    'image-mismatch'{$parameters.registerImage.value='registry.example.test/register:older'}
    'failed-deployment'{$deployment.properties.provisioningState='Failed'}
    'malformed-auth-list'{$auth.value=$null}
    'multiple-auth'{$auth.value+=@{name='unexpected'}}
    'disabled-auth'{$auth.value[0].properties.platform.enabled=$false}
    'inline-secret'{$parameters.easyAuthSecretKeyVaultUri.value='not-a-key-vault-reference'}
  }
  $accepted=$false
  try{$config=Get-DevPreviewRegisterConfig $app $auth $deployment;$accepted=$true}catch{}
  if($accepted -ne ($case -cin @('inactive','active'))){throw ('Register state preservation failed: '+$case)}
  if($accepted -and ($config.image -cne $parameters.registerImage.value -or $config.clientId -cne $parameters.easyAuthClientId.value -or $config.secretUri -cne $parameters.easyAuthSecretKeyVaultUri.value)){throw 'Register preview altered existing configuration.'}
  $checks++
}
$saved=@{}
foreach($case in @('same','export-normalization','policy-change','default-change','resource-change','application-metadata','array-order')){
  $source=@{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#';contentVersion='1.0.0.0';metadata=@{_generator=@{version='fixture'}};
    parameters=@{mode=@{type='string';defaultValue='legacy';metadata=@{description='fixture'}}};resources=@{fixture=@{type='Microsoft.ApiManagement/service/apis/policies';name='fixture';properties=@{value="<policies>`n<inbound />`n</policies>";metadata=@{owner='fixture'};items=@('first','second')}}}}
  $copy=$source|ConvertTo-Json -Depth 100|ConvertFrom-Json -AsHashtable
  switch($case){
    'export-normalization'{$copy.Remove('metadata');$copy.parameters.mode.type='String';$copy.parameters.mode.metadata.description='changed description';$copy.resources.fixture.properties.value=$copy.resources.fixture.properties.value.Replace("`n","`r`n")}
    'policy-change'{$copy.resources.fixture.properties.value='<policies><inbound><base /></inbound></policies>'}
    'default-change'{$copy.parameters.mode.defaultValue='coexistence'}
    'resource-change'{$copy.resources.fixture.name='other'}
    'application-metadata'{$copy.resources.fixture.properties.metadata.owner='other'}
    'array-order'{$copy.resources.fixture.properties.items=@('second','first')}
  }
  if((Test-DevRecoveryTemplate $copy $source) -ne ($case -cin @('same','export-normalization'))){throw ('Recovery template comparison failed: '+$case)}
  $checks++
}
foreach($case in @('valid','old','future','wrong-template','wrong-environment','succeeded-parent','multiple-failures','wrong-child','auth-drift','image-drift')){
  $app=@{id=$groupId+'/providers/Microsoft.App/containerApps/fixture';tags=@{'azd-service-name'='register'};properties=@{provisioningState='Succeeded';template=@{containers=@(@{image='registry.example.test/register:current'})}}}
  $auth=@{value=@()}
  $nested=@{properties=@{provisioningState='Succeeded';parameters=@{registerImage=@{value='registry.example.test/register:placeholder'};easyAuthClientId=@{value=''};easyAuthSecretKeyVaultUri=@{value=''}}}}
  $settings=@{envName=@{value='comm-dev'};namePrefix=@{value='copilot-byok'};cloudEnv=@{value='AzureCloud'};callerAuthRollout=@{value='legacy'};
    callerAuthPreparation=@{value=@{enabled=$false}};registerAppImage=@{value='registry.example.test/register:current'};registerEasyAuthClientId=@{value=''};registerEasyAuthSecretKeyVaultUri=@{value=''}}
  $parent=@{properties=@{provisioningState='Failed';timestamp=[DateTimeOffset]::UtcNow.AddMinutes(-5);parameters=$settings}}
  $operations=@(@{properties=@{provisioningState='Failed';provisioningOperation='Create';targetResource=@{id=$groupId+'/providers/Microsoft.Resources/deployments/apim'}}})
  switch($case){
    'old'{$parent.properties.timestamp=[DateTimeOffset]::UtcNow.AddHours(-25)}
    'future'{$parent.properties.timestamp=[DateTimeOffset]::UtcNow.AddHours(1)}
    'wrong-environment'{$settings.envName.value='gov-dev'}
    'succeeded-parent'{$parent.properties.provisioningState='Succeeded'}
    'multiple-failures'{$operations+=$operations[0]}
    'wrong-child'{$operations[0].properties.targetResource.id=$groupId+'/providers/Microsoft.Resources/deployments/network'}
    'auth-drift'{$settings.registerEasyAuthClientId.value=[guid]::NewGuid().ToString()}
    'image-drift'{$settings.registerAppImage.value='registry.example.test/register:other'}
  }
  $accepted=$false
  try{$preserved=Get-DevRecoveryRegisterConfig $app $auth $nested $parent $operations $groupId ($case -cne 'wrong-template');$accepted=$true}catch{}
  if($accepted -ne ($case -ceq 'valid')){throw ('Recovery parent guard failed: '+$case)}
  if($accepted -and ($preserved.image -cne $settings.registerAppImage.value -or $preserved.clientId -cne '' -or $preserved.secretUri -cne '')){throw 'Recovery did not preserve parent image and auth.'}
  if($nested.properties.parameters.registerImage.value -cne 'registry.example.test/register:placeholder'){throw 'Recovery modified the original deployment metadata.'}
  $checks++
}
foreach($name in @('BYOK_RESPONSE_OWNER_KEY','BYOK_RESPONSE_OWNER_PREVIOUS_KEY')){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
try{
  $env:BYOK_RESPONSE_OWNER_KEY=[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
  $env:BYOK_RESPONSE_OWNER_PREVIOUS_KEY='__none__'
  $source=Get-Content -Raw -LiteralPath (Join-Path $root 'infra/main.parameters.ci.commercial-dev.json')|ConvertFrom-Json -AsHashtable
  $source.parameters.callerAuthPreparation=@{value=@{enabled=$false;keyEnabled=$true;entraEnabled=$true;entraClientIds=@();oktaTrust=@{enabled=$false;issuer='';openIdConfigUrl='';audience='';requiredScope='';clientIds=@()};jwtProductId='byok-jwt'}}
  $source.parameters.callerAuthRollout=@{value='legacy'}
  foreach($mode in @('shared','coexistence')){
    foreach($initial in @('legacy','shared','coexistence')){
      $inputDocument=$source|ConvertTo-Json -Depth 100|ConvertFrom-Json -AsHashtable
      $inputDocument.parameters.callerAuthRollout.value=$initial
      $inputDocument.parameters.callerAuthPreparation.value.enabled=$initial -cne 'legacy'
      $candidate=New-DevCallerCandidate $inputDocument $mode '__none__'
      $resolved=Resolve-DevPreviewParameters $candidate $template comm-dev eastus2 $mode
      if($resolved.parameters.callerAuthRollout.value -cne $mode -or $inputDocument.parameters.callerAuthRollout.value -cne $initial -or
        ($candidate|ConvertTo-Json -Depth 100 -Compress).Contains($env:BYOK_RESPONSE_OWNER_KEY)){throw 'Caller transition candidate changed its source or exposed a key.'}
      $checks++
    }
    foreach($tierCase in @('disabled','entra','okta','malformed','missing-flag','unknown-tier','missing-catalog','zero-limit')){
      $inputDocument=$source|ConvertTo-Json -Depth 100|ConvertFrom-Json -AsHashtable
      $inputDocument.parameters.entraTenantId=@{value=[guid]::NewGuid().ToString()}
      $inputDocument.parameters.apiAudience=@{value=[guid]::NewGuid().ToString()}
      $tiering=@{entra=@{enabled=$false;mappings=@(@{claimValue='Byok.Standard';tier='byok-standard'})};okta=@{enabled=$false;claimName='byok_tier';mappings=@(@{claimValue='Byok.Standard';tier='byok-standard'})}}
      switch($tierCase){
        'entra'{$tiering.entra.enabled=$true}
        'okta'{$tiering.okta.enabled=$true}
        'malformed'{$tiering.entra.enabled='false'}
        'missing-flag'{$tiering.okta.Remove('enabled')}
        'unknown-tier'{$tiering.entra.enabled=$true;$tiering.entra.mappings[0].tier='unknown'}
        'missing-catalog'{$tiering.entra.enabled=$true;$inputDocument.parameters.Remove('productTiers')}
        'zero-limit'{$tiering.entra.enabled=$true;$inputDocument.parameters.productTiers.value[0].tokensPerMinute=0}
      }
      $inputDocument.parameters.callerJwtTiering=@{value=$tiering}
      $candidate=New-DevCallerCandidate $inputDocument $mode '__none__'
      $accepted=$false
      try{$null=Resolve-DevPreviewParameters $candidate $template comm-dev eastus2 $mode;$accepted=$true}catch{}
      if($accepted -ne ($tierCase -cin @('disabled','entra'))){throw ('Caller preview tier contract failed: '+$tierCase)}
      $checks++
    }
  }
  foreach($case in @('valid','applying','not-candidate','already-enabled','key-disabled','entra-disabled','okta-enabled','missing-previous','bad-key','same-key','wrong-rollout','source-secret')){
    $inputDocument=$source|ConvertTo-Json -Depth 100|ConvertFrom-Json -AsHashtable
    $previewOnly=$case -cne 'applying'
    $previousState=if($case -ceq 'missing-previous'){''}else{'__none__'}
    switch($case){
      'already-enabled'{$inputDocument.parameters.callerAuthPreparation.value.enabled=$true}
      'key-disabled'{$inputDocument.parameters.callerAuthPreparation.value.keyEnabled=$false}
      'entra-disabled'{$inputDocument.parameters.callerAuthPreparation.value.entraEnabled=$false}
      'okta-enabled'{$inputDocument.parameters.callerAuthPreparation.value.oktaTrust.enabled=$true}
      'source-secret'{$inputDocument.parameters.responseOwnerKey=@{value='fixture'}}
    }
    $accepted=$false
    try{
      $candidate=New-DevPreviewCandidate $inputDocument $previewOnly $true $previousState
      if(($candidate|ConvertTo-Json -Depth 100 -Compress).Contains($env:BYOK_RESPONSE_OWNER_KEY)){throw 'Candidate document contains an ownership secret.'}
      if($case -ceq 'bad-key'){$candidate.parameters.responseOwnerKey.value='fixture'}
      if($case -ceq 'same-key'){$candidate.parameters.responseOwnerPreviousKey.value='${BYOK_RESPONSE_OWNER_KEY}'}
      if($case -ceq 'wrong-rollout'){$candidate.parameters.callerAuthRollout.value='shared'}
      $rollout=if($case -ceq 'not-candidate'){'legacy'}else{'coexistence'}
      $resolved=Resolve-DevPreviewParameters $candidate $template comm-dev eastus2 $rollout
      $accepted=$true
    }catch{if($_.Exception.Message -ceq 'Candidate document contains an ownership secret.'){throw}}
    if($accepted -ne ($case -ceq 'valid')){throw ('JWT candidate isolation failed: '+$case)}
    if($source.parameters.callerAuthPreparation.value.enabled -ne $false -or $source.parameters.callerAuthRollout.value -cne 'legacy'){throw 'JWT preview mutated the live input document.'}
    $checks++
  }
}finally{
  foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
  $resolved=$null;$candidate=$null
}
foreach($cloud in @('AzureCloud','AzureUSGovernment')){
  foreach($case in @('valid','native-disabled','backend-http','trust-mismatch','missing-setting','pinned-model','existing-caller','open-product','extra-operation','wrong-operation','pagination','backend-pool','tier-entra','tier-disabled','tier-unknown','tier-v2')){
    $loginHost=if($cloud -ceq 'AzureUSGovernment'){'login.microsoftonline.us'}else{'login.microsoftonline.com'}
    $audience=if($cloud -ceq 'AzureUSGovernment'){'https://cognitiveservices.azure.us'}else{'https://cognitiveservices.azure.com'}
    $tenant=[guid]::NewGuid().ToString()
    $appAudience=[guid]::NewGuid().ToString()
    $parameters=@{deployFoundry=@{value=$true};deployAoai=@{value=$false};deployBackendPool=@{value=$false};foundryRegions=@{value=@()};aoaiRegions=@{value=@()};
      callerAuthRollout=@{value='coexistence'};cloudEnv=@{value=$cloud};entraTenantId=@{value=$tenant};apiAudience=@{value=$appAudience};requiredScope=@{value='cli.invoke'};
      jwtDefaultCallsPerMinute=@{value=120};jwtDefaultTokensPerMinute=@{value=200000};jwtDefaultMonthlyCallQuota=@{value=200000};
      responseOwnerKey=@{value='synthetic-secret-marker'};responseOwnerPreviousKey=@{value=''};
      callerAuthPreparation=@{value=@{enabled=$true;keyEnabled=$true;entraEnabled=$true;entraClientIds=@();oktaTrust=@{enabled=$false};jwtProductId='byok-jwt'}}}
    $apim=@{id=$apimId;name='fixture';sku=@{name='Developer'};properties=@{provisioningState='Succeeded';virtualNetworkType='Internal'}}
    $api=@{id=$apimId+'/apis/copilot-byok-foundry';properties=@{path='openai';subscriptionRequired=$true;subscriptionKeyParameterNames=@{header='api-key';query='api-key'};protocols=@('https');serviceUrl='https://backend.example.test'}}
    $backend=@{id=$apimId+'/backends/foundry';properties=@{url='https://backend.example.test'}}
    $settings=@{'entra-openid-config-url'='https://'+$loginHost+'/'+$tenant+'/v2.0/.well-known/openid-configuration';'api-audience'=$appAudience;
      'required-scope'='cli.invoke';'foundry-private-base-url'='https://backend.example.test';'foundry-backend-id'='foundry';'foundry-mi-audience'=$audience;
      'commercial-models'='__none__';'aoai-pinned-models'=' ';'jwt-calls-per-minute'='120';'jwt-tokens-per-minute'='200000';'jwt-monthly-call-quota'='200000'}
    $values=@{value=@($settings.GetEnumerator()|ForEach-Object {@{name=$_.Key;properties=@{secret=$false;value=$_.Value}}})}
    $routes=@{'chat-completions'='POST /v1/chat/completions';'completions'='POST /v1/completions';'embeddings'='POST /v1/embeddings';'responses'='POST /v1/responses';
      'responses-get'='GET /v1/responses/{response_id}';'responses-delete'='DELETE /v1/responses/{response_id}';'responses-cancel'='POST /v1/responses/{response_id}/cancel';
      'responses-input-items'='GET /v1/responses/{response_id}/input_items';'chat-completions-deployment'='POST /deployments/{deployment}/chat/completions';
      'completions-deployment'='POST /deployments/{deployment}/completions';'embeddings-deployment'='POST /deployments/{deployment}/embeddings';'list-models'='GET /v1/models'}
    $operations=@{value=@($routes.GetEnumerator()|ForEach-Object {$parts=$_.Value.Split(' ',2);@{name=$_.Key;properties=@{method=$parts[0];urlTemplate=$parts[1]}}})}
    $products=@{value=@(@{name='byok-standard';properties=@{subscriptionRequired=$true}},@{name='byok-power';properties=@{subscriptionRequired=$true}})}
    $fragments=@{value=@()}
    if($case -clike 'tier-*'){
      $parameters.callerAuthPreparation.value.oktaTrust=@{enabled=$false;issuer='';openIdConfigUrl='';audience='';requiredScope='';clientIds=@()}
      $parameters.callerJwtTiering=@{value=@{entra=@{enabled=$case -cne 'tier-disabled';mappings=@(@{claimValue='Byok.Standard';tier='byok-standard'})};okta=@{enabled=$false;claimName='byok_tier';mappings=@()}}}
      $parameters.productTiers=@{value=@(@{name='byok-standard';callsPerMinute=60;tokensPerMinute=100000;monthlyCallQuota=50000})}
    }
    switch($case){
      'native-disabled'{$api.properties.subscriptionRequired=$false}
      'backend-http'{$backend.properties.url='http://backend.example.test'}
      'trust-mismatch'{($values.value|Where-Object name -CEQ 'api-audience').properties.value=[guid]::NewGuid().ToString()}
      'missing-setting'{$values.value=@($values.value|Where-Object name -CNE 'required-scope')}
      'pinned-model'{($values.value|Where-Object name -CEQ 'aoai-pinned-models').properties.value='fixture-model'}
      'existing-caller'{$values.value+=@{name='caller-response-owner-key';properties=@{secret=$true}}}
      'open-product'{$products.value[0].properties.subscriptionRequired=$false}
      'extra-operation'{$operations.value+=@{name='uncovered';properties=@{method='GET';urlTemplate='/uncovered'}}}
      'wrong-operation'{$operations.value[0].properties.urlTemplate='/wrong'}
      'pagination'{$values.nextLink='https://management.example.test/next'}
      'backend-pool'{$parameters.deployBackendPool.value=$true}
      'tier-unknown'{$parameters.callerJwtTiering.value.entra.mappings[0].tier='unknown'}
      'tier-v2'{$apim.sku.name='StandardV2'}
    }
    $accepted=$false
    try{$bound=New-DevApimPreviewParameters $parameters $apim $api $backend $values $operations $products $fragments;$accepted=$true}catch{}
    if($accepted -ne ($case -cin @('valid','tier-entra','tier-disabled'))){throw ('Focused live-state parameter guard failed: '+$cloud+' '+$case)}
    if($accepted -and ($bound.parameters.Count -ne $(if($case -clike 'tier-*'){10}else{8}) -or $bound.parameters.responseOwnerKey.value -cne 'synthetic-secret-marker' -or
      $bound.parameters.callerAuthRollout.value -cne 'coexistence')){throw 'Focused parameter boundary changed.'}
    if($accepted -and $case -ceq 'tier-entra' -and ($bound.parameters.callerJwtTiering.value.entra.enabled -ne $true -or
      $bound.parameters.productTiers.value[0].monthlyCallQuota -ne 50000)){throw 'Focused tier/catalog values were discarded.'}
    $checks++
  }
}
function Invoke-DevWorkflowBashFixture {
  param([string]$Text,$Environment)
  $bash=if($IsWindows){Join-Path $env:ProgramFiles 'Git/bin/bash.exe'}else{(Get-Command bash -CommandType Application|Select-Object -First 1).Source}
  $start=[Diagnostics.ProcessStartInfo]::new($bash)
  $start.UseShellExecute=$false;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  $start.StandardInputEncoding=[Text.UTF8Encoding]::new($false)
  foreach($argument in @('--noprofile','--norc','-s')){$start.ArgumentList.Add($argument)}
  foreach($name in $Environment.Keys){$start.Environment[$name]=[string]$Environment[$name]}
  $start.Environment['GITHUB_OUTPUT']='/dev/null'
  $process=[Diagnostics.Process]::Start($start)
  try{
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write($Text.Replace("`r`n","`n")+"`n");$process.StandardInput.Close();$process.WaitForExit()
    $null=$stdout.GetAwaiter().GetResult();$null=$stderr.GetAwaiter().GetResult()
    $process.ExitCode
  }finally{$process.Dispose()}
}
foreach($job in @($workflow.jobs.provision,$teardown.jobs.teardown)){
  $guard=@($job.steps|Where-Object name -CEQ 'Guard caller transition hold')
  if($guard.Count -ne 1 -or $job.concurrency.group -cne 'dev-env-${{ matrix.env }}' -or $job.concurrency.'cancel-in-progress' -cne 'false'){
    throw 'Lifecycle hold must run under the shared non-cancelling lock.'
  }
  foreach($case in @('clear','held','unknown','read-failed')){
    $stub='az() { if [[ "$HOLD_FIXTURE" == "read-failed" ]]; then return 1; fi; if [[ "$2" == "exists" ]]; then printf "true\n"; elif [[ "$HOLD_FIXTURE" != "clear" ]]; then printf "%s\n" "$HOLD_FIXTURE"; fi; }'
    $exitCode=Invoke-DevWorkflowBashFixture ($stub+"`n"+$guard[0].run) @{TARGET_ENVIRONMENT='comm-dev';HOLD_FIXTURE=$case}
    if(($exitCode -eq 0) -ne ($case -ceq 'clear')){throw ('Lifecycle hold failed: '+$case)}
    $checks++
  }
}
foreach($case in @('legacy','jwt-preview','jwt-with-apply','apim-preview','apim-without-jwt','recovery-preview','recovery-government','recovery-smoke','recovery-jwt',
  'caller-preview','caller-apply','caller-rollback','caller-finalize','caller-government','caller-both','caller-smoke','caller-recovery','caller-jwt','caller-unknown',
  'caller-gov-pilot','caller-comm-pilot','caller-pilot-apply','caller-pilot-rollback','caller-pilot-finalize','pilot-full-stack','pilot-legacy-preview',
  'caller-pilot-push','caller-pilot-scheduled','caller-pilot-smoke','caller-pilot-mixed','caller-pilot-jwt')){
  $fixture=@{EVENT_NAME='workflow_dispatch';PREVIEW_ONLY='true';PREVIEW_JWT='false';RECOVER_PHASE_TWO='false';REQUESTED_ENVS='comm-dev';REQUESTED_SMOKE='false';CALLER_ACTION='none'}
  $apimFlag='false'
  switch($case){
    'legacy'{$fixture.PREVIEW_ONLY='false';$fixture.REQUESTED_SMOKE='true'}
    'jwt-preview'{$fixture.PREVIEW_JWT='true'}
    'jwt-with-apply'{$fixture.PREVIEW_JWT='true';$fixture.PREVIEW_ONLY='false'}
    'apim-preview'{$apimFlag='true';$fixture.PREVIEW_JWT='true'}
    'apim-without-jwt'{$apimFlag='true'}
    'recovery-preview'{$fixture.RECOVER_PHASE_TWO='true'}
    'recovery-government'{$fixture.RECOVER_PHASE_TWO='true';$fixture.REQUESTED_ENVS='gov-dev'}
    'recovery-smoke'{$fixture.RECOVER_PHASE_TWO='true';$fixture.REQUESTED_SMOKE='true'}
    'recovery-jwt'{$fixture.RECOVER_PHASE_TWO='true';$fixture.PREVIEW_JWT='true'}
    'caller-preview'{$fixture.CALLER_ACTION='activate'}
    'caller-apply'{$fixture.CALLER_ACTION='activate';$fixture.PREVIEW_ONLY='false'}
    'caller-rollback'{$fixture.CALLER_ACTION='rollback'}
    'caller-finalize'{$fixture.CALLER_ACTION='finalize'}
    'caller-government'{$fixture.CALLER_ACTION='activate';$fixture.REQUESTED_ENVS='gov-dev'}
    'caller-both'{$fixture.CALLER_ACTION='activate';$fixture.REQUESTED_ENVS='comm-dev,gov-dev'}
    'caller-smoke'{$fixture.CALLER_ACTION='activate';$fixture.REQUESTED_SMOKE='true'}
    'caller-recovery'{$fixture.CALLER_ACTION='activate';$fixture.RECOVER_PHASE_TWO='true'}
    'caller-jwt'{$fixture.CALLER_ACTION='activate';$fixture.PREVIEW_JWT='true'}
    'caller-unknown'{$fixture.CALLER_ACTION='unknown'}
    'caller-gov-pilot'{$fixture.CALLER_ACTION='activate';$fixture.REQUESTED_ENVS='gov-pilot'}
    'caller-comm-pilot'{$fixture.CALLER_ACTION='activate';$fixture.REQUESTED_ENVS='comm-pilot'}
    'caller-pilot-apply'{$fixture.CALLER_ACTION='activate';$fixture.REQUESTED_ENVS='gov-pilot';$fixture.PREVIEW_ONLY='false'}
    'caller-pilot-rollback'{$fixture.CALLER_ACTION='rollback';$fixture.REQUESTED_ENVS='gov-pilot'}
    'caller-pilot-finalize'{$fixture.CALLER_ACTION='finalize';$fixture.REQUESTED_ENVS='gov-pilot'}
    'pilot-full-stack'{$fixture.REQUESTED_ENVS='gov-pilot';$fixture.PREVIEW_ONLY='false'}
    'pilot-legacy-preview'{$fixture.REQUESTED_ENVS='comm-pilot'}
    'caller-pilot-push'{$fixture.CALLER_ACTION='activate';$fixture.REQUESTED_ENVS='gov-pilot';$fixture.EVENT_NAME='push'}
    'caller-pilot-scheduled'{$fixture.CALLER_ACTION='activate';$fixture.REQUESTED_ENVS='gov-pilot';$fixture.EVENT_NAME='schedule'}
    'caller-pilot-smoke'{$fixture.CALLER_ACTION='activate';$fixture.REQUESTED_ENVS='gov-pilot';$fixture.REQUESTED_SMOKE='true'}
    'caller-pilot-mixed'{$fixture.CALLER_ACTION='activate';$fixture.REQUESTED_ENVS='gov-pilot,gov-dev'}
    'caller-pilot-jwt'{$fixture.CALLER_ACTION='activate';$fixture.REQUESTED_ENVS='gov-pilot';$fixture.PREVIEW_JWT='true'}
  }
  $text=$configStep[0].run.Replace('${{ inputs.preview_apim_only }}',$apimFlag).Replace('${{ matrix.env }}',$fixture.REQUESTED_ENVS.Split(',')[0])
  $accepted=(Invoke-DevWorkflowBashFixture $text $fixture) -eq 0
  if($accepted -ne ($case -cin @('legacy','jwt-preview','apim-preview','recovery-preview','caller-preview','caller-apply','caller-rollback','caller-finalize','caller-government',
    'caller-gov-pilot','caller-comm-pilot','caller-pilot-apply','caller-pilot-rollback','caller-pilot-finalize'))){throw ('Actual dispatch gate failed: '+$case)}
  $checks++
}
$transportText='transport-'+[char]0x2014
$transportInput=@{fixture=$transportText}|ConvertTo-Json -Compress
$transport=Invoke-DevPreviewProcess pwsh @('-NoProfile','-Command','[Console]::InputEncoding=[Text.UTF8Encoding]::new($false); [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $payload=[Console]::In.ReadToEnd()|ConvertFrom-Json; [Console]::Out.Write($payload.fixture); [Console]::Error.Write("sensitive-fixture-marker")') $transportInput
if($transport -cne $transportText){throw 'Private UTF-8 stdin transport failed.'}
Write-Output "PASS: $checks development preview inventory/parameter cases, mutation/smoke gates and private UTF-8 stdin transport."
exit 0