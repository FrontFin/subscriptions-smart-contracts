#!/usr/bin/env bash
# List — and optionally close — the upgrade buffers an env's authority holds.
#
# Run it after any interrupted deploy or upgrade. A leftover buffer holds
# rent, and while it belongs to the program's upgrade authority it is a
# second live path to upgrade the program.
#
# Usage:
#   scripts/buffers.sh <local|dev|prod>                    list them
#   scripts/buffers.sh <local|dev|prod> --close            close all of them
#   scripts/buffers.sh <local|dev|prod> --close <buffer>   close just that one
#
# Listing is read-only. Closing needs the AUTHORITY to sign, so its key is
# pasted at the prompt (hidden input, temp file outside the repo, removed on
# exit). Once the authority is a Squads vault no such key exists — close the
# buffers from the Squads app instead.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_wallet.sh
source scripts/_env.sh

ENV="${1:?usage: scripts/buffers.sh <local|dev|prod> [--close [buffer-address]]}"
MODE="${2:-}"
TARGET="${3:-}"
[[ "$ENV" != "test" ]] || { echo "error: 'test' is the LiteSVM fixture — nothing on-chain" >&2; exit 1; }
[[ -z "$MODE" || "$MODE" == "--close" ]] || { echo "error: unknown option '$MODE' (only --close)" >&2; exit 1; }
AUTHORITY=$(env_upgrade_authority "$ENV")
URL="mainnet-beta"

# A buffer records an authority and some bytes. It is not tied to a program
# until an upgrade consumes it, so this list belongs to the AUTHORITY — every
# env sharing that key sees, and can close, the same buffers.
SHARED=""
for envfile in scripts/envs/*.env; do
  other=$(basename "$envfile" .env)
  [[ "$other" != "$ENV" ]] || continue
  grep -q "^UPGRADE_AUTHORITY=$AUTHORITY\$" "$envfile" && SHARED="$SHARED $other"
done

echo "environment : $ENV"
echo "authority   : $AUTHORITY"
[[ -z "$SHARED" ]] || echo "shared with :$SHARED — same authority, so the same buffers"
echo
solana program show --buffers --buffer-authority "$AUTHORITY" --url "$URL"

[[ "$MODE" == "--close" ]] || exit 0

echo
if [[ -n "$TARGET" ]]; then
  echo "About to close buffer $TARGET — its rent goes to $AUTHORITY."
else
  echo "About to close EVERY buffer listed above — their rent goes to $AUTHORITY."
  echo "⚠️  That list is everything $AUTHORITY holds, not everything '$ENV' holds."
  [[ -z "$SHARED" ]] || echo "   It therefore includes buffers staged for:$SHARED"
  echo "   A buffer is not tied to a program until an upgrade consumes it, so one"
  echo "   in this list may belong to a different program entirely. A buffer"
  echo "   staged for a Squads upgrade that has not executed yet is in it too —"
  echo "   closing that one cancels the pending upgrade."
  echo "   Read the list before you continue, or pass a single buffer address."
fi
read -rp "Type 'close' to proceed: " CONFIRM
[[ "$CONFIRM" == "close" ]] || { echo "aborted"; exit 1; }

prompt_wallet "$AUTHORITY"

# -k names the FEE PAYER. --authority only supplies the buffer-authority
# signature; without -k the fee falls to whatever ~/.config/solana holds.
if [[ -n "$TARGET" ]]; then
  solana program close "$TARGET" -k "$WALLET" --authority "$WALLET" --recipient "$AUTHORITY" --url "$URL"
else
  solana program close --buffers -k "$WALLET" --authority "$WALLET" --recipient "$AUTHORITY" --url "$URL"
fi
