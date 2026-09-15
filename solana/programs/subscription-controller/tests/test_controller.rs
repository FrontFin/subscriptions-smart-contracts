//! LiteSVM tests use public fixture seeds; never use them for funded accounts.

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
    subscription_controller::{CONFIG_SEED, DELEGATE_SEED, MIN_PULL_AMOUNT, SUBSCRIPTIONS_PROGRAM},
};

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
    program_data: Pubkey,
    admin: Keypair,
    pullers: [Keypair; 2],
}

/// Native pull_payment: discriminator (1) + amount (8) + delegator (32) + mint (32).
fn valid_native_pull_data() -> Vec<u8> {
    // Use a valid amount so authorization tests reach CPI instead of failing the minimum check.
    let mut d = vec![5u8];
    d.extend_from_slice(&MIN_PULL_AMOUNT.to_le_bytes());
    d.extend(std::iter::repeat(0u8).take(64));
    d
}

fn initialize_ix(env: &Env, admin: Pubkey, puller_keys: Vec<Pubkey>) -> Instruction {
    Instruction::new_with_bytes(
        env.program_id,
        &subscription_controller::instruction::Initialize { puller_keys }.data(),
        subscription_controller::accounts::Initialize {
            config: env.config,
            admin,
            program_data: env.program_data,
            system_program: anchor_lang::system_program::ID,
        }
        .to_account_metas(None),
    )
}

fn admin_action_metas(env: &Env, admin: Pubkey) -> Vec<anchor_lang::solana_program::instruction::AccountMeta> {
    subscription_controller::accounts::AdminAction {
        config: env.config,
        admin,
    }
    .to_account_metas(None)
}

fn set_puller_keys_ix(env: &Env, admin: Pubkey, puller_keys: Vec<Pubkey>) -> Instruction {
    Instruction::new_with_bytes(
        env.program_id,
        &subscription_controller::instruction::SetPullerKeys { puller_keys }.data(),
        admin_action_metas(env, admin),
    )
}

fn propose_admin_ix(env: &Env, admin: Pubkey, new_admin: Pubkey) -> Instruction {
    Instruction::new_with_bytes(
        env.program_id,
        &subscription_controller::instruction::ProposeAdmin { new_admin }.data(),
        admin_action_metas(env, admin),
    )
}

fn accept_admin_ix(env: &Env, new_admin: Pubkey) -> Instruction {
    Instruction::new_with_bytes(
        env.program_id,
        &subscription_controller::instruction::AcceptAdmin {}.data(),
        subscription_controller::accounts::AcceptAdmin {
            config: env.config,
            new_admin,
        }
        .to_account_metas(None),
    )
}

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

    // LiteSVM omits ProgramData; supply it to exercise the upgrade-authority gate.
    use anchor_lang::solana_program::bpf_loader_upgradeable::{self, UpgradeableLoaderState};
    let (program_data, _) =
        Pubkey::find_program_address(&[program_id.as_ref()], &bpf_loader_upgradeable::ID);
    let pd_data = bincode::serialize(&UpgradeableLoaderState::ProgramData {
        slot: 0,
        upgrade_authority_address: Some(admin.pubkey()),
    })
    .unwrap();
    svm.set_account(
        program_data,
        solana_account::Account {
            lamports: 1_000_000_000,
            data: pd_data,
            owner: bpf_loader_upgradeable::ID,
            executable: false,
            rent_epoch: 0,
        },
    )
    .unwrap();

    let mut env = Env {
        svm,
        program_id,
        delegate,
        config,
        program_data,
        admin: admin.insecure_clone(),
        pullers,
    };
    let keys = env.pullers.iter().map(|k| k.pubkey()).collect();
    let ix = initialize_ix(&env, admin.pubkey(), keys);
    send(&mut env, ix, &admin, &[&admin]).expect("initialize config");
    env
}

fn pull_ix(env: &Env, puller_key: Pubkey, subscriptions_program: Pubkey) -> Instruction {
    pull_ix_data(env, puller_key, subscriptions_program, valid_native_pull_data())
}

fn pull_ix_data(
    env: &Env,
    puller_key: Pubkey,
    subscriptions_program: Pubkey,
    native_data: Vec<u8>,
) -> Instruction {
    Instruction::new_with_bytes(
        env.program_id,
        &subscription_controller::instruction::Pull { native_data }.data(),
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


#[test]
fn initialize_cannot_run_twice() {
    let mut env = setup();

    let admin = env.admin.insecure_clone();
    let ix = initialize_ix(&env, admin.pubkey(), vec![Pubkey::new_unique()]);
    send(&mut env, ix, &admin, &[&admin]).expect_err("config must be initialize-once");
}

#[test]
fn initialize_requires_the_upgrade_authority() {
    use anchor_lang::solana_program::bpf_loader_upgradeable::{self, UpgradeableLoaderState};

    let program_id = subscription_controller::id();
    let mut svm = LiteSVM::new();
    svm.add_program(
        program_id,
        include_bytes!("../../../target/deploy/subscription_controller.so"),
    )
    .unwrap();
    let (config, _) = Pubkey::find_program_address(&[CONFIG_SEED], &program_id);
    let (program_data, _) =
        Pubkey::find_program_address(&[program_id.as_ref()], &bpf_loader_upgradeable::ID);

    let real_authority = Keypair::new();
    let attacker = Keypair::new();
    svm.airdrop(&attacker.pubkey(), 1_000_000_000).unwrap();

    let pd = bincode::serialize(&UpgradeableLoaderState::ProgramData {
        slot: 0,
        upgrade_authority_address: Some(real_authority.pubkey()),
    })
    .unwrap();
    svm.set_account(
        program_data,
        solana_account::Account {
            lamports: 1_000_000_000,
            data: pd,
            owner: bpf_loader_upgradeable::ID,
            executable: false,
            rent_epoch: 0,
        },
    )
    .unwrap();

    let ix = Instruction::new_with_bytes(
        program_id,
        &subscription_controller::instruction::Initialize { puller_keys: vec![] }.data(),
        subscription_controller::accounts::Initialize {
            config,
            admin: attacker.pubkey(),
            program_data,
            system_program: anchor_lang::system_program::ID,
        }
        .to_account_metas(None),
    );
    let blockhash = svm.latest_blockhash();
    let msg = Message::new_with_blockhash(&[ix], Some(&attacker.pubkey()), &blockhash);
    let tx = VersionedTransaction::try_new(VersionedMessage::Legacy(msg), &[&attacker]).unwrap();
    let err = svm
        .send_transaction(tx)
        .expect_err("only the upgrade authority may initialize");
    assert!(
        err.meta.logs.join("\n").contains("Unauthorized"),
        "expected Unauthorized, got:\n{}",
        err.meta.logs.join("\n")
    );
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

    let ix = set_puller_keys_ix(&env, admin.pubkey(), vec![new.pubkey()]);
    send(&mut env, ix, &admin, &[&admin]).expect("admin rotates the keys");

    let ix = pull_ix(&env, old.pubkey(), SUBSCRIPTIONS_PROGRAM);
    let err = send(&mut env, ix, &old, &[&old]).expect_err("rotated-out key rejected");
    assert!(err.meta.logs.join("\n").contains("Unauthorized"));

    // The native program is absent, so failure must come from CPI, not authorization.
    let ix = pull_ix(&env, new.pubkey(), SUBSCRIPTIONS_PROGRAM);
    let err = send(&mut env, ix, &new, &[&new]).unwrap_err();
    let logs = err.meta.logs.join("\n");
    assert!(
        !logs.contains("Unauthorized") && !logs.contains("WrongTargetProgram"),
        "new key must pass the gate, got:\n{logs}"
    );
}

#[test]
fn admin_handover_is_two_step() {
    let mut env = setup();
    let old_admin = env.admin.insecure_clone();
    let new_admin = Keypair::new();
    let outsider = Keypair::new();
    for k in [&new_admin, &outsider] {
        env.svm.airdrop(&k.pubkey(), 1_000_000_000).unwrap();
    }

    let ix = propose_admin_ix(&env, outsider.pubkey(), outsider.pubkey());
    send(&mut env, ix, &outsider, &[&outsider]).expect_err("non-admin cannot propose");

    let ix = propose_admin_ix(&env, old_admin.pubkey(), new_admin.pubkey());
    send(&mut env, ix, &old_admin, &[&old_admin]).expect("admin proposes handover");

    let ix = accept_admin_ix(&env, outsider.pubkey());
    send(&mut env, ix, &outsider, &[&outsider]).expect_err("only the pending admin accepts");
    let ix = set_puller_keys_ix(&env, new_admin.pubkey(), vec![]);
    send(&mut env, ix, &new_admin, &[&new_admin])
        .expect_err("proposed admin has no power until it accepts");
    let ix = set_puller_keys_ix(&env, old_admin.pubkey(), vec![old_admin.pubkey()]);
    send(&mut env, ix, &old_admin, &[&old_admin]).expect("old admin still in charge pre-accept");

    let ix = accept_admin_ix(&env, new_admin.pubkey());
    send(&mut env, ix, &new_admin, &[&new_admin]).expect("pending admin accepts");

    let ix = set_puller_keys_ix(&env, old_admin.pubkey(), vec![]);
    send(&mut env, ix, &old_admin, &[&old_admin]).expect_err("old admin locked out after handover");
    let ix = set_puller_keys_ix(&env, new_admin.pubkey(), vec![new_admin.pubkey()]);
    send(&mut env, ix, &new_admin, &[&new_admin]).expect("new admin now in control");
}

#[test]
fn close_config_reclaims_and_requires_admin() {
    let mut env = setup();
    let admin = env.admin.insecure_clone();
    let outsider = Keypair::new();
    env.svm.airdrop(&outsider.pubkey(), 1_000_000_000).unwrap();

    fn close_ix(env: &Env, signer: Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            env.program_id,
            &subscription_controller::instruction::CloseConfig {}.data(),
            subscription_controller::accounts::CloseConfig {
                config: env.config,
                admin: signer,
            }
            .to_account_metas(None),
        )
    }

    let ix = close_ix(&env, outsider.pubkey());
    send(&mut env, ix, &outsider, &[&outsider]).expect_err("only admin closes the config");

    let ix = close_ix(&env, admin.pubkey());
    send(&mut env, ix, &admin, &[&admin]).expect("admin closes config");
    assert!(env
        .svm
        .get_account(&env.config)
        .map(|a| a.data.is_empty())
        .unwrap_or(true));
}

#[test]
fn close_config_works_when_the_admin_is_not_the_fee_payer() {
    // A separate fee payer exposes a missing writable flag on the rent recipient.
    let mut env = setup();
    let admin = env.admin.insecure_clone();
    let payer = Keypair::new();
    env.svm.airdrop(&payer.pubkey(), 1_000_000_000).unwrap();

    let admin_before = env.svm.get_account(&admin.pubkey()).map(|a| a.lamports).unwrap_or(0);
    let rent = env.svm.get_account(&env.config).expect("config exists").lamports;

    let ix = Instruction::new_with_bytes(
        env.program_id,
        &subscription_controller::instruction::CloseConfig {}.data(),
        subscription_controller::accounts::CloseConfig {
            config: env.config,
            admin: admin.pubkey(),
        }
        .to_account_metas(None),
    );
    send(&mut env, ix, &payer, &[&payer, &admin])
        .expect("close_config must work when the admin only signs");

    assert!(env
        .svm
        .get_account(&env.config)
        .map(|a| a.data.is_empty())
        .unwrap_or(true));
    let admin_after = env.svm.get_account(&admin.pubkey()).map(|a| a.lamports).unwrap_or(0);
    assert_eq!(
        admin_after,
        admin_before + rent,
        "the config's rent must reach the admin, who paid no fee"
    );
}

#[test]
fn close_config_is_blocked_while_a_handover_is_pending() {
    let mut env = setup();
    let admin = env.admin.insecure_clone();
    let new_admin = Keypair::new();
    env.svm.airdrop(&new_admin.pubkey(), 1_000_000_000).unwrap();

    fn close_ix(env: &Env, signer: Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            env.program_id,
            &subscription_controller::instruction::CloseConfig {}.data(),
            subscription_controller::accounts::CloseConfig {
                config: env.config,
                admin: signer,
            }
            .to_account_metas(None),
        )
    }

    let ix = propose_admin_ix(&env, admin.pubkey(), new_admin.pubkey());
    send(&mut env, ix, &admin, &[&admin]).expect("admin proposes handover");

    let ix = close_ix(&env, admin.pubkey());
    let err = send(&mut env, ix, &admin, &[&admin])
        .expect_err("close must be refused while a handover is pending");
    let logs = err.meta.logs.join("\n");
    assert!(
        logs.contains("HandoverPending"),
        "expected HandoverPending, got:\n{logs}"
    );
    assert!(
        env.svm
            .get_account(&env.config)
            .is_some_and(|a| !a.data.is_empty()),
        "the config must survive the refused close"
    );

    let ix = propose_admin_ix(&env, admin.pubkey(), Pubkey::default());
    send(&mut env, ix, &admin, &[&admin]).expect("admin cancels the handover");

    // A byte-identical retry is rejected as AlreadyProcessed without executing.
    env.svm.expire_blockhash();
    let ix = close_ix(&env, admin.pubkey());
    send(&mut env, ix, &admin, &[&admin])
        .expect("close succeeds once no handover is pending");
}

#[test]
fn pull_rejects_non_pull_payment_instruction() {
    let mut env = setup();
    let puller = env.pullers[0].insecure_clone();
    env.svm.airdrop(&puller.pubkey(), 1_000_000_000).unwrap();

    let mut wrong = vec![2u8]; // create_recurring_delegation, not pull_payment
    wrong.extend(std::iter::repeat(0u8).take(72));
    let ix = pull_ix_data(&env, puller.pubkey(), SUBSCRIPTIONS_PROGRAM, wrong);
    let err = send(&mut env, ix, &puller, &[&puller]).expect_err("non-pull_payment rejected");
    assert!(err.meta.logs.join("\n").contains("UnexpectedNativeInstruction"));

    let ix = pull_ix_data(&env, puller.pubkey(), SUBSCRIPTIONS_PROGRAM, vec![5u8]);
    let err = send(&mut env, ix, &puller, &[&puller]).expect_err("wrong length rejected");
    assert!(err.meta.logs.join("\n").contains("UnexpectedNativeInstruction"));
}

#[test]
fn empty_list_is_the_kill_switch() {
    let mut env = setup();
    let admin = env.admin.insecure_clone();
    let puller = env.pullers[0].insecure_clone();
    env.svm.airdrop(&puller.pubkey(), 1_000_000_000).unwrap();

    let ix = set_puller_keys_ix(&env, admin.pubkey(), vec![]);
    send(&mut env, ix, &admin, &[&admin]).expect("admin engages the kill switch");

    let ix = pull_ix(&env, puller.pubkey(), SUBSCRIPTIONS_PROGRAM);
    let err = send(&mut env, ix, &puller, &[&puller]).expect_err("paused: nobody can pull");
    assert!(err.meta.logs.join("\n").contains("Unauthorized"));

    let ix = set_puller_keys_ix(&env, admin.pubkey(), vec![puller.pubkey()]);
    send(&mut env, ix, &admin, &[&admin]).expect("admin resumes");
    // A byte-identical retry is rejected as AlreadyProcessed without executing.
    env.svm.expire_blockhash();
    let ix = pull_ix(&env, puller.pubkey(), SUBSCRIPTIONS_PROGRAM);
    let err = send(&mut env, ix, &puller, &[&puller]).unwrap_err();
    let logs = err.meta.logs.join("\n");
    assert!(!logs.is_empty(), "the pull must reach execution");
    assert!(!logs.contains("Unauthorized"), "expected past the gate, got:\n{logs}");
}


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
    for i in 0..2 {
        let mut env = setup();
        let puller = env.pullers[i].insecure_clone();
        env.svm.airdrop(&puller.pubkey(), 1_000_000_000).unwrap();

        // The native program is absent: expect CPI failure after authorization succeeds.
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
fn pull_rejects_amounts_below_the_minimum() {
    let pull_data_of = |amount: u64| {
        let mut d = vec![5u8];
        d.extend_from_slice(&amount.to_le_bytes());
        d.extend(std::iter::repeat(0u8).take(64));
        d
    };

    for amount in [0, 1, MIN_PULL_AMOUNT - 1] {
        let mut env = setup();
        let puller = env.pullers[0].insecure_clone();
        env.svm.airdrop(&puller.pubkey(), 1_000_000_000).unwrap();

        let ix = pull_ix_data(
            &env,
            puller.pubkey(),
            SUBSCRIPTIONS_PROGRAM,
            pull_data_of(amount),
        );
        let err = send(&mut env, ix, &puller, &[&puller])
            .expect_err("an amount below the floor must not be forwarded");
        let logs = err.meta.logs.join("\n");
        assert!(
            logs.contains("AmountBelowMinimum"),
            "amount {amount} must be rejected by the floor, got:\n{logs}"
        );
    }

    // The native program is absent, so reaching CPI proves the minimum check passed.
    let mut env = setup();
    let puller = env.pullers[0].insecure_clone();
    env.svm.airdrop(&puller.pubkey(), 1_000_000_000).unwrap();
    let ix = pull_ix_data(
        &env,
        puller.pubkey(),
        SUBSCRIPTIONS_PROGRAM,
        pull_data_of(MIN_PULL_AMOUNT),
    );
    let err = send(&mut env, ix, &puller, &[&puller])
        .expect_err("CPI into a non-deployed program cannot succeed in LiteSVM");
    let logs = err.meta.logs.join("\n");
    assert!(!logs.is_empty(), "the pull must reach execution");
    assert!(
        !logs.contains("AmountBelowMinimum"),
        "exactly MIN_PULL_AMOUNT must clear the floor, got:\n{logs}"
    );
}

#[test]
fn pull_requires_puller_key_signature() {
    let mut env = setup();

    let puller_pubkey = env.pullers[0].pubkey();
    let payer = Keypair::new();
    env.svm.airdrop(&payer.pubkey(), 1_000_000_000).unwrap();

    let ix = pull_ix(&env, puller_pubkey, SUBSCRIPTIONS_PROGRAM);
    let blockhash = env.svm.latest_blockhash();
    let msg = Message::new_with_blockhash(&[ix], Some(&payer.pubkey()), &blockhash);
    let res = VersionedTransaction::try_new(VersionedMessage::Legacy(msg), &[&payer]);
    assert!(res.is_err(), "tx must be unsignable without the puller key");
}

#[test]
fn pull_reads_a_config_whose_tail_is_not_zero() {
    // Shrinking a Borsh Vec leaves stale account bytes; deserialization must ignore them.
    use solana_account::Account;

    let mut env = setup();
    let puller = env.pullers[0].insecure_clone();
    env.svm.airdrop(&puller.pubkey(), 1_000_000_000).unwrap();

    let existing = env.svm.get_account(&env.config).expect("config exists");
    let mut data = vec![0xABu8; existing.data.len()];
    data[0..8].copy_from_slice(&existing.data[0..8]);
    data[8..40].copy_from_slice(env.admin.pubkey().as_ref());
    data[40..44].copy_from_slice(&1u32.to_le_bytes());
    data[44..76].copy_from_slice(puller.pubkey().as_ref());
    data[76..108].copy_from_slice(Pubkey::default().as_ref());
    env.svm
        .set_account(
            env.config,
            Account {
                data,
                ..existing.clone()
            },
        )
        .unwrap();

    let ix = pull_ix(&env, puller.pubkey(), SUBSCRIPTIONS_PROGRAM);
    let err = send(&mut env, ix, &puller, &[&puller])
        .expect_err("the native program is not loaded in this fixture");
    let logs = err.meta.logs.join("\n");
    assert!(!logs.is_empty(), "the pull must reach execution");
    assert!(
        !logs.contains("AccountDidNotDeserialize") && !logs.contains("Unauthorized"),
        "a dirty tail must not affect Config deserialization:\n{logs}"
    );
}

#[test]
fn delegate_pda_is_stable_and_program_derived() {
    let env = setup();

    let (delegate, _bump) = Pubkey::find_program_address(&[DELEGATE_SEED], &env.program_id);
    assert_eq!(delegate, env.delegate);
    for puller in &env.pullers {
        assert_ne!(delegate, puller.pubkey());
    }
}

// Native wire format follows SolanaSubscriptionInstructionBuilder in FrontBackEnd.

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

    /// Native account order; the controller marks MeshDelegate as a signer.
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

    let native = include_bytes!("fixtures/subscriptions_program.so");
    env.svm.add_program(SUBSCRIPTIONS_PROGRAM, native).unwrap();

    // Match mainnet rent; the native program funds new accounts at its one-year minimum.
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

    // Refresh the blockhash so the retry exercises the cap instead of AlreadyProcessed.
    env.svm.expire_blockhash();
    let err = send(&mut env, ix, &puller, &[&puller])
        .expect_err("second pull in the same period must exceed the cap");
    let logs = err.meta.logs.join("\n");
    assert!(
        !logs.is_empty(),
        "the second pull must reach execution, not be rejected before it runs"
    );
    assert!(
        !logs.contains("Unauthorized") && !logs.contains("WrongTargetProgram"),
        "failure must come from the native program, not the gate:\n{logs}"
    );
}

#[test]
fn smallest_allowed_pulls_consume_only_their_own_amount() {
    use anchor_lang::solana_program::clock::Clock;
    use solana_account::Account;

    const DECIMALS: u8 = 6;
    const FUNDED: u64 = 100_000_000;
    const AMOUNT_PER_PERIOD: u64 = 50_000_000;
    const SMALLEST_PULL: u64 = MIN_PULL_AMOUNT;
    const SMALL_PULLS: u64 = 3;

    let mut env = setup();
    let native_binary = include_bytes!("fixtures/subscriptions_program.so");
    env.svm
        .add_program(SUBSCRIPTIONS_PROGRAM, native_binary)
        .unwrap();

    #[allow(deprecated)]
    let mainnet_rent = anchor_lang::solana_program::rent::Rent {
        lamports_per_byte_year: 3480,
        exemption_threshold: 1.0,
        burn_percent: 50,
    };
    env.svm.set_sysvar(&mainnet_rent);

    let puller = env.pullers[0].insecure_clone();
    let delegator = Keypair::new();
    let delegator_key = delegator.pubkey();
    let merchant = Pubkey::new_unique();
    env.svm.airdrop(&puller.pubkey(), 10_000_000_000).unwrap();
    env.svm.airdrop(&delegator_key, 10_000_000_000).unwrap();

    let mint = Pubkey::new_unique();
    let mint_authority = Pubkey::new_unique();
    let token_owner = native::token_program();
    let source_ata = native::ata(&delegator_key, &mint);
    let dest_ata = native::ata(&merchant, &mint);
    for (address, data) in [
        (
            mint,
            native::mint_account_data(&mint_authority, FUNDED, DECIMALS),
        ),
        (
            source_ata,
            native::token_account_data(&mint, &delegator_key, FUNDED),
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

    let init_ix = native::initialize_authority_ix(&delegator_key, &mint);
    send(&mut env, init_ix, &delegator, &[&delegator]).expect("initialize_authority");

    let authority = native::subscription_authority(&delegator_key, &mint);
    let authority_account = env.svm.get_account(&authority).expect("authority created");
    let init_id = i64::from_le_bytes(authority_account.data[98..106].try_into().unwrap());

    let clock: Clock = env.svm.get_sysvar();
    let nonce = 1u64;
    let create_ix = native::create_delegation_ix(
        &delegator_key,
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
        native::recurring_delegation(&authority, &delegator_key, &env.delegate, nonce);

    let program_id = env.program_id;
    let mut metas = subscription_controller::accounts::Pull {
        delegate: env.delegate,
        puller_key: puller.pubkey(),
        subscriptions_program: SUBSCRIPTIONS_PROGRAM,
        config: env.config,
    }
    .to_account_metas(None);
    metas.extend(native::pull_payment_metas(
        &delegation,
        &delegator_key,
        &env.delegate,
        &mint,
        &merchant,
    ));
    let pull_of = |amount: u64| {
        Instruction::new_with_bytes(
            program_id,
            &subscription_controller::instruction::Pull {
                native_data: native::pull_payment_data(amount, &delegator_key, &mint),
            }
            .data(),
            metas.clone(),
        )
    };

    for _ in 0..SMALL_PULLS {
        env.svm.expire_blockhash();
        send(&mut env, pull_of(SMALLEST_PULL), &puller, &[&puller])
            .expect("a smallest-allowed pull must succeed");
    }

    let destination = env.svm.get_account(&dest_ata).unwrap();
    assert_eq!(
        native::token_amount(&destination.data),
        SMALLEST_PULL * SMALL_PULLS,
        "each small pull must move exactly its own amount"
    );

    let delegation_account = env.svm.get_account(&delegation).unwrap();
    assert_eq!(
        u64::from_le_bytes(delegation_account.data[203..211].try_into().unwrap()),
        SMALLEST_PULL * SMALL_PULLS,
        "the period counter must meter by amount, not by pull count"
    );

    for (amount, label) in [(0u64, "zero"), (MIN_PULL_AMOUNT - 1, "one below the floor")] {
        env.svm.expire_blockhash();
        let err = send(&mut env, pull_of(amount), &puller, &[&puller])
            .expect_err("a below-minimum pull must be rejected");
        let logs = err.meta.logs.join("\n");
        assert!(
            logs.contains("AmountBelowMinimum"),
            "a {label} pull must fail AmountBelowMinimum, got:\n{logs}"
        );
    }

    env.svm.expire_blockhash();
    send(
        &mut env,
        pull_of(AMOUNT_PER_PERIOD - SMALLEST_PULL * SMALL_PULLS),
        &puller,
        &[&puller],
    )
    .expect("small pulls must not burn the rest of the period's allowance");
}
