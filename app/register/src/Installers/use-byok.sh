#!/usr/bin/env bash
# One-shot local installer for BYOK on VS Code + GitHub Copilot CLI (macOS/Linux). Rendered
# per-developer by the register app (APIM host + your personal subscription key inlined below).
#
# Merges three local surfaces in place, NEVER clobbering unrelated config (idempotent):
#   1. VS Code  chatLanguageModels.json  — adds/refreshes the "BYOK ..." provider blocks only.
#   2. VS Code  settings.json            — utility-model pair + telemetry/call-home lockdown.
#   3. Copilot CLI  COPILOT_PROVIDER_*    — exported in your shell profile (marker block).
#
# NEVER sets COPILOT_OFFLINE — that breaks BYOK. Privacy is enforced at the network layer.
#
# Opt-outs:  --skip-utility-models  --skip-privacy-lockdown  --skip-cli-env
# Targets:   stable VS Code by default; add --insiders to also target "Code - Insiders".
set -euo pipefail

# ---- Rendered per-developer by the register app -------------------------------------------
APIM_HOST='@@APIM_HOST@@'
APIM_KEY='@@APIM_KEY@@'
BASE_URL='@@BASE_URL@@'
MINI_MODEL_NAME='@@MINI_MODEL_NAME@@'
read -r -d '' CHAT_MODELS_JSON <<'OURS_JSON' || true
@@CHAT_MODELS_JSON@@
OURS_JSON
# -------------------------------------------------------------------------------------------

SKIP_UTILITY=''; SKIP_PRIVACY=''; SKIP_CLI=''; INSIDERS=''
for arg in "$@"; do
  case "$arg" in
    --skip-utility-models)  SKIP_UTILITY=1 ;;
    --skip-privacy-lockdown) SKIP_PRIVACY=1 ;;
    --skip-cli-env)         SKIP_CLI=1 ;;
    --insiders)             INSIDERS=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq / apt-get install jq)." >&2; exit 1; }

vscode_user_dirs() {
  local base variants=("Code") d
  [[ -n "$INSIDERS" ]] && variants+=("Code - Insiders")
  if [[ "$(uname -s)" == "Darwin" ]]; then base="$HOME/Library/Application Support"; else base="${XDG_CONFIG_HOME:-$HOME/.config}"; fi
  for v in "${variants[@]}"; do
    d="$base/$v/User"
    if [[ -d "$d" ]]; then echo "$d"; else echo "  (skip) $v not installed at $d" >&2; fi
  done
}

merge_chat_models() {
  local dir="$1" path="$dir/chatLanguageModels.json" merged
  if [[ -f "$path" ]]; then
    cp "$path" "$path.byok.bak"
    if existing="$(jq '.' "$path" 2>/dev/null)"; then
      merged="$(jq -n --argjson e "$existing" --argjson o "$CHAT_MODELS_JSON" \
        '((if ($e|type)=="array" then $e else [] end) | map(select((.name // "") | startswith("BYOK ") | not))) + $o')"
    else
      echo "  WARNING: $path is not valid JSON; backed up to $path.byok.bak and replacing." >&2
      merged="$CHAT_MODELS_JSON"
    fi
  else
    merged="$CHAT_MODELS_JSON"
  fi
  echo "$merged" > "$path"
  echo "  chatLanguageModels.json: wrote $(echo "$merged" | jq 'length') provider block(s) -> $path"
}

merge_settings() {
  local dir="$1" path="$dir/settings.json" desired current merged
  desired='{}'
  if [[ -z "$SKIP_UTILITY" ]]; then
    desired="$(echo "$desired" | jq --arg m "$MINI_MODEL_NAME" '. + {"chat.utilityModel":$m,"chat.utilitySmallModel":$m}')"
  fi
  if [[ -z "$SKIP_PRIVACY" ]]; then
    desired="$(echo "$desired" | jq '. + {
      "telemetry.telemetryLevel":"off","update.mode":"none","update.showReleaseNotes":false,
      "extensions.autoCheckUpdates":false,"extensions.autoUpdate":false,
      "workbench.enableExperiments":false,"workbench.settings.enableNaturalLanguageSearch":false,
      "npm.fetchOnlinePackageInfo":false,"json.schemaDownload.enable":false,
      "redhat.telemetry.enabled":false,"github.copilot.enable":{"*":false}}')"
  fi
  if [[ "$(echo "$desired" | jq 'length')" -eq 0 ]]; then echo '  settings.json: nothing to write (both groups skipped).'; return; fi

  if [[ -f "$path" ]]; then
    cp "$path" "$path.byok.bak"
    if current="$(jq '.' "$path" 2>/dev/null)"; then
      merged="$(jq -n --argjson c "$current" --argjson d "$desired" '$c + $d')"
    else
      echo "$desired" > "$dir/byok.settings-fragment.json"
      echo "  WARNING: settings.json has comments/trailing commas jq can't parse." >&2
      echo "  Wrote keys to merge by hand -> $dir/byok.settings-fragment.json (settings.json NOT modified)." >&2
      return
    fi
  else
    merged="$desired"
  fi
  echo "$merged" > "$path"
  echo "  settings.json: merged $(echo "$desired" | jq 'length') key(s) -> $path"
}

set_cli_env() {
  if [[ -n "$SKIP_CLI" ]]; then echo '  CLI env: skipped (--skip-cli-env).'; return; fi
  local profile
  if [[ -n "${ZSH_VERSION:-}" || "${SHELL:-}" == */zsh ]]; then profile="$HOME/.zshrc"
  elif [[ "${SHELL:-}" == */bash ]]; then profile="$HOME/.bashrc"
  else profile="$HOME/.profile"; fi
  touch "$profile"
  # Remove any prior BYOK marker block, then append a fresh one (idempotent replace).
  local tmp; tmp="$(mktemp)"
  awk 'BEGIN{skip=0} /^# >>> BYOK >>>$/{skip=1} skip==0{print} /^# <<< BYOK <<<$/{skip=0}' "$profile" > "$tmp"
  {
    cat "$tmp"
    echo '# >>> BYOK >>>'
    echo 'export COPILOT_PROVIDER_TYPE=azure'
    echo "export COPILOT_PROVIDER_BASE_URL='$BASE_URL'"
    echo "export COPILOT_PROVIDER_API_KEY='$APIM_KEY'"
    echo 'export COPILOT_PROVIDER_MAX_PROMPT_TOKENS=272000'
    echo 'export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=32768'
    echo '# <<< BYOK <<<'
  } > "$profile"
  rm -f "$tmp"
  echo "  CLI env: wrote COPILOT_PROVIDER_* block to $profile (open a NEW terminal to pick up)."
}

echo -e "BYOK local installer — APIM host: $APIM_HOST\n"

found=0
while IFS= read -r d; do
  [[ -d "$d" ]] || continue
  found=1
  echo "VS Code User dir: $d"
  merge_chat_models "$d"
  merge_settings "$d"
done < <(vscode_user_dirs)
[[ "$found" -eq 1 ]] || echo "WARNING: no VS Code User folder found. Install VS Code (or pass --insiders) then re-run." >&2

set_cli_env

cat <<EOF

Done. Next steps:
  1. Reload VS Code ('Developer: Reload Window') so the BYOK models register.
  2. Open a NEW terminal so the Copilot CLI env vars load, then run:  copilot "say hello"
  3. Pick a 'BYOK ...' model in the chat model picker.

Re-running this installer is safe: it preserves unrelated providers, settings, and environment.
EOF
