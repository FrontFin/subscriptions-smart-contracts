# Sourced helper — upgrade buffers left behind by an interrupted deploy or
# upgrade.
#
# A buffer that still exists is locked-up rent, and while its authority is
# also the program's upgrade authority it is a second live path to upgrade
# the program. Both reasons to notice it and close it.
#
# The two CLI subcommands spell the filter differently: `solana program show`
# takes `--buffer-authority <PUBKEY>`, `solana program close` takes
# `--authority <SIGNER>` (a keypair path, not a pubkey).

# list_buffers <authority-pubkey> <url> — the CLI's own table rows. It pads the
# table with blank lines and a "Buffer Address | ..." header even when it found
# nothing, so both are stripped; empty output means no buffers. Non-zero means
# the listing itself failed.
list_buffers() {
  solana program show --buffers --buffer-authority "$1" --url "$2" 2>/dev/null \
    | awk 'NF && $1 != "Buffer"'
}

# report_stray_buffers <authority-pubkey> <url> [how-to-close]
# Warns on stderr, never fails.
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
