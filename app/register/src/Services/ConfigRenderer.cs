using Microsoft.Extensions.Hosting;

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
    /// <summary>VS Code model name the utility-model settings point at (the BYOK Foundry mini).</summary>
    public const string MiniModelName = "BYOK gpt-4.1-mini";

    private const string HostToken = "<APIM_HOSTNAME>";
    private const string KeyToken = "<APIM_SUBSCRIPTION_KEY>";

    private readonly string _installersDir;

    public ConfigRenderer(IHostEnvironment env)
    {
        _installersDir = Path.Combine(env.ContentRootPath, "Installers");
    }

    /// <summary>File name VS Code expects for the rendered model config.</summary>
    public string ChatLanguageModelsFileName => "chatLanguageModels.json";

    /// <summary>Render the chatLanguageModels.json content for this developer (host + key inlined).</summary>
    public string RenderChatLanguageModels(string apimHost, string key)
    {
        var template = File.ReadAllText(Path.Combine(_installersDir, "chatLanguageModels.foundry.json"));
        return template.Replace(HostToken, apimHost).Replace(KeyToken, key);
    }

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
