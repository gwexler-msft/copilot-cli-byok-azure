#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
command -v pwsh >/dev/null 2>&1 || { printf '%s\n' 'PowerShell 7.4+ is required for the shared caller-policy upgrade.' >&2; exit 1; }
exec pwsh -NoProfile -NonInteractive -File "$script_dir/update-caller-auth.ps1" "$@"