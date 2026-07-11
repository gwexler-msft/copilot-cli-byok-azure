#!/usr/bin/env bash
# COMMERCIAL-tenant peer setup for the parallel /openai-commercial route. Creates the secretless
# service principal the Gov APIM federates to, trusts the Gov APIM managed identity via a
# federated identity credential, grants it "Cognitive Services OpenAI User" on the commercial
# Foundry, and (with --allow-gov-egress-ip) allowlists the Gov NAT egress IP on the Foundry
# firewall. Idempotent. Run signed in to the COMMERCIAL tenant (AzureCloud).
# See setup-commercial-backend.ps1 / docs/commercial-foundry-route.md for full docs.
#
# This is the cross-tenant/cross-cloud half that the Gov main.bicep + azd hooks CANNOT do
# (directory + RBAC writes in a different tenant/cloud). It emits COMMERCIAL_CLIENT_ID /
# COMMERCIAL_TENANT_ID for the Gov side (foundryCommercialClientId / foundryCommercialTenantId,
# foundryCommercialAuthMode=servicePrincipalFederated).
#
# Get the GOV inputs first (signed in to AzureUSGovernment):
#   az apim show -g <gov-rg> -n <gov-apim> --query identity.principalId -o tsv   # --gov-apim-mi-object-id
#   az network public-ip show -g <gov-rg> -n pip-natgw-copilot-byok-<env>-<sfx> --query ipAddress -o tsv  # --gov-egress-ip
set -euo pipefail

APP_NAME='copilot-byok-commercial-backend'
ROLE_NAME='Cognitive Services OpenAI User'
FIC_NAME='gov-apim-fed'
ONLY_ISSUER='v2'
SKIP_FED=false
CREATE_SECRET=false
SECRET_YEARS=1
ALLOW_GOV_EGRESS_IP=false
FOUNDRY_ACCOUNT="${foundryCommercialAccountName:-}"
FOUNDRY_RG="${foundryCommercialResourceGroup:-}"
FOUNDRY_ID=''
GOV_TENANT_ID="${GOV_TENANT_ID:-}"
GOV_APIM_MI_OBJECT_ID="${GOV_APIM_MI_OBJECT_ID:-}"
GOV_EGRESS_IP="${GOV_EGRESS_IP:-}"
SOURCE_ISSUER_V1=''
SOURCE_ISSUER_V2=''
EXPECTED_COMMERCIAL_TENANT_ID=''

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --foundry-account-name) FOUNDRY_ACCOUNT="$2"; shift 2;;
    --foundry-resource-group) FOUNDRY_RG="$2"; shift 2;;
    --foundry-resource-id) FOUNDRY_ID="$2"; shift 2;;
    --gov-tenant-id) GOV_TENANT_ID="$2"; shift 2;;
    --gov-apim-mi-object-id) GOV_APIM_MI_OBJECT_ID="$2"; shift 2;;
    --gov-egress-ip) GOV_EGRESS_IP="$2"; shift 2;;
    --app-name) APP_NAME="$2"; shift 2;;
    --role-name) ROLE_NAME="$2"; shift 2;;
    --source-issuer-v1) SOURCE_ISSUER_V1="$2"; shift 2;;
    --source-issuer-v2) SOURCE_ISSUER_V2="$2"; shift 2;;
    --fic-name) FIC_NAME="$2"; shift 2;;
    --only-issuer) ONLY_ISSUER="$2"; shift 2;;
    --skip-federated-credential) SKIP_FED=true; shift;;
    --create-secret) CREATE_SECRET=true; shift;;
    --secret-years) SECRET_YEARS="$2"; shift 2;;
    --allow-gov-egress-ip) ALLOW_GOV_EGRESS_IP=true; shift;;
    --expected-commercial-tenant-id) EXPECTED_COMMERCIAL_TENANT_ID="$2"; shift 2;;
    -h|--help) usage 0;;
    *) echo "Unknown arg: $1" >&2; usage 1;;
  esac
done

set_output_var() {
  local name="$1" value="$2"
  if command -v azd >/dev/null 2>&1; then azd env set "$name" "$value" >/dev/null 2>&1 || true; fi
  if [[ -n "${GITHUB_ENV:-}" ]]; then echo "$name=$value" >> "$GITHUB_ENV"; fi
  echo "  $name=$value"
}

az version >/dev/null 2>&1 || { echo "Install Azure CLI first." >&2; exit 1; }
CTX="$(az account show -o json 2>/dev/null)" || { echo "Not logged in. Run 'az cloud set --name AzureCloud; az login' (the COMMERCIAL tenant) first." >&2; exit 1; }
CLOUD="$(echo "$CTX" | jq -r .environmentName)"
TENANT="$(echo "$CTX" | jq -r .tenantId)"
echo "Cloud:   $CLOUD"
echo "Tenant:  $TENANT"
echo -e "Account: $(echo "$CTX" | jq -r .user.name)\n"
[[ "$CLOUD" == "AzureCloud" ]] || echo "WARNING: signed-in cloud is '$CLOUD', not 'AzureCloud' (the COMMERCIAL tenant hosting the Foundry)." >&2
if [[ -n "$EXPECTED_COMMERCIAL_TENANT_ID" && "$TENANT" != "$EXPECTED_COMMERCIAL_TENANT_ID" ]]; then
  echo "Signed-in tenant $TENANT != expected commercial tenant $EXPECTED_COMMERCIAL_TENANT_ID." >&2; exit 1
fi

[[ -n "$GOV_TENANT_ID" ]] || { echo "--gov-tenant-id is required." >&2; exit 1; }
[[ -n "$GOV_APIM_MI_OBJECT_ID" ]] || { echo "--gov-apim-mi-object-id is required (Gov APIM MI object id = FIC subject)." >&2; exit 1; }

# Resolve the Foundry account resource id.
if [[ -z "$FOUNDRY_ID" ]]; then
  [[ -n "$FOUNDRY_ACCOUNT" && -n "$FOUNDRY_RG" ]] || { echo "Provide --foundry-resource-id, or both --foundry-account-name and --foundry-resource-group." >&2; exit 1; }
  FOUNDRY_ID="$(az cognitiveservices account show -g "$FOUNDRY_RG" -n "$FOUNDRY_ACCOUNT" --query id -o tsv)"
  [[ -n "$FOUNDRY_ID" ]] || { echo "Could not resolve Foundry account '$FOUNDRY_ACCOUNT' in '$FOUNDRY_RG'." >&2; exit 1; }
fi
echo -e "Foundry account: $FOUNDRY_ID\n"

[[ -n "$SOURCE_ISSUER_V1" ]] || SOURCE_ISSUER_V1="https://sts.windows.net/$GOV_TENANT_ID/"
[[ -n "$SOURCE_ISSUER_V2" ]] || SOURCE_ISSUER_V2="https://login.microsoftonline.us/$GOV_TENANT_ID/v2.0"

# 1. App registration + service principal (no secret, no certificate).
APP_ID="$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv 2>/dev/null || true)"
if [[ -n "$APP_ID" ]]; then
  echo "Reusing app registration '$APP_NAME' (appId $APP_ID)."
else
  APP_ID="$(az ad app create --display-name "$APP_NAME" --sign-in-audience AzureADMyOrg --query appId -o tsv)"
  [[ -n "$APP_ID" ]] || { echo "Failed to create app registration '$APP_NAME'." >&2; exit 1; }
  echo "Created app registration '$APP_NAME' (appId $APP_ID)."
fi
SP_ID="$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || true)"
if [[ -z "$SP_ID" ]]; then
  SP_ID="$(az ad sp create --id "$APP_ID" --query id -o tsv)"
  [[ -n "$SP_ID" ]] || { echo "Failed to create service principal for appId $APP_ID." >&2; exit 1; }
  echo "Created service principal (objectId $SP_ID)."
else
  echo "Reusing service principal (objectId $SP_ID)."
fi

# 2. Federated identity credential(s) trusting the Gov APIM managed identity.
set_fic() {
  local name="$1" issuer="$2"
  local existing
  existing="$(az ad app federated-credential list --id "$APP_ID" --query "[?name=='$name'] | [0]" -o json 2>/dev/null || echo '')"
  if [[ -n "$existing" && "$existing" != "null" ]]; then
    local ex_sub ex_iss ex_id
    ex_sub="$(echo "$existing" | jq -r .subject)"; ex_iss="$(echo "$existing" | jq -r .issuer)"; ex_id="$(echo "$existing" | jq -r .id)"
    if [[ "$ex_sub" == "$GOV_APIM_MI_OBJECT_ID" && "$ex_iss" == "$issuer" ]]; then
      echo "  FIC '$name' already correct — skipping."; return
    fi
    echo "  FIC '$name' exists but differs — recreating."
    az ad app federated-credential delete --id "$APP_ID" --federated-credential-id "$ex_id" >/dev/null
  fi
  local tmp; tmp="$(mktemp)"
  jq -n --arg name "$name" --arg issuer "$issuer" --arg subject "$GOV_APIM_MI_OBJECT_ID" \
    '{name:$name, issuer:$issuer, subject:$subject, audiences:["api://AzureADTokenExchange"], description:"Secretless cross-tenant token exchange for the BYOK commercial route"}' > "$tmp"
  az ad app federated-credential create --id "$APP_ID" --parameters "@$tmp" >/dev/null
  rm -f "$tmp"
  echo "  FIC '$name' set (issuer $issuer)."
}

echo "Federated identity credentials (subject=$GOV_APIM_MI_OBJECT_ID, aud=api://AzureADTokenExchange):"
if [[ "$SKIP_FED" == "true" ]]; then
  echo "  --skip-federated-credential set - not creating any FIC (Gov -> Commercial can only use"
  echo "  servicePrincipal secret mode; cross-sovereign-cloud WIF is blocked, AADSTS700238)."
else
  # Entra allows only ONE FIC per subject (a v1+v2 hedge fails at runtime with AADSTS700263).
  # APIM managed identities mint a v2 token, so the default is the single v2 FIC.
  [[ "$ONLY_ISSUER" == "v1" || "$ONLY_ISSUER" == "both" ]] && set_fic "${FIC_NAME}-v1" "$SOURCE_ISSUER_V1"
  [[ "$ONLY_ISSUER" == "v2" || "$ONLY_ISSUER" == "both" ]] && set_fic "${FIC_NAME}-v2" "$SOURCE_ISSUER_V2"
fi

# 3. Data-plane role on the Foundry account.
az role assignment create --assignee-object-id "$SP_ID" --assignee-principal-type ServicePrincipal --role "$ROLE_NAME" --scope "$FOUNDRY_ID" >/dev/null
echo -e "\nGranted '$ROLE_NAME' to the SP on the Foundry account."

# 3b. Optional client secret for servicePrincipal (secret) mode. REQUIRED for Gov -> Commercial
# (secretless federated path is blocked, AADSTS700238).
CLIENT_SECRET=''
if [[ "$CREATE_SECRET" == "true" ]]; then
  CLIENT_SECRET="$(az ad app credential reset --id "$APP_ID" --display-name "${APP_NAME}-secret" --years "$SECRET_YEARS" --append --query password -o tsv)"
  [[ -n "$CLIENT_SECRET" ]] || { echo "Failed to create a client secret on the SP." >&2; exit 1; }
  echo "WARNING: a client secret was created. Protect it: store in Key Vault / a secure variable; never commit." >&2
fi

# 4. Optional firewall allowlist for the Gov egress IP.
if [[ "$ALLOW_GOV_EGRESS_IP" == "true" ]]; then
  [[ -n "$GOV_EGRESS_IP" ]] || { echo "--allow-gov-egress-ip requires --gov-egress-ip." >&2; exit 1; }
  echo "WARNING: allowlisting $GOV_EGRESS_IP on the Foundry firewall and enabling public network access (defaultAction stays Deny)." >&2
  az cognitiveservices account network-rule add --ids "$FOUNDRY_ID" --ip-address "$GOV_EGRESS_IP" -o none
  az resource update --ids "$FOUNDRY_ID" --set properties.publicNetworkAccess=Enabled -o none
  echo "Foundry firewall now: $(az cognitiveservices account show --ids "$FOUNDRY_ID" --query '{pna:properties.publicNetworkAccess, defaultAction:properties.networkAcls.defaultAction, ipRules:properties.networkAcls.ipRules[].value}' -o json)"
else
  echo -e "\nSkipping firewall change (no --allow-gov-egress-ip). The Gov gateway is blocked until ${GOV_EGRESS_IP:-<gov-egress-ip>} is allowlisted on the Foundry."
fi

# 5. Emit the values the Gov side needs.
echo -e "\nGov-side parameters (set on the Gov deployment):"
set_output_var 'COMMERCIAL_CLIENT_ID' "$APP_ID"
set_output_var 'COMMERCIAL_TENANT_ID' "$TENANT"
if [[ "$CREATE_SECRET" == "true" ]]; then
  set_output_var 'COMMERCIAL_FOUNDRY_CLIENT_SECRET' "$CLIENT_SECRET"
  echo -e "\nGov -> Commercial (cross-sovereign-cloud): foundryCommercialAuthMode=servicePrincipal,"
  echo "deployFoundryCommercial=true, foundryCommercialClientId=$APP_ID, foundryCommercialTenantId=$TENANT,"
  echo "foundryCommercialClientSecret=<the secret above>, then re-provision the Gov gateway."
else
  echo -e "\nSame-cloud cross-tenant: foundryCommercialAuthMode=servicePrincipalFederated, deployFoundryCommercial=true,"
  echo "foundryCommercialClientId=$APP_ID, foundryCommercialTenantId=$TENANT, then re-provision the Gov gateway."
  echo "(Gov -> Commercial cannot use the federated path - AADSTS700238; re-run with --skip-federated-credential --create-secret.)"
fi
