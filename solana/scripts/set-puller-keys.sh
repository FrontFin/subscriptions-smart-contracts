#!/usr/bin/env bash
# Apply the env's PULLER_KEYS to the program's ON-CHAIN config — a single
# data transaction signed by the CONFIG ADMIN. The admin is read live from the
# on-chain config (not assumed to be UPGRADE_AUTHORITY — after a handover they
# can differ), so this always prompts for whoever actually controls the
# config. No build, no deploy: the audited program code is untouched. If the
# config doesn't exist yet, it initializes as the upgrade authority.
#
# Signing (2nd arg):
#   (default)  browser wallet popup via the localhost bridge — the key never
#              leaves the wallet extension;
#   --paste    legacy: paste the base58 secret key at a hidden prompt;
#   --print    Squads: print the instruction for the transaction builder.
#
# Rotation:    list old+new keys in the .env → run this → flip the backend's
#              Key Vault secret → remove the old key → run this again.
# Kill switch: set PULLER_KEYS="" → run this. Resume: restore keys → run.
#
# Usage: scripts/set-puller-keys.sh <local|dev|prod> [--paste|--print]
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

# Whitespace-separated pubkeys on stdin -> one sorted, space-joined line, so
# the wanted list and the on-chain list compare regardless of order.
normalize_keys() { tr -s ' \t\n' '\n' | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//'; }

# The signer must be the CURRENT config admin. Read it live from chain; if the
# config isn't initialized yet, fall back to the upgrade authority (the
# gated `initialize` path).
SIGNER=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$UPGRADE_AUTHORITY" "$RPC_URL" show 2>/dev/null \
  | awk '$1=="admin"{print $3}')
[[ -n "$SIGNER" ]] || SIGNER="$UPGRADE_AUTHORITY"

echo "environment : $ENV"
echo "program id  : $PROGRAM_ID"
echo "signed by   : $SIGNER (current config admin)"
if [[ -z "${KEYS// /}" ]]; then
  echo "puller keys : <EMPTY — ⚠️  KILL SWITCH: no key will be able to pull>"
else
  echo "puller keys : $KEYS"
fi
echo

MODE="${2:-}"

# Squads mode — the admin is the vault, so nothing is signed here; print the
# instruction for the Squads transaction builder.
if [[ "$MODE" == "--print" ]]; then
  # shellcheck disable=SC2086 — KEYS is intentionally word-split
  cargo run -q -p admin-cli -- "$PROGRAM_ID" print "$RPC_URL" keys $KEYS
  exit 0
fi

# Legacy paste mode.
if [[ "$MODE" == "--paste" ]]; then
  prompt_wallet "$SIGNER"
  read -rp "Apply to the on-chain config on MAINNET? Type 'apply' to proceed: " CONFIRM
  [[ "$CONFIRM" == "apply" ]] || { echo "aborted"; exit 1; }
  # shellcheck disable=SC2086 — KEYS is intentionally word-split
  cargo run -q -p admin-cli -- "$PROGRAM_ID" "$WALLET" "$RPC_URL" keys $KEYS
  exit 0
fi

# Default: browser wallet popup (localhost bridge). The wallet shows the
# transaction and IS the confirmation step.
while true; do
  # shellcheck disable=SC2086 — KEYS is intentionally word-split
  B64=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$SIGNER" "$RPC_URL" keys $KEYS \
        | awk -F': *|:' '/^UNSIGNED_TX_B64:/ {print $2}')
  [[ -n "$B64" ]] || { echo "error: could not build the transaction" >&2; exit 1; }
  if SIG=$(python3 scripts/sign_in_browser.py "$B64" "$SIGNER"); then
    echo "signature: $SIG"
    solana confirm "$SIG" -u "$RPC_URL" >/dev/null 2>&1 || sleep 2
    ON_CHAIN=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$SIGNER" "$RPC_URL" show | tee /dev/stderr \
      | awk '$1=="puller"&&$2=="key"{print $4}' | normalize_keys)
    WANTED=$(printf '%s' "$KEYS" | normalize_keys)
    if [[ "$ON_CHAIN" != "$WANTED" ]]; then
      echo "🛑 on-chain puller keys are [$ON_CHAIN], expected [$WANTED] — the change did NOT land." >&2
      if [[ -z "$WANTED" ]]; then
        echo "   THE KILL SWITCH IS NOT ENGAGED. Re-run this script." >&2
      fi
      exit 1
    fi
    echo "verified on-chain: puller keys = [${ON_CHAIN:-EMPTY — kill switch engaged}]"
    exit 0
  fi
  echo
  read -rp "Not signed (rejected or blockhash expired). Retry with a fresh transaction? [y/N] " AGAIN
  [[ "$AGAIN" == "y" || "$AGAIN" == "Y" ]] || { echo "aborted"; exit 1; }
done
