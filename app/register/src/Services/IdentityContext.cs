using System.Text;
using System.Text.Json;

namespace Byok.Register.Services;

/// <summary>
/// Resolves the caller's identity (UPN) and Entra group object IDs from the Easy Auth injected
/// principal headers (X-MS-CLIENT-PRINCIPAL-NAME / X-MS-CLIENT-PRINCIPAL) on the current request
/// (#72). All privileged decisions (tier, offboarding) key off this. Scoped per request; lazily
/// parses on first access.
/// </summary>
public sealed class IdentityContext
{
    private const string PrincipalNameHeader = "X-MS-CLIENT-PRINCIPAL-NAME";
    private const string PrincipalHeader = "X-MS-CLIENT-PRINCIPAL";

    private static readonly string[] UpnClaimTypes =
    {
        "preferred_username",
        "upn",
        "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn",
        "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress",
    };

    private static readonly string[] ObjectIdClaimTypes =
    {
        "oid",
        "http://schemas.microsoft.com/identity/claims/objectidentifier",
    };

    // Entra emits these instead of an inline `groups` claim when the user exceeds the per-token
    // group cap (~200 for JWT). Their presence -> resolve groups via Microsoft Graph.
    private static readonly string[] GroupOverageClaimTypes =
    {
        "_claim_names",
        "hasgroups",
        "http://schemas.microsoft.com/claims/groups.link",
    };

    private readonly IHttpContextAccessor _http;
    private bool _parsed;
    private string? _upn;
    private string? _oid;
    private bool _groupOverage;
    private List<string> _groups = new();

    public IdentityContext(IHttpContextAccessor http) => _http = http;

    public string? UserPrincipalName
    {
        get
        {
            EnsureParsed();
            return _upn;
        }
    }

    /// <summary>Immutable Entra object ID (oid). Drives the deterministic subscription sid.</summary>
    public string? ObjectId
    {
        get
        {
            EnsureParsed();
            return _oid;
        }
    }

    public IReadOnlyList<string> GroupIds
    {
        get
        {
            EnsureParsed();
            return _groups;
        }
    }

    /// <summary>
    /// True when the token omitted the inline <c>groups</c> claim due to overage; callers should
    /// resolve group membership via Microsoft Graph rather than trusting <see cref="GroupIds"/>.
    /// </summary>
    public bool HasGroupOverage
    {
        get
        {
            EnsureParsed();
            return _groupOverage;
        }
    }

    public bool IsAuthenticated => UserPrincipalName is not null;

    private void EnsureParsed()
    {
        if (_parsed)
        {
            return;
        }

        _parsed = true;

        var ctx = _http.HttpContext;
        if (ctx is null)
        {
            return;
        }

        var headers = ctx.Request.Headers;
        _upn = NullIfEmpty(headers[PrincipalNameHeader].ToString());

        var encoded = NullIfEmpty(headers[PrincipalHeader].ToString());
        if (encoded is null)
        {
            return;
        }

        try
        {
            var json = Encoding.UTF8.GetString(Convert.FromBase64String(encoded));
            using var doc = JsonDocument.Parse(json);

            if (!doc.RootElement.TryGetProperty("claims", out var claims) ||
                claims.ValueKind != JsonValueKind.Array)
            {
                return;
            }

            foreach (var claim in claims.EnumerateArray())
            {
                var typ = claim.TryGetProperty("typ", out var t) ? t.GetString() : null;
                var val = claim.TryGetProperty("val", out var v) ? v.GetString() : null;
                if (typ is null || string.IsNullOrEmpty(val))
                {
                    continue;
                }

                if (string.Equals(typ, "groups", StringComparison.OrdinalIgnoreCase))
                {
                    _groups.Add(val);
                }
                else if (_oid is null && ObjectIdClaimTypes.Contains(typ, StringComparer.OrdinalIgnoreCase))
                {
                    _oid = val;
                }
                else if (!_groupOverage && GroupOverageClaimTypes.Contains(typ, StringComparer.OrdinalIgnoreCase))
                {
                    _groupOverage = true;
                }
                else if (_upn is null && UpnClaimTypes.Contains(typ, StringComparer.OrdinalIgnoreCase))
                {
                    _upn = val;
                }
            }

            // Inline groups win; only treat as overage when no groups were emitted in the token.
            if (_groups.Count > 0)
            {
                _groupOverage = false;
            }
        }
        catch (Exception ex) when (ex is FormatException or JsonException)
        {
            // Malformed principal header -> treat as anonymous rather than failing the request.
        }
    }

    private static string? NullIfEmpty(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value;
}
