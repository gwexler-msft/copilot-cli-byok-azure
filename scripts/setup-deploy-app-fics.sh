#!/usr/bin/env bash
#
# setup-deploy-app-fics.sh — Adds (or removes) GitHub Actions OIDC federated credentials
# on the Entra deploy app registration used by the CI/CD `deploy.yml` workflow.
# Bash counterpart to setup-deploy-app-fics.ps1; same flags, same idempotent semantics,
# works in both AzureCloud and AzureUSGovernment (issuer URL is identical).
#
# Subject convention:   repo:<repo>:environment:<env>
# Issuer:               https://token.actions.githubusercontent.com
# Audience:             api://AzureADTokenExchange
# FIC name pattern:     fic-env-<env>
#
# Usage:
#   ./setup-deploy-app-fics.sh --app-display-name copilot-byok-cicd
#   ./setup-deploy-app-fics.sh --app-id 00000000-0000-0000-0000-000000000000 \
#       --envs comm-pilot,comm-dev
#   ./setup-deploy-app-fics.sh --app-display-name copilot-byok-cicd --envs comm-dev --remove
#
set -euo pipefail

REPO_DEFAULT='gwexler_microsoft/copilot-cli-byok-azure'
ENVS_DEFAULT='comm-pilot,comm-dev,gov-pilot,gov-dev'

usage() {
  sed -n '2,18p' "$0"
  exit 1
}

APP_DISPLAY_NAME=''
APP_ID=''
REPOSITORY="$REPO_DEFAULT"
ENVS_CSV="$ENVS_DEFAULT"
REMOVE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-display-name) APP_DISPLAY_NAME="$2"; shift 2 ;;
    --app-id)           APP_ID="$2"; shift 2 ;;
    --repository)       REPOSITORY="$2"; shift 2 ;;
    --envs)             ENVS_CSV="$2"; shift 2 ;;
    --remove)           REMOVE=1; shift ;;
    -h|--help)          usage ;;
    *) echo "Unknown flag: $1" >&2; usage ;;
  esac
done

if [[ -z "$APP_DISPLAY_NAME" && -z "$APP_ID" ]]; then
  echo "Provide --app-display-name OR --app-id" >&2
  usage
fi

# --- preflight -----------------------------------------------------------------------------
CTX=$(az account show --only-show-errors -o json 2>/dev/null || true)
[[ -z "$CTX" ]] && { echo 'Run `az login` first.' >&2; exit 1; }
CLOUD=$(echo "$CTX" | jq -r '.environmentName')
TENANT=$(echo "$CTX" | jq -r '.tenantId')
echo "Cloud:       $CLOUD"
echo "Tenant:      $TENANT"
echo "Repo:        $REPOSITORY"
echo "Env subjects:$ENVS_CSV"

if [[ -z "$APP_ID" ]]; then
  APP_ID=$(az ad app list --display-name "$APP_DISPLAY_NAME" --query '[0].appId' -o tsv)
  if [[ -z "$APP_ID" ]]; then
    echo "No Entra app registration named '$APP_DISPLAY_NAME' found in tenant $TENANT." >&2
    exit 1
  fi
fi

APP_NAME=$(az ad app show --id "$APP_ID" --query 'displayName' -o tsv)
echo "App:         $APP_NAME ($APP_ID)"

# --- existing FICs -------------------------------------------------------------------------
EXISTING=$(az ad app federated-credential list --id "$APP_ID" -o json)

ISSUER='https://token.actions.githubusercontent.com'
AUDIENCE='api://AzureADTokenExchange'

IFS=',' read -r -a ENV_ARR <<< "$ENVS_CSV"

for env in "${ENV_ARR[@]}"; do
  FIC_NAME="fic-env-$env"
  SUBJECT="repo:${REPOSITORY}:environment:${env}"

  CUR_ID=$(echo "$EXISTING" | jq -r --arg n "$FIC_NAME" '.[] | select(.name==$n) | .id' || true)

  if [[ $REMOVE -eq 1 ]]; then
    if [[ -n "$CUR_ID" ]]; then
      echo "Removing $FIC_NAME -> $SUBJECT"
      az ad app federated-credential delete --id "$APP_ID" --federated-credential-id "$CUR_ID" >/dev/null
    else
      echo "Skip remove $FIC_NAME (not present)"
    fi
    continue
  fi

  if [[ -n "$CUR_ID" ]]; then
    CUR_SUBJECT=$(echo "$EXISTING" | jq -r --arg n "$FIC_NAME" '.[] | select(.name==$n) | .subject')
    CUR_ISSUER=$(echo "$EXISTING" | jq -r --arg n "$FIC_NAME" '.[] | select(.name==$n) | .issuer')
    if [[ "$CUR_SUBJECT" != "$SUBJECT" || "$CUR_ISSUER" != "$ISSUER" ]]; then
      echo "WARN  FIC '$FIC_NAME' exists with different subject/issuer; recreating."
      az ad app federated-credential delete --id "$APP_ID" --federated-credential-id "$CUR_ID" >/dev/null
    else
      echo "OK    $FIC_NAME -> $SUBJECT"
      continue
    fi
  fi

  TMP=$(mktemp)
  cat > "$TMP" <<EOF
{
  "name": "$FIC_NAME",
  "issuer": "$ISSUER",
  "subject": "$SUBJECT",
  "audiences": ["$AUDIENCE"]
}
EOF
  az ad app federated-credential create --id "$APP_ID" --parameters "@$TMP" >/dev/null
  rm -f "$TMP"
  echo "ADD   $FIC_NAME -> $SUBJECT"
done

echo ''
echo 'Final FIC inventory:'
az ad app federated-credential list --id "$APP_ID" -o table --query "[].{name:name,subject:subject,issuer:issuer}"
