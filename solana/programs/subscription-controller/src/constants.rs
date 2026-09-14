
use anchor_lang::prelude::*;

/// Changing this seed invalidates existing delegations.
#[constant]
pub const DELEGATE_SEED: &[u8] = b"mesh_delegate";

#[constant]
pub const CONFIG_SEED: &[u8] = b"config";

/// Account allocation limit; allow room for overlapping keys during rotation.
#[constant]
pub const MAX_PULLER_KEYS: usize = 16;

/// Must match the backend's native subscription program ID.
pub const SUBSCRIPTIONS_PROGRAM: Pubkey = pubkey!("De1egAFMkMWZSN5rYXRj9CAdheBamobVNubTsi9avR44");

/// Native pull_payment wire format: discriminator (1) + amount (8) + delegator (32) + mint (32).
pub const NATIVE_PULL_DISCRIMINATOR: u8 = 5;
pub const NATIVE_PULL_DATA_LEN: usize = 73;

/// Little-endian u64 immediately after the discriminator.
pub const NATIVE_PULL_AMOUNT_OFFSET: usize = 1;

/// Minimum pull in token base units: 10_000 is $0.01 for six-decimal USDC.
/// This is a fee-abuse policy, not a protocol limit. The mint is not pinned;
/// reassess the floor before supporting other decimals.
#[constant]
pub const MIN_PULL_AMOUNT: u64 = 10_000;
