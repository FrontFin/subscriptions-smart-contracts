#!/usr/bin/env bash
# One-time migration of an env's TWO authorities to a Squads vault:
#   1. the program's upgrade authority  (solana program set-upgrade-authority)
#   2. the config admin                 (controller set_admin instruction)
# Signed by the CURRENT authority wallet (key pasted at the prompt — the last
# time it is ever needed). Afterwards: upgrades via scripts/stage-upgrade.sh,
# key changes via scripts/set-puller-keys.sh <env> --print — both approved in
# the Squads app.
#
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
echo "⚠️  ONE-WAY for this wallet: after this, only the Squad can upgrade the"
echo "   program or change puller keys. Triple-check the vault address."
read -rp "Type the LAST 4 characters of the vault address to confirm: " TAIL
[[ "$VAULT" == *"$TAIL" && -n "$TAIL" ]] || { echo "aborted (mismatch)"; exit 1; }

prompt_wallet "$CURRENT"

echo "1/2 upgrade authority → vault..."
solana program set-upgrade-authority "$PROGRAM_ID" \
  --keypair "$WALLET" \
  --new-upgrade-authority "$VAULT" \
  --skip-new-upgrade-authority-signer-check \
  --url "$URL"

echo "2/2 config admin → vault..."
cargo run -q -p admin-cli -- "$PROGRAM_ID" "$WALLET" "https://api.mainnet-beta.solana.com" admin "$VAULT"

echo
echo "Done. Update scripts/envs/$ENV.env:  UPGRADE_AUTHORITY=$VAULT"
echo "From now on: upgrades = scripts/stage-upgrade.sh $ENV (+ Squads approval);"
echo "puller keys = edit .env, scripts/set-puller-keys.sh $ENV --print (+ Squads)."
