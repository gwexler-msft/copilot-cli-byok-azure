#!/usr/bin/env bash
# Pre-provision guard that stops a provision from WIPING populated pilot values when CI-only
# environment variables are absent. See check-provision-params.ps1 for full docs. Wired as an azd
# `preprovision` hook AFTER ensure-byok-groups.
#
#   OPTION 2 (HARD): deployFoundryCommercial=true but COMMERCIAL_* resolve empty/placeholder -> abort
#                    (a local provision would reset the foundry-commercial-* named values -> 502).
#   OPTION 3 (WARN): list every ${VAR} param that resolves EMPTY (louder on *-pilot envs). Non-fatal:
#                    some empties are intentional (register Easy Auth two-phase; route off for the env).
#   SKIP_PROVISION_PARAM_CHECK=true -> bypass. Secret VALUES are never printed (only names).
set -euo pipefail

if [[ "${SKIP_PROVISION_PARAM_CHECK:-}" == "true" ]]; then
  echo "[provision-params] SKIP_PROVISION_PARAM_CHECK=true - skipping guard."
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# azd always provisions from infra/main.parameters.json (workflows stage the per-env file into it
# before `azd provision`). Read that staged file so the guard reflects what will actually deploy.
PARAM_FILE="$SCRIPT_DIR/../infra/main.parameters.json"
if [[ ! -f "$PARAM_FILE" ]]; then
  echo "[provision-params] $PARAM_FILE not found - skipping guard."
  exit 0
fi

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

ENV_NAME="${AZURE_ENV_NAME:-$(resolve_param envName)}"
ENV_LABEL="${ENV_NAME:-main.parameters.json}"
IS_PILOT=0; [[ "$ENV_NAME" == *-pilot ]] && IS_PILOT=1

# ---- OPTION 2: Commercial Foundry route HARD gate ----
DEPLOY_COMM="$(resolve_param deployFoundryCommercial)"
if [[ "$DEPLOY_COMM" == "true" ]]; then
  BASE="$(resolve_param foundryCommercialBaseUrl)"
  TENANT="$(resolve_param foundryCommercialTenantId)"
  CLIENT="$(resolve_param foundryCommercialClientId)"
  AUTHMODE="$(resolve_param foundryCommercialAuthMode)"
  SECRET="$(resolve_param foundryCommercialClientSecret)"

  BAD=()
  { [[ -z "$BASE" ]]   || [[ "$BASE" == "https://unset.invalid" ]]; } && BAD+=("foundryCommercialBaseUrl (COMMERCIAL_FOUNDRY_BASE_URL)")
  { [[ -z "$TENANT" ]] || [[ "$TENANT" == "organizations" ]]; }       && BAD+=("foundryCommercialTenantId (COMMERCIAL_TENANT_ID)")
  { [[ -z "$CLIENT" ]] || [[ "$CLIENT" == "unset" ]]; }               && BAD+=("foundryCommercialClientId (COMMERCIAL_CLIENT_ID)")
  if [[ "$AUTHMODE" == "servicePrincipal" && -z "$SECRET" ]]; then BAD+=("foundryCommercialClientSecret (COMMERCIAL_FOUNDRY_CLIENT_SECRET)"); fi

  if [[ ${#BAD[@]} -gt 0 ]]; then
    echo "" >&2
    echo "COMMERCIAL BACKEND CHECK FAILED ($ENV_LABEL)." >&2
    echo "  deployFoundryCommercial=true, but these resolve to empty/placeholder:" >&2
    for b in "${BAD[@]}"; do echo "    - $b" >&2; done
    cat >&2 <<'EOF'

Provisioning now would OVERWRITE the live foundry-commercial-* APIM named values with placeholders
(base-url=https://unset.invalid, auth-mode=servicePrincipalFederated, ...), breaking every
commercial-model request (502). Classic "local azd provision without the COMMERCIAL_* env vars" wipe.
Fix ONE of:
  1. Provision via CI (deploy.yml) - it exports COMMERCIAL_* from the env's GitHub settings.
  2. Or export COMMERCIAL_FOUNDRY_BASE_URL, COMMERCIAL_TENANT_ID, COMMERCIAL_CLIENT_ID
     (+ COMMERCIAL_FOUNDRY_CLIENT_SECRET for servicePrincipal) before provisioning.
  3. Or turn the backend off for this provision: deployFoundryCommercial=false.
  4. Or intentional? Re-run with SKIP_PROVISION_PARAM_CHECK=true.
EOF
    exit 1
  fi
  echo "[provision-params] Commercial route enabled and all COMMERCIAL_* values resolved. OK."
fi

# ---- OPTION 3: general empty-${VAR} substitution scan (advisory; louder on pilots) ----
EMPTY_SUBS=()
while IFS=$'\t' read -r name raw; do
  [[ -n "$name" ]] || continue
  var="${raw#\$\{}"; var="${var%\}}"
  if [[ -z "${!var:-}" ]]; then EMPTY_SUBS+=("$name (\${$var})"); fi
done < <(jq -r '.parameters | to_entries[] | select(.value.value | type=="string" and test("^\\$\\{.+\\}$")) | "\(.key)\t\(.value.value)"' "$PARAM_FILE")

if [[ ${#EMPTY_SUBS[@]} -gt 0 ]]; then
  echo ""
  echo "[provision-params] NOTE ($ENV_LABEL): ${#EMPTY_SUBS[@]} parameter(s) reference an env var that is EMPTY and will deploy blank:"
  for e in "${EMPTY_SUBS[@]}"; do echo "    - $e"; done
  if [[ $IS_PILOT -eq 1 ]]; then
    echo ""
    echo "  This is a PILOT env. If any of the above are currently populated LIVE, this provision will WIPE them."
    echo "  That is exactly what a LOCAL 'azd provision' missing the CI env vars does. Strongly prefer CI, or export"
    echo "  the values first. (Intentional cases like the register Easy Auth two-phase bring-up are expected.)"
  fi
fi

exit 0
