import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';

console.log('🔑 Generating test keypairs for Sui\n');

// Generate user keypair
const userKeypair = new Ed25519Keypair();
const userPrivateKey = userKeypair.getSecretKey();
const userAddress = userKeypair.getPublicKey().toSuiAddress();

console.log('User Keypair:');
console.log('  Private Key:', '0x' + Buffer.from(userPrivateKey).toString('hex'));
console.log('  Address:', userAddress);

// Generate resolver keypair
const resolverKeypair = new Ed25519Keypair();
const resolverPrivateKey = resolverKeypair.getSecretKey();
const resolverAddress = resolverKeypair.getPublicKey().toSuiAddress();

console.log('\nResolver Keypair:');
console.log('  Private Key:', '0x' + Buffer.from(resolverPrivateKey).toString('hex'));
console.log('  Address:', resolverAddress);

console.log('\n📝 Add these to your .env file:');
console.log(`USER_PRIVATE_KEY=0x${Buffer.from(userPrivateKey).toString('hex')}`);
console.log(`RESOLVER_PRIVATE_KEY=0x${Buffer.from(resolverPrivateKey).toString('hex')}`);

console.log('\n💰 Get testnet SUI for these addresses from:');
console.log('   https://discord.gg/sui (testnet-faucet channel)');
console.log('   Or use: curl -X POST https://faucet.testnet.sui.io/gas -H "Content-Type: application/json" -d \'{"FixedAmountRequest":{"recipient":"YOUR_ADDRESS"}}\'');