# Sourced helper — not executable on its own.
#
# prompt_wallet <expected-pubkey>: asks for that wallet's base58 secret key
# (hidden input), verifies it derives <expected-pubkey> (the env's
# UPGRADE_AUTHORITY), and exports WALLET=<temp keypair path>. See
# scripts/_secrets.sh for the staging rules (temp file outside the repo,
# auto-removed on exit; only public keys live in the repo).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_secrets.sh"

prompt_wallet() {
  local expected="${1:?prompt_wallet requires the expected pubkey}"
  stage_secret_key "$expected" "upgrade-authority wallet" WALLET || return 1
  echo "wallet key staged in a temp file (auto-removed on exit)" >&2
}
