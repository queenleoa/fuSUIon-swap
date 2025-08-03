/// Module: escrow
module escrow::escrow_create;

    use sui::sui::SUI;
    use sui::coin::{Self, Coin};
    use sui::clock::Clock;
    use std::string;
    use escrow::structs::{ Self, Wallet};
    use escrow::events;
    use escrow::utils;
    use escrow::constants::{
        e_invalid_amount,
        e_invalid_timelock,
        e_invalid_hashlock,
        e_invalid_order_hash,
        e_safety_deposit_too_low,
        e_auction_violated,
        e_secret_index_used,
        e_invalid_merkle_proof,
        min_safety_deposit,
    };

    // ============ Wallet Creation (Sui as Source) ============

    /// Create a pre-funded wallet for Sui->EVM swaps
    /// Maker deposits funds that resolvers can later use to create escrows
    entry fun create_wallet<T>(
        order_hash: vector<u8>,
        salt: u256,
        maker_asset: string::String,
        taker_asset: string::String,
        making_amount: u64,
        taking_amount: u64,
        duration: u64,
        hashlock: vector<u8>, // merkle root for partial fills or keccak256(secret) for full fill
        src_safety_deposit_amount: u64,
        dst_safety_deposit_amount: u64,
        allow_partial_fills: bool,
        parts_amount: u8,
        funding: Coin<T>,
        // Relative timelock parameters (in milliseconds from creation)
        src_withdrawal: u64,
        src_public_withdrawal: u64,
        src_cancellation: u64,
        src_public_cancellation: u64,
        dst_withdrawal: u64,
        dst_public_withdrawal: u64,
        dst_cancellation: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let maker = tx_context::sender(ctx);
        let initial_amount = coin::value(&funding);
        
        // Create timelocks struct
        let timelocks = structs::create_timelocks(
            src_withdrawal,
            src_public_withdrawal,
            src_cancellation,
            src_public_cancellation,
            dst_withdrawal,
            dst_public_withdrawal,
            dst_cancellation,
        );
        
        // Validate inputs
        assert!(vector::length(&order_hash) == 32, e_invalid_order_hash());
        assert!(vector::length(&hashlock) == 32, e_invalid_hashlock());
        assert!(initial_amount == making_amount, e_invalid_amount()); // Funding must match making amount
        assert!(making_amount > 0, e_invalid_amount());
        assert!(taking_amount > 0, e_invalid_amount());
        assert!(duration > 0, e_invalid_amount());
        assert!(utils::is_valid_timelocks(&timelocks), e_invalid_timelock());
        
        // If partial fills enabled, validate parts amount
        if (allow_partial_fills) {
            assert!(parts_amount > 1, e_invalid_amount());
        } else {
            // For full fills, parts_amount should be 0
            assert!(parts_amount == 0, e_invalid_amount());
        };
        
        // Create wallet with funding
        let wallet = structs::create_wallet(
            order_hash,
            salt,
            maker,
            maker_asset,
            taker_asset,
            making_amount,
            taking_amount,
            duration,
            hashlock, //this is merkle root for partial fills
            timelocks,
            src_safety_deposit_amount,
            dst_safety_deposit_amount,
            allow_partial_fills,
            parts_amount,
            coin::into_balance(funding),
            sui::clock::timestamp_ms(clock),
            ctx,
        );
        
        // Get wallet address for event
        let wallet_address = structs::wallet_address(&wallet);
        
        // Emit creation event
        events::wallet_created(
            wallet_address,
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
            sui::clock::timestamp_ms(clock),
        );
        
        // Share the wallet object
        transfer::public_share_object(wallet);
    }

    // ============ Escrow Creation ============

    /// Create source chain escrow (Sui as source)
    /// Resolver pulls funds from pre-funded wallet
    /// For partial fills: resolver must provide valid merkle proof
    entry fun create_escrow_src<T>(
        wallet: &mut Wallet<T>,
        secret_hashlock: vector<u8>, // keccak256(secret) for this specific fill
        secret_index: u8, // Index of secret being used (for partial fills)
        merkle_proof: vector<vector<u8>>, // Merkle proof (empty vector for full fills)
        taker: address,
        making_amount: u64, // Amount taker wants to fill from maker. We're assuming we're swapping USDC between two chains so this serves as max taking amount too.
        taking_amount: u64, // Amount taker must provide
        safety_deposit: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let safety_deposit_amount = coin::value(&safety_deposit);
        
        // Basic validations
        assert!(making_amount > 0, e_invalid_amount());
        assert!(taking_amount > 0, e_invalid_amount());
        assert!(safety_deposit_amount >= structs::wallet_src_safety_deposit(wallet), e_safety_deposit_too_low());
        assert!(vector::length(&secret_hashlock) == 32, e_invalid_hashlock());
        
        // Validate wallet can fulfill
        assert!(utils::can_fulfill_amount(wallet, making_amount), e_invalid_amount());
        
        // Dutch auction validation: Ensure taking amount matches auction curve
        let expected_taking_amount = utils::get_taking_amount(wallet, making_amount, clock);
        assert!(taking_amount >= expected_taking_amount, e_auction_violated());
        
        // Partial fill validations
        if (structs::wallet_allow_partial_fills(wallet)) {
            // Validate secret index
            assert!(utils::validate_partial_fill_index(wallet, secret_index, making_amount), e_secret_index_used());
            
            // Verify merkle proof
            let wallet_merkle_root = structs::wallet_hashlock(wallet);
            assert!(
                utils::verify_merkle_proof(&secret_hashlock, wallet_merkle_root, &merkle_proof), 
                e_invalid_merkle_proof()
            );
            
            // Update last used index
            structs::wallet_add_used_index(wallet, secret_index);
        } else {
            // For full fills, secret_index must be 0 and no merkle proof needed
            assert!(secret_index == 0, e_invalid_amount());
            assert!(vector::length(&merkle_proof) == 0, e_invalid_merkle_proof());
            
            // Full fill must take entire wallet balance
            assert!(making_amount == structs::wallet_balance(wallet), e_invalid_amount());
        };
        
        // Pull funds from wallet
        let token_balance = structs::withdraw_from_wallet_for_escrow(wallet, making_amount);
        
        // Create immutables with wallet's timelocks
        let immutables = structs::create_escrow_immutables(
            *structs::wallet_order_hash(wallet),
            secret_hashlock, // Specific hashlock for this fill
            structs::wallet_maker(wallet),
            taker,
            string::utf8(b"wSUI"),
            making_amount,
            safety_deposit_amount,
            *structs::wallet_timelocks(wallet),
        );
        
        // Validate immutables
        assert!(utils::validate_immutables(&immutables), e_invalid_amount());
        
        // Create escrow with current timestamp
        let escrow = structs::create_escrow_src<T>(
            immutables,
            token_balance,
            coin::into_balance(safety_deposit),
            sui::clock::timestamp_ms(clock),
            ctx,
        );
        
        // Get escrow address for event
        let escrow_address = structs::get_src_address(&escrow);
        
        // Emit creation event
        events::escrow_created(
            escrow_address,
            *structs::wallet_order_hash(wallet),
            secret_hashlock,
            structs::wallet_maker(wallet),
            taker,
            making_amount,
            safety_deposit_amount,
            sui::clock::timestamp_ms(clock),
            secret_index,
        );
        
        // Share the escrow
        transfer::public_share_object(escrow);
    }

    /// Create destination chain escrow (Sui as destination)
    /// Taker deposits funds directly
    /// No merkle proof needed - hashlock already determined on EVM
    entry fun create_escrow_dst<T>(
        order_hash: vector<u8>,
        hashlock: vector<u8>, // Specific hashlock for this fill
        maker: address,
        token_deposit: Coin<T>,
        safety_deposit: Coin<SUI>,
        // Relative timelock parameters (in milliseconds)
        src_withdrawal: u64,
        src_public_withdrawal: u64,
        src_cancellation: u64,
        src_public_cancellation: u64,
        dst_withdrawal: u64,
        dst_public_withdrawal: u64,
        dst_cancellation: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let taker = tx_context::sender(ctx);
        let amount = coin::value(&token_deposit);
        let safety_deposit_amount = coin::value(&safety_deposit);
        
        // Create timelocks struct
        let timelocks = structs::create_timelocks(
            src_withdrawal,
            src_public_withdrawal,
            src_cancellation,
            src_public_cancellation,
            dst_withdrawal,
            dst_public_withdrawal,
            dst_cancellation,
        );
        
        // Validate inputs
        assert!(amount > 0, e_invalid_amount());
        assert!(safety_deposit_amount >= min_safety_deposit(), e_safety_deposit_too_low());
        assert!(vector::length(&order_hash) == 32, e_invalid_order_hash());
        assert!(vector::length(&hashlock) == 32, e_invalid_hashlock());
        assert!(utils::is_valid_timelocks(&timelocks), e_invalid_timelock());
        
        // Create immutables
        let immutables = structs::create_escrow_immutables(
            order_hash,
            hashlock,
            maker,
            taker,
            string::utf8(b"wSUI"),
            amount,
            safety_deposit_amount,
            timelocks,
        );
        
        // Validate immutables
        assert!(utils::validate_immutables(&immutables), e_invalid_amount());
        
        // Create escrow with current timestamp
        let escrow = structs::create_escrow_dst<T>(
            immutables,
            coin::into_balance(token_deposit),
            coin::into_balance(safety_deposit),
            sui::clock::timestamp_ms(clock),
            ctx,
        );
        
        // Get escrow address for event
        let escrow_address = structs::get_dst_address(&escrow);
        
        // Emit creation event (secret_index 0 for destination escrows)
        events::escrow_created(
            escrow_address,
            order_hash,
            hashlock,
            maker,
            taker,
            amount,
            safety_deposit_amount,
            sui::clock::timestamp_ms(clock),
            0, // No secret index for destination escrows
        );
        
        // Share the escrow
        transfer::public_share_object(escrow);
    }