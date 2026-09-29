#!/usr/bin/env bash
set +x
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
command -v node >/dev/null 2>&1 || { printf '%s\n' 'Node.js 22+ is required for the Okta credential helper.' >&2; exit 1; }
node "$script_dir/okta/token.mjs" "$@"