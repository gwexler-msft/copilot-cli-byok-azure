#!/usr/bin/env bash
# Configure the current shell to run `copilot` (GitHub Copilot CLI) against the private APIM,
# or run a one-shot smoke test of the gateway.
#
# Two auth modes, matching the gateway's `authMode` Bicep parameter:
#   - subscriptionKey (DEFAULT): present a long-lived per-developer APIM subscription key.
#       No token mint, no expiry. Set it via APIM_SUBSCRIPTION_KEY.
#   - jwt: mint a short-lived (~1h) Entra JWT. Opt in with AUTH_MODE=jwt and pass <appId>.
#
#   Configure shell (default, subscription key):
#       APIM_SUBSCRIPTION_KEY=<key> source ./copilot-cli-byok.sh <apimBaseUrl> [model]
#   Smoke test (default):
#       TEST=1 APIM_SUBSCRIPTION_KEY=<key> [APIM_PRIVATE_IP=10.60.1.4] ./copilot-cli-byok.sh <apimBaseUrl> [model]
#   Configure shell (jwt, opt-in):
#       AUTH_MODE=jwt source ./copilot-cli-byok.sh <apimBaseUrl> [model] <appId>
#
# Notes:
#   - The credential rides in COPILOT_PROVIDER_API_KEY because the CLI cannot send custom headers
#     (github/copilot-cli#3399). APIM strips it before the backend.
#   - <apimBaseUrl> may omit the /openai suffix — it is appended automatically (so
#     https://apim-...azure-api.us and https://apim-...azure-api.us/openai are equivalent).
#   - <model> defaults to 'auto' (let the gateway route between the full and mini tiers) if omitted.
#   - jwt mode: <appId> is the app (client) ID GUID of the BYOK gateway app (output of setup-entra).
#     With v2 access tokens the JWT 'aud' is this GUID, NOT the api:// URI. We mint with
#     `--scope "<appId>/.default"`, which also dodges az's per-resource token cache. Token TTL ~1h.
#   - APIM_PRIVATE_IP (optional, smoke test only) makes curl use --resolve so you need no
#     hosts entry or private DNS zone.
#   - MAX_PROMPT_TOKENS / MAX_OUTPUT_TOKENS (optional) override the token limits exported for a
#     non-catalog model like 'auto'. Defaults: 272000 prompt (gpt-5.1 input cap) and 32768 output
#     (gpt-4.1-mini output cap) — the smaller limit of each tier the 'auto' router can pick.
set -euo pipefail

APIM_BASE_URL="${1:?Usage: source ./copilot-cli-byok.sh <apimBaseUrl> [model] [appId]}"
MODEL="${2:-auto}"
APP_ID="${3:-}"
AUTH_MODE="${AUTH_MODE:-subscriptionKey}"
BASE_URL="${APIM_BASE_URL%/}"
# Normalize: the gateway routes live under /openai (default route) or /openai-commercial (opt-in
# commercial route). Only append /openai when the caller passed a bare host with neither suffix.
if [[ ! "$BASE_URL" =~ /openai(-commercial)?$ ]]; then BASE_URL="${BASE_URL}/openai"; fi

# Resolve the credential that will ride in the api-key header, per auth mode.
if [[ "$AUTH_MODE" == "subscriptionKey" ]]; then
  CREDENTIAL="${APIM_SUBSCRIPTION_KEY:-}"
  [[ -n "$CREDENTIAL" ]] || { echo "subscriptionKey mode: set APIM_SUBSCRIPTION_KEY (your per-developer APIM subscription key)." >&2; exit 1; }
  CRED_KIND='APIM subscription key'
elif [[ "$AUTH_MODE" == "jwt" ]]; then
  [[ -n "$APP_ID" ]] || { echo "jwt mode: pass <appId> (the BYOK gateway app/client ID GUID) as the 3rd argument." >&2; exit 1; }
  az account show >/dev/null || { echo "Run 'az login' first." >&2; exit 1; }
  # v2 token: scope "<appId>/.default" => aud == appId GUID (what APIM validate-jwt expects).
  CREDENTIAL="$(az account get-access-token --scope "${APP_ID}/.default" --query accessToken -o tsv)"
  [[ -n "$CREDENTIAL" ]] || { echo "Could not get token for $APP_ID." >&2; exit 1; }
  CRED_KIND='Entra JWT (~1h)'
else
  echo "Unknown AUTH_MODE='$AUTH_MODE' (expected 'subscriptionKey' or 'jwt')." >&2; exit 1
fi

if [[ "${TEST:-}" == "1" ]]; then
  URI="${BASE_URL}/v1/chat/completions"
  BODY="{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"say hi in three words\"}]}"
  RESOLVE_ARGS=()
  if [[ -n "${APIM_PRIVATE_IP:-}" ]]; then
    APIM_HOST="$(printf '%s' "$BASE_URL" | sed -E 's#^https?://([^/]+).*#\1#')"
    RESOLVE_ARGS=(--resolve "${APIM_HOST}:443:${APIM_PRIVATE_IP}")
  fi
  echo "POST $URI  (authMode=$AUTH_MODE, model=$MODEL, credential=$CRED_KIND, length=${#CREDENTIAL})"
  curl -sk -w '\nhttp=%{http_code}\n' --max-time 40 "${RESOLVE_ARGS[@]}" \
    -X POST "$URI" \
    -H "api-key: $CREDENTIAL" \
    -H "Content-Type: application/json" \
    -d "$BODY"
  exit 0
fi

export COPILOT_PROVIDER_BASE_URL="$BASE_URL"
export COPILOT_PROVIDER_TYPE='azure'
export COPILOT_PROVIDER_API_KEY="$CREDENTIAL"
export COPILOT_MODEL="$MODEL"

# The CLI sizes its context window from a built-in model catalog. A gateway-routed name like
# 'auto' isn't in that catalog, so the CLI warns and falls back to tiny defaults. Export the
# limits explicitly for any non-catalog model: honor MAX_PROMPT_TOKENS/MAX_OUTPUT_TOKENS if set,
# else use the SMALLER limit of each tier the 'auto' router can pick so a request can't overflow:
#   prompt 272000 = gpt-5.1 input cap; output 32768 = gpt-4.1-mini output cap.
case " gpt-4.1 gpt-4.1-mini gpt-4o gpt-4o-mini gpt-5.1 gpt-5 o3 o4-mini " in
  *" $MODEL "*) IS_CATALOG_MODEL=1 ;;
  *)           IS_CATALOG_MODEL=0 ;;
esac
if [[ -n "${MAX_PROMPT_TOKENS:-}" ]]; then
  export COPILOT_PROVIDER_MAX_PROMPT_TOKENS="$MAX_PROMPT_TOKENS"
elif [[ "$IS_CATALOG_MODEL" == "0" ]]; then
  export COPILOT_PROVIDER_MAX_PROMPT_TOKENS='272000'
fi
if [[ -n "${MAX_OUTPUT_TOKENS:-}" ]]; then
  export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS="$MAX_OUTPUT_TOKENS"
elif [[ "$IS_CATALOG_MODEL" == "0" ]]; then
  export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS='32768'
fi

echo "Configured Copilot CLI for BYOK ($AUTH_MODE):"
echo "  COPILOT_PROVIDER_BASE_URL = $COPILOT_PROVIDER_BASE_URL"
echo "  COPILOT_PROVIDER_TYPE     = $COPILOT_PROVIDER_TYPE"
echo "  COPILOT_PROVIDER_API_KEY  = <hidden $CRED_KIND, length=${#CREDENTIAL}>"
echo "  COPILOT_MODEL             = $COPILOT_MODEL"
[[ -n "${COPILOT_PROVIDER_MAX_PROMPT_TOKENS:-}" ]] && echo "  COPILOT_PROVIDER_MAX_PROMPT_TOKENS = $COPILOT_PROVIDER_MAX_PROMPT_TOKENS"
[[ -n "${COPILOT_PROVIDER_MAX_OUTPUT_TOKENS:-}" ]] && echo "  COPILOT_PROVIDER_MAX_OUTPUT_TOKENS = $COPILOT_PROVIDER_MAX_OUTPUT_TOKENS"
echo
if [[ "$AUTH_MODE" == "jwt" ]]; then
  echo "Token expires in ~1 hour. Re-source to refresh."
else
  echo "Subscription key does not expire."
fi

