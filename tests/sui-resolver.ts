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
        await new Promise(resolve => setTimeout(resolve, 2000));
        
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
                return null;
            }

            const fields = response.data.content.fields as any;
            
            return {
                id: walletId,
                orderHash: '0x' + Buffer.from(fields.order_hash).toString('hex'),
                salt: fields.salt,
                maker: fields.maker,
                makerAsset: fields.maker_asset,
                takerAsset: fields.taker_asset,
                makingAmount: BigInt(fields.making_amount),
                takingAmount: BigInt(fields.taking_amount),
                duration: BigInt(fields.duration),
                hashlock: '0x' + Buffer.from(fields.hashlock).toString('hex'),
                timelocks: {
                    srcWithdrawal: BigInt(fields.timelocks.src_withdrawal),
                    srcPublicWithdrawal: BigInt(fields.timelocks.src_public_withdrawal),
                    srcCancellation: BigInt(fields.timelocks.src_cancellation),
                    srcPublicCancellation: BigInt(fields.timelocks.src_public_cancellation),
                    dstWithdrawal: BigInt(fields.timelocks.dst_withdrawal),
                    dstPublicWithdrawal: BigInt(fields.timelocks.dst_public_withdrawal),
                    dstCancellation: BigInt(fields.timelocks.dst_cancellation),
                },
                srcSafetyDeposit: BigInt(fields.src_safety_deposit_amount),
                dstSafetyDeposit: BigInt(fields.dst_safety_deposit_amount),
                allowPartialFills: fields.allow_partial_fills,
                partsAmount: fields.parts_amount,
                lastUsedIndex: fields.last_used_index,
                balance: BigInt(fields.balance.value || 0),
                createdAt: BigInt(fields.created_at),
                isActive: fields.is_active
            };
        } catch (error) {
            console.error('Failed to get wallet info:', error);
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
    getCurrentTakingAmount(
        walletInfo: WalletInfo,
        makingAmount: bigint,
        currentTime?: number
    ): bigint {
        const now = currentTime || Date.now();
        const startTime = Number(walletInfo.createdAt);
        const duration = Number(walletInfo.duration);
        const endTime = startTime + duration;
        
        // Clamp current time
        const t = Math.max(startTime, Math.min(now, endTime));
        
        // Linear interpolation
        const progress = BigInt(t - startTime);
        const totalDuration = BigInt(endTime - startTime);
        
        if (totalDuration === 0n) {
            return walletInfo.makingAmount; // No duration, use max price
        }
        
        // Calculate taking amount at current time
        const startAmount = walletInfo.makingAmount; // Start high (1:1)
        const endAmount = walletInfo.takingAmount;   // End low (minimum)
        
        const currentTaking = (startAmount * (totalDuration - progress) + endAmount * progress) / totalDuration;
        
        // Scale by the actual making amount requested
        return (currentTaking * makingAmount) / walletInfo.makingAmount;
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