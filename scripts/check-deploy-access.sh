#!/usr/bin/env bash
# Pre-deployment access check for the BYOK gateway. See check-deploy-access.ps1 for full docs.
# Wired as an azd `preprovision` hook. Works in AzureCloud + AzureUSGovernment.
#   STRICT=1 -> treat the "missing role-assignment capability" warning as a hard failure.
set -euo pipefail

STRICT="${STRICT:-0}"

az version >/dev/null 2>&1 || { echo "Install Azure CLI first." >&2; exit 1; }
CTX="$(az account show -o json 2>/dev/null)" || { echo "Not logged in. Run 'az login' (matching the deployment cloud) first." >&2; exit 1; }
SUB_ID="$(echo "$CTX" | jq -r .id)"
USER_TYPE="$(echo "$CTX" | jq -r .user.type)"
echo "Cloud:        $(echo "$CTX" | jq -r .environmentName)"
echo "Subscription: $(echo "$CTX" | jq -r .name) ($SUB_ID)"
echo "Account:      $(echo "$CTX" | jq -r .user.name) [$USER_TYPE]"

# Resolve the signed-in principal's objectId (users); SP/MI fall back to the account name (appId).
ASSIGNEE=""
if [[ "$USER_TYPE" == "user" ]]; then
  ASSIGNEE="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
fi
[[ -n "$ASSIGNEE" ]] || ASSIGNEE="$(echo "$CTX" | jq -r .user.name)"

SCOPE="/subscriptions/$SUB_ID"
ROLES="$(az role assignment list --assignee "$ASSIGNEE" --scope "$SCOPE" --include-inherited \
  --query "[].roleDefinitionName" -o tsv 2>/dev/null || true)"

has_role() { echo "$ROLES" | grep -qx "$1"; }

CAN_CREATE=0; CAN_ASSIGN=0
if has_role "Owner" || has_role "Contributor"; then CAN_CREATE=1; fi
if has_role "Owner" || has_role "User Access Administrator" || has_role "Role Based Access Control Administrator"; then CAN_ASSIGN=1; fi

echo -e "\nEffective roles at subscription scope:"
if [[ -z "$ROLES" ]]; then
  echo "  (none found — you may have only resource-scoped or PIM-eligible roles not yet activated)"
else
  echo "$ROLES" | sort -u | sed 's/^/  - /'
fi

echo -e "\nCapabilities:"
echo "  Resource creation (Owner/Contributor):        $([[ $CAN_CREATE -eq 1 ]] && echo YES || echo NO)"
echo "  Role assignment write (Owner/UAA/RBAC Admin): $([[ $CAN_ASSIGN -eq 1 ]] && echo YES || echo NO)"

ASSIGN_RBAC="${assignAoaiRbac:-}"

if [[ $CAN_CREATE -ne 1 ]]; then
  echo "ACCESS CHECK FAILED: you need Owner or Contributor at subscription scope to provision resources. If you hold a PIM-eligible role, activate it and re-run." >&2
  exit 1
fi

if [[ $CAN_ASSIGN -ne 1 ]]; then
  cat >&2 <<'EOF'

WARNING: you do NOT appear to hold a role-assignment-capable role (Owner / User Access
Administrator / Role Based Access Control Administrator) at subscription scope.

The APIM managed identity must be granted 'Cognitive Services OpenAI User' on the AOAI and
Foundry accounts or data-plane calls will return 401 PermissionDenied. That grant is done
either in-template (assignAoaiRbac=true) or out-of-band via the postprovision
grant-apim-mi-rbac hook -- both require this capability. Obtain Owner/UAA, or have an
administrator run scripts/grant-apim-mi-rbac after deploy.
EOF
  if [[ "$STRICT" == "1" || "$ASSIGN_RBAC" == "true" ]]; then
    echo "ACCESS CHECK FAILED: assignAoaiRbac=$ASSIGN_RBAC requires role-assignment capability. Set assignAoaiRbac=false to defer RBAC, or obtain Owner/UAA." >&2
    exit 1
  fi
  echo -e "\nProceeding (assignAoaiRbac is not 'true'); remember to run scripts/grant-apim-mi-rbac after deployment."
  exit 0
fi

echo -e "\nACCESS CHECK PASSED: you can provision resources and grant the APIM MI role."
exit 0
