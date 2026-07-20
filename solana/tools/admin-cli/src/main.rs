//! Sync the controller's on-chain puller-key config: initializes the Config
//! account on first use, updates it afterwards. Data-only — never builds or
//! deploys code. Driven by scripts/set-puller-keys.sh (and deploy.sh).
//!
//! Usage: admin-cli <program-id> <admin-keypair-path> <rpc-url> [puller-key ...]
//!        (zero puller keys = the kill switch: no key may pull)

use anchor_lang::{AccountDeserialize, InstructionData, ToAccountMetas};
use anchor_lang::prelude::Pubkey;
use anchor_lang::solana_program::instruction::Instruction;
use solana_keypair::read_keypair_file;
use solana_rpc_client::rpc_client::RpcClient;
use solana_signer::Signer;
use solana_transaction::Transaction;
use std::str::FromStr;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 3 {
        eprintln!("usage: admin-cli <program-id> <admin-keypair-path> <rpc-url> [puller-key ...]");
        std::process::exit(2);
    }
    let program_id = Pubkey::from_str(&args[0]).expect("invalid program id");
    let admin = read_keypair_file(&args[1]).expect("cannot read admin keypair");
    // "confirmed", not the default "finalized": deploy.sh runs this right
    // after `solana program deploy` (which confirms at "confirmed"), and a
    // finalized-state preflight would simulate against the pre-upgrade
    // binary for ~30s and fail with InstructionFallbackNotFound.
    let client = RpcClient::new_with_commitment(
        args[2].clone(),
        solana_commitment_config::CommitmentConfig::confirmed(),
    );
    let puller_keys: Vec<Pubkey> = args[3..]
        .iter()
        .map(|k| Pubkey::from_str(k).expect("invalid puller key"))
        .collect();

    let (config, _) =
        Pubkey::find_program_address(&[subscription_controller::CONFIG_SEED], &program_id);

    let ix = if client.get_account(&config).is_err() {
        println!("config {config} not found — initializing (admin = {})", admin.pubkey());
        Instruction::new_with_bytes(
            program_id,
            &subscription_controller::instruction::Initialize {
                puller_keys: puller_keys.clone(),
            }
            .data(),
            subscription_controller::accounts::Initialize {
                config,
                admin: admin.pubkey(),
                system_program: anchor_lang::system_program::ID,
            }
            .to_account_metas(None),
        )
    } else {
        println!("config {config} exists — updating puller keys");
        Instruction::new_with_bytes(
            program_id,
            &subscription_controller::instruction::SetPullerKeys {
                puller_keys: puller_keys.clone(),
            }
            .data(),
            subscription_controller::accounts::SetPullerKeys {
                config,
                admin: admin.pubkey(),
            }
            .to_account_metas(None),
        )
    };

    let blockhash = client.get_latest_blockhash().expect("get blockhash");
    let tx = Transaction::new_signed_with_payer(
        &[ix],
        Some(&admin.pubkey()),
        &[&admin],
        blockhash,
    );
    let sig = client
        .send_and_confirm_transaction(&tx)
        .expect("transaction failed");
    println!("confirmed: {sig}");

    let account = client.get_account(&config).expect("fetch config");
    let state =
        subscription_controller::Config::try_deserialize(&mut account.data.as_slice())
            .expect("decode config");
    println!("on-chain config now:");
    println!("  admin       : {}", state.admin);
    if state.puller_keys.is_empty() {
        println!("  puller keys : <EMPTY — KILL SWITCH: no key can pull>");
    } else {
        for k in state.puller_keys {
            println!("  puller key  : {k}");
        }
    }
}
