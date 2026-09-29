#!/usr/bin/env bash
# Pre-provision guard that stops a provision from WIPING populated pilot values when CI-only
# environment variables are absent. See check-provision-params.ps1 for full docs. Wired as an azd
# `preprovision` hook AFTER ensure-byok-groups.
#
#   OPTION 2 (HARD): deployFoundryCommercial=true but COMMERCIAL_* resolve empty/placeholder -> abort
#                    (a local provision would reset the foundry-commercial-* named values -> 502).
#   OPTION 3 (WARN): list every ${VAR} param that resolves EMPTY (louder on *-pilot envs). Non-fatal:
#                    some empties are intentional (register Easy Auth two-phase; route off for the env).
#   Shared-auth preparation trust is always checked when supplied. SKIP_PROVISION_PARAM_CHECK=true
#   bypasses only the legacy backend/advisory checks. Secret VALUES are never printed.
set -euo pipefail

export MSYS2_ENV_CONV_EXCL="${MSYS2_ENV_CONV_EXCL:+${MSYS2_ENV_CONV_EXCL};}BYOK_RESPONSE_OWNER_KEY;BYOK_RESPONSE_OWNER_PREVIOUS_KEY;BYOK_CALLER_AUTH_PREPARATION;BYOK_CALLER_JWT_TIERING;FOUNDRY_API_KEY"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE_CALLER_AUTH=false
STANDALONE_CLOUD=''
if [[ "${1:-}" == '--stage-caller-auth' ]]; then
  STAGE_CALLER_AUTH=true
  shift
fi
if [[ "${1:-}" == '--standalone-cloud' ]]; then
  [[ $# -ge 2 && ( "$2" == AzureCloud || "$2" == AzureUSGovernment ) ]] || { echo '[provision-params] A supported standalone cloud is required.' >&2; exit 1; }
  STANDALONE_CLOUD="$2"
  shift 2
fi
if [[ "$STAGE_CALLER_AUTH" == true && -n "$STANDALONE_CLOUD" ]]; then
  echo '[provision-params] Standalone validation cannot stage the source parameter file.' >&2
  exit 1
fi
# azd always provisions from infra/main.parameters.json (workflows stage the per-env file into it
# before `azd provision`). Read that staged file so the guard reflects what will actually deploy.
if [[ $# -gt 1 ]]; then
  echo '[provision-params] Expected at most one explicit parameter-file argument.' >&2
  exit 1
fi
PARAM_FILE="${1:-$SCRIPT_DIR/../infra/main.parameters.json}"
if [[ ! -f "$PARAM_FILE" ]]; then
  if [[ $# -eq 1 || "$STAGE_CALLER_AUTH" == true ]]; then
    echo '[provision-params] Explicit parameter file was not found.' >&2
    exit 1
  fi
  echo "[provision-params] $PARAM_FILE not found - skipping guard."
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo '[provision-params] jq is required to validate deployment parameters.' >&2
  exit 1
fi
if ! jq -e 'type == "object" and (.parameters | type == "object")' "$PARAM_FILE" >/dev/null 2>&1; then
  echo '[provision-params] Cannot read a valid deployment parameter document.' >&2
  exit 1
fi

TARGET_FILE="$PARAM_FILE"
STAGED_FILE=''
if [[ "$STAGE_CALLER_AUTH" == true ]]; then
  STAGED_FILE="$(mktemp "${PARAM_FILE}.XXXXXX")"
  trap 'rm -f "$STAGED_FILE"' EXIT
  if ! jq '
    (env.BYOK_CALLER_AUTH_PREPARATION // "") as $preparation |
    (env.BYOK_CALLER_AUTH_ROLLOUT // "") as $rollout |
    (env.BYOK_CALLER_JWT_TIERING // "") as $tiering |
    (if $preparation != "" then .parameters.callerAuthPreparation = {value: ($preparation | fromjson)} else . end) |
    (if $rollout != "" then .parameters.callerAuthRollout = {value: $rollout} else . end) |
    (if $tiering != "" then .parameters.callerJwtTiering = {value: ($tiering | fromjson)} else . end) |
    if (.parameters.callerAuthRollout.value // "legacy") != "legacy" then
      if (env.BYOK_RESPONSE_OWNER_PREVIOUS_KEY // "") == "" then error("Missing previous ownership key state") else . end |
      .parameters.responseOwnerKey = {value: "${BYOK_RESPONSE_OWNER_KEY}"} |
      .parameters.responseOwnerPreviousKey = {value: (if env.BYOK_RESPONSE_OWNER_PREVIOUS_KEY == "__none__" then "" else "${BYOK_RESPONSE_OWNER_PREVIOUS_KEY}" end)}
    else . end
  ' "$PARAM_FILE" > "$STAGED_FILE" 2>/dev/null; then
    echo '[provision-params] Invalid caller-auth staging configuration. Values are withheld.' >&2
    exit 1
  fi
  PARAM_FILE="$STAGED_FILE"
fi

if ! jq -e --arg standaloneCloud "$STANDALONE_CLOUD" '
  env as $environment |
  def resolved:
    walk(if type == "string" then gsub("\\$\\{(?<variable>[A-Za-z_][A-Za-z0-9_]*)\\}"; $environment[.variable] // "") else . end);
  def properties($names): if type == "object" then keys == ($names | sort) else false end;
  def matches($pattern): if type == "string" then test($pattern) else false end;
  def string_array: if type == "array" then all(.[]; type == "string") else false end;
  def guid_value:
    matches("\\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\z") and . != "00000000-0000-0000-0000-000000000000";
  def ownership_key:
    matches("\\A[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=\\z") and . != (("A" * 43) + "=");
  (.parameters | resolved) as $source |
  (if $standaloneCloud != "" then
    if ($source | has("responseOwnerKey") or has("responseOwnerPreviousKey")) then error("Owner keys cannot be in the parameter file") else . end |
    $source + {cloudEnv: {value:$standaloneCloud}} |
    (if has("productTiers") then . else .productTiers = {value: (([$source.existingProductName.value // ""] + ($source.additionalProductNames.value // [])) | map(select(. != "") | {name:.}))} end) |
    if (.callerAuthRollout.value // "legacy") != "legacy" then
      if ($environment.BYOK_RESPONSE_OWNER_PREVIOUS_KEY // "") == "" then error("Missing previous ownership key state") else . end |
      .responseOwnerKey = {value:($environment.BYOK_RESPONSE_OWNER_KEY // "")} |
      .responseOwnerPreviousKey = {value:(if $environment.BYOK_RESPONSE_OWNER_PREVIOUS_KEY == "__none__" then "" else $environment.BYOK_RESPONSE_OWNER_PREVIOUS_KEY end)}
    else . end
  else $source end) as $parameters |
  def parameter($name; $default): if $parameters | has($name) then $parameters[$name].value else $default end;
  def tier_name: matches("\\A[a-z][a-z0-9-]{0,79}\\z");
  def tier_limit: if type == "number" then . >= 1 and . <= 2147483647 and floor == . else false end;
  def tier_mappings:
    . as $provider | if (.mappings | type) != "array" then false else
      (.mappings | length) <= 16 and ((.enabled | not) or (.mappings | length) > 0) and
      (.mappings | all(.[]; properties(["claimValue", "tier"]) and
        (.claimValue | matches("\\A[A-Za-z][A-Za-z0-9_.:-]{0,127}\\z")) and (.tier | tier_name))) and
      ((.mappings | map(.claimValue) | unique | length) == ($provider.mappings | length))
    end;
  (if ($parameters | has("callerJwtTiering") | not) then true
  elif ($parameters.callerJwtTiering | properties(["value"]) | not) then false
  else $parameters.callerJwtTiering.value as $tiering |
    if ($tiering | properties(["entra", "okta"]) | not) or
       ($tiering.entra | properties(["enabled", "mappings"]) | not) or
       ($tiering.okta | properties(["enabled", "claimName", "mappings"]) | not) then false
    elif ([$tiering.entra.enabled, $tiering.okta.enabled] | all(.[]; type == "boolean") | not) then false
    else
      ($tiering.okta.claimName | matches("\\A[A-Za-z][A-Za-z0-9_.-]{0,63}\\z")) and
      ((["iss", "aud", "sub", "uid", "cid", "scp", "exp", "nbf", "iat", "jti", "azp", "tid", "oid", "idtyp"] | index($tiering.okta.claimName)) == null) and
      ([$tiering.entra, $tiering.okta] | all(.[]; tier_mappings)) and
      (if ($tiering.entra.enabled or $tiering.okta.enabled) then
        (($parameters | has("configureApim") | not) or $parameters.configureApim.value == true) and
        ((["shared", "coexistence"] | index($parameters.callerAuthRollout.value)) != null) and
        $parameters.callerAuthPreparation.value.enabled == true and
        (($tiering.entra.enabled | not) or $parameters.callerAuthPreparation.value.entraEnabled == true) and
        (($tiering.okta.enabled | not) or $parameters.callerAuthPreparation.value.oktaTrust.enabled == true) and
        ($parameters.productTiers.value as $catalog |
          if ($catalog | type) != "array" then false else
            ($catalog | length) > 0 and ($catalog | length) <= 8 and
            ($catalog | all(.[]; (.name | tier_name) and ([.callsPerMinute, .tokensPerMinute, .monthlyCallQuota] | all(.[]; tier_limit)))) and
            (($catalog | map(.name) | unique | length) == ($catalog | length)) and
            ([$tiering.entra.mappings[], $tiering.okta.mappings[]] | all(.[]; .tier as $tier | ($catalog | map(.name) | index($tier)) != null))
          end)
      else true end)
    end
  end) and
  (if ($parameters | has("callerAuthPreparation") | not) then true
  else $parameters.callerAuthPreparation.value as $config |
    if ($config | properties(["enabled", "keyEnabled", "entraEnabled", "entraClientIds", "oktaTrust", "jwtProductId"]) | not) then false
    elif ($config.oktaTrust | properties(["enabled", "issuer", "openIdConfigUrl", "audience", "requiredScope", "clientIds"]) | not) then false
    elif ([$config.enabled, $config.keyEnabled, $config.entraEnabled, $config.oktaTrust.enabled] | all(.[]; type == "boolean") | not) then false
    elif ([$config.entraClientIds, $config.oktaTrust.clientIds] | all(.[]; string_array) | not) then false
    elif ([$config.jwtProductId, $config.oktaTrust.issuer, $config.oktaTrust.openIdConfigUrl, $config.oktaTrust.audience, $config.oktaTrust.requiredScope] | all(.[]; type == "string") | not) then false
    elif ($config.enabled | not) then true
    else $config.oktaTrust as $okta |
      ($config.keyEnabled or $config.entraEnabled or $okta.enabled) and
      ($config.jwtProductId | matches("\\A[A-Za-z0-9_-]{1,80}\\z")) and
      ((($parameters.productTiers.value // [{name:"byok-standard"}, {name:"byok-power"}] | map(.name)) +
        (if $standaloneCloud != "" then ([$parameters.existingProductName.value // ""] + ($parameters.additionalProductNames.value // [])) else [] end)) |
        all(.[]; ascii_downcase != ($config.jwtProductId | ascii_downcase))) and
      ((["AzureCloud", "AzureUSGovernment"] | index($parameters.cloudEnv.value // "AzureUSGovernment")) != null) and
      ((["subscriptionKey", "jwt"] | index($parameters.authMode.value // "subscriptionKey")) != null) and
      (if $config.entraEnabled then
        ([$parameters.entraTenantId.value, $parameters.apiAudience.value] + $config.entraClientIds | all(.[]; guid_value)) and
        ($parameters.requiredScope.value // "cli.invoke" | matches("\\A[A-Za-z0-9._-]{1,128}\\z")) and
        ($config.entraClientIds | all(.[]; . != $parameters.apiAudience.value)) and
        (($config.entraClientIds | unique | length) == ($config.entraClientIds | length)) and
        (($config.entraClientIds | join(",") | length) <= 4096)
      else true end) and
      (if $okta.enabled then
        ($okta.issuer | matches("\\Ahttps://(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}(?::443)?/oauth2/[A-Za-z0-9_-]+\\z")) and
        ($okta.issuer | test("\\.(invalid|localhost)(:443)?/oauth2/") | not) and
        ($okta.openIdConfigUrl == ($okta.issuer + "/.well-known/openid-configuration")) and
        ($okta.audience | matches("\\A[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}\\z")) and
        ($okta.requiredScope | matches("\\A[A-Za-z0-9._-]{1,128}\\z")) and
        (($okta.clientIds | length) > 0) and (($okta.clientIds | join(",") | length) <= 4096) and
        (($okta.clientIds | unique | length) == ($okta.clientIds | length)) and
        ($okta.clientIds | all(.[]; matches("\\A[A-Za-z0-9_-]{1,128}\\z") and . != "__any__" and . != "__none__" and . != $okta.audience))
      else true end)
    end
  end) and
  (if $standaloneCloud != "" and ($parameters.callerAuthRollout.value // "legacy") != "legacy" then
    ($parameters.existingBackendOrigin.value | matches("\\Ahttps://(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}(?::443)?\\z")) and
    ($parameters.existingBackendOrigin.value | test("\\.(invalid|localhost)(:443)?$") | not) and
    (parameter("foundryAuthMode"; "apiKey") as $mode | (["apiKey", "managedIdentity"] | index($mode)) != null and
      ($mode == "managedIdentity" or (($environment.FOUNDRY_API_KEY // "") | test("[^[:space:]]"))))
  else true end) and
  (parameter("callerAuthRollout"; "legacy") as $rollout |
    if (["legacy", "shared", "coexistence"] | index($rollout)) == null then false
    elif $rollout == "legacy" then true
    else $parameters.callerAuthPreparation.value as $config |
      parameter("responseOwnerKey"; "") as $key |
      parameter("responseOwnerPreviousKey"; "") as $previous |
      parameter("deployFoundry"; true) as $foundry |
      parameter("deployAoai"; false) as $aoai |
      parameter("deployFoundryCommercial"; false) as $commercial |
      parameter("foundryRegions"; []) as $foundryRegions |
      parameter("aoaiRegions"; []) as $aoaiRegions |
      $config.enabled == true and
      (if $rollout == "coexistence" then $config.keyEnabled == true and ($config.entraEnabled == true or $config.oktaTrust.enabled == true) else true end) and
      ($key | ownership_key) and ($previous | type == "string") and
      ($previous == "" or (($previous | ownership_key) and $previous != $key)) and
      ([$foundry, $aoai, $commercial] | all(.[]; type == "boolean")) and ($foundry or $aoai) and
      ([$foundryRegions, $aoaiRegions] | all(.[]; type == "array")) and
      (((if $foundry then 1 + ($foundryRegions | length) else 0 end) +
        (if $aoai then 1 + ($aoaiRegions | length) else 0 end) + (if $commercial then 1 else 0 end)) <= 8)
    end)
' "$PARAM_FILE" >/dev/null 2>&1; then
  echo '[provision-params] CALLER AUTH CHECK FAILED: invalid preparation/rollout, enabled trust, ownership keys, response stores or product conflict. See docs/authentication.md. Values are withheld.' >&2
  exit 1
fi
if jq -e '.parameters | has("callerAuthPreparation")' "$PARAM_FILE" >/dev/null; then
  echo '[provision-params] Caller-auth preparation checked; this does not enable API coexistence.'
fi
if [[ -n "$STANDALONE_CLOUD" ]]; then
  echo '[provision-params] Standalone caller trust, native admission, backend origin and ownership secret inputs validated. No deployment was performed.'
  exit 0
fi

if [[ "$STAGE_CALLER_AUTH" == true ]]; then
  if [[ -n "${BYOK_CALLER_AUTH_PREPARATION:-}" || -n "${BYOK_CALLER_AUTH_ROLLOUT:-}" || -n "${BYOK_CALLER_JWT_TIERING:-}" ]] ||
    jq -e '.parameters.callerAuthRollout.value == "shared" or .parameters.callerAuthRollout.value == "coexistence"' "$PARAM_FILE" >/dev/null; then
    mv -f "$STAGED_FILE" "$TARGET_FILE"
  fi
  echo '[provision-params] Caller-auth staging validated; ownership secrets remain environment references. No deployment was performed.'
  exit 0
fi

if [[ "${SKIP_PROVISION_PARAM_CHECK:-}" == "true" ]]; then
  echo '[provision-params] SKIP_PROVISION_PARAM_CHECK=true - skipping legacy backend/advisory checks only.'
  exit 0
fi

# Resolve a parameter value, expanding a sole ${VAR} placeholder against the environment.
resolve_param() {
  local name="$1" raw
  raw="$(jq -r --arg n "$name" '.parameters[$n].value // ""' "$PARAM_FILE")"
  if [[ "$raw" =~ ^\$\{(.+)\}$ ]]; then
    printf '%s' "${!BASH_REMATCH[1]:-}"
  else
    printf '%s' "$raw"
  fi
}

ENV_NAME="${AZURE_ENV_NAME:-$(resolve_param envName)}"
ENV_LABEL="${ENV_NAME:-main.parameters.json}"
IS_PILOT=0; [[ "$ENV_NAME" == *-pilot ]] && IS_PILOT=1

# ---- OPTION 2: Commercial Foundry route HARD gate ----
DEPLOY_COMM="$(resolve_param deployFoundryCommercial)"
if [[ "$DEPLOY_COMM" == "true" ]]; then
  BASE="$(resolve_param foundryCommercialBaseUrl)"
  TENANT="$(resolve_param foundryCommercialTenantId)"
  CLIENT="$(resolve_param foundryCommercialClientId)"
  AUTHMODE="$(resolve_param foundryCommercialAuthMode)"
  SECRET="$(resolve_param foundryCommercialClientSecret)"

  BAD=()
  { [[ -z "$BASE" ]]   || [[ "$BASE" == "https://unset.invalid" ]]; } && BAD+=("foundryCommercialBaseUrl (COMMERCIAL_FOUNDRY_BASE_URL)")
  { [[ -z "$TENANT" ]] || [[ "$TENANT" == "organizations" ]]; }       && BAD+=("foundryCommercialTenantId (COMMERCIAL_TENANT_ID)")
  { [[ -z "$CLIENT" ]] || [[ "$CLIENT" == "unset" ]]; }               && BAD+=("foundryCommercialClientId (COMMERCIAL_CLIENT_ID)")
  if [[ "$AUTHMODE" == "servicePrincipal" && -z "$SECRET" ]]; then BAD+=("foundryCommercialClientSecret (COMMERCIAL_FOUNDRY_CLIENT_SECRET)"); fi

  if [[ ${#BAD[@]} -gt 0 ]]; then
    echo "" >&2
    echo "COMMERCIAL BACKEND CHECK FAILED ($ENV_LABEL)." >&2
    echo "  deployFoundryCommercial=true, but these resolve to empty/placeholder:" >&2
    for b in "${BAD[@]}"; do echo "    - $b" >&2; done
    cat >&2 <<'EOF'

Provisioning now would OVERWRITE the live foundry-commercial-* APIM named values with placeholders
(base-url=https://unset.invalid, auth-mode=servicePrincipalFederated, ...), breaking every
commercial-model request (502). Classic "local azd provision without the COMMERCIAL_* env vars" wipe.
Fix ONE of:
  1. Provision via CI (deploy.yml) - it exports COMMERCIAL_* from the env's GitHub settings.
  2. Or export COMMERCIAL_FOUNDRY_BASE_URL, COMMERCIAL_TENANT_ID, COMMERCIAL_CLIENT_ID
     (+ COMMERCIAL_FOUNDRY_CLIENT_SECRET for servicePrincipal) before provisioning.
  3. Or turn the backend off for this provision: deployFoundryCommercial=false.
  4. Or intentional? Re-run with SKIP_PROVISION_PARAM_CHECK=true.
EOF
    exit 1
  fi
  echo "[provision-params] Commercial route enabled and all COMMERCIAL_* values resolved. OK."
fi

# ---- OPTION 3: general empty-${VAR} substitution scan (advisory; louder on pilots) ----
EMPTY_SUBS=()
while IFS=$'\t' read -r name raw; do
  [[ -n "$name" ]] || continue
  var="${raw#\$\{}"; var="${var%\}}"
  if [[ -z "${!var:-}" ]]; then EMPTY_SUBS+=("$name (\${$var})"); fi
done < <(jq -r '.parameters | to_entries[] | select(.value.value | type=="string" and test("^\\$\\{.+\\}$")) | "\(.key)\t\(.value.value)"' "$PARAM_FILE")

if [[ ${#EMPTY_SUBS[@]} -gt 0 ]]; then
  echo ""
  echo "[provision-params] NOTE ($ENV_LABEL): ${#EMPTY_SUBS[@]} parameter(s) reference an env var that is EMPTY and will deploy blank:"
  for e in "${EMPTY_SUBS[@]}"; do echo "    - $e"; done
  if [[ $IS_PILOT -eq 1 ]]; then
    echo ""
    echo "  This is a PILOT env. If any of the above are currently populated LIVE, this provision will WIPE them."
    echo "  That is exactly what a LOCAL 'azd provision' missing the CI env vars does. Strongly prefer CI, or export"
    echo "  the values first. (Intentional cases like the register Easy Auth two-phase bring-up are expected.)"
  fi
fi

exit 0
