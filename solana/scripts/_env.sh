# Environment values and pinned program IDs live in scripts/envs/<env>.env.

env_file() {
  local env="$1" f="scripts/envs/$1.env"
  [[ -f "$f" ]] || { echo "error: unknown environment '$env' ($f not found)" >&2; return 1; }
  echo "$f"
}

# Validate decoded length; base58 character count alone cannot detect truncated keys.
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

env_upgrade_authority() {
  local f; f=$(env_file "$1") || return 1
  local ua
  ua=$(grep '^UPGRADE_AUTHORITY=' "$f" | cut -d= -f2 || true)
  [[ -n "$ua" ]] || { echo "error: no UPGRADE_AUTHORITY in $f" >&2; return 1; }
  echo "$ua"
}

# deploy.sh pins the public ID on first deploy; its throwaway key is not retained.
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
