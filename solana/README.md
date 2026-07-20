# Mesh Subscription Controller (Anchor program)

On-chain implementation of the **Mesh-owned Delegatee PDA** design
([TDD](../docs/solana-pull-payment-pda-tdd.md)), deliberately reduced to its
minimal form. The program owns a `MeshDelegate` PDA that is registered as the
`delegatee` on every recurring delegation. Because the delegatee is a PDA (no
private key), the operational **puller key** only *triggers* pulls — and every
admin action (kill switch, puller-key rotation) is a **program upgrade** signed by
the upgrade authority. There is no admin key and no admin instruction.

```
solana/
├── Anchor.toml
├── test.sh                  # builds the test env + runs the LiteSVM tests
├── scripts/
│   ├── envs/{test,local,dev,prod}.env  # per-env puller keys, upgrade authority, program id (all public)
│   ├── build.sh <env>       # inject env constants → build → restore source (test values)
│   ├── deploy.sh <local|dev|prod> # build + deploy an env to mainnet (prompts for wallet key)
│   └── close.sh  <local|dev|prod> # close an env's program, refund its rent
├── programs/subscription-controller/
│   ├── src/
│   │   ├── lib.rs           # the single `pull` instruction (gate + CPI forwarder)
│   │   ├── constants.rs     # config baked into the binary (committed = test env)
│   │   └── error.rs         # ControllerError
│   └── tests/
│       ├── test_controller.rs   # LiteSVM tests (7 passing, incl. end-to-end pull)
│       └── fixtures/
│           └── subscriptions_program.so # native Subscriptions program, dumped from mainnet
└── DEPLOY.md                # ← deployment & operations guide
```

## Design: no state, no admin — upgrades are the admin plane

The program has **one instruction and zero accounts of its own**:

| Instruction | Signer | Purpose |
| --- | --- | --- |
| `pull(native_data)` | puller | Gate (puller-key listed + target program) then CPI the native pull, signing as `MeshDelegate`. |

All configuration is compile-time constants, sourced per environment from
`scripts/envs/<env>.env` (`scripts/build.sh <env>` injects them; the committed
source always carries the `test` values):

| Constant | Source | Meaning | To change it |
| --- | --- | --- | --- |
| `PULLER_KEYS` | per-env `.env` — test: public-seed keys; local/dev/prod: real puller key(s) | The keys allowed to trigger `pull`. **Empty list = kill switch ("pause")** (authorizes no one, so every pull fails `Unauthorized`). | Edit the env's `.env`; re-deploy that env. Rotation: list old+new (zero-downtime overlap), flip Key Vault, remove the old key. |
| `SUBSCRIPTIONS_PROGRAM` | `constants.rs` (same on all envs) — `De1egAFM…9avR44` | The native Subscriptions program CPI'd into (matches `SolanaSubscriptionInstructionBuilder.ProgramId` in FrontBackEnd) | Upgrade |

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

The test env's `PULLER_KEYS` are derived from fixed public seeds in the
test suite (`fixture_puller_keypairs` in `test_controller.rs`; two entries to
exercise the rotation overlap), so the tests sign with them directly against
the local build — no private-key files in the repo, no feature flags. The
keys are publicly derivable by anyone, which is why `test` is never
deployable; local/dev/prod builds inject the real puller key(s) from their `.env`
(the `constants_are_the_committed_fixtures` test pins the test values).

The suite includes a full end-to-end test: subscribe (initialize authority +
create delegation with `MeshDelegate` as delegatee) and pull through the
controller against the **real native Subscriptions program binary dumped from
mainnet** (`tests/fixtures/subscriptions_program.so`) — funds move, the
per-period counter advances, and a second over-cap pull is rejected by the
native program. Re-dump with
`solana program dump De1egAFMkMWZSN5rYXRj9CAdheBamobVNubTsi9avR44 programs/subscription-controller/tests/fixtures/subscriptions_program.so -u mainnet-beta`
if the mainnet program upgrades.

## Future scope

If admin actions become frequent enough that upgrade-per-change hurts, the
config-account version of this program (on-chain `pause`, `rotate_puller_key`,
two-step cold handover, destination allowlist) exists fully tested in the
`SolanaSubscriptionPDA/controller` prototype and can be restored via a normal
upgrade — state accounts can be added later without moving the `MeshDelegate`
PDA, provided its `["mesh_delegate"]` seeds are kept.
