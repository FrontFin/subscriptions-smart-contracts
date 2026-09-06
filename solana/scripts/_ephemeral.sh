# Sourced helper — temporary fee payer funded FROM THE AUTHORITY WALLET, so
# the wallet is the only funded wallet you maintain. Flow:
#   1. mint a throwaway keypair (temp file, auto-removed on exit);
#   2. one browser popup: the wallet funds it with the needed working capital;
#   3. the throwaway does the mechanical signing (buffer writes etc.);
#   4. on exit — success, error, or Ctrl-C — every leftover lamport is swept
#      back to the wallet automatically.
# Override: set FEE_PAYER=<keypair path> to use a standing hot key instead
# (skips the funding popup and the sweep).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_secrets.sh"

EPHEMERAL=""
_EPH_SWEEP_TO=""
_EPH_URL="mainnet-beta"

# Takes the throwaway keypair off the deletion list, so a funded key that
# could not be swept survives `_secrets_cleanup`.
_eph_keep_payer_keypair() {
  local kept=()
  local file
  for file in ${SECRET_TMPFILES[@]+"${SECRET_TMPFILES[@]}"}; do
    [[ "$file" == "$EPHEMERAL" ]] || kept+=("$file")
  done
  SECRET_TMPFILES=(${kept[@]+"${kept[@]}"})
}

_eph_cleanup() {
  if [[ -n "$EPHEMERAL" && -f "$EPHEMERAL" && -n "$_EPH_SWEEP_TO" ]]; then
    # A failed balance read must not abort the trap: an unknown balance is
    # treated as "possibly funded" and swept anyway.
    local bal=""
    bal=$(solana balance -k "$EPHEMERAL" -u "$_EPH_URL" 2>/dev/null | awk '{print $1}') || bal=""
    if [[ "$bal" != "0" ]]; then
      echo "sweeping ${bal:-an unknown amount of} SOL from the temporary payer back to $_EPH_SWEEP_TO..." >&2
      if ! solana transfer "$_EPH_SWEEP_TO" ALL --keypair "$EPHEMERAL" --url "$_EPH_URL" >/dev/null 2>&1; then
        local pubkey="" rescue=""
        pubkey=$(solana-keygen pubkey "$EPHEMERAL" 2>/dev/null) || pubkey=""
        if [[ -n "$pubkey" ]]; then
          rescue="${TMPDIR:-/tmp}/mesh-unswept-payer-$pubkey.json"
          if ! (cp "$EPHEMERAL" "$rescue" && chmod 600 "$rescue"); then
            rescue=""
          fi
        fi
        if [[ -z "$rescue" ]]; then
          rescue="$EPHEMERAL"
          _eph_keep_payer_keypair
        fi
        echo "⚠️  SWEEP FAILED — ${bal:-an unknown amount of} SOL is still on the temporary payer." >&2
        echo "   Its key is kept at: $rescue" >&2
        echo "   Recover with: solana transfer $_EPH_SWEEP_TO ALL --keypair $rescue --url $_EPH_URL" >&2
        echo "   DELETE that file once the funds are back." >&2
      fi
    fi
  fi
  _secrets_cleanup
}

# ephemeral_payer <authority-pubkey> <lamports> <rpc-http-url>
# Sets PAYER_FILE. If FEE_PAYER is set in the environment, uses it directly
# (no popup, no sweep); otherwise mints + browser-funds a throwaway.
ephemeral_payer() {
  local authority="$1" lamports="$2" rpc="$3"
  if [[ -n "${FEE_PAYER:-}" ]]; then
    [[ -f "$FEE_PAYER" ]] || { echo "error: FEE_PAYER keypair $FEE_PAYER not found" >&2; return 1; }
    PAYER_FILE="$FEE_PAYER"
    echo "fee payer: $(solana-keygen pubkey "$PAYER_FILE") (FEE_PAYER override — no funding popup, no sweep)" >&2
    return 0
  fi

  EPHEMERAL=$(mktemp)
  SECRET_TMPFILES+=("$EPHEMERAL")
  _EPH_SWEEP_TO="$authority"
  trap _eph_cleanup EXIT INT TERM
  solana-keygen new --no-bip39-passphrase --silent --force -o "$EPHEMERAL" >&2
  local eph_pub sol
  eph_pub=$(solana-keygen pubkey "$EPHEMERAL")
  sol=$(python3 -c "print(f'{$lamports/1e9:.4f}')")
  echo "temporary payer $eph_pub — approve funding it with $sol SOL from your wallet (swept back on exit)..." >&2

  local b64
  b64=$(cargo run -q -p admin-cli -- 11111111111111111111111111111111 "tx:$authority" "$rpc" transfer "$eph_pub" "$lamports" \
        | awk -F': *|:' '/^UNSIGNED_TX_B64:/ {print $2}')
  [[ -n "$b64" ]] || { echo "error: could not build the funding transfer" >&2; return 1; }
  python3 scripts/sign_in_browser.py "$b64" "$authority" >/dev/null || {
    echo "error: funding transfer not signed" >&2
    return 1
  }

  local bal="0"
  for _ in $(seq 1 30); do
    bal=$(solana balance -k "$EPHEMERAL" -u "$_EPH_URL" 2>/dev/null | awk '{print $1}')
    [[ -n "$bal" && "$bal" != "0" ]] && break
    sleep 2
  done
  [[ -n "$bal" && "$bal" != "0" ]] || { echo "error: funding did not arrive" >&2; return 1; }
  echo "temporary payer funded: $bal SOL" >&2
  PAYER_FILE="$EPHEMERAL"
}
