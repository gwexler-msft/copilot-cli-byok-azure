#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ $# -eq 1 && "$1" == '-Stage' ]]; then
	parameter_file="$script_dir/../infra/main.parameters.json"
	if [[ ! -f "$parameter_file" ]]; then
		printf '%s\n' '[register-role] No staged parameter file; no resolution performed.'
		exit 0
	fi
	if command -v jq >/dev/null 2>&1 && jq -e '
		type == "object" and (.parameters | type == "object") and
		((.parameters | has("deployRegisterApp") | not) or .parameters.deployRegisterApp.value == false)
	' "$parameter_file" >/dev/null 2>&1; then
		printf '%s\n' '[register-role] Registration is disabled; no resolution performed.'
		exit 0
	fi
fi
command -v pwsh >/dev/null 2>&1 || { printf '%s\n' 'PowerShell 7.4+ is required for register role resolution.' >&2; exit 1; }
exec pwsh -NoProfile -NonInteractive -File "$script_dir/resolve-register-role-assignment.ps1" "$@"