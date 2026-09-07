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

/// Byte offset of the little-endian `u64` amount inside a `pull_payment`
/// payload — immediately after the single-byte discriminator. The length above
/// is pinned before this is read, so the slice is always in range.
pub const NATIVE_PULL_AMOUNT_OFFSET: usize = 1;

/// Smallest amount `pull` will forward, in the pulled token's BASE UNITS.
/// 10_000 = $0.01 at USDC's 6 decimals (HAL-008 / SEC-123).
///
/// *Why a floor at all:* nothing but the native program's own non-zero check
/// stood between a puller key and an unbounded stream of 1-unit pulls. Each is
/// a separate transaction whose base fee — 5_000 lamports per signature, ~$0.0005
/// at SOL $104 — is paid by the PULLER, i.e. by Mesh. The floor is ~19x that
/// fee, so a pull can never cost more to submit than it moves.
///
/// *Why $0.01 and not more:* Solana has no protocol-level dust limit for SPL
/// amounts (unlike Bitcoin's 546 sats), so this is a policy number. Wallet-
/// cleanup tools commonly call anything under $1 dust, but a floor that high
/// would permanently reject a legitimate sub-dollar plan, prorated charge or
/// partial retry — and raising or lowering this needs a program upgrade. A cent
/// is below any real subscription charge and above any plausible dust.
///
/// ponytail: denominated in base units against a mint this program does not
/// pin, so it is $0.01 only for a 6-decimal mint. The product is USDC-only
/// (README, TDD) so that holds today. Onboarding a mint with different decimals
/// silently changes what this floor is worth — at that point either pin the
/// mint at `NATIVE_PULL_MINT_OFFSET` or carry a per-mint floor.
#[constant]
pub const MIN_PULL_AMOUNT: u64 = 10_000;
