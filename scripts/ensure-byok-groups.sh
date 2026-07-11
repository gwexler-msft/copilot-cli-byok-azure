#!/usr/bin/env bash
# Ensure the two BYOK security groups (tier mapping for the self-serve register app)
# exist, creating them when missing and the caller has rights. Idempotent. See
# ensure-byok-groups.ps1 for full docs.
#
# Wired as an azd PREprovision hook (the group object-ids are consumed as Bicep params
# at provision time, so they must exist BEFORE `azd provision`). Works in AzureCloud +
# AzureUSGovernment. Degrades gracefully (exit 0) when the caller lacks group-creation
# rights — never fails the deployment. Resolved ids are published to the active azd env
# (registerAdminGroupId / registerPowerGroupId) for "${...}" param substitution.
#
# OPT-IN: only acts when MANAGE_BYOK_GROUPS is truthy (set per-env by the commercial CI
# jobs); otherwise prints a skip notice and exits 0 so gov / non-register envs are
# untouched.
set -euo pipefail

ADMIN_GROUP_NAME="${1:-BYOK Admins}"
POWER_GROUP_NAME="${2:-BYOK Power Users}"

case "${MANAGE_BYOK_GROUPS:-}" in
  1|true|True|yes|on) ;;
  *) echo "MANAGE_BYOK_GROUPS not set — skipping BYOK group bootstrap (set it to true to enable)."; exit 0 ;;
esac

az version >/dev/null 2>&1 || { echo "Install Azure CLI first." >&2; exit 1; }
CTX="$(az account show -o json 2>/dev/null)" || { echo "Not logged in. Run 'az login' (matching the deployment cloud) first." >&2; exit 1; }
echo "Cloud:   $(echo "$CTX" | jq -r .environmentName)"
echo -e "Account: $(echo "$CTX" | jq -r .user.name)\n"

# Resolve a group by display name, creating it when absent. Echoes the object id, or an
# empty string when it does not exist and the caller cannot create it (graceful — never
# fails on a permission boundary).
resolve_or_create_group() {
  local display_name="$1" id nick out rc

  id="$(az ad group list --display-name "$display_name" --query '[0].id' -o tsv 2>/dev/null || true)"
  if [[ -n "$id" ]]; then
    echo "Found '$display_name' -> $id" >&2
    echo "$id"; return 0
  fi

  # mailNickname must be mail-safe (no spaces); derive from the display name.
  nick="$(echo "$display_name" | tr -cd '[:alnum:]')"
  echo "Creating '$display_name' (mailNickname '$nick')..." >&2
  set +e
  out="$(az ad group create --display-name "$display_name" --mail-nickname "$nick" --query 'id' -o tsv 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 && -n "$out" ]]; then
    echo "Created '$display_name' -> $out" >&2
    echo "$out"; return 0
  fi

  if echo "$out" | grep -qiE 'already exist|exists with the same'; then
    id="$(az ad group list --display-name "$display_name" --query '[0].id' -o tsv 2>/dev/null || true)"
    if [[ -n "$id" ]]; then echo "Found '$display_name' (created concurrently) -> $id" >&2; echo "$id"; return 0; fi
  fi
  if echo "$out" | grep -qiE 'Authorization_RequestDenied|Insufficient privileges|Forbidden|\b403\b'; then
    cat >&2 <<EOF

WARNING: could not create '$display_name' — the signed-in account lacks group-creation rights.

This is EXPECTED when the azd deploy principal is not a tenant admin. Deployment continues
(tier mapping for this group is skipped until the group exists). Have a Groups Administrator
sign in to THIS cloud and run:

  az login                       # correct cloud (Commercial or Gov)
  ./scripts/ensure-byok-groups.sh
EOF
    echo ""; return 0
  fi
  echo "Failed to create group '$display_name' (exit $rc): $out" >&2
  exit 1
}

ADMIN_ID="$(resolve_or_create_group "$ADMIN_GROUP_NAME")"
POWER_ID="$(resolve_or_create_group "$POWER_GROUP_NAME")"

# Publish resolved ids to the active azd environment so param files that use
# "${registerAdminGroupId}" / "${registerPowerGroupId}" substitution pick them up. Only
# set when resolved — never blank a working literal param fallback.
if command -v azd >/dev/null 2>&1 && [[ -n "${AZURE_ENV_NAME:-}" ]]; then
  [[ -n "$ADMIN_ID" ]] && azd env set registerAdminGroupId "$ADMIN_ID" >/dev/null 2>&1 || true
  [[ -n "$POWER_ID" ]] && azd env set registerPowerGroupId "$POWER_ID" >/dev/null 2>&1 || true
  echo -e "\nPublished resolved group ids to azd env '${AZURE_ENV_NAME}'."
else
  echo -e "\nResolved group ids (azd env not detected — set params manually if needed):"
  echo "  registerAdminGroupId = $ADMIN_ID"
  echo "  registerPowerGroupId = $POWER_ID"
fi

echo -e "\nDone. BYOK group bootstrap complete."
