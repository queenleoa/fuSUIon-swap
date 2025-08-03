import {id, Interface, JsonRpcProvider} from 'ethers'
import * as Sdk from '@1inch/cross-chain-sdk'
import EscrowFactoryContract from '../dist/contracts/EscrowFactory.sol/EscrowFactory.json'

export class EscrowFactory {
    private iface = new Interface(EscrowFactoryContract.abi)

    constructor(
        private readonly provider: JsonRpcProvider,
        private readonly address: string
    ) {}

    public async getSourceImpl(): Promise<Sdk.Address> {
        return Sdk.Address.fromBigInt(
            BigInt(
                await this.provider.call({
                    to: this.address,
                    data: id('ESCROW_SRC_IMPLEMENTATION()').slice(0, 10)
                })
            )
        )
    }

    public async getDestinationImpl(): Promise<Sdk.Address> {
        return Sdk.Address.fromBigInt(
            BigInt(
                await this.provider.call({
                    to: this.address,
                    data: id('ESCROW_DST_IMPLEMENTATION()').slice(0, 10)
                })
            )
        )
    }

   public async getSrcDeployEvent(blockHash: string): Promise<[Sdk.Immutables, Sdk.DstImmutablesComplement]> {
    const event = this.iface.getEvent('SrcEscrowCreated');
    if (!event) {
        throw new Error('SrcEscrowCreated event not found in ABI');
    }

    // First attempt: get logs directly by block hash
    const logs = await this.provider.getLogs({
        blockHash,
        address: this.address,
        topics: [event.topicHash]
    });

    let targetLog = logs.length > 0 ? logs[0] : undefined;

    // Fallback: look through tx receipts if logs were missing
    if (!targetLog) {
        console.warn(`⚠️ No logs found via blockHash. Falling back to tx receipt logs...`);

        const block = await this.provider.getBlock(blockHash);
        if (!block) {
            throw new Error(`Could not fetch block for hash ${blockHash}`);
        }

        for (const txHash of Array.from(block.transactions).reverse()) {
            const receipt = await this.provider.getTransactionReceipt(txHash);
            if (!receipt?.logs) continue;

            const matchingLog = receipt.logs.find(log =>
                log.address.toLowerCase() === this.address.toLowerCase() &&
                log.topics[0] === event.topicHash
            );

            if (matchingLog) {
                targetLog = matchingLog;
                break;
            }
        }

        if (!targetLog) {
            throw new Error(`SrcEscrowCreated event not found in any transaction of block ${blockHash}`);
        }
    }

    // Safely parse the log (we know it's defined now)
    const parsed = this.iface.parseLog({
        topics: targetLog.topics,
        data: targetLog.data
    });

    const immutables = parsed!.args.srcImmutables ?? parsed!.args[0];
    const complement = parsed!.args.dstImmutablesComplement ?? parsed!.args[1];

    return [
        Sdk.Immutables.new({
            orderHash: immutables[0],
            hashLock: Sdk.HashLock.fromString(immutables[1]),
            maker: Sdk.Address.fromBigInt(immutables[2]),
            taker: Sdk.Address.fromBigInt(immutables[3]),
            token: Sdk.Address.fromBigInt(immutables[4]),
            amount: immutables[5],
            safetyDeposit: immutables[6],
            timeLocks: Sdk.TimeLocks.fromBigInt(immutables[7])
        }),
        Sdk.DstImmutablesComplement.new({
            maker: Sdk.Address.fromBigInt(complement[0]),
            amount: complement[1],
            token: Sdk.Address.fromBigInt(complement[2]),
            safetyDeposit: complement[3]
        })
    ];
}}

