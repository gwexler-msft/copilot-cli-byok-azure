#!/usr/bin/env bash
# Create/refresh the Entra app registration that fronts the self-serve "register" app with
# Easy Auth, store its client secret in Key Vault, and publish the client id + secret URI for
# a follow-up `azd provision`. Idempotent. Cloud-aware (AzureCloud + AzureUSGovernment).
# Degrades gracefully (prints the manual command, exits 0) when the caller lacks directory
# write rights — never fails the deployment. See setup-register-entra.ps1 for full docs.
#
# Two-phase register-app bring-up (issue #64 / #68):
#   phase 1:  azd provision (deployRegisterApp=true, auth params empty)  -> hosting + KV + UAMI
#   deploy:   azd deploy register                                        -> real Blazor image
#   phase 2:  THIS SCRIPT                                                 -> app reg + secret->KV
#             azd provision (auth params now populated)                  -> Easy Auth attached
set -euo pipefail

# azd stores bicep outputs UPPER_SNAKE-cased; keep the camelCase name as a secondary fallback.
APP_FQDN="${1:-${REGISTER_APP_FQDN:-${registerAppFqdn:-}}}"
KEYVAULT_NAME="${2:-${REGISTER_KEY_VAULT_NAME:-${registerKeyVaultName:-}}}"
ENV_NAME="${3:-${AZURE_ENV_NAME:-}}"
SECRET_NAME="${SECRET_NAME:-register-easyauth-secret}"
ROTATE="${ROTATE:-}"

set_output_var() {
  local name="$1" value="$2"
  if command -v azd >/dev/null 2>&1; then azd env set "$name" "$value" 2>/dev/null || true; fi
  if [[ -n "${GITHUB_ENV:-}" ]]; then echo "$name=$value" >> "$GITHUB_ENV"; fi
  echo "  $name=$value"
}

az version >/dev/null 2>&1 || { echo "Install Azure CLI first." >&2; exit 1; }
CTX="$(az account show -o json 2>/dev/null)" || { echo "Not logged in. Run 'az login' (matching the deployment cloud) first." >&2; exit 1; }
echo "Cloud:   $(echo "$CTX" | jq -r .environmentName)"
echo "Account: $(echo "$CTX" | jq -r .user.name)"

if [[ -z "$APP_FQDN" ]]; then
  echo "Register app not deployed (registerAppFqdn is empty) — skipping Easy Auth setup."
  exit 0
fi
if [[ -z "$KEYVAULT_NAME" ]]; then
  echo "No register Key Vault name supplied (registerKeyVaultName is empty) — skipping Easy Auth setup."
  exit 0
fi
[[ -n "$ENV_NAME" ]] || ENV_NAME='register'

TENANT_ID="$(echo "$CTX" | jq -r .tenantId)"
DISPLAY_NAME="copilot-byok-register-$ENV_NAME"
REDIRECT_URI="https://$APP_FQDN/.auth/login/aad/callback"
GRAPH="$(az cloud show --query 'endpoints.microsoftGraphResourceId' -o tsv)"; GRAPH="${GRAPH%/}"
CALLER_USER="$(echo "$CTX" | jq -r .user.name)"

echo "App reg: $DISPLAY_NAME"
echo -e "Redirect: $REDIRECT_URI\n"

is_denied() {
  case "$1" in
    *Authorization_RequestDenied*|*"Insufficient privileges"*|*Forbidden*|*403*) return 0 ;;
    *) return 1 ;;
  esac
}

manual_fallback() {
  cat >&2 <<EOF
WARNING: Could not complete Easy Auth app-registration setup — $1

This is EXPECTED when the deploy principal lacks Entra app-management rights
(Application.ReadWrite.OwnedBy). The deployment itself is fine; the register app stays
reachable WITHOUT auth until an admin wires Easy Auth. Have an admin run, in THIS cloud:

  az login    # correct cloud (Commercial or Gov)
  ./scripts/setup-register-entra.sh "$APP_FQDN" "$KEYVAULT_NAME" "$ENV_NAME"

Then re-run 'azd provision' to attach the login flow.
EOF
}

# 1. Create or reuse the app registration.
APP_ID="$(az ad app list --display-name "$DISPLAY_NAME" --query '[0].appId' -o tsv 2>/dev/null || true)"
if [[ -n "$APP_ID" ]]; then
  echo "Reusing existing app registration appId=$APP_ID."
else
  echo "Creating app registration '$DISPLAY_NAME'..."
  if ! APP_ID="$(az ad app create --display-name "$DISPLAY_NAME" --sign-in-audience AzureADMyOrg --query appId -o tsv 2>&1)"; then
    if is_denied "$APP_ID"; then manual_fallback "directory write denied."; exit 0; fi
    echo "$APP_ID" >&2; exit 1
  fi
fi

OBJECT_ID="$(az ad app show --id "$APP_ID" --query id -o tsv)"

# 2. Redirect URI + v2 tokens + identifier + SecurityGroup claim.
echo "Configuring redirect URI, v2 tokens, and SecurityGroup claim..."
PATCH_FILE="$(mktemp)"
cat > "$PATCH_FILE" <<EOF
{
  "web": { "redirectUris": ["$REDIRECT_URI"], "implicitGrantSettings": { "enableIdTokenIssuance": true } },
  "identifierUris": ["api://$APP_ID"],
  "groupMembershipClaims": "SecurityGroup",
  "api": { "requestedAccessTokenVersion": 2 }
}
EOF
if ! PATCH_OUT="$(az rest --method PATCH --uri "$GRAPH/v1.0/applications/$OBJECT_ID" --resource "$GRAPH" --headers 'Content-Type=application/json' --body "@$PATCH_FILE" 2>&1)"; then
  rm -f "$PATCH_FILE"
  if is_denied "$PATCH_OUT"; then manual_fallback "directory write denied."; exit 0; fi
  echo "Graph PATCH failed: $PATCH_OUT" >&2; exit 1
fi
rm -f "$PATCH_FILE"

# Ensure a service principal exists for the app (Easy Auth needs it in the tenant).
if [[ -z "$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || true)" ]]; then
  az ad sp create --id "$APP_ID" >/dev/null 2>&1 || true
fi

# 3. Client secret -> Key Vault. Only mint when absent (or ROTATE=1), to keep re-provisions stable.
VAULT_URI="$(az keyvault show --name "$KEYVAULT_NAME" --query 'properties.vaultUri' -o tsv 2>/dev/null || true)"
[[ -n "$VAULT_URI" ]] || { manual_fallback "Key Vault '$KEYVAULT_NAME' not found."; exit 0; }
SECRET_URI="${VAULT_URI}secrets/$SECRET_NAME"

HAVE_SECRET="$(az keyvault secret show --vault-name "$KEYVAULT_NAME" --name "$SECRET_NAME" --query id -o tsv 2>/dev/null || true)"
if [[ -n "$HAVE_SECRET" && -z "$ROTATE" ]]; then
  echo "Key Vault already holds '$SECRET_NAME' — reusing (set ROTATE=1 to force a new secret)."
else
  echo "Minting a client secret..."
  if ! SECRET_VALUE="$(az ad app credential reset --id "$APP_ID" --display-name 'byok-easyauth' --years 1 --query password -o tsv 2>&1)"; then
    if is_denied "$SECRET_VALUE"; then manual_fallback "cannot mint a client secret."; exit 0; fi
    echo "Credential reset failed: $SECRET_VALUE" >&2; exit 1
  fi

  if ! az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "$SECRET_NAME" --value "$SECRET_VALUE" -o none 2>/tmp/kvset.err; then
    if grep -qiE 'Forbidden|secrets set permission|AuthorizationFailed|403' /tmp/kvset.err; then
      echo "No Key Vault write yet — self-granting Key Vault Secrets Officer and retrying..."
      CALLER_OID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
      [[ -n "$CALLER_OID" ]] || CALLER_OID="$(az ad sp show --id "$CALLER_USER" --query id -o tsv 2>/dev/null || true)"
      KV_ID="$(az keyvault show --name "$KEYVAULT_NAME" --query id -o tsv)"
      if [[ -n "$CALLER_OID" ]]; then
        az role assignment create --assignee-object-id "$CALLER_OID" --assignee-principal-type ServicePrincipal \
          --role 'Key Vault Secrets Officer' --scope "$KV_ID" >/dev/null 2>&1 || true
      fi
      OK=
      for i in 1 2 3 4 5 6; do
        sleep 10
        if az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "$SECRET_NAME" --value "$SECRET_VALUE" -o none 2>/dev/null; then OK=1; break; fi
        echo "  retry $i/6 — role propagation pending..."
      done
      [[ -n "$OK" ]] || { manual_fallback "Key Vault write denied (role not propagated)."; exit 0; }
    else
      echo "Key Vault secret set failed: $(cat /tmp/kvset.err)" >&2; exit 1
    fi
  fi
  echo "Stored Easy Auth client secret in Key Vault as '$SECRET_NAME'."
fi

# 4. Publish for the follow-up provision.
echo -e "\nPublishing Easy Auth values for the follow-up provision:"
set_output_var 'REGISTER_EASYAUTH_CLIENT_ID'     "$APP_ID"
set_output_var 'REGISTER_EASYAUTH_SECRET_KV_URI' "$SECRET_URI"

echo -e "\nDone. Re-run 'azd provision' to attach Easy Auth to the register app."
