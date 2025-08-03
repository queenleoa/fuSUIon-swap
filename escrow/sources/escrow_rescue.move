/// Module: escrow
module escrow::escrow_rescue;

    use sui::clock::Clock;
    use sui::event;
    use std::string;
    use escrow::structs::{Self, Wallet, EscrowSrc, EscrowDst};
    use escrow::constants::{
        e_inactive_escrow,
        rescue_delay_period,
    };
    use escrow::structs::destroy_dst_escrow;
    use escrow::structs::destroy_src_escrow;
    use escrow::structs::destroy_wallet;

    // ============ Rescue Events ============

    /// Event emitted when a wallet is rescued
    public struct WalletRescued has copy, drop {
        wallet_id: address,
        order_hash: vector<u8>,
        maker: address,
        rescued_by: address,
        amount: u64,
        rescued_at: u64,
    }

    /// Event emitted when an escrow is rescued
    public struct EscrowRescued has copy, drop {
        escrow_id: address,
        order_hash: vector<u8>,
        hashlock: vector<u8>,
        maker: address,
        taker: address,
        rescued_by: address,
        amount: u64,
        rescued_at: u64,
        escrow_type: string::String,
    }

    // ============ Rescue Functions ============
    // These functions allow recovery of funds and/or cleanup of objects after all timelocks have expired
    // and an additional rescue delay period has passed.
    // Can be called on escrows/wallets in any status to get storage rebates.

    /// Calculate if rescue stage has been reached for source escrow
    fun is_src_rescue_stage(created_at: u64, timelocks: &structs::Timelocks, clock: &Clock): bool {
        let current_time = sui::clock::timestamp_ms(clock);
        let public_cancel_time = created_at + structs::get_src_public_cancellation_time(timelocks);
        let rescue_time = public_cancel_time + rescue_delay_period();
        
        current_time >= rescue_time
    }

    /// Calculate if rescue stage has been reached for destination escrow
    fun is_dst_rescue_stage(created_at: u64, timelocks: &structs::Timelocks, clock: &Clock): bool {
        let current_time = sui::clock::timestamp_ms(clock);
        let cancel_time = created_at + structs::get_dst_cancellation_time(timelocks);
        let rescue_time = cancel_time + rescue_delay_period();
        
        current_time >= rescue_time
    }

    /// Calculate if rescue stage has been reached for wallet
    fun is_wallet_rescue_stage(created_at: u64, timelocks: &structs::Timelocks, clock: &Clock): bool {
        // Wallet rescue is based on source chain timelocks since wallet is on source
        is_src_rescue_stage(created_at, timelocks, clock)
    }

    // ============ Wallet Rescue ============

    /// Rescue funds from abandoned wallet or cleanup empty wallets
    /// Returns any remaining funds to the maker and destroys the wallet
    /// Can be called on active or inactive wallets for storage rebate
    entry fun rescue_wallet<T>(
        wallet: Wallet<T>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let caller = tx_context::sender(ctx);
        let maker = structs::wallet_maker(&wallet);
        let created_at = structs::wallet_created_at(&wallet);
        let timelocks = structs::wallet_timelocks(&wallet);
        let wallet_address = structs::wallet_address(&wallet);
        let order_hash = *structs::wallet_order_hash(&wallet);
        
        // Check if rescue stage has been reached
        assert!(is_wallet_rescue_stage(created_at, timelocks, clock), e_inactive_escrow());
        
        // Get remaining balance before destruction
        let remaining_amount = structs::wallet_balance(&wallet);
        
        destroy_wallet(wallet, maker, ctx);
        
        // Emit rescue event
        event::emit(WalletRescued {
            wallet_id: wallet_address,
            order_hash,
            maker,
            rescued_by: caller,
            amount: remaining_amount,
            rescued_at: sui::clock::timestamp_ms(clock),
        });
    }

    // ============ Source Escrow Rescue ============

    /// Rescue funds from abandoned source escrow or cleanup already processed escrows
    /// Returns any remaining tokens to maker, safety deposit to caller, and destroys the escrow
    /// Can be called on active, withdrawn, or cancelled escrows for storage rebate
    entry fun rescue_src<T>(
        escrow: EscrowSrc<T>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let caller = tx_context::sender(ctx);
        
        // Read data before destruction
        let escrow_address = structs::get_src_address(&escrow);
        let imm = structs::get_src_immutables(&escrow);
        let created_at = structs::get_src_created_at(&escrow);
        let timelocks = structs::get_timelocks(imm);
        
        // Check if rescue stage has been reached
        assert!(is_src_rescue_stage(created_at, timelocks, clock), e_inactive_escrow());
        
        // Extract data for event
        let maker = structs::get_maker(imm);
        let taker = structs::get_taker(imm);
        let order_hash = *structs::get_order_hash(imm);
        let amount = structs::get_amount(imm);
        let hashlock = *structs::get_hashlock(imm);
        
        destroy_src_escrow(escrow, maker, ctx);
        
        // Emit rescue event
        event::emit(EscrowRescued {
            escrow_id: escrow_address,
            order_hash,
            hashlock,
            maker,
            taker,
            rescued_by: caller,
            amount,
            rescued_at: sui::clock::timestamp_ms(clock),
            escrow_type: string::utf8(b"source"),
        });
    }

    // ============ Destination Escrow Rescue ============

    /// Rescue funds from abandoned destination escrow or cleanup already processed escrows
    /// Returns any remaining tokens to taker, safety deposit to caller, and destroys the escrow
    /// Can be called on active, withdrawn, or cancelled escrows for storage rebate
    entry fun rescue_dst<T>(
        escrow: EscrowDst<T>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let caller = tx_context::sender(ctx);
        
        // Read data before destruction
        let escrow_address = structs::get_dst_address(&escrow);
        let imm = structs::get_dst_immutables(&escrow);
        let created_at = structs::get_dst_created_at(&escrow);
        let timelocks = structs::get_timelocks(imm);
        
        // Check if rescue stage has been reached
        assert!(is_dst_rescue_stage(created_at, timelocks, clock), e_inactive_escrow());
        
        // Extract data for event
        let maker = structs::get_maker(imm);
        let taker = structs::get_taker(imm);
        let order_hash = *structs::get_order_hash(imm);
        let amount = structs::get_amount(imm);
        let hashlock = *structs::get_hashlock(imm);
        
        // Destructure the escrow
        destroy_dst_escrow(escrow, taker, ctx);
        
        // Emit rescue event
        event::emit(EscrowRescued {
            escrow_id: escrow_address,
            order_hash,
            hashlock,
            maker,
            taker,
            rescued_by: caller,
            amount,
            rescued_at: sui::clock::timestamp_ms(clock),
            escrow_type: string::utf8(b"destination"),
        });
    }
}