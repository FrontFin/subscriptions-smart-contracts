#!/usr/bin/env bash
# Undeploy an env's program, refunding its rent deposit — signed by the
# authority wallet IN THE BROWSER (one popup). No key pasted or stored.
#
# ⚠️ IRREVERSIBLE: a closed program id is burned forever. On success this
# script unpins PROGRAM_ID from the env's .env, so the env's next deploy
# mints a fresh id → new MeshDelegate PDA (existing delegations die with the
# old one; update the backend's SmartContractAddress).
#
# Usage: scripts/close.sh <local|dev|prod> [recipient-pubkey]  (default: the wallet)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_env.sh

ENV="${1:?usage: scripts/close.sh <local|dev|prod> [recipient-pubkey]}"
[[ "$ENV" != "test" ]] || { echo "error: 'test' is the LiteSVM fixture — nothing on-chain to close" >&2; exit 1; }
PROGRAM_ID=$(env_program_id "$ENV")
AUTHORITY=$(env_upgrade_authority "$ENV")
RECIPIENT="${2:-$AUTHORITY}"
URL="mainnet-beta"
RPC_URL="https://api.mainnet-beta.solana.com"

echo "environment : $ENV"
echo "program id  : $PROGRAM_ID"
echo "signed by   : $AUTHORITY (browser wallet, one popup)"
echo "refund to   : $RECIPIENT"
echo
echo "This permanently burns the program id (it can never be redeployed)."
read -rp "Type 'close' to proceed: " CONFIRM
[[ "$CONFIRM" == "close" ]] || { echo "aborted"; exit 1; }

# reclaim_rent <admin-cli command> <label> <rent> — build, simulate, and (if
# the simulation is clean) browser-sign one rent-reclaiming close. Simulating
# first skips gracefully, with no scary popup, when the deployed program has no
# such instruction or the account is already gone.
reclaim_rent() {
  local cli_command="$1" label="$2" rent="$3"
  local b64 sim_err sig
  b64=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$CONFIG_ADMIN" "$RPC_URL" "$cli_command" \
        | awk -F': *|:' '/^UNSIGNED_TX_B64:/ {print $2}')
  if [[ -z "$b64" ]]; then
    echo "could not build the $label close — skipping; $rent orphaned." >&2
    return 0
  fi
  sim_err=$(curl -s "$RPC_URL" -X POST -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"simulateTransaction\",\"params\":[\"$b64\",{\"sigVerify\":false,\"replaceRecentBlockhash\":true,\"encoding\":\"base64\"}]}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['value']['err'])" 2>/dev/null)
  if [[ "$sim_err" != "None" ]]; then
    echo "$label rent reclaim unavailable (deployed program has no $cli_command, or the account is already gone) — skipping; $rent orphaned."
    return 0
  fi
  echo "reclaiming $label rent (admin $CONFIG_ADMIN)..."
  if sig=$(python3 scripts/sign_in_browser.py "$b64" "$CONFIG_ADMIN"); then
    echo "$label closed: $sig"
    solana confirm "$sig" --url "$URL" >/dev/null 2>&1 || true
  else
    echo "⚠️  $label close not signed — its rent ($rent) will be orphaned." >&2
  fi
}

# First reclaim the account rents, while the program is still live (closing the
# program first would orphan them). Signed by the CURRENT on-chain admin —
# which may differ from the upgrade authority after a handover. The destination
# registry MUST go first: closing it reads the config to check the admin, so
# once the config is gone the registry can never be closed.
CONFIG_ADMIN=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$AUTHORITY" "$RPC_URL" show 2>/dev/null \
  | awk '$1=="admin"{print $3}')
if [[ -n "$CONFIG_ADMIN" ]]; then
  reclaim_rent close-registry "destination registry" "~0.0043 SOL"
  reclaim_rent close-config "config" "~0.0035 SOL"
else
  echo "no config found on-chain — skipping the rent reclaims (without a config the registry cannot be closed either)."
fi

while true; do
  B64=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$AUTHORITY" "$RPC_URL" close "$RECIPIENT" \
        | awk -F': *|:' '/^UNSIGNED_TX_B64:/ {print $2}')
  [[ -n "$B64" ]] || { echo "error: could not build the close transaction" >&2; exit 1; }
  if SIG=$(python3 scripts/sign_in_browser.py "$B64" "$AUTHORITY"); then
    echo "close signature: $SIG"
    solana confirm "$SIG" --url "$URL" || true
    break
  fi
  echo
  read -rp "Not signed (rejected or blockhash expired). Retry with a fresh transaction? [y/N] " AGAIN
  [[ "$AGAIN" == "y" || "$AGAIN" == "Y" ]] || { echo "aborted"; exit 1; }
done

SCRUBBED=$(mktemp)
sed \
  -e '/^PROGRAM_ID=/d' \
  -e '/^# \^ the smart contract address/d' \
  -e '/^#   SolanaSubscription.*SmartContractAddress/d' \
  -e '/^# The backend derives the MeshDelegate PDA/d' \
  -e '/^# value\. Informational, for cross-checking/d' \
  -e '/^# becomes the .delegatee. recorded/d' \
  -e '/^# MeshDelegate PDA = /d' \
  "scripts/envs/$ENV.env" > "$SCRUBBED"
cat "$SCRUBBED" > "scripts/envs/$ENV.env"
rm -f "$SCRUBBED"
echo "Done. Rent refunded to $RECIPIENT."
echo "Unpinned the burned PROGRAM_ID from scripts/envs/$ENV.env — the next deploy mints a fresh id/PDA."
