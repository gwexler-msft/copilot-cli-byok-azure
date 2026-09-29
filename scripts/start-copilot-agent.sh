#!/usr/bin/env bash
set +x
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
command -v pwsh >/dev/null 2>&1 || { printf '%s\n' 'PowerShell 7.4+ is required by the shared CLI agent launcher.' >&2; exit 1; }
exec pwsh -NoLogo -NoProfile -NonInteractive -File "$script_dir/start-copilot-agent.ps1" "$@"