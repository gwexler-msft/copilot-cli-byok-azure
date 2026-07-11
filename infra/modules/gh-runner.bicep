// VNet-injected self-hosted GitHub Actions runner deployed as an Azure Container Apps Job,
// scaled by KEDA's `github-runner` scaler. The runner is the single egress point used by
// CI/CD smoke tests to reach the private APIM gateway and the private Foundry data plane
// over the BYOK VNet (no public access to either).
//
// Phase 1 (this module, issue #57): provisions the ACA Environment, the user-assigned
// managed identity, and a MANUAL-trigger ACA Job. The job uses a sentinel container image
// (mcr.microsoft.com/azure-cli) so `azd provision --parameters deployGhRunner=true`
// succeeds without any GitHub credentials present. Phase 2 (#53) layers OIDC federation
// onto the UAMI, phase 3 (#58) replaces the trigger with KEDA `github-runner` event
// scaling + the real runner container.
//
// Ingress: NONE. The job is outbound-only (KEDA polls the GitHub Actions queue API and
// the runner registers itself with GitHub). The ACA env is created as `internal: true`
// because no inbound HTTPS is ever needed; this avoids the L7 "Azure Container App -
// Unavailable" routing bug that affects internal-ingress apps (workload note:
// aca-internal-l7-bug — runner has no ingress so unaffected).

@description('Short prefix used in all resource names. Lowercase, alpha-only.')
param namePrefix string

@description('Environment short name, e.g. gov-pilot, comm-pilot. Used in names.')
param envName string

@description('Stable 6-char suffix shared across the deployment for global uniqueness.')
param suffix string

@description('Azure region.')
param location string

@description('Subnet ID for the ACA runner environment. Must be /27 or larger (Workload Profiles requirement) and delegated to Microsoft.App/environments. Egress must reach GitHub Actions APIs.')
param runnerSubnetId string

@description('Log Analytics workspace name the ACA env streams app logs to. The module reads its customer ID and shared key directly to keep the secret out of the parent template.')
param logAnalyticsName string

@description('Workload profile name. "Consumption" gives the cheapest pay-per-second tier; switch to a dedicated profile (D4/D8/etc.) for runners that need more CPU/RAM than the 4-vCPU Consumption ceiling.')
param workloadProfileName string = 'Consumption'

@description('Container image the runner job runs. Phase 1 uses a placeholder so the job is deployable without GitHub credentials; phase 3 swaps in the real runner image (ghcr.io/actions/actions-runner or an MS-published equivalent).')
param runnerImage string = 'mcr.microsoft.com/azure-cli:latest'

@description('CPU cores allocated per job replica.')
param runnerCpu string = '1.0'

@description('Memory allocated per job replica.')
param runnerMemory string = '2Gi'

@description('Job replica timeout (seconds). Must be at least as long as the longest workflow that may dispatch to this runner. The deploy-dev workflow has `timeout-minutes: 60`; gov APIM Developer first-create alone takes ~35-45 min, so 60 min (3600s) is the floor. Default 4500s (75 min) gives ~15 min headroom for cold starts and azd housekeeping. Bump higher only if you start dispatching real long-running provisioning workflows that need it; the workflow-level timeout-minutes is still the authoritative cap.')
param replicaTimeoutSeconds int = 4500

@description('Max parallel job replicas in a single execution.')
param parallelism int = 1

@description('Tags applied to every resource the module creates.')
param tags object = {}

// ------------------------------------------------------------------------------------
// OIDC federation (issue #53 phase 2). Federated credentials let the GitHub Actions
// workflow exchange its short-lived OIDC token for an Azure AD token bound to this
// UAMI, with NO stored client secret. Each subject in `ghFicEnvSubjects` produces one
// FIC child resource. The default subject is this env's own name, but the array can
// include sibling envs that share this runner pool (e.g. comm-pilot runner servicing
// comm-dev jobs). Empty array disables federation entirely (runner becomes
// MI-callable from inside the VNet only).
//
// Subject convention: `repo:<owner>/<repo>:environment:<env>` (matches the workflow's
// `environment:` gate; same issuer/audience for both Azure clouds).
// ------------------------------------------------------------------------------------

@description('GitHub repository in `<owner>/<repo>` form. Used to build the FIC subject `repo:<owner>/<repo>:environment:<env>`.')
param ghRepository string = 'gwexler_microsoft/copilot-cli-byok-azure'

@description('GitHub Environment names whose OIDC tokens may federate to this runner UAMI. Each entry creates one federated credential `fic-env-<name>`. Defaults to this env only; add sibling envs to share the runner pool.')
param ghFicEnvSubjects array = [envName]

// ------------------------------------------------------------------------------------
// KEDA-driven self-hosted runner (issue #58 phase 3). Supplying `ghRunnerPat` flips
// this Job from the Phase 1 manual placeholder into an event-driven self-hosted
// GitHub Actions runner pool:
//   - triggerType: Event with KEDA `github-runner` scaler polling the GitHub Actions
//     queue for jobs targeting `ghRunnerLabels` on `ghRepository`
//   - container image: `myoung34/github-runner` (community image; honors the
//     ACCESS_TOKEN/REPO_URL/LABELS/EPHEMERAL env-var bootstrap pattern; container
//     runs `./config.sh --ephemeral` + `./run.sh --once` then exits, so every Job
//     execution = exactly one workflow job, then deregister)
//   - Job secret `gh-pat` stores the PAT, referenced by both KEDA (queue polling)
//     and the container env (registration). Same secret, two consumers.
// Leave `ghRunnerPat` empty to keep the Phase 1 placeholder behavior (Manual trigger,
// azure-cli image) — useful for the first `azd provision` before a PAT is minted.
// ------------------------------------------------------------------------------------

@description('GitHub PAT (classic with `repo` scope OR fine-grained with `Actions: read+write` + `Administration: read+write`). Stored ONLY as a Job-level secret named `gh-pat`. Leave empty to keep the Phase 1 manual-trigger placeholder. Prefer `ghRunnerPatKeyVaultSecretUri` (Key Vault reference) over this inline param for production: it keeps the PAT out of azd state and makes rotation a single `az keyvault secret set`.')
@secure()
param ghRunnerPat string = ''

@description('Full Key Vault secret URI (https://<vault>.<dns>/secrets/gh-pat) holding the runner PAT. When set, the Job secret `gh-pat` is a Key Vault reference resolved by the runner UAMI (which must hold Key Vault Secrets User on the vault) instead of an inline value, and rotation becomes a single `az keyvault secret set`. Takes precedence over `ghRunnerPat`. Like `ghRunnerPat`, a non-empty value flips the Job to the KEDA Event trigger. Leave empty to use the inline `ghRunnerPat` path (or the Phase 1 placeholder when both are empty).')
param ghRunnerPatKeyVaultSecretUri string = ''

// ------------------------------------------------------------------------------------
// GitHub App auth (issue #58, PRIMARY path). A GitHub App authenticates with a private
// key and mints SHORT-LIVED installation tokens on the fly, so there is no long-lived
// credential to rotate (unlike a PAT). Both consumers support it: KEDA's `github-runner`
// scaler (metadata `applicationID`/`installationID` + auth `appKey`) and the
// `myoung34/github-runner` image (`APP_ID`/`APP_PRIVATE_KEY`/`APP_LOGIN`). The Job secret
// `gh-app-key` holds the PEM private key; App ID + Installation ID are NON-secret ids.
// PAT auth (above) remains a fully-supported opt-in via `ghRunnerAuthMode: 'pat'`.
// ------------------------------------------------------------------------------------

@description('Runner auth method: `app` (GitHub App — recommended PRIMARY path; mints short-lived installation tokens, no credential to rotate, 15k/hr API limit) or `pat` (Personal Access Token — supported opt-in fallback). App mode needs ghAppId + ghAppInstallationId + an App private key (Key Vault ref or inline). PAT mode needs ghRunnerPat (Key Vault ref or inline). Either mode falls back to the Phase 1 Manual placeholder until its credentials are present.')
@allowed([ 'app', 'pat' ])
param ghRunnerAuthMode string = 'app'

@description('GitHub App ID (numeric string, NOT secret). Required for app mode. Found on the App\'s settings page ("App ID").')
param ghAppId string = ''

@description('GitHub App installation ID (numeric string, NOT secret). Required for app mode. Found in the installation settings URL (.../installations/<id>) or via `gh api /repos/<owner>/<repo>/installation --jq .id`.')
param ghAppInstallationId string = ''

@description('GitHub App private key PEM, inline @secure(). Used in app mode when no Key Vault URI is supplied (the dev path — injected from a repo secret on each nightly rebuild). Prefer ghAppPrivateKeyKeyVaultSecretUri for long-lived pilot envs.')
@secure()
param ghAppPrivateKey string = ''

@description('Full Key Vault secret URI (https://<vault>.<dns>/secrets/gh-app-key) holding the GitHub App private key PEM. When set (app mode), the Job secret `gh-app-key` is a Key Vault reference resolved by the runner UAMI (which must hold Key Vault Secrets User), and rotation/key-roll is a single `az keyvault secret set`. Takes precedence over the inline ghAppPrivateKey.')
param ghAppPrivateKeyKeyVaultSecretUri string = ''

@description('Container image used when the Event trigger is enabled. Community image `myoung34/github-runner` is the canonical KEDA + ACA Jobs choice because it honors ACCESS_TOKEN (pat) / APP_ID+APP_PRIVATE_KEY (app) / REPO_URL/LABELS/EPHEMERAL env vars at startup. Pin to a digest in production (e.g. `myoung34/github-runner@sha256:...`). IGNORED when acrLoginServer is set (#94): the pre-baked ACR image takes precedence.')
param ghRunnerEventImage string = 'myoung34/github-runner:latest'

@description('Login server of the ACR holding the pre-baked runner image (#94), e.g. `acrregcommpilotxxxxxx.azurecr.io`. When set, the Job pulls `<acrLoginServer>/<runnerImageRepository>:<runnerImageTag>` via the runner UAMI (a `registries` block + AcrPull role are added) INSTEAD of the public ghRunnerEventImage. Empty (default) keeps the public-image behavior so live runners are untouched until an env opts in.')
param acrLoginServer string = ''

@description('Name of the ACR holding the pre-baked runner image (#94). Required alongside acrLoginServer so this module can grant the runner UAMI AcrPull on it (the runner grants its OWN pull to avoid a module dependency cycle with the shared-ACR module). Empty when not using the ACR image.')
param acrName string = ''

@description('Repository name of the pre-baked runner image within the ACR (#94).')
param runnerImageRepository string = 'github-runner'

@description('Tag of the pre-baked runner image within the ACR (#94). Pin to a digest/immutable tag in production and bump to roll a new image (two-phase: build the new tag, then bump this).')
param runnerImageTag string = 'latest'

@description('Comma-separated runner labels applied at registration. Workflows must `runs-on:` one of these. Defaults to this env name so e.g. comm-pilot smoke tests use `runs-on: comm-pilot`.')
param ghRunnerLabels string = envName

@description('Max number of concurrent runner replicas KEDA may scale up to. Each replica = one workflow job (ephemeral). Higher = more parallelism but more Azure billing during bursts.')
param ghMaxRunners int = 5

@description('KEDA polling interval (seconds) against the GitHub Actions queue API. 30s is the KEDA-recommended default and stays well under the 5,000/hr unauthenticated rate limit.')
param ghPollingInterval int = 30

@description('Target queued-jobs threshold per replica. KEDA scales up when queued >= threshold * current-replicas. Default 1 = scale aggressively (one runner per queued job).')
param ghTargetQueueLength int = 1


var envNameAca = take('cae-runner-${envName}-${suffix}', 32)
var jobName    = take('caj-runner-${envName}-${suffix}', 32)
var uamiName   = take('id-${namePrefix}-runner-${envName}-${suffix}',  64)

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsName
}

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiName
  location: location
  tags: tags
}

// One FIC per env subject. Names are `fic-env-<subject>` so they sort by env in the
// portal and are easy to grep in `az identity federated-credential list`. Re-running
// the deployment is idempotent: adding/removing entries in ghFicEnvSubjects creates or
// removes credentials in place; the UAMI itself (and any downstream RBAC) is untouched.
//
// @batchSize(1) serializes the writes — Azure rejects parallel FIC writes against the
// same UAMI with `ConcurrentFederatedIdentityCredentialsWritesForSingleManagedIdentity`.
@batchSize(1)
resource ghFics 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = [for subject in ghFicEnvSubjects: {
  parent: uami
  name: 'fic-env-${subject}'
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    audiences: [ 'api://AzureADTokenExchange' ]
    subject: 'repo:${ghRepository}:environment:${subject}'
  }
}]

// Internal-only ACA env. The runner has NO ingress (jobs don't expose ports), so the
// internal-L7 routing bug that affects internal-ingress apps does not apply here.
resource env 'Microsoft.App/managedEnvironments@2024-10-02-preview' = {
  name: envNameAca
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
    vnetConfiguration: {
      internal: true
      infrastructureSubnetId: runnerSubnetId
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    publicNetworkAccess: 'Disabled'
  }
}

// Phase 3 toggle: presence of a non-empty PAT flips the Job from the Phase 1 manual
// placeholder to a KEDA-scaled, event-driven, ephemeral self-hosted runner pool.
// `enableEventTrigger` is the single boolean threaded through the Job's `configuration`
// and `template` objects so all the ternary branches stay aligned. Splitting the repo
// for KEDA's `owner` + `repos` metadata is done once here so the rule body stays simple.
// Phase 3 toggle: presence of a non-empty PAT (inline OR Key Vault reference) flips the
// Job from the Phase 1 manual placeholder to a KEDA-scaled, event-driven, ephemeral
// self-hosted runner pool. `enableEventTrigger` is the single boolean threaded through the
// Job's `configuration` and `template` objects so all the ternary branches stay aligned.
// `useKvSecret` selects how the `gh-pat` secret is sourced: a Key Vault `keyVaultUrl`
// reference (resolved by the runner UAMI) when a secret URI is supplied, else the inline
// `@secure()` value. KEDA + the container both consume the SAME secret name (`gh-pat`)
// regardless of source. Splitting the repo for KEDA's `owner` + `repos` metadata is done
// once here so the rule body stays simple.
var useApp = ghRunnerAuthMode == 'app'
// Which store backs the active auth secret: a Key Vault reference (resolved by the runner
// UAMI) when the mode's *KeyVaultSecretUri is supplied, else the inline @secure() value.
var appUseKv = !empty(ghAppPrivateKeyKeyVaultSecretUri)
var patUseKv = !empty(ghRunnerPatKeyVaultSecretUri)
var useKvSecret = useApp ? appUseKv : patUseKv
// App mode is "configured" once we have App id + installation id + a private key (KV or
// inline); PAT mode once we have a PAT (KV or inline). Until then the Job stays a Phase 1
// Manual placeholder so `azd provision` succeeds with no GitHub credentials present.
var appConfigured = useApp && !empty(ghAppId) && !empty(ghAppInstallationId) && (appUseKv || !empty(ghAppPrivateKey))
var patConfigured = !useApp && (patUseKv || !empty(ghRunnerPat))
var enableEventTrigger = appConfigured || patConfigured
// One Job secret, two consumers (KEDA scaler + runner container). Its name differs by
// mode: `gh-app-key` (PEM, KEDA `appKey` / container `APP_PRIVATE_KEY`) vs `gh-pat`
// (KEDA `personalAccessToken` / container `ACCESS_TOKEN`).
var secretName = useApp ? 'gh-app-key' : 'gh-pat'
var repoSplit = split(ghRepository, '/')
var ghOwner = repoSplit[0]
var ghRepoName = repoSplit[1]

// #94: when an ACR login server is supplied, the Job pulls the pre-baked image from our ACR
// (covered by the AzureContainerRegistry + Storage service tags, so it works under
// restrictRunnerEgress with zero CIDR params) instead of the public ghRunnerEventImage. The
// env contract is identical (entrypoint.sh in infra/runner-image mimics myoung34), so only
// the image ref + a `registries` block + an AcrPull role differ.
var useAcr = !empty(acrLoginServer)
var effectiveEventImage = useAcr ? '${acrLoginServer}/${runnerImageRepository}:${runnerImageTag}' : ghRunnerEventImage

// Phase 1: manual trigger w/ azure-cli placeholder. Phase 3 (#58, enabled by setting
// `ghRunnerPat`): Event trigger with the KEDA `github-runner` scaler + a real runner
// container. Same resource definition — only the `configuration` / `template` branches
// differ based on `enableEventTrigger`.
resource job 'Microsoft.App/jobs@2024-10-02-preview' = {
  name: jobName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    environmentId: env.id
    workloadProfileName: workloadProfileName
    configuration: {
      triggerType: enableEventTrigger ? 'Event' : 'Manual'
      replicaTimeout: replicaTimeoutSeconds
      replicaRetryLimit: 0
      // The same Job secret is consumed by KEDA (queue polling) and the container
      // (registration token fetch). Stored at Job scope so a rotation = single
      // `az keyvault secret set` (KV-backed) or `az containerapp job secret set`
      // (inline). `useKvSecret` picks a Key Vault reference resolved by the runner
      // UAMI vs. the inline @secure() value.
      secrets: enableEventTrigger ? [
        useApp ? (appUseKv ? {
          name: secretName
          keyVaultUrl: ghAppPrivateKeyKeyVaultSecretUri
          identity: uami.id
        } : {
          name: secretName
          value: ghAppPrivateKey
        }) : (patUseKv ? {
          name: secretName
          keyVaultUrl: ghRunnerPatKeyVaultSecretUri
          identity: uami.id
        } : {
          name: secretName
          value: ghRunnerPat
        })
      ] : []
      manualTriggerConfig: enableEventTrigger ? null : {
        parallelism: parallelism
        replicaCompletionCount: parallelism
      }
      // #94: pull the pre-baked image from our ACR via the runner UAMI. Only present when
      // an ACR login server is supplied; public-image runs keep an empty registries list.
      registries: (enableEventTrigger && useAcr) ? [
        {
          server: acrLoginServer
          identity: uami.id
        }
      ] : []
      // KEDA `github-runner` scaler. `auth[].triggerParameter` is the KEDA metadata
      // key (`personalAccessToken`); `secretRef` is the Job-secret name (`gh-pat`).
      // `targetWorkflowQueueLength` of 1 means "spin up one runner per queued job",
      // which matches the ephemeral runner pattern (one job = one container = one exit).
      eventTriggerConfig: enableEventTrigger ? {
        parallelism: parallelism
        replicaCompletionCount: parallelism
        scale: {
          minExecutions: 0
          maxExecutions: ghMaxRunners
          pollingInterval: ghPollingInterval
          rules: [
            {
              name: 'github-runner'
              type: 'github-runner'
              metadata: union({
                githubAPIURL: 'https://api.github.com'
                owner: ghOwner
                runnerScope: 'repo'
                repos: ghRepoName
                labels: ghRunnerLabels
                targetWorkflowQueueLength: string(ghTargetQueueLength)
              }, useApp ? {
                applicationID: ghAppId
                installationID: ghAppInstallationId
              } : {})
              auth: [
                useApp ? {
                  secretRef: secretName
                  triggerParameter: 'appKey'
                } : {
                  secretRef: secretName
                  triggerParameter: 'personalAccessToken'
                }
              ]
            }
          ]
        }
      } : null
    }
    template: {
      containers: [
        {
          name: 'runner'
          image: enableEventTrigger ? effectiveEventImage : runnerImage
          resources: {
            cpu: json(runnerCpu)
            memory: runnerMemory
          }
          // Event-trigger env wires `myoung34/github-runner`'s built-in startup logic:
          //   - ACCESS_TOKEN={PAT}     → image fetches a fresh registration token at startup
          //   - REPO_URL                → which repo to register against
          //   - RUNNER_SCOPE=repo       → repo-scoped runner (not org)
          //   - LABELS                  → label set workflows target
          //   - EPHEMERAL=true          → exit after one job (no lingering registration)
          //   - DISABLE_RUNNER_UPDATE   → skip the auto-update probe to keep the image
          //                                 deterministic across executions
          //   - RUNNER_NAME_PREFIX      → human-friendly per-execution name prefix; the
          //                                 image appends a unique suffix per container.
          //                                 (We intentionally do NOT set the fixed
          //                                 `RUNNER_NAME` env var — that causes registration
          //                                 collisions when KEDA scales >1 replica
          //                                 concurrently and one container "wins" the name
          //                                 while the others loop forever with stale
          //                                 registration IDs.)
          // Phase 1 (manual placeholder): just sleep so the manually-triggered
          // execution succeeds cleanly during provision validation.
          // Auth-specific env first (app: APP_ID/APP_PRIVATE_KEY/APP_LOGIN — the image's
          // app_token.sh mints a short-lived installation token at startup; pat:
          // ACCESS_TOKEN), then the common registration env. APP_PRIVATE_KEY and
          // ACCESS_TOKEN must never both be set (image rejects the combination), which the
          // `useApp` branch guarantees.
          env: enableEventTrigger ? concat(useApp ? [
            {
              name: 'APP_ID'
              value: ghAppId
            }
            {
              name: 'APP_PRIVATE_KEY'
              secretRef: secretName
            }
            {
              name: 'APP_LOGIN'
              value: ghOwner
            }
          ] : [
            {
              name: 'ACCESS_TOKEN'
              secretRef: secretName
            }
          ], [
            {
              name: 'REPO_URL'
              value: 'https://github.com/${ghRepository}'
            }
            {
              name: 'RUNNER_SCOPE'
              value: 'repo'
            }
            {
              name: 'LABELS'
              value: ghRunnerLabels
            }
            {
              name: 'EPHEMERAL'
              value: 'true'
            }
            {
              name: 'DISABLE_RUNNER_UPDATE'
              value: 'true'
            }
            {
              name: 'RUNNER_NAME_PREFIX'
              value: '${envName}-runner'
            }
          ]) : []
          command: enableEventTrigger ? [] : [ '/bin/sh', '-c' ]
          args: enableEventTrigger ? [] : [ 'echo phase-1 placeholder runner ready; sleep 10' ]
        }
      ]
    }
  }
}

// #94: grant the runner UAMI AcrPull on the shared ACR holding the pre-baked image. Done
// HERE (not in the shared-ACR module) so the ACR doesn't need the runner UAMI principal as
// an input — that would cycle (gh-runner already depends on the ACR for acrLoginServer).
// Scoped to the existing registry by name; only created when acrName is supplied.
resource sharedAcr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = if (!empty(acrName)) {
  name: acrName
}

var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

resource runnerAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(acrName)) {
  scope: sharedAcr
  name: guid(sharedAcr.id, uami.id, acrPullRoleId)
  properties: {
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleId
  }
}

output uamiName string = uami.name
output uamiId string = uami.id
output uamiClientId string = uami.properties.clientId
output uamiPrincipalId string = uami.properties.principalId
output envName string = env.name
output envId string = env.id
output jobName string = job.name
output jobId string = job.id

@description('Federated credential subjects bound to the runner UAMI (one per env subject in ghFicEnvSubjects). Empty when federation is disabled.')
output ghFicSubjects array = [for (subject, i) in ghFicEnvSubjects: ghFics[i].properties.subject]

@description('Trigger type the runner Job is currently configured for: `Event` when the active auth mode has its credentials present (KEDA-driven ephemeral runner), `Manual` otherwise (Phase 1 placeholder).')
output ghRunnerTriggerType string = enableEventTrigger ? 'Event' : 'Manual'

@description('Runner label string the KEDA scaler filters on. Workflows must `runs-on:` this exact value (or be a superset).')
output ghRunnerLabels string = ghRunnerLabels

@description('Where the runner Job sources its auth secret: `keyvault` (Key Vault reference resolved by the runner UAMI), `inline` (inline @secure() value), or `none` (Phase 1 placeholder, no secret).')
output ghRunnerSecretSource string = useKvSecret ? 'keyvault' : (enableEventTrigger ? 'inline' : 'none')

@description('Active runner auth method: `app` (GitHub App) or `pat` (Personal Access Token).')
output ghRunnerAuthMode string = ghRunnerAuthMode

@description('Name of the Job secret backing the active auth method: `gh-app-key` (app) or `gh-pat` (pat). Empty when the Job is a Phase 1 placeholder.')
output ghRunnerSecretName string = enableEventTrigger ? secretName : ''

