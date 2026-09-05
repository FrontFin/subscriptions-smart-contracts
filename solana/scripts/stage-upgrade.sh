#!/usr/bin/env bash
# Stage a program upgrade for a Squads-held upgrade authority: builds the
# env, writes the new binary into an on-chain buffer, and hands the buffer to
# the vault (UPGRADE_AUTHORITY in the env's .env). The upgrade itself is then
# proposed and approved in the Squads app — no authority key ever touches
# this machine.
#
# The buffer is paid by a plain funded FEE PAYER keypair (working capital,
# not an authority): default ~/.config/solana/id.json, override with
# FEE_PAYER=<path>. Needs ~0.7 SOL free (buffer rent, recovered when the
# upgrade executes and the buffer is consumed).
#
# Usage: scripts/stage-upgrade.sh <local|dev|prod>
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_env.sh
source scripts/_buffers.sh

ENV="${1:?usage: scripts/stage-upgrade.sh <local|dev|prod>}"
[[ "$ENV" != "test" ]] || { echo "error: 'test' is the LiteSVM fixture — never deployable" >&2; exit 1; }
PROGRAM_ID=$(env_program_id "$ENV")
VAULT=$(env_upgrade_authority "$ENV")
URL="mainnet-beta"
FEE_PAYER="${FEE_PAYER:-$HOME/.config/solana/id.json}"
[[ -f "$FEE_PAYER" ]] || { echo "error: fee payer keypair $FEE_PAYER not found (set FEE_PAYER=<path>)" >&2; exit 1; }
FEE_PAYER_PUBKEY=$(solana-keygen pubkey "$FEE_PAYER")

# A buffer handed to anything but the program's real upgrade authority strands
# its rent and can never be executed, so read that authority off chain.
PROGRAM_INFO=$(solana program show "$PROGRAM_ID" --url "$URL" 2>/dev/null) \
  || { echo "error: $PROGRAM_ID is not deployed on $URL — first deploys use scripts/deploy.sh" >&2; exit 1; }
ON_CHAIN_AUTHORITY=$(printf '%s\n' "$PROGRAM_INFO" | awk '/^Authority:/ {print $2}')
[[ -n "$ON_CHAIN_AUTHORITY" ]] || { echo "error: could not read the program's upgrade authority from $URL" >&2; exit 1; }
if [[ "$ON_CHAIN_AUTHORITY" != "$VAULT" ]]; then
  echo "error: UPGRADE_AUTHORITY in $(env_file "$ENV") is $VAULT," >&2
  echo "       but $PROGRAM_ID's on-chain upgrade authority is $ON_CHAIN_AUTHORITY." >&2
  echo "       Fix the env file, or finish scripts/migrate-to-squads.sh $ENV <vault> first." >&2
  exit 1
fi

scripts/build.sh "$ENV"
ARTIFACT="target/deploy-$ENV/subscription_controller.so"
SIZE=$(stat -f%z "$ARTIFACT" 2>/dev/null || stat -c%s "$ARTIFACT")

echo "environment      : $ENV"
echo "program id       : $PROGRAM_ID"
echo "vault (authority): $VAULT"
echo "artifact         : $ARTIFACT ($SIZE bytes)"
echo "sha256           : $(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
echo "fee payer        : $FEE_PAYER_PUBKEY (balance: $(solana balance -k "$FEE_PAYER" -u "$URL" | awk '{print $1}') SOL)"
echo
echo "⚠️  ONE-WAY for the buffer: once its authority is the vault, only the Squad"
echo "   can execute or close it. If the proposal is never executed the buffer"
echo "   keeps its rent and stays a live upgrade path — see scripts/buffers.sh."
report_stray_buffers "$VAULT" "$URL" "the Squads app — only vault $VAULT can close these"
report_stray_buffers "$FEE_PAYER_PUBKEY" "$URL" "solana program close --buffers -k $FEE_PAYER --authority $FEE_PAYER --recipient $FEE_PAYER_PUBKEY --url $URL"
echo
read -rp "Write the buffer to MAINNET and hand it to the vault? Retype the FULL vault address: " TYPED
[[ "$TYPED" == "$VAULT" ]] || { echo "aborted (mismatch)"; exit 1; }

BUFFER=$(solana program write-buffer "$ARTIFACT" --keypair "$FEE_PAYER" --url "$URL" | awk '/Buffer:/ {print $2}')
[[ -n "$BUFFER" ]] || { echo "error: buffer address not captured" >&2; exit 1; }
echo "buffer: $BUFFER"
if ! solana program set-buffer-authority "$BUFFER" --new-buffer-authority "$VAULT" --keypair "$FEE_PAYER" --url "$URL"; then
  echo "error: buffer $BUFFER could not be handed to $VAULT — closing it so its rent comes back." >&2
  solana program close "$BUFFER" -k "$FEE_PAYER" --authority "$FEE_PAYER" --recipient "$FEE_PAYER_PUBKEY" --url "$URL" || {
    echo "⚠️  the close failed too. Buffer $BUFFER still holds rent and the fee payer still" >&2
    echo "   owns it. Retry with:" >&2
    echo "     solana program close $BUFFER -k $FEE_PAYER --authority $FEE_PAYER --recipient $FEE_PAYER_PUBKEY --url $URL" >&2
  }
  exit 1
fi

echo
echo "Staged. Finish in the Squads app (the Squad owning vault $VAULT):"
echo "  Developers → Programs → program $PROGRAM_ID → Upgrade"
echo "  buffer address: $BUFFER"
echo "  → propose, approve with your wallet, execute."
echo "The buffer's rent returns to the fee payer when the upgrade executes."
echo "If you abandon the proposal instead, close the buffer from the Squads app —"
echo "list it anytime with: scripts/buffers.sh $ENV"
