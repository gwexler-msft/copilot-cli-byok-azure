#!/usr/bin/env bash
set +x
set -euo pipefail

trace_token() {
  [[ -n "${BYOK_TOKEN_TRACE_FILE:-}" ]] || return 0
  if ! (jq -nc --arg event "$1" --arg expiry "${2:-}" \
    '{event:$event,observedUtc:(now|todateiso8601),expiresUtc:(if $expiry=="" then null else ($expiry|tonumber|todateiso8601) end)}' \
    >> "$BYOK_TOKEN_TRACE_FILE") 2>/dev/null; then
    printf '%s\n' 'BYOK token trace could not be written; credential handling is unchanged.' >&2
  fi
}

fail() {
  trace_token acquisition-failed
  printf '%s\n' 'Gateway credential unavailable. Check the pinned Azure cloud, account, cache and Entra connectivity. To sign in again, exit Copilot and rerun the BYOK launcher with AUTH_MODE=jwt REFRESH_TOKEN=1 BYOK_LOGIN=1 (add BYOK_USE_DEVICE_CODE=1 on a VM). No credential was returned.' >&2
  exit 1
}

[[ "$#" == 5 ]] || fail
app_id="$1"
cloud="$2"
tenant_id="$3"
account_name="$4"
config_directory="$5"
guid_pattern='^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$'
[[ "$app_id" =~ $guid_pattern && "$tenant_id" =~ $guid_pattern ]] || fail
[[ "$cloud" == AzureCloud || "$cloud" == AzureUSGovernment ]] || fail
[[ -n "$account_name" && -n "$config_directory" ]] || fail
command -v az >/dev/null 2>&1 || fail
command -v jq >/dev/null 2>&1 || fail
export AZURE_CONFIG_DIR="$config_directory"

actual_cloud="$(az cloud show --query name -o tsv --only-show-errors 2>/dev/null)" || fail
actual_cloud="${actual_cloud%$'\r'}"
[[ "$actual_cloud" == "$cloud" ]] || fail
account="$(az account show -o json --only-show-errors 2>/dev/null)" || fail
printf '%s' "$account" | jq -e --arg cloud "$cloud" --arg tenant "$tenant_id" --arg account "$account_name" \
  '.environmentName == $cloud and (.tenantId | ascii_downcase) == ($tenant | ascii_downcase) and .user.type == "user" and (.user.name | ascii_downcase) == ($account | ascii_downcase)' >/dev/null 2>&1 || fail
credential="$(az account get-access-token --tenant "$tenant_id" --scope "$app_id/.default" -o json --only-show-errors 2>/dev/null)" || fail
token="$(printf '%s' "$credential" | jq -ser --arg tenant "$tenant_id" '
  select(length == 1) | .[0]
  | select((.tenant | ascii_downcase) == ($tenant | ascii_downcase))
  | select((.expires_on | tonumber) > (now + 60))
  | .accessToken
  | select(type == "string" and test("\\A[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\z"))
' 2>/dev/null)" || fail
[[ -n "$token" ]] || fail
if [[ -n "${BYOK_TOKEN_TRACE_FILE:-}" ]]; then
  trace_token token-acquired "$(printf '%s' "$credential" | jq -r '.expires_on' 2>/dev/null)"
fi
printf '%s\n' "$token"