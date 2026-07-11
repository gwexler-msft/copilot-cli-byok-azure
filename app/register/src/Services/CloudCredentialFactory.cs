extern alias AzureIdentity;
using Azure.Core;

// The transitive Azure.Core also surfaces DefaultAzureCredential / AzureAuthorityHosts in the
// Azure.Identity namespace, so those types are referenced through the AzureIdentity extern alias.
// Centralizing credential creation here keeps the alias confined to a single file; callers receive
// the base Azure.Core.TokenCredential and need no alias of their own.

namespace Byok.Register.Services;

/// <summary>
/// Builds the cloud-aware (Commercial vs US Government) managed-identity credential the register
/// app uses for both ARM (APIM provisioning) and Microsoft Graph (group-overage fallback).
/// </summary>
public static class CloudCredentialFactory
{
    public static TokenCredential Create(ByokOptions options) =>
        new AzureIdentity::Azure.Identity.DefaultAzureCredential(new AzureIdentity::Azure.Identity.DefaultAzureCredentialOptions
        {
            ManagedIdentityClientId = string.IsNullOrWhiteSpace(options.UamiClientId) ? null : options.UamiClientId,
            AuthorityHost = options.IsGovernment
                ? AzureIdentity::Azure.Identity.AzureAuthorityHosts.AzureGovernment
                : AzureIdentity::Azure.Identity.AzureAuthorityHosts.AzurePublicCloud,
        });
}
