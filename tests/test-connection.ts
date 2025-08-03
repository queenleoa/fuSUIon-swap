import 'dotenv/config';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { SuiClient } from '@mysten/sui/client';

async function testConnection() {
    console.log('🔍 Testing Sui Connection and Setup\n');
    
    const rpcUrl = process.env.SUI_RPC || 'https://fullnode.testnet.sui.io';
    const packageId = process.env.SUI_ESCROW_PACKAGE_ID;
    
    if (!packageId) {
        console.error('❌ SUI_ESCROW_PACKAGE_ID not set in .env file');
        console.log('\n📝 Please add to your .env file:');
        console.log('SUI_ESCROW_PACKAGE_ID=0x...');
        return;
    }
    
    if (!process.env.SUI_USER_PRIVATE_KEY || !process.env.SUI_RESOLVER_PRIVATE_KEY_1 || !process.env.SUI_RESOLVER_PRIVATE_KEY_2 || !process.env.SUI_RESOLVER_PRIVATE_KEY_3) {
        console.error('❌ Private keys not set in .env file');
        console.log('\n📝 Please add to your .env file:');
        console.log('USER_PRIVATE_KEY=0x... (64 hex chars)');
        console.log('RESOLVER_PRIVATE_KEY=0x... (64 hex chars)');
        return;
    }
    
    try {
        // Test Sui connection
        const client = new SuiClient({ url: rpcUrl });
        const checkpoint = await client.getLatestCheckpointSequenceNumber();
        console.log('✅ Connected to Sui at:', rpcUrl);
        console.log('   Latest checkpoint:', checkpoint);
        
        // Test package exists
        const packageObj = await client.getObject({
            id: packageId,
            options: { showContent: true }
        });
        
        if (packageObj.data) {
            console.log('✅ Package found at:', packageId);
            if (packageObj.data.content?.dataType === 'package') {
                console.log('   Type: Package (correct)');
            }
        } else {
            console.error('❌ Package not found at:', packageId);
            return;
        }
        
        // Test keypairs
        const userKeypair = Ed25519Keypair.fromSecretKey(
            Buffer.from(process.env.SUI_USER_PRIVATE_KEY.slice(2), 'hex')
        );
        const userAddress = userKeypair.getPublicKey().toSuiAddress();
        console.log('\n✅ User keypair loaded');
        console.log('   Address:', userAddress);
        
        const resolver1Keypair = Ed25519Keypair.fromSecretKey(
            Buffer.from(process.env.SUI_RESOLVER_PRIVATE_KEY_1.slice(2), 'hex')
        );
        const resolver1Address = resolver1Keypair.getPublicKey().toSuiAddress();
        console.log('\n✅ Resolver 1 keypair loaded');
        console.log('   Address:', resolver1Address);

        const resolver2Keypair = Ed25519Keypair.fromSecretKey(
            Buffer.from(process.env.SUI_RESOLVER_PRIVATE_KEY_2.slice(2), 'hex')
        );
        const resolver2Address = resolver2Keypair.getPublicKey().toSuiAddress();
        console.log('\n✅ Resolver 2 keypair loaded');
        console.log('   Address:', resolver2Address);

         const resolver3Keypair = Ed25519Keypair.fromSecretKey(
            Buffer.from(process.env.SUI_RESOLVER_PRIVATE_KEY_3.slice(2), 'hex')
        );
        const resolver3Address = resolver3Keypair.getPublicKey().toSuiAddress();
        console.log('\n✅ Resolver 3 keypair loaded');
        console.log('   Address:', resolver3Address);
        
        // Check balances
        const userBalance = await client.getBalance({ owner: userAddress });
        const resolver1Balance = await client.getBalance({ owner: resolver1Address });
        const resolver2Balance = await client.getBalance({ owner: resolver2Address });
        const resolver3Balance = await client.getBalance({ owner: resolver3Address });

        
        console.log('\n💰 Balances:');
        console.log(`   User: ${userBalance.totalBalance} MIST (${Number(userBalance.totalBalance) / 1e9} SUI)`);
        console.log(`   Resolver 1: ${resolver1Balance.totalBalance} MIST (${Number(resolver1Balance.totalBalance) / 1e9} SUI)`);
        console.log(`   Resolver 2: ${resolver2Balance.totalBalance} MIST (${Number(resolver2Balance.totalBalance) / 1e9} SUI)`);
        console.log(`   Resolver 3: ${resolver3Balance.totalBalance} MIST (${Number(resolver3Balance.totalBalance) / 1e9} SUI)`);
        
        
        if (Number(userBalance.totalBalance) < 1e9) {
            console.warn('\n⚠️  User balance is low. Get testnet SUI from:');
            console.log('   https://discord.gg/sui (testnet-faucet channel)');
        }
        
        if (Number(resolver1Balance.totalBalance) < 1e9) {
            console.warn('\n⚠️  Resolver balance is low. Get testnet SUI from:');
            console.log('   https://discord.gg/sui (testnet-faucet channel)');
        }

        if (Number(resolver2Balance.totalBalance) < 1e9) {
            console.warn('\n⚠️  Resolver balance is low. Get testnet SUI from:');
            console.log('   https://discord.gg/sui (testnet-faucet channel)');
        }

        if (Number(resolver3Balance.totalBalance) < 1e9) {
            console.warn('\n⚠️  Resolver balance is low. Get testnet SUI from:');
            console.log('   https://discord.gg/sui (testnet-faucet channel)');
        }
        
        console.log('\n✅ All checks passed! Ready to run tests.');
        
    } catch (error) {
        console.error('\n❌ Connection test failed:', error);
    }
}

testConnection().catch(console.error);