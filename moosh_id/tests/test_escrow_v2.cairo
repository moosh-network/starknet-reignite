use core::traits::Into;
use core::option::OptionTrait;
use core::result::ResultTrait;
use core::array::ArrayTrait;
use core::poseidon::poseidon_hash_span;
use starknet::ContractAddress;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    declare, 
    ContractClassTrait, 
    DeclareResultTrait,
    cheat_caller_address,
    start_cheat_block_timestamp_global,
    CheatSpan
};
use super::test_utils::{deploy_registry, pk_u16_span_to_felt252_array_for_hash};
use moosh_id::escrow_v2::EscrowV2::{
    IEscrowV2Dispatcher,
    IEscrowV2DispatcherTrait,
    EscrowStatus,
    DisputeResolution
};
use moosh_id::keyregistry::FalconPublicKeyRegistry::{
    IFalconPublicKeyRegistryDispatcherTrait
};
use moosh_id::addressverifier::FalconSignatureVerifier::{
    IFalconSignatureVerifierDispatcher,
};
use super::inputs::falcon_test_vectors_n1024::{PK_N1024, S1_N1024, MSG_POINT_N1024};

// Mock constants for testing
const MOCK_TOTAL_AMOUNT: u256 = 1000000000000000000; // 1e18 (1 full token)
const MOCK_DURATION: u64 = 1000; // 1000 seconds
const INITIAL_BALANCE: u256 = 1000000000000000000000; // 1000e18

fn to_u256(amount: u128) -> u256 {
    u256 { low: amount, high: 0 }
}

// Helper function to deploy the verifier
fn deploy_verifier(key_registry_addr: ContractAddress) -> IFalconSignatureVerifierDispatcher {
    let contract = declare("FalconSignatureVerifier").unwrap().contract_class();
    let constructor_args = array![key_registry_addr.into()];
    let (contract_address, _) = contract.deploy(@constructor_args).unwrap();
    IFalconSignatureVerifierDispatcher { contract_address }
}

// Helper function to deploy the escrow v2 contract
fn deploy_escrow_v2(
    strk_token_dispatcher: IERC20Dispatcher,
    arbiter: ContractAddress,
    resolver: ContractAddress
) -> IEscrowV2Dispatcher {
    let key_registry = deploy_registry();
    let pk_span = PK_N1024.span();
    key_registry.register_public_key(pk_span);
    let pk_felts = pk_u16_span_to_felt252_array_for_hash(pk_span);
    let key_hash = poseidon_hash_span(pk_felts.span());
    let verifier = deploy_verifier(key_registry.contract_address);
    
    let strk_addr_from_dispatcher = strk_token_dispatcher.contract_address;
    let client_address: ContractAddress = 0x123.try_into().unwrap();
    let provider_address: ContractAddress = 0x456.try_into().unwrap();
    
    let constructor_args = array![
        key_hash.into(),
        MOCK_TOTAL_AMOUNT.low.into(),
        MOCK_TOTAL_AMOUNT.high.into(),
        MOCK_DURATION.into(),
        verifier.contract_address.into(),
        key_registry.contract_address.into(),
        strk_addr_from_dispatcher.into(),
        client_address.into(),
        provider_address.into(),
        arbiter.into(),
        resolver.into()
    ];
    
    let contract = declare("EscrowV2").unwrap().contract_class();
    let (contract_address, _) = contract.deploy(@constructor_args).unwrap();
    IEscrowV2Dispatcher { contract_address }
}

// Helper function to deploy an ERC20 token for testing
fn deploy_erc20_token() -> IERC20Dispatcher {
    let contract = declare("ESCToken").unwrap().contract_class();
    let initial_supply: u256 = INITIAL_BALANCE;
    let recipient: ContractAddress = 0x123.try_into().unwrap();
    let constructor_args = array![
        initial_supply.low.into(),
        initial_supply.high.into(),
        recipient.into()
    ];
    let (contract_address, _) = contract.deploy(@constructor_args).unwrap();
    IERC20Dispatcher { contract_address }
}

fn setup_test_environment() -> (ContractAddress, IERC20Dispatcher, ContractAddress, ContractAddress) {
    let client_address: ContractAddress = 0x123.try_into().unwrap();
    let arbiter_address: ContractAddress = 0x789.try_into().unwrap();
    
    // Deploy a real ERC20 token with initial supply to client
    let strk_dispatcher = deploy_erc20_token();
    
    (client_address, strk_dispatcher, arbiter_address, arbiter_address)
}

fn setup_escrow_with_deposit() -> (IEscrowV2Dispatcher, IERC20Dispatcher, ContractAddress, u64) {
    let (client_address, token, arbiter, _) = setup_test_environment();
    let escrow = deploy_escrow_v2(token, arbiter, 0.try_into().unwrap());
    
    // Client sets message points
    cheat_caller_address(escrow.contract_address, client_address, CheatSpan::TargetCalls(1));
    let msg_point = MSG_POINT_N1024.span();
    escrow.set_message_points(msg_point);
    
    // Client approves tokens for escrow
    cheat_caller_address(token.contract_address, client_address, CheatSpan::TargetCalls(1));
    let approve_success = token.approve(escrow.contract_address, MOCK_TOTAL_AMOUNT);
    assert(approve_success, 'Approval failed');
    
    // Set initial timestamp
    let start_time: u64 = 1000000;
    start_cheat_block_timestamp_global(start_time);
    
    // Client deposits
    cheat_caller_address(escrow.contract_address, client_address, CheatSpan::TargetCalls(1));
    let success_deposit = escrow.deposit();
    assert(success_deposit, 'Deposit failed');
    
    (escrow, token, client_address, start_time)
}

fn assert_token_balance(token: IERC20Dispatcher, account: ContractAddress, expected_balance: u256) {
    let balance = token.balance_of(account);
    assert(balance == expected_balance, 'Incorrect token balance');
}

// ============================================================================
// Deployment and Basic Tests
// ============================================================================

#[test]
fn test_deploy_escrow_v2() {
    let (_client_address, strk_token_dispatcher, arbiter, _) = setup_test_environment();
    let escrow = deploy_escrow_v2(strk_token_dispatcher, arbiter, 0.try_into().unwrap());
    
    let details = escrow.get_escrow_details();
    assert(!details.is_deposited, 'Should start undeposited');
    assert(details.status == EscrowStatus::Active, 'Should start Active');
    assert(details.claimed_amount == 0, 'Should start unclaimed');
    assert(details.total_amount == MOCK_TOTAL_AMOUNT, 'Wrong total amount');
    assert(details.duration == MOCK_DURATION, 'Wrong duration');
}

// ============================================================================
// Deposit Tests
// ============================================================================

#[test]
fn test_successful_deposit() {
    let (escrow, token, _client_address, start_time) = setup_escrow_with_deposit();
    
    let details = escrow.get_escrow_details();
    assert(details.is_deposited, 'Should be deposited');
    assert(details.start_time == start_time, 'Wrong start time');
    assert(details.end_time == start_time + MOCK_DURATION, 'Wrong end time');
    
    // Check token balance transferred
    let escrow_balance = token.balance_of(escrow.contract_address);
    assert(escrow_balance == MOCK_TOTAL_AMOUNT, 'Wrong escrow balance');
}

#[test]
#[should_panic(expected: ('Already deposited',))]
fn test_prevent_double_deposit() {
    let (escrow, _, client_address, _) = setup_escrow_with_deposit();
    cheat_caller_address(escrow.contract_address, client_address, CheatSpan::TargetCalls(1));
    escrow.deposit();
}

// ============================================================================
// Vesting Calculation Tests
// ============================================================================

#[test]
fn test_vesting_before_start() {
    let (escrow, _, _, start_time) = setup_escrow_with_deposit();
    
    // Set time before start
    start_cheat_block_timestamp_global(start_time - 100);
    
    let vested = escrow.vested_now();
    assert(vested == 0, 'Should be 0 before start');
    
    let claimable = escrow.claimable_now();
    assert(claimable == 0, 'Should be 0 claimable');
}

#[test]
fn test_immediate_vesting() {
    let (escrow, _, _, start_time) = setup_escrow_with_deposit();
    
    // At start time, 20% should be immediately vested
    start_cheat_block_timestamp_global(start_time);
    
    let vested = escrow.vested_now();
    let expected = (MOCK_TOTAL_AMOUNT * 20) / 100;
    assert(vested == expected, 'Wrong immediate vesting');
}

#[test]
fn test_vesting_before_cliff() {
    let (escrow, _, _, start_time) = setup_escrow_with_deposit();
    
    // Before cliff (20% of duration), only immediate 20% is vested
    let cliff_time = start_time + (MOCK_DURATION * 20) / 100;
    start_cheat_block_timestamp_global(cliff_time - 1);
    
    let vested = escrow.vested_now();
    let expected = (MOCK_TOTAL_AMOUNT * 20) / 100;
    assert(vested == expected, 'Wrong vesting before cliff');
}

#[test]
fn test_vesting_at_cliff() {
    let (escrow, _, _, start_time) = setup_escrow_with_deposit();
    
    // At cliff time (20% of duration), still only immediate 20% is vested
    let cliff_time = start_time + (MOCK_DURATION * 20) / 100;
    start_cheat_block_timestamp_global(cliff_time);
    
    let vested = escrow.vested_now();
    let expected = (MOCK_TOTAL_AMOUNT * 20) / 100;
    assert(vested == expected, 'Wrong vesting at cliff');
}

#[test]
fn test_vesting_midway() {
    let (escrow, _, _, start_time) = setup_escrow_with_deposit();
    
    // Halfway between start and end
    let mid_time = start_time + MOCK_DURATION / 2;
    start_cheat_block_timestamp_global(mid_time);
    
    let vested = escrow.vested_now();
    
    // Should be more than 20% but less than 100%
    let immediate = (MOCK_TOTAL_AMOUNT * 20) / 100;
    assert(vested > immediate, 'Should vest more than 20%');
    assert(vested < MOCK_TOTAL_AMOUNT, 'Should vest less than 100%');
}

#[test]
fn test_vesting_at_end() {
    let (escrow, _, _, start_time) = setup_escrow_with_deposit();
    
    // At end time, 100% should be vested
    let end_time = start_time + MOCK_DURATION;
    start_cheat_block_timestamp_global(end_time);
    
    let vested = escrow.vested_now();
    assert(vested == MOCK_TOTAL_AMOUNT, 'Should be fully vested');
}

#[test]
fn test_vesting_after_end() {
    let (escrow, _, _, start_time) = setup_escrow_with_deposit();
    
    // After end time, still 100% vested
    let after_end = start_time + MOCK_DURATION + 10000;
    start_cheat_block_timestamp_global(after_end);
    
    let vested = escrow.vested_now();
    assert(vested == MOCK_TOTAL_AMOUNT, 'Should stay fully vested');
}

// ============================================================================
// Claim Tests
// ============================================================================

#[test]
fn test_claim_immediate_vesting() {
    let (escrow, token, _client_address, start_time) = setup_escrow_with_deposit();
    
    // Claim immediately at start (20% should be available)
    start_cheat_block_timestamp_global(start_time);
    
    let provider_address: ContractAddress = 0x456.try_into().unwrap();
    cheat_caller_address(escrow.contract_address, provider_address, CheatSpan::TargetCalls(1));
    
    let s1_coeffs = S1_N1024.span();
    let success = escrow.claim(s1_coeffs);
    assert(success, 'Claim failed');
    
    let expected_claim = (MOCK_TOTAL_AMOUNT * 20) / 100;
    let provider_balance = token.balance_of(provider_address);
    assert(provider_balance == expected_claim, 'Wrong claimed amount');
    
    let details = escrow.get_escrow_details();
    assert(details.claimed_amount == expected_claim, 'Wrong claimed tracking');
}

#[test]
fn test_multiple_claims() {
    let (escrow, token, _, start_time) = setup_escrow_with_deposit();
    
    let provider_address: ContractAddress = 0x456.try_into().unwrap();
    
    let s1_coeffs = S1_N1024.span();
    
    // First claim at start (20%)
    start_cheat_block_timestamp_global(start_time);
    cheat_caller_address(escrow.contract_address, provider_address, CheatSpan::TargetCalls(1));
    let success = escrow.claim(s1_coeffs);
    assert(success, 'First claim failed');
    
    let first_claim = (MOCK_TOTAL_AMOUNT * 20) / 100;
    let balance_after_first = token.balance_of(provider_address);
    assert(balance_after_first == first_claim, 'Wrong first claim');
    
    // Second claim at end (remaining 80%)
    let end_time = start_time + MOCK_DURATION;
    start_cheat_block_timestamp_global(end_time);
    cheat_caller_address(escrow.contract_address, provider_address, CheatSpan::TargetCalls(1));
    let success2 = escrow.claim(s1_coeffs);
    assert(success2, 'Second claim failed');
    
    let balance_after_second = token.balance_of(provider_address);
    assert(balance_after_second == MOCK_TOTAL_AMOUNT, 'Wrong total claimed');
}

#[test]
#[should_panic(expected: ('No claimable amount',))]
fn test_claim_with_zero_claimable() {
    let (escrow, _, _, start_time) = setup_escrow_with_deposit();
    
    let provider_address: ContractAddress = 0x456.try_into().unwrap();
    cheat_caller_address(escrow.contract_address, provider_address, CheatSpan::TargetCalls(1));
    
    let s1_coeffs = S1_N1024.span();
    
    // Claim at start
    start_cheat_block_timestamp_global(start_time);
    escrow.claim(s1_coeffs);
    
    // Try to claim again immediately (no new vesting)
    escrow.claim(s1_coeffs);
}

#[test]
#[should_panic(expected: ('Not deposited',))]
fn test_claim_before_deposit() {
    let (_client_address, token, arbiter, _) = setup_test_environment();
    let escrow = deploy_escrow_v2(token, arbiter, 0.try_into().unwrap());
    
    let s1_coeffs = S1_N1024.span();
    escrow.claim(s1_coeffs);
}

// ============================================================================
// Dispute Tests
// ============================================================================

#[test]
fn test_client_raises_dispute() {
    let (escrow, _, client_address, _) = setup_escrow_with_deposit();
    
    cheat_caller_address(escrow.contract_address, client_address, CheatSpan::TargetCalls(1));
    
    let reason_hash: felt252 = 'bad_service';
    let success = escrow.raise_dispute(reason_hash);
    assert(success, 'Dispute failed');
    
    let details = escrow.get_escrow_details();
    assert(details.status == EscrowStatus::Disputed, 'Should be Disputed');
}

#[test]
fn test_provider_raises_dispute() {
    let (escrow, _, _, _) = setup_escrow_with_deposit();
    
    let provider_address: ContractAddress = 0x456.try_into().unwrap();
    cheat_caller_address(escrow.contract_address, provider_address, CheatSpan::TargetCalls(1));
    
    let reason_hash: felt252 = 'non_payment';
    let success = escrow.raise_dispute(reason_hash);
    assert(success, 'Dispute failed');
    
    let details = escrow.get_escrow_details();
    assert(details.status == EscrowStatus::Disputed, 'Should be Disputed');
}

#[test]
#[should_panic(expected: ('Only client/provider allowed',))]
fn test_unauthorized_dispute() {
    let (escrow, _, _, _) = setup_escrow_with_deposit();
    
    let random_address: ContractAddress = 0x999.try_into().unwrap();
    cheat_caller_address(escrow.contract_address, random_address, CheatSpan::TargetCalls(1));
    
    escrow.raise_dispute('hacker');
}

#[test]
#[should_panic(expected: ('Must be Active to claim',))]
fn test_claim_during_dispute() {
    let (escrow, _, client_address, start_time) = setup_escrow_with_deposit();
    
    // Raise dispute
    cheat_caller_address(escrow.contract_address, client_address, CheatSpan::TargetCalls(1));
    escrow.raise_dispute('issue');
    
    // Try to claim
    let provider_address: ContractAddress = 0x456.try_into().unwrap();
    cheat_caller_address(escrow.contract_address, provider_address, CheatSpan::TargetCalls(1));
    
    start_cheat_block_timestamp_global(start_time + MOCK_DURATION);
    let s1_coeffs = S1_N1024.span();
    escrow.claim(s1_coeffs);
}

// ============================================================================
// Dispute Resolution Tests
// ============================================================================

#[test]
fn test_resolve_dispute_resume() {
    let (escrow, _, client_address, start_time) = setup_escrow_with_deposit();
    
    // Raise dispute
    cheat_caller_address(escrow.contract_address, client_address, CheatSpan::TargetCalls(1));
    escrow.raise_dispute('issue');
    
    // Resolve by resuming
    let arbiter_address: ContractAddress = 0x789.try_into().unwrap();
    cheat_caller_address(escrow.contract_address, arbiter_address, CheatSpan::TargetCalls(1));
    
    let success = escrow.resolve_dispute(DisputeResolution::Resume);
    assert(success, 'Resolve failed');
    
    let details = escrow.get_escrow_details();
    assert(details.status == EscrowStatus::Active, 'Should be Active again');
    
    // Should be able to claim now
    let provider_address: ContractAddress = 0x456.try_into().unwrap();
    cheat_caller_address(escrow.contract_address, provider_address, CheatSpan::TargetCalls(1));
    start_cheat_block_timestamp_global(start_time);
    
    let s1_coeffs = S1_N1024.span();
    let success2 = escrow.claim(s1_coeffs);
    assert(success2, 'Claim after resume failed');
}

#[test]
fn test_resolve_dispute_refund_remaining() {
    let (escrow, token, client_address, _) = setup_escrow_with_deposit();
    
    // Raise dispute
    cheat_caller_address(escrow.contract_address, client_address, CheatSpan::TargetCalls(1));
    escrow.raise_dispute('issue');
    
    // Resolve by refunding client
    let arbiter_address: ContractAddress = 0x789.try_into().unwrap();
    cheat_caller_address(escrow.contract_address, arbiter_address, CheatSpan::TargetCalls(1));
    
    let success = escrow.resolve_dispute(DisputeResolution::RefundRemaining);
    assert(success, 'Resolve failed');
    
    let details = escrow.get_escrow_details();
    assert(details.status == EscrowStatus::Resolved, 'Should be Resolved');
    
    // Client should have all funds back
    let client_balance = token.balance_of(client_address);
    assert(client_balance == INITIAL_BALANCE, 'Wrong client refund');
}

#[test]
fn test_resolve_dispute_release_remaining() {
    let (escrow, token, client_address, _) = setup_escrow_with_deposit();
    
    // Raise dispute
    cheat_caller_address(escrow.contract_address, client_address, CheatSpan::TargetCalls(1));
    escrow.raise_dispute('issue');
    
    // Resolve by releasing to provider
    let arbiter_address: ContractAddress = 0x789.try_into().unwrap();
    cheat_caller_address(escrow.contract_address, arbiter_address, CheatSpan::TargetCalls(1));
    
    let success = escrow.resolve_dispute(DisputeResolution::ReleaseRemaining);
    assert(success, 'Resolve failed');
    
    let details = escrow.get_escrow_details();
    assert(details.status == EscrowStatus::Resolved, 'Should be Resolved');
    
    // Provider should have all funds
    let provider_address: ContractAddress = 0x456.try_into().unwrap();
    let provider_balance = token.balance_of(provider_address);
    assert(provider_balance == MOCK_TOTAL_AMOUNT, 'Wrong provider release');
}

#[test]
fn test_resolve_dispute_split_50_50() {
    let (escrow, token, client_address, _) = setup_escrow_with_deposit();
    
    // Raise dispute
    cheat_caller_address(escrow.contract_address, client_address, CheatSpan::TargetCalls(1));
    escrow.raise_dispute('issue');
    
    // Resolve with 50/50 split (5000 basis points = 50%)
    let arbiter_address: ContractAddress = 0x789.try_into().unwrap();
    cheat_caller_address(escrow.contract_address, arbiter_address, CheatSpan::TargetCalls(1));
    
    let success = escrow.resolve_dispute(DisputeResolution::SplitRemaining(5000));
    assert(success, 'Resolve failed');
    
    let details = escrow.get_escrow_details();
    assert(details.status == EscrowStatus::Resolved, 'Should be Resolved');
    
    // Check split
    let provider_address: ContractAddress = 0x456.try_into().unwrap();
    let provider_balance = token.balance_of(provider_address);
    let client_balance = token.balance_of(client_address);
    
    let expected_split = MOCK_TOTAL_AMOUNT / 2;
    let expected_client = INITIAL_BALANCE - expected_split;
    
    assert(provider_balance == expected_split, 'Wrong provider split');
    assert(client_balance == expected_client, 'Wrong client split');
}

#[test]
fn test_resolve_dispute_with_partial_claim() {
    let (escrow, token, client_address, start_time) = setup_escrow_with_deposit();
    
    // Provider claims immediate 20%
    let provider_address: ContractAddress = 0x456.try_into().unwrap();
    cheat_caller_address(escrow.contract_address, provider_address, CheatSpan::TargetCalls(1));
    start_cheat_block_timestamp_global(start_time);
    
    let s1_coeffs = S1_N1024.span();
    escrow.claim(s1_coeffs);
    
    let claimed_amount = (MOCK_TOTAL_AMOUNT * 20) / 100;
    
    // Client raises dispute
    cheat_caller_address(escrow.contract_address, client_address, CheatSpan::TargetCalls(1));
    escrow.raise_dispute('issue');
    
    // Arbiter refunds remaining to client
    let arbiter_address: ContractAddress = 0x789.try_into().unwrap();
    cheat_caller_address(escrow.contract_address, arbiter_address, CheatSpan::TargetCalls(1));
    
    let success = escrow.resolve_dispute(DisputeResolution::RefundRemaining);
    assert(success, 'Resolve failed');
    
    // Check balances
    let _remaining = MOCK_TOTAL_AMOUNT - claimed_amount;
    let expected_client = INITIAL_BALANCE - claimed_amount;
    
    let client_balance = token.balance_of(client_address);
    let provider_balance = token.balance_of(provider_address);
    
    assert(client_balance == expected_client, 'Wrong client balance');
    assert(provider_balance == claimed_amount, 'Wrong provider balance');
}

#[test]
#[should_panic(expected: ('Only arbiter/resolver allowed',))]
fn test_unauthorized_resolution() {
    let (escrow, _, client_address, _) = setup_escrow_with_deposit();
    
    // Raise dispute
    cheat_caller_address(escrow.contract_address, client_address, CheatSpan::TargetCalls(1));
    escrow.raise_dispute('issue');
    
    // Random address tries to resolve
    let random_address: ContractAddress = 0x999.try_into().unwrap();
    cheat_caller_address(escrow.contract_address, random_address, CheatSpan::TargetCalls(1));
    
    escrow.resolve_dispute(DisputeResolution::Resume);
}

#[test]
#[should_panic(expected: ('Must be Disputed to resolve',))]
fn test_resolve_without_dispute() {
    let (escrow, _, _, _) = setup_escrow_with_deposit();
    
    let arbiter_address: ContractAddress = 0x789.try_into().unwrap();
    cheat_caller_address(escrow.contract_address, arbiter_address, CheatSpan::TargetCalls(1));
    
    escrow.resolve_dispute(DisputeResolution::Resume);
}

// ============================================================================
// Edge Case Tests
// ============================================================================

#[test]
fn test_claimable_now_view_function() {
    let (escrow, _, _, start_time) = setup_escrow_with_deposit();
    
    // At start, 20% is claimable
    start_cheat_block_timestamp_global(start_time);
    let claimable = escrow.claimable_now();
    let expected = (MOCK_TOTAL_AMOUNT * 20) / 100;
    assert(claimable == expected, 'Wrong claimable at start');
    
    // At end, 100% is claimable
    let end_time = start_time + MOCK_DURATION;
    start_cheat_block_timestamp_global(end_time);
    let claimable_end = escrow.claimable_now();
    assert(claimable_end == MOCK_TOTAL_AMOUNT, 'Wrong claimable at end');
}

#[test]
fn test_get_client_allowance() {
    let (client_address, token, arbiter, _) = setup_test_environment();
    let escrow = deploy_escrow_v2(token, arbiter, 0.try_into().unwrap());
    
    // Initially no allowance
    let allowance = escrow.get_client_allowance();
    assert(allowance == 0, 'Should start with 0 allowance');
    
    // Approve tokens - need to cheat for the token contract
    cheat_caller_address(token.contract_address, client_address, CheatSpan::TargetCalls(1));
    let approve_success = token.approve(escrow.contract_address, MOCK_TOTAL_AMOUNT);
    assert(approve_success, 'Approve failed');
    
    let allowance_after = escrow.get_client_allowance();
    assert(allowance_after == MOCK_TOTAL_AMOUNT, 'Wrong allowance after approve');
}

#[test]
fn test_full_lifecycle() {
    let (escrow, token, _client_address, start_time) = setup_escrow_with_deposit();
    
    let provider_address: ContractAddress = 0x456.try_into().unwrap();
    let s1_coeffs = S1_N1024.span();
    
    // Claim at start (20%)
    start_cheat_block_timestamp_global(start_time);
    cheat_caller_address(escrow.contract_address, provider_address, CheatSpan::TargetCalls(1));
    escrow.claim(s1_coeffs);
    
    let _first_claim = (MOCK_TOTAL_AMOUNT * 20) / 100;
    
    // Claim at 50% duration
    let mid_time = start_time + MOCK_DURATION / 2;
    start_cheat_block_timestamp_global(mid_time);
    cheat_caller_address(escrow.contract_address, provider_address, CheatSpan::TargetCalls(1));
    escrow.claim(s1_coeffs);
    
    // Claim at end
    let end_time = start_time + MOCK_DURATION;
    start_cheat_block_timestamp_global(end_time);
    cheat_caller_address(escrow.contract_address, provider_address, CheatSpan::TargetCalls(1));
    escrow.claim(s1_coeffs);
    
    // All tokens should be with provider
    let provider_balance = token.balance_of(provider_address);
    assert(provider_balance == MOCK_TOTAL_AMOUNT, 'Wrong final balance');
    
    // Escrow should be empty
    let escrow_balance = token.balance_of(escrow.contract_address);
    assert(escrow_balance == 0, 'Escrow should be empty');
}
