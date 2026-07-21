# Mesh Subscription Controller — Implementation TDD

| | |
| --- | --- |
| **Status** | Implemented (mainnet-only) |
| **Program** | `subscription-controller` (Anchor 1.0.1) — `solana/` |
| **Overview** | repo root [`README.md`](../README.md) |
| **Backend integration** | `FrontBackEnd/docs/solana-subscriptions-controller-pull-plan.md` |

## Summary

A stateless **signer proxy** between the Mesh puller and Solana's native
Subscriptions program (`De1egAF…`). It owns one PDA, **`MeshDelegate`**
(`seeds=["mesh_delegate"]`), registered as the `delegatee` on every recurring
delegation. A PDA has no private key, so only this program can sign as the
delegatee — and only on the `pull` path, after a gate. It holds no funds and
enforces no financial rules; the native program still enforces the per-period
cap, rollover, expiry, and delegatee-must-sign. The controller decides *who*
may pull and *that it is a pull*.

```
puller (hot key) → controller.pull → invoke_signed(MeshDelegate) → native pull_payment → user USDC → merchant USDC
                       ↑ gate reads Config.puller_keys (admin-managed)
```

## Accounts & instructions

- **`Config`** PDA (`seeds=["config"]`): `admin: Pubkey`, `puller_keys: Vec<Pubkey>` (≤16), `pending_admin: Pubkey`. `SPACE=588` (fixed; no realloc).
- `initialize(puller_keys)` — create `Config`; caller becomes admin. **Gated to the program's upgrade authority.**
- `set_puller_keys(keys)` — admin; replace the allow-list (empty = kill switch).
- `propose_admin(new)` / `accept_admin()` — two-step admin handover.
- `close_config()` — admin; reclaim config rent (teardown).
- `pull(native_data)` — puller; gate then forward the native `pull_payment` as `MeshDelegate`.

## Key decisions (this iteration)

1. **Puller-key allow-list lives in an on-chain `Config` account, not in code.**
   *Why:* rotation and the kill switch became data transactions, so they never
   change the program binary — an in-code key list meant every rotation was an
   unaudited redeploy that invalidated the verified build. This was the
   audit-driven pivot from the original stateless-constants design.

2. **Puller keys are rotatable; empty list is the kill switch.**
   Rotation: list old+new → switch the puller → drop old (delegatee never
   changes, no user re-subscribes). Kill switch: `puller_keys = []` → every
   `pull` fails `Unauthorized`, instantly and reversibly; funds/subscriptions
   untouched. There is no separate `Paused` flag — empty list *is* pause.

3. **Two-step admin handover** (`propose_admin` → `accept_admin`), replacing a
   one-step setter. *Why:* a one-step handover to a typo'd/uncontrolled address
   permanently bricks admin. Two-step requires the incoming key to sign
   `accept_admin`, proving control before power moves; a bad proposal simply
   never lands.

4. **`initialize` is gated to the program's upgrade authority** (via the
   `ProgramData` account constraint). *Why:* `initialize` is otherwise
   permissionless and could be front-run right after deploy to seize admin.
   Gating makes only the deploying party able to initialize.

5. **`pull` pins the native instruction** to `pull_payment` (single-byte
   discriminator `5` + exact length `73`). *Why:* the proxy forwards
   caller-supplied CPI data as `MeshDelegate`; without the pin a puller key
   could invoke *any* native instruction as the delegatee. The pin narrows the
   surface to exactly the recurring pull.

6. **`MeshDelegate` seed is `"mesh_delegate"`**, frozen. Derived from the
   program id alone, so it is stable across upgrades and key rotations; a seed
   change would strand every existing delegation.

7. **Accepted tradeoff (H1):** within `pull_payment` the destination and amount
   are caller-chosen, so a compromised puller key can pull up to the per-period
   cap to any address. Bounded by kill switch + rotation, **not** by this
   program. A destination allow-list was deliberately left out to keep the
   program minimal; revisit if the threat model demands it.

## Operational model (decisions)

- **Mainnet only.** No devnet. Pre-deploy validation is the LiteSVM suite
  running an end-to-end pull against the real native program binary dumped
  from mainnet.
- **Environments** — `local` (full Mesh env on a dev machine), `dev`, `prod`
  are independent program instances on mainnet: each has its own program id →
  its own `MeshDelegate` PDA → its own delegations, never crossing. `test` is
  the LiteSVM fixture, never deployable (its puller keys derive from public
  seeds). Per-env config (`scripts/envs/<env>.env`) holds only public values
  and is committed as the source of truth (no registry/DB yet).
- **No private keys in the repo.** The program keypair is minted in a temp file
  at first deploy and discarded (its pubkey is the permanent program id). All
  admin/deploy signatures happen in a **browser wallet** via a localhost bridge
  (Wallet Standard); deploy/upgrade working capital is fronted from the wallet
  into an ephemeral payer and swept back on exit.
- **20% allocation headroom** on first deploy, so later code upgrades fit
  without a separate `solana program extend` (which needs the upgrade
  authority to sign — a step the browser flow doesn't do).
- **Trust root:** admin and program upgrade authority are one wallet today;
  they *can* be split (the tooling reads the live on-chain admin). A Squads
  multisig migration path is scaffolded but not adopted.

## Backend integration

The backend config setting `SmartContractAddress` = the controller's program
id, set on both Core API and Backend Functions apps. The backend **derives**
the `MeshDelegate` PDA from it (never a config value) and registers that PDA
as each subscription's `delegatee`; the puller signs the controller's `pull`
instead of the native pull.

## Testing & assurance

15 LiteSVM tests: gate (unlisted/wrong-target/non-pull_payment rejected, every
listed key passes), config lifecycle (init-once, upgrade-authority gate, admin
gating, two-step handover, kill switch, close), and an end-to-end
subscribe + pull against the mainnet-dumped native binary. Embedded
`security.txt`. **External audit + dust-amount mainnet validation required
before real traffic.**
