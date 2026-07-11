# BYOK self-serve register app

Self-serve developer onboarding for the Copilot CLI / VS Code BYOK gateway (issue #64).
A Blazor Web App (.NET 10) that, once complete, lets a developer sign in with Entra, get a
per-developer APIM subscription auto-provisioned, and download a local installer that writes
their VS Code + Copilot CLI BYOK config to disk.

## Status — M1 (infra + hosting skeleton)

This milestone ships only the deployable skeleton:

- External Azure Container Apps environment + Container App fronted by Entra Easy Auth
  (`infra/modules/register-app.bicep`).
- A least-privilege user-assigned managed identity + custom APIM role
  (`infra/modules/apim-register-role.bicep`): APIM subscription CRUD + key actions +
  product read only.
- A Blazor placeholder page and the minimal-API route contract (`/healthz`, `/api/*`),
  with the privileged bodies stubbed for later milestones.

Subsequent milestones:

- **M2** — backend: per-dev APIM subscription provisioning (#65), tier gating (#67),
  offboarding (#72).
- **M3** — frontend + three-artifact local config installer (#69, #70).
- **M4** — docs + rollout (#71).

## Layout

```
app/register/
  Dockerfile            # .NET 10 multi-stage build, Kestrel on :8080
  src/
    register.csproj
    Program.cs          # Blazor Web App + minimal-API wiring
    appsettings.json
    Components/          # App/Routes/Layout/Pages (Blazor)
    Endpoints/           # ConfigEndpoints.cs (route contract)
    Services/            # IdentityContext, ApimProvisioner, TierResolver, ConfigRenderer
    wwwroot/             # static assets
```

## Build / run locally

```pwsh
dotnet build app/register/src/register.csproj
dotnet run --project app/register/src/register.csproj
```

## Deploy

Provisioned behind the `deployRegisterApp` flag in `infra/main.bicep` and the `register`
service in `azure.yaml`:

```pwsh
azd provision --parameters deployRegisterApp=true
azd deploy register
```

The first provision uses a placeholder image (`mcr.microsoft.com/dotnet/samples:aspnetapp`,
port 8080) so hosting comes up before the Entra app registration exists; supply
`registerEasyAuthClientId` / `registerEasyAuthClientSecret` on a later provision to turn on
the login redirect, then `azd deploy register` to push this image.
