#!/usr/bin/env bash
# Close one environment's deployed program and refund its rent deposit.
# Must be signed by that env's upgrade authority (UPGRADE_AUTHORITY in the
# env's .env); prompts for its secret key on each run — nothing saved.
#
# ⚠️ IRREVERSIBLE for the program ID: a closed program id can NEVER be
# redeployed. On success this script unpins PROGRAM_ID from the env file, so
# the env's next deploy mints a fresh id → new MeshDelegate PDA (existing
# delegations die with the old one).
#
# Usage: scripts/close.sh <local|dev|prod> [recipient-pubkey]   (default: the wallet)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_wallet.sh
source scripts/_env.sh

ENV="${1:?usage: scripts/close.sh <local|dev|prod> [recipient-pubkey]}"
[[ "$ENV" != "test" ]] || { echo "error: 'test' is the LiteSVM fixture — nothing on-chain to close" >&2; exit 1; }
PROGRAM_ID=$(env_program_id "$ENV")
UPGRADE_AUTHORITY=$(env_upgrade_authority "$ENV")
URL="mainnet-beta"

prompt_wallet "$UPGRADE_AUTHORITY"
RECIPIENT="${2:-$(solana-keygen pubkey "$WALLET")}"

echo "environment : $ENV"
echo "program id  : $PROGRAM_ID"
echo "refund to   : $RECIPIENT"
echo
echo "This permanently burns the program id (it can never be redeployed)."
read -rp "Type 'close' to proceed: " CONFIRM
[[ "$CONFIRM" == "close" ]] || { echo "aborted"; exit 1; }

solana program close "$PROGRAM_ID" \
  --keypair "$WALLET" \
  --recipient "$RECIPIENT" \
  --bypass-warning \
  --url "$URL"

sed -i '' \
  -e '/^PROGRAM_ID=/d' \
  -e '/^# \^ the smart contract address/d' \
  -e '/^#   SolanaSubscription.*SmartContractAddress/d' \
  -e '/^# The backend derives the MeshDelegate PDA/d' \
  -e '/^# value\. Informational, for cross-checking/d' \
  -e '/^# becomes the .delegatee. recorded/d' \
  -e '/^# MeshDelegate PDA = /d' \
  -e '/^# This env'"'"'s MeshDelegate PDA/d' \
  -e '/^# Set the backend'"'"'s SolanaSubscriptionConfig.Delegatee/d' \
  -e '/^# Delegatee = /d' \
  "scripts/envs/$ENV.env"
echo "Done. Rent refunded to $RECIPIENT."
echo "Unpinned the burned PROGRAM_ID from scripts/envs/$ENV.env — the next deploy mints a fresh id/PDA."
