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

/// On-chain configuration — the puller-key allowlist lives in DATA, not code,
/// so key rotation and the kill switch are single transactions that never
/// modify the (audited) program binary.
#[account]
pub struct Config {
    /// The only key allowed to call `set_puller_keys` (set once, at
    /// `initialize`, to the initializer).
    pub admin: Pubkey,
    /// Pubkeys allowed to trigger `pull`. EMPTY list = kill switch ("pause"):
    /// no key is authorized, every pull fails `Unauthorized`.
    pub puller_keys: Vec<Pubkey>,
}

impl Config {
    /// 8 discriminator + 32 admin + 4 vec length + the max key list.
    pub const SPACE: usize = 8 + 32 + 4 + 32 * MAX_PULLER_KEYS;
}

#[derive(Accounts)]
pub struct Initialize<'info> {
    /// The singleton config. `init` makes re-initialization impossible.
    #[account(init, payer = admin, space = Config::SPACE, seeds = [CONFIG_SEED], bump)]
    pub config: Account<'info, Config>,

    /// Becomes the config's admin; pays the config account's rent.
    #[account(mut)]
    pub admin: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct SetPullerKeys<'info> {
    #[account(mut, seeds = [CONFIG_SEED], bump, has_one = admin @ ControllerError::Unauthorized)]
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
        Ok(())
    }

    /// Admin: replace the puller-key list. Rotation = list old+new, then
    /// remove old. Kill switch = empty list. One transaction; no upgrade.
    pub fn set_puller_keys(ctx: Context<SetPullerKeys>, puller_keys: Vec<Pubkey>) -> Result<()> {
        require!(
            puller_keys.len() <= MAX_PULLER_KEYS,
            ControllerError::TooManyPullerKeys
        );
        ctx.accounts.config.puller_keys = puller_keys;
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
