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

#[cfg(not(feature = "no-entrypoint"))]
solana_security_txt::security_txt! {
    name: "Mesh Subscription Controller",
    project_url: "https://www.meshconnect.com",
    contacts: "email:security@meshconnect.com",
    policy: "Please report vulnerabilities privately to the contact above. Do not exploit or publicly disclose before a fix is deployed.",
    preferred_languages: "en"
}

/// On-chain allowlist. Field order is fixed by deployed Borsh accounts.
#[account]
pub struct Config {
    pub admin: Pubkey,
    /// Empty disables all pulls.
    pub puller_keys: Vec<Pubkey>,
    /// Pending handover recipient; Pubkey::default() means none.
    pub pending_admin: Pubkey,
}

impl Config {
    /// 8 discriminator + 32 admin + (4 vec len + max key list) + 32 pending.
    pub const SPACE: usize = 8 + 32 + (4 + 32 * MAX_PULLER_KEYS) + 32;
}

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(init, payer = admin, space = Config::SPACE, seeds = [CONFIG_SEED], bump)]
    pub config: Account<'info, Config>,

    #[account(mut)]
    pub admin: Signer<'info>,

    /// Restricts initialization to the deployed program's upgrade authority.
    #[account(
        seeds = [crate::ID.as_ref()],
        bump,
        seeds::program = anchor_lang::solana_program::bpf_loader_upgradeable::ID,
        constraint = program_data.upgrade_authority_address == Some(admin.key()) @ ControllerError::Unauthorized,
    )]
    pub program_data: Account<'info, ProgramData>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AdminAction<'info> {
    #[account(mut, seeds = [CONFIG_SEED], bump, has_one = admin @ ControllerError::Unauthorized)]
    pub config: Account<'info, Config>,

    pub admin: Signer<'info>,
}

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

    /// Rent recipient must be writable even when it is not the fee payer.
    #[account(mut)]
    pub admin: Signer<'info>,
}

/// Forward a native pull, signing as MeshDelegate. remaining_accounts must
/// match the native account order and include MeshDelegate; native_data is pre-encoded.
#[derive(Accounts)]
pub struct Pull<'info> {
    /// CHECK: Validated by seeds; must also appear in remaining_accounts.
    #[account(seeds = [DELEGATE_SEED], bump)]
    pub delegate: UncheckedAccount<'info>,

    pub puller_key: Signer<'info>,

    /// CHECK: verified to equal `SUBSCRIPTIONS_PROGRAM`; used as the CPI target.
    #[account(address = SUBSCRIPTIONS_PROGRAM @ ControllerError::WrongTargetProgram)]
    pub subscriptions_program: UncheckedAccount<'info>,

    #[account(seeds = [CONFIG_SEED], bump)]
    pub config: Account<'info, Config>,
}

#[program]
pub mod subscription_controller {
    use super::*;

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

    /// Empty disables pulls; include old and new keys during rotation.
    pub fn set_puller_keys(ctx: Context<AdminAction>, puller_keys: Vec<Pubkey>) -> Result<()> {
        require!(
            puller_keys.len() <= MAX_PULLER_KEYS,
            ControllerError::TooManyPullerKeys
        );
        ctx.accounts.config.puller_keys = puller_keys;
        Ok(())
    }

    /// Propose a handover, or pass Pubkey::default() to cancel one.
    pub fn propose_admin(ctx: Context<AdminAction>, new_admin: Pubkey) -> Result<()> {
        ctx.accounts.config.pending_admin = new_admin;
        Ok(())
    }

    pub fn accept_admin(ctx: Context<AcceptAdmin>) -> Result<()> {
        let config = &mut ctx.accounts.config;
        config.admin = ctx.accounts.new_admin.key();
        config.pending_admin = Pubkey::default();
        Ok(())
    }

    /// Close before undeploying the program, or the config rent becomes stranded.
    pub fn close_config(_ctx: Context<CloseConfig>) -> Result<()> {
        Ok(())
    }

    pub fn pull<'info>(
        ctx: Context<'info, Pull<'info>>,
        native_data: Vec<u8>,
    ) -> Result<()> {
        require!(
            ctx.accounts
                .config
                .puller_keys
                .contains(&ctx.accounts.puller_key.key()),
            ControllerError::Unauthorized
        );

        // Restrict the delegate signature to pull_payment; destination remains caller-supplied.
        require!(
            native_data.first() == Some(&NATIVE_PULL_DISCRIMINATOR)
                && native_data.len() == NATIVE_PULL_DATA_LEN,
            ControllerError::UnexpectedNativeInstruction
        );

        // The length check above makes the amount slice safe.
        let amount = u64::from_le_bytes(
            native_data[NATIVE_PULL_AMOUNT_OFFSET..NATIVE_PULL_AMOUNT_OFFSET + 8]
                .try_into()
                .unwrap(),
        );
        require!(
            amount >= MIN_PULL_AMOUNT,
            ControllerError::AmountBelowMinimum
        );

        // The length check above also makes the delegator and mint slices safe.
        let delegator = Pubkey::new_from_array(
            native_data[NATIVE_PULL_DELEGATOR_OFFSET..NATIVE_PULL_DELEGATOR_OFFSET + 32]
                .try_into()
                .unwrap(),
        );
        let mint = Pubkey::new_from_array(
            native_data[NATIVE_PULL_MINT_OFFSET..NATIVE_PULL_MINT_OFFSET + 32]
                .try_into()
                .unwrap(),
        );

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

        // CPI requires the target program AccountInfo as well as its instruction accounts.
        let mut infos = ctx.remaining_accounts.to_vec();
        infos.push(ctx.accounts.subscriptions_program.to_account_info());

        let signer_seeds: &[&[u8]] = &[DELEGATE_SEED, &[ctx.bumps.delegate]];

        invoke_signed(&ix, &infos, &[signer_seeds])?;

        // Emit a controller-level record so pulls are traceable without decoding
        // the forwarded CPI. Best-effort telemetry via program logs, not authz.
        emit!(PullExecuted {
            puller_key: ctx.accounts.puller_key.key(),
            delegate: delegate_key,
            delegator,
            mint,
            amount,
        });

        Ok(())
    }
}

/// Controller-level forensic record for a forwarded pull.
#[event]
pub struct PullExecuted {
    pub puller_key: Pubkey,
    pub delegate: Pubkey,
    pub delegator: Pubkey,
    pub mint: Pubkey,
    pub amount: u64,
}
