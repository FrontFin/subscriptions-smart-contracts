use anchor_lang::prelude::*;

#[error_code]
pub enum ControllerError {
    // There is no distinct "Paused" state: the kill switch ("pause") is simply
    // an empty puller-key list, which authorizes no one, so every pull fails
    // `Unauthorized`.
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
}
