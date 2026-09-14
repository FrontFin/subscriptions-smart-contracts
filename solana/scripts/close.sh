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

# First reclaim the config account's rent, while the program is still live
# (closing the program first would orphan it). Signed by the CURRENT on-chain
# admin — which may differ from the upgrade authority after a handover.
CONFIG_PDA=$(python3 scripts/derive_pda.py "$PROGRAM_ID" config)
CONFIG_PRESENT=$(curl -s "$RPC_URL" -X POST -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccountInfo\",\"params\":[\"$CONFIG_PDA\",{\"encoding\":\"base64\",\"commitment\":\"confirmed\"}]}" \
  | python3 -c '
import json, sys
try:
    body = json.load(sys.stdin)
except Exception:
    print("unreadable"); raise SystemExit
if not isinstance(body, dict) or "error" in body:
    print("unreadable"); raise SystemExit
result = body.get("result")
if not isinstance(result, dict) or "value" not in result:
    print("unreadable"); raise SystemExit
print("absent" if result["value"] is None else "present")
' 2>/dev/null) || CONFIG_PRESENT="unreadable"
if [[ "$CONFIG_PRESENT" == "unreadable" ]]; then
  echo "error: could not read the config account $CONFIG_PDA. Closing the program without knowing whether a live Config exists could orphan it forever, so stopping. The program is untouched." >&2
  exit 1
fi
if [[ "$CONFIG_PRESENT" == "present" ]]; then
  CONFIG_ADMIN=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$AUTHORITY" "$RPC_URL" show 2>/dev/null \
    | awk '$1=="admin"{print $3}')
  [[ -n "$CONFIG_ADMIN" ]] || {
    echo "error: the config account $CONFIG_PDA exists but its admin could not be read — the RPC may be failing, or the deployed layout may differ. Stopping; the program is untouched." >&2
    exit 1
  }
  CB64=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$CONFIG_ADMIN" "$RPC_URL" close-config \
        | awk -F': *|:' '/^UNSIGNED_TX_B64:/ {print $2}')
  # Simulate first: skip gracefully (no scary popup) only if the deployed
  # program predates `close_config`. Any other outcome is not safe to skip,
  # because the program close below is irreversible.
  SIM=$(curl -s "$RPC_URL" -X POST -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"simulateTransaction\",\"params\":[\"$CB64\",{\"sigVerify\":false,\"replaceRecentBlockhash\":true,\"encoding\":\"base64\",\"commitment\":\"confirmed\"}]}" \
    | python3 -c '
import json, sys
try:
    value = json.load(sys.stdin)["result"]["value"]
except Exception:
    print("unreadable"); raise SystemExit
if not isinstance(value, dict) or "err" not in value:
    print("unreadable"); raise SystemExit
err = value["err"]
if err is None:
    print("ok"); raise SystemExit
code = None
if isinstance(err, dict) and isinstance(err.get("InstructionError"), list):
    detail = err["InstructionError"][1]
    if isinstance(detail, dict):
        code = detail.get("Custom")
print("no-close-config" if code == 101 else "failed " + json.dumps(err))
' 2>/dev/null) || SIM="unreadable"
  case "$SIM" in
    no-close-config)
      echo "config-rent reclaim unavailable (deployed program has no close_config) — skipping; ~0.0035 SOL orphaned." ;;
    ok) : ;;
    *)
      echo "error: the config close could not be simulated cleanly ($SIM). Closing the program now would leave the live Config account unclosable forever, so stopping. The program is untouched." >&2
      exit 1 ;;
  esac
  if [[ "$SIM" == "ok" ]]; then
    echo "reclaiming config rent (admin $CONFIG_ADMIN)..."
    if CSIG=$(python3 scripts/sign_in_browser.py "$CB64" "$CONFIG_ADMIN"); then
      echo "config close signature: $CSIG"
      CONFIRM_RC=0; confirm_signature "$CSIG" "$URL" finalized || CONFIRM_RC=$?
      if (( CONFIRM_RC == 2 )); then
        echo "error: the config close outcome is UNKNOWN — look up $CSIG before doing anything else. Stopping; the program is untouched." >&2
        exit 1
      elif (( CONFIRM_RC != 0 )); then
        echo "error: the config close did not land. Closing the program now would leave the Config account owned by a program that no longer exists — unclosable forever. Stopping; the program is untouched, so re-run once the config close is finalized." >&2
        exit 1
      fi
    else
      echo "error: config close not signed. Closing the program now would leave the Config account unclosable forever. Stopping; the program is untouched." >&2
      exit 1
    fi
  fi
else
  echo "no config account on-chain at $CONFIG_PDA — skipping config-rent reclaim."
fi

while true; do
  B64=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$AUTHORITY" "$RPC_URL" close "$RECIPIENT" \
        | awk -F': *|:' '/^UNSIGNED_TX_B64:/ {print $2}')
  [[ -n "$B64" ]] || { echo "error: could not build the close transaction" >&2; exit 1; }
  if SIG=$(python3 scripts/sign_in_browser.py "$B64" "$AUTHORITY"); then
    echo "close signature: $SIG"
    CONFIRM_RC=0; confirm_signature "$SIG" "$URL" finalized || CONFIRM_RC=$?
    if (( CONFIRM_RC == 2 )); then
      echo "error: the program close outcome is UNKNOWN — look up $SIG. Do NOT re-run until you know: PROGRAM_ID is still pinned in scripts/envs/$ENV.env, and re-running on a closed program would mint a second one." >&2
      exit 1
    elif (( CONFIRM_RC != 0 )); then
      echo "error: the program close was not finalized — check $SIG before re-running." >&2
      exit 1
    fi
    break
  fi
  echo
  read -rp "Not signed (rejected or blockhash expired). Retry with a fresh transaction? [y/N] " AGAIN
  [[ "$AGAIN" == "y" || "$AGAIN" == "Y" ]] || { echo "aborted"; exit 1; }
done

UNPINNED=$(mktemp "scripts/envs/.$ENV.env.XXXXXX") || {
  echo "error: the program IS closed, but no temporary file could be created next to scripts/envs/$ENV.env — the file is unchanged; delete the PROGRAM_ID line by hand before the next deploy." >&2
  exit 1
}
sed -e '/^PROGRAM_ID=/d' \
  -e '/^# \^ the smart contract address/d' \
  -e '/^#   SolanaSubscription.*SmartContractAddress/d' \
  -e '/^# The backend derives the MeshDelegate PDA/d' \
  -e '/^# value\. Informational, for cross-checking/d' \
  -e '/^# becomes the .delegatee. recorded/d' \
  -e '/^# MeshDelegate PDA = /d' \
  "scripts/envs/$ENV.env" > "$UNPINNED" \
  && mv "$UNPINNED" "scripts/envs/$ENV.env" \
  || {
    rm -f "$UNPINNED"
    echo "error: the program IS closed, but PROGRAM_ID could not be unpinned from scripts/envs/$ENV.env — the file is unchanged; delete the PROGRAM_ID line by hand before the next deploy." >&2
    exit 1
  }
echo "Done. Rent refunded to $RECIPIENT."
echo "Unpinned the burned PROGRAM_ID from scripts/envs/$ENV.env — the next deploy mints a fresh id/PDA."
