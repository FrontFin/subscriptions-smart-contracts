#!/usr/bin/env bash
# Transfer upgrade authority and propose config-admin handover; the vault must accept admin.
# Usage: scripts/migrate-to-squads.sh <local|dev|prod> <vault-address>
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_wallet.sh
source scripts/_env.sh

ENV="${1:?usage: scripts/migrate-to-squads.sh <local|dev|prod> <vault-address>}"
VAULT="${2:?usage: scripts/migrate-to-squads.sh <local|dev|prod> <vault-address>}"
[[ "$ENV" != "test" ]] || { echo "error: 'test' is the LiteSVM fixture" >&2; exit 1; }
PROGRAM_ID=$(env_program_id "$ENV")
CURRENT=$(env_upgrade_authority "$ENV")
URL="mainnet-beta"

echo "environment       : $ENV"
echo "program id        : $PROGRAM_ID"
echo "current authority : $CURRENT (its key is prompted below, one last time)"
echo "new authority     : $VAULT (Squads vault)"
echo
echo "⚠️  ONE-WAY for the UPGRADE AUTHORITY: after step 1 only the Squad can"
echo "   upgrade the program, and it cannot be undone from this wallet."
echo "   The CONFIG ADMIN does not move until the vault executes accept-admin"
echo "   (step 2 below) — until then this wallet still changes puller keys."
echo "   Triple-check the vault address."
read -rp "Type the LAST 4 characters of the vault address to confirm: " TAIL
[[ "$TAIL" == "${VAULT: -4}" ]] || { echo "aborted (mismatch)"; exit 1; }

prompt_wallet "$CURRENT"

echo "1/2 upgrade authority → vault..."
solana program set-upgrade-authority "$PROGRAM_ID" \
  --keypair "$WALLET" \
  --new-upgrade-authority "$VAULT" \
  --skip-new-upgrade-authority-signer-check \
  --url "$URL"

echo "2/2 propose config admin → vault (step 1 of the two-step handover)..."
cargo run -q -p admin-cli -- "$PROGRAM_ID" "$WALLET" "https://api.mainnet-beta.solana.com" propose-admin "$VAULT"

echo
echo "Done — EXCEPT the vault must ACCEPT the config admin (step 2). In Squads,"
echo "propose+execute this instruction (print it with):"
echo "  cargo run -p admin-cli -- $PROGRAM_ID print https://api.mainnet-beta.solana.com accept-admin"
echo "The upgrade authority moved immediately; the config admin moves only on accept."
echo
echo "Then update scripts/envs/$ENV.env:  UPGRADE_AUTHORITY=$VAULT"
echo "From now on: upgrades = scripts/stage-upgrade.sh $ENV (+ Squads approval);"
echo "puller keys = edit .env, scripts/set-puller-keys.sh $ENV --print (+ Squads)."
