#!/usr/bin/env bash
set -euo pipefail
if ! command -v pwsh >/dev/null 2>&1; then
  printf '%s\n' 'PowerShell 7 (pwsh) is required for the shared Windows-VM JWT probe harness.' >&2
  exit 1
fi
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec pwsh -NoProfile -File "$script_dir/probe-jwt-auth.ps1" "$@"