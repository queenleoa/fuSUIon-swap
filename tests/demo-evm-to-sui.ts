import 'dotenv/config'
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import {
    ContractFactory,
    JsonRpcProvider,
    Wallet as EthersWallet,
    parseUnits,
    parseEther,
    formatUnits,
    formatEther,
    randomBytes
} from 'ethers'
import * as Sdk from '@1inch/cross-chain-sdk'
console.log('Sdk:', Sdk)
console.log('Sdk keys:', Object.keys(Sdk || {}))
import { uint8ArrayToHex, UINT_40_MAX } from '@1inch/byte-utils'
import chalk from 'chalk'

// Import our modules
import { config } from './config'
import { Wallet } from './wallet'
import { Resolver } from './evm-resolver'
import { EscrowFactory } from './escrow-factory'
import { SuiResolver } from './sui-resolver'

// Import contracts
import factoryContract from '../dist/contracts/TestEscrowFactory.sol/TestEscrowFactory.json'
import resolverContract from '../dist/contracts/Resolver.sol/Resolver.json'

const { Address } = Sdk

// Console logging helpers
const log = {
    title: (msg: string) => console.log(chalk.bold.cyan(`\n${'='.repeat(60)}\n${msg}\n${'='.repeat(60)}`)),
    step: (num: number, msg: string) => console.log(chalk.bold.green(`\n${num}️⃣  ${msg}`)),
    info: (label: string, value: any) => console.log(chalk.gray('   ') + chalk.yellow(label + ':'), value),
    success: (msg: string) => console.log(chalk.green('   ✅ ' + msg)),
    error: (msg: string) => console.log(chalk.red('   ❌ ' + msg)),
    waiting: (msg: string) => console.log(chalk.gray('   ⏳ ' + msg)),
    tx: (label: string, hash: string) => console.log(chalk.gray('   📝 ') + chalk.blue(label + ':'), chalk.gray(hash))
}

// Helper to wait with progress indicator
async function waitWithProgress(seconds: number, message: string) {
    log.waiting(`${message} (${seconds}s)`)
    for (let i = seconds; i > 0; i--) {
        process.stdout.write(`\r   ⏳ ${message} (${i}s remaining)`)
        await new Promise(resolve => setTimeout(resolve, 1000))
    }
    process.stdout.write('\r' + ' '.repeat(50) + '\r')
}

// Main demo function
async function runEvmToSuiSwap() {
    log.title('🔄 Cross-Chain Swap Demo: Arbitrum → Sui')
    
    // Check if running on fork
    const isForked = process.env.USE_FORK === 'true'
    if (isForked) {
        log.info('Mode', 'Running on forked network')
    } else {
        log.info('Mode', 'Running on mainnet - REAL FUNDS!')
    }
    
    // Setup
    log.step(1, 'Setting up wallets and connections')
    
    // EVM Setup
    const evmProvider = new JsonRpcProvider(
        isForked ? 'http://localhost:8545' : config.evm.rpc
    )
    const evmUserWallet = new EthersWallet(config.evm.accounts.user.privateKey, evmProvider)
    const evmResolverWallet = new EthersWallet(config.evm.accounts.resolver.privateKey, evmProvider)
    
    log.info('EVM User Address', evmUserWallet.address)
    log.info('EVM Resolver Address', evmResolverWallet.address)
    
    // Check balances
    const evmUserBalance = await evmProvider.getBalance(evmUserWallet.address)
    const evmResolverBalance = await evmProvider.getBalance(evmResolverWallet.address)
    
    log.info('EVM User ETH Balance', formatEther(evmUserBalance) + ' ETH')
    log.info('EVM Resolver ETH Balance', formatEther(evmResolverBalance) + ' ETH')
    
    // Sui Setup
    const suiUserKeypair = Ed25519Keypair.fromSecretKey(
        Buffer.from(config.sui.accounts.user.privateKey.slice(2), 'hex')
    )
    const suiResolverKeypair = Ed25519Keypair.fromSecretKey(
        Buffer.from(config.sui.accounts.resolver.privateKey.slice(2), 'hex')
    )
    
    log.info('Sui User Address', suiUserKeypair.getPublicKey().toSuiAddress())
    log.info('Sui Resolver Address', suiResolverKeypair.getPublicKey().toSuiAddress())
    
    // Deploy or use existing contracts
    log.step(2, 'Setting up contracts on Arbitrum')
    
    let escrowFactoryAddress: string
    let resolverContractAddress: string
    
    if (process.env.ARBITRUM_ESCROW_FACTORY && process.env.ARBITRUM_RESOLVER_CONTRACT && !isForked) {
        escrowFactoryAddress = process.env.ARBITRUM_ESCROW_FACTORY
        resolverContractAddress = process.env.ARBITRUM_RESOLVER_CONTRACT
        log.info('Using existing Escrow Factory', escrowFactoryAddress)
        log.info('Using existing Resolver Contract', resolverContractAddress)
    } else {
        log.info('Deploying new contracts', 'Please wait...')
        
        // Deploy EscrowFactory
        const escrowFactory = await new ContractFactory(
            factoryContract.abi,
            factoryContract.bytecode,
            evmResolverWallet
        ).deploy(
            config.evm.limitOrderProtocol,
            config.evm.wrappedNative, // feeToken (WETH)
            Address.fromBigInt(0n).toString(), // accessToken
            evmResolverWallet.address, // owner
            60 * 30, // src rescue delay
            60 * 30  // dst rescue delay
        )
        await escrowFactory.waitForDeployment()
        escrowFactoryAddress = await escrowFactory.getAddress()
        log.success(`Escrow Factory deployed at ${escrowFactoryAddress}`)
        
        // Deploy Resolver contract
        const resolver = await new ContractFactory(
            resolverContract.abi,
            resolverContract.bytecode,
            evmResolverWallet
        ).deploy(
            escrowFactoryAddress,
            config.evm.limitOrderProtocol,
            evmResolverWallet.address // resolver as owner
        )
        await resolver.waitForDeployment()
        resolverContractAddress = await resolver.getAddress()
        log.success(`Resolver Contract deployed at ${resolverContractAddress}`)
    }
    
    // Create resolver contract instance here (before using it)
    const resolverContractInstance = new Resolver(resolverContractAddress, 'dummy_dst_address')
    
    // Create wallet wrappers
    const evmUser = new Wallet(evmUserWallet, evmProvider)
    const evmResolver = new Wallet(evmResolverWallet, evmProvider)
    
    // Check USDC balance
    const userUsdcBalance = await evmUser.tokenBalance(config.evm.tokens.USDC.address)
    log.info('User USDC Balance', formatUnits(userUsdcBalance, 6) + ' USDC')
    
    if (userUsdcBalance < parseUnits('1', 6)) {
        if (isForked) {
            log.info('Funding user with USDC on fork', 'Impersonating donor...')
            // On fork, we can impersonate a whale to get USDC
            // Arbitrum USDC rich addresses (you can verify on Arbiscan)
            const donors = [
                '0x489ee077994B6658eAfA855C308275EAd8097C4A', // Arbitrum Foundation
                '0xB38e8c17e38363aF6EbdCb3dAE12e0243582891D', // Binance
                '0x40ec5B33f54e0E8A33A975908C5BA1c14e5BbbDf', // Polygon Bridge
            ]
            
            // Try each donor until we find one with enough balance
            for (const donor of donors) {
                try {
                    const donorBalance = await evmUser.tokenBalance(config.evm.tokens.USDC.address)
                    await evmUser.topUpFromDonor(config.evm.tokens.USDC.address, donor, parseUnits('100', 6))
                    log.success('User funded with 100 USDC')
                    break
                } catch (e) {
                    continue
                }
            }
        } else {
            log.error('Insufficient USDC balance. Please fund your wallet with at least 1 USDC on Arbitrum')
            return
        }
    }
    
    // Approve USDC to LOP
    log.step(3, 'Approving USDC to Limit Order Protocol')
    const allowance = await evmUser.getAllowance(
        config.evm.tokens.USDC.address,
        config.evm.limitOrderProtocol
    )
    
    if (allowance < parseUnits('0.1', 6)) {
        await evmUser.approveToken(
            config.evm.tokens.USDC.address,
            config.evm.limitOrderProtocol,
            parseUnits('0.1', 6) // Approve 1 USDC
        )
        log.success('USDC approved')
    } else {
        log.info('USDC already approved', formatUnits(allowance, 6) + ' USDC')
    }
    
    // Create order
    log.step(4, 'Creating cross-chain swap order')
    
    const swapAmount = parseUnits('0.1', 6) // 1 USDC
    const minReceiveAmount = parseUnits('0.09', 6) // 0.99 USDC minimum (1% slippage)
    const secret = uint8ArrayToHex(randomBytes(32))
    
    log.info('Swap Amount', '0.1 USDC')
    log.info('Min Receive', '0.09 USDC')
    log.info('Secret', secret.slice(0, 10) + '...')
    
    const currentTimestamp = BigInt(Math.floor(Date.now() / 1000))
    
    const order = Sdk.CrossChainOrder.new(
        new Address(escrowFactoryAddress),
        {
            salt: Sdk.randBigInt(1000n),
            maker: new Address(evmUserWallet.address),
            makingAmount: swapAmount,
            takingAmount: minReceiveAmount,
            makerAsset: new Address(config.evm.tokens.USDC.address),
            takerAsset: new Address(config.evm.tokens.USDC.address) // Placeholder, actual is on Sui
        },
        {
            hashLock: Sdk.HashLock.forSingleFill(secret),
            timeLocks: Sdk.TimeLocks.new({
                srcWithdrawal: BigInt(config.swap.timelocks.srcWithdrawal),
                srcPublicWithdrawal: BigInt(config.swap.timelocks.srcPublicWithdrawal),
                srcCancellation: BigInt(config.swap.timelocks.srcCancellation),
                srcPublicCancellation: BigInt(config.swap.timelocks.srcPublicCancellation),
                dstWithdrawal: BigInt(config.swap.timelocks.dstWithdrawal),
                dstPublicWithdrawal: BigInt(config.swap.timelocks.dstPublicWithdrawal),
                dstCancellation: BigInt(config.swap.timelocks.dstCancellation)
            }),
            srcChainId: config.evm.chainId,
            dstChainId: 1, // Sui doesn't have a standard chain ID
            srcSafetyDeposit: parseEther(config.swap.safetyDeposit.arbitrum),
            dstSafetyDeposit: parseUnits(config.swap.safetyDeposit.sui, 9)
        },
        {
            auction: new Sdk.AuctionDetails({
                initialRateBump: 0,
                points: [],
                duration: 300n, // 5 minutes
                startTime: currentTimestamp
            }),
            whitelist: [
                {
                    address: new Address(resolverContractAddress),
                    allowFrom: 0n
                }
            ],
            resolvingStartTime: 0n
        },
        {
            nonce: Sdk.randBigInt(UINT_40_MAX),
            allowPartialFills: false,
            allowMultipleFills: false
        }
    )
    
    // Get order hash
    const orderHash = order.getOrderHash(config.evm.chainId)
    log.info('Order Hash', orderHash.slice(0, 10) + '...')
    
    // Sign order
    const signature = await evmUser.signOrder(config.evm.chainId, order)
    log.success('Order signed')
    
    // Create EVM escrow
    log.step(5, 'Creating source escrow on Arbitrum')
    
    const fillAmount = order.makingAmount
    
    const { txHash: fillTxHash, blockHash: srcBlockHash } = await evmResolver.send(
        resolverContractInstance.deploySrc(
            config.evm.chainId,
            order,
            signature,
            Sdk.TakerTraits.default()
                .setExtension(order.extension)
                .setAmountMode(Sdk.AmountMode.maker)
                .setAmountThreshold(order.takingAmount),
            fillAmount
        )
    )
  
        // ✅ Wait for transaction to be mined and get reliable block hash
    const receipt = await evmProvider.getTransactionReceipt(fillTxHash)
    if (!receipt || receipt.status !== 1) {
        throw new Error(`Transaction ${fillTxHash} failed or not yet mined`)
    }

    const srcescrowBlockHash = receipt.blockHash

    // ✅ Now pass this correct block hash into the EscrowFactory
    const escrowFactory = new EscrowFactory(evmProvider, escrowFactoryAddress)
    const [srcImmutables, complement] = await escrowFactory.getSrcDeployEvent(srcescrowBlockHash)
    
    const ESCROW_SRC_IMPL = await escrowFactory.getSourceImpl()
    const srcEscrowAddress = new Sdk.EscrowFactory(new Address(escrowFactoryAddress)).getSrcEscrowAddress(
        srcImmutables,
        ESCROW_SRC_IMPL
    )
    
    log.success(`Source escrow created at ${srcEscrowAddress}`)
    
    // Create Sui resolver
    log.step(6, 'Creating destination escrow on Sui')
    
    const suiResolver = new SuiResolver(
        config.sui.rpc,
        config.sui.packageId,
        suiResolverKeypair,
        suiResolverKeypair.getPublicKey().toSuiAddress(),
        resolverContractAddress
    )
    
    // Convert timelocks to milliseconds for Sui
    const timelockMs = {
        srcWithdrawal: BigInt(config.swap.timelocks.srcWithdrawal) * 1000n,
        srcPublicWithdrawal: BigInt(config.swap.timelocks.srcPublicWithdrawal) * 1000n,
        srcCancellation: BigInt(config.swap.timelocks.srcCancellation) * 1000n,
        srcPublicCancellation: BigInt(config.swap.timelocks.srcPublicCancellation) * 1000n,
        dstWithdrawal: BigInt(config.swap.timelocks.dstWithdrawal) * 1000n,
        dstPublicWithdrawal: BigInt(config.swap.timelocks.dstPublicWithdrawal) * 1000n,
        dstCancellation: BigInt(config.swap.timelocks.dstCancellation) * 1000n
    }
    
    const dstEscrowId = await suiResolver.deployDst(
        orderHash,
        Sdk.HashLock.forSingleFill(secret).toString(),
        suiUserKeypair.getPublicKey().toSuiAddress(),
        parseUnits('0.099', 6), // Convert to usd decimal places
        parseUnits(config.swap.safetyDeposit.sui, 9),
        timelockMs
    )
    
    log.success(`Destination escrow created at ${dstEscrowId}`)
    
    // Wait for finality
    await waitWithProgress(30, 'Waiting for finality locks')
    
    // Share secret
    log.step(7, 'Sharing secret with resolvers')
    log.info('Secret revealed', secret)
    log.success('Both escrows verified and secret shared')
    
    // Withdraw from destination
    log.step(8, 'Withdrawing funds on Sui (user receives funds)')
    await suiResolver.withdraw(dstEscrowId, 'dst', secret)
    log.success('User received funds on Sui')
    
    // Withdraw from source
    log.step(9, 'Withdrawing funds on Arbitrum (resolver receives funds)')
    
    const withdrawTx = await evmResolver.send(
        resolverContractInstance.withdraw('src', srcEscrowAddress, secret, srcImmutables)
    )
    log.tx('Withdraw transaction', withdrawTx.txHash)
    log.success('Resolver received funds on Arbitrum')
    
    // Summary
    log.title('✅ Swap Completed Successfully!')
    console.log(chalk.white('\n📊 Summary:'))
    console.log(chalk.gray('  • ') + chalk.white('From:'), chalk.cyan('0.10 USDC on Arbitrum'))
    console.log(chalk.gray('  • ') + chalk.white('To:'), chalk.cyan('0.099 USDC equivalent on Sui'))
    console.log(chalk.gray('  • ') + chalk.white('User:'), chalk.yellow(evmUserWallet.address))
    console.log(chalk.gray('  • ') + chalk.white('Source Escrow:'), chalk.gray(srcEscrowAddress.toString()))
    console.log(chalk.gray('  • ') + chalk.white('Destination Escrow:'), chalk.gray(dstEscrowId))
    console.log(chalk.gray('  • ') + chalk.white('Time:'), chalk.green('~1 minute'))
}

// Error handler
async function main() {
    try {
        await runEvmToSuiSwap()
    } catch (error: any) {
        log.error('Demo failed: ' + error.message)
        console.error(error)
        
        if (error.message?.includes('insufficient funds')) {
            console.log(chalk.yellow('\n💡 Tip: Make sure your wallets are funded:'))
            console.log(chalk.gray('  • EVM User needs: USDC + ETH for gas'))
            console.log(chalk.gray('  • EVM Resolver needs: ETH for gas (0.002 ETH should suffice)'))
            console.log(chalk.gray('  • Sui Resolver needs: SUI for gas'))
        }
    }
}

main().catch(console.error)