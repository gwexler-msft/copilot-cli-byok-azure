using Byok.Register.Services;
using Microsoft.Extensions.Options;

namespace Byok.Register.Endpoints;

/// <summary>
/// Minimal-API surface for the register app. M2 (#65/#67/#72) implements the privileged
/// provisioning routes (register / regenerate / revoke); M3 (#69/#70) adds the per-developer
/// config rendering (/api/config) and cross-platform installer (/api/installer).
/// </summary>
public static class ConfigEndpoints
{
    public static IEndpointRouteBuilder MapConfigEndpoints(this IEndpointRouteBuilder app)
    {
        // Liveness/readiness probe target for ACA ingress.
        app.MapGet("/healthz", () => Results.Ok(new { status = "ok" }));

        // Provision (or reuse) the caller's per-dev APIM subscription. M2 (#65/#67).
        app.MapPost("/api/register", async (
            IdentityContext identity,
            GroupMembershipResolver groups,
            TierResolver tiers,
            IApimProvisioner provisioner,
            IOptions<ByokOptions> options,
            CancellationToken ct) =>
        {
            if (!TryResolveCaller(identity, out var objectId, out var upn))
            {
                return Results.Unauthorized();
            }

            var groupIds = await groups.GetEffectiveGroupIdsAsync(ct);
            var productId = tiers.ResolveProductId(groupIds);
            var result = await provisioner.EnsureSubscriptionAsync(
                objectId, upn, productId, ct);

            return Results.Ok(new
            {
                sid = result.Sid,
                productId = result.ProductId,
                primaryKey = result.PrimaryKey,
                baseUrl = $"{options.Value.ApimGatewayUrl.TrimEnd('/')}/openai",
            });
        });

        // Return the caller's BYOK config (chatLanguageModels.json). M3 (#69/#70).
        app.MapGet("/api/config", async (
            IdentityContext identity,
            GroupMembershipResolver groups,
            TierResolver tiers,
            IApimProvisioner provisioner,
            ConfigRenderer renderer,
            IOptions<ByokOptions> options,
            CancellationToken ct) =>
        {
            if (!TryResolveCaller(identity, out var objectId, out var upn))
            {
                return Results.Unauthorized();
            }

            var groupIds = await groups.GetEffectiveGroupIdsAsync(ct);
            var productId = tiers.ResolveProductId(groupIds);
            var result = await provisioner.EnsureSubscriptionAsync(
                objectId, upn, productId, ct);

            var host = ConfigRenderer.HostFromGatewayUrl(options.Value.ApimGatewayUrl);
            var content = renderer.RenderChatLanguageModels(host, result.PrimaryKey);
            return Results.File(
                System.Text.Encoding.UTF8.GetBytes(content),
                "application/json; charset=utf-8",
                renderer.ChatLanguageModelsFileName);
        });

        // Return the cross-platform local installer script. M3 (#70). ?os=win|mac|linux.
        app.MapGet("/api/installer", async (
            HttpContext http,
            IdentityContext identity,
            GroupMembershipResolver groups,
            TierResolver tiers,
            IApimProvisioner provisioner,
            ConfigRenderer renderer,
            IOptions<ByokOptions> options,
            CancellationToken ct) =>
        {
            if (!TryResolveCaller(identity, out var objectId, out var upn))
            {
                return Results.Unauthorized();
            }

            var os = http.Request.Query["os"].ToString();

            var groupIds = await groups.GetEffectiveGroupIdsAsync(ct);
            var productId = tiers.ResolveProductId(groupIds);
            var result = await provisioner.EnsureSubscriptionAsync(
                objectId, upn, productId, ct);

            var host = ConfigRenderer.HostFromGatewayUrl(options.Value.ApimGatewayUrl);
            var baseUrl = $"{options.Value.ApimGatewayUrl.TrimEnd('/')}/openai";
            var content = renderer.RenderInstaller(os, host, result.PrimaryKey, baseUrl);
            return Results.File(
                System.Text.Encoding.UTF8.GetBytes(content),
                "text/plain; charset=utf-8",
                ConfigRenderer.InstallerFileName(os));
        });

        // Rotate the caller's subscription key. M2 (#65).
        app.MapPost("/api/regenerate", async (
            IdentityContext identity,
            IApimProvisioner provisioner,
            CancellationToken ct) =>
        {
            if (!TryResolveCaller(identity, out var objectId, out _))
            {
                return Results.Unauthorized();
            }

            var primaryKey = await provisioner.RegeneratePrimaryKeyAsync(objectId, ct);
            return Results.Ok(new { primaryKey });
        });

        // Revoke/offboard a subscription. Self-revoke (by object ID) is always allowed; revoking
        // another developer (?upn=, matched by DisplayName) requires AdminGroup membership. M2 (#72).
        app.MapPost("/api/revoke", async (
            HttpContext http,
            IdentityContext identity,
            GroupMembershipResolver groups,
            TierResolver tiers,
            IApimProvisioner provisioner,
            CancellationToken ct) =>
        {
            if (!TryResolveCaller(identity, out var objectId, out var self))
            {
                return Results.Unauthorized();
            }

            var target = http.Request.Query["upn"].ToString();

            if (string.IsNullOrWhiteSpace(target) || string.Equals(target, self, StringComparison.OrdinalIgnoreCase))
            {
                var revokedSelf = await provisioner.RevokeByObjectIdAsync(objectId, ct);
                return Results.Ok(new { revoked = revokedSelf, upn = self });
            }

            var groupIds = await groups.GetEffectiveGroupIdsAsync(ct);
            if (!tiers.IsAdmin(groupIds))
            {
                return Results.Forbid();
            }

            var revoked = await provisioner.RevokeByUpnAsync(target, ct);
            return Results.Ok(new { revoked, upn = target });
        });

        return app;
    }

    /// <summary>Resolves the caller's object id and UPN together, or fails the request.</summary>
    /// <remarks>
    /// The endpoints used to guard on IsAuthenticated + ObjectId and then pass
    /// <c>UserPrincipalName!</c>. That is safe only because IsAuthenticated happens to be defined
    /// as "UPN is not null" - an invisible coupling that becomes a NullReferenceException the
    /// moment it keys off anything else, such as the oid (#87).
    /// </remarks>
    private static bool TryResolveCaller(IdentityContext identity, out string objectId, out string upn)
    {
        objectId = identity.ObjectId ?? string.Empty;
        upn = identity.UserPrincipalName ?? string.Empty;
        return identity.IsAuthenticated && objectId.Length > 0 && upn.Length > 0;
    }
}
