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

/// The native Solana Subscriptions program this program CPIs into (the program
/// that owns `RecurringDelegation` and enforces the per-period cap / expiry).
/// Matches `SolanaSubscriptionInstructionBuilder.ProgramId` in FrontBackEnd.
pub const SUBSCRIPTIONS_PROGRAM: Pubkey = pubkey!("De1egAFMkMWZSN5rYXRj9CAdheBamobVNubTsi9avR44");

/// The native recurring `pull_payment` instruction — single-byte discriminator
/// and exact data length (`[disc(1)] + amount(8) + delegator(32) + mint(32)`).
/// `pull` pins these so a puller key can forward ONLY pull_payment as the
/// delegatee, never any other native instruction. Matches
/// `PullPaymentRecurringDiscriminator` / `PullPaymentDataLength` in FrontBackEnd.
/// (Destination and amount WITHIN pull_payment stay caller-chosen — accepted
/// design tradeoff, mitigated by kill switch + rotation, not by this program.)
pub const NATIVE_PULL_DISCRIMINATOR: u8 = 5;
pub const NATIVE_PULL_DATA_LEN: usize = 73;
