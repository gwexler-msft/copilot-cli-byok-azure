using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Byok.Register.Services;

/// <summary>
/// Renders the per-developer local artifacts from the templates under <c>Installers/</c>:
///   1. VS Code <c>chatLanguageModels.json</c> (BYOK provider blocks),
///   2. the cross-platform installer (<c>Use-Byok.ps1</c> / <c>use-byok.sh</c>) that merges
///      that JSON, the <c>settings.json</c> utility-model + telemetry/call-home lockdown keys,
///      and the Copilot CLI <c>COPILOT_PROVIDER_*</c> User-scope environment variables in place.
///
/// CRITICAL: the installer NEVER sets <c>COPILOT_OFFLINE</c> — that kills BYOK's identity/token
/// call. Privacy is enforced at the network layer (see docs/github-egress-allowlist.md).
/// </summary>
public sealed class ConfigRenderer
{
    /// <summary>VS Code model name the utility-model settings point at (the BYOK Foundry cheap tier).</summary>
    public const string MiniModelName = "BYOK gpt-5.6-luna";

    /// <summary>COPILOT_MODEL for the CLI. BYOK providers reject an unset model, so this must always
    /// be written. Sol is the default; developers can opt into the gateway's auto sentinel.</summary>
    public const string CliModelName = "gpt-5.6-sol";

    private const string HostToken = "<APIM_HOSTNAME>";

    /// <summary>
    /// The key is inlined. VS Code's documented `"apiKey": "${input:...}"` form does NOT resolve in
    /// chatLanguageModels.json - tested 2026-08-07 on gov-pilot, VS Code sent the literal string and
    /// APIM rejected it, with no prompt shown (#129). Secret storage still WINS over this value when
    /// it holds one, so the register UI tells the developer to set it via the gear icon whenever the
    /// provider has been configured before.
    /// </summary>
    private const string KeyToken = "<APIM_SUBSCRIPTION_KEY>";

    /// <summary>Context window advertised for models whose real limit is not known here. The auto
    /// sentinel can resolve to either tier, so it must advertise the SMALLER one or VS Code will
    /// happily send a prompt that overflows whichever tier the router picks.</summary>
    private const int ConservativeMaxInputTokens = 1050000;
    private const int DefaultMaxOutputTokens = 128000;

    private readonly string _installersDir;
    private readonly ByokOptions _opts;

    public ConfigRenderer(IHostEnvironment env, IOptions<ByokOptions> opts)
    {
        _installersDir = Path.Combine(env.ContentRootPath, "Installers");
        _opts = opts.Value;
    }

    /// <summary>File name VS Code expects for the rendered model config.</summary>
    public string ChatLanguageModelsFileName => "chatLanguageModels.json";

    /// <summary>Render the chatLanguageModels.json content for this developer (host + key inlined).</summary>
    public string RenderChatLanguageModels(string apimHost, string key)
    {
        var template = File.ReadAllText(Path.Combine(_installersDir, "chatLanguageModels.foundry.json"));
        var providers = JsonNode.Parse(template)!.AsArray();
        AddGatewayModels(providers);
        var json = providers.ToJsonString(SerializerOptions);
        return json.Replace(HostToken, apimHost).Replace(KeyToken, key);
    }

    /// <summary>
    /// The relaxed encoder is REQUIRED, not cosmetic: the default one escapes '&lt;' and '&gt;' to
    /// \u003C/\u003E, which silently breaks the &lt;APIM_HOSTNAME&gt; / &lt;APIM_SUBSCRIPTION_KEY&gt;
    /// substitution below and ships an unfilled template to the developer.
    /// </summary>
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// <summary>
    /// Adds the models the static template cannot know about because they depend on how this
    /// environment was deployed: the auto-route sentinel and any commercial-only models.
    /// </summary>
    private void AddGatewayModels(JsonArray providers)
    {
        var chat = providers
            .FirstOrDefault(p => string.Equals((string?)p?["apiType"], "chat-completions", StringComparison.Ordinal))
            ?["models"]?.AsArray();
        var responses = providers
            .FirstOrDefault(p => string.Equals((string?)p?["apiType"], "responses", StringComparison.Ordinal))
            ?["models"]?.AsArray();
        if (chat is null || responses is null) { return; }

        // Auto goes first so it is the obvious pick in the model list.
        if (!string.IsNullOrWhiteSpace(_opts.AutoModelId))
        {
            responses.Insert(0, ResponseModel(_opts.AutoModelId, $"BYOK {_opts.AutoModelId}"));
        }

        var existingChat = chat
            .Select(m => (string?)m?["id"])
            .Where(id => id is not null)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var existingResponses = responses
            .Select(m => (string?)m?["id"])
            .Where(id => id is not null)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        foreach (var model in _opts.CommercialModelList)
        {
            if (RequiresResponsesForToolCalling(model))
            {
                if (existingResponses.Add(model))
                {
                    responses.Add(ResponseModel(model, $"BYOK {model}"));
                }
            }
            else if (existingChat.Add(model))
            {
                chat.Add(ChatModel(model, $"BYOK {model}"));
            }
        }
    }

    private static bool RequiresResponsesForToolCalling(string id)
    {
        var match = System.Text.RegularExpressions.Regex.Match(
            id,
            @"^gpt-(\d+)\.(\d+)(?:-|$)",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        if (!match.Success ||
            !int.TryParse(match.Groups[1].Value, out var major) ||
            !int.TryParse(match.Groups[2].Value, out var minor))
        {
            return false;
        }

        return major > 5 || (major == 5 && minor >= 6);
    }

    private static JsonObject ChatModel(string id, string name) => new()
    {
        ["id"] = id,
        ["name"] = name,
        ["url"] = $"https://{HostToken}/openai/v1/chat/completions?_vscodeauth=openai.azure",
        ["toolCalling"] = true,
        ["vision"] = false,
        ["streaming"] = true,
        ["maxInputTokens"] = ConservativeMaxInputTokens,
        ["maxOutputTokens"] = DefaultMaxOutputTokens,
        ["zeroDataRetentionEnabled"] = true,
    };

    private static JsonObject ResponseModel(string id, string name) => new()
    {
        ["id"] = id,
        ["name"] = name,
        ["url"] = $"https://{HostToken}/openai/v1/responses?_vscodeauth=openai.azure",
        ["toolCalling"] = true,
        ["vision"] = false,
        ["thinking"] = true,
        ["supportsReasoningEffort"] = new JsonArray(
            JsonValue.Create("none"),
            JsonValue.Create("low"),
            JsonValue.Create("medium"),
            JsonValue.Create("high"),
            JsonValue.Create("xhigh"),
            JsonValue.Create("max")),
        ["reasoningEffortFormat"] = "responses",
        ["streaming"] = true,
        ["maxInputTokens"] = ConservativeMaxInputTokens,
        ["maxOutputTokens"] = DefaultMaxOutputTokens,
        ["zeroDataRetentionEnabled"] = true,
    };

    /// <summary>File name of the installer for the requested OS.</summary>
    public static string InstallerFileName(string os) =>
        IsWindows(os) ? "Use-Byok.ps1" : "use-byok.sh";

    /// <summary>Render the one-shot local installer for the requested OS (host + key inlined).</summary>
    public string RenderInstaller(string os, string apimHost, string key, string baseUrl)
    {
        var templateName = IsWindows(os) ? "Use-Byok.ps1" : "use-byok.sh";
        var template = File.ReadAllText(Path.Combine(_installersDir, templateName));
        var chatModels = RenderChatLanguageModels(apimHost, key);
        return template
            .Replace("@@APIM_HOST@@", apimHost)
            .Replace("@@APIM_KEY@@", key)
            .Replace("@@BASE_URL@@", baseUrl)
            .Replace("@@MINI_MODEL_NAME@@", MiniModelName)
            .Replace("@@CLI_MODEL@@", CliModelName)
            .Replace("@@CHAT_MODELS_JSON@@", chatModels.TrimEnd());
    }

    private static bool IsWindows(string os) =>
        os is "win" or "windows" || string.IsNullOrWhiteSpace(os);

    /// <summary>Extract the bare APIM host from the gateway URL (no scheme, no path).</summary>
    public static string HostFromGatewayUrl(string gatewayUrl)
    {
        if (Uri.TryCreate(gatewayUrl, UriKind.Absolute, out var uri))
        {
            return uri.Host;
        }
        return gatewayUrl.Replace("https://", "").Replace("http://", "").TrimEnd('/');
    }
}
