# Sourced helper — transient secret-key staging shared by the wallet and
# program-key prompts. Keys are prompted with hidden input, held only in
# mode-600 temp files OUTSIDE the repo, and removed on exit (success, error,
# or Ctrl-C). Nothing secret is ever stored.

SECRET_TMPFILES=()
_secrets_cleanup() { [[ ${#SECRET_TMPFILES[@]} -gt 0 ]] && rm -f "${SECRET_TMPFILES[@]}" || true; }
# Cleanup hangs off EXIT only. A signal handler that returns instead of
# exiting lets bash resume the script, so Ctrl-C would run cleanup and then
# carry on with the operation the operator was trying to stop. Exiting from
# the signal handler fires the EXIT trap, so cleanup still runs exactly once.
trap _secrets_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# stage_secret_key <expected-pubkey> <label> <out-var> — assigns the temp
# keypair path to <out-var>. Must be called directly (NOT in $(...) — a
# subshell would strand the temp file outside the cleanup trap). Aborts,
# keeping nothing, if the pasted key does not derive <expected-pubkey>.
stage_secret_key() {
  local expected="$1" label="$2" __outvar="$3" sk out
  read -rsp "Paste base58 secret key for $label [$expected] (input hidden): " sk
  echo >&2
  out=$(mktemp)
  chmod 600 "$out"
  SECRET_TMPFILES+=("$out")
  if ! SK="$sk" EXPECTED="$expected" OUT="$out" python3 scripts/stage_key.py >&2; then
    rm -f "$out"
    return 1
  fi
  printf -v "$__outvar" '%s' "$out"
}
