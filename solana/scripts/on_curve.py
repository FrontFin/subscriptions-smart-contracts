#!/usr/bin/env python3
"""Classify a pubkey: prints "wallet" or "program" on stdout.

Usage: on_curve.py <pubkey>

Every keypair's public key is a point on the ed25519 curve. A program address
is chosen precisely because it is not, so nothing can sign for it. A Squads
vault is a program address: it can neither pay a transaction fee nor sign in a
browser wallet.

The answer is the printed word, never the exit status. An uncaught exception
also exits 1, so a caller reading the status alone cannot tell "off the curve"
from "this script failed to run" — and every caller gates an irreversible
operation on the answer. Nothing is printed unless the classification
succeeded.
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

print('wallet' if oncurve(key) else 'program')
