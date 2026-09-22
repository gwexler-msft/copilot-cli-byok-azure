using System.Text.Json.Nodes;
using Byok.Register.Services;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;
using Xunit;

namespace Byok.Register.Tests;

public class ConfigRendererTests
{
    private const string Host = "gw.example.us";
    private const string Key = "test-subscription-key";

    private static ConfigRenderer Renderer(string? commercialModels = null, string? autoModelId = null)
    {
        var opts = new ByokOptions();
        if (commercialModels is not null) { opts.CommercialModels = commercialModels; }
        if (autoModelId is not null) { opts.AutoModelId = autoModelId; }
        return new ConfigRenderer(new TestEnv(), Options.Create(opts));
    }

    private static JsonArray Render(ConfigRenderer r) =>
        JsonNode.Parse(r.RenderChatLanguageModels(Host, Key))!.AsArray();

    private static IEnumerable<string?> ChatModelIds(JsonArray providers) =>
        providers.FirstOrDefault(p => (string?)p!["apiType"] == "chat-completions")?["models"]?
            .AsArray().Select(m => (string?)m!["id"]) ?? [];

    private static IEnumerable<string?> ResponseModelIds(JsonArray providers) =>
        providers.First(p => (string?)p!["apiType"] == "responses")!["models"]!
            .AsArray().Select(m => (string?)m!["id"]);

    // Regression: serializing through JsonNode with the default encoder escaped '<' and '>' to
    // \u003C/\u003E, so the placeholder replacements silently matched nothing and every developer
    // downloaded an unfilled template.
    [Fact]
    public void RenderChatLanguageModels_SubstitutesEveryPlaceholder()
    {
        var json = Renderer().RenderChatLanguageModels(Host, Key);

        Assert.DoesNotContain("<APIM_HOSTNAME>", json);
        Assert.DoesNotContain("<APIM_SUBSCRIPTION_KEY>", json);
        Assert.DoesNotContain("\\u003C", json);
        Assert.Contains(Host, json);
        Assert.Contains(Key, json);
    }

    // #129: the key must be INLINE. VS Code's documented "apiKey": "${input:...}" form does not
    // resolve in chatLanguageModels.json - verified 2026-08-07 against gov-pilot: no prompt was
    // shown, VS Code sent the literal token and APIM rejected it as an invalid subscription key.
    // Anything that reintroduces an unresolved ${...} here ships a config that cannot authenticate.
    [Fact]
    public void RenderChatLanguageModels_InlinesTheKeyAndLeavesNoUnresolvedVariable()
    {
        var json = Renderer("gpt-5.6-luna").RenderChatLanguageModels(Host, Key);
        var providers = JsonNode.Parse(json)!.AsArray();

        Assert.NotEmpty(providers);
        foreach (var p in providers)
        {
            Assert.Equal(Key, (string?)p!["apiKey"]);
        }
        Assert.DoesNotContain("${input:", json);
    }

    [Fact]
    public void RenderChatLanguageModels_ProducesValidJson()
    {
        Assert.NotNull(JsonNode.Parse(Renderer().RenderChatLanguageModels(Host, Key)));
    }

    [Fact]
    public void AutoModel_IsOfferedFirst()
    {
        Assert.Equal("auto", ResponseModelIds(Render(Renderer())).First());
    }

    [Fact]
    public void AutoModel_OmittedWhenNotConfigured()
    {
        Assert.DoesNotContain("auto", ResponseModelIds(Render(Renderer(autoModelId: ""))));
    }

    // GPT-5.6 rejects reasoning plus function tools on Chat Completions. VS Code agent requests
    // always carry tools, so these models must use the Responses provider.
    [Fact]
    public void Gpt56Models_UseResponsesProvider()
    {
        var providers = Render(Renderer("gpt-5.6-luna,gpt-5-mini"));
        var responseModels = providers.First(p => (string?)p!["apiType"] == "responses")!["models"]!.AsArray();
        var gpt56 = responseModels.First(m => (string?)m!["id"] == "gpt-5.6-luna")!;

        Assert.Contains("gpt-5.6-luna", ResponseModelIds(providers));
        Assert.DoesNotContain("gpt-5.6-luna", ChatModelIds(providers));
        Assert.Contains("gpt-5-mini", ChatModelIds(providers));
        Assert.Single(ResponseModelIds(providers), id =>
            string.Equals(id, "gpt-5.6-luna", StringComparison.OrdinalIgnoreCase));
        Assert.Contains("/v1/responses", (string?)gpt56["url"]);
        Assert.True((bool?)gpt56["thinking"]);
        Assert.Equal("responses", (string?)gpt56["reasoningEffortFormat"]);
        Assert.Equal(
            ["none", "low", "medium", "high", "xhigh", "max"],
            gpt56["supportsReasoningEffort"]!.AsArray().Select(effort => (string?)effort));
    }

    [Fact]
    public void CommercialModels_AreTrimmedAndDeduped()
    {
        var ids = ResponseModelIds(Render(Renderer(" gpt-5.6-luna , , GPT-5.6-LUNA "))).ToList();

        Assert.Contains("gpt-5.6-luna", ids);
        Assert.Equal(ids.Count, ids.Distinct(StringComparer.OrdinalIgnoreCase).Count());
        Assert.DoesNotContain("", ids);
    }

    // The auto sentinel can resolve to either tier, so it must advertise the smaller context window
    // or VS Code will send a prompt that overflows whichever tier the router picks.
    [Fact]
    public void AutoModel_AdvertisesConservativeContextWindow()
    {
        var auto = Render(Renderer()).First(p => (string?)p!["apiType"] == "responses")!["models"]!
            .AsArray().First(m => (string?)m!["id"] == "auto");

        Assert.Equal(1050000, (int)auto!["maxInputTokens"]!);
    }

    [Fact]
    public void RenderInstaller_SubstitutesEveryToken()
    {
        foreach (var os in new[] { "win", "linux" })
        {
            var script = Renderer("gpt-5.6-luna").RenderInstaller(os, Host, Key, $"https://{Host}/openai");

            Assert.DoesNotMatch("@@[A-Z_]+@@", script);
            Assert.Contains(Host, script);
            Assert.Contains(Key, script);
        }
    }

    // Without COPILOT_MODEL the CLI refuses to start with "BYOK providers require an explicit model".
    [Fact]
    public void RenderInstaller_SetsCopilotModel()
    {
        foreach (var os in new[] { "win", "linux" })
        {
            Assert.Contains("COPILOT_MODEL", Renderer().RenderInstaller(os, Host, Key, $"https://{Host}/openai"));
        }
    }

    [Fact]
    public void RenderInstaller_DefaultsCliToSolOverResponses()
    {
        foreach (var os in new[] { "win", "linux" })
        {
            var script = Renderer().RenderInstaller(os, Host, Key, $"https://{Host}/openai");
            Assert.Contains("gpt-5.6-sol", script);
            Assert.Contains("COPILOT_PROVIDER_WIRE_API", script);
            Assert.Contains("responses", script);
        }
    }

    // A non-ASCII byte that survives the download but not the decode is how these scripts broke on a
    // stock Windows VM.
    [Fact]
    public void RenderInstaller_IsAscii()
    {
        foreach (var os in new[] { "win", "linux" })
        {
            var script = Renderer().RenderInstaller(os, Host, Key, $"https://{Host}/openai");
            Assert.DoesNotContain(script, c => c > 127);
        }
    }

    private sealed class TestEnv : IHostEnvironment
    {
        public string EnvironmentName { get; set; } = "Test";
        public string ApplicationName { get; set; } = "register.Tests";
        public string ContentRootPath { get; set; } = AppContext.BaseDirectory;
        public Microsoft.Extensions.FileProviders.IFileProvider ContentRootFileProvider { get; set; } =
            new Microsoft.Extensions.FileProviders.NullFileProvider();
    }
}
