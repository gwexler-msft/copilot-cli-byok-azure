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
            if (!identity.IsAuthenticated || string.IsNullOrEmpty(identity.ObjectId))
            {
                return Results.Unauthorized();
            }

            var groupIds = await groups.GetEffectiveGroupIdsAsync(ct);
            var productId = tiers.ResolveProductId(groupIds);
            var result = await provisioner.EnsureSubscriptionAsync(
                identity.ObjectId, identity.UserPrincipalName!, productId, ct);

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
            if (!identity.IsAuthenticated || string.IsNullOrEmpty(identity.ObjectId))
            {
                return Results.Unauthorized();
            }

            var groupIds = await groups.GetEffectiveGroupIdsAsync(ct);
            var productId = tiers.ResolveProductId(groupIds);
            var result = await provisioner.EnsureSubscriptionAsync(
                identity.ObjectId, identity.UserPrincipalName!, productId, ct);

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
            if (!identity.IsAuthenticated || string.IsNullOrEmpty(identity.ObjectId))
            {
                return Results.Unauthorized();
            }

            var os = http.Request.Query["os"].ToString();

            var groupIds = await groups.GetEffectiveGroupIdsAsync(ct);
            var productId = tiers.ResolveProductId(groupIds);
            var result = await provisioner.EnsureSubscriptionAsync(
                identity.ObjectId, identity.UserPrincipalName!, productId, ct);

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
            if (!identity.IsAuthenticated || string.IsNullOrEmpty(identity.ObjectId))
            {
                return Results.Unauthorized();
            }

            var primaryKey = await provisioner.RegeneratePrimaryKeyAsync(identity.ObjectId, ct);
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
            if (!identity.IsAuthenticated || string.IsNullOrEmpty(identity.ObjectId))
            {
                return Results.Unauthorized();
            }

            var self = identity.UserPrincipalName!;
            var target = http.Request.Query["upn"].ToString();

            if (string.IsNullOrWhiteSpace(target) || string.Equals(target, self, StringComparison.OrdinalIgnoreCase))
            {
                var revokedSelf = await provisioner.RevokeByObjectIdAsync(identity.ObjectId, ct);
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
}
