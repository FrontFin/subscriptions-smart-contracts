//! Compile-time configuration, baked into the binary.
//!
//! This program deliberately has NO on-chain state: all admin actions —
//! kill switch, puller-key rotation, retargeting — are program upgrades that
//! change the constants below and are signed by the upgrade authority.
//! The `MeshDelegate` PDA depends only on the program ID, so upgrades never
//! invalidate existing delegations.

use anchor_lang::prelude::*;

/// Seed for the `MeshDelegate` PDA: `["mesh_delegate"]`. This PDA is registered as
/// the `delegatee` on every new recurring delegation. It has no private key;
/// the program signs pulls on its behalf via `invoke_signed`.
#[constant]
pub const DELEGATE_SEED: &[u8] = b"mesh_delegate";

/// The operational puller keys allowed to trigger `pull` — the Mesh puller
/// keys. They only authorize and pay fees — they are NOT the delegatee, so
/// changing this list (via program upgrade) never invalidates a delegation.
///
/// ⚠️ The committed values are LOCAL TEST keys, derived in the test suite
/// from fixed public seeds (`[1u8; 32]` / `[2u8; 32]` — see
/// `fixture_puller_keypairs` in `tests/test_controller.rs`; two entries so the
/// tests exercise rotation overlap). No private-key files exist in the repo,
/// but anyone can derive these keys — before any real deploy, replace them
/// with the real Mesh puller key(s) from Key Vault (see DEPLOY.md step 1).
///
/// - **Rotation**: deploy with both old and new keys listed (zero-downtime
///   overlap), flip the puller's Key Vault secret, then deploy with the old
///   key removed.
/// - **Kill switch ("pause")**: deploy with an EMPTY list — no key is
///   authorized, so every pull fails `Unauthorized` until a non-empty list
///   is deployed again.
pub const PULLER_KEYS: &[Pubkey] = &[
    pubkey!("D8BXX8NxgxFN9LifSuDYQ8rTBfd9wfzVAL1KrntMBnU1"),
    pubkey!("AKnL4NNf3DGWZJS6cPknBuEGnVsV4A4m5tgebLHaRSZ9"),
    pubkey!("9hSR6S7WPtxmTojgo6GG3k4yDPecgJY292j7xrsUGWBu"),
];

/// The native Solana Subscriptions program this program CPIs into (the program
/// that owns `RecurringDelegation` and enforces the per-period cap / expiry).
/// Matches `SolanaSubscriptionInstructionBuilder.ProgramId` in FrontBackEnd.
pub const SUBSCRIPTIONS_PROGRAM: Pubkey = pubkey!("De1egAFMkMWZSN5rYXRj9CAdheBamobVNubTsi9avR44");
