#!/usr/bin/env python3
"""Print the MeshDelegate PDA for a program id: derive_pda.py <program-id>"""
import hashlib
import sys

A = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'


def b58d(s):
    n = 0
    for c in s:
        n = n * 58 + A.index(c)
    b = n.to_bytes((n.bit_length() + 7) // 8, 'big')
    return b'\x00' * (len(s) - len(s.lstrip('1'))) + b


def b58e(b):
    n = int.from_bytes(b, 'big')
    r = ''
    while n:
        n, m = divmod(n, 58)
        r = A[m] + r
    return '1' * (len(b) - len(b.lstrip(b'\x00'))) + r


p = 2**255 - 19
d = (-121665 * pow(121666, p - 2, p)) % p


def oncurve(b):
    y = int.from_bytes(b, 'little') & ((1 << 255) - 1)
    if y >= p:
        return False
    x2 = ((y * y - 1) % p) * pow((d * y * y + 1) % p, p - 2, p) % p
    x = pow(x2, (p + 3) // 8, p)
    if (x * x - x2) % p != 0:
        x = (x * pow(2, (p - 1) // 4, p)) % p
    return (x * x - x2) % p == 0


def main():
    prog = b58d(sys.argv[1])
    for bump in range(255, -1, -1):
        h = hashlib.sha256(b'mesh_delegate' + bytes([bump]) + prog + b'ProgramDerivedAddress').digest()
        if not oncurve(h):
            print(b58e(h))
            break


if __name__ == '__main__':
    main()
