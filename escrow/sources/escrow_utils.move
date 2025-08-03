/// Module: escrow
module escrow::utils;

    use sui::hash;
    use escrow::structs::{
        EscrowImmutables, 
        Timelocks,
        Wallet,
        get_src_withdrawal_time,
        get_src_public_withdrawal_time,
        get_src_cancellation_time,
        get_src_public_cancellation_time,
        get_dst_withdrawal_time,
        get_dst_public_withdrawal_time,
        get_dst_cancellation_time,
    };
    use escrow::structs;
    use sui::clock::{Clock, timestamp_ms};
    use escrow::constants::{
        stage_finality_lock,
        stage_resolver_exclusive_withdraw,
        stage_public_withdraw,
        stage_resolver_exclusive_cancel,
        stage_public_cancel,
    };

    // ============ Immutables Validation Functions ============

    /// Validate all immutable parameters are properly set
    public(package) fun validate_immutables(immutables: &EscrowImmutables): bool {
        // Validate order hash is 32 bytes
        if (vector::length(structs::get_order_hash(immutables)) != 32) {
            return false
        };
        
        // Validate hashlock is 32 bytes (keccak256)
        if (vector::length(structs::get_hashlock(immutables)) != 32) {
            return false
        };
        
        // Validate addresses are not zero
        if (structs::get_maker(immutables) == @0x0 || 
            structs::get_taker(immutables) == @0x0) {
            return false
        };
        
        // Validate amounts are positive
        if (structs::get_amount(immutables) == 0 || 
            structs::get_safety_deposit_amount(immutables) == 0) {
            return false
        };
        
        true
    }

    // ============ Balance Validation Functions ============

    /// Validate token balance meets required amount
    public(package) fun validate_balance(provided: u64, required: u64): bool {
        provided >= required
    }

    // ============ Hashlock Validation Functions ============

    /// Validate a secret against a hashlock
    public(package) fun validate_hashlock(secret: &vector<u8>, hashlock: &vector<u8>): bool {
        let hashed = hash::keccak256(secret);
        &hashed == hashlock
    }

    /// Check if secret meets minimum length requirements
    public(package) fun validate_secret_length(secret: &vector<u8>): bool {
        vector::length(secret) >= 32
    }

    // ============ Timelock Functions ============

    /// Validate that relative timelocks form a proper sequence
    public(package) fun is_valid_timelocks(tl: &Timelocks): bool {
        // Monotonic sequence on the source chain (all relative times)
        let src_ok =
            0 < get_src_withdrawal_time(tl) &&
            get_src_withdrawal_time(tl) < get_src_public_withdrawal_time(tl) &&
            get_src_public_withdrawal_time(tl) < get_src_cancellation_time(tl) &&
            get_src_cancellation_time(tl) < get_src_public_cancellation_time(tl);

        // Monotonic sequence on the destination chain
        let dst_ok =
            0 < get_dst_withdrawal_time(tl) &&
            get_dst_withdrawal_time(tl) < get_dst_public_withdrawal_time(tl) &&
            get_dst_public_withdrawal_time(tl) < get_dst_cancellation_time(tl);

        // Cross-chain ordering (dst deadlines must precede src)
        let cross_ok =
            get_dst_withdrawal_time(tl) < get_src_withdrawal_time(tl) &&
            get_dst_public_withdrawal_time(tl) < get_src_public_withdrawal_time(tl) &&
            get_dst_cancellation_time(tl) < get_src_cancellation_time(tl);

        // All groups must pass
        src_ok && dst_ok && cross_ok
    }

    /// Calculate absolute timelock from relative timelock and creation time
    fun calculate_absolute_time(created_at: u64, relative_time: u64): u64 {
        created_at + relative_time
    }

    /// Get stage for source escrow based on relative timelocks
    public(package) fun src_stage(tl: &Timelocks, created_at: u64, clock: &Clock): u8 {
        let now = timestamp_ms(clock);
        
        // Calculate absolute times from relative
        let abs_src_withdrawal = calculate_absolute_time(created_at, get_src_withdrawal_time(tl));
        let abs_src_public_withdrawal = calculate_absolute_time(created_at, get_src_public_withdrawal_time(tl));
        let abs_src_cancellation = calculate_absolute_time(created_at, get_src_cancellation_time(tl));
        let abs_src_public_cancellation = calculate_absolute_time(created_at, get_src_public_cancellation_time(tl));

        if (now < abs_src_withdrawal) {
            stage_finality_lock()
        } else if (now < abs_src_public_withdrawal) {
            stage_resolver_exclusive_withdraw()
        } else if (now < abs_src_cancellation) {
            stage_public_withdraw()
        } else if (now < abs_src_public_cancellation) {
            stage_resolver_exclusive_cancel()
        } else {
            stage_public_cancel()
        }
    }

    /// Get stage for destination escrow based on relative timelocks
    public(package) fun dst_stage(tl: &Timelocks, created_at: u64, clock: &Clock): u8 {
        let now = timestamp_ms(clock);
        
        // Calculate absolute times from relative
        let abs_dst_withdrawal = calculate_absolute_time(created_at, get_dst_withdrawal_time(tl));
        let abs_dst_public_withdrawal = calculate_absolute_time(created_at, get_dst_public_withdrawal_time(tl));
        let abs_dst_cancellation = calculate_absolute_time(created_at, get_dst_cancellation_time(tl));

        if (now < abs_dst_withdrawal) {
            stage_finality_lock()
        } else if (now < abs_dst_public_withdrawal) {
            stage_resolver_exclusive_withdraw()
        } else if (now < abs_dst_cancellation) {
            stage_public_withdraw()
        } else {
            stage_resolver_exclusive_cancel()
        }
    }

    // ============ Dutch Auction Functions (1inch style) ============

    /// Calculate auction taking amount at current time
    /// Mirrors 1inch DutchAuctionCalculator._calculateAuctionTakingAmount
    fun calculate_auction_taking_amount(
        created_at: u64,
        duration: u64,
        taking_amount_start: u64, //wallet making amount is max
        taking_amount_end: u64,   //wallet taking amount is min
        current_time: u64
    ): u64 {
        let start_time = created_at;
        let end_time = created_at + duration;

        // Clamp current time between start and end
        let t = if (current_time < start_time) {
            start_time
        } else if (current_time > end_time) {
            end_time
        } else {
            current_time
        };

        // Convert to u128 for precision
        let t_u128 = (t as u128);
        let start_time_u128 = (start_time as u128);
        let end_time_u128 = (end_time as u128);
        let taking_start_u128 = (taking_amount_start as u128);
        let taking_end_u128 = (taking_amount_end as u128);

        // Linear interpolation formula from 1inch
        // (takingAmountStart * (endTime - currentTime) + takingAmountEnd * (currentTime - startTime)) / (endTime - startTime)
        let result = (taking_start_u128 * (end_time_u128 - t_u128) + taking_end_u128 * (t_u128 - start_time_u128)) 
                     / (end_time_u128 - start_time_u128);
        
        (result as u64)
    }

    /// Get making amount based on taking amount (1inch style)
    /// Returns how much maker tokens for given taker tokens (following price curve)
    public fun get_making_amount<T>(
        wallet: &Wallet<T>, //gives absolute making amount and taking amount 
        taking_amount: u64, //relative taking amount
        clock: &Clock,
    ): u64 {
        let start_time = structs::wallet_created_at(wallet);
        let duration =  structs::wallet_duration(wallet);
        let current_time = timestamp_ms(clock);
        
        let calculated_taking_amount = calculate_auction_taking_amount(
            start_time,
            duration,
            structs::wallet_making_amount(wallet), // Start high
            structs::wallet_taking_amount(wallet), // End low 
            current_time
        );
        
        // makingAmount * takingAmount / calculatedTakingAmount
        let making_u128 = (structs::wallet_making_amount(wallet) as u128); //absolute making amount
        let taking_u128 = (taking_amount as u128); //relative taking amount (partial fills)
        let calc_taking_u128 = (calculated_taking_amount as u128); //absolute taking amount
        
        let result = (making_u128 * taking_u128) / calc_taking_u128;
        (result as u64)
    }

    /// Get taking amount based on making amount (1inch style)
    /// Returns how much taker tokens needed for given maker tokens
    public fun get_taking_amount<T>(
        wallet: &Wallet<T>, //gives absolute making amount and taking amount 
        making_amount: u64, //relative making amount
        clock: &Clock,
    ): u64 {
        let start_time = structs::wallet_created_at(wallet);
        let duration =  structs::wallet_duration(wallet);
        let current_time = timestamp_ms(clock);
        
        let calculated_taking_amount = calculate_auction_taking_amount(
            start_time,
            duration,
            structs::wallet_making_amount(wallet), // Start high
            structs::wallet_taking_amount(wallet), // End low 
            current_time
        );
        
        // ceilDiv: (calculatedTakingAmount * makingAmount + wallet.makingAmount - 1) / wallet.makingAmount
        let calc_taking_u128 = (calculated_taking_amount as u128);
        let making_u128 = (making_amount as u128);
        let wallet_making_u128 = (structs::wallet_making_amount(wallet) as u128);
        
        let result = (calc_taking_u128 * making_u128 + wallet_making_u128 - 1) / wallet_making_u128;
        (result as u64)
    }

    // ============ Partial Fill & Merkle Functions (1inch style) ============

    /// Verify merkle proof for partial fill
    /// Validates that a secret at given index is part of the merkle tree
    public fun verify_merkle_proof(
        leaf: &vector<u8>,
        merkle_root: &vector<u8>,
        proof: &vector<vector<u8>>,
    ): bool {
        let mut current_hash = *leaf;
        let proof_len = vector::length(proof);
        let mut i = 0;
        
        while (i < proof_len) {
            let proof_element = vector::borrow(proof, i);
            
            // Combine hashes in sorted order (matching EVM SimpleMerkleTree)
            current_hash = if (is_less_than(&current_hash, proof_element)) {
                hash_pair(&current_hash, proof_element)
            } else {
                hash_pair(proof_element, &current_hash)
            };
            
            i = i + 1;
        };
        
        // Compare final hash with merkle root
        &current_hash == merkle_root
    }

    /// Hash two nodes together for merkle tree
    fun hash_pair(left: &vector<u8>, right: &vector<u8>): vector<u8> {
        let mut combined = *left;
        vector::append(&mut combined, *right);
        hash::keccak256(&combined)
    }

    /// Compare two byte arrays lexicographically
    /// Returns true if a < b
    fun is_less_than(a: &vector<u8>, b: &vector<u8>): bool {
        let len_a = vector::length(a);
        let len_b = vector::length(b);
        let min_len = if (len_a < len_b) { len_a } else { len_b };
        
        let mut i = 0;
        while (i < min_len) {
            let byte_a = *vector::borrow(a, i);
            let byte_b = *vector::borrow(b, i);
            
            if (byte_a < byte_b) {
                return true
            } else if (byte_a > byte_b) {
                return false
            };
            
            i = i + 1;
        };
        
        // If all compared bytes are equal, shorter vector is less
        len_a < len_b
    }

    /// Validate that resolver can use a specific secret index
    /// Based on the fill amount and previous fills
    public fun validate_partial_fill_index<T>(
        wallet: &Wallet<T>,
        secret_index: u8,
        fill_amount: u64,
    ): bool {
        // Check if partial fills are allowed
        if (!structs::wallet_allow_partial_fills(wallet)) {
            return secret_index == 0 // Only index 0 for single fill
        };
        
        let parts_amount = structs::wallet_parts_amount(wallet);
        let last_used_index = structs::wallet_last_used_index(wallet);
        
       // Special handling for uninitialized state
        if (last_used_index == 255) {
            // First use - index must be valid for the fill amount
            if (secret_index > parts_amount) {
                return false
            };
        } else {
            // Subsequent uses - must be greater than last used
            if (secret_index <= last_used_index) {
                return false
            };
            if (secret_index > parts_amount) {
                return false
            };
        };
        
        // For partial fills, calculate if fill amount justifies using this index
        let total_amount = structs::wallet_making_amount(wallet);
        let already_filled = total_amount - structs::wallet_balance(wallet);
        let new_total_filled = already_filled + fill_amount;
     
        // Calculate minimum amount needed for this index
        // Each part represents roughly 1/n of the total
        //lowerbound index
        // ----- bucket math -----
    // Boundaries are (index / parts_amount) * total
            let denom = parts_amount as u64;

            let min_for_idx = (total_amount * (secret_index as u64)) / denom;          // lower bound inclusive
            let max_for_idx =
                if (secret_index < parts_amount) {
                    (total_amount * ((secret_index + 1) as u64)) / denom               // upper bound exclusive
                } else {
                    total_amount                                                      // last bucket – up to 100 %
                };

                if (secret_index == parts_amount) {
            // Special case for last index - must fill exactly to 100%
            new_total_filled == total_amount
        } else {
            // Normal bucket range check
            (new_total_filled >= min_for_idx) && (new_total_filled < max_for_idx)
        }
    }

    // ============ Helper Functions ============

    /// Check if wallet can fulfill requested amount
    public fun can_fulfill_amount<T>(
        wallet: &Wallet<T>,
        requested_amount: u64,
    ): bool {
        structs::wallet_balance(wallet) >= requested_amount && 
        structs::wallet_is_active(wallet)
    }