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

/// Trigger one recurring-delegation pull.
///
/// The program is a *verified signer proxy* with no state: it checks the
/// compile-time gate (kill switch not engaged, signer is an authorized puller
/// key, CPI target is the configured native Subscriptions program), then
/// forwards the caller-supplied native pull instruction, signing as the
/// `MeshDelegate` PDA via `invoke_signed`. The native program still enforces
/// all of its own invariants (`amount_per_period` cap, period rollover,
/// expiry, delegatee-must-sign).
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
    /// one of `PULLER_KEYS` (checked in the handler).
    pub puller_key: Signer<'info>,

    /// CHECK: verified to equal `SUBSCRIPTIONS_PROGRAM`; used as the CPI target.
    #[account(address = SUBSCRIPTIONS_PROGRAM @ ControllerError::WrongTargetProgram)]
    pub subscriptions_program: UncheckedAccount<'info>,
}

#[program]
pub mod subscription_controller {
    use super::*;

    /// Puller key: gate + forward one native pull, signing as `MeshDelegate`.
    pub fn pull<'info>(
        ctx: Context<'info, Pull<'info>>,
        native_data: Vec<u8>,
    ) -> Result<()> {
        // Authorization: the signer must be a listed puller key. An empty
        // list authorizes no one, which is the kill switch ("pause").
        // Target-program identity is enforced by the `address =` constraint.
        require!(
            PULLER_KEYS.contains(&ctx.accounts.puller_key.key()),
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
