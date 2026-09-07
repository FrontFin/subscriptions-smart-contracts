//! Byte-layout guards for the on-chain `Config` account.
//!
//! `Config` is live on two mainnet programs. Borsh deserializes positionally,
//! so any change to the field order, to a field's type, or to `SPACE` misreads
//! the deployed accounts instead of failing loudly.
//!
//! These are pure host-side assertions with no `include_bytes!`, so they run
//! without an SBF toolchain: `cargo test --test test_config_layout`.
//!
//! If one of these goes red, do NOT update the literals to match. The literals
//! describe accounts that already exist on chain and cannot be rewritten.

use {
    anchor_lang::{prelude::Pubkey, AccountSerialize, Discriminator},
    subscription_controller::{
        Config, DestinationRegistry, DESTINATION_REGISTRY_VERSION, MAX_DESTINATIONS,
        MAX_PULLER_KEYS,
    },
};

const DISCRIMINATOR: [u8; 8] = [155, 12, 170, 224, 30, 250, 204, 130];

fn serialize(config: &Config) -> Vec<u8> {
    let mut bytes = Vec::new();
    config.try_serialize(&mut bytes).expect("Config serializes");
    bytes
}

fn config_with(puller_keys: Vec<Pubkey>) -> Config {
    Config {
        admin: Pubkey::new_from_array([7u8; 32]),
        puller_keys,
        pending_admin: Pubkey::new_from_array([13u8; 32]),
    }
}

#[test]
fn discriminator_is_frozen() {
    assert_eq!(
        Config::DISCRIMINATOR,
        &DISCRIMINATOR[..],
        "renaming the Config struct strands both deployed accounts"
    );
}

#[test]
fn space_is_frozen() {
    assert_eq!(Config::SPACE, 588);
    assert_eq!(MAX_PULLER_KEYS, 16);
}

#[test]
fn field_offsets_are_frozen() {
    let keys = vec![
        Pubkey::new_from_array([9u8; 32]),
        Pubkey::new_from_array([11u8; 32]),
    ];
    let config = config_with(keys.clone());
    let bytes = serialize(&config);

    assert_eq!(&bytes[0..8], &DISCRIMINATOR[..]);
    assert_eq!(&bytes[8..40], config.admin.as_ref());
    assert_eq!(u32::from_le_bytes(bytes[40..44].try_into().unwrap()), 2);
    assert_eq!(&bytes[44..76], keys[0].as_ref());
    assert_eq!(&bytes[76..108], keys[1].as_ref());
    assert_eq!(&bytes[108..140], config.pending_admin.as_ref());
    assert_eq!(bytes.len(), 140, "no field may follow pending_admin");
}

#[test]
fn pending_admin_offset_moves_with_the_puller_key_count() {
    for count in [0usize, 1, 2, MAX_PULLER_KEYS] {
        let config = config_with(vec![Pubkey::new_from_array([9u8; 32]); count]);
        let bytes = serialize(&config);
        let offset = 44 + 32 * count;
        assert_eq!(
            &bytes[offset..offset + 32],
            config.pending_admin.as_ref(),
            "pending_admin is not at a fixed offset; nothing may be appended after it"
        );
        assert_eq!(bytes.len(), offset + 32);
    }
}

#[test]
fn a_full_config_exactly_fills_its_allocated_space() {
    let bytes = serialize(&config_with(vec![
        Pubkey::new_from_array([9u8; 32]);
        MAX_PULLER_KEYS
    ]));
    assert_eq!(
        bytes.len(),
        Config::SPACE,
        "a full puller-key list leaves no spare byte, so an appended field \
         cannot be written and every instruction that loads Config fails"
    );
}

// ---------------------------------------------------------------------------
// The destination registry is a NEW account, so its layout is not yet frozen by
// anything on chain. These guards pin the one property the program depends on:
// `version` is field 0, so it is readable at a fixed offset no matter how long
// the owner list is, which is what makes a future migration detectable.
// ---------------------------------------------------------------------------

fn serialize_registry(registry: &DestinationRegistry) -> Vec<u8> {
    let mut bytes = Vec::new();
    registry
        .try_serialize(&mut bytes)
        .expect("DestinationRegistry serializes");
    bytes
}

#[test]
fn registry_space_fits_a_full_owner_list() {
    let bytes = serialize_registry(&DestinationRegistry {
        version: DESTINATION_REGISTRY_VERSION,
        destination_owners: vec![Pubkey::new_from_array([5u8; 32]); MAX_DESTINATIONS],
    });
    assert_eq!(DestinationRegistry::SPACE, 525);
    assert_eq!(bytes.len(), DestinationRegistry::SPACE);
}

#[test]
fn registry_version_is_field_zero_at_a_fixed_offset() {
    for count in [0usize, 1, 2, MAX_DESTINATIONS] {
        let owners = vec![Pubkey::new_from_array([5u8; 32]); count];
        let bytes = serialize_registry(&DestinationRegistry {
            version: DESTINATION_REGISTRY_VERSION,
            destination_owners: owners.clone(),
        });

        assert_eq!(&bytes[0..8], DestinationRegistry::DISCRIMINATOR);
        assert_eq!(
            bytes[8], DESTINATION_REGISTRY_VERSION,
            "version must stay at offset 8 whatever the list length"
        );
        assert_eq!(
            u32::from_le_bytes(bytes[9..13].try_into().unwrap()),
            count as u32
        );
        for (index, owner) in owners.iter().enumerate() {
            let offset = 13 + 32 * index;
            assert_eq!(&bytes[offset..offset + 32], owner.as_ref());
        }
        assert_eq!(bytes.len(), 13 + 32 * count);
    }
}

#[test]
fn registry_and_config_are_distinct_account_types() {
    assert_ne!(
        Config::DISCRIMINATOR,
        DestinationRegistry::DISCRIMINATOR,
        "a shared discriminator would let one account be loaded as the other"
    );
}
