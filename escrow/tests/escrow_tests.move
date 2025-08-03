#[test_only]
#[allow(unused_variable, implicit_const_copy)]

module escrow::escrow_tests;

    use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::hash;
    use std::string;
 
    use escrow::escrow_create;
    use escrow::escrow_withdraw;
    use escrow::escrow_cancel;
    use escrow::escrow_rescue;
    use escrow::structs::{Self, Wallet, EscrowSrc, EscrowDst};
    use escrow::utils;
    use escrow::constants;
    use escrow::merkle_utils_testonly as merkle;
    use escrow::structs::wallet_balance;

    
    // Test addresses
    const MAKER: address = @0xA;
    const TAKER: address = @0xB; 
    const RESOLVER1: address = @0xC;
    const RESOLVER2: address = @0xD;
    const ANYONE: address = @0xE;
    
    // Test amounts
    const WALLET_AMOUNT_FULL_FILL: u64 = 1_000_000_000; // 1 TOKEN
    const TAKING_AMOUNT_FULL_FILL: u64 = 900_000_000;  // 0.9 TOKEN (Minimum acceptable amount)
    const RESOLVER_TAKING_AMOUNT_FULL_FILL: u64 = 999_000_000; //0.999 TOKEN is being filled by resolver
    const SAFETY_DEPOSIT_FULL_FILL: u64 = 100_000_000;   // 0.1 SUI
    
    // Test amounts
    const WALLET_AMOUNT_PARTIAL_FILL: u64 = 1_000_000_000; // 1 TOKEN
    const ESCROW_AMOUNT_PARTIAL_FILL: u64 = 400_000_000;  // 0.4 TOKEN how much resolver wants to fill
    const TAKING_AMOUNT_PARTIAL_FILL: u64 = 900_000_000;  // 0.9 tokens (Minimum acceptable amount)
    const SAFETY_DEPOSIT_PARTIAL_FILL: u64 = 40_000_000;   // 0.04 SUI
    //test duration
    const DURATION: u64 = 3_600_000; // 1 hour in ms

    // Test secrets for partial fills: 4 part order
    const SECRET0: vector<u8> = b"secret0_32_bytes_long_0000000000";
    const SECRET1: vector<u8> = b"secret1_32_bytes_long_1111111111";
    const SECRET2: vector<u8> = b"secret2_32_bytes_long_2222222222";
    const SECRET3: vector<u8> = b"secret3_32_bytes_long_3333333333";
    const SECRET4: vector<u8> = b"secret3_32_bytes_long_4444444444";


    // Test token
    public struct TEST has drop {}
    
    // Helper functions
    fun setup_test(): (Scenario, Clock, vector<u8>, vector<u8>) {
        let mut scenario = test::begin(MAKER);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        let order_hash = b"order_hash_32_bytes_long_1234567";
        // secrets in test
        let secrets = vector[
            SECRET0, SECRET1, SECRET2, SECRET3, SECRET4
        ];

        // compute root/proof
        let root = merkle::root_from_secrets(&secrets);
        let proof1 = merkle::proof_for_index_from_secrets(&secrets, 1);
        let leaf1 = merkle::leaf(&SECRET1);

        // assert verifies with your prod function or the helper's `verify`
        assert!(merkle::verify(&leaf1, &proof1, &root), 0);

        (scenario, clock, order_hash, root)
        
    }
    
    fun mint_test(amount: u64, scenario: &mut Scenario): Coin<TEST> {
        coin::mint_for_testing<TEST>(amount, ctx(scenario))
    }

    fun mint_sui(amount: u64, scenario: &mut Scenario): Coin<SUI> {
        coin::mint_for_testing<SUI>(amount, ctx(scenario))
    }
    
    // ============ Wallet Tests ============
    
    #[test]
    fun test_create_wallet_full_fill() {
        let (mut scenario, clock, order_hash, root) = setup_test();
        
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT_FULL_FILL, &mut scenario);
            let hashlock = hash::keccak256(&SECRET0); // Single secret for full fill
            
            escrow_create::create_wallet(
                order_hash,
                1234567890u256, // salt
                string::utf8(b"TEST"),
                string::utf8(b"ETH"),
                WALLET_AMOUNT_FULL_FILL,
                TAKING_AMOUNT_FULL_FILL,
                DURATION,
                hashlock,
                SAFETY_DEPOSIT_FULL_FILL,
                SAFETY_DEPOSIT_FULL_FILL,
                false, // No partial fills
                0,     // parts_amount = 0 for full fill
                funding,
                // Timelocks (relative times in ms)
                300_000,   // src_withdrawal
                600_000,   // src_public_withdrawal
                900_000,   // src_cancellation
                1_200_000, // src_public_cancellation
                250_000,   // dst_withdrawal
                550_000,   // dst_public_withdrawal
                850_000,   // dst_cancellation
                &clock,
                ctx(&mut scenario)
            );
        };
        
        // Verify wallet
        next_tx(&mut scenario, MAKER);
        {
            let wallet = test::take_shared<Wallet<TEST>>(&scenario);
            assert!(structs::wallet_order_hash(&wallet) == &order_hash, 0);
            assert!(structs::wallet_maker(&wallet) == MAKER, 1);
            assert!(structs::wallet_making_amount(&wallet) == WALLET_AMOUNT_FULL_FILL, 2);
            assert!(structs::wallet_taking_amount(&wallet) == TAKING_AMOUNT_FULL_FILL, 3);
            assert!(structs::wallet_duration(&wallet) == DURATION, 4);
            assert!(structs::wallet_allow_partial_fills(&wallet) == false, 5);
            assert!(structs::wallet_is_active(&wallet), 6);
            test::return_shared(wallet);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }
    
    #[test]
    fun test_create_wallet_partial_fills() {
        let (mut scenario, clock, order_hash,root) = setup_test();
        
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT_PARTIAL_FILL, &mut scenario);
            
            escrow_create::create_wallet(
                order_hash,
                9876543210u256,
                string::utf8(b"TEST"),
                string::utf8(b"ETH"),
                WALLET_AMOUNT_PARTIAL_FILL,
                TAKING_AMOUNT_PARTIAL_FILL,
                DURATION,
                root,
                SAFETY_DEPOSIT_PARTIAL_FILL,
                SAFETY_DEPOSIT_PARTIAL_FILL,
                true,  // Allow partial fills
                4,     // 4 parts (5 secrets 0-4)
                funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock,
                ctx(&mut scenario)
            );
        };
        
        // Verify wallet
        next_tx(&mut scenario, MAKER);
        {
            let wallet = test::take_shared<Wallet<TEST>>(&scenario);
            assert!(structs::wallet_allow_partial_fills(&wallet) == true, 0);
            assert!(structs::wallet_parts_amount(&wallet) == 4, 1);
            assert!(structs::wallet_last_used_index(&wallet) == 255, 2);
            test::return_shared(wallet);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // ============ Source Escrow Tests ============
    
    #[test]
    fun test_create_src_escrow_full_fill() {
        let (mut scenario, mut clock, order_hash, root) = setup_test();
        
        // Create wallet
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT_FULL_FILL, &mut scenario);
            let hashlock = hash::keccak256(&SECRET0);
            
            escrow_create::create_wallet(
                order_hash,
                1234u256,
                string::utf8(b"TEST"),
                string::utf8(b"ETH"),
                WALLET_AMOUNT_FULL_FILL,
                TAKING_AMOUNT_FULL_FILL,
                DURATION,
                hashlock,
                SAFETY_DEPOSIT_FULL_FILL,
                SAFETY_DEPOSIT_FULL_FILL,
                false, 
                0,
                funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock,
                ctx(&mut scenario)
            );
        };
        clock::increment_for_testing(&mut clock, 1_600_000); // +1 hour
        // Create source escrow (full fill)
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT_FULL_FILL, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET0);
            
            escrow_create::create_escrow_src(
                &mut wallet,
                secret_hashlock,
                0, // secret_index for full fill
                vector::empty<vector<u8>>(), // No merkle proof for full fill
                TAKER,
                WALLET_AMOUNT_FULL_FILL, // Full amount
                RESOLVER_TAKING_AMOUNT_FULL_FILL,
                safety_deposit,
                &clock,
                ctx(&mut scenario)
            );
            
            // Wallet balance should be zero
            assert!(structs::wallet_balance(&wallet) == 0, 0);
            test::return_shared(wallet);
        };
        
        // Verify escrow
        next_tx(&mut scenario, RESOLVER1);
        {
            let escrow = test::take_shared<EscrowSrc<TEST>>(&scenario);
            let imm = structs::get_src_immutables(&escrow);
            
            assert!(structs::get_maker(imm) == MAKER, 0);
            assert!(structs::get_taker(imm) == TAKER, 1);
            assert!(structs::get_amount(imm) == WALLET_AMOUNT_FULL_FILL, 2);
            assert!(structs::get_src_status(&escrow) == constants::status_active(), 3);
            
            test::return_shared(escrow);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }
    
    #[test]
    #[expected_failure] //fails the dutch auction price 
    fun test_create_src_escrow_full_fill_no_clock_tick() {
        let (mut scenario, mut clock, order_hash, root) = setup_test();
        
        // Create wallet
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT_FULL_FILL, &mut scenario);
            let hashlock = hash::keccak256(&SECRET0);
            
            escrow_create::create_wallet(
                order_hash,
                1234u256,
                string::utf8(b"TEST"),
                string::utf8(b"ETH"),
                WALLET_AMOUNT_FULL_FILL,
                TAKING_AMOUNT_FULL_FILL,
                DURATION,
                hashlock,
                SAFETY_DEPOSIT_FULL_FILL,
                SAFETY_DEPOSIT_FULL_FILL,
                false, 
                0,
                funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock,
                ctx(&mut scenario)
            );
        };
        // Create source escrow (full fill)
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT_FULL_FILL, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET0);
            
            escrow_create::create_escrow_src(
                &mut wallet,
                secret_hashlock,
                0, // secret_index for full fill
                vector::empty<vector<u8>>(), // No merkle proof for full fill
                TAKER,
                WALLET_AMOUNT_FULL_FILL, // Full amount
                RESOLVER_TAKING_AMOUNT_FULL_FILL,
                safety_deposit,
                &clock,
                ctx(&mut scenario)
            );
            
            // Wallet balance should be zero
            assert!(structs::wallet_balance(&wallet) == 0, 0);
            test::return_shared(wallet);
        };
        
        // Verify escrow
        next_tx(&mut scenario, RESOLVER1);
        {
            let escrow = test::take_shared<EscrowSrc<TEST>>(&scenario);
            let imm = structs::get_src_immutables(&escrow);
            
            assert!(structs::get_maker(imm) == MAKER, 0);
            assert!(structs::get_taker(imm) == TAKER, 1);
            assert!(structs::get_amount(imm) == WALLET_AMOUNT_FULL_FILL, 2);
            assert!(structs::get_src_status(&escrow) == constants::status_active(), 3);
            
            test::return_shared(escrow);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }


    #[test] //correct indices and partial fill amounts
    fun test_create_src_escrow_partial_fills() {
        let (mut scenario, mut clock, order_hash, root) = setup_test();
        
        // Create wallet with partial fills
        //order divided into 4
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT_PARTIAL_FILL, &mut scenario);
            let secrets = vector[SECRET0, SECRET1, SECRET2, SECRET3, SECRET4];
            
            escrow_create::create_wallet(
                order_hash,
                5678u256,
                string::utf8(b"TEST"),
                string::utf8(b"ETH"),
                WALLET_AMOUNT_PARTIAL_FILL,
                TAKING_AMOUNT_PARTIAL_FILL,
                DURATION,
                root,
                SAFETY_DEPOSIT_PARTIAL_FILL,
                SAFETY_DEPOSIT_PARTIAL_FILL,
                true, 4,
                funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock,
                ctx(&mut scenario)
            );
        };
        
        // First partial fill (40%)
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT_PARTIAL_FILL, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET1);
            // compute root/proof
            let secrets = vector[SECRET0, SECRET1, SECRET2, SECRET3, SECRET4];
            let root = merkle::root_from_secrets(&secrets);
            let proof1 = merkle::proof_for_index_from_secrets(&secrets, 1);
            let leaf1 = merkle::leaf(&SECRET1);


        // assert verifies with your prod function or the helper's `verify`
        assert!(merkle::verify(&leaf1, &proof1, &root), 0);            
            // Calculate expected taking amount for dutch auction
            let expected_taking = utils::get_taking_amount(&wallet, 400_000_000, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet,
                secret_hashlock,
                1, // Using secret index 1
                proof1,
                TAKER,
                400_000_000, // 40% of wallet
                expected_taking,
                safety_deposit,
                &clock,
                ctx(&mut scenario)
            );
            
            // Wallet should still be active
            assert!(structs::wallet_is_active(&wallet), 0);
            assert!(structs::wallet_last_used_index(&wallet) == 1, 1);
            assert!(structs::wallet_balance(&wallet) == 600_000_000, 2);
            
            test::return_shared(wallet);
        };
        
        // Second partial fill (50% of remaining)
        clock::increment_for_testing(&mut clock, 1_800_000); // Advance 30 min
        
        next_tx(&mut scenario, RESOLVER2);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT_PARTIAL_FILL, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET3);
            // compute root/proof
            let secrets = vector[SECRET0, SECRET1, SECRET2, SECRET3, SECRET4];
            let root = merkle::root_from_secrets(&secrets);
            let proof3 = merkle::proof_for_index_from_secrets(&secrets, 3);
            let leaf2 = merkle::leaf(&SECRET2);

            // Price should be lower due to dutch auction
            let expected_taking = utils::get_taking_amount(&wallet, 500_000_000, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet,
                secret_hashlock,
                3, // Using secret index 2
                proof3,
                TAKER,
                500_000_000,
                expected_taking,
                safety_deposit,
                &clock,
                ctx(&mut scenario)
            );
            
            assert!(structs::wallet_last_used_index(&wallet) == 3, 0);
            assert!(structs::wallet_balance(&wallet) == 100_000_000, 1);
            
            test::return_shared(wallet);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test] //incorrect indices and partial fill amounts
    #[expected_failure]
    fun test_create_src_escrow_partial_fills_incorrect_indice() {
        let (mut scenario, mut clock, order_hash, root) = setup_test();
        
        // Create wallet with partial fills
        //order divided into 4
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT_PARTIAL_FILL, &mut scenario);
            let secrets = vector[SECRET0, SECRET1, SECRET2, SECRET3, SECRET4];
            
            escrow_create::create_wallet(
                order_hash,
                5678u256,
                string::utf8(b"TEST"),
                string::utf8(b"ETH"),
                WALLET_AMOUNT_PARTIAL_FILL,
                TAKING_AMOUNT_PARTIAL_FILL,
                DURATION,
                root,
                SAFETY_DEPOSIT_PARTIAL_FILL,
                SAFETY_DEPOSIT_PARTIAL_FILL,
                true, 4,
                funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock,
                ctx(&mut scenario)
            );
        };
        
        // First partial fill (40%)
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT_PARTIAL_FILL, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET1);
            // compute root/proof
            let secrets = vector[SECRET0, SECRET1, SECRET2, SECRET3, SECRET4];
            let root = merkle::root_from_secrets(&secrets);
            let proof1 = merkle::proof_for_index_from_secrets(&secrets, 1);
            let leaf1 = merkle::leaf(&SECRET1);


        // assert verifies with your prod function or the helper's `verify`
        assert!(merkle::verify(&leaf1, &proof1, &root), 0);            
            // Calculate expected taking amount for dutch auction
            let expected_taking = utils::get_taking_amount(&wallet, 400_000_000, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet,
                secret_hashlock,
                1, // Using secret index 1
                proof1,
                TAKER,
                400_000_000, // 40% of wallet
                expected_taking,
                safety_deposit,
                &clock,
                ctx(&mut scenario)
            );
            
            // Wallet should still be active
            assert!(structs::wallet_is_active(&wallet), 0);
            assert!(structs::wallet_last_used_index(&wallet) == 1, 1);
            assert!(structs::wallet_balance(&wallet) == 600_000_000, 2);
            
            test::return_shared(wallet);
        };
        
        // Second partial fill (50% of remaining)
        clock::increment_for_testing(&mut clock, 1_800_000); // Advance 30 min
        
        next_tx(&mut scenario, RESOLVER2);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT_PARTIAL_FILL, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET2);
            // compute root/proof
            let secrets = vector[SECRET0, SECRET1, SECRET2, SECRET3, SECRET4];
            let proof2 = merkle::proof_for_index_from_secrets(&secrets, 2);

            // Price should be lower due to dutch auction
            let expected_taking = utils::get_taking_amount(&wallet, 500_000_000, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet,
                secret_hashlock,
                2, // Using secret index 2
                proof2,
                TAKER,
                500_000_000,
                expected_taking,
                safety_deposit,
                &clock,
                ctx(&mut scenario)
            );
            
            assert!(structs::wallet_last_used_index(&wallet) == 2, 0);
            assert!(structs::wallet_balance(&wallet) == 100_000_000, 1);
            
            test::return_shared(wallet);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // ============ Destination Escrow Tests (Full Fill) ============
    
    #[test]
    fun test_create_dst_escrow_full_fill() {
        let (mut scenario, clock, order_hash, _) = setup_test();
        
        // Create destination escrow directly (taker deposits)
        next_tx(&mut scenario, TAKER);
        {
            let token_deposit = mint_test(WALLET_AMOUNT_FULL_FILL, &mut scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT_FULL_FILL, &mut scenario);
            let hashlock = hash::keccak256(&SECRET0);
            
            escrow_create::create_escrow_dst(
                order_hash,
                hashlock,
                MAKER,
                token_deposit,
                safety_deposit,
                // Timelocks
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock,
                ctx(&mut scenario)
            );
        };
        
        // Verify escrow
        next_tx(&mut scenario, TAKER);
        {
            let escrow = test::take_shared<EscrowDst<TEST>>(&scenario);
            let imm = structs::get_dst_immutables(&escrow);
            
            assert!(structs::get_maker(imm) == MAKER, 0);
            assert!(structs::get_taker(imm) == TAKER, 1);
            assert!(structs::get_amount(imm) == WALLET_AMOUNT_FULL_FILL, 2);
            assert!(structs::get_dst_status(&escrow) == constants::status_active(), 3);
            
            test::return_shared(escrow);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // ============ Withdrawal Tests (Full Fill) ============
    
    #[test]
    fun test_withdraw_src_resolver_exclusive() {
        let (mut scenario, mut clock, order_hash, _) = setup_test();
        
        // Setup: Create wallet and escrow
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT_FULL_FILL, &mut scenario);
            let hashlock = hash::keccak256(&SECRET0);
            
            escrow_create::create_wallet(
                order_hash, 1234u256,
                string::utf8(b"TEST"), string::utf8(b"ETH"),
                WALLET_AMOUNT_FULL_FILL, TAKING_AMOUNT_FULL_FILL,
                DURATION, hashlock,
                SAFETY_DEPOSIT_FULL_FILL, SAFETY_DEPOSIT_FULL_FILL,
                false, 0, funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        clock::increment_for_testing(&mut clock, 100_000); // Advance time for dutch auction
        
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT_FULL_FILL, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET0);
            let expected_taking = utils::get_taking_amount(&wallet, WALLET_AMOUNT_FULL_FILL, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 0,
                vector::empty<vector<u8>>(),
                TAKER, WALLET_AMOUNT_FULL_FILL,
                expected_taking, safety_deposit,
                &clock, ctx(&mut scenario)
            );
            test::return_shared(wallet);
        };
        
        // Advance to resolver exclusive withdrawal stage
        clock::increment_for_testing(&mut clock, 300_000);
        
        // Withdraw by resolver (TAKER)
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
    fun test_withdraw_src_public_stage() {
        let (mut scenario, mut clock, order_hash, _) = setup_test();
        
        // Setup: Create wallet and escrow
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT_FULL_FILL, &mut scenario);
            let hashlock = hash::keccak256(&SECRET0);
            
            escrow_create::create_wallet(
                order_hash, 1234u256,
                string::utf8(b"TEST"), string::utf8(b"ETH"),
                WALLET_AMOUNT_FULL_FILL, TAKING_AMOUNT_FULL_FILL,
                DURATION, hashlock,
                SAFETY_DEPOSIT_FULL_FILL, SAFETY_DEPOSIT_FULL_FILL,
                false, 0, funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        clock::increment_for_testing(&mut clock, 100_000);
        
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT_FULL_FILL, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET0);
            let expected_taking = utils::get_taking_amount(&wallet, WALLET_AMOUNT_FULL_FILL, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 0,
                vector::empty<vector<u8>>(),
                TAKER, WALLET_AMOUNT_FULL_FILL,
                expected_taking, safety_deposit,
                &clock, ctx(&mut scenario)
            );
            test::return_shared(wallet);
        };
        
        // Advance to public withdrawal stage
        clock::increment_for_testing(&mut clock, 700_000);
        
        // Withdraw by anyone
        next_tx(&mut scenario, ANYONE);
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
    #[expected_failure] // Wrong secret
    fun test_withdraw_src_wrong_secret() {
        let (mut scenario, mut clock, order_hash, _) = setup_test();
        
        // Setup escrow
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT_FULL_FILL, &mut scenario);
            let hashlock = hash::keccak256(&SECRET0);
            
            escrow_create::create_wallet(
                order_hash, 1234u256,
                string::utf8(b"TEST"), string::utf8(b"ETH"),
                WALLET_AMOUNT_FULL_FILL, TAKING_AMOUNT_FULL_FILL,
                DURATION, hashlock,
                SAFETY_DEPOSIT_FULL_FILL, SAFETY_DEPOSIT_FULL_FILL,
                false, 0, funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        clock::increment_for_testing(&mut clock, 100_000);
        
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT_FULL_FILL, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET0);
            let expected_taking = utils::get_taking_amount(&wallet, WALLET_AMOUNT_FULL_FILL, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 0,
                vector::empty<vector<u8>>(),
                TAKER, WALLET_AMOUNT_FULL_FILL,
                expected_taking, safety_deposit,
                &clock, ctx(&mut scenario)
            );
            test::return_shared(wallet);
        };
        
        clock::increment_for_testing(&mut clock, 300_000);
        
        // Try to withdraw with wrong secret
        next_tx(&mut scenario, TAKER);
        {
            let mut escrow = test::take_shared<EscrowSrc<TEST>>(&scenario);
            
            escrow_withdraw::withdraw_src(
                &mut escrow,
                SECRET1, // Wrong secret!
                &clock,
                ctx(&mut scenario)
            );
            
            test::return_shared(escrow);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_withdraw_dst_resolver_exclusive() {
        let (mut scenario, mut clock, order_hash, _) = setup_test();
        
        // Create destination escrow
        next_tx(&mut scenario, TAKER);
        {
            let token_deposit = mint_test(WALLET_AMOUNT_FULL_FILL, &mut scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT_FULL_FILL, &mut scenario);
            let hashlock = hash::keccak256(&SECRET0);
            
            escrow_create::create_escrow_dst(
                order_hash, hashlock, MAKER,
                token_deposit, safety_deposit,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        // Advance to resolver exclusive withdrawal
        clock::increment_for_testing(&mut clock, 250_000);
        
        // Withdraw by resolver
        next_tx(&mut scenario, TAKER);
        {
            let mut escrow = test::take_shared<EscrowDst<TEST>>(&scenario);
            
            escrow_withdraw::withdraw_dst(
                &mut escrow,
                SECRET0,
                &clock,
                ctx(&mut scenario)
            );
            
            assert!(structs::get_dst_status(&escrow) == constants::status_withdrawn(), 0);
            test::return_shared(escrow);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // ============ Cancellation Tests (Full Fill) ============
    
    #[test]
    fun test_cancel_src_resolver_exclusive() {
        let (mut scenario, mut clock, order_hash, _) = setup_test();
        
        // Setup escrow
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT_FULL_FILL, &mut scenario);
            let hashlock = hash::keccak256(&SECRET0);
            
            escrow_create::create_wallet(
                order_hash, 1234u256,
                string::utf8(b"TEST"), string::utf8(b"ETH"),
                WALLET_AMOUNT_FULL_FILL, TAKING_AMOUNT_FULL_FILL,
                DURATION, hashlock,
                SAFETY_DEPOSIT_FULL_FILL, SAFETY_DEPOSIT_FULL_FILL,
                false, 0, funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        clock::increment_for_testing(&mut clock, 100_000);
        
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT_FULL_FILL, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET0);
            let expected_taking = utils::get_taking_amount(&wallet, WALLET_AMOUNT_FULL_FILL, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 0,
                vector::empty<vector<u8>>(),
                TAKER, WALLET_AMOUNT_FULL_FILL,
                expected_taking, safety_deposit,
                &clock, ctx(&mut scenario)
            );
            test::return_shared(wallet);
        };
        
        // Advance to resolver exclusive cancel stage
        clock::increment_for_testing(&mut clock, 900_000);
        
        // Cancel by resolver
        next_tx(&mut scenario, TAKER);
        {
            let mut escrow = test::take_shared<EscrowSrc<TEST>>(&scenario);
            
            escrow_cancel::cancel_src(
                &mut escrow,
                &clock,
                ctx(&mut scenario)
            );
            
            assert!(structs::get_src_status(&escrow) == constants::status_cancelled(), 0);
            test::return_shared(escrow);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_cancel_src_public_stage() {
        let (mut scenario, mut clock, order_hash, _) = setup_test();
        
        // Setup escrow
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT_FULL_FILL, &mut scenario);
            let hashlock = hash::keccak256(&SECRET0);
            
            escrow_create::create_wallet(
                order_hash, 1234u256,
                string::utf8(b"TEST"), string::utf8(b"ETH"),
                WALLET_AMOUNT_FULL_FILL, TAKING_AMOUNT_FULL_FILL,
                DURATION, hashlock,
                SAFETY_DEPOSIT_FULL_FILL, SAFETY_DEPOSIT_FULL_FILL,
                false, 0, funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        clock::increment_for_testing(&mut clock, 100_000);
        
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT_FULL_FILL, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET0);
            let expected_taking = utils::get_taking_amount(&wallet, WALLET_AMOUNT_FULL_FILL, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 0,
                vector::empty<vector<u8>>(),
                TAKER, WALLET_AMOUNT_FULL_FILL,
                expected_taking, safety_deposit,
                &clock, ctx(&mut scenario)
            );
            test::return_shared(wallet);
        };
        
        // Advance to public cancel stage
        clock::increment_for_testing(&mut clock, 1_200_000);
        
        // Cancel by anyone
        next_tx(&mut scenario, ANYONE);
        {
            let mut escrow = test::take_shared<EscrowSrc<TEST>>(&scenario);
            
            escrow_cancel::cancel_src(
                &mut escrow,
                &clock,
                ctx(&mut scenario)
            );
            
            assert!(structs::get_src_status(&escrow) == constants::status_cancelled(), 0);
            test::return_shared(escrow);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_cancel_dst() {
        let (mut scenario, mut clock, order_hash, _) = setup_test();
        
        // Create destination escrow
        next_tx(&mut scenario, TAKER);
        {
            let token_deposit = mint_test(WALLET_AMOUNT_FULL_FILL, &mut scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT_FULL_FILL, &mut scenario);
            let hashlock = hash::keccak256(&SECRET0);
            
            escrow_create::create_escrow_dst(
                order_hash, hashlock, MAKER,
                token_deposit, safety_deposit,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        // Advance to cancellation stage
        clock::increment_for_testing(&mut clock, 850_000);
        
        // Cancel by resolver
        next_tx(&mut scenario, TAKER);
        {
            let mut escrow = test::take_shared<EscrowDst<TEST>>(&scenario);
            
            escrow_cancel::cancel_dst(
                &mut escrow,
                &clock,
                ctx(&mut scenario)
            );
            
            assert!(structs::get_dst_status(&escrow) == constants::status_cancelled(), 0);
            test::return_shared(escrow);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // ============ Rescue Tests (Full Fill) ============
    
    #[test]
    fun test_rescue_wallet() {
        let (mut scenario, mut clock, order_hash, _) = setup_test();
        
        // Create wallet
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT_FULL_FILL, &mut scenario);
            let hashlock = hash::keccak256(&SECRET0);
            
            escrow_create::create_wallet(
                order_hash, 1234u256,
                string::utf8(b"TEST"), string::utf8(b"ETH"),
                WALLET_AMOUNT_FULL_FILL, TAKING_AMOUNT_FULL_FILL,
                DURATION, hashlock,
                SAFETY_DEPOSIT_FULL_FILL, SAFETY_DEPOSIT_FULL_FILL,
                false, 0, funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        // Advance past all timelocks + rescue delay
        clock::increment_for_testing(&mut clock, 1_200_000 + constants::rescue_delay_period());
        
        // Rescue by anyone
        next_tx(&mut scenario, ANYONE);
        {
            let wallet = test::take_shared<Wallet<TEST>>(&scenario);
            
            escrow_rescue::rescue_wallet(
                wallet,
                &clock,
                ctx(&mut scenario)
            );
        };
        
        // Verify wallet no longer exists
        next_tx(&mut scenario, MAKER);
        {
            assert!(!test::has_most_recent_shared<Wallet<TEST>>(), 0);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_rescue_src_escrow() {
        let (mut scenario, mut clock, order_hash, _) = setup_test();
        
        // Setup escrow
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT_FULL_FILL, &mut scenario);
            let hashlock = hash::keccak256(&SECRET0);
            
            escrow_create::create_wallet(
                order_hash, 1234u256,
                string::utf8(b"TEST"), string::utf8(b"ETH"),
                WALLET_AMOUNT_FULL_FILL, TAKING_AMOUNT_FULL_FILL,
                DURATION, hashlock,
                SAFETY_DEPOSIT_FULL_FILL, SAFETY_DEPOSIT_FULL_FILL,
                false, 0, funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        clock::increment_for_testing(&mut clock, 100_000);
        
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT_FULL_FILL, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET0);
            let expected_taking = utils::get_taking_amount(&wallet, WALLET_AMOUNT_FULL_FILL, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 0,
                vector::empty<vector<u8>>(),
                TAKER, WALLET_AMOUNT_FULL_FILL,
                expected_taking, safety_deposit,
                &clock, ctx(&mut scenario)
            );
            test::return_shared(wallet);
        };
        
        // Advance past all timelocks + rescue delay
        clock::increment_for_testing(&mut clock, 1_200_000 + constants::rescue_delay_period());
        
        // Rescue escrow
        next_tx(&mut scenario, ANYONE);
        {
            let escrow = test::take_shared<EscrowSrc<TEST>>(&scenario);
            
            escrow_rescue::rescue_src(
                escrow,
                &clock,
                ctx(&mut scenario)
            );
        };
        
        // Verify escrow no longer exists
        next_tx(&mut scenario, MAKER);
        {
            assert!(!test::has_most_recent_shared<EscrowSrc<TEST>>(), 0);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // ============ Dutch Auction Tests (Full Fill) ============
    
    #[test]
    fun test_dutch_auction_price_decay() {
        let (mut scenario, mut clock, order_hash, _) = setup_test();
        
        // Create wallet
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT_FULL_FILL, &mut scenario);
            let hashlock = hash::keccak256(&SECRET0);
            
            escrow_create::create_wallet(
                order_hash, 1234u256,
                string::utf8(b"TEST"), string::utf8(b"ETH"),
                WALLET_AMOUNT_FULL_FILL, TAKING_AMOUNT_FULL_FILL,
                DURATION, hashlock,
                SAFETY_DEPOSIT_FULL_FILL, SAFETY_DEPOSIT_FULL_FILL,
                false, 0, funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        // Test price at start (should be maximum)
        next_tx(&mut scenario, RESOLVER1);
        {
            let wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let taking_at_start = utils::get_taking_amount(&wallet, WALLET_AMOUNT_FULL_FILL, &clock);
            assert!(taking_at_start == WALLET_AMOUNT_FULL_FILL, 0); // 1:1 at start
            test::return_shared(wallet);
        };
        
        // Test price at half duration
        clock::increment_for_testing(&mut clock, DURATION / 2);
        next_tx(&mut scenario, RESOLVER1);
        {
            let wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let taking_at_half = utils::get_taking_amount(&wallet, WALLET_AMOUNT_FULL_FILL, &clock);
            // Price should be between start and end
            assert!(taking_at_half < WALLET_AMOUNT_FULL_FILL, 0);
            assert!(taking_at_half > TAKING_AMOUNT_FULL_FILL, 1);
            test::return_shared(wallet);
        };
        
        // Test price at end
        clock::increment_for_testing(&mut clock, DURATION / 2);
        next_tx(&mut scenario, RESOLVER1);
        {
            let wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let taking_at_end = utils::get_taking_amount(&wallet, WALLET_AMOUNT_FULL_FILL, &clock);
            assert!(taking_at_end == TAKING_AMOUNT_FULL_FILL, 0); // Minimum price
            test::return_shared(wallet);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // ============ Edge Cases and Validation Tests (Full Fill) ============
    
    #[test]
    #[expected_failure] // Already withdrawn
    fun test_double_withdraw_fails() {
        let (mut scenario, mut clock, order_hash, _) = setup_test();
        
        // Setup and withdraw escrow
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT_FULL_FILL, &mut scenario);
            let hashlock = hash::keccak256(&SECRET0);
            
            escrow_create::create_wallet(
                order_hash, 1234u256,
                string::utf8(b"TEST"), string::utf8(b"ETH"),
                WALLET_AMOUNT_FULL_FILL, TAKING_AMOUNT_FULL_FILL,
                DURATION, hashlock,
                SAFETY_DEPOSIT_FULL_FILL, SAFETY_DEPOSIT_FULL_FILL,
                false, 0, funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        clock::increment_for_testing(&mut clock, 100_000);
        
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT_FULL_FILL, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET0);
            let expected_taking = utils::get_taking_amount(&wallet, WALLET_AMOUNT_FULL_FILL, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 0,
                vector::empty<vector<u8>>(),
                TAKER, WALLET_AMOUNT_FULL_FILL,
                expected_taking, safety_deposit,
                &clock, ctx(&mut scenario)
            );
            test::return_shared(wallet);
        };
        
        clock::increment_for_testing(&mut clock, 300_000);
        
        // First withdrawal
        next_tx(&mut scenario, TAKER);
        {
            let mut escrow = test::take_shared<EscrowSrc<TEST>>(&scenario);
            escrow_withdraw::withdraw_src(&mut escrow, SECRET0, &clock, ctx(&mut scenario));
            test::return_shared(escrow);
        };
        
        // Second withdrawal attempt
        next_tx(&mut scenario, TAKER);
        {
            let mut escrow = test::take_shared<EscrowSrc<TEST>>(&scenario);
            escrow_withdraw::withdraw_src(&mut escrow, SECRET0, &clock, ctx(&mut scenario));
            test::return_shared(escrow);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    #[expected_failure] // Withdraw too early
    fun test_withdraw_before_timelock() {
        let (mut scenario, mut clock, order_hash, _) = setup_test();
        
        // Setup escrow
        next_tx(&mut scenario, MAKER);
        {
            let funding = mint_test(WALLET_AMOUNT_FULL_FILL, &mut scenario);
            let hashlock = hash::keccak256(&SECRET0);
            
            escrow_create::create_wallet(
                order_hash, 1234u256,
                string::utf8(b"TEST"), string::utf8(b"ETH"),
                WALLET_AMOUNT_FULL_FILL, TAKING_AMOUNT_FULL_FILL,
                DURATION, hashlock,
                SAFETY_DEPOSIT_FULL_FILL, SAFETY_DEPOSIT_FULL_FILL,
                false, 0, funding,
                300_000, 600_000, 900_000, 1_200_000,
                250_000, 550_000, 850_000,
                &clock, ctx(&mut scenario)
            );
        };
        
        clock::increment_for_testing(&mut clock, 100_000);
        
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut wallet = test::take_shared<Wallet<TEST>>(&scenario);
            let safety_deposit = mint_sui(SAFETY_DEPOSIT_FULL_FILL, &mut scenario);
            let secret_hashlock = hash::keccak256(&SECRET0);
            let expected_taking = utils::get_taking_amount(&wallet, WALLET_AMOUNT_FULL_FILL, &clock);
            
            escrow_create::create_escrow_src(
                &mut wallet, secret_hashlock, 0,
                vector::empty<vector<u8>>(),
                TAKER, WALLET_AMOUNT_FULL_FILL,
                expected_taking, safety_deposit,
                &clock, ctx(&mut scenario)
            );
            test::return_shared(wallet);
        };
        
        // Try to withdraw during finality lock
        clock::increment_for_testing(&mut clock, 100_000); // Still before withdrawal time
        
        next_tx(&mut scenario, TAKER);
        {
            let mut escrow = test::take_shared<EscrowSrc<TEST>>(&scenario);
            escrow_withdraw::withdraw_src(&mut escrow, SECRET0, &clock, ctx(&mut scenario));
            test::return_shared(escrow);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // Continue with partial fill tests after verifying full fill tests...

    

