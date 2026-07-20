#!/usr/bin/env bash
# Print an environment's smart contract address (program id) and its
# MeshDelegate PDA (derived by the backend from SmartContractAddress; the
# per-subscription delegatee). Pure derivation — works before any deploy.
#
# Usage: scripts/pda.sh [test|local|dev|prod]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_env.sh

envs=("${1:-test}")
[[ $# -eq 0 ]] && envs=(test local dev prod)

for env in "${envs[@]}"; do
  if program_id=$(env_program_id "$env" 2>/dev/null); then
    pda=$(python3 scripts/derive_pda.py "$program_id")
    printf '%-6s program id: %s\n       MeshDelegate: %s\n' "$env" "$program_id" "$pda"
  else
    printf '%-6s (no PROGRAM_ID yet — minted and pinned at first deploy)\n' "$env"
  fi
done
