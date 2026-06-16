# VS Code Custom Endpoint samples for BYOK

These samples wire **VS Code 1.122+** (the now-stable Custom Endpoint provider) to the
BYOK APIM gateway. They are the corrected JSON you paste into the `chatLanguageModels.json`
file that VS Code opens after you walk through **`Chat: Manage Language Models` →
`Add Models` → `Custom Endpoint`**.

The `customendpoint` schema is **provider-wrapped**: each top-level object is one provider
group (one `apiType`, one set of credentials), and the nested `models[]` array lists the
backend deployments served by that provider. Because `apiType` is provider-level, exposing
the same backend through both Chat Completions **and** Responses takes **two provider
blocks** (same key, same APIM, different `apiType` and matching `url`).

| File | What's inside |
|---|---|
| [`chatLanguageModels.foundry.json`](chatLanguageModels.foundry.json) | Two providers (chat-completions + responses), Foundry backend (`/openai/v1/...`), models `gpt-5.1` + `gpt-4.1-mini` |
| [`chatLanguageModels.aoai.json`](chatLanguageModels.aoai.json) | Same shape, classic AOAI backend (`/aoai/v1/...`), models `gpt-5.1` |
| [`chatLanguageModels.template.jsonc`](chatLanguageModels.template.jsonc) | Annotated template with every field documented — start here when crafting your own |

## What you need before pasting

1. **The APIM hostname.** From the deployment outputs:
   ```pwsh
   azd env get-values | Select-String 'apim'                # if you used azd
   az deployment sub show -n <deployment-name> --query 'properties.outputs.apimGatewayUrl.value' -o tsv
   ```
   Gov hosts end in `.azure-api.us`; Commercial in `.azure-api.net`. Substitute it into
   every `url` field.
2. **An APIM subscription key.** The `dev1` / `dev2` test keys provisioned in Step 6 work
   for smoke-testing; for real developers, create per-user APIM subscriptions and hand
   each developer their own key. Fetch with:
   ```pwsh
   az apim subscription show -g <rg> --service-name <apim> --sid dev1 --query primaryKey -o tsv
   ```
3. **Network reachability.** You must resolve the APIM hostname to the **private** IP:
   - in-VNet (Bastion / RDP workstation): automatic via the VNet's private DNS zone, OR
   - off-VNet over P2S VPN: the VPN client pushes the privatelink zone for you. Confirm
     with `Resolve-DnsName apim-...` — it should return `10.x.x.x`, not a public IP.

## Why two provider blocks (and not three model entries)

VS Code 1.122 promotes `apiType` and credentials to the **provider** level (see the
[`chatLanguageModels.json` schema reference](https://code.visualstudio.com/docs/agent-customization/language-models#_model-configuration-reference)).
Every model inside a provider's `models[]` array inherits that `apiType`, so a single
provider block can either be Chat Completions or Responses — not both. To expose the same
`gpt-5.1` deployment under both wire formats (recommended: Responses for reasoning chats,
Chat Completions for tool-heavy or non-reasoning workflows), declare two provider blocks
with identical `apiKey` / `requestHeaders` but different `apiType` and `url`.

## Why `requestHeaders: { "api-key": "<key>" }` on every model

VS Code's Custom Endpoint provider defaults to `Authorization: Bearer <apiKey>` for
OpenAI-compatible `apiType`s. **APIM's native subscription-key validation reads `api-key`**
(or the `subscription-key` query param), so we override the header explicitly per model.
Leave the provider's `apiKey` field set to the same value (VS Code requires it for the
default Bearer header). `requestHeaders` is a **model-level** field per the
[schema](https://code.visualstudio.com/docs/agent-customization/language-models#_model-configuration-reference);
a provider-level `requestHeaders` is silently ignored — that's why pasting the same key
at the provider scope returns `Access denied due to missing subscription key`. Repeat
the block on every model that hits the same gateway.

If you deployed the gateway with `authMode=jwt`, drop the per-model `requestHeaders`
overrides and set the provider's `apiKey` to a fresh Entra access token (VS Code does not
refresh JWTs — they're good for ~1 hour).

## Why `supportsReasoningEffort` is an array

Per the [schema](https://code.visualstudio.com/docs/agent-customization/language-models#_model-configuration-reference),
`supportsReasoningEffort` is an **array of effort levels** (`["minimal","low","medium","high"]`),
not a boolean. Setting it to `true` registers the model without a Thinking Effort picker
and the field never reaches the model. Omit it entirely for non-reasoning models like
`gpt-4.1-mini`.

## Why two `reasoningEffortFormat` values

The two wire formats put the reasoning-effort field in different places:

| `apiType` | Where `reasoning_effort` lives in the body | `reasoningEffortFormat` |
|---|---|---|
| `chat-completions` | `{ "reasoning_effort": "minimal\|low\|medium\|high" }` (root) | `"chat-completions"` |
| `responses` | `{ "reasoning": { "effort": "minimal\|low\|medium\|high" } }` (nested) | `"responses"` |

**Mismatching them silently strips the field** — the model runs at default effort. Match
each model's surface (its `url`) to the matching `reasoningEffortFormat`.

## How to install

1. **Command Palette → `Chat: Manage Language Models`** (or open the Language Models
   editor from the model picker's gear icon).
2. Click **`Add Models`** → choose **`Custom Endpoint`**.
3. Enter a group name (e.g. `BYOK Foundry`), a display name, and your APIM subscription
   key. Pick **Chat Completions** as the API type for the first round.
4. VS Code opens **`chatLanguageModels.json`**. Replace the auto-generated content with
   the contents of the sample file that matches your gateway.
5. Substitute `<APIM_HOSTNAME>` (e.g. `apim-byok-gov-pilot-jzjre3.azure-api.us`) and
   `<APIM_SUBSCRIPTION_KEY>` in every place they appear (Ctrl+H → Replace All works fine).
6. Save the file. If the new models don't appear in the picker within a few seconds,
   run **`Developer: Reload Window`**.
7. Open a new chat (Ctrl+Alt+I), pick a `BYOK …` model from the picker, and ask
   *"say hello in exactly five words."* A 200 response means the chain is wired
   (VS Code → DNS → APIM → policy → MI → backend).

## Smoke test from the same machine (no VS Code required)

Use these to prove the route works before configuring VS Code. They send the exact same
shape VS Code will send.

```pwsh
$base = 'https://<APIM_HOSTNAME>/openai'
$key  = '<APIM_SUBSCRIPTION_KEY>'

# 1) Chat Completions
$body = @{ model = 'gpt-5.1'; messages = @(@{ role = 'user'; content = 'say hello in five words' }); max_completion_tokens = 32 } | ConvertTo-Json -Depth 5
curl.exe -ksS -H "api-key: $key" -H 'Content-Type: application/json' -d $body "$base/v1/chat/completions"

# 2) Responses
$body = @{ model = 'gpt-5.1'; input = 'say hello in five words'; max_output_tokens = 32 } | ConvertTo-Json -Depth 5
curl.exe -ksS -H "api-key: $key" -H 'Content-Type: application/json' -d $body "$base/v1/responses"
```

Both should return `200` with usage. If you're on Linux/macOS, the same `curl` calls
work without changes.

## See also

- [docs/deployment-guide.md → Option C: VS Code via Custom Endpoint](../../docs/deployment-guide.md#option-c--vs-code-via-custom-endpoint-byok-provider) — the
  step-by-step walkthrough this sample plugs into.
- [docs/architecture.md → Wire format / Responses route](../../docs/architecture.md#responses-route-openaiv1responses) — the protocol-level differences
  the gateway bridges.
- [README.md → Client surfaces](../../README.md#client-surfaces) — where VS Code sits
  alongside Copilot CLI as a first-class client.
