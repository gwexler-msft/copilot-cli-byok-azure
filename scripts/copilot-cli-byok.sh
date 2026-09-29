#!/usr/bin/env bash
# Configure the current shell to run `copilot` (GitHub Copilot CLI) against the private APIM,
# or run a one-shot smoke test of the gateway.
#
# Two auth modes, matching the gateway's `authMode` Bicep parameter:
#   - subscriptionKey (DEFAULT): present a long-lived per-developer APIM subscription key.
#       No token mint, no expiry. Set it via APIM_SUBSCRIPTION_KEY.
#   - jwt: mint a short-lived (~1h) Entra JWT. Opt in with AUTH_MODE=jwt and pass <appId>.
#       Requires Azure CLI and jq. Add REFRESH_TOKEN=1 for per-request token acquisition.
#       Standard APIM hostnames infer the cloud; custom domains use BYOK_AZURE_CLOUD.
#       First sign-in prompts for approval and BYOK_TENANT_ID if missing. BYOK_LOGIN=1
#       explicitly starts login; BYOK_USE_DEVICE_CODE=1 supports a remote client session.
#   - okta: AUTH_MODE=okta and OKTA_CONFIG_FILE=<local nonsecret settings>. Requires explicit
#       get-okta-token.sh --login first and CLI credential-command support. Always renewable.
#
#   Configure shell (default, subscription key):
#       APIM_SUBSCRIPTION_KEY=<key> source ./copilot-cli-byok.sh <apimBaseUrl> [model]
#   Smoke test (default):
#       TEST=1 APIM_SUBSCRIPTION_KEY=<key> [APIM_PRIVATE_IP=10.60.1.4] ./copilot-cli-byok.sh <apimBaseUrl> [model]
#   Configure shell (jwt, opt-in):
#       AUTH_MODE=jwt source ./copilot-cli-byok.sh <apimBaseUrl> [model] <appId>
#
# Notes:
#   - The credential uses the Azure provider's api-key header. APIM strips it before the backend.
#   - <apimBaseUrl> may omit the /openai suffix - it is appended automatically (so
#     https://apim-...azure-api.us and https://apim-...azure-api.us/openai are equivalent).
#   - <model> defaults to 'gpt-5.6-sol'; pass 'auto' to opt into gateway tier routing.
#   - WIRE_API selects 'responses' (default) or 'completions'. GPT-5.6 agent tool calls require
#     Responses; set WIRE_API=completions only for a legacy chat-completions backend.
#   - jwt mode: <appId> is the app (client) ID GUID of the BYOK gateway app (output of setup-entra).
#     With v2 access tokens the JWT 'aud' is this GUID, NOT the api:// URI. We mint with
#     `--scope "<appId>/.default"`, which also dodges az's per-resource token cache. Token TTL ~1h.
#   - APIM_PRIVATE_IP (optional, smoke test only) makes curl use --resolve so you need no
#     hosts entry or private DNS zone.
#   - MAX_PROMPT_TOKENS / MAX_OUTPUT_TOKENS (optional) override the token limits exported for a
#     non-catalog model like 'auto'. Defaults: 1050000 prompt and 128000 output, shared by the
#     GPT-5.6 Sol/Luna tiers.
set -euo pipefail

APIM_BASE_URL="${1:?Usage: source ./copilot-cli-byok.sh <apimBaseUrl> [model] [appId]}"
MODEL="${2:-gpt-5.6-sol}"
APP_ID="${3:-}"
AUTH_MODE="${AUTH_MODE:-subscriptionKey}"
REFRESH_TOKEN="${REFRESH_TOKEN:-0}"
if [[ "$AUTH_MODE" == okta ]]; then REFRESH_TOKEN=1; fi
WIRE_API="${WIRE_API:-responses}"
BASE_URL="${APIM_BASE_URL%/}"
[[ "$REFRESH_TOKEN" == 0 || "$REFRESH_TOKEN" == 1 ]] || { echo 'REFRESH_TOKEN must be 0 or 1.' >&2; return 1 2>/dev/null || exit 1; }
if [[ "$REFRESH_TOKEN" == 1 && ( ( "$AUTH_MODE" != jwt && "$AUTH_MODE" != okta ) || "${TEST:-}" == 1 ) ]]; then
  echo 'REFRESH_TOKEN=1 requires AUTH_MODE=jwt or okta and cannot be combined with TEST=1.' >&2
  return 1 2>/dev/null || exit 1
fi
if printf '%s\n' "${COPILOT_PROVIDER_HEADERS:-}" | sed 's/\\n/\n/g' | grep -Eiq '^[[:space:]]*(Authorization|api-key|x-api-key|Ocp-Apim-Subscription-Key)[[:space:]]*:'; then
  echo 'Remove credential headers from COPILOT_PROVIDER_HEADERS before configuring BYOK; use one credential source.' >&2
  return 1 2>/dev/null || exit 1
fi
[[ "$WIRE_API" == "responses" || "$WIRE_API" == "completions" ]] || {
  echo "Unknown WIRE_API='$WIRE_API' (expected 'responses' or 'completions')." >&2; exit 1;
}
# Normalize: the inference routes live under /openai (the default route, and the only path the CLI's
# azure provider actually keeps). Only append /openai when the caller passed a bare host.
if [[ ! "$BASE_URL" =~ /openai$ ]]; then BASE_URL="${BASE_URL}/openai"; fi

# Resolve the credential that will ride in the api-key header, per auth mode.
if [[ "$AUTH_MODE" == "subscriptionKey" ]]; then
  CREDENTIAL="${APIM_SUBSCRIPTION_KEY:-}"
  [[ -n "$CREDENTIAL" ]] || { echo "subscriptionKey mode: set APIM_SUBSCRIPTION_KEY (your per-developer APIM subscription key)." >&2; exit 1; }
  CRED_KIND='APIM subscription key'
elif [[ "$AUTH_MODE" == okta ]]; then
  [[ "$BASE_URL" == https://* && -n "${OKTA_CONFIG_FILE:-}" ]] || { echo 'Okta mode requires HTTPS and OKTA_CONFIG_FILE; sign in explicitly with get-okta-token first.' >&2; return 1 2>/dev/null || exit 1; }
  command -v copilot >/dev/null 2>&1 || { echo 'Copilot CLI is required for credential-command mode.' >&2; return 1 2>/dev/null || exit 1; }
  PROVIDER_HELP="$(copilot help providers 2>/dev/null)" || { echo 'Could not read CLI provider capabilities.' >&2; return 1 2>/dev/null || exit 1; }
  [[ "$PROVIDER_HELP" == *COPILOT_PROVIDER_API_KEY_COMMAND* ]] || { echo 'Update Copilot CLI before enabling Okta credential-command mode.' >&2; return 1 2>/dev/null || exit 1; }
  OKTA_CONFIG_PATH="$(cd "$(dirname "$OKTA_CONFIG_FILE")" && pwd -P)/$(basename "$OKTA_CONFIG_FILE")"
  TOKEN_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/get-okta-token.sh"
  bash "$TOKEN_HELPER" --config "$OKTA_CONFIG_PATH" >/dev/null || { return 1 2>/dev/null || exit 1; }
  byok_quote_argument() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
  CREDENTIAL_COMMAND="bash $(byok_quote_argument "$TOKEN_HELPER") --config $(byok_quote_argument "$OKTA_CONFIG_PATH")"
  unset -f byok_quote_argument
  CRED_KIND='Okta JWT (OS-protected renewable user grant)'
elif [[ "$AUTH_MODE" == "jwt" ]]; then
  [[ -n "$APP_ID" ]] || { echo "jwt mode: pass <appId> (the BYOK gateway app/client ID GUID) as the 3rd argument." >&2; exit 1; }
  command -v az >/dev/null 2>&1 || { echo 'JWT mode requires Azure CLI (az) installed separately. The launcher can guide sign-in after installation.' >&2; return 1 2>/dev/null || exit 1; }
  command -v jq >/dev/null 2>&1 || { echo 'JWT setup requires jq.' >&2; return 1 2>/dev/null || exit 1; }
  byok_resolve_azure_cloud() {
    local url="$1" selected="$2" interactive="$3" hostname inferred=''
    local pattern='^[hH][tT][tT][pP][sS]://([A-Za-z0-9][A-Za-z0-9.-]*)(:[0-9]+)?(/[^?#[:space:]]*)?$'
    [[ "$url" =~ $pattern ]] || { echo 'JWT mode requires an HTTPS gateway URL without user information, query parameters or fragments.' >&2; return 1; }
    hostname="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')" || return 1
    hostname="${hostname%.}"
    case "$hostname" in
      *.azure-api.us) inferred=AzureUSGovernment ;;
      *.azure-api.net) inferred=AzureCloud ;;
    esac
    [[ -z "$selected" || -z "$inferred" || "$selected" == "$inferred" ]] || { echo 'The requested cloud conflicts with the APIM hostname.' >&2; return 1; }
    selected="${selected:-$inferred}"
    if [[ -z "$selected" && "$interactive" == 1 ]]; then
      read -r -p 'Custom gateway domain: enter AzureCloud or AzureUSGovernment: ' selected || return 1
    fi
    [[ "$selected" == AzureCloud || "$selected" == AzureUSGovernment ]] || { echo 'Cannot infer this gateway cloud. Set BYOK_AZURE_CLOUD=AzureCloud or AzureUSGovernment.' >&2; return 1; }
    printf '%s' "$selected"
  }
  byok_valid_azure_account() {
    printf '%s' "$AZURE_CONTEXT" | jq -e --arg cloud "$TOKEN_CLOUD" --arg tenant "$1" '
      type == "object" and .environmentName == $cloud and .user.type == "user" and
      (.user.name | type == "string" and test("\\S")) and
      (.tenantId | type == "string" and test("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$"; "i")) and
      ($tenant == "" or (.tenantId | ascii_downcase) == ($tenant | ascii_downcase))
    ' >/dev/null 2>&1
  }
  byok_initialize_azure_account() {
    local interactive=0 approved="${BYOK_LOGIN:-0}" device="${BYOK_USE_DEVICE_CODE:-0}"
    local tenant="${BYOK_TENANT_ID:-}" cache new_cache=0 current_cloud='' account_name='' answer=''
    local tenant_pattern='^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
    [[ "$approved" == 0 || "$approved" == 1 ]] && [[ "$device" == 0 || "$device" == 1 ]] || { echo 'BYOK_LOGIN and BYOK_USE_DEVICE_CODE must be 0 or 1.' >&2; return 1; }
    [[ -z "$tenant" || "$tenant" =~ $tenant_pattern ]] || { echo 'BYOK_TENANT_ID must be the directory tenant GUID, not AppId or a login URL.' >&2; return 1; }
    if [[ -t 0 && -t 1 ]]; then interactive=1; fi
    TOKEN_CLOUD="$(byok_resolve_azure_cloud "$BASE_URL" "${BYOK_AZURE_CLOUD:-}" "$interactive")" || return 1
    if [[ -n "${AZURE_CONFIG_DIR:-}" ]]; then cache="$AZURE_CONFIG_DIR"
    elif [[ "$TOKEN_CLOUD" == AzureUSGovernment ]]; then cache="$HOME/.azure-byok-government"
    else cache="$HOME/.azure-byok-commercial"; fi
    AZURE_CONTEXT=''
    if [[ -e "$cache" || -L "$cache" ]]; then
      [[ -d "$cache" ]] || { echo 'AZURE_CONFIG_DIR must identify a directory.' >&2; return 1; }
      TOKEN_CONFIG="$(cd "$cache" && pwd -P)" || return 1
      export AZURE_CONFIG_DIR="$TOKEN_CONFIG"
      current_cloud="$(az cloud show --query name --output tsv --only-show-errors 2>/dev/null)" || return 1
      [[ "$current_cloud" == "$TOKEN_CLOUD" ]] || { echo 'The selected Azure CLI cache does not match the gateway cloud. It will not be switched; use a dedicated terminal/cache.' >&2; return 1; }
      if ! AZURE_CONTEXT="$(az account show --output json --only-show-errors 2>/dev/null)"; then AZURE_CONTEXT=''; fi
      if [[ -n "$AZURE_CONTEXT" ]] && ! printf '%s' "$AZURE_CONTEXT" | jq -e . >/dev/null 2>&1; then AZURE_CONTEXT=''; fi
    else new_cache=1; fi
    if [[ -n "$AZURE_CONTEXT" ]]; then
      byok_valid_azure_account "$tenant" || { echo 'The cached account must be one delegated user in the gateway cloud and requested tenant. Use a dedicated user cache.' >&2; return 1; }
      tenant="$(printf '%s' "$AZURE_CONTEXT" | jq -er '.tenantId')" || return 1
      account_name="$(printf '%s' "$AZURE_CONTEXT" | jq -er '.user.name')" || return 1
    fi
    if [[ -z "$AZURE_CONTEXT" || "$approved" == 1 ]]; then
      printf 'Gateway authentication cloud: %s.\n' "$TOKEN_CLOUD"
      if [[ "$approved" != 1 && "$interactive" == 1 ]]; then
        read -r -p "Sign in to $TOKEN_CLOUD for this gateway now? [y/N] " answer || return 1
        case "$answer" in y|Y|yes|YES) approved=1 ;; esac
      fi
      [[ "$approved" == 1 ]] || { echo 'No usable Azure CLI account. Rerun interactively or set BYOK_LOGIN=1 and BYOK_TENANT_ID; AZURE_CONFIG_DIR must be dedicated to the gateway cloud.' >&2; return 1; }
      if [[ -z "$tenant" && "$interactive" == 1 ]]; then read -r -p 'Gateway directory Tenant ID (GUID, not AppId): ' tenant || return 1; fi
      [[ "$tenant" =~ $tenant_pattern && "$tenant" != "$APP_ID" ]] || { echo 'Sign-in requires BYOK_TENANT_ID as the gateway directory GUID; it cannot be inferred from the APIM URL or AppId.' >&2; return 1; }
      if [[ "$new_cache" == 1 ]]; then
        local staging_cache
        staging_cache="$(umask 077 && mktemp -d "$(dirname "$cache")/.byok-cache-setup-XXXXXXXXXX")" || return 1
        export AZURE_CONFIG_DIR="$staging_cache"
        if ! az cloud set --name "$TOKEN_CLOUD" --output none --only-show-errors 2>/dev/null ||
           ! current_cloud="$(az cloud show --query name --output tsv --only-show-errors 2>/dev/null)" ||
           [[ "$current_cloud" != "$TOKEN_CLOUD" ]]; then
          rm -rf -- "$staging_cache"
          echo 'Could not initialize the new cloud-specific cache. No login was attempted; retry setup explicitly.' >&2
          return 1
        fi
        if ! (umask 077 && mkdir -- "$cache"); then
          rm -rf -- "$staging_cache"
          echo 'Could not create the new cloud-specific cache; an existing directory will not be reused implicitly.' >&2
          return 1
        fi
        if ! cp -R -- "$staging_cache/." "$cache"; then
          rm -rf -- "$staging_cache" "$cache"
          echo 'Could not publish the new cache. No login was attempted; retry setup explicitly.' >&2
          return 1
        fi
        rm -rf -- "$staging_cache" || return 1
        TOKEN_CONFIG="$(cd "$cache" && pwd -P)" || return 1
        export AZURE_CONFIG_DIR="$TOKEN_CONFIG"
      fi
      local login_arguments=(login --tenant "$tenant" --scope "$APP_ID/.default" --allow-no-subscriptions --output none)
      if [[ "$device" == 1 ]]; then login_arguments+=(--use-device-code); fi
      az "${login_arguments[@]}" || { echo 'Azure sign-in did not complete. Provider credentials were not changed; retry explicitly.' >&2; return 1; }
      AZURE_CONTEXT="$(az account show --output json --only-show-errors 2>/dev/null)" || { echo 'Could not verify the resulting sign-in.' >&2; return 1; }
      current_cloud="$(az cloud show --query name --output tsv --only-show-errors 2>/dev/null)" || return 1
      [[ "$current_cloud" == "$TOKEN_CLOUD" ]] && byok_valid_azure_account "$tenant" || { echo 'The resulting sign-in does not match the expected cloud, tenant and delegated user.' >&2; return 1; }
      if [[ -n "$account_name" ]] && ! printf '%s' "$AZURE_CONTEXT" | jq -e --arg name "$account_name" '(.user.name | ascii_downcase) == ($name | ascii_downcase)' >/dev/null; then
        echo 'Sign-in changed the expected delegated user. Provider credentials were not changed.' >&2; return 1
      fi
    fi
    TOKEN_TENANT="$(printf '%s' "$AZURE_CONTEXT" | jq -er '.tenantId')" || return 1
    TOKEN_ACCOUNT="$(printf '%s' "$AZURE_CONTEXT" | jq -er '.user.name')" || return 1
  }
  BYOK_PREVIOUS_CACHE="${AZURE_CONFIG_DIR-}"
  BYOK_HAD_CACHE="${AZURE_CONFIG_DIR+x}"
  if ! byok_initialize_azure_account; then
    if [[ "$BYOK_HAD_CACHE" == x ]]; then export AZURE_CONFIG_DIR="$BYOK_PREVIOUS_CACHE"; else unset AZURE_CONFIG_DIR; fi
    unset -f byok_resolve_azure_cloud byok_valid_azure_account byok_initialize_azure_account
    unset BYOK_PREVIOUS_CACHE BYOK_HAD_CACHE
    return 1 2>/dev/null || exit 1
  fi
  unset -f byok_resolve_azure_cloud byok_valid_azure_account byok_initialize_azure_account
  unset BYOK_PREVIOUS_CACHE BYOK_HAD_CACHE
  byok_jwt_access_guidance() {
    if [[ "${#1}" -le 65536 ]] && printf '%s' "$1" | jq -Rse '
      select(test("\\A[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\z"))
      | split(".")[1] | gsub("-"; "+") | gsub("_"; "/") | @base64d | fromjson
      | select(type == "object" and (.roles == null or .roles == [])) | true
    ' >/dev/null 2>&1; then
      printf '%s\n' 'WARNING: The acquired gateway token has no app roles. If group-based JWT tiers are enabled, APIM will deny inference with 403. After a group change, allow propagation and rerun this launcher with BYOK_LOGIN=1 (add BYOK_USE_DEVICE_CODE=1 on a VM). If access is still denied, ask your administrator to verify exactly one mapped gateway tier. This is a local metadata hint, not an authorization check.' >&2
    fi
    return 0
  }
  if [[ "$REFRESH_TOKEN" == 1 ]]; then
    command -v copilot >/dev/null 2>&1 || { echo 'Copilot CLI is required for credential-command mode.' >&2; return 1 2>/dev/null || exit 1; }
    PROVIDER_HELP="$(copilot help providers 2>/dev/null)" || { echo 'Could not read CLI provider capabilities.' >&2; return 1 2>/dev/null || exit 1; }
    [[ "$PROVIDER_HELP" == *COPILOT_PROVIDER_API_KEY_COMMAND* ]] || { echo 'Update Copilot CLI before enabling REFRESH_TOKEN=1.' >&2; return 1 2>/dev/null || exit 1; }
    TOKEN_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/get-byok-token.sh"
    if ! BYOK_PREFLIGHT_TOKEN="$(bash "$TOKEN_HELPER" "$APP_ID" "$TOKEN_CLOUD" "$TOKEN_TENANT" "$TOKEN_ACCOUNT" "$TOKEN_CONFIG")"; then
      unset BYOK_PREFLIGHT_TOKEN
      unset -f byok_jwt_access_guidance
      return 1 2>/dev/null || exit 1
    fi
    byok_jwt_access_guidance "$BYOK_PREFLIGHT_TOKEN"
    unset BYOK_PREFLIGHT_TOKEN
    byok_quote_argument() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
    CREDENTIAL_COMMAND="bash $(byok_quote_argument "$TOKEN_HELPER") $(byok_quote_argument "$APP_ID") $(byok_quote_argument "$TOKEN_CLOUD") $(byok_quote_argument "$TOKEN_TENANT") $(byok_quote_argument "$TOKEN_ACCOUNT") $(byok_quote_argument "$TOKEN_CONFIG")"
    unset -f byok_quote_argument
    CRED_KIND='Entra JWT (per-request Azure CLI cache)'
  else
    CREDENTIAL="$(az account get-access-token --scope "${APP_ID}/.default" --query accessToken -o tsv --only-show-errors)" || { echo 'Gateway token acquisition failed.' >&2; exit 1; }
    [[ -n "$CREDENTIAL" ]] || { echo 'Could not acquire the gateway token.' >&2; exit 1; }
    byok_jwt_access_guidance "$CREDENTIAL"
    CRED_KIND='Entra JWT (~1h)'
  fi
  unset -f byok_jwt_access_guidance
else
  echo "Unknown AUTH_MODE='$AUTH_MODE' (expected 'subscriptionKey', 'jwt' or 'okta')." >&2; exit 1
fi

if [[ "${TEST:-}" == "1" ]]; then
  if [[ "$WIRE_API" == "responses" ]]; then
    URI="${BASE_URL}/v1/responses"
    BODY="{\"model\":\"${MODEL}\",\"input\":\"say hi in three words\"}"
  else
    URI="${BASE_URL}/v1/chat/completions"
    BODY="{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"say hi in three words\"}]}"
  fi
  RESOLVE_ARGS=()
  if [[ -n "${APIM_PRIVATE_IP:-}" ]]; then
    APIM_HOST="$(printf '%s' "$BASE_URL" | sed -E 's#^https?://([^/]+).*#\1#')"
    RESOLVE_ARGS=(--resolve "${APIM_HOST}:443:${APIM_PRIVATE_IP}")
  fi
  echo "POST $URI  (wireApi=$WIRE_API, authMode=$AUTH_MODE, model=$MODEL, credential=$CRED_KIND, length=${#CREDENTIAL})"
  curl -sk -w '\nhttp=%{http_code}\n' --max-time 40 "${RESOLVE_ARGS[@]}" \
    -X POST "$URI" \
    -H "api-key: $CREDENTIAL" \
    -H "Content-Type: application/json" \
    -d "$BODY"
  exit 0
fi

export COPILOT_PROVIDER_BASE_URL="$BASE_URL"
export COPILOT_PROVIDER_TYPE='azure'
export COPILOT_PROVIDER_WIRE_API="$WIRE_API"
unset COPILOT_PROVIDER_BEARER_TOKEN
if [[ "$REFRESH_TOKEN" == 1 ]]; then
  unset COPILOT_PROVIDER_API_KEY
  export COPILOT_PROVIDER_API_KEY_COMMAND="$CREDENTIAL_COMMAND"
  unset CREDENTIAL
else
  unset COPILOT_PROVIDER_API_KEY_COMMAND
  export COPILOT_PROVIDER_API_KEY="$CREDENTIAL"
fi
export COPILOT_MODEL="$MODEL"

# The CLI sizes its context window from a built-in model catalog. A gateway-routed name like
# 'auto' isn't in that catalog, so the CLI warns and falls back to tiny defaults. Export the
# limits explicitly for any non-catalog model: honor MAX_PROMPT_TOKENS/MAX_OUTPUT_TOKENS if set,
# else use the SMALLER limit of each tier the 'auto' router can pick so a request can't overflow:
#   prompt 1050000 and output 128000 = shared GPT-5.6 Sol/Luna limits.
case " gpt-4.1 gpt-4.1-mini gpt-4o gpt-4o-mini gpt-5.1 gpt-5 gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna o3 o4-mini " in
  *" $MODEL "*) IS_CATALOG_MODEL=1 ;;
  *)           IS_CATALOG_MODEL=0 ;;
esac
if [[ -n "${MAX_PROMPT_TOKENS:-}" ]]; then
  export COPILOT_PROVIDER_MAX_PROMPT_TOKENS="$MAX_PROMPT_TOKENS"
elif [[ "$IS_CATALOG_MODEL" == "0" ]]; then
  export COPILOT_PROVIDER_MAX_PROMPT_TOKENS='1050000'
fi
if [[ -n "${MAX_OUTPUT_TOKENS:-}" ]]; then
  export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS="$MAX_OUTPUT_TOKENS"
elif [[ "$IS_CATALOG_MODEL" == "0" ]]; then
  export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS='128000'
fi

echo "Configured Copilot CLI for BYOK ($AUTH_MODE):"
echo "  COPILOT_PROVIDER_BASE_URL = $COPILOT_PROVIDER_BASE_URL"
echo "  COPILOT_PROVIDER_TYPE     = $COPILOT_PROVIDER_TYPE"
echo "  COPILOT_PROVIDER_WIRE_API = $COPILOT_PROVIDER_WIRE_API"
if [[ "$REFRESH_TOKEN" == 1 ]]; then
  echo '  COPILOT_PROVIDER_API_KEY_COMMAND = <pinned token helper>'
else
  echo "  COPILOT_PROVIDER_API_KEY  = <hidden $CRED_KIND, length=${#CREDENTIAL}>"
fi
echo "  COPILOT_MODEL             = $COPILOT_MODEL"
[[ -n "${COPILOT_PROVIDER_MAX_PROMPT_TOKENS:-}" ]] && echo "  COPILOT_PROVIDER_MAX_PROMPT_TOKENS = $COPILOT_PROVIDER_MAX_PROMPT_TOKENS"
[[ -n "${COPILOT_PROVIDER_MAX_OUTPUT_TOKENS:-}" ]] && echo "  COPILOT_PROVIDER_MAX_OUTPUT_TOKENS = $COPILOT_PROVIDER_MAX_OUTPUT_TOKENS"
if [[ "$AUTH_MODE" == jwt ]]; then
  echo '  Entra token acquired; APIM authorization has not been checked by this launcher.'
  echo '  A cached token can retain old tier roles. After group changes, use BYOK_LOGIN=1 (and BYOK_USE_DEVICE_CODE=1 on a VM); REFRESH_TOKEN=1 alone may reuse the cache.'
fi
echo
if [[ "$REFRESH_TOKEN" == 1 ]]; then
  echo 'Copilot will acquire the gateway token per request using the pinned credential helper.'
elif [[ "$AUTH_MODE" == "jwt" ]]; then
  echo "Token expires in ~1 hour. Re-source to refresh."
else
  echo "Subscription key does not expire."
fi

