#!/usr/bin/env bash
# View or configure Azure OpenAI / Foundry content filters (responsible-AI / "raiPolicies")
# for the BYOK model deployments. Cloud-agnostic (AzureCloud + AzureUSGovernment).
#
# Microsoft applies a default content filter (Microsoft.DefaultV2) to every deployment. This
# script lets a customer:
#   --show                       list raiPolicies and which policy each deployment uses
#   --apply --policy-name N \
#           --config-path F      create/update a custom raiPolicy from a JSON spec
#   [--attach-to-deployment D]   also repoint deployment D to the new policy
#
# Reads the ARM endpoint from the active cloud (az cloud show), so it works in Gov.
#
# IMPORTANT: Lowering filtering below Microsoft defaults requires an approved
# modified-content-filter application; the platform rejects an unapproved loosened policy.
# Tightening (more blocking / lower thresholds) is always allowed.
#
# Usage:
#   ./configure-content-filter.sh --resource-group RG --account-name ACC --show
#   ./configure-content-filter.sh --resource-group RG --account-name ACC \
#       --apply --policy-name byok-strict --config-path ./scripts/content-filter.sample.json \
#       --attach-to-deployment gpt-5.1
set -euo pipefail

API_VERSION='2024-10-01'
RG=''; ACC=''; ACTION='show'; POLICY_NAME=''; CONFIG_PATH=''; ATTACH=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group) RG="$2"; shift 2 ;;
    --account-name) ACC="$2"; shift 2 ;;
    --show) ACTION='show'; shift ;;
    --apply) ACTION='apply'; shift ;;
    --policy-name) POLICY_NAME="$2"; shift 2 ;;
    --config-path) CONFIG_PATH="$2"; shift 2 ;;
    --attach-to-deployment) ATTACH="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$RG" || -z "$ACC" ]] && { echo 'ERROR: --resource-group and --account-name are required.' >&2; exit 1; }
az account show >/dev/null 2>&1 || { echo 'ERROR: run `az login` first.' >&2; exit 1; }

ARM="$(az cloud show --query 'endpoints.resourceManager' -o tsv)"; ARM="${ARM%/}"
SUB="$(az account show --query id -o tsv)"
BASE="$ARM/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/$ACC"

if [[ "$ACTION" == 'show' ]]; then
  echo "== raiPolicies on $ACC =="
  az rest --method get --url "$BASE/raiPolicies?api-version=$API_VERSION" \
    --query 'value[].{name:name, base:properties.basePolicyName, mode:properties.mode}' -o table
  echo
  echo "== deployments and their content filter =="
  az rest --method get --url "$BASE/deployments?api-version=$API_VERSION" \
    --query 'value[].{deployment:name, raiPolicyName:properties.raiPolicyName}' -o table
  exit 0
fi

# apply
[[ -z "$POLICY_NAME" || -z "$CONFIG_PATH" ]] && { echo 'ERROR: --apply needs --policy-name and --config-path.' >&2; exit 1; }
[[ -f "$CONFIG_PATH" ]] || { echo "ERROR: config not found: $CONFIG_PATH" >&2; exit 1; }

BASE_POLICY="$(jq -r '.basePolicyName // "Microsoft.DefaultV2"' "$CONFIG_PATH")"
MODE="$(jq -r '.mode // "Default"' "$CONFIG_PATH")"
FILTERS="$(jq -c '.contentFilters' "$CONFIG_PATH")"
BODY="$(jq -nc --arg b "$BASE_POLICY" --arg m "$MODE" --argjson f "$FILTERS" \
  '{properties:{basePolicyName:$b, mode:$m, contentFilters:$f}}')"

echo "Applying raiPolicy '$POLICY_NAME' to $ACC ..."
echo "WARNING: loosening below Microsoft defaults requires an approved modified-content-filter application." >&2
az rest --method put --url "$BASE/raiPolicies/$POLICY_NAME?api-version=$API_VERSION" \
  --headers 'Content-Type=application/json' --body "$BODY" >/dev/null
echo "  raiPolicy '$POLICY_NAME' applied."

if [[ -n "$ATTACH" ]]; then
  echo "Repointing deployment '$ATTACH' to raiPolicy '$POLICY_NAME' ..."
  DEP="$(az rest --method get --url "$BASE/deployments/$ATTACH?api-version=$API_VERSION")"
  DEP_BODY="$(echo "$DEP" | jq -c --arg p "$POLICY_NAME" \
    '{sku:.sku, properties:{model:.properties.model, raiPolicyName:$p}}')"
  az rest --method put --url "$BASE/deployments/$ATTACH?api-version=$API_VERSION" \
    --headers 'Content-Type=application/json' --body "$DEP_BODY" >/dev/null
  echo "  Deployment '$ATTACH' now uses '$POLICY_NAME'."
  echo "  To persist in IaC, set the model module's raiPolicyName param to '$POLICY_NAME'."
fi
