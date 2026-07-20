#!/usr/bin/env bash
# Apply the env's PULLER_KEYS to the program's ON-CHAIN config — a single
# data transaction signed by the admin (the UPGRADE_AUTHORITY wallet). No
# build, no deploy: the audited program code is untouched. Initializes the
# config automatically on first use.
#
# Rotation:    list old+new keys in the .env → run this → flip the backend's
#              Key Vault secret → remove the old key → run this again.
# Kill switch: set PULLER_KEYS="" → run this. Resume: restore keys → run.
#
# Usage: scripts/set-puller-keys.sh <local|dev|prod>
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_wallet.sh
source scripts/_env.sh

ENV="${1:?usage: scripts/set-puller-keys.sh <local|dev|prod>}"
[[ "$ENV" != "test" ]] || { echo "error: 'test' is the LiteSVM fixture — nothing on-chain to update" >&2; exit 1; }
ENV_FILE=$(env_file "$ENV")
PROGRAM_ID=$(env_program_id "$ENV")
UPGRADE_AUTHORITY=$(env_upgrade_authority "$ENV")
RPC_URL="https://api.mainnet-beta.solana.com"

grep -q '^PULLER_KEYS=' "$ENV_FILE" || {
  echo "error: PULLER_KEYS is not set in $ENV_FILE" >&2
  exit 1
}
KEYS=$(grep '^PULLER_KEYS=' "$ENV_FILE" | cut -d= -f2- | tr -d '"')

echo "environment : $ENV"
echo "program id  : $PROGRAM_ID"
if [[ -z "${KEYS// /}" ]]; then
  echo "puller keys : <EMPTY — ⚠️  KILL SWITCH: no key will be able to pull>"
else
  echo "puller keys : $KEYS"
fi
echo
prompt_wallet "$UPGRADE_AUTHORITY"
read -rp "Apply to the on-chain config on MAINNET? Type 'apply' to proceed: " CONFIRM
[[ "$CONFIRM" == "apply" ]] || { echo "aborted"; exit 1; }

# shellcheck disable=SC2086 — KEYS is intentionally word-split
cargo run -q -p admin-cli -- "$PROGRAM_ID" "$WALLET" "$RPC_URL" $KEYS
