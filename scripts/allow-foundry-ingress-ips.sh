#!/usr/bin/env bash
# Allowlist gov gateway NAT egress IP(s) on THIS deployment's Foundry account firewall (enable
# public network access with defaultAction=Deny + ipRules). No-op unless FOUNDRY_PUBLIC_INGRESS_IPS
# is set. Idempotent. Cloud-agnostic. Wired as an azd `postprovision` hook.
# See allow-foundry-ingress-ips.ps1 / docs/commercial-foundry-route.md for full docs.
#
# Runs on the COMMERCIAL deployment (comm-pilot) so the Foundry owner manages its own ingress
# allowlist from one environment Variable (the Gov deployment can't touch a resource in another
# tenant/cloud). foundry.bicep pins publicNetworkAccess=Disabled + ipRules=[]; this hook runs AFTER
# provision and overrides to Enabled + the listed IPs (private-endpoint path is unchanged; PE
# bypasses networkAcls). Bicep clears ipRules each provision and this re-adds the current list, so
# removed IPs converge out. Empty var -> no-op, so Gov / other envs are untouched.
set -euo pipefail

FOUNDRY_INGRESS_IPS="${1:-${FOUNDRY_PUBLIC_INGRESS_IPS:-}}"
RESOURCE_GROUP="${2:-${resourceGroup:-}}"
FOUNDRY_ACCOUNT="${3:-${foundryAccountName:-}}"

if [[ -z "${FOUNDRY_INGRESS_IPS// /}" ]]; then
  echo "FOUNDRY_PUBLIC_INGRESS_IPS is empty — no Foundry ingress allowlist to apply (skipping)."
  exit 0
fi
if [[ -z "$FOUNDRY_ACCOUNT" ]]; then
  echo "foundryAccountName not available (Foundry not deployed?) — skipping ingress allowlist."
  exit 0
fi
[[ -n "$RESOURCE_GROUP" ]] || { echo "ResourceGroup not provided and \$resourceGroup is empty." >&2; exit 1; }

az version >/dev/null 2>&1 || { echo "Install Azure CLI first." >&2; exit 1; }
CTX="$(az account show -o json 2>/dev/null)" || { echo "Not logged in. Run 'az login' (matching the deployment cloud) first." >&2; exit 1; }
echo "Cloud:   $(echo "$CTX" | jq -r .environmentName)"
echo "Foundry: $FOUNDRY_ACCOUNT (rg $RESOURCE_GROUP)"

ID="$(az cognitiveservices account show -g "$RESOURCE_GROUP" -n "$FOUNDRY_ACCOUNT" --query id -o tsv)"
[[ -n "$ID" ]] || { echo "Could not resolve Foundry account '$FOUNDRY_ACCOUNT' in '$RESOURCE_GROUP'." >&2; exit 1; }

echo "WARNING: allowlisting public ingress IP(s) on '$FOUNDRY_ACCOUNT' and enabling public network access (defaultAction stays Deny)." >&2
# Split on commas/whitespace and build the networkAcls.ipRules array.
read -r -a IPS <<< "$(echo "$FOUNDRY_INGRESS_IPS" | tr ',' ' ')"
ip_rules=''
allowed=()
for ip in "${IPS[@]}"; do
  [[ -n "$ip" ]] || continue
  ip_rules+="{\"value\":\"$ip\"},"
  allowed+=("$ip")
done
if [[ ${#allowed[@]} -eq 0 ]]; then
  echo "No valid ingress IPs parsed from '$FOUNDRY_INGRESS_IPS' - nothing to allowlist (skipping)."
  exit 0
fi
ip_rules="[${ip_rules%,}]"
# Apply PNA + defaultAction=Deny + the full ipRules list in ONE call, addressing the account by its
# resource id (--ids). This deliberately avoids `az cognitiveservices account network-rule add`,
# which does not accept --ids and refused the -g/-n it was given inside the azd hook environment.
# `az resource update --ids` is the same call the PNA line used and is known-good here. Idempotent:
# Bicep resets ipRules=[] each provision and this re-sets exactly the current list, so removed
# IPs converge out. Non-fatal: a firewall convenience must never abort the whole provision.
if ! az resource update --ids "$ID" \
      --set properties.publicNetworkAccess=Enabled \
            properties.networkAcls.defaultAction=Deny \
            "properties.networkAcls.ipRules=$ip_rules" -o none; then
  echo "WARNING: failed to update Foundry firewall on '$FOUNDRY_ACCOUNT'; leaving provision green. Re-run this hook or set the ipRules manually." >&2
  exit 0
fi
printf '  allowed %s\n' "${allowed[@]}"
echo "Foundry firewall now: $(az cognitiveservices account show --ids "$ID" --query '{pna:properties.publicNetworkAccess, defaultAction:properties.networkAcls.defaultAction, ipRules:properties.networkAcls.ipRules[].value}' -o json)"
