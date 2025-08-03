import { 
    SuiClient, 
    SuiTransactionBlockResponse,
    SuiObjectResponse
} from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import { bcs } from '@mysten/sui/bcs';
import { keccak256 } from 'ethers';

// Sui system objects
const SUI_CLOCK_OBJECT_ID = '0x0000000000000000000000000000000000000000000000000000000000000006';

export interface WalletInfo {
    id: string;
    orderHash: string;
    salt: string;
    maker: string;
    makerAsset: string;
    takerAsset: string;
    makingAmount: bigint;
    takingAmount: bigint;
    duration: bigint;
    hashlock: string;
    timelocks: {
        srcWithdrawal: bigint;
        srcPublicWithdrawal: bigint;
        srcCancellation: bigint;
        srcPublicCancellation: bigint;
        dstWithdrawal: bigint;
        dstPublicWithdrawal: bigint;
        dstCancellation: bigint;
    };
    srcSafetyDeposit: bigint;
    dstSafetyDeposit: bigint;
    allowPartialFills: boolean;
    partsAmount: number;
    lastUsedIndex: number;
    balance: bigint;
    createdAt: bigint;
    isActive: boolean;
}

export interface MerkleProofData {
    proof: string[][]; // Array of hex strings for merkle proof
    index: number;
    secretHash: string;
}

export class SuiResolver {
    private client: SuiClient;
    private keypair: Ed25519Keypair;
    sponsor: any;
    sponsorGas: { objectId: string; version: string | number; digest: string; };
    
    constructor(
        private rpcUrl: string,
        private packageId: string,
        keypair: Ed25519Keypair,
        public readonly srcAddress: string, // Resolver address on Sui
        public readonly dstAddress: string  // Resolver address on EVM (for reference)
    ) {
        this.client = new SuiClient({ url: rpcUrl });
        this.keypair = keypair;
    }

    /**
     * Get signer address
     */
    getSignerAddress(): string {
        return this.keypair.getPublicKey().toSuiAddress();
    }

    /**
     * Create wallet (for maker) - Sui specific implementation
     */
    async createWallet(
        orderHash: string,
        salt: string,
        makerAsset: string,
        takerAsset: string,
        makingAmount: bigint,
        takingAmount: bigint,
        duration: bigint,
        hashlock: string, // merkle root for partial fills, keccak256(secret) for single fill
        srcSafetyDeposit: bigint,
        dstSafetyDeposit: bigint,
        allowPartialFills: boolean,
        partsAmount: number,
        fundingAmount: bigint,
        timelocks: {
            srcWithdrawal: bigint;
            srcPublicWithdrawal: bigint;
            srcCancellation: bigint;
            srcPublicCancellation: bigint;
            dstWithdrawal: bigint;
            dstPublicWithdrawal: bigint;
            dstCancellation: bigint;
        },
        tokenType: string = '0x2::sui::SUI'
    ): Promise<string> {
        console.log('Creating wallet with order hash:', orderHash);
        
        const tx = new Transaction();
        
        // Convert hex strings to byte arrays
        const orderHashBytes = Array.from(Buffer.from(orderHash.slice(2), 'hex'));
        const hashlockBytes = Array.from(Buffer.from(hashlock.slice(2), 'hex'));
        
        // Split coin for funding
        const [fundingCoin] = tx.splitCoins(tx.gas, [fundingAmount]);
        
        tx.moveCall({
            target: `${this.packageId}::escrow_create::create_wallet`,
            typeArguments: [tokenType],
            arguments: [
                tx.pure(bcs.vector(bcs.u8()).serialize(orderHashBytes)),
                tx.pure.u256(salt),
                tx.pure.string(makerAsset),
                tx.pure.string(takerAsset),
                tx.pure.u64(makingAmount),
                tx.pure.u64(takingAmount),
                tx.pure.u64(duration),
                tx.pure(bcs.vector(bcs.u8()).serialize(hashlockBytes)),
                tx.pure.u64(srcSafetyDeposit),
                tx.pure.u64(dstSafetyDeposit),
                tx.pure.bool(allowPartialFills),
                tx.pure.u8(partsAmount),
                fundingCoin,
                // Relative timelocks in milliseconds
                tx.pure.u64(timelocks.srcWithdrawal),
                tx.pure.u64(timelocks.srcPublicWithdrawal),
                tx.pure.u64(timelocks.srcCancellation),
                tx.pure.u64(timelocks.srcPublicCancellation),
                tx.pure.u64(timelocks.dstWithdrawal),
                tx.pure.u64(timelocks.dstPublicWithdrawal),
                tx.pure.u64(timelocks.dstCancellation),
                tx.object(SUI_CLOCK_OBJECT_ID)
            ]
        });

        const result = await this.client.signAndExecuteTransaction({
            transaction: tx,
            signer: this.keypair,
            options: {
                showEffects: true,
                showEvents: true
            }
        });
        
        const walletCreatedEvent = result.events?.find(
            e => e.type.includes('WalletCreated')
        );
        
        if (!walletCreatedEvent || !walletCreatedEvent.parsedJson) {
            throw new Error('Failed to create wallet - no event emitted');
        }
        
        const walletId = (walletCreatedEvent.parsedJson as any).wallet_id;
        console.log('✅ Wallet created at:', walletId);

        // Add delay for object propagation
        console.log('⏳ Waiting for object to be indexed...');
        await new Promise(resolve => setTimeout(resolve, 3000));
        
        return walletId;
    }


    /**
     * Gas-sponsored version of `createWallet` – **same method signature**
     * -------------------------------------------------------------------
     * • `this.keypair`  → maker / user (tx.sender)
     * • `this.sponsor`  → Ed25519Keypair of the resolver that pays gas
     * • `this.sponsorGas` → object id of a SUI coin the resolver owns (≥ gasBudget)
     * 
     * Everything else – Move call arguments, event parsing, etc. – is
     * unchanged from your original snippet.
     */
    async createWalletSponsored(
    orderHash: string,
    salt: string,
    makerAsset: string,
    takerAsset: string,
    makingAmount: bigint,
    takingAmount: bigint,
    duration: bigint,
    hashlock: string,
    srcSafetyDeposit: bigint,
    dstSafetyDeposit: bigint,
    allowPartialFills: boolean,
    partsAmount: number,
    fundingAmount: bigint,
    timelocks: {
        srcWithdrawal: bigint;
        srcPublicWithdrawal: bigint;
        srcCancellation: bigint;
        srcPublicCancellation: bigint;
        dstWithdrawal: bigint;
        dstPublicWithdrawal: bigint;
        dstCancellation: bigint;
    },
    tokenType: string = '0x2::sui::SUI'
    ): Promise<string> {
    console.log('Creating wallet with order hash:', orderHash);

    /* ─────────────── build programmable tx block ─────────────── */

    const tx = new Transaction();                          // ← @mysten/sui.js
    tx.setSender(this.keypair.getPublicKey().toSuiAddress());
    tx.setGasOwner(this.sponsor.getPublicKey().toSuiAddress());
    tx.setGasPayment([this.sponsorGas]);                   // resolver’s coin
    tx.setGasBudget(500_000_000);                           // tune as needed

    /* encode hashes */
    const orderHashBytes = Array.from(Buffer.from(orderHash.slice(2), 'hex'));
    const hashlockBytes  = Array.from(Buffer.from(hashlock.slice(2),  'hex'));

    /* funding comes from (a split of) the gas coin – minimal change */
    const [fundingCoin] = tx.splitCoins(tx.gas, [fundingAmount]);

    tx.moveCall({
        target: `${this.packageId}::escrow_create::create_wallet`,
        typeArguments: [tokenType],
        arguments: [
        tx.pure(bcs.vector(bcs.u8()).serialize(orderHashBytes)),
        tx.pure.u256(salt),
        tx.pure.string(makerAsset),
        tx.pure.string(takerAsset),
        tx.pure.u64(makingAmount),
        tx.pure.u64(takingAmount),
        tx.pure.u64(duration),
        tx.pure(bcs.vector(bcs.u8()).serialize(hashlockBytes)),
        tx.pure.u64(srcSafetyDeposit),
        tx.pure.u64(dstSafetyDeposit),
        tx.pure.bool(allowPartialFills),
        tx.pure.u8(partsAmount),
        fundingCoin,
        tx.pure.u64(timelocks.srcWithdrawal),
        tx.pure.u64(timelocks.srcPublicWithdrawal),
        tx.pure.u64(timelocks.srcCancellation),
        tx.pure.u64(timelocks.srcPublicCancellation),
        tx.pure.u64(timelocks.dstWithdrawal),
        tx.pure.u64(timelocks.dstPublicWithdrawal),
        tx.pure.u64(timelocks.dstCancellation),
        tx.object(SUI_CLOCK_OBJECT_ID)
        ]
    });

    /* ─────────────── dual-sign (intent signing) ─────────────── */

    const txBytes   = await tx.build({ client: this.client });
    const sigUser   = this.keypair.signTransaction(txBytes);
    const sigSponsor = this.sponsor.signTransactionBlock(txBytes);

    const result = await this.client.executeTransactionBlock({
        transactionBlock: txBytes,
        signature: [sigUser, sigSponsor],        // order irrelevant
        options: { showEffects: true, showEvents: true }
    });

  /* ─────────────── parse WalletCreated event ─────────────── */

    const walletEvt = result.events?.find(e => e.type.includes('WalletCreated'));
    if (!walletEvt?.parsedJson) {
        throw new Error('Failed to create wallet – no WalletCreated event');
    }
    const walletId = (walletEvt.parsedJson as any).wallet_id as string;

    console.log('✅ Wallet created at:', walletId);
    console.log('⏳ Waiting for object to be indexed…');
    await new Promise(res => setTimeout(res, 3_000));

    return walletId;
    }
    /**
     * Deploy source escrow (Sui as source) - pulls from wallet
     */
    async deploySrc(
        walletAddress: string,
        secretHashlock: string,
        secretIndex: number,
        merkleProof: string[][], // Array of byte arrays
        taker: string, // Taker address (resolver)
        makingAmount: bigint,
        takingAmount: bigint,
        safetyDeposit: bigint,
        tokenType: string = '0x2::sui::SUI'
    ): Promise<string> {
        console.log('Creating source escrow...');
        console.log('  Wallet address:', walletAddress);
        console.log('  Making amount:', makingAmount.toString());
        console.log('  Taking amount:', takingAmount.toString());
        console.log('  Taker:', taker);
        
        const tx = new Transaction();
        
        // Convert to bytes
        const secretHashlockBytes = Array.from(Buffer.from(secretHashlock.slice(2), 'hex'));
        
        // Serialize merkle proof - each node is a byte array
        const merkleProofBytes = merkleProof.map(node => 
            Array.from(Buffer.from(node[0].slice(2), 'hex'))
        );
        
        // Split safety deposit coin
        const [safetyDepositCoin] = tx.splitCoins(tx.gas, [safetyDeposit]);
        
        tx.moveCall({
            target: `${this.packageId}::escrow_create::create_escrow_src`,
            typeArguments: [tokenType],
            arguments: [
                tx.object(walletAddress),
                tx.pure(bcs.vector(bcs.u8()).serialize(secretHashlockBytes)),
                tx.pure.u8(secretIndex),
                tx.pure(bcs.vector(bcs.vector(bcs.u8())).serialize(merkleProofBytes)),
                tx.pure.address(taker),
                tx.pure.u64(makingAmount),
                tx.pure.u64(takingAmount),
                safetyDepositCoin,
                tx.object(SUI_CLOCK_OBJECT_ID)
            ]
        });

        const result = await this.client.signAndExecuteTransaction({
            transaction: tx,
            signer: this.keypair,
            options: {
                showEffects: true,
                showEvents: true
            }
        });
        
        const escrowCreatedEvent = result.events?.find(
            e => e.type.includes('EscrowCreated')
        );
        
        if (!escrowCreatedEvent || !escrowCreatedEvent.parsedJson) {
            throw new Error('Failed to create escrow - no event emitted');
        }
        
        const escrowId = (escrowCreatedEvent.parsedJson as any).escrow_id;
        console.log('✅ Source escrow created at:', escrowId);
        
        return escrowId;
    }

    /**
     * Deploy destination escrow (Sui as destination)
     */
    async deployDst(
        orderHash: string,
        hashlock: string,
        maker: string, // Maker address
        amount: bigint,
        safetyDeposit: bigint,
        timelocks: {
            srcWithdrawal: bigint;
            srcPublicWithdrawal: bigint;
            srcCancellation: bigint;
            srcPublicCancellation: bigint;
            dstWithdrawal: bigint;
            dstPublicWithdrawal: bigint;
            dstCancellation: bigint;
        },
        tokenType: string = '0x2::sui::SUI'
    ): Promise<string> {
        console.log('Creating destination escrow...');
        
        const tx = new Transaction();
        
        // Convert immutables data
        const orderHashBytes = Array.from(Buffer.from(orderHash.slice(2), 'hex'));
        const hashlockBytes = Array.from(Buffer.from(hashlock.slice(2), 'hex'));
        
        // Split coins for token deposit and safety deposit
        const [tokenCoin, safetyDepositCoin] = tx.splitCoins(
            tx.gas,
            [amount, safetyDeposit]
        );
        
        tx.moveCall({
            target: `${this.packageId}::escrow_create::create_escrow_dst`,
            typeArguments: [tokenType],
            arguments: [
                tx.pure(bcs.vector(bcs.u8()).serialize(orderHashBytes)),
                tx.pure(bcs.vector(bcs.u8()).serialize(hashlockBytes)),
                tx.pure.address(maker),
                tokenCoin,
                safetyDepositCoin,
                // Relative timelocks
                tx.pure.u64(timelocks.srcWithdrawal),
                tx.pure.u64(timelocks.srcPublicWithdrawal),
                tx.pure.u64(timelocks.srcCancellation),
                tx.pure.u64(timelocks.srcPublicCancellation),
                tx.pure.u64(timelocks.dstWithdrawal),
                tx.pure.u64(timelocks.dstPublicWithdrawal),
                tx.pure.u64(timelocks.dstCancellation),
                tx.object(SUI_CLOCK_OBJECT_ID)
            ]
        });

        const result = await this.client.signAndExecuteTransaction({
            transaction: tx,
            signer: this.keypair,
            options: {
                showEffects: true,
                showEvents: true
            }
        });
        
        const escrowCreatedEvent = result.events?.find(
            e => e.type.includes('EscrowCreated')
        );
        
        if (!escrowCreatedEvent || !escrowCreatedEvent.parsedJson) {
            throw new Error('Failed to create dst escrow - no event emitted');
        }
        
        const escrowId = (escrowCreatedEvent.parsedJson as any).escrow_id;
        console.log('✅ Destination escrow created at:', escrowId);
        
        return escrowId;
    }

    /**
     * Withdraw from escrow
     */
    async withdraw(
        escrowAddress: string,
        escrowType: 'src' | 'dst',
        secret: string,
        tokenType: string = '0x2::sui::SUI'
    ): Promise<void> {
        console.log(`Withdrawing from ${escrowType} escrow ${escrowAddress}...`);
        
        const tx = new Transaction();
        
        // Convert secret to bytes
        const secretBytes = Array.from(Buffer.from(secret.slice(2), 'hex'));
        
        tx.moveCall({
            target: `${this.packageId}::escrow_withdraw::withdraw_${escrowType}`,
            typeArguments: [tokenType],
            arguments: [
                tx.object(escrowAddress),
                tx.pure(bcs.vector(bcs.u8()).serialize(secretBytes)),
                tx.object(SUI_CLOCK_OBJECT_ID)
            ]
        });
        
        const result = await this.client.signAndExecuteTransaction({
            transaction: tx,
            signer: this.keypair,
            options: {
                showEffects: true,
                showEvents: true
            }
        });
        
        console.log('✅ Withdrawal successful:', result.digest);
    }

    /**
     * Cancel escrow
     */
    async cancel(
        escrowAddress: string,
        escrowType: 'src' | 'dst',
        tokenType: string = '0x2::sui::SUI'
    ): Promise<void> {
        console.log(`Cancelling ${escrowType} escrow ${escrowAddress}...`);
        
        const tx = new Transaction();
        
        tx.moveCall({
            target: `${this.packageId}::escrow_cancel::cancel_${escrowType}`,
            typeArguments: [tokenType],
            arguments: [
                tx.object(escrowAddress),
                tx.object(SUI_CLOCK_OBJECT_ID)
            ]
        });
        
        const result = await this.client.signAndExecuteTransaction({
            transaction: tx,
            signer: this.keypair,
            options: {
                showEffects: true,
                showEvents: true
            }
        });
        
        console.log('✅ Cancellation successful:', result.digest);
    }

    /**
     * Get wallet info from chain
     */
    async getWalletInfo(walletId: string): Promise<WalletInfo | null> {
        try {
            const response = await this.client.getObject({
                id: walletId,
                options: { showContent: true }
            });

            if (!response.data || !response.data.content || response.data.content.dataType !== 'moveObject') {
                console.error('Object not found or not a Move object');
                return null;
            }

            const fields = response.data.content.fields as any;
            
            // Debug logging
            console.log('Raw wallet fields:', JSON.stringify(fields, null, 2));
            
            // Helper function to safely convert to BigInt
            const toBigInt = (value: any): bigint => {
                if (value === undefined || value === null) {
                    console.warn('Value is undefined/null, defaulting to 0');
                    return BigInt(0);
                }
                return BigInt(value.toString());
            };
            
            // Helper to convert byte array or base64 to hex
            const toHex = (value: any): string => {
                if (Array.isArray(value)) {
                    return '0x' + Buffer.from(value).toString('hex');
                } else if (typeof value === 'string') {
                    // Might be base64 encoded
                    return '0x' + Buffer.from(value, 'base64').toString('hex');
                }
                return '0x' + value.toString('hex');
            };
            
            return {
                id: walletId,
                orderHash: toHex(fields.order_hash),
                salt: fields.salt || '0',
                maker: fields.maker,
                makerAsset: fields.maker_asset,
                takerAsset: fields.taker_asset,
                makingAmount: toBigInt(fields.making_amount),
                takingAmount: toBigInt(fields.taking_amount),
                duration: toBigInt(fields.duration),
                hashlock: toHex(fields.hashlock),
                timelocks: {
                    srcWithdrawal: toBigInt(fields.timelocks?.fields?.src_withdrawal || fields.timelocks?.src_withdrawal),
                    srcPublicWithdrawal: toBigInt(fields.timelocks?.fields?.src_public_withdrawal || fields.timelocks?.src_public_withdrawal),
                    srcCancellation: toBigInt(fields.timelocks?.fields?.src_cancellation || fields.timelocks?.src_cancellation),
                    srcPublicCancellation: toBigInt(fields.timelocks?.fields?.src_public_cancellation || fields.timelocks?.src_public_cancellation),
                    dstWithdrawal: toBigInt(fields.timelocks?.fields?.dst_withdrawal || fields.timelocks?.dst_withdrawal),
                    dstPublicWithdrawal: toBigInt(fields.timelocks?.fields?.dst_public_withdrawal || fields.timelocks?.dst_public_withdrawal),
                    dstCancellation: toBigInt(fields.timelocks?.fields?.dst_cancellation || fields.timelocks?.dst_cancellation),
                },
                srcSafetyDeposit: toBigInt(fields.src_safety_deposit_amount),
                dstSafetyDeposit: toBigInt(fields.dst_safety_deposit_amount),
                allowPartialFills: fields.allow_partial_fills || false,
                partsAmount: Number(fields.parts_amount || 0),
                lastUsedIndex: Number(fields.last_used_index || 255),
                balance: toBigInt(fields.balance?.fields?.value || fields.balance?.value || fields.balance || 0),
                createdAt: toBigInt(fields.created_at),
                isActive: fields.is_active !== undefined ? fields.is_active : true
            };
        } catch (error) {
            console.error('Failed to parse wallet info:', error);
            console.error('Error details:', error);
            return null;
        }
    }

    /**
     * Calculate secret index for partial fill based on cumulative amount
     */
    calculateSecretIndex(
        walletInfo: WalletInfo,
        fillAmount: bigint
    ): number {
        if (!walletInfo.allowPartialFills) {
            return 0; // Full fill only uses index 0
        }

        const totalAmount = walletInfo.makingAmount;
        const alreadyFilled = totalAmount - walletInfo.balance;
        const newTotalFilled = alreadyFilled + fillAmount;
        
        // Calculate which bucket this falls into
        const partsAmount = BigInt(walletInfo.partsAmount);
        
        // For exact 100% fill, use last index
        if (newTotalFilled === totalAmount) {
            return walletInfo.partsAmount;
        }
        
        // Otherwise calculate bucket
        const bucketSize = totalAmount / partsAmount;
        const bucketIndex = Number(newTotalFilled / bucketSize);
        
        // Ensure we don't exceed max index
        return Math.min(bucketIndex, walletInfo.partsAmount);
    }

    /**
     * Get current taking amount based on Dutch auction
     */
    async getCurrentTakingAmount(
    wallet: WalletInfo,
    relativeMakingAmount: bigint,
        ): Promise<bigint> {
            const tx = new Transaction();
            let tokenType ='0x2::sui::SUI';

            tx.moveCall({
            target: `${this.packageId}::utils::get_taking_amount`,
            typeArguments: [tokenType],
            arguments: [
                tx.object(wallet.id),          // &Wallet<T>
                tx.pure.u64(relativeMakingAmount),   // making_amount (u64)
                tx.object(SUI_CLOCK_OBJECT_ID),                 // &Clock
            ],
            });

            /* dev-inspect is a free local VM run – perfect for reads */
            const dev = await this.client.devInspectTransactionBlock({
            sender: this.getSignerAddress(),
            transactionBlock: tx,
            });

            const raw = dev.results?.[0]?.returnValues?.[0];
            if (!raw) throw new Error('No return value from get_taking_amount');

            const [bytes] = raw;                                 // [Uint8Array, tag]
            const taking  =Buffer.from(bytes).readBigUInt64LE(0);              // BigInt  ➟  correct value

            return taking;
        }


    /**
     * Helper to build merkle tree (for testing partial fills)
     */
    static buildMerkleTree(secrets: string[]): {
        root: string;
        proofs: Map<number, string[][]>;
    } {
        // Simple implementation - in production use a proper merkle tree library
        const leaves = secrets.map(s => keccak256(s));
        const proofs = new Map<number, string[][]>();
        
        // For now, return a simple structure
        // In production, implement proper merkle tree construction
        return {
            root: keccak256(leaves.join('')),
            proofs
        };
    }
}