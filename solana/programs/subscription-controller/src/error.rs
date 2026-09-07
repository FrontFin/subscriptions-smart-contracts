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
    // APPENDED. Anchor numbers these positionally from 6000 and both live
    // deployments already publish 6000..=6004, so a new variant may only be
    // added at the end — never inserted.
    //
    // NOTE: feature/sec-118-destination-allowlist also appends, starting at
    // this same 6005. Both branches are stacked on fix/audit-remediation, so
    // whichever merges SECOND must move its own variants after the first's —
    // the number is the wire contract, not the name.
    #[msg("Pull amount is below MIN_PULL_AMOUNT")]
    AmountBelowMinimum,
}
