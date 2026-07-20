#!/usr/bin/env python3
"""Rewrite the program source from an environment file.

Usage: apply_env.py <env-file> [program-id]

Sets `PULLER_KEYS` in constants.rs and `declare_id!` in lib.rs from the env
file. `program-id` overrides the env file's PROGRAM_ID (used when the id
comes from a per-env program keypair).
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
keys = env.get('PULLER_KEYS', '').split()

constants = 'programs/subscription-controller/src/constants.rs'
src = open(constants).read()
if keys:
    block = ('pub const PULLER_KEYS: &[Pubkey] = &[\n'
             + ''.join(f'    pubkey!("{k}"),\n' for k in keys) + '];')
else:
    block = 'pub const PULLER_KEYS: &[Pubkey] = &[];'
new = re.sub(r'pub const PULLER_KEYS: &\[Pubkey\] = &\[[^;]*\];', block, src, flags=re.S)
if new == src and block not in src:
    sys.exit(f'error: PULLER_KEYS block not found in {constants}')
open(constants, 'w').write(new)

lib = 'programs/subscription-controller/src/lib.rs'
src = open(lib).read()
new = re.sub(r'declare_id!\("[^"]*"\)', f'declare_id!("{program_id}")', src)
open(lib, 'w').write(new)

print(f'applied {env_path}: program_id={program_id} puller_keys={keys}')
