#!/usr/bin/env bash
# Deploy the IntelliJ BYOK bolt-on (Option A) — dedicated /intellij API + policy on the customer's
# existing Internal APIM, plus the static-IP nginx proxy VM.
#
# Preflight checks the customer environment, then runs a subscription-scoped Bicep deployment.
# Everything comes from the parameters file (copy main.parameters.example.json -> main.parameters.json).
#
# Requires: az, jq.
#
# Usage:
#   ./deploy.sh [-p main.parameters.json] [-l <region>] [-k <foundry-api-key>] [--what-if]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAMS="$SCRIPT_DIR/main.parameters.json"
LOCATION=""
FOUNDRY_API_KEY=""
WHATIF=0

while [ $# -gt 0 ]; do
  case "$1" in
    -p|--parameters) PARAMS="$2"; shift 2 ;;
    -l|--location)   LOCATION="$2"; shift 2 ;;
    -k|--foundry-api-key) FOUNDRY_API_KEY="$2"; shift 2 ;;
    --what-if)       WHATIF=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

info() { printf '\033[36m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m[OK]  \033[0m %s\n' "$1"; }
warn() { printf '  \033[33m[WARN]\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1" >&2; exit 1; }

command -v az >/dev/null 2>&1 || fail "Azure CLI (az) not found on PATH."
command -v jq >/dev/null 2>&1 || fail "jq not found on PATH."
[ -f "$PARAMS" ] || fail "Parameters file not found: $PARAMS (copy main.parameters.example.json to main.parameters.json)."

val() { jq -r ".parameters.$1.value // empty" "$PARAMS"; }

LOC="${LOCATION:-$(val location)}"
[ -n "$LOC" ] || fail "location not provided (set it in the params file or pass -l)."

# ------------------------------------------------------------------ Preflight
info "== Preflight =="
ACCT="$(az account show -o json 2>/dev/null || true)"
[ -n "$ACCT" ] || fail "Not signed in. Run: az login"
SUB="$(echo "$ACCT" | jq -r '.id')"
ARM_BASE="$(az cloud show --query endpoints.resourceManager -o tsv | sed 's:/*$::')"
ok "Signed in: $(echo "$ACCT" | jq -r '.name')  (sub $SUB)"

APIM_RG="$(val apimResourceGroup)"; APIM="$(val apimName)"
az apim show -g "$APIM_RG" -n "$APIM" -o none 2>/dev/null || fail "APIM '$APIM' not found in resource group '$APIM_RG'."
ok "APIM found: $APIM"

BE="$(val existingBackendName)"
BE_URL="$ARM_BASE/subscriptions/$SUB/resourceGroups/$APIM_RG/providers/Microsoft.ApiManagement/service/$APIM/backends/$BE?api-version=2024-05-01"
if az rest --method get --url "$BE_URL" -o none 2>/dev/null; then ok "Foundry backend found: $BE"; else warn "Backend '$BE' not found on APIM — double-check existingBackendName."; fi

PRODUCTS=()
while IFS= read -r product; do
  [ -n "$product" ] && PRODUCTS+=("$product")
done < <(jq -r '[.parameters.existingProductName.value // empty] + (.parameters.additionalProductNames.value // []) | map(select(type == "string" and length > 0)) | unique[]' "$PARAMS")
if [ ${#PRODUCTS[@]} -gt 0 ]; then
  for product in "${PRODUCTS[@]}"; do
    az apim product show -g "$APIM_RG" --service-name "$APIM" --product-id "$product" -o none 2>/dev/null || fail "Product '$product' not found on APIM (existingProductName/additionalProductNames)."
    ok "Product found: $product"
  done
else
  ok "No product association (subscription keys are all-APIs scope)."
fi

IP="$(val proxyStaticPrivateIp)"
[ -n "$IP" ] || fail "proxyStaticPrivateIp not set in the params file."
VM_RG="$(val vmResourceGroup)"; VM_NAME="$(val vmName)"; [ -n "$VM_NAME" ] || VM_NAME="vm-byok-intellij-proxy"
PROXY_NIC_ID="$(val proxyNicId)"
if [ -n "$PROXY_NIC_ID" ]; then
  NIC_JSON="$(az network nic show --ids "$PROXY_NIC_ID" -o json 2>/dev/null || true)"
  [ -n "$NIC_JSON" ] || fail "proxyNicId not found or not readable: $PROXY_NIC_ID"
  NIC_SUB="$(echo "$NIC_JSON" | jq -r '.id | split("/")[2] // empty')"
  [ "$NIC_SUB" = "$SUB" ] || fail "The supplied proxy NIC must be in the active subscription '$SUB'."
  NIC_LOCATION="$(echo "$NIC_JSON" | jq -r '.location')"
  [ "$(printf '%s' "$NIC_LOCATION" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$LOC" | tr '[:upper:]' '[:lower:]')" ] || fail "The supplied proxy NIC is in '$NIC_LOCATION' but the proxy VM location is '$LOC'."
  [ "$(echo "$NIC_JSON" | jq '.ipConfigurations | length')" = "1" ] || fail "The supplied proxy NIC must have exactly one IP configuration."
  NIC_IP="$(echo "$NIC_JSON" | jq -r '.ipConfigurations[0].privateIPAddress // empty')"
  [ "$NIC_IP" = "$IP" ] || fail "proxyStaticPrivateIp '$IP' does not match the supplied NIC private IP '$NIC_IP'."
  [ "$(echo "$NIC_JSON" | jq -r '.ipConfigurations[0].privateIPAllocationMethod')" = "Static" ] || fail "The supplied proxy NIC must use static private IP allocation."
  [ -z "$(echo "$NIC_JSON" | jq -r '.ipConfigurations[0].publicIPAddress.id // empty')" ] || fail "The supplied proxy NIC must not have a public IP address."
  [ -n "$(echo "$NIC_JSON" | jq -r '.ipConfigurations[0].subnet.id // empty')" ] || fail "The supplied proxy NIC is not attached to a subnet."
  ATTACHED_VM_ID="$(echo "$NIC_JSON" | jq -r '.virtualMachine.id // empty')"
  EXPECTED_VM_ID="/subscriptions/$SUB/resourceGroups/$VM_RG/providers/Microsoft.Compute/virtualMachines/$VM_NAME"
  if [ -n "$ATTACHED_VM_ID" ] && [ "$(printf '%s' "$ATTACHED_VM_ID" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$EXPECTED_VM_ID" | tr '[:upper:]' '[:lower:]')" ]; then
    fail "The supplied proxy NIC is already attached to another VM: $ATTACHED_VM_ID"
  fi
  if [ -n "$ATTACHED_VM_ID" ]; then ok "Customer NIC already attached to this proxy VM (idempotent re-run): $NIC_IP"; else ok "Customer NIC validated ($NIC_IP); the deployment will attach it and create no NIC."; fi
else
  SUBNET_ID="$(val vmSubnetId)"
  [ -n "$SUBNET_ID" ] || fail "vmSubnetId is required when proxyNicId is empty."
  az network vnet subnet show --ids "$SUBNET_ID" -o none 2>/dev/null || fail "Subnet not found: $SUBNET_ID"
  ok "Subnet found"

  OWN_IP="$(az network nic show -g "$VM_RG" -n "nic-$VM_NAME" --query "ipConfigurations[0].privateIPAddress" -o tsv 2>/dev/null || true)"
  if [ "$OWN_IP" = "$IP" ]; then
    ok "Static IP $IP already held by this deployment's NIC (idempotent re-run)."
  elif [[ "$SUBNET_ID" =~ /resourceGroups/([^/]+)/providers/Microsoft.Network/virtualNetworks/([^/]+)/subnets/ ]]; then
    VNET_RG="${BASH_REMATCH[1]}"; VNET="${BASH_REMATCH[2]}"
    AVAIL="$(az network vnet check-ip-address -g "$VNET_RG" -n "$VNET" --ip-address "$IP" --query available -o tsv 2>/dev/null || echo "")"
    if [ "$AVAIL" = "false" ]; then fail "Static IP $IP is already in use in VNet '$VNET'."; fi
    ok "Static IP $IP is available in '$VNET'."
  fi
fi

# App Insights: metrics are always on. The operator supplies the name + resource group of an
# EXISTING Application Insights (same subscription as APIM); the template reads its connection
# string itself, so no secret ever has to live in the params file or the CLI invocation.
AI_NAME="$(val appInsightsName)"
AI_RG="$(val appInsightsResourceGroup)"
[ -n "$AI_NAME" ] || fail "appInsightsName not set in the params file (metrics are required — point it at the customer's existing Application Insights)."
[ -n "$AI_RG" ] || fail "appInsightsResourceGroup not set in the params file (the resource group of that Application Insights, same subscription as APIM)."
az resource show -g "$AI_RG" -n "$AI_NAME" --resource-type microsoft.insights/components -o none 2>/dev/null || fail "Application Insights '$AI_NAME' not found in resource group '$AI_RG'."
ok "Application Insights '$AI_NAME' found in '$AI_RG'."

# When not creating the VM RG, it must already exist.
CREATE_VM_RG="$(val createVmResourceGroup)"
VM_RG_NAME="$(val vmResourceGroup)"
if [ "$CREATE_VM_RG" = "false" ]; then
  az group show -n "$VM_RG_NAME" -o none 2>/dev/null || fail "createVmResourceGroup=false but VM resource group '$VM_RG_NAME' does not exist (create it, or set createVmResourceGroup=true)."
  ok "VM resource group '$VM_RG_NAME' exists (deploying into it; createVmResourceGroup=false)."
fi

# ------------------------------------------------------------------ Deploy
info $'\n== Deploy =='
TEMPLATE="$SCRIPT_DIR/main.bicep"
EXTRA=()
[ -n "$FOUNDRY_API_KEY" ] && EXTRA+=(--parameters "foundryApiKey=$FOUNDRY_API_KEY")

if [ "$WHATIF" = "1" ]; then
  az deployment sub what-if --location "$LOC" --template-file "$TEMPLATE" --parameters "@$PARAMS" ${EXTRA[@]+"${EXTRA[@]}"}
  exit $?
fi

DEPLOY_NAME="intellij-byok-$(date +%Y%m%d%H%M%S)"
az deployment sub create --name "$DEPLOY_NAME" --location "$LOC" --template-file "$TEMPLATE" --parameters "@$PARAMS" ${EXTRA[@]+"${EXTRA[@]}"} || fail "Deployment failed."

# ------------------------------------------------------------------ Done
BASE_URL="$(az deployment sub show --name "$DEPLOY_NAME" --query properties.outputs.clientBaseUrl.value -o tsv)"
info $'\n== Done =='
echo "Client base URL : $BASE_URL"
echo ""
echo "Configure JetBrains AI Assistant (Settings -> Tools -> AI Assistant -> Providers & API keys):"
echo "  URL     : $BASE_URL"
echo "  API Key : <the developer's existing APIM subscription key>"
echo ""
echo "Validate from an IN-VNET host (the proxy + APIM are private):"
echo "  curl -s $BASE_URL/models -H 'Authorization: Bearer <APIM-SUB-KEY>'"
echo "  # expect HTTP 200 and an OpenAI-shaped {\"object\":\"list\",\"data\":[...]}"
