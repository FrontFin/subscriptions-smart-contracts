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

solana program deploy "$ARTIFACT" \
  --program-id "$PROGRAM_KP" \
  --keypair "$PAYER_FILE" \
  --max-len "$MAX_LEN" \
  --url "$URL"

solana program set-upgrade-authority "$PROGRAM_ID" \
  --keypair "$PAYER_FILE" \
  --new-upgrade-authority "$UPGRADE_AUTHORITY" \
  --skip-new-upgrade-authority-signer-check \
  --url "$URL"

# Record the deployed ID before another step can abort and delete the throwaway key.
PDA=$(python3 scripts/derive_pda.py "$PROGRAM_ID")
{
  echo "PROGRAM_ID=$PROGRAM_ID"
  echo "# ^ the smart contract address. Set BOTH backend settings to it (same value):"
  echo "#   SolanaSubscriptionConfig--SmartContractAddress        (Core API app)"
  echo "#   SolanaSubscriptionPullerConfig--SmartContractAddress  (Backend Functions app)"
  echo "# The backend derives the MeshDelegate PDA from it by itself — not a config"
  echo "# value. Informational, for cross-checking the backend's derivation; this PDA"
  echo "# becomes the 'delegatee' recorded on each subscription (DB row + on-chain):"
  echo "# MeshDelegate PDA = $PDA"
} >> "$ENV_FILE"
echo "pinned PROGRAM_ID=$PROGRAM_ID into $ENV_FILE (the throwaway program key is discarded on exit)"

INITIALIZED=false
while true; do
  # shellcheck disable=SC2086 — KEYS is intentionally word-split
  B64=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$UPGRADE_AUTHORITY" "$RPC_URL" keys $KEYS \
        | awk -F': *|:' '/^UNSIGNED_TX_B64:/ {print $2}')
  [[ -n "$B64" ]] || { echo "error: could not build the initialize transaction" >&2; break; }
  if SIG=$(python3 scripts/sign_in_browser.py "$B64" "$UPGRADE_AUTHORITY"); then
    echo "config initialized: $SIG"
    INITIALIZED=true
    break
  fi
  read -rp "Config not initialized (rejected or blockhash expired). Retry? [y/N] " AGAIN
  [[ "$AGAIN" == "y" || "$AGAIN" == "Y" ]] || break
done
$INITIALIZED || echo "⚠️  Config NOT initialized — pulls will fail until you run: scripts/set-puller-keys.sh $ENV" >&2

if $INITIALIZED; then
  # Allow read failures to reach the recovery warning instead of exiting under set -e.
  ON_CHAIN_ADMIN=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$UPGRADE_AUTHORITY" "$RPC_URL" show \
    | awk '$1=="admin"{print $3}' || true)
  if [[ -z "$ON_CHAIN_ADMIN" ]]; then
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
