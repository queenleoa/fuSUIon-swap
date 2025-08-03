/// Module: escrow
module escrow::constants;

// ============ Status Constants ============

    /// Escrow status values
    public fun status_active(): u8 { 0 }
    public fun status_withdrawn(): u8 { 1 }
    public fun status_cancelled(): u8 { 2 }

// ============ Timelock Stage Constants ============

    /// Timelock stages
    public fun stage_finality_lock(): u8 { 0 }
    public fun stage_resolver_exclusive_withdraw(): u8 { 1 }
    public fun stage_public_withdraw(): u8 { 2 }
    public fun stage_resolver_exclusive_cancel(): u8 { 3 }
    public fun stage_public_cancel(): u8 { 4 } //for sui as a source chain
    public fun stage_rescue(): u8 { 5 }

// ============ Rescue Delay ============

    public fun rescue_delay_period(): u64 { 36000000 } //10 hour to return funds for demo

// ============ Safety Deposit ============

    /// Minimum safety deposit amount (in MIST)
    public fun min_safety_deposit(): u64 { 1_000_000 } // 0.001 SUI

// ============ Error Codes ============
    
    /// Validation errors
    public fun e_invalid_amount(): u64 { 1001 }
    public fun e_invalid_timelock(): u64 { 1002 }
    public fun e_invalid_hashlock(): u64 { 1003 }
    public fun e_invalid_secret(): u64 { 1004 }
    public fun e_invalid_address(): u64 { 1005 }
    
    /// State errors
    public fun e_already_withdrawn(): u64 { 1006 }
    public fun e_not_withdrawable(): u64 { 1007 }
    public fun e_inactive_escrow(): u64 { 1008 }
    public fun e_not_cancellable(): u64 { 1009 }
    
    /// Access errors
    public fun e_unauthorised(): u64 { 1010 }
    public fun e_public_withdraw_not_started(): u64 { 1011 }
    public fun e_public_cancel_not_started(): u64 { 1012 }
    
    /// balance errors
    public fun e_insufficient_balance(): u64 { 1013 }
    public fun e_safety_deposit_too_low(): u64 { 1014 }
    public fun e_wallet_inactive(): u64 { 1015 }
    public fun e_invalid_order_hash(): u64 { 1016 }

     /// partial fill and dutch auction errors
    public fun e_auction_violated(): u64 { 1017 }
    public fun e_secret_index_used(): u64 { 1014 }
    public fun e_invalid_merkle_proof(): u64 { 1015 }


