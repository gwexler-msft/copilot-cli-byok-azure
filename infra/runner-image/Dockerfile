# Pre-baked self-hosted GitHub Actions runner image (issue #94).
#
# WHY THIS EXISTS
# The VNet-injected runner Job (infra/modules/gh-runner.bicep) runs on snet-runner, which
# we want to lock down with an egress-allowlist NSG (restrictRunnerEgress). The community
# myoung34/github-runner image is pulled from Docker Hub and the workflows then install
# azd / Azure CLI / bicep / .NET SDK from public CDNs AT RUNTIME — none of which have NSG
# service tags, so the allowlist can't express them without brittle IP ranges.
#
# Pre-baking moves ALL that egress from runtime (on the locked-down subnet) to BUILD time
# (inside ACR Tasks, which has its own unrestricted egress). The runner then only ever
# pulls THIS ONE image from our ACR — already covered by the AzureContainerRegistry +
# Storage service tags — so restrictRunnerEgress=true works with zero CIDR params.
#
# BASE IMAGE
# We use the official ghcr.io/actions/actions-runner (decision in #94) instead of
# myoung34/github-runner. The official image ships the runner binaries (config.sh/run.sh)
# but NOT myoung34's env-var bootstrap, so entrypoint.sh below re-implements that bootstrap
# while honoring the SAME env contract (APP_ID/APP_PRIVATE_KEY/APP_LOGIN/ACCESS_TOKEN/
# REPO_URL/RUNNER_SCOPE/LABELS/EPHEMERAL/RUNNER_NAME_PREFIX/DISABLE_RUNNER_UPDATE). That
# keeps gh-runner.bicep's container env block unchanged and lets the ACR image be a drop-in
# opt-in (useAcrRunnerImage) without touching the live myoung34-based runners.
#
# BUILD
# Built by .github/workflows/build-runner-image.yml via `az acr build` (ACR Tasks,
# server-side) on a weekly schedule + workflow_dispatch. Pin versions via the ARGs below
# for deterministic, reproducible runs; bump them (and rebuild) to patch.

# Pin the runner version. ghcr.io/actions/actions-runner publishes a tag per release.
# Must be recent enough for GitHub's message-broker (broker.actions.githubusercontent.com):
# older runners (e.g. 2.319.1) get HTTP 403 from the broker after BrokerMigration and exit
# before receiving a job, so keep this at/near the latest release.
ARG RUNNER_VERSION=2.335.1
FROM ghcr.io/actions/actions-runner:${RUNNER_VERSION}

# Tool versions — pinned for deterministic rebuilds. Bump to patch.
ARG DOTNET_CHANNEL=10.0
ARG BICEP_VERSION=v0.30.23
ARG GH_VERSION=2.95.0

# The base image runs as the unprivileged `runner` user; switch to root to install the
# system-wide toolchain, then drop back to `runner` for execution.
USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Base OS packages. curl/jq/openssl/git are needed by entrypoint.sh (App JWT minting,
# registration-token API calls); the others back the tool installers below.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      curl \
      jq \
      git \
      openssl \
      ca-certificates \
      apt-transport-https \
      gnupg \
      lsb-release \
 && rm -rf /var/lib/apt/lists/*

# Azure CLI (system-wide, /opt/az + /usr/bin/az). Pulled from packages.microsoft.com.
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# Azure Developer CLI (azd) → /usr/local/bin/azd. Pulled from aka.ms/GitHub releases.
RUN curl -fsSL https://aka.ms/install-azd.sh | bash

# Bicep CLI (standalone, pinned) → /usr/local/bin/bicep. Independent of `az bicep` so the
# runner never needs to download it at job time.
RUN curl -fsSL -o /usr/local/bin/bicep \
      "https://github.com/Azure/bicep/releases/download/${BICEP_VERSION}/bicep-linux-x64" \
 && chmod +x /usr/local/bin/bicep \
 && /usr/local/bin/bicep --version

# .NET SDK (for the register-build validate gate, `dotnet restore/build`). Installed
# system-wide to /usr/share/dotnet and symlinked onto PATH.
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
 && chmod +x /tmp/dotnet-install.sh \
 && /tmp/dotnet-install.sh --channel "${DOTNET_CHANNEL}" --install-dir /usr/share/dotnet \
 && ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet \
 && rm -f /tmp/dotnet-install.sh \
 && dotnet --info
ENV DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1

# PowerShell 7 (pwsh) — many repo helper scripts are .ps1. Installed from packages.microsoft.com.
RUN curl -fsSL -o /tmp/pwsh.deb \
      "https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell_7.4.6-1.deb_amd64.deb" \
 && DEBIAN_FRONTEND=noninteractive apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/pwsh.deb \
 && rm -f /tmp/pwsh.deb \
 && rm -rf /var/lib/apt/lists/* \
 && pwsh --version

# GitHub CLI (gh) — repo automation scripts (e.g. scripts/seed-project-fields.ps1 for the
# Refresh-project-votes workflow) call `gh api graphql`. The community myoung34 base shipped
# gh out of the box; the official actions-runner base does NOT, so we bake the pinned release
# binary here (same pattern as bicep). Runtime egress is api.github.com, already covered by
# githubEgressCidrs under restrictRunnerEgress.
RUN curl -fsSL -o /tmp/gh.tar.gz \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
 && tar -xzf /tmp/gh.tar.gz -C /tmp \
 && mv "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
 && chmod +x /usr/local/bin/gh \
 && rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_amd64" \
 && gh --version

# yamllint — backs the "Workflow YAML validity" validate gate (.github/workflows/validate.yml).
# The base actions-runner image ships python3 but NOT pip, and the egress-locked runner can't
# reach PyPI, so install yamllint from the Ubuntu repos at BUILD time (server-side ACR Tasks)
# rather than `pip install` at job time. The validate step then uses this baked binary.
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends yamllint \
 && rm -rf /var/lib/apt/lists/* \
 && yamllint --version

# Our bootstrap entrypoint (App/PAT registration → config.sh --ephemeral → run.sh).
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Drop privileges back to the runner user; config.sh refuses to run as root.
USER runner
WORKDIR /home/runner

ENTRYPOINT ["/entrypoint.sh"]
