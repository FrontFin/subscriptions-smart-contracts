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
        close = admin,
    )]
    pub config: Account<'info, Config>,

    pub admin: Signer<'info>,
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
    pub fn pull<'info>(
        ctx: Context<'info, Pull<'info>>,
        native_data: Vec<u8>,
    ) -> Result<()> {
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
        // any other native instruction as the delegatee. Destination/amount
        // within pull_payment stay caller-chosen (accepted design tradeoff).
        require!(
            native_data.first() == Some(&NATIVE_PULL_DISCRIMINATOR)
                && native_data.len() == NATIVE_PULL_DATA_LEN,
            ControllerError::UnexpectedNativeInstruction
        );

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
        Ok(())
    }
}
