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

if [[ "$MODE" == "--print" ]]; then
  # print mode cannot build close_config without a config, and would abort the
  # whole script under set -e. The program close does not depend on it.
  SHOW_OUT=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "print:$AUTHORITY" "$RPC_URL" show 2>&1) || {
    echo "error: could not read the on-chain config — cannot tell whether one" >&2
    echo "exists, so the teardown order is unknown. Retry when the RPC answers:" >&2
    echo "$SHOW_OUT" >&2
    exit 1
  }
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

# Close config before the program to recover its rent; its admin may differ from upgrade authority.
CONFIG_ADMIN=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$AUTHORITY" "$RPC_URL" show 2>/dev/null \
  | awk '$1=="admin"{print $3}')
if [[ -n "$CONFIG_ADMIN" ]]; then
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
  # Simulate at the same commitment admin-cli builds against. At the RPC's
  # default of finalized, a program deployed or upgraded minutes ago still
  # simulates as its previous binary, which would read as 'legacy'.
  SIM_JSON=$(curl -sS "$RPC_URL" -X POST -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"simulateTransaction\",\"params\":[\"$CB64\",{\"sigVerify\":false,\"replaceRecentBlockhash\":true,\"encoding\":\"base64\",\"commitment\":\"confirmed\"}]}") \
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
  || ! grep -qiE 'has been closed|unable to find|does not exist|no account' <<<"$SHOW_STATE"; then
  echo "error: could not confirm that $PROGRAM_ID is closed." >&2
  echo "PROGRAM_ID stays in scripts/envs/$ENV.env — erasing it while the program" >&2
  echo "may still be live would lose the only record of its address." >&2
  echo "Check signature $SIG, then rerun. The reader said:" >&2
  echo "$SHOW_STATE" >&2
  exit 1
fi

# Rename a sibling temp file atomically, preserving the original mode and avoiding truncation.
SCRUBBED=$(mktemp "scripts/envs/.$ENV.env.tmp.XXXXXX")
trap 'rm -f "$SCRUBBED"' EXIT
chmod --reference="scripts/envs/$ENV.env" "$SCRUBBED" 2>/dev/null || chmod 644 "$SCRUBBED"
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
