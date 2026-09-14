# Deploying the Mesh Subscription Controller

Steps first, background last. The why is in the
[TDD](docs/solana-subscription-controller-tdd.md).

> **Mainnet-only, money-moving.** Every signature is a popup in your browser
> wallet (Phantom / Solflare / Backpack) via a localhost bridge — no private
> key is ever pasted or stored, and your wallet stays the owner. Approve
> popups within ~60s (blockhash expiry; scripts offer a retry).

Prerequisites: Solana CLI (Agave) `4.0.2`, Rust `1.89`, a Wallet Standard
browser wallet.

## Deploy (first time for an env)

1. **Configure** `scripts/envs/<env>.env` (`local`, `dev`, or `prod`):
  ```bash
   UPGRADE_AUTHORITY=<your wallet pubkey>   # owns the program: signs upgrades/close, becomes config admin
   PULLER_KEYS="<puller pubkey>"            # key(s) the env's backend signs pulls with (space-separated)
  ```
   Don't set `PROGRAM_ID` — the deploy writes it.
2. **Fund**: ~~0.75 SOL in the wallet (~~0.65 becomes the program's rent
  deposit, refunded on undeploy; leftovers return automatically).
3. **Run**:
  ```bash
   cd solana
   scripts/deploy.sh <env>
  ```
   Review the printed plan, type `deploy`, then approve **two popups**:
   fund the temporary payer, and initialize the on-chain config.
4. **Copy the printed outputs into the backend** (both Azure apps, same
  value):
  - `SolanaSubscriptionConfig--SmartContractAddress` (Core API) = the
  printed **smart contract address**.
  - `SolanaSubscriptionPullerConfig--SmartContractAddress` (Backend
  Functions) = the same value.
  - `SolanaSubscriptionPullerConfig--PullerPrivateKey` (Key Vault) = the
  puller key's secret; `PullerPublicKey` = its pubkey. Keep the puller
  wallet funded (it pays pull fees).
   The printed **MeshDelegate PDA** is informational — the backend derives it
   from the contract address itself; it becomes each subscription's
   `delegatee`. Re-print anytime: `scripts/pda.sh <env>`.
   The deploy also saves these values into `scripts/envs/<env>.env`
   (`PROGRAM_ID` + the PDA as a comment). **Commit that file** — everything
   in it is public, and with no registry/DB yet the committed `.env` files
   are the source of truth for what each environment runs.
5. **Verify** with a smallest-allowed subscription: subscribe → auto-pull
  through the controller → check the transfer on an explorer. The pull amount
  must be at least `MIN_PULL_AMOUNT` (10,000 base units, $0.01 in six-decimal
  USDC); anything smaller is rejected with `AmountBelowMinimum`.



## Update puller keys (rotation / kill switch)

A single data transaction — no rebuild, no redeploy, audited code untouched.
Program id, PDA, and existing delegations never change.

1. **Configure** `scripts/envs/<env>.env`: set `PULLER_KEYS` to the new
  space-separated list. Rotation: list old **and** new. Kill switch: `""`.
   Resume: restore the keys.
2. **Run** and approve **one popup**:
  ```bash
   scripts/set-puller-keys.sh <env>
  ```
3. For a zero-downtime rotation, finish by flipping the backend's Key Vault
  secret to the new key, then repeat steps 1–2 with the old key removed.



## Change the config admin

A two-step handover (a typo can't brick admin — power moves only once the new
wallet accepts). Two transactions signed by two different wallets:

1. **Current admin proposes** the new admin (browser popup, current wallet):
  ```bash
   scripts/change-admin.sh <env> propose <new-admin-pubkey>
  ```
2. **New admin accepts** (browser popup, new wallet):
  ```bash
   scripts/change-admin.sh <env> accept <new-admin-pubkey>
  ```
   If you control both wallets, run both yourself. Then update
   `UPGRADE_AUTHORITY` in `scripts/envs/<env>.env` to the new wallet.

### The upgrade authority outranks the config admin

While a single wallet still holds the upgrade authority, an admin handover is
**not** a boundary against that wallet. It can take the admin role back:

- The upgrade authority can replace the program's code with anything.
- `initialize` is gated on the upgrade authority and the `Config` PDA has a
  fixed seed, so once the config account is closed the upgrade authority can
  call `initialize` again and be admin.

So treat "upgrade authority" and "config admin" as one role until
`scripts/migrate-to-squads.sh` has moved **both** to a Squads multisig. Only
then does the handover mean anything on its own.



## Upgrade code

Same program id, same PDA — delegations and backend config are unaffected.

1. **Change the source** (`programs/subscription-controller/`) and check the
  tests pass:
2. **Run**:
  ```bash
   cd solana
   scripts/upgrade.sh <env>
  ```
   Type `upgrade` to confirm, then approve **two popups**: fund the temporary
   payer, and sign the upgrade (~0.7 SOL fronted from the wallet, returned
   when the upgrade lands).

Never make the program immutable (`--final`) — upgrades are how code gets
fixed. Binary growth is handled automatically.

### Stray upgrade buffers

An interrupted upgrade leaves its staged buffer on chain. The buffer holds
rent, and while the upgrade authority owns it it is a second live way to
upgrade the program — so check after any run that did not finish:

```bash
scripts/buffers.sh <env>            # list what the authority still holds
scripts/buffers.sh <env> --close    # close them, rent back to the authority
```

`--close` needs the authority key, so it works only while the authority is a
wallet you hold. Once it is a Squads vault, close the buffers from the Squads
app instead.

## Undeploy

```bash
scripts/close.sh <env>          # type 'close', then approve one wallet popup
```

Refunds the rent deposit and unpins `PROGRAM_ID`. ⚠️ Irreversible: a closed
program id is burned; the next deploy mints a fresh id → fresh PDA →
existing delegations die and the backend `SmartContractAddress` must be
updated.

After `scripts/migrate-to-squads.sh`, the config admin is a Squads vault. A
vault is a program address: it has no private key, so it can neither pay a
transaction fee nor sign in a browser wallet. Teardown is then two steps:

```bash
scripts/close.sh <env> --print   # prints the close_config instruction for Squads
scripts/close.sh <env>           # after the Squads tx lands: burns the program id
```

The script checks both signers up front and stops before anything is
destroyed if either one is a program address.

---



## Background

**Environments.** `local` (the full Mesh environment on your machine), `dev`,
and `prod` are independent program instances on mainnet, one `.env` each:
own program id → own MeshDelegate PDA → own delegations. `test` is the
LiteSVM fixture for `./test.sh`, never deployable.

**Design.** Instructions: `initialize` (once; callable only by the program's
upgrade authority, who becomes admin — so it can't be front-run after
deploy), `set_puller_keys` (admin-only allowlist update — rotation/kill switch
without touching audited code), a two-step admin handover (`propose_admin` →
`accept_admin`, so a typo can't brick admin control), and `pull`
(gated by the allowlist, forwards ONLY the native `pull_payment` — discriminator
and length pinned — signing as the MeshDelegate PDA). The PDA is
`hash("mesh_delegate", program id)` — upgrades and config updates never move
it. `SUBSCRIPTIONS_PROGRAM` (the native program) is a compile-time constant,
identical on all envs.

**How signing works.** Scripts build transactions (`tools/admin-cli`), a
localhost page (`scripts/sign_in_browser.py`) hands them to your wallet, you
approve. Deploy/upgrade working capital is fronted from the wallet into a
temporary payer (popup) and swept back on exit — the wallet is the only
funded wallet. Alternatives: `FEE_PAYER=<path>` (standing hot payer, one
fewer popup), `set-puller-keys.sh --paste` (legacy hidden key prompt), and a
Squads multisig path for later (`scripts/migrate-to-squads.sh`,
`scripts/stage-upgrade.sh`, `set-puller-keys.sh --print`) — start 1-of-1,
add members/threshold when prod needs it.

**Testing.**

```bash
./test.sh                       # 25 LiteSVM tests must pass
```

The suite creates the on-chain Config itself with keypairs derived from
public seeds, and includes an end-to-end subscribe + pull against the real
native Subscriptions binary dumped from mainnet
(`tests/fixtures/subscriptions_program.so`). Refresh it with
`solana program dump De1egAFMkMWZSN5rYXRj9CAdheBamobVNubTsi9avR44 programs/subscription-controller/tests/fixtures/subscriptions_program.so -u mainnet-beta`.

**Releases.** Record the git commit per deploy;
`[solana-verify](https://github.com/Ellipsis-Labs/solana-verifiable-build)`
matches on-chain bytes to source. Optional IDL: `NO_DNA=1 anchor build`, then
`anchor idl init --provider.cluster mainnet --filepath target/idl/subscription_controller.json <PROGRAM_ID>`.

## Troubleshooting


| Symptom                                   | Likely cause                                                            |
| ----------------------------------------- | ----------------------------------------------------------------------- |
| `Unauthorized` on **every** pull          | Kill switch engaged (empty on-chain key list).                          |
| `Unauthorized` on **some** pulls          | Signing key not in the on-chain list — mid-rotation or Key Vault drift. |
| `AccountNotInitialized` on pull           | Config never initialized — run `scripts/set-puller-keys.sh <env>`.      |
| `WrongTargetProgram`                      | Passed `subscriptions_program` ≠ the `SUBSCRIPTIONS_PROGRAM` constant.  |
| Wallet popup fails with a blockhash error | Took longer than ~60s — retry when the script offers.                   |
| Build errors                              | Toolchain drift — re-pin (Agave `4.0.2`, Rust `1.89`).                  |


