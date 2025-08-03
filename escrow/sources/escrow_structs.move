/// Module: escrow
module escrow::structs;

    use std::string::String;
    use sui::balance::{Balance, withdraw_all, split, destroy_zero, value};
    use sui::sui::SUI;
    use escrow::constants::{
        status_active, 
        e_insufficient_balance, 
        e_wallet_inactive
        };   

// ======== Wallet (Sui as source chain) ========
    // Design rationale: wallet is a pre-funded wallet that makers create
    // Resolvers can pull funds from this wallet to create escrows
    // This enables partial fills - multiple resolvers can create escrows from one wallet
    // The wallet itself is NOT the escrow - it's just a funding source
    // The wallet object is used as the order state for the maker when the order is created on SUI
    public struct Wallet<phantom T> has key, store {
        id: UID,
        order_hash: vector<u8>,
        salt: u256,
        maker: address,
        maker_asset: String,
        taker_asset: String,
        making_amount: u64, //used for dutch auction. Also a reference for the initial amount
        taking_amount: u64, // minimum amount the taker will provide : used for dutch auction
        duration: u64, // duration in seconds for the order : used for dutch auction
        hashlock: vector<u8>, // keccak256(secret) for the full fill and merkle root for partial fills. This is not needed for computation but as a public reference
        timelocks: Timelocks, // timelock configuration
        src_safety_deposit_amount: u64, // safety deposit amount in SUI (paid by resolver)
        dst_safety_deposit_amount: u64, // safety deposit amount in ETH (paid by resolver)
        allow_partial_fills: bool, // whether this wallet allows partial fills
        parts_amount: u8, // amount of parts an order is split into (n+1 secrets for partial fill)
        last_used_index: u8, // indices of used parts
        balance: Balance<T>,
        created_at: u64,
        is_active: bool
    }


// ============ Core Structs ============

    /// Core immutable parameters for escrow operations
    public struct EscrowImmutables has copy, drop, store {
        order_hash: vector<u8>,      // 32 bytes - unique identifier for the order
        hashlock: vector<u8>,        // 32 bytes - keccak256(secret) for the specific fill
        maker: address,              // Address that provides source tokens
        taker: address,              // Address that provides destination tokens
        token_type: String,          // Token type identifier (for generic token support). Using SUI
        amount: u64,                 // Amount of tokens to be swapped
        safety_deposit_amount: u64,  // Safety deposit amount in SUI (paid by resolver)
        timelocks: Timelocks,        // Timelock configuration
    }

    /// Timelocks configuration
    public struct Timelocks has copy, drop, store {
        src_withdrawal: u64,
        src_public_withdrawal: u64,
        src_cancellation: u64,
        src_public_cancellation: u64,
        dst_withdrawal: u64,
        dst_public_withdrawal: u64,
        dst_cancellation: u64,
    }

    /// Source chain escrow object - holds maker's tokens
    /// Must be a shared object for cross-party access
    public struct EscrowSrc<phantom T> has key, store {
        id: UID,
        immutables: EscrowImmutables,
        token_balance: Balance<T>,         // Maker's locked tokens (only SUI)
        safety_deposit: Balance<SUI>,        // Resolver's safety deposit
        created_at: u64,
        status: u8,                          // Current status (active/withdrawn/cancelled)
    }

    /// Destination chain escrow object - ensure SHARED for consensus
    /// holds taker tokens
    public struct EscrowDst<phantom T> has key, store {
        id: UID,
        immutables: EscrowImmutables,
        token_balance: Balance<T>,         // Taker's locked tokens (only SUI)
        safety_deposit: Balance<SUI>,        // Resolver's safety deposit
        created_at: u64,
        status: u8,                          // Current status (active/withdrawn/cancelled)
    }

    // ============ Getter Functions ============

    // Wallet getters
    public(package) fun wallet_id<T>(wallet: &Wallet<T>): &UID { &wallet.id }
    public(package) fun wallet_address<T>(wallet: &Wallet<T>): address { object::uid_to_address(&wallet.id) }
    public(package) fun wallet_order_hash<T>(wallet: &Wallet<T>): &vector<u8> { &wallet.order_hash }
    public(package) fun wallet_salt<T>(wallet: &Wallet<T>): u256 { wallet.salt }
    public(package) fun wallet_maker<T>(wallet: &Wallet<T>): address { wallet.maker }
    public(package) fun wallet_maker_asset<T>(wallet: &Wallet<T>): &String { &wallet.maker_asset }
    public(package) fun wallet_taker_asset<T>(wallet: &Wallet<T>): &String { &wallet.taker_asset }
    public(package) fun wallet_making_amount<T>(wallet: &Wallet<T>): u64 { wallet.making_amount }
    public(package) fun wallet_taking_amount<T>(wallet: &Wallet<T>): u64 { wallet.taking_amount }
    public(package) fun wallet_duration<T>(wallet: &Wallet<T>): u64 { wallet.duration }
    public(package) fun wallet_hashlock<T>(wallet: &Wallet<T>): &vector<u8> { &wallet.hashlock }
    public(package) fun wallet_timelocks<T>(wallet: &Wallet<T>): &Timelocks { &wallet.timelocks }
    public(package) fun wallet_src_safety_deposit<T>(wallet: &Wallet<T>): u64 { wallet.src_safety_deposit_amount }
    public(package) fun wallet_dst_safety_deposit<T>(wallet: &Wallet<T>): u64 { wallet.dst_safety_deposit_amount }
    public(package) fun wallet_allow_partial_fills<T>(wallet: &Wallet<T>): bool { wallet.allow_partial_fills }
    public(package) fun wallet_parts_amount<T>(wallet: &Wallet<T>): u8 { wallet.parts_amount }
    public(package) fun wallet_last_used_index<T>(wallet: &Wallet<T>): u8 { wallet.last_used_index }
    public(package) fun wallet_balance<T>(wallet: &Wallet<T>): u64 { value(&wallet.balance) }
    public(package) fun wallet_created_at<T>(wallet: &Wallet<T>): u64 { wallet.created_at }
    public(package) fun wallet_is_active<T>(wallet: &Wallet<T>): bool { wallet.is_active }

    // EscrowImmutables getters
    public(package) fun get_order_hash(immutables: &EscrowImmutables): &vector<u8> { &immutables.order_hash }
    public(package) fun get_hashlock(immutables: &EscrowImmutables): &vector<u8> { &immutables.hashlock }
    public(package) fun get_maker(immutables: &EscrowImmutables): address { immutables.maker }
    public(package) fun get_taker(immutables: &EscrowImmutables): address { immutables.taker }
    public(package) fun get_token_type(immutables: &EscrowImmutables): &String { &immutables.token_type }
    public(package) fun get_amount(immutables: &EscrowImmutables): u64 { immutables.amount }
    public(package) fun get_safety_deposit_amount(immutables: &EscrowImmutables): u64 { immutables.safety_deposit_amount }
    public(package) fun get_timelocks(immutables: &EscrowImmutables): &Timelocks { &immutables.timelocks }

    // Timelocks getters
    public(package) fun get_src_withdrawal_time(timelocks: &Timelocks): u64 { timelocks.src_withdrawal }
    public(package) fun get_src_public_withdrawal_time(timelocks: &Timelocks): u64 { timelocks.src_public_withdrawal }
    public(package) fun get_src_cancellation_time(timelocks: &Timelocks): u64 { timelocks.src_cancellation }
    public(package) fun get_src_public_cancellation_time(timelocks: &Timelocks): u64 { timelocks.src_public_cancellation }
    public(package) fun get_dst_withdrawal_time(timelocks: &Timelocks): u64 { timelocks.dst_withdrawal }
    public(package) fun get_dst_public_withdrawal_time(timelocks: &Timelocks): u64 { timelocks.dst_public_withdrawal }
    public(package) fun get_dst_cancellation_time(timelocks: &Timelocks): u64 { timelocks.dst_cancellation }

    // EscrowSrc getters
    public(package) fun get_src_id<T>(escrow: &EscrowSrc<T>): &UID { &escrow.id}
    public(package) fun get_src_address<T>(escrow: &EscrowSrc<T>): address { object::uid_to_address(&escrow.id) } //for logs
    public(package) fun get_src_immutables<T>(escrow: &EscrowSrc<T>): &EscrowImmutables { &escrow.immutables }
    public(package) fun get_src_token_balance<T>(escrow: &EscrowSrc<T>): u64 { value(&escrow.token_balance) }
    public(package) fun get_src_safety_deposit<T>(escrow: &EscrowSrc<T>): u64 { value(&escrow.safety_deposit) }
    public(package) fun get_src_created_at<T>(escrow: &EscrowSrc<T>): u64 { escrow.created_at }
    public(package) fun get_src_status<T>(escrow: &EscrowSrc<T>): u8 { escrow.status }

    // EscrowDst getters
    public(package) fun get_dst_id<T>(escrow: &EscrowSrc<T>): &UID { &escrow.id}
    public(package) fun get_dst_address<T>(escrow: &EscrowDst<T>): address { object::uid_to_address(&escrow.id) } //for logs
    public(package) fun get_dst_immutables<T>(escrow: &EscrowDst<T>): &EscrowImmutables { &escrow.immutables }
    public(package) fun get_dst_token_balance<T>(escrow: &EscrowDst<T>): u64 { value(&escrow.token_balance) }
    public(package) fun get_dst_safety_deposit<T>(escrow: &EscrowDst<T>): u64 { value(&escrow.safety_deposit) }
    public(package) fun get_dst_created_at<T>(escrow: &EscrowDst<T>): u64 { escrow.created_at }
    public(package) fun get_dst_status<T>(escrow: &EscrowDst<T>): u8 { escrow.status }

    // ============ Setter/Mutator Functions ============

    // Wallet mutators
    public(package) fun wallet_add_used_index<T>(wallet: &mut Wallet<T>, index: u8) {
        wallet.last_used_index = index;
    }

    public(package) fun wallet_set_active<T>(wallet: &mut Wallet<T>, is_active: bool) {
        wallet.is_active = is_active;
    }

    // Escrow status mutators
    public(package) fun set_src_status<T>(escrow: &mut EscrowSrc<T>, status: u8) {
        escrow.status = status;
    }

    public(package) fun set_dst_status<T>(escrow: &mut EscrowDst<T>, status: u8) {
        escrow.status = status;
    }


    // ============ Balance Operations for escrows ============

    // These functions extract both balances in a single operation to avoid 
    // multiple mutable borrows

    /// Extract both token balance and safety deposit from source escrow
    public(package) fun extract_all_from_src<T>(escrow: &mut EscrowSrc<T>): (Balance<T>, Balance<SUI>) {
        let tokens = withdraw_all(&mut escrow.token_balance);
        let safety_deposit = withdraw_all(&mut escrow.safety_deposit);
        (tokens, safety_deposit)
    }

    /// Extract both token balance and safety deposit from destination escrow  
    public(package) fun extract_all_from_dst<T>(escrow: &mut EscrowDst<T>): (Balance<T>, Balance<SUI>) {
        let tokens = withdraw_all(&mut escrow.token_balance);
        let safety_deposit = withdraw_all(&mut escrow.safety_deposit);
        (tokens, safety_deposit)
    }

    // ============ Constructor Functions for Keyed Structs ============

    /// Create a new Wallet. Entry Fn. Call using PTB
    public(package) fun create_wallet<T>(
        order_hash: vector<u8>,
        salt: u256,
        maker: address,
        maker_asset: String,
        taker_asset: String,
        making_amount: u64,
        taking_amount: u64,
        duration: u64,
        hashlock: vector<u8>,
        timelocks: Timelocks,
        src_safety_deposit_amount: u64,
        dst_safety_deposit_amount: u64,
        allow_partial_fills: bool,
        parts_amount: u8,
        initial_balance: Balance<T>,
        created_at: u64,
        ctx: &mut TxContext,
    ): Wallet<T> {
        Wallet {
            id: object::new(ctx),
            order_hash,
            salt,
            maker,
            maker_asset,
            taker_asset,
            making_amount,
            taking_amount,
            duration,
            hashlock,
            timelocks,
            src_safety_deposit_amount,
            dst_safety_deposit_amount,
            allow_partial_fills,
            parts_amount,
            last_used_index: 255,
            balance: initial_balance,
            created_at,
            is_active: true,
        }
    }


    /// Create a new EscrowSrc object
    public(package) fun create_escrow_src<T>(
        immutables: EscrowImmutables,
        token_balance: Balance<T>,
        safety_deposit: Balance<SUI>,
        created_at: u64,
        ctx: &mut TxContext,
    ): EscrowSrc<T> {
        EscrowSrc {
            id: object::new(ctx),
            immutables,
            token_balance,
            safety_deposit,
            created_at,
            status: status_active(),
        }
    }

    /// Create a new EscrowDst object
    public(package) fun create_escrow_dst<T>(
        immutables: EscrowImmutables,
        token_balance: Balance<T>,
        safety_deposit: Balance<SUI>,
        created_at: u64,
        ctx: &mut TxContext,
    ): EscrowDst<T> {
        EscrowDst {
            id: object::new(ctx),
            immutables,
            token_balance,
            safety_deposit,
            created_at,
            status: status_active(),
        }
    }

    // ============ Other Constructor Functions ============

    public(package) fun create_escrow_immutables(
        order_hash: vector<u8>,
        hashlock: vector<u8>,
        maker: address,
        taker: address,
        token_type: String,
        amount: u64,
        safety_deposit_amount: u64,
        timelocks: Timelocks,
    ): EscrowImmutables {
        EscrowImmutables {
            order_hash,
            hashlock,
            maker,
            taker,
            token_type,
            amount,
            safety_deposit_amount,
            timelocks,
        }
    }

    public(package) fun create_timelocks(
        src_withdrawal: u64,
        src_public_withdrawal: u64,
        src_cancellation: u64,
        src_public_cancellation: u64,
        dst_withdrawal: u64,
        dst_public_withdrawal: u64,
        dst_cancellation: u64,
    ): Timelocks {
        Timelocks {
            src_withdrawal,
            src_public_withdrawal,
            src_cancellation,
            src_public_cancellation,
            dst_withdrawal,
            dst_public_withdrawal,
            dst_cancellation,
        }
    }

    // Withdraws funds from wallet to create an escrow
    // Returns the balance for the wallet
    public(package) fun withdraw_from_wallet_for_escrow<T>(
    wallet: &mut Wallet<T>,
    escrow_amount: u64,
    ): Balance<T> {
        // 1. Wallet must still be usable
        assert!(wallet.is_active, e_wallet_inactive());

        // 2. Must hold enough tokens
        assert!(
            value(&wallet.balance) >= escrow_amount,
            e_insufficient_balance()
        );
        //    `balance::split` :: (&mut Balance<T>, u64) -> Balance<T>
        //    ‑ moves the requested amount into a *new* Balance<T> and shrinks the
        //      original in‑place.
        split(&mut wallet.balance, escrow_amount)
    }
    
    // Return unused funds to maker when wallet is closed
    public(package) fun destroy_wallet<T>(wallet: Wallet<T>, maker: address, ctx: &mut TxContext,) {
        let Wallet {
            id,
            order_hash: _,
            salt: _,
            maker: _,
            maker_asset: _,
            taker_asset: _,
            making_amount: _,
            taking_amount: _,
            duration: _,
            hashlock: _,
            timelocks: _,
            src_safety_deposit_amount: _,
            dst_safety_deposit_amount: _,
            allow_partial_fills: _,
            parts_amount: _,
            last_used_index: _,
            balance,
            created_at: _,
            is_active: _,
        } = wallet;

        if (value(&balance) > 0) {
            transfer::public_transfer(sui::coin::from_balance(balance, ctx), maker);
        } else {
            destroy_zero(balance);
        };
        
        // Delete the wallet object - caller gets storage rebate
        object::delete(id);
        
    }

    // ============ Object Cleanup Functions ============


    /// Destroy EscrowSrc after lifecycle is complete
    #[allow(lint(self_transfer))]
    public(package) fun destroy_src_escrow<T>(escrow: EscrowSrc<T>, maker: address, ctx: &mut TxContext,) {
        let EscrowSrc { 
            id, 
            immutables: _, 
            token_balance, 
            safety_deposit, 
            created_at:_,
            status: _
        } = escrow;

        let caller = tx_context::sender(ctx);
        
         if (value(&token_balance) > 0) {
            transfer::public_transfer(sui::coin::from_balance(token_balance, ctx), maker);
        } else {
            destroy_zero(token_balance);
        };
        
        if (value(&safety_deposit) > 0) {
            transfer::public_transfer(sui::coin::from_balance(safety_deposit, ctx), caller);
        } else {
            destroy_zero(safety_deposit);
        };
        object::delete(id);
    }

    /// Destroy EscrowDst after lifecycle is complete
    #[allow(lint(self_transfer))]
    public(package) fun destroy_dst_escrow<T>(escrow: EscrowDst<T>, taker: address, ctx: &mut TxContext,) {
        let EscrowDst { 
            id, 
            immutables: _, 
            token_balance, 
            safety_deposit,
            created_at:_, 
            status: _
        } = escrow;
        
        let caller = tx_context::sender(ctx);
        
         if (value(&token_balance) > 0) {
            transfer::public_transfer(sui::coin::from_balance(token_balance, ctx), taker);
        } else {
            destroy_zero(token_balance);
        };
        
        if (value(&safety_deposit) > 0) {
            transfer::public_transfer(sui::coin::from_balance(safety_deposit, ctx), caller);
        } else {
            destroy_zero(safety_deposit);
        };
        object::delete(id);
    }

    