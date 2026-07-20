# subscriptions-smart-contracts

Smart contracts for Mesh's recurring-payment ("subscriptions") project, organized
per chain so future EVM contracts live alongside the Solana programs.

```
subscriptions-smart-contracts/
├── docs/                  # chain-agnostic design docs (TDDs)
├── solana/                # Anchor workspace — Mesh Subscription Controller
└── evm/                   # (future) EVM contracts for the same project
```

## Solana — Mesh Subscription Controller

Implements the **Mesh-owned Delegatee PDA** design
([TDD](docs/solana-pull-payment-pda-tdd.md)) in its minimal, stateless form:
instead of a raw hot key acting as the `delegatee` that signs every subscription
pull, a program-owned **`MeshDelegate` PDA** is the delegatee. The PDA has no
private key — the program signs pulls on its behalf via `invoke_signed`, gated
by compile-time constants:

- **Hot authority** — operational key that merely *triggers* pulls and pays
  their fees. Because it is not the delegatee, rotating it never invalidates
  a delegation.
- **Upgrade authority (cold multisig)** — the root of trust. Every admin action
  is a program upgrade to a new `HOT_AUTHORITIES` list: the **kill switch** is a
  pre-staged empty-list build (one multisig tx to deploy), and **hot-key
  rotation** deploys an overlapping old+new list for zero downtime. The
  `MeshDelegate` PDA depends only on the program ID, which upgrades never
  change — so users never re-subscribe.

The program has exactly one instruction (`pull`), no state, and no on-chain
admin surface. See [solana/README.md](solana/README.md) for the design and
[solana/DEPLOY.md](solana/DEPLOY.md) for build, deploy, the kill-switch runbook,
and rotation.

```bash
cd solana
NO_DNA=1 anchor build   # deployable build + IDL
./test.sh               # 9 tests (against a test-keyed variant build)
```

`constants.rs` is committed with the production values: the Mesh puller key in
`HOT_AUTHORITIES` and the native Subscriptions program
`De1egAFMkMWZSN5rYXRj9CAdheBamobVNubTsi9avR44` as the CPI target.

## EVM (future)

Reserved. When EVM subscriptions land, add a Foundry/Hardhat workspace under
`evm/` and put its design doc in `docs/`.
