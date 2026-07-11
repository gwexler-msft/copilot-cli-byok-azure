using Byok.Register.Components;
using Byok.Register.Endpoints;
using Byok.Register.Services;

var builder = WebApplication.CreateBuilder(args);

// Blazor Web App with interactive server rendering (privileged work stays server-side).
builder.Services.AddRazorComponents()
    .AddInteractiveServerComponents();

// Expose the current request to IdentityContext for Easy Auth principal-header parsing.
builder.Services.AddHttpContextAccessor();

// Strongly-typed config (Byok__* env vars + appsettings "Byok" section).
builder.Services.Configure<ByokOptions>(builder.Configuration.GetSection(ByokOptions.SectionName));

// Register-app services.
builder.Services.AddSingleton<TierResolver>();
builder.Services.AddSingleton<ConfigRenderer>();
builder.Services.AddScoped<IdentityContext>();
builder.Services.AddSingleton<IApimProvisioner, ApimProvisioner>();

// Microsoft Graph group-overage fallback (#67): typed HttpClient + per-request resolver that
// prefers the inline groups claim and only calls Graph when the token signalled overage.
builder.Services.AddHttpClient<IGroupOverageResolver, GraphGroupResolver>();
builder.Services.AddScoped<GroupMembershipResolver>();

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error", createScopeForErrors: true);
    app.UseHsts();
}

app.UseStaticFiles();
app.UseAntiforgery();

// Minimal-API surface (/healthz + /api/*). Bodies are M2/M3 placeholders for now.
app.MapConfigEndpoints();

app.MapRazorComponents<App>()
    .AddInteractiveServerRenderMode();

app.Run();
