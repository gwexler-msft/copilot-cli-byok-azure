#!/usr/bin/env bash
# Idempotent bootstrap helper for the BYOK self-hosted GitHub Actions runner pool.
# Bash counterpart of scripts/setup-gh-runner.ps1. See that file for full docs.
#
# Modes:
#   set-secret   (default) - write GH_RUNNER_PAT into the ACA Job secret 'gh-pat'
#   status                 - list runners registered for the env's labels
#   test                   - dispatch a test workflow, wait for a new Job execution
#
# Usage:
#   GH_RUNNER_PAT=ghp_xxx ./scripts/setup-gh-runner.sh
#   ./scripts/setup-gh-runner.sh status --env-name comm-pilot
#   ./scripts/setup-gh-runner.sh test  --env-name comm-pilot
#
# Required tools: az (logged in), gh (authenticated), jq.

set -euo pipefail

ACTION="${1:-set-secret}"
shift || true

ENV_NAME="${AZURE_ENV_NAME:-comm-pilot}"
REPOSITORY="gwexler_microsoft/copilot-cli-byok-azure"
RESOURCE_GROUP=""
JOB_NAME=""
LABELS=""
WORKFLOW_FILE="smoke-test.yml"
TOKEN="${GH_RUNNER_PAT:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-name)      ENV_NAME="$2";       shift 2;;
    --resource-group)RESOURCE_GROUP="$2"; shift 2;;
    --job-name)      JOB_NAME="$2";       shift 2;;
    --repository)    REPOSITORY="$2";     shift 2;;
    --labels)        LABELS="$2";         shift 2;;
    --workflow)      WORKFLOW_FILE="$2";  shift 2;;
    --token)         TOKEN="$2";          shift 2;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

: "${LABELS:=$ENV_NAME}"
: "${RESOURCE_GROUP:=rg-copilot-byok-$ENV_NAME}"

cyan() { printf '\033[36m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

discover_job() {
  local rg="$1" matches
  matches=$(az containerapp job list -g "$rg" --query "[?starts_with(name, 'caj-runner-')].name" -o tsv 2>/dev/null || true)
  local count
  count=$(printf '%s\n' "$matches" | grep -c . || true)
  if [[ "$count" -eq 0 ]]; then
    echo "No caj-runner-* Job found in $rg. Pass --job-name explicitly or verify deployGhRunner=true." >&2
    exit 1
  fi
  if [[ "$count" -gt 1 ]]; then
    echo "Multiple runner Jobs in $rg: $matches -- pass --job-name explicitly." >&2
  fi
  printf '%s\n' "$matches" | head -n1
}

assert_gh_auth() {
  if ! gh auth status >/dev/null 2>&1; then
    echo "gh CLI not authenticated. Run 'gh auth login' first." >&2
    exit 1
  fi
  if ! gh api "repos/$REPOSITORY" -q '.full_name' >/dev/null 2>&1; then
    echo "Cannot read repo $REPOSITORY via gh CLI." >&2
    exit 1
  fi
}

set_secret() {
  local rg="$1" job="$2" pat="$3"
  cyan "==> Updating Job secret 'gh-pat' on $job ..."
  az containerapp job secret set -g "$rg" -n "$job" --secrets "gh-pat=$pat" -o none
  green "    OK."

  local names
  names=$(az containerapp job secret list -g "$rg" -n "$job" --query "[].name" -o tsv 2>/dev/null || true)
  if ! grep -qx 'gh-pat' <<<"$names"; then
    yellow "Secret list did not include 'gh-pat' after set: '$names'"
  else
    green "    Verified 'gh-pat' present on Job."
  fi

  local trigger
  trigger=$(az containerapp job show -g "$rg" -n "$job" --query 'properties.configuration.triggerType' -o tsv)
  yellow "    Job triggerType = $trigger"
  if [[ "$trigger" != 'Event' ]]; then
    cat <<EOF
$(yellow '
NOTE: triggerType is not Event. The KEDA scaler is NOT yet active.
      Setting the secret alone does NOT flip the trigger -- the Bicep template drives
      that via the ghRunnerPat deployment parameter. Run:

        azd provision --parameters ghRunnerPat=<same-pat>

      so Bicep sees a non-empty value and writes triggerType=Event + the KEDA rule.')
EOF
  else
    green "    KEDA event trigger active. Runner pool will scale on queued jobs matching '$LABELS'."
  fi
}

list_runners() {
  cyan "==> Listing runners registered on $REPOSITORY ..."
  local data
  data=$(gh api "repos/$REPOSITORY/actions/runners" 2>/dev/null || true)
  if [[ -z "$data" ]]; then
    yellow "No runner data returned (PAT may lack 'Administration: read')."
    return
  fi
  local label_filters
  label_filters=$(echo "$LABELS" | tr ',' '\n' | sed 's/^ *//; s/ *$//')
  local found
  found=$(jq -r --argjson filt "$(echo "$label_filters" | jq -R . | jq -s .)" '
    .runners[] | . as $r |
    ([$r.labels[].name] | tostring) as $rl |
    select(any($filt[]; . as $f | ([$r.labels[].name] | index($f)))) |
    "\($r.name)\t\($r.status)\t\($r.busy)\t\([$r.labels[].name] | join(","))"
  ' <<<"$data" || true)
  if [[ -z "$found" ]]; then
    yellow "    No runners currently registered matching label(s) '$LABELS'."
    yellow "    (Ephemeral runners deregister immediately after each job, so this is normal between runs.)"
  else
    printf 'NAME\tSTATUS\tBUSY\tLABELS\n%s\n' "$found" | column -t -s $'\t'
  fi
}

invoke_test() {
  local rg="$1" job="$2"
  cyan "==> Dispatching workflow '$WORKFLOW_FILE' on $REPOSITORY ..."
  if ! gh workflow run "$WORKFLOW_FILE" --repo "$REPOSITORY"; then
    echo "gh workflow run failed." >&2
    exit 1
  fi
  cyan "    Dispatched. Watching for new Job executions on $job ..."
  mapfile -t baseline < <(az containerapp job execution list -g "$rg" -n "$job" --query "[].name" -o tsv 2>/dev/null || true)
  local deadline=$(( $(date +%s) + 180 ))
  local new_exec=""
  while [[ $(date +%s) -lt $deadline ]]; do
    sleep 15
    mapfile -t current < <(az containerapp job execution list -g "$rg" -n "$job" --query "[].name" -o tsv 2>/dev/null || true)
    for c in "${current[@]}"; do
      local match=0
      for b in "${baseline[@]}"; do
        if [[ "$c" == "$b" ]]; then match=1; break; fi
      done
      if [[ $match -eq 0 ]]; then new_exec="$c"; break; fi
    done
    if [[ -n "$new_exec" ]]; then break; fi
    echo "    ...still waiting (KEDA poll interval is ~30s)"
  done
  if [[ -z "$new_exec" ]]; then
    yellow "No new Job execution observed within 3 min. Verify the workflow file targets 'runs-on: $LABELS' and that Bicep was deployed with ghRunnerPat set."
    return
  fi
  green "    New execution: $new_exec"
  echo "    Tail logs: az containerapp job execution show -g $rg -n $job --job-execution-name $new_exec"
}

if [[ -z "$JOB_NAME" ]]; then
  cyan "==> Discovering Job name in $RESOURCE_GROUP ..."
  JOB_NAME="$(discover_job "$RESOURCE_GROUP")"
  green "    Found: $JOB_NAME"
fi

case "$ACTION" in
  set-secret)
    if [[ -z "$TOKEN" ]]; then
      echo "No --token supplied and GH_RUNNER_PAT env is empty." >&2
      exit 2
    fi
    set_secret "$RESOURCE_GROUP" "$JOB_NAME" "$TOKEN"
    ;;
  status)
    assert_gh_auth
    list_runners
    ;;
  test)
    assert_gh_auth
    invoke_test "$RESOURCE_GROUP" "$JOB_NAME"
    ;;
  *)
    echo "Unknown action: $ACTION (use set-secret | status | test)" >&2
    exit 2
    ;;
esac
