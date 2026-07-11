#!/usr/bin/env bash
# Grant the register-app managed identity a Microsoft Graph application permission
# (default GroupMember.Read.All) so it can resolve a developer's security groups via
# `getMemberGroups` on group overage (~200 groups). Idempotent. See
# grant-register-graph-perms.ps1 for full docs.
# Wired as an azd `postprovision` hook; also runnable standalone by a tenant admin.
# Works in AzureCloud + AzureUSGovernment. Degrades gracefully (exit 0) when the caller
# lacks directory-consent rights — never fails the deployment.
set -euo pipefail

# Microsoft Graph's appId is the same well-known GUID in every national cloud.
GRAPH_APP_ID='00000003-0000-0000-c000-000000000000'

# Params fall back to azd-injected output env vars.
REGISTER_UAMI_CLIENT_ID="${1:-${registerUamiClientId:-}}"
PERMISSION_NAME="${2:-GroupMember.Read.All}"

az version >/dev/null 2>&1 || { echo "Install Azure CLI first." >&2; exit 1; }
CTX="$(az account show -o json 2>/dev/null)" || { echo "Not logged in. Run 'az login' (matching the deployment cloud) first." >&2; exit 1; }
echo "Cloud:   $(echo "$CTX" | jq -r .environmentName)"
echo "Account: $(echo "$CTX" | jq -r .user.name)"

if [[ -z "$REGISTER_UAMI_CLIENT_ID" ]]; then
  echo "Register app not deployed (registerUamiClientId is empty) — skipping Graph grant."
  exit 0
fi

# Cloud-aware Graph endpoint (graph.microsoft.com vs graph.microsoft.us).
GRAPH="$(az cloud show --query 'endpoints.microsoftGraphResourceId' -o tsv)"
GRAPH="${GRAPH%/}"
echo "Graph:   $GRAPH"

# Resolve the managed identity's service principal (the grant target/principal).
MI_SP_ID="$(az ad sp show --id "$REGISTER_UAMI_CLIENT_ID" --query 'id' -o tsv 2>/dev/null || true)"
if [[ -z "$MI_SP_ID" ]]; then
  echo "Could not resolve a service principal for managed identity clientId '$REGISTER_UAMI_CLIENT_ID'. Has the register app been provisioned? Skipping."
  exit 0
fi

# Resolve Microsoft Graph's service principal in this tenant + the target appRole id.
GRAPH_SP_ID="$(az ad sp show --id "$GRAPH_APP_ID" --query 'id' -o tsv)"
[[ -n "$GRAPH_SP_ID" ]] || { echo "Could not resolve the Microsoft Graph service principal in this tenant." >&2; exit 1; }
APP_ROLE_ID="$(az ad sp show --id "$GRAPH_APP_ID" --query "appRoles[?value=='$PERMISSION_NAME' && contains(allowedMemberTypes, 'Application')].id | [0]" -o tsv)"
[[ -n "$APP_ROLE_ID" ]] || { echo "Microsoft Graph exposes no application appRole named '$PERMISSION_NAME'." >&2; exit 1; }

echo "MI SP:   $MI_SP_ID"
echo -e "Grant:   $PERMISSION_NAME ($APP_ROLE_ID) on Microsoft Graph\n"

# Idempotency: is the assignment already present?
EXISTING="$(az rest --method GET \
  --uri "$GRAPH/v1.0/servicePrincipals/$MI_SP_ID/appRoleAssignments" \
  --resource "$GRAPH" -o json 2>/dev/null || echo '{}')"
if echo "$EXISTING" | jq -e --arg r "$APP_ROLE_ID" --arg s "$GRAPH_SP_ID" \
     '.value[]? | select(.appRoleId==$r and .resourceId==$s)' >/dev/null 2>&1; then
  echo "Already granted '$PERMISSION_NAME' to the register MI — nothing to do."
  exit 0
fi

# Create the assignment.
BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT
jq -n --arg p "$MI_SP_ID" --arg s "$GRAPH_SP_ID" --arg r "$APP_ROLE_ID" \
  '{principalId:$p, resourceId:$s, appRoleId:$r}' > "$BODY_FILE"

set +e
OUT="$(az rest --method POST \
  --uri "$GRAPH/v1.0/servicePrincipals/$MI_SP_ID/appRoleAssignedTo" \
  --resource "$GRAPH" \
  --headers 'Content-Type=application/json' \
  --body "@$BODY_FILE" 2>&1)"
RC=$?
set -e

if [[ $RC -ne 0 ]]; then
  if echo "$OUT" | grep -qiE 'already exists|Permission being assigned already exists'; then
    echo "Grant already present (reported by Graph) — treating as success."
    exit 0
  fi
  if echo "$OUT" | grep -qiE 'Authorization_RequestDenied|Insufficient privileges|Forbidden|\b403\b'; then
    cat >&2 <<EOF

WARNING: could not grant '$PERMISSION_NAME' — the signed-in account lacks directory-consent rights.

This is EXPECTED when the azd deploy principal is not a tenant admin. The deployment
itself is fine; the group-overage fallback just won't work until an admin grants this.

Have a Global Administrator or Privileged Role Administrator sign in to THIS cloud and run:

  az login                       # correct cloud (Commercial or Gov)
  ./scripts/grant-register-graph-perms.sh $REGISTER_UAMI_CLIENT_ID

Or skip Graph entirely by setting the app registration groups claim to
'Groups assigned to the application'.
EOF
    exit 0   # never fail azd on a permission boundary
  fi
  echo "Graph appRole assignment failed (exit $RC): $OUT" >&2
  exit 1
fi

echo "Granted '$PERMISSION_NAME' to the register managed identity."
echo -e "\nDone. Register-app Graph grant is in place."
