#!/usr/bin/env bash
# Usage: scripts/buffers.sh <local|dev|prod> [--close [buffer-address]]
# --close without an address closes all buffers owned by the authority.
# Wallet authorities sign via key prompt; PDA authorities must close through Squads.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_wallet.sh
source scripts/_env.sh
source scripts/_buffers.sh

ENV="${1:?usage: scripts/buffers.sh <local|dev|prod> [--close [buffer-address]]}"
MODE="${2:-}"
TARGET="${3:-}"
[[ "$ENV" != "test" ]] || { echo "error: 'test' is the LiteSVM fixture — nothing on-chain" >&2; exit 1; }
[[ -z "$MODE" || "$MODE" == "--close" ]] || { echo "error: unknown option '$MODE' (only --close)" >&2; exit 1; }
AUTHORITY=$(env_upgrade_authority "$ENV")
URL="mainnet-beta"

# Buffers belong to an authority, not an environment; shared keys see the same list.
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

HELD=$(list_buffers "$AUTHORITY" "$URL") || {
  echo >&2
  echo "error: could not read the buffers $AUTHORITY holds, so no address can be checked" >&2
  echo "       against that list. Nothing was closed. Retry when the RPC answers." >&2
  exit 1
}

echo
if [[ -n "$TARGET" ]]; then
  if ! grep -qxF "$TARGET" <<<"$HELD"; then
    echo "error: $TARGET is not a buffer held by $AUTHORITY, so this script will not" >&2
    echo "       close it. The same command closes a PROGRAM account, and a closed" >&2
    echo "       program is gone for good." >&2
    if [[ -z "$HELD" ]]; then
      echo "       $AUTHORITY holds no buffers at all right now." >&2
    else
      echo "       Buffers it holds:" >&2
      sed 's/^/         /' <<<"$HELD" >&2
    fi
    exit 1
  fi
  CLOSING="$TARGET"
  echo "About to close buffer $TARGET — its rent goes to $AUTHORITY."
  read -rp "Retype the FULL buffer address to confirm: " TYPED
  [[ "$TYPED" == "$TARGET" ]] || { echo "aborted (mismatch)"; exit 1; }
else
  [[ -n "$HELD" ]] || { echo "$AUTHORITY holds no buffers — nothing to close."; exit 0; }
  CLOSING="$HELD"
  echo "About to close these $(grep -c . <<<"$HELD") buffer(s) — their rent goes to $AUTHORITY:"
  sed 's/^/  /' <<<"$HELD"
  echo "⚠️  That is everything $AUTHORITY holds, not everything '$ENV' holds."
  [[ -z "$SHARED" ]] || echo "   It therefore includes buffers staged for:$SHARED"
  echo "   A buffer is not tied to a program until an upgrade consumes it, so one"
  echo "   in this list may belong to a different program entirely. A buffer"
  echo "   staged for a Squads upgrade that has not executed yet is in it too —"
  echo "   closing that one cancels the pending upgrade."
  echo "   Only the addresses printed here are closed. A buffer created after this"
  echo "   point is left alone."
  read -rp "Type the environment name '$ENV' to close the buffers listed above: " TYPED
  [[ "$TYPED" == "$ENV" ]] || { echo "aborted (mismatch)"; exit 1; }
fi

prompt_wallet "$AUTHORITY"

# --authority does not select the fee payer; -k is required as well.
FAILED=()
while read -r ADDRESS; do
  [[ -n "$ADDRESS" ]] || continue
  solana program close "$ADDRESS" -k "$WALLET" --authority "$WALLET" --recipient "$AUTHORITY" --url "$URL" \
    || FAILED+=("$ADDRESS")
done <<<"$CLOSING"

if (( ${#FAILED[@]} > 0 )); then
  echo >&2
  echo "⚠️  these buffers were not closed:" >&2
  printf '   %s\n' "${FAILED[@]}" >&2
  exit 1
fi
