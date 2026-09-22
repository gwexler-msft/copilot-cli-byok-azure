#!/usr/bin/env bash
# Discover which API surface(s) each deployed model supports, per APIM route, and write the
# resulting model->types capability map into the committed CI param file. (Issue #119 Phase 1 / #122.)
#
# HYBRID discovery (decision locked on #122):
#   1. ENUMERATE  - GET <gateway>/<route>/v1/models -> model id list.
#   2. PROBE      - for each model, POST a minimal request to each candidate surface through the
#                   SAME gateway route; 2xx => supported, typed 4xx (400/404/405/422) => unsupported.
#                   (/v1/models exposes no `responses` capability flag, so surfaces are PROBED.)
# Surfaces: chat/completions, responses, messages (Anthropic), and embeddings with --include-embeddings.
#
# Result: compact JSON { "<model>": ["chat/completions","responses",...], ... } written into the CI
# param file under the route's key (foundryModelTypes | aoaiModelTypes).
# The param file is AUTHORITATIVE; a provision applies the named value. `az apim nv update` only runs
# with --also-write-named-value (instant, non-authoritative dev refresh).
#
# NOT probed: the commercial map (foundryCommercialModelTypes / foundry-commercial-model-types). It is
# still live - the /anthropic route policy reads it - but commercial models are now selected by the
# commercial-models sentinel on /openai rather than by a route of their own, and /anthropic exposes
# only /v1/messages (no /v1/models to enumerate). Maintain that map by hand in the CI param file.
#
# The subscription key is read from an env var (default BYOK_DISCOVERY_KEY) and sent in the api-key
# header; it is NEVER echoed, logged, or passed on the command line.
#
# Usage:
#   export BYOK_DISCOVERY_KEY='<subscription-key>'   # set out-of-band; not echoed
#   ./scripts/discover-model-types.sh --apim-name <apim> --resource-group <rg> \
#       --routes openai --param-file infra/main.parameters.ci.commercial.json
set -euo pipefail

GATEWAY_URL=""
APIM_NAME=""
RESOURCE_GROUP=""
ROUTES="openai"
PARAM_FILE=""
API_KEY_ENV_VAR="BYOK_DISCOVERY_KEY"
INCLUDE_EMBEDDINGS=0
ALSO_WRITE_NV=0
TIMEOUT=40

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gateway-url) GATEWAY_URL="$2"; shift 2 ;;
    --apim-name) APIM_NAME="$2"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --routes) ROUTES="$2"; shift 2 ;;
    --param-file) PARAM_FILE="$2"; shift 2 ;;
    --api-key-env-var) API_KEY_ENV_VAR="$2"; shift 2 ;;
    --include-embeddings) INCLUDE_EMBEDDINGS=1; shift ;;
    --also-write-named-value) ALSO_WRITE_NV=1; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required." >&2; exit 2; }

API_KEY="${!API_KEY_ENV_VAR:-}"
if [[ -z "$API_KEY" ]]; then
  echo "ERROR: APIM subscription key not found. Export \$$API_KEY_ENV_VAR out-of-band (never echoed)." >&2
  exit 2
fi

if [[ -z "$GATEWAY_URL" ]]; then
  if [[ -z "$APIM_NAME" || -z "$RESOURCE_GROUP" ]]; then
    echo "ERROR: provide --gateway-url, or both --apim-name and --resource-group." >&2
    exit 2
  fi
  GATEWAY_URL="$(az apim show -g "$RESOURCE_GROUP" -n "$APIM_NAME" --query 'gatewayUrl' -o tsv)"
  [[ -n "$GATEWAY_URL" ]] || { echo "ERROR: could not resolve gateway URL." >&2; exit 2; }
fi
GATEWAY_URL="${GATEWAY_URL%/}"

# route -> CI param key + named-value name (Phase 1 storage side, apim-named-values.bicep)
route_param() {
  case "$1" in
    openai) echo "foundryModelTypes" ;;
    aoai) echo "aoaiModelTypes" ;;
    *) echo "" ;;
  esac
}
route_nv() {
  case "$1" in
    openai) echo "foundry-model-types" ;;
    aoai) echo "aoai-model-types" ;;
    *) echo "" ;;
  esac
}

# Probe one surface; echo 1 (supported, 2xx), 0 (typed 4xx = unsupported), or "" (inconclusive).
probe() {
  local url="$1" body="$2" code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" \
      -H "api-key: $API_KEY" -H 'content-type: application/json' \
      -X POST "$url" -d "$body" 2>/dev/null || echo 000)"
  if [[ "$code" -ge 200 && "$code" -lt 300 ]]; then echo 1
  elif [[ "$code" == 400 || "$code" == 404 || "$code" == 405 || "$code" == 422 ]]; then echo 0
  else echo ""; fi
}

get_model_ids() {
  local base="$1" body
  body="$(curl -sS --max-time "$TIMEOUT" -H "api-key: $API_KEY" "$base/v1/models" 2>/dev/null || echo '')"
  [[ -n "$body" ]] || { return 0; }
  echo "$body" | jq -r '.data[]?.id // empty' 2>/dev/null | grep -viE '^(auto|byok-auto)$' || true
}

# Build the { model: [types] } object for one route, printed as compact JSON to stdout.
route_map() {
  local base="$1" route="$2"
  local ids; ids="$(get_model_ids "$base")"
  if [[ -z "$ids" ]]; then echo "    (no models enumerated on /$route)" >&2; echo '{}'; return; fi
  echo "    models: $(echo "$ids" | paste -sd, -)" >&2

  local obj='{}' model types
  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    types='[]'
    # NOTE: chat/completions probe uses max_completion_tokens (NOT max_tokens) - the gpt-5.x family
    # 400s on max_tokens, which would FALSE-NEGATIVE chat/completions support.
    [[ "$(probe "$base/v1/chat/completions" "$(jq -nc --arg m "$model" '{model:$m,messages:[{role:"user",content:"ping"}],max_completion_tokens:16}')")" == 1 ]] \
      && types="$(echo "$types" | jq -c '. + ["chat/completions"]')"
    [[ "$(probe "$base/v1/responses" "$(jq -nc --arg m "$model" '{model:$m,input:"ping",max_output_tokens:16}')")" == 1 ]] \
      && types="$(echo "$types" | jq -c '. + ["responses"]')"
    [[ "$(probe "$base/v1/messages" "$(jq -nc --arg m "$model" '{model:$m,messages:[{role:"user",content:"ping"}],max_tokens:1}')")" == 1 ]] \
      && types="$(echo "$types" | jq -c '. + ["messages"]')"
    if [[ "$INCLUDE_EMBEDDINGS" == 1 ]]; then
      [[ "$(probe "$base/v1/embeddings" "$(jq -nc --arg m "$model" '{model:$m,input:"ping"}')")" == 1 ]] \
        && types="$(echo "$types" | jq -c '. + ["embeddings"]')"
    fi
    echo "      $model -> $types" >&2
    obj="$(echo "$obj" | jq -c --arg m "$model" --argjson t "$types" '. + {($m): $t}')"
  done <<< "$ids"
  echo "$obj"
}

update_param_file() {
  local path="$1" key="$2" compact="$3"
  [[ -f "$path" ]] || { echo "ERROR: param file not found: $path" >&2; exit 2; }
  local tmp; tmp="$(mktemp)"
  jq --arg k "$key" --argjson v "$compact" \
     '.parameters[$k] = {value: ($v | tojson)}' "$path" > "$tmp"
  mv "$tmp" "$path"
  echo "    wrote $key ($(echo "$compact" | jq 'length') models) -> $path"
}

echo "Gateway: $GATEWAY_URL"
echo "Routes : $ROUTES"
echo

IFS=',' read -ra ROUTE_ARR <<< "$ROUTES"
for route in "${ROUTE_ARR[@]}"; do
  key="$(route_param "$route")"
  if [[ -z "$key" ]]; then echo "Unknown route '$route' (no param mapping); skipping." >&2; continue; fi
  echo "== /$route ==" >&2
  compact="$(route_map "$GATEWAY_URL/$route" "$route")"
  [[ "$compact" == '{}' ]] && continue

  if [[ -n "$PARAM_FILE" ]]; then
    update_param_file "$PARAM_FILE" "$key" "$compact"
  else
    echo "-- /$route ($key) --"
    echo "$compact"
  fi

  if [[ "$ALSO_WRITE_NV" == 1 ]]; then
    nv="$(route_nv "$route")"
    if [[ -z "$APIM_NAME" || -z "$RESOURCE_GROUP" ]]; then
      echo "    --also-write-named-value needs --apim-name/--resource-group; skipped." >&2
    else
      az apim nv update -g "$RESOURCE_GROUP" --service-name "$APIM_NAME" --named-value-id "$nv" --value "$compact" >/dev/null \
        && echo "    az apim nv update $nv OK (non-authoritative dev refresh)" \
        || echo "    az apim nv update $nv failed" >&2
    fi
  fi
done

echo
echo "Done."
exit 0
