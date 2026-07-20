#!/usr/bin/env python3
"""Decode a base58 ed25519 secret key (env SK), verify it derives the pubkey
in env EXPECTED, and write the CLI keypair JSON to the path in env OUT.
Shared by the wallet and program-key prompts — never prints the secret."""
import json
import os
import sys

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

pubkey = b58encode(raw[32:])
expected = os.environ['EXPECTED']
if expected and pubkey != expected:
    sys.exit(f'error: key derives {pubkey}, expected {expected} — wrong key, nothing kept')

with open(os.environ['OUT'], 'w') as f:
    json.dump(list(raw), f)
