#!/usr/bin/env bash
# Browser signs funding and upgrade; buffer rent returns to the authority.
# Usage: scripts/upgrade.sh <local|dev|prod> [FEE_PAYER=<path> override]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_ephemeral.sh
source scripts/_env.sh
source scripts/_buffers.sh

ENV="${1:?usage: scripts/upgrade.sh <local|dev|prod>}"
[[ "$ENV" != "test" ]] || { echo "error: 'test' is the LiteSVM fixture — never deployable" >&2; exit 1; }
PROGRAM_ID=$(env_program_id "$ENV")
AUTHORITY=$(env_upgrade_authority "$ENV")
URL="mainnet-beta"
RPC_URL="https://api.mainnet-beta.solana.com"

solana program show "$PROGRAM_ID" --url "$URL" >/dev/null 2>&1 \
  || { echo "error: $PROGRAM_ID is not deployed — first deploys use scripts/deploy.sh" >&2; exit 1; }

scripts/build.sh "$ENV"
ARTIFACT="target/deploy-$ENV/subscription_controller.so"
SIZE=$(stat -f%z "$ARTIFACT" 2>/dev/null || stat -c%s "$ARTIFACT")
CURRENT_LEN=$(solana program show "$PROGRAM_ID" --url "$URL" | awk '/Data Length/ {print $3}')
GROW=0
if (( SIZE > CURRENT_LEN )); then
  GROW=$(( SIZE - CURRENT_LEN ))
  (( GROW < 10240 )) && GROW=10240
fi
# Buffer rent is refunded; allocation growth rent stays with the program.
FUND_LAMPORTS=$(python3 -c "print(($SIZE + 200 + $GROW) * 6960 + 20_000_000)")

echo "environment       : $ENV (upgrade, browser-signed — two wallet popups)"
echo "program id        : $PROGRAM_ID"
echo "upgrade authority : $AUTHORITY"
echo "artifact          : $ARTIFACT ($SIZE bytes)"
echo "sha256            : $(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
if (( GROW > 0 )); then
  echo "allocation        : binary grew ($CURRENT_LEN → $SIZE bytes) — will extend by $GROW bytes first"
fi
echo "working capital   : ~$(python3 -c "print(f'{$FUND_LAMPORTS/1e9:.3f}')") SOL from the wallet (buffer rent comes back to it when the upgrade lands)"
report_stray_buffers "$AUTHORITY" "$URL" "scripts/buffers.sh $ENV --close"
echo
read -rp "Stage this upgrade on MAINNET? Type 'upgrade' to proceed: " CONFIRM
[[ "$CONFIRM" == "upgrade" ]] || { echo "aborted"; exit 1; }

ephemeral_payer "$AUTHORITY" "$FUND_LAMPORTS" "$RPC_URL"

if (( GROW > 0 )); then
  solana program extend "$PROGRAM_ID" "$GROW" --keypair "$PAYER_FILE" --url "$URL"
fi

BUFFER=$(solana program write-buffer "$ARTIFACT" --keypair "$PAYER_FILE" --url "$URL" | awk '/Buffer:/ {print $2}')
[[ -n "$BUFFER" ]] || { echo "error: buffer address not captured" >&2; exit 1; }
echo "buffer staged: $BUFFER"
solana program set-buffer-authority "$BUFFER" --new-buffer-authority "$AUTHORITY" --keypair "$PAYER_FILE" --url "$URL" >/dev/null

BUFFER_LIVE=false
_upgrade_cleanup() {
  if $BUFFER_LIVE; then
    echo >&2
    echo "The staged buffer $BUFFER still exists (authority: $AUTHORITY)." >&2
    echo "Re-running this script stages a NEW buffer; close the old one with:" >&2
    echo "  scripts/buffers.sh $ENV --close $BUFFER" >&2
    report_stray_buffers "$AUTHORITY" "$URL" "scripts/buffers.sh $ENV --close"
  fi
  _eph_cleanup
}
trap _upgrade_cleanup EXIT INT TERM
BUFFER_LIVE=true

while true; do
  B64=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$AUTHORITY" "$RPC_URL" upgrade "$BUFFER" \
        | awk -F': *|:' '/^UNSIGNED_TX_B64:/ {print $2}')
  [[ -n "$B64" ]] || { echo "error: could not build the upgrade transaction" >&2; exit 1; }
  if SIG=$(python3 scripts/sign_in_browser.py "$B64" "$AUTHORITY"); then
    echo "upgrade signature: $SIG"
    # The wallet returns as soon as it sends. Only a confirmed, successful
    # transaction proves the program was upgraded and the buffer consumed, so
    # the buffer stays flagged live until then — otherwise a dropped upgrade
    # leaves a second way to upgrade the program and nothing says so.
    if ! solana confirm "$SIG" --url "$URL"; then
      echo >&2
      echo "error: upgrade $SIG did not confirm — the program was NOT upgraded." >&2
      break
    fi
    BUFFER_LIVE=false
    solana program show "$PROGRAM_ID" --url "$URL"
    echo "buffer rent was refunded to $AUTHORITY (the spill account)."
    report_stray_buffers "$AUTHORITY" "$URL" "scripts/buffers.sh $ENV --close"
    exit 0
  fi
  echo
  read -rp "Not signed (rejected or blockhash expired). Retry with a fresh transaction? [y/N] " AGAIN
  [[ "$AGAIN" == "y" || "$AGAIN" == "Y" ]] || break
done

echo "Upgrade did not complete." >&2
exit 1
