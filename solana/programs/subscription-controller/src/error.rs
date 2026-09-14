use anchor_lang::prelude::*;

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
