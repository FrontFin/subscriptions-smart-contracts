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
    // Everything below is APPENDED. Anchor numbers these positionally from
    // 6000, and both live deployments already publish 6000..=6004, so a new
    // variant may only be added at the end — never inserted.
    #[msg("Destination owner list exceeds MAX_DESTINATIONS")]
    TooManyDestinations,
    #[msg("Destination registry has an unsupported layout version")]
    UnsupportedRegistryVersion,
    #[msg("No token account of the pulled mint gained a balance")]
    NoDestinationCredited,
    #[msg("More than one token account of the pulled mint gained a balance")]
    MultipleDestinationsCredited,
    #[msg("Credited token account is owned by a key that is not allowlisted")]
    DestinationOwnerNotAllowlisted,
    #[msg("Credited token account is not its owner's canonical associated token account")]
    DestinationIsNotCanonicalAta,
}
