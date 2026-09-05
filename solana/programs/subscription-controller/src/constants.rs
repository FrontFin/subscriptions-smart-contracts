//! Compile-time configuration. Only protocol-level values live here — the
//! puller-key allowlist is on-chain DATA (the `Config` account), updated by
//! `set_puller_keys` without touching this (audited) code.
//!
//! The `MeshDelegate` PDA depends only on the program ID, so neither
//! upgrades nor config updates ever invalidate existing delegations.

use anchor_lang::prelude::*;

/// Seed for the `MeshDelegate` PDA: `["mesh_delegate"]`. This PDA is
/// registered as the `delegatee` on every new recurring delegation. It has no
/// private key; the program signs pulls on its behalf via `invoke_signed`.
/// FROZEN: changing it after launch strands every existing delegation.
#[constant]
pub const DELEGATE_SEED: &[u8] = b"mesh_delegate";

/// Seed for the singleton `Config` PDA holding the admin + puller-key list.
#[constant]
pub const CONFIG_SEED: &[u8] = b"config";

/// Upper bound on `Config.puller_keys` (sizes the account; rotation overlap
/// needs 2 — 16 is generous headroom).
#[constant]
pub const MAX_PULLER_KEYS: usize = 16;

/// Seed for the singleton `DestinationRegistry` PDA: `["destinations"]`.
/// A SEPARATE account, not a new `Config` field: `Config`'s byte layout is
/// frozen by the two live mainnet deployments, and `puller_keys` is a
/// variable-length `Vec` in the middle of it, so an appended field would read
/// stale bytes whenever the key list shrinks (which is exactly what the kill
/// switch does).
#[constant]
pub const DESTINATIONS_SEED: &[u8] = b"destinations";

/// Upper bound on `DestinationRegistry.destination_owners` (sizes the account).
/// Raising it needs a program upgrade AND a resize of the existing registry
/// account, because an account's allocated size is fixed at creation.
#[constant]
pub const MAX_DESTINATIONS: usize = 16;

/// Layout version of `DestinationRegistry`, stored as its FIELD 0 so it sits at
/// a fixed offset no matter how long the list is. `pull` refuses to run against
/// any other value, so a future layout change cannot be misread as this one.
#[constant]
pub const DESTINATION_REGISTRY_VERSION: u8 = 1;

/// The native Solana Subscriptions program this program CPIs into (the program
/// that owns `RecurringDelegation` and enforces the per-period cap / expiry).
/// Matches `SolanaSubscriptionInstructionBuilder.ProgramId` in FrontBackEnd.
pub const SUBSCRIPTIONS_PROGRAM: Pubkey = pubkey!("De1egAFMkMWZSN5rYXRj9CAdheBamobVNubTsi9avR44");

/// The native recurring `pull_payment` instruction — single-byte discriminator
/// and exact data length (`[disc(1)] + amount(8) + delegator(32) + mint(32)`).
/// `pull` pins these so a puller key can forward ONLY pull_payment as the
/// delegatee, never any other native instruction. Matches
/// `PullPaymentRecurringDiscriminator` / `PullPaymentDataLength` in FrontBackEnd.
/// (The amount WITHIN pull_payment stays caller-chosen, capped per period by
/// the native program. The destination does not: `pull` reads the token
/// balances back after the CPI and requires the credited account to be an
/// allowlisted owner's canonical ATA.)
pub const NATIVE_PULL_DISCRIMINATOR: u8 = 5;
pub const NATIVE_PULL_DATA_LEN: usize = 73;

/// Byte offsets of the two pubkeys inside a `pull_payment` payload. The length
/// above is pinned before either is read, so both slices are always in range.
pub const NATIVE_PULL_DELEGATOR_OFFSET: usize = 9;
pub const NATIVE_PULL_MINT_OFFSET: usize = 41;

/// The two SPL token programs a destination account can be owned by. Used to
/// pick the token accounts out of `remaining_accounts` before and after the CPI
/// and, for the one that got credited, to derive its canonical ATA address.
pub const TOKEN_PROGRAM: Pubkey = pubkey!("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
pub const TOKEN_2022_PROGRAM: Pubkey = pubkey!("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb");

/// The Associated Token Account program, whose PDA
/// `[owner, token_program, mint]` is the only destination address `pull`
/// accepts for an allowlisted owner.
pub const ASSOCIATED_TOKEN_PROGRAM: Pubkey =
    pubkey!("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL");

/// Length of a classic SPL token account. Token-2022 accounts start with the
/// same 165-byte body and append their extensions, so `mint` at `[0..32]`,
/// `owner` at `[32..64]` and `amount` at `[64..72]` read the same in both.
pub const SPL_TOKEN_ACCOUNT_LEN: usize = 165;
