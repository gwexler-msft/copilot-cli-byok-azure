// Runner user-assigned managed identity + GitHub OIDC federated credentials (issues #53, #86).
//
// WHY THIS IS ITS OWN MODULE (#86 — the bootstrap deadlock):
// The UAMI used to be declared inside `gh-runner.bicep`. That forced an unbreakable ordering:
//   runner-kv  --(needs uamiPrincipalId for the Secrets User role)-->  gh-runner
// while the ACA Job inside gh-runner needs the vault (and the secret, and the role) to ALREADY
// exist, because Container Apps *fetch-validates* a `keyVaultUrl` secret reference at Job
// create/update time. With `ghRunnerSecretFromKeyVault=true` a fresh provision therefore
// deadlocked: the Job failed -> gh-runner produced no outputs -> runner-kv never ran -> the
// vault never appeared. Hoisting the identity here inverts the graph to:
//   runner-identity  ->  runner-kv (vault + seeded secret + RBAC)  ->  gh-runner (Job w/ KV ref)
// which bootstraps in a single pass.
//
// Moving the resource between modules does NOT recreate it in Azure: the UAMI name is unchanged
// (`id-<prefix>-runner-<env>-<suffix>`), and ARM identifies resources by resourceId, not by which
// nested deployment declares them. Existing envs update in place; RBAC and FICs are preserved.

@description('Short prefix used in all resource names. Lowercase, alpha-only.')
param namePrefix string

@description('Environment short name, e.g. gov-pilot, comm-pilot. Used in names.')
param envName string

@description('Stable 6-char suffix shared across the deployment for global uniqueness.')
param suffix string

@description('Azure region.')
param location string

@description('GitHub repository in `<owner>/<repo>` form. Used to build the FIC subject `repo:<owner>/<repo>:environment:<env>`.')
param ghRepository string = '<OWNER>/<REPO>'

@description('GitHub Environment names whose OIDC tokens may federate to this runner UAMI. Each entry creates one federated credential `fic-env-<name>`. Defaults to this env only; add sibling envs to share the runner pool. Empty array disables federation entirely.')
param ghFicEnvSubjects array = [envName]

@description('Tags applied to every resource the module creates.')
param tags object = {}

var uamiName = take('id-${namePrefix}-runner-${envName}-${suffix}', 64)

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiName
  location: location
  tags: tags
}

// One FIC per env subject. Names are `fic-env-<subject>` so they sort by env in the portal and
// are easy to grep in `az identity federated-credential list`. Re-running the deployment is
// idempotent: adding/removing entries in ghFicEnvSubjects creates or removes credentials in
// place; the UAMI itself (and any downstream RBAC) is untouched.
//
// @batchSize(1) serializes the writes — Azure rejects parallel FIC writes against the same UAMI
// with `ConcurrentFederatedIdentityCredentialsWritesForSingleManagedIdentity`.
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

output uamiName string = uami.name
output uamiId string = uami.id
output uamiClientId string = uami.properties.clientId
output uamiPrincipalId string = uami.properties.principalId

@description('Federated credential subjects bound to the runner UAMI (one per env subject in ghFicEnvSubjects). Empty when federation is disabled.')
output ghFicSubjects array = [for (subject, i) in ghFicEnvSubjects: ghFics[i].properties.subject]
