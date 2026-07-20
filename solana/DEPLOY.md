# Deploying the Mesh Subscription Controller

How to deploy, update, and undeploy — step by step first; background
(environments, testing, design) at the end. The why is in the
[TDD](../docs/solana-pull-payment-pda-tdd.md).

> **Money-moving program, mainnet-only.** The upgrade-authority wallet is the
> root of trust — whoever holds it can replace the program. No private keys
> ever live in this repo.

## How to deploy

Prerequisites: Solana CLI (Agave) `4.0.2`, Rust `1.89` (pinned in
`rust-toolchain.toml`), and a wallet (e.g. Phantom) you can export the
private key from.

**Step 1 — set the env's variables.** Open `scripts/envs/<env>.env`
(`local`, `dev`, or `prod`) and set:

```bash
# the wallet that will OWN the program: signs this deploy and every future
# upgrade/close, pays fees, receives the rent refund on undeploy.
# You hold its private key in your wallet app.
UPGRADE_AUTHORITY=<your wallet pubkey>

# pubkeys allowed to trigger `pull` — the key(s) this env's backend signs
# pulls with (private keys in that backend's Key Vault). Space-separated.
PULLER_KEYS="<puller pubkey>"
```

Leave `PROGRAM_ID` alone — it does not exist yet; the deploy writes it.

**Step 2 — fund the wallet.** Send **~1 SOL** to the `UPGRADE_AUTHORITY`
address (~0.63 SOL is a rent deposit refunded on undeploy; the rest covers
fees, leftover stays in the wallet).

**Step 3 — run the deploy.**

```bash
cd solana
scripts/deploy.sh <env>
```

The script, in order:

1. Refuses to run if `UPGRADE_AUTHORITY` or `PULLER_KEYS` is missing; warns
   loudly if `PULLER_KEYS` is empty (the on-chain config would be set to the
   kill switch).
2. Builds the program (only the program id is compiled in — puller keys
   live in the on-chain config, next step).
3. First deploy only: mints a fresh program keypair — its pubkey becomes the
   env's **permanent program id**; the private key is used for this one
   deploy and discarded (it grants nothing afterwards).
4. **Prompts you to paste the `UPGRADE_AUTHORITY` wallet's private key**
   (base58, e.g. Phantom → Settings → Export Private Key). Input is hidden,
   held in a temp file outside the repo, deleted when the script exits, and
   rejected unless it derives exactly the configured pubkey.
5. Prints the plan (env, payer, program id, artifact hash, puller keys) —
   **type `deploy`** to confirm, anything else aborts.
6. Deploys, then syncs the env's `PULLER_KEYS` into the program's on-chain
   config (creates it on the first deploy) — signed by the same wallet.
7. Pins the contract address into the `.env` and prints:

```
Smart contract address (program id) : <PROGRAM_ID>
    → set BOTH (same value): SolanaSubscriptionConfig--SmartContractAddress (Core API)
      and SolanaSubscriptionPullerConfig--SmartContractAddress (Backend Functions)
MeshDelegate PDA (informational)    : <PDA>
    → derived by the backend itself; becomes the 'delegatee' recorded on
      each subscription (DB row + on-chain delegation)
```

The PDA is `hash("mesh_delegate", PROGRAM_ID)` — the backend re-derives it
from the contract address at run time, so it is **not a config value**; the
printed value is for cross-checking the backend's derivation (it's also the
known-good test vector in `SolanaSubscriptionInstructionBuilderTests`).
Re-print anytime with `scripts/pda.sh <env>`.

**Step 4 — wire into Mesh.** One config change spanning both Azure apps
(they must always carry the same address — if they diverge, the API mints
rows under one PDA and the puller derives another; watch for the
`subscription_unpullable_active_row` signal):

- `SolanaSubscriptionConfig--SmartContractAddress` (Core API app) = the
  contract address from step 3.
- `SolanaSubscriptionPullerConfig--SmartContractAddress` (Backend Functions
  app) = the same value.
- `SolanaSubscriptionPullerConfig--PullerPrivateKey` (Key Vault secret) = the
  private key whose pubkey is in this env's `PULLER_KEYS`; set the plain
  `PullerPublicKey` setting to that pubkey so operators can verify without
  the secret. The puller signs `pull` with it and pays each pull's fee —
  keep the wallet funded with SOL and alerted on balance.

**Step 5 — verify.** Create a test subscription with a dust amount, let the
puller pull it through the controller, confirm the transfer on an explorer.
Only then enable real traffic (after the external audit).

## How to update

Key changes are DATA transactions (edit the `.env`, run `set-puller-keys.sh`)
— the audited program code is never touched, no re-audit trigger. Only code
changes redeploy. Program id and PDA never change either way; delegations are
never affected:

| Change | Edit | Run |
| --- | --- | --- |
| Kill switch (pause all pulls) | `PULLER_KEYS=""` | `scripts/set-puller-keys.sh <env>` |
| Resume | restore the keys | `scripts/set-puller-keys.sh <env>` |
| Rotate puller key (zero downtime) | 1) list old+new keys 2) after applying, flip Key Vault 3) remove old key | `scripts/set-puller-keys.sh <env>` after 1 and 3 |
| Change upgrade authority | update `UPGRADE_AUTHORITY` after running → | `solana program set-upgrade-authority <PROGRAM_ID> --new-upgrade-authority <NEW_WALLET>` |
| Code / retarget native program | source / `constants.rs` | `scripts/deploy.sh <env>` |

The config admin is the wallet that ran the first deploy (it signed
`initialize`). Never make the program immutable (`--final`) — code fixes
still need upgrades. If a new binary outgrows the allocation, the deploy
script extends it automatically.

## How to undeploy

```bash
scripts/close.sh <env>          # wallet-key prompt, then type 'close'
```

- Refunds the ~0.63 SOL rent deposit to the wallet (or pass a recipient
  pubkey as 2nd argument).
- Unpins `PROGRAM_ID` from the `.env`.
- ⚠️ **Irreversible**: a closed program id is burned forever. The env's next
  deploy mints a fresh id → fresh PDA → existing delegations die with the
  old one, and the backend `SmartContractAddress` settings must be updated.

---

## Background

**Environments.** `local` (the full Mesh environment on your machine), `dev`,
and `prod` are three independent program instances on mainnet, one `.env`
each. Own program id → own MeshDelegate PDA → own delegations: one env's
program can never pull another env's delegations. `test` is not an
environment — it's the LiteSVM fixture below.

**Design.** Three instructions: `initialize` (one-time; creator becomes
admin), `set_puller_keys` (admin-only; rewrites the on-chain allowlist —
rotation and kill switch as single transactions that never modify audited
code), and `pull` (gated by the allowlist, CPIs the native program signing as
the MeshDelegate PDA). The PDA derives from `["mesh_delegate"]` + the program
id only, so neither upgrades nor config updates ever move it or invalidate a
delegation. `SUBSCRIPTIONS_PROGRAM` (the native program CPI'd into) stays a
compile-time constant, identical on all envs.

**Testing.**

```bash
./test.sh                       # 11 LiteSVM tests must pass
```

The committed source carries the `test` program id (`scripts/build.sh <env>`
injects a real env's id into a build, then restores the source). The suite
creates the on-chain Config itself with keypairs derived from public seeds
(`[1u8;32]` / `[2u8;32]`) so it can sign — anyone can reproduce them, which
is why `test` is never deployable. Covered: config lifecycle (initialize-once,
admin gating, rotation, kill switch + resume) and an end-to-end subscribe +
pull against the real native Subscriptions binary dumped from mainnet
(`tests/fixtures/subscriptions_program.so`).

**Releases.** Record the git commit per deploy;
[`solana-verify`](https://github.com/Ellipsis-Labs/solana-verifiable-build)
lets anyone match on-chain bytes to source. Optional IDL for explorers /
codegen: `NO_DNA=1 anchor build`, then
`anchor idl init --provider.cluster mainnet --filepath target/idl/subscription_controller.json <PROGRAM_ID>`.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `Unauthorized` on **every** pull | Kill-switch build (empty `PULLER_KEYS`) is live. |
| `Unauthorized` on **some** pulls | Signing key not in the deployed `PULLER_KEYS` — mid-rotation or Key Vault / build drift. |
| `WrongTargetProgram` | Passed `subscriptions_program` ≠ the `SUBSCRIPTIONS_PROGRAM` constant. |
| Pulls fail after an upgrade | Wrong env's build deployed — verify with `solana-verify`. |
| Build errors | Toolchain drift — re-pin (Agave `4.0.2`, Rust `1.89`). |
