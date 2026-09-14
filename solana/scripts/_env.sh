# Sourced helper — environment resolution for build/deploy/close scripts.
#
# Environments live in scripts/envs/<env>.env (puller keys) plus a per-env
# program keypair scripts/envs/<env>-program-keypair.json (gitignored; local
# pins PROGRAM_ID in its env file instead). Different program keypair per
# env → different program ID → different MeshDelegate PDA, so local/dev/prod
# coexist on mainnet without touching each other.

CONFIRM_ATTEMPTS="${CONFIRM_ATTEMPTS:-20}"
CONFIRM_DELAY_SECONDS="${CONFIRM_DELAY_SECONDS:-3}"

confirm_signature() {
  local signature="$1" url="$2" attempt=1 verdict
  while true; do
    verdict=$(solana confirm "$signature" --url "$url" --output json 2>/dev/null | python3 -c '
import json, sys
try:
    result = json.load(sys.stdin)
except Exception:
    print("pending"); raise SystemExit
if result.get("err") is not None:
    print("failed", json.dumps(result["err"])); raise SystemExit
print("landed" if result.get("confirmationStatus") in ("confirmed", "finalized") else "pending")
') || verdict="pending"
    case "$verdict" in
      landed)
        echo "confirmed on chain: $signature"
        return 0 ;;
      failed*)
        echo "error: $signature landed but FAILED on chain: ${verdict#failed }" >&2
        return 1 ;;
    esac
    if (( attempt >= CONFIRM_ATTEMPTS )); then
      echo "error: $signature did not confirm after $CONFIRM_ATTEMPTS checks over $(( CONFIRM_ATTEMPTS * CONFIRM_DELAY_SECONDS ))s — it was dropped, or the wallet page reported a signature that was never sent" >&2
      return 1
    fi
    attempt=$(( attempt + 1 ))
    sleep "$CONFIRM_DELAY_SECONDS"
  done
}

env_file() {
  local env="$1" f="scripts/envs/$1.env"
  [[ -f "$f" ]] || { echo "error: unknown environment '$env' ($f not found)" >&2; return 1; }
  echo "$f"
}

# Prints the env's upgrade-authority pubkey (public; the private key is
# prompted at deploy/close time, never stored).
env_upgrade_authority() {
  local f; f=$(env_file "$1") || return 1
  local ua
  ua=$(grep '^UPGRADE_AUTHORITY=' "$f" | cut -d= -f2 || true)
  [[ -n "$ua" ]] || { echo "error: no UPGRADE_AUTHORITY in $f" >&2; return 1; }
  echo "$ua"
}

# Prints the env's program id — the PUBLIC value pinned as PROGRAM_ID in the
# env file. No program keypair is ever stored: deploy.sh mints a throwaway
# keypair at the env's FIRST deploy, pins the resulting id here, and discards
# the secret. Until that first deploy the env simply has no id.
env_program_id() {
  local f; f=$(env_file "$1") || return 1
  local pinned
  pinned=$(grep '^PROGRAM_ID=' "$f" | cut -d= -f2 || true)
  [[ -n "$pinned" ]] || {
    echo "error: no PROGRAM_ID pinned in $f — it is minted and pinned at the env's first deploy (scripts/deploy.sh $1)" >&2
    return 1
  }
  echo "$pinned"
}
