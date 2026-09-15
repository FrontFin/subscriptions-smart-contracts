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

PROGRAM_INFO=$(solana program show "$PROGRAM_ID" --url "$URL" 2>/dev/null) \
  || { echo "error: $PROGRAM_ID is not deployed — first deploys use scripts/deploy.sh" >&2; exit 1; }

# Everything below stages a rent-bearing buffer and hands it to $AUTHORITY
# before the browser is ever asked to sign. Checking the signer afterwards is
# too late: the buffer is already the authority's and the temporary payer can
# no longer reclaim it.
ON_CHAIN_AUTHORITY=$(awk '/^Authority:/ {print $2}' <<<"$PROGRAM_INFO")
[[ -n "$ON_CHAIN_AUTHORITY" ]] \
  || { echo "error: could not read $PROGRAM_ID's upgrade authority from $URL" >&2; exit 1; }
if [[ "$ON_CHAIN_AUTHORITY" != "$AUTHORITY" ]]; then
  echo "error: UPGRADE_AUTHORITY in $(env_file "$ENV") is $AUTHORITY," >&2
  echo "       but $PROGRAM_ID's on-chain upgrade authority is $ON_CHAIN_AUTHORITY." >&2
  echo "       Fix the env file before staging anything." >&2
  exit 1
fi
AUTHORITY_KIND=$(key_kind "$AUTHORITY" "UPGRADE_AUTHORITY") || exit 1
if [[ "$AUTHORITY_KIND" != "wallet" ]]; then
  echo "error: the upgrade authority $AUTHORITY is a program address, so it cannot" >&2
  echo "       sign in the browser. Use scripts/stage-upgrade.sh $ENV for a vault." >&2
  exit 1
fi

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

# The buffer holds rent and is a second way to upgrade the program, so it is
# tracked from the moment it exists. The handoff below is inside the tracked
# window on purpose: it can land and still report failure, which leaves the
# buffer under $AUTHORITY rather than the temporary payer.
BUFFER_LIVE=true
_upgrade_cleanup() {
  if $BUFFER_LIVE; then
    echo >&2
    echo "The staged buffer $BUFFER still exists. Re-running stages a NEW one." >&2
    # The handoff may or may not have landed, so look under both owners — and
    # print the close each one needs. buffers.sh signs as the env's upgrade
    # authority, so it cannot touch a buffer the fee payer still owns.
    echo "If $AUTHORITY owns it:" >&2
    echo "  scripts/buffers.sh $ENV --close $BUFFER" >&2
    report_stray_buffers "$AUTHORITY" "$URL" "scripts/buffers.sh $ENV --close"
    # Only with a FEE_PAYER override does the payer key outlive this script;
    # the temporary payer closes its own buffers in _eph_cleanup below.
    if [[ -n "${FEE_PAYER:-}" && -n "${EPHEMERAL_PUBKEY:-}" ]]; then
      echo "If $EPHEMERAL_PUBKEY (the FEE_PAYER) owns it:" >&2
      echo "  solana program close $BUFFER -k $PAYER_FILE --authority $PAYER_FILE --recipient $EPHEMERAL_PUBKEY --url $URL" >&2
      report_stray_buffers "$EPHEMERAL_PUBKEY" "$URL" \
        "solana program close --buffers -k $PAYER_FILE --authority $PAYER_FILE --recipient $EPHEMERAL_PUBKEY --url $URL"
    fi
  fi
  _eph_cleanup
}
trap _upgrade_cleanup EXIT INT TERM

EPHEMERAL_PUBKEY=$(solana-keygen pubkey "$PAYER_FILE" 2>/dev/null) || EPHEMERAL_PUBKEY=""
solana program set-buffer-authority "$BUFFER" --new-buffer-authority "$AUTHORITY" --keypair "$PAYER_FILE" --url "$URL" >/dev/null

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
    # A lost confirmation is not proof the upgrade failed, so the buffer
    # decides: the loader consumes it when the upgrade lands.
    if ! solana confirm "$SIG" --url "$URL"; then
      echo >&2
      echo "warning: $SIG did not confirm through this RPC." >&2
      BUF_LOOKUP=$(solana account "$BUFFER" --url "$URL" 2>&1) && BUF_FOUND=true || BUF_FOUND=false
      if $BUF_FOUND; then
        echo "error: buffer $BUFFER still exists, so the upgrade did not land." >&2
        break
      fi
      # A failed lookup is not proof of consumption — it also covers outages.
      if ! grep -qiE 'accountnotfound|not found|unable to find|does not exist' <<<"$BUF_LOOKUP"; then
        echo "error: could not tell whether buffer $BUFFER still exists, so the" >&2
        echo "   upgrade outcome is unknown. Check it before re-running, because a" >&2
        echo "   rerun stages another buffer:" >&2
        echo "     solana confirm $SIG --url $URL" >&2
        break
      fi
      echo "The buffer is gone, so the upgrade did land after all." >&2
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
