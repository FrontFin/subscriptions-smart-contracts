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

ENV="${1:?usage: scripts/stage-upgrade.sh <local|dev|prod>}"
[[ "$ENV" != "test" ]] || { echo "error: 'test' is the LiteSVM fixture — never deployable" >&2; exit 1; }
PROGRAM_ID=$(env_program_id "$ENV")
VAULT=$(env_upgrade_authority "$ENV")
URL="mainnet-beta"
FEE_PAYER="${FEE_PAYER:-$HOME/.config/solana/id.json}"
[[ -f "$FEE_PAYER" ]] || { echo "error: fee payer keypair $FEE_PAYER not found (set FEE_PAYER=<path>)" >&2; exit 1; }

scripts/build.sh "$ENV"
ARTIFACT="target/deploy-$ENV/subscription_controller.so"
SIZE=$(stat -f%z "$ARTIFACT" 2>/dev/null || stat -c%s "$ARTIFACT")

echo "environment      : $ENV"
echo "program id       : $PROGRAM_ID"
echo "vault (authority): $VAULT"
echo "artifact         : $ARTIFACT ($SIZE bytes)"
echo "sha256           : $(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
echo "fee payer        : $(solana-keygen pubkey "$FEE_PAYER") (balance: $(solana balance -k "$FEE_PAYER" -u "$URL" | awk '{print $1}') SOL)"
echo
read -rp "Write the buffer to MAINNET now? Type 'stage' to proceed: " CONFIRM
[[ "$CONFIRM" == "stage" ]] || { echo "aborted"; exit 1; }

BUFFER=$(solana program write-buffer "$ARTIFACT" --keypair "$FEE_PAYER" --url "$URL" | awk '/Buffer:/ {print $2}')
[[ -n "$BUFFER" ]] || { echo "error: buffer address not captured" >&2; exit 1; }
echo "buffer: $BUFFER"
solana program set-buffer-authority "$BUFFER" --new-buffer-authority "$VAULT" --keypair "$FEE_PAYER" --url "$URL"

echo
echo "Staged. Finish in the Squads app (the Squad owning vault $VAULT):"
echo "  Developers → Programs → program $PROGRAM_ID → Upgrade"
echo "  buffer address: $BUFFER"
echo "  → propose, approve with your wallet, execute."
echo "The buffer's rent returns to the fee payer when the upgrade executes."
