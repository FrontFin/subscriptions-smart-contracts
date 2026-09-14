#!/usr/bin/env python3
"""Exit 0 if a pubkey has a private key, 1 if it is a program address.

Usage: on_curve.py <pubkey>

Every keypair's public key is a point on the ed25519 curve. A program address
is chosen precisely because it is not, so nothing can sign for it. A Squads
vault is a program address: it can neither pay a transaction fee nor sign in a
browser wallet.
"""
import sys

from derive_pda import b58d, oncurve

if len(sys.argv) != 2:
    print('usage: on_curve.py <pubkey>', file=sys.stderr)
    sys.exit(2)

try:
    key = b58d(sys.argv[1])
except ValueError:
    print(f'error: {sys.argv[1]} is not base58', file=sys.stderr)
    sys.exit(2)

if len(key) != 32:
    print(f'error: {sys.argv[1]} is {len(key)} bytes, not 32', file=sys.stderr)
    sys.exit(2)

sys.exit(0 if oncurve(key) else 1)
