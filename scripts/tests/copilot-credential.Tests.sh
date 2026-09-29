#!/usr/bin/env bash
set -euo pipefail

test_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
helper="$test_directory/../get-byok-token.sh"
wrapper="$test_directory/../copilot-cli-byok.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export MOCK_STATE="$scratch"
export MOCK_CONFIG="$scratch/cache with a ' quote"
mkdir -p "$MOCK_CONFIG"
export MOCK_APP_ID="$(printf '00000000-0000-0000-0000-%012d' 1)"
export MOCK_TENANT_ID="$(printf '00000000-0000-0000-0000-%012d' 2)"
export MOCK_CLOUD=AzureCloud
export MOCK_FAILURE=''
export MOCK_LEGACY_CLI=0
export AZURE_CONFIG_DIR="$MOCK_CONFIG"
unset BYOK_TOKEN_TRACE_FILE

az() {
  local staging=0
  if [[ "${AZURE_CONFIG_DIR:-}" == "${MOCK_CONFIG%/*}/.byok-cache-setup-"* && "$1" == cloud && "${MOCK_EXISTING_CACHE:-0}" == 0 ]]; then staging=1; fi
  [[ "${AZURE_CONFIG_DIR:-}" == "$MOCK_CONFIG" || "$staging" == 1 ]] || return 1
  if [[ -n "$MOCK_FAILURE" && "$1 $2" == "$MOCK_FAILURE" ]]; then
    printf '%s\n' 'private-error-details' >&2
    return 1
  fi
  case "$1 $2" in
    'cloud show') printf '%s\n' "$MOCK_CLOUD" ;;
    'cloud set')
      [[ -n "${MOCK_SETUP_LOG:-}" && "$staging" == 1 && "$*" == "cloud set --name $MOCK_TARGET_CLOUD --output none --only-show-errors" ]] || return 1
      printf '%s\n' cloud-set >> "$MOCK_SETUP_LOG"
      [[ "${MOCK_CLOUD_SET_FAILURE:-0}" != 1 ]] || return 1
      export MOCK_CLOUD="$MOCK_TARGET_CLOUD"
      if [[ "${MOCK_CLOUD_VERIFY_FAILURE:-0}" == 1 ]]; then export MOCK_CLOUD=OtherCloud; fi
      printf '%s' "$MOCK_CLOUD" > "$AZURE_CONFIG_DIR/mock-cloud"
      if [[ "${MOCK_PUBLISH_RACE:-0}" == 1 ]]; then
        mkdir -- "$MOCK_CONFIG"
        printf '%s' preserve > "$MOCK_CONFIG/sentinel"
      fi
      ;;
    'account show') if [[ "${MOCK_EMPTY_ACCOUNT:-0}" != 1 ]]; then cat "$MOCK_STATE/account.json"; fi ;;
    'login --tenant')
      [[ -n "${MOCK_SETUP_LOG:-}" ]] || return 1
      local expected="login --tenant $MOCK_TENANT_ID --scope $MOCK_APP_ID/.default --allow-no-subscriptions --output none"
      if [[ "${BYOK_USE_DEVICE_CODE:-0}" == 1 ]]; then expected+=' --use-device-code'; fi
      [[ "$*" == "$expected" ]] || return 1
      printf '%s\n' login >> "$MOCK_SETUP_LOG"
      [[ "${MOCK_LOGIN_FAILURE:-0}" != 1 ]] || return 1
      export MOCK_EMPTY_ACCOUNT=0
      case "${MOCK_LOGIN_RESULT:-valid}" in
        wrong-tenant) mutate_fixture "$MOCK_STATE/account.json" '.tenantId="00000000-0000-0000-0000-000000000099"' ;;
        wrong-cloud) export MOCK_CLOUD=OtherCloud ;;
        non-user) mutate_fixture "$MOCK_STATE/account.json" '.user.type="servicePrincipal"' ;;
        changed-user) mutate_fixture "$MOCK_STATE/account.json" '.user.name="other-user"' ;;
      esac
      ;;
    'account get-access-token')
      [[ "$*" == *"--scope $MOCK_APP_ID/.default"* ]] || return 1
      printf '%s\n' request >> "$MOCK_STATE/requests"
      if [[ "$*" == *'--query accessToken -o tsv'* ]]; then jq -r '.accessToken' "$MOCK_STATE/token.json"; return; fi
      [[ "$*" == *"--tenant $MOCK_TENANT_ID"* ]] || return 1
      cat "$MOCK_STATE/token.json"
      ;;
    *) return 1 ;;
  esac
}
copilot() {
  [[ "$*" == 'help providers' ]] || return 1
  if [[ "$MOCK_LEGACY_CLI" == 1 ]]; then printf '%s\n' 'Legacy help'; else printf '%s\n' COPILOT_PROVIDER_API_KEY_COMMAND; fi
}
export -f az copilot

reset_fixture() {
  export MOCK_CLOUD="${1:-AzureCloud}"
  export MOCK_FAILURE=''
  export MOCK_EMPTY_ACCOUNT=0
  jq -n --arg tenant "$MOCK_TENANT_ID" --arg cloud "$MOCK_CLOUD" \
    '{tenantId:$tenant,environmentName:$cloud,user:{name:"fixture-user",type:"user"}}' > "$MOCK_STATE/account.json"
  jq -n --arg tenant "$MOCK_TENANT_ID" \
    '{tenant:$tenant,expires_on:(now+3600|floor),accessToken:"fixture.payload.signature"}' > "$MOCK_STATE/token.json"
}
mutate_fixture() {
  local file="$1"
  local expression="$2"
  jq "$expression" "$file" > "$MOCK_STATE/changed.json"
  mv "$MOCK_STATE/changed.json" "$file"
}
expect_token() {
  local output
  output="$(bash "$helper" "$MOCK_APP_ID" "$MOCK_CLOUD" "$MOCK_TENANT_ID" fixture-user "$MOCK_CONFIG")"
  [[ "$output" == "${1:-fixture.payload.signature}" ]] || { echo 'Unexpected token-only output.' >&2; exit 1; }
  printf '%s\n' 'PASS: Bash token-only acquisition'
}
expect_rejection() {
  local name="$1"
  local output
  if output="$(bash "$helper" "$MOCK_APP_ID" AzureCloud "$MOCK_TENANT_ID" fixture-user "$MOCK_CONFIG" 2> "$MOCK_STATE/error")"; then
    printf 'Unexpected acceptance: %s\n' "$name" >&2
    exit 1
  fi
  [[ -z "$output" ]] || { echo 'Failure emitted a credential.' >&2; exit 1; }
  if grep -Eq 'fixture\.payload|private-error-details' "$MOCK_STATE/error"; then echo 'Failure details were not sanitized.' >&2; exit 1; fi
  grep -Fq 'BYOK_LOGIN=1' "$MOCK_STATE/error"
  grep -Fq 'No credential was returned.' "$MOCK_STATE/error"
  printf 'PASS: Bash %s\n' "$name"
}

reset_fixture
expect_token
reset_fixture AzureUSGovernment
expect_token
reset_fixture
mutate_fixture "$MOCK_STATE/token.json" '.accessToken="renewed.payload.signature"'
expect_token renewed.payload.signature
reset_fixture
export MOCK_CLOUD=AzureUSGovernment
expect_rejection 'cloud mismatch'
reset_fixture
mutate_fixture "$MOCK_STATE/account.json" '.tenantId="other-tenant"'
expect_rejection 'tenant mismatch'
reset_fixture
mutate_fixture "$MOCK_STATE/account.json" '.user.name="other-user"'
expect_rejection 'account switch'
reset_fixture
mutate_fixture "$MOCK_STATE/account.json" '.user.type="servicePrincipal"'
expect_rejection 'application identity rejected'
reset_fixture
export MOCK_FAILURE='account get-access-token'
expect_rejection 'token failure sanitized'
reset_fixture
mutate_fixture "$MOCK_STATE/token.json" '.tenant="other-tenant"'
expect_rejection 'wrong token tenant'
reset_fixture
mutate_fixture "$MOCK_STATE/token.json" '.expires_on=(now-60|floor)'
expect_rejection 'expired token'
reset_fixture
mutate_fixture "$MOCK_STATE/token.json" '.expires_on=(now+20|floor)'
expect_rejection 'near-expiry token'
reset_fixture
mutate_fixture "$MOCK_STATE/token.json" 'del(.expires_on)'
expect_rejection 'missing expiration'
reset_fixture
mutate_fixture "$MOCK_STATE/token.json" '.accessToken="not-a-jwt"'
expect_rejection 'malformed token'
reset_fixture
mutate_fixture "$MOCK_STATE/token.json" '.accessToken="fixture.payload.signature\n"'
expect_rejection 'trailing newline token'

reset_fixture
export BYOK_TOKEN_TRACE_FILE="$MOCK_STATE/token-renewal.log"
[[ ! -e "$BYOK_TOKEN_TRACE_FILE" ]] || { echo 'Disabled tracing created a file.' >&2; exit 1; }
expect_token
expect_token
mutate_fixture "$MOCK_STATE/token.json" '.expires_on+=3600 | .accessToken="renewed.payload.signature"'
expect_token renewed.payload.signature
export MOCK_FAILURE='account get-access-token'
expect_rejection 'traced acquisition failure'
jq -se '
  length == 4 and
  (all(.[]; (keys == ["event","expiresUtc","observedUtc"]) and (.observedUtc | endswith("Z")))) and
  (.[0:3] | all(.[]; .event == "token-acquired")) and
  (.[0].expiresUtc == .[1].expiresUtc) and (.[2].expiresUtc > .[1].expiresUtc) and
  (.[3].event == "acquisition-failed" and .[3].expiresUtc == null)
' "$BYOK_TOKEN_TRACE_FILE" > /dev/null
if grep -Eq 'payload|private-error-details|fixture-user' "$BYOK_TOKEN_TRACE_FILE" ||
  grep -Fq "$MOCK_APP_ID" "$BYOK_TOKEN_TRACE_FILE" || grep -Fq "$MOCK_TENANT_ID" "$BYOK_TOKEN_TRACE_FILE" ||
  grep -Fq "$MOCK_CONFIG" "$BYOK_TOKEN_TRACE_FILE"; then echo 'Token trace leaked private data.' >&2; exit 1; fi
reset_fixture
export BYOK_TOKEN_TRACE_FILE="$MOCK_STATE/missing/token.log"
expect_token
unset BYOK_TOKEN_TRACE_FILE
printf '%s\n' 'PASS: Bash optional trace distinguishes cache reuse/new expiry/failure without leaking credentials or changing stdout'

reset_fixture
export AUTH_MODE=jwt REFRESH_TOKEN=1
export BYOK_AZURE_CLOUD=AzureCloud BYOK_LOGIN=0 BYOK_USE_DEVICE_CODE=0
unset BYOK_TENANT_ID
export COPILOT_PROVIDER_API_KEY=stale-key COPILOT_PROVIDER_BEARER_TOKEN=stale-bearer COPILOT_PROVIDER_API_KEY_COMMAND=stale-command
unset COPILOT_PROVIDER_HEADERS
source "$wrapper" https://gateway.example.test gpt-4o-mini "$MOCK_APP_ID" > /dev/null
[[ -z "${COPILOT_PROVIDER_API_KEY:-}" && -z "${COPILOT_PROVIDER_BEARER_TOKEN:-}" && -n "$COPILOT_PROVIDER_API_KEY_COMMAND" ]] || { echo 'Conflicting credential sources remain.' >&2; exit 1; }
first="$(eval "$COPILOT_PROVIDER_API_KEY_COMMAND")"
mutate_fixture "$MOCK_STATE/token.json" '.accessToken="next.payload.signature"'
second="$(eval "$COPILOT_PROVIDER_API_KEY_COMMAND")"
[[ "$first" == fixture.payload.signature && "$second" == next.payload.signature ]] || { echo 'Credential command did not refresh.' >&2; exit 1; }
printf '%s\n' 'PASS: Bash generated command refreshes with quoted cache paths'

for refresh in 0 1; do
  export REFRESH_TOKEN="$refresh"
  for role_case in missing empty null standard power custom both non-array malformed; do
    payload="$(jq -nc --arg case "$role_case" --arg app "$MOCK_APP_ID" '
      {sub:"private-fixture-subject",aud:$app} +
      (if $case == "empty" then {roles:[]}
       elif $case == "null" then {roles:null}
       elif $case == "standard" then {roles:["BYOK.Standard"]}
       elif $case == "power" then {roles:["BYOK.Power"]}
       elif $case == "custom" then {roles:["private-custom-role"]}
       elif $case == "both" then {roles:["BYOK.Standard","BYOK.Power"]}
       elif $case == "non-array" then {roles:"private-custom-role"} else {} end)
      | tojson | @base64' -r)"
    token="e30.$(printf '%s' "$payload" | tr '+/' '-_' | tr -d '=').AA"
    if [[ "$role_case" == malformed ]]; then token=fixture.payload.signature; fi
    mutate_fixture "$MOCK_STATE/token.json" ".accessToken=\"$token\""
    requests_before="$(wc -l < "$MOCK_STATE/requests")"
    source "$wrapper" https://gateway.example.test gpt-4o-mini "$MOCK_APP_ID" > "$MOCK_STATE/guidance-out" 2> "$MOCK_STATE/guidance-err"
    [[ "$(wc -l < "$MOCK_STATE/requests")" -eq $((requests_before + 1)) ]]
    case "$role_case" in
      missing|empty|null)
        grep -Fq 'If group-based JWT tiers are enabled' "$MOCK_STATE/guidance-err"
        grep -Fq 'BYOK_LOGIN=1' "$MOCK_STATE/guidance-err"
        grep -Fq 'not an authorization check' "$MOCK_STATE/guidance-err"
        ;;
      *) [[ ! -s "$MOCK_STATE/guidance-err" ]] ;;
    esac
    grep -Fq 'APIM authorization has not been checked' "$MOCK_STATE/guidance-out"
    for sensitive in "$token" "$MOCK_APP_ID" private-fixture-subject private-custom-role; do
      if grep -Fq "$sensitive" "$MOCK_STATE/guidance-out" "$MOCK_STATE/guidance-err"; then echo 'JWT guidance leaked token or identity claims.' >&2; exit 1; fi
    done
    [[ -z "${BYOK_PREFLIGHT_TOKEN+x}" ]]
  done
done
reset_fixture
printf '%s\n' 'PASS: eighteen Bash static/renewable guidance cases warn about missing roles without extra token requests, credential disclosure or local authorization decisions'

previous_command="$COPILOT_PROVIDER_API_KEY_COMMAND"
previous_requests="$(wc -l < "$MOCK_STATE/requests")"
for refresh in 0 1; do
  export REFRESH_TOKEN="$refresh"
  for failure in failed empty; do
    reset_fixture
    if [[ "$failure" == failed ]]; then export MOCK_FAILURE='account show'; else export MOCK_EMPTY_ACCOUNT=1; fi
    if source "$wrapper" https://gateway.example.test gpt-4o-mini "$MOCK_APP_ID" > "$MOCK_STATE/wrapper-output" 2>&1; then
      echo 'Missing Azure account was accepted.' >&2; exit 1
    fi
    grep -Fq 'No usable Azure CLI account' "$MOCK_STATE/wrapper-output"
    grep -Fq 'AZURE_CONFIG_DIR' "$MOCK_STATE/wrapper-output"
    grep -Fq 'BYOK_LOGIN=1' "$MOCK_STATE/wrapper-output"
    if grep -Eq 'private-error-details|payload.signature' "$MOCK_STATE/wrapper-output"; then echo 'Account failure was not sanitized.' >&2; exit 1; fi
    [[ "$AZURE_CONFIG_DIR" == "$MOCK_CONFIG" && "$COPILOT_PROVIDER_API_KEY_COMMAND" == "$previous_command" && -z "${COPILOT_PROVIDER_API_KEY:-}" && -z "${COPILOT_PROVIDER_BEARER_TOKEN:-}" ]]
    [[ "$(wc -l < "$MOCK_STATE/requests")" == "$previous_requests" ]]
  done
done
reset_fixture
(
  command() {
    if [[ "$*" == '-v az' ]]; then return 1; fi
    builtin command "$@"
  }
  if source "$wrapper" https://gateway.example.test gpt-4o-mini "$MOCK_APP_ID" > "$MOCK_STATE/wrapper-output" 2>&1; then
    echo 'Missing Azure CLI was accepted.' >&2; exit 1
  fi
  grep -Fq 'Azure CLI (az) installed separately' "$MOCK_STATE/wrapper-output"
  [[ "$COPILOT_PROVIDER_API_KEY_COMMAND" == "$previous_command" ]]
)
printf '%s\n' 'PASS: Bash missing account/CLI gives explicit cloud/cache guidance without token requests or credential changes'

for setup_case in new-commercial new-government existing-commercial existing-government existing-empty existing-reauth declined unattended missing-tenant cancelled wrong-cloud-cache wrong-tenant-cache non-user-cache wrong-tenant-result wrong-cloud-result non-user-result changed-user-result custom-without-cloud hostname-lookalike conflicting-cloud insecure-url cloud-set-retry-government cloud-verify-retry-government cache-publish-race; do
  (
    reset_fixture
    export HOME="$scratch/setup-$setup_case"
    mkdir -p "$HOME"
    export AUTH_MODE=jwt REFRESH_TOKEN=1 BYOK_LOGIN=1 BYOK_USE_DEVICE_CODE=0 BYOK_TENANT_ID="$MOCK_TENANT_ID"
    unset BYOK_AZURE_CLOUD AZURE_CONFIG_DIR
    export MOCK_TARGET_CLOUD=AzureCloud MOCK_EXISTING_CACHE=0 MOCK_LOGIN_FAILURE=0 MOCK_LOGIN_RESULT=valid
    export MOCK_CLOUD_SET_FAILURE=0 MOCK_CLOUD_VERIFY_FAILURE=0 MOCK_PUBLISH_RACE=0
    expected_logins=1 expected_sets=1 expected_success=1
    setup_url=https://fixture.azure-api.net/openai
    case "$setup_case" in
      *government)
        export MOCK_TARGET_CLOUD=AzureUSGovernment BYOK_USE_DEVICE_CODE=1
        setup_url=https://fixture.azure-api.us/openai
        ;;
    esac
    reset_fixture "$MOCK_TARGET_CLOUD"
    if [[ "$MOCK_TARGET_CLOUD" == AzureUSGovernment ]]; then export MOCK_CONFIG="$HOME/.azure-byok-government"
    else export MOCK_CONFIG="$HOME/.azure-byok-commercial"; fi
    export MOCK_SETUP_LOG="$HOME/operations"
    : > "$MOCK_SETUP_LOG"
    case "$setup_case" in
      existing-*|wrong-cloud-cache|wrong-tenant-cache|non-user-cache|changed-user-result)
        mkdir -p "$MOCK_CONFIG"
        printf '%s' preserve > "$MOCK_CONFIG/sentinel"
        export AZURE_CONFIG_DIR="$MOCK_CONFIG" MOCK_EXISTING_CACHE=1 BYOK_LOGIN=0
        expected_logins=0 expected_sets=0
        ;;
    esac
    case "$setup_case" in
      existing-empty) export MOCK_EMPTY_ACCOUNT=1 BYOK_LOGIN=1; expected_logins=1 ;;
      existing-reauth) export BYOK_LOGIN=1; expected_logins=1 ;;
      declined|unattended) export BYOK_LOGIN=0; expected_success=0 expected_logins=0 expected_sets=0 ;;
      missing-tenant) unset BYOK_TENANT_ID; expected_success=0 expected_logins=0 expected_sets=0 ;;
      cancelled) export MOCK_LOGIN_FAILURE=1; expected_success=0 ;;
      wrong-cloud-cache) export MOCK_CLOUD=AzureUSGovernment; expected_success=0 ;;
      wrong-tenant-cache) mutate_fixture "$MOCK_STATE/account.json" '.tenantId="00000000-0000-0000-0000-000000000099"'; expected_success=0 ;;
      non-user-cache) mutate_fixture "$MOCK_STATE/account.json" '.user.type="servicePrincipal"'; expected_success=0 ;;
      wrong-tenant-result) export MOCK_LOGIN_RESULT=wrong-tenant; expected_success=0 ;;
      wrong-cloud-result) export MOCK_LOGIN_RESULT=wrong-cloud; expected_success=0 ;;
      non-user-result) export MOCK_LOGIN_RESULT=non-user; expected_success=0 ;;
      changed-user-result) export MOCK_LOGIN_RESULT=changed-user BYOK_LOGIN=1; expected_logins=1 expected_success=0 ;;
      custom-without-cloud) setup_url=https://gateway.example.test/openai; expected_success=0 expected_logins=0 expected_sets=0 ;;
      hostname-lookalike) setup_url=https://fixture.azure-api.us.example.test/openai; expected_success=0 expected_logins=0 expected_sets=0 ;;
      conflicting-cloud) export BYOK_AZURE_CLOUD=AzureUSGovernment; expected_success=0 expected_logins=0 expected_sets=0 ;;
      insecure-url) setup_url=http://fixture.azure-api.net/openai; expected_success=0 expected_logins=0 expected_sets=0 ;;
      cloud-set-retry-government) export MOCK_CLOUD_SET_FAILURE=1; expected_success=0 expected_logins=0 ;;
      cloud-verify-retry-government) export MOCK_CLOUD_VERIFY_FAILURE=1; expected_success=0 expected_logins=0 ;;
      cache-publish-race) export MOCK_PUBLISH_RACE=1; expected_success=0 expected_logins=0 ;;
    esac
    before_cache="${AZURE_CONFIG_DIR-}"
    before_had_cache="${AZURE_CONFIG_DIR+x}"
    before_command="$COPILOT_PROVIDER_API_KEY_COMMAND"
    succeeded=0
    if source "$wrapper" "$setup_url" gpt-4o-mini "$MOCK_APP_ID" > "$HOME/output" 2>&1; then succeeded=1; fi
    actual_logins="$(grep -c '^login$' "$MOCK_SETUP_LOG" || true)"
    actual_sets="$(grep -c '^cloud-set$' "$MOCK_SETUP_LOG" || true)"
    if [[ "$succeeded" != "$expected_success" || "$actual_logins" != "$expected_logins" || "$actual_sets" != "$expected_sets" ]]; then
      printf 'Bash first-run case failed: %s\n' "$setup_case" >&2; exit 1
    fi
    if [[ "$succeeded" == 0 ]]; then
      [[ "${AZURE_CONFIG_DIR-}" == "$before_cache" && "${AZURE_CONFIG_DIR+x}" == "$before_had_cache" && "$COPILOT_PROVIDER_API_KEY_COMMAND" == "$before_command" ]]
    else
      [[ "$AZURE_CONFIG_DIR" == "$MOCK_CONFIG" && "$TOKEN_CLOUD" == "$MOCK_TARGET_CLOUD" && "$TOKEN_TENANT" == "$MOCK_TENANT_ID" ]]
    fi
    if [[ "$MOCK_EXISTING_CACHE" == 1 || "$MOCK_PUBLISH_RACE" == 1 ]]; then [[ "$(cat "$MOCK_CONFIG/sentinel")" == preserve ]]; fi
    if compgen -G "$HOME/.byok-cache-setup-*" >/dev/null; then echo 'Owned staging cache was not cleaned up.' >&2; exit 1; fi
    if [[ "$setup_case" == cloud-*-retry-government ]]; then
      [[ ! -e "$MOCK_CONFIG" ]] || { echo 'Failed setup published an uninitialized cache.' >&2; exit 1; }
      export MOCK_CLOUD_SET_FAILURE=0 MOCK_CLOUD_VERIFY_FAILURE=0
      source "$wrapper" "$setup_url" gpt-4o-mini "$MOCK_APP_ID" >> "$HOME/output" 2>&1
      [[ "$AZURE_CONFIG_DIR" == "$MOCK_CONFIG" && "$(cat "$MOCK_CONFIG/mock-cloud")" == "$MOCK_TARGET_CLOUD" ]]
      [[ "$(grep -c '^login$' "$MOCK_SETUP_LOG")" == 1 && "$(grep -c '^cloud-set$' "$MOCK_SETUP_LOG")" == 2 ]]
      if compgen -G "$HOME/.byok-cache-setup-*" >/dev/null; then echo 'Retry left cache staging behind.' >&2; exit 1; fi
    fi
    if grep -Eq 'private-error-details|payload.signature' "$HOME/output"; then echo 'Setup leaked private fixture output.' >&2; exit 1; fi
  )
done
reset_fixture
printf '%s\n' 'PASS: twenty-four Bash first-run cases plus two retries cover cache staging, failure recovery, destination conflicts and no existing-cloud switches'

export MOCK_LEGACY_CLI=1
if (source "$wrapper" https://gateway.example.test gpt-4o-mini "$MOCK_APP_ID" > /dev/null 2>&1); then echo 'Unsupported CLI accepted.' >&2; exit 1; fi
export MOCK_LEGACY_CLI=0 AUTH_MODE=subscriptionKey REFRESH_TOKEN=0 APIM_SUBSCRIPTION_KEY=fixture-key
source "$wrapper" https://gateway.example.test gpt-4o-mini > /dev/null
[[ "$COPILOT_PROVIDER_API_KEY" == fixture-key && -z "${COPILOT_PROVIDER_API_KEY_COMMAND:-}" && -z "${COPILOT_PROVIDER_BEARER_TOKEN:-}" ]] || { echo 'Static-key transition failed.' >&2; exit 1; }
printf '%s\n' 'PASS: Bash unsupported CLI rejected and static-key transition preserved'
node() {
  [[ "$1" == */okta/token.mjs && "$2" == --config && "$3" == "$OKTA_CONFIG_FILE" && "$#" == 3 ]] || return 1
  [[ "${MOCK_OKTA_FAILURE:-0}" == 0 ]] || return 1
  printf '%s\n' "$MOCK_OKTA_TOKEN"
}
export -f node
export AUTH_MODE=okta OKTA_CONFIG_FILE="$MOCK_STATE/fixture's okta.json" MOCK_OKTA_TOKEN=fixture.okta.signature MOCK_OKTA_FAILURE=0
source "$wrapper" https://gateway.example.test gpt-4o-mini > /dev/null
[[ -z "${COPILOT_PROVIDER_API_KEY:-}" && -z "${COPILOT_PROVIDER_BEARER_TOKEN:-}" && -n "$COPILOT_PROVIDER_API_KEY_COMMAND" ]] || { echo 'Okta conflicting sources remain.' >&2; exit 1; }
[[ "$COPILOT_PROVIDER_API_KEY_COMMAND" != *fixture.okta.signature* && "$COPILOT_PROVIDER_API_KEY_COMMAND" != *--login* ]] || { echo 'Okta command contains a token or login.' >&2; exit 1; }
[[ "$(eval "$COPILOT_PROVIDER_API_KEY_COMMAND")" == fixture.okta.signature ]] || { echo 'Okta command did not reacquire.' >&2; exit 1; }
export MOCK_OKTA_TOKEN=renewed.okta.signature
[[ "$(eval "$COPILOT_PROVIDER_API_KEY_COMMAND")" == renewed.okta.signature ]] || { echo 'Okta command did not renew.' >&2; exit 1; }
export MOCK_OKTA_FAILURE=1
if (source "$wrapper" https://gateway.example.test gpt-4o-mini > /dev/null 2>&1); then echo 'Failed Okta preflight accepted.' >&2; exit 1; fi
printf '%s\n' 'PASS: Bash Okta command quoting, renewal, single credential and failed preflight'
export AUTH_MODE=subscriptionKey REFRESH_TOKEN=0
export COPILOT_PROVIDER_HEADERS='X-Example: value\nAuthorization: Bearer conflict'
if (source "$wrapper" https://gateway.example.test gpt-4o-mini > /dev/null 2>&1); then echo 'Custom credential conflict accepted.' >&2; exit 1; fi
printf '%s\n' 'PASS: Bash credential header collision rejected'