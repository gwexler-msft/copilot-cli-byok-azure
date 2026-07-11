using System.Text;
using Azure;
using Azure.Core;
using Azure.ResourceManager;
using Azure.ResourceManager.ApiManagement;
using Azure.ResourceManager.ApiManagement.Models;
using Microsoft.Extensions.Options;

namespace Byok.Register.Services;

/// <summary>Result of an idempotent per-developer subscription upsert.</summary>
public sealed record ByokSubscriptionResult(string Sid, string ProductId, string PrimaryKey);

/// <summary>
/// Provisions (idempotent upsert) the per-developer APIM subscription and returns its primary
/// key via listSecrets. Runs as the register UAMI — DefaultAzureCredential picks up the
/// AZURE_CLIENT_ID env var injected by the Container App.
/// </summary>
public interface IApimProvisioner
{
    /// <summary>
    /// Upserts the developer's subscription (sid derived from the immutable <paramref name="objectId"/>,
    /// DisplayName set to <paramref name="userPrincipalName"/>) against <paramref name="productId"/>
    /// and returns its primary key.
    /// </summary>
    Task<ByokSubscriptionResult> EnsureSubscriptionAsync(string objectId, string userPrincipalName, string productId, CancellationToken ct = default);

    /// <summary>Rotates and returns the developer's new primary key (sid from <paramref name="objectId"/>).</summary>
    Task<string> RegeneratePrimaryKeyAsync(string objectId, CancellationToken ct = default);

    /// <summary>Deletes the caller's own subscription by object ID. Returns false if it did not exist.</summary>
    Task<bool> RevokeByObjectIdAsync(string objectId, CancellationToken ct = default);

    /// <summary>
    /// Offboards another developer by UPN: finds the subscription whose DisplayName matches and
    /// deletes it (the sid is oid-derived, so we cannot compute it from a UPN alone). Returns false
    /// if no matching subscription exists.
    /// </summary>
    Task<bool> RevokeByUpnAsync(string userPrincipalName, CancellationToken ct = default);

    /// <summary>Deterministic subscription id (sid) derived from the immutable object ID (oid).</summary>
    string ComputeSid(string objectId);
}

/// <summary>
/// Cloud-aware (Commercial vs Government) ARM implementation against
/// Azure.ResourceManager.ApiManagement. The sid is derived from the immutable Entra object ID so a
/// UPN rename never orphans the subscription; the DisplayName is set to the UPN because the gateway
/// policy derives <c>developer_upn</c> telemetry from <c>context.Subscription.Name</c> (the DisplayName).
/// </summary>
public sealed class ApimProvisioner : IApimProvisioner
{
    private readonly ByokOptions _options;
    private readonly ArmClient _arm;
    private readonly ResourceIdentifier _apimId;

    public ApimProvisioner(IOptions<ByokOptions> options)
    {
        _options = options.Value;

        var credential = CloudCredentialFactory.Create(_options);

        var armOptions = new ArmClientOptions
        {
            Environment = _options.IsGovernment
                ? ArmEnvironment.AzureGovernment
                : ArmEnvironment.AzurePublicCloud,
        };

        _arm = new ArmClient(credential, _options.SubscriptionId, armOptions);
        _apimId = ApiManagementServiceResource.CreateResourceIdentifier(
            _options.SubscriptionId, _options.ResourceGroup, _options.ApimName);
    }

    public string ComputeSid(string objectId)
    {
        var lower = objectId.Trim().ToLowerInvariant();
        var sb = new StringBuilder("byok-", lower.Length + 5);
        foreach (var c in lower)
        {
            sb.Append(char.IsLetterOrDigit(c) ? c : '-');
        }

        var sid = sb.ToString();
        return sid.Length > 80 ? sid[..80] : sid;
    }

    public async Task<ByokSubscriptionResult> EnsureSubscriptionAsync(
        string objectId, string userPrincipalName, string productId, CancellationToken ct = default)
    {
        var sid = ComputeSid(objectId);
        var subscriptions = _arm.GetApiManagementServiceResource(_apimId).GetApiManagementSubscriptions();

        var content = new ApiManagementSubscriptionCreateOrUpdateContent
        {
            Scope = $"{_apimId}/products/{productId}",
            DisplayName = userPrincipalName,
            State = SubscriptionState.Active,
        };

        var operation = await subscriptions.CreateOrUpdateAsync(WaitUntil.Completed, sid, content, cancellationToken: ct);
        var secrets = await operation.Value.GetSecretsAsync(ct);
        return new ByokSubscriptionResult(sid, productId, secrets.Value.PrimaryKey);
    }

    public async Task<string> RegeneratePrimaryKeyAsync(string objectId, CancellationToken ct = default)
    {
        var subscription = GetSubscriptionResource(objectId);
        await subscription.RegeneratePrimaryKeyAsync(ct);
        var secrets = await subscription.GetSecretsAsync(ct);
        return secrets.Value.PrimaryKey;
    }

    public async Task<bool> RevokeByObjectIdAsync(string objectId, CancellationToken ct = default)
    {
        var sid = ComputeSid(objectId);
        var subscriptions = _arm.GetApiManagementServiceResource(_apimId).GetApiManagementSubscriptions();
        if (!await subscriptions.ExistsAsync(sid, cancellationToken: ct))
        {
            return false;
        }

        var subscription = await subscriptions.GetAsync(sid, ct);
        await subscription.Value.DeleteAsync(WaitUntil.Completed, ETag.All, ct);
        return true;
    }

    public async Task<bool> RevokeByUpnAsync(string userPrincipalName, CancellationToken ct = default)
    {
        var subscriptions = _arm.GetApiManagementServiceResource(_apimId).GetApiManagementSubscriptions();
        await foreach (var subscription in subscriptions.GetAllAsync(cancellationToken: ct))
        {
            if (string.Equals(subscription.Data.DisplayName, userPrincipalName, StringComparison.OrdinalIgnoreCase))
            {
                await subscription.DeleteAsync(WaitUntil.Completed, ETag.All, ct);
                return true;
            }
        }

        return false;
    }

    private ApiManagementSubscriptionResource GetSubscriptionResource(string objectId)
    {
        var sid = ComputeSid(objectId);
        var id = ApiManagementSubscriptionResource.CreateResourceIdentifier(
            _options.SubscriptionId, _options.ResourceGroup, _options.ApimName, sid);
        return _arm.GetApiManagementSubscriptionResource(id);
    }
}
