#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
command -v pwsh >/dev/null 2>&1 || { printf '%s\n' 'PowerShell 7.4+ is required for private client-access validation.' >&2; exit 1; }
exec pwsh -NoProfile -NonInteractive -File "$script_dir/preview-private-client-access.ps1" "$@"