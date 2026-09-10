using Microsoft.Extensions.Options;

namespace Byok.Register.Services;

/// <summary>
/// Maps the caller's Entra group object IDs to a BYOK APIM product/tier, falling back to the
/// least-privileged default product when no mapping matches (#67). The TierMap and default are
/// config-driven (<see cref="ByokOptions"/>) so group object IDs drop in per environment with
/// no code change.
/// </summary>
public sealed class TierResolver
{
    private readonly ByokOptions _options;

    public TierResolver(IOptions<ByokOptions> options) => _options = options.Value;

    /// <summary>First matching TierMap group wins; otherwise the default product.</summary>
    public string ResolveProductId(IReadOnlyList<string> groupIds)
    {
        foreach (var mapping in _options.TierMap)
        {
            if (string.IsNullOrWhiteSpace(mapping.GroupId) || string.IsNullOrWhiteSpace(mapping.ProductId))
            {
                continue;
            }

            if (groupIds.Contains(mapping.GroupId, StringComparer.OrdinalIgnoreCase))
            {
                return mapping.ProductId;
            }
        }

        return _options.DefaultProductId;
    }

    /// <summary>True when an AdminGroupId is configured and the caller is a member.</summary>
    public bool IsAdmin(IReadOnlyList<string> groupIds) =>
        !string.IsNullOrWhiteSpace(_options.AdminGroupId)
        && groupIds.Contains(_options.AdminGroupId, StringComparer.OrdinalIgnoreCase);
}
