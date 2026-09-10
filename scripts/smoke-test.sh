#!/usr/bin/env bash
# End-to-end smoke test for a deployed BYOK gateway env (#56). See
# scripts/smoke-test.ps1 for full docs; this is the bash counterpart used
# by the self-hosted runner Linux containers.
#
# Usage:
#   ./scripts/smoke-test.sh                       # uses AZURE_ENV_NAME / azd defaults
#   ./scripts/smoke-test.sh --env-name comm-pilot
#   ./scripts/smoke-test.sh --skip-token-limit
#
# Requires: jq, az, gh (for some workflows). Will exit 0 on full pass, 1 on any fail,
# 2 on usage/config errors.

set -uo pipefail

ENV_NAME="${AZURE_ENV_NAME:-}"
RESOURCE_GROUP=""
APIM_NAME=""
APP_INSIGHTS_NAME=""
PRIMARY_MODEL="gpt-5.6-sol"
MINI_MODEL="gpt-5.6-luna"
# A model deployed ONLY on the Commercial Foundry (not available in Gov). Assertion 3a calls it
# through the DEFAULT /openai route, where the `commercial-models` sentinel selects the commercial
# Foundry backend, to prove the cross-cloud path reaches a Gov-unavailable model. It is a reasoning
# model, so the probe gives it a generous completion budget and asserts on the echoed model name
# (content may be empty when reasoning eats the budget).
COMMERCIAL_ONLY_MODEL=""
# Number of PROMPT tokens per request in assertion 5's token burst. The
# token-limit policy's estimate-prompt-tokens counts PROMPT tokens on the inbound
# (NOT max_completion_tokens) and accumulates them per subscription, so the probe
# sends a BURST of moderate, well-formed requests until the product's
# tokens-per-minute (byok-standard default 100000 TPM) is spent and the gateway
# returns 429. ~1 token per word; each body stays small enough for the gateway to
# buffer/parse (a single 300k-token prompt 400s with ModelNotSpecified before the
# throttle can fire). Keep OVERSIZED_TOKENS x TOKEN_BURST_MAX above the tier TPM
# (8000 x 20 = 160k vs a 100k ceiling) or this assertion reports a false FAIL.
OVERSIZED_TOKENS=8000
TOKEN_BURST_MAX=20
SKIP_TOKEN_LIMIT=0
# Assertion 9 (sub-key provisioning round-trip) settings. PROVISION_PRODUCT is the tier the
# ephemeral probe subscription is scoped to (register app's DefaultProductId). The probe MUTATES
# APIM (creates + deletes a throwaway subscription); --skip-provision-probe opts out entirely.
PROVISION_PRODUCT="byok-standard"
SKIP_PROVISION_PROBE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-name)            ENV_NAME="$2"; shift 2;;
    --resource-group)      RESOURCE_GROUP="$2"; shift 2;;
    --apim-name)           APIM_NAME="$2"; shift 2;;
    --app-insights-name)   APP_INSIGHTS_NAME="$2"; shift 2;;
    --primary-model)       PRIMARY_MODEL="$2"; shift 2;;
    --mini-model)          MINI_MODEL="$2"; shift 2;;
    --commercial-only-model) COMMERCIAL_ONLY_MODEL="$2"; shift 2;;
    --oversized-tokens)    OVERSIZED_TOKENS="$2"; shift 2;;
    --skip-token-limit)    SKIP_TOKEN_LIMIT=1; shift;;
    --provision-product)   PROVISION_PRODUCT="$2"; shift 2;;
    --skip-provision-probe) SKIP_PROVISION_PROBE=1; shift;;
    -h|--help)             sed -n '2,15p' "$0"; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

results=()
pass_n=0; fail_n=0; skip_n=0
cyan()   { printf '\033[36m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
add_result() {
  local status="$1" name="$2" detail="${3:-}"
  results+=("$status|$name|$detail")
  case "$status" in
    PASS) green   "    [PASS] $name ${detail}"; pass_n=$((pass_n+1));;
    FAIL) red     "    [FAIL] $name ${detail}"; fail_n=$((fail_n+1));;
    SKIP) yellow  "    [SKIP] $name ${detail}"; skip_n=$((skip_n+1));;
  esac
}

# ---------- setup: resolve env, APIM gateway, dev keys ----------
cyan "==> Setup"
if [[ -z "$ENV_NAME" ]]; then
  ENV_NAME="$(azd env get-value AZURE_ENV_NAME 2>/dev/null || true)"
fi
if [[ -z "$ENV_NAME" ]]; then
  red "ERROR: --env-name not supplied and AZURE_ENV_NAME / azd default env not set."
  exit 2
fi
echo "    EnvName        = $ENV_NAME"

# Pull from azd env get-values (key=value lines).
declare -A envv
while IFS='=' read -r k v; do
  [[ -z "$k" ]] && continue
  v="${v%\"}"; v="${v#\"}"
  envv["$k"]="$v"
done < <(azd env get-values --output dotenv 2>/dev/null || true)

: "${RESOURCE_GROUP:=${envv[RESOURCE_GROUP]:-}}"
: "${APIM_NAME:=${envv[APIM_NAME]:-}}"
: "${APP_INSIGHTS_NAME:=${envv[APP_INSIGHTS_NAME]:-}}"
: "${RESOURCE_GROUP:=rg-copilot-byok-$ENV_NAME}"

if [[ -z "$APIM_NAME" && -n "$RESOURCE_GROUP" ]]; then
  APIM_NAME="$(az apim list -g "$RESOURCE_GROUP" --query '[0].name' -o tsv 2>/dev/null || true)"
fi
if [[ -z "$APP_INSIGHTS_NAME" && -n "$RESOURCE_GROUP" ]]; then
  APP_INSIGHTS_NAME="$(az resource list -g "$RESOURCE_GROUP" --resource-type Microsoft.Insights/components --query '[0].name' -o tsv 2>/dev/null || true)"
fi
[[ -z "$APIM_NAME" ]]        && { red "ERROR: cannot determine APIM name (use --apim-name)."; exit 2; }
[[ -z "$APP_INSIGHTS_NAME" ]] && { red "ERROR: cannot determine App Insights name (use --app-insights-name)."; exit 2; }

APIM_GW="$(az apim show -g "$RESOURCE_GROUP" -n "$APIM_NAME" --query 'gatewayUrl' -o tsv)"
[[ -z "$APIM_GW" ]] && { red "ERROR: cannot read APIM gateway URL."; exit 2; }

echo "    ResourceGroup  = $RESOURCE_GROUP"
echo "    ApimName       = $APIM_NAME"
echo "    GatewayUrl     = $APIM_GW"
echo "    AppInsights    = $APP_INSIGHTS_NAME"

# Ensure the application-insights CLI extension is present (KQL-via-CLI in
# assertion 4 lives in that extension). Idempotent on the comm-pilot wizard
# machine where it's preinstalled; needed on fresh ACA Job runner containers
# that get a bare apt-installed az with no extensions.
if ! az extension show --name application-insights >/dev/null 2>&1; then
  az extension add --name application-insights --only-show-errors --yes >/dev/null 2>&1 || true
fi

SUBSCRIPTION_ID="$(az account show --query id -o tsv 2>/dev/null || true)"
# Cloud-aware ARM endpoint (#59): hardcoding management.azure.com broke gov.
# Resolves to:
#   AzureCloud         -> https://management.azure.com
#   AzureUSGovernment  -> https://management.usgovcloudapi.net
#   AzureChinaCloud    -> https://management.chinacloudapi.cn
ARM_ENDPOINT="$(az cloud show --query 'endpoints.resourceManager' -o tsv 2>/dev/null | sed 's:/*$::')"
: "${ARM_ENDPOINT:=https://management.azure.com}"

get_dev_key() {
  local sid="$1"
  # APIM subscription primary key. `az apim subscription` doesn't exist in
  # current az CLI (and there's no `apim` extension that adds it), so call
  # the ARM listSecrets endpoint directly via `az rest`. The host MUST come
  # from `az cloud show` (#59) -- a hardcoded management.azure.com fails on
  # gov clouds and the whole smoke run cascades to SKIP.
  [[ -z "$SUBSCRIPTION_ID" ]] && return 1
  az rest --method POST \
    --url "${ARM_ENDPOINT}/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/subscriptions/${sid}/listSecrets?api-version=2024-05-01" \
    --query 'primaryKey' -o tsv 2>/dev/null
}
DEV1_KEY="$(get_dev_key dev1 || true)"
DEV2_KEY="$(get_dev_key dev2 || true)"
# Model listing (GET /v1/models) is served by the foundry inference API to ANY valid
# inference key. The dedicated 'discovery' API + 'smoke' subscription were consolidated
# away (they returned the same list), so we assert with the normal dev1 tier key.

# ---------- assertion 1: list models ----------
cyan "==> Assertion 1: GET /openai/v1/models"
if [[ -z "$DEV1_KEY" ]]; then
  add_result SKIP list-models "(no dev1 key)"
else
  # Capture HTTP status + body separately so we can diagnose FAILs without
  # re-running. -w '%{http_code}' appends the code; we split it off the tail.
  # This is the FIRST request to the gateway AND the models op proxies to the Foundry
  # backend via a managed-identity token (see byok-foundry-models-policy*.xml).
  # On a freshly-provisioned ephemeral dev env the APIM-MI -> Foundry RBAC is still
  # propagating and the AIServices account is cold, so this first hit can hang for
  # minutes (curl reports HTTP 000 / empty body) while the next chat assertion gets
  # 200 seconds later. Poll with a SHORT per-attempt ceiling (20s) and MANY
  # attempts (15): the short timeout makes a warm env return in one fast hit and
  # break immediately, while the larger attempt count (~370s total budget incl. the
  # 5s backoffs) stays patient through a cold scheduled bootstrap. Retry only on
  # transient classes (000 / empty body / 5xx).
  list_attempts=15
  status=""; body=""
  for attempt in $(seq 1 "$list_attempts"); do
    raw="$(curl -sk --max-time 20 -w '\n__STATUS__%{http_code}' -H "api-key: $DEV1_KEY" "$APIM_GW/openai/v1/models")"
    status="${raw##*__STATUS__}"
    body="${raw%$'\n'__STATUS__*}"
    if [[ -n "$body" && "$status" != "000" && "$status" != 5* ]]; then break; fi
    [[ $attempt -lt $list_attempts ]] && sleep 5
  done
  if [[ -z "$body" ]]; then
    add_result FAIL list-models "(HTTP $status; empty body after $list_attempts attempts)"
  else
    ids="$(echo "$body" | jq -r '.data[]?.id' 2>/dev/null || true)"
    has_primary=0; has_mini=0
    [[ "$ids" == *"$PRIMARY_MODEL"* ]] && has_primary=1
    [[ "$ids" == *"$MINI_MODEL"* ]]    && has_mini=1
    count="$(echo "$ids" | grep -c . || true)"
    if [[ $has_primary -eq 1 && $has_mini -eq 1 ]]; then
      add_result PASS list-models "(HTTP $status; found $count models incl. $PRIMARY_MODEL + $MINI_MODEL)"
    else
      # Print first 400 chars of body to job log so we can diagnose without re-running.
      body_snippet="$(printf '%s' "$body" | head -c 400 | tr '\n' ' ')"
      add_result FAIL list-models "(HTTP $status; expected $PRIMARY_MODEL + $MINI_MODEL; got ids: '$(echo "$ids" | tr '\n' ',' | sed 's/,$//')'; body[0:400]='$body_snippet')"
    fi
  fi
fi

# ---------- assertions 2 & 3: chat completions ----------
chat_probe() {
  local sid="$1" key="$2"
  local name="chat-$sid"
  if [[ -z "$key" ]]; then add_result SKIP "$name" "(no key available)"; return; fi
  local payload status content
  payload="$(jq -nc --arg m "$PRIMARY_MODEL" '{model:$m, messages:[{role:"user", content:"Reply with the single word: pong."}], max_completion_tokens:50}')"
  http_response="$(curl -sk --max-time 60 -o /tmp/smoke_chat.json -w '%{http_code}' \
    -H "api-key: $key" -H 'Content-Type: application/json' \
    -X POST -d "$payload" "$APIM_GW/openai/v1/chat/completions")"
  status="$http_response"
  if [[ "$status" == "200" ]]; then
    content="$(jq -r '.choices[0].message.content // ""' /tmp/smoke_chat.json | tr '\n' ' ' | sed 's/  */ /g')"
    model="$(jq -r '.model // ""' /tmp/smoke_chat.json)"
    if [[ -n "$content" ]]; then
      snippet="${content:0:40}"; [[ "${#content}" -gt 40 ]] && snippet="${snippet}..."
      add_result PASS "$name" "(model=$model; reply='$snippet')"
    else
      add_result FAIL "$name" "(200 but empty content)"
    fi
  else
    snippet="$(head -c 200 /tmp/smoke_chat.json 2>/dev/null || true)"
    add_result FAIL "$name" "(HTTP $status; body=$snippet)"
  fi
}
cyan "==> Assertion 2: chat completions with dev1 key"
chat_probe dev1 "$DEV1_KEY"
cyan "==> Assertion 3: chat completions with dev2 key"
chat_probe dev2 "$DEV2_KEY"

# ---------- assertion 3a: Responses auto-route and Copilot request compatibility ----------
# /responses is account-root and selects the deployment from body.model. A short, non-coding
# prompt must replace the auto sentinel with the configured cheap tier before forwarding.
# Copilot clients may send top-level snippy metadata, which native Azure endpoints reject.
responses_auto_probe() {
  local key="$1" name="responses-auto"
  if [[ -z "$key" ]]; then add_result SKIP "$name" "(no dev1 key)"; return; fi
  local payload status model snippet
  payload="$(jq -nc '{model:"auto", input:"Reply with the single word: pong.", reasoning:{effort:"none"}, snippy:{enabled:true}, max_output_tokens:50}')"
  status="$(curl -sk --max-time 60 -o /tmp/smoke_responses_auto.json -w '%{http_code}' \
    -H "api-key: $key" -H 'Content-Type: application/json' \
    -X POST -d "$payload" "$APIM_GW/openai/v1/responses")"
  model="$(jq -r '.model // ""' /tmp/smoke_responses_auto.json 2>/dev/null || true)"
  if [[ "$status" == "200" && ( "$model" == "$MINI_MODEL" || "$model" == "$MINI_MODEL-"* ) ]]; then
    add_result PASS "$name" "(auto resolved to $model on /responses)"
  else
    snippet="$(head -c 240 /tmp/smoke_responses_auto.json 2>/dev/null | tr '\n' ' ' || true)"
    add_result FAIL "$name" "(HTTP $status; expected model=$MINI_MODEL, got '$model'; body=$snippet)"
  fi
}
cyan "==> Assertion 3a: Responses auto-route and Copilot request compatibility"
responses_auto_probe "$DEV1_KEY"

# ---------- assertion: unsupported API surface -> typed 400 (#119 Phase 2 / #120) ----------
# PRIMARY_MODEL (gpt-5.6-sol) supports [chat/completions, responses] but NOT embeddings, so when the
# discovered {{foundry-model-types}} map is populated an embeddings request returns a typed
# 400 UnsupportedApiTypeForModel. SKIP on any non-400 (map not populated on this env -> keep
# other envs green).
unsupported_surface_probe() {
  local key="$1" name="unsupported-surface"
  if [[ -z "$key" ]]; then add_result SKIP "$name" "(no dev1 key)"; return; fi
  local payload status code supported snippet
  payload="$(jq -nc --arg m "$PRIMARY_MODEL" '{model:$m, input:"x"}')"
  status="$(curl -sk --max-time 40 -o /tmp/smoke_unsup.json -w '%{http_code}' \
    -H "api-key: $key" -H 'Content-Type: application/json' \
    -X POST -d "$payload" "$APIM_GW/openai/v1/embeddings")"
  code="$(jq -r '.error.code // ""' /tmp/smoke_unsup.json 2>/dev/null || true)"
  if [[ "$status" == "400" && "$code" == "UnsupportedApiTypeForModel" ]]; then
    supported="$(jq -c '.error.supported_types // []' /tmp/smoke_unsup.json 2>/dev/null || echo '[]')"
    add_result PASS "$name" "(400 UnsupportedApiTypeForModel; embeddings on $PRIMARY_MODEL rejected; supported=$supported)"
  else
    snippet="$(head -c 160 /tmp/smoke_unsup.json 2>/dev/null | tr '\n' ' ' || true)"
    add_result SKIP "$name" "(map likely not populated on this env; HTTP $status code='$code' body=$snippet)"
  fi
}
cyan "==> Assertion: unsupported API surface -> typed 400 (#120)"
unsupported_surface_probe "$DEV1_KEY"

# ---------- assertion 3a: commercial model via the DEFAULT /openai route (Copilot CLI path, #118) ----------
# The CLI azure provider can ONLY reach /openai/v1/chat/completions (it discards the base-URL path).
# When COMMERCIAL_ONLY_MODEL is listed in the env's `commercialModels`, the default policy routes it
# to the commercial Foundry cross-cloud. Asserts a commercial-only model works via the PLAIN default
# route -- the actual CLI scenario. SKIP on 404 (commercialModels not set here -> routed to gov
# Foundry, not found); 403-firewall-on-dev SKIP; 502 = commercial routing/auth broken -> FAIL.
commercial_via_default_probe() {
  local key="$1" name="commercial-via-default"
  if [[ -z "$key" ]]; then add_result SKIP "$name" "(no dev1 key)"; return; fi
  if [[ -z "$COMMERCIAL_ONLY_MODEL" ]]; then add_result SKIP "$name" "(no commercial-only model configured)"; return; fi
  local payload status model snippet
  payload="$(jq -nc --arg m "$COMMERCIAL_ONLY_MODEL" '{model:$m, messages:[{role:"user", content:"Reply with the single word: pong."}], max_completion_tokens:400}')"
  status="$(curl -sk --max-time 60 -o /tmp/smoke_comm_default.json -w '%{http_code}' \
    -H "api-key: $key" -H 'Content-Type: application/json' \
    -X POST -d "$payload" "$APIM_GW/openai/v1/chat/completions")"
  if [[ "$status" == "404" ]]; then
    add_result SKIP "$name" "(commercialModels not configured on this env -- '$COMMERCIAL_ONLY_MODEL' routed to gov Foundry, not found)"
  elif [[ "$status" == "200" ]]; then
    model="$(jq -r '.model // ""' /tmp/smoke_comm_default.json)"
    if [[ "$model" == "$COMMERCIAL_ONLY_MODEL"* ]]; then
      add_result PASS "$name" "(model=$model; commercial model served via plain /openai route -- CLI path works)"
    else
      add_result FAIL "$name" "(200 but echoed model='$model', expected '$COMMERCIAL_ONLY_MODEL'*)"
    fi
  elif [[ "$status" == "403" ]]; then
    if [[ "$ENV_NAME" == *-dev ]]; then
      add_result SKIP "$name" "(HTTP 403 firewall; ephemeral dev NAT egress IP not on the Commercial Foundry allowlist)"
    else
      snippet="$(head -c 200 /tmp/smoke_comm_default.json 2>/dev/null | tr '\n' ' ' || true)"
      add_result FAIL "$name" "(HTTP 403; body=$snippet)"
    fi
  else
    snippet="$(head -c 200 /tmp/smoke_comm_default.json 2>/dev/null | tr '\n' ' ' || true)"
    add_result FAIL "$name" "(HTTP $status; body=$snippet)"
  fi
}
cyan "==> Assertion 3a: commercial model via default /openai route (Copilot CLI path, #118)"
commercial_via_default_probe "$DEV1_KEY"

# ---------- assertion 3b2: native Anthropic route (/anthropic, x-api-key) ----------
# Proves the THREE things that make the /anthropic route worth having, without needing a Claude
# model deployed:
#   1. the route exists and the operation matches   (not 404)
#   2. the per-developer subscription key validates from the 'x-api-key' HEADER (not 401) -- this
#      is the entire reason the route is a separate APIM API, since APIM validates the key from
#      the API's declared header BEFORE any policy runs and /openai declares 'api-key'
#   3. the wire-format guard runs and EXPLAINS instead of reshaping (typed 400 WireFormatMismatch)
# We deliberately send an OPENAI-shaped body (system role message) so the expected result is the
# typed 400. A 401 here is the interesting failure: it means the key was not accepted on
# x-api-key, i.e. subscriptionKeyParameterNames did not take effect.
anthropic_route_probe() {
  local key="$1" name="anthropic-route"
  if [[ -z "$key" ]]; then add_result SKIP "$name" "(no dev1 key)"; return; fi
  local payload status code
  payload="$(jq -nc --arg m "$PRIMARY_MODEL" '{model:$m, messages:[{role:"system", content:"You are a test."},{role:"user", content:"ping"}]}')"
  status="$(curl -sk --max-time 60 -o /tmp/smoke_anthropic.json -w '%{http_code}' \
    -H "x-api-key: $key" -H 'Content-Type: application/json' \
    -X POST -d "$payload" "$APIM_GW/anthropic/v1/messages")"
  code="$(jq -r '.error.code // ""' /tmp/smoke_anthropic.json 2>/dev/null || true)"
  if [[ "$status" == "404" ]]; then
    add_result SKIP "$name" "(/anthropic not deployed on this env)"
  elif [[ "$status" == "401" ]]; then
    add_result FAIL "$name" "(HTTP 401 -- the subscription key was NOT accepted from the x-api-key header; check subscriptionKeyParameterNames on the anthropic API and that it is linked into the product tiers)"
  elif [[ "$status" == "400" && "$code" == "WireFormatMismatch" ]]; then
    add_result PASS "$name" "(key accepted on x-api-key; OpenAI-shaped body correctly refused with typed 400 WireFormatMismatch instead of being reshaped)"
  else
    local snippet; snippet="$(head -c 200 /tmp/smoke_anthropic.json 2>/dev/null | tr '\n' ' ' || true)"
    add_result FAIL "$name" "(HTTP $status code='$code'; expected 400 WireFormatMismatch; body=$snippet)"
  fi
}
cyan "==> Assertion 3b2: native Anthropic route (/anthropic, x-api-key auth + wire-format guard)"
anthropic_route_probe "$DEV1_KEY"

# ---------- assertion 3c: stateful Responses sub-resources (#110) ----------
# Round-trips the surface agentic clients need for store:true / background / resumable turns:
#   POST /v1/responses (store:true) -> id  ->  GET /v1/responses/{id}  ->  DELETE /v1/responses/{id}
# The GET is the assertion that matters: it proves the operation matches (not 404) AND that the
# operation-scoped policy skipped the API inference policy -- a body-less GET would otherwise hit
# its ModelNotSpecified 400, which is exactly the bug this surface is prone to.
responses_item_probe() {
  local key="$1" name="responses-subresources"
  if [[ -z "$key" ]]; then add_result SKIP "$name" "(no dev1 key)"; return; fi
  local payload create_status rid get_status del_status code
  payload="$(jq -nc --arg m "$PRIMARY_MODEL" '{model:$m, input:"Reply with the single word: pong.", store:true}')"
  create_status="$(curl -sk --max-time 60 -o /tmp/smoke_resp_create.json -w '%{http_code}' \
    -H "api-key: $key" -H 'Content-Type: application/json' \
    -X POST -d "$payload" "$APIM_GW/openai/v1/responses")"
  if [[ "$create_status" != "200" ]]; then
    add_result SKIP "$name" "(could not create a stored response; POST /v1/responses HTTP $create_status)"
    return
  fi
  rid="$(jq -r '.id // ""' /tmp/smoke_resp_create.json 2>/dev/null || true)"
  if [[ -z "$rid" ]]; then add_result SKIP "$name" "(POST /v1/responses 200 but no .id in the body)"; return; fi

  for attempt in $(seq 1 6); do
    get_status="$(curl -sk --max-time 60 -o /tmp/smoke_resp_get.json -w '%{http_code}' \
      -H "api-key: $key" "$APIM_GW/openai/v1/responses/$rid")"
    [[ "$get_status" != "404" ]] && break
    [[ $attempt -lt 6 ]] && sleep 2
  done
  code="$(jq -r '.error.code // ""' /tmp/smoke_resp_get.json 2>/dev/null || true)"

  if [[ "$get_status" == "404" ]]; then
    local snippet; snippet="$(head -c 300 /tmp/smoke_resp_get.json 2>/dev/null | tr '\n' ' ' || true)"
    add_result FAIL "$name" "(GET /v1/responses/{id} HTTP 404; code='$code'; body=$snippet)"
    return
  elif [[ "$get_status" == "400" && "$code" == "ModelNotSpecified" ]]; then
    add_result FAIL "$name" "(GET /v1/responses/{id} hit the inference body-parse guard -- the operation-scoped policy is not applied, it must omit <base />)"
    return
  elif [[ "$get_status" != "200" ]]; then
    local snippet; snippet="$(head -c 200 /tmp/smoke_resp_get.json 2>/dev/null | tr '\n' ' ' || true)"
    add_result FAIL "$name" "(GET /v1/responses/{id} HTTP $get_status; body=$snippet)"
    return
  fi

  # DELETE is an ACCEPTANCE criterion (200/204), not just cleanup. A 404 is ambiguous on its own -
  # the resource may already be gone, or the DELETE operation may not be routing at all - so
  # re-GET to tell those apart instead of passing regardless, which is what used to happen here.
  del_status="$(curl -sk --max-time 60 -o /dev/null -w '%{http_code}' \
    -H "api-key: $key" -X DELETE "$APIM_GW/openai/v1/responses/$rid")"
  if [[ "$del_status" == "200" || "$del_status" == "204" ]]; then
    add_result PASS "$name" "(POST store:true -> GET {id} 200 -> DELETE $del_status; body-less GET did not hit the inference 400-guard)"
  elif [[ "$del_status" == "404" ]]; then
    local recheck
    recheck="$(curl -sk --max-time 60 -o /dev/null -w '%{http_code}' \
      -H "api-key: $key" "$APIM_GW/openai/v1/responses/$rid")"
    if [[ "$recheck" == "404" ]]; then
      add_result PASS "$name" "(GET {id} 200; DELETE 404 but the response is GONE on re-GET -- backend treats it as already-deleted)"
    else
      add_result FAIL "$name" "(DELETE {id} 404 and the response STILL EXISTS on re-GET HTTP $recheck -- the DELETE operation is not routing)"
    fi
  else
    add_result FAIL "$name" "(DELETE /v1/responses/{id} HTTP $del_status; expected 200/204)"
  fi
}

# ---------- assertion 3d: /v1/responses/{id}/input_items (#110) ----------
# Separate assertion so a missing sub-path is visible instead of hiding inside the round-trip.
responses_input_items_probe() {
  local key="$1" name="responses-input-items"
  if [[ -z "$key" ]]; then add_result SKIP "$name" "(no dev1 key)"; return; fi
  local payload create_status rid status code is_list
  payload="$(jq -nc --arg m "$PRIMARY_MODEL" '{model:$m, input:"Reply with the single word: pong.", store:true}')"
  create_status="$(curl -sk --max-time 60 -o /tmp/smoke_items_create.json -w '%{http_code}' \
    -H "api-key: $key" -H 'Content-Type: application/json' \
    -X POST -d "$payload" "$APIM_GW/openai/v1/responses")"
  if [[ "$create_status" != "200" ]]; then
    add_result SKIP "$name" "(could not create a stored response; POST /v1/responses HTTP $create_status)"; return
  fi
  rid="$(jq -r '.id // ""' /tmp/smoke_items_create.json 2>/dev/null || true)"
  if [[ -z "$rid" ]]; then add_result SKIP "$name" "(POST /v1/responses 200 but no .id in the body)"; return; fi

  for attempt in $(seq 1 6); do
    status="$(curl -sk --max-time 60 -o /tmp/smoke_items.json -w '%{http_code}' \
      -H "api-key: $key" "$APIM_GW/openai/v1/responses/$rid/input_items")"
    [[ "$status" != "404" ]] && break
    [[ $attempt -lt 6 ]] && sleep 2
  done
  code="$(jq -r '.error.code // ""' /tmp/smoke_items.json 2>/dev/null || true)"
  if [[ "$status" == "404" ]]; then
    local snippet; snippet="$(head -c 300 /tmp/smoke_items.json 2>/dev/null | tr '\n' ' ' || true)"
    add_result FAIL "$name" "(GET /v1/responses/{id}/input_items HTTP 404; code='$code'; body=$snippet)"
  elif [[ "$status" == "400" && "$code" == "ModelNotSpecified" ]]; then
    add_result FAIL "$name" "(input_items hit the inference body-parse guard -- the operation-scoped policy must omit <base />)"
  elif [[ "$status" != "200" ]]; then
    add_result FAIL "$name" "(GET input_items HTTP $status)"
  else
    is_list="$(jq -r 'if (.data | type) == "array" then "yes" else "no" end' /tmp/smoke_items.json 2>/dev/null || echo no)"
    if [[ "$is_list" == "yes" ]]; then
      add_result PASS "$name" "(GET input_items 200 with an OpenAI list shape)"
    else
      add_result FAIL "$name" "(GET input_items 200 but .data is not an array -- not the OpenAI list shape)"
    fi
  fi
  curl -sk --max-time 60 -o /dev/null -H "api-key: $key" -X DELETE "$APIM_GW/openai/v1/responses/$rid" || true
}

# ---------- assertion 3e: /v1/responses/{id}/cancel (#110) ----------
# Cancel only applies to a BACKGROUND response. If the backend will not accept background:true, the
# endpoint cannot be exercised - that is a SKIP, not a failure of the gateway. A 404 IS a failure:
# it means the operation is not matched, which is the thing this assertion exists to catch.
responses_cancel_probe() {
  local key="$1" name="responses-cancel"
  if [[ -z "$key" ]]; then add_result SKIP "$name" "(no dev1 key)"; return; fi
  local payload create_status rid status code
  payload="$(jq -nc --arg m "$PRIMARY_MODEL" '{model:$m, input:"Count slowly to twenty.", store:true, background:true}')"
  create_status="$(curl -sk --max-time 60 -o /tmp/smoke_cancel_create.json -w '%{http_code}' \
    -H "api-key: $key" -H 'Content-Type: application/json' \
    -X POST -d "$payload" "$APIM_GW/openai/v1/responses")"
  if [[ "$create_status" != "200" ]]; then
    add_result SKIP "$name" "(backend did not accept background:true; POST /v1/responses HTTP $create_status)"; return
  fi
  rid="$(jq -r '.id // ""' /tmp/smoke_cancel_create.json 2>/dev/null || true)"
  if [[ -z "$rid" ]]; then add_result SKIP "$name" "(background POST 200 but no .id in the body)"; return; fi

  # -d '' is required, not cosmetic: a POST with no body omits Content-Length, and the Gov gateway
  # answers 411 Length Required before the request ever reaches the operation.
  status="$(curl -sk --max-time 60 -o /tmp/smoke_cancel.json -w '%{http_code}' \
    -H "api-key: $key" -H 'Content-Type: application/json' \
    -X POST -d '' "$APIM_GW/openai/v1/responses/$rid/cancel")"
  code="$(jq -r '.error.code // ""' /tmp/smoke_cancel.json 2>/dev/null || true)"
  if [[ "$status" == "404" ]]; then
    add_result FAIL "$name" "(POST /v1/responses/{id}/cancel HTTP 404 -- operation not matched; the sub-path op is missing from this env)"
  elif [[ "$status" == "400" && "$code" == "ModelNotSpecified" ]]; then
    add_result FAIL "$name" "(cancel hit the inference body-parse guard -- the operation-scoped policy must omit <base />)"
  elif [[ "$status" == "200" ]]; then
    add_result PASS "$name" "(POST background -> cancel 200)"
  else
    # Routed (not 404), but the backend refused for a state reason - e.g. the run already finished.
    add_result SKIP "$name" "(cancel routed but returned HTTP $status code=${code:-none}; likely already completed)"
  fi
  curl -sk --max-time 60 -o /dev/null -H "api-key: $key" -X DELETE "$APIM_GW/openai/v1/responses/$rid" || true
}
cyan "==> Assertion 3c: stateful Responses sub-resources (#110)"
responses_item_probe "$DEV1_KEY"
cyan "==> Assertion 3d: Responses input_items (#110)"
responses_input_items_probe "$DEV1_KEY"
cyan "==> Assertion 3e: Responses cancel (#110)"
responses_cancel_probe "$DEV1_KEY"

# ---------- assertion 4: emit-metric KQL ----------
cyan "==> Assertion 4: customMetrics emit-metric flow (KQL)"
APP_ID="$(az monitor app-insights component show -g "$RESOURCE_GROUP" --app "$APP_INSIGHTS_NAME" --query 'appId' -o tsv 2>/dev/null || true)"
KQL_PATH="$(dirname "$0")/../monitoring/kql/smoke-emit-metric.kql"
if [[ -z "$APP_ID" ]]; then
  add_result FAIL emit-metric "(cannot resolve appId for App Insights '$APP_INSIGHTS_NAME')"
elif [[ ! -f "$KQL_PATH" ]]; then
  add_result FAIL emit-metric "(KQL file missing at $KQL_PATH)"
else
  # We POST directly to the App Insights query REST API via `az rest`. The
  # `az monitor app-insights query` CLI extension is unusable for this:
  #   - Multi-line bodies silently drop the `| summarize` clause and return the
  #     full unaggregated schema with rows=[] (exit 0, but wrong).
  #   - Single-line bodies return `BadArgumentError: The request had some invalid
  #     properties` with no inner error code.
  # `az rest` exposes the real server-side error (e.g. `SEM0100 ... itemCount`)
  # which is how we caught the wrong-column-name bug behind #60. The endpoint
  # hostname is cloud-aware via `az cloud show --query endpoints.appInsightsResourceId`.
  AI_API="$(az cloud show --query 'endpoints.appInsightsResourceId' -o tsv)"
  # Strip `//` line comments + blank lines (smaller request body, easier to debug).
  kql="$(grep -Ev '^[[:space:]]*(//|$)' "$KQL_PATH")"
  body_file="$(mktemp)"
  jq -n --arg q "$kql" '{query: $q}' > "$body_file"
  err_file="$(mktemp)"
  # APIM `emit-metric` flows via the appinsights logger with isBuffered:true,
  # then through AI's ingestion pipeline. Measured end-to-end latency from
  # policy emit to customMetrics queryability is ~75-100s typical, but the gov
  # cloud's App Insights ingestion occasionally backs up well past the old 480s
  # window (seen intermittently on gov-dev smoke while comm-dev passes the same
  # run). We poll up to 12 min before declaring the metrics pipeline broken;
  # polling every 15s means we still return as soon as ingestion lands rather
  # than always blocking the full deadline, so the larger ceiling is ~free on
  # the happy path.
  poll_deadline=$(( SECONDS + 720 ))
  hits=0; latest=""; distinct=0; cli_exit=0; err_msg=""
  while (( SECONDS < poll_deadline )); do
    resp="$(az rest --method post --url "$AI_API/v1/apps/$APP_ID/query" --headers 'Content-Type=application/json' --body "@$body_file" --resource "$AI_API" -o json 2>"$err_file")"
    cli_exit=$?
    err_msg="$(head -c 400 "$err_file" | tr '\n' ' ')"
    if [[ $cli_exit -ne 0 || -z "$resp" ]]; then break; fi
    hits="$(echo "$resp"  | jq -r '.tables[0].rows[0][0] // 0')"
    latest="$(echo "$resp" | jq -r '.tables[0].rows[0][1] // ""')"
    distinct="$(echo "$resp" | jq -r '.tables[0].rows[0][2] // 0')"
    if [[ "$hits" -gt 0 ]]; then break; fi
    sleep 15
  done
  rm -f "$body_file" "$err_file"
  if [[ $cli_exit -ne 0 || -z "$resp" ]]; then
    add_result FAIL emit-metric "(az rest exit=$cli_exit; err: ${err_msg:-<empty>})"
  elif [[ "$hits" -gt 0 ]]; then
    add_result PASS emit-metric "(hits=$hits, distinctMetricNames=$distinct, latestEmit=$latest)"
  else
    add_result FAIL emit-metric "(hits=0 after 720s polling -- check APIM diagnostic metrics:true (#16) AND that this run actually fired chat assertions before assertion 4)"
  fi

# ---------- assertion 4b: auto-route classifier actually runs (#128) ----------
# The classifier only fires for the AMBIGUOUS length band, so a short smoke prompt routes straight
# to mini and never exercises it. Size the prompt from this env's own threshold: len == threshold is
# the centre of the ambiguous band, so it lands there whatever the per-env tuning is.
#
# Telemetry is the only honest assertion here. The classifier runs with ignore-error=true, so a
# broken self-call (APIM unable to reach its own gateway host) degrades silently to the full model
# and still returns 200 -- indistinguishable from success without checking auto_route_reason.
cyan "==> Assertion 4b: auto-route classifier (#128)"
name="classifier-route"
CLASSIFIER_ON="$(az apim nv show -g "$RESOURCE_GROUP" -n "$APIM_NAME" --named-value-id auto-route-classifier-enabled --query value -o tsv 2>/dev/null || true)"
THRESHOLD="$(az apim nv show -g "$RESOURCE_GROUP" -n "$APIM_NAME" --named-value-id auto-route-length-threshold --query value -o tsv 2>/dev/null || true)"
if [[ "${CLASSIFIER_ON,,}" != "true" ]]; then
  add_result SKIP "$name" "(auto-route-classifier-enabled=${CLASSIFIER_ON:-<unset>})"
elif [[ -z "$DEV1_KEY" || -z "$THRESHOLD" || -z "$APP_ID" ]]; then
  add_result SKIP "$name" "(missing dev1 key, threshold or appId)"
else
  filler="$(head -c "$THRESHOLD" < /dev/zero | tr '\0' 'a')"
  payload="$(jq -nc --arg c "Answer in one short sentence. $filler" '{model:"auto", messages:[{role:"user", content:$c}], max_completion_tokens:40}')"
  cstatus="$(curl -sk --max-time 90 -o /tmp/smoke_classifier.json -w '%{http_code}' \
    -H "api-key: $DEV1_KEY" -H 'Content-Type: application/json' \
    -X POST -d "$payload" "$APIM_GW/openai/v1/chat/completions")"
  if [[ "$cstatus" != "200" ]]; then
    add_result FAIL "$name" "(HTTP $cstatus; body=$(head -c 200 /tmp/smoke_classifier.json 2>/dev/null | tr '\n' ' '))"
  else
    ckql='customMetrics | where timestamp > ago(20m) | where name in ("copilot_byok_auto_route","copilot_byok_classifier_tokens") | extend reason = tostring(customDimensions["auto_route_reason"]) | summarize decided=countif(name == "copilot_byok_auto_route" and reason in ("classifier-simple","classifier-complex")), fellback=countif(name == "copilot_byok_auto_route" and reason startswith "classifier-fallback"), reasons=tostring(make_set_if(reason, reason startswith "classifier-")), ctok=countif(name == "copilot_byok_classifier_tokens"), ctoksum=sum(iff(name == "copilot_byok_classifier_tokens", valueSum, 0.0))'
    cbody="$(mktemp)"; jq -n --arg q "$ckql" '{query: $q}' > "$cbody"
    cdecided=0; cfellback=0; creasons=""; ctok=0; ctoksum=0; deadline=$(( SECONDS + 300 ))
    while (( SECONDS < deadline )); do
      cresp="$(az rest --method post --url "$AI_API/v1/apps/$APP_ID/query" --headers 'Content-Type=application/json' --body "@$cbody" --resource "$AI_API" -o json 2>/dev/null)"
      cdecided="$(echo "$cresp"  | jq -r '.tables[0].rows[0][0] // 0')"
      cfellback="$(echo "$cresp" | jq -r '.tables[0].rows[0][1] // 0')"
      creasons="$(echo "$cresp"  | jq -r '.tables[0].rows[0][2] // ""')"
      ctok="$(echo "$cresp"     | jq -r '.tables[0].rows[0][3] // 0')"
      ctoksum="$(echo "$cresp"  | jq -r '.tables[0].rows[0][4] // 0')"
      # Stop as soon as ANY classifier outcome lands; a fallback is a result, not a reason to wait.
      if [[ "$cdecided" -gt 0 || "$cfellback" -gt 0 ]]; then break; fi
      sleep 15
    done
    rm -f "$cbody"
    if [[ "$cdecided" -gt 0 ]]; then
      # The classifier calls the model directly, so its tokens are only visible via the explicit
      # metric; without it that spend is invisible again, which is the #128 gap.
      if [[ "$ctok" -gt 0 ]]; then
        add_result PASS "$name" "(threshold=$THRESHOLD; classifier decided $cdecided time(s): $creasons; classifier tokens metered: $ctok emit(s), $ctoksum tokens)"
      else
        add_result FAIL "$name" "(threshold=$THRESHOLD; classifier decided ($creasons) but copilot_byok_classifier_tokens never landed -- the classifier ran and its spend is unmetered, the #128 gap)"
      fi
    elif [[ "$cfellback" -gt 0 ]]; then
      # classifier-fallback == the classifier call itself failed and routing silently degraded
      # to the full model. This is the #128 failure, not a pass. The suffix says which mode.
      add_result FAIL "$name" "(threshold=$THRESHOLD; classifier fell back x$cfellback, reasons=$creasons -- the classifier call FAILED and silently degraded to the full model. Suffix: noresp=no response at all (unreachable, or past the 8s timeout), httpNNN=endpoint refused it (401/403 credential, 429 throttle), parse/empty=answered but unusable)"
    else
      add_result FAIL "$name" "(threshold=$THRESHOLD; request 200 but no classifier-* reason in 300s -- the classifier did not run at all)"
    fi
  fi
fi
fi

# ---------- assertion 5: token burst -> 429 ----------
cyan "==> Assertion 5: token burst -> 429 (llm-token-limit)"
if [[ $SKIP_TOKEN_LIMIT -eq 1 ]]; then
  add_result SKIP token-limit '(--skip-token-limit set)'
else
  key="${DEV1_KEY:-$DEV2_KEY}"
  if [[ -z "$key" ]]; then
    add_result SKIP token-limit '(no dev key for probe)'
  else
    # The token-limit policy's estimate-prompt-tokens counts PROMPT tokens on the
    # inbound and accumulates them against a per-subscription counter -- it does NOT
    # pre-count max_completion_tokens (completion is only tallied from the backend
    # response's usage). A single huge prompt is too large for the gateway to
    # buffer/parse (the backend 400s with ModelNotSpecified before the throttle
    # fires), so send a BURST of moderate, well-formed requests until the product's
    # tokens-per-minute budget is spent and the gateway returns 429.
    prompt="$(yes token | head -n "$OVERSIZED_TOKENS" | tr '\n' ' ')"
    payload="$(jq -nc --arg m "$PRIMARY_MODEL" --arg p "$prompt" '{model:$m, messages:[{role:"user", content:$p}], max_completion_tokens:16}')"
    status=0
    body_snippet=""
    for _ in $(seq 1 "$TOKEN_BURST_MAX"); do
      status="$(curl -sk --max-time 30 -o /tmp/smoke_throttle.json -w '%{http_code}' \
        -H "api-key: $key" -H 'Content-Type: application/json' \
        -X POST -d "$payload" "$APIM_GW/openai/v1/chat/completions")"
      [[ "$status" == "429" ]] && break
      if [[ "$status" != "200" ]]; then
        body_snippet="$(head -c 200 /tmp/smoke_throttle.json 2>/dev/null | tr '\n' ' ')"
        break
      fi
    done
    if [[ "$status" == "429" ]]; then
      # A backend capacity 429 is indistinguishable from a policy 429 by status alone, so
      # passing on it would hide a tier-TPM-above-modelCapacity misconfig.
      if grep -qiE 'pricing tier|exceeded token rate limit' /tmp/smoke_throttle.json 2>/dev/null; then
        add_result FAIL token-limit "(429 came from the MODEL DEPLOYMENT, not llm-token-limit: the product tier TPM exceeds this env modelCapacity, so the backend throttles before APIM does)"
      else
        add_result PASS token-limit "(HTTP 429 after burst)"
      fi
    else
      body_snippet="${body_snippet:-$(head -c 200 /tmp/smoke_throttle.json 2>/dev/null | tr '\n' ' ')}"
      add_result FAIL token-limit "(expected 429 from token burst vs product TPM, got HTTP $status after up to ${TOKEN_BURST_MAX}x ~${OVERSIZED_TOKENS}-token reqs; body=$body_snippet)"
    fi
  fi
fi

# ---------- assertion 6: register app reachable (best-effort) ----------
cyan "==> Assertion 6: register app health (best-effort)"
# The register app (#64) is opt-in: only present when the env was provisioned with
# deployRegisterApp=true. Discover its URL from the azd output, else from the ACA app
# tagged azd-service-name=register. SKIP (not FAIL) when the env has no register app.
REGISTER_URL="${envv[REGISTER_APP_URL]:-}"
if [[ -z "$REGISTER_URL" && -n "$RESOURCE_GROUP" ]]; then
  REGISTER_FQDN="$(az containerapp list -g "$RESOURCE_GROUP" --query "[?tags.\"azd-service-name\"=='register'].properties.configuration.ingress.fqdn | [0]" -o tsv 2>/dev/null || true)"
  [[ -n "$REGISTER_FQDN" ]] && REGISTER_URL="https://$REGISTER_FQDN"
fi
if [[ -z "$REGISTER_URL" ]]; then
  add_result SKIP register-app '(no register app in this env)'
else
  # Easy Auth (RedirectToLoginPage) answers /healthz with a 302 to the login page when auth
  # is on, or 200 when it is the pre-auth placeholder. Either proves the app is up; only a
  # 5xx / connection failure is a real failure. Don't follow the redirect (probe liveness).
  reg_code="$(curl -sk --max-time 30 -o /dev/null -w '%{http_code}' "${REGISTER_URL%/}/healthz" 2>/dev/null || echo 000)"
  case "$reg_code" in
    200|302|401|403) add_result PASS register-app "(HTTP $reg_code from $REGISTER_URL)";;
    *)               add_result FAIL register-app "(HTTP $reg_code from $REGISTER_URL; expected 200/302/401/403)";;
  esac
fi

# ---------- assertion 7: register Easy Auth enforcement (best-effort) ----------
cyan "==> Assertion 7: register Easy Auth enforcement (unauth must be denied)"
if [[ -z "$REGISTER_URL" ]]; then
  add_result SKIP register-auth '(no register app in this env)'
else
  # POST /api/register with NO token. Easy Auth on -> 302 login redirect (before the app runs);
  # Easy Auth not attached -> app returns 401. Either denies provisioning. A 2xx means the
  # privileged endpoint is anonymously reachable -> hard FAIL. Don't follow redirects.
  ra_code="$(curl -sk --max-time 30 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "${REGISTER_URL%/}/api/register" 2>/dev/null || echo 000)"
  case "$ra_code" in
    302)     add_result PASS register-auth "(HTTP 302 -> Easy Auth login enforced)";;
    401|403) add_result PASS register-auth "(HTTP $ra_code -> provisioning denied; Easy Auth may not be attached yet)";;
    200|201) add_result FAIL register-auth "(HTTP $ra_code -> /api/register reachable ANONYMOUSLY; Easy Auth not enforcing)";;
    *)       add_result FAIL register-auth "(HTTP $ra_code from /api/register; expected 302/401/403)";;
  esac
fi

# ---------- assertion 8: register provisioning RBAC wired (best-effort) ----------
cyan "==> Assertion 8: register UAMI has the custom APIM subscription role"
# Resolve the register UAMI principal. Prefer the azd output (clientId), but fall back to
# discovering the UAMI by its deterministic name (id-<prefix>-register-<env>-<suffix>) so the
# assertion still runs when the smoke job's azd env lacks the output (provision + smoke can be
# separate jobs/runners, so the azd .env outputs aren't always present here). A register-less
# env has no such identity -> UAMI_PID stays empty -> SKIP (not FAIL).
REGISTER_UAMI_CLIENT_ID="${envv[REGISTER_UAMI_CLIENT_ID]:-}"
APIM_ID=""
UAMI_PID=""
if [[ -n "$REGISTER_UAMI_CLIENT_ID" ]]; then
  UAMI_PID="$(az identity list -g "$RESOURCE_GROUP" --query "[?clientId=='$REGISTER_UAMI_CLIENT_ID'].principalId | [0]" -o tsv 2>/dev/null || true)"
fi
if [[ -z "$UAMI_PID" ]]; then
  UAMI_PID="$(az identity list -g "$RESOURCE_GROUP" --query "[?contains(name, '-register-')].principalId | [0]" -o tsv 2>/dev/null || true)"
fi
if [[ -z "$UAMI_PID" ]]; then
  add_result SKIP register-rbac '(no register app in this env)'
else
  APIM_ID="$(az apim show -g "$RESOURCE_GROUP" -n "$APIM_NAME" --query id -o tsv 2>/dev/null || true)"
  if [[ -z "$APIM_ID" ]]; then
    add_result SKIP register-rbac '(cannot resolve APIM id)'
  else
    # List assignments AT the APIM scope and match the custom role by name. Reader on the RG
    # (which the runner UAMI has) includes Microsoft.Authorization/roleAssignments/read.
    ROLES="$(az role assignment list --scope "$APIM_ID" --query "[?principalId=='$UAMI_PID'].roleDefinitionName" -o tsv 2>/dev/null || true)"
    if echo "$ROLES" | grep -q 'BYOK Register Subscription Manager'; then
      add_result PASS register-rbac '(custom role assigned at APIM scope)'
    else
      add_result FAIL register-rbac "(register UAMI has no 'BYOK Register Subscription Manager' role at APIM scope; got: '$(echo "$ROLES" | tr '\n' ',' | sed 's/,$//')')"
    fi
  fi
fi

# ---------- assertion 9: sub-key provisioning round-trip (best-effort; MUTATES APIM) ----------
cyan "==> Assertion 9: provision a sub key -> chat -> revoke (register app path)"
if [[ "$SKIP_PROVISION_PROBE" == "1" ]]; then
  add_result SKIP provision-roundtrip '(--skip-provision-probe set)'
elif [[ -z "$SUBSCRIPTION_ID" ]]; then
  add_result SKIP provision-roundtrip '(no subscription context)'
else
  PROBE_SID="smoke-prov-$(date +%s)-${RANDOM}"
  [[ -z "$APIM_ID" ]] && APIM_ID="$(az apim show -g "$RESOURCE_GROUP" -n "$APIM_NAME" --query id -o tsv 2>/dev/null || true)"
  SUB_BASE="${ARM_ENDPOINT}/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/subscriptions/${PROBE_SID}"
  # Mirror the register app's ApimProvisioner: PUT a subscription scoped to a tier PRODUCT.
  # Needs subscriptions/write -- register UAMI + dev runner (Contributor) have it; a read-only
  # pilot smoke identity gets 403 -> SKIP.
  PUT_BODY="$(jq -nc --arg s "${APIM_ID}/products/${PROVISION_PRODUCT}" '{properties:{scope:$s, displayName:"smoke provision probe", state:"active"}}')"
  created=0
  PUT_ERR="$(az rest --method PUT --url "${SUB_BASE}?api-version=2024-05-01" --headers 'Content-Type=application/json' --body "$PUT_BODY" -o none 2>&1)"
  put_rc=$?
  if [[ $put_rc -ne 0 ]]; then
    if echo "$PUT_ERR" | grep -Eq '403|Authorization|Forbidden'; then
      add_result SKIP provision-roundtrip "(identity lacks subscriptions/write -> $PROVISION_PRODUCT)"
    else
      add_result FAIL provision-roundtrip "(create sub failed: $(printf '%s' "$PUT_ERR" | head -c 300 | tr '\n' ' '))"
    fi
  else
    created=1
    PROV_KEY=""
    for _ in $(seq 1 6); do
      PROV_KEY="$(az rest --method POST --url "${SUB_BASE}/listSecrets?api-version=2024-05-01" --query primaryKey -o tsv 2>/dev/null || true)"
      [[ -n "$PROV_KEY" ]] && break
      sleep 3
    done
    if [[ -z "$PROV_KEY" ]]; then
      add_result FAIL provision-roundtrip "(provisioned '$PROBE_SID' but listSecrets returned no key)"
    else
      # Key activation can lag a few seconds; retry the chat briefly on 401/403.
      payload="$(jq -nc --arg m "$PRIMARY_MODEL" '{model:$m, messages:[{role:"user", content:"Reply with the single word: pong."}], max_completion_tokens:16}')"
      pstatus=0
      for _ in $(seq 1 6); do
        pstatus="$(curl -sk --max-time 60 -o /dev/null -w '%{http_code}' -H "api-key: $PROV_KEY" -H 'Content-Type: application/json' -X POST -d "$payload" "$APIM_GW/openai/v1/chat/completions")"
        [[ "$pstatus" == "200" ]] && break
        if [[ "$pstatus" == "401" || "$pstatus" == "403" ]]; then sleep 3; continue; fi
        break
      done
      if [[ "$pstatus" == "200" ]]; then
        add_result PASS provision-roundtrip "(provisioned '$PROBE_SID' on $PROVISION_PRODUCT; chat HTTP 200)"
      else
        add_result FAIL provision-roundtrip "(provisioned key chat returned HTTP $pstatus; expected 200)"
      fi
    fi
  fi
  # cleanup (best-effort): always remove the throwaway subscription we created.
  if [[ "$created" == "1" ]]; then
    az rest --method DELETE --url "${SUB_BASE}?api-version=2024-05-01" -o none 2>/dev/null || true
  fi
fi

# ---------- assertion: STREAMED requests emit token metrics (#126) ----------
# The hand-rolled outbound emit-metric pair is guarded by Content-Type: application/json, so it
# never fires for text/event-stream -- and Copilot CLI / VS Code stream by default, which left most
# real traffic unmetered. The built-in llm-emit-token-metric (inbound) captures usage at the
# platform level for streamed responses too. This proves it end to end: send a STREAMING
# chat/completions call, confirm it really streamed, then confirm a platform token metric landed.
# Deliberately runs LAST so the metric query window contains only this call's traffic.
# SKIPs (does not fail) if the Log Analytics query plane isn't reachable or ingestion hasn't landed
# in time -- custom-metric ingestion is best-effort and we don't want a flaky gate.
streaming_metrics_probe() {
  local key="$1" name="streaming-token-metrics"
  if [[ -z "$key" ]]; then add_result SKIP "$name" "(no dev1 key)"; return; fi
  local t0 status rstatus app_id ai_api q n legacy i row attempt
  # Custom metrics are aggregated per MINUTE and the datapoint is stamped at the START of that
  # bin, so a mid-minute t0 would exclude this call's own datapoint (looks like ingestion lag).
  # Land ~2s into a fresh minute and floor t0 to it: because this probe runs LAST, that minute
  # then contains ONLY this call, which lets us assert both directions cleanly.
  sleep $(( 62 - 10#$(date -u +%S) ))
  t0="$(date -u +%Y-%m-%dT%H:%M:00Z)"
  for attempt in $(seq 1 3); do
    status="$(curl -sk --max-time 45 -o /tmp/smoke_stream126.txt -w '%{http_code}' \
      -H "api-key: $key" -H 'Content-Type: application/json' -H 'Accept: text/event-stream' -X POST \
      -d "$(jq -nc --arg m "$PRIMARY_MODEL" '{model:$m, messages:[{role:"user",content:"Reply with the single word: pong."}], max_completion_tokens:64, stream:true}')" \
      "$APIM_GW/openai/v1/chat/completions")"
    [[ "$status" == "200" ]] && break
    [[ "$status" == "000" || "$status" == "429" || "$status" =~ ^5 ]] || break
    [[ $attempt -lt 3 ]] && sleep 5
  done
  if [[ "$status" != "200" ]]; then
    add_result FAIL "$name" "(streaming request HTTP $status after $attempt attempt(s); body=$(head -c 160 /tmp/smoke_stream126.txt 2>/dev/null | tr '\n' ' '))"; return
  fi
  if ! grep -q 'chat\.completion\.chunk' /tmp/smoke_stream126.txt || ! grep -q '\[DONE\]' /tmp/smoke_stream126.txt; then
    add_result FAIL "$name" "(200 but not an SSE chunk stream; head=$(head -c 120 /tmp/smoke_stream126.txt 2>/dev/null | tr '\n' ' '))"; return
  fi
  # Same minute: also stream on the RESPONSES surface. This is a genuinely different path -- the
  # inbound policy deliberately does NOT inject stream_options.include_usage there, because the
  # Responses API reports usage natively in its terminal response.completed event.
  for attempt in $(seq 1 3); do
    rstatus="$(curl -sk --max-time 45 -o /tmp/smoke_stream126r.txt -w '%{http_code}' \
      -H "api-key: $key" -H 'Content-Type: application/json' -H 'Accept: text/event-stream' -X POST \
      -d "$(jq -nc --arg m "$PRIMARY_MODEL" '{model:$m, input:"Reply with the single word: pong.", max_output_tokens:64, stream:true}')" \
      "$APIM_GW/openai/v1/responses")"
    [[ "$rstatus" == "200" ]] && break
    [[ "$rstatus" == "000" || "$rstatus" == "429" || "$rstatus" =~ ^5 ]] || break
    [[ $attempt -lt 3 ]] && sleep 5
  done
  if [[ "$rstatus" != "200" ]] || ! grep -q 'response\.' /tmp/smoke_stream126r.txt; then
    add_result FAIL "$name" "(chat stream OK but /responses stream failed: HTTP $rstatus after $attempt attempt(s); head=$(head -c 140 /tmp/smoke_stream126r.txt 2>/dev/null | tr '\n' ' '))"; return
  fi
  # The call definitely streamed. Now confirm the platform emitted token metrics for it.
  # Query via the App Insights REST API (same approach as assertion 4) rather than the
  # log-analytics CLI extension, which isn't guaranteed present on a runner.
  app_id="$(az monitor app-insights component show -g "$RESOURCE_GROUP" --app "$APP_INSIGHTS_NAME" --query appId -o tsv 2>/dev/null || true)"
  ai_api="$(az cloud show --query 'endpoints.appInsightsResourceId' -o tsv 2>/dev/null || true)"
  if [[ -z "$app_id" || -z "$ai_api" ]]; then
    add_result SKIP "$name" "(streamed OK, but App Insights query endpoint not resolvable for the metric check)"; return
  fi
  # One query returns BOTH counts for the probe's isolated minute: the built-in policy must have
  # counted this streamed call, and the legacy outbound pair must NOT have (that's the whole gap).
  # valueCount = number of measurements aggregated, which is what separates calls (sums can't).
  q="customMetrics | where timestamp >= datetime($t0) | summarize builtin = sumif(valueCount, name in ('Total Tokens','Completion Tokens','Prompt Tokens')), legacy = sumif(valueCount, name in ('copilot_byok_prompt_tokens','copilot_byok_completion_tokens'))"
  n=0; legacy=0
  for i in $(seq 1 10); do
    row="$(az rest --method post --url "$ai_api/v1/apps/$app_id/query" --headers 'Content-Type=application/json' \
          --body "$(jq -nc --arg q "$q" '{query:$q}')" --resource "$ai_api" -o json 2>/dev/null \
          | jq -r '(.tables[0].rows[0][0] // 0 | tostring) + " " + (.tables[0].rows[0][1] // 0 | tostring)' 2>/dev/null || echo '0 0')"
    n="${row%% *}"; legacy="${row##* }"
    [[ "$n" == "null" ]] && n=0
    [[ "$legacy" == "null" ]] && legacy=0
    if [[ "${n:-0}" -gt 0 ]]; then break; fi
    sleep 30
  done
  if [[ "${n:-0}" -le 0 ]]; then
    add_result SKIP "$name" "(both surfaces streamed OK, but no token metric visible within ~5m; custom-metric ingestion lag)"; return
  fi
  if [[ "${legacy:-0}" -le 0 ]]; then
    add_result PASS "$name" "(chat/completions + /responses both streamed; built-in emitted $n token measurement(s), legacy copilot_byok_*_tokens emitted 0 -- exactly the #126 gap, now covered)"
  else
    add_result PASS "$name" "(both surfaces streamed; built-in emitted $n token measurement(s); note: legacy also emitted $legacy in the same minute)"
  fi
}
cyan "==> Assertion: streamed requests emit token metrics (#126)"
streaming_metrics_probe "$DEV1_KEY"

# ---------- summary ----------
echo
cyan "==> Summary"
for r in "${results[@]}"; do
  IFS='|' read -r s n d <<<"$r"
  case "$s" in
    PASS) green   "    PASS $n  $d";;
    FAIL) red     "    FAIL $n  $d";;
    SKIP) yellow  "    SKIP $n  $d";;
  esac
done
echo
cyan "    Total: $pass_n PASS, $fail_n FAIL, $skip_n SKIP"
if [[ $fail_n -gt 0 ]]; then
  red "    Smoke test FAILED."
  exit 1
fi
green "    Smoke test PASSED."
exit 0
