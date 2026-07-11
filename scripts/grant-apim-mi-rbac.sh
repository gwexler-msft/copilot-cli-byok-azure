#!/usr/bin/env bash
# Grant the APIM managed identity "Cognitive Services OpenAI User" on the AOAI and
# Foundry accounts. Idempotent. See grant-apim-mi-rbac.ps1 for full docs.
# Wired as an azd `postprovision` hook; also runnable standalone.
# Works in AzureCloud + AzureUSGovernment.
set -euo pipefail

ROLE_NAME='Cognitive Services OpenAI User'   # 5e0bd9bd-7b93-4f28-af87-19fc36ad61bd

# Params fall back to azd-injected output env vars.
RESOURCE_GROUP="${1:-${resourceGroup:-}}"
APIM_NAME="${2:-${apimName:-}}"
AOAI_ACCOUNT="${3:-${aoaiAccountName:-}}"
FOUNDRY_ACCOUNT="${4:-${foundryAccountName:-}}"

az version >/dev/null 2>&1 || { echo "Install Azure CLI first." >&2; exit 1; }
CTX="$(az account show -o json 2>/dev/null)" || { echo "Not logged in. Run 'az login' (matching the deployment cloud) first." >&2; exit 1; }
echo "Cloud:   $(echo "$CTX" | jq -r .environmentName)"
echo "Account: $(echo "$CTX" | jq -r .user.name)"

[[ -n "$RESOURCE_GROUP" ]] || { echo "ResourceGroup not provided and \$resourceGroup is empty." >&2; exit 1; }
[[ -n "$APIM_NAME" ]]      || { echo "ApimName not provided and \$apimName is empty." >&2; exit 1; }

# Resolve the APIM managed identity principalId fresh — it changes on every recreate.
APIM_MI="$(az apim show -g "$RESOURCE_GROUP" -n "$APIM_NAME" --query 'identity.principalId' -o tsv)"
[[ -n "$APIM_MI" ]] || { echo "Could not read identity.principalId from APIM '$APIM_NAME'. Is system-assigned MI enabled?" >&2; exit 1; }
echo -e "APIM MI principalId: $APIM_MI\n"

grant_account() {
  local account_name="$1" label="$2"
  if [[ -z "$account_name" ]]; then echo "$label account not deployed — skipping."; return; fi
  local id
  id="$(az cognitiveservices account show -g "$RESOURCE_GROUP" -n "$account_name" --query id -o tsv)"
  [[ -n "$id" ]] || { echo "Could not resolve $label account '$account_name'." >&2; exit 1; }
  az role assignment create \
    --assignee-object-id "$APIM_MI" \
    --assignee-principal-type ServicePrincipal \
    --role "$ROLE_NAME" \
    --scope "$id" >/dev/null
  echo "Granted '$ROLE_NAME' to APIM MI on $label account: $account_name"
}

grant_account "$AOAI_ACCOUNT"    "AOAI"
grant_account "$FOUNDRY_ACCOUNT" "Foundry"

echo -e "\nDone. APIM MI RBAC grants are in place."
