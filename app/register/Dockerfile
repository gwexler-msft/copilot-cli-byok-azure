# Multi-stage build for the BYOK self-serve register app (Blazor Web App, .NET 10).
# The ACA ingress targetPort is 8080 (see infra/modules/register-app.bicep); Kestrel is
# bound there explicitly via ASPNETCORE_HTTP_PORTS so it matches both the placeholder
# provision image and this real image.

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY src/register.csproj ./src/
RUN dotnet restore ./src/register.csproj
COPY src/ ./src/
RUN dotnet publish ./src/register.csproj -c Release -o /app /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
COPY --from=build /app ./
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "register.dll"]
