#!/usr/bin/env bash
# FIRST deploy of an environment to mainnet, signed entirely by the authority
# wallet IN THE BROWSER — no private key is ever pasted or stored, and the
# wallet is the only funded wallet you maintain. Exactly two popups:
#
#   popup 1  fund a temporary payer (working capital for rent + fees; every
#            leftover lamport is swept back to the wallet on exit);
#   popup 2  initialize the on-chain Config with the env's PULLER_KEYS — the
#            wallet becomes the config admin.
#
# In between, the script: mints the program keypair (throwaway — its pubkey
# becomes the permanent program id; discarded after claiming the address),
# deploys with the temporary payer, and hands the upgrade authority to the
# wallet. Later code changes: scripts/upgrade.sh. Key changes:
# scripts/set-puller-keys.sh.
#
# Usage: scripts/deploy.sh <local|dev|prod>     [FEE_PAYER=<path> overrides]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_ephemeral.sh
source scripts/_env.sh

ENV="${1:?usage: scripts/deploy.sh <local|dev|prod>}"
[[ "$ENV" != "test" ]] || { echo "error: 'test' is the LiteSVM fixture — never deployable (its puller keys are publicly derivable)" >&2; exit 1; }
ENV_FILE=$(env_file "$ENV")
UPGRADE_AUTHORITY=$(env_upgrade_authority "$ENV")
# Nothing later can undo a bad value: the authority is handed the program
# without ever signing, and the program keypair is discarded on exit.
require_pubkey "$UPGRADE_AUTHORITY" "UPGRADE_AUTHORITY in $ENV_FILE" || exit 1
URL="mainnet-beta"
RPC_URL="https://api.mainnet-beta.solana.com"

# The .env must be configured before deploying. A PULLER_KEYS line must be
# present — an explicitly EMPTY value ("") is the intentional kill switch,
# but a missing line is a misconfiguration.
grep -q '^PULLER_KEYS=' "$ENV_FILE" || {
  echo "error: PULLER_KEYS is not set in $ENV_FILE — set it before deploying" >&2
  echo "(an explicit PULLER_KEYS=\"\" is the kill switch; a missing line is treated as a mistake)" >&2
  exit 1
}
KEYS=$(grep '^PULLER_KEYS=' "$ENV_FILE" | cut -d= -f2- | tr -d '"')
if [[ -z "${KEYS// /}" ]]; then
  echo "⚠️  PULLER_KEYS is EMPTY — the on-chain config will be initialized to the kill switch: no key can pull." >&2
fi

# This script is FIRST deploys only.
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

# Mint the program keypair (temp file, discarded on exit — its pubkey is the
# env's permanent program id; the key grants nothing after the first deploy).
PROGRAM_KP=$(mktemp)
chmod 600 "$PROGRAM_KP"
SECRET_TMPFILES+=("$PROGRAM_KP")
solana-keygen new --no-bip39-passphrase --silent --force -o "$PROGRAM_KP" >&2
PROGRAM_ID=$(solana-keygen pubkey "$PROGRAM_KP")

scripts/build.sh "$ENV" "$PROGRAM_ID"
ARTIFACT="target/deploy-$ENV/subscription_controller.so"
SIZE=$(stat -f%z "$ARTIFACT" 2>/dev/null || stat -c%s "$ARTIFACT")
# Allocate 20% headroom so later code upgrades fit without a separate
# `solana program extend` (which needs the upgrade authority to sign — an
# extra step the browser-signed flow doesn't do). Extra rent is refunded on
# close.
MAX_LEN=$(python3 -c "print(int($SIZE * 12 // 10))")
# Working capital: program rent for the full allocation (locked in
# ProgramData; refunded on close) plus fee headroom. Leftovers sweep back.
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

# Popup 1 — the wallet funds the temporary payer.
ephemeral_payer "$UPGRADE_AUTHORITY" "$FUND_LAMPORTS" "$RPC_URL"

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
  fi
  echo "   $ENV_FILE was NOT touched — re-running mints a fresh program id." >&2
  echo "   The program key is discarded on exit, so if $PROGRAM_ID was already created" >&2
  echo "   on chain it keeps the rent it holds." >&2
  exit 1
fi

# Hand the upgrade authority to the wallet (signed by the temporary payer,
# which held it for the seconds since the deploy).
# The skip flag is structural, not a shortcut: the new authority never signs
# here, and a Squads vault is a PDA with no private key that ever could.
solana program set-upgrade-authority "$PROGRAM_ID" \
  --keypair "$PAYER_FILE" \
  --new-upgrade-authority "$UPGRADE_AUTHORITY" \
  --skip-new-upgrade-authority-signer-check \
  --url "$URL"

# Pin the id BEFORE anything that can abort. The program keypair is discarded
# on exit, so an id that exists on-chain but not in the env file is unreachable.
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

# Popup 2 — the wallet initializes the on-chain Config (becomes admin).
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

# Ownership check: `initialize` is gated to the program's upgrade authority,
# so a front-run needs that key — but confirm WE own the resulting config
# anyway rather than let you wire a backend to a config you don't control.
if $INITIALIZED; then
  ON_CHAIN_ADMIN=$(cargo run -q -p admin-cli -- "$PROGRAM_ID" "tx:$UPGRADE_AUTHORITY" "$RPC_URL" show \
    | awk '$1=="admin"{print $3}')
  if [[ -z "$ON_CHAIN_ADMIN" ]]; then
    echo "⚠️  could not read the config admin back — the RPC returned nothing." >&2
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
