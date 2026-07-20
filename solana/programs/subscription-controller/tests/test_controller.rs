//! LiteSVM tests for the Mesh Subscription Controller.
//!
//! The puller-key allowlist lives in the on-chain `Config` account (created
//! by `initialize`, updated by the admin via `set_puller_keys`) — NOT in the
//! code. These tests assert the whole lifecycle: initialize, admin gating,
//! rotation and the kill switch as single data transactions, and the `pull`
//! gate (only a listed puller key may pull, only into the configured
//! subscriptions program).
//!
//! The test puller keypairs are derived from fixed public seeds (see
//! `fixture_puller_keypairs`) — no private-key files exist in the repo, and
//! nothing key-related is baked into the binary anymore.

use {
    anchor_lang::{
        prelude::Pubkey,
        solana_program::instruction::Instruction,
        InstructionData, ToAccountMetas,
    },
    litesvm::LiteSVM,
    solana_keypair::Keypair,
    solana_message::{Message, VersionedMessage},
    solana_signer::Signer,
    solana_transaction::versioned::VersionedTransaction,
    subscription_controller::{CONFIG_SEED, DELEGATE_SEED, SUBSCRIPTIONS_PROGRAM},
};

/// Two puller keypairs the suite signs with. Derived from fixed, public
/// seeds — deliberately NOT secrets (safe on LiteSVM's throwaway chain; real
/// envs get their keys via `set-puller-keys.sh`, never from the repo).
fn fixture_puller_keypairs() -> [Keypair; 2] {
    [
        Keypair::new_from_array([1u8; 32]),
        Keypair::new_from_array([2u8; 32]),
    ]
}

struct Env {
    svm: LiteSVM,
    program_id: Pubkey,
    delegate: Pubkey,
    config: Pubkey,
    admin: Keypair,
    pullers: [Keypair; 2],
}

fn config_ix(env: &Env, data: &[u8], admin: Pubkey, init: bool) -> Instruction {
    let metas = if init {
        subscription_controller::accounts::Initialize {
            config: env.config,
            admin,
            system_program: anchor_lang::system_program::ID,
        }
        .to_account_metas(None)
    } else {
        subscription_controller::accounts::SetPullerKeys {
            config: env.config,
            admin,
        }
        .to_account_metas(None)
    };
    Instruction::new_with_bytes(env.program_id, data, metas)
}

fn initialize_ix(env: &Env, admin: Pubkey, puller_keys: Vec<Pubkey>) -> Instruction {
    config_ix(
        env,
        &subscription_controller::instruction::Initialize { puller_keys }.data(),
        admin,
        true,
    )
}

fn set_puller_keys_ix(env: &Env, admin: Pubkey, puller_keys: Vec<Pubkey>) -> Instruction {
    config_ix(
        env,
        &subscription_controller::instruction::SetPullerKeys { puller_keys }.data(),
        admin,
        false,
    )
}

/// Fresh SVM with the program loaded and the config initialized to the two
/// fixture puller keys (admin = a funded throwaway keypair).
fn setup() -> Env {
    let program_id = subscription_controller::id();
    let mut svm = LiteSVM::new();

    let bytes = include_bytes!("../../../target/deploy/subscription_controller.so");
    svm.add_program(program_id, bytes).unwrap();

    let pullers = fixture_puller_keypairs();
    let (delegate, _) = Pubkey::find_program_address(&[DELEGATE_SEED], &program_id);
    let (config, _) = Pubkey::find_program_address(&[CONFIG_SEED], &program_id);

    let admin = Keypair::new();
    svm.airdrop(&admin.pubkey(), 1_000_000_000).unwrap();

    let mut env = Env {
        svm,
        program_id,
        delegate,
        config,
        admin: admin.insecure_clone(),
        pullers,
    };
    let keys = env.pullers.iter().map(|k| k.pubkey()).collect();
    let ix = initialize_ix(&env, admin.pubkey(), keys);
    send(&mut env, ix, &admin, &[&admin]).expect("initialize config");
    env
}

fn pull_ix(env: &Env, puller_key: Pubkey, subscriptions_program: Pubkey) -> Instruction {
    Instruction::new_with_bytes(
        env.program_id,
        &subscription_controller::instruction::Pull { native_data: vec![] }.data(),
        subscription_controller::accounts::Pull {
            delegate: env.delegate,
            puller_key,
            subscriptions_program,
            config: env.config,
        }
        .to_account_metas(None),
    )
}

fn send(
    env: &mut Env,
    ix: Instruction,
    fee_payer: &Keypair,
    signers: &[&Keypair],
) -> Result<(), litesvm::types::FailedTransactionMetadata> {
    let blockhash = env.svm.latest_blockhash();
    let msg = Message::new_with_blockhash(&[ix], Some(&fee_payer.pubkey()), &blockhash);
    let tx = VersionedTransaction::try_new(VersionedMessage::Legacy(msg), signers).unwrap();
    env.svm.send_transaction(tx).map(|_| ())
}

// ---------------------------------------------------------------------------
// Config lifecycle
// ---------------------------------------------------------------------------

#[test]
fn initialize_cannot_run_twice() {
    let mut env = setup();

    // A second initialize (even by the same admin) must fail — the config
    // account already exists, so `init` rejects it. No re-init takeover.
    let admin = env.admin.insecure_clone();
    let ix = initialize_ix(&env, admin.pubkey(), vec![Pubkey::new_unique()]);
    send(&mut env, ix, &admin, &[&admin]).expect_err("config must be initialize-once");
}

#[test]
fn set_puller_keys_requires_admin() {
    let mut env = setup();

    let attacker = Keypair::new();
    env.svm.airdrop(&attacker.pubkey(), 1_000_000_000).unwrap();

    let ix = set_puller_keys_ix(&env, attacker.pubkey(), vec![attacker.pubkey()]);
    let err = send(&mut env, ix, &attacker, &[&attacker])
        .expect_err("only the admin may change the puller keys");
    let logs = err.meta.logs.join("\n");
    assert!(logs.contains("Unauthorized"), "expected Unauthorized, got:\n{logs}");

    // The gate still honors the original list.
    let puller = env.pullers[0].insecure_clone();
    env.svm.airdrop(&puller.pubkey(), 1_000_000_000).unwrap();
    let ix = pull_ix(&env, puller.pubkey(), SUBSCRIPTIONS_PROGRAM);
    let err = send(&mut env, ix, &puller, &[&puller]).unwrap_err();
    let logs = err.meta.logs.join("\n");
    assert!(!logs.contains("Unauthorized"), "original key must still pass the gate");
}

#[test]
fn rotation_is_a_single_transaction() {
    let mut env = setup();
    let admin = env.admin.insecure_clone();
    let old = env.pullers[0].insecure_clone();
    let new = Keypair::new();
    env.svm.airdrop(&old.pubkey(), 1_000_000_000).unwrap();
    env.svm.airdrop(&new.pubkey(), 1_000_000_000).unwrap();

    // Rotate: replace the list with [new] only.
    let ix = set_puller_keys_ix(&env, admin.pubkey(), vec![new.pubkey()]);
    send(&mut env, ix, &admin, &[&admin]).expect("admin rotates the keys");

    // Old key is out...
    let ix = pull_ix(&env, old.pubkey(), SUBSCRIPTIONS_PROGRAM);
    let err = send(&mut env, ix, &old, &[&old]).expect_err("rotated-out key rejected");
    assert!(err.meta.logs.join("\n").contains("Unauthorized"));

    // ...and the new key passes the gate (failure comes from the CPI into the
    // not-deployed native program, not from authorization).
    let ix = pull_ix(&env, new.pubkey(), SUBSCRIPTIONS_PROGRAM);
    let err = send(&mut env, ix, &new, &[&new]).unwrap_err();
    let logs = err.meta.logs.join("\n");
    assert!(
        !logs.contains("Unauthorized") && !logs.contains("WrongTargetProgram"),
        "new key must pass the gate, got:\n{logs}"
    );
}

#[test]
fn empty_list_is_the_kill_switch() {
    let mut env = setup();
    let admin = env.admin.insecure_clone();
    let puller = env.pullers[0].insecure_clone();
    env.svm.airdrop(&puller.pubkey(), 1_000_000_000).unwrap();

    // Kill: empty list. One transaction, no upgrade.
    let ix = set_puller_keys_ix(&env, admin.pubkey(), vec![]);
    send(&mut env, ix, &admin, &[&admin]).expect("admin engages the kill switch");

    let ix = pull_ix(&env, puller.pubkey(), SUBSCRIPTIONS_PROGRAM);
    let err = send(&mut env, ix, &puller, &[&puller]).expect_err("paused: nobody can pull");
    assert!(err.meta.logs.join("\n").contains("Unauthorized"));

    // Resume: restore the list. The same key pulls again (past the gate).
    let ix = set_puller_keys_ix(&env, admin.pubkey(), vec![puller.pubkey()]);
    send(&mut env, ix, &admin, &[&admin]).expect("admin resumes");
    let ix = pull_ix(&env, puller.pubkey(), SUBSCRIPTIONS_PROGRAM);
    let err = send(&mut env, ix, &puller, &[&puller]).unwrap_err();
    assert!(!err.meta.logs.join("\n").contains("Unauthorized"));
}

// ---------------------------------------------------------------------------
// Pull gate
// ---------------------------------------------------------------------------

#[test]
fn subscriptions_program_constant_is_pinned() {
    assert_eq!(
        SUBSCRIPTIONS_PROGRAM.to_string(),
        "De1egAFMkMWZSN5rYXRj9CAdheBamobVNubTsi9avR44",
        "SUBSCRIPTIONS_PROGRAM must match SolanaSubscriptionInstructionBuilder.ProgramId"
    );
}

#[test]
fn pull_is_rejected_for_unlisted_puller_key() {
    let mut env = setup();

    let attacker = Keypair::new();
    env.svm.airdrop(&attacker.pubkey(), 1_000_000_000).unwrap();

    let ix = pull_ix(&env, attacker.pubkey(), SUBSCRIPTIONS_PROGRAM);
    let err = send(&mut env, ix, &attacker, &[&attacker])
        .expect_err("unlisted signer must not trigger a pull");
    let logs = err.meta.logs.join("\n");
    assert!(logs.contains("Unauthorized"), "expected Unauthorized, got:\n{logs}");
}

#[test]
fn pull_is_rejected_for_wrong_target_program() {
    let mut env = setup();

    let puller = env.pullers[0].insecure_clone();
    env.svm.airdrop(&puller.pubkey(), 1_000_000_000).unwrap();

    // Even a listed puller key cannot point the CPI at a different program.
    let ix = pull_ix(&env, puller.pubkey(), Pubkey::new_unique());
    let err = send(&mut env, ix, &puller, &[&puller])
        .expect_err("pull must only CPI the configured subscriptions program");
    let logs = err.meta.logs.join("\n");
    assert!(
        logs.contains("WrongTargetProgram"),
        "expected WrongTargetProgram, got:\n{logs}"
    );
}

#[test]
fn pull_gate_passes_for_every_listed_puller_key() {
    // Both listed keys must pass the gate — the rotation-overlap property:
    // during a rotation the old and new key are listed together.
    for i in 0..2 {
        let mut env = setup();
        let puller = env.pullers[i].insecure_clone();
        env.svm.airdrop(&puller.pubkey(), 1_000_000_000).unwrap();

        // Correct signer + correct target: the controller's own gate must
        // pass. The native Subscriptions program is not deployed in this SVM,
        // so the tx still fails — but at the CPI, NOT at the gate.
        let ix = pull_ix(&env, puller.pubkey(), SUBSCRIPTIONS_PROGRAM);
        let err = send(&mut env, ix, &puller, &[&puller])
            .expect_err("CPI into a non-deployed program cannot succeed in LiteSVM");
        let logs = err.meta.logs.join("\n");
        assert!(
            !logs.contains("Unauthorized") && !logs.contains("WrongTargetProgram"),
            "gate must pass for listed puller key #{i}; failure must come from the CPI, got:\n{logs}"
        );
    }
}

#[test]
fn pull_requires_puller_key_signature() {
    let mut env = setup();

    let puller_pubkey = env.pullers[0].pubkey();
    let payer = Keypair::new();
    env.svm.airdrop(&payer.pubkey(), 1_000_000_000).unwrap();

    // Correct puller-key *pubkey* but without its signature: the account
    // meta demands a signer, so the transaction cannot even be assembled
    // without the puller key signing.
    let ix = pull_ix(&env, puller_pubkey, SUBSCRIPTIONS_PROGRAM);
    let blockhash = env.svm.latest_blockhash();
    let msg = Message::new_with_blockhash(&[ix], Some(&payer.pubkey()), &blockhash);
    let res = VersionedTransaction::try_new(VersionedMessage::Legacy(msg), &[&payer]);
    assert!(res.is_err(), "tx must be unsignable without the puller key");
}

#[test]
fn delegate_pda_is_stable_and_program_derived() {
    let env = setup();

    // The delegatee registered on every delegation. Depends only on the
    // program ID — no authority key, no state — so neither upgrades nor
    // config updates (kill, rotation) can ever move it.
    let (delegate, _bump) = Pubkey::find_program_address(&[DELEGATE_SEED], &env.program_id);
    assert_eq!(delegate, env.delegate);
    for puller in &env.pullers {
        assert_ne!(delegate, puller.pubkey());
    }
}

// ---------------------------------------------------------------------------
// End-to-end success path against the REAL native Subscriptions program
// (binary dumped from mainnet: tests/fixtures/subscriptions_program.so).
// Wire format (discriminators, account order, PDA seeds) mirrors
// SolanaSubscriptionInstructionBuilder in FrontBackEnd.
// ---------------------------------------------------------------------------

mod native {
    use super::*;
    use anchor_lang::solana_program::instruction::AccountMeta;
    use std::str::FromStr;

    pub const TOKEN_PROGRAM: &str = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
    pub const ATA_PROGRAM: &str = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL";
    pub const SYSTEM_PROGRAM: &str = "11111111111111111111111111111111";

    pub fn token_program() -> Pubkey {
        Pubkey::from_str(TOKEN_PROGRAM).unwrap()
    }

    pub fn ata(owner: &Pubkey, mint: &Pubkey) -> Pubkey {
        Pubkey::find_program_address(
            &[owner.as_ref(), token_program().as_ref(), mint.as_ref()],
            &Pubkey::from_str(ATA_PROGRAM).unwrap(),
        )
        .0
    }

    pub fn subscription_authority(delegator: &Pubkey, mint: &Pubkey) -> Pubkey {
        Pubkey::find_program_address(
            &[b"SubscriptionAuthority", delegator.as_ref(), mint.as_ref()],
            &SUBSCRIPTIONS_PROGRAM,
        )
        .0
    }

    pub fn recurring_delegation(
        authority: &Pubkey,
        delegator: &Pubkey,
        delegatee: &Pubkey,
        nonce: u64,
    ) -> Pubkey {
        Pubkey::find_program_address(
            &[
                b"delegation",
                authority.as_ref(),
                delegator.as_ref(),
                delegatee.as_ref(),
                &nonce.to_le_bytes(),
            ],
            &SUBSCRIPTIONS_PROGRAM,
        )
        .0
    }

    pub fn event_authority() -> Pubkey {
        Pubkey::find_program_address(&[b"event_authority"], &SUBSCRIPTIONS_PROGRAM).0
    }

    /// Classic SPL mint account data (82 bytes), pre-initialized.
    pub fn mint_account_data(authority: &Pubkey, supply: u64, decimals: u8) -> Vec<u8> {
        let mut data = vec![0u8; 82];
        data[0..4].copy_from_slice(&1u32.to_le_bytes()); // COption::Some(mint_authority)
        data[4..36].copy_from_slice(authority.as_ref());
        data[36..44].copy_from_slice(&supply.to_le_bytes());
        data[44] = decimals;
        data[45] = 1; // is_initialized
        data
    }

    /// Classic SPL token account data (165 bytes), pre-initialized.
    pub fn token_account_data(mint: &Pubkey, owner: &Pubkey, amount: u64) -> Vec<u8> {
        let mut data = vec![0u8; 165];
        data[0..32].copy_from_slice(mint.as_ref());
        data[32..64].copy_from_slice(owner.as_ref());
        data[64..72].copy_from_slice(&amount.to_le_bytes());
        data[108] = 1; // AccountState::Initialized
        data
    }

    pub fn token_amount(data: &[u8]) -> u64 {
        u64::from_le_bytes(data[64..72].try_into().unwrap())
    }

    /// `initialize_authority` (disc 0): [user(s,w), authority(w), mint, userAta(w), system, token].
    pub fn initialize_authority_ix(user: &Pubkey, mint: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            SUBSCRIPTIONS_PROGRAM,
            &[0u8],
            vec![
                AccountMeta::new(*user, true),
                AccountMeta::new(subscription_authority(user, mint), false),
                AccountMeta::new_readonly(*mint, false),
                AccountMeta::new(ata(user, mint), false),
                AccountMeta::new_readonly(Pubkey::from_str(SYSTEM_PROGRAM).unwrap(), false),
                AccountMeta::new_readonly(token_program(), false),
            ],
        )
    }

    /// `create_recurring_delegation` (disc 2), data = disc + nonce + amount +
    /// period + start_ts + expiry_ts + expected_init_id (49 bytes, LE).
    #[allow(clippy::too_many_arguments)]
    pub fn create_delegation_ix(
        delegator: &Pubkey,
        delegatee: &Pubkey,
        mint: &Pubkey,
        nonce: u64,
        amount_per_period: u64,
        period_length_s: u64,
        start_ts: i64,
        expiry_ts: i64,
        expected_init_id: i64,
    ) -> Instruction {
        let authority = subscription_authority(delegator, mint);
        let mut data = Vec::with_capacity(49);
        data.push(2u8);
        data.extend_from_slice(&nonce.to_le_bytes());
        data.extend_from_slice(&amount_per_period.to_le_bytes());
        data.extend_from_slice(&period_length_s.to_le_bytes());
        data.extend_from_slice(&start_ts.to_le_bytes());
        data.extend_from_slice(&expiry_ts.to_le_bytes());
        data.extend_from_slice(&expected_init_id.to_le_bytes());
        Instruction::new_with_bytes(
            SUBSCRIPTIONS_PROGRAM,
            &data,
            vec![
                AccountMeta::new(*delegator, true),
                AccountMeta::new_readonly(authority, false),
                AccountMeta::new(
                    recurring_delegation(&authority, delegator, delegatee, nonce),
                    false,
                ),
                AccountMeta::new_readonly(*delegatee, false),
                AccountMeta::new_readonly(Pubkey::from_str(SYSTEM_PROGRAM).unwrap(), false),
            ],
        )
    }

    /// Native recurring `pull_payment` (disc 5) data: disc + amount(u64) +
    /// delegator(32) + mint(32) = 73 bytes.
    pub fn pull_payment_data(amount: u64, delegator: &Pubkey, mint: &Pubkey) -> Vec<u8> {
        let mut data = Vec::with_capacity(73);
        data.push(5u8);
        data.extend_from_slice(&amount.to_le_bytes());
        data.extend_from_slice(delegator.as_ref());
        data.extend_from_slice(mint.as_ref());
        data
    }

    /// The native pull's account list, in order. The delegatee (MeshDelegate
    /// PDA) is passed non-signer; the controller force-marks it.
    pub fn pull_payment_metas(
        delegation: &Pubkey,
        delegator: &Pubkey,
        delegatee: &Pubkey,
        mint: &Pubkey,
        destination_owner: &Pubkey,
    ) -> Vec<AccountMeta> {
        vec![
            AccountMeta::new(*delegation, false),
            AccountMeta::new_readonly(subscription_authority(delegator, mint), false),
            AccountMeta::new(ata(delegator, mint), false),
            AccountMeta::new(ata(destination_owner, mint), false),
            AccountMeta::new_readonly(*mint, false),
            AccountMeta::new_readonly(token_program(), false),
            AccountMeta::new_readonly(*delegatee, false),
            AccountMeta::new_readonly(event_authority(), false),
            AccountMeta::new_readonly(SUBSCRIPTIONS_PROGRAM, false),
        ]
    }
}

#[test]
fn pull_moves_funds_end_to_end_via_native_program() {
    use anchor_lang::solana_program::clock::Clock;
    use solana_account::Account;

    const DECIMALS: u8 = 6;
    const FUNDED: u64 = 100_000_000; // 100 USDC
    const AMOUNT_PER_PERIOD: u64 = 50_000_000; // 50 USDC

    let mut env = setup();

    // Real native Subscriptions program, dumped from mainnet.
    let native = include_bytes!("fixtures/subscriptions_program.so");
    env.svm.add_program(SUBSCRIPTIONS_PROGRAM, native).unwrap();

    // LiteSVM defaults to the legacy 2-year rent-exemption threshold; the
    // native program funds new PDAs with mainnet's current 1-year minimum.
    // Align the sysvar with mainnet so account creation passes the rent check.
    #[allow(deprecated)]
    let mainnet_rent = anchor_lang::solana_program::rent::Rent {
        lamports_per_byte_year: 3480,
        exemption_threshold: 1.0,
        burn_percent: 50,
    };
    env.svm.set_sysvar(&mainnet_rent);

    let puller = env.pullers[0].insecure_clone();
    let delegator = Keypair::new();
    let merchant = Pubkey::new_unique();
    env.svm.airdrop(&puller.pubkey(), 10_000_000_000).unwrap();
    env.svm.airdrop(&delegator.pubkey(), 10_000_000_000).unwrap();

    // Mint + pre-initialized ATAs (source funded, destination empty), written
    // directly instead of driving spl-token instructions.
    let mint = Pubkey::new_unique();
    let mint_authority = Pubkey::new_unique();
    let token_owner = native::token_program();
    let source_ata = native::ata(&delegator.pubkey(), &mint);
    let dest_ata = native::ata(&merchant, &mint);
    for (address, data) in [
        (mint, native::mint_account_data(&mint_authority, FUNDED, DECIMALS)),
        (
            source_ata,
            native::token_account_data(&mint, &delegator.pubkey(), FUNDED),
        ),
        (dest_ata, native::token_account_data(&mint, &merchant, 0)),
    ] {
        env.svm
            .set_account(
                address,
                Account {
                    lamports: 10_000_000,
                    data,
                    owner: token_owner,
                    executable: false,
                    rent_epoch: 0,
                },
            )
            .unwrap();
    }

    // Subscribe: initialize_authority, then create the delegation with the
    // MeshDelegate PDA as delegatee (both signed by the user, as in prod).
    let init_ix = native::initialize_authority_ix(&delegator.pubkey(), &mint);
    send(&mut env, init_ix, &delegator, &[&delegator]).expect("initialize_authority");

    let authority = native::subscription_authority(&delegator.pubkey(), &mint);
    let authority_account = env.svm.get_account(&authority).expect("authority created");
    assert_eq!(authority_account.data.len(), 106, "SubscriptionAuthority size");
    let init_id = i64::from_le_bytes(authority_account.data[98..106].try_into().unwrap());

    let clock: Clock = env.svm.get_sysvar();
    let nonce = 1u64;
    let create_ix = native::create_delegation_ix(
        &delegator.pubkey(),
        &env.delegate,
        &mint,
        nonce,
        AMOUNT_PER_PERIOD,
        3600,
        clock.unix_timestamp,
        clock.unix_timestamp + 30 * 86_400,
        init_id,
    );
    send(&mut env, create_ix, &delegator, &[&delegator]).expect("create_recurring_delegation");
    let delegation =
        native::recurring_delegation(&authority, &delegator.pubkey(), &env.delegate, nonce);
    assert!(env.svm.get_account(&delegation).is_some(), "delegation created");

    // Pull through the controller: puller key signs; the program signs the
    // native pull as the MeshDelegate PDA.
    let native_data =
        native::pull_payment_data(AMOUNT_PER_PERIOD, &delegator.pubkey(), &mint);
    let mut metas = subscription_controller::accounts::Pull {
        delegate: env.delegate,
        puller_key: puller.pubkey(),
        subscriptions_program: SUBSCRIPTIONS_PROGRAM,
        config: env.config,
    }
    .to_account_metas(None);
    metas.extend(native::pull_payment_metas(
        &delegation,
        &delegator.pubkey(),
        &env.delegate,
        &mint,
        &merchant,
    ));
    let ix = Instruction::new_with_bytes(
        env.program_id,
        &subscription_controller::instruction::Pull { native_data }.data(),
        metas,
    );
    send(&mut env, ix.clone(), &puller, &[&puller]).expect("pull must succeed end-to-end");

    // Funds moved and the on-chain per-period counter advanced.
    let dest = env.svm.get_account(&dest_ata).unwrap();
    assert_eq!(native::token_amount(&dest.data), AMOUNT_PER_PERIOD);
    let source = env.svm.get_account(&source_ata).unwrap();
    assert_eq!(native::token_amount(&source.data), FUNDED - AMOUNT_PER_PERIOD);
    let delegation_account = env.svm.get_account(&delegation).unwrap();
    assert_eq!(
        u64::from_le_bytes(delegation_account.data[203..211].try_into().unwrap()),
        AMOUNT_PER_PERIOD,
        "amount_pulled_in_period"
    );

    // The native program still enforces its own cap through the proxy: a
    // second pull in the same period must fail (allowance exhausted).
    let err = send(&mut env, ix, &puller, &[&puller])
        .expect_err("second pull in the same period must exceed the cap");
    let logs = err.meta.logs.join("\n");
    assert!(
        !logs.contains("Unauthorized") && !logs.contains("WrongTargetProgram"),
        "failure must come from the native program, not the gate:\n{logs}"
    );
}
