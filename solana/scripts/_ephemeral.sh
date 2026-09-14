# Browser-funded temporary payer; close buffers and sweep on exit. FEE_PAYER skips cleanup.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_secrets.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_buffers.sh"

EPHEMERAL=""
_EPH_SWEEP_TO=""
_EPH_URL="mainnet-beta"

# Retain the key if its balance could not be swept.
_eph_keep_payer_keypair() {
  local kept=()
  local file
  for file in ${SECRET_TMPFILES[@]+"${SECRET_TMPFILES[@]}"}; do
    [[ "$file" == "$EPHEMERAL" ]] || kept+=("$file")
  done
  SECRET_TMPFILES=(${kept[@]+"${kept[@]}"})
}

# Copy the payer key where it survives cleanup, and print the path. mktemp
# creates the file itself, exclusively and readable only by this user, so a
# symlink planted at a guessable name cannot redirect the private key.
_eph_rescue_copy() {
  local label="$1" pubkey rescue
  pubkey=$(solana-keygen pubkey "$EPHEMERAL" 2>/dev/null) || pubkey="unknown"
  rescue=$(mktemp "${TMPDIR:-/tmp}/mesh-$label-payer-$pubkey-XXXXXX") || return 1
  chmod 600 "$rescue" || { rm -f "$rescue"; return 1; }
  cat "$EPHEMERAL" >"$rescue" || { rm -f "$rescue"; return 1; }
  printf '%s' "$rescue"
}

# Keep the temporary payer key past exit; sets RETAINED_PAYER_FILE.
retain_ephemeral_payer() {
  RETAINED_PAYER_FILE=""
  [[ -n "$EPHEMERAL" && -f "$EPHEMERAL" ]] || return 1
  local rescue
  if rescue=$(_eph_rescue_copy retained); then
    RETAINED_PAYER_FILE="$rescue"
  else
    RETAINED_PAYER_FILE="$EPHEMERAL"
    _eph_keep_payer_keypair
  fi
}

_eph_cleanup() {
  if [[ -n "$EPHEMERAL" && -f "$EPHEMERAL" && -n "$_EPH_SWEEP_TO" ]]; then
    # Close buffers before deleting their authority key.
    local eph_pub strays listed
    eph_pub=$(solana-keygen pubkey "$EPHEMERAL" 2>/dev/null) || eph_pub=""
    if [[ -n "$eph_pub" ]]; then
      listed=true
      strays=$(list_buffers "$eph_pub" "$_EPH_URL") || { strays=""; listed=false; }
      [[ -z "$strays" ]] || echo "closing the write buffer this run left behind (rent → $_EPH_SWEEP_TO)..." >&2
      if ! solana program close --buffers -k "$EPHEMERAL" --authority "$EPHEMERAL" --recipient "$_EPH_SWEEP_TO" --url "$_EPH_URL" >/dev/null 2>&1; then
        # A buffer that was not confirmed closed can only ever be closed by this
        # key, so keep a copy rather than deleting the rent away — the same
        # treatment the sweep failure below gets.
        local buffer_key=""
        if [[ -n "$strays" || "$listed" == false ]]; then
          buffer_key=$(_eph_rescue_copy buffer-authority) || buffer_key=""
          if [[ -z "$buffer_key" ]]; then
            buffer_key="$EPHEMERAL"
            _eph_keep_payer_keypair
          fi
        fi
        if [[ -n "$strays" ]]; then
          echo "⚠️  could not close the write buffer this run left behind:" >&2
          echo "$strays" >&2
        elif [[ "$listed" == false ]]; then
          echo "⚠️  could not close the write buffer, and could not list what $eph_pub holds," >&2
          echo "   so there may be one. Check with:" >&2
          echo "     solana program show --buffers --buffer-authority $eph_pub --url $_EPH_URL" >&2
        fi
        if [[ -n "$buffer_key" ]]; then
          echo "   Its authority key is kept at: $buffer_key" >&2
          echo "   Reclaim the rent with:" >&2
          echo "     solana program close --buffers -k $buffer_key --authority $buffer_key --recipient $_EPH_SWEEP_TO --url $_EPH_URL" >&2
          echo "   DELETE that file once the rent is back." >&2
        fi
      fi
    fi

    # An RPC failure leaves the balance unknown; still attempt the sweep.
    local bal=""
    bal=$(solana balance -k "$EPHEMERAL" -u "$_EPH_URL" 2>/dev/null | awk '{print $1}') || bal=""
    if [[ "$bal" != "0" ]]; then
      echo "sweeping ${bal:-an unknown amount of} SOL from the temporary payer back to $_EPH_SWEEP_TO..." >&2
      if ! solana transfer "$_EPH_SWEEP_TO" ALL --keypair "$EPHEMERAL" --url "$_EPH_URL" >/dev/null 2>&1; then
        local rescue=""
        rescue=$(_eph_rescue_copy unswept) || rescue=""
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

# ephemeral_payer <authority-pubkey> <lamports> <rpc-url>; sets PAYER_FILE.
ephemeral_payer() {
  local authority="$1" lamports="$2" rpc="$3"
  if [[ -n "${FEE_PAYER:-}" ]]; then
    [[ -f "$FEE_PAYER" ]] || { echo "error: FEE_PAYER keypair $FEE_PAYER not found" >&2; return 1; }
    PAYER_FILE="$FEE_PAYER"
    echo "fee payer: $(solana-keygen pubkey "$PAYER_FILE") (FEE_PAYER override — no funding popup, no buffer close, no sweep)" >&2
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
