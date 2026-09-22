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

// ARM/APIM failures on the /api surface become ProblemDetails instead of the Blazor HTML error
// page or a raw 500 carrying Azure's error text (#88).
builder.Services.AddProblemDetails();
builder.Services.AddExceptionHandler<ApiExceptionHandler>();

var app = builder.Build();

// The API needs its exception handler in EVERY environment; only the HTML error page is
// environment-specific (in development Blazor shows the developer exception page instead).
if (app.Environment.IsDevelopment())
{
    app.UseExceptionHandler(_ => { });
}
else
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
