#!/usr/bin/env bash
# Switch the active BYOK deployment environment (Gov vs Commercial) in one step.
# See select-env.ps1 for full docs.
#
# Keeps ONE persistent, gitignored params file per env
# (infra/main.parameters.<env>.json) so filled-in secrets survive cloud switches.
# The active file azd/az read (infra/main.parameters.json) is just a copy.
#
# Usage:
#   ./select-env.sh <env-name> [gov|commercial] [--set-cloud] [--force]
# Examples:
#   ./select-env.sh gov-pilot
#   ./select-env.sh comm-pilot commercial --set-cloud
set -euo pipefail

ENV_NAME="${1:-}"
[[ -n "$ENV_NAME" ]] || { echo "Usage: $0 <env-name> [gov|commercial] [--set-cloud] [--force]" >&2; exit 1; }
shift

PROFILE=""
SET_CLOUD=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    gov|commercial) PROFILE="$arg" ;;
    --set-cloud)    SET_CLOUD=1 ;;
    --force)        FORCE=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# scripts/ sits directly under the repo root.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$REPO_ROOT/infra"

# Infer profile from the env name when not given.
if [[ -z "$PROFILE" ]]; then
  case "$ENV_NAME" in
    gov-*)  PROFILE="gov" ;;
    comm-*) PROFILE="commercial" ;;
    *) echo "Cannot infer profile from env name '$ENV_NAME'. Pass gov|commercial." >&2; exit 1 ;;
  esac
fi

case "$PROFILE" in
  gov)        EXAMPLE="main.parameters.example.json";            CLOUD_NAME="AzureUSGovernment" ;;
  commercial) EXAMPLE="main.parameters.commercial.example.json"; CLOUD_NAME="AzureCloud" ;;
esac

EXAMPLE_FILE="$INFRA_DIR/$EXAMPLE"
PER_ENV_FILE="$INFRA_DIR/main.parameters.$ENV_NAME.json"
ACTIVE_FILE="$INFRA_DIR/main.parameters.json"

[[ -f "$EXAMPLE_FILE" ]] || { echo "Example profile not found: $EXAMPLE_FILE" >&2; exit 1; }

echo "Environment: $ENV_NAME"
echo "Profile:     $PROFILE ($CLOUD_NAME)"

# 1. Seed the per-env params file on first use.
if [[ ! -f "$PER_ENV_FILE" ]]; then
  if [[ -f "$ACTIVE_FILE" ]]; then
    # Adopt an already-filled active file (e.g. an existing single-env setup) so its
    # secrets are preserved as this env's persistent copy.
    cp "$ACTIVE_FILE" "$PER_ENV_FILE"
    echo
    echo "Seeded main.parameters.$ENV_NAME.json from your existing infra/main.parameters.json."
  else
    # No active file yet — seed from the example template, then stop for placeholders.
    cp "$EXAMPLE_FILE" "$PER_ENV_FILE"
    echo
    echo "Seeded main.parameters.$ENV_NAME.json from $EXAMPLE."
    echo "Fill in every <PLACEHOLDER> value in that file, then re-run this script."
    exit 2
  fi
fi

# Guard against shipping unfilled placeholders.
if grep -Eq '<[A-Z0-9_]+>' "$PER_ENV_FILE"; then
  echo
  echo "main.parameters.$ENV_NAME.json still contains <PLACEHOLDER> values."
  echo "Fill them in before provisioning."
fi

# 2. Copy the per-env file over the active file.
if [[ -f "$ACTIVE_FILE" && "$FORCE" -ne 1 ]]; then
  read -r -p "Overwrite active infra/main.parameters.json from main.parameters.$ENV_NAME.json? [Y/n] " ans
  if [[ -n "${ans:-}" && ! "$ans" =~ ^([yY]|[yY][eE][sS])$ ]]; then echo "Aborted by user." >&2; exit 1; fi
fi
cp "$PER_ENV_FILE" "$ACTIVE_FILE"
echo "Active params -> infra/main.parameters.json (copy of main.parameters.$ENV_NAME.json)"

# 3. Optionally point az + azd at the right cloud (azd cloud.name is global).
if [[ "$SET_CLOUD" -eq 1 ]]; then
  az cloud set --name "$CLOUD_NAME" >/dev/null
  azd config set cloud.name "$CLOUD_NAME" >/dev/null
  echo "Cloud set to $CLOUD_NAME (az + azd global). Run 'az login' if your session is for a different cloud."
fi

# 4. Select the azd environment, creating it if it does not exist.
if azd env list -o json 2>/dev/null | jq -e --arg n "$ENV_NAME" 'any(.[]; .Name == $n)' >/dev/null; then
  azd env select "$ENV_NAME"
  echo "Selected existing azd environment: $ENV_NAME"
else
  echo "azd environment '$ENV_NAME' not found — creating it (you'll be prompted for subscription + location)."
  azd env new "$ENV_NAME"
fi

echo
echo "Done. Active environment: $ENV_NAME -> resource group rg-copilot-byok-$ENV_NAME"
echo "Next: review infra/main.parameters.$ENV_NAME.json, then 'azd provision'."
