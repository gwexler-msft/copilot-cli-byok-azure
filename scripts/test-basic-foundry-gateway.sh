#!/usr/bin/env bash
# Quick probe of a BASIC-profile Foundry gateway, without Copilot CLI or VS Code.
#
#   ./scripts/test-basic-foundry-gateway.sh --base-url https://<apim-host>/openai
#
# Reads the key from a hidden prompt so it stays out of the terminal and shell history.
# Set BYOK_API_KEY in the environment to skip the prompt (useful in CI).
set -euo pipefail

BASE_URL=""
MODEL="gpt-5.6-sol"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-url) BASE_URL="$2"; shift 2 ;;
        --model)    MODEL="$2"; shift 2 ;;
        -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

[[ -n "$BASE_URL" ]] || { echo "ERROR: --base-url is required." >&2; exit 2; }
BASE_URL="${BASE_URL%/}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 2; }

KEY="${BYOK_API_KEY:-}"
if [[ -z "$KEY" ]]; then
    read -rsp 'APIM subscription key (hidden): ' KEY
    echo
fi

probe() {
    local name="$1" method="$2" url="$3" body="${4:-}"
    printf '\n== %s : %s %s\n' "$name" "$method" "$url"
    local out code
    out="$(mktemp)"
    if [[ -n "$body" ]]; then
        code="$(curl -sS -o "$out" -w '%{http_code}' -X "$method" "$url" \
            -H "api-key: $KEY" -H 'Content-Type: application/json' -d "$body" || echo 000)"
    else
        code="$(curl -sS -o "$out" -w '%{http_code}' -X "$method" "$url" -H "api-key: $KEY" || echo 000)"
    fi
    if [[ "$code" =~ ^2 ]]; then
        echo "PASS $code"
    else
        echo "FAIL $code"
        # The body says which layer failed: "Resource not found" = APIM has no such
        # operation; anything else = the backend answered.
        cat "$out"; echo
    fi
    rm -f "$out"
}

probe 'models'    GET  "$BASE_URL/v1/models"
probe 'responses' POST "$BASE_URL/v1/responses" \
    "$(jq -nc --arg m "$MODEL" '{model:$m,input:"say ok"}')"
probe 'chat'      POST "$BASE_URL/v1/chat/completions" \
    "$(jq -nc --arg m "$MODEL" '{model:$m,messages:[{role:"user",content:"say ok"}]}')"
