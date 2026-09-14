#!/usr/bin/env bash
# Upgrade an env's program with the authority wallet signing IN THE BROWSER —
# no private key is ever pasted or stored, and the wallet is the only funded
# wallet you maintain. Two popups:
#
#   popup 1  fund a temporary payer (working capital for the staging buffer;
#            the buffer rent is refunded to the WALLET when the upgrade lands,
#            and leftovers in the temporary payer are swept back on exit);
#   popup 2  sign the upgrade itself.
#
# First deploys use scripts/deploy.sh.
#
# Usage: scripts/upgrade.sh <local|dev|prod>     [FEE_PAYER=<path> overrides]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_ephemeral.sh
source scripts/_env.sh

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
# Working capital: buffer rent (refunded to the WALLET as the upgrade's spill)
# + allocation growth rent (stays with the program) + fee margin.
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
echo
read -rp "Stage this upgrade on MAINNET? Type 'upgrade' to proceed: " CONFIRM
[[ "$CONFIRM" == "upgrade" ]] || { echo "aborted"; exit 1; }

# Popup 1 — the wallet funds the temporary payer.
ephemeral_payer "$AUTHORITY" "$FUND_LAMPORTS" "$RPC_URL"

if (( GROW > 0 )); then
  solana program extend "$PROGRAM_ID" "$GROW" --keypair "$PAYER_FILE" --url "$URL"
fi

BUFFER=$(solana program write-buffer "$ARTIFACT" --keypair "$PAYER_FILE" --url "$URL" | awk '/Buffer:/ {print $2}')
[[ -n "$BUFFER" ]] || { echo "error: buffer address not captured" >&2; exit 1; }
echo "buffer staged: $BUFFER"
solana program set-buffer-authority "$BUFFER" --new-buffer-authority "$AUTHORITY" --keypair "$PAYER_FILE" --url "$URL" >/dev/null

# Popup 2 — the wallet signs the upgrade.
while true; do
  B64=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$AUTHORITY" "$RPC_URL" upgrade "$BUFFER" \
        | awk -F': *|:' '/^UNSIGNED_TX_B64:/ {print $2}')
  [[ -n "$B64" ]] || { echo "error: could not build the upgrade transaction" >&2; exit 1; }
  if SIG=$(python3 scripts/sign_in_browser.py "$B64" "$AUTHORITY"); then
    echo "upgrade signature: $SIG"
    CONFIRM_RC=0; confirm_signature "$SIG" "$URL" || CONFIRM_RC=$?
    if (( CONFIRM_RC == 2 )); then
      echo "error: the upgrade's outcome is UNKNOWN. Look up $SIG and check whether buffer $BUFFER still exists before staging another one." >&2
      exit 1
    elif (( CONFIRM_RC != 0 )); then
      echo "error: the upgrade did not take effect, so buffer $BUFFER was not consumed and can be retried with." >&2
      exit 1
    fi
    solana program show "$PROGRAM_ID" --url "$URL"
    echo "buffer rent was refunded to $AUTHORITY (the spill account)."
    exit 0
  fi
  echo
  read -rp "Not signed (rejected or blockhash expired). Retry with a fresh transaction? [y/N] " AGAIN
  [[ "$AGAIN" == "y" || "$AGAIN" == "Y" ]] || break
done

echo "Upgrade not executed. The staged buffer $BUFFER still exists (authority: $AUTHORITY)." >&2
echo "Re-running this script stages a NEW buffer; reclaim the old one's rent later with:" >&2
echo "  solana program close $BUFFER --recipient <address>   (signed by the authority)" >&2
exit 1
