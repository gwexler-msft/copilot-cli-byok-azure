#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
command -v pwsh >/dev/null 2>&1 || { printf '%s\n' 'PowerShell 7.4+ is required to verify the private-access hold.' >&2; exit 2; }
exec pwsh -NoProfile -NonInteractive -File "$script_dir/check-private-client-access-hold.ps1" "$@"