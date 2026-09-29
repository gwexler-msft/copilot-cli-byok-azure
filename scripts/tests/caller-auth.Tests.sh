#!/usr/bin/env bash
set -euo pipefail
if ! command -v pwsh >/dev/null 2>&1; then
  printf '%s\n' 'PowerShell 7 (pwsh) is required to execute the shared APIM policy expressions.' >&2
  exit 1
fi
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec pwsh -NoProfile -NonInteractive -File "$script_dir/caller-auth.Tests.ps1" "$@"