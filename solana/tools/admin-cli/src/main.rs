//! Admin CLI: <program-id> <signer> <rpc-url> <command> [args].
//! Signer: keypair path sends directly; tx:<pubkey> emits UNSIGNED_TX_B64;
//! print emits a Squads instruction using the on-chain admin; print:<pubkey>
//! emits one for a signer the config does not name, such as the upgrade
//! authority on the loader's Close.
//! keys initializes missing config; an empty key list disables pulls.

use anchor_lang::prelude::Pubkey;
use anchor_lang::solana_program::instruction::Instruction;
use anchor_lang::{AccountDeserialize, InstructionData, ToAccountMetas};
use solana_keypair::read_keypair_file;
use solana_rpc_client::rpc_client::RpcClient;
use anchor_lang::solana_program::instruction::AccountMeta;
use solana_signer::Signer;
use solana_transaction::Transaction;
use std::str::FromStr;

const LOADER: &str = "BPFLoaderUpgradeab1e11111111111111111111111";
const SYSVAR_RENT: &str = "SysvarRent111111111111111111111111111111111";
const SYSVAR_CLOCK: &str = "SysvarC1ock11111111111111111111111111111111";

fn base64(data: &[u8]) -> String {
    const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    out
}

const B58: &str = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

fn base58(bytes: &[u8]) -> String {
    let mut n = num_bigint(bytes);
    let mut out = String::new();
    while !n.is_empty() {
        let mut rem = 0u32;
        let mut next = Vec::with_capacity(n.len());
        for &limb in &n {
            let acc = (rem as u64) << 32 | limb as u64;
            let q = (acc / 58) as u32;
            rem = (acc % 58) as u32;
            if !next.is_empty() || q != 0 {
                next.push(q);
            }
        }
        out.push(B58.as_bytes()[rem as usize] as char);
        n = next;
    }
    for &b in bytes {
        if b == 0 {
            out.push('1');
        } else {
            break;
        }
    }
    out.chars().rev().collect()
}

fn num_bigint(bytes: &[u8]) -> Vec<u32> {
    // big-endian u32 limbs
    let mut n: Vec<u32> = Vec::new();
    for &b in bytes {
        let mut carry = b as u64;
        for limb in n.iter_mut().rev() {
            let acc = (*limb as u64) << 8 | carry;
            *limb = (acc & 0xFFFF_FFFF) as u32;
            carry = acc >> 32;
        }
        if carry != 0 {
            n.insert(0, carry as u32);
        }
    }
    n
}

/// Only account absence returns None; treating RPC errors as absence would build Initialize.
fn fetch_config(client: &RpcClient, config: &Pubkey) -> Option<subscription_controller::Config> {
    let account = match client.get_account_with_commitment(config, client.commitment()) {
        Ok(response) => response.value?,
        Err(err) => {
            eprintln!("error: cannot read config {config} over RPC: {err}");
            std::process::exit(1);
        }
    };
    match subscription_controller::Config::try_deserialize(&mut account.data.as_slice()) {
        Ok(state) => Some(state),
        Err(err) => {
            eprintln!("error: config {config} exists but does not deserialize: {err}");
            std::process::exit(1);
        }
    }
}

fn print_config(client: &RpcClient, config: &Pubkey) {
    if let Some(state) = fetch_config(client, config) {
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
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 4 {
        eprintln!("usage: admin-cli <program-id> <signer-keypair|print> <rpc-url> keys  [puller-key ...]");
        eprintln!("       admin-cli <program-id> <signer-keypair|print> <rpc-url> admin <new-admin>");
        std::process::exit(2);
    }
    let program_id = Pubkey::from_str(&args[0]).expect("invalid program id");
    let print_signer: Option<Pubkey> = args[1]
        .strip_prefix("print:")
        .map(|p| Pubkey::from_str(p).expect("invalid print:<pubkey> signer"));
    let print_only = args[1] == "print" || print_signer.is_some();
    let tx_payer: Option<Pubkey> = args[1]
        .strip_prefix("tx:")
        .map(|p| Pubkey::from_str(p).expect("invalid tx:<pubkey> payer"));
    // Match deploy confirmation so preflight sees the new binary rather than stale finalized state.
    let client = RpcClient::new_with_commitment(
        args[2].clone(),
        solana_commitment_config::CommitmentConfig::confirmed(),
    );
    let command = args[3].as_str();

    let (config, _) =
        Pubkey::find_program_address(&[subscription_controller::CONFIG_SEED], &program_id);

    let admin_pubkey: Pubkey;
    let keypair = if let Some(signer) = print_signer {
        admin_pubkey = signer;
        None
    } else if print_only {
        let state = fetch_config(&client, &config)
            .expect("print mode needs an existing config (initialize directly first)");
        admin_pubkey = if command == "accept-admin" {
            state.pending_admin
        } else {
            state.admin
        };
        None
    } else if let Some(payer) = tx_payer {
        admin_pubkey = payer;
        None
    } else {
        let kp = read_keypair_file(&args[1]).expect("cannot read signer keypair file");
        admin_pubkey = kp.pubkey();
        Some(kp)
    };

    let ix = match command {
        "keys" => {
            let puller_keys: Vec<Pubkey> = args[4..]
                .iter()
                .map(|k| Pubkey::from_str(k).expect("invalid puller key"))
                .collect();
            if !print_only && fetch_config(&client, &config).is_none() {
                println!("config {config} not found — initializing (admin = {admin_pubkey})");
                let (program_data, _) = Pubkey::find_program_address(
                    &[program_id.as_ref()],
                    &anchor_lang::solana_program::bpf_loader_upgradeable::ID,
                );
                Instruction::new_with_bytes(
                    program_id,
                    &subscription_controller::instruction::Initialize { puller_keys }.data(),
                    subscription_controller::accounts::Initialize {
                        config,
                        admin: admin_pubkey,
                        program_data,
                        system_program: anchor_lang::system_program::ID,
                    }
                    .to_account_metas(None),
                )
            } else {
                Instruction::new_with_bytes(
                    program_id,
                    &subscription_controller::instruction::SetPullerKeys { puller_keys }.data(),
                    subscription_controller::accounts::AdminAction {
                        config,
                        admin: admin_pubkey,
                    }
                    .to_account_metas(None),
                )
            }
        }
        "propose-admin" => {
            let new_admin =
                Pubkey::from_str(args.get(4).expect("usage: ... propose-admin <new-admin>"))
                    .expect("invalid new-admin pubkey");
            println!("propose_admin → {new_admin} (they must then accept-admin)");
            Instruction::new_with_bytes(
                program_id,
                &subscription_controller::instruction::ProposeAdmin { new_admin }.data(),
                subscription_controller::accounts::AdminAction {
                    config,
                    admin: admin_pubkey,
                }
                .to_account_metas(None),
            )
        }
        "accept-admin" => {
            println!("accept_admin as {admin_pubkey}");
            Instruction::new_with_bytes(
                program_id,
                &subscription_controller::instruction::AcceptAdmin {}.data(),
                subscription_controller::accounts::AcceptAdmin {
                    config,
                    new_admin: admin_pubkey,
                }
                .to_account_metas(None),
            )
        }
        "close-config" => {
            println!("close_config (reclaim rent) — admin {admin_pubkey}");
            Instruction::new_with_bytes(
                program_id,
                &subscription_controller::instruction::CloseConfig {}.data(),
                subscription_controller::accounts::CloseConfig {
                    config,
                    admin: admin_pubkey,
                }
                .to_account_metas(None),
            )
        }
        "show" => {
            print_config(&client, &config);
            return;
        }
        "close" => {
            // Loader v3 Close (5) targets ProgramData, not the program account.
            let recipient = Pubkey::from_str(
                args.get(4).expect("usage: ... close <recipient>"),
            )
            .expect("invalid recipient");
            let loader = Pubkey::from_str(LOADER).unwrap();
            let (programdata, _) =
                Pubkey::find_program_address(&[program_id.as_ref()], &loader);
            println!("close program {program_id} — rent refund → {recipient}");
            Instruction::new_with_bytes(
                loader,
                &5u32.to_le_bytes(),
                vec![
                    AccountMeta::new(programdata, false),
                    AccountMeta::new(recipient, false),
                    AccountMeta::new_readonly(admin_pubkey, true),
                    AccountMeta::new(program_id, false),
                ],
            )
        }
        "transfer" => {
            let to = Pubkey::from_str(
                args.get(4).expect("usage: ... transfer <to> <lamports>"),
            )
            .expect("invalid recipient");
            let lamports: u64 = args
                .get(5)
                .expect("usage: ... transfer <to> <lamports>")
                .parse()
                .expect("invalid lamports");
            let system = Pubkey::from_str("11111111111111111111111111111111").unwrap();
            let mut data = 2u32.to_le_bytes().to_vec();
            data.extend_from_slice(&lamports.to_le_bytes());
            println!("transfer {lamports} lamports {admin_pubkey} → {to}");
            Instruction::new_with_bytes(
                system,
                &data,
                vec![
                    AccountMeta::new(admin_pubkey, true),
                    AccountMeta::new(to, false),
                ],
            )
        }
        "upgrade" => {
            let buffer = Pubkey::from_str(
                args.get(4).expect("usage: ... upgrade <buffer-address>"),
            )
            .expect("invalid buffer address");
            let loader = Pubkey::from_str(LOADER).unwrap();
            let (programdata, _) =
                Pubkey::find_program_address(&[program_id.as_ref()], &loader);
            println!("upgrade {program_id} from buffer {buffer} (authority {admin_pubkey})");
            // Loader v3 Upgrade (3); refund buffer rent to the authority.
            Instruction::new_with_bytes(
                loader,
                &3u32.to_le_bytes(),
                vec![
                    AccountMeta::new(programdata, false),
                    AccountMeta::new(program_id, false),
                    AccountMeta::new(buffer, false),
                    AccountMeta::new(admin_pubkey, false),
                    AccountMeta::new_readonly(Pubkey::from_str(SYSVAR_RENT).unwrap(), false),
                    AccountMeta::new_readonly(Pubkey::from_str(SYSVAR_CLOCK).unwrap(), false),
                    AccountMeta::new_readonly(admin_pubkey, true),
                ],
            )
        }
        other => {
            eprintln!("unknown command '{other}' (expected keys | propose-admin | accept-admin | upgrade | close | show)");
            std::process::exit(2);
        }
    };

    if let Some(payer) = tx_payer {
        let blockhash = client.get_latest_blockhash().expect("get blockhash");
        let message = solana_message::Message::new_with_blockhash(
            &[ix],
            Some(&payer),
            &blockhash,
        );
        let tx = Transaction::new_unsigned(message);
        let bytes = bincode::serialize(&tx).expect("serialize transaction");
        println!("(sign within ~60s — the blockhash expires)");
        println!("UNSIGNED_TX_B64:{}", base64(&bytes));
        return;
    }

    if print_only {
        println!();
        println!("Unsigned instruction for the Squads transaction builder");
        println!("(create a tx in the Squad that owns admin {admin_pubkey}):");
        println!();
        println!("  Program ID : {program_id}");
        println!("  Accounts   :");
        for (i, meta) in ix.accounts.iter().enumerate() {
            let mut flags = Vec::new();
            if meta.is_signer {
                flags.push("signer");
            }
            if meta.is_writable {
                flags.push("writable");
            }
            println!("    {}. {}  [{}]", i + 1, meta.pubkey, flags.join(", "));
        }
        println!("  Data (base58): {}", base58(&ix.data));
        println!("  Data (hex)   : {}", ix.data.iter().map(|b| format!("{b:02x}")).collect::<String>());
        println!();
        println!("The 'signer' account is the vault — Squads signs it at execution.");
        return;
    }

    let keypair = keypair.unwrap();
    let blockhash = client.get_latest_blockhash().expect("get blockhash");
    let tx =
        Transaction::new_signed_with_payer(&[ix], Some(&keypair.pubkey()), &[&keypair], blockhash);
    let sig = client
        .send_and_confirm_transaction(&tx)
        .expect("transaction failed");
    println!("confirmed: {sig}");
    print_config(&client, &config);
}
