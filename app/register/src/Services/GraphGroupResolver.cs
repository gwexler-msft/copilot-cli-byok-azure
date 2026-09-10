using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Azure.Core;
using Microsoft.Extensions.Options;

namespace Byok.Register.Services;

/// <summary>
/// Resolves a user's security-group object IDs from Microsoft Graph. Used only when the Easy Auth
/// token omitted the inline <c>groups</c> claim because the user exceeded the per-token group cap
/// (~200 for JWT) — see <see cref="IdentityContext.HasGroupOverage"/>.
/// </summary>
public interface IGroupOverageResolver
{
    Task<IReadOnlyList<string>> GetGroupIdsAsync(string objectId, CancellationToken ct = default);
}

/// <summary>
/// Cloud-aware (graph.microsoft.com / graph.microsoft.us) implementation calling
/// <c>POST /users/{id}/getMemberGroups</c>, which returns transitive security-group membership.
/// Requires the register UAMI to hold a Graph app permission (GroupMember.Read.All or
/// Directory.Read.All) with admin consent.
/// </summary>
public sealed class GraphGroupResolver : IGroupOverageResolver
{
    private readonly HttpClient _http;
    private readonly TokenCredential _credential;
    private readonly string _graphHost;
    private readonly string[] _scopes;

    public GraphGroupResolver(HttpClient http, IOptions<ByokOptions> options)
    {
        _http = http;
        var o = options.Value;
        _graphHost = o.EffectiveGraphHost;
        _scopes = new[] { $"{_graphHost}/.default" };
        _credential = CloudCredentialFactory.Create(o);
    }

    public async Task<IReadOnlyList<string>> GetGroupIdsAsync(string objectId, CancellationToken ct = default)
    {
        var token = await _credential.GetTokenAsync(new TokenRequestContext(_scopes), ct);

        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            $"{_graphHost}/v1.0/users/{Uri.EscapeDataString(objectId)}/getMemberGroups")
        {
            // securityEnabledOnly limits results to security groups (what tier gating maps on).
            Content = JsonContent.Create(new { securityEnabledOnly = true }),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);

        var ids = new List<string>();
        var response = await _http.SendAsync(request, ct);
        response.EnsureSuccessStatusCode();
        var nextLink = AppendPage(ids, await response.Content.ReadAsStringAsync(ct));

        // getMemberGroups pages via @odata.nextLink, followed with GET (no body).
        while (nextLink is not null)
        {
            using var pageRequest = new HttpRequestMessage(HttpMethod.Get, nextLink);
            pageRequest.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
            var page = await _http.SendAsync(pageRequest, ct);
            page.EnsureSuccessStatusCode();
            nextLink = AppendPage(ids, await page.Content.ReadAsStringAsync(ct));
        }

        return ids;
    }

    private static string? AppendPage(List<string> ids, string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        if (root.TryGetProperty("value", out var value) && value.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in value.EnumerateArray())
            {
                var id = item.GetString();
                if (!string.IsNullOrEmpty(id))
                {
                    ids.Add(id);
                }
            }
        }

        return root.TryGetProperty("@odata.nextLink", out var next) ? next.GetString() : null;
    }
}
