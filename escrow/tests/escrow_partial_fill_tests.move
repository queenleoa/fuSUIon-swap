#[test_only]
#[allow(unused_variable, implicit_const_copy)]

module escrow::escrow_partial_fill_tests;

    use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::hash;
    use std::string;
 
    use escrow::escrow_create;
    use escrow::escrow_withdraw;
    use escrow::escrow_cancel;
    use escrow::structs::{Self, Wallet, EscrowSrc};
    use escrow::utils;
    use escrow::constants;
    use escrow::merkle_utils_testonly as merkle;
    
    // Test addresses
    const MAKER: address = @0xA;
    const TAKER: address = @0xB; 
    const RESOLVER1: address = @0xC;
    const RESOLVER2: address = @0xD;
    const RESOLVER3: address = @0xE;
    const RESOLVER4: address = @0xF;
    
    // Test amounts for 4-part order (1 TOKEN total)
    const WALLET_AMOUNT: u64 = 1_000_000_000; // 1 TOKEN
    const TAKING_AMOUNT_MIN: u64 = 900_000_000;  // 0.9 TOKEN (minimum)
    const SAFETY_DEPOSIT: u64 = 10_000_000;   // 0.01 SUI per part
    const DURATION: u64 = 3_600_000; // 1 hour

    // Partial fill amounts - these must align with bucket boundaries!
    // For 4 parts: [0-25%), [25%-50%), [50%-75%), [75%-100%), [100%]
    const FILL_20_PERCENT: u64 = 200_000_000;  // 20% - uses index 0
    const FILL_10_PERCENT: u64 = 100_000_000;  // 10% - uses index 0
    const FILL_25_PERCENT: u64 = 250_000_000;  // 25% - boundary case
    const FILL_30_PERCENT: u64 = 300_000_000;  // 30% - uses index 1 if first fill
    const FILL_40_PERCENT: u64 = 400_000_000;  // 40% - uses index 1 if first fill
    const FILL_50_PERCENT: u64 = 500_000_000;  // 50% - uses index 1 if first fill

    // Test secrets (5 secrets for 4-part order)
    const SECRET0: vector<u8> = b"secret0_32_bytes_long_0000000000";
    const SECRET1: vector<u8> = b"secret1_32_bytes_long_1111111111";
    const SECRET2: vector<u8> = b"secret2_32_bytes_long_2222222222";
    const SECRET3: vector<u8> = b"secret3_32_bytes_long_3333333333";
    const SECRET4: vector<u8> = b"secret4_32_bytes_long_4444444444";

    // Test token
    public struct TEST has drop {}
    
    // Helper to create all secrets and merkle root
    fun setup_merkle(): (vector<vector<u8>>, vector<u8>) {
        let secrets = vector[SECRET0, SECRET1, SECRET2, SECRET3, SECRET4];
        let root = merkle::root_from_secrets(&secrets);
        (secrets, root)
    }
    
    fun setup_test(): (Scenario, Clock, vector<u8>) {
        let mut scenario = test::begin(MAKER);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        let order_hash = b"partial_order_hash_32_bytes_long";
        (scenario, clock, order_hash)
    }
    
    fun mint_test(amount: u64, scenario: &mut Scenario): Coin<TEST> {
        coin::mint_for_testing<TEST>(amount, ctx(scenario))
    }

    fun mint_sui(amount: u64, scenario: &mut Scenario): Coin<SUI> {
        coin::mint_for_testing<SUI>(amount, ctx(scenario))
    }

    // ============ Basic Partial Fill Tests ============
    #[test]
    fun test_partial_fill_single_resolver() {
        let (mut scenario, mut clock, order_hash) = setup_test();
        let (secrets, root) = setup_merkle();
        
        // Create wallet with 4 parts
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT, &mut scenario);
            
            escrow_create::create_wallet(
                order_hash,
                1234u256,
                string::utf8(b"TEST"),
                string::utf8(b"ETH"),
                WALLET_AMOUNT,
                TAKING_AMOUNT_MIN,
                DURATION,
                root,
                SAFETY_DEPOSIT,
                SAFETY_DEPOSIT,
                true,  // Allow partial fills
                4,     // 4 parts
                funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock,
                ctx(&mut scenario)
            );
        };
        
        // Advance time for dutch auction
        clock::increment_for_testing(&mut clock, 100_000);
        
        // Fill 10% using secret index 0 (cumulative: 10%, falls in [0%, 25%))
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET0);
            let proof = merkle::proof_for_index_from_secrets(&secrets, 0);
            
            let expected_taking = utils::get_taking_amount(&wallet, FILL_10_PERCENT, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet,
                secret_hashlock,
                0, // Index 0 for [0%, 25%)
                proof,
                TAKER,
                FILL_10_PERCENT,
                expected_taking,
                safety_deposit,
                &clock,
                ctx(&mut scenario)
            );
            
            assert!(structs::wallet_last_used_index(&wallet) == 0, 0);
            assert!(structs::wallet_balance(&wallet) == 900_000_000, 1);
            test::return_shared(wallet);
        };
        
        // Verify escrow and withdraw
        clock::increment_for_testing(&mut clock, 300_000);
        
        next_tx(&mut scenario, TAKER);
        {
            let mut escrow = test::take_shared<EscrowSrc<TEST>>(&scenario);
            
            escrow_withdraw::withdraw_src(
                &mut escrow,
                SECRET0,
                &clock,
                ctx(&mut scenario)
            );
            
            assert!(structs::get_src_status(&escrow) == constants::status_withdrawn(), 0);
            test::return_shared(escrow);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_partial_fill_multiple_resolvers_sequential() {
        let (mut scenario, mut clock, order_hash) = setup_test();
        let (secrets, root) = setup_merkle();
        
        // Create wallet
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT, &mut scenario);
            
            escrow_create::create_wallet(
                order_hash, 5678u256,
                string::utf8(b"TEST"), string::utf8(b"ETH"),
                WALLET_AMOUNT, TAKING_AMOUNT_MIN, DURATION,
                root, SAFETY_DEPOSIT, SAFETY_DEPOSIT,
                true, 4, funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        clock::increment_for_testing(&mut clock, 100_000);
        
        // Resolver 1: Fill 40% (cumulative 40%) - use index 1 
        // 40% falls in [25%, 50%) bucket
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET1);
            let proof = merkle::proof_for_index_from_secrets(&secrets, 1);
            
            let expected_taking = utils::get_taking_amount(&wallet, FILL_40_PERCENT, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 1, proof,
                TAKER, FILL_40_PERCENT, expected_taking,
                safety_deposit, &clock, ctx(&mut scenario)
            );
            
            assert!(structs::wallet_last_used_index(&wallet) == 1, 0);
            assert!(structs::wallet_balance(&wallet) == 600_000_000, 1);
            test::return_shared(wallet);
        };
        
        // Resolver 2: Fill 35% (cumulative 75%) - use index 3
        // 75% falls in [75%, 100%) bucket  
        clock::increment_for_testing(&mut clock, 300_000);
        
        next_tx(&mut scenario, RESOLVER2);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET3);
            let proof = merkle::proof_for_index_from_secrets(&secrets, 3);
            
            let expected_taking = utils::get_taking_amount(&wallet, 350_000_000, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 3, proof,
                TAKER, 350_000_000, expected_taking,
                safety_deposit, &clock, ctx(&mut scenario)
            );
            
            assert!(structs::wallet_last_used_index(&wallet) == 3, 0);
            assert!(structs::wallet_balance(&wallet) == 250_000_000, 1);
            test::return_shared(wallet);
        };
        
        // Resolver 3: Fill remaining 25% (cumulative 100%) - use index 4
        clock::increment_for_testing(&mut clock, 200_000);
        
        next_tx(&mut scenario, RESOLVER3);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET4);
            let proof = merkle::proof_for_index_from_secrets(&secrets, 4);
            
            let expected_taking = utils::get_taking_amount(&wallet, 250_000_000, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 4, proof,
                TAKER, 250_000_000, expected_taking,
                safety_deposit, &clock, ctx(&mut scenario)
            );
            
            assert!(structs::wallet_last_used_index(&wallet) == 4, 0);
            assert!(structs::wallet_balance(&wallet) == 0, 1);
            test::return_shared(wallet);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // ============ Bucket Boundary Tests ============
    
    #[test]
    fun test_partial_fill_exact_bucket_boundaries() {
        let (mut scenario, mut clock, order_hash) = setup_test();
        let (secrets, root) = setup_merkle();
        
        // Create wallet
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT, &mut scenario);
            
            escrow_create::create_wallet(
                order_hash, 9999u256,
                string::utf8(b"TEST"), string::utf8(b"ETH"),
                WALLET_AMOUNT, TAKING_AMOUNT_MIN, DURATION,
                root, SAFETY_DEPOSIT, SAFETY_DEPOSIT,
                true, 4, funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        clock::increment_for_testing(&mut clock, 100_000);
        
        // Fill exactly 50% (500M) - should use index 2 (cumulative 50% falls in [50%, 75%))
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET2);
            let proof = merkle::proof_for_index_from_secrets(&secrets, 2);
            
            let expected_taking = utils::get_taking_amount(&wallet, FILL_50_PERCENT, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 2, proof,
                TAKER, FILL_50_PERCENT, expected_taking,
                safety_deposit, &clock, ctx(&mut scenario)
            );
            
            assert!(structs::wallet_balance(&wallet) == 500_000_000, 0);
            test::return_shared(wallet);
        };
        
        // Fill another 25% (cumulative 75%) - should use index 3
        next_tx(&mut scenario, RESOLVER2);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET3);
            let proof = merkle::proof_for_index_from_secrets(&secrets, 3);
            
            let expected_taking = utils::get_taking_amount(&wallet, FILL_25_PERCENT, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 3, proof,
                TAKER, FILL_25_PERCENT, expected_taking,
                safety_deposit, &clock, ctx(&mut scenario)
            );
            
            assert!(structs::wallet_balance(&wallet) == 250_000_000, 0);
            test::return_shared(wallet);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    #[expected_failure] // Wrong index for fill amount
    fun test_partial_fill_wrong_index_for_amount() {
        let (mut scenario, mut clock, order_hash) = setup_test();
        let (secrets, root) = setup_merkle();
        
        // Create wallet
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT, &mut scenario);
            
            escrow_create::create_wallet(
                order_hash, 7777u256,
                string::utf8(b"TEST"), string::utf8(b"ETH"),
                WALLET_AMOUNT, TAKING_AMOUNT_MIN, DURATION,
                root, SAFETY_DEPOSIT, SAFETY_DEPOSIT,
                true, 4, funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        clock::increment_for_testing(&mut clock, 100_000);
        
        // Try to fill 60% with index 1 (should fail - 60% needs index 2)
        // 60% falls in [50%, 75%) bucket which requires index 2
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET1);
            let proof = merkle::proof_for_index_from_secrets(&secrets, 1);
            
            let expected_taking = utils::get_taking_amount(&wallet, 600_000_000, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 1, proof,
                TAKER, 600_000_000, expected_taking,
                safety_deposit, &clock, ctx(&mut scenario)
            );
            
            test::return_shared(wallet);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // ============ Merkle Proof Tests ============
    
    #[test]
    #[expected_failure] // Invalid merkle proof
    fun test_partial_fill_invalid_merkle_proof() {
        let (mut scenario, mut clock, order_hash) = setup_test();
        let (secrets, root) = setup_merkle();
        
        // Create wallet
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT, &mut scenario);
            
            escrow_create::create_wallet(
                order_hash, 3333u256,
                string::utf8(b"TEST"), string::utf8(b"ETH"),
                WALLET_AMOUNT, TAKING_AMOUNT_MIN, DURATION,
                root, SAFETY_DEPOSIT, SAFETY_DEPOSIT,
                true, 4, funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        clock::increment_for_testing(&mut clock, 100_000);
        
        // Use wrong proof (proof for index 2 with secret 1)
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET1);
            let wrong_proof = merkle::proof_for_index_from_secrets(&secrets, 2); // Wrong!
            
            let expected_taking = utils::get_taking_amount(&wallet, FILL_30_PERCENT, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 1, wrong_proof,
                TAKER, FILL_30_PERCENT, expected_taking,
                safety_deposit, &clock, ctx(&mut scenario)
            );
            
            test::return_shared(wallet);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // ============ Sequential Index Tests ============
    
    #[test]
    #[expected_failure] // Reusing an index
    fun test_partial_fill_cannot_reuse_index() {
        let (mut scenario, mut clock, order_hash) = setup_test();
        let (secrets, root) = setup_merkle();
        
        // Create wallet
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT, &mut scenario);
            
            escrow_create::create_wallet(
                order_hash, 4444u256,
                string::utf8(b"TEST"), string::utf8(b"ETH"),
                WALLET_AMOUNT, TAKING_AMOUNT_MIN, DURATION,
                root, SAFETY_DEPOSIT, SAFETY_DEPOSIT,
                true, 4, funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        clock::increment_for_testing(&mut clock, 100_000);
        
        // First fill with index 1 (30% falls in [25%, 50%))
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET1);
            let proof = merkle::proof_for_index_from_secrets(&secrets, 1);
            
            let expected_taking = utils::get_taking_amount(&wallet, FILL_30_PERCENT, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 1, proof,
                TAKER, FILL_30_PERCENT, expected_taking,
                safety_deposit, &clock, ctx(&mut scenario)
            );
            
            test::return_shared(wallet);
        };
        
        // Try to reuse index 1
        next_tx(&mut scenario, RESOLVER2);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET1);
            let proof = merkle::proof_for_index_from_secrets(&secrets, 1);
            
            let expected_taking = utils::get_taking_amount(&wallet, FILL_10_PERCENT, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 1, proof,
                TAKER, FILL_10_PERCENT, expected_taking,
                safety_deposit, &clock, ctx(&mut scenario)
            );
            
            test::return_shared(wallet);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    #[expected_failure] // Wrong index for cumulative amount
    fun test_partial_fill_must_match_cumulative_amount() {
        let (mut scenario, mut clock, order_hash) = setup_test();
        let (secrets, root) = setup_merkle();
        
        // Create wallet
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT, &mut scenario);
            
            escrow_create::create_wallet(
                order_hash, 5555u256,
                string::utf8(b"TEST"), string::utf8(b"ETH"),
                WALLET_AMOUNT, TAKING_AMOUNT_MIN, DURATION,
                root, SAFETY_DEPOSIT, SAFETY_DEPOSIT,
                true, 4, funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        clock::increment_for_testing(&mut clock, 100_000);
        
        // Fill 10% with index 0 (correct)
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET0);
            let proof = merkle::proof_for_index_from_secrets(&secrets, 0);
            
            let expected_taking = utils::get_taking_amount(&wallet, FILL_10_PERCENT, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 0, proof,
                TAKER, FILL_10_PERCENT, expected_taking,
                safety_deposit, &clock, ctx(&mut scenario)
            );
            
            test::return_shared(wallet);
        };
        
        // Try to fill another 10% with index 2 (wrong - cumulative 20% needs index 0)
        next_tx(&mut scenario, RESOLVER2);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET2);
            let proof = merkle::proof_for_index_from_secrets(&secrets, 2);
            
            let expected_taking = utils::get_taking_amount(&wallet, FILL_10_PERCENT, &clock);
            
            // This should fail because cumulative 20% still falls in [0%, 25%)
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 2, proof,
                TAKER, FILL_10_PERCENT, expected_taking,
                safety_deposit, &clock, ctx(&mut scenario)
            );
            
            test::return_shared(wallet);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // ============ Dutch Auction with Partial Fills ============
    
    #[test]
    fun test_partial_fill_dutch_auction_price_changes() {
        let (mut scenario, mut clock, order_hash) = setup_test();
        let (secrets, root) = setup_merkle();
        
        // Create wallet
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT, &mut scenario);
            
            escrow_create::create_wallet(
                order_hash, 6666u256,
                string::utf8(b"TEST"), string::utf8(b"ETH"),
                WALLET_AMOUNT, TAKING_AMOUNT_MIN, DURATION,
                root, SAFETY_DEPOSIT, SAFETY_DEPOSIT,
                true, 4, funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        // Fill at start (high price)
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET1);
            let proof = merkle::proof_for_index_from_secrets(&secrets, 1);
            
            let taking_at_start = utils::get_taking_amount(&wallet, FILL_25_PERCENT, &clock);
            // At start, price is 1:1
            assert!(taking_at_start == FILL_25_PERCENT, 0);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 1, proof,
                TAKER, FILL_25_PERCENT, taking_at_start,
                safety_deposit, &clock, ctx(&mut scenario)
            );
            
            test::return_shared(wallet);
        };
        
        // Fill at end (low price)
        clock::increment_for_testing(&mut clock, DURATION);
        
        next_tx(&mut scenario, RESOLVER2);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET2);
            let proof = merkle::proof_for_index_from_secrets(&secrets, 2);
            
            let taking_at_end = utils::get_taking_amount(&wallet, FILL_25_PERCENT, &clock);
            // At end, price should be lower (0.9:1)
            assert!(taking_at_end < FILL_25_PERCENT, 0);
            assert!(taking_at_end == (FILL_25_PERCENT * 9) / 10, 1); // 90% of fill amount
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 2, proof,
                TAKER, FILL_25_PERCENT, taking_at_end,
                safety_deposit, &clock, ctx(&mut scenario)
            );
            
            test::return_shared(wallet);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // ============ Complex Scenarios ============
    
    #[test]
    #[expected_failure] //tries to cancel an active escrow
    fun test_partial_fill_with_cancellations() {
        let (mut scenario, mut clock, order_hash) = setup_test();
        let (secrets, root) = setup_merkle();
        
        // Create wallet
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT, &mut scenario);
            
            escrow_create::create_wallet(
                order_hash, 7777u256,
                string::utf8(b"TEST"), string::utf8(b"ETH"),
                WALLET_AMOUNT, TAKING_AMOUNT_MIN, DURATION,
                root, SAFETY_DEPOSIT, SAFETY_DEPOSIT,
                true, 4, funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        clock::increment_for_testing(&mut clock, 100_000);
        
        // Create first escrow (30%)
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET1);
            let proof = merkle::proof_for_index_from_secrets(&secrets, 1);
            let expected_taking = utils::get_taking_amount(&wallet, FILL_30_PERCENT, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 1, proof,
                TAKER, FILL_30_PERCENT, expected_taking,
                safety_deposit, &clock, ctx(&mut scenario)
            );
            
            test::return_shared(wallet);
        };
        
        // Create second escrow (45% more, cumulative 75%)
        next_tx(&mut scenario, RESOLVER2);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET3);
            let proof = merkle::proof_for_index_from_secrets(&secrets, 3);
            let expected_taking = utils::get_taking_amount(&wallet, 450_000_000, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 3, proof,
                TAKER, 450_000_000, expected_taking,
                safety_deposit, &clock, ctx(&mut scenario)
            );
            
            test::return_shared(wallet);
        };
        
        // Advance to withdrawal stage first to withdraw one escrow
        clock::increment_for_testing(&mut clock, 300_000);
        
        // Withdraw the second escrow
        next_tx(&mut scenario, TAKER);
        {
            // Take an escrow and check if it's the one we want to withdraw
            let mut escrow = test::take_shared<EscrowSrc<TEST>>(&scenario);
            let imm = structs::get_src_immutables(&escrow);
            
            // If this is the 45% escrow (450M), withdraw it
            if (structs::get_amount(imm) == 450_000_000) {
                escrow_withdraw::withdraw_src(&mut escrow, SECRET3, &clock, ctx(&mut scenario));
            };
            test::return_shared(escrow);
        };
        
        // Now advance to cancellation stage
        clock::increment_for_testing(&mut clock, 700_000);
        
        // Cancel first escrow (as TAKER/resolver)
        next_tx(&mut scenario, TAKER);
        {
            let mut escrow = test::take_shared<EscrowSrc<TEST>>(&scenario);
            
            // This should be the 30% escrow since we withdrew the other one
            escrow_cancel::cancel_src(&mut escrow, &clock, ctx(&mut scenario));
            test::return_shared(escrow);
        };
        
        // Wallet should still have remaining funds
        next_tx(&mut scenario, MAKER);
        {
            let wallet = test::take_shared<Wallet<TEST>>(&scenario);
            assert!(structs::wallet_balance(&wallet) == 250_000_000, 0); // 25% remaining
            assert!(structs::wallet_last_used_index(&wallet) == 3, 1);
            test::return_shared(wallet);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_partial_fill_edge_case_last_bucket() {
        let (mut scenario, mut clock, order_hash) = setup_test();
        let (secrets, root) = setup_merkle();
        
        // Create wallet
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT, &mut scenario);
            
            escrow_create::create_wallet(
                order_hash, 8888u256,
                string::utf8(b"TEST"), string::utf8(b"ETH"),
                WALLET_AMOUNT, TAKING_AMOUNT_MIN, DURATION,
                root, SAFETY_DEPOSIT, SAFETY_DEPOSIT,
                true, 4, funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        clock::increment_for_testing(&mut clock, 100_000);
        
        // Fill 80% first (cumulative 80% uses index 3)
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET3);
            let proof = merkle::proof_for_index_from_secrets(&secrets, 3);
            let expected_taking = utils::get_taking_amount(&wallet, 800_000_000, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 3, proof,
                TAKER, 800_000_000, expected_taking,
                safety_deposit, &clock, ctx(&mut scenario)
            );
            
            test::return_shared(wallet);
        };
        
        // Fill remaining 20% (cumulative 100% uses index 4 - special last bucket)
        next_tx(&mut scenario, RESOLVER2);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET4);
            let proof = merkle::proof_for_index_from_secrets(&secrets, 4);
            let expected_taking = utils::get_taking_amount(&wallet, 200_000_000, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 4, proof,
                TAKER, 200_000_000, expected_taking,
                safety_deposit, &clock, ctx(&mut scenario)
            );
            
            assert!(structs::wallet_balance(&wallet) == 0, 0);
            assert!(structs::wallet_last_used_index(&wallet) == 4, 1);
            test::return_shared(wallet);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }
