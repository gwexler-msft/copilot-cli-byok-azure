#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
parameters_file=''
deploy=false
network_validated=false
validate_only=false
fail() { printf '%s\n' "$1" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --parameters-file) [[ $# -ge 2 ]] || fail 'Missing parameters file.'; parameters_file="$2"; shift 2 ;;
    --deploy) deploy=true; shift ;;
    --network-validated) network_validated=true; shift ;;
    --validate-only) validate_only=true; shift ;;
    *) fail 'Usage: deploy-containerapp.sh --parameters-file FILE [--validate-only | --deploy --network-validated]' ;;
  esac
done
[[ -f "$parameters_file" ]] || fail 'An existing --parameters-file is required.'
[[ "$deploy" != true || "$validate_only" != true ]] || fail 'Choose deploy or validate-only, not both.'
[[ "$deploy" != true || "$network_validated" == true ]] || fail 'Deployment requires --network-validated after the runbook network gate passes.'
command -v az >/dev/null || fail 'Azure CLI is required.'
command -v jq >/dev/null || fail 'jq is required.'
jq -e '.parameters | type == "object"' "$parameters_file" >/dev/null || fail 'Expected an ARM parameters object.'
jq -e '.parameters | has("foundryApiKey") | not' "$parameters_file" >/dev/null || fail 'Supply backend credentials through FOUNDRY_API_KEY, never the parameters file.'
value() { jq -r --arg name "$1" --arg fallback "${2:-}" 'if .parameters | has($name) then .parameters[$name].value else $fallback end' "$parameters_file"; }
read_azure() { az "$@" --only-show-errors -o json; }
for name in location proxyResourceGroup proxyImage environmentName environmentResourceGroup apimResourceGroup apimName apimPrivateIp apimGatewayHost; do
  jq -e --arg name "$name" '.parameters[$name].value | type == "string" and test("[^[:space:]]") and (test("[<>\r\n]") | not)' "$parameters_file" >/dev/null || fail "Set a non-placeholder string value for $name."
done
api_path="$(value intellijApiPath intellij)"
host_name="$(value apimGatewayHost)"
private_ip="$(value apimPrivateIp)"
[[ "$api_path" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || fail 'intellijApiPath must be a single safe path segment.'
[[ ${#host_name} -le 253 && "$host_name" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || fail 'apimGatewayHost must be a hostname without scheme, port, or path.'
[[ "$private_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail 'apimPrivateIp must be a canonical IPv4 address.'
IFS='.' read -r -a octets <<< "$private_ip"
for octet in "${octets[@]}"; do
  [[ "$octet" == 0 || "$octet" != 0* ]] || fail 'IPv4 octets must not have leading zeros.'
  (( 10#$octet <= 255 )) || fail 'Invalid IPv4 octet.'
done
jq -e 'if .parameters | has("configureApim") then .parameters.configureApim.value | type == "boolean" else true end' "$parameters_file" >/dev/null || fail 'configureApim must be a JSON boolean.'
configure_apim="$(value configureApim false)"
ingress_mode="$(value environmentIngressMode internal)"
[[ "$ingress_mode" == internal || "$ingress_mode" == privateEndpoint ]] || fail 'environmentIngressMode must be internal or privateEndpoint.'
jq -e 'if .parameters | has("configurePrivateDns") then .parameters.configurePrivateDns.value | type == "boolean" else true end' "$parameters_file" >/dev/null || fail 'configurePrivateDns must be a JSON boolean.'
read_azure account show >/dev/null
read_azure group show --name "$(value proxyResourceGroup)" >/dev/null
environment="$(read_azure resource show --resource-group "$(value environmentResourceGroup)" --name "$(value environmentName)" --resource-type Microsoft.App/managedEnvironments --api-version 2024-10-02-preview)"
if [[ "$ingress_mode" == internal ]]; then
  jq -e '.properties.vnetConfiguration.internal == true and (.properties.vnetConfiguration.infrastructureSubnetId | type == "string" and length > 0)' <<< "$environment" >/dev/null || fail 'Internal mode requires an existing INTERNAL VNet-integrated ACA environment.'
else
  jq -e '.properties.vnetConfiguration.internal == false and (.properties.vnetConfiguration.infrastructureSubnetId | type == "string" and length > 0) and .properties.publicNetworkAccess == "Disabled" and any(.properties.privateEndpointConnections[]?; .properties.privateLinkServiceConnectionState.status == "Approved" and .properties.provisioningState == "Succeeded")' <<< "$environment" >/dev/null || fail 'Private Endpoint mode requires an external VNet-integrated environment with public access Disabled and an approved, provisioned Private Endpoint.'
  [[ "$(value configurePrivateDns false)" == false ]] || fail 'Private Endpoint mode must reuse existing PE DNS with configurePrivateDns=false.'
fi
jq -e --arg location "$(value location)" '.properties.provisioningState == "Succeeded" and ((.location | ascii_downcase | gsub(" "; "")) == ($location | ascii_downcase | gsub(" "; "")))' <<< "$environment" >/dev/null || fail 'ACA environment must be ready and match location.'
apim="$(read_azure apim show --resource-group "$(value apimResourceGroup)" --name "$(value apimName)")"
jq -e --arg ip "$private_ip" '.virtualNetworkType == "Internal" and (.privateIpAddresses | index($ip) != null)' <<< "$apim" >/dev/null || fail 'This proof of concept requires Internal APIM and one of its current private VIPs.'
jq -e --arg host "$host_name" '([(.gatewayUrl | sub("^https://"; "") | rtrimstr("/"))] + [.hostnameConfigurations[]? | select(.type == "Proxy") | .hostName]) | map(ascii_downcase) | index($host | ascii_downcase) != null' <<< "$apim" >/dev/null || fail 'apimGatewayHost does not match an APIM gateway hostname.'
if [[ "$configure_apim" == true ]]; then
  for name in existingBackendName appInsightsName appInsightsResourceGroup; do
    jq -e --arg name "$name" '.parameters[$name].value | type == "string" and test("[^[:space:]]") and (test("[<>\r\n]") | not)' "$parameters_file" >/dev/null || fail "configureApim=true requires $name."
  done
  cloud="$(read_azure cloud show)"
  arm_base="$(jq -r '.endpoints.resourceManager | rtrimstr("/")' <<< "$cloud")"
  apim_id="$(jq -r '.id' <<< "$apim")"
  read_azure rest --method get --url "$arm_base$apim_id/backends/$(value existingBackendName)?api-version=2024-05-01" >/dev/null
  read_azure resource show --resource-group "$(value appInsightsResourceGroup)" --name "$(value appInsightsName)" --resource-type Microsoft.Insights/components --api-version 2020-02-02 >/dev/null
  while IFS= read -r product; do
    read_azure apim product show --resource-group "$(value apimResourceGroup)" --service-name "$(value apimName)" --product-id "$product" >/dev/null
  done < <(jq -r '([.parameters.existingProductName.value // ""] + (.parameters.additionalProductNames.value // [])) | unique[] | select(length > 0)' "$parameters_file")
else
  api="$(read_azure apim api show --resource-group "$(value apimResourceGroup)" --service-name "$(value apimName)" --api-id intellij-byok)"
  jq -e --arg path "$api_path" '.path == $path and .subscriptionRequired == true and .subscriptionKeyParameterNames.header == "api-key"' <<< "$api" >/dev/null || fail 'Existing intellij-byok API must match the path and require native api-key subscription authentication.'
fi
printf '%s\n' 'Control-plane preflight passed. Private DNS, routes, image pulls, TLS and SSE still require in-network validation.'
[[ "$validate_only" != true ]] || exit 0
operation=what-if
[[ "$deploy" != true ]] || operation=create
arguments=(deployment sub "$operation" --name intellij-containerapp --location "$(value location)" --template-file "$script_dir/containerapp.bicep" --parameters "@$parameters_file" --only-show-errors)
if [[ "$configure_apim" == true && -n "${FOUNDRY_API_KEY:-}" ]]; then
  arguments+=(--parameters "foundryApiKey=$FOUNDRY_API_KEY")
fi
if [[ "$deploy" == true ]]; then
  arguments+=(--query properties.outputs.clientBaseUrl.value -o tsv)
fi
az "${arguments[@]}"