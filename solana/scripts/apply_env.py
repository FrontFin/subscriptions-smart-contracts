#!/usr/bin/env python3
"""Rewrite the program source from an environment file.

Usage: apply_env.py <env-file> [program-id]

Sets `declare_id!` in lib.rs from the env file's PROGRAM_ID (or the explicit
`program-id` override, used when the id comes from a freshly minted keypair).
Puller keys are NOT baked into the source — they live in the on-chain Config
account (see scripts/set-puller-keys.sh).
"""
import re
import sys

env_path = sys.argv[1]
env = {}
for line in open(env_path):
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    k, v = line.split('=', 1)
    env[k] = v.strip().strip('"')

program_id = sys.argv[2] if len(sys.argv) > 2 else env.get('PROGRAM_ID')
if not program_id:
    sys.exit(f'error: no PROGRAM_ID in {env_path} and none passed')

lib = 'programs/subscription-controller/src/lib.rs'
src = open(lib).read()
new, count = re.subn(r'declare_id!\("[^"]*"\)', f'declare_id!("{program_id}")', src)
if count != 1:
    sys.exit(f'error: expected exactly one declare_id! in {lib}, rewrote {count} — nothing written')
open(lib, 'w').write(new)

print(f'applied {env_path}: program_id={program_id}')
