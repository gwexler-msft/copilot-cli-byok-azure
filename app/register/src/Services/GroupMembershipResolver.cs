using Microsoft.Extensions.Logging;

namespace Byok.Register.Services;

/// <summary>
/// Returns the caller's effective group object IDs for tier/admin decisions: the inline Easy Auth
/// <c>groups</c> claim normally, or a Microsoft Graph lookup when the token signalled overage
/// (#67). Graph failures degrade gracefully to the (possibly empty) claim groups so a Graph outage
/// can never escalate a tier — it only ever falls back to the least-privileged default.
/// </summary>
public sealed class GroupMembershipResolver
{
    private readonly IdentityContext _identity;
    private readonly IGroupOverageResolver _overage;
    private readonly ILogger<GroupMembershipResolver> _logger;

    public GroupMembershipResolver(
        IdentityContext identity,
        IGroupOverageResolver overage,
        ILogger<GroupMembershipResolver> logger)
    {
        _identity = identity;
        _overage = overage;
        _logger = logger;
    }

    public async Task<IReadOnlyList<string>> GetEffectiveGroupIdsAsync(CancellationToken ct = default)
    {
        if (!_identity.HasGroupOverage || string.IsNullOrEmpty(_identity.ObjectId))
        {
            return _identity.GroupIds;
        }

        try
        {
            return await _overage.GetGroupIdsAsync(_identity.ObjectId, ct);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(
                ex,
                "Graph group-overage resolution failed for oid {ObjectId}; falling back to claim groups.",
                _identity.ObjectId);
            return _identity.GroupIds;
        }
    }
}
