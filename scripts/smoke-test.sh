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
# A model deployed ONLY on the Commercial Foundry (not available in Gov). Assertion 3c calls it
# through the gov gateway's /openai-commercial route to prove the cross-cloud path reaches a
# Gov-unavailable model. It is a reasoning model, so the probe gives it a generous completion
# budget and asserts on the echoed model name (content may be empty when reasoning eats the budget).
COMMERCIAL_ONLY_MODEL="gpt-5-mini"
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

# ---------- assertion 3b: commercial route (/openai-commercial -> Commercial Foundry) ----------
# Only meaningful where the parallel route is deployed (deployFoundryCommercial=true, e.g. the gov
# envs). A 404 = the route isn't on this env -> SKIP (comm-* and any gov env with it off). 200 =
# the cross-cloud path (caller key -> strip -> commercial SP token -> Commercial Foundry) works.
# Anything else (e.g. 502 CommercialTokenFederationFailed / CommercialTokenAcquisitionFailed) = the
# route is deployed but the backend auth / firewall / egress is broken -> FAIL. Exception: a 403
# firewall rejection is a soft-fail (SKIP) on ephemeral dev envs, whose NAT egress IP rotates on
# each teardown/reprovision and falls off the Commercial Foundry allowlist; still FAIL on pilots.
commercial_route_probe() {
  local key="$1" name="commercial-route"
  if [[ -z "$key" ]]; then add_result SKIP "$name" "(no dev1 key)"; return; fi
  local payload status content model snippet
  payload="$(jq -nc --arg m "$PRIMARY_MODEL" '{model:$m, messages:[{role:"user", content:"Reply with the single word: pong."}], max_completion_tokens:50}')"
  status="$(curl -sk --max-time 60 -o /tmp/smoke_comm.json -w '%{http_code}' \
    -H "api-key: $key" -H 'Content-Type: application/json' \
    -X POST -d "$payload" "$APIM_GW/openai-commercial/v1/chat/completions")"
  if [[ "$status" == "404" ]]; then
    add_result SKIP "$name" "(/openai-commercial not deployed on this env)"
  elif [[ "$status" == "200" ]]; then
    content="$(jq -r '.choices[0].message.content // ""' /tmp/smoke_comm.json | tr '\n' ' ' | sed 's/  */ /g')"
    model="$(jq -r '.model // ""' /tmp/smoke_comm.json)"
    if [[ -n "$content" ]]; then
      snippet="${content:0:40}"; [[ "${#content}" -gt 40 ]] && snippet="${snippet}..."
      add_result PASS "$name" "(model=$model; reply='$snippet')"
    else
      add_result FAIL "$name" "(200 but empty content)"
    fi
  elif [[ "$status" == "403" ]]; then
    # 403 "Access denied due to Virtual Network/Firewall rules" = the Commercial Foundry firewall
    # rejected THIS env's NAT egress IP. Ephemeral dev envs get a NEW NAT public IP on every
    # teardown/reprovision, so their egress IP falls off the Foundry allowlist -> expected -> SKIP
    # (soft-fail). On stable pilots a 403 is a real allowlist/firewall break -> FAIL.
    if [[ "$ENV_NAME" == *-dev ]]; then
      add_result SKIP "$name" "(HTTP 403 firewall; ephemeral dev NAT egress IP not on the Commercial Foundry allowlist -- expected after teardown/reprovision, NAT IP rotates)"
    else
      snippet="$(head -c 200 /tmp/smoke_comm.json 2>/dev/null | tr '\n' ' ' || true)"
      add_result FAIL "$name" "(HTTP 403; body=$snippet)"
    fi
  else
    snippet="$(head -c 200 /tmp/smoke_comm.json 2>/dev/null | tr '\n' ' ' || true)"
    add_result FAIL "$name" "(HTTP $status; body=$snippet)"
  fi
}
cyan "==> Assertion 3b: commercial route (/openai-commercial -> Commercial Foundry)"
commercial_route_probe "$DEV1_KEY"

# ---------- assertion 3c: commercial-only model over the commercial route ----------
# Exercises the cross-cloud route with a model that exists ONLY on the Commercial Foundry (e.g.
# gpt-5-mini), which Gov does not host. A 200 whose echoed .model matches proves the gov gateway
# routed to the Commercial backend AND served a Gov-unavailable model. Reuses the 3b response-code
# semantics: 404 = route not on this env -> SKIP; 403 firewall reject -> SKIP on ephemeral dev
# (rotated NAT egress IP), FAIL on pilots; anything else non-200 -> FAIL. gpt-5-mini is a reasoning
# model, so the budget is generous and the assertion checks the echoed model name, not the content.
commercial_only_model_probe() {
  local key="$1" name="commercial-only-model"
  if [[ -z "$key" ]]; then add_result SKIP "$name" "(no dev1 key)"; return; fi
  if [[ -z "$COMMERCIAL_ONLY_MODEL" ]]; then add_result SKIP "$name" "(no commercial-only model configured)"; return; fi
  local payload status model snippet
  payload="$(jq -nc --arg m "$COMMERCIAL_ONLY_MODEL" '{model:$m, messages:[{role:"user", content:"Reply with the single word: pong."}], max_completion_tokens:400}')"
  status="$(curl -sk --max-time 60 -o /tmp/smoke_comm_only.json -w '%{http_code}' \
    -H "api-key: $key" -H 'Content-Type: application/json' \
    -X POST -d "$payload" "$APIM_GW/openai-commercial/v1/chat/completions")"
  if [[ "$status" == "404" ]]; then
    add_result SKIP "$name" "(/openai-commercial not deployed on this env)"
  elif [[ "$status" == "200" ]]; then
    model="$(jq -r '.model // ""' /tmp/smoke_comm_only.json)"
    if [[ "$model" == "$COMMERCIAL_ONLY_MODEL"* ]]; then
      add_result PASS "$name" "(model=$model; Gov-unavailable model served via commercial route)"
    else
      add_result FAIL "$name" "(200 but echoed model='$model', expected '$COMMERCIAL_ONLY_MODEL'*)"
    fi
  elif [[ "$status" == "403" ]]; then
    if [[ "$ENV_NAME" == *-dev ]]; then
      add_result SKIP "$name" "(HTTP 403 firewall; ephemeral dev NAT egress IP not on the Commercial Foundry allowlist -- expected after teardown/reprovision, NAT IP rotates)"
    else
      snippet="$(head -c 200 /tmp/smoke_comm_only.json 2>/dev/null | tr '\n' ' ' || true)"
      add_result FAIL "$name" "(HTTP 403; body=$snippet)"
    fi
  else
    snippet="$(head -c 200 /tmp/smoke_comm_only.json 2>/dev/null | tr '\n' ' ' || true)"
    add_result FAIL "$name" "(HTTP $status; body=$snippet)"
  fi
}
cyan "==> Assertion 3c: commercial-only model ($COMMERCIAL_ONLY_MODEL) over the commercial route"
commercial_only_model_probe "$DEV1_KEY"

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
