#!/usr/bin/env bash
# First deploy: browser signs funding and config initialization. Later updates use upgrade.sh.
# Usage: scripts/deploy.sh <local|dev|prod> [FEE_PAYER=<path> override]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_ephemeral.sh
source scripts/_env.sh

ENV="${1:?usage: scripts/deploy.sh <local|dev|prod>}"
[[ "$ENV" != "test" ]] || { echo "error: 'test' is the LiteSVM fixture — never deployable (its puller keys are publicly derivable)" >&2; exit 1; }
ENV_FILE=$(env_file "$ENV")
UPGRADE_AUTHORITY=$(env_upgrade_authority "$ENV")
require_pubkey "$UPGRADE_AUTHORITY" "UPGRADE_AUTHORITY in $ENV_FILE" || exit 1
# A first deploy needs this key to sign in the browser, both to fund the payer
# and to initialize the config. A program address cannot, so with a FEE_PAYER
# override the deploy would pin a program and then fail at initialization,
# leaving a live program with no way to create its config.
AUTHORITY_KIND=$(key_kind "$UPGRADE_AUTHORITY" "UPGRADE_AUTHORITY") || exit 1
if [[ "$AUTHORITY_KIND" != "wallet" ]]; then
  echo "error: UPGRADE_AUTHORITY in $ENV_FILE is $UPGRADE_AUTHORITY, a program" >&2
  echo "address. It cannot sign, so this deploy would strand an initialized-less" >&2
  echo "program. Deploy with a wallet, then hand over with migrate-to-squads.sh." >&2
  exit 1
fi
URL="mainnet-beta"
RPC_URL="https://api.mainnet-beta.solana.com"

# Empty PULLER_KEYS is the kill switch; a missing entry is a configuration error.
grep -q '^PULLER_KEYS=' "$ENV_FILE" || {
  echo "error: PULLER_KEYS is not set in $ENV_FILE — set it before deploying" >&2
  echo "(an explicit PULLER_KEYS=\"\" is the kill switch; a missing line is treated as a mistake)" >&2
  exit 1
}
KEYS=$(grep '^PULLER_KEYS=' "$ENV_FILE" | cut -d= -f2- | tr -d '"')
if [[ -z "${KEYS// /}" ]]; then
  echo "⚠️  PULLER_KEYS is EMPTY — the on-chain config will be initialized to the kill switch: no key can pull." >&2
fi

if PROGRAM_ID=$(env_program_id "$ENV" 2>/dev/null); then
  if solana program show "$PROGRAM_ID" --url "$URL" >/dev/null 2>&1; then
    echo "error: $ENV is already deployed at $PROGRAM_ID — code changes use scripts/upgrade.sh $ENV" >&2
    exit 1
  fi
  echo "error: PROGRAM_ID $PROGRAM_ID is pinned in $ENV_FILE but no program exists there on-chain." >&2
  echo "Its private key was never stored, so that id cannot be claimed anymore." >&2
  echo "Remove the PROGRAM_ID line (and the comments under it) from $ENV_FILE and re-run to mint a fresh id." >&2
  exit 1
fi

# The program key is discarded after deploy; its public address remains permanent.
PROGRAM_KP=$(mktemp)
chmod 600 "$PROGRAM_KP"
SECRET_TMPFILES+=("$PROGRAM_KP")
solana-keygen new --no-bip39-passphrase --silent --force -o "$PROGRAM_KP" >&2
PROGRAM_ID=$(solana-keygen pubkey "$PROGRAM_KP")

scripts/build.sh "$ENV" "$PROGRAM_ID"
ARTIFACT="target/deploy-$ENV/subscription_controller.so"
SIZE=$(stat -f%z "$ARTIFACT" 2>/dev/null || stat -c%s "$ARTIFACT")
# Reserve 20% headroom to avoid extending the account on small upgrades.
MAX_LEN=$(python3 -c "print(int($SIZE * 12 // 10))")
# Program rent stays locked until close; the remainder covers fees.
FUND_LAMPORTS=$(python3 -c "print(($MAX_LEN + 200) * 6960 + 30_000_000)")

echo "environment       : $ENV (FIRST deploy, browser-signed — two wallet popups)"
echo "authority wallet  : $UPGRADE_AUTHORITY (funds the deploy; becomes upgrade authority + config admin)"
echo "program id        : $PROGRAM_ID (minted now, permanent)"
echo "artifact          : $ARTIFACT ($SIZE bytes; allocated $MAX_LEN with 20% headroom)"
echo "sha256            : $(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
echo "puller keys       : ${KEYS:-<EMPTY — kill switch>}"
echo "working capital   : ~$(python3 -c "print(f'{$FUND_LAMPORTS/1e9:.3f}')") SOL from the wallet (rent deposit stays with the program; the rest sweeps back)"
echo
read -rp "Deploy '$ENV' to MAINNET now? Type 'deploy' to proceed: " CONFIRM
[[ "$CONFIRM" == "deploy" ]] || { echo "aborted"; exit 1; }

ephemeral_payer "$UPGRADE_AUTHORITY" "$FUND_LAMPORTS" "$RPC_URL"

# From here on the deploy can create the program at any moment, and until the
# handover is confirmed the temporary payer is its only upgrade authority. The
# trap has to be in place BEFORE the deploy starts: a Ctrl-C partway through it
# would otherwise reach _eph_cleanup, which sweeps and deletes that key.
AUTHORITY_MOVED=false
_deploy_cleanup() {
  if ! $AUTHORITY_MOVED && [[ -z "${FEE_PAYER:-}" ]] && retain_ephemeral_payer; then
    echo >&2
    echo "⚠️  the temporary payer may be the upgrade authority of a program this run" >&2
    echo "   already created. Its key is kept at: $RETAINED_PAYER_FILE" >&2
    echo "   Without that key such a program can never be upgraded or closed." >&2
    echo "   Check with: solana program show $PROGRAM_ID --url $URL" >&2
    echo "   DELETE the file once you have confirmed it is not needed." >&2
  fi
  _eph_cleanup
}
# EXIT only — the INT/TERM handlers exit, which fires this. A signal trap that
# returns would let an interrupted deploy carry on past the operator's Ctrl-C.
trap _deploy_cleanup EXIT

if ! solana program deploy "$ARTIFACT" \
  --program-id "$PROGRAM_KP" \
  --keypair "$PAYER_FILE" \
  --max-len "$MAX_LEN" \
  --url "$URL"; then
  echo >&2
  echo "🛑 deploy failed." >&2
  if [[ -n "${FEE_PAYER:-}" ]]; then
    PAYER_PUBKEY=$(solana-keygen pubkey "$PAYER_FILE" 2>/dev/null) || PAYER_PUBKEY=""
    echo "   Its write buffer (if any) belongs to the FEE_PAYER override $PAYER_FILE," >&2
    echo "   which this script never closes or sweeps. Recover that rent yourself:" >&2
    echo "     solana program close --buffers -k $PAYER_FILE --authority $PAYER_FILE --recipient ${PAYER_PUBKEY:-<the fee payer address>} --url $URL" >&2
    [[ -z "$PAYER_PUBKEY" ]] || report_stray_buffers "$PAYER_PUBKEY" "$URL" \
      "solana program close --buffers -k $PAYER_FILE --authority $PAYER_FILE --recipient $PAYER_PUBKEY --url $URL"
  else
    echo "   Its write buffer (if any) belongs to the temporary payer and is closed on" >&2
    echo "   exit, so that rent comes back to $UPGRADE_AUTHORITY." >&2
    # deploy can create the program before it reports failure, and until the
    # handover runs the temporary payer is that program's upgrade authority —
    # the only key that can ever close it.
    if retain_ephemeral_payer; then
      echo "   The temporary payer key is kept at: $RETAINED_PAYER_FILE" >&2
      echo "   If $PROGRAM_ID reached the chain, that key is its upgrade authority and" >&2
      echo "   the only way to reclaim its rent. DELETE the file once you are done." >&2
    fi
  fi
  echo "   $ENV_FILE was NOT touched — re-running mints a fresh program id." >&2
  echo "   The program key is discarded on exit, so if $PROGRAM_ID was already created" >&2
  echo "   on chain it keeps the rent it holds." >&2
  exit 1
fi

# The program now exists on chain. Record its id before the handover, because
# every check after this point can abort, and the throwaway program key is
# discarded on exit — an unrecorded id is a live program nobody can find.
echo "PROGRAM_ID=$PROGRAM_ID" >> "$ENV_FILE"
echo "pinned PROGRAM_ID=$PROGRAM_ID into $ENV_FILE (the throwaway program key is discarded on exit)"

# This CLI transfer does not collect a destination signature.
HANDOVER_REPORTED_OK=true
solana program set-upgrade-authority "$PROGRAM_ID" \
  --keypair "$PAYER_FILE" \
  --new-upgrade-authority "$UPGRADE_AUTHORITY" \
  --skip-new-upgrade-authority-signer-check \
  --url "$URL" || HANDOVER_REPORTED_OK=false

# Read at the same commitment the deploy and handover were confirmed at.
# The CLI default is finalized, which lags and can still show the temporary
# payer after a handover that actually landed.
ON_CHAIN_UPGRADE_AUTHORITY=$(solana program show "$PROGRAM_ID" --url "$URL" --commitment confirmed 2>/dev/null \
  | awk '$1=="Authority:"{print $2}') || ON_CHAIN_UPGRADE_AUTHORITY=""
if [[ "$ON_CHAIN_UPGRADE_AUTHORITY" != "$UPGRADE_AUTHORITY" ]]; then
  PAYER_PUBKEY=$(solana-keygen pubkey "$PAYER_FILE" 2>/dev/null) || PAYER_PUBKEY=""
  KEPT_KEY="$PAYER_FILE"
  if [[ -z "${FEE_PAYER:-}" ]] && retain_ephemeral_payer; then
    KEPT_KEY="$RETAINED_PAYER_FILE"
  fi
  echo >&2
  echo "🛑 the upgrade authority handover did NOT take effect." >&2
  if $HANDOVER_REPORTED_OK; then
    echo "   The command reported success, but the program reads back with authority" >&2
    echo "   '${ON_CHAIN_UPGRADE_AUTHORITY:-<nothing — the read itself failed>}', not $UPGRADE_AUTHORITY." >&2
  else
    echo "   solana program set-upgrade-authority failed." >&2
  fi
  echo "   $PROGRAM_ID is deployed and ${PAYER_PUBKEY:-the temporary payer} is still the only" >&2
  echo "   key that can upgrade or close it, so that key is kept at:" >&2
  echo "     $KEPT_KEY" >&2
  # Only the temporary payer is swept on exit; a FEE_PAYER override is left
  # alone, and telling its operator to re-fund it would be wrong.
  if [[ -z "${FEE_PAYER:-}" ]]; then
    echo "   Its balance is swept back to $UPGRADE_AUTHORITY on exit, so fund it again first:" >&2
    [[ -z "$PAYER_PUBKEY" ]] || echo "     solana transfer $PAYER_PUBKEY 0.01 --url $URL" >&2
  else
    echo "   It is your FEE_PAYER override, so its balance is left untouched." >&2
  fi
  echo "   Then retry the handover:" >&2
  echo "     solana program set-upgrade-authority $PROGRAM_ID --keypair $KEPT_KEY \\" >&2
  echo "       --new-upgrade-authority $UPGRADE_AUTHORITY --skip-new-upgrade-authority-signer-check --url $URL" >&2
  echo "   Or take the rent back and start over with a fresh id:" >&2
  echo "     solana program close $PROGRAM_ID -k $KEPT_KEY --authority $KEPT_KEY --recipient $UPGRADE_AUTHORITY --url $URL" >&2
  echo "   DELETE that key file once one of those is done." >&2
  echo "   PROGRAM_ID=$PROGRAM_ID is already pinned in $ENV_FILE so the deployed id" >&2
  echo "   is not lost. Remove that line if you close the program instead." >&2
  exit 1
fi

# Read back above proves the authority moved, so the payer key no longer has
# to survive this run.
AUTHORITY_MOVED=true

PDA=$(python3 scripts/derive_pda.py "$PROGRAM_ID")
{
  echo "# ^ the smart contract address. Set BOTH backend settings to it (same value):"
  echo "#   SolanaSubscriptionConfig--SmartContractAddress        (Core API app)"
  echo "#   SolanaSubscriptionPullerConfig--SmartContractAddress  (Backend Functions app)"
  echo "# The backend derives the MeshDelegate PDA from it by itself — not a config"
  echo "# value. Informational, for cross-checking the backend's derivation; this PDA"
  echo "# becomes the 'delegatee' recorded on each subscription (DB row + on-chain):"
  echo "# MeshDelegate PDA = $PDA"
} >> "$ENV_FILE"

INITIALIZED=false
INIT_UNKNOWN=""
while true; do
  # shellcheck disable=SC2086 — KEYS is intentionally word-split
  B64=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$UPGRADE_AUTHORITY" "$RPC_URL" keys $KEYS \
        | awk -F': *|:' '/^UNSIGNED_TX_B64:/ {print $2}')
  [[ -n "$B64" ]] || { echo "error: could not build the initialize transaction" >&2; break; }
  if SIG=$(python3 scripts/sign_in_browser.py "$B64" "$UPGRADE_AUTHORITY"); then
    echo "initialize signature: $SIG"
    CONFIRM_RC=0; confirm_signature "$SIG" "$URL" || CONFIRM_RC=$?
    if (( CONFIRM_RC == 0 )); then
      INITIALIZED=true
      break
    fi
    if (( CONFIRM_RC == 2 )); then
      INIT_UNKNOWN=$SIG
      break
    fi
  fi
  read -rp "Config not initialized (rejected or blockhash expired). Retry? [y/N] " AGAIN
  [[ "$AGAIN" == "y" || "$AGAIN" == "Y" ]] || break
done
$INITIALIZED || echo "⚠️  Config NOT initialized — pulls will fail until you run: scripts/set-puller-keys.sh $ENV" >&2

# A deployed program with no Config is not a finished deploy either, so an
# abandoned or rejected initialization has to fail the same way an unreadable
# admin does.
ADMIN_UNVERIFIED=true
if $INITIALIZED; then
  ADMIN_UNVERIFIED=false
  # Allow read failures to reach the recovery warning instead of exiting under set -e.
  ON_CHAIN_ADMIN=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$UPGRADE_AUTHORITY" "$RPC_URL" show \
    | awk '$1=="admin"{print $3}' || true)
  if [[ -z "$ON_CHAIN_ADMIN" ]]; then
    ADMIN_UNVERIFIED=true
    echo "⚠️  could not read the config admin back — the read failed or returned" >&2
    echo "   nothing (RPC error, admin-cli build failure, or unexpected output)." >&2
    echo "   PROGRAM_ID is already pinned in $ENV_FILE; verify before wiring the backend:" >&2
    echo "   cargo run -p admin-cli -- $PROGRAM_ID tx:$UPGRADE_AUTHORITY $RPC_URL show" >&2
  elif [[ "$ON_CHAIN_ADMIN" != "$UPGRADE_AUTHORITY" ]]; then
    echo "🛑 config admin is $ON_CHAIN_ADMIN, expected $UPGRADE_AUTHORITY — initialize was front-run." >&2
    echo "   Do NOT wire the backend to $PROGRAM_ID. Close it (scripts/close.sh $ENV) and redeploy for a fresh id." >&2
    exit 1
  else
    echo "verified: config admin = $UPGRADE_AUTHORITY"
  fi
fi

echo
echo "Backend configuration for '$ENV':"
echo "  Smart contract address (program id) : $PROGRAM_ID"
echo "      → set BOTH (same value): SolanaSubscriptionConfig--SmartContractAddress (Core API)"
echo "        and SolanaSubscriptionPullerConfig--SmartContractAddress (Backend Functions)"
echo "  MeshDelegate PDA (informational)    : $PDA"
echo "      → derived by the backend itself from the contract address; becomes the"
echo "        'delegatee' recorded on each subscription (DB row + on-chain delegation)"

if ! $INITIALIZED; then
  echo >&2
  echo "🛑 PARTIAL DEPLOY: the program is live at $PROGRAM_ID and pinned in $ENV_FILE." >&2
  if [[ -n "$INIT_UNKNOWN" ]]; then
    echo "   The initialize transaction's outcome is UNKNOWN — the RPC never answered." >&2
    echo "   Look up $INIT_UNKNOWN first. Running set-puller-keys.sh before you know" >&2
    echo "   whether it landed can initialize the config a second time." >&2
  else
    echo "   Its Config was never initialized, so every pull will fail." >&2
    echo "   Finish it with: scripts/set-puller-keys.sh $ENV" >&2
  fi
  exit 1
fi

# The address above is printed so nothing is lost, but the deploy is not proven
# until the admin reads back. Exit non-zero so automation cannot treat an
# unverified config as a finished deploy.
if $ADMIN_UNVERIFIED; then
  echo >&2
  echo "🛑 exiting non-zero: the config admin was never verified (see the warning" >&2
  echo "   above). Re-run the printed 'show' command before wiring the backend." >&2
  exit 1
fi
