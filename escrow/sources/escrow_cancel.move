/// Module: escrow
module escrow::escrow_cancel;

    use sui::coin::{Self};
    use sui::clock::Clock;
    use escrow::structs::{Self, EscrowSrc, EscrowDst};
    use escrow::events;
    use escrow::utils;
    use escrow::constants::{
        e_unauthorised,
        e_inactive_escrow,
        e_not_cancellable,
        status_active,
        status_cancelled,
        stage_resolver_exclusive_cancel,
        stage_public_cancel,
    };

    // ============ Cancellation Functions ============
    // Note: Status must be updated before extracting balances to avoid 
    // multiple mutable borrows of the escrow object

    /// Cancel source escrow (refund to maker)
    entry fun cancel_src<T>(
        escrow: &mut EscrowSrc<T>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let caller = tx_context::sender(ctx);

        // ************ READ‑ONLY SCOPE ************ //
        // Returns (maker, taker, order_hash, amount)
        let (maker, taker, order_hash, amount) = {
            let imm = structs::get_src_immutables(escrow);
            let created_at = structs::get_src_created_at(escrow);

            // Stage & status checks
            let timelocks     = structs::get_timelocks(imm);
            let current_stage = utils::src_stage(timelocks, created_at, clock);
            assert!(structs::get_src_status(escrow) == status_active(), e_inactive_escrow());

            // Authorisation by stage
            if (current_stage == stage_resolver_exclusive_cancel()) {
                assert!(caller == structs::get_taker(imm), e_unauthorised());
            } else if (current_stage == stage_public_cancel()) {
                // anyone can cancel
            } else {
                abort e_not_cancellable()
            };

            // Bind values to locals, then return tuple  (❗ no semicolon)
            let maker_local      = structs::get_maker(imm);
            let taker_local      = structs::get_taker(imm);
            let order_hash_local = *structs::get_order_hash(imm); // vector<u8>
            let amount_local     = structs::get_amount(imm);

            (copy maker_local, copy taker_local, order_hash_local, amount_local)
            // ← immutable borrow ends here
        };
        // ************ MUTATION PHASE ************ //

        let (token_balance, safety_deposit) = structs::extract_all_from_src(escrow);
        structs::set_src_status(escrow, status_cancelled());

        // Transfers
        transfer::public_transfer(coin::from_balance(token_balance, ctx), maker);
        transfer::public_transfer(coin::from_balance(safety_deposit, ctx), caller);

        // Event
        events::escrow_cancelled(
            structs::get_src_address(escrow),
            order_hash,
            maker,
            taker,
            caller,
            amount,
            sui::clock::timestamp_ms(clock),
        );
    }

    /// Cancel destination escrow (refund to taker)
    entry fun cancel_dst<T>(
        escrow: &mut EscrowDst<T>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let caller = tx_context::sender(ctx);

        // ************ READ‑ONLY SCOPE ************ //
        // Returns (maker, taker, order_hash, amount)
        let (maker, taker, order_hash, amount) = {
            let imm = structs::get_dst_immutables(escrow);
            let created_at = structs::get_dst_created_at(escrow);

            // Stage & status checks
            let timelocks     = structs::get_timelocks(imm);
            let current_stage = utils::dst_stage(timelocks,created_at, clock);
            assert!(structs::get_dst_status(escrow) == status_active(), e_inactive_escrow());

            // Must be past (or at) resolver‑exclusive‑cancel stage
            assert!(current_stage >= stage_resolver_exclusive_cancel(), e_not_cancellable());

            // Only the assigned resolver may cancel
            assert!(caller == structs::get_taker(imm), e_unauthorised());

            // Bind values to locals, then return tuple  (❗ no semicolon)
            let maker_local      = structs::get_maker(imm);
            let taker_local      = structs::get_taker(imm);
            let order_hash_local = *structs::get_order_hash(imm);  // vector<u8>
            let amount_local     = structs::get_amount(imm);

            (copy maker_local, copy taker_local, order_hash_local, amount_local)
            // ← immutable borrow ends here
        };
        //************ MUTATION PHASE ************//

        let (token_balance, safety_deposit) = structs::extract_all_from_dst(escrow);
        structs::set_dst_status(escrow, status_cancelled());
        // Transfers
        transfer::public_transfer(coin::from_balance(token_balance, ctx), taker);
        transfer::public_transfer(coin::from_balance(safety_deposit, ctx), caller);

        // Event
        events::escrow_cancelled(
            structs::get_dst_address(escrow),
            order_hash,
            maker,
            taker,
            caller,
            amount,
            sui::clock::timestamp_ms(clock),
        );
    }
