#[starknet::contract]
mod ESCToken {
    use starknet::ContractAddress;
    use openzeppelin::token::erc20::erc20::{ERC20Component, ERC20HooksEmptyImpl};
    use core::byte_array::ByteArray;

    // Define a default config for decimals
    struct DefaultConfig {
        decimals: u8,
    }

    impl DefaultConfigImpl of ERC20Component::ImmutableConfig {
        const DECIMALS: u8 = 18;
    }

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);

    #[abi(embed_v0)]
    impl ERC20Impl = ERC20Component::ERC20Impl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;
    impl ERC20HooksImpl = ERC20HooksEmptyImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc20: ERC20Component::Storage
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        initial_supply: u256,
        recipient: ContractAddress
    ) {
        let name: ByteArray = "Escrow Token";
        let symbol: ByteArray = "ESC";
        self.erc20.initializer(name, symbol);
        ERC20InternalImpl::mint(ref self.erc20, recipient, initial_supply);
    }
} 