pub mod constants;
pub mod error;

use anchor_lang::prelude::*;
use anchor_lang::solana_program::{
    instruction::{AccountMeta, Instruction},
    program::invoke_signed,
};

pub use constants::*;
pub use error::*;

declare_id!("GowYj1dH8kM9sD88cEFk8PExCkct7AqLWGvTkWz6evoD");

// Embedded contact info for security researchers (parsed by explorers —
// shows as "security.txt" on Solscan). Baked into the binary; applies to an
// env on its next deploy/upgrade.
#[cfg(not(feature = "no-entrypoint"))]
solana_security_txt::security_txt! {
    name: "Mesh Subscription Controller",
    project_url: "https://www.meshconnect.com",
    contacts: "email:security@meshconnect.com",
    policy: "Please report vulnerabilities privately to the contact above. Do not exploit or publicly disclose before a fix is deployed.",
    preferred_languages: "en"
}

/// On-chain configuration — the puller-key allowlist lives in DATA, not code,
/// so key rotation and the kill switch are single transactions that never
/// modify the (audited) program binary.
#[account]
pub struct Config {
    /// The only key allowed to call the admin instructions (set at
    /// `initialize` to the initializer; changed via the two-step handover).
    pub admin: Pubkey,
    /// Pubkeys allowed to trigger `pull`. EMPTY list = kill switch ("pause"):
    /// no key is authorized, every pull fails `Unauthorized`.
    pub puller_keys: Vec<Pubkey>,
    /// Two-step admin handover target: `propose_admin` sets it, `accept_admin`
    /// (signed by it) promotes it. `Pubkey::default()` = none pending.
    /// NB: do not reorder `Config`'s fields once deployed — the on-chain
    /// account layout is fixed at creation, and reordering would misread every
    /// existing config.
    pub pending_admin: Pubkey,
}

impl Config {
    /// 8 discriminator + 32 admin + (4 vec len + max key list) + 32 pending.
    pub const SPACE: usize = 8 + 32 + (4 + 32 * MAX_PULLER_KEYS) + 32;
}

/// The keys a pull may pay. A pull is only accepted if the token account the
/// CPI actually credited is the canonical associated token account of one of
/// these owners, so a compromised puller key can move money on schedule but
/// cannot redirect it.
///
/// This is a SEPARATE account rather than two more `Config` fields because
/// `Config`'s byte layout is frozen by the live deployments (see
/// `DESTINATIONS_SEED`). `version` is field 0, so it is always at offset 8
/// regardless of how long the list is.
#[account]
pub struct DestinationRegistry {
    /// Layout version. Must equal `DESTINATION_REGISTRY_VERSION` or `pull`
    /// refuses to run.
    pub version: u8,
    /// SPL token-account owners allowed to receive a pull. EMPTY = no
    /// destination is payable, so every pull fails — the same fail-closed
    /// shape as an empty puller-key list.
    pub destination_owners: Vec<Pubkey>,
}

impl DestinationRegistry {
    /// 8 discriminator + 1 version + (4 vec len + max owner list).
    pub const SPACE: usize = 8 + 1 + (4 + 32 * MAX_DESTINATIONS);
}

/// Emitted after a pull settles. `destination`, `destination_owner` and
/// `amount` are read back from the token accounts AFTER the CPI, so they
/// describe where the money actually went and how much actually arrived — not
/// what the caller asked for. `delegation` is the caller's account slot and is
/// informational only.
#[event]
pub struct PullExecuted {
    pub puller: Pubkey,
    pub delegation: Pubkey,
    pub delegator: Pubkey,
    pub mint: Pubkey,
    pub destination: Pubkey,
    pub destination_owner: Pubkey,
    pub amount: u64,
}

#[derive(Accounts)]
pub struct Initialize<'info> {
    /// The singleton config. `init` makes re-initialization impossible.
    #[account(init, payer = admin, space = Config::SPACE, seeds = [CONFIG_SEED], bump)]
    pub config: Account<'info, Config>,

    /// Becomes the config's admin; pays the config account's rent. Gated to the
    /// program's upgrade authority (see `program_data`), so `initialize` cannot
    /// be front-run by an arbitrary caller right after deploy.
    #[account(mut)]
    pub admin: Signer<'info>,

    /// The program's ProgramData account (BPF upgradeable loader). Its recorded
    /// upgrade authority must equal `admin` — this is what restricts
    /// `initialize` to whoever controls the deployed program.
    #[account(
        seeds = [crate::ID.as_ref()],
        bump,
        seeds::program = anchor_lang::solana_program::bpf_loader_upgradeable::ID,
        constraint = program_data.upgrade_authority_address == Some(admin.key()) @ ControllerError::Unauthorized,
    )]
    pub program_data: Account<'info, ProgramData>,

    pub system_program: Program<'info, System>,
}

/// Any admin-gated mutation (set puller keys, propose a new admin).
#[derive(Accounts)]
pub struct AdminAction<'info> {
    #[account(mut, seeds = [CONFIG_SEED], bump, has_one = admin @ ControllerError::Unauthorized)]
    pub config: Account<'info, Config>,

    pub admin: Signer<'info>,
}

/// Second step of the handover: the pending admin claims the role.
#[derive(Accounts)]
pub struct AcceptAdmin<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump,
        constraint = config.pending_admin == new_admin.key() @ ControllerError::Unauthorized,
    )]
    pub config: Account<'info, Config>,

    pub new_admin: Signer<'info>,
}

/// Reclaim the config account's rent (teardown). Admin-gated; refund → admin.
#[derive(Accounts)]
pub struct CloseConfig<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump,
        has_one = admin @ ControllerError::Unauthorized,
        constraint = config.pending_admin == Pubkey::default() @ ControllerError::HandoverPending,
        close = admin,
    )]
    pub config: Account<'info, Config>,

    /// Receives the config's rent, so it must be writable even when it is not
    /// the fee payer (a Squads vault admin never is).
    #[account(mut)]
    pub admin: Signer<'info>,
}

/// One-time creation of the destination registry. Gated on the config's admin,
/// exactly like `set_puller_keys`.
#[derive(Accounts)]
pub struct InitializeDestinationRegistry<'info> {
    #[account(seeds = [CONFIG_SEED], bump, has_one = admin @ ControllerError::Unauthorized)]
    pub config: Account<'info, Config>,

    #[account(
        init,
        payer = admin,
        space = DestinationRegistry::SPACE,
        seeds = [DESTINATIONS_SEED],
        bump,
    )]
    pub destination_registry: Account<'info, DestinationRegistry>,

    #[account(mut)]
    pub admin: Signer<'info>,

    pub system_program: Program<'info, System>,
}

/// Admin: replace the destination-owner list.
#[derive(Accounts)]
pub struct SetDestinationOwners<'info> {
    #[account(seeds = [CONFIG_SEED], bump, has_one = admin @ ControllerError::Unauthorized)]
    pub config: Account<'info, Config>,

    /// Resized to the binary's current `SPACE` on every write. Without this an
    /// account keeps the size it was created with, so raising
    /// `MAX_DESTINATIONS` in a later upgrade could never take effect.
    #[account(
        mut,
        seeds = [DESTINATIONS_SEED],
        bump,
        realloc = DestinationRegistry::SPACE,
        realloc::payer = admin,
        realloc::zero = false,
    )]
    pub destination_registry: Account<'info, DestinationRegistry>,

    #[account(mut)]
    pub admin: Signer<'info>,

    pub system_program: Program<'info, System>,
}

/// Trigger one recurring-delegation pull.
///
/// The program is a *verified signer proxy*: it checks the gate (signer is in
/// the config's puller-key list, CPI target is the configured native
/// Subscriptions program), then forwards the caller-supplied native pull
/// instruction, signing as the `MeshDelegate` PDA via `invoke_signed`. The
/// native program still enforces all of its own invariants
/// (`amount_per_period` cap, period rollover, expiry, delegatee-must-sign).
///
/// `remaining_accounts` MUST be the exact ordered account list the native
/// `pull` instruction expects, and MUST include the `MeshDelegate` PDA (it is
/// force-marked as signer here). `native_data` is the pre-encoded native
/// `pull` instruction data.
///
/// WIRE CHANGE: `destination_registry` is a named account, so it is consumed
/// positionally from the front of the account list, before `remaining_accounts`
/// begins. Every caller must insert it at index 4.
#[derive(Accounts)]
pub struct Pull<'info> {
    /// CHECK: The `MeshDelegate` PDA; validated by seeds. Signs the native pull
    /// via `invoke_signed`. Must also be present in `remaining_accounts`.
    #[account(seeds = [DELEGATE_SEED], bump)]
    pub delegate: UncheckedAccount<'info>,

    /// Operational key authorizing this pull (and paying the tx fee). Must be
    /// listed in `config.puller_keys` (checked in the handler).
    pub puller_key: Signer<'info>,

    /// CHECK: verified to equal `SUBSCRIPTIONS_PROGRAM`; used as the CPI target.
    #[account(address = SUBSCRIPTIONS_PROGRAM @ ControllerError::WrongTargetProgram)]
    pub subscriptions_program: UncheckedAccount<'info>,

    /// The on-chain puller-key allowlist.
    #[account(seeds = [CONFIG_SEED], bump)]
    pub config: Account<'info, Config>,

    /// The on-chain destination allowlist. Not optional: a pull with no
    /// registry account fails to deserialize, so omitting it denies the pull
    /// instead of skipping the destination check.
    #[account(seeds = [DESTINATIONS_SEED], bump)]
    pub destination_registry: Account<'info, DestinationRegistry>,
}

// These helpers live at the crate root, NOT inside `#[program] pub mod`.
// Anchor collects any fn in that module whose first argument is not a
// `Context<..>` as the program's fallback function, and this program has none.
struct TokenAccountSnapshot {
    address: Pubkey,
    token_program: Pubkey,
    owner: Pubkey,
    amount: u64,
}

struct CreditedDestination {
    address: Pubkey,
    token_program: Pubkey,
    owner: Pubkey,
    received: u64,
}

fn pubkey_at(data: &[u8], offset: usize) -> Pubkey {
    let mut bytes = [0u8; 32];
    bytes.copy_from_slice(&data[offset..offset + 32]);
    Pubkey::new_from_array(bytes)
}

fn is_token_program(program_id: &Pubkey) -> bool {
    *program_id == TOKEN_PROGRAM || *program_id == TOKEN_2022_PROGRAM
}

fn snapshot_token_accounts(
    accounts: &[AccountInfo<'_>],
    mint: &Pubkey,
) -> Result<Vec<TokenAccountSnapshot>> {
    let mut snapshots: Vec<TokenAccountSnapshot> = Vec::new();
    for account in accounts {
        if !is_token_program(account.owner) {
            continue;
        }
        if snapshots.iter().any(|s| s.address == *account.key) {
            continue;
        }
        let borrowed = account.try_borrow_data()?;
        let data: &[u8] = &**borrowed;
        if data.len() < SPL_TOKEN_ACCOUNT_LEN || &data[0..32] != mint.as_ref() {
            continue;
        }
        let mut amount = [0u8; 8];
        amount.copy_from_slice(&data[64..72]);
        snapshots.push(TokenAccountSnapshot {
            address: *account.key,
            token_program: *account.owner,
            owner: pubkey_at(data, 32),
            amount: u64::from_le_bytes(amount),
        });
    }
    Ok(snapshots)
}

fn credited_destination(
    before: &[TokenAccountSnapshot],
    after: &[TokenAccountSnapshot],
) -> Result<CreditedDestination> {
    let mut credited: Option<CreditedDestination> = None;
    for account in after {
        let previous = before
            .iter()
            .find(|s| s.address == account.address)
            .map_or(0, |s| s.amount);
        if account.amount <= previous {
            continue;
        }
        require!(
            credited.is_none(),
            ControllerError::MultipleDestinationsCredited
        );
        credited = Some(CreditedDestination {
            address: account.address,
            token_program: account.token_program,
            owner: account.owner,
            received: account.amount - previous,
        });
    }
    credited.ok_or_else(|| error!(ControllerError::NoDestinationCredited))
}

fn is_canonical_associated_token_account(
    address: &Pubkey,
    owner: &Pubkey,
    token_program: &Pubkey,
    mint: &Pubkey,
) -> bool {
    let (expected, _bump) = Pubkey::find_program_address(
        &[owner.as_ref(), token_program.as_ref(), mint.as_ref()],
        &ASSOCIATED_TOKEN_PROGRAM,
    );
    expected == *address
}

#[program]
pub mod subscription_controller {
    use super::*;

    /// One-time setup: create the config with the initial puller-key list.
    /// The signer becomes the admin. Cannot be called twice (`init`).
    pub fn initialize(ctx: Context<Initialize>, puller_keys: Vec<Pubkey>) -> Result<()> {
        require!(
            puller_keys.len() <= MAX_PULLER_KEYS,
            ControllerError::TooManyPullerKeys
        );
        let config = &mut ctx.accounts.config;
        config.admin = ctx.accounts.admin.key();
        config.puller_keys = puller_keys;
        config.pending_admin = Pubkey::default();
        Ok(())
    }

    /// Admin: replace the puller-key list. Rotation = list old+new, then
    /// remove old. Kill switch = empty list. One transaction; no upgrade.
    pub fn set_puller_keys(ctx: Context<AdminAction>, puller_keys: Vec<Pubkey>) -> Result<()> {
        require!(
            puller_keys.len() <= MAX_PULLER_KEYS,
            ControllerError::TooManyPullerKeys
        );
        ctx.accounts.config.puller_keys = puller_keys;
        Ok(())
    }

    /// Admin: create the destination registry with its initial owner list.
    /// Must run BEFORE the upgraded program serves traffic — `pull` requires
    /// the registry, so until it exists every pull is denied.
    pub fn initialize_destination_registry(
        ctx: Context<InitializeDestinationRegistry>,
        destination_owners: Vec<Pubkey>,
    ) -> Result<()> {
        require!(
            destination_owners.len() <= MAX_DESTINATIONS,
            ControllerError::TooManyDestinations
        );
        let registry = &mut ctx.accounts.destination_registry;
        registry.version = DESTINATION_REGISTRY_VERSION;
        registry.destination_owners = destination_owners;
        Ok(())
    }

    /// Admin: replace the destination-owner list. Same gate as
    /// `set_puller_keys`. An empty list pays nobody, so it is a second, finer
    /// kill switch that stops payouts without disabling the puller keys.
    pub fn set_destination_owners(
        ctx: Context<SetDestinationOwners>,
        destination_owners: Vec<Pubkey>,
    ) -> Result<()> {
        require!(
            destination_owners.len() <= MAX_DESTINATIONS,
            ControllerError::TooManyDestinations
        );
        ctx.accounts.destination_registry.destination_owners = destination_owners;
        Ok(())
    }

    /// Admin: propose a new admin (step 1 of 2). Nothing changes until the
    /// proposed key calls `accept_admin`, so a typo cannot brick the config —
    /// re-propose to correct it. Pass `Pubkey::default()` to cancel a pending
    /// handover.
    pub fn propose_admin(ctx: Context<AdminAction>, new_admin: Pubkey) -> Result<()> {
        ctx.accounts.config.pending_admin = new_admin;
        Ok(())
    }

    /// Pending admin: accept the handover (step 2 of 2). Signed by the
    /// proposed key, proving it is controllable before it gains power.
    pub fn accept_admin(ctx: Context<AcceptAdmin>) -> Result<()> {
        let config = &mut ctx.accounts.config;
        config.admin = ctx.accounts.new_admin.key();
        config.pending_admin = Pubkey::default();
        Ok(())
    }

    /// Admin: close the config account and reclaim its rent (teardown only —
    /// afterwards `pull` fails until a new config is initialized). Do this
    /// while the program is still live; closing the program first orphans the
    /// config's rent.
    pub fn close_config(_ctx: Context<CloseConfig>) -> Result<()> {
        Ok(())
    }

    /// Puller key: gate + forward one native pull, signing as `MeshDelegate`.
    pub fn pull<'info>(ctx: Context<'info, Pull<'info>>, native_data: Vec<u8>) -> Result<()> {
        // Authorization: the signer must be listed in the config. An empty
        // list authorizes no one, which is the kill switch ("pause").
        // Target-program identity is enforced by the `address =` constraint.
        require!(
            ctx.accounts
                .config
                .puller_keys
                .contains(&ctx.accounts.puller_key.key()),
            ControllerError::Unauthorized
        );

        // Forward ONLY the native recurring pull_payment (pin its single-byte
        // discriminator + exact length). A puller key therefore cannot invoke
        // any other native instruction as the delegatee. The amount within
        // pull_payment stays caller-chosen (the native program caps it per
        // period); the destination does NOT — see the balance-delta proof below.
        require!(
            native_data.first() == Some(&NATIVE_PULL_DISCRIMINATOR)
                && native_data.len() == NATIVE_PULL_DATA_LEN,
            ControllerError::UnexpectedNativeInstruction
        );

        require!(
            ctx.accounts.destination_registry.version == DESTINATION_REGISTRY_VERSION,
            ControllerError::UnsupportedRegistryVersion
        );

        let delegator = pubkey_at(&native_data, NATIVE_PULL_DELEGATOR_OFFSET);
        let mint = pubkey_at(&native_data, NATIVE_PULL_MINT_OFFSET);

        // Record every token account of this mint BEFORE the CPI. The
        // destination is never taken from a fixed account index — a caller
        // controls the order of `remaining_accounts`, so an index proves
        // nothing. Every borrow taken here is dropped before `invoke_signed`.
        let before = snapshot_token_accounts(ctx.remaining_accounts, &mint)?;

        // Build the CPI instruction from the forwarded accounts, force-signing
        // the MeshDelegate PDA.
        let delegate_key = ctx.accounts.delegate.key();
        let metas: Vec<AccountMeta> = ctx
            .remaining_accounts
            .iter()
            .map(|a| AccountMeta {
                pubkey: *a.key,
                is_signer: a.is_signer || a.key == &delegate_key,
                is_writable: a.is_writable,
            })
            .collect();

        let ix = Instruction {
            program_id: SUBSCRIPTIONS_PROGRAM,
            accounts: metas,
            data: native_data,
        };

        // `invoke_signed` needs AccountInfos for every account referenced by
        // the instruction plus the target program account.
        let mut infos = ctx.remaining_accounts.to_vec();
        infos.push(ctx.accounts.subscriptions_program.to_account_info());

        let signer_seeds: &[&[u8]] = &[DELEGATE_SEED, &[ctx.bumps.delegate]];

        invoke_signed(&ix, &infos, &[signer_seeds])?;

        // Re-read the same accounts. Exactly one must have gained balance;
        // that account IS the destination, proven rather than inferred. Zero
        // means nothing was paid (source == destination, for example) and more
        // than one means the payout cannot be attributed — both revert.
        let after = snapshot_token_accounts(ctx.remaining_accounts, &mint)?;
        let credited = credited_destination(&before, &after)?;

        require!(
            ctx.accounts
                .destination_registry
                .destination_owners
                .contains(&credited.owner),
            ControllerError::DestinationOwnerNotAllowlisted
        );

        // The owner field is written by whoever initialized the token account
        // and needs no signature from the named owner, so an attacker can mint
        // an account that claims to belong to a real merchant. Requiring the
        // canonical ATA address closes that: only the merchant can spend from
        // the one account this derivation can name.
        require!(
            is_canonical_associated_token_account(
                &credited.address,
                &credited.owner,
                &credited.token_program,
                &mint,
            ),
            ControllerError::DestinationIsNotCanonicalAta
        );

        emit!(PullExecuted {
            puller: ctx.accounts.puller_key.key(),
            delegation: ctx
                .remaining_accounts
                .first()
                .map(|a| *a.key)
                .unwrap_or_default(),
            delegator,
            mint,
            destination: credited.address,
            destination_owner: credited.owner,
            amount: credited.received,
        });

        Ok(())
    }
}
