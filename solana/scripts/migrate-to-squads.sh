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
RPC_URL="https://api.mainnet-beta.solana.com"

# Reject a mistyped address here: on_curve.py cannot classify one, and step 1
# below is irreversible.
require_pubkey "$VAULT" "vault address" || exit 1

# A Squads vault is a program address, so a wallet key here is certainly wrong
# and is the likely mistake: it would become the permanent upgrade authority
# while the rest of the tooling kept treating it as a vault.
#
# This rules out a wallet key and NOTHING MORE. A vault is derived from its
# multisig address and is System-owned, so with only the vault address there is
# nothing to derive and compare — any other program address passes here too,
# and one that no Squad controls would leave the program permanently
# unupgradeable. Retyping the address in full and opening it in the Squads app
# are the checks that catch that; they are not optional.
VAULT_KIND=$(key_kind "$VAULT" "vault address") || exit 1
if [[ "$VAULT_KIND" != "program" ]]; then
  echo "error: $VAULT is an ordinary wallet address, not a Squads vault." >&2
  echo "A vault is a program address and has no private key. Copy the vault" >&2
  echo "address from Squads, not a member's wallet address. Nothing was sent." >&2
  exit 1
fi

# Step 1 is irreversible and step 2 is signed by this same wallet as the config
# admin. If a previous handover already moved the admin elsewhere, step 2 would
# be rejected after step 1 had already given the program away.
ADMIN_OUT=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$CURRENT" "$RPC_URL" show 2>&1) || {
  echo "error: could not read the on-chain config, so the config admin is unknown." >&2
  echo "Nothing was sent. Retry when the RPC answers:" >&2
  echo "$ADMIN_OUT" >&2
  exit 1
}
LIVE_ADMIN=$(awk '$1=="admin"{print $3}' <<<"$ADMIN_OUT")
if [[ -z "$LIVE_ADMIN" ]]; then
  echo "error: $PROGRAM_ID has no config account, so there is no admin to hand" >&2
  echo "over. Initialize it first. Nothing was sent." >&2
  exit 1
fi
if [[ "$LIVE_ADMIN" != "$CURRENT" ]]; then
  echo "error: the live config admin is $LIVE_ADMIN, but this script signs as" >&2
  echo "$CURRENT. Step 2 would be rejected after step 1 had already moved the" >&2
  echo "upgrade authority for good. Nothing was sent." >&2
  echo "Run the propose from $LIVE_ADMIN, or fix UPGRADE_AUTHORITY in the env file." >&2
  exit 1
fi

echo "environment       : $ENV"
echo "program id        : $PROGRAM_ID"
echo "current authority : $CURRENT (its key is prompted below, one last time)"
echo "new authority     : $VAULT (Squads vault)"
echo
echo "⚠️  ONE-WAY for the UPGRADE AUTHORITY: after step 1 only the Squad can"
echo "   upgrade the program, and it cannot be undone from this wallet."
echo "   The CONFIG ADMIN does not move until the vault executes accept-admin"
echo "   (step 2 below) — until then this wallet still changes puller keys."
echo
echo "   This script has checked that $VAULT is a program address, not a"
echo "   wallet. It CANNOT check that a Squad controls it — that is not"
echo "   derivable from the address alone. If no Squad does, the program can"
echo "   never be upgraded or closed again. Open the address in the Squads app"
echo "   and confirm you can propose a transaction from it BEFORE continuing."
echo

if solana account "$VAULT" --url "$URL" >/dev/null 2>&1; then
  echo "vault account     : exists on $URL"
else
  echo "error: $VAULT does not exist on $URL." >&2
  echo "   A Squads vault is a System-owned PDA that appears once something funds" >&2
  echo "   it, so a fresh vault looks exactly like a typo — and a typo here makes" >&2
  echo "   the program permanently unupgradeable." >&2
  echo "   Send a small amount to the vault from the Squads app, then rerun. That" >&2
  echo "   proves the address is the one the Squad actually controls." >&2
  echo "   Nothing was sent." >&2
  exit 1
fi
echo

read -rp "Retype the FULL vault address to confirm: " TYPED
[[ "$TYPED" == "$VAULT" ]] || { echo "aborted (mismatch)"; exit 1; }

prompt_wallet "$CURRENT"

echo "1/2 upgrade authority → vault..."
# The vault cannot sign as a CLI keypair; this path relies on full-address confirmation.
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
