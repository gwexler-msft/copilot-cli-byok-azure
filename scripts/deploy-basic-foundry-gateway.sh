#!/usr/bin/env bash
# Deploy the BASIC Foundry gateway profile onto an existing APIM instance.
#
# Creates (idempotently) everything the BASIC profile needs, so nobody has to hand-type
# operations in the portal:
#
#   1. A backend pointing at the Foundry account, with the REQUIRED trailing /openai.
#   2. The API, imported from policies/wizard-foundry-basic-openapi.json, which creates
#      all four operations: /v1/responses, /v1/chat/completions,
#      /deployments/{deployment}/chat/completions and /v1/models.
#   3. subscriptionKeyParameterNames set to 'api-key'. APIM's DEFAULT is
#      'Ocp-Apim-Subscription-Key'; Copilot CLI (COPILOT_PROVIDER_TYPE=azure) can only
#      send 'api-key', so leaving the default gives an unfixable-looking 401.
#   4. The API-scope policy, with placeholders substituted.
#   5. The operation-scope policy on listModels only (it must NOT inherit the API policy,
#      which parses a request body a GET does not have).
#   6. Optionally, the 'Cognitive Services OpenAI User' role for the APIM managed identity.
#
# Safe to re-run: every step is a PUT of desired state.
#
# Usage:
#   ./scripts/deploy-basic-foundry-gateway.sh --resource-group rg-ai --apim-name apim-dev \
#       --foundry-account myfoundry [--grant-rbac] [--dry-run]
#
# Options:
#   --resource-group NAME          Resource group holding the APIM instance. (required)
#   --apim-name NAME               APIM service name. (required)
#   --foundry-account NAME         Foundry / AI Services account name. (required) Its real
#                                  endpoint is read from Azure, so the script never has to
#                                  guess between openai.azure.us, cognitiveservices.azure.us
#                                  and services.ai.
#   --foundry-resource-group NAME  Resource group of the Foundry account. Defaults to
#                                  --resource-group.
#   --api-id ID                    Default: copilot-byok-foundry-basic
#   --api-display-name NAME        Default: "Copilot BYOK -> Foundry (basic)"
#   --api-path PATH                API URL suffix. Default: openai. MUST be 'openai' for
#                                  Copilot CLI: the azure provider discards any path on the
#                                  base URL and always calls <origin>/openai/...
#   --backend-id ID                Default: foundry-backend
#   --spec-path PATH               Default: policies/wizard-foundry-basic-openapi.json
#   --api-policy-path PATH         Default: policies/wizard-foundry-policy-basic.xml
#   --models-policy-path PATH      Default: policies/wizard-foundry-policy-basic-models.xml
#   --models-operation-id ID       Default: listModels
#   --grant-rbac                   Also grant the APIM managed identity
#                                  'Cognitive Services OpenAI User' on the account.
#   --dry-run                      Print what would change and exit without writing.
#   -h, --help                     Show this help.
#
# Requires: az (logged in to the right cloud and subscription) and jq.
set -euo pipefail

RESOURCE_GROUP=""
APIM_NAME=""
FOUNDRY_ACCOUNT=""
FOUNDRY_RESOURCE_GROUP=""
API_ID="copilot-byok-foundry-basic"
API_DISPLAY_NAME="Copilot BYOK -> Foundry (basic)"
API_PATH="openai"
BACKEND_ID="foundry-backend"
SPEC_PATH="policies/wizard-foundry-basic-openapi.json"
API_POLICY_PATH="policies/wizard-foundry-policy-basic.xml"
MODELS_POLICY_PATH="policies/wizard-foundry-policy-basic-models.xml"
MODELS_OPERATION_ID="listModels"
GRANT_RBAC=0
DRY_RUN=0
API_VERSION="2024-05-01"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --resource-group)         RESOURCE_GROUP="$2"; shift 2 ;;
        --apim-name)              APIM_NAME="$2"; shift 2 ;;
        --foundry-account)        FOUNDRY_ACCOUNT="$2"; shift 2 ;;
        --foundry-resource-group) FOUNDRY_RESOURCE_GROUP="$2"; shift 2 ;;
        --api-id)                 API_ID="$2"; shift 2 ;;
        --api-display-name)       API_DISPLAY_NAME="$2"; shift 2 ;;
        --api-path)               API_PATH="$2"; shift 2 ;;
        --backend-id)             BACKEND_ID="$2"; shift 2 ;;
        --spec-path)              SPEC_PATH="$2"; shift 2 ;;
        --api-policy-path)        API_POLICY_PATH="$2"; shift 2 ;;
        --models-policy-path)     MODELS_POLICY_PATH="$2"; shift 2 ;;
        --models-operation-id)    MODELS_OPERATION_ID="$2"; shift 2 ;;
        --grant-rbac)             GRANT_RBAC=1; shift ;;
        --dry-run)                DRY_RUN=1; shift ;;
        -h|--help)                usage 0 ;;
        *) echo "ERROR: unknown argument '$1'" >&2; usage 2 ;;
    esac
done

[[ -n "$RESOURCE_GROUP"  ]] || { echo "ERROR: --resource-group is required." >&2; exit 2; }
[[ -n "$APIM_NAME"       ]] || { echo "ERROR: --apim-name is required." >&2; exit 2; }
[[ -n "$FOUNDRY_ACCOUNT" ]] || { echo "ERROR: --foundry-account is required." >&2; exit 2; }
[[ -n "$FOUNDRY_RESOURCE_GROUP" ]] || FOUNDRY_RESOURCE_GROUP="$RESOURCE_GROUP"

command -v az >/dev/null 2>&1 || { echo "ERROR: az is required." >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 2; }

step() { printf '==> %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '!!  %s\n' "$1" >&2; }

arm_call() {
    local method="$1" url="$2" body_file="${3:-}"
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY RUN would ${method} ${url%%\?*}"
        return 0
    fi
    if [[ -n "$body_file" ]]; then
        az rest --method "$method" --url "$url" \
            --headers "Content-Type=application/json" --body "@$body_file" -o none
    else
        az rest --method "$method" --url "$url" -o none
    fi
}

# --- context -----------------------------------------------------------------
step 'Resolving Azure context'
SUB="$(az account show --query id -o tsv)"
[[ -n "$SUB" ]] || { echo "ERROR: not logged in. Run az login (in the correct cloud) first." >&2; exit 1; }
CLOUD="$(az cloud show --query name -o tsv)"
ARM="$(az cloud show --query endpoints.resourceManager -o tsv)"
ARM="${ARM%/}"
info "cloud=$CLOUD  subscription=$SUB"

# Audience follows the CLOUD, not the model or api-version.
case "$CLOUD" in
    AzureUSGovernment) MI_AUDIENCE="https://cognitiveservices.azure.us" ;;
    AzureCloud)        MI_AUDIENCE="https://cognitiveservices.azure.com" ;;
    *) echo "ERROR: unsupported cloud '$CLOUD'. Add its Cognitive Services audience above." >&2; exit 1 ;;
esac
info "managed-identity audience = $MI_AUDIENCE"

# --- backend -----------------------------------------------------------------
step "Resolving Foundry endpoint for '$FOUNDRY_ACCOUNT'"
ENDPOINT="$(az cognitiveservices account show -n "$FOUNDRY_ACCOUNT" -g "$FOUNDRY_RESOURCE_GROUP" \
    --query properties.endpoint -o tsv)"
[[ -n "$ENDPOINT" ]] || { echo "ERROR: could not read the endpoint for '$FOUNDRY_ACCOUNT' in '$FOUNDRY_RESOURCE_GROUP'." >&2; exit 1; }
# The BASIC policies do no path rewriting for inference, so /openai has to live on the backend.
BACKEND_URL="${ENDPOINT%/}/openai"
info "backend url = $BACKEND_URL"

TMPDIR_SELF="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SELF"' EXIT

step "Upserting backend '$BACKEND_ID'"
jq -n --arg url "$BACKEND_URL" \
    '{properties:{url:$url,protocol:"http",description:"Foundry account (BASIC profile)"}}' \
    > "$TMPDIR_SELF/backend.json"
arm_call put \
    "$ARM/subscriptions/$SUB/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ApiManagement/service/$APIM_NAME/backends/$BACKEND_ID?api-version=$API_VERSION" \
    "$TMPDIR_SELF/backend.json"

# --- api + operations --------------------------------------------------------
step "Importing API '$API_ID' (path '$API_PATH') from $SPEC_PATH"
[[ -f "$SPEC_PATH" ]] || { echo "ERROR: spec not found: $SPEC_PATH" >&2; exit 1; }
if [[ $DRY_RUN -eq 1 ]]; then
    info 'DRY RUN would import the OpenAPI spec (4 operations)'
else
    az apim api import --resource-group "$RESOURCE_GROUP" --service-name "$APIM_NAME" \
        --api-id "$API_ID" --path "$API_PATH" \
        --specification-format OpenApi --specification-path "$SPEC_PATH" \
        --display-name "$API_DISPLAY_NAME" --protocols https --subscription-required true -o none
fi

# APIM defaults this to 'Ocp-Apim-Subscription-Key'. Copilot CLI can only send 'api-key'.
step "Forcing subscription key header/query to 'api-key'"
jq -n --arg name "$API_DISPLAY_NAME" --arg path "$API_PATH" --arg url "$BACKEND_URL" \
    '{properties:{displayName:$name,path:$path,protocols:["https"],subscriptionRequired:true,
      subscriptionKeyParameterNames:{header:"api-key",query:"api-key"},serviceUrl:$url}}' \
    > "$TMPDIR_SELF/api.json"
arm_call patch \
    "$ARM/subscriptions/$SUB/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ApiManagement/service/$APIM_NAME/apis/$API_ID?api-version=$API_VERSION" \
    "$TMPDIR_SELF/api.json"

# --- policies ----------------------------------------------------------------
set_policy() {
    local path="$1" url="$2" label="$3"
    [[ -f "$path" ]] || { echo "ERROR: policy not found: $path" >&2; exit 1; }
    local xml
    xml="$(cat "$path")"
    xml="${xml//REPLACE-WITH-YOUR-FOUNDRY-BACKEND-ID/$BACKEND_ID}"
    xml="${xml//REPLACE-WITH-YOUR-FOUNDRY-MI-AUDIENCE/$MI_AUDIENCE}"
    if [[ "$xml" == *REPLACE-WITH-* ]]; then
        echo "ERROR: $label still contains an unsubstituted placeholder; refusing to upload." >&2
        exit 1
    fi
    step "Applying $label"
    printf '%s' "$xml" > "$TMPDIR_SELF/policy.xml"
    jq -n --rawfile xml "$TMPDIR_SELF/policy.xml" \
        '{properties:{format:"rawxml",value:$xml}}' > "$TMPDIR_SELF/policy.json"
    arm_call put "$url" "$TMPDIR_SELF/policy.json"
}

set_policy "$API_POLICY_PATH" \
    "$ARM/subscriptions/$SUB/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ApiManagement/service/$APIM_NAME/apis/$API_ID/policies/policy?api-version=$API_VERSION" \
    'API-scope policy'

set_policy "$MODELS_POLICY_PATH" \
    "$ARM/subscriptions/$SUB/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ApiManagement/service/$APIM_NAME/apis/$API_ID/operations/$MODELS_OPERATION_ID/policies/policy?api-version=$API_VERSION" \
    "operation-scope policy on '$MODELS_OPERATION_ID'"

# --- rbac --------------------------------------------------------------------
if [[ $GRANT_RBAC -eq 1 ]]; then
    step 'Granting APIM managed identity Cognitive Services OpenAI User'
    PRINCIPAL="$(az apim show -n "$APIM_NAME" -g "$RESOURCE_GROUP" --query identity.principalId -o tsv)"
    if [[ -z "$PRINCIPAL" || "$PRINCIPAL" == "null" ]]; then
        warn 'APIM has no system-assigned managed identity. Enable one, then re-run with --grant-rbac.'
    else
        SCOPE="$(az cognitiveservices account show -n "$FOUNDRY_ACCOUNT" -g "$FOUNDRY_RESOURCE_GROUP" --query id -o tsv)"
        if [[ $DRY_RUN -eq 1 ]]; then
            info "DRY RUN would grant $PRINCIPAL -> Cognitive Services OpenAI User on the account"
        else
            az role assignment create --assignee-object-id "$PRINCIPAL" \
                --assignee-principal-type ServicePrincipal \
                --role 'Cognitive Services OpenAI User' --scope "$SCOPE" -o none 2>/dev/null || true
            info 'Granted (or already present). Allow a few minutes to propagate; it 401s until it does.'
        fi
    fi
fi

# --- summary -----------------------------------------------------------------
GATEWAY="$(az apim show -n "$APIM_NAME" -g "$RESOURCE_GROUP" --query gatewayUrl -o tsv)"
echo
step 'Done'
info "Gateway    : $GATEWAY"
info "Base URL   : $GATEWAY/$API_PATH"
info "Backend    : $BACKEND_URL"
echo
info 'Point a client at it with:'
info '  COPILOT_PROVIDER_TYPE=azure'
info "  COPILOT_PROVIDER_BASE_URL=$GATEWAY/$API_PATH"
info '  COPILOT_PROVIDER_API_KEY=<an APIM subscription key for this API>'
echo
info 'Smoke check (expects a JSON model list):'
info "  curl -i \"$GATEWAY/$API_PATH/v1/models\" -H \"api-key: <key>\""
