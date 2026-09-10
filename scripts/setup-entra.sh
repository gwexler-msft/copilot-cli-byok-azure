#!/usr/bin/env bash
# Creates (or removes) the Entra app registration that fronts the Copilot BYOK APIM gateway.
# See setup-entra.ps1 for full docs. Works in both AzureCloud and AzureUSGovernment.
set -euo pipefail

DISPLAY_NAME="${1:-copilot-byok-gateway}"
SCOPE_NAME="${2:-cli.invoke}"
ACTION="${3:-create}"   # create | remove

az version >/dev/null 2>&1 || { echo "Install Azure CLI first." >&2; exit 1; }
CTX="$(az account show 2>/dev/null)" || { echo "Run 'az login' first." >&2; exit 1; }
TENANT_ID="$(echo "$CTX" | jq -r .tenantId)"
echo "Cloud:    $(echo "$CTX" | jq -r .environmentName)"
echo "Tenant:   $TENANT_ID"
echo "Account:  $(echo "$CTX" | jq -r .user.name)"

EXISTING="$(az ad app list --display-name "$DISPLAY_NAME" --query '[0].appId' -o tsv)"

if [[ "$ACTION" == "remove" ]]; then
  [[ -z "$EXISTING" ]] && { echo "No app named '$DISPLAY_NAME' found."; exit 0; }
  echo "Deleting app '$DISPLAY_NAME' ($EXISTING)..."
  az ad app delete --id "$EXISTING"
  exit 0
fi

if [[ -n "$EXISTING" ]]; then
  APP_ID="$EXISTING"
  echo "Reusing existing app $APP_ID."
else
  APP_ID="$(az ad app create --display-name "$DISPLAY_NAME" --sign-in-audience AzureADMyOrg --query appId -o tsv)"
  echo "Created app $APP_ID."
fi

# Graph endpoint differs per cloud (graph.microsoft.com vs graph.microsoft.us).
GRAPH="$(az cloud show --query 'endpoints.microsoftGraphResourceId' -o tsv)"
GRAPH="${GRAPH%/}"
OBJECT_ID="$(az ad app show --id "$APP_ID" --query id -o tsv)"
TENANT_SHORT="${TENANT_ID:0:8}"
APP_ID_URI="api://${DISPLAY_NAME}-${TENANT_SHORT}"

# Reuse the existing scope id on re-runs; otherwise mint one.
SCOPE_ID="$(az ad app show --id "$APP_ID" --query "api.oauth2PermissionScopes[?value=='$SCOPE_NAME'].id | [0]" -o tsv)"
[[ -z "$SCOPE_ID" ]] && SCOPE_ID="$(uuidgen)"

# Step 1: identifier URI + v2 tokens + the exposed scope (same request, per tenant policy).
# Address by object id; the 'applications(appId=...)' form breaks some shells/wrappers.
echo "Setting Application ID URI ($APP_ID_URI), v2 tokens, and scope '$SCOPE_NAME'..."
TMP1="$(mktemp)"
cat > "$TMP1" <<EOF
{
  "identifierUris": ["$APP_ID_URI"],
  "api": {
    "requestedAccessTokenVersion": 2,
    "oauth2PermissionScopes": [{
      "id": "$SCOPE_ID",
      "adminConsentDescription": "Invoke the Copilot BYOK gateway on behalf of the signed-in user.",
      "adminConsentDisplayName": "Invoke $DISPLAY_NAME",
      "userConsentDescription":  "Allow $DISPLAY_NAME to be invoked on your behalf.",
      "userConsentDisplayName":  "Invoke $DISPLAY_NAME",
      "isEnabled": true,
      "type": "User",
      "value": "$SCOPE_NAME"
    }]
  }
}
EOF
az rest --method PATCH \
  --uri "$GRAPH/v1.0/applications/$OBJECT_ID" \
  --resource "$GRAPH" \
  --headers "Content-Type=application/json" \
  --body "@$TMP1"
rm -f "$TMP1"

# Step 2: pre-authorize Azure CLI for the now-existing scope (separate request).
echo "Pre-authorizing Azure CLI for scope '$SCOPE_NAME'..."
TMP2="$(mktemp)"
cat > "$TMP2" <<EOF
{
  "api": {
    "preAuthorizedApplications": [{
      "appId": "04b07795-8ddb-461a-bbee-02f9e1bf7b46",
      "delegatedPermissionIds": ["$SCOPE_ID"]
    }]
  }
}
EOF
az rest --method PATCH \
  --uri "$GRAPH/v1.0/applications/$OBJECT_ID" \
  --resource "$GRAPH" \
  --headers "Content-Type=application/json" \
  --body "@$TMP2"
rm -f "$TMP2"

if [[ -z "$(az ad sp list --filter "appId eq '$APP_ID'" --query '[0].id' -o tsv)" ]]; then
  az ad sp create --id "$APP_ID" >/dev/null
fi

cat <<EOF

----- Save these for infra/main.parameters.json -----
tenantId   : $TENANT_ID
appId      : $APP_ID
appIdUri   : $APP_ID_URI
scopeName  : $SCOPE_NAME

NOTE: with v2 tokens the JWT 'aud' claim is the appId GUID ($APP_ID),
      NOT the api:// URI. The APIM validate-jwt audience must be this GUID.
      Clients still fetch tokens with: az account get-access-token --resource $APP_ID_URI
-----------------------------------------------------
EOF
