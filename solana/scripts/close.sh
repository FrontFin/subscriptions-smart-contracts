#!/usr/bin/env bash
# Closing burns the program ID; redeployment changes the PDA and invalidates old delegations.
# Usage: scripts/close.sh <local|dev|prod> [recipient-pubkey|--print]
# Default: browser signing. --print: Squads instruction for a vault admin.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_env.sh

ENV="${1:?usage: scripts/close.sh <local|dev|prod> [recipient-pubkey|--print]}"
[[ "$ENV" != "test" ]] || { echo "error: 'test' is the LiteSVM fixture — nothing on-chain to close" >&2; exit 1; }
PROGRAM_ID=$(env_program_id "$ENV")
AUTHORITY=$(env_upgrade_authority "$ENV")
URL="mainnet-beta"
RPC_URL="https://api.mainnet-beta.solana.com"

RECIPIENT="$AUTHORITY"
MODE=""
case "${2:-}" in
  "") ;;
  --print) MODE="--print" ;;
  --*) echo "error: unknown option $2 (expected --print)" >&2; exit 1 ;;
  *) RECIPIENT="$2" ;;
esac
# admin-cli only parses the recipient when it builds the loader Close, which is
# after close_config has already run. A malformed one would abort a teardown
# that is half done.
require_pubkey "$RECIPIENT" "refund recipient" || exit 1

if [[ "$MODE" == "--print" ]]; then
  # print mode cannot build close_config without a config, and would abort the
  # whole script under set -e. The program close does not depend on it.
  SHOW_OUT=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "print:$AUTHORITY" "$RPC_URL" show 2>&1) || {
    echo "error: could not read the on-chain config — cannot tell whether one" >&2
    echo "exists, so the teardown order is unknown. Retry when the RPC answers:" >&2
    echo "$SHOW_OUT" >&2
    exit 1
  }
  # A close_config that is guaranteed to fail must not be printed above an
  # irreversible loader Close: an operator who runs step 2 after step 1 failed
  # burns the program and strands the config rent for good.
  if grep -q '^ *pending admin' <<<"$SHOW_OUT"; then
    echo "error: an admin handover is pending on $PROGRAM_ID." >&2
    grep '^ *pending admin' <<<"$SHOW_OUT" >&2
    echo "close_config is blocked while it is, so the first teardown instruction" >&2
    echo "would fail and the second would burn the program with the config still" >&2
    echo "on chain. Complete or cancel the handover, then rerun. Nothing printed." >&2
    exit 1
  fi
  if awk '$1=="admin"{found=1} END{exit !found}' <<<"$SHOW_OUT"; then
    echo "=== 1/2 close_config — reclaims the config rent ==="
    cargo run -q -p admin-cli -- "$PROGRAM_ID" print "$RPC_URL" close-config
  else
    echo "=== 1/2 close_config — SKIP, no config account on chain ==="
  fi
  echo
  echo "=== 2/2 loader Close — burns $PROGRAM_ID, refunds its rent ==="
  cargo run -q -p admin-cli -- "$PROGRAM_ID" "print:$AUTHORITY" "$RPC_URL" close "$RECIPIENT"
  echo
  echo "Execute them in Squads IN THIS ORDER. Closing the program first strands"
  echo "the config rent, because the config can only be closed by its own program."
  echo "⚠️  Step 2 is irreversible: the program id can never be redeployed."
  echo
  echo "Afterwards, delete the PROGRAM_ID line and the comment block under it"
  echo "from scripts/envs/$ENV.env, so the next deploy mints a fresh id."
  exit 0
fi

# Both signers below sign in a browser wallet, so neither may be a program
# address such as a Squads vault. Checked before anything is destroyed.
AUTHORITY_KIND=$(key_kind "$AUTHORITY" "upgrade authority") || exit 1
if [[ "$AUTHORITY_KIND" != "wallet" ]]; then
  echo "error: upgrade authority $AUTHORITY is a program address, not a wallet." >&2
  echo "It cannot pay a fee or sign in the browser, so this script cannot burn" >&2
  echo "the program id directly. Run 'scripts/close.sh $ENV --print' and execute" >&2
  echo "both printed instructions in Squads instead." >&2
  exit 1
fi

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
config_account_state() {
  curl -s "$RPC_URL" -X POST -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccountInfo\",\"params\":[\"$CONFIG_PDA\",{\"encoding\":\"base64\",\"commitment\":\"$1\"}]}" \
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
' 2>/dev/null || echo "unreadable"
}
# Absence has to hold on both views: the confirmed fork can still roll back,
# and the finalized view can lag behind an account this deploy just created.
CONFIG_AT_CONFIRMED=$(config_account_state confirmed)
CONFIG_AT_FINALIZED=$(config_account_state finalized)
if [[ "$CONFIG_AT_CONFIRMED" == "unreadable" || "$CONFIG_AT_FINALIZED" == "unreadable" ]]; then
  echo "error: could not read the config account $CONFIG_PDA (confirmed=$CONFIG_AT_CONFIRMED finalized=$CONFIG_AT_FINALIZED). Closing the program without knowing whether a live Config exists could orphan it forever, so stopping. The program is untouched." >&2
  exit 1
fi
if [[ "$CONFIG_AT_CONFIRMED" == "absent" && "$CONFIG_AT_FINALIZED" == "absent" ]]; then
  CONFIG_PRESENT="absent"
else
  CONFIG_PRESENT="present"
fi
if [[ "$CONFIG_PRESENT" == "present" ]]; then
  CONFIG_ADMIN=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$AUTHORITY" "$RPC_URL" show 2>/dev/null \
    | awk '$1=="admin"{print $3}')
  [[ -n "$CONFIG_ADMIN" ]] || {
    echo "error: the config account $CONFIG_PDA exists but its admin could not be read — the RPC may be failing, or the deployed layout may differ. Stopping; the program is untouched." >&2
    exit 1
  }
  CONFIG_ADMIN_KIND=$(key_kind "$CONFIG_ADMIN" "config admin") || exit 1
  if [[ "$CONFIG_ADMIN_KIND" != "wallet" ]]; then
    echo "error: config admin $CONFIG_ADMIN is a program address, not a wallet" >&2
    echo "(a Squads vault, for example). It can neither pay the fee nor sign in" >&2
    echo "the browser, so the config rent cannot be reclaimed this way." >&2
    echo "Run 'scripts/close.sh $ENV --print' and execute the printed instruction" >&2
    echo "in Squads, then rerun this script. Nothing has been destroyed." >&2
    exit 1
  fi
  CB64=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$CONFIG_ADMIN" "$RPC_URL" close-config \
        | awk -F': *|:' '/^UNSIGNED_TX_B64:/ {print $2}')
  [[ -n "$CB64" ]] || { echo "error: could not build the close-config transaction" >&2; exit 1; }
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

# Scrub only on a positive "the account is gone". solana program show also
# exits non-zero when it cannot reach the RPC, and treating that as proof of
# closure would erase the only record of a program that is still live.
SHOW_STATE=$(solana program show "$PROGRAM_ID" --url "$URL" 2>&1) && SHOW_OK=true || SHOW_OK=false
if $SHOW_OK; then
  echo "error: $PROGRAM_ID is still live on-chain — the close did not take effect." >&2
  echo "PROGRAM_ID stays in scripts/envs/$ENV.env so the next deploy cannot mint a second id." >&2
  echo "Check signature $SIG, then rerun this script." >&2
  exit 1
fi
# The absence phrase alone is not enough: an RPC or proxy error can carry the
# same words. A genuine account-absent answer names this program id, and a
# gateway failure does not.
if ! grep -q -- "$PROGRAM_ID" <<<"$SHOW_STATE" \
  || ! grep -qiE 'has been closed|accountnotfound|not found|unable to find|does not exist' <<<"$SHOW_STATE"; then
  echo "error: could not confirm that $PROGRAM_ID is closed." >&2
  echo "PROGRAM_ID stays in scripts/envs/$ENV.env — erasing it while the program" >&2
  echo "may still be live would lose the only record of its address." >&2
  echo "Check signature $SIG, then rerun. The reader said:" >&2
  echo "$SHOW_STATE" >&2
  exit 1
fi

# Rename a sibling temp file atomically, preserving the original mode and avoiding truncation.
SCRUBBED=$(mktemp "scripts/envs/.$ENV.env.XXXXXX") || {
  echo "error: the program IS closed, but no temporary file could be created next to scripts/envs/$ENV.env — the file is unchanged; delete the PROGRAM_ID line by hand before the next deploy." >&2
  exit 1
}
trap 'rm -f "$SCRUBBED"' EXIT
# chmod --reference is GNU-only, and hardcoding a fallback would widen a
# private env file. Read the mode the way the rest of these scripts read sizes.
ENV_MODE=$(stat -f%Lp "scripts/envs/$ENV.env" 2>/dev/null || stat -c%a "scripts/envs/$ENV.env")
chmod "$ENV_MODE" "$SCRUBBED"
sed \
  -e '/^PROGRAM_ID=/d' \
  -e '/^# \^ the smart contract address/d' \
  -e '/^#   SolanaSubscription.*SmartContractAddress/d' \
  -e '/^# The backend derives the MeshDelegate PDA/d' \
  -e '/^# value\. Informational, for cross-checking/d' \
  -e '/^# becomes the .delegatee. recorded/d' \
  -e '/^# MeshDelegate PDA = /d' \
  "scripts/envs/$ENV.env" > "$SCRUBBED" \
  && mv "$SCRUBBED" "scripts/envs/$ENV.env" \
  || {
    rm -f "$SCRUBBED"
    echo "error: the program IS closed, but PROGRAM_ID could not be unpinned from scripts/envs/$ENV.env — the file is unchanged; delete the PROGRAM_ID line by hand before the next deploy." >&2
    exit 1
  }
echo "Done. Rent refunded to $RECIPIENT."
echo "Unpinned the burned PROGRAM_ID from scripts/envs/$ENV.env — the next deploy mints a fresh id/PDA."
