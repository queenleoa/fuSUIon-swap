/// Module: escrow
module escrow::escrow_withdraw;

    use sui::coin::{Self};
    use sui::clock::Clock;
    use escrow::structs::{Self, EscrowSrc, EscrowDst};
    use escrow::events;
    use escrow::utils;
    use escrow::constants::{
        e_invalid_secret,
        e_unauthorised,
        e_already_withdrawn,
        e_not_withdrawable,
        status_active,
        status_withdrawn,
        stage_resolver_exclusive_withdraw,
        stage_public_withdraw,
    };
    use escrow::constants::e_inactive_escrow;

    // ============ Withdrawal Functions ============

    /// Withdraw from source escrow (reveal secret, funds go to taker)
    entry fun withdraw_src<T>(
        escrow: &mut EscrowSrc<T>,
        secret: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let caller = tx_context::sender(ctx);

        // ************ READ‑ONLY SCOPE ************ //
        let (taker, 
            maker, 
            order_hash, 
            amount,
            hashlock) = {
            let imm = structs::get_src_immutables(escrow);
            let created_at = structs::get_src_created_at(escrow);

            // Stage & status checks
            let timelocks     = structs::get_timelocks(imm);
            let current_stage = utils::src_stage(timelocks, created_at, clock);
            assert!(structs::get_src_status(escrow) == status_active(), e_inactive_escrow());

            // Secret validation
            assert!(utils::validate_secret_length(&secret), e_invalid_secret());
            assert!( utils::validate_hashlock(&secret, structs::get_hashlock(imm)), e_invalid_secret());

            // Authorisation by stage
            if (current_stage == stage_resolver_exclusive_withdraw()) {
                assert!(caller == structs::get_taker(imm), e_unauthorised());
            } else if (current_stage == stage_public_withdraw()) {
                // anyone can withdraw
            } else {
                abort e_not_withdrawable()
            };

                // Bind results to locals, then return tuple (no semicolon!)
                let taker_local      = structs::get_taker(imm);
                let maker_local      = structs::get_maker(imm);
                let order_hash_local = *structs::get_order_hash(imm); // vector<u8> – move, not copy
                let amount_local     = structs::get_amount(imm);
                let hashlock_local = *structs::get_hashlock(imm);
                (copy taker_local, copy maker_local, order_hash_local, amount_local, hashlock_local)
                // immutable borrow ends here
        };
        // ************ MUTATION PHASE ************ //

        // Needs &mut, so borrow is now clear
        let (token_balance, safety_deposit) = structs::extract_all_from_src(escrow);
        structs::set_src_status(escrow, status_withdrawn());

        // Transfers
        transfer::public_transfer(coin::from_balance(token_balance, ctx), taker);
        transfer::public_transfer(coin::from_balance(safety_deposit, ctx), caller);

        // Event
        events::escrow_withdrawn(
            structs::get_src_address(escrow),
            order_hash,
            hashlock,
            secret,
            caller,
            maker,
            taker,
            amount,
            sui::clock::timestamp_ms(clock),
        );
    }

    /// Withdraw from destination escrow (reveal secret, funds go to maker)
    entry fun withdraw_dst<T>(
        escrow: &mut EscrowDst<T>,
        secret: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) { 
        let caller = tx_context::sender(ctx);

        // ************ READ‑ONLY SCOPE ************ //
        // Returns (maker, taker, order_hash, amount)
        let (maker, 
            taker, 
            order_hash, 
            amount,
            hashlock) = {
            let imm = structs::get_dst_immutables(escrow);
            let created_at = structs::get_dst_created_at(escrow);

            // Stage & status checks
            let timelocks     = structs::get_timelocks(imm);
            let current_stage = utils::dst_stage(timelocks, created_at, clock);
            assert!(structs::get_dst_status(escrow) == status_active(), e_already_withdrawn());

            // Secret validation
            assert!(utils::validate_secret_length(&secret), e_invalid_secret());
            assert!(
                utils::validate_hashlock(&secret, structs::get_hashlock(imm)),
                e_invalid_secret()
            );

            // Authorisation by stage
            if (current_stage == stage_resolver_exclusive_withdraw()) {
                assert!(caller == structs::get_taker(imm), e_unauthorised());
            } else if (current_stage == stage_public_withdraw()) {
                // anyone can withdraw
            } else {
                abort e_not_withdrawable()
            };

            let maker_local      = structs::get_maker(imm);
            let taker_local      = structs::get_taker(imm);
            let hashlock_local = *structs::get_hashlock(imm);
            let order_hash_local = *structs::get_order_hash(imm); // vector<u8>
            let amount_local     = structs::get_amount(imm);

            (copy maker_local, copy taker_local, order_hash_local, amount_local, hashlock_local)
            // ← immutable borrow ends here
        };
        //************ MUTATION PHASE ************//

        // Needs &mut after borrow is gone
        let (token_balance, safety_deposit) = structs::extract_all_from_dst(escrow);
        structs::set_dst_status(escrow, status_withdrawn());

        // Transfers
        transfer::public_transfer(coin::from_balance(token_balance, ctx), maker);
        transfer::public_transfer(coin::from_balance(safety_deposit, ctx), caller);

        // Event
        events::escrow_withdrawn(
            structs::get_dst_address(escrow),
            order_hash,
            hashlock,
            secret,
            caller,
            maker,
            taker,
            amount,
            sui::clock::timestamp_ms(clock),
        );
    }
