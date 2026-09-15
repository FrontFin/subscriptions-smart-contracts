use anchor_lang::prelude::*;

use crate::constants::MIN_PULL_AMOUNT;

// Anchor's #[msg] takes a literal, so the threshold below is written out. This
// keeps the message and the constant from drifting apart: change one without
// the other and the build stops here.
const _: () = assert!(MIN_PULL_AMOUNT == 10_000);

#[error_code]
pub enum ControllerError {
    // An empty allowlist uses Unauthorized as the kill-switch error.
    #[msg("Signer is not one of the authorized puller keys")]
    Unauthorized,
    #[msg("Target program does not match the configured subscriptions program")]
    WrongTargetProgram,
    #[msg("Puller key list exceeds MAX_PULLER_KEYS")]
    TooManyPullerKeys,
    #[msg("Forwarded instruction is not the native recurring pull_payment")]
    UnexpectedNativeInstruction,
    #[msg("Config cannot be closed while an admin handover is pending")]
    HandoverPending,
    // Append errors only: Anchor assigns wire codes by position, starting at 6000.
    #[msg("Pull amount is below the minimum of 10000 token base units")]
    AmountBelowMinimum,
}
