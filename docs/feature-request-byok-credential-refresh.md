# Feature request (draft): credential refresh hook for BYOK providers

> **Status:** draft, not yet filed upstream. Target repo: [github/copilot-cli](https://github.com/github/copilot-cli/issues).
> Track alongside (but distinct from) [#3399 — custom headers](https://github.com/github/copilot-cli/issues/3399)
> and [#3448 — extra request params](https://github.com/github/copilot-cli/issues/3448).

## Title

Support refreshing the BYOK provider credential without restarting the CLI

## Describe the feature or problem you'd like to solve

When using a BYOK provider with a **short-lived bearer credential** (e.g. an Entra ID /
Azure AD OAuth access token, an AWS STS token, or any OIDC JWT), the Copilot CLI reads
`COPILOT_PROVIDER_API_KEY` (and any custom headers) **once at process startup** and reuses
that static value for the lifetime of the interactive session.

Entra access tokens live ~60–90 minutes. In a long interactive coding session the token
expires mid-conversation, the upstream gateway (e.g. Azure API Management running
`validate-jwt`) starts returning **HTTP 401**, and the CLI has **no way to obtain a fresh
credential** short of killing and relaunching the process — which loses the conversation
context.

This forces BYOK deployments that want true per-user identity (rather than a long-lived
static API key) to run an external **local reverse-proxy sidecar** purely to re-mint and
inject a fresh token on each request. That sidecar is the only reason JWT-based auth can't
be the simple default for enterprise/regulated (e.g. Azure Government) BYOK setups.

Note: this is **not** solved by custom-header support (#3399). Custom headers would still be
read once at startup and held static. The gap is specifically the *refresh* of a
short-lived credential during a live session.

## Proposed solution

Provide a way for the CLI to obtain a fresh credential per request (or on 401), e.g. one of:

1. **Credential command (preferred).** A new env var, e.g.
   `COPILOT_PROVIDER_API_KEY_COMMAND="az account get-access-token --scope <appId>/.default --query accessToken -o tsv"`.
   The CLI executes it to obtain the credential, caches the result, and **re-executes it**
   when the credential is near expiry or when the provider returns 401. Mirrors the
   well-established `credential_process` / `credHelpers` patterns in the AWS CLI, kubectl
   exec-credential, Git credential helpers, and Docker credential helpers.

2. **File-backed credential.** `COPILOT_PROVIDER_API_KEY_FILE=/path/to/token` where the CLI
   re-reads the file per request (an external `az`/cron/sidecar keeps it fresh). Simpler but
   weaker than option 1.

3. **Native OAuth client-credential / refresh-token flow** for `COPILOT_PROVIDER_TYPE=azure`
   that the CLI manages internally (mint + silent refresh).

Reactive trigger: on a `401` from the provider, the CLI should refresh the credential once
and retry the request transparently before surfacing the error.

## Example prompts or workflows

```bash
export COPILOT_PROVIDER_TYPE=azure
export COPILOT_PROVIDER_BASE_URL=https://my-apim.azure-api.us/openai
export COPILOT_MODEL=gpt-5.1
# CLI runs this to get a token, and re-runs it automatically before expiry / on 401:
export COPILOT_PROVIDER_API_KEY_COMMAND='az account get-access-token --scope 5c211941-.../.default --query accessToken -o tsv'
copilot   # stays authenticated across a multi-hour session, no restarts
```

## Additional context

- Validated working today (2026-06-03) against an Azure Government APIM gateway: an Entra JWT
  in the `api-key` header passes `validate-jwt` and returns a `gpt-5.1` completion (HTTP 200);
  a bad token returns HTTP 401. The **only** operational gap for interactive use is that the
  token cannot be refreshed in-session.
- Prior art for "run a command to get a credential": AWS CLI `credential_process`, kubernetes
  client-go exec credential plugins, Git/Docker credential helpers.
- Relationship to other issues:
  - #3399 (custom headers): complementary cleanup; would let the JWT ride in a real
    `Authorization` header, but does **not** address refresh.
  - #3448 (extra request params): unrelated (request body params, not auth).
