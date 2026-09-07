#!/usr/bin/env python3
"""Decode a base58 ed25519 secret key (env SK), verify it derives the pubkey
in env EXPECTED, and write the CLI keypair JSON to the path in env OUT.
Shared by the wallet and program-key prompts — never prints the secret."""
import json
import os
import sys

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
except ImportError:
    sys.exit(
        'error: cryptography is required; activate your Python virtual environment '
        'and run: python3 -m pip install -r solana/scripts/requirements.txt (from the repo root)'
    )

ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'

def b58decode(s):
    n = 0
    for c in s:
        n = n * 58 + ALPHABET.index(c)
    b = n.to_bytes((n.bit_length() + 7) // 8, 'big')
    return b'\x00' * (len(s) - len(s.lstrip('1'))) + b


def b58encode(b):
    n = int.from_bytes(b, 'big')
    r = ''
    while n:
        n, m = divmod(n, 58)
        r = ALPHABET[m] + r
    return '1' * (len(b) - len(b.lstrip(b'\x00'))) + r


sk = os.environ['SK'].strip()
try:
    raw = b58decode(sk)
except ValueError:
    sys.exit('error: not valid base58')
if len(raw) != 64:
    sys.exit(f'error: decoded to {len(raw)} bytes, expected a 64-byte ed25519 secret key')

# The trailing 32 bytes are only the key's CLAIM about its public half.
# Re-deriving from the seed is what turns that claim into a check.
derived = Ed25519PrivateKey.from_private_bytes(raw[:32]).public_key().public_bytes_raw()
pubkey = b58encode(derived)
claimed = b58encode(raw[32:])
if pubkey != claimed:
    sys.exit(f'error: key derives {pubkey} but claims {claimed} — malformed, nothing kept')

expected = os.environ['EXPECTED']
if expected and pubkey != expected:
    sys.exit(f'error: key derives {pubkey}, expected {expected} — wrong key, nothing kept')

fd = os.open(os.environ['OUT'], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as f:
    json.dump(list(raw), f)
