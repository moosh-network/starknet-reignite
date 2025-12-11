mod Events {
    // Event data structs are now public within this module
    #[derive(Drop, starknet::Event)]
    pub struct VerificationSuccess {
        #[key]
        pub key_hash: felt252,
        pub msg_hash_part: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct VerificationFailed {
        #[key]
        pub key_hash: felt252,
        pub msg_hash_part: felt252,
        pub reason: felt252,
    }
}


#[starknet::contract]
pub mod FalconSignatureVerifier {
    // --- Core Imports ---
    use core::array::{ArrayTrait, Span, SpanTrait};
    use core::option::OptionTrait;
    use core::traits::{Into, TryInto};
    use falcon::falcon::{FalconVerificationError, verify_uncompressed};

    // --- Dependency Imports ---
    use moosh_id::keyregistry::FalconPublicKeyRegistry::{
        IFalconPublicKeyRegistryDispatcher, IFalconPublicKeyRegistryDispatcherTrait,
    };
    use starknet::syscalls::emit_event_syscall;
    use starknet::{ContractAddress, SyscallResultTrait};

    // --- Constants ---
    const PK_SIZE_512: u32 = 512;
    const PK_SIZE_1024: u32 = 1024;

    // --- Starknet Imports ---
    use starknet::event::{EventEmitter};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};

    use super::Events::{VerificationFailed, VerificationSuccess}; // Import the event data structs

    // --- Storage ---
    #[storage]
    struct Storage {
        key_registry_address: ContractAddress,
    }

    // --- Contract's Main Event Enum ---
    // This enum references the structs defined in the Events module.
    #[event]
    #[derive(Drop, starknet::Event)] // This derive needs StarknetEventTrait
    pub enum Event { // Made pub as per Starknet docs example
        // Variants now use the imported struct types
        VerificationSuccess: VerificationSuccess,
        VerificationFailed: VerificationFailed,
    }

    // --- Constructor ---
    #[constructor]
    fn constructor(ref self: ContractState, key_registry_addr: ContractAddress) {
        self.key_registry_address.write(key_registry_addr);
    }

    // --- Contract Interface (ABI) ---
    #[starknet::interface]
    pub trait IFalconSignatureVerifier<TContractState> {
        fn verify_signature_for_key_hash(
            self: @TContractState,
            key_hash: felt252,
            s1_coeffs_span: Span<u16>,
            msg_point_span: Span<u16>,
        ) -> bool;
    }

    // --- Contract Implementation ---
    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn emit_success(ref self: ContractState, key_hash: felt252, msg_hash_part: felt252) {
            self.emit(Event::VerificationSuccess(VerificationSuccess { key_hash, msg_hash_part }));
        }

        fn emit_failure(
            ref self: ContractState, key_hash: felt252, msg_hash_part: felt252, reason: felt252,
        ) {
            self
                .emit(
                    Event::VerificationFailed(
                        VerificationFailed { key_hash, msg_hash_part, reason },
                    ),
                );
        }

        fn get_msg_hash_part(msg_point_span: Span<u16>) -> felt252 {
            if msg_point_span.len() > 0 {
                (*msg_point_span.at(0)).into()
            } else {
                0.into()
            }
        }
    }

    #[abi(embed_v0)]
    impl FalconSignatureVerifierImpl of IFalconSignatureVerifier<ContractState> {
        fn verify_signature_for_key_hash(
            self: @ContractState,
            key_hash: felt252,
            s1_coeffs_span: Span<u16>,
            msg_point_span: Span<u16>,
        ) -> bool {
            let registry_address = self.key_registry_address.read();
            let key_registry_dispatcher = IFalconPublicKeyRegistryDispatcher {
                contract_address: registry_address,
            };

            let pk_coeffs_array = key_registry_dispatcher.get_public_key(key_hash);
            let n_val: u32 = pk_coeffs_array.len().try_into().unwrap();

            // Validate key size
            assert(n_val == PK_SIZE_512 || n_val == PK_SIZE_1024, 'Invalid PK size');
            assert(s1_coeffs_span.len() == pk_coeffs_array.len(), 's1 length mismatch');
            assert(msg_point_span.len() == pk_coeffs_array.len(), 'msg_point length');

            let msg_hash_part = InternalImpl::get_msg_hash_part(msg_point_span);

            let result = if n_val == PK_SIZE_512 {
                verify_uncompressed::<
                    512,
                >(s1_coeffs_span, pk_coeffs_array.span(), msg_point_span, n_val)
            } else {
                verify_uncompressed::<
                    1024,
                >(s1_coeffs_span, pk_coeffs_array.span(), msg_point_span, n_val)
            };

            match result {
                Result::Ok(()) => {
                    let mut keys = array![key_hash];
                    let mut data = array![msg_hash_part];
                    emit_event_syscall(keys.span(), data.span()).unwrap_syscall();
                    true
                },
                Result::Err(falcon_error) => {
                    let error_felt = match falcon_error {
                        FalconVerificationError::NormOverflow => 'NormOverflow',
                    };
                    let mut keys = array![key_hash];
                    let mut data = array![msg_hash_part, error_felt];
                    emit_event_syscall(keys.span(), data.span()).unwrap_syscall();
                    false
                },
            }
        }
    }

    #[starknet::interface]
    trait IFalconSignatureVerifierEvents<TContractState> {
        fn emit_success(ref self: TContractState, key_hash: felt252, msg_hash_part: felt252);
        fn emit_failure(
            ref self: TContractState, key_hash: felt252, msg_hash_part: felt252, reason: felt252,
        );
    }

    #[abi(embed_v0)]
    impl FalconSignatureVerifierEventsImpl of IFalconSignatureVerifierEvents<ContractState> {
        fn emit_success(ref self: ContractState, key_hash: felt252, msg_hash_part: felt252) {
            self.emit(Event::VerificationSuccess(VerificationSuccess { key_hash, msg_hash_part }));
        }

        fn emit_failure(
            ref self: ContractState, key_hash: felt252, msg_hash_part: felt252, reason: felt252,
        ) {
            self
                .emit(
                    Event::VerificationFailed(
                        VerificationFailed { key_hash, msg_hash_part, reason },
                    ),
                );
        }
    }
}
