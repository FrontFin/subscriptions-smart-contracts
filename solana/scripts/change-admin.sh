#!/usr/bin/env bash
# Change the config admin — a TWO-STEP, browser-signed handover (a typo can't
# brick admin control, because power only moves once the new wallet accepts):
#
#   propose <new-admin>   signed by the CURRENT admin (UPGRADE_AUTHORITY)
#   accept                signed by the NEW admin (the proposed wallet)
#
# Run `propose` first (current-admin browser popup), then have the new admin
# run `accept` (new-admin browser popup). If you control both wallets, run
# both yourself. After a completed handover, update UPGRADE_AUTHORITY in the
# env's .env to the new wallet.
#
# The private key never leaves the wallet extension (localhost bridge).
#
# Usage: scripts/change-admin.sh <local|dev|prod> propose <new-admin-pubkey>
#        scripts/change-admin.sh <local|dev|prod> accept  <new-admin-pubkey>
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_env.sh

ENV="${1:?usage: scripts/change-admin.sh <local|dev|prod> propose|accept <new-admin-pubkey>}"
STEP="${2:?usage: scripts/change-admin.sh <env> propose|accept <new-admin-pubkey>}"
NEW_ADMIN="${3:?usage: scripts/change-admin.sh <env> propose|accept <new-admin-pubkey>}"
[[ "$ENV" != "test" ]] || { echo "error: 'test' is the LiteSVM fixture — nothing on-chain" >&2; exit 1; }
PROGRAM_ID=$(env_program_id "$ENV")
RPC_URL="https://api.mainnet-beta.solana.com"

case "$STEP" in
  propose)
    # The current admin signs propose — read it live from chain (it may differ
    # from UPGRADE_AUTHORITY after a prior handover), falling back to the
    # upgrade authority if the config isn't initialized yet.
    SIGNER=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$(env_upgrade_authority "$ENV")" "$RPC_URL" show 2>/dev/null \
      | awk '$1=="admin"{print $3}')
    [[ -n "$SIGNER" ]] || SIGNER=$(env_upgrade_authority "$ENV")
    ARGS=(propose-admin "$NEW_ADMIN")
    echo "propose: current admin $SIGNER → pending admin $NEW_ADMIN" ;;
  accept)
    SIGNER="$NEW_ADMIN"                       # the pending admin accepts
    ARGS=(accept-admin)
    echo "accept: $NEW_ADMIN claims the admin role" ;;
  *)
    echo "error: step must be 'propose' or 'accept'" >&2; exit 1 ;;
esac

while true; do
  B64=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$SIGNER" "$RPC_URL" "${ARGS[@]}" \
        | awk -F': *|:' '/^UNSIGNED_TX_B64:/ {print $2}')
  [[ -n "$B64" ]] || { echo "error: could not build the transaction" >&2; exit 1; }
  if SIG=$(python3 scripts/sign_in_browser.py "$B64" "$SIGNER"); then
    echo "signature: $SIG"
    solana confirm "$SIG" -u "$RPC_URL" >/dev/null 2>&1 || sleep 2
    cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$SIGNER" "$RPC_URL" show || true
    [[ "$STEP" == "accept" ]] && echo "Handover complete — update UPGRADE_AUTHORITY in scripts/envs/$ENV.env to $NEW_ADMIN"
    exit 0
  fi
  echo
  read -rp "Not signed (rejected or blockhash expired). Retry with a fresh transaction? [y/N] " AGAIN
  [[ "$AGAIN" == "y" || "$AGAIN" == "Y" ]] || { echo "aborted"; exit 1; }
done
