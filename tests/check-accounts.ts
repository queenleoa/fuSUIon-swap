import 'dotenv/config'
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { SuiClient } from '@mysten/sui/client';
import { JsonRpcProvider, Wallet, Contract, formatEther, formatUnits } from 'ethers'
import chalk from 'chalk'
import { config } from './config'
import ERC20 from '../dist/contracts/IERC20.sol/IERC20.json'

async function checkAccounts() {
    console.log(chalk.bold.cyan('\n🔍 Checking Account Balances\n'))
    
    // // Check EVM accounts
    // console.log(chalk.bold.yellow('Arbitrum Mainnet Accounts:'))
    // const evmProvider = new JsonRpcProvider(config.evm.rpc)
    
    // // User account
    // const evmUserWallet = new Wallet(config.evm.accounts.user.privateKey, evmProvider)
    // const userEthBalance = await evmProvider.getBalance(evmUserWallet.address)
    // const usdcContract = new Contract(config.evm.tokens.USDC.address, ERC20.abi, evmProvider)
    // const userUsdcBalance = await usdcContract.balanceOf(evmUserWallet.address)
    
    // console.log(chalk.white('\n👤 User Account:'))
    // console.log(chalk.gray('   Address:'), evmUserWallet.address)
    // console.log(chalk.gray('   ETH:'), formatEther(userEthBalance), userEthBalance < 2000000000000000n ? chalk.red('❌ Need at least 0.002 ETH') : chalk.green('✅'))
    // console.log(chalk.gray('   USDC:'), formatUnits(userUsdcBalance, 6), userUsdcBalance < 1000000n ? chalk.red('❌ Need at least 1 USDC') : chalk.green('✅'))
    
    // // Resolver account
    // const evmResolverWallet = new Wallet(config.evm.accounts.resolver.privateKey, evmProvider)
    // const resolverEthBalance = await evmProvider.getBalance(evmResolverWallet.address)
    // const resolverUsdcBalance = await usdcContract.balanceOf(evmResolverWallet.address)
    
    // console.log(chalk.white('\n🤖 Resolver Account:'))
    // console.log(chalk.gray('   Address:'), evmResolverWallet.address)
    // console.log(chalk.gray('   ETH:'), formatEther(resolverEthBalance), resolverEthBalance < 2000000000000000n ? chalk.red('❌ Need at least 0.002 ETH') : chalk.green('✅'))
    // console.log(chalk.gray('   USDC:'), formatUnits(resolverUsdcBalance, 6))
    
    // Check Sui accounts
    console.log(chalk.bold.yellow('\n\nSui Testnet Accounts:'))
    const suiClient = new SuiClient({ url: config.sui.rpc })
    
    // User account
    const suiUserKeypair = Ed25519Keypair.fromSecretKey(
        Buffer.from(config.sui.accounts.user.privateKey.slice(2), 'hex')
    )
    const suiUserAddress = suiUserKeypair.getPublicKey().toSuiAddress()
    const suiUserBalance = await suiClient.getBalance({ owner: suiUserAddress })
    
    console.log(chalk.white('\n👤 User Account:'))
    console.log(chalk.gray('   Address:'), suiUserAddress)
    console.log(chalk.gray('   SUI:'), formatUnits(suiUserBalance.totalBalance, 9), BigInt(suiUserBalance.totalBalance) < 100000000n ? chalk.red('❌ Need at least 0.1 SUI') : chalk.green('✅'))
    
    // Resolver account
    const suiResolverKeypair = Ed25519Keypair.fromSecretKey(
        Buffer.from(config.sui.accounts.resolver.privateKey.slice(2), 'hex')
    )
    const suiResolverAddress = suiResolverKeypair.getPublicKey().toSuiAddress()
    const suiResolverBalance = await suiClient.getBalance({ owner: suiResolverAddress })
    
    console.log(chalk.white('\n🤖 Resolver Account:'))
    console.log(chalk.gray('   Address:'), suiResolverAddress)
    console.log(chalk.gray('   SUI:'), formatUnits(suiResolverBalance.totalBalance, 9), BigInt(suiResolverBalance.totalBalance) < 1000000000n ? chalk.red('❌ Need at least 1 SUI') : chalk.green('✅'))
    const USDC_TYPE =
  '0xa1ec7fc00a6f40db9693ad1415d0c193ad3906494428cf252621037bd7117e29::usdc::USDC';

    /* ---------- User account ---------- */
    const suiUserUsdcBal   = await suiClient.getBalance({ owner: suiUserAddress, coinType: USDC_TYPE });

    console.log(chalk.white('\n👤 User Account:'));
    console.log(chalk.gray('   Address:'), suiUserAddress);
    console.log(chalk.gray('   USDC:'), formatUnits(suiUserUsdcBal.totalBalance, 6));

    /* ---------- Resolver account ---------- */
    const suiResolverUsdcBal = await suiClient.getBalance({ owner: suiResolverAddress, coinType: USDC_TYPE });

    console.log(chalk.white('\n🤖 Resolver Account:'));
    console.log(chalk.gray('   Address:'), suiResolverAddress);
    console.log(chalk.gray('   USDC:'), formatUnits(suiResolverUsdcBal.totalBalance, 6));
    // Funding instructions
    console.log(chalk.bold.cyan('\n\n💰 Funding Instructions:\n'))
    
    console.log(chalk.bold.yellow('For Arbitrum Mainnet:'))
    console.log(chalk.white('1. Get ETH from an exchange or bridge to Arbitrum'))
    console.log(chalk.white('2. Get USDC:'))
    console.log(chalk.gray('   • Buy on Uniswap: https://app.uniswap.org'))
    console.log(chalk.gray('   • Bridge from Ethereum: https://bridge.arbitrum.io'))
    console.log(chalk.gray('   • USDC Contract:'), config.evm.tokens.USDC.address)
    
    console.log(chalk.bold.yellow('\n\nFor Sui Testnet:'))
    console.log(chalk.white('1. Get testnet SUI from faucet:'))
    console.log(chalk.gray('   • Discord: Join Sui Discord and use #testnet-faucet'))
    console.log(chalk.gray('   • Web: https://sui.io/faucet'))
    
    console.log(chalk.bold.red('\n\n⚠️  Important:'))
    console.log(chalk.white('• These are REAL funds on Arbitrum mainnet!'))
    console.log(chalk.white('• Only use test amounts you can afford to lose'))
    console.log(chalk.white('• Double-check all addresses before sending funds'))
}

checkAccounts().catch(console.error)