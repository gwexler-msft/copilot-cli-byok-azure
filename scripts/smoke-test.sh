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
PRIMARY_MODEL="gpt-5.1"
MINI_MODEL="gpt-4.1-mini"
# Number of PROMPT tokens per request in assertion 5's token burst. The
# token-limit policy's estimate-prompt-tokens counts PROMPT tokens on the inbound
# (NOT max_completion_tokens) and accumulates them per subscription, so the probe
# sends a BURST of moderate, well-formed requests until the product's
# tokens-per-minute (byok-standard default 20000 TPM) is spent and the gateway
# returns 429. ~1 token per word; each body stays small enough for the gateway to
# buffer/parse (a single 300k-token prompt 400s with ModelNotSpecified before the
# throttle can fire). TOKEN_BURST_MAX caps the loop so byok-power (60000 TPM) trips too.
OVERSIZED_TOKENS=5000
TOKEN_BURST_MAX=20
SKIP_TOKEN_LIMIT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-name)            ENV_NAME="$2"; shift 2;;
    --resource-group)      RESOURCE_GROUP="$2"; shift 2;;
    --apim-name)           APIM_NAME="$2"; shift 2;;
    --app-insights-name)   APP_INSIGHTS_NAME="$2"; shift 2;;
    --primary-model)       PRIMARY_MODEL="$2"; shift 2;;
    --mini-model)          MINI_MODEL="$2"; shift 2;;
    --oversized-tokens)    OVERSIZED_TOKENS="$2"; shift 2;;
    --skip-token-limit)    SKIP_TOKEN_LIMIT=1; shift;;
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

# ---------- discovery ----------
cyan "==> Discovery"
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
# 'smoke' is scoped to the byok-discovery product, NOT a tier product. It can list
# models on /discovery/v1/models but cannot run chat. dev1/dev2 keys cannot reach
# /discovery (they're not in that product). Discovery+chat live on separate APIs by
# design so "who can list models?" is auditable in the portal.
SMOKE_KEY="$(get_dev_key smoke || true)"

# ---------- assertion 1: discovery ----------
cyan "==> Assertion 1: GET /discovery/v1/models"
if [[ -z "$SMOKE_KEY" ]]; then
  add_result SKIP discovery "(no smoke key)"
else
  # Capture HTTP status + body separately so we can diagnose FAILs without
  # re-running. -w '%{http_code}' appends the code; we split it off the tail.
  raw="$(curl -sk --max-time 30 -w '\n__STATUS__%{http_code}' -H "api-key: $SMOKE_KEY" "$APIM_GW/discovery/v1/models")"
  status="${raw##*__STATUS__}"
  body="${raw%$'\n'__STATUS__*}"
  if [[ -z "$body" ]]; then
    add_result FAIL discovery "(HTTP $status; empty body)"
  else
    ids="$(echo "$body" | jq -r '.data[]?.id' 2>/dev/null || true)"
    has_primary=0; has_mini=0
    [[ "$ids" == *"$PRIMARY_MODEL"* ]] && has_primary=1
    [[ "$ids" == *"$MINI_MODEL"* ]]    && has_mini=1
    count="$(echo "$ids" | grep -c . || true)"
    if [[ $has_primary -eq 1 && $has_mini -eq 1 ]]; then
      add_result PASS discovery "(HTTP $status; found $count models incl. $PRIMARY_MODEL + $MINI_MODEL)"
    else
      # Print first 400 chars of body to job log so we can diagnose without re-running.
      body_snippet="$(printf '%s' "$body" | head -c 400 | tr '\n' ' ')"
      add_result FAIL discovery "(HTTP $status; expected $PRIMARY_MODEL + $MINI_MODEL; got ids: '$(echo "$ids" | tr '\n' ',' | sed 's/,$//')'; body[0:400]='$body_snippet')"
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
  # policy emit to customMetrics queryability is ~75-100s typical; we allow up
  # to ~3 min before declaring the metrics pipeline broken. Polling every 15s
  # so we return as soon as ingestion lands rather than always blocking the
  # full deadline.
  poll_deadline=$(( SECONDS + 480 ))
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
    add_result FAIL emit-metric "(hits=0 after 480s polling -- check APIM diagnostic metrics:true (#16) AND that this run actually fired chat assertions before assertion 4)"
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
      add_result PASS token-limit "(HTTP 429 after burst)"
    else
      body_snippet="${body_snippet:-$(head -c 200 /tmp/smoke_throttle.json 2>/dev/null | tr '\n' ' ')}"
      add_result FAIL token-limit "(expected 429 from token burst vs product TPM, got HTTP $status after up to ${TOKEN_BURST_MAX}x ~${OVERSIZED_TOKENS}-token reqs; body=$body_snippet)"
    fi
  fi
fi

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
