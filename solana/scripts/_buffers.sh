# Buffer listing uses --buffer-authority <pubkey>; closing uses --authority <signer>.

# Keep address rows only; headers may appear even when no buffers exist. Nonzero means RPC failure.
list_buffers() {
  local table
  table=$(solana program show --buffers --buffer-authority "$1" --url "$2" 2>/dev/null) || return 1
  printf '%s\n' "$table" \
    | awk 'length($1) >= 32 && length($1) <= 44 && $1 !~ /[^1-9A-HJ-NP-Za-km-z]/'
}

# Report listing failures and stray buffers without aborting the caller.
report_stray_buffers() {
  local authority="$1" url="$2" hint="${3:-scripts/buffers.sh <env> --close}" strays
  if ! strays=$(list_buffers "$authority" "$url"); then
    echo "note: could not list upgrade buffers for $authority on $url. Check by hand:" >&2
    echo "      solana program show --buffers --buffer-authority $authority --url $url" >&2
    return 0
  fi
  [[ -n "$strays" ]] || return 0
  echo >&2
  echo "⚠️  upgrade buffers still held by $authority:" >&2
  echo "$strays" >&2
  echo "   Each one holds rent and can still be used to upgrade this program." >&2
  echo "   Close the ones you no longer need:  $hint" >&2
}
