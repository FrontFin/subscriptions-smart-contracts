# Sourced helper — environment resolution for build/deploy/close scripts.
#
# Environments live in scripts/envs/<env>.env (puller keys) plus a per-env
# program keypair scripts/envs/<env>-program-keypair.json (gitignored; local
# pins PROGRAM_ID in its env file instead). Different program keypair per
# env → different program ID → different MeshDelegate PDA, so local/dev/prod
# coexist on mainnet without touching each other.

env_file() {
  local env="$1" f="scripts/envs/$1.env"
  [[ -f "$f" ]] || { echo "error: unknown environment '$env' ($f not found)" >&2; return 1; }
  echo "$f"
}

# Fails unless the value decodes to exactly 32 bytes. The base58 alphabet and a
# 32..44 character band are not enough on their own: a paste that loses a couple
# of characters stays inside the band and still decodes short.
require_pubkey() {
  local value="$1" label="$2"
  python3 - "$value" <<'PY' && return 0
import sys
ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
text = sys.argv[1]
if not text or any(c not in ALPHABET for c in text):
    sys.exit(1)
value = 0
for char in text:
    value = value * 58 + ALPHABET.index(char)
raw = b'\x00' * (len(text) - len(text.lstrip('1')))
raw += value.to_bytes((value.bit_length() + 7) // 8, 'big')
sys.exit(0 if len(raw) == 32 else 1)
PY
  echo "error: $label '$value' is not a 32-byte base58 address" >&2
  return 1
}

# Prints the env's upgrade-authority pubkey (public; the private key is
# prompted at deploy/close time, never stored).
env_upgrade_authority() {
  local f; f=$(env_file "$1") || return 1
  local ua
  ua=$(grep '^UPGRADE_AUTHORITY=' "$f" | cut -d= -f2 || true)
  [[ -n "$ua" ]] || { echo "error: no UPGRADE_AUTHORITY in $f" >&2; return 1; }
  echo "$ua"
}

# Prints the env's program id — the PUBLIC value pinned as PROGRAM_ID in the
# env file. No program keypair is ever stored: deploy.sh mints a throwaway
# keypair at the env's FIRST deploy, pins the resulting id here, and discards
# the secret. Until that first deploy the env simply has no id.
env_program_id() {
  local f; f=$(env_file "$1") || return 1
  local pinned
  pinned=$(grep '^PROGRAM_ID=' "$f" | cut -d= -f2 || true)
  [[ -n "$pinned" ]] || {
    echo "error: no PROGRAM_ID pinned in $f — it is minted and pinned at the env's first deploy (scripts/deploy.sh $1)" >&2
    return 1
  }
  echo "$pinned"
}
