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

AUTHORITY_KIND=$(python3 - "$AUTHORITY" <<'PY'
import sys

ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
address = sys.argv[1]
if any(char not in ALPHABET for char in address):
    sys.exit(f'error: {address} is not a base58 address')
value = 0
for char in address:
    value = value * 58 + ALPHABET.index(char)
raw = b'\x00' * (len(address) - len(address.lstrip('1')))
raw += value.to_bytes((value.bit_length() + 7) // 8, 'big')
if len(raw) != 32:
    sys.exit(f'error: {address} decodes to {len(raw)} bytes, not a 32-byte pubkey')

prime = 2 ** 255 - 19
curve_d = (-121665 * pow(121666, prime - 2, prime)) % prime
y = int.from_bytes(raw, 'little') & ((1 << 255) - 1)
on_curve = False
if y < prime:
    y_squared = y * y % prime
    x_squared = (y_squared - 1) * pow((curve_d * y_squared + 1) % prime, prime - 2, prime) % prime
    x = pow(x_squared, (prime + 3) // 8, prime)
    if (x * x - x_squared) % prime != 0:
        x = x * pow(2, (prime - 1) // 4, prime) % prime
    on_curve = (x * x - x_squared) % prime == 0
print('keypair' if on_curve else 'pda')
PY
)
if [[ "$AUTHORITY_KIND" != "keypair" ]]; then
  echo >&2
  echo "error: $AUTHORITY is off the ed25519 curve, so it is a program-derived address —" >&2
  echo "       what a Squads vault looks like. No private key for it exists anywhere, so" >&2
  echo "       nothing you could paste here would sign the close." >&2
  echo "       Close these buffers from the Squads app that owns the vault instead." >&2
  exit 1
fi

echo
if [[ -n "$TARGET" ]]; then
  echo "About to close buffer $TARGET — its rent goes to $AUTHORITY."
  read -rp "Retype the FULL buffer address to confirm: " TYPED
  [[ "$TYPED" == "$TARGET" ]] || { echo "aborted (mismatch)"; exit 1; }
else
  echo "About to close EVERY buffer listed above — their rent goes to $AUTHORITY."
  echo "⚠️  That list is everything $AUTHORITY holds, not everything '$ENV' holds."
  [[ -z "$SHARED" ]] || echo "   It therefore includes buffers staged for:$SHARED"
  echo "   A buffer is not tied to a program until an upgrade consumes it, so one"
  echo "   in this list may belong to a different program entirely. A buffer"
  echo "   staged for a Squads upgrade that has not executed yet is in it too —"
  echo "   closing that one cancels the pending upgrade."
  echo "   Read the list before you continue, or pass a single buffer address."
  read -rp "Type the environment name '$ENV' to close every buffer $AUTHORITY holds: " TYPED
  [[ "$TYPED" == "$ENV" ]] || { echo "aborted (mismatch)"; exit 1; }
fi

prompt_wallet "$AUTHORITY"

# -k names the FEE PAYER. --authority only supplies the buffer-authority
# signature; without -k the fee falls to whatever ~/.config/solana holds.
if [[ -n "$TARGET" ]]; then
  solana program close "$TARGET" -k "$WALLET" --authority "$WALLET" --recipient "$AUTHORITY" --url "$URL"
else
  solana program close --buffers -k "$WALLET" --authority "$WALLET" --recipient "$AUTHORITY" --url "$URL"
fi
