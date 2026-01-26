#[starknet::contract]
pub mod EscrowV2 {
    use core::traits::Into;
    use core::traits::TryInto;
    use core::num::traits::Zero;
    use core::array::Span;
    use starknet::{
        ContractAddress,
        get_contract_address,
        get_caller_address,
        get_block_timestamp,
    };
    use starknet::event::EventEmitter;

    // Import storage traits
    use starknet::storage::{
        StorageMapReadAccess,
        StorageMapWriteAccess,
        StoragePointerReadAccess,
        StoragePointerWriteAccess,
        Map
    };
    
    // Import OpenZeppelin ERC20 interface
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    
    // Import verifier interface
    use moosh_id::addressverifier::FalconSignatureVerifier::{
        IFalconSignatureVerifierDispatcher,
        IFalconSignatureVerifierDispatcherTrait,
    };

    // ============================================================================
    // Constants
    // ============================================================================

    const PERCENTAGE_BASE: u256 = 100;
    const BASIS_POINTS_BASE: u256 = 10000;
    const IMMEDIATE_VEST_PERCENTAGE: u256 = 20; // 20%
    const CLIFF_PERCENTAGE: u256 = 20; // 20% of duration

    // ============================================================================
    // Enums
    // ============================================================================

    /// Status of the escrow contract
    #[allow(starknet::store_no_default_variant)]
    #[derive(Drop, Copy, Serde, starknet::Store, PartialEq)]
    pub enum EscrowStatus {
        Active,
        Disputed,
        Resolved
    }

    /// Dispute resolution outcomes
    #[derive(Drop, Copy, Serde)]
    pub enum DisputeResolution {
        Resume,                    // Return to Active
        RefundRemaining,           // Send unclaimed to client
        ReleaseRemaining,          // Send unclaimed to provider
        SplitRemaining: u16        // Split by basis points (0-10000)
    }

    // ============================================================================
    // Storage
    // ============================================================================

    #[storage]
    struct Storage {
        // Core escrow data
        provider_key_hash: felt252,
        total_amount: u256,
        duration: u64,              // Duration in seconds
        start_time: u64,            // Unix timestamp when vesting starts
        end_time: u64,              // Unix timestamp when vesting completes
        claimed_amount: u256,       // Total amount claimed so far
        status: EscrowStatus,       // Current status of the escrow
        is_deposited: bool,         // Whether deposit has been made
        
        // Dispute tracking
        dispute_reason_hash: felt252,
        
        // Contract participants
        client: ContractAddress,
        provider: ContractAddress,
        arbiter: ContractAddress,     // Optional single arbiter
        resolver: ContractAddress,    // Optional pluggable resolver contract

        // Verifier contract
        verifier: ContractAddress,

        // Key registry contract
        key_registry: ContractAddress,

        // STRK token contract
        strk_token: ContractAddress,

        // Message point for signature verification
        msg_point_len: u32,
        msg_points: Map::<u32, u16>
    }

    // ============================================================================
    // Events
    // ============================================================================

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        EscrowCreated: EscrowCreated,
        EscrowDeposited: EscrowDeposited,
        EscrowClaimed: EscrowClaimed,
        DisputeRaised: DisputeRaised,
        DisputeResolved: DisputeResolved,
    }

    #[derive(Drop, starknet::Event)]
    struct EscrowCreated {
        client: ContractAddress,
        provider_key_hash: felt252,
        total_amount: u256,
        duration: u64,
        arbiter: ContractAddress,
        resolver: ContractAddress
    }

    #[derive(Drop, starknet::Event)]
    struct EscrowDeposited {
        client: ContractAddress,
        amount: u256,
        start_time: u64,
        end_time: u64
    }

    #[derive(Drop, starknet::Event)]
    struct EscrowClaimed {
        provider: ContractAddress,
        amount: u256,
        total_claimed: u256
    }

    #[derive(Drop, starknet::Event)]
    struct DisputeRaised {
        raiser: ContractAddress,
        reason_hash: felt252
    }

    #[derive(Drop, starknet::Event)]
    struct DisputeResolved {
        resolver: ContractAddress,
        client_amount: u256,
        provider_amount: u256
    }

    // ============================================================================
    // Data Structures
    // ============================================================================

    /// Struct to return escrow details
    #[derive(Drop, Serde)]
    pub struct EscrowDetails {
        pub provider_key_hash: felt252,
        pub total_amount: u256,
        pub claimed_amount: u256,
        pub duration: u64,
        pub start_time: u64,
        pub end_time: u64,
        pub status: EscrowStatus,
        pub is_deposited: bool,
        pub client: ContractAddress,
        pub provider: ContractAddress,
        pub arbiter: ContractAddress,
        pub resolver: ContractAddress
    }

    // ============================================================================
    // Constructor
    // ============================================================================

    #[constructor]
    fn constructor(
        ref self: ContractState,
        provider_key_hash: felt252,
        total_amount: u256,
        duration: u64,
        verifier: ContractAddress,
        key_registry: ContractAddress,
        strk_token: ContractAddress,
        client_address: ContractAddress,
        provider_address: ContractAddress,
        arbiter: ContractAddress,
        resolver: ContractAddress,
    ) {
        // Validate parameters
        assert(provider_key_hash != 0, 'Provider key must be non-zero');
        assert(!client_address.is_zero(), 'Client addr must be non-zero');
        assert(!provider_address.is_zero(), 'Provider addr must be non-zero');
        assert(!key_registry.is_zero(), 'Key registry must be non-zero');
        assert(duration > 0, 'Duration must be positive');
        assert(total_amount > 0, 'Amount must be positive');
        
        // At least one dispute authority must be set
        assert(!arbiter.is_zero() || !resolver.is_zero(), 'Need arbiter or resolver');
        
        // Set the escrow parameters
        self.provider_key_hash.write(provider_key_hash);
        self.total_amount.write(total_amount);
        self.duration.write(duration);
        self.verifier.write(verifier);
        self.key_registry.write(key_registry);
        self.strk_token.write(strk_token);
        
        // Set the client and provider addresses
        self.client.write(client_address);
        self.provider.write(provider_address);
        
        // Set dispute authorities
        self.arbiter.write(arbiter);
        self.resolver.write(resolver);
        
        // Initialize state
        self.status.write(EscrowStatus::Active);
        self.is_deposited.write(false);
        self.claimed_amount.write(0);

        // Emit creation event
        self.emit(Event::EscrowCreated(
            EscrowCreated {
                client: client_address,
                provider_key_hash,
                total_amount,
                duration,
                arbiter,
                resolver
            }
        ));
    }

    // ============================================================================
    // Interface
    // ============================================================================

    #[starknet::interface]
    pub trait IEscrowV2<TContractState> {
        fn get_escrow_details(self: @TContractState) -> EscrowDetails;
        fn deposit(ref self: TContractState) -> bool;
        fn claim(ref self: TContractState, s1_coeffs: Span<u16>) -> bool;
        fn raise_dispute(ref self: TContractState, reason_hash: felt252) -> bool;
        fn resolve_dispute(ref self: TContractState, resolution: DisputeResolution) -> bool;
        fn vested_now(self: @TContractState) -> u256;
        fn claimable_now(self: @TContractState) -> u256;
        fn get_client_allowance(self: @TContractState) -> u256;
        fn set_message_points(ref self: TContractState, msg_point_span: Span<u16>) -> bool;
    }

    // ============================================================================
    // Internal Functions
    // ============================================================================

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        /// Assert that caller is the client
        fn assert_only_client(self: @ContractState) {
            let caller = get_caller_address();
            let client = self.client.read();
            assert(caller == client, 'Only client can call');
        }

        /// Assert that caller is the provider
        fn assert_only_provider(self: @ContractState) {
            let caller = get_caller_address();
            let provider = self.provider.read();
            assert(caller == provider, 'Only provider can call');
        }

        /// Assert that caller is either arbiter or resolver
        fn assert_dispute_authority(self: @ContractState) {
            let caller = get_caller_address();
            let arbiter = self.arbiter.read();
            let resolver = self.resolver.read();
            assert(
                caller == arbiter || caller == resolver,
                'Only arbiter/resolver allowed'
            );
        }

        /// Calculate vested amount at a given timestamp
        /// Implements: 20% immediate, cliff at 20% duration, 80% linear vesting
        fn calculate_vested_at_time(
            self: @ContractState,
            current_time: u64
        ) -> u256 {
            let start_time = self.start_time.read();
            let end_time = self.end_time.read();
            let total_amount = self.total_amount.read();
            
            // Before start: nothing vested
            if current_time < start_time {
                return 0;
            }
            
            // After end: everything vested
            if current_time >= end_time {
                return total_amount;
            }
            
            // Calculate cliff time (20% of duration from start)
            let duration = end_time - start_time;
            let cliff_duration = (duration.into() * CLIFF_PERCENTAGE) / PERCENTAGE_BASE;
            let cliff_time = start_time + cliff_duration.try_into().unwrap();
            
            // Immediate vesting: 20%
            let immediate_amount = (total_amount * IMMEDIATE_VEST_PERCENTAGE) / PERCENTAGE_BASE;
            
            // Before cliff: only immediate amount vested
            if current_time < cliff_time {
                return immediate_amount;
            }
            
            // Linear vesting for remaining 80% from cliff to end
            let remaining_amount = total_amount - immediate_amount;
            let time_since_cliff: u256 = (current_time - cliff_time).into();
            let vesting_period: u256 = (end_time - cliff_time).into();
            
            let linear_vested = (remaining_amount * time_since_cliff) / vesting_period;
            
            immediate_amount + linear_vested
        }

        /// Safe transfer that checks balance and performs transfer
        fn safe_transfer(
            self: @ContractState,
            token: IERC20Dispatcher,
            recipient: ContractAddress,
            amount: u256
        ) -> bool {
            // Check contract has sufficient balance
            let contract_balance = token.balance_of(get_contract_address());
            assert(contract_balance >= amount, 'Insufficient contract balance');
            
            // Perform transfer
            token.transfer(recipient, amount)
        }

        /// Validate balance for operation
        fn validate_balance_for_operation(
            self: @ContractState,
            required_amount: u256
        ) -> bool {
            let strk = IERC20Dispatcher { contract_address: self.strk_token.read() };
            let contract_balance = strk.balance_of(get_contract_address());
            contract_balance >= required_amount
        }

        /// Get message points as array
        fn get_msg_point_span(self: @ContractState) -> Array<u16> {
            let msg_point_len = self.msg_point_len.read();
            let mut msg_point_array = ArrayTrait::new();
            
            let mut i: u32 = 0;
            loop {
                if i >= msg_point_len {
                    break;
                }
                let point = self.msg_points.read(i);
                msg_point_array.append(point);
                i += 1;
            };
            
            msg_point_array
        }
    }

    // ============================================================================
    // External Functions
    // ============================================================================

    #[abi(embed_v0)]
    impl EscrowV2Impl of IEscrowV2<ContractState> {
        /// Get complete escrow details
        fn get_escrow_details(self: @ContractState) -> EscrowDetails {
            EscrowDetails {
                provider_key_hash: self.provider_key_hash.read(),
                total_amount: self.total_amount.read(),
                claimed_amount: self.claimed_amount.read(),
                duration: self.duration.read(),
                start_time: self.start_time.read(),
                end_time: self.end_time.read(),
                status: self.status.read(),
                is_deposited: self.is_deposited.read(),
                client: self.client.read(),
                provider: self.provider.read(),
                arbiter: self.arbiter.read(),
                resolver: self.resolver.read()
            }
        }

        /// Deposit funds and start vesting
        fn deposit(ref self: ContractState) -> bool {
            // Only client can deposit
            InternalFunctions::assert_only_client(@self);
            
            // Check if already deposited
            assert(!self.is_deposited.read(), 'Already deposited');
            
            // Check if message points have been set
            assert(self.msg_point_len.read() > 0, 'Message points not set');
            
            // Get the deposit amount
            let total_amount = self.total_amount.read();
            
            // Get contract addresses
            let this_contract = get_contract_address();
            let strk_addr = self.strk_token.read();
            let strk = IERC20Dispatcher { contract_address: strk_addr };
            let client = self.client.read();
            let caller = get_caller_address();
            
            // Verify caller
            assert(caller == client, 'Caller not client');
            let zero_address: ContractAddress = 0.try_into().unwrap();
            assert(strk_addr != zero_address, 'Invalid token address');
            assert(this_contract != zero_address, 'Invalid escrow address');

            // Check client has sufficient balance
            let client_balance = strk.balance_of(client);
            assert(client_balance >= total_amount, 'Insufficient balance');

            // Check allowance is sufficient
            let allowance = strk.allowance(client, this_contract);
            assert(allowance >= total_amount, 'Insufficient allowance');
            
            // Transfer STRK tokens from client to contract
            let transfer_success = strk.transfer_from(client, this_contract, total_amount);
            assert(transfer_success, 'Transfer failed');
            
            // Set vesting times using timestamp
            let current_time = get_block_timestamp();
            let duration = self.duration.read();
            let end_time = current_time + duration;
            
            self.start_time.write(current_time);
            self.end_time.write(end_time);
            
            // Mark as deposited
            self.is_deposited.write(true);
            
            // Emit deposit event
            self.emit(Event::EscrowDeposited(
                EscrowDeposited {
                    client: client,
                    amount: total_amount,
                    start_time: current_time,
                    end_time: end_time
                }
            ));
            
            true
        }

        /// Claim vested tokens (can be called multiple times)
        fn claim(
            ref self: ContractState,
            s1_coeffs: Span<u16>
        ) -> bool {
            // Check if deposit has been made
            assert(self.is_deposited.read(), 'Not deposited');
            
            // Check status is Active
            let status = self.status.read();
            assert(status == EscrowStatus::Active, 'Must be Active to claim');
            
            // Get the key hash and verifier
            let key_hash = self.provider_key_hash.read();
            let verifier = IFalconSignatureVerifierDispatcher { 
                contract_address: self.verifier.read() 
            };
            
            // Get stored message point
            let msg_point_array = InternalFunctions::get_msg_point_span(@self);
            
            // Verify the signature
            let is_valid = verifier.verify_signature_for_key_hash(
                key_hash,
                s1_coeffs,
                msg_point_array.span()
            );
            assert(is_valid, 'Invalid signature');
            
            // Calculate vested and claimable amounts
            let current_time = get_block_timestamp();
            let vested = InternalFunctions::calculate_vested_at_time(@self, current_time);
            let claimed = self.claimed_amount.read();
            
            // Calculate claimable (what's vested but not yet claimed)
            assert(vested >= claimed, 'Claimed exceeds vested');
            let claimable = vested - claimed;
            assert(claimable > 0, 'No claimable amount');
            
            // Update claimed amount (effects before interaction)
            self.claimed_amount.write(claimed + claimable);
            
            // Transfer tokens to caller (provider)
            let caller = get_caller_address();
            let strk = IERC20Dispatcher { contract_address: self.strk_token.read() };
            
            // Validate and transfer
            assert(
                InternalFunctions::validate_balance_for_operation(@self, claimable),
                'Insufficient balance for claim'
            );
            InternalFunctions::safe_transfer(@self, strk, caller, claimable);
            
            // Emit claim event
            self.emit(Event::EscrowClaimed(
                EscrowClaimed {
                    provider: caller,
                    amount: claimable,
                    total_claimed: claimed + claimable
                }
            ));
            
            true
        }

        /// Raise a dispute (callable by client or provider)
        fn raise_dispute(ref self: ContractState, reason_hash: felt252) -> bool {
            // Check if deposit has been made
            assert(self.is_deposited.read(), 'Not deposited');
            
            // Check status is Active
            let status = self.status.read();
            assert(status == EscrowStatus::Active, 'Must be Active to dispute');
            
            // Verify caller is either client or provider
            let caller = get_caller_address();
            let client = self.client.read();
            let provider = self.provider.read();
            assert(
                caller == client || caller == provider,
                'Only client/provider allowed'
            );
            
            // Update status to Disputed
            self.status.write(EscrowStatus::Disputed);
            self.dispute_reason_hash.write(reason_hash);
            
            // Emit dispute event
            self.emit(Event::DisputeRaised(
                DisputeRaised {
                    raiser: caller,
                    reason_hash
                }
            ));
            
            true
        }

        /// Resolve a dispute (callable by arbiter or resolver)
        fn resolve_dispute(ref self: ContractState, resolution: DisputeResolution) -> bool {
            // Check caller is arbiter or resolver
            InternalFunctions::assert_dispute_authority(@self);
            
            // Check status is Disputed
            let status = self.status.read();
            assert(status == EscrowStatus::Disputed, 'Must be Disputed to resolve');
            
            let caller = get_caller_address();
            let client = self.client.read();
            let provider = self.provider.read();
            let strk = IERC20Dispatcher { contract_address: self.strk_token.read() };
            
            // Calculate remaining balance
            let total_amount = self.total_amount.read();
            let claimed_amount = self.claimed_amount.read();
            let remaining = total_amount - claimed_amount;
            
            // Handle resolution based on type
            match resolution {
                DisputeResolution::Resume => {
                    // Return to Active status
                    self.status.write(EscrowStatus::Active);
                    
                    self.emit(Event::DisputeResolved(
                        DisputeResolved {
                            resolver: caller,
                            client_amount: 0,
                            provider_amount: 0
                        }
                    ));
                },
                DisputeResolution::RefundRemaining => {
                    // Send all remaining to client
                    if remaining > 0 {
                        assert(
                            InternalFunctions::validate_balance_for_operation(@self, remaining),
                            'Insufficient balance for refund'
                        );
                        InternalFunctions::safe_transfer(@self, strk, client, remaining);
                    }
                    
                    self.status.write(EscrowStatus::Resolved);
                    
                    self.emit(Event::DisputeResolved(
                        DisputeResolved {
                            resolver: caller,
                            client_amount: remaining,
                            provider_amount: 0
                        }
                    ));
                },
                DisputeResolution::ReleaseRemaining => {
                    // Send all remaining to provider
                    if remaining > 0 {
                        assert(
                            InternalFunctions::validate_balance_for_operation(@self, remaining),
                            'Insufficient balance release'
                        );
                        InternalFunctions::safe_transfer(@self, strk, provider, remaining);
                    }
                    
                    self.status.write(EscrowStatus::Resolved);
                    
                    self.emit(Event::DisputeResolved(
                        DisputeResolved {
                            resolver: caller,
                            client_amount: 0,
                            provider_amount: remaining
                        }
                    ));
                },
                DisputeResolution::SplitRemaining(bps) => {
                    // Validate basis points (0-10000)
                    assert(bps <= 10000, 'Invalid basis points');
                    
                    // Calculate split amounts
                    let provider_amount = (remaining * bps.into()) / BASIS_POINTS_BASE;
                    let client_amount = remaining - provider_amount;
                    
                    // Transfer to provider
                    if provider_amount > 0 {
                        assert(
                            InternalFunctions::validate_balance_for_operation(@self, provider_amount),
                            'Insufficient balance for split'
                        );
                        InternalFunctions::safe_transfer(@self, strk, provider, provider_amount);
                    }
                    
                    // Transfer to client
                    if client_amount > 0 {
                        assert(
                            InternalFunctions::validate_balance_for_operation(@self, client_amount),
                            'Insufficient balance for split'
                        );
                        InternalFunctions::safe_transfer(@self, strk, client, client_amount);
                    }
                    
                    self.status.write(EscrowStatus::Resolved);
                    
                    self.emit(Event::DisputeResolved(
                        DisputeResolved {
                            resolver: caller,
                            client_amount,
                            provider_amount
                        }
                    ));
                }
            }
            
            true
        }

        /// Calculate vested amount at current time
        fn vested_now(self: @ContractState) -> u256 {
            if !self.is_deposited.read() {
                return 0;
            }
            
            let current_time = get_block_timestamp();
            InternalFunctions::calculate_vested_at_time(self, current_time)
        }

        /// Calculate claimable amount at current time
        fn claimable_now(self: @ContractState) -> u256 {
            if !self.is_deposited.read() {
                return 0;
            }
            
            let vested = self.vested_now();
            let claimed = self.claimed_amount.read();
            
            if vested > claimed {
                vested - claimed
            } else {
                0
            }
        }

        /// Get client's token allowance for this contract
        fn get_client_allowance(self: @ContractState) -> u256 {
            let client = self.client.read();
            let this_contract = get_contract_address();
            let strk_addr = self.strk_token.read();
            let strk = IERC20Dispatcher { contract_address: strk_addr };
            
            strk.allowance(client, this_contract)
        }

        /// Set message points for signature verification (client only, once)
        fn set_message_points(ref self: ContractState, msg_point_span: Span<u16>) -> bool {
            // Only client can set message points
            InternalFunctions::assert_only_client(@self);
            
            // Ensure message points haven't been set before
            assert(self.msg_point_len.read() == 0, 'Message already set');
            
            // Validate message point span
            assert(msg_point_span.len() > 0, 'Message point must not be empty');
            
            // Store the message point span
            let msg_point_len: u32 = msg_point_span.len().try_into().unwrap();
            self.msg_point_len.write(msg_point_len);
            
            let mut i: u32 = 0;
            loop {
                if i >= msg_point_len {
                    break;
                }
                let point = *msg_point_span.at(i.try_into().unwrap());
                self.msg_points.write(i, point);
                i += 1;
            };
            
            true
        }
    }
}
