#!/usr/bin/env bash
# Pre-provision guard for the self-hosted runner's GitHub auth (issue #58). See
# check-runner-auth.ps1 for full docs. Wired as an azd `preprovision` hook AFTER
# check-deploy-access. Fails fast (exit 1) when the runner would deploy in `app` mode but the
# GitHub App credentials are not resolvable, preventing a silent placeholder fall-back.
#   SKIP_RUNNER_AUTH_CHECK=true -> bypass (intentional placeholder bootstrap).
set -euo pipefail

if [[ "${SKIP_RUNNER_AUTH_CHECK:-}" == "true" ]]; then
  echo "[runner-auth] SKIP_RUNNER_AUTH_CHECK=true — skipping runner auth guard."
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# azd always provisions from infra/main.parameters.json (workflows stage the per-env file into it
# before `azd provision`). Read that staged file so the guard reflects what will actually deploy.
PARAM_FILE="$SCRIPT_DIR/../infra/main.parameters.json"
if [[ ! -f "$PARAM_FILE" ]]; then
  echo "[runner-auth] $PARAM_FILE not found — skipping guard."
  exit 0
fi
ENV_LABEL="${AZURE_ENV_NAME:-main.parameters.json}"

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

DEPLOY_RUNNER="$(resolve_param deployGhRunner)"
if [[ "$DEPLOY_RUNNER" != "true" ]]; then
  echo "[runner-auth] deployGhRunner is not true ($ENV_LABEL) — runner not deployed; skipping guard."
  exit 0
fi

AUTH_MODE="$(resolve_param ghRunnerAuthMode)"
[[ -n "$AUTH_MODE" ]] || AUTH_MODE="app"   # matches the template default
SECRET_FROM_KV="$(resolve_param ghRunnerSecretFromKeyVault)"
KV_ON=0; [[ "$SECRET_FROM_KV" == "true" ]] && KV_ON=1

echo "[runner-auth] env=$ENV_LABEL  mode=$AUTH_MODE  secretFromKeyVault=$([[ $KV_ON -eq 1 ]] && echo true || echo false)"

if [[ "$AUTH_MODE" == "app" ]]; then
  APP_ID="$(resolve_param ghAppId)"
  INST_ID="$(resolve_param ghAppInstallationId)"
  INLINE_KEY="$(resolve_param ghAppPrivateKey)"

  MISSING=()
  [[ -n "$APP_ID" ]]  || MISSING+=("ghAppId (GH_APP_ID)")
  [[ -n "$INST_ID" ]] || MISSING+=("ghAppInstallationId (GH_APP_INSTALLATION_ID)")
  KEY_OK=0; { [[ $KV_ON -eq 1 ]] || [[ -n "$INLINE_KEY" ]]; } && KEY_OK=1

  if [[ ${#MISSING[@]} -gt 0 || $KEY_OK -ne 1 ]]; then
    echo "" >&2
    echo "RUNNER AUTH CHECK FAILED ($ENV_LABEL, mode 'app')." >&2
    [[ ${#MISSING[@]} -gt 0 ]] && echo "  Missing App identifiers: ${MISSING[*]}" >&2
    [[ $KEY_OK -ne 1 ]] && echo "  No private-key source: ghRunnerSecretFromKeyVault is false AND inline ghAppPrivateKey (GH_APP_PRIVATE_KEY) is empty." >&2
    cat >&2 <<'EOF'

Provisioning now would leave the runner as a Phase-1 placeholder (no autoscaling).
Fix ONE of:
  1. Create/connect the GitHub App once:  ./scripts/setup-gh-app.ps1 -SetRepoVars
     (sets repo Variables GH_APP_ID + GH_APP_INSTALLATION_ID and Secret GH_APP_PRIVATE_KEY;
      for pilots it also prints the runner Key Vault seeding commands).
  2. Or use PAT for this env: set ghRunnerAuthMode=pat in the param file + provide GH_RUNNER_PAT.
  3. Or intentionally bootstrapping a placeholder first? Re-run with SKIP_RUNNER_AUTH_CHECK=true.
EOF
    exit 1
  fi

  echo "[runner-auth] App credentials resolved (App ID + Installation ID present, key source configured). OK."
  exit 0
fi

# pat mode (opt-in fallback)
PAT="$(resolve_param ghRunnerPat)"
PAT_OK=0; { [[ $KV_ON -eq 1 ]] || [[ -n "$PAT" ]]; } && PAT_OK=1
if [[ $PAT_OK -ne 1 ]]; then
  echo "" >&2
  echo "[runner-auth] WARNING: mode 'pat' but neither GH_RUNNER_PAT nor ghRunnerSecretFromKeyVault is set." >&2
  echo "             The runner will provision as a Phase-1 placeholder (no autoscaling) until a PAT is supplied." >&2
  exit 0
fi

echo "[runner-auth] PAT credential source configured. OK."
exit 0
