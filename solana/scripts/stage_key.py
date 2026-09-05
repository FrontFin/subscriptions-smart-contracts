#!/usr/bin/env python3
"""Decode a base58 ed25519 secret key (env SK), verify it derives the pubkey
in env EXPECTED, and write the CLI keypair JSON to the path in env OUT.
Shared by the wallet and program-key prompts — never prints the secret."""
import hashlib
import json
import os
import sys

ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'

FIELD_PRIME = 2 ** 255 - 19
CURVE_D = -121665 * pow(121666, FIELD_PRIME - 2, FIELD_PRIME) % FIELD_PRIME
BASE_X = 15112221349535400772501151409588531511454012693041857206046113283949847762202
BASE_Y = 46316835694926478169428394003475163141307993866256225615783033603165251855960


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


def point_add(first, second):
    x1, y1, z1, t1 = first
    x2, y2, z2, t2 = second
    a = (y1 - x1) * (y2 - x2) % FIELD_PRIME
    b = (y1 + x1) * (y2 + x2) % FIELD_PRIME
    c = 2 * t1 * t2 * CURVE_D % FIELD_PRIME
    d = 2 * z1 * z2 % FIELD_PRIME
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % FIELD_PRIME, g * h % FIELD_PRIME,
            f * g % FIELD_PRIME, e * h % FIELD_PRIME)


def base_point_mult(scalar):
    result = (0, 1, 1, 0)
    addend = (BASE_X, BASE_Y, 1, BASE_X * BASE_Y % FIELD_PRIME)
    while scalar > 0:
        if scalar & 1:
            result = point_add(result, addend)
        addend = point_add(addend, addend)
        scalar >>= 1
    return result


def compress(point):
    x, y, z, _ = point
    inverse_z = pow(z, FIELD_PRIME - 2, FIELD_PRIME)
    x, y = x * inverse_z % FIELD_PRIME, y * inverse_z % FIELD_PRIME
    return (y | ((x & 1) << 255)).to_bytes(32, 'little')


def ed25519_pubkey_from_seed(seed):
    digest = hashlib.sha512(seed).digest()
    scalar = int.from_bytes(digest[:32], 'little')
    scalar &= (1 << 254) - 8
    scalar |= 1 << 254
    return compress(base_point_mult(scalar))


sk = os.environ['SK'].strip()
try:
    raw = b58decode(sk)
except ValueError:
    sys.exit('error: not valid base58')
if len(raw) != 64:
    sys.exit(f'error: decoded to {len(raw)} bytes, expected a 64-byte ed25519 secret key')

# The trailing 32 bytes are only the key's CLAIM about its public half.
# Re-deriving from the seed is what turns that claim into a check.
pubkey = b58encode(ed25519_pubkey_from_seed(raw[:32]))
claimed = b58encode(raw[32:])
if pubkey != claimed:
    sys.exit(f'error: key derives {pubkey} but claims {claimed} — malformed, nothing kept')

expected = os.environ['EXPECTED']
if expected and pubkey != expected:
    sys.exit(f'error: key derives {pubkey}, expected {expected} — wrong key, nothing kept')

fd = os.open(os.environ['OUT'], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as f:
    json.dump(list(raw), f)
