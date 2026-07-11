namespace Byok.Register.Services;

/// <summary>
/// Strongly-typed configuration for the register app, bound from the "Byok" section.
/// Infra (register-app.bicep) injects the runtime values as <c>Byok__*</c> environment
/// variables; the Entra group IDs (AdminGroupId / TierMap) are supplied per-environment
/// via appsettings or env and can be filled in after the app is deployed.
/// </summary>
public sealed class ByokOptions
{
    public const string SectionName = "Byok";

    /// <summary>AzureCloud or AzureUSGovernment. Selects the ARM + Entra authority hosts.</summary>
    public string CloudEnv { get; set; } = "AzureCloud";

    public string SubscriptionId { get; set; } = "";
    public string ResourceGroup { get; set; } = "";
    public string ApimName { get; set; } = "";
    public string ApimGatewayUrl { get; set; } = "";
    public string TenantId { get; set; } = "";

    /// <summary>Client ID of the user-assigned managed identity the app runs as.</summary>
    public string UamiClientId { get; set; } = "";

    /// <summary>Product a developer gets when no TierMap entry matches (least-privileged tier).</summary>
    public string DefaultProductId { get; set; } = "byok-standard";

    /// <summary>Entra group object ID whose members may offboard (revoke) other developers.</summary>
    public string AdminGroupId { get; set; } = "";

    /// <summary>
    /// Microsoft Graph base URL for the group-overage fallback. Optional: when blank it is derived
    /// from <see cref="CloudEnv"/> (graph.microsoft.com / graph.microsoft.us). Override for DoD
    /// (dod-graph.microsoft.us) or sovereign clouds.
    /// </summary>
    public string GraphHost { get; set; } = "";

    /// <summary>Ordered group-to-product mappings; first matching group wins.</summary>
    public List<TierMapping> TierMap { get; set; } = new();

    public bool IsGovernment =>
        string.Equals(CloudEnv, "AzureUSGovernment", StringComparison.OrdinalIgnoreCase);

    /// <summary>Effective Graph base URL (explicit override, else cloud default), no trailing slash.</summary>
    public string EffectiveGraphHost =>
        string.IsNullOrWhiteSpace(GraphHost)
            ? (IsGovernment ? "https://graph.microsoft.us" : "https://graph.microsoft.com")
            : GraphHost.TrimEnd('/');
}

public sealed class TierMapping
{
    /// <summary>Entra group object ID (GUID).</summary>
    public string GroupId { get; set; } = "";

    /// <summary>APIM product ID the group maps to (e.g. byok-power).</summary>
    public string ProductId { get; set; } = "";
}
