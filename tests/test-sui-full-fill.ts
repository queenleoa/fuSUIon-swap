import 'dotenv/config';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { SuiResolver } from './sui-resolver';
import { randomBytes } from 'crypto';
import { keccak256, parseUnits } from 'ethers';


async function testSuiFullFill() {
    console.log('🚀 Testing Sui Full Fill Flow\n');

    if (!process.env.SUI_USER_PRIVATE_KEY || !process.env.SUI_RESOLVER_PRIVATE_KEY) {
        console.error('❌ Private keys not set in .env file');
        console.log('\n📝 Please add to your .env file:');
        console.log('USER_PRIVATE_KEY=0x... (64 hex chars)');
        console.log('RESOLVER_PRIVATE_KEY=0x... (64 hex chars)');
        return;
    }
    
    // Setup keypairs
    const userKeypair = Ed25519Keypair.fromSecretKey(
        Buffer.from(process.env.SUI_USER_PRIVATE_KEY.slice(2), 'hex')
    );
    const resolverKeypair = Ed25519Keypair.fromSecretKey(
        Buffer.from(process.env.SUI_RESOLVER_PRIVATE_KEY.slice(2), 'hex')
    );
    
    // Create resolver instances
    const userResolver = new SuiResolver(
        process.env.SUI_RPC || 'https://fullnode.testnet.sui.io',
        process.env.SUI_ESCROW_PACKAGE_ID!,
        userKeypair,
        userKeypair.getPublicKey().toSuiAddress(),
        '0x0000000000000000000000000000000000000000' // Dummy EVM address
    );
    
    const resolverInstance = new SuiResolver(
        process.env.SUI_RPC || 'https://fullnode.testnet.sui.io',
        process.env.SUI_ESCROW_PACKAGE_ID!,
        resolverKeypair,
        resolverKeypair.getPublicKey().toSuiAddress(),
        process.env.RESOLVER_ADDRESS || '0x0000000000000000000000000000000000000000'
    );
    
    // Test data
    const orderHash = '0x' + randomBytes(32).toString('hex');
    const secret = '0x' + randomBytes(32).toString('hex');
    const hashlock = keccak256(secret);
    const salt = '12345';
    
    // Amounts (in MIST - smallest unit of SUI)
    const orderAmount = parseUnits('0.01', 9); // 1 SUI
    const minTakingAmount = parseUnits('0.009', 9); // 0.9 SUI minimum
    const safetyDeposit = parseUnits('0.002', 9); // 0.01 SUI
    
     console.log('📋 Test Data:');
    console.log('  Order Hash:', orderHash.slice(0, 10) + '...');
    console.log('  Secret:', secret.slice(0, 10) + '...');
    console.log('  Hashlock:', hashlock.slice(0, 10) + '...');
    console.log('  Order Amount:', orderAmount.toString(), 'MIST');
    
    try {
        // Step 1: User creates wallet
        console.log('\n1️⃣ User creating wallet...');
        const walletId = await userResolver.createWalletSponsored(
            orderHash,
            salt,
            '0x2::sui::SUI',
            'USDC',
            orderAmount,
            minTakingAmount,
            3600000n, // 1 hour in ms
            hashlock,
            safetyDeposit,
            safetyDeposit,
            false, // no partial fills
            0,     // parts amount
            orderAmount, // funding amount
            {
                srcWithdrawal: 10000n,      // 10 sec in ms
                srcPublicWithdrawal: 120000n,
                srcCancellation: 121000n,
                srcPublicCancellation: 122000n,
                dstWithdrawal: 8000n,
                dstPublicWithdrawal: 100000n,
                dstCancellation: 101000n
            }
        );
        console.log('  Wallet ID:', walletId);
        
        // Wait for indexing
        console.log('⏳ Waiting for indexing...');
        await new Promise(resolve => setTimeout(resolve, 5000));
        
        // Optional: Wait to get a better auction price (comment out for immediate fill)
        // console.log('⏳ Waiting 30 seconds for better auction price...');
        // await new Promise(resolve => setTimeout(resolve, 30000));
        
        // Get wallet info
        const walletInfo = await resolverInstance.getWalletInfo(walletId);
        if (!walletInfo) {
            throw new Error('Failed to get wallet info');
        }
        console.log('  Wallet balance:', walletInfo.balance.toString());
        console.log('  Wallet making amount:', walletInfo.makingAmount.toString());
        console.log('  Wallet taking amount:', walletInfo.takingAmount.toString());
        console.log('  Wallet duration:', walletInfo.duration.toString());
        console.log('  Wallet created at (ms):', walletInfo.createdAt.toString());
        
        // Calculate current taking amount (Dutch auction)
        const currentTakingAmount = await resolverInstance.getCurrentTakingAmount(
            walletInfo,
            orderAmount
        );
        
        // Add a small buffer for network delays (add 5 seconds worth of price change)
        const futureTime = Date.now() + 5000; // 5 seconds in the future
        const bufferedTakingAmount = await resolverInstance.getCurrentTakingAmount(
            walletInfo,
            orderAmount,
        );
        
        console.log('  Current taking amount:', currentTakingAmount.toString());
        console.log('  Buffered taking amount:', bufferedTakingAmount.toString());
        console.log('  Min taking amount:', minTakingAmount.toString());
        console.log('  Making amount:', orderAmount.toString());
        console.log('  Wallet created at:', new Date(Number(walletInfo.createdAt)).toISOString());
        console.log('  Current time:', new Date().toISOString());
        console.log('  Duration:', walletInfo.duration.toString(), 'ms');
        
        // Step 2: Resolver creates source escrow
        console.log('\n2️⃣ Resolver creating source escrow...');
        const srcEscrowId = await resolverInstance.deploySrc(
            walletId,
            hashlock,
            0, // secret index for full fill
            [], // no merkle proof for full fill
            resolverInstance.getSignerAddress(), // taker is resolver
            orderAmount,
            currentTakingAmount,
            safetyDeposit
        );
        console.log('  Source Escrow ID:', srcEscrowId);
        
        // Step 3: Simulate destination escrow (in real scenario, this would be on EVM)
        console.log('\n3️⃣ Creating destination escrow (simulating cross-chain)...');
        const dstEscrowId = await resolverInstance.deployDst(
            orderHash,
            hashlock,
            userKeypair.getPublicKey().toSuiAddress(), // maker receives
            parseUnits('0.89', 9), // Taking amount minus fees
            safetyDeposit,
            {
                srcWithdrawal: 10000n,
                srcPublicWithdrawal: 120000n,
                srcCancellation: 121000n,
                srcPublicCancellation: 122000n,
                dstWithdrawal: 8000n,
                dstPublicWithdrawal: 100000n,
                dstCancellation: 101000n
            }
        );
        console.log('  Destination Escrow ID:', dstEscrowId);
        
        // Wait for timelock
        console.log('\n⏳ Waiting 10 seconds for timelock to pass...');
        await new Promise(resolve => setTimeout(resolve, 10000));
        
        // Step 4: Withdraw from destination (user gets funds)
        console.log('\n4️⃣ User withdrawing from destination escrow...');
        await resolverInstance.withdraw(dstEscrowId, 'dst', secret);
        
        // Step 5: Withdraw from source (resolver gets funds)
        console.log('\n5️⃣ Resolver withdrawing from source escrow...');
        await resolverInstance.withdraw(srcEscrowId, 'src', secret);
        
        console.log('\n✅ Full fill test successful!');
        console.log('\n📊 Summary:');
        console.log('  Wallet:', walletId);
        console.log('  Source Escrow:', srcEscrowId);
        console.log('  Destination Escrow:', dstEscrowId);
        console.log('  Amount swapped:', orderAmount.toString(), 'MIST');
        
    } catch (error: any) {
        console.error('\n❌ Test failed:', error);
        
        // Check for Move abort codes
        if (error.message?.includes('MoveAbort') || error.cause?.message?.includes('MoveAbort')) {
            console.error('\n💡 Move Error Code Reference:');
            console.error('  1001: Invalid amount');
            console.error('  1002: Invalid timelock');
            console.error('  1003: Invalid hashlock');
            console.error('  1004: Invalid secret');
            console.error('  1006: Already withdrawn');
            console.error('  1007: Not withdrawable (timelock)');
            console.error('  1008: Inactive escrow');
            console.error('  1009: Not cancellable');
            console.error('  1010: Unauthorized');
            console.error('  1013: Insufficient balance');
            console.error('  1014: Safety deposit too low');
            console.error('  1015: Wallet inactive');
            console.error('  1017: Auction violated');
        }
    }
}

testSuiFullFill().catch(console.error);