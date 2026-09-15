#!/usr/bin/env bash
# Change the config admin — a TWO-STEP, browser-signed handover (a typo can't
# brick admin control, because power only moves once the new wallet accepts):
#
#   propose <new-admin>   signed by the CURRENT admin (UPGRADE_AUTHORITY)
#   accept                signed by the NEW admin (the proposed wallet)
#
# Run `propose` first (current-admin browser popup), then have the new admin
# run `accept` (new-admin browser popup). If you control both wallets, run
# both yourself.
#
# This moves Config.admin only. The loader's upgrade authority is separate and
# is what UPGRADE_AUTHORITY in the env file means, so do NOT repoint that line
# at the new admin — upgrade.sh would then sign with a key the loader rejects.
# Admin-signing scripts read the live admin from chain.
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
# Pubkey::default() — proposing it cancels a pending handover.
NO_PENDING_ADMIN="11111111111111111111111111111111"

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
    CONFIRM_RC=0; confirm_signature "$SIG" "$RPC_URL" || CONFIRM_RC=$?
    if (( CONFIRM_RC != 0 )); then
      echo "note: the admin change's outcome is not confirmed by this RPC — reading the config before deciding whether it took effect." >&2
    fi
    STATE=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$SIGNER" "$RPC_URL" show) || {
      echo "error: the config could not be read back, so the admin state is unknown." >&2
      echo "Check it before relying on either wallet:" >&2
      echo "  cargo run -p admin-cli -- $PROGRAM_ID tx:$SIGNER $RPC_URL show" >&2
      exit 1
    }
    echo "$STATE"
    if [[ "$STEP" == "accept" ]]; then
      LIVE=$(awk '$1=="admin"{print $3}' <<<"$STATE")
      if [[ "$LIVE" != "$NEW_ADMIN" ]]; then
        echo "error: the config admin reads back as ${LIVE:-unreadable}, not $NEW_ADMIN." >&2
        echo "The handover did NOT complete. Keep using the current admin wallet." >&2
        exit 1
      fi
      echo "Handover complete — $NEW_ADMIN is the config admin, confirmed on chain."
      echo "Leave UPGRADE_AUTHORITY in scripts/envs/$ENV.env alone; it is the loader's"
      echo "authority, which this did not move."
    else
      # Take everything after the colon rather than counting fields, so the
      # check does not break when the CLI's column padding changes.
      PENDING=$(sed -n 's/^ *pending admin *: *//p' <<<"$STATE")
      if [[ "$NEW_ADMIN" == "$NO_PENDING_ADMIN" ]]; then
        # Proposing the all-zero key cancels a handover, and admin-cli prints
        # no pending line for it, so success here looks like absence.
        if [[ -n "$PENDING" ]]; then
          echo "error: $PENDING is still pending — the cancellation did not land." >&2
          exit 1
        fi
        echo "Cancelled — no handover is pending, confirmed on chain."
      elif [[ "$PENDING" != "$NEW_ADMIN" ]]; then
        echo "error: the config shows pending admin ${PENDING:-<none>}, not $NEW_ADMIN." >&2
        echo "The proposal did NOT land. Re-run this step." >&2
        exit 1
      else
        echo "Proposed — $NEW_ADMIN is pending, confirmed on chain. It must now run"
        echo "'scripts/change-admin.sh $ENV accept $NEW_ADMIN' from its own wallet."
      fi
    fi
    exit 0
  fi
  echo
  read -rp "Not signed (rejected or blockhash expired). Retry with a fresh transaction? [y/N] " AGAIN
  [[ "$AGAIN" == "y" || "$AGAIN" == "Y" ]] || { echo "aborted"; exit 1; }
done
