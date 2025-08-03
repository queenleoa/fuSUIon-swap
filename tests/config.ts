import {z} from 'zod'
import Sdk from '@1inch/cross-chain-sdk'
import * as process from 'node:process'

const bool = z
    .string()
    .transform((v) => v.toLowerCase() === 'true')
    .pipe(z.boolean())

const ConfigSchema = z.object({
    ARBITRUM_RPC: z.string().url(),
    SUI_RPC: z.string().url(),
    SUI_ESCROW_PACKAGE_ID: z.string(),
    // Private keys
    EVM_USER_PRIVATE_KEY: z.string(),
    EVM_RESOLVER_PRIVATE_KEY: z.string(),
    SUI_USER_PRIVATE_KEY: z.string(),
    SUI_RESOLVER_PRIVATE_KEY: z.string(),
})

const fromEnv = ConfigSchema.parse(process.env)

export const config = {
    evm: {
        chainId: 42161,
        rpc: fromEnv.ARBITRUM_RPC,
        limitOrderProtocol: '0x111111125421ca6dc452d289314280a0f8842a65', // 1inch LOP on Arbitrum
        wrappedNative: '0x82aF49447D8a07e3bd95BD0d56f35241523fBab1', // WETH on Arbitrum
        tokens: {
            USDC: {
                address: '0xaf88d065e77c8cC2239327C5EDb3A432268e5831', // Native USDC on Arbitrum
                decimals: 6
            }
        },
        // Test accounts - you'll need to fund these with ETH and USDC
        accounts: {
            user: {
                privateKey: fromEnv.EVM_USER_PRIVATE_KEY,
                // Derived address will be shown when running
            },
            resolver: {
                privateKey: fromEnv.EVM_RESOLVER_PRIVATE_KEY,
            }
        }
    },
    sui: {
        rpc: fromEnv.SUI_RPC,
        packageId: fromEnv.SUI_ESCROW_PACKAGE_ID,
        accounts: {
            user: {
                privateKey: fromEnv.SUI_USER_PRIVATE_KEY,
            },
            resolver: {
                privateKey: fromEnv.SUI_RESOLVER_PRIVATE_KEY,
            }
        }
    },
    // Cross-chain swap config
    swap: {
        // Timelocks in seconds (converted to ms when needed)
        timelocks: {
            srcWithdrawal: 30,        // 30 sec finality lock
            srcPublicWithdrawal: 300, // 5 min for private withdrawal
            srcCancellation: 600,     // 10 min
            srcPublicCancellation: 900, // 15 min
            dstWithdrawal: 20,        // 20 sec finality lock
            dstPublicWithdrawal: 240, // 4 min
            dstCancellation: 480      // 8 min
        },
        safetyDeposit: {
            arbitrum: '0.0001', // ETH (reduced for demo)
            sui: '0.01'         // SUI
        }
    }
} as const

export type Config = typeof config