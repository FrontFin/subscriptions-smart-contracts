#!/usr/bin/env bash
# Closing burns the program ID; redeployment changes the PDA and invalidates old delegations.
# Usage: scripts/close.sh <local|dev|prod> [recipient-pubkey] (default: wallet)
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

# Close config before the program to recover its rent; its admin may differ from upgrade authority.
CONFIG_ADMIN=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$AUTHORITY" "$RPC_URL" show 2>/dev/null \
  | awk '$1=="admin"{print $3}')
if [[ -n "$CONFIG_ADMIN" ]]; then
  CB64=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$CONFIG_ADMIN" "$RPC_URL" close-config \
        | awk -F': *|:' '/^UNSIGNED_TX_B64:/ {print $2}')
  [[ -n "$CB64" ]] || { echo "error: could not build the close-config transaction" >&2; exit 1; }
  read -r -d '' CLASSIFY_SIM <<'PY' || true
import sys, json
try:
    value = json.load(sys.stdin)["result"]["value"]
except Exception:
    print("unreadable")
    sys.exit(0)
if value.get("err") is None:
    print("ok")
    sys.exit(0)
logs = " | ".join(value.get("logs") or [])
if "InstructionFallbackNotFound" in logs or "Fallback functions are not supported" in logs:
    print("legacy")
else:
    print("rejected {} {}".format(json.dumps(value["err"]), logs))
PY
  SIM_JSON=$(curl -sS "$RPC_URL" -X POST -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"simulateTransaction\",\"params\":[\"$CB64\",{\"sigVerify\":false,\"replaceRecentBlockhash\":true,\"encoding\":\"base64\"}]}") \
    || SIM_JSON=""
  SIM_VERDICT=$(printf '%s' "$SIM_JSON" | python3 -c "$CLASSIFY_SIM")
  case "$SIM_VERDICT" in
    ok)
      echo "reclaiming config rent (admin $CONFIG_ADMIN)..."
      # A config close that does not land leaves the config on a program id the
      # lines below burn, so it could never be closed again. Stop instead.
      if ! CSIG=$(python3 scripts/sign_in_browser.py "$CB64" "$CONFIG_ADMIN"); then
        echo "error: the config close was not signed." >&2
        echo "Teardown stops here — nothing has been destroyed. Rerun when ready." >&2
        exit 1
      fi
      if ! solana confirm "$CSIG" --url "$URL" >/dev/null 2>&1; then
        echo "error: config close $CSIG did not confirm." >&2
        echo "Teardown stops here — nothing has been destroyed. Check that" >&2
        echo "signature, then rerun." >&2
        exit 1
      fi
      echo "config closed: $CSIG"
      ;;
    legacy)
      echo "deployed program predates close_config — skipping config-rent reclaim; ~0.0035 SOL orphaned."
      ;;
    unreadable)
      echo "error: could not simulate close_config (RPC unreachable or unexpected reply)." >&2
      echo "Aborting before the irreversible program close. Nothing has been changed." >&2
      exit 1
      ;;
    *)
      echo "error: the deployed program rejected close_config: ${SIM_VERDICT#rejected }" >&2
      echo "The config still exists and its rent would be stranded, so teardown stops here." >&2
      echo "If an admin handover is pending, cancel or complete it first, then rerun." >&2
      exit 1
      ;;
  esac
else
  echo "no config found on-chain — skipping config-rent reclaim."
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

if solana program show "$PROGRAM_ID" --url "$URL" >/dev/null 2>&1; then
  echo "error: $PROGRAM_ID is still live on-chain — the close did not take effect." >&2
  echo "PROGRAM_ID stays in scripts/envs/$ENV.env so the next deploy cannot mint a second id." >&2
  echo "Check signature $SIG, then rerun this script." >&2
  exit 1
fi

# Rename a sibling temp file atomically, preserving the original mode and avoiding truncation.
SCRUBBED="scripts/envs/$ENV.env.tmp.$$"
trap 'rm -f "$SCRUBBED"' EXIT
cp -p "scripts/envs/$ENV.env" "$SCRUBBED"
sed \
  -e '/^PROGRAM_ID=/d' \
  -e '/^# \^ the smart contract address/d' \
  -e '/^#   SolanaSubscription.*SmartContractAddress/d' \
  -e '/^# The backend derives the MeshDelegate PDA/d' \
  -e '/^# value\. Informational, for cross-checking/d' \
  -e '/^# becomes the .delegatee. recorded/d' \
  -e '/^# MeshDelegate PDA = /d' \
  "scripts/envs/$ENV.env" > "$SCRUBBED"
mv "$SCRUBBED" "scripts/envs/$ENV.env"
echo "Done. Rent refunded to $RECIPIENT."
echo "Unpinned the burned PROGRAM_ID from scripts/envs/$ENV.env — the next deploy mints a fresh id/PDA."
