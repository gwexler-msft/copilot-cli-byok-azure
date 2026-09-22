#!/usr/bin/env bash
# Bootstrap for the pre-baked self-hosted GitHub Actions runner (issue #94).
#
# The official ghcr.io/actions/actions-runner base image ships config.sh/run.sh but NOT
# myoung34/github-runner's env-var bootstrap. This script re-implements that bootstrap on
# the SAME env contract so the runner Job (infra/modules/gh-runner.bicep) can point at the
# ACR-baked image with NO changes to its container env block:
#
#   App mode  (recommended): APP_ID + APP_PRIVATE_KEY + APP_LOGIN
#   PAT mode  (fallback):    ACCESS_TOKEN
#   Common:   REPO_URL, RUNNER_SCOPE(=repo), LABELS, EPHEMERAL, RUNNER_NAME_PREFIX,
#             DISABLE_RUNNER_UPDATE
#
# Flow: derive a short-lived REGISTRATION token from GitHub, then
#   config.sh --ephemeral  →  run.sh   (exactly one job per container, then deregister).
set -euo pipefail

API_URL="${GITHUB_API_URL:-https://api.github.com}"

# Both helpers write to STDERR so that command-substituted functions (e.g.
# get_registration_token) keep STDOUT clean — only the token must reach stdout, or a
# stray log line gets captured into the value and config.sh fails with "New-line
# characters are not allowed in header values."
log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() { printf '[entrypoint] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -n "${REPO_URL:-}" ]] || die "REPO_URL is required (https://github.com/<owner>/<repo>)."

# Derive owner/repo from REPO_URL (strip scheme + host, trim trailing slash/.git).
repo_path="${REPO_URL#*://}"      # github.com/<owner>/<repo>
repo_path="${repo_path#*/}"        # <owner>/<repo>
repo_path="${repo_path%/}"
repo_path="${repo_path%.git}"
OWNER="${repo_path%%/*}"
REPO="${repo_path##*/}"
[[ -n "$OWNER" && -n "$REPO" && "$OWNER" != "$REPO" ]] || die "could not parse owner/repo from REPO_URL='$REPO_URL'."

# base64url with no padding (JWT + signature encoding).
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# Mint a GitHub App JWT (RS256) from APP_ID + APP_PRIVATE_KEY, valid ~9 min.
mint_app_jwt() {
  local key="$APP_PRIVATE_KEY"
  # Accept a key passed with literal "\n" sequences (single-line env) as well as real PEM.
  case "$key" in *'\n'*) key="$(printf '%b' "$key")";; esac

  local now iat exp header payload signing_input sig
  now="$(date +%s)"; iat=$((now - 60)); exp=$((now + 540))
  header='{"alg":"RS256","typ":"JWT"}'
  payload="$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$iat" "$exp" "$APP_ID")"
  signing_input="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
  sig="$(printf '%s' "$signing_input" \
        | openssl dgst -sha256 -sign <(printf '%s' "$key") -binary \
        | b64url)"
  printf '%s.%s' "$signing_input" "$sig"
}

get_registration_token() {
  local reg_token
  if [[ -n "${APP_ID:-}" && -n "${APP_PRIVATE_KEY:-}" ]]; then
    log "Auth mode: GitHub App (APP_ID=$APP_ID)."
    local jwt installation_id installation_token
    jwt="$(mint_app_jwt)"
    # Resolve the installation for THIS repo (no installation-id env needed), then exchange
    # the App JWT for a short-lived installation access token.
    installation_id="$(curl -fsSL \
        -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github+json" \
        "${API_URL}/repos/${OWNER}/${REPO}/installation" | jq -r '.id')"
    [[ -n "$installation_id" && "$installation_id" != "null" ]] || die "could not resolve App installation for ${OWNER}/${REPO}."
    installation_token="$(curl -fsSL -X POST \
        -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github+json" \
        "${API_URL}/app/installations/${installation_id}/access_tokens" | jq -r '.token')"
    [[ -n "$installation_token" && "$installation_token" != "null" ]] || die "could not mint installation access token."
    reg_token="$(curl -fsSL -X POST \
        -H "Authorization: token ${installation_token}" \
        -H "Accept: application/vnd.github+json" \
        "${API_URL}/repos/${OWNER}/${REPO}/actions/runners/registration-token" | jq -r '.token')"
  elif [[ -n "${ACCESS_TOKEN:-}" ]]; then
    log "Auth mode: PAT."
    reg_token="$(curl -fsSL -X POST \
        -H "Authorization: token ${ACCESS_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "${API_URL}/repos/${OWNER}/${REPO}/actions/runners/registration-token" | jq -r '.token')"
  else
    die "no credentials: set APP_ID+APP_PRIVATE_KEY (app mode) or ACCESS_TOKEN (pat mode)."
  fi
  [[ -n "$reg_token" && "$reg_token" != "null" ]] || die "failed to obtain a runner registration token."
  printf '%s' "$reg_token"
}

cd /home/runner

REG_TOKEN="$(get_registration_token)"

RUNNER_NAME="${RUNNER_NAME_PREFIX:-runner}-$(hostname)-${RANDOM}"
CONFIG_ARGS=(
  --unattended
  --url "${REPO_URL}"
  --token "${REG_TOKEN}"
  --name "${RUNNER_NAME}"
  --labels "${LABELS:-self-hosted}"
  --work _work
  --replace
)
# Ephemeral = register, run exactly one job, then auto-deregister (the default and only
# supported mode for this Job — KEDA scales one container per queued job).
[[ "${EPHEMERAL:-true}" == "true" ]] && CONFIG_ARGS+=(--ephemeral)
# Keep the baked runner binaries deterministic across executions.
[[ "${DISABLE_RUNNER_UPDATE:-true}" == "true" ]] && CONFIG_ARGS+=(--disableupdate)

log "Registering runner '${RUNNER_NAME}' for ${OWNER}/${REPO} (labels: ${LABELS:-self-hosted})."
./config.sh "${CONFIG_ARGS[@]}"

# Best-effort deregister if we're interrupted before the ephemeral auto-removal fires.
cleanup() {
  log "Removing runner registration."
  ./config.sh remove --token "${REG_TOKEN}" >/dev/null 2>&1 || true
}
trap 'cleanup; exit 130' INT TERM

log "Starting runner."
exec ./run.sh
