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

    /// <summary>Entra authority host (login.microsoftonline.com / .us). Used to build the
    /// end-session URL for sign-out; blank falls back to plain Easy Auth logout.</summary>
    public string EntraLoginHost { get; set; } = "";

    /// <summary>Client ID of the user-assigned managed identity the app runs as.</summary>
    public string UamiClientId { get; set; } = "";

    /// <summary>Product a developer gets when no TierMap entry matches (least-privileged tier).</summary>
    public string DefaultProductId { get; set; } = "byok-standard";

    /// <summary>Entra group object ID whose members may offboard (revoke) other developers.</summary>
    public string AdminGroupId { get; set; } = "";

    /// <summary>
    /// Minutes of inactivity before the page wipes the displayed key and redirects to Easy Auth
    /// logout (#136). This is UX, not enforcement - it runs in the browser. The server-side backstop
    /// is the authConfig cookie expiration. Note that expiry forces a new sign-in, which on a device
    /// holding an Entra Primary Refresh Token can complete without the user typing anything.
    /// 0 disables the idle timer.
    /// </summary>
    public int SessionIdleTimeoutMinutes { get; set; } = 15;

    /// <summary>
    /// Microsoft Graph base URL for the group-overage fallback. Optional: when blank it is derived
    /// from <see cref="CloudEnv"/> (graph.microsoft.com / graph.microsoft.us). Override for DoD
    /// (dod-graph.microsoft.us) or sovereign clouds.
    /// </summary>
    public string GraphHost { get; set; } = "";

    /// <summary>Ordered group-to-product mappings; first matching group wins.</summary>
    public List<TierMapping> TierMap { get; set; } = new();

    /// <summary>Auto-route sentinel model id offered to VS Code. Blank omits it.</summary>
    public string AutoModelId { get; set; } = "auto";

    /// <summary>Comma-separated commercial-only model ids (the gateway's commercialModels sentinel).
    /// Blank when the commercial backend is not deployed - listing them elsewhere would put models
    /// in the picker that can never resolve.</summary>
    public string CommercialModels { get; set; } = "";

    /// <summary>Commercial model ids as a trimmed list.</summary>
    public IEnumerable<string> CommercialModelList =>
        (CommercialModels ?? "")
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(m => m.Length > 0);

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
