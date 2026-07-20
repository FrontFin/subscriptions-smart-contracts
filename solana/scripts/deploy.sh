#!/usr/bin/env bash
# Build + deploy one environment to mainnet. Prompts for the upgrade-
# authority wallet's secret key on every run (hidden input, held only in a
# temp file deleted on exit; the PUBLIC key is pinned as UPGRADE_AUTHORITY in
# the env's .env). The wallet is BOTH the fee payer and the upgrade authority
# for that env's program.
#
# Environments (scripts/envs/<env>.env): each has its own puller keys and its
# own program id → own MeshDelegate PDA. `test` is the LiteSVM fixture and
# cannot be deployed; local/dev/prod are real mainnet instances.
#
# Usage: scripts/deploy.sh <local|dev|prod>
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_wallet.sh
source scripts/_env.sh

ENV="${1:?usage: scripts/deploy.sh <local|dev|prod>}"
[[ "$ENV" != "test" ]] || { echo "error: 'test' is the LiteSVM fixture — never deployable (its puller keys are publicly derivable)" >&2; exit 1; }
ENV_FILE=$(env_file "$ENV")
UPGRADE_AUTHORITY=$(env_upgrade_authority "$ENV")
URL="mainnet-beta"

# The .env must be configured before deploying. A PULLER_KEYS line must be
# present — an explicitly EMPTY value ("") is the intentional kill switch,
# but a missing line is a misconfiguration.
grep -q '^PULLER_KEYS=' "$ENV_FILE" || {
  echo "error: PULLER_KEYS is not set in $ENV_FILE — set it before deploying" >&2
  echo "(an explicit PULLER_KEYS=\"\" is the kill switch; a missing line is treated as a mistake)" >&2
  exit 1
}
if [[ -z "$(grep '^PULLER_KEYS=' "$ENV_FILE" | cut -d= -f2- | tr -d '"[:space:]')" ]]; then
  echo "⚠️  PULLER_KEYS is EMPTY — the on-chain config will be set to EMPTY (kill switch): no key can pull." >&2
fi

# No program keypair is ever stored. Three cases:
#  - PROGRAM_ID pinned + program on-chain  → upgrade (wallet key only);
#  - no PROGRAM_ID pinned                  → FIRST deploy: mint a throwaway
#    keypair (temp file, discarded on exit), pin the id after success;
#  - PROGRAM_ID pinned but NOT on-chain    → a previous first deploy never
#    landed; a fresh id must be minted — remove the PROGRAM_ID line to retry.
MINTED=false
if PROGRAM_ID=$(env_program_id "$ENV" 2>/dev/null); then
  if solana program show "$PROGRAM_ID" --url "$URL" >/dev/null 2>&1; then
    DEPLOY_KIND="upgrade"
    PROGRAM_ID_ARG="$PROGRAM_ID"
  else
    echo "error: PROGRAM_ID $PROGRAM_ID is pinned in $ENV_FILE but no program exists there on-chain." >&2
    echo "Its private key was never stored, so that id cannot be claimed anymore." >&2
    echo "Remove the PROGRAM_ID line (and the MESH_DELEGATE comment) from $ENV_FILE and re-run to mint a fresh id." >&2
    exit 1
  fi
else
  DEPLOY_KIND="first deploy (minting a new program id)"
  MINTED=true
  PROGRAM_ID_ARG=$(mktemp)
  chmod 600 "$PROGRAM_ID_ARG"
  SECRET_TMPFILES+=("$PROGRAM_ID_ARG")
  solana-keygen new --no-bip39-passphrase --silent --force -o "$PROGRAM_ID_ARG" >&2
  PROGRAM_ID=$(solana-keygen pubkey "$PROGRAM_ID_ARG")
fi

scripts/build.sh "$ENV" "$PROGRAM_ID"
ARTIFACT="target/deploy-$ENV/subscription_controller.so"

prompt_wallet "$UPGRADE_AUTHORITY"
PAYER=$(solana-keygen pubkey "$WALLET")
SIZE=$(stat -f%z "$ARTIFACT" 2>/dev/null || stat -c%s "$ARTIFACT")
BALANCE=$(solana balance "$PAYER" -u "$URL" | awk '{print $1}')

# On upgrades a bigger binary needs the on-chain allocation extended first —
# and the loader refuses extensions smaller than 10240 bytes.
GROW=0
if [[ "$DEPLOY_KIND" == "upgrade" ]]; then
  CURRENT_LEN=$(solana program show "$PROGRAM_ID" --url "$URL" | awk '/Data Length/ {print $3}')
  if (( SIZE > CURRENT_LEN )); then
    GROW=$(( SIZE - CURRENT_LEN ))
    (( GROW < 10240 )) && GROW=10240
  fi
fi

echo "environment               : $ENV ($DEPLOY_KIND)"
echo "payer / upgrade authority : $PAYER (balance: $BALANCE SOL)"
echo "program id                : $PROGRAM_ID"
echo "artifact                  : $ARTIFACT ($SIZE bytes, exact max-len — extend later via 'solana program extend')"
echo "sha256                    : $(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
echo "puller keys               : $(grep '^PULLER_KEYS=' "scripts/envs/$ENV.env" | cut -d= -f2)"
if (( GROW > 0 )); then
  echo "allocation                : binary grew ($CURRENT_LEN → $SIZE bytes) — will extend by $GROW bytes first (~$(python3 -c "print(f'{$GROW*6960/1e9:.4f}')") SOL added to the rent deposit, refunded on close)"
fi
echo
read -rp "Deploy '$ENV' to MAINNET now? Type 'deploy' to proceed: " CONFIRM
[[ "$CONFIRM" == "deploy" ]] || { echo "aborted"; exit 1; }

if (( GROW > 0 )); then
  solana program extend "$PROGRAM_ID" "$GROW" --keypair "$WALLET" --url "$URL"
fi

solana program deploy "$ARTIFACT" \
  --program-id "$PROGRAM_ID_ARG" \
  --keypair "$WALLET" \
  --max-len "$SIZE" \
  --url "$URL"

echo
solana program show "$PROGRAM_ID" --url "$URL"

# Sync the env's PULLER_KEYS into the on-chain config (initializes it on the
# first deploy; later key changes don't need a deploy at all — use
# scripts/set-puller-keys.sh).
KEYS=$(grep '^PULLER_KEYS=' "$ENV_FILE" | cut -d= -f2- | tr -d '"')
echo
echo "Syncing puller keys to the on-chain config..."
# shellcheck disable=SC2086 — KEYS is intentionally word-split
cargo run -q -p admin-cli -- "$PROGRAM_ID" "$WALLET" "https://api.mainnet-beta.solana.com" $KEYS

PDA=$(python3 scripts/derive_pda.py "$PROGRAM_ID")
if $MINTED; then
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
fi
echo
echo "Backend configuration for '$ENV':"
echo "  Smart contract address (program id) : $PROGRAM_ID"
echo "      → set BOTH (same value): SolanaSubscriptionConfig--SmartContractAddress (Core API)"
echo "        and SolanaSubscriptionPullerConfig--SmartContractAddress (Backend Functions)"
echo "  MeshDelegate PDA (informational)    : $PDA"
echo "      → derived by the backend itself from the contract address; becomes the"
echo "        'delegatee' recorded on each subscription (DB row + on-chain delegation)"
