#!/usr/bin/env bash
# One-time migration of an env's TWO authorities to a Squads vault:
#   1. the program's upgrade authority  (solana program set-upgrade-authority)
#   2. the config admin                 (controller propose_admin, then the
#      vault executes accept_admin — the handover is two-step)
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
echo "⚠️  ONE-WAY for the UPGRADE AUTHORITY: after step 1 only the Squad can"
echo "   upgrade the program, and it cannot be undone from this wallet."
echo "   The CONFIG ADMIN does not move until the vault executes accept-admin"
echo "   (step 2 below) — until then this wallet still changes puller keys."
echo "   Triple-check the vault address."
echo

if solana account "$VAULT" --url "$URL" >/dev/null 2>&1; then
  echo "vault account     : exists on $URL"
else
  echo "⚠️  $VAULT does not exist on $URL yet."
  echo "   A Squads vault is a System-owned PDA and only appears once something"
  echo "   funds it, so this is normal for a fresh vault — but it is also what a"
  echo "   typo looks like. Open the address in the Squads app before continuing."
fi
echo

read -rp "Retype the FULL vault address to confirm: " TYPED
[[ "$TYPED" == "$VAULT" ]] || { echo "aborted (mismatch)"; exit 1; }

prompt_wallet "$CURRENT"

echo "1/2 upgrade authority → vault..."
# The skip flag is structural, not a shortcut: a Squads vault is a PDA with no
# private key, so it can never sign the transfer. The full-address retype above
# stands in for the signer check.
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
