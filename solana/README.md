# Mesh Subscription Controller (Anchor program)

On-chain implementation of the **Mesh-owned Delegatee PDA** design
([TDD](../docs/solana-pull-payment-pda-tdd.md)), deliberately reduced to its
minimal form. The program owns a `MeshDelegate` PDA that is registered as the
`delegatee` on every recurring delegation. Because the delegatee is a PDA (no
private key), the operational **puller key** only *triggers* pulls. The
puller-key allowlist lives in an on-chain `Config` account, so rotation and
the kill switch are single admin transactions that never modify the (audited)
program code; only code changes are upgrades.

```
solana/
├── Anchor.toml
├── test.sh                  # builds the test env + runs the LiteSVM tests
├── scripts/
│   ├── envs/{test,local,dev,prod}.env  # per-env puller keys, upgrade authority, program id (all public)
│   ├── build.sh <env>       # inject env program id → build → restore source (test id)
│   ├── deploy.sh <local|dev|prod>          # build + deploy + sync puller keys (prompts for wallet key)
│   ├── set-puller-keys.sh <local|dev|prod> # rotation / kill switch — one data tx, no deploy
│   └── close.sh  <local|dev|prod>          # close an env's program, refund its rent
├── programs/subscription-controller/
│   ├── src/
│   │   ├── lib.rs           # Config account + initialize / set_puller_keys / pull
│   │   ├── constants.rs     # protocol constants (seeds, native program id)
│   │   └── error.rs         # ControllerError
│   └── tests/
│       ├── test_controller.rs   # LiteSVM tests (11 passing, incl. end-to-end pull)
│       └── fixtures/
│           └── subscriptions_program.so # native Subscriptions program, dumped from mainnet
├── tools/admin-cli/         # sends initialize / set_puller_keys over RPC
└── DEPLOY.md                # ← deployment & operations guide
```

## Design: one config account, three instructions

| Instruction | Signer | Purpose |
| --- | --- | --- |
| `initialize(puller_keys)` | admin (once) | Creates the singleton `Config` (seed `["config"]`); the creator becomes admin. Cannot run twice. |
| `set_puller_keys(puller_keys)` | admin | Rewrites the allowlist. Rotation = old+new, then remove old. Empty list = kill switch. One transaction — audited code untouched. |
| `pull(native_data)` | puller | Gate (signer listed in `Config.puller_keys` + target program) then CPI the native pull, signing as `MeshDelegate`. |

Where each setting lives:

| Setting | Where | To change it |
| --- | --- | --- |
| Puller-key allowlist | **on-chain `Config` account** (source of truth: the env's `.env` `PULLER_KEYS`) | edit the `.env`, run `scripts/set-puller-keys.sh <env>` — one admin transaction, no build, no deploy. Empty list = kill switch. |
| Program id | pinned in the env's `.env`; compiled into `declare_id!` per build | fixed at first deploy (never changes) |
| `SUBSCRIPTIONS_PROGRAM` | compile-time constant, same on all envs — `De1egAFM…9avR44` (matches `SolanaSubscriptionInstructionBuilder.ProgramId`) | code change + upgrade |

Each environment has its own program ID (minted at first deploy, pinned in
its `.env`) → own `MeshDelegate` PDA, so local/dev/prod coexist on mainnet
independently. No private keys live in the repo — the upgrade-authority
wallet key is prompted during deploy, and the program key exists only
transiently during an env's first deploy.

Why this is safe: an env's `MeshDelegate` PDA is derived as `["mesh_delegate"]`
from its **program ID only**, and the program ID never changes across
upgrades. So kill, un-kill, and any number of puller-key rotations never
invalidate a single delegation and never require a user to re-subscribe. The
only privileged party is the upgrade authority — a property of every
upgradeable Solana program, not a key in this code. Keep that wallet safe and
off servers.

The native Subscriptions program still enforces all of its own invariants
(`amount_per_period` cap, period rollover, expiry, delegatee-must-sign); this
program is only a verified signer proxy in front of it.

## PDAs

```
MeshDelegate = ["mesh_delegate"]      ← the delegatee on new delegations (program-ID-derived, permanent)
```

## Quick start

```bash
./test.sh                # build test env + LiteSVM tests
scripts/deploy.sh dev    # deploy the dev env to mainnet
NO_DNA=1 anchor build    # (optional) also generate the IDL
```

Deployment, environments, the kill-switch runbook, and rotation are in
**[DEPLOY.md](DEPLOY.md)**.

### Testing note

The suite creates the on-chain `Config` itself, using puller keypairs derived
from fixed public seeds (`fixture_puller_keypairs` in `test_controller.rs`) —
no private-key files in the repo, no feature flags. The keys are publicly
derivable by anyone, which is why the `test` build is never deployable. The
config lifecycle is fully covered: initialize-once, admin gating, rotation as
a single transaction, kill switch + resume.

The suite includes a full end-to-end test: subscribe (initialize authority +
create delegation with `MeshDelegate` as delegatee) and pull through the
controller against the **real native Subscriptions program binary dumped from
mainnet** (`tests/fixtures/subscriptions_program.so`) — funds move, the
per-period counter advances, and a second over-cap pull is rejected by the
native program. Re-dump with
`solana program dump De1egAFMkMWZSN5rYXRj9CAdheBamobVNubTsi9avR44 programs/subscription-controller/tests/fixtures/subscriptions_program.so -u mainnet-beta`
if the mainnet program upgrades.

## Future scope

The richer prototype (`SolanaSubscriptionPDA/controller`) also had a two-step
admin handover and a destination allowlist; either can be added via a normal
upgrade later — new instructions and account fields never move the
`MeshDelegate` PDA, provided its `["mesh_delegate"]` seed is kept.
